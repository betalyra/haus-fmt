# haus for Go

**A data format for humans: friendly to write, pleasant to read, and at home in your code.**

> **Highly experimental.** This module has the parser, the formatter, the stream reader, the canonical form and hashing, and schemas (package `schema`). The JSON mappings come next.

```sh
go get github.com/betalyra/haus-fmt/go
```

It follows the [specification](https://github.com/betalyra/haus-fmt/tree/main/spec): exact numbers, limits enforced while parsing, error positions in code points, and an error code from the catalogue on every error. It needs Go 1.24 or later and uses only the standard library.

```go
import haus "github.com/betalyra/haus-fmt/go"

v, err := haus.Parse([]byte(`{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }`))
if err != nil {
	log.Fatal(err)
}
order := v.(haus.Record)
if s, ok := order.Get("status"); ok {
	if st, ok := s.(haus.Variant); ok && st.Tag == "Shipped" {
		tracking, _ := st.Args[0].(haus.Record).Get("tracking")
		fmt.Println("shipped:", tracking) // DE-4711
	}
}

n, _ := haus.Parse([]byte("19.90"))
fmt.Println(n.(haus.Number)) // 19.90: exact, never a float

values, err := haus.ParseAll([]byte("Log { a: 1 },\nHeartbeat,\n")) // a stream: every top-level value
```

Values are `haus.Number`, `haus.String`, `haus.Bytes`, `haus.Array`, `haus.Record` and `haus.Variant`, the six kinds of spec §1, behind the sealed interface `haus.Value`; use a type switch to tell them apart. A `Number` keeps its normalized literal (`0xFF` is `255`, `1E+05` is `1e5`, `19.90` stays `19.90`); `BigInt` gives an integer as a `*big.Int`, and converting to a float is up to you. A `Record` keeps its fields in source order, with `Get`, `Len`, `All` and `Fields`. `haus.Equals` is equality as in spec §2: field order doesn't matter, `1.0` and `1` differ, and `Tag { … }` equals `Tag({ … })`.

## Errors

Every error is a `*haus.Error` with a `Code` (spec §17), a `Message`, and for an error in text a 1-based `Line` and `Column`, counted in code points:

```go
_, err := haus.Parse([]byte("{ ok: true }"))
var e *haus.Error
if errors.As(err, &e) {
	fmt.Println(e.Code, e.Line, e.Column) // boolean-literal 1 7
}
```

`haus.CodeBooleanLiteral` and the other `Code…` constants are generated from the catalogue, [`spec/errors.haus`](../spec/errors.haus); `e.Code.Hint()` is the usual fix and `e.Code.Docs()` its documentation. `json.Marshal(e)` writes the JSON form of spec §17:

```json
{"code":"payload-newline","message":"the payload of Heartbeat must start on its line: expected ',', found '{'",
 "line":2,"column":1,"expected":"','","found":"'{'",
 "hint":"Put the payload on the tag's line, or add a comma if they are two values.",
 "docs":"https://haus-fmt.org/docs/errors#payload-newline"}
```

## Limits

`haus.ParseAllWith(src, haus.Limits{MaxDepth: 64})` sets limits (spec §7); fields left at zero keep their defaults (`haus.DefaultLimits()`): depth 256, 1000 characters per number literal (and so 829 hex digits), exponents up to ±6144, 16 Mi characters per string, key, tag or byte string (counted on the value, after escapes; for a byte string, between the quotes), and 64 Mi characters per top-level value of a stream (`MaxValueLength`, which only the stream reader applies: it bounds the reader's memory, while `ParseAll` already holds the whole text). `MaxDepth` can be at most `haus.MaxSupportedDepth`, 10000: the parser, the formatter and the canonical form recurse once per level, and a larger limit is rejected with the code `unsupported-depth`.

## Streams

`haus.NewStreamReader(r, haus.StreamOptions{})` reads the values of an `io.Reader` one at a time (spec §6), holding at most one value in memory:

```go
reader := haus.NewStreamReader(conn, haus.StreamOptions{Strict: true})
for v, err := range reader.All() {
	if err != nil {
		return err // stream-truncated if the last value has no comma after it
	}
	handle(v)
}
```

Errors have the same codes and positions as when the whole input is parsed at once. `Strict` requires a comma after the last value, so that a stream cut off after a complete-looking value is an error.

## Formatting

`haus.Format(src, haus.FormatOptions{Layout: haus.Pretty})` rewrites text in one of the three layouts of spec §11: `Pretty` keeps comments and blank lines, `Compact` writes one item per line, and `Minimised` drops the whitespace between tokens. Numbers, byte strings and `"…"` strings keep their spelling. `Indent` (default 2) and `Width` (default 80) are the only options. `haus.HasComments` tells a tool that rewrites files in place in the compact or minimised layout whether it would drop comments.

`haus.FormatValue(v, opts)` and `haus.FormatValues(vs, opts)` write values built in code: numbers normalized, byte strings in lowercase hex, strings with the fewest escapes, and a stream with a comma after every value.

## Canonical form and hashing

```go
v, _ := haus.Parse([]byte(`Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }`))
s, _ := haus.Canonical(v) // Order{id:255,total:19.90,"x-y":1e5}
h, _ := haus.Hash(v)      // SHA-256 of the canonical form, 64 hex digits
```

`haus.HashAll(values)` hashes a whole file or stream, and `haus.NewHasher()` does the same value by value as a stream is read. `haus.Compare` orders values by their canonical forms. The hash is unkeyed: don't publish the hash of a document with private content (spec §9).

## Schemas

Package `schema` reads schema files (`.schema.haus`, spec §14) with their imports, and decodes values with their types (spec §15):

```go
import "github.com/betalyra/haus-fmt/go/schema"

s, err := schema.Load("order.schema.haus", schema.Options{Packages: schema.NodeModules{}})
if err != nil {
	log.Fatal(err) // order.schema.haus:3:12: unknown type Strin [unknown-type]
}
order, err := s.Type("Order")
v, _ := haus.Parse([]byte(`{ id: 0x10, total: 19.90, note: "ignored" }`))
decoded, err := order.Decode(v) // {id:16,total:19.90}: the value a writer writes back
var e *haus.Error
if errors.As(err, &e) {
	fmt.Println(e.Code, e.Path) // type-mismatch $.items[2].price
}
```

`Decode` gives the value an encoder writes back: integers in decimal (`-0` as `0`), floats in their one spelling (`0.10` as a `Float64` is `0.1`), the fields an open record doesn't list left out, and everything else as it was (sharing memory with the input). Errors have the code and the path of the failing value; an error inside a `Secret` is `invalid-secret`, at the secret, with nothing of its value. `Encode` checks a value built in code against the type and also reports values that contain themselves (`cyclic-value`). `DecodeAll` and `DecodeStream` decode a file or a stream with a `Stream` definition; paths then start with the value's index, `$[3].total`.

Every rule of spec §14 and §13.3 is checked when a schema loads: names, arities, spreads, guarded and non-growing recursion, attributes, imports. `std/time` is built in (`schema.CheckTime` is its profile). Packages are found by a `Locator`: `schema.NodeModules{}` (the npm rules of spec §13.3), `schema.NewExplicit().Package(dir)` and `.Folder(dir)` (packages given explicitly), or both with `schema.Or{First: explicit, Second: schema.NodeModules{}}`. A package's files are opened without following links and read once, within the limits of spec §13.3 (64 KiB manifests, 1 MiB schema files, 256 files, 4096 entries per folder). `schema.Parse` reads a schema from text; it imports std/time and packages, but no files.

Codecs (`schema.Codec`, spec §13.4) choose host types for named types by their id; with the `Value` API they run after the schema and may reject more values (`DecodeOptions{Codecs: …}`), and `schema.DecodeAs` gives the host value. `schema.InstantTime` is an opt-in codec from `Instant` to `time.Time`, which keeps the instant and its offset but not the spelling. `schema.Secret[T]` holds a value that prints, formats, logs and marshals as `<redacted>`, until `Reveal`.

## Development

```sh
go test ./...                 # the conformance suites in ../test-suite, and unit tests
go test -race ./...
go test -run '^$' -fuzz FuzzParse -fuzztime 1m .
go test -run '^$' -fuzz FuzzSchemaParse -fuzztime 1m ./schema
golangci-lint run ./...
go generate                   # after editing spec/errors.haus: rewrites error_codes.go
```
