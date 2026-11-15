# haus for Rust

| Crate | What it is |
|---|---|
| [`haus-fmt`](haus) | Imported as `haus`. Parser, data model (`haus::Value`), `Decode`/`Encode`, std/time, codecs, compact writer, JSON (`haus::json`). Passes the [conformance suite](../test-suite), JSON suite included. |
| [`haus-fmt-build`](haus-build) | Imported as `haus_build`. Rust types from `.schema.haus` files, generated in `build.rs`. Also `haus-gen`, which generates the Roc modules. |
| [`haus-build-tests`](haus-build-tests) | Tests of the generated code. |
| [`haus-fmt-money`, `haus-fmt-geo`](../extensions) | Imported as `haus_money`, `haus_geo`. The official schema packages, as crates. |

## Examples

The same examples as in TypeScript, on the same files in [`../examples`](../examples).
Run them from this folder; each one's `build.rs` generates its Rust types from the schema first:

```sh
cargo run -p haus-example-quickstart   # thread.haus: typed data, decode, encode, errors
cargo run -p haus-example-order        # order.haus: schema packages and codecs
cargo run -p haus-example-logs         # logs.haus: read and write a stream, entry by entry
```

In VS Code, rust-analyzer needs the build scripts to have run. If it reports
`OUT_DIR not set`, run "rust-analyzer: Rebuild build dependencies".

## Use

```rust
// build.rs
haus_build::Config::new()
    .codec("std/time#Date", "crate::codecs::JiffDate")   // optional: your Rust type for a haus type
    .compile("src/order.schema.haus")?;

// src/main.rs
mod order { haus::include_schema!("order"); }
let order: order::Root = haus::from_str(&text)?;          // checks every rule of the schema
let text = haus::to_string(&order)?;                      // back to haus (compact)
let json = haus::json::to_string(&order)?;                // plain JSON (spec §16.3)
let order: order::Root = haus::json::from_str(&json)?;
```

| haus | Rust |
|---|---|
| `{ a: T, b?: U }` | `struct { a: T, b: Option<U> }` |
| `< A \| B T \| C { … } >` | `enum { A, B(T), C { … }, Unknown(haus::Unknown) }` (open), without `Unknown` when closed |
| `closed < Tag T U >` | `struct Tag(T, U)` |
| `Maybe a`, `Result e a`, `Array a`, `Map v` | `Option<A>`, `Result<A, E>`, `Vec<A>`, `BTreeMap<String, V>` |
| `Int`, `Decimal`, `Int8`…`UInt64`, `Float64` | `haus::Int`, `haus::Decimal` (exact text), `i8`…`u64`, `f64` |
| `Date`, `Instant`, … (std/time) | `haus::time::Date`, … (validated text; codecs map them to `jiff` and others) |
| `Any` | `haus::Value`: any value, as parsed |
| `Secret a` | `haus::Secret<A>`: `Debug` and `Display` print `<redacted>`; `expose()` / `into_inner()` give the value |
| `@deprecated("why")` on a type, field or tag | `#[deprecated(note = "why")]` |

A `Secret` is written in full when encoded (the receiver needs it), but a
decode or encode error inside it names only its place and type
(`.password: not a valid Secret String (the value is hidden)`), never the value
or a key inside it.
The generated code allows its own use of deprecated items, so a crate gets
deprecation warnings only where it touches them. Attributes haus doesn't
define (`@since`) are accepted and reported as Cargo warnings, as are uses of
deprecated types in a schema; `Config::quiet()` turns them off.

Writing checks what it writes, so `haus::to_string` returns a `Result`.
`Encode::encode_with` (and `ToJson::to_json_with`) take a `haus::Encoder`,
which carries the limits and counts the depth while the native value is
traversed: a value nested deeper than the limit fails there with the writer's
error (`[0][0]…: nesting deeper than 256 levels`), however deep it goes. Any
other failure comes from a `haus::Value`
built in code, the raw value of an `Any` or an unknown variant (spec §9.8):
`Value::Number("abc".into())` is an `EncodeError` (`.extra: not a number
literal`), as are a tag that isn't a tag name, a key used twice in a record,
and nesting, strings and numbers beyond the limits. Number literals are
written as the parser reads them (`1E5` as `1e5`). For a reader with other
limits, `haus::to_string_with(&value, &limits)` checks those, and writes an
integer longer than its number limit in hex so that it parses again.

`haus::Int` is an integer of any size, kept as its digits and written back
unchanged. `to_i64()` / `to_i128()` give it as a native integer when it fits; the
`bigint` feature adds conversions to and from `num_bigint::BigInt`. For a native
integer that must fit, the schema says `Int64` (out of range is a decode error).

Schema packages are ordinary dependencies: a crate with `haus.package.haus`,
`links = "<its library name>"` and `haus_build::package()` in its build script. A crate
that depends on it directly can `import @org/name (…)`; the types are the
package crate's own (`haus_money::Money`), so codecs written for them work in
every crate.

