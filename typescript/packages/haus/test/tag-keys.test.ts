/**
 * Keys named `_tag` in data (found by the differential fuzzer, fuzz/README.md).
 * In a map, a record, an `Any` and a payload that doesn't list it, `_tag` is
 * a key like any other; only a payload that lists a field `_tag` can't put
 * its fields beside the tag, and is nested: `{ _tag: "Odd", value: { _tag: 1 } }`.
 */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { canonical, compileSchemaFile, parse, schemaDeclarations } from "../src/index.js"
import * as h from "../src/schema.js"

const repo = join(import.meta.dirname, "../../../..")
const suite = (path: string) => compileSchemaFile(readFileSync(join(repo, path), "utf8")).schemas
const own = (text: string) => compileSchemaFile(text).schemas

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

/** Decode `text` with `schema` and encode it again, canonical. */
const roundTrip = (schema: h.Schema<unknown>, text: string) => canonical(h.encode(schema, h.decode(schema, parse(text))))
/** Write `text` as schema-based JSON, read it back and encode it, canonical. */
const jsonRoundTrip = (schema: h.Schema<unknown>, text: string) => {
  const json = h.toJson(schema, h.decode(schema, parse(text)))
  return { json, back: canonical(h.encode(schema, h.fromJson(schema, json))) }
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
    expect(h.decode(fuzz.NameKeys!, parse(`{_tag:""}`))).toEqual({ _tag: "" })
    expect(h.decode(builtins.Counts!, parse(`{_tag:0}`))).toEqual(new Map([["_tag", 0n]]))
    expect(h.decode(variants.Shape!, parse(`Circle{_tag:0,r:0}`))).toEqual({ _tag: "Circle", r: 0 })
  })

  it("an unlisted _tag in a closed payload is an unexpected field", () => {
    const { V } = own(`type V = < C closed { x: Int } >`)
    expect(() => h.decode(V!, parse(`C{_tag:C,x:0}`))).toThrow(/unexpected field '_tag'/)
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
    expect(h.decode(names.HasOdd!, parse(`{n:1}`))).toEqual({ n: 1 })
    expect(h.toJson(names.HasOdd!, { n: 1 })).toBe(`{"n":1}`)
    expect(h.fromJson(names.HasOdd!, `{"n":1,"odd":{"_tag":"Even"}}`)).toEqual({ n: 1, odd: { _tag: "Even" } })
  })

  it("is nested in value, losslessly", () => {
    const odd = h.decode(names.Odd!, parse(`Odd { _tag: 1, x: "a", y: 2 }`))
    expect(odd).toEqual({ _tag: "Odd", value: { _tag: 1, x: "a" } })
    expect(canonical(h.encode(names.Odd!, odd))).toBe(`Odd{_tag:1,x:"a"}`)
    expect(roundTrip(names.HasOdd!, `{n:1,odd:Odd{_tag:-2}}`)).toBe(`{n:1,odd:Odd{_tag:-2}}`)
  })

  it("has no schema-based JSON form (§16.3)", () => {
    const odd = h.decode(names.HasOdd!, parse(`{n:1,odd:Odd{_tag:1}}`))
    expect(() => h.toJson(names.HasOdd!, odd)).toThrow(/'Odd' has a field named _tag/)
    expect(() => h.fromJson(names.HasOdd!, `{"n":1,"odd":{"_tag":"Odd"}}`)).toThrow(/'Odd' has a field named _tag/)
  })

  it("is declared nested", () => {
    expect(schemaDeclarations(compileSchemaFile(namesText).file))
      .toContain(`type Odd = { readonly _tag: "Odd"; readonly value: { readonly _tag: number; readonly x?: string } } | { readonly _tag: "Even" } | h$.Unknown;`)
  })

  it("h.Variant nests it too, in its type", () => {
    const V = h.Variant({ A: h.Record({ _tag: h.String, n: h.Int32 }), B: h.Record({ n: h.Int32 }) })
    const a: h.Infer<typeof V> = { _tag: "A", value: { _tag: "x", n: 1 } }
    const b: h.Infer<typeof V> = { _tag: "B", n: 2 }
    expect(canonical(h.encode(V, a))).toBe(`A{_tag:"x",n:1}`)
    expect(h.decode(V, parse(`A{_tag:"x",n:1}`))).toEqual(a)
    expect(h.decode(V, parse(`B{n:2}`))).toEqual(b)
  })
})
