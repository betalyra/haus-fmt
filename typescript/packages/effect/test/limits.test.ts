/**
 * Limits (spec §7) through the Effect adapter: every decoder takes them with
 * its input, every encoder with its value. Each limit holds at its value and
 * fails just past it, lowered below and raised above the defaults.
 */
import { describe, expect, it } from "@effect/vitest"
import { Effect, Schema, Stream } from "effect"
import { arr, rec, variant, type Value } from "@haus-fmt/haus"
import * as Haus from "../src/index.js"

type Nest = ReadonlyArray<Nest>
const Nest: Schema.Codec<Nest> = Schema.Array(Schema.suspend(() => Nest))

/** `n` levels of arrays, as haus or JSON text. */
const nested = (n: number) => "[".repeat(n) + "]".repeat(n)
/** `n` levels of arrays, as a value built in code. */
const nestedValue = (n: number): Value => Array.from({ length: n - 1 }).reduce<Value>((inner) => arr([inner]), arr([]))
/** `n` levels of arrays, as the decoded type. */
const nestedArray = (n: number): Nest => Array.from({ length: n - 1 }).reduce<Nest>((inner) => [inner], [])

/** How deeply a decoded `Nest` nests. */
const depth = (x: Nest): number => {
  let n = 1
  for (let at = x; at.length > 0; at = at[0]!) n++
  return n
}

const LOWERED = 8
/** Raised as far as the binding supports. */
const RAISED = Haus.MAX_SUPPORTED_DEPTH

/** A text source in two chunks, split inside the value. */
const chunked = (text: string) => Stream.make(text.slice(0, 3), text.slice(3))

