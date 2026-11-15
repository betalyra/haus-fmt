# @haus-fmt/effect

haus with [Effect](https://effect.website): decode and encode with Effect
schemas, streams of values, schemas from `.schema.haus` files, and codecs that
map haus types onto your own.

```sh
npm install @haus-fmt/effect effect
```

> ⚠️ haus is a draft. Everything may still change.

## Decode and encode

```ts
import * as Haus from "@haus-fmt/effect"
import { Effect, Schema } from "effect"

const Order = Schema.Struct({
  id: Schema.BigInt,
  total: Haus.Decimal,
  status: Haus.OpenUnion([Schema.TaggedStruct("Pending", {}), Schema.TaggedStruct("Shipped", { tracking: Schema.String })]),
  note: Schema.Option(Schema.String),
})

const program = Effect.gen(function* () {
  const order = yield* Haus.decode(Order)(text)                    // HausParseError | HausSchemaError, with positions
  return yield* Haus.encode(Order, { style: "compact" })(order)    // haus text again
})
```

| haus | Effect |
|---|---|
| `Circle { radius: 5 }` | `TaggedStruct("Circle", { radius })` |
| `Point(1, 2)` | `TaggedStruct("Point", { x, y })`, arguments fill fields in order |
| `True` / `False` | `Boolean` |
| `None` / `Some(x)` | `Option(X)`; a missing field is not `None` (`optionalKey` for `x?: T`) |
| `19.90` | `Haus.Decimal`: the exact text, `"19.90"`; or `Number` (Float64), `Haus.Float32`, `BigInt` |
| `Instant("…")`, `ZonedDateTime("…")` | `Haus.Instant`, `Haus.ZonedDateTime`: the text as written |
| `Date("…")` and the other std/time types | `Haus.Date`, …: the text as written |
| an unknown tag in `Haus.OpenUnion` | `{ _tag: "@unknown", tag, value }` |
| any value (`Any`) | `Haus.Any`: the parsed haus `Value`, unchanged |
| a secret (`Secret a`) | `Schema.Redacted(A)`: shows `<redacted>`; errors inside never show the value |

These keep the value: encoding what they decoded writes an equal haus value
(spec §13.4), apart from what §15 drops by design (the spelling of a float,
`-0` as an integer, fields an open record ignores).

### Lossy Effect types, by choice

Effect's `BigDecimal` and `DateTime` keep less than the haus value. They are
there when you ask for them: as schemas for hand-written schemas, and as
codecs for schema files. Encoding what they decoded can write a different
haus value, with another canonical form and hash. Hash and sign the parsed
values, not re-encoded ones.

| Schema | Codec | Type | What it drops |
|---|---|---|---|
| `Haus.DecimalAsBigDecimal` | `Haus.decimalAsBigDecimal` | `BigDecimal` | exponent notation and `-0`: it keeps the scale (`19.90` stays `19.90`), but `-0` is written `0`, `15e2` as `1.5e3`, `1.5e-3` as `0.0015` |
| `Haus.InstantAsDateTime` | `Haus.instantAsDateTime` | `DateTime.Utc` | digits below the millisecond, the offset and the fraction as written: `10:00:00.250999+01:00` is written `09:00:00.250Z` |
| `Haus.ZonedDateTimeAsDateTime` | `Haus.zonedDateTimeAsDateTime` | `DateTime.Zoned` | the same, and zone names are looked up with Intl: an unknown zone is an error (std/time accepts any well-formed name), and a name Intl canonicalises is written that way (`Etc/UTC` as `UTC`) |

```ts
const Payment = Schema.Struct({ amount: Haus.DecimalAsBigDecimal, at: Haus.InstantAsDateTime })
const order = yield* Haus.decode(schemas.Order, Haus.decimalAsBigDecimal)(text)   // Decimals as BigDecimals
```

A DateTime that std/time can't write (a year beyond 9999) is an encoding
error: the writer never emits an invalid value. `Schema.BigDecimal`,
`Schema.DateTimeUtc` and `Schema.DateTimeZoned` work directly too, with the
same losses.

## Streams

```ts
const events = Haus.decodeStream(Event)(response.body!)    // Stream<Event, HausError>
const text = Haus.encodeStream(Event)(events)               // Stream<string>, one value per chunk
```

## JSON

The same schemas read and write plain JSON (spec §16.3), the JSON a JSON
consumer expects. The schema says what JSON can't: that a string is a date
or a decimal.

```ts
const json = yield* Haus.toJson(Order)(order)     // '{"id":"1042","total":"19.90","status":{"_tag":"Pending"},"note":null}'
const back = yield* Haus.fromJson(Order)(json)    // HausParseError (not I-JSON) | HausSchemaError (doesn't fit), with paths

const lines = Haus.encodeJsonLines(Event)(events)            // Stream<string>, one JSON text per line
const decoded = Haus.decodeJsonLines(Event)(response.body!)  // Stream<Event, HausError>, as lines arrive
```

| Effect schema | JSON |
|---|---|
| `String`, `Haus.Date` & co. | a string, std/time as written |
| `Number`, `Haus.Float32` | a number in the one float spelling (spec §15); `"NaN"`, `"Infinity"`, `"-Infinity"` |
| integers of schema files (`Int8` … `UInt32`) | a number |
| `BigInt` (`Int`, `Int64`, `UInt64`) | a string, `"-12"`: many JSON parsers round integers beyond 2⁵³ |
| `Haus.Decimal`, `BigDecimal` | a string, `"19.90"` |
| `Boolean` | `true` / `false` |
| `Uint8Array` | a string, base64 with padding |
| `Option(X)` | `null` / the value; `{"_tag": "None"}` / `{"_tag": "Some", "value": …}` when X's JSON can be `null` |
| `optionalKey(X)` | a missing member (never `null`) |
| `Literals(["Debug", "Info"])` | a string, `"Debug"` |
| tagged structs | `{"_tag": "Circle", "r": 1.5}`; `{"_tag": "Wrap", "value": 3}` and `{"_tag": "Point", "values": [1, 2]}` for positional ones |
| an unknown tag in `Haus.OpenUnion` | `{"_tag": "Hexagon", "args": […]}`, the arguments lossless; read back from that form, or from a newer writer's `{"_tag": "Hexagon", "sides": 6}` as `Hexagon { sides: 6 }` |
| `Haus.Any` | the lossless form: `{"num": "19.90"}`, `{"rec": {…}}`, `{"tag": "None"}`, … |
| `Redacted(X)` | as X; errors inside never show the value |

Numbers keep their exact text: the reader never rounds them through a float,
and rejects text that isn't I-JSON (duplicate members, unpaired surrogates).
A schema with no plain form (`Schema.Unknown`, a union that isn't tagged) is
a `HausSchemaError` naming it. `Haus.toJsonValue` and `Haus.fromJsonValue`
work on parsed JSON (`JsonNumber`s for numbers), `Haus.valueFromJson` reads
JSON without a schema as a haus `Value` (spec §16.1), and
`Haus.toJson(Haus.Any)` / `Haus.fromJson(Haus.Any)` are the lossless mapping
(spec §16.2).

## Limits

Decoders take limits (spec §7) with their input, encoders with their value.
They are the core's: `maxDepth` (256 by default), `maxNumberLength`,
`maxExponent`, `maxStringLength`, and `maxSteps` for the conversion.

```ts
const order = yield* Haus.decode(Order)(text, { maxDepth: 64 })
const events = Haus.decodeStream(Event)(response.body!, { maxDepth: 64 })
const back = yield* Haus.fromJson(Order)(json, { maxDepth: 64 })    // JSON may nest jsonDepth(64) levels
const text = yield* Haus.encode(Order)(order, { style: "compact", limits: { maxDepth: 64 } })
```

Encoders hold the value to `maxDepth` too, so what they write reads again
with the same limits. `maxDepth` is at most `Haus.MAX_SUPPORTED_DEPTH`, 512:
the parser, the converters and Effect's own schema decoder recurse, and 512
levels fit Node's default stack with room to spare (Effect's decoder, the
shallowest path, overflows near 800). A larger `maxDepth` fails with a
`HausLimitsError` naming the maximum, in the error channel. Effect's encoder
also recurses over the value it is given, before haus sees it: a value built
in code nested a thousand levels or more can overflow there.

## Errors

The error channel holds `HausParseError` (text that isn't haus or JSON, with
`line` and `column`; invalid UTF-8 in a byte stream is `invalid-utf8`, without
them), `HausSchemaError` (a value that doesn't fit the schema,
or can't be encoded) and `HausLimitsError`. Each has a `code` (spec §17), the
same in every haus binding, a `hint` and a `docs` link
(`https://haus-fmt.org/docs/errors#<code>`). `Haus.errorJson(e)` (or
`JSON.stringify(e)`) is the core's JSON form, for tools and agents:

```ts
const Cart = Schema.Struct({ items: Schema.Array(Schema.Struct({ qty: Schema.BigInt })) })
const error = yield* Effect.flip(Haus.decode(Cart)(`{ items: [{ qty: 1.5 }] }`))
Haus.errorJson(error)
// { code: "not-an-integer", message: "expected a whole number, got the number 1.5",
//   path: "$.items[0].qty", hint: "Write the integer without a fraction or exponent.",
//   docs: "https://haus-fmt.org/docs/errors#not-an-integer" }
```

A `HausSchemaError` has the code the core gives the same value. For the issues
of Effect's own decoder, also in schemas you write by hand:

| | code |
|---|---|
| a value of another kind (`"2"` for a number, a record for a struct, a tag for a string) | `type-mismatch` |
| `Boolean`, `Option`, literals and tagged structs: a tag none of them takes / a known tag with another payload (`True(1)`, `Some`, `Point(1)`, `Circle(1.5)` for a record case), at the variant, with a hint that says what the tag takes | `unknown-tag` / `wrong-payload` |
| a number with a fraction or exponent for `BigInt` or an integer check (`Schema.Int`) | `not-an-integer` |
| a number outside a range check (`isBetween`, `isGreaterThan`, …), the ranges of `Int8` … `UInt64`, a float too large | `out-of-range` |
| a missing key / an unknown field of a closed record | `missing-field` / `unknown-field` |
| std/time text that the profile rejects (`Date("2026-02-30")`) | `invalid-time` |
| anything inside a `Schema.Redacted` (a `Secret`): the error names its type, never the value | `invalid-secret` |
| any other check or transformation that fails | `type-mismatch` |
| encoding a value the schema can't write | `cannot-encode` |
| more than one value where one is expected | `not-one-value` |

`path` is where the error is in the decoded value (`["items", 0, "qty"]`, as
in Effect's messages); `place` is where it is in the haus value, as the core
writes it (`$.items[0].qty`; a variant's argument as `[i]`, the text of
`Date("…")` as `$.on[0]`), and the JSON form's `path`. A `HausLimitsError` is
`unsupported-depth`. Stream errors keep their `index`.

## Schema files

```ts
import { schemaOptions } from "@haus-fmt/haus/node"

const { schemas } = Haus.compileSchemaFile(text, schemaOptions("order.schema.haus"))
const order = yield* Haus.decode(schemas.Order!)(data)
```

`Int` → `bigint`, `Decimal` → `string` (the exact text), `Maybe` → `Option`,
std/time types → `string` (the text as written), `Any` → `Haus.Value`,
`Secret a` → `Redacted<A>`. A variant case whose record payload has a field
named `_tag` (`< Odd { _tag: Int32 } >`) can't put its fields beside the tag:
it decodes nested, `{ _tag: "Odd", value: { _tag: 1 } }`, and has no plain
JSON form (spec §16.3). For `BigDecimal` and `DateTime`, pass the codecs
above. Attributes
don't change decoding; `schemaDeclarations` marks `@deprecated` types, fields
and tags with JSDoc `@deprecated`. With [`@haus-fmt/import`](../import) (target `"effect"`), you can
import schema files directly: `import { Order } from "./order.schema.haus"`.

## Codecs

A codec is your choice of type for a named haus type, applied after the
schema's own checks:

```ts
import * as money from "@haus-fmt/money/money.schema.haus"

const cents = Haus.codec(money.Money, (base) => base.pipe(Schema.decodeTo(Cents, toCents)))
const order = yield* Haus.decode(Order, cents)(text)   // order.total: Cents
```

See the [order example](../../examples/order) for a complete one.
