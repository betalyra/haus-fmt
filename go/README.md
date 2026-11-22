# haus for Go

**A data format for humans: friendly to write, pleasant to read, and at home in your code.**

> **Highly experimental.** This module has the parser, the formatter, the stream reader, the canonical form and hashing, the three JSON mappings, schemas and checks (package `schema`), and the codecs of the official extensions (`ext/money`, `ext/geo`).

```sh
go get github.com/betalyra/haus-fmt/go
```

It follows the [specification](https://github.com/betalyra/haus-fmt/tree/main/spec): exact numbers, limits enforced while parsing, error positions in code points, and an error code from the catalogue on every error. It needs Go 1.26 or later and uses only the standard library.

```go
import haus "github.com/betalyra/haus-fmt/go"

v, err := haus.Parse([]byte(`{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }`))
if err != nil {
	log.Fatal(err)
}
order := v.(haus.Record)
if s, ok := order.Get("status"); ok {
	if st, ok := s.(haus.Variant); ok && st.Tag.String() == "Shipped" {
		tracking, _ := st.Args[0].(haus.Record).Get("tracking")
		fmt.Println("shipped:", tracking) // DE-4711
	}
}

n, _ := haus.Parse([]byte("19.90"))
fmt.Println(n.(haus.Number)) // 19.90: exact, never a float

values, err := haus.ParseAll([]byte("Log { a: 1 },\nHeartbeat,\n")) // a stream: every top-level value
```

Values are `haus.Number`, `haus.String`, `haus.Bytes`, `haus.Array`, `haus.Record` and `haus.Variant`, the six kinds of spec §1, behind the sealed interface `haus.Value`; use a type switch to tell them apart. A `Number` keeps its normalized literal (`0xFF` is `255`, `1E+05` is `1e5`, `19.90` stays `19.90`); `BigInt` gives an integer as a `*big.Int`, and converting to a float is up to you. A `Record` keeps its fields in source order, with `Get`, `Len`, `All` and `Fields`. `haus.Equals` is equality as in spec §2: field order doesn't matter, `1.0` and `1` differ, and `Tag { … }` equals `Tag({ … })`.

Values built in code are checked when they are built (spec §11), for validity only, never against a limit: `haus.ParseNumber("0xFF")` gives `255` and fails only for text that isn't a number literal (`invalid-number`), however long it is; `haus.NewRecord` rejects a key twice (`duplicate-key`) or a key that isn't UTF-8 (`cannot-encode`); and a variant's tag is a `haus.Tag`, made by `haus.NewTag(name)` (`invalid-tag` unless it matches `[A-Z][A-Za-z0-9_]*`) or `haus.MustTag("Some")` for tags known when the program is written:

```go
some := haus.Variant{Tag: haus.MustTag("Some"), Args: []haus.Value{haus.NumberFromInt(1)}}
if some.Tag == haus.MustTag("Some") { /* tags compare by name; some.Tag.String() is "Some" */ }
```

So a variant with an invalid tag can't be built. Go still lets code build a few things past the constructors: a nil `Value`, a `Variant` with the zero `Tag`, a `haus.String` that isn't UTF-8, an array that contains itself. Writers and the canonical form reject those (`cannot-encode`, `cyclic-value`).

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

`haus.ParseAllWith(src, haus.Limits{MaxDepth: 64})` sets limits (spec §7); fields left at zero keep their defaults (`haus.DefaultLimits()`): depth 256, 1000 characters per number literal (and so 829 hex digits), exponents up to ±6144, 16 Mi characters per string, key, tag or byte string (counted on the value, after escapes; for a byte string, between the quotes), and 64 Mi characters per top-level value of a stream (`MaxValueLength`, which only the stream reader applies: it bounds the reader's memory, while `ParseAll` already holds the whole text). `MaxNodes` (64 Mi values written per top-level value) is the writers' (below). `MaxDepth` can be at most `haus.MaxSupportedDepth`, 10000: the parser and the formatter recurse once per level, and a larger limit is rejected with the code `unsupported-depth`.

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

`haus.Format(src, haus.DefaultFormatOptions())` rewrites text in one of the three layouts of spec §11: `Pretty` keeps comments and blank lines, `Compact` writes one item per line, and `Minimised` drops the whitespace between tokens. Numbers, byte strings and `"…"` strings keep their spelling. `Indent` and `Width` are the only options, taken literally: indent 0 indents nothing, and with width 0 nothing fits, so every positional payload is written one argument per line. `DefaultFormatOptions()` is indent 2, width 80; the zero `FormatOptions{}` is not. A negative indent or width fails with `haus.ErrInvalidOptions`, a plain error without a code. Compact and minimised ignore both, so `haus.FormatOptions{Layout: haus.Compact}` is enough. `haus.HasComments` tells a tool that rewrites files in place in the compact or minimised layout whether it would drop comments.

`haus.FormatValue(v, opts)` and `haus.FormatValues(vs, opts)` write values built in code: numbers normalized, byte strings in lowercase hex, strings with the fewest escapes, and a stream with a comma after every value. They check every limit of `opts.Limits` a value can break, so that a parser with the same limits reads the text back (spec §11): the depth (`Tag { … }` counting one level), the length of each string, key, tag and byte string, the number length and exponent, and the node limit. The node limit (`Limits.MaxNodes`, default 64 Mi) counts the values written for each top-level value, each as often as it is written: a value whose arrays share one another is small in memory but can be exponentially larger written out, and fails with `too-many-nodes`. `haus.CheckValue(v, limits)` makes the same checks without writing.

## Canonical form and hashing

```go
v, _ := haus.Parse([]byte(`Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }`))
s, _ := haus.Canonical(v) // Order{id:255,total:19.90,"x-y":1e5}
h, _ := haus.Hash(v)      // SHA-256 of the canonical form, 64 hex digits
```

`haus.HashAll(values)` hashes a whole file; the items of a stream are hashed one by one with `haus.Hash`. `haus.Compare` orders values by their canonical forms (and returns an error as `Canonical` does). The canonical form and hashing apply only the node limit (spec §12; `haus.CanonicalWith`, `haus.HashWith` and `haus.HashAllWith` take `Limits` for it): a value deeper or longer than a writer's limits still has a canonical form, at any depth (they don't use the call stack for nesting, and neither do `haus.Equals` and `haus.Compare`). The hash is unkeyed: don't publish the hash of a document with private content (spec §9).