describe("haus text", () => {
  it.effect("the default depth is 256 levels", () =>
    Effect.gen(function* () {
      expect(depth(yield* Haus.decode(Nest)(nested(256)))).toBe(256)
      const e = yield* Effect.flip(Haus.decode(Nest)(nested(257)))
      expect(e._tag).toBe("HausParseError")
      expect(e.message).toContain("nesting deeper than 256 levels")
    }))

  it.effect("a lowered maxDepth holds at the limit and fails just past it", () =>
    Effect.gen(function* () {
      expect(depth(yield* Haus.decode(Nest)(nested(LOWERED), { maxDepth: LOWERED }))).toBe(LOWERED)
      const e = yield* Effect.flip(Haus.decode(Nest)(nested(LOWERED + 1), { maxDepth: LOWERED }))
      expect(e._tag).toBe("HausParseError")
      expect(e.message).toContain(`nesting deeper than ${LOWERED} levels`)
    }))

  it.effect("a raised maxDepth decodes values deeper than the default, and fails just past it", () =>
    Effect.gen(function* () {
      expect(depth(yield* Haus.decode(Nest)(nested(RAISED), { maxDepth: RAISED }))).toBe(RAISED)
      expect((yield* Haus.decode(Haus.Any)(nested(RAISED), { maxDepth: RAISED })).kind).toBe("array")
      const e = yield* Effect.flip(Haus.decode(Nest)(nested(RAISED + 1), { maxDepth: RAISED }))
      expect(e.message).toContain(`nesting deeper than ${RAISED} levels`)
    }))

  it.effect("tagged values count as the parser counts them: `Tag { … }` is one level, `Tag(…)` one", () =>
    Effect.gen(function* () {
      interface Box { readonly _tag: "Box"; readonly inner: ReadonlyArray<Box> }
      const Box: Schema.Codec<Box> = Schema.TaggedStruct("Box", { inner: Schema.Array(Schema.suspend(() => Box)) })
      const boxes = (n: number) => "Box { inner: [".repeat(n - 1) + "Box { inner: [] }" + "] }".repeat(n - 1)
      // n boxes: n records and n arrays.
      yield* Haus.decode(Box)(boxes(4), { maxDepth: 8 })
      expect((yield* Effect.flip(Haus.decode(Box)(boxes(4), { maxDepth: 7 }))).message).toContain("nesting deeper than 7 levels")
      // The same value built in code counts the same.
      const value = yield* Haus.encodeValue(Box)(yield* Haus.decode(Box)(boxes(4)), { maxDepth: 8 })
      expect((yield* Effect.flip(Haus.decodeValue(Box)(value, { maxDepth: 7 }))).message).toContain("nested deeper than 7 levels")
      expect((yield* Effect.flip(Haus.encodeValue(Box)(yield* Haus.decodeValue(Box)(value), { maxDepth: 7 }))).message)
        .toContain("nested deeper than 7 levels")
      const somes = (n: number) => "Some(".repeat(n) + "1" + ")".repeat(n)
      yield* Haus.decode(Haus.Any)(somes(LOWERED), { maxDepth: LOWERED })
      yield* Effect.flip(Haus.decode(Haus.Any)(somes(LOWERED + 1), { maxDepth: LOWERED }))
    }))

  it.effect("the other limits of the parser pass through", () =>
    Effect.gen(function* () {
      const S = Schema.Struct({ s: Schema.String, n: Haus.Decimal })
      yield* Haus.decode(S)(`{ s: "abcd", n: 1234 }`, { maxStringLength: 4, maxNumberLength: 4 })
      expect((yield* Effect.flip(Haus.decode(S)(`{ s: "abcde", n: 1 }`, { maxStringLength: 4 }))).message).toContain("longer than 4")
      expect((yield* Effect.flip(Haus.decode(S)(`{ s: "", n: 12345 }`, { maxNumberLength: 4 }))).message).toContain("number literal longer than 4")
      yield* Haus.decode(S)(`{ s: "", n: 1e10 }`, { maxExponent: 10 })
      expect((yield* Effect.flip(Haus.decode(S)(`{ s: "", n: 1e11 }`, { maxExponent: 10 })))._tag).toBe("HausParseError")
    }))

  it.effect("the string limit counts record keys and tags too, in text and in raw values built in code", () =>
    Effect.gen(function* () {
      const four = { maxStringLength: 4 }
      yield* Haus.decode(Haus.Any)("{ abcd: Abcd(1) }", four)
      for (const [text, reason] of [["{ abcde: 1 }", "key longer than 4 characters"], ["[Abcde]", "tag longer than 4 characters"]] as const) {
        const e = yield* Effect.flip(Haus.decode(Haus.Any)(text, four))
        expect(e._tag).toBe("HausParseError")
        expect(e.message).toContain(reason)
      }
      const S = Schema.Struct({ m: Schema.Record(Schema.String, Schema.Finite) })
      expect((yield* Effect.flip(Haus.decode(S)("{ m: { abcde: 1 } }", four))).message).toContain("key longer than 4 characters")
      const encode = Haus.encode(Haus.Any, { style: "compact", limits: four })
      expect(yield* encode(variant("Abcd", [rec(new Map([["abcd", arr([])]]))]))).toBe("Abcd { abcd: [] }")
      for (const [value, reason] of [[rec(new Map([["abcde", arr([])]])), "key longer than 4"], [arr([variant("Abcde")]), "tag longer than 4"]] as const) {
        const e = yield* Effect.flip(encode(value))
        expect(e._tag).toBe("HausSchemaError")
        expect(e.message).toContain(reason)
      }
    }))

  it.effect("maxSteps bounds the conversion", () =>
    Effect.gen(function* () {
      const text = `[${Array.from({ length: 100 }, () => "[]").join(", ")}]`
      yield* Haus.decode(Nest)(text)
      const e = yield* Effect.flip(Haus.decode(Nest)(text, { maxSteps: 50 }))
      expect(e._tag).toBe("HausSchemaError")
      expect(e.message).toContain("budget of 50 steps")
    }))
})

