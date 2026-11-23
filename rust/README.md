# haus for Rust

| Crate | What it is |
|---|---|
| [`haus-fmt`](haus) | Imported as `haus`. Parser, data model (`haus::Value`), `Decode`/`Encode`, std/time, codecs, compact writer, JSON (`haus::json`). Passes the [conformance suite](../test-suite), JSON suite included. |
| [`haus-fmt-schema`](haus-schema) | Imported as `haus_schema`. Schema files parsed, their imports resolved (std/time, schema packages, relative files) and checked (spec §14); data decoded and checked against them at runtime (spec §15), with positions, hints for unknown and deprecated fields and tags, and `Secret`s never shown. What `haus check` uses. Passes the schema conformance suite. |
| [`haus-fmt-build`](haus-build) | Imported as `haus_build`. Rust types from `.schema.haus` files, generated in `build.rs`. Also `haus-gen`, which generates the Roc modules. Uses `haus-fmt-schema` for parsing and resolving schemas. |
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

## Checking data at runtime

```rust
let schema = haus_schema::Schema::load("order.schema.haus", &haus_schema::NoImports)?;
for issue in schema.check_text("Root", &text) {                  // every problem, with positions and hints
    let at = issue.position.unwrap();
    println!("{}:{}: {} {}", at.line, at.column, issue.severity, issue);
}
let value = schema.decode("Root", &haus::parse(&text)?[0])?;     // spec §15: the value an encoder writes back
```

`check_text` reports every error (spec §14, "Every error") and the hints, up
to `MAX_ISSUES` (200): each failing place once, nothing below a value that
failed at its own level (a wrong kind or tag), an error inside a `Secret` once
at the secret, and after a syntax or limit error that one error. The issues
are a set: their order is not part of the result. `check_text_report` (and
`check_report` for parsed values) takes `CheckOptions { first, limits }`,
`first` to stop at the first error with the hints before it, and returns a
`CheckReport` whose `stopped` says that the check stopped at the cap.

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
let json = haus::json::to_string(&order)?;                // schema-based JSON (spec §16.3)
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
deprecated types in a schema and record cases with a field named `_tag` or
`_args`, which have no schema-based JSON form (`no-json-form`);
`Config::quiet()` turns them off. So is `missing-codec` (spec §13.4): the
schema's types reach a type that an official profile has a rule for
(`@haus-fmt/money@1#Currency`, `@haus-fmt/geo@1#LatLng`,
`@haus-fmt/geo@1#BBox`, `@haus-fmt/uuid@1#Uuid`) with no `.codec(…)` for its id, so its values are
checked for their shape only. A type reached only inside a type with a codec
doesn't count: a codec for `Money` (`haus_money::Iso`) covers its `Currency`.
`haus-gen roc` prints the same warning for its `--codec`s.

Writing checks what it writes, so `haus::to_string` returns a `Result`.
`haus::to_string_minimised` writes the minimised layout of spec §11
(`Person{name:"Ada",age:36}`) instead of the compact one, for the wire and
storage, with the same checks.
`Encode::encode_with` (and `ToJson::to_json_with`) take a `haus::Encoder`,
which carries the limits and counts the depth while the native value is
traversed: a value nested deeper than the limit fails there with the writer's
error (`[0][0]…: nesting deeper than 256 levels`), however deep it goes. It
also counts the values it makes, against the node limit
(`Limits::max_nodes`, 64 Mi): a value whose parts are shared, an `Rc`
reached many times (a DAG), fails with `too-many-nodes` instead of expanding
without bound (spec §7, §9.8). `Decode::decode_with` takes a `haus::Decoder` in
the same way: a `Value` built in code, which no parser limited, fails with
`nesting-too-deep` at the depth limit before decoding recurses past it, also
inside an `Any` or the payload of an unknown tag. Any
other failure comes from a `haus::Value` built in code, the raw value of an
`Any` or an unknown variant, beyond the limits (spec §7, §11): nesting
(`nesting-too-deep`, a record that is a tag's only payload sharing the
payload's level), the length of strings, keys and tags (`string-too-long`,
`key-too-long`, `tag-too-long`), the length and exponent of numbers
(`.extra: number literal longer than 1000 characters`,
`exponent-too-large`), and the values written (`too-many-nodes`, at `$`).
For a reader with other limits,
`haus::to_string_with(&value, &limits)` checks those: integers are written in
decimal, and one longer than its number limit is an `EncodeError`
(`number-too-long`).

