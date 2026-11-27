/**
 * The JSON suite (test-suite/json, spec §16) through the Effect adapter:
 * schema-based JSON with the schema file compiled to Effect schemas,
 * self-describing JSON with `Haus.toHausJson` / `Haus.fromHausJson` (and,
 * without the envelope, as the schema-based form of `Haus.Any`), the import
 * with `Haus.importJson`, and every valid/NAME.jsonl a line at a time.
 */
import { canonical, equalsJson, isJsonObject, parseAll, parseJson, stringifyJson, type Json, type Value } from "@haus-fmt/haus/internal"
import { describe, expect, it } from "@effect/vitest"
import { Cause, Effect, Exit, Option } from "effect"
import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import * as Haus from "../src/index.js"
import { compileText, failureOf } from "./support.js"

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
  /** For `Err`, when given: the error's place in the JSON (spec §16.3 "Places"). */
  readonly path: string | undefined
  /** For `Ok`: the places of the secrets in the decoded value (spec §15). */
  readonly secrets: readonly string[]
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
    const path = f.get("path")
    if (v.tag === "Err" && code?.kind !== "string") throw new Error(`an Err case without a code: ${canonical(v)}`)
    return {
      kind: v.tag as Case["kind"],
      type: type?.kind === "string" ? type.value : undefined,
      input: f.get("input"),
      output: f.get("output") ?? f.get("input"),
      json: json.value,
      code: code?.kind === "string" ? code.value : undefined,
      path: path?.kind === "string" ? path.value : undefined,
      secrets: (() => {
        const s = f.get("secrets")
        return s?.kind === "array" ? s.items.map((x) => (x.kind === "string" ? x.value : canonical(x))) : []
      })(),
      name: `${v.tag} ${type?.kind === "string" ? type.value + " " : ""}${json.value}`,
    }
  })

const expectJson = (actual: Json, json: string) =>
  expect(equalsJson(actual, parseJson(json, { maxDepth: 2000 })), `${stringifyJson(actual)} is not ${json}`).toBe(true)

/** The effect fails with a typed error (not a defect) with the case's code (spec §17), and its place when the case gives one. */
const fails = <A>(effect: Effect.Effect<A, Haus.HausError>, c: Case) => {
  const exit = Effect.runSyncExit(effect)
  expect(Exit.isFailure(exit) && Exit.hasFails(exit), String(exit)).toBe(true)
  if (Exit.isFailure(exit)) {
    const error = Cause.findErrorOption(exit.cause).pipe(Option.getOrUndefined)
    expect(error?.code, error?.message).toBe(c.code)
    if (c.path !== undefined) expect(error instanceof Haus.HausSchemaError ? error.place : undefined, error?.message).toBe(c.path)
  }
}

describe("schema-based (spec §16.3)", () => {
  const { schemas } = compileText(read("json/schema-based.schema.haus"))
  const reveal = { revealSecrets: true }

  for (const c of cases(read("json/schema-based.cases.haus"))) {
    it.effect(c.name, () =>
      Effect.gen(function* () {
        const schema = schemas[c.type!]!
        if (c.kind === "Err") return fails(Haus.fromJson(schema)(c.json), c)
        if (c.kind === "Ok") {
          const decoded = yield* Haus.decodeValue(schema)(c.input!)
          expectJson(yield* Haus.toJsonValue(schema)(decoded, reveal), c.json)
          expectJson(parseJson(yield* Haus.toJson(schema)(decoded, reveal)), c.json)
          // Without revealSecrets: refused at a secret's place, or the same JSON (spec §15, "Encoding a secret").
          if (c.secrets.length === 0) expectJson(yield* Haus.toJsonValue(schema)(decoded), c.json)
          else {
            const e = failureOf(Haus.toJson(schema)(decoded))
            expect(e.code, e.message).toBe("cannot-encode")
            expect(c.secrets, e.message).toContain(e._tag === "HausSchemaError" ? e.place : undefined)
          }
        }
        const back = yield* Haus.fromJson(schema)(c.json)
        expect(canonical(yield* Haus.encodeValue(schema)(back, reveal))).toBe(canonical(c.output!))
      }))
  }
})

/** The value in an envelope, as JSON text. */
const valueOf = (json: string): string => {
  const envelope = parseJson(json, { maxDepth: 2000 })
  if (!isJsonObject(envelope) || envelope["_value"] === undefined) throw new Error(`not an envelope: ${json}`)
  return stringifyJson(envelope["_value"])
}

describe("self-describing (spec §16.2)", () => {
  for (const c of cases(read("json/self-describing.cases.haus"))) {
    it.effect(c.name, () =>
      Effect.gen(function* () {
        if (c.kind === "Err") return fails(Haus.fromHausJson(c.json), c)
        expectJson(parseJson(yield* Haus.toHausJson(c.input!)), c.json)
        expect(canonical(yield* Haus.fromHausJson(c.json))).toBe(canonical(c.input!))
        // Haus.Any is the value without the envelope.
        expectJson(yield* Haus.toJsonValue(Haus.Any)(c.input!), valueOf(c.json))
        expect(canonical(yield* Haus.fromJson(Haus.Any)(valueOf(c.json)))).toBe(canonical(c.input!))
      }))
  }
})

describe("import (spec §16.1)", () => {
  for (const c of cases(read("json/import.cases.haus"))) {
    it.effect(c.name, () =>
      Effect.gen(function* () {
        if (c.kind === "Err") return fails(Haus.importJson(c.json), c)
        expect(canonical(yield* Haus.importJson(c.json))).toBe(canonical(c.output!))
      }))
  }
})

describe("valid/NAME.jsonl as self-describing cases", () => {
  const names = readdirSync(`${SUITE}valid`).filter((f) => f.endsWith(".haus")).map((f) => f.slice(0, -".haus".length)).sort()
  for (const name of names) {
    it.effect(name, () =>
      Effect.gen(function* () {
        const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(readFileSync(`${SUITE}valid/${name}.haus`))
        const values = parseAll(text)
        const lines = read(`valid/${name}.jsonl`).split("\n").filter((l) => l !== "")
        expect(lines).toHaveLength(values.length)
        for (const [i, value] of values.entries()) {
          expectJson(parseJson(yield* Haus.toHausJson(value), { maxDepth: 2000 }), lines[i]!)
          expect(canonical(yield* Haus.fromHausJson(lines[i]!))).toBe(canonical(value))
        }
      }))
  }
})
