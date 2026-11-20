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

Each schema is compiled once, on first use, into a reader and a writer
(closures, no `eval`): `h.parse` reads straight from the text into the
values, without the generic `Value` tree in between, and `h.stringify` in the
`compact` and `minimised` layouts writes straight from them. The values,
texts and errors are those of the generic path; on any error, the generic
path runs again to report it, so a syntax error later in the text still wins
over a mismatch before it.

Schemas from `.schema.haus` files:

```ts
import { compileSchemaFile } from "@haus-fmt/haus"
import { schemaOptions } from "@haus-fmt/haus/node"   // resolves imports from the file system

const { schemas } = compileSchemaFile(text, schemaOptions("order.schema.haus"))
const order = h.parse(schemas.Order!, data)
```

`schemaOptions` finds packages in `node_modules` as Node does, from the real
path of the importing file, after checking that the file declares the package
in its `package.json` (spec §13.3); never in `NODE_PATH`, global folders or
directories everyone may write to. Packages can also be given explicitly:
package directories, or folders whose subdirectories are packages (relative to
the schema file's directory). A package directory is used instead of the
installed one; a package from a folder must have the same files as the
installed one, if any. With `npm: false`, only the given packages exist:

```ts
schemaOptions("order.schema.haus", { packages: ["../vendor/money"], folders: ["../schemas"] })
schemaOptions("order.schema.haus", { folders: ["../schemas"], npm: false })
```

A package's `package.haus`, `schema.haus` and `package.json` must be regular
files, not links. Schema files and `package.json` are read up to 1 MiB
(`file-too-large`), and one schema reads at most 256 schema files
(`too-many-files`).

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
(and has no schema-based JSON form, spec §16.3; nor has one with a field named `_args`).

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

### Optimizing a hot schema

For a schema read or written very often, `h.optimize` switches it to
generated code: one function per record, array and variant, a fixed object
shape per record, keys written as constant text. That is 12–40% faster for
one type used over and over. For many types each used a few times, the
default is as fast or faster, so optimize only the schemas you measured as hot.

```ts
const Issue = h.optimize(schemas.Issue!)   // the same schema object, now marked
for (const text of texts) h.parse(Issue, text)
```

`h.optimize` marks the schema itself and returns it; every later
`h.parse`, `h.stringify`, `h.formatAll`, `h.encodeStream` and
`h.decodeStream` with it uses the generated code, and calling it again changes
nothing. The code is made at first use with `new Function`, so it needs
`eval` (not under a content security policy without `'unsafe-eval'`), unless
[`@haus-fmt/import`](../import) built it ahead: its `optimize` option builds
the code and marks the listed types itself, so no `h.optimize` call is needed
for them. Where neither works, the schema keeps the closures. Values, texts and errors are the
same either way.

### Codecs

A codec is your choice of host type for a named type of a schema file,
selected by the type's id (spec §13.4). It runs after the type's schema, so it
can reject more values, never fewer, and it applies wherever the type occurs,
in imported packages too. The official packages ship the codecs of their
profiles:

```ts
import { iso } from "@haus-fmt/money"   // the profile @haus-fmt/money/iso: currencies are three letters A–Z
import { wgs84 } from "@haus-fmt/geo"   // the profile @haus-fmt/geo/wgs84: latitudes and longitudes in range

const { schemas } = compileSchemaFile(text, { ...schemaOptions("order.schema.haus"), codecs: [...iso, ...wgs84] })
h.parse(schemas.Order!, data)   // Money(1, Eur) or LatLng(91, 0): HausDecodeError
```

They keep the value and the host type: a `Money` is still
`{ _tag: "Money", values: ["19.90", "EUR"] }` (its currency always a tag,
never an `Unknown`), a `LatLng` its two floats, `-0` included. For schemas
written with `h.*`, the packages export the types with their profile too:
`h.Record({ total: Money, to: LatLng })`.

A codec is `{ id, apply }`: `apply` builds the host type's schema from the
type's own one, for example with `h.refine(base, check)`, which adds a rule
(`check` returns why it rejects a value, or `undefined`) and checks it when
encoding too. Codecs for types the schema doesn't contain are ignored; two for
one type are an error, and so is one for a record that a variant uses as a
record case (`< Box R >`), whose fields sit beside `_tag` (`codec-unreachable`).

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
`h.stringify` writes for a reader with the limits it is given: integers are
always written in decimal, and one longer than `maxNumberLength` is an error
(`number-too-long`). A hex literal has at most 829 hex digits (with the
default limit of 1000), so every integer the parser takes fits in decimal.

## JSON

Schemas also read and write schema-based JSON (spec §16.3), the JSON a JSON
consumer expects, with the schema saying what JSON can't (that a string is a date or a
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
| an unknown value of an open variant | `{"_tag": "Hexagon", "_args": […]}`, the arguments self-describing (without the envelope) |
| `Any` | its self-describing form (below), without the envelope |
| `Secret a` | as `a`; errors inside never show the value |

Reading follows decoding: an open record ignores members it doesn't list, a
closed one rejects them, an integer type takes only whole numbers (`1.0` is
not one), an open variant reads a `"_tag"` it doesn't list as an unknown
value (with `"_args"` alone, its arguments self-describing; with other
members, those as a record payload, imported, so `{"_tag": "Hexagon", "sides": 6}`
is `Hexagon { sides: 6 }`). A record payload with a field named `_tag` or
`_args` has no schema-based form. Every
schema of `h.` has a JSON form; a schema written by hand (`h.withStandard`)
declares one with `json` (a `JsonType`), or has none. `h.toJsonValue` and
`h.fromJsonValue` work on parsed JSON instead of text.

Without a schema:

```ts
import { fromHausJson, importJson, parseJson, toHausJson } from "@haus-fmt/haus"

toHausJson(value)           // self-describing JSON, every haus value exactly (spec §16.2): {"_haus":1,"_value":{"_rec":{"total":{"_num":"19.90"}}}}
fromHausJson(text)          // and back to an equal value; anything but the envelope of a self-describing form is an error
importJson(`{"total": 19.90, "ok": true, "note": null}`)   // any JSON as haus (spec §16.1): { total: 19.90, ok: True, note: None }
parseJson(text)             // the strict I-JSON reader: numbers as JsonNumber (exact text), duplicate members rejected
```

The caller says which form it reads: `fromHausJson` requires the envelope,
`h.fromJson` and `importJson` never look for one (to them it is an object
like any other). All of them read RFC 8259 JSON restricted to I-JSON: no
duplicate member names, no unpaired surrogates, and the limits of spec §7,
number literals included; `fromHausJson` also rejects raw DEL, C1 and bidi
controls, which haus writers always escape. Numbers are never rounded through
a binary float, except where the type says `Float32` or `Float64`.
`stringifyJson` writes JSON values compactly, with numbers as their text and
DEL, C1 and bidi controls escaped; `JSON.stringify` keeps numbers exact too
where the engine has `JSON.rawJSON`, but writes those controls raw. JSON Lines
without a schema: `parseJsonLines`, `importJsonLines`, `fromHausJsonLines` and
`toHausJsonLines` (an envelope per line). Readers of
JSON Lines accept CR LF and a missing last line feed (`requireTerminator`
makes it an error); an empty line is an error, and a byte order mark is
ignored only at the start of the stream.

## Write haus

```ts
import { format, parseDocument, stringify } from "@haus-fmt/haus"

stringify(value)                                   // one value in the standard layout
stringify(value, { style: "compact" })             // on one line: { a: 1, b: [1, 2] }
stringify(value, { style: "minimised" })           // on one line, no whitespace: {a:1,b:[1,2]}
format(values)                                     // a file of values (a stream)

const { values, comments } = parseDocument(text)
format(values, { source: text, comments })         // reformat a file, comments kept
```

## Limits

Every reader, decoder and encoder takes the limits of spec §7, enforced while
parsing: `maxDepth` (256 by default), `maxNumberLength` (1000),
`maxExponent` (6144) and `maxStringLength` (16 Mi characters, for strings,
record keys and tags), plus `maxSteps` for schemas.

```ts
parse(text, { maxDepth: 512, maxStringLength: 1024 })
h.decode(Order, value, { maxDepth: 64 })
```

`maxDepth` is at most `MAX_SUPPORTED_DEPTH`, 512: the parser, the schema
decoders and encoders and the JSON mappings recurse, and 512 levels fit
Node's default stack with room to spare (the shallowest path, encoding with a
schema, overflows near 750). A larger `maxDepth` is a `RangeError` naming the
maximum, thrown when the limits are given. Raw JSON (`parseJson`) counts JSON
levels, up to `hausJsonDepth(512)`, 2050, as many as 512 haus levels take in
self-describing JSON (`jsonDepth(512)`, 2049, in schema-based JSON).
Formatting, the canonical form and hashing don't recurse: they take any depth.

