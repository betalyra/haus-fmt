# Differential testing

Generated inputs go through every haus parser: the Lean reference parser
(`spec/lean`), Rust, Roc and TypeScript (and, with `--schema`, through
every schema decoder: see [Schema decoding](#schema-decoding); with `--json`,
through every JSON converter: see [JSON](#json)). They must agree on every input:
accepted with the same values, or rejected. A disagreement is a bug in at
least one of them, or a gap in the spec.

```sh
sh fuzz/build.sh                       # build the parsers under test
node fuzz/src/main.ts --count 100000   # about a minute
node fuzz/src/main.ts --seed 7         # repeat a run
```

Needs Node 23.6 or later (it runs the TypeScript directly), Lean (elan),
Rust and Roc. CI ([`ci.yml`](../.github/workflows/ci.yml)) runs both
fuzzers on every pull request with a new seed, and much longer every night;
a failure prints the seed and keeps the shrunk inputs as an artifact.

## How it works

| Step | |
|---|---|
| Generate | [`src/generate.ts`](src/generate.ts): random haus text with varied formatting (spacing, comments, CRLF, byte order mark, number spellings, quoted keys, block strings, both payload forms, trailing commas), values at and just past the limits, the conformance suite as seeds. Half of the inputs are then mutated: bytes deleted, edge characters inserted (quotes, `*/`, control and bidi characters, invalid UTF-8), slices duplicated, cut short. |
| Run | [`src/runners.ts`](src/runners.ts): each parser reads a batch of files and prints one line per file, `ok <values>` in the test-suite JSON encoding or `err <line> <column> <reason>`. The stream readers of Rust, Roc, TypeScript and Python run too, on the same inputs cut into chunks (sizes 1, 2, 3, 5, 8, 13, 64 in turn), and must give what parsing the whole input gives. A runner that crashes is rerun case by case, and the crash counts as a disagreement. |
| Compare | [`src/main.ts`](src/main.ts): accept/reject and the values must agree. |
| Shrink | A disagreeing input is cut down to the smallest input that still disagrees, and saved to `.out/failures/` with every parser's result. |

Error positions are reported separately: the spec fixes their units (§8)
but not which error a parser reports first, so they may differ.

## The runners

| Parser | Runner |
|---|---|
| Lean | `haus-ref --batch DIR N` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)) |
| Rust | [`rust/haus/examples/fuzz_runner.rs`](../rust/haus/examples/fuzz_runner.rs) |
| Roc | [`roc/fuzz/runner.roc`](../roc/fuzz/runner.roc) |
| TypeScript | in this process ([`src/runners.ts`](src/runners.ts)) |
| Python | [`python/fuzz/runner.py`](../python/fuzz/runner.py) |
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
the rules) and the TypeScript, Rust, Roc and Python checkers, which must agree on
every one.

