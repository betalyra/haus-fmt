---
title: Zig and C
description: Parse, check and decode haus in Zig 0.17, and from C or any language that calls C through libhaus and haus.h.
---

Parse haus into a `Value`, decode it with a schema into a `Decoded` tree that keeps every value exactly, and pick Zig types for haus types with codecs. The same library builds `libhaus` with a C header, `haus.h`, for C and every language that can call C. It needs no libc.

The Zig binding is the newest. It was written from the specification and the conformance suite alone, without reading another binding's code, to check that the specification says enough. It passes the conformance suite; its profile codecs pass their test vectors but aren't fuzzed yet.

## Install

There is no Zig package registry: each release is a tarball on GitHub. No release is tagged yet; this is the command for the first one:

```sh
zig fetch --save=haus https://github.com/betalyra/haus-fmt/releases/download/zig-v0.1.0/haus-zig-0.1.0.tar.gz
```

```zig
// build.zig
const haus = b.dependency("haus", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("haus", haus.module("haus"));
```

For C, build the library from [`zig/`](https://github.com/betalyra/haus-fmt/tree/main/zig) in the repository:

```sh
zig build -Doptimize=ReleaseFast    # zig-out/lib/libhaus.a, zig-out/include/haus.h, a pkg-config file
cc app.c $(PKG_CONFIG_PATH=zig-out/lib/pkgconfig pkg-config --cflags --libs haus)
```

## Read and write

```zig
const haus = @import("haus");

var d: haus.Diagnostic = .{};
const parsed = haus.parse(gpa, text, .{ .diagnostic = &d }) catch |e| switch (e) {
    error.Haus => {
        std.debug.print("{s} at {d}:{d}: {s}\n", .{ d.code.name(), d.line, d.column, d.message() });
        return e;
    },
    else => return e,
};
defer parsed.deinit();

const compact = try haus.stringify(arena, parsed.value, .{ .layout = .compact });
const hash = try haus.hash(arena, parsed.value, .{});   // SHA-256 of the canonical form
```

Every function that allocates takes an allocator. Errors are `error.Haus`, described by the `Diagnostic` you pass (`boolean-literal at 1:7: …`), or `error.OutOfMemory`. `haus.parseAll` reads a file of several values (a stream).

## With a schema

```zig
const build = try haus.packages.build(gpa, io, "order.schema.haus", .{ .folders = &.{"schemas"} });
defer build.deinit();
const root = build.root.get("Root").?;

const order = try haus.decoding.decodeText(gpa, arena, root, text, .{ .diagnostic = &d });
const total = order.get("total").?;   // a Decoded: .variant, tag "Money", args[0].decimal "44.40"
```

A `Decoded` is a tagged union that keeps every value: an integer as its decimal text, a `Decimal` as its literal, a std/time value as its checked text. A decoding error has its place: `d.path()` is `$.lines[0].qty`. `decoding.encode` turns a `Decoded` back into a `Value` for the writers. All the mappings: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Codecs** pick Zig types for haus types by their id. None is on unless you list it:

```zig
var codecs = try haus.Codecs.init(gpa, &(haus.codecs.money.iso ++ haus.codecs.geo.wgs84));
defer codecs.deinit(gpa);
_ = try haus.decoding.decodeText(gpa, arena, root, text, .{ .codecs = &codecs, .diagnostic = &d });
// Money(44.40, Eur): $.total[1]: @haus-fmt/money@1#Currency rejects the value: … [codec-rejected]
```

`haus.codecs.time` turns std/time values into Zig values (`time.date`, `time.instant`; `time.instant_timestamp` gives a `std.Io.Timestamp`, dropping the offset). `haus.Codec(T).init(id, decode, encode)` writes your own, for any named type, `prelude#Decimal` included. A profile's rule is checked on what the schema decoded, so a looser codec of your own for `Currency` doesn't let `Money(19.90, Bitcoin)` through. `decoding.unusedCodecs` (or `build.unusedCodecs`) gives the [`unused-codec`](/docs/errors#unused-codec) warning for a codec whose id no type has. There is no [`missing-codec`](/docs/errors#missing-codec) warning yet. [What haus checks](/docs/checks)

- **Streams.** `StreamReader` takes chunks of bytes and gives values once their comma arrives; `TypedStreamReader` decodes them one at a time, with `$[i]` places, so an item's error comes before a syntax error in a later item. [Logs and streams](/docs/tours/streams)
- **JSON.** `json.toJson` and `json.fromJson` with a type, `json.importJson` for any JSON. [Coming from JSON](/docs/from-json)
- **Checking.** `decoding.check` gives the hints and every error of a value, with positions (`.first = true` stops at the first); a stream is checked item by item, and at most 200 errors are reported in all. `haus_check_text` does the same in C.
- **Secrets.** A `Secret` prints as `<redacted>`, also with `{any}` and `std.json`, and the writers without a schema refuse it (`cannot-encode`); `reveal()` gives it out. [Config and secrets](/docs/tours/secrets)
- **Limits.** `haus.Limits` holds the spec's limits; the depth is at most 256.

## From C

```c
#include "haus.h"

haus_error err;
haus_schema *schema = NULL;
if (haus_schema_build("thread.schema.haus", NULL, &schema, &err) != HAUS_OK) { /* err.code, err.message */ }
const haus_type *comment = haus_schema_type(schema, "Comment");

haus_doc *doc = NULL;
const haus_value *value = NULL;
if (haus_decode_text(comment, text, len, &doc, &value, &err) == HAUS_ERROR) {
    printf("%s: %s [%s]\n", err.path, err.message, err.code);   // $.likes: … [type-mismatch]
}
haus_doc_free(doc);
haus_schema_free(schema);
```

A `haus_value` is borrowed from its `haus_doc` and freed with it; text the library returns is freed with `haus_free`. The library has no global state, and a schema can be read from several threads. In the C ABI, a decoded `Secret` is a value of its own kind that every writer rejects (`cannot-encode`); `haus_secret_reveal` is the one call that gives it out. Codecs, including the profile codecs, are in the Zig API only, not yet in the C ABI.

## More

- [README of the Zig binding](https://github.com/betalyra/haus-fmt/tree/main/zig): what is implemented, codecs and the C ABI in full.
- [`haus.h`](https://github.com/betalyra/haus-fmt/blob/main/zig/include/haus.h), which documents every C function.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/zig/examples): `quickstart.zig`, `order.zig` (codecs) and `c/quickstart.c`. Run `zig build examples` in `zig/`.
- [A tour of haus](/docs/tour).
