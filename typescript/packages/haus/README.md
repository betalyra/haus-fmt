# @haus-fmt/haus

The haus data format for TypeScript and JavaScript, barebones and without
dependencies: the text (parser, writer, formatter, canonical form, hash),
values checked when they are built, schemas from `.schema.haus` files with
packages, rules and codecs, typed decoding and encoding, Standard Schema
support. Every step that can fail gives a `Result`; nothing throws.

```sh
npm install @haus-fmt/haus
```

Most applications are better served by [`@haus-fmt/effect`](../effect), which
builds on this package. Use this one when you want nothing else, or to build
your own layer on it.

> ⚠️ haus is a draft. Everything may still change.

## Results

```ts
import { pipe, Result } from "@haus-fmt/haus"

Result.succeed(1)                                     // { _tag: "Success", success: 1 }
Result.fail(e)                                        // { _tag: "Failure", failure: e }
pipe(r, Result.map(f), Result.flatMap(g))             // data-last, or Result.map(r, f)
Result.match(r, { onSuccess: …, onFailure: … })
Result.isSuccess(r), Result.isFailure(r)
```

The shape and the names are Effect 4's, and stay as they are. The failure of
every fallible function is a `HausError`: `HausSyntaxError` (with
`HausSchemaFileError` for schema files: `line`, `column`), `HausDecodeError`
and `HausEncodeError` (a `path`, `$.items[2].price`), `HausPackageError` (the
package layer, no place) and `HausConfigError` (a mistake of your
configuration, without a code).

## Read and write haus

```ts
import { format, formatText, parse, parseAll, parsePlain, stringify, WriteOptions } from "@haus-fmt/haus"

const text = `{ id: 1042, total: 30.30, status: Shipped, note: None }`

parse(text)                          // Result<Value, HausSyntaxError>: the haus data model
parseAll(text)                       // every top-level value (a stream)
parsePlain(text)                     // plain JS values: { id: 1042n, total: "30.30", status: "Shipped", note: { _tag: "None" } }
stringify(value, { style: "compact" })        // total: a value is always writable
format(values, { stream: true })              // a file: a comma after each value, a single one too
formatText(text, { style: "pretty" })         // reformat text, comments kept: Result<string, HausSyntaxError>
const wide = WriteOptions.make({ indent: 4, width: 120 })   // checked when made: Result<WriteOptions, HausConfigError>
```

The plain view: strings, `bigint` for whole numbers (any size, so a field's
type never depends on its values), `string` for decimals (exact), `boolean`,
`Uint8Array` for bytes, string literals for tags without payload, `{ _tag, … }`
for other variants. `None` and `Some(x)` are tagged, `{ _tag: "None" }` and
`{ _tag: "Some", value: x }`, so `Some(None)` stays apart from `None`.

`parseWith(schema, text)` validates the plain view with any
[Standard Schema](https://standardschema.dev) (Zod, Valibot, ArkType, Effect
Schema), giving a Result.

## Values

```ts
import { canonical, compare, equals, hash, Value } from "@haus-fmt/haus"

const order = Value.record({ id: Value.number(7), status: Value.variant("Paid"), tags: Value.array([Value.string("new")]) })
// Result<HRecord, HausEncodeError>; a part may be a value or the Result of building one

Value.number("0xFF")       // Success: 255 (normalized as the parser normalizes it)
Value.number("01")         // Failure: invalid-number
Value.variant("paid")      // Failure: invalid-tag
Value.record([["a", x], ["a", y]])   // Failure: duplicate-key
```

A `Value` is always a valid haus value within the limits it was built with
(spec §7, §11). Constructors check what they are given, with the default
limits: 16 Mi characters per string, key and tag (`string-too-long`,
`key-too-long`, `tag-too-long`), 1000 characters and an exponent of 6144 per
number on its normalized literal (`number-too-long`, `exponent-too-large`), 256
levels (`nesting-too-deep`), and 64 Mi values written out (`too-many-nodes`):
each container records its `size` (itself and every value inside it, a part
shared by two places counted twice) and its `depth` when it is built, so a
value whose parts share each other too much (`x(n+1) = [x(n), x(n)]`) is
refused where it is built. A part parsed with larger limits keeps them.

So what takes a value is total: `stringify`, `format`, `toHausJson`,
`canonical`, `equals`, `compare` give a result for every value, and `hash`
and `hashAll` a Promise (Web Crypto) that never rejects.

