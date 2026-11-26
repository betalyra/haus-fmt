# haus for Zig

The Zig binding of the haus data format, for Zig 0.17, with a C ABI
(`libhaus`, [`include/haus.h`](include/haus.h)) for C and every language that
calls C.

It is also the project's check of its specification. It is written from the
specification ([`../spec`](../spec)) and the conformance suite
([`../test-suite`](../test-suite)) only, never from another binding's code:
where the spec wasn't complete or clear, the choice made is noted (and checked
against the Lean reference, `haus-ref`, as a black box). It implements the
specification's core and its package layer ([`../spec/packages.md`](../spec/packages.md),
draft 0.1) without the npm and Cargo ecosystems. For the shape of its
public API, it looked at the other bindings' READMEs and examples, nothing else.

## Install

There is no Zig package registry: each release is a tarball on GitHub.

```sh
zig fetch --save=haus https://github.com/betalyra/haus-fmt/releases/download/zig-v0.1.0/haus-zig-0.1.0.tar.gz
```

```zig
// build.zig
const haus = b.dependency("haus", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("haus", haus.module("haus"));
// libhaus and haus.h, for C code in the same build:
exe.root_module.linkLibrary(haus.artifact("haus"));
```

A C project builds the library from this directory (or takes it from the
release, built for several targets):

```sh
zig build -Doptimize=ReleaseFast                       # zig-out/lib/libhaus.a, zig-out/include/haus.h
zig build -Doptimize=ReleaseFast -Dlinkage=dynamic     # libhaus.so / .dylib / haus.dll
cc app.c $(PKG_CONFIG_PATH=zig-out/lib/pkgconfig pkg-config --cflags --libs haus)
```

The static library carries Zig's compiler runtime, so any C toolchain links
it; it needs no libc.

## What is implemented

