---
title: Cheat sheet
description: Write and read valid haus on the first try, coming from JSON.
---

haus is a text data format: JSON's records, arrays, strings and numbers, plus bytes, **variants** (a tag with optional arguments: `True`, `None`, `Money(30.30, EUR)`, `Shipped { at: … }`) and **exact numbers** (`19.90` stays `19.90`). There is no `null`. Data files end in `.haus`, schemas in `.schema.haus`. A schema is optional: every valid file parses without one, and a schema says which values each field accepts.

## Syntax

```haus
// order.haus: checked against order.schema.haus next to it
/* block comments /* nest */ */
{
  id: 1042,                                   // bare keys: [a-z_][A-Za-z0-9_]*
  total: Money(30.30, EUR),                   // tag with positional arguments
  status: Shipped { at: Instant("2026-11-08T09:12:00Z") }, // tag with a record
  items: [
    { sku: "TEA-01", qty: 2 },
    { sku: "MUG-07", qty: 1, price: 7.90 },   // trailing commas everywhere
  ],
  coupon: None,                               // tag alone
  labels: { "gift-wrap": "yes" },             // any other key is quoted
  signature: x"9f86d081 884c7d65",            // bytes: two hex digits per byte
  note: """
    Leave it at the door.
    "Fragile", please.
    """,                                      // the closing """ sets the indent
}
```

- **Values:** number, string, bytes, array `[…]`, record `{…}`, variant. No `null`, no `true`/`false`, no other bare words.
- **Strings:** `"…"` with the escapes `\"` `\\` `\n` `\r` `\t` `\u{1F600}`, on one line. Block strings: `"""`, a line break, the lines, then `"""` on its own line; its indent is removed from every line, and spaces at the end of a line belong to the text (the formatter writes the last one as `\u{20}`).
- **Numbers:** `42`, `-0.5`, `1.5e-3`, `1E+05`, `0xFF`, `0b1010`, `1_000_000`. No `+`, no `.5` or `1.`, no leading zeros (`007`).
- **Variants:** a tag starts uppercase. `Circle { r: 1 }` is the same value as `Circle({ r: 1 })`. `True`, `False`, `None`, `Some(x)`, `Ok(x)`, `Err(x)` get their meaning from the prelude.
- **Streams:** a file is zero or more values separated by commas. Writers put a comma after every value, the last one too:

```haus
UserCreated { id: 42, email: "jan@example.com" },
PaymentReceived { id: 42, amount: Money(19.99, EUR) },
```

## Traps for JSON habits

Each trap: what a JSON habit writes → what haus wants. `⏎` is a line break.

Syntax errors, with or without a schema:

- `{ note: null }` → `{}` or `{ note: None }`. There is no `null`: leave the field out, or write `None` where the schema says `Maybe`.
- `{ paid: true }` → `{ paid: True }`. Booleans are the tags `True` and `False`. Lowercase bare words (`null`, `true`, `nan`) are never values.
- `{ Name: 1 }` → `{ "Name": 1 }`. A bare key starts with a lowercase letter or `_`; quote any other key (`"x-y"`, `"$type"`). Quoting is always allowed.
- `circle { r: 1 }` → `Circle { r: 1 }`. Tags start uppercase.
- `Circle⏎{ r: 1 }` → `Circle { r: 1 }`. A payload starts on its tag's line, so a forgotten comma can't turn the next value into a payload.
- `Heartbeat()` → `Heartbeat`. No empty parentheses.
- `{ a: 1, a: 2 }` → `{ a: 2 }`. Duplicate keys are an error, never "last one wins".
- `{ a: 1 }⏎{ b: 2 }` → `{ a: 1 },⏎{ b: 2 },`. Stream values are separated by commas, not by lines (unlike JSON Lines).
- `"\u00e9"` → `"\u{e9}"` or `"é"`. Unicode escapes take braces; `\/`, `\b` and `\f` don't exist.
- `-Infinity` → `NegInfinity`. `NaN`, `Infinity` and `NegInfinity` are tags, accepted where the schema says `Float32` or `Float64`.

Accepted by the parser, rejected by the schema:

- `nick: "Bo"` → `nick: Some("Bo")` for `nick: Maybe String`. A `Maybe` is always written, `None` or `Some(…)`: a bare value is not `Some`, and a missing field is not `None`.
- `note: None` → leave the field out, for `note?: String`. An optional field is present or missing, never `None`; only `note?: Maybe String` takes `None`.
- `id: 1.0` → `id: 1` for `Int`. `1.0` and `1` are different values, and integers have no fraction or exponent. A `Decimal` keeps its scale: `19.90` ≠ `19.9`.
- `total: "19.90"` → `total: 19.90` for `Decimal`. A string is never a number, a bare value never a tag: no conversions.
- `day: "2026-11-08"` → `day: Date("2026-11-08")` for `Date`. Time values are a tag around a string.
- `Circle(1.5)` → `Circle { r: 1.5 }` for `Circle { r: Float64 }`. The schema's case decides the payload: a record, or exactly its positional arguments (`Point(1, 2)` for `Point Float64 Float64`).

## Schemas

```haus-schema
// order.schema.haus
import std/time (Instant)
import @haus-fmt/money (Money)

type Order = closed {                // closed: other fields are errors
  // numbers: Int (any size), Int8…Int64, UInt8…UInt64, Float32, Float64, Decimal (exact)
  id: UInt64,
  total: Money,                      // Money(30.30, EUR)
  status: Status,
  items: Array Item,
  coupon: Maybe String,              // always written: None or Some("…")
  labels?: Map String,               // ?: may be left out; Map: any keys
  signature?: Bytes,
  note?: String,
  apiKey?: Secret String,            // hidden in logs and error messages
  extra?: Any,                       // any value, kept as written
  @deprecated("use labels") tags?: Array String,
}
type Item = { sku: String, qty: UInt32, price?: Decimal } // open: other fields are ignored
type Status = < Pending | Shipped { at: Instant } | Cancelled String > // open: other tags are kept
type Level = closed < Debug | Info | Warn >
```

Also in the prelude: `String`, `Bool`, `Result e a`, and `Stream a` for a whole file of values (`type Root = Stream Event`). `type Page a = { items: Array a }` is generic; `...Base` copies another record's fields or variant's tags. A data file `x.haus` is described by the type `Root` in `x.schema.haus` next to it; `haus check --schema s.schema.haus#Type` uses another schema or type. A data file never names its schema.

## The loop

Install the [`haus` command](/docs/cli) with `cargo install haus-fmt-cli`.

1. Write the `.haus` file, and a `.schema.haus` when the data has a fixed shape.
2. `haus check order.haus` reports syntax errors with line and column. With a schema (`order.schema.haus` next to it, or `--schema s.schema.haus#Type`), it also reports values the schema rejects. `haus check .` checks a whole directory; `haus check --json` gives one JSON document with each error's `code`, `line`, `column`, `path` and `hint`. Exit code 0 is valid (hints allowed), 1 invalid, 2 a usage or I/O error.
3. Fix the first error and check again. Messages say what to write instead.
4. `haus fmt order.haus` writes the standard layout: one entry per line, trailing commas, comments kept. `haus fmt --check .` only lists the files that would change; `haus fmt -` formats standard input.
5. `haus canonical x.haus` and `haus hash x.haus` print the canonical form and the hash (`hashAll`) of a file's values.

## JSON ⇄ haus

- **JSON import, no schema:** objects become records, arrays arrays, strings strings, numbers stay exact, `true`/`false` become `True`/`False`, `null` becomes `None`. Turn `"type": "circle"` discriminators and sets of flags into variants.
- **Schema-based JSON** (for APIs, read and written with the schema): `Int`, `Int64`, `UInt64` and `Decimal` are strings (`"19.90"`); `Int8`…`Int32`, `UInt8`…`UInt32` and floats are numbers; `Bool` is `true`/`false`; `Bytes` is base64; time values are their string; `Maybe` is `null` or the value (tagged if the value can be `null`); a missing optional field is a missing member.
- Closed variants without payloads are strings (`"Debug"`); other variants are objects with `"_tag"`: `{"_tag": "Circle", "r": 1.5}`, positional arguments as `"value"` or `"values"`. `NaN`, `Infinity`, `NegInfinity` are `"NaN"`, `"Infinity"`, `"-Infinity"`.
- **Self-describing JSON, no schema** (exact, for haus tools): `{"_haus": 1, "_value": …}` around `{"_num": "19.90"}`, `{"_rec": {…}}`, `{"_tag": "Some", "_args": […]}`, `{"_bytes": "0b34ff"}`; strings and arrays as themselves.
- Keys starting with `_` are haus's. A stream is JSON Lines: one JSON text per value.
