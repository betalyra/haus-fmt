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
haus::ser::write(&value);    // { id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }
haus::canonical(&value);     // {id:7,status:Shipped{tracking:"DE-4711"},total:44.40}
```

`haus::parse` reads a file of several values (a stream) into a `Vec<Value>`. A `Value` is always a valid haus value: its constructors (`Value::number`, `Value::record`, …) check it when it is built and return a `Result`, so the writers, `canonical`, `hash`, `equals` and `compare` can't fail.

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
use haus_schema::{Schema, Sources};

let schema = Schema::compile(&Sources::read("src/order.schema.haus")?)?;
for issue in schema.check_text("Order", &text) {
    println!("{issue}");   // missing field qty at $.lines[0]
}
```

Reading is apart from compiling: `Sources::read` reads the schema file and the files it imports, `Package::read` a package's directory, and `Sources::make` and `Package::make` take the same as text from anywhere (a database, a URL). `Schema::compile` reads no file.

What each haus type becomes: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Packages** are crates. For the official ones, add `haus-fmt-money`, `haus-fmt-geo` or `haus-fmt-uuid` (`cargo add haus-fmt-money`), and `import @haus-fmt/money (Money)` works; don't rename the dependency. A package's **rules** come with its crate and are always checked, on the value the schema decoded, before any codec: `Money(19.90, Bitcoin)` is rejected (`codec-rejected`) whatever codecs you set.

**Codecs** choose your Rust type for a haus type, by its id, in `build.rs`. A codec may reject more than the rule, never less:

```rust
haus_build::Config::new()
    .codec("@haus-fmt/money@1#Money", "crate::codecs::Cents")   // your own, implementing haus::Codec
    .codec("@haus-fmt/geo@1#LatLng", "haus_geo::Wgs84")         // the crate's: a Point type
    .compile("src/order.schema.haus")?;
```

A third-party package whose manifest gives a type a rule its crate doesn't implement fails the build with [`missing-codec`](/docs/errors#missing-codec): supply one (`.with_rule("@acme/ids@1#Id", "crate::rules::Ulid")`, a type implementing `haus::Rule`) or take the package shape-only (`.shape_only("@acme/ids")`). A codec for a type that can't have one (a generic type, a `Stream`) fails the build too. [What haus checks](/docs/checks)
- **Streams.** `haus::stream::decode::<T, _>(reader)` iterates over any `std::io::Read`; `haus::stream::Reader` takes byte chunks and does no I/O, for async code. `haus::to_string_all` writes a comma after every value, a single one too; to format a log that holds one value so far as a stream, set `FormatOptions { stream: true, .. }` (`haus fmt --stream`). [Logs and streams](/docs/tours/streams)
- **JSON.** `haus::json::to_string(&order)` writes schema-based JSON (`{"id":"7",…}`), `haus::json::from_str` reads it. [Coming from JSON](/docs/from-json)
- **Integers.** `Int` is `haus::Int`, any size, kept as its digits; `to_i64()` and `to_i128()` convert it. Use `Int64` in the schema for a native integer.
- **Secrets.** `Secret a` is `haus::Secret<A>`: `Debug` and `Display` print `<redacted>`, `expose()` gives the value. Encoding refuses a secret (`cannot-encode`, at the secret) unless you ask for it: `haus::to_string_with(&config, haus::Encoder::default().reveal_secrets())`. Decoded at runtime with `haus_schema`, a value is a `Decoded` that hides its secrets the same way; `reveal()` makes it a `haus::Value`. [Config and secrets](/docs/tours/secrets)
- **Limits.** `haus::Limits` holds the spec's limits; the `_with` functions take other ones. The depth is at most 256.
- **Errors.** Each has a `haus::ErrorCode` with `hint()` and `docs()`, and `to_json()` gives the JSON form. [Error codes](/docs/errors)

## More

- [README of the Rust crates](https://github.com/betalyra/haus-fmt/tree/main/rust): generated code, packages, limits and threads in full.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/rust/examples): `quickstart`, `order` (packages, rules and codecs) and `logs` (a stream). Run `cargo run -p haus-example-order` in `rust/`.
- The [`haus` command](/docs/cli) is built on these crates: `brew install betalyra/tap/haus` or `cargo install haus-fmt-cli`.
- [A tour of haus](/docs/tour) and [From schema to code](/docs/tours/typed).
