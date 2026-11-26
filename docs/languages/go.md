---
title: Go
description: Parse haus into haus.Value, check and decode it with a schema at run time, and map types onto your own with codecs.
---

Parse haus into `haus.Value`s, and load a schema at run time to decode and check them. Codecs turn a haus type into your own Go type. Standard library only, Go 1.26 or later.

## Install

```sh
go get github.com/betalyra/haus-fmt/go
```

Imported as `haus`; schemas are in the package `schema`, the official profiles in `ext/money` and `ext/geo`. No version is tagged yet: until the first release, use the module from the [repository](https://github.com/betalyra/haus-fmt/tree/main/go) with a `replace` directive.

## Read and write

```go
import haus "github.com/betalyra/haus-fmt/go"

v, err := haus.Parse([]byte(`{ id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }`))
if err != nil {
	log.Fatal(err) // a *haus.Error with Code, Line and Column
}
order := v.(haus.Record)
total, _ := order.Get("total")
fmt.Println(total.(haus.Number)) // 44.40: exact, never a float

out, _ := haus.FormatValue(v, haus.FormatOptions{Layout: haus.Compact})
// { id: 7, total: 44.40, status: Shipped { tracking: "DE-4711" } }
```

A `haus.Value` is one of `Number`, `String`, `Bytes`, `Array`, `Record` and `Variant`: use a type switch. `haus.ParseAll` reads a file of several values (a stream).

## With a schema

```go
import "github.com/betalyra/haus-fmt/go/schema"

s, err := schema.Load("order.schema.haus", schema.Options{})
order, _ := s.Type("Order")

decoded, err := order.Parse([]byte(`{ id: 7, lines: [{ sku: "TEA-01", qty: -1 }] }`))
var e *haus.Error
if errors.As(err, &e) {
	fmt.Println(e.Code, e.Path) // out-of-range $.lines[0].qty
}
```

`Decode` and `Parse` give a checked `haus.Value`: the value an encoder writes back, with each secret hidden. A `Stream` file is checked item by item, and a check reports at most 200 errors (hints don't count). To report every problem of a file with its position, as an editor does:

```go
for _, issue := range s.CheckText("Order", text) {
	fmt.Println(issue) // 4:17: $.lines[1].qyt: qyt is not a field of this closed record. Did you mean qty? [unknown-field]
}
```

What each haus type becomes: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Packages and codecs.** Go never looks in `node_modules`: give packages with `schema.NewExplicit()`, from disk or an embedded `fs.FS`. The codecs of the official profiles are in `ext/money` and `ext/geo`:

```go
packages, _ := schema.NewExplicit().Folder("schemas")
s, _ := schema.Load("order.schema.haus", schema.Options{Packages: packages})
root, _ := s.Type("Root")

codecs, _ := schema.NewCodecs(money.Iso, geo.Wgs84)
_, err := root.DecodeWith(v, schema.DecodeOptions{Codecs: codecs})
// $.total: @haus-fmt/money@1#Money rejects the value: Eur is not a currency: three letters A–Z (ISO 4217) [codec-rejected]
```

Codecs are given per call, so ask for the warnings with them: `root.MissingCodecs(codecs)` lists a [`missing-codec`](/docs/errors#missing-codec) warning for each profiled type left without one, and `s.UnusedCodecs(codecs)` an [`unused-codec`](/docs/errors#unused-codec) warning for each codec whose id no type has. Codecs work for any named type, `prelude#Decimal` and `std/time#Instant` too. `schema.NewCodec(id, decode, encode)` writes your own; `schema.DecodeAs` gives the host value. [What haus checks](/docs/checks)

- **Time.** std/time values stay checked `haus.Value`s; `schema.InstantTime` is an opt-in codec to `time.Time`, which keeps the instant and its offset but not the spelling.
- **Streams.** `haus.NewStreamReader(r, haus.StreamOptions{Strict: true})` reads one value at a time from an `io.Reader`; `range reader.All()` iterates. `Type.DecodeStream` decodes them. `FormatOptions.Stream` makes `Format` and `FormatValues` write a comma after a single value too, for a log that holds one value so far. [Logs and streams](/docs/tours/streams)
- **JSON.** `order.ToJSON(v)` writes schema-based JSON (`{"id":"7",…}`), `order.FromJSON` reads it back with the same checks. `haus.ImportJSON` reads any JSON as haus. [Coming from JSON](/docs/from-json)
- **Secrets.** Decoding gives a `Secret` type's value hidden in a `haus.Secret`, and `schema.Secret[T]` is the host type for your own structs: both print, log and marshal as `<redacted>` until `Reveal`, and `FormatValue`, `Canonical` and `Hash` refuse a `haus.Secret`; encoding with the schema writes it in full. [Config and secrets](/docs/tours/secrets)
- **Limits.** `haus.ParseAllWith(src, haus.Limits{MaxDepth: 64})`; fields left at zero keep the defaults.
- **Goroutines.** A loaded `*schema.Schema`, its types and codecs don't change, so goroutines can share them.
- **Errors.** Every error is a `*haus.Error` with a `Code`; `json.Marshal(e)` gives the JSON form. [Error codes](/docs/errors)

## More

- [README of the Go module](https://github.com/betalyra/haus-fmt/tree/main/go): formatting, limits, JSON and checks in full.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/go/examples): `quickstart` and `order` (codecs onto your own structs). Run `go run ./examples/order` in `go/`.
- [A tour of haus](/docs/tour).
