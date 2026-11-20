/**
 * The schema decoders under test (schema.ts). Each gets a file of lines
 * `SUITE TYPE HEX` (a value's haus text as hex-encoded UTF-8) and gives one
 * outcome per line: decode the value with the named type of the suite's
 * schema file, encode the result, and write its canonical form (spec §12).
 * TypeScript and Effect run in this process; the others are the programs
 * built by build.sh.
 */
import { spawnSync } from "node:child_process"
import { readdirSync, readFileSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import { canonical, compileSchemaFile, HausSyntaxError, parseAll } from "../../typescript/packages/haus/dist/index.js"
import * as h from "../../typescript/packages/haus/dist/schema.js"
import { checkCase } from "./codec.ts"

/**
 * `ok` with the canonical form of the encoded result, `err` (any reason), or
 * a crash. A runner that reports error codes (spec §17) gives an `err` its
 * code and its place (`$.items[2].price`, arguments as `[i]`).
 */
export type Outcome =
  | { readonly kind: "ok"; readonly text: string }
  | { readonly kind: "err"; readonly reason: string; readonly code?: string; readonly place?: string }
  | { readonly kind: "crash"; readonly reason: string }

export interface SchemaCase {
  readonly suite: string
  readonly type: string
  readonly text: string
}

export interface SchemaRunner {
  readonly name: string
  run(file: string, cases: readonly SchemaCase[]): Outcome[]
}

const root = new URL("../..", import.meta.url).pathname

export const caseLine = (c: SchemaCase) => `${c.suite} ${c.type} ${Buffer.from(c.text, "utf8").toString("hex")}`

/**
 * One line of a runner's output. With `codes`, an error is
 * `err PLACE CODE REASON` (the code of spec §17, `-` for none); otherwise
 * `err REASON`.
 */
export function parseOutcome(line: string, codes: boolean): Outcome {
  if (line.startsWith("ok ")) return { kind: "ok", text: line.slice(3) }
  if (codes) {
    const m = /^err (\S+) (\S+) ?(.*)$/s.exec(line)
    if (m) return { kind: "err", reason: `${m[1]} ${m[3]}`, place: m[1]!, ...(m[2] === "-" ? {} : { code: m[2]! }) }
  }
  if (line.startsWith("err")) return { kind: "err", reason: line.slice(4) }
  return { kind: "crash", reason: `unexpected output: ${line.slice(0, 200)}` }
}

/**
 * A runner that is a separate program: `program [...args] FILE`. When it
 * crashes or hangs, the cases are split in halves until the ones that crash
 * it are found. With `codes`, it reports error codes (see parseOutcome).
 */
function external(name: string, program: string, args: readonly string[] = [], codes = false): SchemaRunner {
  const runRange = (file: string, cases: readonly SchemaCase[]): Outcome[] => {
    const part = `${file}.${name}`
    writeLines(part, cases)
    const p = spawnSync(program, [...args, part], { maxBuffer: 1 << 30, encoding: "utf8", timeout: 600_000 })
    const lines = (p.stdout ?? "").split("\n").filter((l) => l !== "")
    if (p.status === 0 && lines.length === cases.length) return lines.map((l) => parseOutcome(l, codes))
    if (cases.length === 1) {
      const why = p.error ? String(p.error) : p.signal ? `signal ${p.signal}` : `exit ${p.status}, ${lines.length} lines`
      return [{ kind: "crash", reason: `CRASH (${why}): ${(p.stderr ?? "").trim().split("\n").slice(0, 3).join(" ").slice(0, 300)}` }]
    }
    const mid = cases.length >> 1
    return [...runRange(file, cases.slice(0, mid)), ...runRange(file, cases.slice(mid))]
  }
  return { name, run: runRange }
}

const writeLines = (file: string, cases: readonly SchemaCase[]) => writeFileSync(file, cases.map((c) => caseLine(c) + "\n").join(""))

/** The single value of a case's text, or why it isn't one. */
function single(text: string): { value: any } | { error: string } {
  try {
    const vs = parseAll(text)
    return vs.length === 1 ? { value: vs[0] } : { error: "not a single value" }
  } catch (e) {
    return { error: `not a single value: ${(e as Error).message}` }
  }
}

/** Every schema file of the fuzzer: the suite's and fuzz/schema's, by suite name. */
export function schemaTexts(dirs: readonly string[]): Map<string, string> {
  const out = new Map<string, string>()
  for (const dir of dirs) {
    for (const f of readdirSync(dir)) {
      if (f.endsWith(".schema.haus")) out.set(f.replace(".schema.haus", ""), readFileSync(join(dir, f), "utf8"))
    }
  }
  return out
}

/** A runner in this process: decode and encode for one case, or throw. */
function inProcess(name: string, roundtrip: (suite: string, type: string, value: any) => Outcome): SchemaRunner {
  return {
    name,
    run: (_file, cases) =>
      cases.map((c) => {
        const v = single(c.text)
        if ("error" in v) return { kind: "err", reason: v.error }
        try {
          return roundtrip(c.suite, c.type, v.value)
        } catch (e) {
          return { kind: "crash", reason: `CRASH: ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`.slice(0, 300) }
        }
      }),
  }
}

/** @haus-fmt/haus: `compileSchemaFile`, `h.decode`, `h.encode`. */
export function typescriptRunner(texts: ReadonlyMap<string, string>): SchemaRunner {
  const compiled = new Map([...texts].map(([s, t]) => [s, compileSchemaFile(t).schemas as Record<string, h.Schema<unknown>>]))
  return inProcess("typescript", (suite, type, value) => {
    const schema = compiled.get(suite)?.[type]
    if (!schema) return { kind: "crash", reason: `CRASH: no type ${suite}.${type}` }
    let decoded: unknown
    try {
      decoded = h.decode(schema, value)
    } catch (e) {
      if (e instanceof h.HausDecodeError) return { kind: "err", reason: e.message, code: e.code, place: h.formatPath(e.path) }
      throw e
    }
    try {
      return { kind: "ok", text: canonical(h.encode(schema, decoded)) }
    } catch (e) {
      // Encoding what was decoded must work (spec §15): an encode error is a finding.
      if (e instanceof h.HausEncodeError) return { kind: "crash", reason: `CRASH: encoding failed: ${e.message}` }
      throw e
    }
  })
}

/**
 * @haus-fmt/haus's compiled codecs: `h.parse` of the case's text and
 * `h.stringify` (minimised) of the result, on the generic path, checked
 * against the closures (codec.ts), generated code made at runtime, and code
 * generated ahead of time by @haus-fmt/import (each suite file built into a
 * module with `optimize` for all its types and loaded, codegen.ts `prebuilt`,
 * which marks them as `h.optimize` does), in this process (codec.ts here), on
 * the case and on texts and values near it: a difference is a crash. The
 * generic path's outcome is compared with Lean's, as for the other runners.
 */
export async function codecRunner(texts: ReadonlyMap<string, string>, dirs: readonly string[], out: string): Promise<SchemaRunner> {
  const compiled = new Map([...texts].map(([s, t]) => [s, compileSchemaFile(t).schemas as Record<string, h.Schema<unknown>>]))
  // Each schema file as @haus-fmt/import builds it for the plain target, codecs generated ahead for every type.
  const dist = join(root, "typescript/packages/import/dist")
  const { backend, moduleFor, optimizeOf } = await import(pathToFileURL(join(dist, "generate.js")).href)
  const built = new Map<string, Record<string, h.Schema<unknown>>>()
  for (const dir of dirs) {
    for (const f of readdirSync(dir).filter((f) => f.endsWith(".schema.haus"))) {
      const path = join(dir, f)
      const text = readFileSync(path, "utf8")
      const plain = await backend("plain", {}, optimizeOf({ optimize: { [f]: Object.keys(compileSchemaFile(text).schemas) } }, dir))
      const { code } = moduleFor(text, path, plain, (p: string) => pathToFileURL(join(dist, `${p}.js`)).href)
      if (!code.includes("prebuilt(schema, ")) throw new Error(`${f}: @haus-fmt/import generated no codecs`)
      const file = join(out, `built-${f}.mjs`)
      writeFileSync(file, code)
      // Every type is listed, so the module marks each as h.optimize does.
      built.set(f.replace(".schema.haus", ""), await import(pathToFileURL(file).href))
    }
  }
  return {
    name: "typescript-codec",
    run: (_file, cases) =>
      cases.map((c): Outcome => {
        const schema = compiled.get(c.suite)?.[c.type]
        const ahead = built.get(c.suite)?.[c.type]
        if (!schema || !ahead) return { kind: "crash", reason: `CRASH: no type ${c.suite}.${c.type}` }
        try {
          const r = checkCase({ schema, built: ahead }, c.text)
          if (r.problem !== undefined) return { kind: "crash", reason: `CRASH: the compiled and generic paths differ: ${r.problem}`.slice(0, 400) }
          if (!r.decoded.ok) {
            const e = r.decoded.error
            // Not one value (as the other in-process runners say it): no code.
            if (e instanceof HausSyntaxError || (e instanceof h.HausDecodeError && e.code === "not-one-value")) return { kind: "err", reason: e.message }
            if (e instanceof h.HausDecodeError) return { kind: "err", reason: e.message, code: e.code, place: h.formatPath(e.path) }
            throw e
          }
          const encoded = r.encoded!
          // Encoding what was decoded must work (spec §15): an encode error is a finding.
          if (!encoded.ok) return { kind: "crash", reason: `CRASH: encoding failed: ${String(encoded.error)}` }
          return { kind: "ok", text: canonical(parseAll(encoded.value as string)[0]!) }
        } catch (e) {
          return { kind: "crash", reason: `CRASH: ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`.slice(0, 300) }
        }
      }),
  }
}

/** @haus-fmt/effect: `Haus.compileSchemaFile`, `decodeValue`, `encodeValue`. */
export async function effectRunner(texts: ReadonlyMap<string, string>): Promise<SchemaRunner> {
  const dir = join(root, "typescript/packages/effect")
  const Haus = await import(pathToFileURL(join(dir, "dist/index.js")).href)
  const effectEntry = createRequire(join(dir, "package.json")).resolve("effect")
  const { Effect, Exit, Cause, Option } = await import(pathToFileURL(effectEntry).href)
  const compiled = new Map([...texts].map(([s, t]) => [s, Haus.compileSchemaFile(t).schemas]))
  return inProcess("effect", (suite, type, value) => {
    const schema = compiled.get(suite)?.[type]
    if (!schema) return { kind: "crash", reason: `CRASH: no type ${suite}.${type}` }
    const decoded = Effect.runSyncExit(Haus.decodeValue(schema)(value))
    if (Exit.isFailure(decoded)) {
      if (Cause.hasDies(decoded.cause)) return { kind: "crash", reason: `CRASH: ${String(decoded.cause).slice(0, 300)}` }
      // A HausSchemaError, with its code (spec §17) and its place in the haus value.
      const e = Option.getOrUndefined(Cause.findErrorOption(decoded.cause))
      return { kind: "err", reason: String(decoded.cause).slice(0, 300), ...(e?.code ? { code: e.code, place: e.place ?? "$" } : {}) }
    }
    const encoded = Effect.runSyncExit(Haus.encodeValue(schema)(decoded.value))
    if (Exit.isFailure(encoded)) return { kind: "crash", reason: `CRASH: encoding failed: ${String(encoded.cause).slice(0, 300)}` }
    return { kind: "ok", text: canonical(encoded.value) }
  })
}

export const lean = (types: string) => external("lean", join(root, "spec/lean/.lake/build/bin/haus-ref"), ["--schema-batch", types], true)
export const rust = () => external("rust", join(root, "fuzz/schema-rust/target/release/schema_runner"), [], true)
/** haus-fmt-schema's runtime checker (`Schema::decode`), not generated code. */
export const rustCheck = () => external("rust-check", join(root, "fuzz/schema-rust/target/release/check_runner"), [], true)
export const roc = () => external("roc", join(root, "fuzz/.build/roc-schema-runner"), [], true)
export const python = () => external("python", join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/schema_runner.py")], true)
/** Package schema of the Go binding (`schema.Parse`, `Type.Decode`, `Type.Encode`). */
export const go = () => external("go", join(root, "fuzz/.build/go-runner"), ["--schema"], true)
export const swift = () => external("swift", join(root, "fuzz/.build/swift-runner"), ["--schema"], true)
