/**
 * Limits (spec §7) through the Effect adapter: every decoder takes them with
 * its input, every encoder with its value. Each limit holds at its value and
 * fails just past it, lowered below and raised above the defaults.
 */
import { describe, expect, it } from "@effect/vitest"
import { Effect, Schema, Stream } from "effect"
import { arr, type Value } from "@haus-fmt/haus"
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
const RAISED = 500

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
      expect(e.index).toBe(0)
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

  it.effect("valueFromJson takes limits", () =>
    Effect.gen(function* () {
      expect((yield* Haus.valueFromJson(nested(RAISED), { maxDepth: RAISED })).kind).toBe("array")
      expect((yield* Effect.flip(Haus.valueFromJson(nested(LOWERED + 1), { maxDepth: LOWERED })))._tag).toBe("HausParseError")
    }))
})
