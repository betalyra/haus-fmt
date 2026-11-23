---
title: Roc
description: Decode haus into Roc types generated from your schema, with tag unions, records and exact numbers.
---

Decode haus into Roc tag unions and records that `haus-gen` generates from your schema, or work with any value as a `Value`. The package is pure: no effects and no mutable state.

Roc changes quickly, and so does this binding: it is built against the Roc nightly of 2026-11-03 and basic-cli 0.26.0.

## Install

There is no release yet. Point your app at the package in a checkout of the [repository](https://github.com/betalyra/haus-fmt/tree/main/roc):

```python
app [main!] {
	haus: "../haus-fmt/roc/package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}
```

## Read and write

```python
import haus.Value
import haus.Encode

point = Value.tag("Point", [Value.num("1E+05")?, Value.num("0xFF")?])?
Encode.canonical(point)   # Ok("Point(1e5,255)")

match point.view() {
	Tag(name, args) => "${name} with ${args.len().to_str()} arguments"
	_ => "something else"
}
```

`Value.parse_all(text)` reads a file of values. `v.view()` shows one level of a value to match on: `Num`, `Text`, `Bytes`, `Arr`, `Rec` or `Tag`.

## With a schema

Roc has no build scripts, so you generate a module from the schema and check it in. `haus-gen` is part of the Rust crate `haus-fmt-build`:

```sh
haus-gen roc thread.schema.haus --module Thread --out Thread.roc
```

```python
import haus.Decode
import haus.Encode
import haus.Int
import Thread

thread = Decode.one(text, Thread.decode_root)?   # a Comment, whose replies are Comments

liked = match thread {
	Comment(c) => Comment({ ..c, likes: Int.from_i128((c.likes.to_i128() ?? 0) + 1) })
}
encoded = Encode.value(liked, Thread.encode_comment)?
Encode.to_str(encoded)?   # Comment { author: "ada", … }
```

A record is a Roc record, a variant a tag union (an open one gets `Unknown(Str, List(Value))`), `Maybe` is `[None, Some(a)]`, and an optional field is `[Missing, Present(a)]`. `Int` is the package's integer of any size; `Decimal` and std/time values are their exact text, std/time checked by its profile. A value that doesn't fit is a `Decode.Error` with a `code` and a `path` (`$.likes`). All the mappings: [host types](/docs/types#host-types-in-each-language).

## What else you need to know

**Codecs** are Roc modules with a `Target` type, `decode` and `encode`, chosen when you generate. The official profiles are codecs of the Roc packages in `extensions/money/roc` and `extensions/geo/roc`:

```sh
haus-gen roc app.schema.haus --module App --out App.roc \
  --package ../extensions/money=money --package ../extensions/geo=geo \
  --codec "@haus-fmt/money@1#Money=money.Iso" --codec "@haus-fmt/money@1#Currency=money.IsoCurrency" \
  --codec "@haus-fmt/geo@1#LatLng=geo.Wgs84" --codec "@haus-fmt/geo@1#BBox=geo.Wgs84BBox"
```

Without them, `haus-gen` prints a [`missing-codec`](/docs/errors#missing-codec) warning. [What haus checks](/docs/checks)

- **No checker.** Roc decodes and stops at the first error; there is no call that lists every problem of a file. Use [`haus check`](/docs/cli) for that.
- **Streams.** `Streaming.reader` takes chunks of bytes and gives each value as its comma arrives; it does no I/O. [Logs and streams](/docs/tours/streams)
- **JSON.** Generate with `haus-gen roc --json` for `to_json_<name>` and `from_json_<name>`; `JsonValue.import_json` reads any JSON as a `Value`. JSON is opt-in for now. [Coming from JSON](/docs/from-json)
- **Layouts.** `Encode.to_str` writes the compact layout, `Encode.minimised` the minimised one. There is no pretty writer.
- **Equality.** `==` on `Value`s is structural, so field order matters; `Encode.equals` is haus equality.
- **Secrets.** `Secret a` is `Secret(a)`: `Str.inspect` and `dbg` show `<redacted>`, `.expose()` gives the value. [Config and secrets](/docs/tours/secrets)
- **Errors.** Each error record has a `code`; `ErrorCode.hint(code)` gives the fix. [Error codes](/docs/errors)

## More

- [README of the Roc package](https://github.com/betalyra/haus-fmt/tree/main/roc): generated modules, limits and JSON in full.
- [Examples](https://github.com/betalyra/haus-fmt/tree/main/roc/examples): `quickstart`, `order` (codecs), `logs` (a stream) and `shop` (Roc's structural types). Run `roc main.roc` in an example's folder.
- [A tour of haus](/docs/tour).
