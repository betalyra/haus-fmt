# haus design review

Date: 2026-11-07 (status updated 2026-11-13) · Scope: spec draft 0.1 (`spec/`), TypeScript packages, Effect adapter, Rust, Roc and Python packages, the Lean model (`spec/lean/`).

**Status legend:** ✅ done · 🟡 partly done · ⬜ open · — decided not to change

## Verdict

The core idea holds up. haus fixes JSON's real pain points: comments, trailing commas, unquoted keys, exact numbers, sum types, and streaming. It does so without adding the features that made YAML and XML dangerous: references, includes, remote schemas, executable tags. The grammar is small and strict. Four parsers (TypeScript, Rust, Roc, Python) and their stream readers agree on a shared conformance suite and on millions of generated inputs, checked against a reference parser in Lean that is proven to accept exactly the grammar (`spec/lean/`). The Lean model also proves the security properties of every valid file, that the canonical form parses back and is unique, that the stream reader gives the same result however the input is split, and that the std/time calendar is right with one spelling per value.

The weak spots were in four areas:
1. **Resource limits** were not specified, and the Roc parser could be stalled.
2. **A few syntax rules** could silently change meaning.
3. **Missing pieces:** there was no serializer and no canonical form; there is still no CLI or JSON converter.
4. **Some semantics were undefined:** equality, the position units in error messages, and stream termination.

The security and spec issues are fixed (§1, §2), apart from a few open details marked 🟡. What's left is mostly new functionality (§3).

---

## 1. Security

### 1.1 What the design already gets right

| Property | Why it matters |
|---|---|
| No references, anchors, merges or includes | Rules out YAML's "billion laughs" expansion and any reading of local files |
| Schemas are owned by the reader and never fetched remotely | Nothing like XML's external entities (XXE) or JSON Schema's `$ref` fetching, so the parser never makes network requests |
| Tags are data, not type names | Unlike YAML's `!!python/object`, parsing never instantiates classes. Bindings must keep it that way (spec §9) |
| Strict UTF-8, no lone surrogates, no raw control characters in strings | Prevents encoding-confusion attacks |
| Duplicate keys rejected | JSON leaves duplicates undefined. Parsers that pick different duplicates have caused real exploits |
| Nesting depth limit (256) | Prevents stack exhaustion |
| No `NaN` or `Infinity` literals, no leading zeros, no `+1`, no `.5` | One spelling per number, which reduces differences between parsers |

### 1.2 Findings

| | # | Finding | Resolution |
|---|---|---|---|
| ✅ | S1 | **Field smuggling via `__proto__` in the Effect adapter.** `{ "__proto__": { role: "admin" } }` decoded to `role = "admin"`. | Properties are set with `defineProperty`, with a regression test. `h.Record` was hardened the same way. Spec §9.4. |
| ✅ | S2 | **Duplicate-key check in the Roc parser took quadratic time.** 20,000 fields took 35 s. | Uses a `Set`; 20,000 fields now take 0.15 s. Spec §7 requires linear time. |
| ✅ | S3 | **Converting hex and binary literals took quadratic time** (Roc: 20,000 digits took 4 s). | Literals are capped at 1000 characters before conversion. The longest allowed hex literal takes 0.08 s in Roc. |
| 🟡 | S4 | **No configurable limits.** | Spec §7 defines limits and defaults: depth, number length, exponent, string length, and the size of one stream value. TypeScript, Rust, Python and Roc: limits can be set per call (Roc: the `_with` functions, which take a `Value.Limits`), and the stream readers take a maximum value length. **Open:** there are no limits on fields per record or items per array (memory is still bounded by the input size). |
| ✅ | S5 | **Huge exponents reach decoders** (`1e999999999`). | Exponents are capped at ±6144 in both parsers. Spec §3 and §7. |
| ✅ | S6 | **A cut-off stream looks valid.** | Every stream reader (TypeScript, Rust, Roc, Python) has a strict mode (`requireTerminator` / `require_terminator`) that reports a stream ending without a comma after its last value. Spec §6. There's no end-of-stream marker (decided against one). |
| 🟡 | S7 | **Unicode spoofing.** | Raw bidi controls are rejected everywhere (strings, block strings, comments) in both parsers, with 6 conformance tests, and VS Code highlights them as invalid. The spec says keys are compared by code point with no normalization, and notes the risk of NUL characters. **Open:** a linter for lookalike characters and mixed NFC/NFD keys. |
| ✅ | S8 | **Error positions differed between parsers** (UTF-16 vs code points). | Both now count code points. Spec §8. |
| ✅ | S9 | **No canonical form**, so values can't be hashed or signed. | Spec §12 defines the canonical form, `equals` and a SHA-256 `hash`, the same in every binding. Implemented in TypeScript, Rust (`hash` behind the `hash` feature), Python and Roc (`Encode.hash`, with the builtin `Crypto.SHA256`), with `compare` for a total order. A Lean reference encoder is proven to round-trip (`parse_canonical`) and to give identical text exactly for equal values (`canonical_eq_iff`); all bindings agree with it on the suite's `.canonical` files and in differential fuzzing. |
| ✅ | S10 | **Work that grows faster than the input.** Probing with hostile inputs found: schema inference printing was exponential in nesting depth (depth 20 took 0.8 s, so a small file could hang the editor); formatting with comments was quadratic (8,000 commented entries took 1.4 s); a large stream value arriving in small chunks was quadratic; Effect's union decoding is exponential for recursive unions of untagged structs. | All linear now (depth 250 infers in 3 ms, 8,000 comments format in 22 ms, chunked values scale linearly). The Effect adapter rejects recursive schemas with ambiguous unions up front. Inference now recognises recursive data (a tag inside the same tag, or a record inside one with the same keys) and prints a named type (`type Comment = …`) instead of unrolling it; shapes are merged with union-find, so unification is linear too. Regression tests in `adversarial.test.ts` (core and Effect). |
| ✅ | S11 | **Schema decoding had no bound beyond the parser's limits**, and values built in code (deep, shared or cyclic) weren't checked at all. | Spec §9.8–10. `h.*` and the Effect adapter enforce depth, a work budget (16 steps per input value; 16 Mi steps when encoding), cycle detection on encode and checks on raw `Unknown` values. Recursion is opt-in via `h.Recursive` with its own depth limit (64) and a check for unguarded cycles. Error paths are built only when an error occurs. **Open:** Effect's own encoder runs before ours and has no budget, so a JS value with heavy sharing still costs time there; Roc decoders are plain functions without a budget. |
| ✅ | S12 | **Raw control characters in comments and strings.** Comments allowed ESC and NUL, strings DEL and C1 (U+0080–U+009F, including CSI). A comment like `// \e[2K\e[1Aaccess: Admin` rewrites what `cat` shows in a terminal, while the data says something else. Found while proving the character properties in Lean. | Raw C0 (except tab and line breaks), DEL and C1 are rejected everywhere, in all four parsers, and every writer escapes them. Spec §4 and `grammar.ebnf`, 10 conformance cases, proven for the grammar in `spec/lean/Haus/Props/Chars.lean`. |
| ✅ | S13 | **The Rust stream reader crashed on a stream ending in `/`.** At the end of input it read one byte past its buffer: a panic, so a denial of service for anything reading streams from the network. | Found by differential testing (`fuzz/`), shrunk to the one-byte input `/`. Fixed, with a regression test. TypeScript and Roc were not affected. |
| ✅ | S14 | **Stream readers accepted a byte order mark after every comma**, and TypeScript's `parseStream` skipped two at the start. Whole-file parsing rejects both, so the same bytes meant different things streamed and unstreamed. All three bindings had it, so they agreed with each other. | Found by comparing each stream reader with whole-file parsing (`fuzz/`). A BOM is now skipped only at the start of the input, in all three. Regression tests in each binding. |
| ✅ | S15 | **Roc's std/time check accepted huge durations.** Duration components were compared as floats, and a number too long to parse as one (over ~309 digits) counted as 0, so `P999…9Y` passed the 2³² limit. | Found while writing the Lean model of std/time; exact integer arithmetic now. Regression tests in all three bindings, and `fuzz/src/time.ts` fuzzes every binding's std/time check against the model (it finds this bug in the old code). |
| ✅ | S16 | **A rule only in the code.** All bindings rejected zone names over 255 characters, but `std/time.md` didn't say so. | Added to `std/time.md`, and to the Lean model, which proves zone names can't leave the tz database when looked up as files. |
| ✅ | S17 | **Rust's stream reader was quadratic in the values per chunk** (against §7: linear time). After each value it removed that value's bytes from the front of its buffer, moving everything after it. 10 MB pushed as one chunk took 63 s. Neither the fuzzer nor the Lean proofs measure time. | The reader now removes the bytes of returned values once per chunk: 0.3 s. TypeScript and Roc were measured and are linear. Regression test with 200,000 values in one chunk; the benchmark plan covers stream readers with large chunks. |
| ✅ | S18 | **Stream readers reported columns one too small after a byte order mark.** The TypeScript, Rust and Roc stream readers skipped a BOM at the start and didn't count it, so every error on line 1 was a column early (`\uFEFF{ ok: true }`: 1:7 streamed, 1:8 parsed whole). The whole-file parsers, the Lean model and Python's stream reader count the BOM as column 1. All three readers had it, so they agreed with each other. | Found by differential fuzzing of Python's stream reader (`fuzz/` only reports position differences for information, not as failures). Fixed in all three. Regression tests in each binding; TypeScript, Rust and Roc also compare stream and whole-file error positions for every invalid suite file with a BOM in front. |
| ✅ | S19 | **`Int` was bounded in two bindings, and schemaless integer types depended on the data.** The prelude says `Int` is an integer of any size, but TypeScript decoded it to a `number` (failing beyond 2⁵³) and Roc to an `I128` (failing beyond 2¹²⁷). Without a schema, TypeScript chose `number` for a field unless one of its integers was too large, then `bigint`: the type depended on the document, which a stream reader can't know in advance. | `Int` is now an integer of any size in every binding: `bigint` in TypeScript, `haus::Int` in Rust (with `num-bigint` conversions behind the `bigint` feature), `Int` in Roc (exact digits, `to_i64`/`to_i128` fail when out of range). For a native integer the schema says `Int32`, `Int64`, …. Without a schema every integer is a big integer (spec §3). Tests in every binding decode an integer above 2¹²⁸ and write it back unchanged. |

