import { compileSchemaFile, parseAll } from "@haus-fmt/haus"
import { nodeResolver, schemaOptions } from "@haus-fmt/haus/node"
import * as h from "@haus-fmt/haus/schema"
import * as Haus from "@haus-fmt/effect"
import { Effect, Exit, Schema } from "effect"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, expectTypeOf, it } from "vitest"
import { Currency, iso, Money, MONEY_ID } from "../src/index.js"
import { iso as isoEffect } from "../src/effect.js"

const root = join(import.meta.dirname, "../..")
const schemaPath = join(root, "schema.haus")
const text = readFileSync(schemaPath, "utf8")

// ── the vectors (profiles/iso.vectors.haus) ──

const Vector = h.Variant({
  Accept: h.Record({ type: h.String, value: h.String, output: h.Optional(h.String), note: h.Optional(h.String) }),
  Reject: h.Record({ type: h.String, value: h.String, note: h.Optional(h.String) }),
})
const vectors = parseAll(readFileSync(join(root, "profiles/iso.vectors.haus"), "utf8")).map((v) => h.decode(Vector, v))
const name = (v: h.Infer<typeof Vector>) => `${v._tag} ${v.type} ${v.value}${v.note ? ` (${v.note})` : ""}`

/** The value's text in the one spelling of its type (spec §15), decoded with the schema alone. */
const base = compileSchemaFile(text, schemaOptions(schemaPath)).schemas
const normal = (type: string, value: string) => h.stringify(base[type]!, h.parse(base[type]!, value), { style: "compact" })

describe("the iso vectors", () => {
  it("are read", () => {
    expect(vectors.some((v) => v._tag === "Accept") && vectors.some((v) => v._tag === "Reject")).toBe(true)
  })

  describe("with haus schemas", () => {
    const coded = compileSchemaFile(text, { ...schemaOptions(schemaPath), codecs: iso }).schemas
    for (const v of vectors) {
      it(name(v), () => {
        const schema = coded[v.type]!
        // Every vector is valid under the schema: what a codec rejects, the profile rejects.
        expect(() => h.parse(base[v.type]!, v.value)).not.toThrow()
        if (v._tag === "Reject") {
          // The schema accepts it and the profile's codec doesn't (spec §13.4, §17).
          expect(() => h.parse(schema, v.value)).toThrow(expect.objectContaining({ name: "HausDecodeError", code: "codec-rejected" }))
          return
        }
        const decoded = h.parse(schema, v.value)
        const encoded = h.stringify(schema, decoded, { style: "compact" })
        expect(encoded).toBe(normal(v.type, v.output ?? v.value))
        // The codec changes no value: it writes what the schema alone decodes; decode, encode, decode is decode.
        expect(encoded).toBe(normal(v.type, v.value))
        expect(h.parse(schema, encoded)).toEqual(decoded)
      })
    }
  })

  describe("with Effect", () => {
    const schemas = Haus.compileSchemaFile(text, schemaOptions(schemaPath)).schemas
    for (const v of vectors) {
      it(name(v), () => {
        const schema = schemas[v.type]!
        const exit = Effect.runSyncExit(Haus.decode(schema, isoEffect)(v.value))
        if (v._tag === "Reject") {
          expect(Exit.isFailure(exit)).toBe(true)
          expect(Effect.runSync(Effect.flip(Haus.decode(schema, isoEffect)(v.value)))).toMatchObject({ code: "codec-rejected" })
          return
        }
        const decoded = Effect.runSync(Haus.decode(schema, isoEffect)(v.value))
        const encoded = Effect.runSync(Haus.encode(schema, isoEffect)(decoded, { style: "compact" }))
        expect(encoded).toBe(normal(v.type, v.output ?? v.value))
        expect(encoded).toBe(normal(v.type, v.value))
        expect(Effect.runSync(Haus.decode(schema, isoEffect)(encoded))).toEqual(decoded)
      })
    }
  })
})

// ── the rule's edge cases ──

const resolver = nodeResolver({ packages: { "@haus-fmt/money": root } })
const order = `import @haus-fmt/money (Money)\ntype Order = { total: Money, refunds: Array Money }`

describe("the iso codec", () => {
  const Order = compileSchemaFile(order, { resolver, codecs: iso }).schemas.Order!
  const decode = (s: string) => h.parse(Order, s)

  it("keeps the amount exactly: scale, sign, exponent, -0", () => {
    for (const amount of ["19.90", "-3", "0.00005", "1.5e3", "15e2", "-0", "-0.00"]) {
      const s = `{ total: Money(${amount}, EUR), refunds: [] }`
      expect(h.stringify(Order, decode(s), { style: "compact" })).toBe(s)
    }
  })

  it("applies inside imported types: the Money of another schema", () => {
    expect(() => decode(`{ total: Money(1, EUR), refunds: [Money(1, Usd)] }`)).toThrow(/"Usd" is not a currency of the iso profile/)
    expect(() => decode(`{ total: Money(1, EUR), refunds: [Money(1, USD)] }`)).not.toThrow()
  })

  it("rejects what isn't three letters A–Z, without payload", () => {
    for (const c of ["Eur", "EURO", "EU", "E1R", "EUR(1)", "EUR { x: 1 }", "E_R"]) {
      expect(() => decode(`{ total: Money(1, ${c}), refunds: [] }`), c).toThrow(h.HausDecodeError)
    }
  })

  it("checks what it encodes too", () => {
    expect(() => h.stringify(Order, { total: { _tag: "Money", values: ["1", "eur"] }, refunds: [] })).toThrow(h.HausEncodeError)
  })

  it("Money and Currency as h.* schemas", () => {
    expectTypeOf(h.parse(Money, "Money(19.90, EUR)")).toEqualTypeOf<Money>()
    expect(h.parse(Money, "Money(19.90, EUR)")).toEqual({ _tag: "Money", values: ["19.90", "EUR"] })
    expect(h.parse(Currency, "CHF")).toBe("CHF")
    expect(() => h.parse(Currency, "CHF(1)")).toThrow(h.HausDecodeError)
    expect(() => h.parse(Money, "Money(19.90, Chf)")).toThrow(h.HausDecodeError)
    expect(h.stringify(Money, { _tag: "Money", values: ["19.90", "CHF"] }, { style: "compact" })).toBe("Money(19.90, CHF)")
  })
})