Values are read-only: their types are readonly and the arrays inside them
frozen. Changing one anyway (a cast, a `Map`'s `set`) is a programming error;
the writers notice it from the recorded sizes and throw `value-changed`,
instead of hanging or writing something else.

## Schemas

Schemas come from `.schema.haus` files. Reading is separate from compiling,
and compiling reads no file:

```ts
import { pipe, Result, Schema, Sources } from "@haus-fmt/haus"
import { readSources } from "@haus-fmt/haus/node"

// From the file system: the entry file, the files it imports relatively, the packages given.
const sources = await readSources("order.schema.haus", { packages: ["vendor/acme"], folders: ["schemas"], root: ".." })
// Or from data you have from anywhere (a database, a URL, memory), with the same checks but the file system's.
const fromData = Sources.make("order.schema.haus", { "order.schema.haus": text, "common.schema.haus": common })

const schema = Result.flatMap(sources, Schema.compile)   // Result<Schema, HausError>
```

A schema's types have handles, which carry their TypeScript types.
[`@haus-fmt/import`](../import) declares them for a schema file
(`import { Order, schema } from "./order.schema.haus"`); the official
packages export theirs (`@haus-fmt/haus/money`); `Prelude` and `StdTime` have
the built-in ones; `Type.make<Const<A>>("app#Order")` makes one by hand.

```ts
Schema.decode(schema, Order)(text)          // Result<Order, HausError>; also Schema.decode(schema, Order, text)
Schema.decodeValue(schema, Order)(value)    // from a parsed Value
Schema.encode(schema, Order)(order)         // Result<Value, HausError>
Schema.stringify(schema, Order)(order, { style: "compact" })
Schema.toJson(schema, Order)(order)         // schema-based JSON (spec §16.3); Schema.fromJson reads it back
Schema.decodeStream(schema, Log, response.body!)   // a Result per value as it arrives
Schema.standard(schema, Order)              // a Standard Schema of the type
```

A stream type (`type Log = Stream Entry`) has a `StreamType` handle:
`Schema.decode(schema, Log)` gives its items, `Schema.stringify(schema, Log)`
writes them each followed by a comma.

Decoding follows the plain view above: `Int` is a `bigint`, `Int8` …
`UInt32` and floats numbers, `Decimal` its exact text, std/time types their
checked text, `Maybe a` `{ _tag: "None" } | { _tag: "Some", value }`, `Map v` a
`ReadonlyMap`, `Any` the `Value`, `Secret a` a `Secret<A>`, variants tagged
unions (`{ _tag, …fields }`, `{ _tag, values: [...] }`, `{ _tag, value }`),
open variants with an `Unknown` for tags they don't list.

## Packages and rules

A schema imports packages by name: `import @haus-fmt/money (Money)`. Nothing
is ever looked for (no `node_modules` search): a compile has

- the **official packages** (`@haus-fmt/money`, `@haus-fmt/geo`,
  `@haus-fmt/uuid`), built in with their rules (iso, wgs84, rfc9562). A copy
  given must be the built-in one byte for byte, else `duplicate-package`;
- packages given **as values**: `Sources.withPackage(pkg)`, a library's
  bundle (it carries its rules and the bundles it imports), or
  `Package.make({ manifest, schema })` from data;
- packages read from **directories** given to `readSources` (`packages`,
  `folders`), or with `readPackage(dir)` and `readPackages(folder)`.

A package's manifest may give some of its types a rule
(`{ name: "@acme/ids", version: "1.2.0", rules: { "Id": "ulid" } }`). Rules are
on by default: each is checked on every value of its type that is decoded
(`codec-rejected`) or encoded (`cannot-encode`), on the value the schema
decoded, before any codec. A rule of a type the schema reaches needs an
implementation, else compiling fails with `missing-codec`:

```ts
import { money } from "@haus-fmt/haus/money"

Package.withRule(acme, "Id", (id: string) => (ulid.test(id) ? Result.succeed(id) : Result.fail("not a ULID")))
Package.shapeOnly(acme)        // its rules not checked, and not required
Package.shapeOnly(money)       // the official ones too: Money(1, Eur) passes
```

A broken `rules` field (a type the schema doesn't define, one with
parameters, a `Stream`, a rule name that isn't `[a-z][a-z0-9-]*`, its prose
`rules/<name>.md` missing from a directory) is `package-manifest`, shape-only
or not.

## Codecs

A codec chooses the host type of a named type without parameters: yours, a
package's, `prelude#Decimal` or `std/time#Instant`. It is a typed pair:

```ts
import { Codec, Schema, StdTime } from "@haus-fmt/haus"

const instantAsDate = Codec.make(StdTime.Instant, {
  decode: (s) => Result.succeed(new Date(s)),     // lossy: the offset as written is dropped
  encode: (d) => (Number.isNaN(d.getTime()) ? Result.fail("an invalid Date") : Result.succeed(d.toISOString())),
})
const withDates = Result.flatMap(schema, Schema.withCodec(instantAsDate))
// Schema.decode(withDates, Order)(text): every Instant is a Date, in the types too
```

A codec runs after the type's schema and its rule: it can reject more values
(`codec-rejected`, at the type's place), never fewer; inside a `Secret` its
rejection is `invalid-secret`. When codecs nest (a `Currency` codec inside a
`Money` one), they run inside out, and the outer codec receives the inner
part's host value. Two codecs for one id, or one for a type that can't have
one (a generic type, a `Stream`), are a `HausConfigError`; a codec for an id
no type has adds the warning `unused-codec` to `schema.warnings`.

`Schema.optimize(schema, Order)` makes `decode` and `stringify` of a type
read and written very often use generated code (`new Function`, or code
`@haus-fmt/import` built ahead).

## Secrets

`Secret a` decodes to a `Secret<A>`: printing, logging and `JSON.stringify`
show `<redacted>`, `expose()` gives the value. A `Value` can't hold one.
Encoding refuses one by default, `cannot-encode` at the secret, in an error
that doesn't show it; `revealSecrets: true` writes it in full, by your choice:

```ts
Schema.stringify(schema, Config)(config)                          // Failure: cannot-encode at $.apiKey
Schema.stringify(schema, Config)(config, { revealSecrets: true }) // the file, secret included
```

## JSON

```ts
importJson('{"total": 19.90, "ok": true}')   // any JSON as haus (spec §16.1): Result<Value, HausError>
toHausJson(value)                             // self-describing JSON (§16.2): total
fromHausJson(text)                            // and back, to an equal value
```

Schema-based JSON (§16.3) is `Schema.toJson` and `Schema.fromJson`.

## Limits

Readers and encoders take the limits of spec §7: `maxDepth` (256 by default),
`maxNumberLength` (1000), `maxExponent` (6144), `maxStringLength` (16 Mi
characters, for strings, record keys and tags), `maxNodes` (64 Mi), plus
`maxSteps` for schemas. Writers, the canonical form and hashing take none: a
value is within the limits it was built with.

`maxDepth` is at most `MAX_SUPPORTED_DEPTH`, 512: the parser, the schema
decoders and encoders and the JSON mappings recurse, and 512 levels fit
Node's default stack. The stack every path needs at 512 levels is
`STACK_NEEDED_MB`, 1.5 MiB as a worker's `resourceLimits.stackSizeMb`. A
worker with a smaller stack works to fewer levels: deeper input fails with
`nesting-too-deep`, never with the engine's `RangeError`.

## Errors

Every error has a `code` (spec §17), the same in every haus binding and
documented at `https://haus-fmt.org/docs/errors#<code>`, and a `hint`.
`errorJson(e)` (or `JSON.stringify(e)`) gives the JSON form, for tools and
agents:

```ts
Result.match(parse("Heartbeat\n{ at: 1 }"), {
  onSuccess: () => {},
  onFailure: (e) => errorJson(e),
  // { code: "payload-newline", message: "expected ',' between top-level values, found '{'",
  //   line: 2, column: 1, expected: "','", found: "'{'", hint: "…", docs: "…#payload-newline" }
})
```

## Modules

| | |
|---|---|
| `@haus-fmt/haus` | everything above |
| `@haus-fmt/haus/node` | `readSources`, `readPackage`, `readPackages`: the only reading of files |
| `@haus-fmt/haus/money`, `/geo`, `/uuid` | the official packages: their values, handles and rule functions |
| `@haus-fmt/haus/internal` | the internals for first-party tools (Effect, the import tool, the editor); not a stable API |

Typed `.haus` imports: [`@haus-fmt/import`](../import). Effect: [`@haus-fmt/effect`](../effect).