### 1.3 Rules for binding authors

✅ Now spec §9 ("Security considerations"): tags are data, no remote resolution, enforce limits while parsing, keys never reach prototypes or internal fields, unknown variants are untrusted, fail on the first error, how to sign.

---

## 2. Design flaws and sharp edges

| | # | Issue | Resolution |
|---|---|---|---|
| ✅ | D1 | **The payload bound across line breaks**, so a forgotten comma silently created a payload. | A payload must start on the same line as its tag (only spaces and tabs in between). Changed in the grammar, both parsers and the suite, with 3 new invalid cases. |
| ✅ | D2 | **Positional payloads were mapped to named fields by order** (Effect adapter). | Opt-in via `Haus.Positional(…)`. Without it, the error suggests the named form. Spec §5. (`h.Tuple` and Roc decoders were already explicit.) |
| ✅ | D3 | **"Field absent" and `None` were conflated**, so PATCH updates couldn't be expressed. A first fix (a `Patch a = < Keep \| Set a >` field type, with "missing" read as `Keep`) brought back JSON's problem: two spellings of "nothing" whose meaning depends on the reader. | Two separate concepts, each with one spelling (spec §1): optional fields (`x?: T`, may be missing, never `None`) and `Maybe` (an ordinary variant, always written). `x?: Maybe T` gives the three states of a partial update. `Patch` was removed. TypeScript: `h.Optional`, `h.Maybe` (`None` → `null`); Effect: `optionalKey` / `Option`, never converted into each other; Roc: `Decode.optional_field` → `[Missing, Present a]`. Inference prints `x?: T` for fields only some records have. All tested. |
| ✅ | D4 | **Maps, sets, bytes and the size of the prelude.** The old `Map([(k, v)])` example wasn't even valid haus (no untagged tuples), `Set` couldn't be unordered as an array, and the prelude had grown to time, money, UUID and base64 bytes. | Prelude cut down to `Bool`, `Maybe`, `Result` and built-in types (spec §13). `Map v` is a record used as a dictionary (`h.Map`); non-string keys are written `[Entry(k, v), …]`; `Set` was dropped. Time and money moved to standard modules (`std/time`, `std/money`); UUID was dropped. Bytes became a data kind, `x"0b34ff"`, in both parsers, the formatter, `h.Bytes`, Effect (`Uint8Array`), Roc (`Decode.bytes`) and the editor, with 8 conformance files. **Open:** a separate syntax for unordered sets and maps (`#{ }`), if it turns out to be needed. |
| ✅ | D5 | **No `NaN` or `±Infinity`.** | Prelude tags `NaN`, `Infinity`, `NegInfinity`, accepted by `h.Float64` and by Effect's `Schema.Number`. |
| ✅ | D6 | **Equality undefined.** | Spec §2. Scale and notation are part of a number's value (`1.0 ≠ 1`); numeric equality is left to the schema. |
| — | D7 | **Keys must start lowercase, and tags are ASCII-only.** | Kept as a deliberate trade-off. The JSON converter (§3) must quote such keys automatically. |
| ✅ | D8 | **`Tag({…})` and `Tag {…}` are the same value.** | Stated in the grammar and spec §2. |
| ✅ | D9 | **No format version.** | Spec §10: new syntax must be an error in older versions; no version header. |
| — | D10 | **Single document vs stream.** | No change needed (spec §6). |

Ecosystem gotchas, documented in the examples:
- Effect's `DateTimeUtcFromString` accepts `2026-02-30` and rolls it over to March 2.
- Effect's `BigDecimal.format` drops the scale, printing `7.90` as `7.9`.

---

## 3. Missing pieces

### 3.1 Must have before anyone else uses it

