# Differential testing

Generated inputs go through every haus parser: the Lean reference parser
(`spec/lean`), Rust, Roc, TypeScript, Python, Go, Swift and the JVM (and, with `--schema`,
through every schema decoder: see [Schema decoding](#schema-decoding); with
`--json`, through every JSON converter: see [JSON](#json); with `--format`,
through the formatters and value writers: see [Formatters](#formatters); with
`--schema-check`, through every schema-file checker: see
[Schema files](#schema-files)). They must agree on every input:
accepted with the same values, or rejected. A disagreement is a bug in at
least one of them, or a gap in the spec.

```sh
sh fuzz/build.sh                       # build the parsers under test
sh fuzz/build.sh lean rust             # or only some (parts: lean rust typescript python go zig swift jvm roc)
node fuzz/src/main.ts --count 100000   # about a minute
node fuzz/src/main.ts --seed 7         # repeat a run
```

Needs Node 23.6 or later (it runs the TypeScript directly), Lean (elan),
Rust, Roc, Python (uv), Go, Swift and a JDK 17 or later (`JAVA_HOME`). The Go runner, [`go/`](go), is one program
for every fuzzer (`go-runner MODE …`), a module of its own that builds
against the checkout; it finds the schema files and extensions through the
path it was built from, as the Rust runners do. The JVM runner, [`jvm/`](jvm),
is a project of the Gradle build in [`../jvm`](../jvm), installed into
`.build/jvm-runner` (`jvm-runner MODE …`, the same protocol as Go's). CI ([`ci.yml`](../.github/workflows/ci.yml)) runs every
fuzzer on every pull request with a new seed, and much longer every night;
a failure prints the seed and keeps the shrunk inputs as an artifact.

## How it works

| Step | |
|---|---|
| Generate | [`src/generate.ts`](src/generate.ts): random haus text with varied formatting (spacing, comments, CRLF, byte order mark, number spellings, quoted keys, block strings, both payload forms, trailing commas), values at and just past the limits, the conformance suite as seeds. Half of the inputs are then mutated: bytes deleted, edge characters inserted (quotes, `*/`, control and bidi characters, invalid UTF-8), slices duplicated, cut short. |
| Run | [`src/runners.ts`](src/runners.ts): each parser reads a batch of files and prints one line per file, `ok <values>` in the test-suite JSON encoding or `err <line> <column> <reason>`. The stream readers of Rust, Roc, TypeScript, Python, Go, Swift and the JVM run too, on the same inputs cut into chunks (sizes 1, 2, 3, 5, 8, 13, 64 in turn), and must give what parsing the whole input gives. A runner that crashes is rerun case by case, and the crash counts as a disagreement. |
| Compare | [`src/main.ts`](src/main.ts): accept/reject and the values must agree, and so must the error codes (spec §17) of runners that report them, wherever two report an error at the same position. |
| Shrink | A disagreeing input is cut down to the smallest input that still disagrees, and saved to `.out/failures/` with every parser's result. |

Error positions are reported separately: the spec fixes their units (§8)
but not which error a parser reports first, so they may differ. Error codes
are compared where positions agree: an error at the same place is the same
mistake. A runner that reports codes prints `err <line> <column> <code>
<reason>` and is marked `{ codes: true }` in `runners.ts`; the others print
`err <line> <column> <reason>`, and their codes aren't compared. Today all of
them report codes.

## The runners

| Parser | Runner |
|---|---|
| Lean | `haus-ref --batch DIR N` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)) |
| Rust | [`rust/haus/examples/fuzz_runner.rs`](../rust/haus/examples/fuzz_runner.rs) |
| Roc | [`roc/fuzz/runner.roc`](../roc/fuzz/runner.roc) |
| TypeScript | in this process ([`src/runners.ts`](src/runners.ts)) |
| Python | [`python/fuzz/runner.py`](../python/fuzz/runner.py) |
| Go | [`go/`](go) (`go-runner`) |
| Swift | [`swift-runner/`](swift-runner): a package of its own on [`../swift`](../swift) (a directory named `swift` would clash with it: SwiftPM names packages by their directory) |
| JVM | [`jvm/`](jvm) (`jvm-runner`) |
| Stream readers | the same runners with `--stream` (TypeScript: in this process) |

A new binding needs a program that reads `DIR/00000.haus` … `DIR/{N-1}.haus`
and prints those lines (with `--stream`: through its stream reader, chunk k
of case i being `[1, 2, 3, 5, 8, 13, 64][(i + k) % 7]` bytes), plus an entry
in `runners.ts`.

## Found so far

| | |
|---|---|
| Rust stream reader crashed on input ending in `/` | design review S13 |
| Stream readers accepted a byte order mark after a comma | design review S14 |
| Roc's std/time check accepted durations with more than ~309 digits (too large for a float) | fixed: exact integers |
| Effect dropped a record field or map key named `_tag` (`{ _tag: 1 }` as `Map Int` decodes and reads from JSON as `{}`) | fixed (`--schema`, `--json`) |
| Effect rejected an open record payload with an unlisted field `_tag` (`Circle { _tag: 1, r: 1 }`) instead of ignoring it | fixed (`--schema`, `--json`) |
| Roc's plain JSON readers didn't check the depth of the value read (257 nested `{"_tag": "Some", "value": …}` read as `Loop`) | fixed (`--json`) |
| TypeScript and Effect rejected a schema file with a record payload field named `_tag` (`< Odd { _tag: Int32 } >`), where the others report only its JSON | fixed: the schema compiles, the case nests its payload as `value` (`--json`, [`json/names.schema.haus`](json/names.schema.haus)) |
| TypeScript, Effect and Python reported a tagged `Maybe` without `"_tag"` (`{}`) as `unknown-tag`, not `missing-member` | fixed (`--json`, codes; [`json/plain.cases.haus`](../test-suite/json/plain.cases.haus)) |
| TypeScript, Effect and Rust reported an unknown member of a closed record in plain JSON at the record, not at the member (`$.x`) as when decoding | fixed (`--json`, codes) |
| Go reported `"""` at the end of input as `unterminated-block-string`, not `block-string-opening`, and a raw control character on an under-indented block-string line before the indent | fixed (parser) |
| Go's `strconv.ParseFloat` rounds literals of more than 800 significant digits wrongly (a halfway value near the smallest normal float64, 10⁸ too small) | fixed: Go rounds those exactly (`--schema`) |
| Go's formatter: a comment after a multi-line comment trailed the entry; a comma on its own line made a blank line; a comment between a key and its value went below the entry's blank line; a blank line before a payload record's `}` was lost | fixed (`--format`) |
| TypeScript and Effect overflowed the stack on a record that reaches its own record case by name (`type C = { s: < S B > }`, `type B = C`) | fixed (`--schema-check`) |
| The same schema overflowed the stack in [`schema-types.ts`](../spec/lean/scripts/schema-types.ts), which resolves the suite's types for Lean and these fuzzers (haus-gen, haus-fmt-build, Python and Go were fine) | fixed: inside its own record such a case has only `"named"`; in the schema suite ([`variants.schema.haus`](../test-suite/schema/variants.schema.haus)) |
| Rust had no nesting limit for types (`type-too-deep`), and Go counted each parenthesis twice | fixed (`--schema-check`) |
| A `/` that starts no comment was `schema-syntax` in every binding, `stray-slash` (as in data) in Lean | fixed in TypeScript, Python, Rust and Go (`--schema-check`) |
| Attribute arguments without their `)` after a value (`@deprecated("x"`) were `unclosed-bracket` in Rust and Go, `missing-comma` in Lean | fixed (`--schema-check`) |
| `"""` as a field key was `block-string-key` (Python, Go) or `string-line-break` (TypeScript); Lean reads the key `""` and then a `"` (`schema-syntax`) | fixed (`--schema-check`) |
| Go reported a quoted key cut by a line break as `unterminated-string`, not `string-line-break` (or `control-character` for CR LF) | fixed (`--schema-check`) |
| Rust reported a lexical mistake anywhere in the file before a syntax error earlier in it | fixed: the grammar is read up to the lexical mistake (`--schema-check`) |
| Rust and Go read an attribute's arguments as a file of their own: a byte order mark at their start was skipped (`@deprecated(` U+FEFF `"x")` accepted), and `#haus` there was `version-directive`; both are `expected-value` | fixed (`--schema-check`) |
| Go read `{"_tag": "A", "": 0}` for a tag without payload as `A`: a member named `""` passed as the payload member a tag without one doesn't have | fixed: `unexpected-member` (`--json`) |
| Go's stream reader reported `#haus` after a comma (`1,#haus 2`) as `version-directive`, not `expected-value` | fixed (found with the above) |

## Canonical forms

`node fuzz/src/main.ts --canonical` runs the same inputs through each
binding's `canonical` (spec §12) instead of its parser: for every accepted
input, all bindings must write exactly the same text (the Lean reference encoder
through `haus-ref --canonical-batch`, the others through their runners with
`--canonical`).

## std/time

The same idea for the std/time checkers (spec §13.2,
[`std/time.md`](../spec/std/time.md)): generated strings through the Lean
model ([`spec/lean/Haus/Time`](../spec/lean/Haus/Time), proven to compute
the rules) and the TypeScript, Rust, Roc, Python, Go, Swift and JVM checkers, which must agree on
every one.

```sh
node fuzz/src/time.ts --count 2000000   # about half a minute
node fuzz/src/time.ts --runners lean,go,jvm   # only some checkers, Lean first
```

[`src/time.ts`](src/time.ts) builds strings for each type from their parts,
weighted towards the edges: leap and century years, day 29–32, `24:00:00`
and `:60`, fractions of 0, 9 and 10 digits, `-00:00` and `+24:00`, zones
with `.`, `..` and empty parts or 255–256 characters, durations at the 2³²
and 2⁵³ bounds and with hundreds of digits, zero components among ones that
aren't, and zero seconds alone (`PT0S`, `PT0.000S`). Some are given to the wrong
type, and 40% are then mutated (characters removed, inserted or replaced
with separators, `NUL`, non-ASCII). A disagreeing string is shrunk like
above.

| Checker | Runner (`FILE` of lines `TYPE HEX`, the text as hex UTF-8; prints `ok` or `no`) |
|---|---|
| Lean | `haus-ref --time-batch FILE` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)) |
| Rust | [`rust/haus/examples/time_runner.rs`](../rust/haus/examples/time_runner.rs) |
| Roc | [`roc/fuzz/time_runner.roc`](../roc/fuzz/time_runner.roc) |
| TypeScript | in this process |
| Python | [`python/fuzz/time_runner.py`](../python/fuzz/time_runner.py) |
| Go | [`go-runner --time`](go/time.go): `schema.CheckTime` |
| Swift | [`swift-runner --time`](swift-runner/Sources/swift-runner/Lines.swift): `checkTime` |
| JVM | [`jvm-runner --time`](jvm/src/main/java/org/hausfmt/fuzz/TimeMode.java): `StdTime.check` |

## Profiles

The same idea for the codecs of the official profiles (spec §13.3, §13.4;
audit plan X3): `@haus-fmt/money/iso`
([`iso.md`](../extensions/money/profiles/iso.md)) and `@haus-fmt/geo/wgs84`
([`wgs84.md`](../extensions/geo/profiles/wgs84.md)). Generated values and
near misses of each type go through the Lean reference checkers
([`spec/lean/Haus/Profiles`](../spec/lean/Haus/Profiles), proven to compute
the rules) and every binding's codecs, which decode the value with the
package's schema and the profile, and encode what they decoded.

```sh
sh fuzz/build.sh                           # also builds the profile runners
node fuzz/src/profiles.ts --count 200000   # cases per profile; about 75 seconds
node fuzz/src/profiles.ts --seed 7 --profiles wgs84 --runners rust,python
```

[`src/profiles.ts`](src/profiles.ts) generates, for `Money` and `Currency`:
currency tags of 1–6 characters, mostly 2–4 capitals, some with lowercase
letters, digits, `_` or characters that can't be in a tag, and with payloads
(`EUR(1)`, `EUR {}`, `EUR([])`); amounts in every spelling of a `Decimal`
(scales, exponents, `-0.00`, hex and binary, `_`, at the length and exponent
limits) and things that aren't one (`NaN`, strings, tags). For `LatLng` and
`BBox`: coordinates at ±90 and ±180 and one float either side, exactly
halfway to the next float beyond a bound (ties to even: onto the bound) and
a hair either side, literals that round onto a bound
(`90.00000000000000001`) or just below it (`89.999…9`), `-0` and `0` in every
spelling, `NaN` and the infinities, overflow, underflow to zero and
subnormals, integers and floats, hex and binary, hundreds of digits; boxes
with the latitudes in and out of order, equal, `-0` against `0` and one float
apart, across the antimeridian and at ±180. Near misses: the wrong number of
arguments, record payloads, other tags, other kinds of values, the other type
of the profile; a few are mutated as text. A disagreeing case is shrunk as
for std/time, to the smallest text with the same pattern of disagreement.

Compared: accepting or rejecting, and the canonical form (§12) of what is
written back. Where Lean and a binding report an error code at the same
place, the codes must agree; a value the schema accepts and the profile
rejects must be a `type-mismatch` (the profiles' "Encoding"), at any place
(a binding may report a `BBox`'s corner, where Lean reports the box). Lean
reports a profile's rejection as `err $ - not accepted by …`, without a
code; reasons are not compared.

| Codecs | Runner (`FILE` of lines `TYPE HEX`, the value's text as hex UTF-8; prints `ok <canonical>` or `err <place> <code> <reason>`) |
|---|---|
| Lean | `haus-ref --profile-batch NAME FILE` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)) |
| TypeScript | in this process: `@haus-fmt/money`'s `iso` and `@haus-fmt/geo`'s `wgs84` with `compileSchemaFile(schema.haus, { codecs })`, `h.decode`, `h.encode` |
| TypeScript (`typescript-h`) | in this process: the packages' `h.*` schemas `Money`, `Currency`, `LatLng`, `BBox` |
| Effect | in this process: the packages' `./effect` codec groups with `Haus.decodeValue(schema, codecs)`, `Haus.encodeValue(schema, codecs)` |
| Rust | [`schema-rust/src/profile_runner.rs`](schema-rust/src/profile_runner.rs): `haus_money::{Iso, IsoCurrency}`, `haus_geo::{Wgs84, Wgs84BBox}` as generated code runs a codec (`haus::de::codec`) |
| Roc | [`roc/profile_runner.roc`](roc/profile_runner.roc): `Iso`, `IsoCurrency`, `Wgs84`, `Wgs84BBox` of `extensions/*/roc` with `Decode.codec` |
| Python | [`python/fuzz/profile_runner.py`](../python/fuzz/profile_runner.py): `haus_money.iso` and `haus_geo.wgs84` with `haus.schema.load_schema(…, codecs=…)` |
| Go | [`go-runner --profile`](go/profile.go): `ext/money`'s `Iso`, `IsoCurrency` and `ext/geo`'s `Wgs84`, `Wgs84BBox` with `Type.DecodeWith` and `EncodeWith` |
| JVM | [`jvm-runner --profile`](jvm/src/main/java/org/hausfmt/fuzz/ProfileMode.java): `MoneyCodecs.ISO`, `ISO_CURRENCY` and `GeoCodecs.WGS84`, `WGS84_BBOX` (`org.hausfmt.ext`) with `SchemaType.decode`, the codec's `decode` and `encode`, and `SchemaType.encode` |

So far every binding agrees with Lean on every case generated.

## Schema decoding

The same idea for decoding with a schema (spec §15): generated values are
decoded with a type of the schema suite ([`test-suite/schema`](../test-suite/schema),
plus [`schema/fuzz.schema.haus`](schema/fuzz.schema.haus) for the integer
sizes, std/time types and nestings the suite leaves out) and encoded again,
by the Lean reference decoder and by each binding. They must agree on
accepting or rejecting, and on the canonical form (§12) of what is encoded;
error messages and places may differ.

```sh
sh fuzz/build.sh                               # also builds the schema runners
node fuzz/src/main.ts --schema --count 20000   # about 15 seconds
node fuzz/src/main.ts --schema --seed 7 --runners lean,typescript,rust
```

[`src/schema-gen.ts`](src/schema-gen.ts) generates a value for each type
from its resolved form (the JSON that
[`spec/lean/scripts/schema-types.ts`](../spec/lean/scripts/schema-types.ts)
writes for Lean): mostly values the type accepts, written with varied
formatting, and near misses: the wrong kind of value, missing and extra
fields, unknown tags in open and closed variants, the wrong number of
arguments, `Some` without its argument. Numbers sit on the edges: integers
at and just past each range and at the number limit (where the canonical
form switches to hex), `-0` in every spelling, floats as their exact decimal
value or exactly halfway to the next float (or a hair either side, which
catches rounding to binary64 before binary32), near overflow and underflow;
decimals with scales, exponents and negative zeros. Strings have escapes,
control and bidi characters and astral characters; keys sort differently by
code points and by UTF-16 units; `Any` gets arbitrary values; recursive
types sometimes go down to the nesting limit (256) and past it. A case that
disagrees is shrunk to the smallest value with the same pattern of
disagreement. An error inside a `Secret` that shows a part of the value is
reported too: a part of it (5 characters or more) in the message, unless the
message still has it when the case is run again with that part disguised
(then it is a word of the binding's own message, such as a key `value`
against "the value is not shown"). [`src/secret.test.ts`](src/secret.test.ts)
tests the check: `node --test fuzz/src/`.

| Decoder | Runner (`FILE` of lines `SUITE TYPE HEX`, the value's text as hex UTF-8; prints `ok <canonical>` or `err …`) |
|---|---|
| Lean | `haus-ref --schema-batch TYPES FILE` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)) |
| TypeScript | in this process: `compileSchemaFile`, `h.decode`, `h.encode` |
| TypeScript (`typescript-codec`) | in this process: `h.parse` of the text and `h.stringify` (minimised) of the result on the generic path (`withCodec(…, "generic")`, compared with Lean), and on each compiled path checked against it: closures, code generated at runtime, and code generated ahead by @haus-fmt/import (each schema file built into a module with `optimize` for all its types, loaded, which marks its schemas as `h.optimize` does; needs `typescript/packages/import/dist`). On the case, on texts near it and on values near the decoded one: the same values, texts and errors, and no falling back on what the generic path accepts ([`src/codec.ts`](src/codec.ts)); a difference is a crash |
| Effect | in this process: `Haus.compileSchemaFile`, `decodeValue`, `encodeValue` |
| Rust | [`schema-rust`](schema-rust): the code haus-fmt-build generates for each schema |
| Rust (`rust-check`) | [`schema-rust/src/check_runner.rs`](schema-rust/src/check_runner.rs): haus-fmt-schema's runtime checker, `Schema::decode` |
| Roc | [`roc/schema_runner.roc`](roc/schema_runner.roc), with the modules `haus-gen roc` generates ([`roc/gen_schemas.ts`](roc/gen_schemas.ts)) |
| Python | [`python/fuzz/schema_runner.py`](../python/fuzz/schema_runner.py): `haus.schema.compile_schema`, `decode`, `encode` |
| Go | [`go-runner --schema`](go/schema.go): package schema's `Parse`, `Type.Decode`, `Type.Encode` |
| Swift | [`swift-runner --schema`](swift-runner/Sources/swift-runner/Lines.swift): `HausSchema(bytes:)`, `SchemaType.decode`, `encode` |
| JVM | [`jvm-runner --schema`](jvm/src/main/java/org/hausfmt/fuzz/SchemaModes.java): `Schema.parse`, `SchemaType.decode`, `SchemaType.encode` |

Nothing is masked: every binding's default host types keep the value (spec
§13.4), so every runner must agree with Lean exactly. Where Lean and another
runner both report an error code (spec §17) at the same place, the codes must
agree too: Lean's `--schema-batch` prints `err <place> <code> <reason>`, and a
runner made with `external(…, codes = true)` in
[`src/schema-runners.ts`](src/schema-runners.ts) is read the same way
(TypeScript and Effect report codes in this process, and Python, Roc, Go, Swift and both Rust runners are made so). Lossy host types (Effect's
`BigDecimal` and `DateTime`) are opt-in codecs that the runners don't use.

## JSON

The same idea for the JSON mappings (spec §16): generated inputs go through
the Lean reference converters and every binding's, in five directions, and
must agree on accepting or rejecting and on the result, and on the error
code (spec §17) of errors at the same place.

| Mode | Input | Does | Compared |
|---|---|---|---|
| `write` | haus text and a type | decode, write schema-based JSON (§16.3) | the JSON as data: member order doesn't matter, numbers compare by their text |
| `read` | JSON text and a type | read schema-based JSON, encode | the canonical form (§12) |
| `haus-json-write` | haus text | self-describing JSON, in its envelope (§16.2) | the JSON as data |
| `haus-json-read` | JSON text | read self-describing JSON | the canonical form |
| `import` | JSON text | import JSON, without a schema (§16.1) | the canonical form |

```sh
sh fuzz/build.sh                                   # also builds the JSON runners
node fuzz/src/main.ts --json --count 4000          # cases per mode; two or three minutes
node fuzz/src/main.ts --json --seed 7 --modes read,import --runners lean,typescript,rust
```

The types are the schema fuzzer's, plus
[`test-suite/json/schema-based.schema.haus`](../test-suite/json/schema-based.schema.haus)
and [`json/names.schema.haus`](json/names.schema.haus) (a record payload with
a field named `_tag`, which has no schema-based form). A schema file a binding
rejects makes every case of it `err` for that binding.
[`src/json-gen.ts`](src/json-gen.ts) generates the JSON:

- `write` takes the schema fuzzer's values (above). `haus-json-write` takes
  random haus values, values of the schema types, the conformance suite's
  valid files, and nesting at the depth limit (`[`, `{ a:`, `Some(`,
  `T { a:`).
- `read` takes schema-based JSON generated from the type, and the JSON Lean writes
  for generated values (a third of the cases), then near misses: the wrong
  kind of value; missing, extra and repeated members; `_tag` missing,
  renamed, repeated, not a string, not a tag; `value` and `values` swapped
  or of the wrong length; `null` for a `Maybe` that is tagged and the tagged
  form for one that uses `null`, `null` for an optional field; unknown tags
  bare, with `_args` (empty, not an array, not self-describing values) or with other members (`args` among them, an ordinary member); base64
  without padding, with the URL alphabet, whitespace or pad bits; integer
  strings with `+`, leading zeros, exponents, separators, at the 64-bit and
  number limits; decimal strings that aren't JSON numbers; floats exactly at
  and halfway between floats, `"NaN"` and its misspellings; lone surrogates.
- `haus-json-read` takes the self-describing JSON of random values and
  mutations of it: envelopes missing, with other members, another `_haus`
  (`2`, `"1"`, `1.0`) or a member missing; bare numbers, `true`, `null`,
  `_num`s that aren't normalized or are past the number limit (and integers
  whose hex form fits), uppercase or odd hex, tags that aren't tags, empty
  `_args`, the old keys without `_`, extra members, records of bare values;
  raw DEL, C1 and bidi controls; and nesting at the JSON limit (4·256 + 2).
