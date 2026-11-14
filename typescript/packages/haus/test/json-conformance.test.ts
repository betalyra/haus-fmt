/** The JSON suite (test-suite/json, spec §16), and every valid/NAME.json as a lossless case. */
import { describe, expect, it } from "vitest"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import {
  canonical, compileSchemaFile, equals, equalsJson, fromJson, fromLosslessJson, fromLosslessJsonValue, HausDecodeError, HausSyntaxError, parseAll, parseJson,
  stringifyJson, toLosslessJson, toLosslessJsonValue, type Json, type Value,
} from "../src/index.js"
import * as h from "../src/schema.js"

const SUITE = join(import.meta.dirname, "../../../../test-suite")
const read = (path: string) => readFileSync(join(SUITE, path), "utf8")

/** A case: `Ok { … }`, `Read { … }` or `Err { … }`, with its fields. */
interface Case {
  readonly kind: "Ok" | "Read" | "Err"
  readonly type?: string
  readonly input?: Value
  readonly output?: Value
  readonly json: string
  readonly name: string
}

const cases = (text: string): Case[] =>
  parseAll(text).map((v) => {
    if (v.kind !== "variant" || !["Ok", "Read", "Err"].includes(v.tag) || v.args[0]?.kind !== "record") throw new Error(`not a case: ${canonical(v)}`)
    const f = v.args[0].fields
    const field = (k: string) => f.get(k)
    const type = field("type")
    const json = field("json")
    if (json?.kind !== "string") throw new Error(`not a case: ${canonical(v)}`)
    const input = field("input")
    const output = field("output") ?? input
    return {
      kind: v.tag as Case["kind"],
      ...(type?.kind === "string" ? { type: type.value } : {}),
      ...(input ? { input } : {}),
      ...(output ? { output } : {}),
      json: json.value,
      name: `${v.tag} ${type?.kind === "string" ? type.value + " " : ""}${json.value}`,
    }
  })

/** JSON compared as data (member order, whitespace), numbers by their text. */
const expectJson = (actual: Json, json: string) => {
  const expected = parseJson(json, { maxDepth: 2000 })
  expect(equalsJson(actual, expected), `${stringifyJson(actual)} is not ${json}`).toBe(true)
}

const rejects = (f: () => unknown) => {
  try {
    f()
  } catch (e) {
    expect(e instanceof HausDecodeError || e instanceof HausSyntaxError, String(e)).toBe(true)
    return
  }
  throw new Error("expected an error")
}

describe("plain (spec §16.3)", () => {
  const { schemas } = compileSchemaFile(read("json/plain.schema.haus"))
  const schema = (c: Case) => schemas[c.type!] ?? (() => { throw new Error(`no type ${c.type}`) })()

  it.each(cases(read("json/plain.cases.haus")))("$name", (c) => {
    const s = schema(c)
    switch (c.kind) {
      case "Ok": {
        const decoded = h.decode(s, c.input!)
        expectJson(h.toJsonValue(s, decoded), c.json)
        expectJson(parseJson(h.toJson(s, decoded)), c.json)
        expect(canonical(h.encode(s, h.fromJson(s, c.json)))).toBe(canonical(c.output!))
        return
      }
      case "Read":
        expect(canonical(h.encode(s, h.fromJson(s, c.json)))).toBe(canonical(c.output!))
        return
      case "Err":
        return rejects(() => h.fromJson(s, c.json))
    }
  })
})

describe("lossless (spec §16.2)", () => {
  it.each(cases(read("json/lossless.cases.haus")))("$name", (c) => {
    if (c.kind === "Err") return rejects(() => fromLosslessJson(c.json))
    expectJson(toLosslessJsonValue(c.input!), c.json)
    expectJson(parseJson(toLosslessJson(c.input!)), c.json)
    expect(canonical(fromLosslessJson(c.json))).toBe(canonical(c.input!))
  })
})

describe("without a schema (spec §16.1)", () => {
  it.each(cases(read("json/schemaless.cases.haus")))("$name", (c) => {
    if (c.kind === "Err") return rejects(() => fromJson(c.json))
    expect(equals(fromJson(c.json), c.output!), canonical(fromJson(c.json))).toBe(true)
  })
})

describe("valid/NAME.json as lossless cases", () => {
  const names = readdirSync(join(SUITE, "valid")).filter((f) => f.endsWith(".haus")).map((f) => f.slice(0, -".haus".length)).sort()
  it.each(names)("%s", (name) => {
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(readFileSync(join(SUITE, "valid", `${name}.haus`)))
    const values = parseAll(text)
    const json = read(`valid/${name}.json`)
    // Writing: the JSON array of the values' lossless forms.
    expectJson(values.map((v) => toLosslessJsonValue(v)), json)
    // Reading: each element gives an equal value.
    const parsed = parseJson(json, { maxDepth: 2000 })
    expect(Array.isArray(parsed)).toBe(true)
    const back = (parsed as readonly Json[]).map((j) => fromLosslessJsonValue(j))
    expect(back.map(canonical)).toEqual(values.map(canonical))
  })
})
