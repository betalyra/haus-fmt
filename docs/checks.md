---
title: What haus checks and what it doesn't
description: Which rules about values haus has, which belong to your application, and where each kind goes.
---

haus decides what a value is; your application decides whether it accepts it.

`Date("2026-02-30")` is no date: no one who knows the calendar would call it one, so haus rejects it. "At most 9 passengers" is different: another airline allows 12, and a booking for 10 is still a booking. That rule is your application's. When you are unsure where a check goes, ask: if two services disagreed about it, would they disagree about what the data is, or only about whether it is acceptable? The first is haus's; the second is yours. [Spec §13.1](/docs/spec#131-rules-about-values)

## What haus checks

| Who | Checks | When |
|---|---|---|
| A parser, without a schema | the syntax only: `Date("2026-02-30")` is just a tag with a string | always |
| A schema binding | the shape (fields, tags, the type of each value), the prelude's rules (`300` is no `UInt8`, a `Decimal` keeps its digits), and the [std/time profile](/docs/spec/time) | always, in every language |
| A package's profile | the rule of its type: `@haus-fmt/money/iso` (a currency is three letters A–Z), `@haus-fmt/geo/wgs84` (latitudes and longitudes in range), `@haus-fmt/uuid/rfc9562` (a UUID in its lowercase text form) | when your application adds the profile's codec |

A package's types are shape until you add a codec: without the `iso` codec, `Money(19.90, Eur)` decodes, since the schema only says that a currency is a tag. How to add one in each language is in [Where types come from](/docs/types#host-types-in-each-language). So that this is never silent, schema bindings warn with [`missing-codec`](/docs/errors#missing-codec) when your schema reaches a type of an official profile without its codec, and `haus check` and the editor note once per such import that its rules aren't checked there. [Packages §7](/docs/spec/packages#7-codec-wiring)

## Four rules for every check haus makes

Every rule about values in haus, in the prelude, in `std/time` and in a package's profile, follows four rules:

1. **It defines the type.** Without it, the text is no value of the type: no such date, no such `Int8`, no such point on earth. It rests on the published definition of the thing (the calendar, the range of an 8-bit integer, the size of the earth), not on what a language's host type can hold, and not on a subset someone prefers.
2. **It needs only the one value.** No other field, no clock, database, locale or registry lookup. Relations inside one value count: a `BBox`'s south edge can't be north of its north edge.
3. **It is specified exactly.** A rule in prose defines it, test vectors test it, it runs in linear time, and every binding gives the same answer.
4. **One spelling per value where possible.** A rule never changes equality, the canonical form or the hash, so two spellings it accepts for one value stay two values. `std/time` leaves one spelling per value, with a few exceptions it lists.

The first rule sorts checks into three kinds:

| Kind of rule | Example | Where it goes |
|---|---|---|
| one definition everyone shares | `2026-02-30`, a latitude above 90, a UUID's 32 hex digits | the type's rule |
| several legitimate definitions | which codes are currencies: ISO 4217, your shop's list, crypto currencies | profiles of a package; your application picks one |
| a preference | at most 9 passengers, UUIDs of version 7 only, email addresses of your own domain | your application |

## What haus doesn't check

These are your application's, whatever the type:

- **Bounds and relations that are a choice:** at most 100, not empty, a start before an end, a price above zero. Bounds that are part of what a value is stay haus's: a latitude above 90 is no latitude, so `wgs84` rejects it.
- **Lengths and patterns:** at most 80 characters, a regular expression.
- **Lists of allowed values** of your own: the currencies you sell in, the countries you ship to. A closed variant in the schema is often the better type.
- **Other values:** uniqueness across a list, ids that must exist, one field that depends on another.
- **The clock, a database, a locale:** a date in the future, a customer that exists, a postcode of the user's country.
- **Normalization:** trimming, case folding, Unicode normal forms. haus keeps a string exactly as written.
- **Defaults:** a missing field stays missing, and your application decides what it means.

## Where those checks go

- **A tighter type.** `UInt8` for 0 to 255, a closed variant instead of a string with allowed values, `Date` instead of a string with a date pattern.
- **Your application,** after decoding, or the validation library you already use: refinements in Zod, filters in Effect Schema, validators in Pydantic.
- **A codec.** It runs after the schema, can reject more values but never fewer, and reports `codec-rejected` at the value's place. [§13.4](/docs/spec#134-codecs), [`codec-rejected`](/docs/errors#codec-rejected)
- **A comment** in the schema, for the people who read it: `// 1 to 9: the booking service checks it`.

Never an attribute. haus has no `@min`, `@max`, `@pattern` or `@default`, and won't get them: attributes never change which data is valid. [Why only one attribute?](/docs/design#why-only-one-attribute-deprecated)

## How the rules are made exact

The prelude's rules and the `std/time` profile are in the spec. A profile's rule is written in prose in its package (`profiles/iso.md`), and that text is the definition; its test vectors only test it, so where the two disagree, the vectors are wrong.

`std/time` and the official profiles, `iso`, `wgs84` and `rfc9562`, each have a reference checker in Lean, proven to compute exactly their rule. In CI, generated values are fuzzed through the reference checker and through every binding's `std/time` check or profile codecs (TypeScript, Effect, Rust, Python, Go, JVM and Roc for the profiles). Zig's profile codecs (`iso` and `wgs84`) pass the vectors and are not fuzzed yet; Swift ships none yet.

## Where a type goes

A type's rule is checked in one of three tiers: the prelude, a standard module or a schema package. A rule of the prelude or `std/time` is checked by every schema binding, always, and never changes. A package's rule is checked where your application adds its codec, and can change with a major version of the package. So a type goes into a standard module only when its rule has one definition, it is needed nearly everywhere, and its rule must be on everywhere. Today only time passes. More in [Where types come from](/docs/types#why-three).
