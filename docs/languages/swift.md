---
title: Swift
description: Parse haus into HausValue, or decode it with a schema into your Codable structs and enums.
---

Parse haus into `HausValue`, an enum you can switch on, or decode it with a schema into your own `Codable` structs and enums. Swift 6, macOS 13, iOS 16 and Linux, no dependencies.

## Install

Add the repository with Swift Package Manager; its manifest is at the root:

```swift
// Package.swift
.package(url: "https://github.com/betalyra/haus-fmt", from: "0.1.0"),
// and in your target:
.product(name: "Haus", package: "haus-fmt"),
```

## Read and write

```swift
import Haus

let order = try parse(#"{ id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }"#)

if case .string(let tracking)? = order["status"]?["tracking"] {
    print(tracking) // DE-4711
}
if case .number(let total)? = order["total"] {
    print(total) // 44.40: exact, never a float
}
print(try stringify(order, FormatOptions(layout: .compact)))
```

A `HausValue` is `.number`, `.string`, `.bytes`, `.array`, `.record` or `.variant`. `parseAll` reads a file of several values (a stream).

Equality is haus equality: strings compare by their code points, so `"café"` in NFC and in NFD are two different values, though Swift's `==` on `String` calls them equal.

## With a schema

```swift
struct Line: Codable { let sku: String; let qty: UInt16 }
enum Status: Codable { case pending, shipped(tracking: String) }
struct Order: Codable { let id: Int; let lines: [Line]; let status: Status }

let schema = try HausSchema(contentsOf: "order.schema.haus")
let orderType = try schema.type("Order")

let order = try orderType.decode(Order.self, fromText: text)
print(try orderType.stringify(order, FormatOptions(layout: .compact)), terminator: "")
```

The schema checks the value first, then your types are filled. A record is a struct, a variant an enum whose cases are the tags with a lowercase first letter (`Shipped` is `shipped`), `Maybe` an `Optional`. Integers are any fixed-width integer; a value that doesn't fit is `out-of-range`. Errors carry their code and place:

```swift
do {
    _ = try orderType.decode(Order.self, fromText: #"{ id: 7, lines: [{ sku: "TEA-01", qty: -1 }], status: Pending }"#)
} catch {
    print(error.code, error) // the place is $.lines[0].qty
}
```

All the mappings: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

- **Packages.** Give them with a `PackageLocator`: `.explicit(folders:)` for directories, `.explicit(in: Bundle.module, …)` for packages a Swift package ships as resources.
- **Codecs.** A type that conforms to `HausCodec` chooses its own host type for a haus type, by its id: Foundation's `Date` for `std/time#Date`, integer cents for `@haus-fmt/money@1#Money`.
- **No profile codecs yet.** Swift ships no codecs for `@haus-fmt/money/iso` or `@haus-fmt/geo/wgs84`, and doesn't warn about them: `Money(1, Eur)` decodes unless your own codec rejects it. [What haus checks](/docs/checks)
- **Streams.** `StreamReader` takes chunks and gives values as they complete; `HausValues(chunks)` is the same as an `AsyncSequence`. [Logs and streams](/docs/tours/streams)
- **JSON.** `orderType.toJSON(order)` writes schema-based JSON, `decode(_:fromJSON:)` reads it. `importJSON` reads any JSON as haus. [Coming from JSON](/docs/from-json)
- **Hashes.** `hash` uses CryptoKit, so it exists on Apple platforms; on Linux, hash `canonical(value)` with a SHA-256 of your choice.
- **Secrets.** `Secret<T>` holds a value that is never printed. [Config and secrets](/docs/tours/secrets)
- **Concurrency.** Values, schemas and their types are `Sendable`: tasks can share one schema.
- **Errors.** A `HausError` with a `code`, a `position` for text and `json` for the JSON form. [Error codes](/docs/errors)

## More

- [README of the Swift package](https://github.com/betalyra/haus-fmt/tree/main/swift): limits, streams, JSON and Codable in full.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/swift/Examples): `quickstart` and `order` (codecs). Run `swift run order` in `swift/`.
- [A tour of haus](/docs/tour).
