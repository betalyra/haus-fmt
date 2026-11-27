---
title: TypeScript
description: Read and write haus in TypeScript and JavaScript, as plain values or typed by a schema.
---

`@haus-fmt/haus` is the barebones foundation: the haus text, values, and schemas from `.schema.haus` files with packages, rules and codecs. It has no dependencies, and every step that can fail gives a `Result` instead of throwing. Most applications are better served by [Effect](/docs/languages/effect), which builds on it; use this package directly when you want nothing else, or to build your own layer.

## With Effect (recommended)

[`@haus-fmt/effect`](/docs/languages/effect) is the full-featured way: the same schemas, packages and rules, as Effect schemas. A compiled schema's types are Effect schemas, each package rule a check of its type, on by default and before any codec; codecs are ordinary Effect Schema transformations, secrets `Redacted`, errors Effect's, files of values `Stream`s. Reading files is an `Effect` that needs a file system; compiling needs nothing.

```ts
import * as Haus from "@haus-fmt/effect"
import { NodeSchemaFiles } from "@haus-fmt/effect/node"
import { Effect } from "effect"

const program = Effect.gen(function* () {
  const { schemas } = yield* Haus.readSources("order.schema.haus").pipe(Effect.flatMap(Haus.compile))
  return yield* Haus.decode(schemas.Order!)(text)   // HausParseError | HausSchemaError, Money(1, Eur): codec-rejected
}).pipe(Effect.provide(NodeSchemaFiles.layer))
```

It never decides anything about haus itself: parsing, schema files, packages, rules, values and their limits are this package's. The rest of this page is the barebones API.

## Install

```sh
npm install @haus-fmt/haus
```

## Read and write

