/**
 * Error codes (spec §17) of the Effect adapter: every error has the code the
 * core reports for the same input, a hint, a docs link and the core's JSON form.
 * Hand-written Effect schemas get codes too, from the issues of Effect's decoder.
 */
import { errorJson as coreErrorJson, HausSyntaxError, parse } from "@haus-fmt/haus"
import { describe, expect, it } from "@effect/vitest"
import { Effect, Redacted, Schema, Stream } from "effect"
import * as Haus from "../src/index.js"

/** The code and place of decoding `text` with `schema`. */
const failure = (schema: Schema.Top, text: string) =>
  Effect.gen(function* () {
    const e = yield* Effect.flip(Haus.decode(schema as Schema.Codec<unknown>)(text))
    return e._tag === "HausSchemaError" ? `${e.code} ${e.place ?? "-"}` : `${e.code}`
  })

describe("the errors' codes, hints, docs and JSON form", () => {
  it.effect("a HausParseError has the core's code, hint and JSON form", () =>
    Effect.gen(function* () {
      const e = yield* Effect.flip(Haus.decode(Schema.Boolean)("{ ok: true }"))
      expect(e._tag).toBe("HausParseError")
      const core = (() => {
        try {
          parse("{ ok: true }")
        } catch (x) {
          return x as HausSyntaxError
        }
      })()!
      expect(e.code).toBe("boolean-literal")
      expect(e.hint).toBe(core.hint)
      expect(e.docs).toBe("https://haus-fmt.org/docs/errors#boolean-literal")
      expect(Haus.errorJson(e)).toEqual(coreErrorJson(core))
      expect(JSON.parse(JSON.stringify(e))).toEqual(coreErrorJson(core))
    }))

  it.effect("a HausSchemaError: the message without the place, the place as a path", () =>
    Effect.gen(function* () {
      // A check of Effect's decoder (not the conversion before it), whose message ends in the Effect path.
      const S = Schema.Struct({ items: Schema.Array(Schema.Struct({ qty: Schema.Int })) })
      const e = yield* Effect.flip(Haus.decode(S)(`{ items: [{ qty: 1 }, { qty: 2.5 }] }`))
      expect(e._tag === "HausSchemaError" && e.path).toEqual(["items", 1, "qty"])
      expect(Haus.errorJson(e)).toEqual({
        code: "not-an-integer",
        message: "Expected an integer",
        path: "$.items[1].qty",
        hint: "Write the integer without a fraction or exponent.",
        docs: "https://haus-fmt.org/docs/errors#not-an-integer",
      })
    }))

  it.effect("a HausLimitsError is unsupported-depth", () =>
    Effect.gen(function* () {
      const e = yield* Effect.flip(Haus.decode(Schema.Finite)("1", { maxDepth: 100_000 }))
      expect(e._tag).toBe("HausLimitsError")
      expect(Haus.errorJson(e)).toMatchObject({ code: "unsupported-depth", docs: "https://haus-fmt.org/docs/errors#unsupported-depth" })
    }))

  it.effect("several values where one is expected: not-one-value", () =>
    Effect.gen(function* () {
      expect(yield* failure(Schema.Finite, "1, 2")).toBe("not-one-value -")
    }))

  it.effect("stream errors keep their code and index", () =>
    Effect.gen(function* () {
      const e = yield* Stream.runCollect(Haus.decodeStream(Schema.Finite)(["1, \"x\","])).pipe(Effect.flip)
      expect(e._tag === "HausSchemaError" && [e.code, e.index, e.place]).toEqual(["type-mismatch", 1, "$[1]"])
      expect(Haus.errorJson(e)).toMatchObject({ code: "type-mismatch", path: "$[1]", index: 1 })
      const json = yield* Stream.runCollect(Haus.decodeJsonLines(Schema.Int)(["1\n1.5\n"])).pipe(Effect.flip)
      expect(json._tag === "HausSchemaError" && [json.code, json.index, json.place]).toEqual(["not-an-integer", 1, "$[1]"])
    }))

  it.effect("an error in stream item 3 is at $[3], then its place in the item (spec §15)", () =>
    Effect.gen(function* () {
      const Item = Schema.Struct({ price: Schema.Finite, sizes: Schema.Array(Schema.Finite) })
      const items = `${'{ price: 1, sizes: [] },'.repeat(3)} { price: 2, sizes: [1, "x"] },`
      const e = yield* Stream.runCollect(Haus.decodeStream(Item)([items])).pipe(Effect.flip)
      expect(e._tag === "HausSchemaError" && [e.code, e.index, e.place]).toEqual(["type-mismatch", 3, "$[3].sizes[1]"])
      const lines = `${'{"price":1,"sizes":[]}\n'.repeat(3)}{"price":"2","sizes":[]}\n`
      const json = yield* Stream.runCollect(Haus.decodeJsonLines(Item)([lines])).pipe(Effect.flip)
      expect(json._tag === "HausSchemaError" && [json.code, json.index, json.place]).toEqual(["type-mismatch", 3, "$[3].price"])
      const encoded = yield* Stream.runCollect(Haus.encodeStream(Item)(Stream.make(...Array(3).fill({ price: 1, sizes: [] }), { price: 1, sizes: ["x"] } as never))).pipe(Effect.flip)
      expect(encoded._tag === "HausSchemaError" && [encoded.code, encoded.index, encoded.place]).toEqual(["cannot-encode", 3, "$[3].sizes[0]"])
    }))

  it.effect("invalid UTF-8 in a byte stream is a HausParseError invalid-utf8, without a position", () =>
    Effect.gen(function* () {
      const bytes = (...chunks: number[][]) => chunks.map((c) => Uint8Array.from(c))
      const e = yield* Stream.runCollect(Haus.decodeStream(Schema.Finite)(bytes([0x31, 0x2c], [0x22, 0xff, 0x22, 0x2c]))).pipe(Effect.flip)
      expect(e._tag === "HausParseError" && [e.code, e.line, e.column]).toEqual(["invalid-utf8", undefined, undefined])
      expect(Haus.errorJson(e)).toEqual({
        code: "invalid-utf8",
        message: "invalid UTF-8",
        hint: "Save the file as UTF-8.",
        docs: "https://haus-fmt.org/docs/errors#invalid-utf8",
      })
      // Cut inside a character, and never completed.
      const cut = yield* Stream.runCollect(Haus.decodeStream(Schema.String)(Stream.fromIterable(bytes([0x22, 0xc3], [0x22, 0x2c]))))
        .pipe(Effect.flip)
      expect(cut._tag === "HausParseError" && cut.code).toBe("invalid-utf8")
      const json = yield* Stream.runCollect(Haus.decodeJsonLines(Schema.Finite)(bytes([0x31, 0x0a], [0xed, 0xa0, 0x80, 0x0a]))).pipe(Effect.flip)
      expect(json._tag === "HausParseError" && [json.code, json.line]).toEqual(["invalid-utf8", undefined])
    }))

  it.effect("a value that can't be encoded is cannot-encode", () =>
    Effect.gen(function* () {
      const e = yield* Effect.flip(Haus.encode(Schema.Struct({ n: Schema.Finite }))({ n: "1" } as never))
      expect(e.code).toBe("cannot-encode")
      const big = yield* Effect.flip(Haus.encode(Haus.Float32)(1e39))
      expect(big.code).toBe("cannot-encode")
    }))
})

