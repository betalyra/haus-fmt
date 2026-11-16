# haus in Lean

A formal model of the haus data format: the grammar as a precise definition,
and a reference parser that computes it.

| File | Contents |
|---|---|
| [`Haus/Value.lean`](Haus/Value.lean) | The data model (spec §1) and equality (§2) |
| [`Haus/Grammar.lean`](Haus/Grammar.lean) | [`grammar.ebnf`](../grammar.ebnf) as a relation: `File L t vs` says text `t` is a file with values `vs` within the limits `L` (§7). This is the specification. |
| [`Haus/Parser.lean`](Haus/Parser.lean) | The reference parser: total functions that compute `File` |
| [`Haus/Lexical.lean`](Haus/Lexical.lean) | Character classes, limits, number normalization |
| [`Haus/Sound/`](Haus/Sound) | Proofs that the parser only accepts what the grammar allows |
| [`Haus/Complete/`](Haus/Complete) | Proofs that the parser accepts everything the grammar allows |
| [`Haus/Correct.lean`](Haus/Correct.lean) | Both together, and unambiguity |
| [`Haus/Canonical.lean`](Haus/Canonical.lean), [`Haus/RoundTrip/`](Haus/RoundTrip) | The canonical form (spec §12), and the proofs that it parses back and is unique |
| [`Haus/Pretty/`](Haus/Pretty) | The block strings of the pretty layout (spec §4, §11), and the proofs that they parse back and that no line ends in a blank |
| [`Haus/Stream.lean`](Haus/Stream.lean), [`Haus/Stream/`](Haus/Stream) | A model of the bindings' stream readers (spec §6), and the proofs that the chunks don't matter and that it reads what `parse` does |
| [`Haus/Time/`](Haus/Time) | The std/time profile ([`std/time.md`](../std/time.md)): the rules, a checker, and the proof that it computes them |
| [`Haus/Schema/`](Haus/Schema) | Decoding with a schema (spec §15): resolved types, exact float rounding and spelling, the reference decoder and encoder, the rules they follow, and the round trip |
| [`Haus/Version.lean`](Haus/Version.lean) | Versions (spec §10): `Extends old new` |
| [`Haus/Json/`](Haus/Json) | The JSON mappings (spec §16): JSON as data and as text, base64 and hex, the JSON import, self-describing and schema-based JSON, and the proofs that they round-trip and are unique |
| [`Main.lean`](Main.lean) | `haus-ref`, the parser on the command line |
| [`scripts/schema-types.ts`](scripts/schema-types.ts), [`schema-suite.json`](schema-suite.json), [`json-suite.json`](json-suite.json) | The schema suite's and the JSON suite's types, resolved by the TypeScript binding's schema-file parser for `haus-ref --schema-suite` and `--json-suite` |

