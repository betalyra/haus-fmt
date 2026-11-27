/**
 * The API model (packages round): Sources and Package values, Schema.compile,
 * withCodec, typed decoding and encoding with handles, rules on by default,
 * shapeOnly and withRule, secrets and revealSecrets, Results everywhere.
 */
import { describe, expect, expectTypeOf, it } from "vitest"
import {
  Codec, Package, pipe, Prelude, Result, Schema, Secret, Sources, StdTime, Type, type Const, type HausError, type Host, type TypeLambda,
} from "../src/haus.js"
import { Currency, money, Money } from "../src/money.js"
import { LatLng } from "../src/geo.js"
import { compileForTool } from "../src/index.js"

/** The success of a Result, or the test fails with its error. */
const ok = <A>(r: Result<A, HausError>): A => {
  if (r._tag === "Failure") throw new Error(`expected a success: ${r.failure.message}`)
  return r.success
}
const failure = <A>(r: Result<A, HausError>): HausError => {
  if (r._tag === "Success") throw new Error("expected a failure")
  return r.failure
}

const ORDER = `
import @haus-fmt/money (Money)
import std/time (Instant)
type Order = { id: Int, total: Money, placed: Instant, key?: Secret String }
type Log = Stream Order
`

/** Hand-written handles, as @haus-fmt/import declares them. */
type Order<H = {}> = {
  readonly id: Host<H, "prelude#Int", bigint>
  readonly total: Host<H, "@haus-fmt/money@1#Money", Money<H>>
  readonly placed: Host<H, "std/time#Instant", string>
  readonly key?: Secret<Host<H, "prelude#String", string>>
}
interface Order$ extends TypeLambda {
  readonly type: Host<this["hosts"], "order#Order", Order<this["hosts"]>>
}
const Order = Type.make<Order$, "order#Order">("order#Order")
const Log = Type.stream<Order$, "order#Log">("order#Log")

const sources = (text = ORDER) => ok(Sources.make("order.schema.haus", { "order.schema.haus": text }))
const schema = ok(Schema.compile(sources()))
const text = `{ id: 1, total: Money(19.90, EUR), placed: Instant("2026-11-07T10:00:00+01:00") }`

describe("Schema.compile and typed decoding", () => {
  it("decodes with a handle, data-first and data-last, giving Results", () => {
    const order = ok(Schema.decode(schema, Order)(text))
    expectTypeOf(order).toEqualTypeOf<Order>()
    expect(order).toEqual({ id: 1n, total: { _tag: "Money", values: ["19.90", "EUR"] }, placed: "2026-11-07T10:00:00+01:00" })
    expect(ok(Schema.decode(schema, Order, text))).toEqual(order)
    expect(ok(pipe(text, Schema.decode(schema, Order)))).toEqual(order)
    expect(failure(Schema.decode(schema, Order)(`{ id: "x" }`)).code).toBe("type-mismatch")
    expect(failure(Schema.decode(schema, Order)(`{`)).code).toBe("unclosed-bracket")
  })

  it("decodes with the official packages' handles and the built-in ones", () => {
    expect(ok(Schema.decode(schema, Money)(`Money(1, USD)`))).toEqual({ _tag: "Money", values: ["1", "USD"] })
    expect(ok(Schema.decode(schema, Prelude.Decimal)(`1.50`))).toBe("1.50")
    // A handle the schema doesn't have: a mistake of the configuration, without a code.
    expect(failure(Schema.decode(schema, LatLng)(`LatLng(1, 2)`)).code).toBeUndefined()
  })

  it("stream types: every item, each error at $[i]", () => {
    const items = ok(Schema.decode(schema, Log)(`${text},\n${text},\n`))
    expect(items).toHaveLength(2)
    const e = failure(Schema.decode(schema, Log)(`${text},\n{ id: "x" },\n`))
    expect(e.code).toBe("type-mismatch")
    expect("path" in e && e.path[0]).toBe(1)
    expect(ok(Schema.stringify(schema, Log)(items, { style: "compact" }))).toBe(`${text},\n${text},\n`)
  })

  it("encodes and writes back what it decoded; schema-based JSON both ways", () => {
    const order = ok(Schema.decode(schema, Order)(text))
    expect(ok(Schema.stringify(schema, Order)(order, { style: "compact" }))).toBe(text)
    const json = ok(Schema.toJson(schema, Order)(order))
    // A currency is an open variant's tag (`< >`): `{"_tag": …}` in schema-based JSON (spec §16.3).
    expect(json).toBe(`{"id":"1","total":{"_tag":"Money","values":["19.90",{"_tag":"EUR"}]},"placed":"2026-11-07T10:00:00+01:00"}`)
    expect(ok(Schema.fromJson(schema, Order)(json))).toEqual(order)
    expect(failure(Schema.stringify(schema, Order)(order, { indent: -1 })).code).toBeUndefined()
  })

  it("is a Standard Schema per type", () => {
    const s = Schema.standard(schema, Order)
    expect(s["~standard"].validate(text)).toEqual({ value: expect.objectContaining({ id: 1n }) })
    expect(s["~standard"].validate(`{ id: "x" }`)).toEqual({ issues: [expect.objectContaining({ path: ["id"] })] })
  })
})