### Values built in code

A `haus::Value` is always a haus value (spec §11, "Values built in code"):
its parts' constructors reject what isn't one with a `haus::ValueError` and
the code of the mistake, so nothing built can fail later for that reason.

```rust
use haus::{Number, Record, Tag, Value};

let mut order = Record::new();
order.insert("id", 255)?;                                  // integers, strings, bytes, arrays, bools: `From`
order.insert("total", Value::number("19.90")?)?;           // invalid-number: "01", "NaN", ""
order.insert("status", Value::variant("Paid", vec![])?)?;  // invalid-tag: "paid", "A-B"
order.insert("id", 1).unwrap_err();                        // duplicate-key
let order = Value::from(order);
Number::new("1E+05")?;                                     // normalized as the parser reads it: 1e5
Record::from_fields([("a", Value::from(1)), ("b", Value::from(Tag::new("None")?))])?;
```

`Number::new` normalizes the literal as the parser does (`1E+05` is `1e5`,
`0xFF` is `255`, `1_000` is `1000`), with no limit on its length or
exponent: constructors check only that a value is valid, and limits are the
writer's. `Record::insert` rejects a key the record has already
(`duplicate-key`, leaving the record as it was) rather than replacing its
value; to change a field, use `Record::get_mut`. It takes time linear in the
key, also for records with many keys. `Number` and `Tag` deref to their
text, and a `Tag` compares with a `&str` (`tag == "None"`). The JSON value
type is checked the same way: `haus::json::JsonNumber::new` takes only a JSON
number, and a `haus::json::JsonObject` (`Json::Object`) has each member name
once (`JsonObject::insert`, `JsonObject::from_members` and `Json::object`
reject a name twice with `duplicate-key`).

`haus::Int` is an integer of any size, kept as its digits and written back
unchanged. `to_i64()` / `to_i128()` give it as a native integer when it fits; the
`bigint` feature adds conversions to and from `num_bigint::BigInt`. For a native
integer that must fit, the schema says `Int64` (out of range is a decode error).

A schema can be split into files: `import ./common (Address)` reads
`common.schema.haus` next to it (spec §13.3). The files it imports, directly
or not, are generated into the same output, each as a module named after its
path from the schema's directory: `order::common::Address`,
`order::billing_common` for `billing/common.schema.haus`,
`order::up_shared_money` for `../shared/money.schema.haus`. Their ids are
their paths in the crate (`my-app/src/billing/common#Address`), so two
`common.schema.haus` in different folders are different files. Two schemas
compiled separately each get their own copy of a file both import.
Relative imports stay inside the build's root (spec §13.3): for
`Config::compile`, the crate's directory (`CARGO_MANIFEST_DIR`, for a schema
inside the crate; `Config::root` widens it, relative to the crate's
directory, such as `.root("..")` to share files with a sibling crate); for
`haus_schema::Schema` and `haus-gen`, the schema's real directory unless
`Options::root` or `--root` says otherwise (a relative one is relative to
the schema's real directory). The schema and the root are resolved to real
paths once, at the start. `..` names above the root are
`import-outside-root`, rejected before anything is looked at; a relative
import follows no symbolic link: each name of its path must be listed by
its directory with that spelling and must not be a link
(`import-not-found`, without saying where the link points), and a file in
a package's directory, looked for up to the root, is `package-path` (a
directory there that can't be listed is `import-not-found`). Messages show
paths relative to the root. Every schema
file is read as a regular file, opened by its real path without following
a link and without blocking. Packages are given explicitly or come from
Cargo: this binding never looks in `node_modules`.

Schema packages are ordinary dependencies: a crate with `package.haus` and
`schema.haus`, `links = "<its library name>"`, `haus_build::package()` in its
build script and `haus::include_schema!("schema")` in its `lib.rs`. A crate
that depends on it directly can `import @org/name (…)`; the types are the
package crate's own (`haus_money::Money`), so codecs written for them work in
every crate. haus-fmt-schema never prints (it backs tools whose output must stay
clean); haus-fmt-build tells Cargo to rerun when a package's files change,
from `Packages::files()`.

- Generated code names a package's crate by its `links`, so `links` must be
  the library name; `haus_build::package()` checks that, and that the crate's
  version is the one in `package.haus` (`package-version`).
- **Don't rename schema package dependencies** (`money = { package =
  "haus-fmt-money", … }`): generated code refers to `::haus_money`, which a
  renamed dependency isn't, and rustc reports `E0433` inside the generated file.
- Imports are checked as everywhere (spec §13.3): `@org/name@2` with version
  1.4.0 installed is `import-version`, two packages with one name are
  `duplicate-package`. A crate's own files import only its direct
  dependencies (`undeclared-package` otherwise); the packages those import
  are found through them: `haus_build::package()` passes on the packages its
  schema reaches (`cargo::metadata=haus_graph=…`) and re-exports its
  dependencies' crates (`__haus_deps`, hidden), so generated code can name
  `::haus_orders::__haus_deps::haus_ledger::Note` without the crate
  depending on `haus_ledger`.
- A codec applies wherever its type occurs (spec §13.4), inside packages'
  types too: the packages' types that contain the codec's type, directly or
  not (`@acme/orders@1#Order` with a `@haus-fmt/money@1#Money` inside), are
  generated again in your crate, one module per package
  (`order::acme_orders::Order`), with the codec applied. The packages'
  other types stay their crates' own (`haus_orders::Customer`), so code
  that uses them works with every crate. Without codecs, nothing is copied,
  and a type with a codec of its own isn't either: its codec decodes the
  package's type.