- `import` takes any JSON (envelopes and `_tag` objects among it, which it
  reads as records): numbers at the edges (`-0`, `1E+05`,
  exponent and length limits), strings with escapes, duplicate names, and
  nesting at the limit (256), as well as text that isn't JSON.

All of it is written with varied whitespace and escapes (`\u` for any
character, surrogate pairs, `\/`), sometimes with a byte order mark, and
some of it is edited as text (characters deleted, inserted, duplicated, cut
short) or isn't UTF-8. A disagreeing case is shrunk: JSON by removing
members, elements and characters, haus as for schema decoding.

| Converter | Runner (`MODE FILE`; lines `SUITE TYPE HEX` for `write` and `read`, `HEX` for the others) |
|---|---|
| Lean | `haus-ref --json-batch`, `--json-read-batch`, `--haus-json-batch`, `--haus-json-read-batch`, `--import-batch` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)) |
| TypeScript | in this process: `h.decode` and `h.toJson`, `h.fromJson` and `h.encode`, `toHausJson`, `fromHausJson`, `importJson` |
| Effect | in this process: `decodeValue` and `Haus.toJson`, `Haus.fromJson` and `encodeValue`, `Haus.toHausJson`, `Haus.fromHausJson`, `Haus.importJson` |
| Rust | [`schema-rust/src/json_runner.rs`](schema-rust/src/json_runner.rs): the `ToJson` and `FromJson` code haus-fmt-build generates, `haus::json::to_string` and `from_str`, `haus::to_haus_json`, `from_haus_json`, `import_json` |
| Roc | [`roc/json_runner.roc`](roc/json_runner.roc), with the modules `haus-gen roc --json` generates ([`roc/gen_json_schemas.ts`](roc/gen_json_schemas.ts)) and `JsonValue` |
| Python | [`python/fuzz/json_runner.py`](../python/fuzz/json_runner.py): `SchemaType.to_json` and `from_json`, `haus.to_haus_json`, `from_haus_json`, `import_json` |
| Go | [`go-runner --json MODE`](go/json.go): `Type.Decode` and `Type.ToJSON`, `Type.FromJSON` and `Type.Encode`, `haus.ToHausJSON`, `FromHausJSON`, `ImportJSON` |
| JVM | [`jvm-runner --json MODE`](jvm/src/main/java/org/hausfmt/fuzz/SchemaModes.java): `SchemaType.decode` and `toJson`, `fromJson` and `encode`, `HausJson.toHausJson`, `fromHausJson`, `importJson` |
| Swift | [`swift-runner --json MODE`](swift-runner/Sources/swift-runner/Lines.swift): `SchemaType.decode` and `toJSON`, `fromJSON` and `encode`, `toHausJSON`, `fromHausJSON`, `importJSON` |

