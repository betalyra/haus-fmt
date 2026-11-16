/** Schema-based JSON (spec §16.3) for hand-written Effect schemas, and the forms without a schema. */
import { canonical } from "@haus-fmt/haus"
import { describe, expect, it } from "@effect/vitest"
import { BigDecimal, Effect, Option, Redacted, Schema, Stream } from "effect"
import * as Haus from "../src/index.js"

const Currency = Schema.Literals(["EUR", "USD"])
const Money = Haus.Positional(Schema.TaggedStruct("Money", { amount: Schema.BigDecimal, currency: Currency }))
const Circle = Schema.TaggedStruct("Circle", { r: Schema.Finite })
const Empty = Schema.TaggedStruct("Empty", {})
const Shape = Haus.OpenUnion([Circle, Empty])

const Order = Schema.Struct({
  id: Schema.BigInt,
  total: Money,
  paid: Schema.Boolean,
  note: Schema.Option(Schema.String),
  tracking: Schema.optionalKey(Schema.String),
  tags: Schema.Array(Currency),
  counts: Schema.Record(Schema.String, Schema.BigInt),
  shape: Shape,
  data: Schema.Uint8Array,
  day: Haus.Date,
  key: Schema.Redacted(Schema.String),
})

const order: typeof Order.Type = {
  id: 9007199254740993n,
  total: { _tag: "Money", amount: BigDecimal.fromStringUnsafe("19.90"), currency: "EUR" },
  paid: true,
  note: Option.none(),
  tags: ["USD"],
  counts: { a: 1n },
  shape: { _tag: "Circle", r: 1.5 },
  data: new Uint8Array([0x0b, 0x34]),
  day: "2026-11-13",
  key: Redacted.make("sk-1"),
}

const json = `{"id":"9007199254740993","total":{"_tag":"Money","values":["19.90","EUR"]},"paid":true,"note":null,"tags":["USD"],` +
  `"counts":{"a":"1"},"shape":{"_tag":"Circle","r":1.5},"data":"CzQ=","day":"2026-11-13","key":"sk-1"}`

