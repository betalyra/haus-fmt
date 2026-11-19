/**
 * Differential testing of the JSON mappings (spec §16): generated inputs go
 * through the Lean reference converters and each binding's, in five
 * directions (json-runners.ts):
 *
 * - `write`: a haus value decoded with a type of the schema suite, written
 *   as schema-based JSON (§16.3); the JSON must agree as data (member order
 *   doesn't matter, numbers compare by their text);
 * - `read`: JSON text read with a type as schema-based JSON, and encoded;
 *   the canonical forms must agree;
 * - `haus-json-write` and `haus-json-read`: self-describing JSON (§16.2);
 * - `import`: JSON read without a schema (§16.1).
 *
 * Accepting or rejecting must agree too, and so must the error codes (spec
 * §17) of errors at the same place. A disagreement is shrunk and saved.
 * See ../README.md.
 *
 *   node fuzz/src/json.ts [--count N] [--seed S] [--modes write,read,…] [--runners lean,typescript,…]
 *   node fuzz/src/main.ts --json …   (the same)
 */
import { spawnSync } from "node:child_process"
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"
import { Rng, value as hausValue } from "./generate.ts"
import {
  anyJ, badEnvelopeJ, badHausValueJ, envelope, hausJsonJ, hausValueJ, mutateJ, nested, normJ, NOT_JSON, Obj, parseJ, PlainGen, single, smallerJ, textOf, wrongJ, writeJ, type J,
} from "./json-gen.ts"
import {
  caseBytes, caseLine, effectRunner, go, lean, MODES, python, roc, rust, typed, typescriptRunner, writes, type JsonCase, type JsonRunner, type Mode,
} from "./json-runners.ts"
import { shrinkCase } from "./schema.ts"
import { Generator, type Env, type Type } from "./schema-gen.ts"
import { schemaTexts, type Outcome } from "./schema-runners.ts"

const root = new URL("../..", import.meta.url).pathname
const SCHEMA_DIRS = [join(root, "test-suite/schema"), join(root, "fuzz/schema"), join(root, "test-suite/json"), join(root, "fuzz/json")]
const ALL_RUNNERS = ["lean", "typescript", "effect", "rust", "roc", "python", "go"]