Every runner prints an error as `err <place> <code> <reason>`: the place in
the value (`$.items[2].price`), `$` for an error in the JSON text, and `-` for
no code (haus text that isn't one value). Codes are compared where Lean's and
a runner's places agree, as for schema decoding; Lean's JSON readers report
no positions in the text and no places inside self-describing or imported JSON, so
there their errors are at `$`. A runner made with `external(…, codes = true)`
in [`src/json-runners.ts`](src/json-runners.ts) is read this way (all of them
today; TypeScript and Effect report codes in this process).

The output of a run ends with the number of cases each mode accepted and of
error codes compared, and `fuzz/.out/json/coverage.txt` has it per type for
`write` and `read`.

## Formatters

`--format` tests the standard layouts of spec §11 (audit item C2, phase L1
of [`spec/lean/PLAN.md`](../spec/lean/PLAN.md)). Generated documents go
through Lean's model of the formatter (`haus-ref --format-batch`, the reference)
and the TypeScript, Rust, Go, Swift, JVM, Python and Zig formatters in the pretty,
compact and minimised layouts; the values they hold go through the value writers
of TypeScript, Rust, Roc, Go, Swift, the JVM and Python, which must write what
Lean's layout writers write.

```sh
sh fuzz/build.sh                               # haus-ref and the Rust, Roc, Go, Swift, JVM and Python runners
node fuzz/src/main.ts --format --count 20000   # about four minutes
node fuzz/src/main.ts --format --seed 7
```

[`src/format-gen.ts`](src/format-gen.ts) writes documents as people do:
containers on one line or one entry per line, with comments on their own
line, after an entry's comma, before a closing bracket, between a key and
its value, inside `Tag( … )` around the braces of its record and between
top-level items (line and block comments, nested, over several lines, with
blanks at the ends of their lines); blank lines, some with blanks on them;
LF, CR LF or both; a byte order mark; streams with and without a trailing
comma; positional payloads of strings as long as 0 to 80 code points (some
of them wide: `é`, `😀`) so that lines land on both sides of the width;
block strings with blanks at the ends of lines; the spellings layouts keep
(`0xFF_ff`, `1E+05`, `x"9f86 D081"`, `-0x0`); keys with a raw U+2028. Some
inputs come from the parser fuzzer's generator or are files of the suites,
some get whitespace and comments inserted at random places (inside tokens
that mostly makes them invalid), and a few are mutated. Most batches use the
default options; some use another indentation and width (down to 0 and 0).

For every input, and each layout:

| Check | |
|---|---|
| Same bytes | TypeScript, Rust, Go, Swift, the JVM and Python write the same text, or all reject the input; a crash is a finding. |
| Values | The output parses to the input's values (compared by their canonical forms, spec §12). |
| Idempotence | Formatting the output again in the same layout gives it back, in every formatter. |
| Comments | Pretty keeps every comment, in order (a CR LF in one is written as LF); compact and minimised have none. |
| Lines | Compact and minimised: one top-level item per line, each a value on its own, with a comma in a stream and none for a single item; no carriage return, U+2028 or U+2029 anywhere. |
| Minimised | No space or tab outside strings and byte strings. Formatted as pretty, it gives what compact formatted as pretty gives, and the pretty file without its comments and blank lines. |
| Trailing blanks | No pretty line ends in a space or tab outside a comment, and trimming them keeps the values. |
| Layout | Read from the output, without either formatter: keys bare when they can be; one space after `:` and `,`, one between a tag and its `{`, none before `(`; every non-empty record and array broken, each entry one level deeper than its brackets, block strings one level deeper than their entry; a positional payload inline exactly when it fits the width (in code points, with the comma after the entry) and holds no comment, block string or non-empty container; at most one blank line in a row; in a pretty stream a comma after every item and a blank line after each multi-line item that another follows. |

The value writers (no source text: numbers normalized, byte strings in
lowercase hex) are compared with Lean's layout writers
([`spec/lean/Haus/Layout`](../spec/lean/Haus/Layout): `compact`,
`minimised` and `pretty`, proven to parse back to the values), in each
layout and with the batch's indentation and width: every binding must write
each value, and the whole file or stream where it has a writer for one,
byte for byte as Lean does. Lean's text is read back without any writer too:
it holds the values and keeps the layout's rules (above), which checks the
checks.

| Writer | Each value | The file (one value alone, more each with a comma) or a stream (a comma after every value) |
|---|---|---|
| Lean (the reference) | `haus-ref --write-batch LAYOUT DIR N`: `Layout.compact`, `minimised`, `pretty o [] 0` | the file: `compactAll`, `minimisedAll`, `prettyAll o` |
| TypeScript | `stringify(v, { style, indent, width })`, in this process | the file: `format(values, { style, indent, width })` |
| Rust | `haus::to_string`, `to_string_minimised` (no pretty writer from values) | a stream: `haus::to_string_all` (compact) |
| Roc | `Encode.to_str`, `Encode.minimised` (no pretty writer from values) | a stream: `Encode.stream`, `Encode.stream_minimised` |
| Go | `haus.FormatValue` in every layout, with every option | the file: `haus.FormatValues` |
| Swift | `stringify` in every layout | the file: `stringifyAll` |
| JVM | `Haus.write` in every layout, every option | the file: `Haus.writeAll` |
| Python | `haus.stringify` in every layout, every option (0 included) | the file: `haus.stringify_all` |

A failing input is shrunk to the smallest input that still fails the same
check (at most three per check), and saved to `.out/format/failures/` with
the check, what was seen, and every formatter's output in every layout.

| Formatter / writer | Runner (`DIR N`, as for the parsers; prints `ok` and the output as a JSON string, or `err …`) |
|---|---|
| TypeScript | in this process: `parseDocument`, `format(values, { style, indent, width, source, comments })`, `stringify` |
| Lean | `haus-ref --write-batch LAYOUT DIR N` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)): `ok {"values": […], "file": …}` |
| Rust | [`fuzz_runner`](../rust/haus/examples/fuzz_runner.rs) `--format STYLE --indent N --width N`: `haus::format`; `--write STYLE`: `ok {"values": […], "stream": …}` |
| Roc | [`runner.roc`](../roc/fuzz/runner.roc) `--write STYLE`: `ok {"values": […], "stream": …}` |
| Go | [`go-runner`](go/parse.go) `--format STYLE --indent N --width N`: `haus.Format`; `--write STYLE --indent N --width N`: `ok {"values": […], "file": …}`, every option, 0 included |
| Swift | [`swift-runner`](swift-runner/Sources/swift-runner/main.swift) `--format STYLE --indent N --width N`: `format`; `--write STYLE --indent N --width N`: `ok {"values": […], "file": …}` |
| JVM | [`jvm-runner`](jvm/src/main/java/org/hausfmt/fuzz/Runner.java) `--format STYLE --indent N --width N`: `Haus.format`; `--write STYLE --indent N --width N`: `ok {"values": […], "file": …}`, every option, 0 included |
| Python | [`python/fuzz/runner.py`](../python/fuzz/runner.py) `--format STYLE --indent N --width N`: `haus.format`; `--write STYLE --indent N --width N`: `ok {"values": […], "file": …}`, every option, 0 included |

