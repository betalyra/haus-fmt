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
| [`Haus/DupKeys.lean`](Haus/DupKeys.lean) | Duplicate keys found by sorting (spec §7): the same answer as the parser's scan, in n log n comparisons |
| [`Haus/Linear/`](Haus/Linear), [`Haus/Stream/Cost.lean`](Haus/Stream/Cost.lean) | Linear time (spec §7): a cost model (steps counted next to results), a reference parser with a trie of keys that returns what the parser returns and takes at most `256 · n + 68` steps, the stream reader's buffer in at most `3 · n + 3 · p + 6` steps, the design before S17 shown quadratic |
| [`Haus/Canonical.lean`](Haus/Canonical.lean), [`Haus/RoundTrip/`](Haus/RoundTrip) | The canonical form (spec §12), and the proofs that it parses back and is unique |
| [`Haus/Pretty/`](Haus/Pretty) | The block strings of the pretty layout (spec §4, §11), and the proofs that they parse back and that no line ends in a blank |
| [`Haus/Layout/`](Haus/Layout) | The three layouts of spec §11 written from values, without comments: compact and minimised (one writer, the spacing a parameter; minimised is `Canonical.write`) and pretty, with the proofs that they parse back and that a compact or minimised stream splits by lines |
| [`Haus/Stream.lean`](Haus/Stream.lean), [`Haus/Stream/`](Haus/Stream) | A model of the bindings' stream readers (spec §6), and the proofs that the chunks don't matter and that it reads what `parse` does; the value limit (§7) and strict mode (§6) on top of it (`Stream/Limited.lean`) |
| [`Haus/Time/`](Haus/Time) | The std/time profile ([`std/time.md`](../std/time.md)): the rules, a checker, and the proof that it computes them |
| [`Haus/Schema/`](Haus/Schema) | Decoding with a schema (spec §15): resolved types, exact float rounding and spelling, the reference decoder and encoder, the rules they follow, and the round trip |
| [`Haus/SchemaFile/`](Haus/SchemaFile) | Schema files (spec §14): types as written, a reader for `.schema.haus` text, the checker of §14's static rules, instances of generic types and their resolved types (`load`: text to the environment decoding reads); the proofs that a checked file has finitely many instances (§9.10, with a bound) and that decoding with what `load` returns never fails because of the schema |
| [`Haus/Schema/Codec.lean`](Haus/Schema/Codec.lean) | Codecs (spec §13.4): a codec as a check on the value the schema decoded, and the laws of §13.4 proven once for every codec |
| [`Haus/Profiles/`](Haus/Profiles) | The official profiles (spec §13.3) `@haus-fmt/money/iso` and `@haus-fmt/geo/wgs84`: each rule as a definition, a checker proven to compute it, the profile as a codec, and the runner of their test vectors |
| [`Haus/Version.lean`](Haus/Version.lean) | Versions (spec §10): `Extends old new`, with the JSON mappings, the hash, the default limits and the error codes |
| [`Haus/Json/`](Haus/Json) | The JSON mappings (spec §16): JSON as data and as text, base64 and hex, the JSON import, self-describing and schema-based JSON, and the proofs that they round-trip and are unique, that naming a record case's record changes nothing, that an older reader reads a newer writer's JSON (§13.3), and that the readers return no duplicate keys |
| [`Haus/Packages/`](Haus/Packages) | Package resolution (spec §13.3): a file tree with symbolic links, the reference resolver, the package suite's runner; one package per name and injective ids, the read set and non-interference, bounded work, name isolation, order independence, and folders that never change a successful result |
| [`Main.lean`](Main.lean) | `haus-ref`, the parser, the layout writers, the schema-file reader and the decoders on the command line |
| [`scripts/schema-types.ts`](scripts/schema-types.ts), [`schema-suite.json`](schema-suite.json), [`json-suite.json`](json-suite.json) | The schema suite's and the JSON suite's types, resolved by the TypeScript binding's schema-file parser: `--json-suite` decodes with them, `--schema-suite` compares them with the Lean reader's on every case; a record case written by name keeps the name, and the model finds the record itself |

