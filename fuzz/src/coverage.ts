/**
 * What the differential fuzzers exercise: one corpus per fuzzer mode, made
 * by the fuzzers' own generators, replayed through instrumented builds of the
 * Rust, Go and TypeScript runners, and the code they never reach listed per
 * source file. See ../README.md ("Coverage").
 *
 *   node fuzz/src/coverage.ts [--count 3000] [--seed 1] [--langs rust,go,typescript]
 *                             [--modes parse,canonical,format,json,schema,schema-check]
 *                             [--no-generate] [--no-build] [--report RUN]
 *
 * Writes:
 *   fuzz/.out/corpus/<mode>/          the corpus, in the runners' own input formats
 *   fuzz/.out/coverage/<lang>/        reports: summary.md, uncovered.txt, HTML
 *   fuzz/.out/coverage/summary.md     every language's numbers per area and file
 *   fuzz/.out/coverage/raw/<run>/     the raw profiles of each run (never deleted: remove old runs by hand)
 *   fuzz/.out/coverage/build/         the instrumented builds
 *
 * Rust: `-C instrument-coverage`, merged with `llvm-profdata` and read with
 * `llvm-cov` (rustup's llvm-tools or any LLVM of rustc's major version on
 * PATH; LLVM_PROFDATA and LLVM_COV override). Go: `go build -cover` over the
 * module go/, `GOCOVERDIR`, `go tool covdata` and `go tool cover`.
 * TypeScript: Node's own block coverage (`NODE_V8_COVERAGE`) of
 * @haus-fmt/haus's dist/, mapped back to src/ through the source maps; no
 * dependency.
 *
 * Numbers: lines everywhere; Rust also regions (each arm of a branch, each
 * `?`, is a region), Go statements (the only unit it counts), TypeScript the
 * blocks V8 reports as never run (V8 merges a run block into its parent, so
 * there is no total of blocks to divide by).
 */
import { spawnSync, type SpawnSyncOptions } from "node:child_process"
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { SourceMap } from "node:module"
import { dirname, join, relative } from "node:path"
import { parseArgs } from "node:util"
import { compileSchemaFile, parseAll } from "../../typescript/packages/haus/dist/index.js"
import * as h from "../../typescript/packages/haus/dist/schema.js"
import { formatInput } from "./format-gen.ts"
import { STYLES, tsFormat, type Options, type Style } from "./format.ts"
import { input, Rng, value as hausValue } from "./generate.ts"
import {
  anyJ, badEnvelopeJ, badHausValueJ, envelope, hausJsonJ, hausValueJ, mutateJ, nested, NOT_JSON, Obj, parseJ, PlainGen, single, textOf, wrongJ, writeJ, type J,
} from "./json-gen.ts"
import { caseLine as jsonCaseLine, MODES as JSON_MODES, typed, type JsonCase, type Mode as JsonMode } from "./json-runners.ts"
import { schemaFile } from "./schema-check-gen.ts"
import { Generator, type Env, type Type } from "./schema-gen.ts"
import { caseLine as schemaCaseLine, schemaTexts, type SchemaCase } from "./schema-runners.ts"

const root = new URL("../..", import.meta.url).pathname.replace(/\/$/, "")
const OUT = join(root, "fuzz/.out")
const CORPUS = join(OUT, "corpus")
const COVERAGE = join(OUT, "coverage")
const BUILD = join(COVERAGE, "build")
const ALL_MODES = ["parse", "canonical", "format", "json", "schema", "schema-check"] as const
type FuzzMode = (typeof ALL_MODES)[number]
const ALL_LANGS = ["rust", "go", "typescript"] as const
type Lang = (typeof ALL_LANGS)[number]

/** The schema files of the schema fuzzer, and of the JSON fuzzer (schema.ts, json.ts). */
const SCHEMA_DIRS = [join(root, "test-suite/schema"), join(root, "fuzz/schema")]
const JSON_SCHEMA_DIRS = [...SCHEMA_DIRS, join(root, "test-suite/json"), join(root, "fuzz/json")]

const enc = new TextEncoder()
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })
const pad5 = (i: number) => String(i).padStart(5, "0")
const hex = (b: Uint8Array) => Buffer.from(b).toString("hex")

// ── the corpus ───────────────────────────────────────────────

/** A directory of cases DIR/00000.haus … DIR/{n-1}.haus, as the parser and formatter runners read them. */
interface CaseDir {
  readonly dir: string
  readonly n: number
}

/** A batch of the formatter fuzzer: its options, its inputs, and TypeScript's outputs of the inputs every layout accepts (format.ts, round two). */
interface FormatBatch {
  readonly options: Options
  readonly input: CaseDir
  readonly outputs: Record<Style, CaseDir>
}

/** What a corpus directory holds: corpus/<mode>/manifest.json. */
type Manifest =
  | { readonly mode: "parse" | "canonical"; readonly cases: CaseDir }
  | { readonly mode: "format"; readonly batches: readonly FormatBatch[] }
  | { readonly mode: "json"; readonly files: Record<JsonMode, string> }
  | { readonly mode: "schema" | "schema-check"; readonly file: string }

function writeDir(dir: string, cases: readonly Uint8Array[]): CaseDir {
  mkdirSync(dir, { recursive: true })
  cases.forEach((c, i) => writeFileSync(join(dir, `${pad5(i)}.haus`), c))
  return { dir: relative(root, dir), n: cases.length }
}

const abs = (p: string) => join(root, p)

/** The types of some schema files, resolved as the fuzzers resolve them (spec/lean/scripts/schema-types.ts). */
function resolvedTypes(dirs: readonly string[]): { envs: Map<string, Env>; entries: { suite: string; type: string }[] } {
  const envs = new Map<string, Env>()
  const entries: { suite: string; type: string }[] = []
  for (const dir of dirs) {
    const p = spawnSync(process.execPath, [join(root, "spec/lean/scripts/schema-types.ts"), dir], { encoding: "utf8", maxBuffer: 1 << 28 })
    if (p.status !== 0) throw new Error(`schema-types.ts ${dir}: ${p.stderr}`)
    for (const s of JSON.parse(p.stdout).suites as { name: string; defs?: [string, Type][]; error?: string }[]) {
      if (s.error !== undefined) throw new Error(`${s.name}: the schema file is rejected: ${s.error}`)
      envs.set(s.name, new Map(s.defs))
      for (const [name] of s.defs!) if (/^[A-Z][A-Za-z0-9_]*$/.test(name)) entries.push({ suite: s.name, type: name })
    }
  }
  return { envs, entries }
}

const suiteSeeds = (dirs: readonly string[]) =>
  dirs.flatMap((d) => readdirSync(d).filter((f) => f.endsWith(".haus")).sort().map((f) => new Uint8Array(readFileSync(join(d, f)))))

/**
 * The corpus of one mode, generated as the fuzzer generates its cases (the
 * loops of main.ts, format.ts, json.ts, schema.ts and schema-check.ts, with
 * the same generators), and written in the runners' input formats.
 */