| | Item | Notes |
|---|---|---|
| ✅ | **Serializer** | `format` / `stringify` (standard layout, spec §11), comments and blank lines kept, round-trip and idempotence tested on every conformance file; Format Document in VS Code. Schema-aware encoding: `h.stringify` / `h.encodeStream`, Effect `Haus.encode` / `Haus.encodeStream`, Rust `to_string`, Roc `Encode` (compact layout). |
| ✅ | **Limits API and spec defaults** | See S4. Configurable in every binding; Roc's `_with` functions take a `Value.Limits`. |
| ✅ | **Spec prose** | [`README.md`](README.md), draft 0.1: data model, equality, numbers, Unicode, variants, streams, limits, error positions, security, evolution, canonical form and hashing, the prelude and standard modules; schema files (§14) and decoding with a schema (§15); the std/time profile in [`std/time.md`](std/time.md). Schema conformance suite in [`../test-suite/schema`](../test-suite/schema): TypeScript, Effect, Rust, Roc and Python pass it, with lossless default host types (§13.4). |
| ✅ | **Conformance suite expansion** | Added: limits at and just past the boundary, bidi controls, control characters, line breaks, byte order marks, exponents, the D1 cases, Unicode edges (NFC and NFD keys are different keys, `\u{0}`, U+10FFFF, an escaped and a raw spelling of the same key are duplicates): now 120 files, 28 valid and 92 invalid, each valid file with its expected canonical form. Differential fuzzing of all parsers, stream readers, canonical forms and std/time checks runs in CI (`fuzz/`). |

### 3.2 Should have

| | Item |
|---|---|
| ✅ | **Canonical form** for hashing, signing and deduplication: spec §12, in every binding, proven in Lean (S9). `hashAll` hashes a whole file or stream, also while it is read (TypeScript, Rust, Python; proven in `HashAll.lean`). Features built on it are planned in [`plans/canonical-form.md`](../plans/canonical-form.md). |
| ✅ | **Schema language:** spec §14 (schema files: spreads, open vs closed, `Stream`, generics; recursion and expressiveness in §9.9–10) and §15 (decoding with a schema), parser and checker in TypeScript and Rust, and a schema conformance suite that TypeScript, Effect, Rust and Roc pass. Proof phase I is planned in [`lean/PLAN.md`](lean/PLAN.md). |
| ✅ | **JSON interop** (spec §16): JSON without a schema (`null` → `None`), a lossless mapping, and a plain mapping with a schema (large integers and decimals as strings, base64, a type-driven `Maybe`, `_tag` for variants, forward-compatible unknown tags). Vectors in `test-suite/json`, in TypeScript, Effect, Rust, Roc and Python, proven in Lean (phase J: lossless and plain round trips, injectivity), fuzzed against Lean in CI. |
| 🟡 | **MIME type** (drafted in `plans/mime-type.md`, submitted at 1.0): register `application/vnd.haus` in IANA's vendor tree: an online form with expert review, typically a few weeks. It needs the published spec, no parameters (always UTF-8), the security considerations of §9, interoperability notes, the extension `.haus` and a contact. `application/haus` (standards tree) needs an IETF document, as YAML's RFC 9512 did, so it waits for adoption. Optionally later: a `+haus` suffix (`application/vnd.acme.order+haus`), which has its own registry. Never `x-` names (RFC 6838, 6648). |
| ✅ | **A parser that keeps comments and formatting**: `parseDocument` records comment and value positions; the formatter places comments and blank lines. |

### 3.3 Later