## Errors

Every error has a `code` (spec §17): a short name for the mistake, such as
`payload-newline` or `missing-field`, the same in every haus binding and
documented at `https://haus-fmt.org/docs/errors#<code>`. `hint` says how to
fix it: the catalogue's fix for the code, or a concrete one where the decoder
knows more, such as what the tag of a `wrong-payload` takes (`Point takes 2
arguments (Float64, Float64): write \`Point(…, …)\`.`). `errorJson(e)` (or `JSON.stringify(e)`) gives the JSON form, for
tools and agents:

```ts
try {
  parse("Heartbeat\n{ at: 1 }")
} catch (e) {
  errorJson(e)
  // { code: "payload-newline", message: "expected ',' between top-level values, found '{'",
  //   line: 2, column: 1, expected: "','", found: "'{'",
  //   hint: "Put the payload on the same line as Heartbeat, or add a comma if they are two values.",
  //   docs: "https://haus-fmt.org/docs/errors#payload-newline" }
}
```

Syntax errors (`HausSyntaxError`, and `HausSchemaFileError` for schema files)
have `line` and `column`; decoding and encoding errors (`HausDecodeError`,
`HausEncodeError`) have a `path`, `$.items[2].price`. `checkData` gives each
issue a `code` too, and schema-file warnings have one. `errorCode(e)` is the
code of any error this package throws, and `invalid-utf8` for the TypeError
of the UTF-8 decoder `parseStream` uses. `ERROR_CODES` lists them all.

## Also inside

| | |
|---|---|
| `parseStream(chunks)` | values one by one, from any chunked source |
| `infer(values)`, `inferSchema` | the schema a file's data has |
| `parseSchemaFile`, `checkData` | schema files and checking data against them, with positions |
| `parseDocument`, `completeAt` | positions, comments and completions, for editors |

Typed `.haus` imports: [`@haus-fmt/import`](../import). Effect: [`@haus-fmt/effect`](../effect).