describe("package rules, on by default (packages.md §6, §7)", () => {
  it("the built-in rule iso: Money(1, Eur) is codec-rejected, on decoding and encoding", () => {
    const e = failure(Schema.decode(schema, Order)(text.replace("EUR", "Eur")))
    expect(e.code).toBe("codec-rejected")
    expect("path" in e && e.path).toEqual(["total", 1])
    const order = ok(Schema.decode(schema, Order)(text))
    const bad = { ...order, total: { _tag: "Money" as const, values: ["1", "Eur"] as const } }
    expect(failure(Schema.encode(schema, Order)(bad)).code).toBe("cannot-encode")
  })

  it("Package.shapeOnly(money): currencies checked for their shape only", () => {
    const loose = ok(Schema.compile(Sources.withPackage(sources(), Package.shapeOnly(money))))
    expect(ok(Schema.decode(loose, Currency)(`Eur`))).toBe("Eur")
  })

  it("a copy of an official package that differs can't replace it: duplicate-package", () => {
    const copy = ok(Package.make({ manifest: `{ name: "@haus-fmt/money", version: "1.0.0" }`, schema: "type Money = < >" }))
    expect(failure(Schema.compile(Sources.withPackage(sources(), copy))).code).toBe("duplicate-package")
    // The same files are the built-in package.
    expect(ok(Schema.compile(Sources.withPackage(sources(), ok(Package.make({ manifest: money.manifest, schema: money.schema })))))).toBeDefined()
  })

  const codes = (rules = `rules: { "Code": "iso" }`) => ok(Package.make({ manifest: `{ name: "@acme/codes", version: "1.0.0", ${rules} }`, schema: "type Code = < >\ntype Label = String" }))
  const app = (pkg: Package, type = "Code") => Sources.withPackage(ok(Sources.make("app.schema.haus", { "app.schema.haus": `import @acme/codes (${type})\ntype Root = { c: ${type} }` })), pkg)
  const Code = Type.make<Const<string>, "@acme/codes@1#Code">("@acme/codes@1#Code")

  it("a rule the program doesn't implement: missing-codec, naming the type and the rule", () => {
    const e = failure(Schema.compile(app(codes())))
    expect(e.code).toBe("missing-codec")
    expect(e.message).toContain("@acme/codes@1#Code has the rule iso")
    // Not reached: not required.
    expect(ok(Schema.compile(app(codes(), "Label")))).toBeDefined()
  })

  it("withRule supplies it, by name or by handle; shapeOnly opts out", () => {
    const three = (c: string) => (/^[A-Z]{3}$/.test(c) ? Result.succeed(c) : Result.fail("three capitals"))
    const s = ok(Schema.compile(app(ok(Package.withRule(codes(), Code, three)))))
    expect(failure(Schema.decode(s, Code)("Abc")).code).toBe("codec-rejected")
    expect(ok(Schema.decode(s, Code)("ABC"))).toBe("ABC")
    expect(ok(Schema.compile(app(ok(pipe(codes(), Package.withRule("Code", (_: unknown) => Result.succeed(undefined)))))))).toBeDefined()
    expect(ok(Schema.compile(app(Package.shapeOnly(codes()))))).toBeDefined()
    // For a type the manifest gives no rule: a mistake of the configuration.
    expect(failure(Package.withRule(codes(), "Label", () => Result.succeed(undefined))).code).toBeUndefined()
  })

  it("a broken rules field: package-manifest, shape-only or not", () => {
    for (const rules of [`rules: { "Kode": "iso" }`, `rules: "iso"`, `rules: { "Code": ["iso"] }`, `rules: { "Code": "Iso" }`]) {
      expect(failure(Schema.compile(app(Package.shapeOnly(codes(rules))))).code).toBe("package-manifest")
    }
  })

  it("tools: third-party rules unchecked and listed, official ones checked", () => {
    const { schema: s, unchecked } = ok(compileForTool(app(codes())))
    expect(unchecked).toEqual([{ name: "@acme/codes", rules: "Code: iso" }])
    expect(ok(Schema.decode(s, Code)("Abc"))).toBe("Abc")
  })
})