function generate(mode: FuzzMode, count: number, seed: number): Manifest {
  const dir = join(CORPUS, mode)
  mkdirSync(dir, { recursive: true })
  const rng = new Rng(seed)
  let manifest: Manifest
  switch (mode) {
    case "parse":
    case "canonical": {
      // main.ts runParsers: the conformance suite as seeds.
      const seeds = suiteSeeds([join(root, "test-suite/valid"), join(root, "test-suite/invalid")])
      manifest = { mode, cases: writeDir(join(dir, "cases"), Array.from({ length: count }, () => input(rng, seeds))) }
      break
    }
    case "format": {
      // format.ts run: options per batch, mostly the default. Batches of 250 rather than
      // the fuzzer's 1000, so that a corpus of a few thousand sees the other options as a long run does.
      const OPTIONS: readonly Options[] = [{ indent: 4, width: 40 }, { indent: 1, width: 100 }, { indent: 2, width: 20 }, { indent: 8, width: 60 }, { indent: 0, width: 0 }]
      const seeds = suiteSeeds([join(root, "test-suite/valid"), join(root, "test-suite/format/cases"), join(root, "test-suite/format/examples")])
      const batches: FormatBatch[] = []
      for (let done = 0, k = 0; done < count; done += 250, k++) {
        const options = rng.chance(0.7) ? { indent: 2, width: 80 } : rng.pick(OPTIONS)
        const cases = Array.from({ length: Math.min(250, count - done) }, () => formatInput(rng, seeds))
        const outs = new Map(STYLES.map((s) => [s, cases.map((c) => tsFormat(c, s, options))]))
        const accepted = cases.flatMap((_, i) => (STYLES.every((s) => outs.get(s)![i]!.ok) ? [i] : []))
        const batchDir = join(dir, `batch-${pad5(k)}`)
        const outputs = Object.fromEntries(STYLES.map((s) => [s, writeDir(join(batchDir, s), accepted.map((i) => enc.encode((outs.get(s)![i] as { text: string }).text)))])) as Record<Style, CaseDir>
        batches.push({ options, input: writeDir(join(batchDir, "input"), cases), outputs })
      }
      manifest = { mode, batches }
      break
    }
    case "schema": {
      // schema.ts run.
      const { envs, entries } = resolvedTypes(SCHEMA_DIRS)
      const gens = new Map([...envs].map(([s, env]) => [s, new Generator(env)]))
      const cases: SchemaCase[] = Array.from({ length: count }, () => {
        const e = rng.pick(entries)
        const deep = rng.chance(0.04) ? rng.pick([8, 30, 60, 100, 126, 200, 254, 300]) : 0
        const miss = rng.chance(0.55) ? 0 : rng.pick([0.03, 0.08, 0.2])
        return { suite: e.suite, type: e.type, text: gens.get(e.suite)!.value(rng, { ref: e.type }, { miss, maxDepth: rng.pick([1, 2, 3, 4, 6]), deep }) }
      })
      writeFileSync(join(dir, "cases.txt"), cases.map((c) => schemaCaseLine(c) + "\n").join(""))
      manifest = { mode, file: relative(root, join(dir, "cases.txt")) }
      break
    }
    case "schema-check": {
      // schema-check.ts run: the files, then the bases of the files with one mistake (run too, to compare codes).
      const cases = Array.from({ length: count }, () => schemaFile(rng)).map((c) => (c.bytes.length === 0 ? { bytes: Uint8Array.of(0x20) } : c))
      const bases = cases.flatMap((c) => (c.base ? [c.base.length ? c.base : Uint8Array.of(0x20)] : []))
      writeFileSync(join(dir, "cases.txt"), [...cases.map((c) => c.bytes), ...bases].map((b) => hex(b) + "\n").join(""))
      manifest = { mode, file: relative(root, join(dir, "cases.txt")) }
      break
    }
    case "json": {
      const files = Object.fromEntries(JSON_MODES.map((m) => {
        const file = join(dir, `${m}.txt`)
        writeFileSync(file, jsonCases(m, count, rng).map((c) => jsonCaseLine(c) + "\n").join(""))
        return [m, relative(root, file)]
      })) as Record<JsonMode, string>
      manifest = { mode, files }
      break
    }
  }
  writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest, null, 1) + "\n")
  return manifest
}

let jsonContext: ReturnType<typeof makeJsonContext> | undefined

function makeJsonContext() {
  const { envs, entries } = resolvedTypes(JSON_SCHEMA_DIRS)
  const valid = join(root, "test-suite/valid")
  const seeds = readdirSync(valid).filter((f) => f.endsWith(".haus")).sort().map((f) => readFileSync(join(valid, f), "utf8")).filter((t) => single(t) !== undefined)
  // Lean's plain JSON of generated values seeds a third of `read` (json.ts); TypeScript's
  // stands in for it here (the JSON fuzzer keeps the two equal), so Lean needn't be built.
  const compiled = new Map<string, Record<string, h.Schema<unknown>>>()
  for (const [s, t] of schemaTexts(JSON_SCHEMA_DIRS)) {
    try {
      compiled.set(s, compileSchemaFile(t).schemas as Record<string, h.Schema<unknown>>)
    } catch {}
  }
  const plainJsonOf = (suite: string, type: string, text: string): string | undefined => {
    try {
      const schema = compiled.get(suite)?.[type]
      const vs = parseAll(text)
      return schema && vs.length === 1 ? h.toJson(schema, h.decode(schema, vs[0]!)) : undefined
    } catch {
      return undefined
    }
  }
  return {
    entries, seeds, plainJsonOf,
    hausGen: new Map([...envs].map(([s, env]) => [s, new Generator(env)])),
    plainGen: new Map([...envs].map(([s, env]) => [s, new PlainGen(env)])),
  }
}

