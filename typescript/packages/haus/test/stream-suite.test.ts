/** The stream suite (test-suite/stream, spec §6, §7): every case whole, one character at a time, and split at every position. */
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { describe, expect, it } from "vitest"
import { arr, canonical, compileSchemaFile, equals, errorCode, formatPath, HausDecodeError, parse, parseAll, StreamReader, type Value } from "../src/index.js"
import * as h from "../src/schema.js"

/** HAUS_STREAM_SUITE: another directory with the suite's limits.cases.haus. */
const CASES = join(process.env.HAUS_STREAM_SUITE ?? join(import.meta.dirname, "../../../../test-suite/stream"), "limits.cases.haus")

interface Case {
  readonly text: string
  readonly maxValueLength: number
  readonly strict: boolean
  readonly result: { readonly ok: true; readonly values: readonly Value[] } | { readonly ok: false; readonly code: string }
}

const field = (v: Value, key: string): Value | undefined => (v.kind === "record" ? v.fields.get(key) : undefined)

const toCase = (v: Value): Case => {
  const text = field(v, "text")
  const max = field(v, "maxValueLength")
  const strict = field(v, "strict")
  const result = field(v, "result")
  if (text?.kind !== "string" || max?.kind !== "number" || result?.kind !== "variant") throw new Error(`not a case: ${canonical(v)}`)
  const arg = result.args[0]
  return {
    text: text.value,
    maxValueLength: Number(max.text),
    strict: strict?.kind === "variant" && strict.tag === "True",
    result:
      result.tag === "Ok" && arg?.kind === "array"
        ? { ok: true, values: arg.items }
        : result.tag === "Err" && arg?.kind === "string"
          ? { ok: false, code: arg.value }
          : (() => { throw new Error(`not a result: ${canonical(result)}`) })(),
  }
}

type Outcome = { readonly ok: true; readonly values: readonly Value[] } | { readonly ok: false; readonly code: string }

const read = (c: Case, chunks: readonly string[]): Outcome => {
  const reader = new StreamReader({ maxValueLength: c.maxValueLength, requireTerminator: c.strict })
  const values: Value[] = []
  try {
    for (const chunk of chunks) values.push(...reader.push(chunk))
    values.push(...reader.end())
    return { ok: true, values }
  } catch (e) {
    return { ok: false, code: errorCode(e) ?? String(e) }
  }
}

/** Whole, one character at a time, and in two pieces split at every position (in code points). */
const splits = (text: string): [string, readonly string[]][] => {
  const chars = [...text]
  return [
    ["whole", [text]],
    ["by character", chars],
    ...chars.map((_, k): [string, readonly string[]] => [`split at ${k}`, [chars.slice(0, k).join(""), chars.slice(k).join("")]]),
  ]
}

const same = (got: Outcome, want: Case["result"]): boolean =>
  got.ok && want.ok
    ? got.values.length === want.values.length && got.values.every((v, i) => equals(v, want.values[i]!))
    : !got.ok && !want.ok && got.code === want.code

const show = (o: Outcome): string => (o.ok ? `Ok [${o.values.map(canonical).join(", ")}]` : `Err ${o.code}`)

const cases = parseAll(readFileSync(CASES, "utf8")).map(toCase)

describe("stream suite", () => {
  it("has all its cases", () => expect(cases.length).toBe(24))
  for (const c of cases) {
    it(`${JSON.stringify(c.text)} max ${c.maxValueLength}${c.strict ? " strict" : ""}`, () => {
      const failures = splits(c.text).flatMap(([how, chunks]) => {
        const got = read(c, chunks)
        return same(got, c.result) ? [] : [`${how}: ${show(got)}`]
      })
      expect(failures).toEqual([])
    })
  }
})

/** `whole`: parsing the whole text doesn't apply the value limit (spec §7). */
describe("stream suite, parsed whole", () => {
  const wholes = parseAll(readFileSync(CASES, "utf8")).flatMap((v) => {
    const whole = field(v, "whole")
    const text = field(v, "text")
    if (whole === undefined) return []
    if (text?.kind !== "string" || whole.kind !== "variant" || whole.tag !== "Ok" || whole.args[0]?.kind !== "array") throw new Error(`not a case: ${canonical(v)}`)
    return [{ text: text.value, values: whole.args[0].items }]
  })
  it("has cases", () => expect(wholes.length).toBeGreaterThan(0))
  it.each(wholes)("$text", ({ text, values }) => expect(parseAll(text).map(canonical)).toEqual(values.map(canonical)))
})

/** document.cases.haus: single documents (spec §6). */
describe("single documents", () => {
  const docs = parseAll(readFileSync(join(dirname(CASES), "document.cases.haus"), "utf8")).map((v) => {
    const text = field(v, "text")
    const result = field(v, "result")
    if (text?.kind !== "string" || result?.kind !== "variant" || result.args[0] === undefined) throw new Error(`not a case: ${canonical(v)}`)
    return { text: text.value, want: result.tag === "Ok" ? `Ok ${canonical(result.args[0])}` : `Err ${result.args[0].kind === "string" ? result.args[0].value : "?"}` }
  })
  it("has cases", () => expect(docs.length).toBeGreaterThan(0))
  it.each(docs)("$text", ({ text, want }) => {
    let got: string
    try {
      got = `Ok ${canonical(parse(text))}`
    } catch (e) {
      got = `Err ${errorCode(e) ?? String(e)}`
    }
    expect(got).toBe(want)
  })
})

/** typed.schema.haus and typed.cases.haus: streams decoded with a type (spec §15). */
describe("typed streams", () => {
  const dir = dirname(CASES)
  const { schemas, streams } = compileSchemaFile(readFileSync(join(dir, "typed.schema.haus"), "utf8"))
  const typed = parseAll(readFileSync(join(dir, "typed.cases.haus"), "utf8")).map((v) => {
    if (v.kind !== "variant" || v.args[0] === undefined) throw new Error(`not a case: ${canonical(v)}`)
    const f = (k: string) => field(v.args[0]!, k)
    const type = f("type")
    const text = f("text")
    if (type?.kind !== "string" || text?.kind !== "string") throw new Error(`not a case: ${canonical(v)}`)
    const want = v.tag === "Ok" ? `Ok ${canonical(f("output")!)}` : `Err ${(f("code") as { value: string }).value} ${(f("path") as { value: string }).value}`
    return { type: type.value, text: text.value, want }
  })
  it("has cases", () => expect(typed.length).toBeGreaterThan(0))
  it.each(typed)("$type $text", async ({ type, text, want }) => {
    const schema = schemas[type]!
    let got: string
    try {
      if (streams.has(type)) {
        const out: Value[] = []
        for await (const item of h.decodeStream(schema, [text])) out.push(h.encode(schema, item))
        got = `Ok ${canonical(arr(out))}`
      } else got = `Ok ${canonical(h.encode(schema, h.parse(schema, text)))}`
    } catch (e) {
      got = `Err ${errorCode(e) ?? String(e)} ${e instanceof HausDecodeError ? formatPath(e.path) : "-"}`
    }
    expect(got).toBe(want)
  })
})
