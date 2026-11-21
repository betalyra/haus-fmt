# haus for Zig

A **clean-room** binding of the haus data format, written in Zig 0.17.1 from
the specification ([`../spec`](../spec)) and the conformance suite
([`../test-suite`](../test-suite)) only, without reading any other binding's
code. Its purpose is to test whether the spec is complete and unambiguous:
where it wasn't, the choice made is noted (and checked against the Lean
reference, `haus-ref`, as a black box).

Phase 1 covers the data format, spec §1–§12 and §17. Schemas, typed codecs,
packages, std/time and the JSON mappings (§13–§16) are not implemented.

## What is implemented

| | |
|---|---|
| Values, equality, order (§1, §2) | `Value`, `equals`, `compare` (by canonical bytes) |
| Numbers (§3) | exact: the normalized literal; hex and binary to decimal of any size |
| Strings (§4) | UTF-8, escapes, block strings, control and bidi characters |
| Parser (§1–§8, §17) | `parseAll` (a file), `parse` (one document, `not-one-value`), `parseDocument` (with positions and comments); every error with its code, line and column |
| Streams (§6, §7) | `StreamReader`: chunks of bytes in, values out once their comma arrives; the value limit and strict mode; the same results for every way of cutting the input |
| Limits (§7) | `Limits`, the spec's defaults, all configurable; the depth this binding supports is 4096 (`unsupported-depth` above) |
| Layouts (§11) | `format` (a document's text, spellings as written, comments in pretty), `stringify`, `stringifyAll` (values); pretty with `indent` and `width`, compact, minimised |
| Canonical form and hashes (§12) | `canonical`, `hash`, `hashAll` (SHA-256 of `std.crypto`) |
| C ABI | `include/haus.h`, `src/c_api.zig` (below) |

Values built in code are checked when written: a number that isn't a
normalized literal (`invalid-number`), a string or key that isn't UTF-8,
a tag that isn't one (`invalid-tag`), duplicate keys, nesting beyond the
limit, an integer longer than the number limit (layouts only), and more
than `max_nodes` nodes as written out (`too-many-nodes`).

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

Every function that allocates takes an allocator. Errors are `error.Haus`
(a mistake with a code of spec §17, described by the `Diagnostic` passed in
the options) or `error.OutOfMemory`.

## Build and test

```sh
zig build test     # unit tests, the C ABI's tests and the conformance suite
zig build suite    # the conformance suite alone, with a count per file kind
zig build fuzz-runner -Doptimize=ReleaseSafe   # zig-out/bin/zig-runner, for ../fuzz
zig build          # zig-out/lib/libhaus.a and zig-out/include/haus.h
```

The suite runner (`test/suite.zig`) runs `valid/` (values against the
`.jsonl`, `.canonical`, `.hash`), `invalid/` (codes), `positions/`,
`equality/`, `stream/limits.cases.haus` (whole, byte by byte, character by
character, and split at every position), `stream/document.cases.haus`, and
the format suite (`cases/`, `examples/`, `valid/`, `options.cases.haus`) with
its idempotence and round-trip checks.

## C ABI

```c
int haus_canonical(const char *text, size_t len, char **out, size_t *out_len, haus_error *err);
int haus_hash_all(const char *text, size_t len, char out[65], haus_error *err);
int haus_format(const char *text, size_t len, int layout, int indent, int width,
                char **out, size_t *out_len, haus_error *err);
void haus_free(char *ptr, size_t len);
```

Statuses are `HAUS_OK`, `HAUS_ERROR` (the `haus_error` has the code, line,
column and message), `HAUS_OUT_OF_MEMORY` and `HAUS_INVALID_ARGUMENT` (a
negative indent or width, as spec §11 asks, or an unknown layout).

## Fuzzing

`zig-out/bin/zig-runner` speaks the protocol of [`../fuzz`](../fuzz): the
parser, the stream reader, the canonical form, the formatter (`--format`)
and the value writers (`--write`). It is registered as `zig` and
`zig-stream` in `fuzz/src/runners.ts` and `fuzz/src/format.ts`.
