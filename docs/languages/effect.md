---
title: Effect
description: Decode and encode haus with Effect schemas, as Effects and Streams.
---

Decode haus with the Effect schemas you already write, or with schemas from `.schema.haus` files. Decoding is an `Effect`, a file of values is a `Stream`, and errors land in the error channel with their place and code.

## Install

```sh
npm install @haus-fmt/effect effect
```

It builds on [`@haus-fmt/haus`](/docs/languages/typescript).

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

```ts
import { readSchemaFile } from "@haus-fmt/haus/node"

const { text: schemaText, options } = readSchemaFile("order.schema.haus")
const { schemas } = Haus.compileSchemaFile(schemaText, options)
const order = yield* Haus.decode(schemas.Order!)(data)
```

Or import them: with [`@haus-fmt/import`](https://github.com/betalyra/haus-fmt/tree/main/typescript/packages/import) and the target `"effect"`, `import { Order } from "./order.schema.haus"` gives Effect schemas, and `import order from "./order.haus"` the decoded data. `Int` is a `bigint`, `Decimal` and the std/time types their exact text, `Maybe` an `Option`. All of them: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Codecs** map a haus type onto your own type, after the schema's checks. The official profiles come as codec groups:

```ts
import { iso } from "@haus-fmt/money/effect"   // currencies are three letters A–Z
import { wgs84 } from "@haus-fmt/geo/effect"   // latitudes and longitudes in range

const order = yield* Haus.decode(Order, iso, wgs84)(text)   // Money(1, Eur) or LatLng(91, 0) fails
```

Your own: `Haus.codec(money.Money, (base) => base.pipe(Schema.decodeTo(Cents, toCents)))`. A package's rule is checked only where you pass its codec. [What haus checks](/docs/checks)

- **Lossy types, by choice.** `Haus.DecimalAsBigDecimal` gives a `BigDecimal`, `Haus.InstantAsDateTime` a `DateTime.Utc`. Encoding them back can write another value with another hash, so they are opt-in.
- **Streams.** `Haus.decodeStream(Event)(response.body!)` is a `Stream<Event, HausError>`; `Haus.encodeStream(Event)(events)` writes one value per chunk. [Logs and streams](/docs/tours/streams)
- **JSON.** `Haus.toJson(Order)(order)` and `Haus.fromJson(Order)(json)` read and write schema-based JSON; `encodeJsonLines` and `decodeJsonLines` do JSON Lines. [Coming from JSON](/docs/from-json)
- **Secrets.** `Secret a` is a `Redacted`: it shows `<redacted>`, and errors inside never show the value. [Config and secrets](/docs/tours/secrets)
- **Limits.** Decoders take them with their input: `Haus.decode(Order)(text, { maxDepth: 64 })`. The depth is at most 512.

## More

- [README of `@haus-fmt/effect`](https://github.com/betalyra/haus-fmt/tree/main/typescript/packages/effect): the type mapping, JSON and limits in full.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/typescript/examples): `quickstart` (typed imports, decode, encode, errors), `order` (packages and codecs), `logs` (a `Stream`).
- [A tour of haus](/docs/tour) and [From schema to code](/docs/tours/typed).
