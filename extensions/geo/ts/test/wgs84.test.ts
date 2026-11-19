import { compileSchemaFile, parseAll } from "@haus-fmt/haus"
import { nodeResolver, schemaOptions } from "@haus-fmt/haus/node"
import * as h from "@haus-fmt/haus/schema"
import * as Haus from "@haus-fmt/effect"
import { Effect, Exit, Schema } from "effect"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, expectTypeOf, it } from "vitest"
import { BBox, LatLng, wgs84 } from "../src/index.js"
import { wgs84 as wgs84Effect } from "../src/effect.js"

const root = join(import.meta.dirname, "../..")
const schemaPath = join(root, "schema.haus")
const text = readFileSync(schemaPath, "utf8")

// ── the vectors (profiles/wgs84.vectors.haus) ──

const Vector = h.Variant({
  Accept: h.Record({ type: h.String, value: h.String, output: h.Optional(h.String), note: h.Optional(h.String) }),
  Reject: h.Record({ type: h.String, value: h.String, note: h.Optional(h.String) }),
})
const vectors = parseAll(readFileSync(join(root, "profiles/wgs84.vectors.haus"), "utf8")).map((v) => h.decode(Vector, v))
const name = (v: h.Infer<typeof Vector>) => `${v._tag} ${v.type} ${v.value}${v.note ? ` (${v.note})` : ""}`

/**
 * The value's text in the one spelling of its type (spec §15), decoded with
 * the schema alone: `38.80` is the float 38.8, written `38.8`.
 */
const base = compileSchemaFile(text, schemaOptions(schemaPath)).schemas
const normal = (type: string, value: string) => h.stringify(base[type]!, h.parse(base[type]!, value), { style: "compact" })

