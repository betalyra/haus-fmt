/**
 * The parsers under test. Each gets a directory of cases (00000.haus, …) and
 * returns one result per case. TypeScript runs in this process; the others
 * are the binaries built by build.sh.
 */
import { spawnSync } from "node:child_process"
import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { canonical, HausSyntaxError, parseAll, StreamReader } from "../../typescript/packages/haus/dist/index.js"

/** An error has the error code of spec §17 when its runner reports codes (`code` undefined otherwise). */
export type Result =
  | { readonly ok: true; readonly json: string }
  | { readonly ok: false; readonly line: number; readonly column: number; readonly reason: string; readonly code?: string }

export interface Runner {
  readonly name: string
  run(dir: string, cases: readonly Uint8Array[]): Result[]
}

/**
 * How a separate program prints an error: `err LINE COLUMN REASON`, or with
 * `codes`, `err LINE COLUMN CODE REASON` (the code of spec §17). A binding
 * that reports codes sets it, and its codes are then compared with the
 * other runners' (main.ts).
 */
export interface Format {
  readonly codes?: boolean
}

const root = new URL("../..", import.meta.url).pathname
/** The Go runner (fuzz/go): every fuzzer's modes in one program. */
export const GO = join(root, "fuzz/.build/go-runner")
/** The Swift runner (fuzz/swift-runner): the parser, stream reader, canonical form and formatters. */
export const SWIFT = join(root, "fuzz/.build/swift-runner")

/** JSON with object keys sorted, so field order doesn't matter. */
export function normalize(json: string): string {
  const sort = (x: unknown): unknown =>
    Array.isArray(x) ? x.map(sort)
    : x !== null && typeof x === "object" ? Object.fromEntries(Object.entries(x).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([k, v]) => [k, sort(v)]))
    : x
  return JSON.stringify(sort(JSON.parse(json)))
}

function parseLine(line: string, format: Format): Result {
  if (line.startsWith("ok ")) return { ok: true, json: normalize(line.slice(3)) }
  if (format.codes) {
    const m = /^err (\d+) (\d+) ([a-z0-9-]+) ?(.*)$/s.exec(line)
    if (!m) throw new Error(`unexpected runner output (expected err LINE COLUMN CODE REASON): ${line.slice(0, 200)}`)
    return { ok: false, line: Number(m[1]), column: Number(m[2]), code: m[3]!, reason: m[4]! }
  }
  const m = /^err (\d+) (\d+) ?(.*)$/s.exec(line)
  if (!m) throw new Error(`unexpected runner output: ${line.slice(0, 200)}`)
  return { ok: false, line: Number(m[1]), column: Number(m[2]), reason: m[3]! }
}

/** A runner that is a separate program: `program [...args] DIR N`. */
function external(name: string, program: string, args: readonly string[] = [], format: Format = {}): Runner {
  return {
    name,
    run(dir, cases) {
      const p = spawnSync(program, [...args, dir, String(cases.length)], { maxBuffer: 1 << 30, encoding: "utf8" })
      // A crash is a finding: run the cases one by one to see which one crashes.
      if (p.status !== 0) return cases.map((c) => this.runOne(dir, c))
      const lines = p.stdout.split("\n").filter((l) => l !== "")
      if (lines.length !== cases.length) throw new Error(`${name}: ${lines.length} results for ${cases.length} cases`)
      return lines.map((l) => {
        try {
          return parseLine(l, format)
        } catch (e) {
          throw new Error(`${name}: ${(e as Error).message}`)
        }
      })
    },
    runOne(dir: string, bytes: Uint8Array): Result {
      const single = `${dir}-single`
      rmSync(single, { recursive: true, force: true })
      mkdirSync(single, { recursive: true })
      writeFileSync(join(single, "00000.haus"), bytes)
      const p = spawnSync(program, [...args, single, "1"], { encoding: "utf8" })
      if (p.status !== 0) return { ok: false, line: -1, column: -1, reason: `CRASH: ${(p.stderr || String(p.signal)).trim().split("\n").slice(0, 3).join(" ")}` }
      return parseLine(p.stdout.trim(), format)
    },
  } as Runner & { runOne(dir: string, bytes: Uint8Array): Result }
}

/** The suite's JSON encoding (test-suite/README.md). */
function suiteJson(v: any): unknown {
  switch (v.kind) {
    case "string": return v.value
    case "number": return { num: v.text }
    case "bytes": return { bytes: Buffer.from(v.bytes).toString("hex") }
    case "array": return v.items.map(suiteJson)
    case "record": return { rec: Object.fromEntries([...v.fields].map(([k, x]: [string, unknown]) => [k, suiteJson(x)])) }
    case "variant": return v.args.length ? { tag: v.tag, args: v.args.map(suiteJson) } : { tag: v.tag }
  }
}

