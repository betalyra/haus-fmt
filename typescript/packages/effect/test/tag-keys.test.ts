/**
 * Keys named `_tag` in data (found by the differential fuzzer, fuzz/README.md).
 * `_tag` is this package's variant discriminator, but in a map, a record, an
 * `Any` and a payload that doesn't list it, it is a key like any other. A
 * payload that lists a field `_tag` is nested: `{ _tag: "Odd", value: { _tag: 1 } }`.
 */
import { describe, expect, it } from "@effect/vitest"
import { canonical, parse } from "@haus-fmt/haus"
import { Effect, Exit, Redacted, type Schema } from "effect"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import * as Haus from "../src/index.js"

const repo = (path: string) => fileURLToPath(new URL(`../../../../${path}`, import.meta.url))
const own = (text: string) => Haus.compileSchemaFile(text).schemas
const suite = (path: string) => own(readFileSync(repo(path), "utf8"))

// From fuzz/schema/fuzz.schema.haus and fuzz/json/names.schema.haus.
const fuzz = own(`
import std/time (Instant)
type Mixed = closed { list: Array (Maybe Decimal), map: Map (Secret Bytes), result: Result Int (Array String), at?: Instant, any?: Map Any }
type Names = < One { value: Int32 } | Many { values?: Array Int32 } | Pos Int32 >
type NameKeys = { _tag: String, value?: Maybe Int32, args?: Any }
`)
const namesText = `
type Odd = < Odd { _tag: Int32, x?: String } | Even >
type HasOdd = { odd?: Odd, n: Int32 }
`
const names = own(namesText)
const builtins = suite("test-suite/schema/builtins.schema.haus")
const variants = suite("test-suite/schema/variants.schema.haus")
const types = suite("test-suite/schema/types.schema.haus")
const schemaBased = suite("test-suite/json/schema-based.schema.haus")

type Codec = Schema.Codec<unknown>

const run = <A, E>(effect: Effect.Effect<A, E>): A => {
  const exit = Effect.runSyncExit(effect)
  if (Exit.isFailure(exit)) throw new Error(String(exit.cause))
  return exit.value
}
const failure = <A, E>(effect: Effect.Effect<A, E>): string => {
  const exit = Effect.runSyncExit(effect)
  return Exit.isFailure(exit) ? String(exit.cause) : "no error"
}
const decode = (schema: Codec, text: string): any => run(Haus.decodeValue(schema)(parse(text)))
/** Decode `text` with `schema` and encode it again, canonical. */
const roundTrip = (schema: Codec, text: string) => canonical(run(Haus.encodeValue(schema)(decode(schema, text))))
/** Write `text` as schema-based JSON, read it back and encode it, canonical. */
const jsonRoundTrip = (schema: Codec, text: string) => {
  const json = run(Haus.toJson(schema)(decode(schema, text)))
  return { json, back: canonical(run(Haus.encodeValue(schema)(run(Haus.fromJson(schema)(json))))) }
}

