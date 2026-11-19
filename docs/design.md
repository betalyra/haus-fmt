---
title: Design and FAQ
description: The ideas behind haus, and short answers to the questions people ask first.
---

haus makes a few choices that surprise people who know JSON. This page says what they are and why, with a link to the exact rule in the [specification](/docs/spec) for each.

## Design principles

### Data only

A haus file holds values and nothing else: no code, no references between values, no includes, no link to a schema it must load. Parsing never opens another file or touches the network. A tag such as `Shipped { at: … }` is data too: bindings never turn a tag name into a class or a function call. That mapping is what YAML's `!!python/object` and the gadget attacks on Java and .NET deserializers exploit. [Spec §9](/docs/spec#9-security-considerations)

### Exact by default

A number keeps the value it was written with. `19.90` stays `19.90`, and `1.0` is a different value from `1`: the scale is part of the value. Rounding to a binary float is something a schema asks for, never something the parser does.

```haus-schema
type Item = { price: Decimal, weight: Float64, count: UInt32 }
```

`price` keeps `19.90` with both digits, `weight` becomes a float, and `count` must be a whole number from 0 to 4,294,967,295. Without a schema, integers become big integers and other numbers exact decimals, so nothing is rounded on the way. [§2](/docs/spec#2-equality), [§3](/docs/spec#3-numbers)

### Variants instead of null

There is no `null`. JSON uses it for "no value", "unknown", "not given" and "clear this field", and leaves each reader to guess which. haus has two separate things, each with one spelling: an optional field may be left out, and a `Maybe` is always written, `None` or `Some(…)`.

```haus-schema
type Order = { id: UInt64, coupon: Maybe String, note?: String }
```

```haus
{ id: 1042, coupon: None }
```

`x?: Maybe T` has three states, for a partial update: leave it out, clear it with `None`, set it with `Some(…)`. The same idea replaces `type` fields and sets of flags: `status: Shipped { at: … }` instead of `shipped: true` plus a nullable date. [§1](/docs/spec#1-data-model)

### The schema describes shape

A schema says which fields a record has, which tags a variant takes, and which type each value is. It has no syntax for rules about values: no `@min`, `@max`, patterns or defaults. The only rules about values are those of the built-in types, such as the range of `UInt8` or the [std/time profile](/docs/spec/time). The spec fixes them, they run in linear time, and they mean the same in every language.

Rules beyond that are left out on purpose. Every rule a schema could hold would have to behave the same in every binding: regex dialects differ between languages, and a backtracking regex can take exponential time on hostile input. And rules like "at most 9 passengers" or "only these currencies" change with your business, more often than the shape of your data does. They belong to the application that knows them.

What to do instead:

- **Pick a tighter type.** `UInt8` for 0 to 255, a closed variant instead of a string with allowed values, `Date` instead of a string with a date pattern.
- **Check in your application**, after decoding, or in a **codec**: it runs after the schema and can reject more values, never fewer ([§13.4](/docs/spec#134-codecs)).
- **Share rules through a package profile.** A schema package can define profiles: rules that codecs implement, defined by test vectors. `@haus-fmt/money/iso` says a currency code is three letters A–Z ([§13.3](/docs/spec#133-schema-packages)).
- **Write a comment** for the people who read the schema.

```haus-schema
import std/time (Date)

type Seat = closed < Window | Aisle | Middle >

type Booking = {
  // 1 to 9 passengers: the booking service checks it
  passengers: UInt8,
  seat: Seat,
  departs: Date,
}
```

[§13.1](/docs/spec#131-rules-about-values), [§9.10](/docs/spec#9-security-considerations)

### Open by default

Records and variants are open. A reader ignores fields its schema doesn't list, and reads a tag it doesn't know as an *unknown* value that keeps the raw data. So writers can add fields and cases without breaking older readers. Where guessing is wrong, `closed` makes anything unlisted an error.

```haus-schema
type Contact = < Email String | Slack { workspace: String, user: String } >
type Level = closed < Debug | Info | Warn | Error >
```

An older reader of `Contact` reads `Teams { … }` as unknown and carries on; a `Level` it doesn't know stops it. [§14](/docs/spec#14-schema-files), and the tour [Evolving your data](/docs/tours/evolving).

### One meaning everywhere

Equality is defined exactly, and so is the canonical form: one byte sequence per value, so that two values are equal exactly when their canonical forms are identical. A hash is the same in every language, and so are error codes. Every binding passes the same conformance suites, and every parser and schema decoder is fuzzed in CI against a reference implementation in Lean, which is proven to follow the grammar (see [below](#is-the-parser-really-proven)). [§2](/docs/spec#2-equality), [§12](/docs/spec#12-canonical-form-equality-and-hashing)

### Safe to parse untrusted input

Parsers enforce limits while they read: nesting depth 256, 1000 characters per number, exponents up to ±6144, 16 Mi characters per string. All of them can be configured. Parsing takes time linear in the input, and so does decoding with any schema. Duplicate keys are an error, not "last one wins". Raw control characters (other than tabs and line breaks) and bidi controls are rejected, so a file can't display differently from what it contains. And a parser never repairs input: two parsers that repair differently disagree about what a file says. [§7](/docs/spec#7-limits), [§9](/docs/spec#9-security-considerations)

### Never breaking

Until 1.0 the spec is a draft. From 1.0 on, haus only grows: a new version may make invalid text valid, but never makes valid text invalid, never changes what it means, and never changes a canonical form or a hash. The prelude is fixed at 1.0; new built-in types go into standard modules that a schema imports, so no existing schema breaks. There is no breaking version. Files starting with `#` are reserved for a version directive, should a breaking version ever become unavoidable. [§10](/docs/spec#10-evolution-and-versions)

### A small core, extended by packages

The prelude is the data model and little more: numbers, strings, bytes, `Bool`, `Maybe`, `Result`, arrays, maps, records, `Any` and `Secret`. Time is a standard module, `std/time`, that every schema binding supports. Money, coordinates and your own types are schema packages, installed with npm, Cargo or pip like any other dependency, and versioned on their own. [Where types come from](/docs/types)

## FAQ

### Why not JSON, YAML, TOML or JSON5?

Each does something better than haus:

- **JSON** is everywhere: every language has a fast parser built in, and every tool reads it.
- **YAML** needs the least punctuation for nested config, but guesses types (YAML 1.1 reads `no` as `false`) and has anchors and tags some loaders turn into objects.
- **TOML** is pleasant for flat config files and has dates built in; deep nesting gets awkward, and there are no variants.
- **JSON5** is the smallest step from JSON, with comments, trailing commas and bare keys; numbers are still floats, and `null` is still there.

haus is for data whose meaning matters: amounts, times, cases, streams, and data that changes over years. It [maps to JSON](#how-does-it-map-to-json) where JSON is what the other side reads.

### Why is there no `null`?

Because readers disagree about what it means. A missing field and `None` are different values in haus, and nothing converts one into the other: leave the field out, or write `None` where the schema says `Maybe`. A decoder never fills in a missing field. [§1](/docs/spec#1-data-model)

### Why must `Some(…)` be written?

So that a value means the same with every schema. A bare `32` is a number and `Some(32)` is a variant; decoders never convert one into the other. If `Some` could be left out, `None` would be ambiguous for a `Maybe (Maybe Int)`: the outer `None`, or `Some(None)`? [§15](/docs/spec#15-decoding-with-a-schema)

### Why are `True` and `False` tags?

The data grammar has no reserved words at all. `True`, `False` and `None` are ordinary tags, and the prelude fixes what they mean: `type Bool = closed < False | True >`. Fewer special cases for parsers, and one rule for you: a capital letter starts a tag. Lowercase `true` and `null` are errors that say what to write instead ([`boolean-literal`](/docs/errors#boolean-literal), [`null-literal`](/docs/errors#null-literal)).

### Why must a payload start on its tag's line?

Because of a forgotten comma:

```text
[
  Heartbeat
  { user: "ada" },
]
```

If a payload could start on the next line, this would silently be one value, `Heartbeat { user: "ada" }`, instead of two. As it is, it's an error, and the message suggests the comma. [§5](/docs/spec#5-variants), [`payload-newline`](/docs/errors#payload-newline)

### Why is `1.0` not `1`?

The writer may mean something by it: `19.90` is a price with cents, `1.0` a measurement to one decimal place. haus keeps what was written, so equality, the canonical form and the hash don't depend on how some language rounds. Whether `1.0` and `1` are the same amount is the schema's call: `Float64` decodes both to the same float, `Decimal` keeps each as written, and `Int` accepts only `1`. [§2](/docs/spec#2-equality)

### Why no min/max, regex or default values in schemas?

The schema describes shape, and rules about values go to codecs, package profiles or your application: see [the schema describes shape](#the-schema-describes-shape) above. Defaults have a second problem: what a missing field means depends on the reader. In a config, it may mean a default; in a partial update, "leave it as it is". So decoders keep the field missing and let the application decide. [§1](/docs/spec#1-data-model)

### Why only one attribute, `@deprecated`?

An attribute must pass three tests: it doesn't change which data is valid or what it decodes to; tools act on it the same way in every language; and most languages have a counterpart. `@deprecated` passes all three: editors mark deprecated fields where data uses them, and code generators emit `#[deprecated]` in Rust or `@deprecated` in JSDoc.

```haus-schema
type Client = { id: Int, @deprecated("use email") mail?: String, email?: String }
```

`@min` and `@default` fail the first test. Text for people belongs in comments. Tools accept attributes they don't know and warn about them, so a schema written for a later version still works with older tools. [§14](/docs/spec#14-schema-files)

### Why no sets?

A set depends on equality, and haus equality isn't your language's: `1.0` and `1` are two haus values, but one value for many decimal types. A set written as an array also has an order the set doesn't: `[1, 2]` and `[2, 1]` would be the same set with different canonical forms and hashes. Use an `Array` and remove duplicates in your application. If sets turn out to be needed, they can come later as new syntax, an addition that §10 allows.

### Why no references, anchors or includes?

A few lines of YAML with anchors can expand to gigabytes (the "billion laughs" attack), and an include makes the reader open files the writer chose. Without them, the size of a file bounds the work of reading it, and parsing touches nothing else. For shared data or graphs, use ids: `author: "u-17"`. [§9.2](/docs/spec#9-security-considerations)

### Why no version header in files?

Every version of haus reads every earlier version's text the same way, so there is nothing to declare. New syntax is always an error in older versions, so an old parser fails loudly instead of misreading newer data. Files starting with `#` stay reserved for a directive like `#haus 2`; parsers report them as needing a newer haus ([`version-directive`](/docs/errors#version-directive)). [§10](/docs/spec#10-evolution-and-versions)

### Is the format stable?

Not yet. The spec is draft 0.1, and anything may still change, so don't build on it in production yet. From 1.0 on, haus only gains things: new syntax, new standard modules, new attributes. The prelude, the canonical form, the hash, the JSON mappings and existing error codes stay as they are. [§10](/docs/spec#10-evolution-and-versions)

### Can I use my own types for dates or money?

Yes, with a codec: your application chooses the host type of a named type, such as Python's `datetime.date` for a `Date` or `decimal.Decimal` for a `Decimal`. A codec runs after the schema, can reject more values but never fewer, and never changes what a value means. Every binding's default host types keep the value exactly, so decoding and encoding give back an equal value. A host type that keeps less, like a JavaScript `Date`, which forgets the offset an instant was written with, is always a choice you make explicitly (`h.InstantAsDate` in TypeScript), and its documentation says what it drops. [§13.4](/docs/spec#134-codecs)

### How do I keep secrets out of logs?

Write `Secret String` in the schema. The data stays the same; the decoded value shows `<redacted>` when printed or logged, is read through an explicit call, and never appears in error messages. `Secret` is not encryption: the file holds the value in full. And a hash hides nothing: anyone who can guess a short password or a PIN can confirm the guess against a published hash of the document. Use a keyed hash (HMAC), or keep the hash as private as the data. [§15](/docs/spec#15-decoding-with-a-schema), [§9.11](/docs/spec#9-security-considerations), the tour [Config and secrets](/docs/tours/secrets).

### How does it map to JSON?

Three forms, all defined in the spec:

- **Schema-based JSON:** the JSON an API client expects, read and written with the schema. `Decimal` and 64-bit integers are strings, so no float parser rounds them; a `Maybe` is `null` or the value; variants are objects with a `_tag`: `{"_tag": "Circle", "r": 1.5}`.
- **Self-describing JSON:** every haus value exactly, with no schema needed, for carrying haus through systems that only store JSON: `19.90` is `{"_haus": 1, "_value": {"_num": "19.90"}}`.
- **JSON import:** any JSON read as haus, without a schema: objects become records, numbers stay exact, `true` becomes `True`, `null` becomes `None`.

Which one? Whoever knows least decides. If every reader has the schema, schema-based. If a reader lacks it but uses haus and needs exact values, self-describing. If a reader lacks it and wants ordinary JSON, schema-based too: read without the schema, ids, decimals, dates and bytes are just strings, so it isn't a way to pass data through unchanged. The reader always says which form it expects; the data never decides. A stream maps to JSON Lines, one JSON text per value. [§16](/docs/spec#16-json)

### Which languages are supported?

TypeScript (`@haus-fmt/haus`, also through Standard Schema libraries such as Zod), Effect (`@haus-fmt/effect`), Rust (`haus-fmt`, with code generation in `haus-fmt-build`), Python (`haus-fmt`), Roc and Go (`github.com/betalyra/haus-fmt/go`). The [`haus` command](/docs/cli) checks, formats and hashes files, and the VS Code extension shows errors and types as you type. The libraries are published with the first release; until then, use them from the repository. [Install](/docs/install)

### Is the parser really proven?

The reference parser, written in Lean, is. Proven in Lean:

- The parser accepts a text exactly when the grammar describes it, returns the values the grammar gives, and no text has two meanings.
- Every valid file has unique keys at every depth, no bidi controls, no control characters but tab, line feed and carriage return before a line feed, and only values within the limits.
- The canonical form parses back to its value, and two values have the same canonical form exactly when they are equal.
- The model of the stream readers gives the same result however the input is split into chunks.
- The std/time checker computes exactly the profile's rules, with one spelling per date.
- Schema decoding follows §15, and decoding what was encoded gives the same result. Both JSON mappings round-trip.

Not proven:

- **The bindings you use.** TypeScript, Effect, Rust, Python and Roc are checked against the reference by the conformance suites and by differential fuzzing in CI. That has found real bugs, but it is testing, not proof.
- **Running time.** Linear time is a rule of the spec, and regression tests check it, but neither the proofs nor the fuzzer measure time.
- **Some parts below the model.** The model reads Unicode code points, so UTF-8 decoding isn't covered; the proofs cover the text that is hashed, not SHA-256 itself; the stream model leaves out the limit on one value's length, strict mode and error positions; and schema files are parsed by the TypeScript binding before the Lean decoder sees them.

The theorems, with their names: [`spec/lean/README.md`](https://github.com/betalyra/haus-fmt/blob/main/spec/lean/README.md).