describe("codecs: typed pairs (spec §13.4, packages.md §7)", () => {
  const instantAsDate = Codec.make(StdTime.Instant, {
    decode: (s) => Result.succeed(new Date(s)),
    encode: (d) => (Number.isNaN(d.getTime()) ? Result.fail("an invalid Date") : Result.succeed(d.toISOString())),
  })

  it("change the host type wherever the type is, typed through the schema", () => {
    const withDates = ok(Schema.withCodec(schema, instantAsDate))
    const order = ok(Schema.decode(withDates, Order)(text))
    expectTypeOf(order.placed).toEqualTypeOf<Date>()
    expect(order.placed).toBeInstanceOf(Date)
    expect(ok(Schema.stringify(withDates, Order)(order, { style: "compact" }))).toBe(text.replace("10:00:00+01:00", "09:00:00.000Z"))
    expect(failure(Schema.encode(withDates, Order)({ ...order, placed: new Date(Number.NaN) })).code).toBe("cannot-encode")
    // Data-last in a pipe.
    expect(ok(pipe(Result.succeed(schema), Result.flatMap(Schema.withCodec(instantAsDate))))).toBeDefined()
  })

  it("rules run before codecs: a looser Currency codec doesn't let Money(1, Bitcoin) pass", () => {
    const anyCurrency = Codec.make(Currency, { decode: (c) => Result.succeed(c), encode: (c) => Result.succeed(c) })
    const s = ok(Schema.withCodec(schema, anyCurrency))
    expect(failure(Schema.decode(s, Money)(`Money(1, Bitcoin)`)).code).toBe("codec-rejected")
  })

  it("two for one id, or one for a type that can't have one, are mistakes of the configuration; an id no type has warns", () => {
    const twice = ok(Schema.withCodec(schema, instantAsDate))
    expect(failure(Schema.withCodec(twice, instantAsDate)).message).toContain("two codecs for std/time#Instant")
    const log = Codec.make(Type.make<Const<unknown>, "order#Log">("order#Log"), { decode: Result.succeed, encode: Result.succeed })
    expect(failure(Schema.withCodec(schema, log)).message).toContain("Log is a Stream: set the codec for Order")
    const maybe = Codec.make(Type.make<Const<unknown>, "prelude#Maybe">("prelude#Maybe"), { decode: Result.succeed, encode: Result.succeed })
    expect(failure(Schema.withCodec(schema, maybe)).message).toContain("Maybe has type parameters")
    const other = Codec.make(Type.make<Const<unknown>, "@haus-fmt/money@2#Money">("@haus-fmt/money@2#Money"), { decode: Result.succeed, encode: Result.succeed })
    expect(ok(Schema.withCodec(schema, other)).warnings.map((w) => w.code)).toContain("unused-codec")
    // With typed handles, a stream's codec doesn't compile.
    // @ts-expect-error: a StreamType is no Type
    Codec.make(Log, { decode: Result.succeed, encode: Result.succeed })
  })
})

describe("secrets (spec §15)", () => {
  const keyed = `{ id: 1, total: Money(1, EUR), placed: Instant("2026-11-07T10:00:00Z"), key: "sk-1" }`

  it("decode to a Secret; encoding refuses one unless revealSecrets", () => {
    const order = ok(Schema.decode(schema, Order)(keyed))
    expect(String(order.key)).toBe("<redacted>")
    const e = failure(Schema.encode(schema, Order)(order))
    expect(e.code).toBe("cannot-encode")
    expect("path" in e && e.path).toEqual(["key"])
    expect(e.message).not.toContain("sk-1")
    expect(ok(Schema.stringify(schema, Order)(order, { style: "compact", revealSecrets: true }))).toBe(keyed)
    expect(failure(Schema.toJson(schema, Order)(order)).code).toBe("cannot-encode")
    expect(ok(Schema.toJson(schema, Order)(order, { revealSecrets: true }))).toContain(`"key":"sk-1"`)
  })
})
