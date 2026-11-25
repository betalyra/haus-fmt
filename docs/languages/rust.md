---
title: Rust
description: Parse haus into haus::Value, or into Rust structs and enums generated from your schema.
---

Parse haus into `haus::Value`, or into structs and enums that `build.rs` generates from your `.schema.haus` file. Decoding checks every rule of the schema; encoding checks what it writes.

## Install

```sh
cargo add haus-fmt                  # imported as haus
cargo add --build haus-fmt-build    # imported as haus_build: Rust types from schema files
```

`haus-fmt-schema` (imported as `haus_schema`) checks data against a schema at run time, without generated types.

## Read and write

```rust
let value = haus::parse_one(r#"{ id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }"#)?;

let total = value.get("total").and_then(|v| v.as_number()).unwrap();
total.as_str();              // "44.40": exact, never a float
haus::to_string(&value)?;    // { id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }
haus::canonical(&value);     // {id:7,status:Shipped{tracking:"DE-4711"},total:44.40}
```

`haus::parse` reads a file of several values (a stream) into a `Vec<Value>`.

## With a schema

```haus
// src/order.schema.haus
type Line = { sku: String, qty: UInt16 }
type Status = < Pending | Shipped { tracking: String } >
type Order = { id: Int, lines: Array Line, status: Status }
```

```rust
// build.rs
fn main() -> Result<(), haus_build::Error> {
    haus_build::Config::new().compile("src/order.schema.haus")
}
```

```rust
// src/main.rs
mod order { haus::include_schema!("order"); }

let order: order::Order = haus::from_str(text)?;
if let order::Status::Shipped { tracking } = &order.status {
    println!("shipped: {tracking}");
}
haus::to_string(&order)?;   // back to haus, in the compact layout
```

A record is a struct, a variant an enum (an open one gets an `Unknown` case), `Maybe` an `Option`. A value that doesn't fit is an error with its place and code:

```rust
haus::from_str::<order::Order>(r#"{ id: 7, lines: [{ sku: "TEA-01", qty: -1 }], status: Pending }"#)
// Err: .lines[0].qty: -1 is out of range for UInt16 (0 to 65535)   (code out-of-range)
```

To report every problem of a file with its position, as an editor does, use `haus_schema`:

```rust
let schema = haus_schema::Schema::load("src/order.schema.haus", &haus_schema::NoImports)?;
for issue in schema.check_text("Order", &text) {
    println!("{issue}");   // missing field qty at $.lines[0]
}
```

What each haus type becomes: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Codecs** choose your Rust type for a haus type, by its id, in `build.rs`. The official profiles are codecs of the `haus-fmt-money` and `haus-fmt-geo` crates:

```rust
haus_build::Config::new()
    .codec("@haus-fmt/money@1#Money", "haus_money::Iso")
    .codec("@haus-fmt/money@1#Currency", "haus_money::IsoCurrency")
    .codec("@haus-fmt/geo@1#LatLng", "haus_geo::Wgs84")
    .codec("@haus-fmt/geo@1#BBox", "haus_geo::Wgs84BBox")
    .compile("src/order.schema.haus")?;
```

Without them, the build prints a [`missing-codec`](/docs/errors#missing-codec) Cargo warning for each profiled type, and only the shape is checked. Your own codec implements `haus::Codec` (a `jiff` date for `std/time#Date`, integer cents for `Money`). [What haus checks](/docs/checks)

- **Packages.** A schema package is a crate: depend on it and `import @haus-fmt/money (Money)` works. Don't rename the dependency.
- **Streams.** `haus::stream::decode::<T, _>(reader)` iterates over any `std::io::Read`; `haus::stream::Reader` takes byte chunks and does no I/O, for async code. [Logs and streams](/docs/tours/streams)
- **JSON.** `haus::json::to_string(&order)` writes schema-based JSON (`{"id":"7",…}`), `haus::json::from_str` reads it. [Coming from JSON](/docs/from-json)
- **Integers.** `Int` is `haus::Int`, any size, kept as its digits; `to_i64()` and `to_i128()` convert it. Use `Int64` in the schema for a native integer.
- **Secrets.** `Secret a` is `haus::Secret<A>`: `Debug` and `Display` print `<redacted>`, `expose()` gives the value. Decoded at runtime with `haus_schema`, a value is a `Decoded` that hides its secrets the same way; `reveal()` makes it a `haus::Value`. [Config and secrets](/docs/tours/secrets)
- **Limits.** `haus::Limits` holds the spec's limits; the `_with` functions take other ones. The depth is at most 256.
- **Errors.** Each has a `haus::ErrorCode` with `hint()` and `docs()`, and `to_json()` gives the JSON form. [Error codes](/docs/errors)

## More

- [README of the Rust crates](https://github.com/betalyra/haus-fmt/tree/main/rust): generated code, packages, limits and threads in full.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/rust/examples): `quickstart`, `order` (codecs) and `logs` (a stream). Run `cargo run -p haus-example-order` in `rust/`.
- The [`haus` command](/docs/cli) is built on these crates: `brew install betalyra/tap/haus` or `cargo install haus-fmt-cli`.
- [A tour of haus](/docs/tour) and [From schema to code](/docs/tours/typed).