| | |
|---|---|
| Values, equality, order (§1, §2) | `Value`, `equals`, `compare` (by canonical bytes) |
| Numbers (§3) | exact: the normalized literal; hex and binary to decimal of any size |
| Strings (§4) | UTF-8, escapes, block strings, control and bidi characters |
| Parser (§1–§8, §17) | `parseAll` (a file), `parse` (one document, `not-one-value`), `parseDocument` (with positions and comments); every error with its code, line and column |
| Streams (§6, §7) | `StreamReader`: chunks of bytes in, values out once their comma arrives; the value limit and strict mode; the same results for every way of cutting the input |
| Limits (§7) | `Limits`, the spec's defaults, all configurable; the depth this binding supports is 256 (`unsupported-depth` above): the parser, writers, formatter, decoder and JSON readers recurse once per level, and at 256 all of them run on a thread with a 512 KiB stack in ReleaseSafe and ReleaseFast (tested; decoding with codecs needs 1 MiB there, also tested); ReleaseSmall needs more than 512 KiB, and a Debug build about 2 MiB. `canonical`, `hash`, `equals` and `compare` take any depth |
| Layouts (§11) | `format` (a document's text, spellings as written, comments in pretty), `stringify`, `stringifyAll` (values); pretty with `indent` and `width`, compact, minimised; `.stream = true` for `format` and `stringifyAll`: the file is a stream, so a single item has a comma after it too (a file of none or several is written as without it) |
| Canonical form and hashes (§12) | `canonical`, `hash`, `hashAll` (SHA-256 of `std.crypto`) |
| std/time (§13.2) | `time.check(kind, text)`: the std/time profile |
| Schema files (§14) | `schema.load`: the grammar, names, arities, parameters, spreads, `Stream`, attributes, guarded and growing recursion; warnings (`unknown-attribute`, `deprecated`, `no-json-form`) with their line and column; every type's id (`Def.id`, §13.3 "Identity") |
| Decoding (§15) | `decoding.decode` to a `Decoded` (a `Secret` is hidden, below), `decoding.encode`, `decoding.decodeText`, `TypedStreamReader` (`$[i]` places; items are read one at a time, so an item's error comes before a syntax error in a later item), `decoding.check` / `checkWith` / `checkReport` (as a checker reports them, §14 "Every error": the hints and every error, each once (two missing fields are two `missing-field` at the record); a document with a syntax or limit error has that one error; a `Stream` is checked item by item, the items' errors before the syntax error that ends it, which has a line and column and no path; nothing below a value that failed at its own level, any error inside a `Secret` one `invalid-secret` at it; `.first = true` stops at the first error, with the hints found before it; at most `max_errors` errors in the whole check, hints not counted, 200 by default, and `CheckReport.stopped` says when it stopped). Decoding still ends at the first error |
| Codecs (§13.4) | `Codec(T)`, `decoding.rule`, `Codecs` by type id; std/time as Zig values and the official profiles' rules in `codecs` (below) |
| JSON (§16) | `json.importJson` (§16.1), `json.toHausJson` / `fromHausJson` / `fromHausJsonLines` (§16.2), `json.toJson` / `fromJson` (§16.3) |
| Packages (§13.3) | `packages.build(gpa, io, entry, options)`: packages given by directory, by folder, or as file trees in code (`packages.Tree`: files embedded with `@embedFile`, or a directory handle); the build's root (`import-outside-root`); no links followed in relative imports; regular files only, checked on the open handle; names spelled as their directory lists them; manifests, the version check, duplicates, cycles and the limits; messages show paths relative to the root. This binding belongs to no package manager's ecosystem: it never reads `node_modules` |
| C ABI | `include/haus.h`, `src/c_api.zig` (below) |

A decoded `Secret` (`Decoded.secret`, a `Decoded.Hidden`) shows nothing of its
value (spec §15, "Hiding"): `{f}` prints `<redacted>`, `{any}` an opaque
pointer, `std.json` `"<redacted>"`, and `decoding.toValue` (the value without
its schema, for the canonical form, the hash, the writers, `equals` and
`compare`, which take `Value`s only) refuses it with `cannot-encode` at the
secret's place. `reveal()` and `decoding.toValueRevealed` are the explicit
calls that give it out; `decoding.encode` and `json.toJson` write it in full,
with its schema.

`Value` is a plain union, so a value built in code passes no constructor: it is
checked where it is written (spec §11, "Values built in code"), with the codes a
constructor would use (`invalid-number`, `cannot-encode`, `invalid-tag`,
`duplicate-key`). The writers apply every limit of spec §7, the canonical form,
`hash`, `equals` and `compare` only the node limit.

## Use

```zig
const haus = @import("haus");

var d: haus.Diagnostic = .{};
const parsed = haus.parseAll(gpa, text, .{ .diagnostic = &d }) catch |e| switch (e) {
    error.Haus => {
        std.debug.print("{s} at {d}:{d}: {s}\n", .{ d.code.name(), d.line, d.column, d.message() });
        return e;
    },
    else => return e,
};
defer parsed.deinit();
const h = try haus.hashAll(gpa, parsed.value, .{}); // 64 hex digits
const pretty = try haus.format(gpa, text, .{ .indent = 2, .width = 80 });
defer gpa.free(pretty);
```

With a schema and the packages it imports:

```zig
const build = try haus.packages.build(gpa, io, "order.schema.haus", .{ .folders = &.{"vendor/haus"} });
defer build.deinit();
const root = build.root.get("Root").?;
const order = try haus.decoding.decodeText(gpa, arena, root, text, .{ .diagnostic = &d });
const total = order.get("total").?; // a Decoded
```

Every function that allocates takes an allocator. Errors are `error.Haus` (a
mistake with a code of spec §17, described by the `Diagnostic` passed in the
options; a decoder's error has its place, `d.path()`, `$.lines[0].qty`) or
`error.OutOfMemory`.

## Codecs

A codec (spec §13.4) lets the application choose the Zig type of a named type
without arguments. It is selected by the type's **id**: `@haus-fmt/money@1#Money`
for a package's type, `std/time#Date`, `prelude#Decimal`, and, for a file
outside a package, `local#Name` (a schema loaded from text) or
`./path/from/root.schema.haus#Name` (a file of a build). Without a codec a value
decodes to its default host type, which keeps the value: a `Decimal` as its
exact text, a std/time value as its checked text.

```zig
const Amount = struct { cents: i128, currency: [3]u8 };

const cents = haus.Codec(Amount).init("@haus-fmt/money@1#Money", decodeAmount, encodeAmount);
// fn decodeAmount(arena: Allocator, d: Decoded, reason: *Reason) CodecError!Amount
// fn encodeAmount(arena: Allocator, a: Amount, reason: *Reason) CodecError!Decoded

var codecs = try haus.Codecs.init(gpa, &.{ cents.erased(), haus.codecs.time.date.erased() });
defer codecs.deinit(gpa);
const d = try haus.decoding.decodeText(gpa, arena, root, text, .{ .codecs = &codecs });
const amount: Amount = cents.get(d.get("total").?).?;
// Encoding: put host values back with `wrap`, then encode with the same codecs.
const total = try cents.wrap(arena, amount);
```

The contract, as this binding keeps it:

- A codec runs after the type's schema, on what the schema decoded: it can
  reject more values, never fewer. A rejection (`return reason.reject("…", .{})`)
  is `codec-rejected` at the type's place, with the message
  `<id> rejects the value: <reason>`. Inside a `Secret` it is `invalid-secret`
  at the secret, as every error there is.
- Any named type without arguments can have one: the prelude's
  (`prelude#Decimal`, in every package's types too), std/time's, a
  package's, the application's own; and the type a value is decoded with
  (decoding `CHF` as a `Currency` runs the `Currency` codec).
- Codecs run from the inside out: a codec receives the host values of the
  codecs inside its type (a `Money` codec sees the `Currency` codec's value),
  and each host value keeps what the schema decoded (`Decoded.schemaValue()`).
  The first rejection, the innermost, is the error.
- A profile's rule is checked on what the schema decoded, never on what an
  inner codec made of it: `decoding.rule` gives its rule
  `Decoded.schemaView()`, and the shipped rules (`money.acceptsMoney`, …)
  look through host values. So with `money.iso_money`, `Money(19.90, Bitcoin)`
  is `codec-rejected` whatever codec is set for `Currency`.
- A codec applies wherever its type occurs: inside imported packages' types,
  for a record case's payload (`Shipped Address`), in typed streams. A decoded
  value always has a place of its own for a host value (`Decoded.host`), so
  `codec-unreachable` never happens here.
- `encode` writes a host value with its codec's `encode`, then checks the
  value written with the type and the codecs passed (`.codecs`): a value a
  codec rejects is `cannot-encode` at the codec's type's place (inside a
  `Secret`, `invalid-secret` at the secret, without the codec's reason), so
  decode, encode, decode is the same as decode.
- `decoding.rule(id, accepts)` is a codec that keeps the default host type and
  adds a rule (a profile). `Codecs.init` rejects two codecs for one id
  (`error.DuplicateCodec`).
- `decoding.unusedCodecs(arena, &codecs, schemas)` (or
  `build.unusedCodecs(arena, &codecs)`) gives the `unused-codec` warnings: a
  codec whose id no type has (`@haus-fmt/money@2#Money` with a schema that
  imports major 1) never runs. Once per id, at no place; decoding is
  unchanged. The `missing-codec` warning is not reported.
- `json.toJson` takes host values (it encodes them first); `json.fromJson`
  gives the default host types: `decoding.applyCodecs` runs the codecs on its
  result.

### Codecs this binding ships (`haus.codecs`)

None is on unless the application lists it.

| Codec | Type | Zig type | Drops (spec §13.4) |
|---|---|---|---|
| `time.date` | `std/time#Date` | `Date` (year, `std.time.epoch.Month`, day; `epochDay`, `weekday`) | nothing |
| `time.year_month` | `std/time#YearMonth` | `YearMonth` | nothing |
| `time.time_of_day` | `std/time#Time` | `TimeOfDay` (nanoseconds) | trailing zeros of a fraction (`.250` is written `.25`) |
| `time.date_time` | `std/time#DateTime` | `DateTime` | the same |
| `time.instant` | `std/time#Instant` | `Instant` (with its offset; `timestamp()`) | the same, and `+00:00` is written `Z` |
| `time.instant_timestamp` | `std/time#Instant` | `std.Io.Timestamp` (UTC) | also the offset: written with `Z` |
| `time.duration` | `std/time#Duration` | `std.Io.Duration` | how the time is split (`PT90M` is written `PT1H30M`); rejects years, months, weeks and days, which have no fixed length |
| `money.iso_money`, `money.iso_currency` (`money.iso`) | `@haus-fmt/money@1#Money`, `#Currency` | the default | nothing: the rule of `@haus-fmt/money/iso` |
| `geo.wgs84_lat_lng`, `geo.wgs84_bbox` (`geo.wgs84`) | `@haus-fmt/geo@1#LatLng`, `#BBox` | the default | nothing: the rule of `@haus-fmt/geo/wgs84` |

Where a codec drops something, encoding writes a value that means the same but
isn't equal, with another canonical form and hash: hash and sign parsed values.
The profile codecs pass their vectors (`../extensions/*/profiles/*.vectors.haus`,
run by `zig build test`), and their rules are public (`money.acceptsMoney`,
`geo.acceptsLatLng`, …) so that an application's own codec can build on them,
as `examples/order.zig` does.

## C ABI

[`include/haus.h`](include/haus.h) documents every function. In short:

| | |
|---|---|
| Text in, text out | `haus_canonical`, `haus_hash_all`, `haus_format` (a layout, `HAUS_STREAM` or'ed in for a stream) |
| Docs and values | `haus_parse`, `haus_parse_all`, `haus_doc_count`, `haus_doc_value`; `haus_kind`, `haus_number` (the normalized literal), `haus_string`, `haus_bytes`, `haus_len`, `haus_array_get`, `haus_record_key`, `haus_record_value`, `haus_record_get`, `haus_variant_tag`, `haus_variant_arg`, `haus_secret_reveal`, `haus_number_int64`, `haus_number_double` |
| Building | `haus_doc_new`; `haus_new_number` (any spelling, `invalid-number`), `haus_new_string` (`cannot-encode`), `haus_new_bytes`, `haus_new_array`, `haus_new_record` (`duplicate-key`), `haus_new_variant` (`invalid-tag`) |
| Writing, comparing | `haus_stringify` (layout, indent, width), `haus_stringify_doc` (`HAUS_STREAM` as for `haus_format`), `haus_value_canonical`, `haus_value_hash`, `haus_value_equals`, `haus_value_compare` |
| JSON | `haus_import_json`, `haus_to_haus_json`, `haus_from_haus_json`; with a type `haus_type_to_json`, `haus_type_from_json` |
| Schemas | `haus_schema_load` (text), `haus_schema_build` (a file, with packages by directory, folder or in-memory trees, and a root), `haus_schema_warning_count`/`_warning`, `haus_schema_type`, `haus_type_id`, `haus_type_is_stream`; `haus_decode`, `haus_decode_text`, `haus_encode`, `haus_check_text` (all hints and every error, at most `HAUS_CHECK_MAX_ERRORS` (200) in the whole check, `haus_issues_stopped` when it stopped there; a syntax or limit error has an empty path, and its line and column), `haus_check_text_first` (the hints before the first error, and that error), and the one-call `haus_check`, `haus_to_json`, `haus_from_json` |
| Streams | `haus_stream_new` (strict or not), `haus_typed_stream_new` (a `Stream` type), `haus_stream_push`, `haus_stream_end` |

**Statuses.** `HAUS_OK`, `HAUS_ERROR` (the `haus_error` has the code of §17,
line, column, message and, for a decoder, encoder or JSON reader, the place:
`$.lines[0].qty`), `HAUS_OUT_OF_MEMORY`, `HAUS_INVALID_ARGUMENT` (a NULL
pointer, a negative indent or width, an unknown layout, a type that doesn't fit
the call, such as a `Stream` type for `haus_decode`) and `HAUS_SCHEMA_ERROR`
(a mistake in a schema file or a build). The error pointer may be NULL.

**Ownership.** Text the library returns is freed with `haus_free(ptr, len)`.
Every handle has its own free function (`haus_doc_free`, `haus_schema_free`,
`haus_stream_free`, `haus_issues_free`; NULL is fine). A `haus_value` is
borrowed from the `haus_doc` that holds it: values are never freed one by one.
Builders share the values they are given, and `haus_decode`/`haus_encode` may
share parts of their input: keep those docs alive while the new value is used.
A `haus_type` is borrowed from its schema; docs that schema functions return
don't refer to the schema.

**Threads.** No global state. Every function may run on several threads at
once; a schema, its types and a doc no longer built into may be read from
several threads; a doc being built into, and a stream, belong to one thread at
a time. Codecs are a Zig API only.

In what `haus_decode`, `haus_decode_text`, `haus_type_from_json` and typed
streams give, a `Secret` is a value of its own kind, `HAUS_SECRET` (spec §15):
the accessors see nothing in it, every writer, the canonical form, the hash,
equality and order reject it (`cannot-encode`, with the secret's place in
`path`: `$.pin`, `$[0].pin` for a doc's values; for equality and order the
message says which operand), and `haus_secret_reveal` is the one call that gives
out its value. `haus_encode` gives the data to write, in full. The C ABI is tested
from C, every function and status ([`test/c_api_test.c`](test/c_api_test.c)),
and from Zig.

## Examples

[`examples/`](examples): the same steps and files as the other bindings'
examples (`../examples`).

- [`quickstart.zig`](examples/quickstart.zig): a thread checked by its
  schema, a comment decoded, changed and encoded, an error with its place.
- [`order.zig`](examples/order.zig): an order with `@haus-fmt/money` and
  `@haus-fmt/geo`, decoded plainly and with the application's codecs (cents,
  GeoJSON order, a `Date`), encoded back, and the codecs' rules rejecting.
- [`c/quickstart.c`](examples/c/quickstart.c): the quickstart in C through
  `haus.h`, with the same output.

```sh
zig build quickstart        # or: order, quickstart-c
zig build examples          # all of them, their output checked against examples/*.out
```

## Build and test

```sh
zig build test      # unit tests, the C ABI's tests (Zig and C), the profiles' vectors, the conformance suite
zig build suite     # the conformance suite alone, with a count per file kind
zig build examples  # the examples, their output checked
zig build fuzz-runner -Doptimize=ReleaseSafe -Dcpu=baseline   # zig-out/bin/zig-runner, for ../fuzz
zig build           # zig-out/lib/libhaus.a, zig-out/include/haus.h, zig-out/lib/pkgconfig/haus.pc
```

The suite runner (`test/suite.zig`) runs `valid/`, `invalid/`, `positions/`,
`equality/`, the stream cases (whole, byte by byte, character by character, and
split at every position), the format suite with its idempotence and round-trip
checks, `schema/invalid/`, `schema/*.cases.haus` (also with every attribute
removed), `stream/typed.cases.haus`, `check/cases.haus`, `json/` and
`packages/cases.haus` (the `core` cases, and again with their packages given as
file trees; the `npm` and `cargo` cases and, on Windows, the `os: "unix"` ones
are skipped with a count).

## Releases

A tag `zig-vX.Y.Z` (the version of `build.zig.zon`) runs
[`.github/workflows/zig-release.yml`](../.github/workflows/zig-release.yml): it
tests, packs `zig/` as `haus-zig-X.Y.Z.tar.gz` (Zig can't fetch a package from
a subdirectory of a repository) with its hash in the release notes, and attaches
`libhaus` for Linux (glibc, musl), macOS and Windows, static and shared.

## Fuzzing

`zig-out/bin/zig-runner` speaks the protocol of [`../fuzz`](../fuzz): the parser,
the stream reader, the canonical form, the formatter (`--format`), the value
writers (`--write`; both with `--stream`, the stream option of spec §11, which
`--write` applies to its `"file"`), and the schema modes `--schema FILE`, `--schema-check FILE`,
`--time FILE` and `--json MODE FILE`. It is registered as `zig` and
`zig-stream` in `fuzz/src/runners.ts` and `fuzz/src/format.ts`, and as `zig` in
`schema.ts`, `schema-check.ts`, `time.ts` and `json.ts`.