describe("keys named _tag", () => {
  it.each([
    ["NameKeys", fuzz.NameKeys, `{_tag:""}`, `{_tag:""}`],
    ["Map Int", builtins.Counts, `{_tag:0}`, `{_tag:0}`],
    ["Map (Secret Bytes)", fuzz.Mixed, `{list:[],map:{_tag:x""},result:Err(0)}`, `{list:[],map:{_tag:x""},result:Err(0)}`],
    ["an unlisted payload field", variants.Shape, `Circle{_tag:0,r:0}`, `Circle{r:0}`],
    ["an unlisted payload field, recursive", types.Expr, `Neg{_tag:x"",of:Num(0)}`, `Neg{of:Num(0)}`],
    ["an unlisted payload field, closed variant", variants.Strict, `C{_tag:Circle,x:0}`, `C{x:0}`],
    ["an unlisted payload field, nothing else", fuzz.Names, `Many{_tag:0}`, `Many{}`],
  ])("%s: %s", (_, schema, input, expected) => {
    expect(roundTrip(schema!, input)).toBe(canonical(parse(expected)))
  })

  it("decode as data", () => {
    expect(decode(fuzz.NameKeys!, `{_tag:""}`)).toEqual({ _tag: "" })
    expect(decode(builtins.Counts!, `{_tag:0}`)).toEqual({ _tag: 0n })
    expect(Redacted.value(decode(fuzz.Mixed!, `{list:[],map:{_tag:x"01"},result:Err(0)}`).map._tag)).toEqual(new Uint8Array([1]))
    expect(decode(variants.Shape!, `Circle{_tag:0,r:0}`)).toEqual({ _tag: "Circle", r: 0 })
    expect(decode(fuzz.Names!, `Many{_tag:0}`)).toEqual({ _tag: "Many" })
  })

  it("encode as data", () => {
    expect(canonical(run(Haus.encodeValue(fuzz.NameKeys!)({ _tag: "x" })))).toBe(`{_tag:"x"}`)
    expect(canonical(run(Haus.encodeValue(builtins.Counts!)({ _tag: 1n, a: 2n })))).toBe(`{_tag:1,a:2}`)
  })

  it("an unlisted _tag in a closed payload is an unexpected field", () => {
    const { V } = own(`type V = < C closed { x: Int } >`)
    expect(failure(Haus.decodeValue(V!)(parse(`C{_tag:C,x:0}`)))).toMatch(/unexpected field "_tag"/)
  })

  it.each([
    ["NameKeys", fuzz.NameKeys, `{_tag:""}`, `{"_tag":""}`],
    ["Map Int32", schemaBased.Counts, `{_tag:0}`, `{"_tag":0}`],
    ["Map Int", builtins.Counts, `{_tag:0}`, `{"_tag":"0"}`],
    ["Map Any", fuzz.Mixed, `{list:[],map:{},result:Err(0),any:{_tag:0}}`, `"any":{"_tag":{"_num":"0"}}`],
  ])("schema-based JSON keeps them: %s", (_, schema, input, json) => {
    const r = jsonRoundTrip(schema!, input)
    expect(r.json).toContain(json)
    expect(r.back).toBe(canonical(parse(input)))
  })
})

describe("a payload field named _tag", () => {
  it("compiles, and types that don't use it work", () => {
    expect(decode(names.HasOdd!, `{n:1}`)).toEqual({ n: 1 })
    expect(run(Haus.toJson(names.HasOdd!)({ n: 1 }))).toBe(`{"n":1}`)
    expect(run(Haus.fromJson(names.HasOdd!)(`{"n":1,"odd":{"_tag":"Even"}}`))).toEqual({ n: 1, odd: { _tag: "Even" } })
  })

  it("is nested in value, losslessly", () => {
    const odd = decode(names.Odd!, `Odd { _tag: 1, x: "a", y: 2 }`)
    expect(odd).toEqual({ _tag: "Odd", value: { _tag: 1, x: "a" } })
    expect(canonical(run(Haus.encodeValue(names.Odd!)(odd)))).toBe(`Odd{_tag:1,x:"a"}`)
    expect(roundTrip(names.HasOdd!, `{n:1,odd:Odd{_tag:-2}}`)).toBe(`{n:1,odd:Odd{_tag:-2}}`)
    expect(failure(Haus.decodeValue(names.Odd!)(parse(`Odd(1)`)))).toMatch(/expected Odd \{ … \}/)
  })

  it("closed: other fields are an error", () => {
    const { V } = own(`type V = < Odd closed { _tag: Int32 } >`)
    expect(decode(V!, `Odd{_tag:1}`)).toEqual({ _tag: "Odd", value: { _tag: 1 } })
    expect(failure(Haus.decodeValue(V!)(parse(`Odd{_tag:1,y:2}`)))).toMatch(/unexpected field "y"/)
  })

  it("has no schema-based JSON form (§16.3)", () => {
    const odd = decode(names.HasOdd!, `{n:1,odd:Odd{_tag:1}}`)
    expect(failure(Haus.toJson(names.HasOdd!)(odd))).toMatch(/'Odd' has a field named _tag/)
    expect(failure(Haus.fromJson(names.HasOdd!)(`{"n":1,"odd":{"_tag":"Odd"}}`))).toMatch(/'Odd' has a field named _tag/)
  })

  it("is declared nested", () => {
    expect(Haus.schemaDeclarations(Haus.compileSchemaFile(namesText).file))
      .toContain(`{ readonly _tag: "Odd"; readonly value: { readonly _tag: Haus$.Lookup<C$, "prelude#Int32", number>; readonly x?: Haus$.Lookup<C$, "prelude#String", string> } } | { readonly _tag: "Even" } | Haus$.Unknown`)
  })
})