describe("values built in code", () => {
  it.effect("decodeValue holds a value to maxDepth, at the default, lowered and raised", () =>
    Effect.gen(function* () {
      const decode = Haus.decodeValue(Nest)
      for (const [limit, limits] of [[256, {}], [LOWERED, { maxDepth: LOWERED }], [RAISED, { maxDepth: RAISED }]] as const) {
        expect(depth(yield* decode(nestedValue(limit), limits))).toBe(limit)
        const e = yield* Effect.flip(decode(nestedValue(limit + 1), limits))
        expect(e.message).toContain(`nested deeper than ${limit} levels`)
      }
    }))
})

describe("streams", () => {
  it.effect("decodeStream takes limits with the source: each value within them", () =>
    Effect.gen(function* () {
      const decode = Haus.decodeStream(Nest)
      const values = yield* Stream.runCollect(decode(chunked(`${nested(LOWERED)},\n${nested(2)},\n`), { maxDepth: LOWERED }))
      expect(values.map(depth)).toEqual([LOWERED, 2])
      const e = yield* Effect.flip(Stream.runCollect(decode(chunked(`${nested(2)},\n${nested(LOWERED + 1)},\n`), { maxDepth: LOWERED })))
      expect(e._tag).toBe("HausParseError")
      expect(e.message).toContain(`nesting deeper than ${LOWERED} levels`)
    }))

  it.effect("decodeStream with a raised maxDepth, from an async iterable too", () =>
    Effect.gen(function* () {
      const decode = Haus.decodeStream(Nest)
      async function* source(text: string) {
        yield text
      }
      expect((yield* Stream.runCollect(decode(source(`${nested(RAISED)},`), { maxDepth: RAISED }))).map(depth)).toEqual([RAISED])
      expect((yield* Effect.flip(Stream.runCollect(decode(source(`${nested(RAISED + 1)},`), { maxDepth: RAISED }))))._tag).toBe("HausParseError")
      // Without limits, the default.
      expect((yield* Effect.flip(Stream.runCollect(decode(source(`${nested(257)},`)))))._tag).toBe("HausParseError")
    }))

  it.effect("encodeStream takes limits with the values", () =>
    Effect.gen(function* () {
      const encode = Haus.encodeStream(Nest)
      const out = yield* Stream.runCollect(encode(Stream.make(nestedArray(RAISED)), { limits: { maxDepth: RAISED } }))
      expect(out.join("")).toBe(`${nested(RAISED)},\n`)
      const e = yield* Effect.flip(Stream.runCollect(encode(Stream.make(nestedArray(LOWERED + 1)), { limits: { maxDepth: LOWERED } })))
      expect(e.message).toContain(`nested deeper than ${LOWERED} levels`)
      expect(e._tag === "HausSchemaError" && e.index).toBe(0)
    }))
})