The official profiles (spec §13.3) are codecs of the official crates. They
reject what the profile rejects and keep the value (spec §13.4):

| Crate | Codec | For | Rust type |
|---|---|---|---|
| `haus_money` | `Iso` | `@haus-fmt/money@1#Money` | `IsoMoney { amount: Decimal, currency: CurrencyCode }`: the exact amount, scale kept |
| `haus_money` | `IsoCurrency` | `@haus-fmt/money@1#Currency` | `CurrencyCode`: three letters A–Z |
| `haus_geo` | `Wgs84` | `@haus-fmt/geo@1#LatLng` | `Point` (`lat()`, `lng()`): the floats as decoded, `-0` kept |
| `haus_geo` | `Wgs84BBox` | `@haus-fmt/geo@1#BBox` | `Bounds` (`sw()`, `ne()`, `crosses_antimeridian()`) |
| `haus_uuid` | `Rfc9562` | `@haus-fmt/uuid@1#Uuid` | `UuidText` (`as_str()`): the text, lowercase, any version |

```rust
haus_build::Config::new()
    .codec("@haus-fmt/money@1#Money", "haus_money::Iso")
    .codec("@haus-fmt/money@1#Currency", "haus_money::IsoCurrency")
    .codec("@haus-fmt/geo@1#LatLng", "haus_geo::Wgs84")
    .codec("@haus-fmt/geo@1#BBox", "haus_geo::Wgs84BBox")
    .codec("@haus-fmt/uuid@1#Uuid", "haus_uuid::Rfc9562")
    .compile("app.schema.haus")?;
```

Register both codecs of a package: `Iso` alone leaves a `Currency` outside a
`Money` unchecked, `Wgs84` alone leaves a `BBox`'s latitude order unchecked.

Streams (spec §6) are read as the values arrive: `haus::stream::decode::<T, _>(reader)`
is an iterator over any `std::io::Read`, and `haus::stream::encode` writes one value per
line (`encode_with` for other limits). `haus::stream::Reader` does no I/O itself (push byte chunks, split anywhere, get
the completed values), so an async adapter is a short loop around it.

Without a schema, `haus::parse` reads any haus text into `Value`s: a parser in
the sense of spec §13.1, which knows no types. `haus::parse_one` reads a
single document: exactly one value, or `not-one-value` at the end of the
input (spec §6).

## Error codes