## Goroutines

Parsing, writing, formatting, `Canonical`, `Hash` and `Equals` keep their state in the call (pooled parsers and buffers are taken for one call), and a `*schema.Schema`, its `Type`s and `*Codecs` don't change once built, so goroutines can share them; the tests check this under `-race`. A `StreamReader` belongs to one stream, and an `Explicit` is built before the loads that use it.

## Schemas

Package `schema` reads schema files (`.schema.haus`, spec §14) with their imports, and decodes values with their types (spec §15):

```go
import "github.com/betalyra/haus-fmt/go/schema"

packages, err := schema.NewExplicit().Folder("schemas") // the packages in schemas/, each a directory
s, err := schema.Load("order.schema.haus", schema.Options{Packages: packages})
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

`Type.Parse` reads text and decodes it, as `haus.Parse` and `Decode` do, without checking again what the parser checked; `Type.Format` encodes a value and writes it, the text and errors of `Encode` and `haus.FormatValue`, in one pass in the compact and minimised layouts (it writes the value as it checks it, without building the encoded value):

```go
decoded, err := order.Parse([]byte(`{ id: 0x10, total: 19.90 }`))
text, err := order.Format(decoded, haus.FormatOptions{Layout: haus.Minimised}) // {id:16,total:19.90}
```

Every rule of spec §14 and §13.3 is checked when a schema loads: names, arities, spreads, guarded and non-growing recursion, attributes, imports. `std/time` is built in (`schema.CheckTime` is its profile). Packages are found by a `Locator`: `schema.NewExplicit().Package(dir)` and `.Folder(dir)` (packages given explicitly, on disk), `.PackageFS(fsys, dir)` and `.FolderFS(fsys, dir)` (the same in an `fs.FS`, such as the schema package a Go module embeds with `//go:embed`), or two locators with `schema.Or`. This binding doesn't look in `node_modules`: only implementations of the npm ecosystem do (spec §13.3), and a Go build declares its dependencies in `go.mod`. Relative imports stay inside the build's root (`Options.Root`, by default the real directory of the file `Load` starts from, a relative one relative to that directory; `..` names above it are `import-outside-root`, before anything is looked at), and messages show paths relative to it. The entry file and the root are resolved to real paths once; a relative import follows no symbolic link: each name of its path must be listed by its directory with that spelling and must not be a link (`import-not-found`, without saying where it points), and a file in a package's directory, looked for up to the root, is `package-path` (a directory there that can't be listed is `import-not-found`). Every file is a regular file, opened without following a link at its last name and without blocking (`O_NOFOLLOW | O_NONBLOCK` on Unix, `FILE_FLAG_OPEN_REPARSE_POINT` on Windows) and checked on the opened file; names are spelled as their directories list them; each file is read once, within the limits of spec §13.3 (64 KiB manifests, 1 MiB schema files, 256 files, 4096 entries per folder). A file tree follows no links. `schema.Parse` reads a schema from text; it imports std/time and packages, but no files.