type CurrencyOf<C> = Haus.Lookup<C, "@haus-fmt/money@1#Currency", string | Haus.Unknown>
type MoneyOf<C> = Haus.Lookup<C, "@haus-fmt/money@1#Money", { readonly _tag: "Money"; readonly values: readonly [string, CurrencyOf<C>] }>
type OrderOf<C> = { readonly total: MoneyOf<C>; readonly refunds: ReadonlyArray<MoneyOf<C>> }
interface OrderF extends Haus.TypeLambda {
  readonly type: OrderOf<this["C"]>
}

describe("the Effect codec", () => {
  // Typed as the content mapper declares it (schemaDeclarations).
  const Order = Haus.compileSchemaFile(order, { resolver }).schemas.Order as unknown as Haus.Named<
    Schema.Codec<OrderOf<{}>>,
    "Order",
    OrderF,
    "Order" | "@haus-fmt/money@1#Money" | "@haus-fmt/money@1#Currency"
  >

  it("narrows the currency to its tag and applies inside imported types", () => {
    const v = Effect.runSync(Haus.decode(Order, isoEffect)(`{ total: Money(19.90, EUR), refunds: [] }`))
    expectTypeOf(v.total.values).toEqualTypeOf<readonly [string, string]>()
    expect(v.total.values).toEqual(["19.90", "EUR"])
    expect(Exit.isFailure(Effect.runSyncExit(Haus.decode(Order, isoEffect)(`{ total: Money(1, EUR), refunds: [Money(1, Usd)] }`)))).toBe(true)
    expect(Exit.isSuccess(Effect.runSyncExit(Haus.decode(Order)(`{ total: Money(1, EUR), refunds: [Money(1, Usd)] }`)))).toBe(true)
  })

  it("checks what it encodes too", () => {
    const bad = { total: { _tag: "Money" as const, values: ["1", "eur"] as const }, refunds: [] }
    expect(Exit.isFailure(Effect.runSyncExit(Haus.encode(Order, isoEffect)(bad)))).toBe(true)
  })
})

// ── several codecs in one value: inside out, the first to reject at its own place (spec §13.4) ──

describe("codecs inside codecs", () => {
  const rejectAll = "no Money passes here"
  const json = (currency: string) => `{"_tag": "Money", "values": ["1", {"_tag": "${currency}"}]}`

  it("haus schemas: the Currency inside a Money rejects first, at $[1]; then the Money's own codec, at $", () => {
    const money = { id: MONEY_ID, apply: (base: h.Schema<unknown>) => h.refine(base, () => rejectAll) }
    const Money = compileSchemaFile(text, { ...schemaOptions(schemaPath), codecs: [money, ...iso] }).schemas.Money!
    expect(() => h.parse(Money, "Money(1, Eur)")).toThrow(expect.objectContaining({ path: [1], reason: expect.stringMatching(/"Eur" is not a currency/) }))
    expect(() => h.parse(Money, "Money(1, EUR)")).toThrow(expect.objectContaining({ path: [], reason: rejectAll }))
    // In JSON, at the place in the JSON (spec §16.3 "Places").
    expect(() => h.fromJson(Money, json("Eur"))).toThrow(expect.objectContaining({ path: ["values", 1], reason: expect.stringMatching(/"Eur" is not a currency/) }))
    expect(() => h.fromJson(Money, json("EUR"))).toThrow(expect.objectContaining({ path: [], reason: rejectAll }))
  })

  it("Effect: the same order and places", () => {
    const money = Haus.codecs({
      [Haus.CodecTypeId]: [{ id: MONEY_ID, apply: (base: Schema.Top) => base.pipe(Schema.refine((_: unknown): _ is never => false, { message: rejectAll })) }],
    })
    const Money = Haus.compileSchemaFile(text, schemaOptions(schemaPath)).schemas.Money!
    const error = (effect: Effect.Effect<unknown, Haus.HausError>) => Effect.runSync(Effect.flip(effect))
    const placeOf = (effect: Effect.Effect<unknown, Haus.HausError>) => {
      const e = error(effect)
      return e instanceof Haus.HausSchemaError ? [e.place, e.message] : [undefined, e.message]
    }
    expect(placeOf(Haus.decode(Money, isoEffect, money)("Money(1, Eur)"))).toEqual(["$[1]", expect.stringMatching(/a currency of the iso profile/)])
    expect(placeOf(Haus.decode(Money, isoEffect, money)("Money(1, EUR)"))).toEqual(["$", rejectAll])
    expect(placeOf(Haus.fromJson(Money, isoEffect, money)(json("Eur")))).toEqual(["$.values[1]", expect.stringMatching(/a currency of the iso profile/)])
    expect(placeOf(Haus.fromJson(Money, isoEffect, money)(json("EUR")))).toEqual(["$", rejectAll])
  })
})