```sh
node fuzz/src/time.ts --count 2000000   # about half a minute
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
| Effect | in this process: `Haus.compileSchemaFile`, `decodeValue`, `encodeValue` |
| Rust | [`schema-rust`](schema-rust): the code haus-fmt-build generates for each schema |
| Roc | [`roc/schema_runner.roc`](roc/schema_runner.roc), with the modules `haus-gen roc` generates ([`roc/gen_schemas.ts`](roc/gen_schemas.ts)) |
| Python | [`python/fuzz/schema_runner.py`](../python/fuzz/schema_runner.py): `haus.schema.compile_schema`, `decode`, `encode` |

Nothing is masked: every binding's default host types keep the value (spec
§13.4), so every runner must agree with Lean exactly. Lossy host types (Effect's
`BigDecimal` and `DateTime`) are opt-in codecs that the runners don't use.

## JSON

The same idea for the JSON mappings (spec §16): generated inputs go through
the Lean reference converters and every binding's, in five directions, and
must agree on accepting or rejecting and on the result.

| Mode | Input | Does | Compared |
|---|---|---|---|
| `write` | haus text and a type | decode, write plain JSON (§16.3) | the JSON as data: member order doesn't matter, numbers compare by their text |
| `read` | JSON text and a type | read plain JSON, encode | the canonical form (§12) |
| `lossless-write` | haus text | the lossless form (§16.2) | the JSON as data |
| `lossless-read` | JSON text | read the lossless form | the canonical form |
| `schemaless` | JSON text | read JSON without a schema (§16.1) | the canonical form |

```sh
sh fuzz/build.sh                                   # also builds the JSON runners
node fuzz/src/main.ts --json --count 4000          # cases per mode; two or three minutes
node fuzz/src/main.ts --json --seed 7 --modes read,schemaless --runners lean,typescript,rust
```

The types are the schema fuzzer's, plus
[`test-suite/json/plain.schema.haus`](../test-suite/json/plain.schema.haus)
and [`json/names.schema.haus`](json/names.schema.haus) (a record payload with
a field named `_tag`, which has no plain form). A schema file a binding
rejects makes every case of it `err` for that binding.
[`src/json-gen.ts`](src/json-gen.ts) generates the JSON:

- `write` takes the schema fuzzer's values (above). `lossless-write` takes
  random haus values, values of the schema types, the conformance suite's
  valid files, and nesting at the depth limit (`[`, `{ a:`, `Some(`,
  `T { a:`).
- `read` takes plain JSON generated from the type, and the JSON Lean writes
  for generated values (a third of the cases), then near misses: the wrong
  kind of value; missing, extra and repeated members; `_tag` missing,
  renamed, repeated, not a string, not a tag; `value` and `values` swapped
  or of the wrong length; `null` for a `Maybe` that is tagged and the tagged
  form for one that uses `null`, `null` for an optional field; unknown tags
  bare, with `args` (empty, not an array) or with other members; base64
  without padding, with the URL alphabet, whitespace or pad bits; integer
  strings with `+`, leading zeros, exponents, separators, at the 64-bit and
  number limits; decimal strings that aren't JSON numbers; floats exactly at
  and halfway between floats, `"NaN"` and its misspellings; lone surrogates.
- `lossless-read` takes lossless forms of random values and mutations of
  them: bare numbers, `true`, `null`, `num`s that aren't normalized or are
  past the number limit (and integers whose hex form fits), uppercase or odd
  hex, tags that aren't tags, empty `args`, extra members, records of bare
  values; and nesting at the JSON limit (4·256 + 1).
- `schemaless` takes any JSON: numbers at the edges (`-0`, `1E+05`,
  exponent and length limits), strings with escapes, duplicate names, and
  nesting at the limit (256), as well as text that isn't JSON.

All of it is written with varied whitespace and escapes (`\u` for any
character, surrogate pairs, `\/`), sometimes with a byte order mark, and
some of it is edited as text (characters deleted, inserted, duplicated, cut
short) or isn't UTF-8. A disagreeing case is shrunk: JSON by removing
members, elements and characters, haus as for schema decoding.

| Converter | Runner (`MODE FILE`; lines `SUITE TYPE HEX` for `write` and `read`, `HEX` for the others) |
|---|---|
| Lean | `haus-ref --json-batch`, `--json-read-batch`, `--lossless-batch`, `--lossless-read-batch`, `--schemaless-read-batch` ([`spec/lean/Main.lean`](../spec/lean/Main.lean)) |
| TypeScript | in this process: `h.decode` and `h.toJson`, `h.fromJson` and `h.encode`, `toLosslessJson`, `fromLosslessJson`, `fromJson` |
| Effect | in this process: `decodeValue` and `Haus.toJson`, `Haus.fromJson` and `encodeValue`, `Haus.Any` for the lossless form, `Haus.valueFromJson` |
| Rust | [`schema-rust/src/json_runner.rs`](schema-rust/src/json_runner.rs): the `ToJson` and `FromJson` code haus-fmt-build generates, `haus::json::to_string` and `from_str`, `haus::to_lossless_json`, `from_lossless_json`, `from_json` |
| Roc | [`roc/json_runner.roc`](roc/json_runner.roc), with the modules `haus-gen roc --json` generates ([`roc/gen_json_schemas.ts`](roc/gen_json_schemas.ts)) and `JsonValue` |
| Python | [`python/fuzz/json_runner.py`](../python/fuzz/json_runner.py): `SchemaType.to_json` and `from_json`, `haus.to_lossless_json`, `from_lossless_json`, `from_json` |

The output of a run ends with the number of cases each mode accepted, and
`fuzz/.out/json/coverage.txt` has it per type for `write` and `read`.

## When it finds something

Decide what the spec says, fix the parser (or the spec), and add the shrunk
input to [`../test-suite`](../test-suite) so it stays fixed.