describe("encoding", () => {
  it.effect("encode holds the value to maxDepth, so that the parser reads it again", () =>
    Effect.gen(function* () {
      const encode = Haus.encode(Nest)
      expect(yield* encode(nestedArray(256), { style: "compact" })).toBe(nested(256))
      expect((yield* Effect.flip(encode(nestedArray(257)))).message).toContain("nested deeper than 256 levels")
      expect(yield* encode(nestedArray(LOWERED), { style: "compact", limits: { maxDepth: LOWERED } })).toBe(nested(LOWERED))
      expect((yield* Effect.flip(encode(nestedArray(LOWERED + 1), { limits: { maxDepth: LOWERED } }))).message)
        .toContain(`nested deeper than ${LOWERED} levels`)
      expect(yield* encode(nestedArray(RAISED), { style: "compact", limits: { maxDepth: RAISED } })).toBe(nested(RAISED))
      expect((yield* Effect.flip(encode(nestedArray(RAISED + 1), { limits: { maxDepth: RAISED } }))).message)
        .toContain(`nested deeper than ${RAISED} levels`)
    }))

  it.effect("limits given when building the encoder are defaults, merged with the call's", () =>
    Effect.gen(function* () {
      const encode = Haus.encode(Nest, { style: "compact", limits: { maxDepth: LOWERED } })
      expect(yield* encode(nestedArray(LOWERED))).toBe(nested(LOWERED))
      yield* Effect.flip(encode(nestedArray(LOWERED + 1)))
      expect(yield* encode(nestedArray(LOWERED + 1), { limits: { maxDepth: LOWERED + 1 } })).toBe(nested(LOWERED + 1))
    }))

  it.effect("a value decoded with raised limits encodes again with them (Haus.Any included)", () =>
    Effect.gen(function* () {
      const limits = { maxDepth: RAISED }
      const any = yield* Haus.decode(Haus.Any)(nested(RAISED), limits)
      expect(yield* Haus.encode(Haus.Any)(any, { style: "compact", limits })).toBe(nested(RAISED))
      // Within the defaults, the raw value is too deep.
      expect((yield* Effect.flip(Haus.encode(Haus.Any)(any)))._tag).toBe("HausSchemaError")
      const value = yield* Haus.encodeValue(Nest)(nestedArray(RAISED), limits)
      expect(depth(yield* Haus.decodeValue(Nest)(value, limits))).toBe(RAISED)
    }))

  it.effect("a decimal's number limits apply when encoding", () =>
    Effect.gen(function* () {
      const S = Schema.Struct({ n: Haus.Decimal })
      expect(yield* Haus.encode(S)({ n: "12345" }, { style: "compact", limits: { maxNumberLength: 5 } })).toBe("{ n: 12345 }")
      expect((yield* Effect.flip(Haus.encode(S)({ n: "123456" }, { limits: { maxNumberLength: 5 } })))._tag).toBe("HausSchemaError")
    }))
})

