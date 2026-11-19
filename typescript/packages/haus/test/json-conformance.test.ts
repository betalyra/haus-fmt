/** The JSON suite (test-suite/json, spec §16), and every valid/NAME.jsonl as a self-describing case. */
import { describe, expect, it } from "vitest"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import {
  canonical, compileSchemaFile, equals, equalsJson, errorCode, formatPath, fromHausJson, fromHausJsonLines, HausDecodeError, HausSyntaxError, importJson, parseAll, parseJson,
  stringifyJson, toHausJson, toHausJsonLines, toHausJsonValue, type Json, type Value,
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
  /** For `Err`: the error code (spec §17). */
  readonly code?: string
  /** For `Err`, when given: the error's place in the JSON (spec §16.3 "Places"). */
  readonly path?: string
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
    const code = field("code")
    const path = field("path")
    if (v.tag === "Err" && code?.kind !== "string") throw new Error(`an Err case without a code: ${canonical(v)}`)
    return {
      kind: v.tag as Case["kind"],
      ...(type?.kind === "string" ? { type: type.value } : {}),
      ...(input ? { input } : {}),
      ...(output ? { output } : {}),
      json: json.value,
      ...(code?.kind === "string" ? { code: code.value } : {}),
      ...(path?.kind === "string" ? { path: path.value } : {}),
      name: `${v.tag} ${type?.kind === "string" ? type.value + " " : ""}${json.value}`,
    }
  })

/** JSON compared as data (member order, whitespace), numbers by their text. */
const expectJson = (actual: Json, json: string) => {
  const expected = parseJson(json, { maxDepth: 2000 })
  expect(equalsJson(actual, expected), `${stringifyJson(actual)} is not ${json}`).toBe(true)
}

const rejects = (f: () => unknown, c: Case) => {
  try {
    f()
  } catch (e) {
    expect(e instanceof HausDecodeError || e instanceof HausSyntaxError, String(e)).toBe(true)
    expect(errorCode(e), String(e)).toBe(c.code)
    if (c.path !== undefined) expect(e instanceof HausDecodeError ? formatPath(e.path) : undefined, String(e)).toBe(c.path)
    return
  }
  throw new Error("expected an error")
}

describe("schema-based (spec §16.3)", () => {
  const { schemas } = compileSchemaFile(read("json/schema-based.schema.haus"))
  const schema = (c: Case) => schemas[c.type!] ?? (() => { throw new Error(`no type ${c.type}`) })()

  it.each(cases(read("json/schema-based.cases.haus")))("$name", (c) => {
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
        return rejects(() => h.fromJson(s, c.json), c)
    }
  })
})

describe("self-describing (spec §16.2)", () => {
  it.each(cases(read("json/self-describing.cases.haus")))("$name", (c) => {
    if (c.kind === "Err") return rejects(() => fromHausJson(c.json), c)
    expectJson(toHausJsonValue(c.input!), c.json)
    expectJson(parseJson(toHausJson(c.input!)), c.json)
    expect(canonical(fromHausJson(c.json))).toBe(canonical(c.input!))
  })
})

describe("import (spec §16.1)", () => {
  it.each(cases(read("json/import.cases.haus")))("$name", (c) => {
    if (c.kind === "Err") return rejects(() => importJson(c.json), c)
    expect(equals(importJson(c.json), c.output!), canonical(importJson(c.json))).toBe(true)
  })
})

const collect = async <T>(items: AsyncIterable<T>): Promise<T[]> => {
  const out: T[] = []
  for await (const x of items) out.push(x)
  return out
}

describe("valid/NAME.jsonl as self-describing cases", () => {
  const names = readdirSync(join(SUITE, "valid")).filter((f) => f.endsWith(".haus")).map((f) => f.slice(0, -".haus".length)).sort()
  it.each(names)("%s", async (name) => {
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(readFileSync(join(SUITE, "valid", `${name}.haus`)))
    const values = parseAll(text)
    const jsonl = read(`valid/${name}.jsonl`)
    // Writing: one envelope per value, a line each.
    const written = await collect(toHausJsonLines(values))
    const lines = jsonl.split("\n").filter((l) => l !== "")
    expect(written).toHaveLength(lines.length)
    written.forEach((w, i) => expectJson(parseJson(w, { maxDepth: 2000 }), lines[i]!))
    // Reading: each line gives an equal value.
    const back = await collect(fromHausJsonLines([jsonl]))
    expect(back.map(canonical)).toEqual(values.map(canonical))
  })
})