/** The cases of one JSON mode: json.ts's `generate`, the same choices in the same order. */
function jsonCases(mode: JsonMode, n: number, r: Rng): JsonCase[] {
  const { entries, seeds, hausGen, plainGen, plainJsonOf } = (jsonContext ??= makeJsonContext())
  const pickEntry = () => r.pick(entries)
  const missRate = () => (r.chance(0.55) ? 0 : r.pick([0.03, 0.08, 0.2]))
  const deepness = () => (r.chance(0.04) ? r.pick([8, 30, 60, 100, 126, 200, 254, 300]) : 0)
  const hausFor = (e: { suite: string; type: string }, miss: number) =>
    hausGen.get(e.suite)!.value(r, { ref: e.type }, { miss, maxDepth: r.pick([1, 2, 3, 4, 6]), deep: deepness() })
  const anyHaus = (): string => {
    const x = r.next()
    if (x < 0.5) return hausValue(r, 0)
    if (x < 0.75) return hausFor(pickEntry(), 0)
    if (x < 0.9 && seeds.length) return r.pick(seeds)
    const k = r.pick([100, 254, 255, 256, 257])
    const [open, close] = r.pick([["[", "]"], ["{ a: ", " }"], ["Some(", ")"], ["T { a: ", " }"], ["T(1, ", ")"]] as const)
    return open.repeat(k) + r.pick(["1", '"x"', 'x"00"', "[]", "N"]) + close.repeat(k)
  }
  const deepHausJson = (): J => {
    const k = r.pick([254, 255, 256, 257])
    let j: J = { 0: () => new Obj([["_num", "1"]]), 1: () => "x", 2: () => [] as J[] }[r.int(3)]!()
    const shape = r.int(4)
    for (let i = 0; i < k; i++) {
      j = shape === 0 ? new Obj([["_tag", "T"], ["_args", [new Obj([["_rec", new Obj([["a", j]])]])]]])
        : shape === 1 ? new Obj([["_rec", new Obj([["a", j]])]])
        : shape === 2 ? [j]
        : new Obj([["_tag", "S"], ["_args", [j]]])
    }
    return envelope(j)
  }
  const ofText = (text: string, e = { suite: "-", type: "-" }): JsonCase => ({ mode, suite: e.suite, type: e.type, text: text === "" && !typed(mode) ? " " : text })
  switch (mode) {
    case "write":
      return Array.from({ length: n }, () => {
        const e = pickEntry()
        return ofText(hausFor(e, missRate()), e)
      })
    case "haus-json-write":
      return Array.from({ length: n }, () => ofText(anyHaus()))
    case "haus-json-read":
      return Array.from({ length: n }, () => {
        if (r.chance(0.03)) return ofText(r.pick(NOT_JSON))
        if (r.chance(0.04)) return ofText(textOf(r, deepHausJson(), 0.05))
        const v = single(anyHaus())
        let inner: J = v ? hausValueJ(v) : badHausValueJ(r)
        if (r.chance(0.3)) inner = mutateJ(r, inner, badHausValueJ)
        const j = r.chance(0.1) ? badEnvelopeJ(r, inner) : envelope(inner)
        return ofText(textOf(r, j, 0.08))
      })
    case "import":
      return Array.from({ length: n }, () => {
        const x = r.next()
        if (x < 0.06) return ofText(r.pick(NOT_JSON))
        let j: J
        if (x < 0.1) j = nested(r, r.pick([100, 254, 255, 256, 257]), anyJ(r, 4))
        else if (x < 0.25) {
          const v = single(anyHaus())
          j = v ? (r.chance(0.5) ? hausJsonJ(v) : hausValueJ(v)) : anyJ(r)
        } else if (x < 0.4) {
          const e = pickEntry()
          j = plainGen.get(e.suite)!.value(r, { ref: e.type }, { miss: missRate(), maxDepth: 3, deep: 0 })
        } else j = anyJ(r)
        return ofText(textOf(r, j, 0.12))
      })
    case "read": {
      const fromLean = Math.round(n * 0.35)
      const sources = Array.from({ length: fromLean }, () => {
        const e = pickEntry()
        return { suite: e.suite, type: e.type, text: hausFor(e, r.chance(0.8) ? 0 : 0.03) }
      })
      const cases: JsonCase[] = []
      for (let i = 0; i < n; i++) {
        const e = i < fromLean ? sources[i]! : pickEntry()
        const w = i < fromLean ? plainJsonOf(e.suite, e.type, sources[i]!.text) : undefined
        let j: J | undefined = w === undefined ? undefined : parseJ(w)
        if (j !== undefined && r.chance(0.4)) j = mutateJ(r, j, wrongJ)
        if (j === undefined) j = plainGen.get(e.suite)!.value(r, { ref: e.type }, { miss: missRate(), maxDepth: r.pick([1, 2, 3, 4, 6]), deep: deepness() })
        if (r.chance(0.01)) {
          const bytes = Buffer.from(writeJ(j), "utf8")
          const at = r.int(bytes.length + 1)
          const bad = r.pick([[0xff], [0x80], [0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xef, 0xbb]])
          cases.push({ mode, suite: e.suite, type: e.type, text: "", bytes: Uint8Array.from([...bytes.subarray(0, at), ...bad, ...bytes.subarray(at)]) })
          continue
        }
        cases.push({ mode, suite: e.suite, type: e.type, text: r.chance(0.02) ? r.pick(NOT_JSON) : textOf(r, j, 0.06) })
      }
      return cases
    }
  }
}

const readManifest = (mode: FuzzMode): Manifest => {
  const file = join(CORPUS, mode, "manifest.json")
  if (!existsSync(file)) throw new Error(`no corpus for ${mode}: run without --no-generate first`)
  return JSON.parse(readFileSync(file, "utf8"))
}

// ── replaying through programs (Rust, Go) ────────────────────

/** One run of a runner program on a part of the corpus. */
interface Job {
  readonly what: string
  readonly program: string
  readonly args: readonly string[]
}

const dirArgs = (d: CaseDir) => [abs(d.dir), String(d.n)]
const layoutArgs = (o: Options) => ["--indent", String(o.indent), "--width", String(o.width)]

/**
 * The formatter fuzzer's runs of one batch (format.ts checkFormat and
 * checkWriters): each layout on the inputs, each layout again on its own
 * output, compact and minimised outputs as pretty; the value writers in each layout.
 */
function formatJobs(b: FormatBatch, format: (style: Style, d: CaseDir) => Job | undefined, write: (style: Style) => Job | undefined): Job[] {
  const jobs: (Job | undefined)[] = []
  for (const style of STYLES) jobs.push(format(style, b.input), format(style, b.outputs[style]), write(style))
  jobs.push(format("pretty", b.outputs.compact), format("pretty", b.outputs.minimised))
  return jobs.filter((j): j is Job => j !== undefined)
}

function rustJobs(m: Manifest, bin: string): Job[] {
  const runner = join(bin, "examples/fuzz_runner")
  switch (m.mode) {
    case "parse":
      return [
        { what: "parse", program: runner, args: dirArgs(m.cases) },
        { what: "stream", program: runner, args: ["--stream", ...dirArgs(m.cases)] },
      ]
    case "canonical":
      return [{ what: "canonical", program: runner, args: ["--canonical", ...dirArgs(m.cases)] }]
    case "format":
      return m.batches.flatMap((b) =>
        formatJobs(
          b,
          (style, d) => (d.n ? { what: `format ${style}`, program: runner, args: ["--format", style, ...layoutArgs(b.options), ...dirArgs(d)] } : undefined),
          (style) => (style === "pretty" ? undefined : { what: `write ${style}`, program: runner, args: ["--write", style, ...dirArgs(b.input)] }),
        ))
    case "schema":
      return [
        { what: "schema (generated code)", program: join(bin, "schema_runner"), args: [abs(m.file)] },
        { what: "schema (runtime checker)", program: join(bin, "check_runner"), args: [abs(m.file)] },
      ]
    case "json":
      return JSON_MODES.map((mode) => ({ what: `json ${mode}`, program: join(bin, "json_runner"), args: [mode, abs(m.files[mode])] }))
    case "schema-check":
      return [{ what: "schema-check", program: join(bin, "schema_check_runner"), args: [abs(m.file)] }]
  }
}

function goJobs(m: Manifest, runner: string): Job[] {
  switch (m.mode) {
    case "parse":
      return [
        { what: "parse", program: runner, args: dirArgs(m.cases) },
        { what: "stream", program: runner, args: ["--stream", ...dirArgs(m.cases)] },
      ]
    case "canonical":
      return [{ what: "canonical", program: runner, args: ["--canonical", ...dirArgs(m.cases)] }]
    case "format":
      // Go's options take 0 as the default: it sits out the batches with an indent or width of 0 (pretty only, for the writers).
      return m.batches.flatMap((b) => {
        const takes = b.options.indent > 0 && b.options.width > 0
        return formatJobs(
          b,
          (style, d) => (d.n && takes ? { what: `format ${style}`, program: runner, args: ["--format", style, ...layoutArgs(b.options), ...dirArgs(d)] } : undefined),
          (style) =>
            style !== "pretty" ? { what: `write ${style}`, program: runner, args: ["--write", style, ...dirArgs(b.input)] }
            : takes ? { what: "write pretty", program: runner, args: ["--write", style, ...layoutArgs(b.options), ...dirArgs(b.input)] }
            : undefined,
        )
      })
    case "schema":
      return [{ what: "schema", program: runner, args: ["--schema", abs(m.file)] }]
    case "json":
      return JSON_MODES.map((mode) => ({ what: `json ${mode}`, program: runner, args: ["--json", mode, abs(m.files[mode])] }))
    case "schema-check":
      return [{ what: "schema-check", program: runner, args: ["--schema-check", abs(m.file)] }]
  }
}