describe("JSON", () => {
  it.effect("fromJson: the default, lowered and raised maxDepth hold at the limit and fail just past it", () =>
    Effect.gen(function* () {
      const fromJson = Haus.fromJson(Nest)
      for (const [limit, limits] of [[256, {}], [LOWERED, { maxDepth: LOWERED }], [RAISED, { maxDepth: RAISED }]] as const) {
        expect(depth(yield* fromJson(nested(limit), limits))).toBe(limit)
        const e = yield* Effect.flip(fromJson(nested(limit + 1), limits))
        expect(e._tag).toBe("HausSchemaError")
        expect(e.message).toContain(`deeper than ${limit} levels`)
      }
    }))

  it.effect("fromJson reads JSON up to jsonDepth(maxDepth) levels (spec §16); deeper is a parse error", () =>
    Effect.gen(function* () {
      const limit = LOWERED
      const json = (n: number) => "[".repeat(n) + "1" + "]".repeat(n)
      // Within jsonDepth(8) = 33 levels the reader accepts it; the value is then too deep.
      expect((yield* Effect.flip(Haus.fromJson(Schema.Unknown)(json(33), { maxDepth: limit })))._tag).toBe("HausSchemaError")
      const e = yield* Effect.flip(Haus.fromJson(Schema.Unknown)(json(34), { maxDepth: limit }))
      expect(e._tag).toBe("HausParseError")
      expect(e.message).toContain("nesting deeper than 33 levels")
    }))

  it.effect("decodeJsonLines takes limits with the source, per line", () =>
    Effect.gen(function* () {
      const decode = Haus.decodeJsonLines(Nest)
      for (const limit of [LOWERED, RAISED]) {
        const lines = yield* Stream.runCollect(decode(chunked(`${nested(limit)}\n${nested(1)}\n`), { maxDepth: limit }))
        expect(lines.map(depth)).toEqual([limit, 1])
        const e = yield* Effect.flip(Stream.runCollect(decode(chunked(`${nested(1)}\n${nested(limit + 1)}\n`), { maxDepth: limit })))
        expect(e.message).toContain(`deeper than ${limit} levels`)
        expect(e._tag === "HausSchemaError" && e.index).toBe(1)
      }
      // Without limits, the default.
      expect((yield* Effect.flip(Stream.runCollect(decode(chunked(`${nested(257)}\n`)))))._tag).toBe("HausSchemaError")
    }))

  it.effect("toJson, toJsonValue and encodeJsonLines take limits with the value", () =>
    Effect.gen(function* () {
      const limits = { maxDepth: RAISED }
      expect(yield* Haus.toJson(Nest)(nestedArray(RAISED), limits)).toBe(nested(RAISED))
      expect((yield* Effect.flip(Haus.toJson(Nest)(nestedArray(RAISED + 1), limits))).message).toContain(`deeper than ${RAISED} levels`)
      expect((yield* Effect.flip(Haus.toJsonValue(Nest)(nestedArray(LOWERED + 1), { maxDepth: LOWERED }))).message)
        .toContain(`deeper than ${LOWERED} levels`)
      const lines = yield* Stream.runCollect(Haus.encodeJsonLines(Nest)(Stream.make(nestedArray(RAISED)), limits))
      expect(lines).toEqual([`${nested(RAISED)}\n`])
      expect(yield* Effect.flip(Stream.runCollect(Haus.encodeJsonLines(Nest)(Stream.make(nestedArray(257)))))).toBeInstanceOf(Haus.HausSchemaError)
    }))

  it.effect("importJson, toHausJson and fromHausJson take limits", () =>
    Effect.gen(function* () {
      expect((yield* Haus.importJson(nested(RAISED), { maxDepth: RAISED })).kind).toBe("array")
      expect((yield* Effect.flip(Haus.importJson(nested(LOWERED + 1), { maxDepth: LOWERED })))._tag).toBe("HausParseError")
      const deep = yield* Haus.importJson(nested(RAISED), { maxDepth: RAISED })
      const json = yield* Haus.toHausJson(deep, { maxDepth: RAISED })
      expect((yield* Haus.fromHausJson(json, { maxDepth: RAISED })).kind).toBe("array")
      expect((yield* Effect.flip(Haus.toHausJson(deep, { maxDepth: LOWERED })))._tag).toBe("HausSchemaError")
      // 512 JSON levels are beyond hausJsonDepth(8) = 34: the reader stops them.
      expect((yield* Effect.flip(Haus.fromHausJson(json, { maxDepth: LOWERED })))._tag).toBe("HausParseError")
    }))

  it.effect("lengths count on the resulting value, not the JSON text (spec §16, Limits)", () =>
    Effect.gen(function* () {
      const four = { maxStringLength: 4 }
      // `é` is six JSON characters and one haus character.
      const escaped = (n: number) => `"${"\\u00e9".repeat(n)}"`
      expect(yield* Haus.fromJson(Schema.String)(escaped(4), four)).toBe("éééé")
      expect(yield* Stream.runCollect(Haus.decodeJsonLines(Schema.String)(chunked(`${escaped(4)}\n`), four))).toEqual(["éééé"])
      const long = yield* Effect.flip(Haus.fromJson(Schema.String)(escaped(5), four))
      expect([long._tag, long.code]).toEqual(["HausSchemaError", "string-too-long"])
      // Bytes: two characters per byte. With 8, 4 bytes are accepted; 5 are not, though "AAECAwQ=" is 8 JSON characters.
      const eight = { maxStringLength: 8 }
      expect(yield* Haus.fromJson(Schema.Uint8Array)('"AAECAw=="', eight)).toEqual(new Uint8Array([0, 1, 2, 3]))
      const bytes = yield* Effect.flip(Haus.fromJson(Schema.Uint8Array)('"AAECAwQ="', eight))
      expect([bytes._tag, bytes.code]).toEqual(["HausSchemaError", "string-too-long"])
      // Keys and tags as haus keys and tags; escapes read.
      expect((yield* Haus.importJson(`{"\\u0061bcd": []}`, four)).kind).toBe("record")
      expect((yield* Effect.flip(Haus.importJson(`{"\\u0061bcde": []}`, four))).code).toBe("key-too-long")
      expect((yield* Effect.flip(Haus.fromHausJson(`{"_haus": 1, "_value": {"_tag": "Abcde"}}`, four))).code).toBe("tag-too-long")
    }))
})