describe("the wgs84 vectors", () => {
  it("are read", () => {
    expect(vectors.some((v) => v._tag === "Accept") && vectors.some((v) => v._tag === "Reject")).toBe(true)
  })

  describe("with haus schemas", () => {
    const coded = compileSchemaFile(text, { ...schemaOptions(schemaPath), codecs: wgs84 }).schemas
    for (const v of vectors) {
      it(name(v), () => {
        const schema = coded[v.type]!
        // Every vector is valid under the schema: what a codec rejects, the profile rejects.
        expect(() => h.parse(base[v.type]!, v.value)).not.toThrow()
        if (v._tag === "Reject") {
          expect(() => h.parse(schema, v.value)).toThrow(h.HausDecodeError)
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
        const exit = Effect.runSyncExit(Haus.decode(schema, wgs84Effect)(v.value))
        if (v._tag === "Reject") {
          expect(Exit.isFailure(exit)).toBe(true)
          return
        }
        const decoded = Effect.runSync(Haus.decode(schema, wgs84Effect)(v.value))
        const encoded = Effect.runSync(Haus.encode(schema, wgs84Effect)(decoded, { style: "compact" }))
        expect(encoded).toBe(normal(v.type, v.output ?? v.value))
        expect(encoded).toBe(normal(v.type, v.value))
        expect(Effect.runSync(Haus.decode(schema, wgs84Effect)(encoded))).toEqual(decoded)
      })
    }
  })
})

// ── the rule's edge cases ──

const resolver = nodeResolver({ packages: { "@haus-fmt/geo": root } })
const trip = `import @haus-fmt/geo (LatLng, BBox)\ntype Trip = { to: LatLng, area: BBox }`
const at = (p: string, area = "BBox(LatLng(0, 0), LatLng(1, 1))") => `{ to: ${p}, area: ${area} }`

/** The edge cases, for both bindings: `ok` decodes (and encodes back to `out`, default itself), `bad` doesn't. */
const accepted: ReadonlyArray<readonly [string, string?]> = [
  // Rounding: checked on the decoded float.
  [at("LatLng(90.00000000000000001, 0)"), at("LatLng(90, 0)")],
  [at("LatLng(-90.00000000000000001, 180.00000000000000001)"), at("LatLng(-90, 180)")],
  // Negative zero is kept, in either position and in a box.
  [at("LatLng(-0, -0)")],
  [at("LatLng(0, 0)", "BBox(LatLng(-0, -0), LatLng(0, 0))")],
  // The poles and the antimeridian are not normalised.
  [at("LatLng(90, 10)")],
  [at("LatLng(0, -180)")],
  [at("LatLng(0, 180)")],
  // Boxes across the antimeridian, and from -180 to 180.
  [at("LatLng(0, 0)", "BBox(LatLng(0, 170), LatLng(10, -170))")],
  [at("LatLng(0, 0)", "BBox(LatLng(-10, 180), LatLng(10, -180))")],
  [at("LatLng(0, 0)", "BBox(LatLng(-90, -180), LatLng(90, 180))")],
]
const rejected: readonly string[] = [
  at("LatLng(90.0000000000001, 0)"),
  at("LatLng(0, -180.0000000000001)"),
  at("LatLng(Infinity, 0)"),
  at("LatLng(NegInfinity, 0)"),
  at("LatLng(0, Infinity)"),
  at("LatLng(0, NegInfinity)"),
  at("LatLng(NaN, NaN)"),
  at("LatLng(0, 0)", "BBox(LatLng(1, 0), LatLng(-1, 0))"),
  at("LatLng(0, 0)", "BBox(LatLng(0, 0), LatLng(10, 181))"),
  at("LatLng(0, 0)", "BBox(LatLng(NaN, 0), LatLng(10, 0))"),
]

describe("the wgs84 codecs", () => {
  const Trip = compileSchemaFile(trip, { resolver, codecs: wgs84 }).schemas.Trip!

  it("accept the edge cases of the rule and keep the floats", () => {
    for (const [s, out] of accepted) {
      const v = h.parse(Trip, s)
      expect(h.stringify(Trip, v, { style: "compact" }), s).toBe(out ?? s)
    }
    expect(Object.is((h.parse(Trip, at("LatLng(-0, 0)")) as { to: LatLng }).to.values[0], -0)).toBe(true)
  })

  it("reject the rest", () => {
    for (const s of rejected) expect(() => h.parse(Trip, s), s).toThrow(h.HausDecodeError)
    expect(() => h.parse(Trip, at("LatLng(91, 0)"))).toThrow(/latitude 91 out of range/)
    expect(() => h.parse(Trip, at("LatLng(0, 0)", "BBox(LatLng(1, 0), LatLng(-1, 0))"))).toThrow(/south-west corner/)
  })

  it("check what they encode too", () => {
    const point = (lat: number, lng: number): LatLng => ({ _tag: "LatLng", values: [lat, lng] })
    const box: BBox = { _tag: "BBox", values: [point(0, 0), point(1, 1)] }
    expect(() => h.stringify(Trip, { to: point(Infinity, 0), area: box })).toThrow(h.HausEncodeError)
    expect(() => h.stringify(Trip, { to: point(0, 0), area: { _tag: "BBox", values: [point(1, 0), point(0, 0)] } })).toThrow(h.HausEncodeError)
  })

  it("LatLng and BBox as h.* schemas", () => {
    expectTypeOf(h.parse(LatLng, "LatLng(1, 2)")).toEqualTypeOf<LatLng>()
    expect(h.parse(LatLng, "LatLng(38.7223, -9.1393)")).toEqual({ _tag: "LatLng", values: [38.7223, -9.1393] })
    expect(h.stringify(BBox, h.parse(BBox, "BBox(LatLng(0, 170), LatLng(10, -170))"), { style: "compact" })).toBe("BBox(LatLng(0, 170), LatLng(10, -170))")
    expect(() => h.parse(LatLng, "LatLng(NaN, 0)")).toThrow(h.HausDecodeError)
    expect(() => h.parse(BBox, "BBox(LatLng(10, 0), LatLng(0, 1))")).toThrow(h.HausDecodeError)
  })
})

type LatLngOf<C> = Haus.Lookup<C, "@haus-fmt/geo@1#LatLng", { readonly _tag: "LatLng"; readonly values: readonly [number, number] }>
type BBoxOf<C> = Haus.Lookup<C, "@haus-fmt/geo@1#BBox", { readonly _tag: "BBox"; readonly values: readonly [LatLngOf<C>, LatLngOf<C>] }>
type TripOf<C> = { readonly to: LatLngOf<C>; readonly area: BBoxOf<C> }
interface TripF extends Haus.TypeLambda {
  readonly type: TripOf<this["C"]>
}

describe("the Effect codecs", () => {
  // Typed as the content mapper declares it (schemaDeclarations).
  const Trip = Haus.compileSchemaFile(trip, { resolver }).schemas.Trip as unknown as Haus.Named<
    Schema.Codec<TripOf<{}>>,
    "Trip",
    TripF,
    "Trip" | "@haus-fmt/geo@1#LatLng" | "@haus-fmt/geo@1#BBox"
  >
  const decode = Haus.decode(Trip, wgs84Effect)
  const encode = Haus.encode(Trip, wgs84Effect)

  it("accept the edge cases of the rule and keep the floats", () => {
    for (const [s, out] of accepted) {
      const v = Effect.runSync(decode(s))
      expect(Effect.runSync(encode(v, { style: "compact" })), s).toBe(out ?? s)
    }
    expectTypeOf(Effect.runSync(decode(at("LatLng(-0, 0)"))).to).toEqualTypeOf<LatLng>()
    expect(Object.is(Effect.runSync(decode(at("LatLng(-0, 0)"))).to.values[0], -0)).toBe(true)
  })

  it("reject the rest", () => {
    for (const s of rejected) expect(Exit.isFailure(Effect.runSyncExit(decode(s))), s).toBe(true)
    // Without the codecs, the schema takes them.
    expect(Exit.isSuccess(Effect.runSyncExit(Haus.decode(Trip)(at("LatLng(91, 0)"))))).toBe(true)
  })

  it("check what they encode too", () => {
    const point = (lat: number, lng: number): LatLng => ({ _tag: "LatLng", values: [lat, lng] })
    expect(Exit.isFailure(Effect.runSyncExit(encode({ to: point(-Infinity, 0), area: { _tag: "BBox", values: [point(0, 0), point(1, 1)] } })))).toBe(true)
  })
})
