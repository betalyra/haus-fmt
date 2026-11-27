---
title: Effect
description: Decode and encode haus with Effect schemas, as Effects and Streams.
---

The recommended way to use haus in TypeScript. Decode haus with the Effect schemas you already write, or with schemas from `.schema.haus` files with their packages and rules. Decoding is an `Effect`, a file of values is a `Stream`, and errors land in the error channel with their place and code.

## Install

```sh
npm install @haus-fmt/effect effect
```

It builds on [`@haus-fmt/haus`](/docs/languages/typescript), which decides everything about haus (parsing, schema files, packages, rules, values and their limits); this package gives you Effect schemas, Effects and Streams of it.

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

const text = `{ id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" }, note: None }`

const program = Effect.gen(function* () {
  const order = yield* Haus.decode(Order)(text)
  // { id: 7n, total: "44.40", status: { _tag: "Shipped", tracking: "DE-4711" }, note: Option.none() }
  return yield* Haus.encode(Order, { style: "compact" })(order)
  // { id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" }, note: None }
})
```

`Shipped { tracking: … }` is a `TaggedStruct`, `None` and `Some(x)` an `Option`, a decimal its exact text. `Haus.OpenUnion` keeps tags it doesn't list as `{ _tag: "@unknown", tag, value }`, so data from a newer sender still decodes.

## Errors

A value that doesn't fit fails with a `HausSchemaError`. `Haus.errorJson` gives its code, its place in the haus value and a hint:

```ts
const Cart = Schema.Struct({ lines: Schema.Array(Schema.Struct({ qty: Schema.BigInt })) })
const error = yield* Effect.flip(Haus.decode(Cart)(`{ lines: [{ qty: 1.5 }] }`))
Haus.errorJson(error)
// { code: "not-an-integer", message: "expected a whole number, got the number 1.5",
//   path: "$.lines[0].qty", hint: "Write the integer without a fraction or exponent.", … }
```

Text that isn't haus is a `HausParseError`, with a line and column.

## Schema files

Reading is an `Effect` that needs a file system (the `SchemaFiles` service; `NodeSchemaFiles.layer` for Node). Compiling reads nothing:

```ts
import { NodeSchemaFiles } from "@haus-fmt/effect/node"

const program = Effect.gen(function* () {
  const sources = yield* Haus.readSources("order.schema.haus")
  const { schemas } = yield* Haus.compile(sources)
  return yield* Haus.decode(schemas.Order!)(data)
}).pipe(Effect.provide(NodeSchemaFiles.layer))
```

`Haus.Sources.make(entry, { "order.schema.haus": text, … })` makes sources from data you have from anywhere. Compile errors are a `HausCompileError`, at their line and column in a schema file.

Or import them: with [`@haus-fmt/import`](https://github.com/betalyra/haus-fmt/tree/main/typescript/packages/import) and the target `"effect"`, `import { Order } from "./order.schema.haus"` gives Effect schemas, and `import order from "./order.haus"` the decoded data. `Int` is a `bigint`, `Decimal` and the std/time types their exact text, `Maybe` an `Option`. All of them: [host types](/docs/types#host-types-in-each-language).

## Packages and rules

The official packages (`@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid`) are built in, with their rules on: `Money(1, Eur)` and `LatLng(91, 0)` fail with `codec-rejected`, whatever codecs you pass. Nothing is looked for: every other package is given, as a directory (`Haus.readSources(path, { packages, folders })`, `Haus.readPackage`) or a value (`Haus.Package.make({ manifest, schema })`), with `Haus.Sources.withPackage`.

A package whose manifest gives a type a rule (`rules: { "Id": "ulid" }`) needs its implementation in your program, or compiling fails with [`missing-codec`](/docs/errors#missing-codec):

```ts
const acme = yield* Haus.readPackage("vendor/acme")
const checked = yield* Haus.Package.withRule(acme, "Id", (id) => ulid.test(String(id)) || "not a ULID")
// or Haus.Package.shapeOnly(acme): its types checked for their shape only
const { schemas } = yield* Haus.compile(Haus.Sources.withPackage(sources, checked))
```

A rule is a filter, as Effect's `Schema.makeFilter` takes one, checked on the value the type's schema decoded, before any codec. [What haus checks](/docs/checks)

## What else you need to know

**Codecs** map a haus type onto your own type, an ordinary Effect Schema transformation after the schema's checks and its package's rule: `Haus.codec(schemas.Money!, (base) => base.pipe(Schema.decodeTo(Cents, toCents)))`, then `Haus.decode(schemas.Order!, cents)(text)`. The official packages' modules (`@haus-fmt/effect/money`, `/geo`, `/uuid`) export their package values and codecs for host types: `currencyAsString`, `wgs84Types`, `uuidAsString`.

- **Lossy types, by choice.** `Haus.DecimalAsBigDecimal` gives a `BigDecimal`, `Haus.InstantAsDateTime` a `DateTime.Utc`. Encoding them back can write another value with another hash, so they are opt-in.
- **Streams.** `Haus.decodeStream(Event)(response.body!)` is a `Stream<Event, HausError>`; `Haus.encodeStream(Event)(events)` writes one value per chunk. [Logs and streams](/docs/tours/streams)
- **JSON.** `Haus.toJson(Order)(order)` and `Haus.fromJson(Order)(json)` read and write schema-based JSON; `encodeJsonLines` and `decodeJsonLines` do JSON Lines. [Coming from JSON](/docs/from-json)
- **Secrets.** `Secret a` is a `Redacted`: it shows `<redacted>`, and errors inside never show the value. Encoding refuses one (`cannot-encode`) unless you pass `revealSecrets: true`. [Config and secrets](/docs/tours/secrets)
- **Limits.** Decoders take them with their input: `Haus.decode(Order)(text, { maxDepth: 64 })`. The depth is at most 512.

## More

- [README of `@haus-fmt/effect`](https://github.com/betalyra/haus-fmt/tree/main/typescript/packages/effect): the type mapping, JSON and limits in full.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/typescript/examples): `logs` (a `Stream`) with Effect; `quickstart` and `order` with the barebones `@haus-fmt/haus`.
- [A tour of haus](/docs/tour) and [From schema to code](/docs/tours/typed).