describe("the deepest nesting the binding supports (spec §7)", () => {
  const MAX = Haus.MAX_SUPPORTED_DEPTH
  const limits = { maxDepth: MAX }

  interface Box { readonly _tag: "Box"; readonly inner: ReadonlyArray<Box> }
  const Box: Schema.Codec<Box> = Schema.TaggedStruct("Box", { inner: Schema.Array(Schema.suspend(() => Box)) })
  /** `n` boxes: 2n levels (a `Box { … }` and its array). */
  const boxes = (n: number): Box => Array.from({ length: n - 1 }).reduce<Box>((inner) => ({ _tag: "Box", inner: [inner] }), { _tag: "Box", inner: [] })
  const boxText = (n: number) => "Box { inner: [".repeat(n - 1) + "Box { inner: [] }" + "] }".repeat(n - 1)
  /** `n` levels of `T { a: … }`: four JSON levels each in self-describing JSON. */
  const tagged = (n: number) => "T { a: ".repeat(n) + "1" + " }".repeat(n)

  it("is 512", () => {
    expect(MAX).toBe(512)
  })

  it.effect("every decoder and encoder works at it, with Struct-based recursive schemas too", () =>
    Effect.gen(function* () {
      expect(depth(yield* Haus.decode(Nest)(nested(MAX), limits))).toBe(MAX)
      const box = yield* Haus.decode(Box)(boxText(MAX / 2), limits)
      const value = yield* Haus.encodeValue(Box)(box, limits)
      expect(yield* Haus.decodeValue(Box)(value, limits)).toEqual(box)
      expect(yield* Haus.encode(Box)(boxes(MAX / 2), { limits })).toBe(yield* Haus.encode(Box)(box, { limits }))
      expect(yield* Haus.encode(Box)(box, { style: "compact", limits })).toBe(boxText(MAX / 2))
      expect((yield* Stream.runCollect(Haus.decodeStream(Box)(chunked(`${boxText(MAX / 2)},`), limits))).length).toBe(1)
      expect((yield* Stream.runCollect(Haus.encodeStream(Box)(Stream.make(box), { limits }))).join("")).toBe(`${boxText(MAX / 2)},\n`)
      const json = yield* Haus.toJson(Box)(box, limits)
      expect(yield* Haus.fromJson(Box)(json, limits)).toEqual(box)
      expect((yield* Stream.runCollect(Haus.decodeJsonLines(Box)(chunked(`${json}\n`), limits)))).toEqual([box])
      expect((yield* Stream.runCollect(Haus.encodeJsonLines(Box)(Stream.make(box), limits)))).toEqual([`${json}\n`])
      expect((yield* Haus.importJson(nested(MAX), limits)).kind).toBe("array")
    }))

  it.effect("Haus.Any at it, in haus and in self-describing JSON (2049 JSON levels, 2050 with the envelope)", () =>
    Effect.gen(function* () {
      const any = yield* Haus.decode(Haus.Any)(tagged(MAX), limits)
      expect(yield* Haus.encode(Haus.Any)(any, { style: "compact", limits })).toBe(tagged(MAX))
      expect((yield* Haus.encode(Haus.Any)(any, { limits })).split("\n")).toHaveLength(2 * MAX + 1)
      const json = yield* Haus.toJson(Haus.Any)(any, limits)
      expect(yield* Haus.encode(Haus.Any)(yield* Haus.fromJson(Haus.Any)(json, limits), { style: "compact", limits })).toBe(tagged(MAX))
      const self = yield* Haus.toHausJson(any, limits)
      expect(yield* Haus.encode(Haus.Any)(yield* Haus.fromHausJson(self, limits), { style: "compact", limits })).toBe(tagged(MAX))
    }))

  it.effect("a larger maxDepth fails with a HausLimitsError naming the maximum, on every entry point", () =>
    Effect.gen(function* () {
      const over = { maxDepth: MAX + 1 }
      const errors = [
        yield* Effect.flip(Haus.decode(Nest)("[]", over)),
        yield* Effect.flip(Haus.decodeValue(Nest)(nestedValue(1), over)),
        yield* Effect.flip(Stream.runCollect(Haus.decodeStream(Nest)(chunked("[],"), over))),
        yield* Effect.flip(Haus.encodeValue(Nest)([], over)),
        yield* Effect.flip(Haus.encode(Nest)([], { limits: over })),
        yield* Effect.flip(Haus.encode(Nest, { limits: over })([])),
        yield* Effect.flip(Stream.runCollect(Haus.encodeStream(Nest)(Stream.make([]), { limits: over }))),
        yield* Effect.flip(Haus.fromJson(Nest)("[]", over)),
        yield* Effect.flip(Haus.fromJsonValue(Nest)([], over)),
        yield* Effect.flip(Haus.toJson(Nest)([], over)),
        yield* Effect.flip(Haus.toJsonValue(Nest)([], over)),
        yield* Effect.flip(Stream.runCollect(Haus.decodeJsonLines(Nest)(chunked("[]\n"), over))),
        yield* Effect.flip(Stream.runCollect(Haus.encodeJsonLines(Nest)(Stream.make([]), over))),
        yield* Effect.flip(Haus.importJson("[]", over)),
        yield* Effect.flip(Haus.toHausJson(arr([]), over)),
        yield* Effect.flip(Haus.fromHausJson(`{"_haus":1,"_value":[]}`, over)),
      ]
      for (const e of errors) {
        expect(e).toBeInstanceOf(Haus.HausLimitsError)
        expect(e.message).toBe("maxDepth 513 is above 512, the deepest nesting this binding supports (spec §7)")
      }
      expect((yield* Effect.flip(Haus.decode(Nest)("[]", { maxDepth: Number.NaN }))).message).toBe("maxDepth must be a whole number from 0 to 512, not NaN")
    }))
})

