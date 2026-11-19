# Plan: proving haus correct and secure

What we want to know for certain about the haus text format, and in which
order to prove it. Status: ✅ done · 🟡 started · ⬜ open.

## The shape of the argument

1. The **grammar** (`Haus/Grammar.lean`) is the specification.
2. Properties of the grammar are proven once, about every possible text.
3. The **reference parser** is proven to compute exactly the grammar.
   Then everything proven about the grammar holds for what it returns.
4. The **bindings** (TypeScript, Rust, Roc) are tested against the
   reference parser, on millions of generated inputs.

Proofs cover the format and the reference parser. The bindings' own
behaviour (tags never become classes, `__proto__` never reaches a
prototype, …) is outside Lean and stays covered by tests.

## Phases

| | Phase | What it gives us | Effort |
|---|---|---|---|
| ✅ | **0. Model** | Data model, equality, grammar, reference parser, `haus-ref` (139/139 conformance cases) | — |
| ✅ | **A. Security properties of the grammar** | Theorems about every valid file, independent of any parser (below) | days |
| ✅ | **G. Differential testing** | The bindings agree with `haus-ref` on generated and mutated inputs, in CI | ~1 week, can start any time |
| ✅ | **B. Soundness** | The parser only accepts what the grammar allows. A's properties then hold for its output. | 2–3 weeks |
| ✅ | **C. Completeness** | The parser accepts everything the grammar allows: `parse L t = .ok vs ↔ File L t vs` | 3–5 weeks |
| ✅ | **D. Unambiguity** | Every valid text has exactly one meaning. Follows from B + C, since the parser is a function. | days |
| ✅ | **E. Encoder round trip** | `parse_canonical`: for every value a parser returns, its canonical form parses back to that value (in canonical order), so no string, key or number can break out of its syntax. Holds for any limits: the canonical form writes every number as its normalized literal, always decimal (§12), and a hex literal has at most `maxHexDigits` hex digits (§7, the largest `h` with `16^h ≤ 10^(n−1)`: 829 for the default number limit 1000, `Limits.maxHexDigits_iff`), so every parsed number's canonical text fits the number limit it was parsed with (`normalized_lit`, `NumberLit.normalize_fits`, `Bounded.num_fits`). Hex and binary literals keep their sign on zero (`-0x0` normalizes to `-0`, design review B1: `signedText`, `signedLit`). In [`Haus/RoundTrip/`](Haus/RoundTrip). | 1–2 weeks |
| ✅ | **F. Streams** | A model of the bindings' stream readers: `read_chunks`, any split gives the same values and errors; `read_correct`, the reader returns `vs` exactly when `parse` accepts the whole text with `vs`. The value limit and strict mode (design review C4): `readWith_valid`, `readWith_correct`. In [`Haus/Stream/`](Haus/Stream). | 1–2 weeks |
| ✅ | **H. Canonical form** (spec §12) | `canonical_eq_iff`: two parsed values have the same canonical form exactly when they are equal (§2), so `hash` is well defined. `canonicalAll_eq_iff` does the same for `hashAll` of a file or stream, and `read_canonicalAll`/`canonicalAll_prefix` cover hashing while reading ([`Haus/RoundTrip/HashAll.lean`](Haus/RoundTrip/HashAll.lean)). Reference encoder in [`Haus/Canonical.lean`](Haus/Canonical.lean), implemented in TypeScript, Rust and Roc and fuzzed against it. Strings escape U+2028 and U+2029 as `\u{2028}`, `\u{2029}` (design review D1, `isLineSep`). | 1–2 weeks |
| ✅ | **P. Linear time** (spec §7) | A cost model (steps counted next to the result) and proofs that the stream scanner and a linear reference parser take at most `c · length` steps (below): `splitB_steps` (`3 · n + 3 · p + 6`), `parseC_eq` and `parseC_cost` (`256 · n + 68`), `readCost_le` (both, `259 · n + 3 · p + 75`); the design before S17 is quadratic (`splitOld_not_linear`). In [`Haus/Linear/`](Haus/Linear) and [`Haus/Stream/Cost.lean`](Haus/Stream/Cost.lean). | 1–2 weeks |
| 🟡 | **I. Schema decoding** (spec §14–15) | A reference decoder that passes the schema suite, then termination, the round trip and linear time, in steps I1–I7 (below). I1–I6 done, in [`Haus/Schema/`](Haus/Schema) and [`Haus/SchemaFile/`](Haus/SchemaFile) (schema files read, checked and instantiated in Lean, design review C1); I7's bound proven for the decoder's own steps (`decode_linear`), with the float and std/time leaves assumed linear; the fuzzing part of I3 open. | I1–I3: ~2 weeks; all: months |
| 🟡 | **V. Versions** (spec §10) | `Extends old new`: a new version is a conservative extension of the old one (same values for every old text; canonical form, hash, built-in types, schema decoding and the three JSON mappings agree on what the old version can express; the JSON readers read what they read; default limits only grow; codes stay in the catalogue, and a text with one mistake keeps its code; design review C5). Defined, with `refl`, `trans` and `current_extends_self`, in [`Haus/Version.lean`](Haus/Version.lean); to be proven for each release. | days per release |
| ✅ | **T. std/time** | A reference model of the profile (spec §13.2, `std/time.md`), the bindings' time checkers fuzzed against it, and its security and calendar properties proven | 1–3 weeks |
| ✅ | **J. JSON** (spec §16) | A reference for the JSON mappings (the import, self-describing and schema-based JSON) that passes the JSON suite, with the round trips and uniqueness proven, in steps J1–J11 (below). All done, in [`Haus/Json/`](Haus/Json), with the bindings fuzzed against it in CI (J7); `nullFuel` is enough for every chain of `Maybe`s (J9, J11, [`Json/NullFuel.lean`](Haus/Json/NullFuel.lean)). | J1–J6: ~1 week |
| 🟡 | **X. Extensions and codecs** (spec §13.3, §13.4) | The codec contract proven once for any codec; a reference checker for each official profile (`@haus-fmt/money/iso`, `@haus-fmt/geo/wgs84`) that the bindings' codecs are fuzzed against, in steps X1–X4 (below). X1 and X2 done, in [`Haus/Schema/Codec.lean`](Haus/Schema/Codec.lean) and [`Haus/Profiles/`](Haus/Profiles); X3 waits for the bindings' codecs. | X1–X3: ~1 week |
| ✅ | **R. Package resolution** (spec §13.3, §9.2) | A file-system model with links, an executable resolver that is the reference for `test-suite/packages`, and the security properties of the 2026-11-17 review proven on it, in steps R1–R7 (below). All done, in [`Haus/Packages/`](Haus/Packages). | ~1–1.5 weeks |
| 🟡 | **L. Layouts** (spec §11) | The standard format: the formatters fuzzed for keeping the values, idempotence and identical bytes; the block-string rules written down; a reference compact writer proven to parse back, for every binding's serializer to be fuzzed against, in steps L1–L5 (below). L1 done (`node fuzz/src/main.ts --format`, in CI); L2 done in the spec (§4, §10, §11); L4 done, in [`Haus/Pretty/`](Haus/Pretty); L3 and L5 proven, in [`Haus/Layout/`](Haus/Layout), with `haus-ref --compact`, `--minimised` and `--pretty` for the bindings' serializers to be fuzzed against (not wired yet). | L1–L2: days; L3–L4: 1–2 weeks |

Order: A–H, P, T1–T6, I1–I6, J1–J11, X1, X2 and the definition of V are done. Next:
fuzzing the bindings' decoders against the Lean one (the rest of I3), and
the bindings' schema-file checkers against `SchemaFile.load` (C1); then the
JSON suite's and the packages' schema files read by it too. I7's bound is proven
(`decode_linear`) on P's cost model, the float and std/time leaves assumed linear. X3 comes before the extensions are
released, once the bindings have codecs; a new package's profile is written in Lean before its codecs. L1 and L2 come before 1.0 (L2 together with the audit's B2); L3–L5 after, L3 first, as it also gives Python and Roc a reference. L4 was pulled forward to prove the B2 decision (no line of a pretty block string ends in a blank). L3 and L5 are proven; what is left of them is fuzzing the bindings' serializers against the three `haus-ref` layout modes.

## A. Security properties of the grammar

Each is a theorem of the form `File L t vs → …`.

