/**
 * The JSON converters under test (json.ts, spec §16), in five modes:
 *
 * | Mode | Line | Does | Prints |
 * |---|---|---|---|
 * | `write` | `SUITE TYPE HEX` (haus text) | decode with the type, write plain JSON (§16.3) | `ok <JSON>` |
 * | `read` | `SUITE TYPE HEX` (JSON text) | read plain JSON with the type, encode | `ok <canonical form>` |
 * | `lossless-write` | `HEX` (haus text) | the lossless JSON of the value (§16.2) | `ok <JSON>` |
 * | `lossless-read` | `HEX` (JSON text) | read lossless JSON | `ok <canonical form>` |
 * | `schemaless` | `HEX` (JSON text) | read JSON without a schema (§16.1) | `ok <canonical form>` |
 *
 * Otherwise `err <reason>`. TypeScript and Effect run in this process; the
 * others are the programs built by build.sh (Lean: `haus-ref`'s JSON batch
 * modes; the rest take `MODE FILE`).
 */
import { spawnSync } from "node:child_process"
import { writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import {
  canonical, compileSchemaFile, fromJson, fromLosslessJson, HausDecodeError, HausEncodeError, HausSyntaxError, parseAll, toLosslessJson,
} from "../../typescript/packages/haus/dist/index.js"
import * as h from "../../typescript/packages/haus/dist/schema.js"
import type { Outcome } from "./schema-runners.ts"

export type Mode = "write" | "read" | "lossless-write" | "lossless-read" | "schemaless"
export const MODES: readonly Mode[] = ["write", "read", "lossless-write", "lossless-read", "schemaless"]
/** Whether a mode writes JSON (compared as data) rather than reading it (compared by canonical form). */
export const writes = (m: Mode) => m === "write" || m === "lossless-write"
export const typed = (m: Mode) => m === "write" || m === "read"

export interface JsonCase {
  readonly mode: Mode
  readonly suite: string
  readonly type: string
  readonly text: string
  /** Raw bytes instead of `text` (for input that isn't UTF-8). */
  readonly bytes?: Uint8Array | undefined
}

export interface JsonRunner {
  readonly name: string
  run(mode: Mode, file: string, cases: readonly JsonCase[]): Outcome[]
}

const root = new URL("../..", import.meta.url).pathname

export const caseBytes = (c: JsonCase) => c.bytes ?? Buffer.from(c.text, "utf8")
export const caseLine = (c: JsonCase) => {
  const hex = Buffer.from(caseBytes(c)).toString("hex")
  return typed(c.mode) ? `${c.suite} ${c.type} ${hex}` : hex
}

function parseOutcome(line: string): Outcome {
  if (line.startsWith("ok ")) return { kind: "ok", text: line.slice(3) }
  if (line.startsWith("err")) return { kind: "err", reason: line.slice(4) }
  return { kind: "crash", reason: `unexpected output: ${line.slice(0, 200)}` }
}

/** A separate program; when it crashes or hangs, the cases are split in halves until the ones that crash it are found. */
function external(name: string, command: (mode: Mode, file: string) => readonly [string, readonly string[]]): JsonRunner {
  const runRange = (mode: Mode, file: string, cases: readonly JsonCase[]): Outcome[] => {
    const part = `${file}.${name}`
    writeFileSync(part, cases.map((c) => caseLine(c) + "\n").join(""))
    const [program, args] = command(mode, part)
    const p = spawnSync(program, args, { maxBuffer: 1 << 30, encoding: "utf8", timeout: 600_000 })
    const lines = (p.stdout ?? "").split("\n").filter((l) => l !== "")
    if (p.status === 0 && lines.length === cases.length) return lines.map(parseOutcome)
    if (cases.length === 1) {
      const why = p.error ? String(p.error) : p.signal ? `signal ${p.signal}` : `exit ${p.status}, ${lines.length} lines`
      return [{ kind: "crash", reason: `CRASH (${why}): ${(p.stderr ?? "").trim().split("\n").slice(0, 3).join(" ").slice(0, 300)}` }]
    }
    const mid = cases.length >> 1
    return [...runRange(mode, file, cases.slice(0, mid)), ...runRange(mode, file, cases.slice(mid))]
  }
  return { name, run: runRange }
}

const LEAN_FLAGS: Record<Mode, string> = {
  write: "--json-batch",
  read: "--json-read-batch",
  "lossless-write": "--lossless-batch",
  "lossless-read": "--lossless-read-batch",
  schemaless: "--schemaless-read-batch",
}

export const lean = (types: string) =>
  external("lean", (mode, file) => [join(root, "spec/lean/.lake/build/bin/haus-ref"), typed(mode) ? [LEAN_FLAGS[mode], types, file] : [LEAN_FLAGS[mode], file]])
export const rust = () => external("rust", (mode, file) => [join(root, "fuzz/schema-rust/target/release/json_runner"), [mode, file]])
export const roc = () => external("roc", (mode, file) => [join(root, "fuzz/.build/roc-json-runner"), [mode, file]])
export const python = () => external("python", (mode, file) => [join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/json_runner.py"), mode, file]])

// ── in this process ──────────────────────────────────────────

const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })

/** The case's text as the in-process converters get it: UTF-8 decoded, a byte order mark kept. */
function text(c: JsonCase): string | undefined {
  if (!c.bytes) return c.text
  try {
    return utf8.decode(c.bytes)
  } catch {
    return undefined
  }
}

function single(t: string): { value: any } | { error: string } {
  try {
    const vs = parseAll(t)
    return vs.length === 1 ? { value: vs[0] } : { error: "not a single value" }
  } catch (e) {
    return { error: `not a single value: ${(e as Error).message}` }
  }
}

const crash = (e: unknown): Outcome => ({ kind: "crash", reason: `CRASH: ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`.slice(0, 300) })

/** An error the API documents (`err`), or anything else (a crash). */
const isHausError = (e: unknown) => e instanceof HausDecodeError || e instanceof HausSyntaxError || e instanceof HausEncodeError || e instanceof h.HausDecodeError || e instanceof h.HausEncodeError

function inProcess(name: string, one: (mode: Mode, c: JsonCase, t: string) => Outcome): JsonRunner {
  return {
    name,
    run: (mode, _file, cases) =>
      cases.map((c) => {
        const t = text(c)
        if (t === undefined) return { kind: "err", reason: "invalid UTF-8" }
        try {
          return one(mode, c, t)
        } catch (e) {
          if (isHausError(e)) return { kind: "err", reason: (e as Error).message.slice(0, 300) }
          return crash(e)
        }
      }),
  }
}

/**
 * Each schema file compiled, or why the binding rejects it: then every case
 * of the file is `err` (it agrees with lean where lean rejects the case).
 */
function compileEach<S>(texts: ReadonlyMap<string, string>, compile: (text: string) => S): { schemas: Map<string, S>; rejected: Map<string, string> } {
  const schemas = new Map<string, S>()
  const rejected = new Map<string, string>()
  for (const [s, t] of texts) {
    try {
      schemas.set(s, compile(t))
    } catch (e) {
      rejected.set(s, e instanceof Error ? e.message : String(e))
    }
  }
  return { schemas, rejected }
}

/** @haus-fmt/haus: `h.decode` + `h.toJson`, `h.fromJson` + `h.encode`, `toLosslessJson`, `fromLosslessJson`, `fromJson`. */
export function typescriptRunner(texts: ReadonlyMap<string, string>): JsonRunner {
  const compiled = compileEach(texts, (t) => compileSchemaFile(t).schemas as Record<string, h.Schema<unknown>>)
  return inProcess("typescript", (mode, c, t) => {
    switch (mode) {
      case "write":
      case "read": {
        const rejected = compiled.rejected.get(c.suite)
        if (rejected !== undefined) return { kind: "err", reason: `the schema file is rejected: ${rejected}` }
        const schema = compiled.schemas.get(c.suite)?.[c.type]
        if (!schema) return { kind: "crash", reason: `CRASH: no type ${c.suite}.${c.type}` }
        if (mode === "write") {
          const v = single(t)
          if ("error" in v) return { kind: "err", reason: v.error }
          return { kind: "ok", text: h.toJson(schema, h.decode(schema, v.value)) }
        }
        const x = h.fromJson(schema, t)
        try {
          return { kind: "ok", text: canonical(h.encode(schema, x)) }
        } catch (e) {
          return { kind: "crash", reason: `CRASH: encoding what was read failed: ${(e as Error).message}`.slice(0, 300) }
        }
      }
      case "lossless-write": {
        const v = single(t)
        if ("error" in v) return { kind: "err", reason: v.error }
        return { kind: "ok", text: toLosslessJson(v.value) }
      }
      case "lossless-read": return { kind: "ok", text: canonical(fromLosslessJson(t)) }
      case "schemaless": return { kind: "ok", text: canonical(fromJson(t)) }
    }
  })
}

/** @haus-fmt/effect: `decodeValue` + `Haus.toJson`, `Haus.fromJson` + `encodeValue`; lossless as `Haus.Any`; `Haus.valueFromJson`. */
export async function effectRunner(texts: ReadonlyMap<string, string>): Promise<JsonRunner> {
  const dir = join(root, "typescript/packages/effect")
  const Haus = await import(pathToFileURL(join(dir, "dist/index.js")).href)
  const effectEntry = createRequire(join(dir, "package.json")).resolve("effect")
  const { Effect, Exit, Cause } = await import(pathToFileURL(effectEntry).href)
  const compiled = compileEach(texts, (t) => Haus.compileSchemaFile(t).schemas as Record<string, unknown>)
  /** The value of an effect, or the outcome of its failure. */
  const runE = (e: unknown): { value: any } | { outcome: Outcome } => {
    const exit = Effect.runSyncExit(e)
    if (Exit.isSuccess(exit)) return { value: exit.value }
    if (Cause.hasDies(exit.cause)) return { outcome: { kind: "crash", reason: `CRASH: ${String(exit.cause).slice(0, 300)}` } }
    return { outcome: { kind: "err", reason: String(exit.cause).slice(0, 300) } }
  }
  const chain = (...steps: ((x: any) => unknown)[]): Outcome => {
    let x: any = undefined
    for (const step of steps) {
      const r = runE(step(x))
      if ("outcome" in r) return r.outcome
      x = r.value
    }
    return { kind: "ok", text: x }
  }
  return inProcess("effect", (mode, c, t) => {
    switch (mode) {
      case "write":
      case "read": {
        const rejected = compiled.rejected.get(c.suite)
        if (rejected !== undefined) return { kind: "err", reason: `the schema file is rejected: ${rejected}` }
        const schema = compiled.schemas.get(c.suite)?.[c.type]
        if (!schema) return { kind: "crash", reason: `CRASH: no type ${c.suite}.${c.type}` }
        if (mode === "write") {
          const v = single(t)
          if ("error" in v) return { kind: "err", reason: v.error }
          return chain(() => Haus.decodeValue(schema)(v.value), (d) => Haus.toJson(schema)(d))
        }
        const read = runE(Haus.fromJson(schema)(t))
        if ("outcome" in read) return read.outcome
        const enc = runE(Haus.encodeValue(schema)(read.value))
        if ("outcome" in enc) return { kind: "crash", reason: `CRASH: encoding what was read failed: ${"reason" in enc.outcome ? enc.outcome.reason : ""}` }
        return { kind: "ok", text: canonical(enc.value) }
      }
      case "lossless-write": {
        const v = single(t)
        if ("error" in v) return { kind: "err", reason: v.error }
        return chain(() => Haus.toJson(Haus.Any)(v.value))
      }
      case "lossless-read": {
        const r = runE(Haus.fromJson(Haus.Any)(t))
        return "outcome" in r ? r.outcome : { kind: "ok", text: canonical(r.value) }
      }
      case "schemaless": {
        const r = runE(Haus.valueFromJson(t))
        return "outcome" in r ? r.outcome : { kind: "ok", text: canonical(r.value) }
      }
    }
  })
}