/** Runs the jobs with an environment that collects coverage; output is discarded, crashes are counted. */
function runJobs(lang: string, jobs: readonly Job[], env: NodeJS.ProcessEnv): void {
  const failed: string[] = []
  for (const job of jobs) {
    const p = spawnSync(job.program, job.args, { env: { ...process.env, ...env }, stdio: ["ignore", "ignore", "pipe"], maxBuffer: 1 << 28, timeout: 900_000 })
    if (p.status !== 0) failed.push(`${job.what}: ${p.error ?? (p.signal ? `signal ${p.signal}` : `exit ${p.status}`)} ${String(p.stderr ?? "").trim().split("\n")[0] ?? ""}`)
  }
  console.log(`  ${lang}: ${jobs.length} runs${failed.length ? `, ${failed.length} failed (their coverage may be missing):\n    ${failed.join("\n    ")}` : ""}`)
}

// ── replaying in this process (TypeScript) ───────────────────

/**
 * The TypeScript runners the fuzzers run in their own process, on the
 * corpus; run by `coverage.ts --replay-ts` under NODE_V8_COVERAGE. Effect
 * (@haus-fmt/effect) is left out: only @haus-fmt/haus is measured.
 */
async function replayTypescript(modes: readonly FuzzMode[]): Promise<void> {
  const readDir = (d: CaseDir) => Array.from({ length: d.n }, (_, i) => new Uint8Array(readFileSync(join(abs(d.dir), `${pad5(i)}.haus`))))
  const lines = (file: string) => readFileSync(abs(file), "utf8").split("\n").filter((l) => l !== "")
  for (const mode of modes) {
    const m = readManifest(mode)
    switch (m.mode) {
      case "parse": {
        const { runners } = await import("./runners.ts")
        const cases = readDir(m.cases)
        for (const r of runners.filter((x) => x.name === "typescript" || x.name === "ts-stream")) r.run(abs(m.cases.dir), cases)
        break
      }
      case "canonical": {
        const { canonicalRunners } = await import("./runners.ts")
        canonicalRunners.find((x) => x.name === "typescript")!.run(abs(m.cases.dir), readDir(m.cases))
        break
      }
      case "format": {
        const { format, stringify } = await import("../../typescript/packages/haus/dist/index.js")
        for (const b of m.batches) {
          const inputs = readDir(b.input)
          const run = (d: CaseDir, style: Style, cases = readDir(d)) => cases.forEach((c) => tsFormat(c, style, b.options))
          for (const style of STYLES) {
            run(b.input, style, inputs)
            run(b.outputs[style], style)
          }
          run(b.outputs.compact, "pretty")
          run(b.outputs.minimised, "pretty")
          // checkWriters: each value, and the file, from the values of the inputs that parse.
          for (const c of inputs) {
            let values
            try {
              values = parseAll(utf8.decode(c))
            } catch {
              continue
            }
            for (const style of STYLES) {
              const opts = { style, indent: b.options.indent, width: b.options.width }
              try {
                values.forEach((v) => stringify(v, opts))
                format(values, opts)
              } catch {}
            }
          }
        }
        break
      }
      case "schema": {
        const { typescriptRunner, codecRunner } = await import("./schema-runners.ts")
        const cases = lines(m.file).map((l): SchemaCase => {
          const [suite, type, text] = l.split(" ")
          return { suite: suite!, type: type!, text: Buffer.from(text ?? "", "hex").toString("utf8") }
        })
        const texts = schemaTexts(SCHEMA_DIRS)
        typescriptRunner(texts).run("", cases)
        // typescript-codec: the compiled paths, checked against the generic one (codec.ts); needs @haus-fmt/import's dist.
        if (existsSync(join(root, "typescript/packages/import/dist/generate.js"))) {
          const built = join(COVERAGE, "build/ts-codecs")
          mkdirSync(built, { recursive: true })
          ;(await codecRunner(texts, SCHEMA_DIRS, built)).run("", cases)
        } else console.log("  typescript: no typescript/packages/import/dist, typescript-codec left out")
        break
      }
      case "json": {
        const { typescriptRunner } = await import("./json-runners.ts")
        const runner = typescriptRunner(schemaTexts(JSON_SCHEMA_DIRS))
        for (const mode of JSON_MODES) {
          const cases = lines(m.files[mode]).map((l): JsonCase => {
            const parts = l.split(" ")
            const bytes = Buffer.from(parts.at(-1)!, "hex")
            return typed(mode) ? { mode, suite: parts[0]!, type: parts[1]!, text: "", bytes } : { mode, suite: "-", type: "-", text: "", bytes }
          })
          runner.run(mode, "", cases)
        }
        break
      }
      case "schema-check":
        for (const l of lines(m.file)) {
          try {
            compileSchemaFile(utf8.decode(Buffer.from(l, "hex")))
          } catch {}
        }
        break
    }
  }
}

// ── reports ──────────────────────────────────────────────────

/** Where a source file belongs, by its path relative to the checkout. */
function area(path: string): string {
  const f = path.split("/").at(-1)!
  const rules: [RegExp, string][] = [
    [/(haus-schema\/src|go\/schema)\/(syntax|resolve|types|files.*|manifest|packages|locator|lib|doc)\.(rs|go)$/, "schema files"],
    [/typescript\/.*\/(schema-file|schema-compile|schema-imports)\.ts$/, "schema files"],
    [/(\/json\/|json[^/]*\.(rs|go|ts)$|jsonlines|jsonform)/, "JSON"],
    [/(haus-schema\/src\/(check|locate)\.rs|go\/schema\/(decode|onepass|codec|time|check|locate)\.go|internal\/floats|\/(de|codec|time|secret)\.rs$|\/(schema|codec|codegen|std-time|secret|check)\.ts$)/, "decoder"],
    [/\/stream\.(rs|go|ts)$/, "stream reader"],
    [/\/(formatter\.rs|format\.(go|ts)|syntax\.go)$/, "formatter"],
    [/\/(ser\.rs|lines\.go|canonical\.(rs|go|ts)|float\.(rs|go|ts)|hooks\.go|value\.rs|plain\.ts)$/, "writers, canonical form"],
    [/\/(parser|scan|keys|number|limits|reader|chars)\.(rs|go|ts)$|go\/(check|value)\.go$|\/value\.ts$/, "parser"],
    [/error/, "errors"],
  ]
  for (const [re, name] of rules) if (re.test(path)) return name
  return f === "lib.rs" || f === "doc.go" || f === "index.ts" ? "other" : "other"
}

const AREA_ORDER = ["parser", "stream reader", "formatter", "writers, canonical form", "JSON", "schema files", "decoder", "errors", "other"]

/** One source file's coverage, as every language reports it. */
interface FileCoverage {
  readonly path: string
  readonly lines: { covered: number; total: number }
  /** Rust: regions; Go: statements; TypeScript: blocks never run (no total). */
  readonly units: { covered: number; total: number } | { uncovered: number }
  /** Functions never called. */
  readonly deadFunctions: readonly string[]
  /** Uncovered places: "L12-14 in fn: source text". */
  readonly uncovered: readonly string[]
}

const pct = (c: number, t: number) => (t === 0 ? "-" : `${((100 * c) / t).toFixed(1)}%`)
const unitText = (u: FileCoverage["units"]) => ("uncovered" in u ? `${u.uncovered} places never run` : `${pct(u.covered, u.total)} (${u.total - u.covered} of ${u.total})`)