describe("Effect's issues as codes (as the core decides, spec §17)", () => {
  it.effect.each([
    // Bool, Maybe and closed variants: an unknown tag, a listed tag with another payload, not a tag.
    { schema: Schema.Boolean, text: "Yes", expected: "unknown-tag $" },
    { schema: Schema.Boolean, text: "True(1)", expected: "wrong-payload $" },
    { schema: Schema.Boolean, text: `"True"`, expected: "type-mismatch $" },
    { schema: Schema.Option(Schema.Finite), text: "Just(1)", expected: "unknown-tag $" },
    { schema: Schema.Option(Schema.Finite), text: "Some", expected: "wrong-payload $" },
    { schema: Schema.Option(Schema.Finite), text: "None(1)", expected: "wrong-payload $" },
    { schema: Schema.Option(Schema.Finite), text: `Some("1")`, expected: "type-mismatch $[0]" },
    { schema: Schema.Literals(["Debug", "Info"]), text: "Warn", expected: "unknown-tag $" },
    { schema: Schema.Literals(["Debug", "Info"]), text: "Debug(1)", expected: "wrong-payload $" },
    { schema: Schema.Literals(["Debug", "Info"]), text: `"Debug"`, expected: "type-mismatch $" },
    { schema: Schema.TaggedStruct("Circle", { r: Schema.Finite }), text: "Square", expected: "unknown-tag $" },
    { schema: Schema.TaggedStruct("Circle", { r: Schema.Finite }), text: "Circle(1)", expected: "wrong-payload $" },
    { schema: Schema.TaggedStruct("Circle", { r: Schema.Finite }), text: "Circle", expected: "wrong-payload $" },
    { schema: Schema.TaggedStruct("Circle", { r: Schema.Finite }), text: "Circle {}", expected: "missing-field $" },
    { schema: Schema.TaggedStruct("Circle", { r: Schema.Finite }), text: `Circle { r: "1" }`, expected: "type-mismatch $.r" },
    { schema: Schema.TaggedStruct("Empty", {}), text: "Empty {}", expected: "wrong-payload $" },
    // Numbers: whole numbers by spelling, ranges, floats too large.
    { schema: Schema.BigInt, text: "1.5", expected: "not-an-integer $" },
    { schema: Schema.BigInt, text: `"1"`, expected: "type-mismatch $" },
    { schema: Schema.Int, text: "1.5", expected: "not-an-integer $" },
    { schema: Schema.Finite.check(Schema.isBetween({ minimum: 0, maximum: 9 })), text: "10", expected: "out-of-range $" },
    { schema: Schema.BigInt.check(Schema.isGreaterThanBigInt(0n)), text: "0", expected: "out-of-range $" },
    { schema: Schema.Finite, text: "1e400", expected: "out-of-range $" },
    { schema: Haus.Float32, text: "1e39", expected: "out-of-range $" },
    // Records, refinements, std/time and secrets.
    { schema: Schema.Struct({ id: Schema.Finite, name: Schema.String }), text: "{ id: 1 }", expected: "missing-field $" },
    { schema: Schema.Struct({ name: Schema.String.check(Schema.isMinLength(3)) }), text: `{ name: "a" }`, expected: "type-mismatch $.name" },
    { schema: Schema.Struct({ on: Haus.Date }), text: `{ on: Date("2026-02-30") }`, expected: "invalid-time $.on[0]" },
    { schema: Schema.Struct({ on: Haus.Date }), text: `{ on: Instant("2026-02-03T10:00:00Z") }`, expected: "type-mismatch $.on" },
    { schema: Schema.Struct({ at: Schema.DateTimeUtc }), text: `{ at: Instant("2026-02-03T10:00:00") }`, expected: "invalid-time $.at[0]" },
    { schema: Schema.Struct({ key: Schema.Redacted(Schema.Finite) }), text: `{ key: "sk-1" }`, expected: "invalid-secret $.key" },
    { schema: Schema.Struct({ key: Schema.Redacted(Schema.String.check(Schema.isMinLength(9))) }), text: `{ key: "sk-1" }`, expected: "invalid-secret $.key" },
    // Places: arguments of a positional payload, a record payload's fields.
    {
      schema: Schema.TaggedStruct("Point", { values: Schema.Tuple([Schema.Finite, Schema.Finite]) }).annotate({ hausValues: true }),
      text: `Point(1, "2")`,
      expected: "type-mismatch $[1]",
    },
  ])("$text", ({ schema, text, expected }) =>
    Effect.gen(function* () {
      expect(yield* failure(schema, text)).toBe(expected)
    }))

  it.effect("a schema file's types report what the core reports", () =>
    Effect.gen(function* () {
      const { schemas } = Haus.compileSchemaFile(`
        type Root = { small: Int8, big: UInt32, pair: < Pair Int String >, nick: Maybe String, payload: < Wrap { values: Array Int32 } > }`)
      const fields = { small: "1", big: "1", pair: `Pair(1, "a")`, nick: "None", payload: "Wrap { values: [] }" }
      const text = (over: string) => {
        const [key, value] = over.split(/: (.*)/s) as [keyof typeof fields, string]
        return `{ ${Object.entries({ ...fields, [key]: value }).map(([k, v]) => `${k}: ${v}`).join(", ")} }`
      }
      expect(yield* failure(schemas.Root!, text("small: 128"))).toBe("out-of-range $.small")
      expect(yield* failure(schemas.Root!, text("big: 18446744073709551616"))).toBe("out-of-range $.big")
      expect(yield* failure(schemas.Root!, text("big: 1e2"))).toBe("not-an-integer $.big")
      expect(yield* failure(schemas.Root!, text("pair: Pair(1)"))).toBe("wrong-payload $.pair")
      expect(yield* failure(schemas.Root!, text("pair: Pair(1, 2)"))).toBe("type-mismatch $.pair[1]")
      expect(yield* failure(schemas.Root!, text(`nick: Some(1)`))).toBe("type-mismatch $.nick[0]")
      expect(yield* failure(schemas.Root!, text(`payload: Wrap { values: [1, 2147483648] }`))).toBe("out-of-range $.payload.values[1]")
    }))

  it.effect("wrong-payload: at the variant, with a hint that names the case", () =>
    Effect.gen(function* () {
      const hint = (schema: Schema.Top, text: string) =>
        Effect.flip(Haus.decode(schema as Schema.Codec<unknown>)(text)).pipe(Effect.map((e) => Haus.errorJson(e)))
      const circle = Schema.TaggedStruct("Circle", { r: Schema.Finite })
      expect(yield* hint(Schema.Struct({ shape: circle }), "{ shape: Circle(1.5) }")).toMatchObject({
        code: "wrong-payload",
        path: "$.shape",
        hint: "Circle takes one argument, a record: write `Circle { … }`.",
      })
      expect(yield* hint(Schema.TaggedStruct("Empty", {}), "Empty(1)")).toMatchObject({ hint: "Empty takes no payload: write `Empty`." })
      expect(yield* hint(Schema.Option(Schema.Finite), "Some")).toMatchObject({ hint: "Some takes 1 argument: write `Some(…)`." })
      expect(yield* hint(Schema.Boolean, "True(1)")).toMatchObject({ hint: "True takes no payload: write `True`." })
      const { schemas } = Haus.compileSchemaFile("type Root = < Point Float64 Float64 >")
      expect(yield* hint(schemas.Root!, "Point(1)")).toMatchObject({ code: "wrong-payload", path: "$", hint: "Point takes 2 arguments: write `Point(…, …)`." })
    }))

  it.effect("a secret's error names its type, never the value", () =>
    Effect.gen(function* () {
      const e = yield* Effect.flip(Haus.decode(Schema.Struct({ key: Schema.Redacted(Schema.Finite) }))(`{ key: "sk-123" }`))
      expect(e.code).toBe("invalid-secret")
      expect(JSON.stringify(Haus.errorJson(e))).not.toContain("sk-123")
      const ok = yield* Haus.decode(Schema.Struct({ key: Schema.Redacted(Schema.String) }))(`{ key: "sk-123" }`)
      expect(Redacted.value(ok.key)).toBe("sk-123")
    }))
})