```ts
import { parse, parsePlain, Result, stringify } from "@haus-fmt/haus"

const text = `{ id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" }, note: None }`

parsePlain(text)
// Success: { id: 7n, total: "44.40", status: { _tag: "Shipped", tracking: "DE-4711" }, note: { _tag: "None" } }

const value = parse(text)                                     // Result<Value, HausSyntaxError>
Result.map(value, (v) => stringify(v, { style: "compact" }))  // Success: "{ id: 7, total: 44.40, … }"
```

Integers are `bigint` of any size, so a field's type never depends on its values. `None` is `{ _tag: "None" }`, not `null`, so `Some(None)` and `None` stay apart. `parse` takes one value; `parseAll` reads a file of several (a stream).

`Result` has the shape and names of Effect's: `Result.succeed`, `fail`, `map`, `flatMap`, `match`, `isSuccess`, `isFailure`, data-first or data-last with `pipe`.

## Values

A `Value` is always a valid haus value within the limits it was built with. Building one is the only step that can fail; what takes one is total:

```ts
import { canonical, hash, Value } from "@haus-fmt/haus"

const order = Value.record({ id: Value.number(7), status: Value.variant("Paid") })   // Result<HRecord, HausEncodeError>
Value.variant("paid")                                                               // Failure: invalid-tag

if (Result.isSuccess(order)) {
  canonical(order.success)         // "{id:7,status:Paid}"
  await hash(order.success)        // a Promise that never rejects
}
```

Constructors check tags, numbers, Unicode, duplicate keys and every limit of the spec (16 Mi characters per string, 1000 per number, 256 levels, 64 Mi values written out); each container records its size and depth. Values are read-only: changing one after it was built (a cast, a `Map`'s `set`) is a programming error, which the writers report as `value-changed` rather than hang. Writer options are checked when made: `WriteOptions.make({ indent: 4 })`.

## With a schema

Schemas come from `.schema.haus` files. Read them with their imports, compile, and decode with a type handle:

```ts
import { pipe, Result, Schema } from "@haus-fmt/haus"
import { readSources } from "@haus-fmt/haus/node"
import { Root } from "./order.schema.haus"      // with @haus-fmt/import: types and handles

const schema = Result.flatMap(await readSources("order.schema.haus"), Schema.compile)
const order = Result.flatMap(schema, (s) => Schema.decode(s, Root)(text))   // Result<Root, HausError>
```

`readSources` is the only step that reads files; `Sources.make(entry, { "order.schema.haus": text, … })` makes the same from data you have from anywhere. With [`@haus-fmt/import`](https://github.com/betalyra/haus-fmt/tree/main/typescript/packages/import), a schema file is a module that exports its compiled `schema` and a handle per type, and a data file is a module, typed and checked by the schema next to it. It works with Node, tsx, Vite and `tsc` 7.1.

A value that doesn't fit is a `Failure` with its place and a code:

```ts
Schema.decode(schema, Root)(text.replace("id: 7", `id: "7"`))
// Failure: HausDecodeError: expected Int, found string "7" at $.id   (code "type-mismatch")
```

`Schema.encode`, `Schema.stringify`, `Schema.toJson` and `Schema.fromJson` work the same way, and `Schema.standard(schema, Root)` is a [Standard Schema](https://standardschema.dev). What each haus type becomes: [host types](/docs/types#host-types-in-each-language).

## Packages and rules

The official packages (`@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid`) are built in, with their rules on: `Money(44.40, Eur)` is rejected (`codec-rejected`), since `Eur` is not a currency of the rule iso. Nothing is looked for: every other package is given, as a library's value or a directory.

```ts
import { Package, Sources } from "@haus-fmt/haus"
import { money } from "@haus-fmt/haus/money"
import { readSources } from "@haus-fmt/haus/node"

const sources = await readSources("order.schema.haus", { packages: ["vendor/acme"], folders: ["schemas"] })
pipe(sources, Result.map(Sources.withPackage(Package.shapeOnly(money))))   // currencies checked for their shape only
Package.withRule(acme, "Id", (id) => (ulid.test(id) ? Result.succeed(id) : Result.fail("not a ULID")))
```

A package whose manifest gives a type a rule (`rules: { "Id": "ulid" }`) needs an implementation of it in your program, or compiling fails with [`missing-codec`](/docs/errors#missing-codec): supply it with `Package.withRule`, use the library that publishes the package (its value carries the rule), or take the package with `Package.shapeOnly`.

## Codecs

A codec chooses the host type of a named type, as a typed pair:

```ts
import { Codec, StdTime } from "@haus-fmt/haus"

const instantAsDate = Codec.make(StdTime.Instant, {
  decode: (s) => Result.succeed(new Date(s)),     // keeps the instant, drops the offset as written
  encode: (d) => Result.succeed(d.toISOString()),
})
const withDates = Result.flatMap(schema, Schema.withCodec(instantAsDate))
// Schema.decode(withDates, Root)(text): every Instant is a Date, in the types too
```

Codecs run after the type's schema and its package rule, so they can reject more values, never fewer. Two for one type, or one for a type that can't have one (a generic type, a `Stream`), are mistakes of your configuration; a codec for an id no type has gives the warning [`unused-codec`](/docs/errors#unused-codec).

## What else you need to know

- **Checking data.** Decoding reports the first error; the editor tools report them all with their places.
- **Streams.** `parseStream(source)` and `Schema.decodeStream(schema, Log, source)` yield a Result per value as it arrives. `format(values, { stream: true })` writes a comma after a single value too, so the next can be appended. [Logs and streams](/docs/tours/streams)
- **JSON.** `Schema.toJson(schema, Root)(order)` gives the JSON a JSON consumer expects; `importJson` reads any JSON as haus; `toHausJson` and `fromHausJson` carry any value through JSON. [Coming from JSON](/docs/from-json)
- **Secrets.** `Secret a` decodes to a `Secret<A>`: it prints `<redacted>`, and `expose()` gives the value. A `Value` can't hold one, and encoding refuses one (`cannot-encode`) unless you pass `revealSecrets: true`. [Config and secrets](/docs/tours/secrets)
- **Limits.** Every reader takes the limits of the spec: `parse(text, { maxDepth: 64 })`. The depth is at most 512.
- **Errors.** Each has a `code` and a `hint`; `errorJson(e)` gives the JSON form for tools and agents. [Error codes](/docs/errors)

## More

- [README of `@haus-fmt/haus`](https://github.com/betalyra/haus-fmt/tree/main/typescript/packages/haus): the whole API.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/typescript/examples): `quickstart` and `order` with `@haus-fmt/haus`, `logs` with Effect, on the shared [example files](https://github.com/betalyra/haus-fmt/tree/main/examples).
- [A tour of haus](/docs/tour) and [From schema to code](/docs/tours/typed).