function writeReports(lang: Lang, unitName: string, files: readonly FileCoverage[], notes: readonly string[]): string {
  const dir = join(COVERAGE, lang)
  mkdirSync(dir, { recursive: true })
  const sorted = [...files].sort((a, b) => AREA_ORDER.indexOf(area(a.path)) - AREA_ORDER.indexOf(area(b.path)) || a.path.localeCompare(b.path))
  const table = [`| Area | File | Lines | ${unitName} uncovered | Functions never called |`, "|---|---|---|---|---|"]
  const totals = new Map<string, { lc: number; lt: number; uc: number; ut: number; un: number }>()
  for (const f of sorted) {
    const a = area(f.path)
    table.push(`| ${a} | ${f.path} | ${pct(f.lines.covered, f.lines.total)} (${f.lines.total - f.lines.covered} of ${f.lines.total}) | ${unitText(f.units)} | ${f.deadFunctions.length} |`)
    const t = totals.get(a) ?? { lc: 0, lt: 0, uc: 0, ut: 0, un: 0 }
    totals.set(a, t)
    t.lc += f.lines.covered
    t.lt += f.lines.total
    if ("uncovered" in f.units) t.un += f.units.uncovered
    else (t.uc += f.units.covered), (t.ut += f.units.total)
  }
  const byArea = [`| Area | Lines | ${unitName} |`, "|---|---|---|"]
  for (const a of AREA_ORDER) {
    const t = totals.get(a)
    if (t) byArea.push(`| ${a} | ${pct(t.lc, t.lt)} | ${t.ut ? pct(t.uc, t.ut) : `${t.un} never run`} |`)
  }
  const summary = [`## ${lang}`, "", ...notes.map((n) => `${n}`), "", ...byArea, "", ...table, ""].join("\n")
  writeFileSync(join(dir, "summary.md"), summary + "\n")
  const listing = sorted.flatMap((f) => [
    `## ${f.path} (${area(f.path)}): lines ${pct(f.lines.covered, f.lines.total)}, ${unitName} ${unitText(f.units)}`,
    ...f.deadFunctions.map((fn) => `  never called: ${fn}`),
    ...f.uncovered.map((u) => `  ${u}`),
    "",
  ])
  writeFileSync(join(dir, "uncovered.txt"), listing.join("\n"))
  return summary
}

const sourceLine = (path: string, line: number) => {
  try {
    return (readFileSync(abs(path), "utf8").split("\n")[line - 1] ?? "").trim().slice(0, 120)
  } catch {
    return ""
  }
}

/** The first line of a Go block that says something: a block starts after the `{` of its `if`, so its first statement is usually on the next line. */
const firstStatement = (path: string, l1: number, l2: number) => {
  for (let l = l1 === l2 ? l1 : l1 + 1; l <= l2; l++) {
    const text = sourceLine(path, l)
    if (text !== "" && text !== "}" && !text.startsWith("//")) return text
  }
  return sourceLine(path, l1)
}

// ── Rust ─────────────────────────────────────────────────────

function rustHost(): string {
  const p = spawnSync("rustc", ["-vV"], { encoding: "utf8" })
  return /host: (\S+)/.exec(p.stdout)![1]!
}

/** llvm-profdata and llvm-cov of rustc's LLVM: rustup's llvm-tools, else one of the same major version on PATH. */
function llvmTools(): { profdata: string; cov: string; cxxfilt?: string } | string {
  if (process.env.LLVM_PROFDATA && process.env.LLVM_COV) return { profdata: process.env.LLVM_PROFDATA, cov: process.env.LLVM_COV }
  const v = spawnSync("rustc", ["-vV"], { encoding: "utf8" }).stdout
  const major = /LLVM version: (\d+)/.exec(v)?.[1]
  const sysroot = spawnSync("rustc", ["--print", "sysroot"], { encoding: "utf8" }).stdout.trim()
  const candidates = [join(sysroot, "lib/rustlib", rustHost(), "bin"), ...(process.env.PATH ?? "").split(":")]
  for (const d of candidates) {
    const profdata = join(d, "llvm-profdata")
    if (!existsSync(profdata) || !existsSync(join(d, "llvm-cov"))) continue
    const version = spawnSync(profdata, ["--version"], { encoding: "utf8" }).stdout
    if (major && !new RegExp(`version ${major}\\.`).test(version)) continue
    return { profdata, cov: join(d, "llvm-cov"), ...(existsSync(join(d, "llvm-cxxfilt")) ? { cxxfilt: join(d, "llvm-cxxfilt") } : {}) }
  }
  return `no llvm-profdata and llvm-cov of LLVM ${major} (rustup component add llvm-tools, or set LLVM_PROFDATA and LLVM_COV)`
}

function buildRust(): string {
  const host = rustHost()
  const target = join(BUILD, "rust")
  const env = { ...process.env, RUSTFLAGS: "-C instrument-coverage", CARGO_TARGET_DIR: target }
  // --target: RUSTFLAGS then applies to the runners only, not to build scripts (haus-fmt-build runs in schema-rust's).
  const cargo = (cwd: string, args: string[]) => {
    const p = spawnSync("cargo", ["build", "-q", "--release", "--target", host, ...args], { cwd, env, stdio: "inherit" })
    if (p.status !== 0) throw new Error(`cargo build in ${cwd} failed`)
  }
  cargo(join(root, "rust"), ["-p", "haus-fmt", "--example", "fuzz_runner"])
  cargo(join(root, "fuzz/schema-rust"), ["--bins"])
  return join(target, host, "release")
}

/** The Rust sources measured: the binding's crates, not the runners or generated code. */
const RUST_SOURCES = /\/rust\/(haus|haus-schema)\/src\//