Streams (spec §6) are read as the values arrive: `haus::stream::decode::<T, _>(reader)`
is an iterator over any `std::io::Read`, and `haus::stream::encode` writes one value per
line (`encode_with` for other limits). `haus::stream::Reader` does no I/O itself (push byte chunks, split anywhere, get
the completed values), so an async adapter is a short loop around it.

Without a schema, `haus::parse` reads any haus text into `Value`s: a parser in
the sense of spec §13.1, which knows no types.

## Limits

Reading enforces the limits of spec §7, `haus::Limits`: by default a depth of
256, number literals of 1000 characters, exponents up to 6144, and strings,
record keys and tags of 16 Mi characters. Every reader and writer has a
version that takes other limits:

| | With limits |
|---|---|
| haus text | `haus::parse_with`, `haus::stream::Reader::new(Options { limits, .. })`, `stream::values_with` |
| writing for such a reader | `haus::to_string_with`, `haus::ser::write_with`, `stream::encode_with`, `Encode::encode_with(Encoder::new(&limits))` |
| JSON | `json::parse_with`, `json::write_with`, `json::value_from_str_with`, `json::from_str_with`, `json::to_string_with`, `json::to_lossless`, `json::from_lossless`, `json::from_plain`, `FromJson::from_json_with(json, Decoder::new(&limits))` |

`haus::MAX_SUPPORTED_DEPTH` is 256, the default: the parser, decoding,
encoding and the JSON mappings recurse once per level of nesting, so this
crate supports no deeper limit (lower ones are fine). Every function above
rejects a larger `max_depth` before reading or writing anything, with an
error that names the maximum: `max_depth 300 is more than the supported
maximum, 256`. The JSON reader and writer and the canonical form use no call
stack per level.

At 256 levels, the deepest path, the lossless JSON form of nested variants,
takes about 1.2 MiB of stack in a debug build and 0.3 MiB in a release build
(measured on aarch64 macOS): well within the 2 MiB stack of a spawned thread,
a test thread or an async task, and the 8 MiB of a main thread. Code that
haus-fmt-build generates for a recursive type takes stack in proportion to the
type's size: a record of 30 fields that holds itself in a `Maybe` takes about
18 KiB per record to encode in a debug build (7 KiB in a release build), so
128 of them, 256 levels, need more than 2 MiB in a debug build. Keep
recursive types small, or give the thread that reads them a larger stack.

## JSON

The two JSON mappings of spec §16, with a strict reader (I-JSON: no duplicate
member names, no unpaired surrogates, the limits of §7, number text kept
exactly) and a writer, both in `haus::json`. No new dependencies.

| | Function |
|---|---|
| JSON without a schema (§16.1) | `haus::from_json(text) -> Value` (`null` is `None`, `true` is `True`) |
| Lossless (§16.2) | `haus::to_lossless_json(&value)`, `haus::from_lossless_json(text)`: `{"num": "19.90"}`, `{"tag": "Some", "args": […]}` |
| Plain, with a type (§16.3) | `haus::json::to_string(&x)`, `haus::json::from_str::<T>(text)` for any `T: ToJson` / `FromJson` |
| JSON Lines | `haus::json::to_string_all`, `from_str_all`, and `encode` / `decode` over `std::io` |
| The JSON tree | `haus::Json` (numbers as text), `haus::json::parse`, `haus::json::write` |

haus-fmt-build implements `ToJson` and `FromJson` for every generated type; the
prelude types implement them in `haus`. `Int`, `Int64` and `UInt64` are
strings (`"-12"`), `Decimal` a string with its scale (`"19.90"`), `Bytes`
base64, floats in the spelling of §15 (`"NaN"`, `"Infinity"`, `"-Infinity"`
as strings), a closed variant of tags without payload a string (`"Debug"`),
other variants objects with `"_tag"` (`{"_tag": "Circle", "r": 1.5}`,
`"value"`, `"values"`), unknown tags `{"_tag": …, "args": […]}` with the
arguments in the lossless form, and `Any` its lossless form. A `Maybe` is
`null` or the value when its inner JSON can't be `null`, and tagged otherwise:
each type says so in `ToJson::NULLABLE`. A `Secret` is written in full, and a
read error inside it names only its place and type. A record payload with a
field named `_tag` has no plain form: writing or reading it is an error.

JSON may nest 4·256 + 1 levels, so that the lossless form of a value at the
depth limit is readable. Reading it with a type counts the levels of the haus
value as it goes (`FromJson::from_json_with` takes a `haus::Decoder`, as
`ToJson` takes an `Encoder`), so JSON nested deeper than the depth limit fails
there instead of recursing on; `json::from_str` then encodes the result to
check it (so it needs `T: Encode` too). The reader and writer use no call
stack per level.

```sh
cargo test                                                   # everything, with the conformance suite
cargo run -p haus --example errors -- ../test-suite/invalid/*.haus   # print each syntax error
```