describe("toJson / fromJson", () => {
  it.effect("writes and reads", () =>
    Effect.gen(function* () {
      expect(yield* Haus.toJson(Order)(order)).toBe(json)
      const back = yield* Haus.fromJson(Order)(json)
      expect(BigDecimal.format(back.total.amount)).toBe("19.9")
      expect(Redacted.value(back.key)).toBe("sk-1")
      expect("tracking" in back).toBe(false)
      expect(yield* Haus.toJson(Order)(back)).toBe(json)
    }))

  it.effect("Option: null, or tagged when its value's JSON can be null", () =>
    Effect.gen(function* () {
      const Nested = Schema.Option(Schema.Option(Schema.Finite))
      expect(yield* Haus.toJson(Nested)(Option.some(Option.none()))).toBe(`{"_tag":"Some","value":null}`)
      expect(yield* Haus.fromJson(Nested)(`{"_tag":"Some","value":5}`)).toEqual(Option.some(Option.some(5)))
    }))

  it.effect("OpenUnion keeps unknown tags with their self-describing arguments", () =>
    Effect.gen(function* () {
      const text = `{"_tag":"Hexagon","_args":[{"_rec":{"side":{"_num":"1"}}}]}`
      const unknown = yield* Haus.fromJson(Shape)(text)
      expect(unknown._tag).toBe("@unknown")
      expect(yield* Haus.toJson(Shape)(unknown)).toBe(text)
      expect(yield* Haus.toJson(Shape)({ _tag: "Empty" })).toBe(`{"_tag":"Empty"}`)
    }))

  it.effect("a recursive schema", () =>
    Effect.gen(function* () {
      interface Tree { readonly name: string; readonly children: ReadonlyArray<Tree> }
      const Tree = Schema.Struct({ name: Schema.String, children: Schema.Array(Schema.suspend((): Schema.Codec<Tree> => Tree)) })
      const tree: Tree = { name: "a", children: [{ name: "b", children: [] }] }
      const text = yield* Haus.toJson(Tree)(tree)
      expect(text).toBe(`{"name":"a","children":[{"name":"b","children":[]}]}`)
      expect(yield* Haus.fromJson(Tree)(text)).toEqual(tree)
    }))

  it.effect("text that isn't I-JSON is a HausParseError, with its position", () =>
    Effect.gen(function* () {
      const error = yield* Haus.fromJson(Order)(`{"id": "1",\n "id": "2"}`).pipe(Effect.flip)
      expect(error._tag).toBe("HausParseError")
      expect(error._tag === "HausParseError" && [error.line, error.column]).toEqual([2, 2])
    }))

  it.effect("JSON that doesn't fit is a HausSchemaError, with its path", () =>
    Effect.gen(function* () {
      const error = yield* Haus.fromJson(Order)(json.replace(`"paid":true`, `"paid":"yes"`)).pipe(Effect.flip)
      expect(error._tag).toBe("HausSchemaError")
      expect(error._tag === "HausSchemaError" && error.path).toEqual(["paid"])
    }))

  it.effect("errors inside a Redacted never show the value", () =>
    Effect.gen(function* () {
      const S = Schema.Struct({ keys: Schema.Redacted(Schema.Record(Schema.String, Schema.BigInt)) })
      const error = yield* Haus.fromJson(S)(`{"keys":{"sk-live-123":12}}`).pipe(Effect.flip)
      expect(error.message).not.toContain("sk-live")
      expect(error._tag === "HausSchemaError" && error.path).toEqual(["keys"])
    }))

  it.effect("a schema without a schema-based form says so", () =>
    Effect.gen(function* () {
      const error = yield* Haus.toJson(Schema.Struct({ x: Schema.Unknown }))({ x: 1 }).pipe(Effect.flip)
      expect(error.message).toContain("has no schema-based JSON form")
    }))

  it.effect("Haus.Any is the self-describing form without the envelope; importJson reads any JSON", () =>
    Effect.gen(function* () {
      const value = yield* Haus.importJson(`{"a": [1.50, true, null]}`)
      const json = `{"_rec":{"a":[{"_num":"1.50"},{"_tag":"True"},{"_tag":"None"}]}}`
      expect(yield* Haus.toJson(Haus.Any)(value)).toBe(json)
      expect(yield* Haus.toHausJson(value)).toBe(`{"_haus":1,"_value":${json}}`)
      expect(canonical(yield* Haus.fromHausJson(`{"_haus":1,"_value":${json}}`))).toBe(canonical(value))
    }))

  it.effect("the caller says which form it reads", () =>
    Effect.gen(function* () {
      const envelope = `{"_haus":1,"_value":"x"}`
      expect(canonical(yield* Haus.importJson(envelope))).toBe(`{_haus:1,_value:"x"}`)
      expect((yield* Effect.flip(Haus.fromJson(Haus.Any)(envelope))).code).toBe("haus-json-form")
      expect((yield* Effect.flip(Haus.fromHausJson(`"x"`))).code).toBe("haus-json-form")
      expect((yield* Effect.flip(Haus.fromHausJson(`{"_haus":2,"_value":"x"}`))).code).toBe("haus-json-version")
      const raw = yield* Effect.flip(Haus.fromHausJson(`{"_haus":1,"_value":"\u{202E}"}`))
      expect([raw._tag, raw.code]).toEqual(["HausParseError", "bidi-control"])
      expect((yield* Effect.flip(Haus.toHausJson({ kind: "variant", tag: "lower", args: [] })))._tag).toBe("HausSchemaError")
    }))
})

describe("JSON Lines", () => {
  const Event = Schema.Union([Circle, Empty])

  it.effect("encodes and decodes a stream, line by line", () =>
    Effect.gen(function* () {
      const lines = yield* Stream.runCollect(Haus.encodeJsonLines(Event)(Stream.fromIterable([{ _tag: "Circle" as const, r: 1 }, { _tag: "Empty" as const }])))
      expect(lines).toEqual([`{"_tag":"Circle","r":1}\n`, `{"_tag":"Empty"}\n`])
      const text = lines.join("")
      const chunks = Stream.fromIterable([text.slice(0, 5), text.slice(5)])
      expect(yield* Stream.runCollect(Haus.decodeJsonLines(Event)(chunks))).toEqual([{ _tag: "Circle", r: 1 }, { _tag: "Empty" }])
    }))

  it.effect("errors carry the line's index", () =>
    Effect.gen(function* () {
      const error = yield* Stream.runCollect(Haus.decodeJsonLines(Event)([`{"_tag":"Empty"}\n{"_tag":"Square"}\n`])).pipe(Effect.flip)
      expect(error._tag === "HausSchemaError" && error.index).toBe(1)
      const syntax = yield* Stream.runCollect(Haus.decodeJsonLines(Event)([`{"_tag":"Empty"}\n{\n`])).pipe(Effect.flip)
      expect(syntax._tag === "HausParseError" && syntax.line).toBe(2)
    }))
})