function reportRust(raw: string, bin: string, tools: { profdata: string; cov: string; cxxfilt?: string }): string {
  const profraw = readdirSync(raw).filter((f) => f.endsWith(".profraw")).map((f) => join(raw, f))
  if (profraw.length === 0) throw new Error("rust: no profiles written")
  const merged = join(raw, "merged.profdata")
  const m = spawnSync(tools.profdata, ["merge", "-sparse", "-o", merged, ...profraw], { encoding: "utf8" })
  if (m.status !== 0) throw new Error(`llvm-profdata: ${m.stderr}`)
  const objects = ["examples/fuzz_runner", "schema_runner", "check_runner", "json_runner", "schema_check_runner"].map((o) => join(bin, o)).filter(existsSync)
  const objectArgs = [objects[0]!, ...objects.slice(1).flatMap((o) => ["-object", o])]
  const ignore = "-ignore-filename-regex=(\\.cargo|/rustc/|/fuzz/|/examples/|/target/|/extensions/|haus-build)"
  const html = spawnSync(tools.cov, ["show", "-format=html", `-output-dir=${join(COVERAGE, "rust/html")}`, `-instr-profile=${merged}`, ignore,
    "-show-line-counts-or-regions", ...(tools.cxxfilt ? [`-Xdemangler=${tools.cxxfilt}`] : []), ...objectArgs], { encoding: "utf8", maxBuffer: 1 << 30 })
  if (html.status !== 0) console.log(`  rust: llvm-cov show failed: ${html.stderr.slice(0, 300)}`)
  const exported = join(raw, "export.json")
  const fd = openSync(exported, "w")
  const exp = spawnSync(tools.cov, ["export", "-format=text", `-instr-profile=${merged}`, ignore, ...objectArgs], { stdio: ["ignore", fd, "pipe"], encoding: "utf8" })
  closeSync(fd)
  if (exp.status !== 0) throw new Error(`llvm-cov export: ${exp.stderr.slice(0, 500)}`)
  const data = JSON.parse(readFileSync(exported, "utf8")).data[0] as {
    files: { filename: string; summary: { lines: { count: number; covered: number }; regions: { count: number; covered: number } } }[]
    functions: { name: string; count: number; regions: number[][]; filenames: string[] }[]
  }
  // Functions: generic ones are there once per instantiation; a region counts as run if any instance ran it.
  const fnNames = [...new Set(data.functions.map((f) => f.name))]
  const demangled = new Map<string, string>()
  if (tools.cxxfilt) {
    const out = spawnSync(tools.cxxfilt, [], { input: fnNames.join("\n"), encoding: "utf8", maxBuffer: 1 << 28 }).stdout.split("\n")
    fnNames.forEach((n, i) => demangled.set(n, (out[i] ?? n).replace(/::h[0-9a-f]{16}$/, "")))
  }
  const byFile = new Map<string, { fns: Map<string, { line: number; end: number; count: number; name: string }>; regions: Map<string, { l1: number; c1: number; l2: number; c2: number; count: number; fn: string }> }>()
  for (const f of data.functions) {
    const file = f.filenames[0]!
    if (!RUST_SOURCES.test(file)) continue
    const entry = byFile.get(file) ?? { fns: new Map(), regions: new Map() }
    byFile.set(file, entry)
    const name = demangled.get(f.name) ?? f.name
    const first = f.regions[0]!
    const key = `${first[0]}:${first[1]}`
    const fn = entry.fns.get(key) ?? { line: first[0]!, end: Math.max(...f.regions.map((r) => r[2]!)), count: 0, name }
    fn.count += f.count
    entry.fns.set(key, fn)
    for (const r of f.regions) {
      // [lineStart, colStart, lineEnd, colEnd, count, fileId, expandedFileId, kind]; kind 0: code.
      if (r[7] !== 0 || r[5] !== 0) continue
      const k = r.slice(0, 4).join(":")
      const reg = entry.regions.get(k) ?? { l1: r[0]!, c1: r[1]!, l2: r[2]!, c2: r[3]!, count: 0, fn: name }
      reg.count += r[4]!
      entry.regions.set(k, reg)
    }
  }
  const files: FileCoverage[] = data.files.filter((f) => RUST_SOURCES.test(f.filename)).map((f) => {
    const path = relative(root, f.filename)
    const entry = byFile.get(f.filename)
    const dead = [...(entry?.fns.values() ?? [])].filter((x) => x.count === 0).sort((a, b) => a.line - b.line)
    // Uncovered regions in functions that ran; regions on neighbouring lines of one function as one place.
    const inDead = (r: { l1: number }) => dead.some((d) => d.line <= r.l1 && r.l1 <= d.end)
    const zero = [...(entry?.regions.values() ?? [])].filter((r) => r.count === 0 && !inDead(r)).sort((a, b) => a.l1 - b.l1 || a.c1 - b.c1)
    const kept: { l1: number; c1: number; l2: number; fn: string }[] = []
    for (const r of zero) {
      const last = kept.at(-1)
      if (last && r.l1 <= last.l2 + 1 && r.fn === last.fn) last.l2 = Math.max(last.l2, r.l2)
      else kept.push({ l1: r.l1, c1: r.c1, l2: r.l2, fn: r.fn })
    }
    const fnShort = (n: string) => n.replace(/^<?([^ ]*?)(?: as [^>]*>)?::/, "$1::").split("::").slice(-2).join("::")
    return {
      path,
      lines: { covered: f.summary.lines.covered, total: f.summary.lines.count },
      units: { covered: f.summary.regions.covered, total: f.summary.regions.count },
      deadFunctions: dead.map((d) => `${d.name} (L${d.line})`),
      uncovered: kept.map((r) => `L${r.l1}:${r.c1}${r.l2 !== r.l1 ? `-${r.l2}` : ""} in ${fnShort(r.fn)}: ${sourceLine(path, r.l1)}`),
    }
  })
  return writeReports("rust", "Regions", files, [
    "Instrumented with `-C instrument-coverage` (stable rustc: no branch counters, so regions stand in for branches: every arm, every `?`, every short-circuit operand is a region).",
    `HTML: fuzz/.out/coverage/rust/html/index.html. Objects: ${objects.map((o) => relative(bin, o)).join(", ")}.`,
  ])
}

// ── Go ───────────────────────────────────────────────────────

const GO_MODULE = "github.com/betalyra/haus-fmt/go/"

function buildGo(): string {
  const out = join(BUILD, "go-runner")
  const cwd = join(root, "fuzz/go")
  // The packages of the module go/ that the runner uses, named one by one (a pattern, `…/go/...`, matches
  // nothing through the replace directive), and the runner itself: without its main package the
  // binary writes no coverage at all. The report leaves the runner out.
  const deps = spawnSync("go", ["list", "-deps", "."], { cwd, encoding: "utf8" })
  if (deps.status !== 0) throw new Error(`go list: ${deps.stderr}`)
  const pkgs = deps.stdout.split("\n").filter((p) => p === GO_MODULE.slice(0, -1) || p.startsWith(GO_MODULE) || p.endsWith("/fuzz/go"))
  const p = spawnSync("go", ["build", "-cover", `-coverpkg=${pkgs.join(",")}`, "-o", out, "."], { cwd, stdio: "inherit" })
  if (p.status !== 0) throw new Error("go build -cover failed")
  return out
}