| | Item |
|---|---|
| 🟡 | Language server: done (diagnostics, outline, hover with inferred types, formatting, schema inference). |
| ⬜ | **Tree-sitter grammar** (`tree-sitter-haus`), 2–4 days: `grammar.js` (~200 lines) with a small external scanner in C for nested block comments and block strings; the payload-on-the-same-line rule as an immediate token; `highlights.scm`, `folds.scm`, `indents.scm`; a test corpus from `test-suite/valid` (every file parses without error nodes; tree-sitter recovers from errors by design, so it won't reject every invalid file); schema files as a second small grammar or a dialect. `tree-sitter init` generates bindings for Node, Rust, Python, Go, Swift and C. There is no central registry: pull requests to nvim-treesitter and Helix, a Zed extension, a MELPA package for Emacs. GitHub highlighting goes through Linguist, which uses TextMate grammars and needs about 200 public repositories using the language, so it waits for adoption. |
| ⬜ | Code generation from `.schema.haus` (Roc, Go, Swift, …) |
| ⬜ | A binary encoding of the same data model |
| ✅ | Streaming in Roc (`Streaming`), and in Python |
| ✅ | Python: std/time checks, floats, schema files and schema decoding (`haus.schema`), passing the schema suite and fuzzed against Lean |

### 3.4 Agent readiness

Agents mostly write and read data, so what helps them most is a fast write → check → fix loop and knowing the traps a model trained on JSON falls into: no `null`, `True`/`False` are tags, a payload starts on its tag's line, `Maybe` is always written, `1.0` ≠ `1`. Everything here is a thin layer over TypeScript core.

Two parts. **For launch, everything runs on the user's machine**: the CLI and the skill are enough for the loop, and the data never leaves the machine. **MCP servers come later**: a local one only adds convenience over the CLI, and a public one receives whatever data agents send it, so it needs a security and privacy design of its own before it exists.

**Launch: local, data stays private**

| | Item |
|---|---|
| ✅ | **Cheat sheet and skill.** The cheat sheet is `docs/cheat-sheet.md` (about 1.6–1.9k tokens: syntax, the traps for JSON habits, schemas, the loop, JSON). The skill is `claude-plugin/skills/haus` (Agent Skills format: `SKILL.md`, a copy of the cheat sheet kept current by `claude-plugin/scripts/sync.ts --check` in CI, `schemas.md`, `json.md`), shipped as the Claude Code plugin `haus` from the repo's marketplace (`/plugin marketplace add betalyra/haus-fmt`, `/plugin install haus@haus-fmt`). It runs the CLI loop: `haus check --json`, fix by code and hint, `haus fmt`; tried end to end on the classic traps. |
| 🟡 | **llms.txt:** generated by `starlight-llms-txt` (`llms.txt`, `llms-full.txt`, `llms-small.txt`); the cheat sheet comes right after the welcome page. Open: the grammar and prelude (files, not pages), and serving each docs page as Markdown (`/docs/x.md`). |
| ✅ | **Errors agents can act on** (done: spec §17, 101 codes in `spec/errors.haus`, `docs/errors.md`, every binding and Lean, compared by the fuzzer): stable error codes (`payload-newline`) with a docs page each, expected and found, a concrete fix hint ("put the payload on the tag's line, or add a comma"), and errors as JSON. |
| 🟡 | **CLI** (built: `haus check`, `fmt`, `canonical`, `hash`, `completions`; open: the release setup, then `convert` and `query`): `check`, `fmt`, `canonical`, `hash`, then `convert` (after JSON interop) and a jq-like `query` using the path syntax from error messages. Agent-friendly: `--json` output, input from stdin, stable exit codes, no prompts, `check --fix` for safe repairs (formatting only). **In Rust** (a single static binary, no Node): crate `haus-fmt-cli`, command `haus`, on `haus-fmt` and a new `haus-fmt-schema` (schema files and a runtime checker, split out of `haus-fmt-build` so the CLI doesn't pull in the code generator). Needs first: a Rust formatter that keeps comments, byte-identical to the TypeScript one (shared suite `test-suite/format`), and the runtime schema checker (in the schema fuzzer as one more runner). Crates: `clap` (+ `clap_complete`), `annotate-snippets` for human output (`miette` later if needed), `ignore` for directories; `--json` through haus's own JSON writer; tests with `assert_cmd`, `predicates`, `insta`, `tempfile`. Released with `cargo-dist`: GitHub binaries, installers, a Homebrew tap and an npm package `@haus-fmt/cli` (so `npx` works). About 4–5 days. |
| 🟡 | **Editor hints:** a missing import of a standard or extension type is reported with the import to add, and a quick fix adds it. Done in VS Code; the same for other editors as they come. |
| ⬜ | **JSON Schema export** from haus schemas, after JSON interop. Anthropic's and OpenAI's structured outputs only take JSON Schema; with it, agents generate natively and convert to haus. Possibly also a constrained-generation grammar for local models (GBNF for llama.cpp, Outlines). |
| ✅ | **`AGENTS.md` snippet** for projects using haus, on the page `docs/using-agents.md` ("Using haus with agents", with the plugin, llms.txt and the loop; not named `agents.md`, which case-insensitive file systems read as `AGENTS.md`). Open: writing it from `haus init`. |
| ⬜ | **Eval:** how well models write and read haus compared with JSON (error rate per mistake, tokens). Shows which traps to address in the cheat sheet and error messages, and backs the token-efficiency claim with numbers. Can run with the benchmarks. |

Order for launch: cheat sheet, skill and llms.txt; error codes; CLI (`check`, `fmt`); then JSON Schema export and the eval.

**Later: MCP servers**

| | Item |
|---|---|
| ⬜ | **MCP server, local:** `npx @haus-fmt/mcp` over stdio, a thin layer over the CLI; data stays on the machine. Tools: `check` (syntax and schema, errors with fix hints), `format`, `validate` (decode with a schema type, §15), `infer_schema`, `canonical`/`hash` (also `hashAll`, `equals`), `explain` (what the value at a position means), then `convert` and `query`. Resources: spec sections, grammar, prelude, std/time profile and examples (`haus://spec/15`). Prompts: "convert this JSON to haus with a schema", "design a schema for …". A few days, when users ask for it. |
| ⬜ | **MCP server, public** (`mcp.haus-fmt.org`), only after a security and privacy design: agents send it whatever data they hold, often without the user noticing. Needed first: a threat model; stateless processing that never stores or logs payloads (only counts and error codes); a published privacy policy; text in, text out, never reading files or URLs (§9.2); strict input caps, the §7 limits and a time budget per request; rate limits per client and globally, abuse protection; isolation between requests; TLS only; dependency and deployment hardening; monitoring without content; a way to report vulnerabilities. Possibly docs-only tools first (spec lookup, cheat sheet), which receive no user data. Then listed in the official MCP Registry. |

### 3.5 1.0 readiness

Nothing is published yet, so everything can still change. After 1.0 the format only grows: what 1.0 settles is permanent.

| | Item |
|---|---|
| ✅ | **Versioning** (spec §10). Versions 0.x are drafts in which anything may change. From 1.0 on, minor versions only add and patch versions are editorial; there is never a breaking 2.0. A later version may make invalid text valid (new syntax, new schema constructs), never make valid text invalid, change what it means, or change what an existing schema accepts. Limits may only grow. No version header: files starting with `#` are reserved for the version directive of a breaking future version (`#haus 2`, required in every file of that version; a file without one is always 1.x), and parsers SHOULD say "needs a newer haus" for them. Optionally a `version` parameter on the MIME type. Implementations state the version they implement; the conformance suite is tagged per version. |
| ✅ | **Lean: `Extends old new`** (defined in `lean/Haus/Version.lean`, with reflexivity and transitivity), a conservative extension: every text the old version accepts, the new one accepts with the same values, and the canonical form and built-in rules agree on what the old version can express. Defined now, proven for each release. (That an old parser rejects new syntax already follows from soundness, B.) |
| ✅ | **Prelude, frozen at 1.0.** Done in the spec, the schema suite, TypeScript, Effect, Rust and Roc. Add `Secret a`: the same data as `a`; the host type hides the value (Effect `Redacted`, Rust and TypeScript wrappers whose printing and `toJSON` show `<redacted>`, Python like `SecretStr`), reading it takes an explicit call, and decode errors never echo it; the canonical form and hash are unchanged. A `Redacted` tag for redacted logs is left out for now. Add `Any`: any haus value, kept exactly as parsed and re-encoded unchanged, the explicit form of the unknown value (`payload: Any`). Not added: `Set` (haus equality isn't the host's, and sets have no canonical order; deduplicate in application code), `Nat`, `Uuid`/`Url`/`Email`, tuples, `NonEmpty`. `Map v` exists. Built-in types added after 1.0 go into standard modules, so they are opt-in through `import`. Each new type gets a §15 entry, schema suite cases, and support in every binding. |
| ✅ | **`@deprecated("message")`** (spec §14, all bindings, invalid-schema cases) on types, fields and tags in schema files, the only attribute. Tools warn where data uses it, and code generators emit the language's marker (`#[deprecated]`, JSDoc `@deprecated`, Python warnings); decoding doesn't change. The spec defines the list of attributes and the test an attribute must pass: it never affects which data is valid or what it decodes to; tools act on it mechanically, the same way in every language (documentation goes in comments); most target languages have a native counterpart. `@experimental` is the most plausible future candidate; `@since`, `@example`, `@min`, `@default` fail the test. Tools accept attributes they don't know, give them no meaning and warn about them; implementations never add their own. The schema checker produces resolved types without attributes, so decoding can't depend on them; the schema conformance runners check it by stripping all attributes and adding `@deprecated` everywhere, with identical results. |
| ⬜ | **Irreversible decisions, signed off:** prelude contents, default limits, equality and the canonical form, §15 (including the float spelling), the std/time profile, the schema language's semantics, and the JSON mapping if it ships with 1.0. Includes the audit's A2, B1, B5 and D1–D3 (§3.6). |
| ✅ | **Design and FAQ page (`docs/design.md`), including why there are no min/max validators**: haus describes shape; rules go into codecs (§13.4, they can reject more, never fewer), package profiles (§13.3) or the application; constraints for people go in comments. |
| ⬜ | **Governance document** (outside the spec): how changes are proposed and decided, the release process, tags and changelog. |
| ⬜ | **Final review pass** of the whole spec before the 1.0 tag, then tag the conformance suite, register `application/vnd.haus`, and announce. |

### 3.6 Spec and proof audit (2026-11-16)

An audit compared the Lean definitions with `grammar.ebnf`, §1–§16 and `std/time.md`. The theorem statements match the prose; no error in the Lean model. What it found in the prose, and what the proofs don't cover. Priority: A1, A2, B1, B2, then D1–D3, then the rest.

**A. Claims that are wrong as written**

| | Item |
|---|---|
| ✅ | **A1. §13.3 "Versions": the minor-version guarantee is false.** `{ id: 1, note: 5 }` is valid under open `{ id: Int }`; after a minor version adds `note?: String` it fails. Likewise `Foo(1)` as an unknown value becomes `wrong-payload` once `Foo String` is added. The guarantee holds only for data that uses the names the earlier version listed: reword it, or reserve unlisted names in open types for later versions. The table also leaves changes unclassified (adding a required field, optionality in either direction, adding to a closed type, changing a payload, opening a closed type): add "anything not listed as minor or patch is major". Ties in with the compat check in `plans/package-resolution.md`. |
| ✅ | **A2. §16.3 Reading: "a reader keeps a newer writer's case" doesn't hold end to end.** Resolution decided: §3.7 F5 and F7. Derived from `Json/Plain.lean` (`unknownJson`, the `none` branch of `readCore`), not run against the bindings. (1) Lossy: an unlisted case's members read without a schema, so an Int64, Decimal, Bytes or std/time value arrives as a string; value and hash differ. (2) No pass-through: the old reader writes it back as `{"_tag", "args": [lossless]}`, which the newer reader (record case, open) ignores and reports a missing field or drops data. (3) Positional misread: `Hexagon Int` writes `{"_tag":"Hexagon","value":6}`, read as `Hexagon { value: 6 }`. (4) `args` collision: a record case whose only field is `args: Array String` reads as positional. `plain_round_trip` and `plain_injective` stay true (same schema both ways). The mapping is frozen at 1.0, so decide before: at least say an unknown value from plain JSON is best effort and not to be forwarded as faithful; consider reserving `args`/`value`/`values`. |

**B. Rules that are imprecise or live only in code**

| | Item |
|---|---|
| ✅ | **B1.** `-0x0` and `-0b0` normalize to `0`, decimal `-0` stays `-0` (only in a comment at `Haus/Lexical.lean` `normalizeBody`). Changes canonical forms and hashes. State it in §2 and add a conformance case with its `.canonical`. |
| ✅ | **B2.** Block strings have no prose section; the EBNF comment (`grammar.ebnf` 74–81) is wrong: a whitespace-only line starting with the indent keeps the rest (indent 2, line of 6 spaces → 4 spaces), not "empty". Trailing whitespace is significant, so an editor that trims it changes the value and hash. Write the rules in prose, fix the comment, decide whether the formatter (§11) escapes trailing blanks or whitespace-only lines. |
| ⬜ | **B3.** `std/time.md` "every other value has exactly one spelling" is false for offsets: `Z` and `+00:00` both accepted. Add the caveat or reject one spelling. (`instant_same_iff` is stated correctly.) |
| ⬜ | **B4.** §8 doesn't say a BOM counts as column 1, nor what a line break is for line numbers (only in §1.2 S18 and the bindings). |
| ✅ | **B5.** Resolved by removing the threshold: the canonical form is always decimal (see B6), so it depends on no limit. |
| ✅ | **B6.** An integer too long for the canonical form can no longer arise: a hex literal has at most 829 hex digits (derived from the number limit, §7), so every parsed integer fits the limit in decimal, and the canonical form is always decimal and total (§12). Writers for a reader with limits report `number-too-long` for an integer whose decimal form exceeds them. |
| ⬜ | **B7.** `Tag ({ … })` in a schema: record case or positional case with one record argument? Different plain JSON. TypeScript decides at `schema-file.ts` (`c.args.length === 1 && first.t === "record"`). Specify it; add schema and JSON suite cases. |
| ⬜ | **B8.** §7: "MUST accept every input within these defaults" should say "by default", next to "MUST let users configure them". |

**C. What the proofs don't cover**

| | Item |
|---|---|
| ⬜ | **C1.** Schema files (§14) have no Lean model; types come from the TypeScript parser (`scripts/schema-types.ts`), so resolution, spreads, generics and guarded recursion are only compared between bindings. A reference schema-file checker is the piece behind I4 and I6 (`spec/lean/PLAN.md`). |
| ✅ | **C2.** Formatter (§11): specified in prose and by `test-suite/format` (65 inputs, byte for byte, with idempotence and the same values), which TypeScript and Rust run. But the expected files are written by the TypeScript formatter, nothing is fuzzed, and nothing is proven. Planned as phase L in [`lean/PLAN.md`](lean/PLAN.md): L1 fuzzing (values kept, idempotence, TypeScript and Rust identical bytes, comments kept); L2 the block-string rules in prose (B2), trailing blanks in block strings, and whether §10 lets the layouts change after 1.0; L3 a reference compact writer in Lean, proven to parse back, that every binding's serializer is fuzzed against; L4 block strings parse back; L5 pretty from values. The pretty layout with comments stays fuzzed only. Done: `node fuzz/src/main.ts --format` (TypeScript and Rust byte for byte in three layouts, the §11 properties, and the TypeScript, Rust and Roc value writers), in CI; about 240k documents found no bug. |
| ⬜ | **C3.** The model starts after UTF-8 decoding; invalid UTF-8 and SHA-256 are outside the proofs. Say so in `spec/lean/README.md` next to A5. |
| ⬜ | **C4.** Streams: the 64 Mi value limit and strict mode aren't modelled, so the same bytes can be accepted whole and rejected streamed. |
| ⬜ | **C5.** `Extends` (`Version.lean`) omits the JSON mappings, the hash, default limits and error codes, though §16 freezes the mappings. |
| ⬜ | **C6.** Linear time: phase P and I7, already in `spec/lean/PLAN.md`. |
| ⬜ | **C7.** `spec/lean/PLAN.md` phase 0 says 103/103 cases; the suite has 120. |

**D. Decisions before 1.0** (part of the irreversible decisions in §3.5, with B1, B5 and A2)

| | Item |
|---|---|
| ✅ | **D1.** U+2028 and U+2029 are written raw by every writer, canonical included. Python's `str.splitlines()` splits on them, which breaks §11's "a compact stream can be split by lines". Escape them or not, before the canonical form freezes. |
| ⬜ | **D2.** §7's duplicate-key check "must use hashing": require seeded (collision-resistant) hashing or an ordered structure, else crafted keys make it quadratic (the S2 class). |
| ⬜ | **D3.** Year `0000` is valid in std/time, but Python `datetime` and .NET `DateTime` can't hold it, and offsets can push an Instant outside 0000–9999 in UTC. Document that those can't be lossless default host types (§13.4), or narrow the range. |

**E. Extensions and profiles** (from the discussion after the audit; proof steps in [`lean/PLAN.md`](lean/PLAN.md), phase X)

| | Item |
|---|---|
| ⬜ | **E1. §13.3 says a profile "is defined by test vectors".** Vectors can't define a rule: two codecs can pass all of them (7 for `iso`, 6 for `wgs84`) and disagree on other values. Change §13.3: a profile is defined by its rule, written in prose and in Lean, and the vectors are examples of it. Today the rule is only a comment at the top of each `profiles/*.vectors.haus`. |
| ⬜ | **E2. A Lean definition and checker for each official profile** (`@haus-fmt/money/iso`, `@haus-fmt/geo/wgs84`), and every binding's codec fuzzed against it, as for std/time (X2, X3). |
| ⬜ | **E3. `wgs84` leaves questions open.** `LatLng` is two `Float64`s: is the range checked on the float after rounding (`LatLng(90.00000000000000001, 0)` rounds to 90) or on the literal? `Infinity` and `NegInfinity` have no vector (only `NaN`), nor has `-0`. Decide, write it in the rule, add vectors. |
| ⬜ | **E4. The codec contract of §13.4, proven once for any codec** (X1): it rejects more, never fewer; decode, encode, decode is decode; the value's meaning doesn't change. Each extension then gets the three laws without a proof of its own. |
| ⬜ | **E5. More proofs only where a profile claims something** (X4): one spelling per value (a canonical UUID), parsing that security depends on (`@haus-fmt/net`), exact numeric bounds. Registries are not formalised: a profile for assigned ISO 4217 codes would be a table generated from the list, and tested. Proofs are how the official packages are made, never a rule for schema packages (§13.3). |

Not planned: newtypes. A single-tag variant (`closed < UserId String >`) makes the type visible in the data, and a named alias (`type UserId = String`) can get a distinct host type through a codec. An optional codegen setting could emit distinct types for named aliases (a Rust newtype, a TypeScript branded type); that is tooling, not format.

### 3.7 JSON forms: decisions (2026-11-16)

Decided with Jan after the audit, because §16 freezes the mappings at 1.0. Implemented (2026-11-16) in §16, §17, the conformance suite, Lean (J8), TypeScript, Effect, Rust, Python and Roc, and fuzzed against Lean. Still open: the proofs J9 and J10 ([`lean/PLAN.md`](lean/PLAN.md)). Lean files named below were renamed: `Plain*.lean` → `SchemaBased*.lean`, `Lossless.lean` → `SelfDescribing.lean`, `plain_*` → `schemaBased_*`.

**Decided**

| | Decision | Why |
|---|---|---|
| ✅ | **F1. New names.** Lossless becomes **self-describing JSON** (CLI format `haus-json`). Plain becomes **schema-based JSON** (CLI format `json` with a schema). JSON without a schema becomes **JSON import** (`json` without a schema, reading only). Function names follow each binding, for example `toHausJson`/`fromHausJson`, `toJson(schema, …)`/`fromJson(schema, …)`, `importJson`. The codes `lossless-form` and `lossless-number` become `haus-json-form` and `haus-json-number`. | "Lossless" misleads: the schema-based form loses nothing of the decoded value either. "Plain" reads as "ordinary JSON", which is the import. The new names say what the reader needs. With `haus-json` as a format of its own the CLI needs no "form" option, and `--to json` without a schema is an error that names `--schema` and `haus-json`, never a guess. Codes freeze at 1.0 (§17). |
| ✅ | **F2. Underscore keys in the self-describing form:** `_tag`, `_args`, `_rec`, `_num`, `_bytes`. | One rule for both forms: a key that starts with `_` is haus's, never data. `tag` in one form and `_tag` in the other reads like a mistake. All five, not only the tag, or the form is mixed. The wrappers hold no keys of the data, so this is not needed technically: it is cosmetic, and possible only before 1.0. |
| ✅ | **F3. An envelope for self-describing JSON:** `{"_haus": 1, "_value": …}`, exactly these two members. `_haus` is the version of the form. Each line of JSON Lines is an envelope of its own. | A value can be a bare string or array, which is valid in both forms with different meanings (`"Shipped"` is a tag in schema-based JSON, a string in self-describing JSON), and nothing said which form a text is in. The envelope also carries the mapping's version (§16: a different mapping gets a new name). Lines stay independent for appending and tailing (as §6), at about 22 bytes each. |
| ✅ | **F4. A reader checks the form, it never chooses it from the data.** The caller says which form it expects. The self-describing reader requires the envelope; the schema-based reader and the import don't look for one. The CLI may detect the form as a convenience, with an option that overrides it. | If the data chose how it is read, whoever writes the data would choose, which haus avoids everywhere else (§9.6). A service that has the schema may accept both forms from one channel this way; both paths give the same decoded value (J10). |
| ✅ | **F5. `_args` in schema-based JSON.** An unknown value is written `{"_tag": T, "_args": […]}`, and a record payload with a field named `_args` has no schema-based form, like `_tag`. Resolves A2 (4). | `args` is the only member of the mapping with a reading rule of its own that is not reserved. A newer writer's `Run { args: [1, 2] }` makes an older reader reject the document, and `Run { args: ["a"] }` is misread as `Run("a")`, although a new tag in an open variant is a minor change (§13.3). `_args` blocks no field anyone uses, and it changes what is written today, so it can't wait for a later version. |
| ✅ | **F6. Control characters in JSON.** Every haus JSON writer escapes DEL, C1 and bidi controls as `\uXXXX`. The self-describing reader rejects them raw. The schema-based reader and the import accept them. | Written JSON then can't display differently from what it holds, as haus text can't (§4; today the writer escapes only below U+0020). Only haus tools write self-describing JSON, so a raw one there means a foreign or changed file. The other two read what other software wrote: `JSON.stringify` writes these characters raw, and pasted text often holds them, so rejecting would fail valid JSON. |
| ✅ | **F7. Which form when, in §16.** The party that knows least decides: everyone has the schema, schema-based; someone lacks it but uses haus and needs the exact values, self-describing; someone lacks it and wants ordinary JSON, schema-based, read with any JSON library. Schema-based JSON is not a pass-through format: read without its schema, ids, decimals, dates and bytes are strings and a variant is a record with a key `_tag`. Resolves A2 (1)–(3) as wording, stated as a property, not as "readers MUST NOT forward". | Two services over a queue or database that stores only JSON, one without the schema, is a case to support, and self-describing JSON already does. A "MUST NOT forward" can't be tested, and a proxy can't obey it. |

**Kept as it is**

- **A closed variant whose tags have no payload is a string; every other variant an object with `_tag`.** Considered: every case without a payload as a string. Rejected: one variant would mix strings and objects, a consumer could no longer switch on `_tag`, and a tag member is common in JSON anyway.
- **A closed variant with one case keeps its `_tag`** (`UserId("u1")` is `{"_tag": "UserId", "value": "u1"}`). Considered: the payload alone. Rejected: it falls apart as soon as a case is added, and the type is no longer visible.
- **std/time values are strings** in schema-based JSON, not `{"_tag": "Date", …}`. They are built-in types and get JSON's usual form, like `Decimal`, `Bytes`, `Bool` and `Maybe`; the schema already says the field is a date.
- **Three forms, not one.** JSON has no kind for bytes, variants or exact numbers. Wrapping them (self-describing) rejects ordinary JSON; wrapping nothing (import) can't write them; a schema (schema-based) gives natural JSON only for data that has one. Merging the first two would put numbers back as bare JSON numbers, which JSON tools rewrite.
- **`value` and `values`** for positional arguments.

**After 1.0** (additions that break nothing)

- **A configurable name for the tag member** (`type`, `kind`, …): an option of the converter, not of the schema (§14: attributes never change how data is read), default `_tag`, any name but `value`, `values` and `_args`. With it, a check when the converter is built that no record payload has a field of that name: with `type` that will happen (`Person { name, age, type }`). The proofs then hold for every name with that side condition.
- **A writer that mirrors the import.** The import is one way. The use is weak, and an application that holds a haus value knows which JSON it wants.
- **`.haus.json` and `application/vnd.haus+json`** for the self-describing form: decide with [`plans/mime-type.md`](../plans/mime-type.md).

### 3.8 Layouts: decisions (2026-11-16)

Decided with Jan. Implemented (2026-11-16): §11, §12, the TypeScript and Rust formatters, the CLI (`--layout`, `--drop-comments`), Roc's encoder, the VS Code extension, and `NAME.minimised` suite files. Steps: [`lean/PLAN.md`](lean/PLAN.md), phase L.

Four forms of the same values, each with one job:

| | Comments | Key order | Spellings (`0xFF`) | Whitespace | For |
|---|---|---|---|---|---|
| **Pretty** | kept | as written | as written | one entry per line | people who edit |
| **Compact** | dropped | as written | as written | spaces, one item per line | logs and streams people look at |
| **Minimised** (new) | dropped | as written | as written | none between tokens, one item per line | the wire and storage |
| **Canonical** (§12) | dropped | sorted | normalized | none | hashing, signing, comparing |

| | Decision | Why |
|---|---|---|
| ✅ | **G1. A third layout, minimised:** the compact layout without the whitespace between tokens, and nothing else different. One item per line, each followed by `,`. | Compact's spaces cost about 2 bytes a field and 3 a container, 15–20% of a small record (`Person { name: "John", age: 30 }` is 33 bytes, `Person{name:"John",age:30}` 26), and there was no way to choose the small form. The canonical form is as small, but it sorts keys and rewrites numbers: minimise a file and format it pretty again, and the file is back, without its comments and blank lines; through the canonical form it comes back reordered. An encoder also needs no sort for each record. Defined as compact without spaces it is the same code path in every formatter, and in Lean it is the canonical writer without the key sort. The line break after each item costs a byte and keeps a stream splittable by lines and open to appending. |
| ✅ | **G2. Minimised leaves every literal as written:** digit separators (`1_000`), the case of hex digits, and the blanks inside a byte string (`x"9f86 d081"`). | They are spelling, like `0xFF`: grouping inside a literal. One rule without exceptions (whitespace between tokens goes, literals stay), and G1's "the file is back" holds exactly. It costs bytes only in hand-written files; an encoder that writes values writes no blanks. |
| ✅ | **G3. Compact keeps its spaces.** | "One item per line, still readable" (§11) is what compact is for: logs are where people read it. The small form is G1. |
| ✅ | **G4. Compact and minimised drop every comment,** also those between top-level items. A tool that rewrites a file in place in one of them MUST refuse when the file has comments, unless an option says to drop them; writing to standard output or to another file needs no such check. | Keeping comments inside an item on one line is partly impossible: `// see */ here` has no block form, and a block comment over several lines can't stay on one line unchanged. Keeping only those between items makes little sense when the others go. The danger is the rewrite that can't be undone: in an editor, undo brings the comments back; a command that overwrites the file doesn't. It is a rule for tools, so the layouts' output and the format suite's compact files don't change. |
| ✅ | **G5. The canonical form and `hashAll` stay as they are:** no line breaks in the hashed text. | The hash is of the values, not of the text on the wire (§12), so a stream written with a line break after each value hashes the same already. Line breaks between values in the hashed text would lose nothing, after each value they would cost `hashAll([v]) = hash(v)`; neither is needed now that G1 is the small layout for streams. |
| ✅ | **G6. The docs and `haus hash` say it plainly: all four forms of the same data have the same hash.** | With two forms that look alike, people will hash the minimised text and expect the canonical hash. The sentence is true by design, since every form parses to the same values. What it rests on is that the formatters keep the values: proven for the canonical form, tested on the format suite's 65 files for the layouts, to be fuzzed (L1) and proven for the writers of values (L3). |

Decided for L2: compact and minimised never change after 1.0; pretty may change in a minor version (§10).

---

## 4. Use cases

| | Use case | Status / gap |
|---|---|---|
| ✅ | Config files | Comments, trailing commas, block strings, exact numbers, and a formatter that keeps comments. |
| 🟡 | API payloads | Sum types, exact money, open variants, schema-aware encoding and decoding. Missing: a MIME type. |
| ✅ | Event streams and logs | Comma-terminated values, open variants, size limit per value, truncation detection, in every binding. |
| ✅ | Partial updates (PATCH) | A record of optional fields: send only what changes; `x?: Maybe T` can also clear (D3, spec §1.1). |
| ✅ | Signed or hashed documents | Sign the exact bytes, or the canonical form (spec §12): `hash` in TypeScript, Rust and Python. A signing convention is planned (`plans/canonical-form.md`, F5). |
| 🟡 | Tabular data | Works, but repeats every key. Acceptable with compression. |
| 🟡 | Scientific and ML numbers | `NaN`/`Infinity` done (D5). Large numeric arrays are inefficient as text. |
| 🟡 | Binary blobs | `x"…"` byte strings, in hex: readable, but twice the size of the bytes. Fine for small blobs. |
| — | Graphs, shared references | Excluded by design (security). Use ids. |
| ✅ | Dictionaries, binary data | `Map v` over records, bytes as `x"…"` (D4). |

---

**Open from JSON (§16):** Roc assumes a `Maybe` of a type from a schema package uses `null`, generates JSON functions only with `haus-gen roc --json` (so that the checked-in extension code stays unchanged), and checks the depth of plain JSON read with a generic type only through a concrete alias. Lean proves that the JSON text reader reads back what the writer writes, for exactly the JSON it returns, and the same for JSON Lines (`JSON.parse_write_iff`, `JSON.parseLines_writeLines`), and that the lossless and plain JSON of a value within the haus limits is well formed and within the JSON limits (`lossless_fits`, `toJson_wellFormed`, `toJson_fits`), when the limits leave room for the forms' member names and numbers (plain JSON needs `maxNumberLength` ≥ 22: a float spelled as a 21-digit integer is a JSON number token, while haus may count its shorter hex form); the defaults do.

**Open from error codes (§17):** Lean's JSON readers report codes (the JSON category's, and the decoder's where plain reading decodes), and the JSON fuzzer compares them with every binding's, but only where the places agree: Lean gives no positions in JSON text and no places inside lossless or schemaless JSON, so all of those errors are at `$`, and an input with several mistakes in its text counts as one place there (the reference labels number characters like `9e9999e` as a reader that reads the number first would: `exponent-too-large`). Positions in JSON text in the reference would make this exact.

**Open from the 1.0 spec changes:** an encode error inside a `Secret` that holds an `Any` can name a map key in its path in Roc, whose writer checks raw values without knowing the type (§15 now covers encoding too). Roc encoders recurse over native values, so a native value nested millions of levels deep overflows the stack before the writer's depth check.

## 5. Remaining order

Done: the 1.0 spec changes (versions, `Any`, `Secret a`, `@deprecated`) in every binding; proof phases I1–I3 and I5 (a Lean reference decoder that passes the schema suite in CI; the round trip proven, the float law included); lossless default host types everywhere (§13.4); schema decoding fuzzed in CI across Lean, TypeScript, Effect, Rust, Roc and Python; Python parity; the Roc gaps (`hash`/`hashAll` with `Crypto.SHA256`, configurable limits, the stream module renamed `Streaming` to avoid Roc's builtin `Stream`).

**Current order** (2026-11-16, after the audit, §3.6–§3.7); the numbered items below give the details:

1. The audit's wrong claims: A1 ✅; A2 as the JSON forms of §3.7 (F1–F7, Lean J8), in progress.
2. The rules that change hashes or the formatter: B1, B2 with the formatter prose (`lean/PLAN.md` L2), B5, B6, D1, and the minimised layout (§3.8 G1–G6: §11 and §12, the TypeScript and Rust formatters, `NAME.minimised` suite files). Decide in L2 whether §10 lets layouts change after 1.0.
3. Fuzzing the formatters (L1, audit C2).
4. Packages before the first publish (`plans/package-resolution.md`): the TypeScript symlink fix, transitive lookup, the `package-version` check, the open decisions D1–D11 (decided 2026-11-17 and implemented: spec §13.3 in three levels, codes `undeclared-package`, `package-manifest`, `package-version`, `codec-unreachable`, the `test-suite/packages` suite in TS, Python, Rust and through the Rust and Roc generators; the Rust build and Roc on `haus-fmt-schema`'s loader; the `// schema:` comment dropped). Next: the security review of the code. On the backlog: the CLI and editor finding Cargo and Python packages themselves (D11), Python entry points (D8), `haus package check`, the codec closure (D4).
5. Release setup and v0.1 to claim the names.
6. The rest of the audit (B3, B4, B7, B8, D2, D3) and small items: record-payload error paths, Roc's `@major`, llms.txt, Open VSX.
   Also a **project file for tools** (decided 2026-11-17; the `// schema:` comment in data files was dropped, because comments carry no meaning, the minimised layout drops them, and a data file must not choose what tools read). A `haus.config.haus` at the project root, read by the CLI, the VS Code server and agents, never by parsers: globs to schemas (`{ files: "config/*.haus", schema: "./config.schema.haus#Config" }`) and folders of packages (like `--packages`), so `haus check` works in Cargo and Python projects without flags. Paths relative and inside the project. Plus a way for the import plugin to name a data file's schema in the import (an import attribute). Not in the spec; tools only.
   Also a **value diff**: `diff(a, b)` and `diffDocuments(textA, textB)` in the TypeScript library (changes with paths, kinds, old and new values, and the ranges in both texts; arrays aligned by a longest common subsequence of equal values; haus equality, so layout, comments, key order and spellings never count), then the website's compare tool highlights them (the website session), and later `haus diff` in the CLI from a Rust port, with a git diff driver. Not needed for 1.0; nice for the launch, since the tools page today only says whether values differ.
7. Extensions (item 3 below), with X1–X3 first.
8. The Go binding (item 4).
9. Benchmarks and the eval.
10. The 1.0 release (item 5). After 1.0: L3–L5, I4, I6, I7 and P (item 6).

1. **Media type `application/vnd.haus`:** the registration is drafted in `plans/mime-type.md` (the template, four decisions to make, a checklist); it is submitted with the 1.0 release, when the spec has a stable URL.
2. **Agent readiness, launch part** (§3.4): cheat sheet, skill, llms.txt contents, error codes with fix hints, the Design and FAQ page (`docs/design.md`), including why there are no min/max validators, CLI `check` and `fmt`.
3. **Extensions for launch.** Versioned on their own (§13.3), so they don't block the spec, but the docs already show `Money(19.90, EUR)`.
   - ✅ **Done: one name, `@haus-fmt`.** The `haus` names can't be had (npm, crates.io, PyPI); the `@haus-fmt` npm and GitHub orgs and the `haus-fmt` crate and PyPI package are ours. Renamed `@haus/money` → `@haus-fmt/money`, `@haus/geo` → `@haus-fmt/geo` (spec §13.3 and type ids, manifests, the editor's hint table, the Rust and Python hints, generators: Roc `HausFmtMoney`, docs, examples, the website sample); crates `haus-money`, `haus-geo`, `haus-build` → `haus-fmt-money`, `haus-fmt-geo`, `haus-fmt-build` (code keeps `haus_build`, `haus_money`, `haus_geo` through `[lib] name`); PyPI `haus-fmt-money`, `haus-fmt-geo`. Done before 1.0, because type ids are permanent. Still to do: claim the free crates early, `haus-fmt-build` first. crates.io has no scopes yet; when open namespaces (RFC 3243) ship, only the owner of `haus-fmt` can publish `haus-fmt::money`, and the flat crates stay as re-exports.
   - `@haus-fmt/money` and `@haus-fmt/geo` release-ready: a Python package, codecs that implement the profiles (`iso`, `wgs84`) in every binding and pass the profile vectors, Effect support, a docs page each, publishing set up for npm, crates.io and PyPI.
   - One or two new packages whose rules a published grammar fixes, the types left out of the prelude: `@haus-fmt/id` (`Uuid`, maybe `Ulid`) and `@haus-fmt/net` (`Url`, `Email`, `IpAddr`), each with a profile and vectors.
   - The contract for implementers is each profile's rule, written in prose and in Lean; the vectors are examples of it (§3.6 E1). The shape is covered by the schema proofs (phase I) like any schema. Each profile gets a Lean reference checker so the fuzzer compares the bindings, as for std/time, and the codec contract of §13.4 is proven once for every codec (§3.6 E4). More proofs only where a profile claims something: a normal form (a canonical UUID spelling), parsing that security depends on, exact bounds (§3.6 E5). A new package's profile is written in Lean before its codecs.
   - After 1.0, as people ask: units and quantities, locales (language tags, countries), phone numbers.
4. **A Go binding** for launch: config files are the strongest use case and much infrastructure tooling is Go. Parser, formatter (the `test-suite/format` suite), canonical form and hash, JSON (§16), limits and error codes, the runtime schema checker (§15), a fuzz runner against Lean; codegen from schemas after 1.0. About 1–2 weeks. v1 then ships TypeScript, Effect, Rust, Python, Roc and Go.
5. **1.0 release** (§3.5): fix the audit's wrong claims and hash-affecting rules first (§3.6: A1, A2, B1, B2, then D1–D3), sign off the irreversible decisions, governance document, final review, tag the suite, register the MIME type, announce.
6. **After 1.0:** MCP servers, JSON Schema export, eval (§3.4); Tree-sitter and the editor pull requests; proof phases I4, I6, I7, P and L3–L5; Temporal codecs, codegen for more languages, a binary encoding; more bindings as people ask: Java/Kotlin, C#, Swift, and a C or WebAssembly interface to the Rust crate for the long tail. New bindings need no spec change: the tagged suite and the fuzzer show they conform.
7. **Dogfooding** (low priority, after the main packages are published). Config files other tools read stay as they are (`Cargo.toml`, `package.json`, `tsconfig.json`, `pyproject.toml`, `lakefile.toml`, CI YAML, VS Code's JSON); the suite, schemas, manifests, profile vectors and examples are haus already. To do:
   - the TextMate grammars (`editors/vscode/syntaxes/*.tmLanguage.json`) written in haus, regexes in block strings without doubled backslashes, converted to JSON in the extension's build (§16);
   - `spec/lean/schema-suite.json` and `json-suite.json` as `.haus`, read by the Lean reference parser itself;
   - CI: `haus check` and `haus fmt --check` over every `.haus` and `.schema.haus` file, and the extension manifests checked against a `Manifest` schema;
   - the website's samples and fixed data loaded from `.haus` files (for the website session).
