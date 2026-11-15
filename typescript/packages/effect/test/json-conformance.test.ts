/**
 * The JSON suite (test-suite/json, spec §16) through the Effect adapter: the
 * plain mapping with the schema file compiled to Effect schemas, the lossless
 * mapping as the plain form of `Haus.Any`, JSON without a schema with
 * `Haus.valueFromJson`, and every valid/NAME.json as `Array Any`.
 */
import { canonical, equalsJson, parseAll, parseJson, stringifyJson, type Json, type Value } from "@haus-fmt/haus"
import { describe, expect, it } from "@effect/vitest"
import { Cause, Effect, Exit, Option, Schema } from "effect"
import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import * as Haus from "../src/index.js"

const SUITE = fileURLToPath(new URL("../../../../test-suite/", import.meta.url))
const read = (path: string) => readFileSync(`${SUITE}${path}`, "utf8")

interface Case {
  readonly kind: "Ok" | "Read" | "Err"
  readonly type: string | undefined
  readonly input: Value | undefined
  readonly output: Value | undefined
  readonly json: string
  /** For `Err`: the error code (spec §17). */
  readonly code: string | undefined
  readonly name: string
}

const cases = (text: string): Case[] =>
  parseAll(text).map((v) => {
    if (v.kind !== "variant" || !["Ok", "Read", "Err"].includes(v.tag) || v.args[0]?.kind !== "record") throw new Error(`not a case: ${canonical(v)}`)
    const f = v.args[0].fields
    const type = f.get("type")
    const json = f.get("json")
    if (json?.kind !== "string") throw new Error(`not a case: ${canonical(v)}`)
    const code = f.get("code")
    if (v.tag === "Err" && code?.kind !== "string") throw new Error(`an Err case without a code: ${canonical(v)}`)
    return {
      kind: v.tag as Case["kind"],
      type: type?.kind === "string" ? type.value : undefined,
      input: f.get("input"),
      output: f.get("output") ?? f.get("input"),
      json: json.value,
      code: code?.kind === "string" ? code.value : undefined,
      name: `${v.tag} ${type?.kind === "string" ? type.value + " " : ""}${json.value}`,
    }
  })

const expectJson = (actual: Json, json: string) =>
  expect(equalsJson(actual, parseJson(json, { maxDepth: 2000 })), `${stringifyJson(actual)} is not ${json}`).toBe(true)

/** The effect fails with a typed error (not a defect) with this code (spec §17). */
const fails = <A>(effect: Effect.Effect<A, Haus.HausError>, code: string | undefined) => {
  const exit = Effect.runSyncExit(effect)
  expect(Exit.isFailure(exit) && Exit.hasFails(exit), String(exit)).toBe(true)
  if (Exit.isFailure(exit)) {
    const error = Cause.findErrorOption(exit.cause).pipe(Option.getOrUndefined)
    expect(error?.code, error?.message).toBe(code)
  }
}

describe("plain (spec §16.3)", () => {
  const { schemas } = Haus.compileSchemaFile(read("json/plain.schema.haus"))

  for (const c of cases(read("json/plain.cases.haus"))) {
    it.effect(c.name, () =>
      Effect.gen(function* () {
        const schema = schemas[c.type!]!
        if (c.kind === "Err") return fails(Haus.fromJson(schema)(c.json), c.code)
        if (c.kind === "Ok") {
          const decoded = yield* Haus.decodeValue(schema)(c.input!)
          expectJson(yield* Haus.toJsonValue(schema)(decoded), c.json)
          expectJson(parseJson(yield* Haus.toJson(schema)(decoded)), c.json)
        }
        const back = yield* Haus.fromJson(schema)(c.json)
        expect(canonical(yield* Haus.encodeValue(schema)(back))).toBe(canonical(c.output!))
      }))
  }
})

describe("lossless (spec §16.2), as Haus.Any", () => {
  for (const c of cases(read("json/lossless.cases.haus"))) {
    it.effect(c.name, () =>
      Effect.gen(function* () {
        if (c.kind === "Err") return fails(Haus.fromJson(Haus.Any)(c.json), c.code)
        expectJson(yield* Haus.toJsonValue(Haus.Any)(c.input!), c.json)
        expect(canonical(yield* Haus.fromJson(Haus.Any)(c.json))).toBe(canonical(c.input!))
      }))
  }
})

describe("without a schema (spec §16.1)", () => {
  for (const c of cases(read("json/schemaless.cases.haus"))) {
    it.effect(c.name, () =>
      Effect.gen(function* () {
        if (c.kind === "Err") return fails(Haus.valueFromJson(c.json), c.code)
        expect(canonical(yield* Haus.valueFromJson(c.json))).toBe(canonical(c.output!))
      }))
  }
})

describe("valid/NAME.json as lossless cases", () => {
  const Values = Schema.Array(Haus.Any)
  const names = readdirSync(`${SUITE}valid`).filter((f) => f.endsWith(".haus")).map((f) => f.slice(0, -".haus".length)).sort()
  for (const name of names) {
    it.effect(name, () =>
      Effect.gen(function* () {
        const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(readFileSync(`${SUITE}valid/${name}.haus`))
        const values = parseAll(text)
        const json = read(`valid/${name}.json`)
        expectJson(yield* Haus.toJsonValue(Values)(values), json)
        const back = yield* Haus.fromJson(Values)(json)
        expect(back.map(canonical)).toEqual(values.map(canonical))
      }))
  }
})