Every error has a code from the catalogue of spec §17 ([`spec/errors.md`](../spec/errors.md)),
the same in every binding: `haus::ErrorCode`, an enum (`ErrorCode::PayloadNewline`)
whose `as_str()` is the code (`payload-newline`), with its `category()`, the
catalogue's fix as `hint()`, and `docs()`, `https://haus-fmt.org/docs/errors#<code>`.
`ErrorCode::from_name("payload-newline")` goes the other way.

| Error | Code | Also |
|---|---|---|
| `haus::SyntaxError` (haus text, JSON text) | `.code` | `line`, `column`, `expected()`, `found()`, `hint()` |
| `haus::DecodeError`, `haus::EncodeError` (typed values, JSON mappings) | `.code` | `path`, `place()` (`$.items[2].price`), `expected()`, `found()`, `hint()` |
| `haus::Error` (any of them, or I/O) | `code()`, None for I/O | |
| `haus_schema::Error`, `Warning` (schema files, imports) | `code()` | `position()`, `hint()` |
| `haus_schema::Issue` (checking data) | `.code` (`missing-field`; hints: `unlisted-field`, `deprecated`, …) | `position`, `path_string()` |

`hint()` is a fix for the case at hand where one is known (`Put the payload on
the same line as Heartbeat, …`), else the catalogue's. Each of them has
`to_json()`, the JSON form of §17, written with haus's own JSON writer:

```rust
let e = haus::parse("Heartbeat\n{ at: 1 }").unwrap_err();
assert_eq!(e.code, haus::ErrorCode::PayloadNewline);
println!("{}", e.to_json());
// {"code":"payload-newline","message":"expected ',' between top-level values, found '{'","line":2,"column":1,
//  "expected":"','","found":"'{'","hint":"Put the payload on the same line as Heartbeat, …","docs":"https://haus-fmt.org/docs/errors#payload-newline"}
```

`haus::ErrorJson { … }.write()` gives the same form for errors of your own.
The table of codes, `haus/src/error_codes.rs`, is generated from
`spec/errors.haus` by a test, which reads the catalogue with this crate's
parser and fails when the file is out of date; regenerate it with
`HAUS_WRITE_ERROR_CODES=1 cargo test -p haus-fmt --test error_codes`. The
conformance tests compare codes (`invalid/NAME.error`, `code` in `Err` cases),
and every example of the catalogue gives its code.

## Formatting

`haus::format(text, &options)` writes a file in one of the three layouts of spec §11,
byte for byte the same as the TypeScript formatter (both pass the
[format suite](../test-suite/format)):

```rust
let pretty = haus::format(&text, &haus::FormatOptions::default())?;   // keeps comments and blank lines
let compact = haus::format(&text, &haus::FormatOptions { style: haus::Style::Compact, ..Default::default() })?;
let minimised = haus::format(&text, &haus::FormatOptions { style: haus::Style::Minimised, ..Default::default() })?;
```

| `FormatOptions` field | Default | |
|---|---|---|
| `style` | `Style::Pretty` | `Pretty`: one entry per line in every non-empty record and array, comments and blank lines (at most one) kept. `Compact`: every top-level item on one line, comments dropped. `Minimised`: compact without whitespace between tokens (`Person{name:"Ada",age:36}`), for the wire and storage. |
| `indent` | 2 | Spaces per level. |
| `width` | 80 | Positional payloads like `Money(7.90, EUR)` stay inline up to this width, counted in code points and including the comma after the entry. |
| `limits` | `Limits::default()` | The limits the text is parsed with. |

Numbers, single-line strings and byte strings keep their source spelling
(`0xFF` stays `0xFF`, `x"9f86 d081"` keeps its blank, also in minimised), and
formatting the output again changes nothing. Every layout escapes U+2028 and
U+2029 in strings, and no line of a pretty block string ends in a space or
tab (the last one is written `\u{20}` or `\t`), so an editor that trims
trailing whitespace can't change the value. A tool that rewrites a file in
place in compact or minimised should refuse when `haus::has_comments` is
true, unless asked to drop them (spec §11). A text
that doesn't parse gives the same `SyntaxError` as `haus::parse_with`. The
formatter uses no call stack per level of nesting: at
`haus::MAX_SUPPORTED_DEPTH` the parser that checks the text is the deepest
part, within a 2 MiB thread.