[`src/format.test.ts`](src/format.test.ts) tests the generator and the
checks (`node --test fuzz/src/`): the format suite's expected files keep
every rule, and outputs that break one are caught.

So far the formatters and writers agree, and keep every rule, on every
input generated (Go's formatter after the fixes below), and every value
writer writes what Lean's writes, in every layout.

## Schema files

`--schema-check` tests the schema-file checkers (spec §14): generated schema
files go through the Lean reference checker (`Haus.SchemaFile.load`) and
every binding's, which must agree on accepting or rejecting every file.

```sh
sh fuzz/build.sh                                      # also builds the schema-file runners
node fuzz/src/main.ts --schema-check --count 20000    # about 20 seconds
node fuzz/src/main.ts --schema-check --seed 7 --runners lean,typescript,go
```

[`src/schema-check-gen.ts`](src/schema-check-gen.ts) writes files of one to
six definitions: records and variants (open and closed, optional and quoted
fields, record and positional payloads, spreads of the file's records and
variants), applications of the prelude's and the file's generic types,
parameters, std/time imports, attributes this version defines and ones it
doesn't, doc comments, and the formatting of data files (comments, line
breaks, CR LF, a byte order mark). In half of the files every generic type
is used by a type `Uses`, so that instances of it are checked too; recursion
may be unguarded or growing, used or not. Half of the files get one mistake
of §14: a duplicate, unknown or prelude name, a wrong arity (`Stream`'s
included), a bad parameter, duplicate fields and tags, `closed < >`, a `|`
after the last alternative, spreads of the wrong kind or of themselves (also
through nested spreads), `...r`, the attribute errors, `Stream` out of place,
unguarded and growing recursion (also in types nothing uses), the import
errors (unknown modules and names, package names, versions, whitespace in a
module, packages and files, which nothing resolves here), the lexical errors
of data files, and nesting at the limit (128). A sixth of the rest are edited
as text, a few get invalid UTF-8.