It needs [elan](https://github.com/leanprover/elan) (`brew install elan-init`);
the Lean version is pinned in `lean-toolchain`. No Mathlib.

```sh
lake build
.lake/build/bin/haus-ref FILE                    # values as self-describing JSON Lines (spec §16.2)
.lake/build/bin/haus-ref --suite ../../test-suite # the conformance suite
.lake/build/bin/haus-ref --time Date 2026-02-29     # a std/time check
.lake/build/bin/haus-ref --schema-suite ../../test-suite/schema  # the schema suite (spec §15)
.lake/build/bin/haus-ref --json-suite ../../test-suite/json      # the JSON suite (spec §16)
```

The schema suite's schema files are parsed by the TypeScript binding
(`typescript/packages/haus`, built with `pnpm build`), not in Lean.
[`scripts/schema-types.ts`](scripts/schema-types.ts) writes the types they
define, resolved, to [`schema-suite.json`](schema-suite.json); run it again
after changing a schema file (`node scripts/schema-types.ts > schema-suite.json`).
`haus-ref --schema-batch TYPES FILE` decodes one value per line, for fuzzing.
The JSON suite's types are written the same way, from `test-suite/json`
(`node scripts/schema-types.ts ../../test-suite/json > json-suite.json`).
For fuzzing the JSON mappings, one case per line: `--json-batch TYPES FILE`
(`SUITE TYPE HEX`, a haus value: decode and write schema-based JSON),
`--json-read-batch TYPES FILE` (`SUITE TYPE HEX`, JSON text: read with the
type), `--haus-json-batch FILE` (a haus value: its self-describing JSON, in
the envelope), `--haus-json-read-batch FILE` (an envelope read as a haus
value) and `--import-batch FILE` (any JSON text imported as a haus value).
Each prints `ok …` or `err …`.

Errors carry the code of spec §17 ([`Haus/ErrorCode.lean`](Haus/ErrorCode.lean)):
the parser's (syntax and limits), the schema decoder's and the JSON
mappings'. `--batch` prints `err LINE COLUMN CODE REASON`, `--schema-batch`
and the JSON batch modes print `err PLACE CODE REASON` (`-` where there is
none), and `--suite`, `--schema-suite` and `--json-suite` check the codes
the suite expects.

## What is proven

**About every valid file** (theorems about the grammar, so about every
possible input):

| Theorem | Says |
|---|---|
| `File.noBidi` (A1) | It contains no raw bidi control character, anywhere |
| `File.controls` (A2) | Its only control characters are tab, LF and CR |
| `File.crlf` (A2) | Every CR is directly followed by LF: no lone carriage returns |
| `File.uniqueKeys` (A3) | Every record in it, at any depth, has unique keys |
| `File.bounded` (A4) | Every value is within the limits: depth, numbers, strings, byte strings, record keys and tags |
| `char_isScalar` (A5) | Every string is valid Unicode, with no lone surrogates |

**About the reference parser:** it computes exactly the grammar. It accepts
a text if and only if the grammar describes it, and returns the values the
grammar gives:

```lean
theorem parse_correct (L : Limits) (input : Text) (vs : List Value) :
    Parser.parse L input = .ok vs ↔ File L input vs
```

| Theorem | Says |
|---|---|
| `parse_sound` | Whatever the parser accepts is a haus file with exactly the values it returned |
| `parse_complete` | Every haus file is accepted, with its values |
| `File.unique` | A text has at most one meaning: two derivations give the same values |

By soundness, A1–A4 hold for everything the parser returns
([`Haus/Secure.lean`](Haus/Secure.lean): `parse_noBidi`, `parse_controls`,
`parse_uniqueKeys`, `parse_bounded`).

Both directions are proven one file per part of the parser: numbers and
strings, whitespace and nested comments, byte strings, block strings, and
values, records, arrays, payloads and files together (they call each
other). Soundness goes by induction on the parser's fuel, completeness by
induction on the grammar's derivation; it also shows that the parser's fuel
is always enough. Only Lean's standard axioms are used
(`#print axioms parse_correct`).

The full plan, including the security properties, is in [`PLAN.md`](PLAN.md).

**About std/time:** `Time.check_iff : check ty s = true ↔ Valid ty s`. The
checker behind `haus-ref --time` computes exactly the rules of
[`std/time.md`](../std/time.md), written as definitions in
[`Haus/Time/Spec.lean`](Haus/Time/Spec.lean). Every row of the spec's rules
table is also a `#guard` test in [`Haus/Time/Check.lean`](Haus/Time/Check.lean).
[`Haus/Time/Props.lean`](Haus/Time/Props.lean) proves what valid values
guarantee: a zone name looked up as a file under a directory stays inside
it (`ZoneName.lookup_eq`), and a duration's fields fit in 32 bits, 2⁵³
seconds and 10⁹ nanoseconds (`Duration.fits`, `Fraction.nanos_lt`).
[`Haus/Time/Calendar.lean`](Haus/Time/Calendar.lean) proves the calendar
right (`date_iff`): valid `Date` strings are exactly the days from 0000-01-01
to 9999-12-31, one string per day, checked against the standard day-count
formula, which doesn't use the month-length table the rules use.
[`Haus/Time/Spelling.lean`](Haus/Time/Spelling.lean) proves one spelling per
value: two valid strings of a type are the same value exactly when they
differ at most in trailing zeros of a fraction (and, for instants, in the
offset); `Date` and `YearMonth` have exactly one spelling.

**About the canonical form** (spec §12), in [`Haus/RoundTrip/`](Haus/RoundTrip):

| Theorem | Says |
|---|---|
| `parse_canonical` | The canonical form of a parsed value parses back to that value: nothing can break out of its quotes (E) |
| `canonical_eq_iff` | Two parsed values have the same canonical form exactly when they are equal (§2), so hashes are well defined (H) |
| `canonicalAll_eq_iff` | Two parsed files have the same `hashAll` text exactly when they hold equal values in the same order (H) |
| `NumberLit.normalize_fits`, `Bounded.num_fits` | Every number parsed within limits `L`, at any depth, has a canonical text (its normalized literal, always decimal) of at most `L.maxNumberLength` characters: what the hex digit limit of §7 is for |
| `canonical_eq_canonicalAll_iff` | A value's canonical form is the text of a list only for one equal value: `hash v = hashAll [v]`, and nothing else collides (H) |
| `hashText_eq`, `canonicalAll_prefix`, `read_canonicalAll` | Hashing value by value as a stream is read gives `hashAll` of the file; the values read so far give a prefix of the text (H) |

They hold for any limits. The canonical form writes every number as its
normalized literal, always in decimal, and that text is within the limits
the number was parsed with (`NumberLit.normalize_fits`, `Bounded.num_fits`):
a decimal literal only gets shorter, and a hex literal has at most
`maxHexDigits` hex digits (§7: the largest `h` with `16^h ≤ 10^(n−1)`,
`Limits.maxHexDigits_iff`; 829 for the default 1000), so its decimal form,
sign included, has at most `maxNumberLength` characters.

**About block strings** (spec §4, §11), in
[`Haus/Pretty/BlockString.lean`](Haus/Pretty/BlockString.lean).
`blockString ind s` is what the pretty layout writes for a string `s` at the
indent `ind`: each line after the indent, `\`, `\r`, `\"` before two more
quotes, `\u{…}` for controls, bidi controls and U+2028, U+2029, and the last
space or tab of a line as `\u{20}` or `\t`.

| Theorem | Says |
|---|---|
| `blockString_parses`, `parse_blockString` | It is a block string of the grammar with the value `s`, so the parser reads it as exactly `s`, for every string within the limit |
| `blockString_noTrailingBlank` | No line of it ends in a space or a tab |
| `trimLines_blockString`, `parse_trimLines_blockString` | Trimming the spaces and tabs at the end of every line, as editors do, leaves it unchanged, so it still parses to `s` |

**About streams** (spec §6), in [`Haus/Stream/`](Haus/Stream). The model in
[`Haus/Stream.lean`](Haus/Stream.lean) works like the readers of all three
bindings: a scanner finds the commas between top-level values (it tracks
brackets, strings and comments, and waits when a chunk ends before it can
decide), and each piece is parsed on its own.

| Theorem | Says |
|---|---|
| `read_chunks` | However the text is split into chunks, the reader returns the same values and the same error |
| `pieces_prefix` | A value returned after some of the chunks is never taken back: it is one of the final values |
| `read_correct` | The reader returns `vs` without an error exactly when `parse` accepts the whole text with `vs` |
| `read_error` | When `parse` rejects a text, the reader reports an error |

Not modelled: the limit on one value's length (§7), strict mode, UTF-8
decoding and error positions.

**About schema decoding** (spec §15), in [`Haus/Schema/`](Haus/Schema).
`Ty` is a resolved type: built-in types, `Secret`, `Array`, `Map`, records
and variants (open or closed, every payload form), std/time types, and
named references into an environment, generic types applied. Attributes
(§14) are not part of it: a `Schema` keeps them in a table of their own,
which decoding never reads. `decode` recurses on the value, so it always
terminates; a reference that comes up again before any input is consumed
is an error. Floats are rounded and spelled exactly, with integer
arithmetic ([`Float.lean`](Haus/Schema/Float.lean)). All cases of
`test-suite/schema` pass.

| Theorem | Says |
|---|---|
| `decode_iff` | The decoder computes the rules of §15, written as an inductive relation (`Dec`, one rule per row of §15's tables): `decode env t v = .ok x ↔ Dec env t v x` |
| `decode_encode` | Decode, encode, decode is decode: when `t` accepts `v` as `x`, it accepts `encode x`, again as `x` |
| `encode_agree` | `encode x` is `v`, except for the fields an open record ignores, the spelling of floats and `-0` decoded as an integer (`Agree`) |
| `floatLaw` | The spelling of a decoded float (`Float64` or `Float32`) decodes to the same float |
| `secret_error` | An error inside a `Secret` is the same for every value: its place and type, nothing of the value |
| `Schema.decode_erase` | Attributes don't matter: decoding with the schema without its attributes is decoding with the schema (`rfl`) |

`floatLaw` ([`FloatLaw.lean`](Haus/Schema/FloatLaw.lean)) is what makes
the round trip hold for floats: rounding depends only on the value of the
fraction (`roundMag_cross`), a float rounds to itself (`roundMag_self`), so
the search for the shortest spelling always finds one within its 1100 tries
(`shortest_float`), and the text `layout` writes reads back as the digits
and exponent it was given (`decBody_layout`). Rounding and spelling also
matched JavaScript's `Number` and `toString` exactly on 20,000 random
literals.

**About JSON** (spec §16), in [`Haus/Json/`](Haus/Json). JSON is modelled
as data (`JSON`): numbers keep their text, and `JSON.Equiv` compares as §16
does, member order ignored and numbers by text. A strict reader for JSON text
(I-JSON, the limits, a leading byte order mark, JSON Lines) reads back what
the compact writer writes, for exactly the JSON the reader returns; the
writer escapes every control character, bidi control and U+2028, U+2029. Three forms sit
on it: the JSON import (`JSON.toValue`, `readImport`), self-describing JSON
(`selfDescribing`, the value without the envelope, as in `Any`; `hausJson`,
the envelope `{"_haus": 1, "_value": …}` around it; `readHausJson`, which
also rejects raw DEL, C1 and bidi controls), and schema-based JSON
(`toJson`, `fromJson`, `readJson`). All cases of `test-suite/json` pass,
and every `valid/NAME.jsonl` reads back as its file's values, one envelope
per line. A value is *well formed* (`Value.wf`) when its numbers are
normalized literals and its tags are tags, as every parsed value is
(`parse_wf`).

| Theorem | Says |
|---|---|
| `hausJson_read_write`, `fromHausJson_hausJson` | Reading the self-describing JSON of a well-formed value gives the value back (§16.2); `selfDescribing_read_write`, `fromSelfDescribing_selfDescribing` without the envelope |
| `hausJson_unique`, `selfDescribing_unique` | Every JSON the self-describing reader accepts is, as data, the self-describing JSON of the value it reads |
| `hausJson_equiv_iff`, `selfDescribing_equiv_iff` | Two values have the same self-describing JSON, as data, exactly when they are equal (§2); for every value |
| `fromHausJson_wf`, `fromSelfDescribing_wf` | What the self-describing reader returns is well formed |
| `schemaBased_round_trip` | If `decode env t v = .ok x` (`v` well formed) and `toJson env t x = .ok j`, then `fromJson env t j = .ok x` (§16.3) |
| `schemaBased_injective` | Two values decoded with `t` (from well-formed values) with the same schema-based JSON are the same |
| `toJson_error` | Writing a decoded value fails only for a record payload with a field named `_tag` or `_args` (§16.3) |
| `base64_decode_encode`, `base64_encode_decode` | Base64 reads back, and only canonical base64 is read |
| `hex_decode_encode`, `hex_encode_decode` | The same for lowercase hex (self-describing `_bytes`) |
| `normalizeNumber_normal` | A normalized literal normalizes to itself, so a `Decimal` reads back unchanged |
| `parse_wf`, `hausJson_parsed`, `schemaBased_parsed` | Every value the parser returns is well formed, so both round trips hold for every value of every haus text |
| `JSON.parse_write`, `JSON.parse_sound`, `JSON.parse_write_iff` | `JSON.parse L (JSON.write j) = .ok j` exactly when `j` is well formed (`JSON.WellFormed`: number tokens, no duplicate member names) and within the limits (`JSON.Fits`) |
| `JSON.parseLines_writeLines`, `JSON.parseLines_sound` | The same for JSON Lines: the compact writer writes nothing below U+0020 (`JSON.write_chars`), so each value is one line |
| `JSON.write_clean` | The writer writes no control character (C0, DEL, C1), no bidi control and no U+2028, U+2029 raw: it escapes them all (§16). The strict reader rejects only the first two raw (`strictRejects`) |
| `JSON.hausJson_wellFormed`, `toJson_wellFormed` | The self-describing and the schema-based JSON of a value without duplicate keys are well formed: number tokens (`spell_json`: a float's spelling is a JSON number), distinct member names |
| `JSON.hausJson_fits`, `toJson_fits` | The self-describing and the schema-based JSON of a value within the haus limits (`Value.fits`) are within the JSON limits (`JSON.Fits`; nesting `4 · maxDepth + 2` with the envelope, `4 · maxDepth + 1` without), when the limits leave room for the forms' member names and numbers (`SelfDescribingOk`, `SchemaBasedOk`: true of the defaults) |
| `JSON.readHausJson_writeHausJson`, `readJson_write`, `hausJson_text_parsed`, `schemaBased_text_parsed` | The self-describing and schema-based round trips through JSON text, for a value without duplicate keys within the limits |
| `JSON.readHausJsonLines_writeHausJsonLines`, `hausJsonLines_text_parsed` | The same for self-describing JSON Lines, one envelope per line: a parsed file's values read back from them |

The schema-based round trip goes by induction on the rules of decoding (`Dec`),
with `floatLaw` for floats. A `Maybe` writes `None` as `null` only when its
argument's JSON can't be `null` (`nullArg?_next`, `toJsonC_null`), whatever
the rule for cycles of `Maybe`s decides, so `null` is never ambiguous.
`#print axioms` shows only `propext`, `Classical.choice` and `Quot.sound`.

**About versions** (spec §10), in [`Haus/Version.lean`](Haus/Version.lean).
A `Version` is what a version fixes: its files, its canonical form, its
built-in types and its schema files. `Extends old new` says every text
`old` accepts, `new` accepts with the same values, and on what `old` can
express the canonical form, the built-in types and the types of every
schema `old` accepts are the same. `Extends.refl`, `Extends.trans` and
`current_extends_self` are proven; each release will prove that it extends
the one before.