## Canonical form and hashing

The canonical form (spec §12) is one exact text per value, the same in every
binding; hashes are SHA-256 of it (the `hash` feature):

```rust
let v = haus::parse(r#"Order { total: 19.90, id: 0xFF }"#)?.remove(0);
haus::canonical(&v);                   // String: Order{id:255,total:19.90}
haus::hash(&v);                        // String: 64 lowercase hex digits
haus::hash_all(&values);               // a whole file: the forms joined by `,`
haus::equals(&a, &b);                  // bool
haus::compare(&a, &b);                 // Ordering, by the canonical bytes
```

Every value has a canonical form, also one built in code (its constructors
take only haus values, see above), and none of these fail: numbers are
written in decimal, an integer of any size with all its digits, also one
built in code or parsed with a larger `max_number_length`. A number built
from another spelling (`Number::new("1E+05")`) is normalized already, so it
hashes as the value parsed from it. No limit applies: a value deeper or
longer than a writer's limits still has a canonical form. Nor does the node
limit of spec §7: a `Value` owns its parts, so it can't share them and
expand when written; its canonical form is linear in the memory it takes.
`equals` compares the values themselves, records whatever the order of
their keys, without writing their canonical forms.

A `Value` or `haus::Json` built in code may nest any depth (spec §7): the
canonical form, `==`, `clone` and dropping it take a stack on the heap, not
one call per level, and `{:?}` shows the first `haus::DEBUG_DEPTH` (64)
levels, then `…` (the writers recurse, and stop at the depth limit). Tested
with a million levels in a 512 KiB thread. As `Value` and `Json` implement
`Drop`, take their parts out with a reference
(`if let Value::Array(items) = &mut v { std::mem::take(items) }`) rather than
by moving them out of a `match`. Types that haus-fmt-build generates for a
recursive schema type (`Box<Tree>`) drop the way Rust drops them, one call
per level: a value built in code far deeper than the depth limit can
overflow the stack when dropped (decoding never builds one).

## Threads

Every type you share is `Send` and `Sync`, checked at compile time: values, `Limits`, `FormatOptions`, errors and a built `haus_schema::Schema`. Parsing, writing, formatting, the canonical form, hashing and equality keep their state in the call, so they can run on many threads at once (spec §9).

## Limits

Reading enforces the limits of spec §7, `haus::Limits`: by default a depth of
256, number literals of 1000 characters (hex literals of at most 829 hex
digits, `Limits::max_hex_digits()`, so that every integer fits in decimal),
exponents up to 6144, and strings, record keys and tags of 16 Mi characters.
Writers check the same limits for the value they write, and also the node
limit, `max_nodes`: at most 64 Mi values written for one value (spec §7,
"Values written"), which ends a native value whose parts are shared (an
`Rc` reached many times) and would expand without bound. The node limit
applies to writers only: a `Value` owns its parts, so it can't share them,
and the canonical form and hashing need no limit. A writer of several
values (a stream, `to_string_all`, JSON Lines) counts each on its own and
reports an error in value i at `$[i]`. Every reader and writer has a version that takes
other limits:

| | With limits |
|---|---|
| haus text | `haus::parse_with`, `haus::stream::Reader::new(Options { limits, .. })`, `stream::values_with` |
| decoding a `Value` | `Decode::decode_with(&value, Decoder::new(&limits))` |
| writing for such a reader | `haus::to_string_with`, `haus::ser::write_with`, `stream::encode_with`, `Encode::encode_with(Encoder::new(&limits))` |
| JSON | `json::parse_with`, `json::write_with`, `json::from_str_with`, `json::to_string_with`, `json::to_haus_json_with`, `json::from_haus_json_with`, `json::import_json_with`, `json::to_self_describing`, `json::from_self_describing`, `json::import`, `FromJson::from_json_with(json, Decoder::new(&limits))` |

`haus::MAX_SUPPORTED_DEPTH` is 256, the default: the parser, decoding,
encoding and the JSON mappings recurse once per level of nesting, so this
crate supports no deeper limit (lower ones are fine). Every function above
rejects a larger `max_depth` before reading or writing anything, with an
error that names the maximum: `max_depth 300 is more than the supported
maximum, 256`. The JSON reader and writer and the canonical form use no call
stack per level.

