# @haus-fmt/haus

The haus data format for TypeScript and JavaScript: parser, writer, streams,
schemas, type inference and Standard Schema support. No dependencies.

```sh
npm install @haus-fmt/haus
```

> ⚠️ haus is a draft. Everything may still change.

## Read haus

```ts
import { parse, parsePlain } from "@haus-fmt/haus"

const text = `{ id: 1042, total: 30.30, status: Shipped, note: None }`

parse(text)        // the haus data model: { kind: "record", fields: Map { … } }
parsePlain(text)   // plain JS values: { id: 1042n, total: "30.30", status: "Shipped", note: { _tag: "None" } }
```

The plain view: strings, `bigint` for whole numbers (any size, so a field's type
never depends on its values), `string` for decimals (exact),
`boolean`, `Uint8Array` for bytes, string literals for tags without payload,
`{ _tag, … }` for other variants. `None` and `Some(x)` are tagged too,
`{ _tag: "None" }` and `{ _tag: "Some", value: x }`, as with `h.Maybe`, so
`Some(None)` stays apart from `None`. A file with several values (a stream) is
an array.

## Validate with any schema library

Every [Standard Schema](https://standardschema.dev) works: Zod, Valibot, ArkType, Effect Schema, …

```ts
import { parseWith } from "@haus-fmt/haus"
import { z } from "zod"

const Order = z.object({ id: z.bigint(), total: z.string(), status: z.enum(["Pending", "Shipped"]) })
const order = parseWith(Order, text)   // typed; throws HausValidationError with the schema's issues
```

`parseWithAsync` is the same for schemas that validate asynchronously.

## haus schemas

Schemas that read haus exactly (big integers, exact decimals, dates, open
variants) and write it back. Every one is also a Standard Schema.

```ts
import * as h from "@haus-fmt/haus/schema"

const Order = h.Record({
  id: h.Int,
  total: h.Decimal,
  status: h.Variant({ Pending: h.Unit, Shipped: h.Record({ tracking: h.String }) }),
  note: h.Maybe(h.String),
})
type Order = h.Infer<typeof Order>

const order = h.parse(Order, text)       // mismatches fail with the path: expected Int, found string "2" at $.id
order.id                                 // 1042n: Int is a bigint of any size; Int32 etc. are numbers
const back = h.stringify(Order, order)   // haus text again
for await (const o of h.decodeStream(Order, response.body!)) { … }
```

Schemas from `.schema.haus` files:

```ts
import { compileSchemaFile } from "@haus-fmt/haus"
import { schemaOptions } from "@haus-fmt/haus/node"   // resolves imports from the file system

const { schemas } = compileSchemaFile(text, schemaOptions("order.schema.haus"))
const order = h.parse(schemas.Order!, data)
```

| schema file | `h.` schema | TypeScript |
|---|---|---|
| `String`, `Bytes`, `Bool` | `h.String`, `h.Bytes`, `h.Bool` | `string`, `Uint8Array`, `boolean` |
| `Int`, `Int64`, `UInt64` | `h.Int`, `h.Int64`, `h.UInt64` | `bigint` |
| `Int8` … `UInt32`, `Float32`, `Float64` | `h.Int8` …, `h.Float64` | `number` |
| `Decimal` | `h.Decimal` | `string`, the exact literal (`"19.90"`) |
| `Maybe a`, `Array a`, `Map v` | `h.Maybe`, `h.Array`, `h.Map` | `h.Maybe<A>`, `readonly A[]`, `ReadonlyMap<string, V>` |
| `Date`, `Instant`, … (std/time) | `h.Date`, `h.StdTime("Instant")`, … | `string`, as written |
| `{ a: T, b?: T }` | `h.Record({ a, b: h.Optional(…) })` | `{ readonly a: T; readonly b?: T }` |
| `< A \| B { x: T } >` | `h.Variant`, `h.OpenVariant`, `h.Enum` | `{ _tag: "B"; x: T } \| …`, open: `\| Unknown` |
| `Any` | `h.Any` | `Value`: the parsed value, unchanged |
| `Secret a` | `h.Secret(a)` | `Secret<A>`: prints `<redacted>`, `expose()` gives the value |

A case whose record payload has a field named `_tag` (`< Odd { _tag: Int32 } >`)
can't put its fields beside the tag: it is nested, `{ _tag: "Odd"; value: { _tag: number } }`
(and has no plain JSON form, spec §16.3).

`h.Maybe<A>` is `{ _tag: "None" } | { _tag: "Some"; value: A }`, tagged like
every other variant, so `Maybe (Maybe Int)` keeps `None` and `Some(None)`
apart. A missing optional field stays missing (`b?:`), never `None`: an
`h.Optional(h.Maybe(T))` field has three states. `h.Maybe.none`,
`h.Maybe.some(x)`, `h.Maybe.fromNullable(x)`, `h.Maybe.toNullable(m)` and
`h.Maybe.getOrElse(m, () => d)` convert from and to `null`-style values.

Every type above keeps the value: encoding what it decoded writes an equal
haus value, except where spec §15 drops information by design (the spelling
of a float, `-0` as an integer, fields an open record ignores). `h.InstantAsDate` is the one lossy choice, for a JS
`Date`: it keeps the instant to the millisecond, and drops digits below the
millisecond, the offset and the fraction as written (`10:00:00.250+01:00` is
written back as `09:00:00.250Z`, another value with another hash).

A `Secret` hides its value from `console.log`, `String()` and
`JSON.stringify`, and errors inside one name its place and type, never the
value. Encode one with `h.Secret.make(value)`. `@deprecated` and other
attributes don't change decoding; the declarations (`schemaDeclarations`) mark
deprecated types, fields and tags with JSDoc `@deprecated`, `checkData` hints
where data uses them, and `parseSchemaFile(…).warnings` lists attributes this
version doesn't know and each place the schema uses a deprecated type.

An `Any` (or an unknown tag's raw value) is written back after the same checks
as parsing: pass the parser's limits to both if you raise them,
`h.parse(h.Any, text, { maxNumberLength: 5000 })` and
`h.encode(h.Any, value, { maxNumberLength: 5000 })`. Number literals built in
code are normalized as the parser would (`"1E5"` is written `1e5`).
`h.stringify` writes for a reader with the limits it is given: an integer
longer than `maxNumberLength` is written in hex, so that the reader takes it.

## JSON

Schemas also read and write plain JSON (spec §16.3), the JSON a JSON consumer
expects, with the schema saying what JSON can't (that a string is a date or a
decimal):

```ts
h.toJson(Order, order)    // '{"id":"1042","total":"19.90","status":{"_tag":"Pending"},"note":null}'
h.fromJson(Order, json)   // the same Order again; HausSyntaxError (not I-JSON) or HausDecodeError (doesn't fit), with the path

for await (const line of h.encodeJsonLines(Order, orders)) out.write(line)   // JSON Lines: one JSON text per line
for await (const o of h.decodeJsonLines(Order, response.body!)) { … }
```

| type | JSON |
|---|---|
| `String`, std/time types | a string, std/time as written |
| `Int8` … `UInt32` | a number |
| `Int`, `Int64`, `UInt64` | a string, `"-12"`: many JSON parsers round integers beyond 2⁵³ |
| `Float32`, `Float64` | a number in the one float spelling (spec §15); `"NaN"`, `"Infinity"`, `"-Infinity"` |
| `Decimal` | a string, `"19.90"` |
| `Bytes` | a string, base64 with padding |
| `Bool` | `true` / `false` |
| `Maybe a` | `null` / the value; `{"_tag": "None"}` / `{"_tag": "Some", "value": …}` when `a`'s JSON can be `null` (`Maybe (Maybe Int)`) |
| `Array a`, `Map v`, records | arrays and objects; a missing optional field is a missing member, never `null` |
| a closed variant of tags without payload (`h.Enum`) | a string, `"Debug"` |
| other variants | `{"_tag": "Circle", "r": 1.5}`: a record payload's fields beside `_tag`, one argument as `"value"`, several as `"values"` |
| an unknown value of an open variant | `{"_tag": "Hexagon", "args": […]}`, the arguments lossless |
| `Any` | its lossless form (below) |
| `Secret a` | as `a`; errors inside never show the value |

Reading follows decoding: an open record ignores members it doesn't list, a
closed one rejects them, an integer type takes only whole numbers (`1.0` is
not one), an open variant reads a `"_tag"` it doesn't list as an unknown
value (with `"args"` alone, read losslessly; with other members, those as a
record payload read without a schema, so `{"_tag": "Hexagon", "sides": 6}` is
`Hexagon { sides: 6 }`). A record payload with a field named `_tag` has no plain form. Every
schema of `h.` has a JSON form; a schema written by hand (`h.withStandard`)
declares one with `json` (a `JsonType`), or has none. `h.toJsonValue` and
`h.fromJsonValue` work on parsed JSON instead of text.

Without a schema:

```ts
import { fromJson, fromLosslessJson, parseJson, toLosslessJson } from "@haus-fmt/haus"

fromJson(`{"total": 19.90, "ok": true, "note": null}`)   // JSON as haus (spec §16.1): { total: 19.90, ok: True, note: None }
toLosslessJson(value)       // any haus value as JSON (spec §16.2): {"rec":{"total":{"num":"19.90"}}}
fromLosslessJson(text)      // and back to an equal value; anything but a lossless form is an error
parseJson(text)             // the strict I-JSON reader: numbers as JsonNumber (exact text), duplicate members rejected
```

All of them read RFC 8259 JSON restricted to I-JSON: no duplicate member
names, no unpaired surrogates, and the limits of spec §7, number literals
included. Numbers are never rounded through a binary float, except where the
type says `Float32` or `Float64`. `stringifyJson` writes JSON values
compactly, with numbers as their text; `JSON.stringify` does too where the
engine has `JSON.rawJSON`. JSON Lines without a schema: `parseJsonLines`,
`fromJsonLines`, `fromLosslessJsonLines` and `toLosslessJsonLines`. Readers of
JSON Lines accept CR LF and a missing last line feed (`requireTerminator`
makes it an error); an empty line is an error, and a byte order mark is
ignored only at the start of the stream.

## Write haus

```ts
import { format, parseDocument, stringify } from "@haus-fmt/haus"

stringify(value)                                   // one value in the standard layout
stringify(value, { style: "compact" })             // on one line
format(values)                                     // a file of values (a stream)

const { values, comments } = parseDocument(text)
format(values, { source: text, comments })         // reformat a file, comments kept
```

## Also inside

| | |
|---|---|
| `parseStream(chunks)` | values one by one, from any chunked source |
| `infer(values)`, `inferSchema` | the schema a file's data has |
| `parseSchemaFile`, `checkData` | schema files and checking data against them, with positions |
| `parseDocument`, `completeAt` | positions, comments and completions, for editors |

Typed `.haus` imports: [`@haus-fmt/import`](../import). Effect: [`@haus-fmt/effect`](../effect).