Error codes (spec §17) are compared on the files with exactly one mistake:
the generator's mistake added to a file that every checker accepts. Which
error a file with several mistakes reports is not fixed (§17). Positions are
not compared: Lean reports none. A disagreeing file is shrunk to the
smallest text with the same pattern of disagreement.

| Checker | Runner (`FILE` of lines `HEX`, a file's bytes as hex; prints `ok` or `err [LINE COLUMN] CODE REASON`) |
|---|---|
| Lean | `haus-ref --schema-check-batch FILE` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)): `Haus.SchemaFile.load`, no position |
| TypeScript | in this process: `compileSchemaFile` |
| Effect | in this process: `Haus.compileSchemaFile` (TypeScript's parser and checker, its own schema builder) |
| Rust | [`schema-rust/src/schema_check_runner.rs`](schema-rust/src/schema_check_runner.rs): `haus_schema::Schema::parse` |
| Python | [`python/fuzz/schema_check_runner.py`](../python/fuzz/schema_check_runner.py): `haus.schema.compile_schema` |
| Go | [`go-runner --schema-check`](go/check.go): `schema.Parse` |
| Swift | [`swift-runner --schema-check`](swift-runner/Sources/swift-runner/Lines.swift): `HausSchema(bytes:)` |
| JVM | [`jvm-runner --schema-check`](jvm/src/main/java/org/hausfmt/fuzz/SchemaModes.java): `Schema.parse` |

Roc has no schema-file checker of its own (its types are generated by
`haus-gen`, TypeScript's), so it sits out.

There are no known disagreements (`KNOWN` in
[`src/schema-check.ts`](src/schema-check.ts) is empty). The last five were
decided on 2026-11-19: guarded recursion is checked on every definition,
used or not; a spread cycle through nested spreads is `spread-cycle`; a `|`
after a variant's last alternative is a syntax error, as in the grammar;
`Stream`'s arity is checked before its place (`type Q = Stream` and
`{ e: Stream }` are `wrong-arity`); a package import is checked as the
bindings check it (`@Haus/money` is `unknown-module`). A module is one word,
as in the grammar (`import std/ time` and `import foo/bar` are syntax
errors), in every checker.

## When it finds something

Decide what the spec says, fix the parser (or the spec), and add the shrunk
input to [`../test-suite`](../test-suite) so it stays fixed.

## Coverage

[`src/coverage.ts`](src/coverage.ts) measures what the fuzzers exercise: it
makes one corpus per mode with the fuzzers' own generators (parse,
canonical, format, json, schema, schema-check; 3000 cases each by default,
seed 1), replays it through instrumented builds of the Rust, Go and
TypeScript runners, and lists per source file the lines, regions or
statements and functions the corpus never reaches. Not run in CI.

