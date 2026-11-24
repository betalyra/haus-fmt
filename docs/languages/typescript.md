---
title: TypeScript
description: Read and write haus in TypeScript and JavaScript, as plain values or typed by a schema.
---

Parse haus into plain JavaScript values, or decode it with a schema into typed ones: `bigint` for integers, the exact text for decimals, objects with `_tag` for variants. `@haus-fmt/haus` has no dependencies. Using Effect? See [Effect](/docs/languages/effect).

## Install

```sh
npm install @haus-fmt/haus
```

## Read and write

```ts
import { parse, parsePlain, stringify } from "@haus-fmt/haus"

const text = `{ id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" }, note: None }`

parsePlain(text)
// { id: 7n, total: "44.40", status: { _tag: "Shipped", tracking: "DE-4711" }, note: { _tag: "None" } }

const value = parse(text)                // the haus data model: a Value
stringify(value, { style: "compact" })   // { id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" }, note: None }
```

Integers are `bigint` of any size, so a field's type never depends on its values. `None` is `{ _tag: "None" }`, not `null`, so `Some(None)` and `None` stay apart. `parse` takes one value; `parseAll` reads a file of several (a stream), and `parsePlain` gives it as an array.

## With a schema

Write the schema in code with `h`:

```ts
import * as h from "@haus-fmt/haus/schema"

const Order = h.Record({
  id: h.Int,
  total: h.Decimal,
  status: h.Variant({ Pending: h.Unit, Shipped: h.Record({ tracking: h.String }) }),
  note: h.Maybe(h.String),
})
type Order = h.Infer<typeof Order>

const order = h.parse(Order, text)
if (order.status._tag === "Shipped") order.status.tracking   // "DE-4711"
h.stringify(Order, { ...order, id: order.id + 1n }, { style: "compact" })
```

A value that doesn't fit throws a `HausDecodeError` with its place and a code:

```ts
h.parse(Order, text.replace("id: 7", `id: "7"`))
// HausDecodeError: expected Int, found string "7" at $.id   (code "type-mismatch")
```

Or read the schema from a `.schema.haus` file. `readSchemaFile` resolves its imports, including packages in `node_modules`:

```ts
import { compileSchemaFile } from "@haus-fmt/haus"
import { readSchemaFile } from "@haus-fmt/haus/node"

const { text: schemaText, options } = readSchemaFile("order.schema.haus")
const { schemas, warnings } = compileSchemaFile(schemaText, options)
const order = h.parse(schemas.Root!, data)
```

With [`@haus-fmt/import`](https://github.com/betalyra/haus-fmt/tree/main/typescript/packages/import), a data file is a module, typed and checked by the schema next to it: `import thread from "./thread.haus"`. It works with Node, tsx, Vite and `tsc` 7.1.

Every `h` schema is also a [Standard Schema](https://standardschema.dev), and `parseWith(schema, text)` takes any Standard Schema: Zod, Valibot, ArkType. What each haus type becomes: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Codecs.** A schema package's rule is checked only when you add its codec. The official ones come with the packages:

```ts
import { iso } from "@haus-fmt/money"   // currencies are three letters A–Z
import { wgs84 } from "@haus-fmt/geo"   // latitudes and longitudes in range

const { schemas } = compileSchemaFile(schemaText, { ...options, codecs: [...iso, ...wgs84] })
h.parse(schemas.Root!, data)   // Money(44.40, Eur): HausDecodeError, codec-rejected at $.total[1]
```

Without them, `warnings` lists [`missing-codec`](/docs/errors#missing-codec) for each profiled type the schema reaches. Write your own with `h.refine` (one more rule) or `h.transform` (another host type). [What haus checks](/docs/checks)

- **Streams.** `for await (const o of h.decodeStream(Order, response.body!))` decodes each value as it arrives; `parseStream` reads values without a schema. [Logs and streams](/docs/tours/streams)
- **JSON.** `h.toJson(Order, order)` gives `{"id":"7","total":"44.40",…}`, the JSON a JSON consumer expects; `h.fromJson` reads it back with the same checks. `importJson` reads any JSON as haus. [Coming from JSON](/docs/from-json)
- **Dates.** std/time values are their checked text. `h.InstantAsDate` gives a JS `Date`; it keeps the instant to the millisecond and drops the offset as written.
- **Secrets.** `Secret a` is a `Secret<A>`: it prints `<redacted>`, and `expose()` gives the value. [Config and secrets](/docs/tours/secrets)
- **Limits.** Every reader and writer takes the limits of the spec: `parse(text, { maxDepth: 64 })`. The depth is at most 512.
- **Errors.** Each has a `code` and a `hint`; `errorJson(e)` gives the JSON form for tools and agents. [Error codes](/docs/errors)

## More

- [README of `@haus-fmt/haus`](https://github.com/betalyra/haus-fmt/tree/main/typescript/packages/haus): the whole API.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/typescript/examples): `quickstart`, `order` and `logs`, on the shared [example files](https://github.com/betalyra/haus-fmt/tree/main/examples). They use Effect.
- [A tour of haus](/docs/tour) and [From schema to code](/docs/tours/typed).