const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })

/** Runs `parse` and turns its outcome into a result. A TypeError is the UTF-8 decoder's. */
function result(parse: () => unknown[], encode: (v: any) => unknown = suiteJson): Result {
  try {
    return { ok: true, json: normalize(JSON.stringify(parse().map(encode))) }
  } catch (e) {
    if (e instanceof HausSyntaxError) return { ok: false, line: e.line, column: e.column, reason: e.reason, code: e.code }
    if (e instanceof TypeError) return { ok: false, line: 0, column: 0, reason: "invalid UTF-8", code: "invalid-utf8" }
    throw e
  }
}

const typescript: Runner = {
  name: "typescript",
  run: (_dir, cases) => cases.map((bytes) => result(() => parseAll(utf8.decode(bytes)))),
}

/**
 * The chunks of case `i`, the same in every runner: chunk k has size
 * SIZES[(i + k) % 7], so cuts fall inside escapes, comments and UTF-8 sequences.
 */
export function chunks(bytes: Uint8Array, i: number): Uint8Array[] {
  const SIZES = [1, 2, 3, 5, 8, 13, 64]
  const out: Uint8Array[] = []
  for (let at = 0, k = 0; at < bytes.length; k++) {
    const end = Math.min(bytes.length, at + SIZES[(i + k) % 7]!)
    out.push(bytes.subarray(at, end))
    at = end
  }
  return out
}

/** Like `parseStream`: byte chunks through a streaming UTF-8 decoder into the reader. */
const typescriptStream: Runner = {
  name: "ts-stream",
  run: (_dir, cases) =>
    cases.map((bytes, i) =>
      result(() => {
        const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })
        const reader = new StreamReader()
        const values = chunks(bytes, i).flatMap((c) => reader.push(decoder.decode(c, { stream: true })))
        return [...values, ...reader.push(decoder.decode()), ...reader.end()]
      })),
}

export const runners: readonly Runner[] = [
  external("lean", join(root, "spec/lean/.lake/build/bin/haus-ref"), ["--batch"], { codes: true }),
  external("rust", join(root, "rust/target/release/examples/fuzz_runner"), [], { codes: true }),
  external("roc", join(root, "fuzz/.build/roc-runner"), [], { codes: true }),
  typescript,
  external("python", join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/runner.py")], { codes: true }),
  external("go", GO, [], { codes: true }),
  external("swift", SWIFT, [], { codes: true }),
  // The stream readers, on the same inputs in chunks: they must give what parsing the whole input gives.
  external("rust-stream", join(root, "rust/target/release/examples/fuzz_runner"), ["--stream"], { codes: true }),
  external("roc-stream", join(root, "fuzz/.build/roc-runner"), ["--stream"], { codes: true }),
  typescriptStream,
  external("python-stream", join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/runner.py"), "--stream"], { codes: true }),
  external("go-stream", GO, ["--stream"], { codes: true }),
  external("swift-stream", SWIFT, ["--stream"], { codes: true }),
]

/**
 * The canonical form (spec §12) of every value, by each binding: the same
 * inputs must give the same text everywhere (`main.ts --canonical`).
 */
export const canonicalRunners: readonly Runner[] = [
  external("lean", join(root, "spec/lean/.lake/build/bin/haus-ref"), ["--canonical-batch"], { codes: true }),
  external("rust", join(root, "rust/target/release/examples/fuzz_runner"), ["--canonical"], { codes: true }),
  external("roc", join(root, "fuzz/.build/roc-runner"), ["--canonical"], { codes: true }),
  { name: "typescript", run: (_dir, cases) => cases.map((bytes) => result(() => parseAll(utf8.decode(bytes)), canonical)) },
  external("python", join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/runner.py"), "--canonical"], { codes: true }),
  external("go", GO, ["--canonical"], { codes: true }),
  external("swift", SWIFT, ["--canonical"], { codes: true }),
]

/** The runners in use: the parsers, or with `--canonical` the canonical forms. */
let active: readonly Runner[] = runners
export const useCanonical = () => {
  active = canonicalRunners
}
export const activeRunners = () => active

/** Writes the cases to `dir` and runs every runner in use on them: results[case][runner]. */
export function runAll(dir: string, cases: readonly Uint8Array[]): Result[][] {
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(dir, { recursive: true })
  cases.forEach((c, i) => writeFileSync(join(dir, `${String(i).padStart(5, "0")}.haus`), c))
  const byRunner = active.map((r) => r.run(dir, cases))
  return cases.map((_, i) => byRunner.map((rs) => rs[i]!))
}