It needs [elan](https://github.com/leanprover/elan) (`brew install elan-init`);
the Lean version is pinned in `lean-toolchain`. No Mathlib.

```sh
lake build
.lake/build/bin/haus-ref FILE                    # values as self-describing JSON Lines (spec §16.2)
.lake/build/bin/haus-ref --suite ../../test-suite # the conformance suite
.lake/build/bin/haus-ref --compact FILE           # FILE's values in a layout of spec §11, from values:
.lake/build/bin/haus-ref --minimised FILE         #   numbers normalized, keys in source order, no comments
.lake/build/bin/haus-ref --pretty FILE [INDENT WIDTH]  # default indent 2, width 80
.lake/build/bin/haus-ref --write-batch pretty 4 40 DIR N  # the same for fuzz/: each value, and the file, as JSON
.lake/build/bin/haus-ref --time Date 2026-02-29     # a std/time check
.lake/build/bin/haus-ref --schema-suite ../../test-suite/schema  # the schema suite (spec §14, §15)
.lake/build/bin/haus-ref --json-suite ../../test-suite/json      # the JSON suite (spec §16)
.lake/build/bin/haus-ref --packages ../../test-suite/packages/cases.haus  # the package suite (spec §13.3)
.lake/build/bin/haus-ref --profile @haus-fmt/money/iso ../../extensions/money/profiles/iso.vectors.haus  # a profile's vectors
.lake/build/bin/haus-ref --profile @haus-fmt/geo/wgs84 ../../extensions/geo/profiles/wgs84.vectors.haus
```

`--schema-suite` reads each `NAME.schema.haus` of the schema suite itself
(its bytes decoded as UTF-8 first, `invalid-utf8` as in data; then
`Haus.SchemaFile.load`: parsed, checked, its generic types instantiated)
and decodes `NAME.cases.haus` with it; every `invalid/NAME.schema.haus` must
be rejected with the code in `invalid/NAME.error`. It then runs the cases
again with the types the TypeScript binding (`typescript/packages/haus`,
built with `pnpm build`) resolved:
[`scripts/schema-types.ts`](scripts/schema-types.ts) writes them to
[`schema-suite.json`](schema-suite.json); run it again after changing a
schema file (`node scripts/schema-types.ts > schema-suite.json`).
`haus-ref --schema-batch TYPES FILE` decodes one value per line, for fuzzing.
The JSON suite's types are written the same way, from `test-suite/json`
(`node scripts/schema-types.ts ../../test-suite/json > json-suite.json`).
For fuzzing the JSON mappings, one case per line: `--json-batch TYPES FILE`
(`SUITE TYPE HEX`, a haus value: decode and write schema-based JSON),
`--json-read-batch TYPES FILE` (`SUITE TYPE HEX`, JSON text: read with the
type), `--haus-json-batch FILE` (a haus value: its self-describing JSON, in
the envelope), `--haus-json-read-batch FILE` (an envelope read as a haus
value) and `--import-batch FILE` (any JSON text imported as a haus value).
Each prints `ok …` or `err …`. `--profile-batch NAME FILE` does the same for
an official profile's codec (`TYPE HEX`, a haus value of a type of the
profile's package): `ok <canonical form>` when it is accepted, `err PLACE
CODE REASON` when the schema rejects it and `err $ - REASON` when the
profile does.

Errors carry the code of spec §17 ([`Haus/ErrorCode.lean`](Haus/ErrorCode.lean)):
the parser's (syntax and limits), the schema-file checker's, the schema
decoder's and the JSON mappings'. `--batch` prints `err LINE COLUMN CODE REASON`, `--schema-batch`
and the JSON batch modes print `err PLACE CODE REASON` (`-` where there is
none), and `--suite`, `--schema-suite` and `--json-suite` check the codes
the suite expects; `--schema-suite` also checks the place (`path`, spec §15
"General rules": `$.items[2].price`, `$.m["pt-BR"]`, `$[0]` for an argument),
and `--json-suite` the place in the JSON where a case gives one (§16.3
"Places": `$.shape.values[1]`, `$._value._args[1]._num`). Schema-based
JSON's reader names that place itself; the self-describing reader's errors
are placed by `JSON.hausJsonPlace`, the first part it rejects in reading
order, and in JSON Lines by `JSON.readHausJsonLinesAt`, the line's index
first (`$[3]`).

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

**Duplicate keys in n log n** (spec §7, design review D2), in
[`Haus/DupKeys.lean`](Haus/DupKeys.lean). The reference parser checks each
key against the keys before it (`scanDup`), which is quadratic. Sorting
the keys and comparing neighbours (`keysDup`, a merge sort that counts its
comparisons) reports a duplicate exactly when the parser's scan does
(`keysDup_eq_scanDup`, `keysDup_iff`: exactly when the keys aren't
distinct), in at most `n · (log₂ n + 2)` comparisons of two keys
(`keysDup_cost`; `msort_cost`: `n ≤ 2^k` keys sort in `n · k`).

**Linear time** (spec §7, plan phase P, design review S17 and C6), in
[`Haus/Linear/`](Haus/Linear) and
[`Haus/Stream/Cost.lean`](Haus/Stream/Cost.lean). Lean proofs say nothing
about time by themselves, so the cost model is explicit: the counting
functions return their steps next to their result (`PC`, a parser monad
with a step count, [`Linear/Monad.lean`](Haus/Linear/Monad.lean)). The
input is an array (a position, an error's position and skipping take one
step); a list function takes one step per element it visits; arithmetic one
step per operation. Steps are proven with a small Hoare-style calculus
(`Spec`, [`Linear/Spec.lean`](Haus/Linear/Spec.lean)).

| Theorem | Says |
|---|---|
| `parseC_eq` | `parseC`, the reference parser written with step counts, returns exactly what `parse` returns: values, errors and positions. Its one change: a record's keys are kept in a `KeySet`, a binary trie over the 21 bits of each code point, so a duplicate check takes `21 · n + 1` steps for a key of `n` characters, with no hashing and no `log` factor (`mem_keySet`, `KeySet.memC_cost`, `KeySet.insertC_cost`) |
| `parseC_cost` | On any input of `n` characters, valid or not, crafted or not, `parseC` takes at most `256 · n + 68` steps |
| `splitB_view`, `splitB_steps` | The stream reader with one buffer (`Buf`: offsets for the current value and the scan, the completed values dropped once per chunk, as Rust's reader since S17) finds the pieces of `split`, and takes at most `3 · n + 3 · p + 6` steps for `n` characters in `p` chunks: each character appended once, scanned once, moved at most once |
| `splitOld_view`, `splitOld_steps_vals`, `splitOld_not_linear` | The design before S17 (each value's bytes dropped as its comma is found) finds the same pieces, but `k` values `0,` in one chunk take at least `k · (k + 1)` steps, so no linear bound holds for it |
| `readCost_le` | The whole stream reader, scanning and parsing every piece: at most `259 · n + 3 · p + 75` steps |

Not covered: the bindings' own code and constant factors (the benchmarks'
doubling tests are for that), and bit-level costs of big numbers (a hex
literal's conversion is quadratic in its digits, at most
`maxNumberLength`). Schema decoding (I7): `decode_linear` in
[`Linear/Decode.lean`](Haus/Linear/Decode.lean), at most
`costK env M k · inputSize v` steps, `M` the size of the largest type, for
leaf costs (float rounding, std/time checks) linear in their literal, which
are assumed, not counted.

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
offset); `Date` and `YearMonth` have exactly one spelling. The offset zero
has two spellings, `Z` and `+00:00` (`offset_same_iff`, `instant_offset_zero`):
two `Instant`s are the same value (the same instant with the same offset)
exactly when they differ at most in trailing zeros and in that
(`instant_value_same_iff`). `-00:00` is no offset (`not_offset_minusZero`),
so no `Instant` ends in it (`not_instant_minusZero`, `check_instant_minusZero`).

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

**About the layouts** (spec §11), written from values without comments, in
[`Haus/Layout/`](Haus/Layout). `compact v` and `minimised v` write a value
on one line (`Tag { a: 1, b: [1, 2] }`, `Tag{a:1,b:[1,2]}`), `compactAll` and
`minimisedAll` a file or stream one value per line; `pretty o ind used v` and
`prettyAll o vs` write the pretty layout with the options `o` (indent, line
width). Fields in the order given, numbers normalized, bytes as lowercase
hex, as when a binding serializes values. They hold for any limits and any
options:

| Theorem | Says |
|---|---|
| `minimised_eq_write`, `canonical_eq_minimised` | The minimised layout is `Canonical.write`: the canonical form is the minimised layout of the value in canonical order |
| `parse_compact`, `parse_minimised` | The compact and the minimised layout of a parsed value parse back to exactly that value, fields in the same order (L3) |
| `parse_compactAll`, `parse_minimisedAll` | A parsed file or stream in either layout parses back to the same values in the same order (L3) |
| `Val.line_noLF`, `compactAll_split`, `minimisedAll_split` | A value's compact or minimised layout holds no line feed, so a stream in either layout, split at its line feeds, is one line per value, each parsing alone to its value (L3, like NDJSON) |
| `parse_pretty` | The pretty layout of a parsed value parses back to exactly that value, at every indent and column, whichever way the width decides each payload (L5) |
| `parse_prettyAll` | A parsed file or stream in the pretty layout parses back to the same values in the same order (L5) |

The expected files of [`test-suite/format`](../../test-suite/format) are
written by the formatter, which keeps source spellings (`0xFF`, `1_000`,
`\u{41}`, blanks in byte strings), comments and blank lines; the writers here agree with
them byte for byte on every input without those (60 of 70 compact and
minimised files, 30 of 70 pretty files; PLAN.md L3, L5). The bindings'
value writers are fuzzed against them (`haus-ref --write-batch`, `node
fuzz/src/main.ts --format`, [`fuzz/README.md`](../../fuzz/README.md#formatters)).

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

The value limit (§7) and strict mode (§6) are added on top
([`Stream/Limited.lean`](Haus/Stream/Limited.lean), `readWith`). A value's
characters are counted from the previous top-level comma (or the start,
after a byte order mark) up to the next one, the text after the last comma
included (`valueLengths`); the limit is checked on a value before it is
parsed, so the first error in the stream wins. The whole-text `parse` doesn't
apply it.

| Theorem | Says |
|---|---|
| `readWith_chunks` | However the text is split, the same values and error |
| `readWith_cases` | For any text, the reader gives what `read` gives, or stops with `value-too-long` or, in strict mode, `stream-truncated`, after some of `read`'s values |
| `readWith_valid` | For a text `parse` accepts: `value-too-long` exactly when some value's characters exceed the limit (`Fits`), else `stream-truncated` exactly when in strict mode a value follows the last top-level comma (`Terminated`), else no error; the values are the first values of the whole text, all of them without an error |
| `readWith_correct` | The reader returns `vs` without an error exactly when `parse` accepts the whole text with `vs`, every value fits, and in strict mode the stream is terminated |
| `readWith_eq_read` | Within the limit and not strict, it is `read` |

Not modelled: UTF-8 decoding and error positions.

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
| `decodeStream_error` | An error decoding a stream (`decodeStream`) is the error of one item, its place starting with the item's index (`$[3].price`, §15) |
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

**About schema files** (spec §14), in [`Haus/SchemaFile/`](Haus/SchemaFile).
A type as written is a term `Tm`: a parameter, a name applied to arguments,
or a record or variant node (a spread `...Name` is the name `Name` in it).
`parse` reads a schema file's text (with the data parser's comments,
strings and attribute values), `declare` and `check` apply the static rules
of §14, `Source.instances` finds the instances of generic types that the
definitions without parameters reach, `translate` turns each into a `Ty`
(spreads copied in), and guarded recursion (§9.9) is checked on the result
with the decoder's own `whnf`, and on every definition, used or not (a
generic one with `Any` for its parameters, `Source.templates`); `load` does
all of it, text to `Env`. Spread cycles are found at any depth
(`checkSpreadCycles`: the definitions a definition's spreads, and the names
they stand for, need built first, without fuel). A package or file import is
checked as the bindings check it (`checkModule`: `unknown-module` with the
package model's `isPackageName`, `import-version`) and is then
`import-unavailable`: resolving it (finding the package and bringing its
definitions in) is `Haus.Packages`'s, and not wired into `load`. All cases
of `test-suite/schema` pass with it, and every schema file in
`test-suite/schema/invalid` is rejected with its code.

| Theorem | Says |
|---|---|
| `Source.reach_finite` (I6) | In a file without an expansive cycle (§9.10: `GrowthOk`, no expanding edge of the parameter graph on a cycle), the instances reachable from any types `ts` are at most `instBound F ts`, a number computed from the file and `ts` |
| `check_finite` (I6) | The same for every file `check` accepts: its rule for §9.10 (`checkGrowth`) holds exactly when `GrowthOk` does (`checkGrowth_iff`, through `iterReach_complete`/`iterReach_sound`: the checker's rounds find exactly the parameters a parameter leads to) |
| `Source.infinite_of_expansive`, `Source.growthOk_iff_finite`, `checkGrowth_iff_finite` (I6) | The converse: in a file `declare` and `checkParams` accept (`WellFormed`), an expanding edge on a cycle makes a type without parameters (`A Int … Int`) reach infinitely many instances; so §9.10 holds exactly when every type reaches finitely many, and `checkGrowth` decides it |
| `wellFormed_of_declare`, `check_wellFormed`, `load_wellFormed`, `declare_checkGrowth_iff_finite` | `WellFormed` is what `declare` and `checkParams` check (names found, parameters distinct, bodies using their own), proven, not assumed: so §9.10's check passes exactly when every type reaches finitely many instances, for every file `declare` and `checkParams` accept |
| `doubling_infinite`, `doubling_checks_without_growth`, `doubling_rejected` | §9.10's example (`type A a = < X (B (P a a)) \| Done >`, `type B a = < Y (A (P a a)) \| Stop >`) passes every other rule, reaches infinitely many instances, and is rejected by §9.10's rule |
| `Source.instances_reach`, `Source.instances_some` | What the reference computes is exactly the reachable instances; for a checked file it returns whenever `instBound` is within the bindings' limit |
| `load_decode` (I4) | For every schema file `load` accepts and every name in it, decoding any value never fails with `unknown-type` or `unguarded-recursion`; `whnf_ok`: following names succeeds on every closed type within `env.fuel` steps |

**About codecs and profiles** (spec §13.3, §13.4). A codec
([`Schema/Codec.lean`](Haus/Schema/Codec.lean)) reads the value the type's
schema decoded into a host type, or rejects it, and writes a host value
back as a decoded value for the schema's encoder; a profile is a check, a
codec that keeps the decoded value (`Codec.check`). The laws of §13.4 are
proven once, for every codec that keeps the value (`Codec.Keeps`, which
every check does):

| Theorem | Says |
|---|---|
| `Codec.decode_ok`, `Codec.decode_schema` | It accepts only what the schema accepts: exactly what it reads from a value the schema decoded |
| `Codec.decode_error` | It rejects more, never fewer: what the schema rejects, it rejects with the schema's error |
| `Codec.decode_encode` | Decode, encode, decode is decode, from the schema's `decode_encode` |
| `Codec.decoded`, `Codec.dec` | What it decodes is the value the schema decoded (and so follows the rules of §15) |
| `Codec.encode_eq`, `Codec.encode_equiv`, `Codec.encode_agree` | Encoding through it writes what the schema's encoding of the decoded value writes: equal (§2), the same canonical form and hash, and the input except where §15 says |
| `Codec.same_value` | Two codecs that both accept a value agree on what it is; they differ only in what they accept |
| `Codec.decode_encode_of` | A codec whose host type keeps less (a `Date` for an `Instant`) still has decode, encode, decode, when what it writes is a value of the type that reads back as the same host value |

The official profiles ([`Haus/Profiles/`](Haus/Profiles)) state their
rules (`extensions/*/profiles/*.md`) on the decoded value, with a checker
proven to compute each (`Money.check_iff`, `Geo.check_iff`), and are codecs
(`Money.codec_decode`, `Geo.codec_decode`: the codec accepts exactly the
values the schema decodes that the rule accepts, kept as decoded; with
`codec_keeps`, every law above). `@haus-fmt/money/iso`: a `Currency` is a
bare tag of three capitals `A`–`Z`, a `Money` any `Decimal` with such a
currency. Both codecs in one `Money` run from the inside out
(`Money.decodeInsideOut`, §13.4): the currency's first, so a bad currency
is rejected at its own place, `$[1]`; together they accept exactly what the
codec of `Money` alone accepts (`Money.decodeInsideOut_ok`).
`@haus-fmt/geo/wgs84`: the ranges are stated on the exact value of
the decoded float as a rational number (`Geo.toRat?`; `NaN` and the
infinities have none, so they are rejected), and checked with products of
integers; `BBox` also needs `sw.lat ≤ ne.lat`. The packages' schemas are
written in Lean (`Money.env`, `Geo.env`), as `scripts/schema-types.ts`
resolves `extensions/*/schema.haus` (compared by hand, not in CI). `haus-ref --profile NAME FILE` runs a vectors file: an
`Accept` passes when the codec accepts `value` and writes back the same
value as `output` (or `value`), and exactly `output` when one is given; a
`Reject` when `value` is valid for the schema of its type (the shape) and
the profile rejects it, so the rejection comes from the rule: a `Reject` the
schema already rejects fails, with the schema's error. Both vectors files
pass.

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
| `record_case_named`, `record_case_ref` | Naming a record changes nothing (§15, design review B7): in a variant, the case `Tag T` with `T` a record through names (in parentheses, `type Disc = { … }`, an alias chain, an applied generic's instance) and `Tag { … }` written in place decode the same haus text, write the same schema-based JSON and read the same JSON, for every value and every fuel of the `Maybe` chains |
| `positional_one_toJson`, `positional_one_fromJson`, `result_ok_toJson`, `result_ok_fromJson` | A type parameter never makes a record case: one positional argument, `Ok a` of `Result` included, is written as `{"_tag": …, "value": J}` and read from `value` alone, `J` the argument's own JSON, whatever its type (`Case.resolve_positional`) |
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
| `older_reads_newer`, `older_reads_newer_name`, `older_reads_newer_parsed` | An older reader accepts a newer writer (§13.3, §16.3): when `env'` is a later minor version of `env` (`Env.Minor`) and `t'` the newer version of `t` (`MinorTy`), the older reader reads the newer writer's schema-based JSON of every value `t'` decodes (well formed, no duplicate keys: every parsed value) without an error, as the value with each case the older schema doesn't list read as an unknown value and each field it doesn't list left out (`Older`); for every fuel `F` of the `Maybe` chains, the same on both sides |
| `JSON.toValue_uniqueKeys`, `JSON.readImport_uniqueKeys` | What the JSON import returns has no duplicate keys (`UniqueKeys`), as `parse_uniqueKeys` says of the haus parser |
| `JSON.fromSelfDescribing_uniqueKeys`, `JSON.fromHausJson_uniqueKeys`, `JSON.readHausJson_uniqueKeys`, `JSON.readHausJsonLines_uniqueKeys` | The same for the self-describing reader, without and with the envelope, from text and from JSON Lines |
| `json_paths_agree` | A value's self-describing JSON read back and decoded with `t` gives what its schema-based JSON read with `t` gives |
| `toJson_eq`, `fromJson_eq`, `toJsonF_fuel`, `fromJsonF_fuel`, `chainNull_fuel` | `nullFuel` is enough for every chain of `Maybe`s: from `env.fuel` on, the fuel changes nothing, and `toJson`/`fromJson` are `toJsonF`/`fromJsonF` at any such fuel |
| `record_case_named_json`, `older_reads_newer_json` | J11 and J9 for `toJson` and `fromJson` themselves, each type and schema with its own `nullFuel` |

A case is a record case when it is written `Tag { … }` or when its one
argument, written as a name or in parentheses, is a record through
references (`Case.resolve`, `recordOf?`); `caseOf?` returns the resolved
case, so decoding, the rules and both JSON directions see record cases only
as `Tag { … }`, and the round trip covers record cases written by name.
`record_case_named` holds for each fuel, and `record_case_named_json` for
`toJson` and `fromJson` themselves, whose fuel (`nullFuel`) counts the two
types differently. [`Json/RecordCases.lean`](Haus/Json/RecordCases.lean) has
the theorems.

The schema-based round trip goes by induction on the rules of decoding (`Dec`),
with `floatLaw` for floats. A `Maybe` writes `None` as `null` only when its
argument's JSON can't be `null` (`nullArg?_next`, `toJsonC_null`), whatever
the rule for cycles of `Maybe`s decides, so `null` is never ambiguous.
`#print axioms` shows only `propext`, `Classical.choice` and `Quot.sound`.

**A newer writer, an older reader** (§13.3), in
[`Json/Evolution.lean`](Haus/Json/Evolution.lean). `Env.Minor env env'`
is §13.3's minor version: every type of `env` is defined in `env'` as the old
definition with new optional fields in open records (`MinorFields.add`) and
new tags, of any payload, in open variants (`MinorCases.add`), anywhere
inside, and `env'` may define new types. A new field key or tag is not one
the record or variant already has after it; a new tag is a tag. A
`closed < None | Some a >` (the prelude's `Maybe`) keeps its argument as it
is written (a name in it may change). `older_reads_newer` goes by induction
on the newer decoding, like the round trip; the two schemas follow the same
names (`whnf_minor`, `recordOf?_minor`), take the same `Bool`
(`boolTy_minor`), the same origins and the same cases and fields
(`caseOf?_minor`, `find_minorFields`), and write `null` for the same
`Maybe`s (`nullArg?_minor`). Each schema follows names with its own fuel,
`env.fuel`, which grows with the number of definitions; it is enough for
every name chain ([`Json/Fuel.lean`](Haus/Json/Fuel.lean): `whnfNames_nodup`,
a chain that ends visits each name once, so `whnf_enough`), so more fuel
gives the same results (`whnf_fuel`, `recordOf?_fuel`, `lastRef_fuel`,
`reachesBool_fuel`). Types are compared structurally (`Ty.beq`, lawful);
the derived `BEq` was a `partial` function nothing could be proven about.
The theorem is stated for one fuel `F` of the `Maybe` chains on both sides;
`older_reads_newer_json` states it for `toJson` and `fromJson`, each schema
with its own `nullFuel`. Not modelled: a `Maybe`'s argument written in place
(`Maybe < A | B >`, rather than a name) can't grow.

**The chains of `Maybe`s** (J9, J11), in
[`Json/NullFuel.lean`](Haus/Json/NullFuel.lean). After its first link, a
chain goes on only at the body of a definition of the prelude's `Maybe`
(`links_mem`; a type written in place inside one is the schema's own,
`origin`), so it meets at most `env.fuel` links that go on; for any function
with such a bound, a chain ends at the same place from that many steps on
(`endOf_stable`, by pigeonholes). So `chainNull_fuel`, `nullArg?_fuel`; the
JSON functions see the fuel only through `nullArg?` (`toJson_congr`,
`fromJson_congr`, by their functional induction), so `toJsonF_fuel`,
`fromJsonF_fuel`; and `nullFuel env t ≥ env.fuel` (`fuel_le_nullFuel`), so
`toJson_eq`, `fromJson_eq`: `toJson` and `fromJson` are `toJsonF` and
`fromJsonF` at every fuel from `env.fuel` on.

**About versions** (spec §10), in [`Haus/Version.lean`](Haus/Version.lean).
A `Version` is what a version fixes: its default limits (§7, the stream
value limit too), its catalogue of error codes and the codes it fixes for
texts with one mistake (§17), its files (values, or an error's code), its
canonical form and what `hash` and `hashAll` hash (§12), its built-in types
and schema files, each type with its decoder and its schema-based JSON
(§16.3), and its self-describing JSON and JSON import (§16.1, §16.2).
Everything is written on haus values and texts, with codes by name, so
versions with different host types and catalogues compare. `Extends old
new` says: every text `old` accepts, `new` accepts with the same values; on
what `old` can express, the canonical form, the hash, the self-describing
JSON, and every built-in type and type of a schema `old` accepts (decoding
and schema-based JSON) are the same; each JSON reader reads what the old one
reads, alike; the default limits only grow; no code leaves the catalogue;
and a text whose code `old` fixes keeps it, unless it has become valid.
Proven: `Extends.refl`, `Extends.trans`, `Extends.expresses`,
`Extends.hash`, `Extends.hashAll_parse`, `Extends.readHausJson_write` and
`current_extends_self`; for this version, `current_hash` (`hash` hashes the
canonical form) and `current_parse_code` (every code its parser reports is
in its catalogue). Each release will prove that it extends the one before.

Codes are compared only where §17 fixes them, for a text with one mistake
(the suite's error cases, `fixed`): with several mistakes, a larger limit or
new syntax can legitimately change which one is found first. The decoders'
and JSON readers' error codes are not compared, only what they accept.

**About package resolution** (spec §13.3), in
[`Haus/Packages/`](Haus/Packages). A file tree with directories, regular
files, symbolic links and other files (`Fs.lean`), and the reference
resolver on it (`Resolve.lean`), which reads files only through one function
that records them; `haus-ref --packages` runs the package suite with it. On
it: the packages a run makes have distinct names, and on success they are
the result (`one_package_per_name`, `resolveIn_ok`); a copy is one package
with another only if its `package.haus`, `schema.haus` and imports are the
same (`addClass_same`); and type ids `@org/name@N#Type` are injective
(`typeId_injective`).

The resolver sees the tree only through `look`, which tells kinds, names,
links and real paths but never a file's bytes, and `openFile`, which records
each file it opens. Properties of whole runs are proven a function at a
time, with Hoare-style triples for the resolver's monad (`Run.lean`) and
`load` by induction on its fuel:

| Theorem | Says |
|---|---|
| `reads_allowed` | Every file a run opens is a package's own `package.haus`, `schema.haus` or `package.json` (a regular file directly in a directory with a `package.haus`, never through a link), a regular file whose real path ends in `.schema.haus` (or the root), or the real path of a `package.json` in a directory above a schema file (R7, P1) |
| `resolveIn_same`, `resolveIn_other_files` | Two trees that differ only in the bytes of files the run doesn't open give the same result, message and reads; so changing a file outside the read set changes nothing (R7, P2) |
| `reads_nodup`, `reads_length_le` | Each file is opened at most once, so at most as many as the tree has (R4) |
| `count_le`, `openFile_spec` | At most `Limits.files` schema files, the root included; the bytes of a file opened are within its limit, or the run fails before using them (R4) |
| `lookups_le`, `lookups_le_files` | The searches for a package are at most the imports of the files loaded: files × the most imports in one file (R4) |
| `candidates_from` | A package found for `@org/name` is one given explicitly with that name, or what the npm walk finds (R5) |
| `npmLookup_eq`, `npmLookup_isolated`, `walk_mem`, `walk_skips_scope` | The walk reads no file and depends only on the real paths of `D/node_modules/@org/name`, for the directories `D` from the importer's up that §13.3 keeps: never `node_modules/@scope/node_modules` (R5, F1). Node's walk does try it (`nodeWalk_scope`) and finds a planted package (`#guard`) |
| `runIn_closed`, `classes_topo` | In every state of every run, a package imports only packages made before it, and every copy loaded names a package made: the packages reached and their imports form a graph without cycles, made imports first (a step of R3, `Closed.lean`) |
| `resolveIn_walk`, `resolveIn_walk_error` | The result doesn't depend on the order the imports of each file are walked in (`Walk`): a run that succeeds succeeds in every order with the same packages, one that fails fails in every order (R3, F4; the error code may differ; `Walk.lean`) |
| `load_good`, `load_sim` | A successful run's finished targets pass their checks as properties of the tree and import only targets finished before them (`Done.lean`); a run in another order stays below such a state and never fails (R3, `Walk.lean`) |
| `resolveIn_addFolders`, `resolveIn_folders` | Adding folders of packages never turns a successful result into a different one: the same packages, or an error; for any settings with more folders and everything else the same (`MoreFolders`), in any walk orders (R6, F2; `Folders.lean`) |
| `givenPackages_ok`, `load_reach`, `load_wider` | The packages given are exactly those of the directories and folders given; every target a run finishes is reached from the root; two successful loads, the second with more packages in folders (`Wider`: the same packages given by directory), make the same packages (R6) |

With two mistakes in one schema, the error reported does depend on the
order (`Order.lean`); the spec doesn't say which one is reported, and R3 is
about success, failure and the packages. R6 is about two successful runs: a
folder can turn a success into an error (a second copy of a package with
other files is `duplicate-package`), as intended.