function reportGo(raw: string): string {
  const dir = join(COVERAGE, "go")
  mkdirSync(dir, { recursive: true })
  const profile = join(raw, "profile.txt")
  const run = (args: string[], opts: SpawnSyncOptions = {}) => {
    const p = spawnSync("go", args, { cwd: join(root, "fuzz/go"), encoding: "utf8", maxBuffer: 1 << 28, ...opts })
    if (p.status !== 0) throw new Error(`go ${args.join(" ")}: ${p.stderr}`)
    return String(p.stdout)
  }
  run(["tool", "covdata", "textfmt", `-i=${raw}`, `-o=${profile}`])
  run(["tool", "cover", `-html=${profile}`, `-o=${join(dir, "index.html")}`])
  const funcs = run(["tool", "cover", `-func=${profile}`]).split("\n").flatMap((l) => {
    const m = /^(\S+?\.go):(\d+):\s+(\S+)\s+([\d.]+)%$/.exec(l)
    return m ? [{ file: m[1]!.replace(GO_MODULE, "go/"), line: Number(m[2]), name: m[3]!, pct: Number(m[4]) }] : []
  })
  // Blocks: file:l1.c1,l2.c2 statements count. Several runs may list a block more than once.
  const blocks = new Map<string, { file: string; l1: number; l2: number; stmts: number; count: number }>()
  for (const l of readFileSync(profile, "utf8").split("\n").slice(1)) {
    const m = /^(\S+?\.go):(\d+)\.\d+,(\d+)\.\d+ (\d+) (\d+)$/.exec(l)
    if (!m) continue
    const key = l.slice(0, l.lastIndexOf(" "))
    const b = blocks.get(key) ?? { file: m[1]!.replace(GO_MODULE, "go/"), l1: Number(m[2]), l2: Number(m[3]), stmts: Number(m[4]), count: 0 }
    b.count += Number(m[5])
    blocks.set(key, b)
  }
  const perFile = new Map<string, (typeof blocks extends Map<string, infer B> ? B : never)[]>()
  for (const b of blocks.values()) perFile.set(b.file, [...(perFile.get(b.file) ?? []), b])
  const files: FileCoverage[] = [...perFile].filter(([f]) => f.startsWith("go/") && !/\/(ext|examples|internal\/(vectors|errorcodes))\//.test(f)).map(([path, bs]) => {
    const fns = funcs.filter((f) => f.file === path).sort((a, b) => a.line - b.line)
    const fnAt = (line: number) => [...fns].reverse().find((f) => f.line <= line)
    const dead = fns.filter((f) => f.pct === 0)
    const covered = (b: { count: number }) => b.count > 0
    const lineSet = (pred: (b: { count: number }) => boolean) => new Set(bs.filter(pred).flatMap((b) => Array.from({ length: b.l2 - b.l1 + 1 }, (_, i) => b.l1 + i)))
    const coveredLines = lineSet(covered)
    const allLines = lineSet(() => true)
    const zero = bs.filter((b) => !covered(b) && !dead.includes(fnAt(b.l1)!)).sort((a, b) => a.l1 - b.l1)
    // Adjacent uncovered blocks as one place.
    const places: { l1: number; l2: number }[] = []
    for (const b of zero) {
      const last = places.at(-1)
      if (last && b.l1 <= last.l2 + 1 && fnAt(b.l1) === fnAt(last.l1)) last.l2 = Math.max(last.l2, b.l2)
      else places.push({ l1: b.l1, l2: b.l2 })
    }
    return {
      path,
      lines: { covered: coveredLines.size, total: allLines.size },
      units: { covered: bs.filter(covered).reduce((s, b) => s + b.stmts, 0), total: bs.reduce((s, b) => s + b.stmts, 0) },
      deadFunctions: dead.map((f) => `${f.name} (L${f.line})`),
      uncovered: places.map((p) => `L${p.l1}${p.l2 !== p.l1 ? `-${p.l2}` : ""} in ${fnAt(p.l1)?.name ?? "?"}: ${firstStatement(path, p.l1, p.l2)}`),
    }
  })
  return writeReports("go", "Statements", files, [
    "Built with `go build -cover`, `-coverpkg` the packages of go/ the runner uses (Go counts statements in blocks; it has no branch counters). ext/ (the profiles) and examples are left out.",
    "HTML: fuzz/.out/coverage/go/index.html. A line counts as covered when a block on it ran.",
  ])
}

// ── TypeScript ───────────────────────────────────────────────

const TS_DIST = join(root, "typescript/packages/haus/dist")

/** The segments of a source map's mappings: per generated line, [column, source, line, column] (all 0-based). */
function decodeMappings(mappings: string): number[][][] {
  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  const lines: number[][][] = []
  let src = 0, srcLine = 0, srcCol = 0
  for (const line of mappings.split(";")) {
    const segs: number[][] = []
    let col = 0
    for (const seg of line.split(",")) {
      if (seg === "") continue
      const vals: number[] = []
      let shift = 0, value = 0
      for (const ch of seg) {
        const d = B64.indexOf(ch)
        value += (d & 31) << shift
        if (d & 32) shift += 5
        else {
          vals.push(value & 1 ? -(value >>> 1) : value >>> 1)
          shift = 0
          value = 0
        }
      }
      col += vals[0]!
      if (vals.length >= 4) {
        src += vals[1]!
        srcLine += vals[2]!
        srcCol += vals[3]!
        segs.push([col, src, srcLine, srcCol])
      }
    }
    lines.push(segs)
  }
  return lines
}

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