```sh
node fuzz/src/coverage.ts                          # about a minute; builds what it needs
node fuzz/src/coverage.ts --langs go --modes schema,json --count 10000
node fuzz/src/coverage.ts --no-generate --no-build # replay the corpus again
node fuzz/src/coverage.ts --report RUN --no-build  # only the reports again, from .out/coverage/raw/RUN
```

| Language | Instrumented with | Counts |
|---|---|---|
| Rust | `RUSTFLAGS=-C instrument-coverage` (the runners of `rust/haus` and [`schema-rust`](schema-rust), built into `.out/coverage/build`), `llvm-profdata` and `llvm-cov` of rustc's LLVM version (rustup's `llvm-tools`, or one on `PATH`; `LLVM_PROFDATA` and `LLVM_COV` override) | lines, regions (an arm, a `?`, an operand of `&&`: stable rustc has no branch counters) |
| Go | `go build -cover` of [`go/`](go) over the module's packages, `GOCOVERDIR`, `go tool covdata` and `go tool cover` | lines, statements (Go counts nothing finer) |
| TypeScript | Node's own block coverage (`NODE_V8_COVERAGE`) of the in-process runners, mapped from `typescript/packages/haus/dist` to `src` through the source maps; no dependency | lines, places never run (V8 folds a block that ran into its parent, so there is no total to divide by) |

The corpus goes to `.out/corpus/<mode>/`, in the runners' input formats
(with a `manifest.json`); the reports to `.out/coverage/<lang>/`
(`summary.md` per area and file, `uncovered.txt` with every function never
called and every place never reached, with its source line, and HTML) and
`.out/coverage/summary.md`. Raw profiles go to `.out/coverage/raw/<run>/`,
a directory per run that the script never deletes. The corpus follows the
fuzzers' generation loops, with two differences: the formatter batches are
250 cases (so a small corpus sees the other options), and the third of
`read` that the JSON fuzzer seeds from Lean's JSON is seeded from
TypeScript's (the fuzzer keeps them equal), so Lean needn't be built.
std/time and the profiles (`time.ts`, `profiles.ts`) and the Effect runners
are not measured.