export async function run(argv: readonly string[]): Promise<number> {
  const { values: args } = parseArgs({
    args: [...argv],
    options: {
      count: { type: "string", default: "3000" }, // per mode
      seed: { type: "string", default: String(Date.now() % 1_000_000) },
      out: { type: "string", default: "fuzz/.out/json" },
      runners: { type: "string", default: ALL_RUNNERS.join(",") },
      modes: { type: "string", default: MODES.join(",") },
      batch: { type: "string", default: "4000" },
      json: { type: "boolean", default: false }, // from main.ts
    },
  })
  const count = Number(args.count)
  const seed = Number(args.seed)
  const out = args.out!
  const batch = Number(args.batch)
  const modes = args.modes!.split(",") as Mode[]
  for (const m of modes) if (!MODES.includes(m)) throw new Error(`unknown mode ${m} (${MODES.join(", ")})`)
  mkdirSync(out, { recursive: true })

  // ── the types ──────────────────────────────────────────────
  const suites = SCHEMA_DIRS.flatMap((dir) => {
    const p = spawnSync(process.execPath, [join(root, "spec/lean/scripts/schema-types.ts"), dir], { encoding: "utf8", maxBuffer: 1 << 28 })
    if (p.status !== 0) throw new Error(`schema-types.ts ${dir}: ${p.stderr}`)
    return JSON.parse(p.stdout).suites as { name: string; defs?: [string, Type][]; error?: string }[]
  })
  const typesFile = join(out, "types.json")
  writeFileSync(typesFile, JSON.stringify({ suites }))
  const envs = new Map<string, Env>()
  const entries: { suite: string; type: string }[] = []
  for (const s of suites) {
    if (s.error !== undefined) throw new Error(`${s.name}: the schema file is rejected: ${s.error}`)
    envs.set(s.name, new Map(s.defs))
    for (const [name] of s.defs!) if (/^[A-Z][A-Za-z0-9_]*$/.test(name)) entries.push({ suite: s.name, type: name })
  }
  const hausGen = new Map([...envs].map(([s, env]) => [s, new Generator(env)]))
  const plainGen = new Map([...envs].map(([s, env]) => [s, new PlainGen(env)]))

  // The conformance suite's valid files that hold one value: seeds for self-describing JSON.
  const valid = join(root, "test-suite/valid")
  const seeds = readdirSync(valid).filter((f) => f.endsWith(".haus")).map((f) => readFileSync(join(valid, f), "utf8")).filter((t) => single(t) !== undefined)

  // ── the runners ────────────────────────────────────────────
  const wanted = args.runners!.split(",")
  if (wanted[0] !== "lean") throw new Error("--runners must start with lean, the reference")
  const texts = schemaTexts(SCHEMA_DIRS)
  const runners: JsonRunner[] = []
  for (const name of wanted) {
    if (name === "lean") runners.push(lean(typesFile))
    else if (name === "typescript") runners.push(typescriptRunner(texts))
    else if (name === "effect") runners.push(await effectRunner(texts))
    else if (name === "rust") runners.push(rust())
    else if (name === "roc") runners.push(roc())
    else if (name === "python") runners.push(python())
    else if (name === "go") runners.push(go())
    else throw new Error(`unknown runner ${name} (${ALL_RUNNERS.join(", ")})`)
  }

  /** Every runner's outcome for each case: written JSON is compared as data. */
  const runAll = (mode: Mode, cases: readonly JsonCase[]): Outcome[][] => {
    const file = join(out, "cases.txt")
    const byRunner = runners.map((r) => r.run(mode, file, cases))
    return cases.map((_, i) => byRunner.map((rs) => rs[i]!))
  }

  // ── comparing ──────────────────────────────────────────────
  /** What must agree with lean: `ok` and the result (JSON as data), `err` (codes: see sameCode), never a crash. */
  const result = (mode: Mode, o: Outcome): string => {
    if (o.kind !== "ok") return o.kind
    if (!writes(mode)) return "ok " + o.text
    const j = parseJ(o.text)
    return j === undefined ? `ok, not JSON: ${o.text}` : "ok " + normJ(j)
  }
  /** Two errors at the same place (`$` for one in the text) with codes (spec §17): which error comes first is not fixed, but a place has one mistake. */
  const codesAt = (ref: Outcome, o: Outcome) => ref.kind === "err" && o.kind === "err" && ref.code !== undefined && o.code !== undefined && ref.place === o.place
  const sameCode = (ref: Outcome, o: Outcome) => !codesAt(ref, o) || (ref.kind === "err" && o.kind === "err" && ref.code === o.code)
  const pattern = (mode: Mode, rs: readonly Outcome[]): string => {
    const ref = result(mode, rs[0]!)
    return rs.map((o, i) => (i === 0 ? rs[0]!.kind : ref !== "crash" && result(mode, o) === ref && sameCode(rs[0]!, o) ? "=" : o.kind)).join(" ")
  }
  const disagrees = (p: string) => p.startsWith("crash") || p.split(" ").slice(1).some((x) => x !== "=")
  /** The pattern of each case; an empty case without a type can't be given to the runners (an empty line), so it is skipped. */
  const patterns = (mode: Mode, cs: readonly JsonCase[]): string[] => {
    const keep = cs.filter((c) => typed(mode) || caseBytes(c).length > 0)
    const ps = runAll(mode, keep).map((rs) => pattern(mode, rs))
    return cs.map((c) => (typed(mode) || caseBytes(c).length > 0 ? ps.shift()! : "empty"))
  }

  /** The smallest case with the same pattern. */
  const shrink = (c: JsonCase, p: string): JsonCase => {
    if (writes(c.mode)) {
      const small = shrinkCase(c, p, (cs) => patterns(c.mode, cs.map((x) => ({ ...c, text: x.text }))))
      return { ...c, text: small.text }
    }
    return shrinkJson(c, p, (cs) => patterns(c.mode, cs))
  }

  // ── generating ─────────────────────────────────────────────
  const rng = new Rng(seed)
  const r = rng
  const pickEntry = () => r.pick(entries)
  const missRate = () => (r.chance(0.55) ? 0 : r.pick([0.03, 0.08, 0.2]))
  const deepness = () => (r.chance(0.04) ? r.pick([8, 30, 60, 100, 126, 200, 254, 300]) : 0)
  const hausFor = (e: { suite: string; type: string }, miss: number) =>
    hausGen.get(e.suite)!.value(r, { ref: e.type }, { miss, maxDepth: r.pick([1, 2, 3, 4, 6]), deep: deepness() })

  /** A haus value of any kind: random, of a random type, a seed, or nested at the depth limit. */
  const anyHaus = (): string => {
    const x = r.next()
    if (x < 0.5) return hausValue(r, 0)
    if (x < 0.75) return hausFor(pickEntry(), 0)
    if (x < 0.9 && seeds.length) return r.pick(seeds)
    const n = r.pick([100, 254, 255, 256, 257])
    const [open, close] = r.pick([["[", "]"], ["{ a: ", " }"], ["Some(", ")"], ["T { a: ", " }"], ["T(1, ", ")"]] as const)
    return open.repeat(n) + r.pick(["1", '"x"', 'x"00"', "[]", "N"]) + close.repeat(n)
  }

  /** Self-describing JSON nested near the JSON limit (4·256 + 2 with the envelope): `T { a: … }` takes four levels. */
  const deepHausJson = (): J => {
    const n = r.pick([254, 255, 256, 257])
    let j: J = { 0: () => new Obj([["_num", "1"]]), 1: () => "x", 2: () => [] as J[] }[r.int(3)]!()
    const shape = r.int(4)
    for (let i = 0; i < n; i++) {
      j = shape === 0 ? new Obj([["_tag", "T"], ["_args", [new Obj([["_rec", new Obj([["a", j]])]])]]])
        : shape === 1 ? new Obj([["_rec", new Obj([["a", j]])]])
        : shape === 2 ? [j]
        : new Obj([["_tag", "S"], ["_args", [j]]])
    }
    return envelope(j)
  }

  /** Generate one batch of cases for a mode. */
  const generate = (mode: Mode, n: number): JsonCase[] => {
    // An empty text without a type would be an empty line: a space instead.
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
        // Some from lean's own plain JSON of generated values, the rest generated from the type.
        const fromLean = Math.round(n * 0.35)
        const sources = Array.from({ length: fromLean }, () => {
          const e = pickEntry()
          return { mode: "write" as Mode, suite: e.suite, type: e.type, text: hausFor(e, r.chance(0.8) ? 0 : 0.03) }
        })
        const written = runners[0]!.run("write", join(out, "seed-cases.txt"), sources)
        const cases: JsonCase[] = []
        for (let i = 0; i < n; i++) {
          const e = i < fromLean ? sources[i]! : pickEntry()
          const w = i < fromLean ? written[i]! : undefined
          let j: J | undefined = w?.kind === "ok" ? parseJ(w.text) : undefined
          if (j !== undefined && r.chance(0.4)) j = mutateJ(r, j, wrongJ)
          if (j === undefined) j = plainGen.get(e.suite)!.value(r, { ref: e.type }, { miss: missRate(), maxDepth: r.pick([1, 2, 3, 4, 6]), deep: deepness() })
          if (r.chance(0.01)) {
            // Not UTF-8.
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

  // ── run ────────────────────────────────────────────────────
  console.log(`seed ${seed}: ${count} cases per mode (${modes.join(", ")}; ${entries.length} types in ${envs.size} schema files) through ${runners.map((x) => x.name).join(", ")}`)
  const found = new Map<string, { case: JsonCase; pattern: string; outcomes: Outcome[]; hits: number }>()
  const coverage: string[] = []
  for (const mode of modes) {
    const perType = new Map<string, { total: number; ok: number }>()
    let accepted = 0
    /** Errors whose codes were compared: lean's and another runner's, at the same place. */
    let codesCompared = 0
    let before = found.size
    for (let done = 0; done < count; done += batch) {
      const cases = generate(mode, Math.min(batch, count - done))
      const results = runAll(mode, cases)
      results.forEach((rs, i) => {
        const c = cases[i]!
        const key = `${c.suite}.${c.type}`
        const stat = perType.get(key) ?? { total: 0, ok: 0 }
        perType.set(key, stat)
        stat.total++
        if (rs[0]!.kind === "ok") (stat.ok++, accepted++)
        if (rs.slice(1).some((o) => codesAt(rs[0]!, o))) codesCompared++
        const p = pattern(mode, rs)
        if (!disagrees(p)) return
        const groupKey = `${mode} ${typedKey(c)} ${p}`
        const seen = found.get(groupKey)
        if (seen) return void seen.hits++
        const small = shrink(c, p)
        found.set(groupKey, { case: small, pattern: p, outcomes: runAll(mode, [small])[0]!, hits: 1 })
      })
      process.stdout.write(`  ${mode}: ${Math.min(done + batch, count)} cases, ${found.size - before} disagreements\n`)
    }
    const line = `${mode}: ${accepted} accepted, ${count - accepted} rejected (by lean); ${codesCompared} error codes compared (at the same place); ${found.size - before} disagreements`
    console.log(line)
    coverage.push(line)
    if (mode === "write" || mode === "read") {
      for (const [k, s] of [...perType].sort()) coverage.push(`  ${k.padEnd(28)} ${String(s.ok).padStart(6)} accepted of ${s.total}`)
    }
    before = found.size
  }
  writeFileSync(join(out, "coverage.txt"), coverage.join("\n") + "\n")

  if (found.size === 0) console.log("no disagreements")
  const report: string[] = []
  for (const [key, f] of found) {
    const lines = [
      `DISAGREEMENT ${key} (${f.hits} cases; shrunk)`,
      `  case: ${f.case.mode} ${typedKey(f.case)} ${f.case.bytes ? `bytes ${Buffer.from(f.case.bytes).toString("hex")}` : JSON.stringify(f.case.text)}`,
      `  line: ${caseLine(f.case)}`,
      ...f.outcomes.map((o, i) => `  ${runners[i]!.name.padEnd(10)} ${o.kind === "ok" ? `ok ${o.text.slice(0, 600)}` : `${o.kind} ${o.kind === "err" && o.code !== undefined ? `[${o.code} at ${o.place}] ` : ""}${o.reason.slice(0, 300)}`}`),
    ]
    report.push(lines.join("\n"))
    console.log("\n" + lines.join("\n"))
  }
  writeFileSync(join(out, "failures.txt"), report.join("\n\n") + "\n")
  return found.size ? 1 : 0
}

const typedKey = (c: JsonCase) => (c.suite === "-" ? "-" : `${c.suite}.${c.type}`)

// ── shrinking JSON ───────────────────────────────────────────

/**
 * A smaller JSON case with the same pattern: first the compact form of the
 * JSON, then smaller JSON (members, elements removed, a node replaced by a
 * child, strings cut). If the compact form doesn't disagree (the spelling
 * matters), slices of the text are removed instead.
 */
function shrinkJson(c: JsonCase, p: string, patterns: (cs: readonly JsonCase[]) => string[]): JsonCase {
  const withText = (text: string): JsonCase => ({ mode: c.mode, suite: c.suite, type: c.type, text })
  if (c.bytes) {
    let best = c.bytes
    let size = Math.max(1, best.length >> 1)
    for (let round = 0; round < 400 && best.length > 1; round++) {
      const candidates: JsonCase[] = []
      for (let at = 0; at < best.length; at += size) candidates.push({ ...c, bytes: Uint8Array.from([...best.subarray(0, at), ...best.subarray(at + size)]) })
      const i = patterns(candidates).findIndex((q) => q === p)
      if (i >= 0) best = candidates[i]!.bytes!
      else if (size > 1) size >>= 1
      else break
    }
    return { ...c, bytes: best }
  }
  let j = parseJ(c.text)
  if (j !== undefined && patterns([withText(writeJ(j))])[0] === p) {
    for (let round = 0; round < 300; round++) {
      const seen = new Set<string>()
      const candidates = [...smallerJ(j)].map((x) => writeJ(x)).filter((t) => !seen.has(t) && seen.add(t)).sort((x, y) => x.length - y.length).slice(0, 400)
      if (candidates.length === 0) break
      const i = patterns(candidates.map(withText)).findIndex((q) => q === p)
      if (i < 0) break
      j = parseJ(candidates[i]!)!
    }
    return withText(writeJ(j))
  }
  // Slices of the text, at most 400 per round (the next 400 if none of them disagrees).
  let best = [...c.text]
  let size = Math.max(1, best.length >> 1)
  let start = 0
  for (let round = 0; round < 600 && best.length > 1; round++) {
    const candidates: JsonCase[] = []
    const chunks = Math.ceil(best.length / size)
    for (let k = 0; k < 400 && start + k < chunks; k++) {
      const at = (start + k) * size
      candidates.push(withText([...best.slice(0, at), ...best.slice(at + size)].join("")))
    }
    const i = patterns(candidates).findIndex((q) => q === p)
    if (i >= 0) best = [...candidates[i]!.text]
    else if (start + 400 < chunks) start += 400
    else if (size > 1) (size >>= 1), (start = 0)
    else break
  }
  return withText(best.join(""))
}

if (import.meta.url === `file://${process.argv[1]}`) process.exitCode = await run(process.argv.slice(2))