Codecs (`schema.Codec`, spec §13.4) choose host types for named types by their id; with the `Value` API they run after the schema and may reject more values (`DecodeOptions{Codecs: …}`), and `schema.DecodeAs` gives the host value. `schema.InstantTime` is an opt-in codec from `Instant` to `time.Time`, which keeps the instant and its offset but not the spelling. `schema.Secret[T]` holds a value that prints, formats, logs and marshals as `<redacted>`, until `Reveal`.

## JSON

Three forms connect haus and JSON (spec §16). The caller says which form it reads; the data never decides.

```go
v, _ := haus.ImportJSON([]byte(`{"price": 19.90, "tags": ["a"], "note": null}`)) // any JSON: { price: 19.90, tags: ["a"], note: None }
out, _ := haus.ToHausJSON(v)   // self-describing: {"_haus":1,"_value":{"_rec":{"price":{"_num":"19.90"},…}}}
back, _ := haus.FromHausJSON(out) // equal to v (spec §2), and every accepted text is the form of exactly one value
```

Numbers keep their exact text (never a float), readers accept only I-JSON (no duplicate member names, no unpaired surrogates), and the limits of §7 count the haus value: a string's characters after its escapes, bytes as two characters a byte. JSON Lines: `haus.ToHausJSONLines`, `haus.FromHausJSONLines`, `haus.ImportJSONLines`, and `haus.ReadHausJSONLines(r, opts)`, which holds one line at a time.

Schema-based JSON (§16.3) is the JSON a JSON consumer expects, written and read with a type:

```go
order, _ := s.Type("Order")
j, err := order.ToJSON(v)     // {"id":"7",…,"total":{"_tag":"Money","values":["44.40",{"_tag":"EUR"}]},"status":{"_tag":"Shipped","tracking":"DE-4711"}}
d, err := order.FromJSON(j)   // the decoded value, as order.Decode gives it
```

`Int`, `Int64`, `UInt64` and `Decimal` are strings, bytes base64, the prelude's `Maybe` is `null` or the value where that is unambiguous (tagged otherwise), a closed enum is its tag as a string, and other variants are objects with `"_tag"`. Reading applies the rules of decoding (open records ignore members, unknown tags of open variants are unknown values) and the codecs of `DecodeOptions`. `Type.ToJSONLines`, `FromJSONLines` and `ReadJSONLines` do the same for JSON Lines. A record case with a field named `_tag` or `_args` has no JSON form: converters fail on its values (`no-json-form`), and `Schema.Warnings` points at it when the schema loads.

## Checking data

`Schema.CheckText(typeName, text)` reports every problem of a data file, not only the first, with positions: errors, and hints for fields and tags an open type doesn't list (`unlisted-field`, `unlisted-tag`, with a "did you mean") and for deprecated fields and tags the data uses. A problem inside a `Secret` is one error at the secret, and nothing inside a secret is shown.

```go
for _, issue := range s.CheckText("Root", text) {
	fmt.Println(issue) // 4:17: $.lines[1].qyt: qyt is not a field of this closed record. Did you mean qty? [unknown-field]
}
```

`Schema.Check` does the same for values without text; `Issue` has `Severity`, `Code`, `Message`, `Path`, `Line`, `Column`, byte `Offset` and `End`, and marshals to the JSON form of spec §17.

## The official extensions

`github.com/betalyra/haus-fmt/go/ext/money` and `…/ext/geo` hold the codecs of the profiles `@haus-fmt/money/iso` (`money.Iso`, `money.IsoCurrency`) and `@haus-fmt/geo/wgs84` (`geo.Wgs84`, `geo.Wgs84BBox`), tested against the profiles' vectors. The schemas themselves are given like any package's, with `schema.NewExplicit()`.

```go
codecs, _ := schema.NewCodecs(money.Iso, geo.Wgs84)
v, err := order.DecodeWith(value, schema.DecodeOptions{Codecs: codecs}) // $.total: … Eur is not a currency [codec-rejected]
```

## Examples

`examples/quickstart` and `examples/order` do the steps of the Rust and TypeScript examples on the shared files in `../examples`: `go run ./examples/quickstart`.

## Development

```sh
go test ./...                 # the conformance suites in ../test-suite, and unit tests
go test -race ./...
go test -run '^$' -fuzz FuzzParse -fuzztime 1m .
go test -run '^$' -fuzz FuzzSchemaParse -fuzztime 1m ./schema
go test -run '^$' -fuzz FuzzJSON -fuzztime 1m .
go test -run '^$' -fuzz FuzzSchemaJSON -fuzztime 1m ./schema
go test -run '^$' -bench JSON -benchmem . ./schema
golangci-lint run ./...
go generate                   # after editing spec/errors.haus: rewrites error_codes.go
```