describe("an empty record, array or payload is a level, built in code as parsed (spec §7)", () => {
  const empty = new Map<string, Value>()
  // Each needs three levels: an empty container innermost.
  const built: ReadonlyArray<readonly [string, Value]> = [
    ["[[[]]]", arr([arr([arr([])])])],
    ["{ a: { b: {} } }", rec(new Map([["a", rec(new Map([["b", rec(empty)]]))]]))],
    ["A(B(C {}))", variant("A", [variant("B", [variant("C", [rec(empty)])])])],
  ]
  for (const [text, value] of built) {
    it(`${text}: decoding and encoding a value built in code count it as parsing does`, () => {
      const code = <A, E extends { readonly code: string }>(effect: Effect.Effect<A, E>) => Effect.runSync(Effect.flip(effect)).code
      expect(code(Haus.decode(Haus.Any)(text, { maxDepth: 2 }))).toBe("nesting-too-deep")
      expect(code(Haus.decodeValue(Haus.Any)(value, { maxDepth: 2 }))).toBe("nesting-too-deep")
      expect(code(Haus.encodeValue(Haus.Any)(value, { maxDepth: 2 }))).toBe("nesting-too-deep")
      expect(code(Haus.toHausJson(value, { maxDepth: 2 }))).toBe("nesting-too-deep")
      expect(Effect.runSync(Haus.decodeValue(Haus.Any)(value, { maxDepth: 3 }))).toBe(value)
    })
  }
  it("a schema's empty array counts too", () => {
    const e = Effect.runSync(Effect.flip(Haus.encodeValue(Nest)(nestedArray(3), { maxDepth: 2 })))
    expect(e.code).toBe("nesting-too-deep")
    expect(Effect.runSync(Haus.encodeValue(Nest)(nestedArray(3), { maxDepth: 3 }))).toEqual(nestedValue(3))
  })
})