| Theorem | Security issue | Spec |
|---|---|---|
| ✅ A1. No raw bidi control character anywhere in a valid file (`File.noBidi`, `Haus/Props/Chars.lean`) | "Trojan Source": text that displays differently from what it is | §4, review S7 |
| ✅ A2. The only control characters in a valid file are tab, LF and CR (`File.controls`). Found by the proof attempt: comments allowed ESC and NUL, strings allowed DEL and C1; now forbidden everywhere (spec §4). And every CR is directly followed by LF (`File.crlf`, `Haus/Props/LineBreaks.lean`). | Terminal escape injection, truncation at NUL | §4 |
| ✅ A3. Every record, at any depth, has unique keys (`File.uniqueKeys`, `Haus/Props/Values.lean`) | Parsers that pick different duplicates | review §1.1 |
| ✅ A4. Every value is within the limits: nesting depth, number length, exponent, string and byte string length, and the length of record keys and tags, which count like strings (`File.bounded`) | Resource exhaustion | §7, review S4, S5 |
| ✅ A5. Every string is valid Unicode with no lone surrogates (`char_isScalar`) | Encoding confusion | §4 (holds by construction: Lean's `Char`) |

Two properties already hold by construction and need no proof:
- The parser can't do I/O, follow references or fetch anything: its type is
  `Text → Except Error (List Value)` (§9.2).
- It always terminates: Lean accepts only total functions.

## B. Soundness ✅

`parse_sound`: whatever the reference parser accepts is a `File` of the
grammar, with the values it returned. So A1–A4 hold for its output
(`Haus/Secure.lean`). About 1,400 lines in `Haus/Sound/`, no `sorry`, standard
axioms only.

| Part | File |
|---|---|
| Numbers, escapes, basic strings | `Sound/Lexical.lean` |
| Whitespace, line and nested block comments | `Sound/Whitespace.lean` |
| Byte strings | `Sound/Bytes.lean` |
| Block strings | `Sound/BlockString.lean` |
| Keys, values, records, arrays, payloads, files | `Sound/Values.lean` |

Mismatches found while proving: none between parser and grammar. Two grammar
rules were restated in an equivalent, simpler form (block string text joined
with `List.intercalate`; the closing `"""` stated over content and indent).

## C. Completeness ✅ and D. Unambiguity ✅

`parse_complete`: when the grammar derives `File L t vs`, then
`parse L t = .ok vs`. With B, `parse_correct` gives both directions, and
`File.unique` (D) follows: the parser is a function, so two derivations of
the same text give the same values. In [`Haus/Complete/`](Haus/Complete):

| Part | How |
|---|---|
| Follow conditions | The parser reads greedily, so each lemma says what may follow: a number or tag nothing in `[A-Za-z0-9_.]`, a bare tag not blanks then `(` or `{`, whitespace not whitespace or `/`. The grammar only puts a value before whitespace, `,`, a closing bracket or the end, which satisfies all of them. |
| Lexical | The reverse of each soundness lemma: `lexNumber` reads exactly the literal, `chars` exactly the string, `blockComment` exactly a nested comment, `ws` exactly `WS`, `findClose` finds the closing `"""` (the content before it never ends with `\` or `"`), `splitLines` gives back the lines. |
| Values and files | Induction over the grammar's derivation (mutual, like the grammar). A value needs fuel above twice its length, so the parser's `4 * (length + 1)` is always enough; no fuel monotonicity needed. |

Nothing in the parser or the grammar had to change: no valid input is
rejected.

## F. Streams ✅

The readers of all three bindings work the same way, and
[`Haus/Stream.lean`](Haus/Stream.lean) models it: a scanner finds the commas
between top-level values, tracking only bracket depth, strings, block strings
and comments, and each piece before such a comma is parsed on its own. The
scanner looks up to three characters ahead (`"""`, `//`, `*/`, `\"`) and
waits when a chunk ends before it can decide.

| Part | File |
|---|---|
| A decision the scanner makes on part of the input is the same on any continuation (`step_stable`); so scanning in parts is scanning the whole (`scan_append`), and any chunks give the same pieces (`split_chunks`, `read_chunks`) | `Stream/Chunks.lean` |
| On valid text the scanner passes over every value, string, comment and bracketed part without cutting, and cuts exactly at the commas between top-level values | `Stream/Scan.lean` |
| Valid text is read correctly; what the reader accepts is valid, since a piece that ends in a line comment or has a comma of its own can't occur (the scanner would not have cut there) | `Stream/Correct.lean` |

Pieces after the first may not start with a byte order mark: the model
rejects one, as the bindings do since S14. Without that rule `read_correct`
would be false.

**The value limit and strict mode** (design review C4, spec §6, §7), in
[`Stream/Limited.lean`](Haus/Stream/Limited.lean): `readWith o L chunks`,
with `Options` `maxValueLength` (default 64 Mi) and `strict`. A value's
characters are counted as §7 says, from the previous top-level comma (or
the start, after a byte order mark) to the next one, the text after the last
comma included (`valueLengths`); each value is checked before it is parsed,
so the first error in the stream wins. Strict mode reports
`stream-truncated` when a value follows the last top-level comma, after
that value parsed; a stream without values is not truncated. Decided
2026-11-18: the limit applies to stream readers only, and `parse` doesn't
apply it (a `#guard` shows a text `parse` accepts that a stream reader with
a small limit rejects).

| Theorem | Says |
|---|---|
| `readWith_chunks` | Any split gives the same values and error |
| `readWith_cases` | Any text: what `read` gives, or a stop with `value-too-long` or (strict) `stream-truncated` after some of `read`'s values |
| `readWith_valid` | A text `parse` accepts: `value-too-long` exactly when some value's characters exceed the limit (`Fits`); else `stream-truncated` exactly when strict and a value follows the last top-level comma (`¬Terminated`); else no error. The values returned are the first values of the whole text, all of them without an error |
| `readWith_correct` | `(vs, none)` exactly when `parse` accepts the whole text with `vs`, every value fits, and (strict) the stream is terminated |
| `readWith_eq_read` | Within the limit and not strict, `read` |

Found while writing it: the TypeScript reader checks the length before
scanning each further character, so a value is caught only when a
character follows it. At the end of the stream, a last value without a comma
that is exactly one character over the limit is accepted (`end()` parses it
without a check); the model, following §7, rejects it. Not a change to the
spec; worth a case for the bindings' stream tests (outside this directory).

## G. Differential testing

In [`fuzz/`](../../fuzz): runners for all four parsers and for the three
stream readers (inputs split into chunks), a generator with mutations,
comparison and shrinking. 100,000 cases through all seven run in about 80
seconds.

Found so far: a crash in the Rust stream reader on input ending in `/`, and
stream readers accepting a byte order mark after a comma (design review S13,
S14). Both fixed; two seeds of 100,000 cases now run clean.

CI ([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)) runs every
binding's tests, `lake build --wfail` (a broken proof or a `sorry` fails it)
and the conformance suite, and fuzzes 100,000 parser cases and 2 million
std/time cases per pull request; 1 million and 20 million nightly.

Open:
Decided: §8 fixes the units of an error position, not which error a parser
reports first, nor any message. Fixing it would rule out parsers that
validate in separate passes (UTF-8 and control characters first, as fast
parsers do) and need exceptions anyway (unterminated strings are reported
at their opening quote). The fuzzer counts position differences for
information only.

## P. Linear time ✅

Spec §7 requires parsing to take time linear in the input. Lean proofs say
nothing about time by themselves (`List.drop` costs nothing in a proof), so
this needs an explicit cost model: each function returns the number of
steps it took next to its result, and the operations whose cost matters
are given their real cost (removing the front of a buffer costs one step
per byte moved).

The model ([`Linear/Monad.lean`](Haus/Linear/Monad.lean)): the input is an
array, so the rest of the input is a position, and reading it, setting it,
skipping a character and an error's position take one step; a function on
lists takes one step per element it visits, plus one; arithmetic on
natural numbers one step per operation; an error message (built at most
once per parse) one step.

| | Step | Gives |
|---|---|---|
| ✅ | P1. Cost model | For the stream model of F: `Buf` ([`Stream/Cost.lean`](Haus/Stream/Cost.lean)), a reader with one buffer as the bindings keep it (offsets `start` and `pos`, appending a chunk, the scanner's steps, dropping the front of the buffer at one step per byte moved), with its step count as a field; `splitB_view`: it finds exactly the pieces of `split`, so `read_correct` holds for it. For the parser: `PC` ([`Linear/Monad.lean`](Haus/Linear/Monad.lean)), the parser monad `P` with a step count next to the result, also on failure (`res`, `cost`; steps are only added, never read); `Agrees`; a Hoare-style calculus over it, `Spec` ([`Linear/Spec.lean`](Haus/Linear/Spec.lean): `spec_bind`, `spec_tick_bind`, `spec_liftP`, …). |
| ✅ | P2. Stream scanner | `splitB_steps`: reading `n` characters in `p` chunks, split anywhere, takes at most `3 · n + 3 · p + 6` steps. Amortized with a ghost field (`Buf.mark`, where the scan stood at the last drop): every character is appended once, scanned once and moved at most once, as a moved character sits before the next comma and the next drop removes it (`Buf.Inv`); the lookahead the scanner waits on (at most two characters, `step_wait_lt`) is paid per chunk. The design before S17 (`Buf.pushOld`: each value's bytes dropped as soon as its comma is found) finds the same pieces (`splitOld_view`) but fails the bound: `splitOld_steps_vals`, `k` values `0,` in one chunk (`2 · k` characters) take at least `k · (k + 1)` steps; `splitOld_not_linear`, no `c · (n + p + 1)` bounds it. |
| ✅ | P3. Parser | `parseC` ([`Linear/Parser.lean`](Haus/Linear/Parser.lean)) is the reference parser with its steps counted and one change: a record's keys are also kept in a `KeySet`, a binary trie over the 21 bits of each code point ([`Linear/KeySet.lean`](Haus/Linear/KeySet.lean)): a key of `n` characters is a path of `21 · n` bits, the same length for all keys of `n` characters, so different keys are different paths (`keyBits_inj`); looking a key up or adding it visits `21 · n + 1` nodes whatever the set holds (`KeySet.memC_cost`, `KeySet.insertC_cost`), so the duplicate check is linear in the keys' characters, deterministic, with no hashing and no `log n`. `parseC_eq`: it returns exactly what `parse` returns, values, errors and positions ([`Linear/Agree.lean`](Haus/Linear/Agree.lean): `mem_keySet`, the trie answers as the scan does). `parseC_cost`: at most `256 · n + 68` steps on any input of `n` characters ([`Linear/Bound.lean`](Haus/Linear/Bound.lean)). Leaves (whitespace, numbers, strings, block strings, byte strings, keys) run the reference function and count its steps by a function following its recursion; each takes at most 50 steps per character read, or per character left on failure ([`Linear/Leaves.lean`](Haus/Linear/Leaves.lean): `wsC_spec`, `numberC_spec`, `basicStringC_spec`, `blockStringC_spec`, `bytesC_spec`, `keyC_spec`; a hex literal's decimal form has at most two digits per hex digit, `normalizeNumber_length`). Values, records, arrays, payloads and files are written out with steps; their bound is amortized over the characters read, by induction on the fuel (`BoundAt`): a value takes at most 128 steps per character it read, plus the blanks after a tag that it looked at for a payload and left for the next `ws` (`blanks`, the one place a character is read twice), and a record or array one more step per element for reversing them; a failure at most 256 per character left, and 64. The sorted alternative of D2 (`keysDup`, [`DupKeys.lean`](Haus/DupKeys.lean), `n · (log₂ n + 2)` comparisons) stays as a lemma; the trie made it unnecessary. `readCost_le` ([`Linear/Stream.lean`](Haus/Linear/Stream.lean)): P2 and P3 together, the stream reader scanning and parsing every piece, at most `259 · n + 3 · p + 75` steps (`scan_length`: the pieces and their commas don't overlap). |

What this can't cover: the bindings' own code (S17 was in Rust's buffer
handling, not in the design) and constant factors. Those are covered by the
benchmarks ([`plans/benchmarks.md`](../../plans/benchmarks.md)), including a
doubling test in CI: twice the input must take about twice the time. The
bindings' seeded hash tables are outside the model (their bound is
probabilistic); they are covered by tests with many and with colliding
keys. Arithmetic counts one step per operation: a hex literal's conversion
to decimal is quadratic in its digits at the bit level, at most
`maxNumberLength` (§7) of them. Growing a buffer is counted as one step per
byte appended (amortized). Not counted: what `readWith` adds to the reader
(the value limit and strict mode, one length per value).

## I. Schema decoding

Spec §15 defines what each type accepts, and `test-suite/schema` tests it.
The goal is the same as for parsing: an executable reference in Lean that
the bindings are fuzzed against, then proofs about it. Each step after I3
stands on its own.

| | Step | Gives | Effort |
|---|---|---|---|
| ✅ | I1. Schema types | `Ty` ([`Schema/Types.lean`](Haus/Schema/Types.lean)): built-in types, `Any`, `Secret`, std/time types, `Array`, `Map`, records (open or closed, `?` fields), variants (open or closed, every payload form, `< >`), `Bool`/`Maybe`/`Result` as the prelude's closed variants, named references into an environment, generics applied. Attributes are not part of a type: a `Schema` keeps them in a table of their own, so `Schema.decode_erase` (decoding is the same without them) is `rfl`. | days |
| ✅ | I2. Reference decoder and encoder | `decode`/`encode` following §15 ([`Schema/Decode.lean`](Haus/Schema/Decode.lean)), unknown values, `Any` and secrets included; errors with their place. Recursion on the value, so it terminates for every environment: a reference that comes up again at the same level is an error (§9.9). Floats exact, with integer arithmetic ([`Schema/Float.lean`](Haus/Schema/Float.lean)): rounding to binary64/binary32 ties to even, directly from the decimal; the shortest spelling with ties to the even digit, JavaScript's layout. `decode_iff`: the decoder computes the rules of §15, written as an inductive relation ([`Schema/Rules.lean`](Haus/Schema/Rules.lean)). `secret_error`: an error inside a `Secret` doesn't depend on the value. | ~1 week |
| 🟡 | I3. Conformance | `haus-ref --schema-suite`: all cases of `test-suite/schema` pass, none skipped, with the code and the place (`path`, §15 "General rules": a variant's argument is `[i]`, a record case's fields are steps from the case, an error in a `Secret` is at the secret; `decodeStream_error`: in a stream, the item's index comes first), with each `NAME.schema.haus` read by the Lean schema-file reader (`SchemaFile.load`, C1 below), and every `invalid/NAME.schema.haus` is rejected with the code in `invalid/NAME.error`. The cases run a second time with the types the TypeScript binding's schema-file parser resolved ([`scripts/schema-types.ts`](scripts/schema-types.ts) → [`schema-suite.json`](schema-suite.json), which also checks that removing the attributes changes no type), so the two resolutions are compared on every case. Floats also matched JavaScript's `Number`/`toString` on 20,000 random literals. Open: fuzzing the bindings' decoders against the Lean one. `haus-ref --schema-batch TYPES FILE` is the Lean side; missing are a generator of values for a type and a runner per binding in `fuzz/`. | days |
| ✅ | C1. Schema files (design review C1) | A model of schema files before resolution, in [`Haus/SchemaFile/`](Haus/SchemaFile): types as terms (`Tm`: parameters, names applied to arguments, records and variants whose shape is a `Label`, a spread `...Name` the kid `ref Name []`), definitions with parameters, imports reduced to the std/time types in scope (`Source`; a package's definitions would be more definitions, finding them is phase R). `parse` reads the text with the data parser's comments, whitespace, quoted keys and attribute values, and the grammar's errors (`attribute-space`, `attribute-arguments`, `attribute-twice`, `attribute-on-spread`, `row-parameter`, `closed-empty-variant`, `invalid-parameter`, `underscore-type`, `type-too-deep`; a module is one word, as in the grammar). `declare` and `check`, the static rules of §14: `unknown-type`, `wrong-arity`, `unknown-parameter`, `duplicate-type`, `redefine-prelude`, `misplaced-stream` (after `Stream`'s arity), `invalid-spread`, `spread-cycle` (at any depth: `checkSpreadCycles`, the definitions a definition's spreads and the names they stand for need built first, a graph searched with `iterReach`, no fuel to run out; 2026-11-19), `duplicate-field`, `duplicate-tag`, and §9.10 (`growing-recursion`: the expansive-cycle rule, no expanding edge of the parameter graph `Source.paramEdges` on a cycle, `checkGrowth`; 2026-11-19, replacing the stricter rule for groups). `Source.instances` computes the instances, `translate` turns each into the `Ty` of an `Env` (spreads copied in, `Tag T` with `T` a name kept as `Case.named`), and guarded recursion (§9.9, `unguarded-recursion`) is checked on them with the decoder's own `whnf` (`guarded`), as the bindings do (`type I a = a` with `type X = I X` is unguarded only as an instance), and on every definition, used or not (`Source.templates`: a generic one with `Any` for its parameters; 2026-11-19, so `type Q a = Q a` is rejected when nothing uses it, as §14 says). `load` is the whole way, text to `Env`; `haus-ref --schema-suite` uses it (I3). The doubling example is rejected (`doubling_rejected`, by `decide`; `#guard` on the text). Package and file imports are checked as the bindings check them (`checkModule`: `import-version`, `unknown-module` with `Packages.isPackageName`, so `@Haus/money` is `unknown-module`), then `import-unavailable`. Not modelled: resolving them (finding the package is phase R's `resolveIn`; bringing the definitions of the files it finds into `load`, each file's names its own, is not done), error positions (codes and messages only), the attributes table (checked, then dropped), which error comes first in a file with several (the spec doesn't fix it). The parser has no grammar of its own to be proven against. | done |
| ✅ | I4. Termination | Decoding terminates for every schema `load` accepts, and never fails because of the schema. `decode` recurses on the value (so it terminates for any environment); the one step that doesn't consume input is `whnf`, following names and secrets. For an `Env` that `load` returns: `load_closed`, every name its types mention is defined (`EnvClosed`) and `guarded` holds; `whnf_ok`, so `whnf` succeeds on every closed type within `env.fuel` steps; `decode_noFault`/`load_decode`, decoding any value with any closed type (a name of the environment for one) never fails with `unknown-type` or `unguarded-recursion` (`SchemaFault`), by induction over the decoder (`decode.mutual_induct`), through `Case.resolve` (`caseOf?_closed`, `recordOf?_closed`). In [`SchemaFile/Decoding.lean`](Haus/SchemaFile/Decoding.lean). Not proven: that `translate` never makes a name that isn't defined; `closedEnv` checks it in `load` instead (it never fires on the suites). | done |
| ✅ | I5. Round trip | `decode_encode`: decode, encode, decode is decode. `encode_agree`: encode after decode is the input except where §15 says (`Agree`: fields an open record ignores, a float spelled another way that rounds to the same float, `-0` as an integer written `0`). Both unconditional: `floatLaw` proves that the spelling of a decoded float rounds back to it, for binary64 and binary32 ([`Schema/FloatLaw.lean`](Haus/Schema/FloatLaw.lean)): rounding depends only on the value of `a / b` (`roundMag_cross`), it is the identity on floats (`roundMag_self`), so the search for the shortest spelling succeeds within its 1100 tries (`shortest_float`), and the layout reads back as its digits and exponent (`decBody_layout`). In [`Schema/RoundTrip.lean`](Haus/Schema/RoundTrip.lean). | 1–2 weeks |
| ✅ | I6. Schema checker | The static rules of §14 imply what decoding needs: finitely many instances, and §9.10's rule is exact. `Reach F ts`: the instances reachable from types `ts` (a definition's body, its parameters replaced, mentions more: `Source.succs`). §9.10 is the expansive-cycle rule (2026-11-19): the parameter graph `Source.paramEdges` (an edge from `(A, a)` to `(B, q)` for each `a` in the argument `B`'s parameter `q` gets in `A`'s body, expanding when the argument is more than `a`); `GrowthOk`: no expanding edge on a cycle; `checkGrowth_iff`: the checker (`Source.expansive?`, rounds of `iterReach`) decides exactly that (`iterReach_complete`, `iterReach_sound`). `Source.reach_finite`: with `GrowthOk`, the reachable instances are among `Source.universe F ts`, at most `Source.instBound F ts` of them, an explicit number from the file and `ts` alone; `check_finite`, for every file `check` accepts. The proof gives each parameter a height (`Source.height`: how many expanding edges lead to it); an edge never goes down (`height_edge`), an expanding one goes up (`height_edge_lt`, which is where §9.10 is used), so the argument for a parameter of height `k` is in `argSet k`, built from the parts of `ts`, the parameters and the written arguments, and at `k + 1` the written arguments substituted with lists of height `k` (`good_succ`, `reach_inv`). The converse, in [`SchemaFile/Cycles.lean`](Haus/SchemaFile/Cycles.lean): for a file `declare` and `checkParams` accept (`Source.WellFormed`: names found, no parameter twice, bodies use their own parameters), an expanding edge on a cycle makes `A Int … Int` reach instances with ever bigger arguments (`edge_step`, `path_step`), so infinitely many (`infinite_of_expansive`); hence `growthOk_iff_finite` and `checkGrowth_iff_finite`: §9.10 holds, and the checker passes, exactly when every type reaches finitely many instances. `Source.instances_reach`: what the reference computes (`Source.instances`, rounds of `grow`) is exactly `Reach`; `instances_some`: it returns for every checked file whose `instBound` is within the bindings' limit `maxInstances` (10,000); `load_instances` ties it to `load`. `doubling_infinite`: without §9.10, the example (`type A a = < X (B (P a a)) \| Done >`, `type B a = < Y (A (P a a)) \| Stop >`) passes every other check (`doubling_checks_without_growth`) and reaches infinitely many instances; `doubling_rejected`: `check` rejects it. In [`SchemaFile/Groups.lean`](Haus/SchemaFile/Groups.lean), [`Finite.lean`](Haus/SchemaFile/Finite.lean), [`Cycles.lean`](Haus/SchemaFile/Cycles.lean), [`Closure.lean`](Haus/SchemaFile/Closure.lean). Limits: `instBound` is far from tight (a tower in the number of expanding edges), so `instances_some` says nothing for big files; the executable stops at `maxInstances` as the bindings do; `WellFormed` is proven from `declare` and `checkParams` (2026-11-19, [`SchemaFile/WellFormed.lean`](Haus/SchemaFile/WellFormed.lean): `wellFormed_of_declare`, `check_wellFormed`, `load_wellFormed`), so `declare_checkGrowth_iff_finite` holds with no assumption. | done |
| 🟡 | I7. Linear time | Decoding takes at most `K · size` steps (§9.8), `K` a number of the schema alone. In [`Linear/Decode.lean`](Haus/Linear/Decode.lean), with P1's cost model: `decodeSteps` counts the steps of `decode` by functions following its recursion (as P3 counts the parser's leaves), an upper bound (where `decode` stops at the first error the count goes on): following a name is a lookup, one step per definition (`whnfSteps`, at most `env.fuel` of them, `whnfSteps_le`); a `Secret` one step (`peelSteps`; the secrets `whnf` returns are at most its steps, `whnf_size`); finding a field or a case compares the input's key or tag with each the type lists, one step per character and one (`keysSteps`, `caseSteps`; a record type compares every key twice, `missing?` and `fieldOf?`); `recordOf?` a lookup per name (`recordOfSteps_le`); a list one step per element; an integer literal one per character. `inputSize`: the parts of a value and the characters of its numbers, strings, byte strings, tags and keys. **`decode_linear`**: `decodeSteps lc env t v ≤ costK env (maxTySize env t) k * inputSize v` for every environment, type and value, `costK env M k = 3 · (env.fuel + 1) · (M + #defs + 1) + 2 · M + k + 8`, `M` the size of the largest type (`maxTySize`); `decodeStream_linear` for a stream's items. The proof: every type met is at most `M` (`whnf_size`, `recordOf_size`, `caseOf_size`, `field_size`), so a record or variant type has at most `M` fields or cases (`length_le_sizeOf`), and each part of the input pays for what is done at it (`decodeSteps_le`, by induction on the input's size; `fieldsSteps_le`, `argsSteps_le`, `itemsSteps_le`, `entriesSteps_le` for its lists). Open: the leaves counted by what they are given (`LeafCost`, assumed linear in the literal, `LeafCost.Linear`): rounding a float (`roundLit`, whose `fraction` takes `2^e` for the literal's exponent `e`, so it is linear only with the exponent bounded, as the bindings bound it) and `Time.check`; `inputSize` against the text's length (a parser fact, P3's). | weeks |


## T. std/time

The profile in [`std/time.md`](../std/time.md) is small and every rule is
decidable, so it can be modelled completely. What depends on the tz database
(does a zone exist, does an offset match its zone) is outside the profile by
design, and so outside the model.

| | Step | Gives | Effort |
|---|---|---|---|
| ✅ | T1. Reference model | Each type's rules as a definition, and a checker proven to compute them (`check_iff`); `haus-ref --time` | days |
| ✅ | T2. Fuzzing | The TypeScript, Rust and Roc std/time checkers against the model ([`fuzz/src/time.ts`](../../fuzz/src/time.ts)): 2 million cases, no disagreements. It finds the Roc bound bug when run against the old code. | 1–2 days |
| ✅ | T3. Zone names can't traverse paths | `ZoneName.lookup_eq`: looked up as a file under `base`, a valid zone name resolves to exactly `base/…` (modelled like `os.path.join`: `.`, `..`, absolute names); `ZoneName.chars`: no `\`, `:` or NUL | ~1 day |
| ✅ | T4. Durations can't overflow | `Duration.fits`: years, months and weeks below 2³²; days and time below 2⁵³ seconds (exact as a JavaScript number, and a signed 64-bit count of seconds); `Fraction.nanos_lt`: a fraction below 10⁹ nanoseconds. Mostly by construction: the bounds are in the rules, and `check_iff` makes the checker enforce them. | ~1 day |
| ✅ | T5. The calendar is right | `date_iff`: a string is a valid `Date` exactly when it is the text of one of the days 0000-01-01 … 9999-12-31, one string per day. The days are counted with the standard day-count formula (365 days a year, leap rules by 4, 100, 400, month lengths from `(153·M + 2)/5`), which doesn't use `daysIn`; `next_dayNumber` shows that the day after every valid date gets the next number, so `daysIn` can't allow a day too many or too few anywhere. In [`Haus/Time/Calendar.lean`](Haus/Time/Calendar.lean). | ~1 week |
| ✅ | T6. One spelling per value | For every type, two valid strings have the same value exactly when they differ at most in trailing zeros of the fraction (`time_same_iff`, `dateTime_same_iff`, `duration_same_iff`; for `Instant` and `ZonedDateTime` with the same offset: `instant_same_iff`, `zoned_same_iff`); `Date` and `YearMonth` have exactly one spelling (`date_same_iff`, `yearMonth_same_iff`). `duration_text`: formatting a duration's value gives back its text. Writing the proof found three more spellings, now rejected (`P01D`, `-P0D`, zero components such as `P1DT0S`). In [`Haus/Time/Spelling.lean`](Haus/Time/Spelling.lean). | ~1 week |
| ✅ | T7. Offset zero (design review B3) | In [`Time/Spelling.lean`](Haus/Time/Spelling.lean): `offset_same_iff`: two valid offsets have the same value exactly when they are the same string or are `Z` and `+00:00`; `offset_zero_iff`: the offsets of value zero are exactly `Z` and `+00:00`; `instant_offset_zero`: `dt ++ "Z"` and `dt ++ "+00:00"` are the same instant with the same offset; `instant_value_same_iff`: two valid `Instant`s are the same value (instant and offset) exactly when they differ at most in trailing zeros of the fraction and in `Z` against `+00:00`. `-00:00` is rejected: `not_offset_minusZero`, `not_instant_minusZero` (no `Instant` ends in it), `check_instant_minusZero` (so the checker rejects it, by `check_iff`). | hours |


## J. JSON

Spec §16 maps haus to JSON two ways: **self-describing** (every value, no
schema, in an envelope `{"_haus": 1, "_value": …}`) and **schema-based** (a
schema type's values, as JSON consumers expect them), and imports any JSON
as a haus value (§16.1). `test-suite/json` tests them. The
model works on JSON as data (`JSON`: numbers keep their text, objects their
member order); a strict text reader and a compact writer sit next to it.

| | Step | Gives | Effort |
|---|---|---|---|
| ✅ | J1. JSON as data and as text | `JSON`, compared as data (`JSON.Equiv`: member order ignored, numbers by text) ([`Json/Data.lean`](Haus/Json/Data.lean)). `JSON.parse`: RFC 8259 restricted to I-JSON (no duplicate member names, no unpaired surrogates), a leading byte order mark ignored, the limits of §16 (number tokens as written, strings, nesting 4·d + 1); `JSON.parseLines` for JSON Lines; `JSON.write`, compact, escaping every control character, bidi control and U+2028, U+2029 (`mustEscape`; the strict reader rejects only the first two raw, `strictRejects`, design review D1) ([`Json/Text.lean`](Haus/Json/Text.lean)). Proven in [`Json/TextRoundTrip.lean`](Haus/Json/TextRoundTrip.lean): `parse_write`, the text of every well-formed JSON within the limits (`WellFormed`: number tokens, no duplicate member names; `Fits`: strings, member names, number tokens, nesting) reads back as exactly that JSON; `parse_sound`, everything `parse` returns is such a JSON, so `parse_write_iff`; `parseLines_writeLines`/`parseLines_sound`, the same for JSON Lines (`writeLines`: each value and a line feed), since the writer writes nothing below U+0020 (`write_chars`); nor DEL, C1, a bidi control or U+2028, U+2029 (`write_clean`). | days |
| ✅ | J2. Byte strings | Base64 with padding, strict (canonical only), and lowercase hex: each reader accepts exactly the writer's texts and reads them back (`base64_decode_encode`, `base64_encode_decode`, `hex_decode_encode`, `hex_encode_decode`, [`Json/Base64.lean`](Haus/Json/Base64.lean)). | ~1 day |
| ✅ | J3. The import and self-describing JSON (§16.1, §16.2) | `JSON.toValue` (the import), `selfDescribing`/`fromSelfDescribing` (a value without the envelope, as in `Any`), `hausJson`/`fromHausJson` (with it) ([`Json/SelfDescribing.lean`](Haus/Json/SelfDescribing.lean)). `hausJson_read_write`/`fromHausJson_hausJson`: reading the self-describing JSON gives the value back; `hausJson_unique`: every accepted JSON is, as data, the self-describing JSON of what it reads; `hausJson_equiv_iff`: two values have the same self-describing JSON, as data, exactly when they are equal (§2), for every value; the same without the envelope (`selfDescribing_…`). | days |
| ✅ | J4. Schema-based (§16.3) | `toJson`/`fromJson` over the schema model, row by row ([`Json/SchemaBased.lean`](Haus/Json/SchemaBased.lean)). `schemaBased_round_trip`: reading the schema-based JSON of a decoded value gives it back; `schemaBased_injective`: two decoded values with the same schema-based JSON are the same; `toJson_error`: writing a decoded value fails only for a record payload with a field named `_tag` or `_args` ([`Json/SchemaBasedRoundTrip.lean`](Haus/Json/SchemaBasedRoundTrip.lean)). Floats rest on `floatLaw`; `normalizeNumber_normal` ([`Json/Normal.lean`](Haus/Json/Normal.lean)) shows a `Decimal`'s literal reads back unchanged. | ~1 week |
| ✅ | J5. Parsed values | The round trips assume a well-formed value (normalized numbers, tags); `parse_wf`: every value the reference parser returns is one ([`Json/WellFormed.lean`](Haus/Json/WellFormed.lean)), so `hausJson_parsed` and `schemaBased_parsed` hold for every value of every haus text ([`Json/Correct.lean`](Haus/Json/Correct.lean)). | days |
| ✅ | J6. Conformance | `haus-ref --json-suite`: all cases of `test-suite/json` pass (schema-based, self-describing, import, and every `valid/NAME.jsonl` as self-describing JSON Lines), none skipped; in CI. `haus-ref --suite` checks `valid/NAME.jsonl` too. Types from [`scripts/schema-types.ts`](scripts/schema-types.ts) → [`json-suite.json`](json-suite.json), checked up to date in CI. | days |
| ✅ | J7. Fuzzing | `--json-batch`, `--json-read-batch`, `--haus-json-batch`, `--haus-json-read-batch`, `--import-batch` against runners for TypeScript, Effect, Rust, Roc and Python (`fuzz/src/json.ts`), error codes compared, in CI. | done |
| ✅ | J8. The decided forms | The decisions of the design review ([§3.7](../design-review.md), F1–F7) in the model, its names following F1 (`SelfDescribing`, `SchemaBased`, `readImport`). The self-describing form's keys `_tag`, `_args`, `_rec`, `_num`, `_bytes`; its envelope (`hausJson`, `fromHausJson`: exactly the members `_haus` and `_value`, `haus-json-form` otherwise, `_haus` the number written `1`, `haus-json-version` otherwise), one per line of JSON Lines (`readHausJsonLines`); JSON nesting `4 · d + 2` for it (`hausJsonDepth`). `_args` in `unknownJson` and `readCore` (`args` is now an ordinary member of a newer writer's record payload), reserved with `_tag` (`hasReservedField`); `Any` and `_args` without the envelope. Every writer escapes DEL, C1 and bidi controls (`escape`, `write_clean`); the self-describing text reader rejects them raw where its string lexer meets them (`strChars` in strict mode: `control-character`, `bidi-control`), so the error is the first in the text, the schema-based reader and the import accept them. Proven again: `hausJson_*` beside `selfDescribing_*`, `hausJson_fits` (`SelfDescribingOk` now needs room for `_bytes` and `_value`, and the version `1`), `hausJson_wellFormed`, `readHausJson_writeHausJson` (`parseText_write` in strict mode), `readHausJsonLines_writeHausJsonLines`, `hausJsonLines_text_parsed`; `toJson_error` names `_tag` or `_args`. Error codes `haus-json-form`, `haus-json-version`, `haus-json-number`, `haus-json-bytes`. | days |
| ✅ | J11. Record cases (design review B7) | The model follows §15/§16.3: a case with one argument whose type is a record is a record case, however the record is written. `Case.named tag T` is `Tag T` written with a name, an applied name or parentheses; `caseOf?` resolves it (`Case.resolve`): the record case of `T`'s record through references (`recordOf?`, not through `Secret`, as the TypeScript resolver does), else one positional argument. A type parameter, once applied, is `Case.positional`, which never resolves to a record case. `scripts/schema-types.ts` keeps the name (`"named"`, beside the resolved `"record"` the fuzzers read), so `haus-ref` finds the record itself; all cases of both suites pass. In [`Json/RecordCases.lean`](Haus/Json/RecordCases.lean): `record_case_named`, `record_case_ref`: in a variant, `Tag T` with `T` the record `{ … }` through names and `Tag { … }` in place decode every haus value alike, write every decoded value to the same JSON and read every JSON to the same value, for every fuel of the `Maybe` chains; `positional_one_toJson`/`_fromJson`, `result_ok_toJson`/`_fromJson`: one positional argument (`Ok a`) is `{"_tag": …, "value": J}`, `J` the argument's own JSON, whatever its type; `schemaBased_round_trip` and the other J theorems hold unchanged (their proofs go through `caseOf?`). `record_case_named_json`: the same for `toJson` and `fromJson`, whose fuel (`nullFuel`, from type sizes) differs between the two (see "The chains of `Maybe`s" below). Not proven: the in-environment form (`type Boxed = < Box BoxRec >` against `< Box { … } >` as definitions, rather than as the variant itself). | 1 day |
| ✅ | J9. An older reader accepts a newer writer | What "newer" means (§13.3's minor versions): `Env.Minor env env'`, every type of `env` defined in `env'` as the old definition with new optional fields in open records (`MinorFields.add`) and new tags, of any payload and a tag, in open variants (`MinorCases.add`), anywhere inside (`MinorTy`), new types allowed; a new key or tag is none the record or variant has after it. `older_reads_newer`: for a well-formed value without duplicate keys that the newer type decodes to `x'`, the older reader reads the newer writer's schema-based JSON without an error, as `y` with `Older x' y`: the cases the older schema doesn't list unknown values (`{"_tag": "Run", "args": [1, 2]}`, `{"_tag": "Square", "side": 2}`: their members imported as a record payload, §16.1), the fields it doesn't list left out, the rest the same; `older_reads_newer_name` for a type by name, `older_reads_newer_parsed` for every parsed value; an `example` shows a schema with a new case and a new optional field is a minor version. Needed on the way: the two schemas follow the same names, `Bool`, origins, cases and fields, and write `null` for the same `Maybe`s (`whnf_minor`, `boolTy_minor`, `caseOf?_minor`, `nullArg?_minor`, with `chainEnd_minor` on the chains); each schema's own fuel `env.fuel` is enough for every chain of names (`whnfNames_nodup`: a successful chain visits each name once, so `whnf_enough`; `whnf_fuel`, `recordOf?_fuel`, `lastRef_fuel`, `reachesBool_fuel`, in [`Json/Fuel.lean`](Haus/Json/Fuel.lean)); types compared structurally (`Ty.beq`, lawful, replacing a derived `BEq` that was `partial` and opaque, so `chainEnd`'s `contains` can be reasoned about). The theorem is for one fuel `F` of the `Maybe` chains on both sides, as in J11; `older_reads_newer_json` states it for `toJson` and `fromJson`, each schema with its own `nullFuel` (below). A `closed < None \| Some a >` keeps its argument as written (it may name a type that changes): a `Maybe` of a variant or record written in place can't grow in the model. In [`Json/Evolution.lean`](Haus/Json/Evolution.lean). | done |
| ✅ | J10. What the JSON readers return | `UniqueKeys` for what the JSON readers return, as `parse_uniqueKeys` for haus text: the import (`JSON.toValue_uniqueKeys` for well-formed JSON, `JSON.readImport_uniqueKeys` from text) and the self-describing reader (`JSON.fromSelfDescribing_uniqueKeys`, `JSON.fromHausJson_uniqueKeys`, `JSON.readHausJson_uniqueKeys`, `JSON.readHausJsonLines_uniqueKeys`), from `parseText_sound` (no duplicate member names) and the readers keeping member names as keys. Both paths decode alike: `json_paths_agree`, reading a value's self-describing JSON and decoding it with `t` gives what reading its schema-based JSON with `t` gives (from `fromHausJson_hausJson` and `schemaBased_round_trip`). In [`Json/Readers.lean`](Haus/Json/Readers.lean). | done |

The mappings' theorems are about `JSON` as data; J1's connect them to text:
`JSON.readHausJson_writeHausJson`, `readJson_write`, `hausJson_text_parsed`
and `schemaBased_text_parsed` ([`Json/Correct.lean`](Haus/Json/Correct.lean))
read the written text back to the value, for a value without duplicate keys
(`UniqueKeys`, which every parsed value has) that is within the limits
(`Value.fits`: record keys and tags count like strings, §7);
`hausJsonLines_text_parsed` does it for a file's values as self-describing
JSON Lines, as the suite's `valid/NAME.jsonl` hold them. The JSON written
is well formed (number tokens, distinct member names): the self-describing
JSON (`hausJson_wellFormed`) and the schema-based JSON (`toJson_wellFormed`,
in [`Json/SchemaBasedWellFormed.lean`](Haus/Json/SchemaBasedWellFormed.lean):
integers are normalized literals, a float's spelling is a JSON number
(`spell_json`), a record's members are some of the value's fields, and
`_tag` never meets a payload field named `_tag`, the case `toJson_error`
refuses). Its text holds no raw DEL, C1, bidi control or U+2028, U+2029
(`write_clean`), so the self-describing reader's strict mode, which rejects
the first three raw and accepts the separators (`strictRejects`), reads it (`parseText_write` holds
for both modes). And it is
within the JSON limits (`Fits`): the self-describing JSON, nested at most
`4 · maxDepth + 2` (`hausJson_fits`, [`Json/Fits.lean`](Haus/Json/Fits.lean)),
when the limits leave room for its member names, for number literals in
strings and for the version (`SelfDescribingOk`: `maxStringLength` at least
6 and at least `maxNumberLength`, the longest haus number within the limits;
`maxNumberLength` at least 1); the schema-based JSON, nested at most
`4 · maxDepth + 1` (`toJson_fits`,
[`Json/SchemaBasedFits.lean`](Haus/Json/SchemaBasedFits.lean)), under the
same conditions (`SchemaBasedOk`): a haus number within the limits and a
JSON number token within them are counted the same way, as written
(`numberFits_tokenFits`), since every integer a haus literal can hold has a
decimal form within the number limit (§7) and no hex form is accepted
instead. The defaults meet both. Not proven: linear time.

How the model follows §16 where it was clarified while writing it (all now
in the spec, with vectors):

- **The prelude's `Bool` and `Maybe`, by name.** The model's types have no
  names, so the prelude's `Bool` is the reference `Bool` (`boolTy`), and each
  use of the prelude's `Maybe` a definition of its own named `Maybe#k`
  (`preludeMaybe`); `haus-ref` writes the resolved types that way for the
  JSON modes. A schema's own `closed < False | True >` is a closed enum, and
  its own `closed < None | Some a >` a tagged variant.
- **A `Maybe` that reaches itself** (`type T = Maybe T`) uses the tagged
  form, as §16.3 says. A `Maybe` is identified by the definition it is
  written in and its type (`origin`), so with `type D = Maybe T`, `T` is
  tagged and `D` uses `null` (D doesn't reach itself, and `T`'s JSON is never
  `null`). The chain of `Maybe` arguments is followed with fuel
  (`nullFuel`, the size of the types involved). The round trip holds for any
  answer the chain gives (`usesNull` never lets a `null` arm hold a `null`),
  and the answer is the same for every fuel from `env.fuel` on, which
  `nullFuel` always is ([`Json/NullFuel.lean`](Haus/Json/NullFuel.lean):
  after its first link a chain goes on only at the body of a `Maybe#…`
  definition, `links_mem`, so `endOf_stable`, `chainNull_fuel`, and
  `toJson_eq`, `fromJson_eq`).
- **A schema's own `closed < None | Some a >` inside a `Maybe`'s argument**
  (`Maybe (closed < None | Some Int >)`) is a variant like any other: a
  type written in place inside a `Maybe#…` definition has the origin `""`,
  not the `Maybe`'s (`origin`, `inPlace`). It used to inherit it, so
  `haus-ref` wrote `Some(None)` as `{"_tag": "Some", "value": null}`, where
  §16.3 and the TypeScript binding give `{"_tag": "None"}` (`#guard`s in
  `NullFuel.lean`). No JSON suite case covers it yet.
- **An unlisted tag without other members** reads as bare (`Hexagon`), not as
  `Hexagon {}`; with only `_args` as self-describing values, and
  `"_args": []` is rejected;
  otherwise its other members read as a record payload (§16.1).

## L. Layouts

Spec §11 defines the pretty and the compact layout in prose, and
[`test-suite/format`](../../test-suite/format) pins them down byte for byte
on 70 inputs (31 cases, 9 examples, the 30 valid files), with idempotence
and the same values checked for each. The TypeScript and Rust formatters run
it. What that leaves open:

- The expected files are written by the TypeScript formatter and reviewed by
  hand, so the suite shows that Rust agrees with TypeScript, and that
  TypeScript is right as far as the review saw.
- Nothing is checked on generated input: the fuzzer (G) has no formatter.
- Nothing was proven. E proves that the canonical form parses back; the
  layouts' writers are different code. L3 and L5 now prove reference
  writers of the three layouts from values (without comments) parse back.
- Block strings, where a mistake is likeliest, had no written rules
  (design review §3.6 B2). Spec §4 and §11 now have them, and L4 proves
  the pretty layout's block strings parse back and survive trimming.

| | Step | Gives | Effort |
|---|---|---|---|
| ✅ | L1. Fuzzing the formatters | In `fuzz/`, on G's generated inputs (comments, blank lines, block strings, CRLF, byte order marks, both payload forms): formatting keeps the values, in all three layouts (pretty, compact, minimised: design review §3.8), so every form has the same hash; formatting twice is formatting once; the TypeScript and Rust formatters give identical bytes; the pretty layout keeps every comment; a compact or minimised item has no line break; minimised and then pretty is pretty of the input without its comments and blank lines (G1, G2). Shrinking as in G. | days |
| ⬜ | L2. The rules in prose | Block strings in spec §4 and §11 (B2): the indent, whitespace-only lines, escapes after the indent is removed. What the pretty layout writes for a string whose lines end in blanks or hold only blanks, which an editor that trims lines would change: decide (escape them, or not use a block string). And whether §10 lets the layouts change after 1.0: it lists what never changes, and the standard format is not on the list. The decisions of design review §3.8 in §11 and §12: the minimised layout (compact without the whitespace between tokens, literals as written), compact and minimised drop every comment and a tool refuses to rewrite a file with comments in place in them, and all four forms have the same hash. Expected `NAME.minimised` files in `test-suite/format`. Also, found by the Go binding (2026-11-18), rules the format suite pins that §11 doesn't state: a comment after an opening bracket on the same line leads the first entry; comments between a key and its colon, or the colon and the value, go after the entry's own leading comments; for `Tag({…}) // c` the comment trails the last entry when `}` is on its line, else it dangles at the end; blank lines right after an opener or before a closer are dropped; a trailing comment after the comma doesn't count toward the width; comments and multi-line strings inside a positional payload never fit. | days |
| ✅ | L3. Reference compact and minimised writers | In [`Layout/Compact.lean`](Haus/Layout/Compact.lean): `line sp : Value → Text`, one writer for both one-line layouts with the whitespace between tokens as a parameter (`Spacing`: compact's `, ` `: ` `{ … }` `Tag { … }`, or none), so `compact` and `minimised`, and `compactAll`, `minimisedAll` for a file or stream (a single value without a comma, more than one each followed by `,`, one per line, every line ending with a line feed, as the TypeScript `format`). Fields in the order given, numbers as their normalized literal, bytes as lowercase hex, strings `"…"` with the canonical escapes (never a block string), keys bare when they can be. `minimised_eq_write`: the minimised layout is `Canonical.write`, so `canonical_eq_minimised`, the canonical form is the minimised layout of the value in canonical order. Proven in [`Layout/CompactRoundTrip.lean`](Haus/Layout/CompactRoundTrip.lean), by induction on the derivation as in E, for any spacing of blanks (`Val.line`): `parse_compact`, `parse_minimised`, every parsed value's layout parses back to exactly that value, fields in the same order; `parse_compactAll`, `parse_minimisedAll`, the same for a file or stream; `Val.line_noLF`, the layout of a value holds no line feed (number literals, tags, keys, escapes and bytes have none), so `compactAll_split`, `minimisedAll_split`: split at its line feeds, the text is one line per value (and an empty last one), each line parsing alone to its value (§11, like NDJSON). For any limits. `haus-ref --compact FILE` and `--minimised FILE` print them. Checked against `test-suite/format` (all 70 inputs): 60 of 70 `.compact` and 60 of 70 `.minimised` files are identical; the other 10 (`cases/spellings`, `cases/minimised-spellings`, `examples/syntax-tour`, `valid/bytes`, `exponents`, `limits-boundary`, `negative-zero-hex`, `numbers`, `strings`, `unicode-edges`) differ only where the formatter keeps a source spelling: digit separators, hex and binary integers, `E`/`+`/leading zeros in exponents, hex case and blanks in byte strings, `\u{…}` escapes of printable characters. Open: every binding's serializer of values (`stringify`, `to_string`, Roc `Encode`, Python) fuzzed against the two modes. | done |
| ✅ | L4. Block strings parse back | `Pretty.blockString ind s` ([`Pretty/BlockString.lean`](Haus/Pretty/BlockString.lean)) is the block string the pretty layout writes for `s` at the indent `ind`, as spec §11 and the TypeScript formatter write it: each line of `s` after `ind` (an empty line without it), `\` as `\\`, a quote followed by two more quotes as `\"`, a carriage return as `\r`, other raw controls but tab, bidi controls and U+2028, U+2029 as `\u{…}`, and a last space or tab of a line as `\u{20}` or `\t` (B2). Proven for every string within the string limit and every indent of blanks: `blockString_parses`, it is a `Grammar.BlockString` with the value `s`, so `parse_blockString`, the reference parser reads it as `[.str s]`; `blockString_noTrailingBlank`, no line of it ends in a space or a tab (and `blockString_noCR`, it has no carriage return, so its lines are split at line feeds); `trimLines_blockString`, trimming the blanks at the end of every line leaves it unchanged, so `parse_trimLines_blockString`, it still parses to `s`. `#guard`s check the spec's example and the TypeScript formatter's output on quotes, controls and blank-only lines. Not covered: the formatters themselves (L1 fuzzes them), and a `haus-ref` mode to fuzz their block strings against `blockString`. | done |
| ✅ | L5. The pretty layout from values | In [`Layout/Pretty.lean`](Haus/Layout/Pretty.lean): `pretty o ind used v`, the pretty layout without comments as the TypeScript formatter writes values, with the options `o` (indent width 2, line width 80 by default), `v` starting on a line indented by `ind` with `used` columns taken (the entry's indent, `key: ` and the comma after it). One entry per line in every non-empty record and array, each followed by `,`, the closing bracket at `ind`; `{}`, `[]`, `Tag {}`; `Tag({ … })` as `Tag { … }`; a positional payload on its line exactly when it is `flat` (no non-empty record or array, no string with a line feed, at any depth) and `used` plus its compact length, in code points, is at most the width, else one argument per line; a string with a line feed as `Pretty.blockString` (L4) one level deeper than the entry. `prettyAll` for a file: a single value at `used` 0 and a line feed; more than one each with `,` (so `used` 1), a line feed, and a blank line after a value that spans lines and isn't the last. Proven in [`Layout/PrettyRoundTrip.lean`](Haus/Layout/PrettyRoundTrip.lean), by induction on the derivation (`Val.pretty`): for every value a parser returns, every options, every indent of spaces and tabs and every `used`, `parse_pretty`, the layout parses back to exactly the value, fields in order; `parse_prettyAll`, a parsed file or stream in the pretty layout parses back to the same values. The width decides only which of two texts is written, and both parse back: the payload on its line is its compact layout (L3, `Val.line`), and a block string parses back by L4 (`Pretty.blockString_val`: nothing is assumed about block strings beyond what L4 proves). `haus-ref --pretty FILE [INDENT WIDTH]` prints it. Checked against `test-suite/format`: 30 of 70 `.pretty` files identical (with `cases/width-options`' indent 4 and width 40; that case is also a `#guard`); of the other 40, 28 differ only by the comments and source blank lines the formatter keeps, 2 (`cases/comments-containers`, `cases/comments-payload-parens`) because a container or payload holding only a comment is broken over lines, and 10 (the inputs above) by kept source spellings, with the same lines otherwise. Not proven: that no line of `prettyAll` ends in a blank, so trimming keeps it (L4 proves it of block strings; the rest of the layout ends lines in `,`, an opening bracket or `"""`), and that a line is never wider than the width when it can fit. Open: the bindings' pretty serializers fuzzed against `--pretty`. | done |

Not planned: a model of the pretty layout with comments, their placement
and blank lines. It would need a model of documents with comments, which
the parser's model has no place for (comments are whitespace in the
grammar). L1 covers it by fuzzing, and the suite pins the placement.

## X. Extensions and codecs

An extension's schema is an ordinary schema, so the theorems of I and J
(`decode_iff`, `decode_encode`, `schemaBased_round_trip`) already hold for its
types. What they don't cover is the rules a package adds beyond its shape:
its profiles (spec §13.3), which codecs (§13.4) enforce. A profile is small
and decidable, like the std/time profile, so it gets the same treatment as
T: a definition, a checker proven to compute it, and the bindings fuzzed
against it.

| | Step | Gives | Effort |
|---|---|---|---|
| ✅ | X1. The codec contract | In [`Schema/Codec.lean`](Haus/Schema/Codec.lean). A codec (`Codec H`) reads the value the type's schema decoded into a host type `H`, or rejects it (`read`), and writes a host value back as a decoded value for the schema's encoder (`write`); a profile is a check (`Codec.check p`: `H` is the decoded value, kept). For every codec that keeps the value (`Codec.Keeps`; `check_keeps`: every check does), the laws of §13.4: it accepts only what the schema accepts (`decode_ok`, `decode_schema`; by construction) and rejects more, never fewer (`decode_error`: the schema's error); decode, encode, decode is decode (`decode_encode`, from `Schema.decode_encode`); the value's meaning doesn't change (`decoded`/`dec`: it holds the value the schema decoded; `encode_eq`, `encode_equiv`: encoding through it writes what the schema's encoding of that value writes, equal by §2, so the same canonical form and hash; `encode_agree`: the input except where §15 says; `same_value`: two codecs that both accept a value agree on it). A codec whose host type keeps less than the value (`Instant` as a JavaScript `Date`) gets decode, encode, decode from its one obligation (`decode_encode_of`): what it writes is a value of the type that it reads back as the same host value. Not modelled: a codec applied inside other types (§13.4: wherever its type occurs); the official profiles' rules include their nested types (`Money`'s currency, `BBox`'s corners). | days |
| ✅ | X2. Reference model of each profile | In [`Haus/Profiles/`](Haus/Profiles). The rule of `extensions/*/profiles/*.md` as a definition on the decoded value (`Valid`), a checker with `check_iff` (`Money.check_iff`, `Geo.check_iff`), and the profile as a codec (`codec_decode`: it accepts exactly what the schema decodes and the rule accepts; `codec_keeps`, so every law of X1 holds; `codec_decode_encode`). `@haus-fmt/money/iso`: a `Currency` is a bare tag of three capitals A–Z, a `Money` any `Decimal` with such a currency. `@haus-fmt/geo/wgs84` (design review E3): the ranges on the decoded float's exact value as a `Rat` (`toRat?`; `NaN` and the infinities have none), −90 ≤ lat ≤ 90, −180 ≤ lng ≤ 180, `-0` kept; `BBox` needs `sw.lat ≤ ne.lat` and may cross the antimeridian; the checker compares products of integers (`within_iff`, `le_iff`). The packages' schemas are written in Lean (`Money.env`, `Geo.env`); they are what `scripts/schema-types.ts` resolves from `extensions/*/schema.haus` (compared by hand, not in CI). `haus-ref --profile NAME FILE` runs a vectors file (`Accept { type, value, output?, note? }`, `Reject { type, value, note? }`); a `Reject` must be valid for the schema of its type (the shape), so that the rejection comes from the rule, and one the schema already rejects fails with the schema's error; both pass (money 10/10, geo 17/17), in CI. | days |
| ✅ | X3. Fuzzing | Every binding's profile codecs (TypeScript `h.*` and package exports, Effect, Python, Rust, Roc) against `haus-ref --profile-batch`, on generated values and near misses (`fuzz/src/profiles.ts`, runners in `fuzz/schema-rust`, `fuzz/roc`, `python/fuzz`; CI: 200,000 cases per profile per PR, 2,000,000 nightly). No disagreements (2026-11-18, seeds 2–4, 6, 11; up to 200,000 per profile). Go has no profile codecs yet. | done |
| ⬜ | X4. Proofs where a profile claims something | One spelling per value (a canonical UUID, as T6), parsing that security depends on (`@haus-fmt/net`: URLs, email addresses, IP addresses), exact numeric bounds. Per profile, when the package is written. | per profile |

Not modelled: registries. Whether a currency code is assigned is outside the
`iso` profile by design; a profile that checks it would be a table generated
from ISO 4217 and tested, not proven. And none of this is a rule for schema
packages: a profile's contract is its written rule, and community packages
need no Lean.

## R. Package resolution

`plans/package-resolution.md` first judged the rules "finite checks over a
graph, not worth proofs". The security review of 2026-11-17
(`plans/package-security-review.md`, appendix "What Lean could verify")
showed otherwise: F1 (Node's walk also tries `node_modules/@scope/node_modules`)
and F4 (unifying identical copies made the result depend on import order) are
exactly the bugs a proof finds, and the suite's expected results (74 cases, 40
from the review) were written by hand and checked by nothing. So:

| | Step | Gives | Effort |
|---|---|---|---|
| ✅ | R1. File-system model and reference resolver | A finite file tree with directories, regular files, symbolic links (relative targets, dangling, cycles) and other files (a FIFO); `realPath` (at most 40 links), a directory listing, and reads through an interface that records them ([`Packages/Fs.lean`](Haus/Packages/Fs.lean)). The resolver of §13.3 on it, executable: root file, mode (`Npm`, `Explicit`, both) → `Ok packages` or `Err code` with a message ([`Packages/Resolve.lean`](Haus/Packages/Resolve.lean)); names, versions and quoting ([`Packages/Names.lean`](Haus/Packages/Names.lean)); a schema file's imports and type names ([`Packages/SchemaFile.lean`](Haus/Packages/SchemaFile.lean)). `haus-ref --packages FILE [CASE]` runs `test-suite/packages/cases.haus`, the `should` cases included: all pass, every hand-written `expect` checked, and every run reads only package files and `*.schema.haus` files, each once ([`Packages/Suite.lean`](Haus/Packages/Suite.lean)). The world-writable skip is a parameter (`Config.worldWritable`); Windows drive roots are not modelled. | 2–3 days |
| ✅ | R2. One package per name, and ids | `one_package_per_name`: the packages a run makes have distinct names (an invariant of their type, `Classes`), and on `Ok` they are the result (`resolveIn_ok`); `addClass_same`: a copy gets a class only with the same name, `package.haus`, `schema.haus` and imports, and classes only grow. `typeId_injective`: `(name, major, type) ↦ @org/name@N#Type` is injective for valid names and majors. In [`Packages/Props.lean`](Haus/Packages/Props.lean). Not proven: that `classify` is the only writer of the classes over all of `load` (by inspection). | ½–1 day |
| ✅ | R3. Order independence (F4) | The result doesn't change when the graph is walked in another order. As intended by the spec, this holds of success or failure and of the packages on success, not of the error code: with two mistakes in one schema the resolver reports the first it meets (`twoMistakes` in [`Packages/Order.lean`](Haus/Packages/Order.lean): `import-not-found` or `undeclared-package` by the order of two imports). **Proven** in [`Packages/Walk.lean`](Haus/Packages/Walk.lean): `resolveIn_walk` (a run that succeeds in one order succeeds in every order, with the same packages) and `resolveIn_walk_error` (one that fails fails in every order). The order is a parameter of the model: `resolveIn t c root w`, `w : Walk` a permutation of each file's import list, used by both loops of `load` (default `Walk.file`, the order of the file; the suite runs that). The steps: (0) the classes ([`Packages/Closed.lean`](Haus/Packages/Closed.lean)): `runIn_closed`, `classes_topo`: in every state of every run, each class imports only classes made before it, and every copy loaded (`.done k`) names a class made; `resolveImport` and `load` return only classes made (`resolveImport_closed`, `load_closed`); (1) every step of the resolver but `load`, `classify` and `countFile` as a function of the tree and the settings (`View`, which has no order) with its caches (`St.manifests`, `St.npm`) shown truthful (`Tr`): `Pure env x v`, `x` returns `a` exactly when `v = some a` and fails exactly when `v = none` ([`Packages/Steps.lean`](Haus/Packages/Steps.lean): `Pure.openFile`, `.manifestOf`, `.packageJsonOf`, `.projectOf`, `.declared`, `.npmLookup`, `.candidates`, `.decodeScan`, `.checkNames`, `.copyNpm`); (2) what a successful run has checked ([`Packages/Done.lean`](Haus/Packages/Done.lean)): in every state, each target finished (ghost `St.finished`, in the order the run finished them) passes its own checks as a property of the tree (`Local`) with every target it loads finished before it, each file and copy done has the types of its file and a copy's class is its package (`Corr`), and the targets started are at most the files counted (`Good`; `load_good`, `givenPackages_at`); (3) the simulation ([`Packages/Walk.lean`](Haus/Packages/Walk.lean)): from the last state `S` of a successful run (`Ref`: closed, checked, at most `Limits.files` targets, one package per name), a run in another order from a state `Below` it never fails and stays below it (`load_sim`): it starts only targets `S` finished (so `countFile` passes), a target on its stack was finished in `S` after everything it loads (so no `import-cycle`, and the fuel `Limits.files + 1` is enough), and its classes are packages of `S`, each with its imports in its own order (so `duplicate-package` can't occur). `load_walk`, `runIn_walk`: the packages of the second run are packages of the first; by symmetry the same, so `packagesOf` is the same (`packagesOf_eq`). Model changes, none observable (the suite passes): the walk order parameter; `load`'s fuel is `Limits.files + 1` (was the tree's entries + 1, which a tree with files and directories at the same paths could exhaust; each frame counts its file before recursing, so `too-many-files` comes first); three checks of a copy factored out of `load` (`copyNpm`, `checkVersion`, `checkNoFiles`, `Import.isFile`); the ghost `St.finished`. | done |
| ✅ | R4. Bounded work (P3, F9) | `reads_nodup`: a run opens each file at most once, so at most as many as the tree has files (`reads_length_le`); `count_le`: at most `Limits.files` schema files, the root included; `openFile_spec`: the bytes of a file opened are within the limit its caller gives, or the run fails before using them; `lookups_le`, `lookups_le_files`: the searches for a package (`candidates`, each an npm walk of one `realPath` per directory above the importer) are at most the imports of the schema files loaded, at most files × the most imports in one file. One invariant over every state of every run, in [`Packages/Reads.lean`](Haus/Packages/Reads.lean), with a Hoare-style `Triple` for the resolver's monad ([`Packages/Run.lean`](Haus/Packages/Run.lean)). Writing it found that the resolver could read a file twice, its caches being kept by kind: a project's `package.json` that is a link to a schema file, and a root that is a `package.json` (`linkedPackageJson`, `rootPackageJson` in [`Packages/Order.lean`](Haus/Packages/Order.lean)); `openFile` now keeps the paths it opened. | 1 day |
| ✅ | R5. Name isolation (F1, P6) | `candidates_from`: every candidate for `@org/name` is a package given explicitly with that name (by its directory; in a folder only when none is given by its directory), or, with `npm` and none given by its directory, what the walk finds; the walk runs only after the importer's `package.json` is read (`declared`, R7). `npmLookup_eq`: the walk is `npmFind` on `walk`, reads no file and changes nothing of the state; `npmFind_congr`, `npmLookup_isolated`: it depends only on the real paths of the places of `walk` and whether those have a `package.haus`. `walk_mem`: those places are `D/node_modules/@org/name` for `D` the importer's directory or above, not named `node_modules`, not a scope directory directly inside one, not world-writable (`Config.worldWritable`); `walk_skips_scope`: never `…/node_modules/@scope/node_modules/…`. Node's walk is the counterexample: `nodeWalk_scope` tries that place from any file in the scope, and on the tree of F1 it finds the planted package where `walk` finds the honest one (`#guard`). In [`Packages/Isolation.lean`](Haus/Packages/Isolation.lean). | 1–2 days |
| ✅ | R6. Folders are conservative (F2) | Adding a folder of packages never turns one successful result into a different successful result: it gives the same result or an error (it can turn a success into an error, a second copy with other files being `duplicate-package`, as intended). **Proven** in [`Packages/Folders.lean`](Haus/Packages/Folders.lean): `resolveIn_addFolders` (the folders `fs` appended, `Config.addFolders`: the same packages or an error) and `resolveIn_folders` (any settings with more folders and everything else the same, `MoreFolders`, both runs successful, each in any walk order: the same packages). The steps: (0) the packages given (`givenPackages_ok`): on success, exactly those of the directories given (`PkgEntry`) and of the folders' entries (`FolderEntry`); so with more folders the packages given by directory are the same and the others only more (`Wider`), and every candidate set of an import only grows, by directory (`Wider.cand`: the folders only add `inFolders`, and a name now in a folder is no longer `undeclared-package`; `declared`, the npm walk, manifests and files are the same); (1) reachability (`load_reach`): in every state of every run, every target finished is reached from the root (`Reach`: the root, or what an import of a reached target loads, `Loads`: the file it names or a candidate, both properties of the tree), an invariant of its own next to R3's `Good` (it needs the target being loaded, which `Good` doesn't know); (2) without ⊆ with (`Good.loads_wider`): the last state `S'` of the run with the folders is closed under the smaller candidate sets, so it finished every target the run without them reaches, and every package of `S` is one of `S'`; (3) with ⊆ without, by induction on reachability with the folders (`load_wider`): each file reached `S` finished, and each copy reached has the name of a copy `S` finished (`InWithout`): a copy that only a folder gives has the name of a copy that `S` finished, so in `S'` its class (one package per name), so the same schema and imports (`Good.same_scan`), which resolve in `S` (`Local`) to copies with the names imported (`ImpOk.found`). So the packages have the same names, and the same versions, since `S'` finished the copies of `S` too. No model change. The partial simulation planned for (a) (a run without the folders against `S'`, like `load_sim`) wasn't needed: reachability and the closure of `S'` give it, and (b) needs no order on the finished targets. | done |
| ✅ | R7. Read set and non-interference (P1, P2, F6–F8) | `reads_allowed`: every file a run opens is `Allowed`: a package's own `package.haus`, `schema.haus` or `package.json`, a regular file directly in a directory with a `package.haus`, never through a link (this covers the reached packages, the explicitly given ones and folder entries, and a `node_modules/@org/name` that names another package); a regular file whose real path ends in `.schema.haus`, or the root; the real path of `D/package.json` for a directory `D` above a schema file (also the ones skipped). `resolveIn_same`: two trees that differ only in the bytes of files the run on one of them doesn't open give the same result, message and reads; `resolveIn_other_files`: so changing any file that isn't `Allowed` changes nothing. The resolver now sees the tree only through `look` (kinds, names, links, real paths, never bytes) and `openFile`, which records a file when it opens it, before the size check. Proven a construct at a time (`NI`) in [`Packages/NonInterference.lean`](Haus/Packages/NonInterference.lean); the read set in [`Packages/Reads.lean`](Haus/Packages/Reads.lean). Not modelled: "a reached package" (the read set says "a package"), and the race of F6. | 2–3 days |

R1 comes first: it checks the suite's expected results, and the fuzzer can
then compare the bindings with it on random small trees (a `--packages` mode,
as for the schema checker in G). R2–R4 need only the graph and are small;
R5–R7 need the file-system model with links.

Not settled by Lean: what operating systems do (case-insensitive and
Unicode-normalising file systems, Windows junctions and UNC paths, the race
between checking and reading of F6), what npm installs, differences between
regex engines, and the editor.

## V. Versions

[`Haus/Version.lean`](Haus/Version.lean). A `Version` is what a version
fixes, everything written on haus values and texts, with error codes by
name, so that versions with different host types and catalogues compare:

| Field | Spec | `Extends old new` requires |
|---|---|---|
| `limits`, `maxValueLength` | §7 | Each default limit only grows (`Limits.Le`) |
| `codes` | §17 | No code leaves the catalogue |
| `parse` (values, or the error's code) | §1–§8 | Every text `old` accepts, `new` accepts with the same values (`Keeps`) |
| `fixed` (the code §17 fixes for a text with one mistake: the suite's error cases) | §17 | `new` fixes the same code, or accepts the text |
| `canonical`, `hashAll` (`hash v = hashAll [v]`; SHA-256 itself outside the model) | §12 | The same on what `old` can express |
| `builtin`, `schema`: each type's decoder, schema-based JSON writer (`toJson`) and reader (`fromJson`) | §13, §15, §16.3 | Every type keeps its name; decoding and its JSON are the same on what `old` can express; its JSON reader reads what the old one reads, alike |
| `writeHausJson`, `readHausJson` | §16.2 | The writer is the same on what `old` can express; the reader reads what the old one reads, alike |
| `readImport` | §16.1 | Reads what the old one reads, alike |

Proven: `Extends.refl`, `Extends.trans` (with `Keeps.trans`,
`Limits.Le.trans`, `sameType_trans`), `Extends.expresses`, `Extends.hash`,
`Extends.hashAll_parse` (an old file's values keep their hash and canonical
forms), `Extends.readHausJson_write` (self-describing JSON an old version
writes, the new one reads alike), `current_extends_self` (the version this
model describes, with the schema files' resolver and the suite's fixed codes
as parameters, since schema files are parsed outside Lean and the suite is
read at run time); `current_hash`: its `hash` hashes the canonical form;
`current_parse_code`: every code its parser reports is in `Code.all`, its
catalogue, but for running out of fuel (no valid text does; not proven for
invalid ones). Each release proves `Extends previous release`.

Decided in the model: error codes are compared only where §17 fixes them,
for a text with one mistake (`fixed`). Requiring the same code for every
text both versions reject would be false for a legitimate release: with a
larger string limit, a text with a too-long string and a later syntax error
changes from `string-too-long` to the syntax error's code; new syntax can
likewise move the first mistake. For the same reason the decoders' and JSON
readers' error codes are not compared, only what they accept (`TypeV.decode`
is `Option`, readers by `Keeps`).

Left: `Version.Conforms` (the version reports the codes it fixes) is checked
for this version only at run time by `haus-ref --suite`; `fixed` for the
schema and JSON suites' error cases; and a first non-trivial instance,
`current` with larger default limits extends `current` (needs `parse`
monotone in the limits: `File L t vs → Limits.Le L L' → File L' t vs`, by
induction over the grammar, with `maxHexDigits` monotone; the JSON readers
likewise), which the first release that raises a limit will need.

## Also

- Every disagreement found (by a proof or by testing) becomes a conformance
  case. So far: the lone carriage return (now an error everywhere), the
  string limit counting UTF-16 units in TypeScript (fixed), and raw control
  characters in comments and strings (now an error everywhere), the Rust
  stream crash and the byte order mark in streams (fixed), and Roc's std/time
  check accepting duration components too long to parse as a float (fixed,
  found while writing the model). The schema model found `type Any = < >`
  in `test-suite/schema/variants.schema.haus`, which `Any` in the prelude
  had made invalid (renamed `AnyTag`).