At 256 levels, the deepest paths, the parser and the self-describing JSON of
nested variants, take up to about 1.5 MiB of stack in a debug build and less
than 0.5 MiB in a release build (measured on aarch64 macOS): within the 2 MiB
stack of a spawned thread, a test thread or an async task, and the 8 MiB of a
main thread. In a release build every path also fits a 512 KiB thread (a
secondary thread's default on macOS), as spec §7 asks to test (`cargo test
--release` runs those tests; a debug build skips them, and 256 is the least
maximum the spec allows, so it can't be lowered to fit). Code that
haus-fmt-build generates for a recursive type takes stack in proportion to the
type's size: a record of 30 fields that holds itself in a `Maybe` takes about
18 KiB per record to encode in a debug build (7 KiB in a release build), so
128 of them, 256 levels, need more than 2 MiB in a debug build. Keep
recursive types small, or give the thread that reads them a larger stack.

## JSON

The three JSON forms of spec §16, with a strict reader (I-JSON: no duplicate
member names, no unpaired surrogates, the limits of §7, number text kept
exactly) and a writer, both in `haus::json`. No new dependencies. The caller
says which form it reads: the data never decides.

| | Function |
|---|---|
| Schema-based JSON, with a type (§16.3) | `haus::json::to_string(&x)`, `haus::json::from_str::<T>(text)` for any `T: ToJson` / `FromJson` |
| Self-describing JSON (§16.2) | `haus::to_haus_json(&value)`, `haus::from_haus_json(text)`: `{"_haus": 1, "_value": {"_tag": "Some", "_args": [{"_num": "19.90"}]}}` |
| JSON import, without a schema (§16.1) | `haus::import_json(text) -> Value` (`null` is `None`, `true` is `True`); it only reads |
| JSON Lines | `haus::json::to_string_all`, `from_str_all`, and `encode` / `decode` over `std::io`; `to_haus_json_lines`, `from_haus_json_lines` (an envelope per line) |
| The JSON tree | `haus::Json` (numbers as text), `haus::json::parse`, `haus::json::write` |

haus-fmt-build implements `ToJson` and `FromJson` for every generated type; the
prelude types implement them in `haus`. `Int`, `Int64` and `UInt64` are
strings (`"-12"`), `Decimal` a string with its scale (`"19.90"`), `Bytes`
base64, floats in the spelling of §15 (`"NaN"`, `"Infinity"`, `"-Infinity"`
as strings), a closed variant of tags without payload a string (`"Debug"`),
other variants objects with `"_tag"` (`{"_tag": "Circle", "r": 1.5}`,
`"value"`, `"values"`; a record case has its fields beside `"_tag"` however
the record is written, so `Circle Disc` with `type Disc = { r: Float64 }`,
which Rust keeps as `Circle(Disc)`, writes the same as `Circle { r: Float64 }`), unknown tags `{"_tag": …, "_args": […]}` with the
arguments' self-describing values, and `Any` its self-describing value, both
without the envelope. A `Maybe` is
`null` or the value when its inner JSON can't be `null`, and tagged otherwise:
each type says so in `ToJson::NULLABLE`. A `Secret` is written in full, and a
read error inside it names only its place and type. A record payload with a
field named `_tag` or `_args` has no schema-based form: writing or reading it
is an error. Writers escape DEL, C1 and bidi controls as well as what JSON
requires; the self-describing reader rejects them raw.

Schema-based JSON may nest 4·256 + 1 levels and self-describing JSON one more
for its envelope, so that the forms of a value at the depth limit are
readable; the import's JSON nests 256. Reading it with a type counts the levels of the haus
value as it goes (`FromJson::from_json_with` takes a `haus::Decoder`, as
`ToJson` takes an `Encoder`), so JSON nested deeper than the depth limit fails
there instead of recursing on; `json::from_str` then encodes the result to
check it (so it needs `T: Encode` too). The reader and writer use no call
stack per level.

```sh
cargo test                                                   # everything, with the conformance suite
cargo run -p haus-fmt --example errors -- ../test-suite/invalid/*.haus   # print each syntax error and its code
```