function reportTypescript(raw: string): string {
  // Each process's block counts, painted onto the characters of each script (outer ranges first, inner ones over them), summed over processes.
  const counts = new Map<string, Float64Array>()
  /** Per script, its named functions by start offset, with how often they ran (summed over processes). */
  const functions = new Map<string, Map<number, { name: string; count: number }>>()
  for (const f of readdirSync(raw).filter((x) => x.endsWith(".json"))) {
    const { result } = JSON.parse(readFileSync(join(raw, f), "utf8")) as { result: { url: string; functions: { functionName: string; ranges: { startOffset: number; endOffset: number; count: number }[] }[] }[] }
    for (const script of result) {
      if (!script.url.startsWith(`file://${TS_DIST}/`) || !script.url.endsWith(".js")) continue
      const path = new URL(script.url).pathname
      const length = readFileSync(path, "utf8").length
      const painted = new Float64Array(length)
      const ranges = script.functions.flatMap((fn) => fn.ranges).sort((a, b) => a.startOffset - b.startOffset || b.endOffset - a.endOffset)
      for (const r of ranges) painted.fill(r.count, r.startOffset, Math.min(r.endOffset, length))
      const fns = functions.get(path) ?? new Map<number, { name: string; count: number }>()
      functions.set(path, fns)
      for (const fn of script.functions) {
        if (fn.functionName === "") continue
        const r = fn.ranges[0]!
        const entry = fns.get(r.startOffset) ?? { name: fn.functionName, count: 0 }
        entry.count += r.count
        fns.set(r.startOffset, entry)
      }
      const sum = counts.get(path)
      if (sum) sum.forEach((x, i) => (sum[i] = x + painted[i]!))
      else counts.set(path, painted)
    }
  }
  const files: FileCoverage[] = []
  const htmlDir = join(COVERAGE, "typescript/html")
  mkdirSync(htmlDir, { recursive: true })
  const index: string[] = []
  for (const [jsPath, painted] of [...counts].sort()) {
    const map = JSON.parse(readFileSync(`${jsPath}.map`, "utf8"))
    void new SourceMap(map) // validates the map
    const tsPath = join(dirname(jsPath), map.sourceRoot ?? "", map.sources[0])
    const path = relative(root, tsPath)
    const js = readFileSync(jsPath, "utf8")
    const starts = [0]
    for (let i = 0; i < js.length; i++) if (js[i] === "\n") starts.push(i + 1)
    // A TypeScript line is run if a mapped position on it ran, never run if it has mapped positions and none ran.
    const tsLines = new Map<number, boolean>()
    const segments = decodeMappings(map.mappings)
    segments.forEach((segs, gl) => {
      for (const [col, , sl] of segs) {
        const at = starts[gl]! + col!
        if (at >= js.length || /\s/.test(js[at]!)) continue
        const ran = painted[at]! > 0
        tsLines.set(sl! + 1, (tsLines.get(sl! + 1) ?? false) || ran)
      }
    })
    /** The TypeScript line of a JavaScript offset: the last mapped segment at or before it. */
    const tsLineAt = (offset: number) => {
      let gl = starts.findLastIndex((s) => s <= offset)
      for (; gl >= 0; gl--) {
        const col = gl === starts.findLastIndex((s) => s <= offset) ? offset - starts[gl]! : Infinity
        const seg = segments[gl]?.filter((s) => s[0]! <= col).at(-1)
        if (seg) return seg[2]! + 1
      }
      return 0
    }
    // Places never run: runs of characters with count 0 (whitespace between them ignored), mapped to TypeScript lines.
    const runs: [number, number][] = []
    for (let i = 0; i < js.length; i++) {
      if (painted[i]! !== 0 || /\s/.test(js[i]!)) continue
      const last = runs.at(-1)
      if (last && /^\s*$/.test(js.slice(last[1], i))) last[1] = i + 1
      else runs.push([i, i + 1])
    }
    const tsSource = readFileSync(tsPath, "utf8").split("\n")
    const places = new Map<number, number>()
    for (const [s, e] of runs) {
      const l1 = tsLineAt(s)
      const l2 = Math.max(l1, tsLineAt(e - 1))
      // Skip runs that are only comments or punctuation in the TypeScript.
      const text = tsSource.slice(l1 - 1, l2).join("\n")
      if (!/[A-Za-z0-9]/.test(text.replace(/\/\/.*|\/\*[\s\S]*?\*\//g, ""))) continue
      if ([...places].some(([a, b]) => a <= l1 && l2 <= b)) continue
      places.set(l1, Math.max(places.get(l1) ?? 0, l2))
    }
    const enclosing = (line: number) => {
      for (let l = line; l > 0; l--) {
        const m = /^\s*(?:export\s+)?(?:async\s+)?(?:function\*?\s+(\w+)|(?:const|let)\s+(\w+)\s*=\s*(?:\([^)]*\)|\w+)\s*=>|(?:private\s+|static\s+|readonly\s+)*(\w+)\s*\([^)]*\)\s*(?::[^{]*)?\{\s*$|class\s+(\w+))/.exec(tsSource[l - 1] ?? "")
        const name = m && (m[1] ?? m[2] ?? m[3] ?? m[4])
        if (name && !/^(if|for|while|switch|catch|return|function)$/.test(name)) return name
      }
      return "?"
    }
    const covered = [...tsLines.values()].filter(Boolean).length
    files.push({
      path,
      lines: { covered, total: tsLines.size },
      units: { uncovered: places.size },
      deadFunctions: [...(functions.get(jsPath) ?? [])].filter(([, f]) => f.count === 0).map(([at, f]) => ({ line: tsLineAt(at), name: f.name })).sort((a, b) => a.line - b.line).map((f) => `${f.name} (L${f.line})`),
      uncovered: [...places].sort((a, b) => a[0] - b[0]).map(([l1, l2]) => `L${l1}${l2 !== l1 ? `-${l2}` : ""} in ${enclosing(l1)}: ${(tsSource[l1 - 1] ?? "").trim().slice(0, 120)}`),
    })
    const name = path.replaceAll("/", "_") + ".html"
    const rows = tsSource.map((text, i) => {
      const s = tsLines.get(i + 1)
      return `<tr class="${s === undefined ? "" : s ? "run" : "never"}"><td>${i + 1}</td><td><pre>${escapeHtml(text)}</pre></td></tr>`
    })
    writeFileSync(join(htmlDir, name), `<!doctype html><meta charset="utf-8"><title>${escapeHtml(path)}</title><style>body{font:13px ui-monospace,monospace}td{padding:0 6px;vertical-align:top}pre{margin:0}tr.never{background:#fdd}td:first-child{color:#888;text-align:right}</style><h1>${escapeHtml(path)}</h1><p>lines ${pct(covered, tsLines.size)}; red: never run</p><table>${rows.join("")}</table>`)
    index.push(`<li><a href="${name}">${escapeHtml(path)}</a> ${pct(covered, tsLines.size)}</li>`)
  }
  writeFileSync(join(htmlDir, "index.html"), `<!doctype html><meta charset="utf-8"><title>TypeScript coverage</title><ul>${index.join("")}</ul>`)
  return writeReports("typescript", "Blocks", files, [
    "Node's block coverage (NODE_V8_COVERAGE) of typescript/packages/haus/dist, mapped to src/ through the source maps. V8 folds a block that ran as often as its parent into the parent, so only blocks never run are counted (no percentage); a line counts as run when a mapped position on it ran.",
    "HTML: fuzz/.out/coverage/typescript/html/index.html.",
  ])
}

// ── run ──────────────────────────────────────────────────────

async function main() {
  const { values: args } = parseArgs({
    options: {
      count: { type: "string", default: "3000" },
      seed: { type: "string", default: "1" },
      langs: { type: "string", default: ALL_LANGS.join(",") },
      modes: { type: "string", default: ALL_MODES.join(",") },
      "no-generate": { type: "boolean", default: false },
      "no-build": { type: "boolean", default: false },
      "replay-ts": { type: "boolean", default: false },
      // Only the reports again, from the raw profiles of an earlier run (a directory name under coverage/raw).
      report: { type: "string" },
    },
  })
  const modes = args.modes!.split(",") as FuzzMode[]
  for (const m of modes) if (!ALL_MODES.includes(m)) throw new Error(`unknown mode ${m} (${ALL_MODES.join(", ")})`)
  if (args["replay-ts"]) return replayTypescript(modes)
  const langs = args.langs!.split(",") as Lang[]
  for (const l of langs) if (!ALL_LANGS.includes(l)) throw new Error(`unknown language ${l} (${ALL_LANGS.join(", ")})`)
  const count = Number(args.count)
  const seed = Number(args.seed)

  const reportOnly = args.report !== undefined
  if (!args["no-generate"] && !reportOnly) {
    for (const [i, mode] of modes.entries()) {
      const started = Date.now()
      generate(mode, count, seed + i)
      console.log(`corpus ${mode}: ${count} cases (seed ${seed + i}), ${((Date.now() - started) / 1000).toFixed(1)} s`)
    }
  }
  const manifests = reportOnly ? [] : modes.map(readManifest)
  const run = args.report ?? new Date().toISOString().replace(/[:.]/g, "-")
  const summaries: string[] = []
  const skipped: string[] = []

  for (const lang of langs) {
    const raw = join(COVERAGE, "raw", run, lang)
    mkdirSync(raw, { recursive: true })
    console.log(`${lang}:`)
    try {
      if (lang === "rust") {
        const tools = llvmTools()
        if (typeof tools === "string") throw new Error(tools)
        const bin = args["no-build"] ? join(BUILD, "rust", rustHost(), "release") : buildRust()
        if (!reportOnly) runJobs("rust", manifests.flatMap((m) => rustJobs(m, bin)), { LLVM_PROFILE_FILE: join(raw, "%p-%m.profraw") })
        summaries.push(reportRust(raw, bin, tools))
      } else if (lang === "go") {
        const runner = args["no-build"] ? join(BUILD, "go-runner") : buildGo()
        if (!reportOnly) runJobs("go", manifests.flatMap((m) => goJobs(m, runner)), { GOCOVERDIR: raw })
        summaries.push(reportGo(raw))
      } else {
        if (!existsSync(join(TS_DIST, "index.js"))) throw new Error("no typescript/packages/haus/dist: run sh fuzz/build.sh (or pnpm build in typescript/)")
        if (!reportOnly) {
          const p = spawnSync(process.execPath, [new URL(import.meta.url).pathname, "--replay-ts", "--modes", modes.join(",")], { env: { ...process.env, NODE_V8_COVERAGE: raw }, stdio: "inherit" })
          if (p.status !== 0) throw new Error("the TypeScript replay failed")
        }
        summaries.push(reportTypescript(raw))
      }
      console.log(`  report: ${relative(root, join(COVERAGE, lang))}/summary.md, uncovered.txt`)
    } catch (e) {
      console.log(`  ${lang} skipped: ${(e as Error).message}`)
      skipped.push(`- ${lang}: skipped (${(e as Error).message})`)
    }
  }
  const header = [`# Fuzzer coverage`, "", `Modes ${modes.join(", ")}; corpus in fuzz/.out/corpus; raw profiles in fuzz/.out/coverage/raw/${run}.`, "", ...skipped, ""]
  writeFileSync(join(COVERAGE, "summary.md"), [...header, ...summaries].join("\n"))
  console.log(`summary: ${relative(root, join(COVERAGE, "summary.md"))}`)
}

await main()
