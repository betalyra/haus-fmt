# haus vs JSON: benchmarks

A first, small benchmark of haus against JSON, in TypeScript:

1. **Size and tokens**: bytes and LLM tokens of the same documents as JSON and as haus.
2. **Speed**: parsing and writing with the TypeScript binding against `JSON.parse` and `JSON.stringify`.

The data is real, from two sources, each measured and reported on its own (never averaged together):

- **`github-rest`** (API responses): every example response in GitHub's REST API description ([github/rest-api-description](https://github.com/github/rest-api-description), MIT), converted to haus with a schema generated from GitHub's own OpenAPI 3.1 description.
- **`vega-lite`** (configuration and specs): every example specification of [Vega-Lite](https://github.com/vega/vega-lite) (`examples/specs/*.vl.json`, BSD-3-Clause), converted with a schema generated from Vega-Lite's own JSON Schema (`build/vega-lite-schema.json`, draft-07).

The plan behind it is in the maintainers' benchmark notes (§4.1, §4.2, §6, §11).

## Running it

From a fresh checkout, with Node 26 (TypeScript run by Node's type stripping) and pnpm, the versions CI uses:

```sh
cd typescript
pnpm install                          # the bench package is part of the workspace
pnpm --filter haus-bench all          # every step below, in order (about 2 minutes)
```

Or step by step:

| Step | Command (from `typescript/`) | Takes (M1 Max) | Writes |
|---|---|---|---|
| build the bindings | `pnpm --filter haus-bench prepare-haus` | ~10 s | `typescript/packages/{haus,effect}/dist/` |
| download | `pnpm --filter haus-bench fetch` | ~20 s (~100 MB, once) | `bench/.data/` |
| convert | `pnpm --filter haus-bench convert` | ~3 s | `bench/.out/<source>/corpus.json`, `<source>.schema.haus`, `<source>-strings.schema.haus`, `<source>.haus` |
| tokens | `pnpm --filter haus-bench tokens` | ~50 s (4 tokenizers × 2 sources) | `bench/.out/<source>/tokens.json` |
| speed | `pnpm --filter haus-bench speed` | ~60 s (11 tasks × 2.5 s × 2 sources) | `bench/.out/<source>/speed.json` |
| report | `pnpm --filter haus-bench report` | < 1 s | prints the tables; `bench/.out/results.md`, `bench/.out/results.haus` (one section, one record per source) |

`pnpm --filter haus-bench smoke` runs the whole pipeline on a sample (40 documents per source, one tokenizer, a 50 ms time budget per speed task) in a few seconds: it checks that every step works, and its numbers are not for publishing.

Options (`pnpm --filter haus-bench convert --limit 40`; `--help` on any command lists them):

- `--sources vega-lite` (convert, tokens, speed, report, all, smoke): only these sources (names from `sources.haus`, comma-separated).
- `convert --limit N`: a fixed sample of N documents per source (every k-th), instead of all.
- `tokens --tokenizers o200k,gemma4`: only these tokenizers (names from `sources.haus`).
- `speed --quick`: a 50 ms budget per task, to check the harness.
- `--data-dir DIR`, `--out-dir DIR` (or `HAUS_BENCH_DATA`, `HAUS_BENCH_OUT`): where downloads and results go (default `bench/.data/`, `bench/.out/`); `fetch --data-dir $TMPDIR/scratch` downloads everything from scratch.

Nothing large is committed: `bench/.data/` (downloads) and `bench/.out/` (results) are git-ignored. `fetch` downloads what `sources.haus` pins and checks every file's SHA-256; files already there with the right hash are kept.

### Node, Bun and Deno

One program, one thin entry per runtime; everything else is runtime-neutral (`src/`). The pnpm scripts use Node. From `bench/`, after `pnpm install` and `prepare-haus`:

| Runtime | Command | Platform layer |
|---|---|---|
| Node 26 | `node --use-env-proxy --expose-gc main.node.ts <command>` | `@effect/platform-node` (`NodeServices`, `NodeRuntime`) |
| Bun 1.4 | `bun main.bun.ts <command>` | `@effect/platform-bun` (`BunServices`, `BunRuntime`); garbage collection with `Bun.gc` |
| Deno 2.9 | `deno run -A --v8-flags=--expose-gc main.node.ts <command>` | the Node layer, through Deno's Node compatibility (no Deno-specific entry is needed) |

`<command>` is `fetch`, `convert`, `tokens`, `speed`, `report`, `all` or `smoke`. Downloads use Effect's fetch-based `HttpClient` on every runtime; `--use-env-proxy` makes Node's fetch use `HTTPS_PROXY` (Bun's and Deno's always do). `--expose-gc` lets the speed step collect garbage before each task (Bun always can). All three give the same conversions and token counts; speed differs by engine (V8 for Node and Deno, JavaScriptCore for Bun), and the runtime is recorded in the results.

## Code

The steps are [Effect](https://effect.website) programs (Effect 4): services and layers for what they need, tagged errors for what can fail, Effect Schemas for the manifest and the results files. The conversion, the statistics and the tables are pure functions; Effect is at the edges (files, git, HTTP, the command line, errors).

| File | |
|---|---|
| `sources.haus` | the manifest: the corpus sources (repository, commit, license, category, and the pinned files: a single file or a whole directory, by SHA-256) and the tokenizers (Hub repository, revision, files and SHA-256s). Adding a tokenizer is one entry. Read with the haus Effect binding (`@haus-fmt/effect`) into an Effect Schema. |
| `main.node.ts`, `main.bun.ts` | the entries: the CLI with the runtime's platform layer |
| `src/cli.ts` | the commands and their flags (`effect/cli`) |
| `src/steps/fetch.ts` | downloads into `bench/.data/` and checks hashes: git (child process) for the corpora, `HttpClient` for the tokenizers, a few at a time |
| `src/steps/convert.ts` | every document → haus (three forms), with the round trip checked |
| `src/steps/tokens.ts` | token counts with tokenizers.js |
| `src/steps/speed.ts` | tinybench: haus parse/decode/stringify against `JSON.parse`/`JSON.stringify` |
| `src/steps/report.ts` | the tables, as markdown and as `results.haus` |
| `src/openapi.ts` | OpenAPI 3.1 / JSON Schema → haus schema types, and the JSON ↔ haus mapping for those types |
| `src/corpus.ts` | the documents of each source |
| `src/manifest.ts`, `src/results.ts` | the manifest and results files, as Effect Schemas; the `Manifest` and `Results` services |
| `src/paths.ts`, `src/host.ts`, `src/sources.ts`, `src/listing.ts`, `src/stats.ts`, `src/errors.ts` | directories (`BenchPaths`), the machine and its garbage collector (`Host`), source selection, directory listings, statistics and tables, errors |

Services: `BenchPaths` (from `--data-dir`/`--out-dir`), `Manifest` (reads `sources.haus`), `Results` (reads and writes the results files, checked with their schemas), `Host` (provided by each entry); from the platform: `FileSystem`, `Path`, `Crypto` (SHA-256), `ChildProcessSpawner` (git), `HttpClient`. tinybench stays the timing engine: the timed functions are the plain library calls, built before the run, with no Effect inside them.

`pnpm --filter haus-bench typecheck` and `pnpm --filter haus-bench lint` (the Effect language service, `@effect/tsgo`) check the code.

## The corpora

### `github-rest`: GitHub's REST API examples

`descriptions-next/api.github.com/api.github.com.2026-03-10.json` (the OpenAPI 3.1 description, API version 2026-03-10) at commit `c9c95fe34ced05fe076001f5c55704742bc8e7f8` (2026-11-17).

Every example of a response with a JSON media type is one document: the examples under `content.<type>.examples`, inline or referenced from `components.examples`. Of 714 examples, 45 are not an object or array (empty or non-JSON bodies) and 50 repeat another example's JSON, which leaves **619 documents, 1.25 MB of minified JSON**.

### `vega-lite`: Vega-Lite's example specifications

`examples/specs/*.vl.json` (633 files, not the subdirectories) and `build/vega-lite-schema.json` at commit `e415f441845e198629f2049b46849ddcfdbf6596` (v6.5.0, 2026-10-08). Each file is one document, of the schema's root type (`TopLevelSpec`); 5 repeat another file's JSON, which leaves **628 documents, 0.40 MB of minified JSON**. The 633 files are pinned together by one SHA-256, of the listing `<name>\t<SHA-256 of the file>\n` sorted by name (written beside them as `specs.listing`).

Both repositories are fetched with git from github.com: a shallow, blob-less fetch of the pinned commit, then the files' blobs (for a directory, all of them in one request). The usual archive and raw URLs (`codeload.github.com`, `raw.githubusercontent.com`) were not reachable from the sandbox this benchmark was built in; git over github.com gives the same bytes, checked by the SHA-256s in the manifest.

## From JSON to haus

Each document is measured in three haus forms, next to JSON minified (`JSON.stringify(v)`) and pretty (`JSON.stringify(v, null, 2)`), with numbers exactly as written in the source:

- **idiomatic** (the main form): read with a schema generated from the source's own schema (GitHub's OpenAPI description, Vega-Lite's JSON Schema), enums as tags;
- **enums as strings**: the same schema with every enum a `String`, so enums map exactly as spec §16.3 says;
- **plain**: the JSON import of spec §16.1, without a schema (keys unquoted where they can be, `null` → `None`, `true` → `True`).

Each is written minimised (spec §11, `{a:1,b:[1,2]}`, the counterpart of minified JSON), compact (`{ a: 1, b: [1, 2] }`) and pretty (2 spaces, the counterpart of pretty JSON).

### The schema: OpenAPI → haus (`src/openapi.ts`)

The generated schema is `bench/.out/github-rest/github-rest.schema.haus` (enums as tags) and `github-rest-strings.schema.haus` (enums as strings). Rules, with how often each applied on the GitHub corpus (types reachable from the 619 documents' response types, each type once):

| OpenAPI / JSON Schema | haus | Count |
|---|---|---:|
| `components/schemas/<name>` | `type <PascalName> = …` (`pull-request-simple` → `PullRequestSimple`); a response's inline schema is named after its operation and status (`ReposGetContent200`) | |
| `$ref` | a reference to that name | |
| `properties` | a record; `field` if `required`, else `field?` | 1100 |
| members the description doesn't list | **kept**: records are open (haus's default), an unlisted member is the imported JSON (§16.1) and decoding ignores it. Closed records would reject 388 members in the examples. | 388 members |
| `additionalProperties` without `properties` | `Map v` (`Map Any` for a free-form object) | 33 (16 free-form) |
| `type: [T, "null"]`, `nullable`, an `anyOf`/`oneOf` branch `{type: null}` | `Maybe T` | 863 |
| string `enum` | a closed variant of tags, by a naming convention: `open` → `Open`, `in_progress` → `InProgress`, `read-only` → `ReadOnly`, `+1` → `Plus1`; a value that is already a tag stays (`OWNER`, `Bot`). Each enum keeps its tag → value map. An enum whose values would give the same tag twice stays `String` (none on this corpus). | 659 |
| `integer` / `number` / `boolean` / `string` | `Int` / `Float64` / `Bool` / `String` | 762 / 77 / 729 / 2933 |
| `format: date-time` / `date` | `Instant` / `Date` (std/time), or `String` where an example value at that type isn't valid RFC 3339 (none on this corpus) | 345 / 12 |
| `allOf` | a record; a referenced record is spread (`...Name`) when its fields are copied unchanged, merged otherwise; one branch alone is that branch | 5 records, 4 spreads |
| `oneOf`/`anyOf` with a `discriminator` | a closed variant: the discriminator's value is the tag (same convention), the branch's other fields its record payload | 3 |
| `oneOf`/`anyOf` without one (other than `T | null`) | `Any` | 32 + 17 |
| several types, no type, an `allOf` of non-records, a discriminated case that isn't a record | `Any` | 3 + 1 + 1 |
| | **`Any` in total** (reachable) | 70 |

### The schema: JSON Schema → haus (Vega-Lite)

The same rules, with `definitions/<name>` for `components/schemas/<name>` (`ConditionalValueDef<(number|ExprRef)>` → `ConditionalValueDefNumberExprRef`), and one more, for unions without an OpenAPI `discriminator`: a `oneOf`/`anyOf` of records with a property that every branch requires and gives one value (`const`, or a one-value `enum`), a different value in each branch, is a closed variant: that value is the tag (same naming convention and tag → value map as enums), the branch's other fields its record payload, and in JSON the tag is that property (`"type": "boxplot"`). The rule is off for GitHub, so its numbers stay those it was first measured with; turned on, it makes 3 more of GitHub's reachable unions variants (haus minimised 56 bytes smaller, the same 532 documents round-trip).

**What it finds in Vega-Lite: almost nothing to type.** The whole schema (all 468 definitions) has 1,506 unions without a discriminator, and the rule turns 3 of them into variants (`type: boxplot | errorbar | errorband`, the GeoJSON geometries by `type`, gradients by `gradient`); the rest are mostly a value or an expression (`number | ExprRef`), or records told apart by which keys they have (the transforms, the data sources, the view compositions). The documents' root type, `TopLevelSpec`, is such a union (`anyOf` of unit, layer, facet, repeat, concat, vconcat and hconcat specs, told apart by keys like `layer` or `facet`, not by a property's value), so it is `Any`, and **every Vega-Lite document is read as `Any`: its idiomatic and enums-as-strings forms are its plain form** (the report shows the same numbers for all three). Typing Vega-Lite would take a rule this benchmark doesn't have: unions of records told apart by a required key (a variant whose tag the JSON doesn't spell, chosen by the keys).

**628 of 628 Vega-Lite documents round-trip** (as `Any`, the import and back, numbers exact).

### The JSON mapping and the round trip

GitHub's JSON is not schema-based JSON (§16.3), so the conversion uses §16.3 with the reader options the plan names: an enum is its JSON string (by the tag → value map), integers are JSON numbers (§16.3 quotes `Int`), a discriminated union's tag is its discriminator member (`"user_view_type": "public"`) instead of `"_tag"`, and unlisted members are kept. `Any` maps as the import (§16.1) and back. With enums as strings, the enum part is exactly §16.3.

Every document must round-trip, in every form: the minimised, compact and pretty texts parse to the same haus value; it decodes with the compiled schema (`h.decode`); written back to JSON it **equals the original** (`equalsJson`: member order ignored, numbers compared by their exact text, strings exactly); the plain form maps back to the same JSON too. A document that fails is excluded from every number, and counted.

**532 of 619 GitHub documents round-trip; 87 are excluded**, because the example doesn't match GitHub's own schema for that response:

| Reason | Documents |
|---|---:|
| a `required` field is missing from the example | 63 |
| a value of another type than the schema says (string, number, object, array) | 16 |
| an `integer` written with a fraction (`budget_amount: 100.0`) | 3 |
| a discriminator value the union doesn't list | 3 |
| an enum value the schema doesn't list | 2 |

Excluding them keeps the comparison to documents that are valid against their schema; the lift rate (benchmarks plan §4.2) is 86%.

## Measurements

### Size and tokens

Per document and form: UTF-8 bytes, and tokens with [tokenizers.js](https://github.com/huggingface/tokenizers.js) (`@huggingface/tokenizers` 0.2.0) without special tokens. The report gives, for each comparison (haus form / JSON form) and tokenizer, the ratio of the totals (large documents weigh more), the median and geometric mean of the per-document ratios (each document weighs the same), the share of documents where haus is larger, and the average over the tokenizers.

| Name | Stands for | Hub repository | Revision | Vocabulary |
|---|---|---|---|---:|
| `o200k` | OpenAI GPT-4o and GPT-5.x (`o200k_base`; `o200k_harmony` only adds special tokens) | `Xenova/gpt-4o` | `7956d98f2a83b2751a98ea7136fdf7fe6cf54e69` | 200,000 |
| `gemma4` | Google Gemma 4, the closest public proxy for Gemini (whose tokenizer isn't published) | `google/gemma-4-31B-it` (same `tokenizer.json` as `gemma-4-26B-A4B-it`) | `842da3794eaa0b77d5f08bae87a17459d91ff475` | 262,144 |
| `qwen3.8` | Alibaba Qwen 3.8, the newest Qwen on the Hub with a `tokenizer.json` | `Qwen/Qwen3.8-27B` | `37561816e66b5b9153b1b64c10968c18c1e6f4a0` | 248,077 |
| `deepseek-v4` | DeepSeek V4 (same `tokenizer.json` as `DeepSeek-V4-Flash`) | `deepseek-ai/DeepSeek-V4-Pro-0813` | `72e1d3230f6c080a530b0a1d46f8eb4602340597` | 129,280 |

Not included:

- **Anthropic (Claude)**: Claude's tokenizer isn't public. The old Claude 1/2 tokenizer is not Claude's current one and is not used as a stand-in. Claude counts need Anthropic's token counting API: a later step, on a seeded sample.
- **Meta Llama 4, Mistral (Tekken), Moonshot Kimi**: left out of this first run to keep it small. Notes for adding them: `meta-llama/*` is gated (a login and accepted license), so it would need a faithful ungated copy such as `unsloth/Llama-4-Maverick-17B-128E-Instruct` (not verified against Meta's file, which can't be read without a login); `mistralai/Mistral-Large-4-1T-A52B` has a `tokenizer.json`; `moonshotai/Kimi-K3.1-Pro` ships only `tiktoken.model`, which tokenizers.js doesn't read.

### Speed (TypeScript)

[tinybench](https://github.com/tinylibs/tinybench) 6.2.3, garbage collected before each task (Node and Deno with `--expose-gc`, Bun with `Bun.gc`), warm-up on, 2 s per task after 0.5 s of warm-up, each source on its own. Inputs are the wire forms, minified JSON and minimised haus (idiomatic):

| Task | JSON | haus |
|---|---|---|
| parse | `JSON.parse` | `parse` / `parseAll`: text → `Value` tree, no schema |
| typed | | `h.parse(schema, text)`: parse and decode with the document's schema |
| write | `JSON.stringify` of the parsed JS value | `stringify` / `format` of the `Value` tree, minimised and compact |

Each runs on the **corpus** (one text: a JSON array, a haus stream) and **per document** (every document on its own; the time is for all of them). The report gives MB/s (against each format's own bytes), µs per document, ops/s, mean, p75 and p99, and the time relative to JSON for the same task and input.

Before timing, each pair is checked once: the haus text parses to a value that writes back to the same text, the typed decode succeeds, the haus stream reads as the same values as the documents, and `JSON.parse` → `JSON.stringify` gives the same text (where it doesn't, because a number can't be held exactly in a JS number, the count is reported). Every output is consumed into a checksum that is recorded. The machine, OS and runtime version are recorded in the results.

## Caveats

- **API examples, not traffic.** The examples are hand-written by GitHub's API team, small (median a few hundred bytes to a few KB) and heavy in URLs, which neither format can shorten. Other categories (events, configs, tool calls, tabular data) come later (plan §4.1).
- **Two sources, ~500 and ~600 documents.** Enough to test the pipeline and get a first number for API responses and for specs, not "on average"; each source is reported on its own.
- **Vega-Lite is read without a schema in effect** (its root type is `Any`, see above): its numbers are those of plain haus, and say nothing yet about a schema-typed form of specs.
- **The schema decides the haus form.** A nullable field is `Maybe T`, so every present value is written `Some(…)` (1,110 times in the corpus, about 6.7 KB), and dates are `Instant("…")` (703 times, about 6.3 KB). These are what a schema author following GitHub's description writes; they cost bytes and tokens that the plain form doesn't pay, which is why plain haus is smaller than idiomatic haus here.
- **Minimised vs compact.** Compact haus keeps a space after `:` and `,` and is larger than minified JSON; the like-for-like comparison is minimised haus against minified JSON.
- **Unlisted members** (388) are kept as imported JSON, so the haus text holds all of the document's data; a strict reader with a closed schema would reject these documents.
- **Speed**: pure-JS haus against the engine's native `JSON.parse`/`JSON.stringify`; one machine, wall-clock. Ratios measured in the same run are more stable than absolute numbers. The quick mode (`--quick`, used by `smoke`) is a harness check only.
- **Tokenizers are proxies** for what each provider bills, and tokenizers.js reproduces each tokenizer's regex closely but not perfectly in every edge case (see its README).
