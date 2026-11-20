# haus vs JSON: benchmarks

A first, small benchmark of haus against JSON, in TypeScript:

1. **Size and tokens**: bytes and LLM tokens of the same documents as JSON and as haus.
2. **Speed**: parsing and writing with the TypeScript binding against `JSON.parse` and `JSON.stringify`.

The data is real, from seven sources in five categories, each measured and reported on its own (never averaged together, not even within a category):

| Category | Source | Documents | Schema |
|---|---|---|---|
| API responses | **`github-rest`** | every example response in GitHub's REST API description ([github/rest-api-description](https://github.com/github/rest-api-description), MIT) | generated from GitHub's OpenAPI 3.1 description |
| API responses | **`stripe`** | the example objects of Stripe's fixtures file ([stripe/openapi](https://github.com/stripe/openapi), MIT) | generated from Stripe's OpenAPI 3.0 description |
| Configuration | **`vega-lite`** | every example specification of [Vega-Lite](https://github.com/vega/vega-lite) (BSD-3-Clause) | generated from Vega-Lite's JSON Schema (draft-07) |
| Configuration | **`kubernetes`** | every YAML manifest of [kubernetes/examples](https://github.com/kubernetes/examples) (Apache-2.0), one document per YAML document | generated from the OpenAPI v3 description of Kubernetes v1.37.2 (Apache-2.0) |
| LLM tool calls | **`bfcl`** | the single-turn entries of the [Berkeley Function Calling Leaderboard](https://github.com/ShishirPatil/gorilla/tree/main/berkeley-function-call-leaderboard) (Apache-2.0): function definitions, question and expected call | **hand-written** (`schemas/bfcl.schema.haus`): BFCL has none |
| Events and logs | **`gh-archive`** | ~2,000 public GitHub events of one hour of [GH Archive](https://www.gharchive.org), stratified by event type; also measured as one stream (JSON Lines against a haus stream) | the event schemas of GitHub's OpenAPI description |
| Geo (number-heavy) | **`geojson`** | the 177 country features of Natural Earth's 1:110m admin-0 countries ([nvkelso/natural-earth-vector](https://github.com/nvkelso/natural-earth-vector), public domain) | the GeoJSON Feature JSON Schema ([geojson/schema](https://github.com/geojson/schema), MIT) |

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
| download | `pnpm --filter haus-bench fetch` | ~1 min (~140 MB, once) | `bench/.data/` |
| convert | `pnpm --filter haus-bench convert` | ~15 s | `bench/.out/<source>/corpus.json`, `<source>.schema.haus`, `<source>-strings.schema.haus`, `<source>.haus` |
| tokens | `pnpm --filter haus-bench tokens` | ~15 min (4 tokenizers × 7 sources; bfcl and gh-archive are most of it) | `bench/.out/<source>/tokens.json` |
| compress | `node main.node.ts compress` (from `bench/`) | ~3 min (brotli 11 is most of it) | `bench/.out/<source>/compression.json` |
| speed | `pnpm --filter haus-bench speed` | ~6 min (11 tasks × 2.5 s × 7 sources, and the checks before timing; `--quick` alone takes ~3 min) | `bench/.out/<source>/speed.json` |
| report | `pnpm --filter haus-bench report` | < 1 s | prints the tables; `bench/.out/results.md`, `bench/.out/results.haus` (one section, one record per source) |

`convert` and `speed` build `@haus-fmt/haus` and `@haus-fmt/effect` first: they measure the built `dist/`, which git ignores, so after switching branches an old build would otherwise be measured. When running `main.node.ts` directly (Bun, Deno), run `prepare-haus` first.

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

`<command>` is `fetch`, `convert`, `tokens`, `compress`, `speed`, `report`, `all` or `smoke` (`all` and `smoke` run `compress` after `tokens`). Downloads use Effect's fetch-based `HttpClient` on every runtime; `--use-env-proxy` makes Node's fetch use `HTTPS_PROXY` (Bun's and Deno's always do). `--expose-gc` lets the speed step collect garbage before each task (Bun always can). All three give the same conversions and token counts (checked on the smoke sample); compressed sizes differ a little, since each runtime has its own zlib, brotli and zstd builds (gzip by up to 2%, the others by less than 0.5%), so `compression.json` records the runtime; speed differs by engine (V8 for Node and Deno, JavaScriptCore for Bun), and the runtime is recorded in the results.

## Code

The steps are [Effect](https://effect.website) programs (Effect 4): services and layers for what they need, tagged errors for what can fail, Effect Schemas for the manifest and the results files. The conversion, the statistics and the tables are pure functions; Effect is at the edges (files, git, HTTP, the command line, errors).

| File | |
|---|---|
| `sources.haus` | the manifest: the corpus sources (repository, commit, license, category, the pinned files: a single file, or a whole directory or tree by the SHA-256 of its listing; a second repository for a schema kept apart, a file downloaded over HTTPS, a file of an npm package; and the converter rules a source turns on) and the tokenizers (Hub repository, revision, files and SHA-256s). Adding a tokenizer is one entry. Read with the haus Effect binding (`@haus-fmt/effect`) into an Effect Schema. |
| `main.node.ts`, `main.bun.ts` | the entries: the CLI with the runtime's platform layer |
| `src/cli.ts` | the commands and their flags (`effect/cli`) |
| `src/steps/fetch.ts` | downloads into `bench/.data/` and checks hashes: git (child process) for the corpora, `HttpClient` for GH Archive and the tokenizers (a few at a time), and the hash of the npm package file GeoJSON's schema comes from |
| `src/steps/convert.ts` | every document → haus (three forms), with the round trip checked |
| `src/steps/tokens.ts` | token counts with tokenizers.js, per document and of all documents as one stream |
| `src/steps/compress.ts`, `src/compress.ts` | compressed sizes: gzip, brotli, zstd (node:zlib), per document and as one stream |
| `src/steps/speed.ts` | tinybench: haus parse/decode/stringify against `JSON.parse`/`JSON.stringify` |
| `src/steps/report.ts` | the tables, as markdown and as `results.haus` |
| `src/openapi.ts` | OpenAPI 3.0/3.1 / JSON Schema → haus schema types, and the JSON ↔ haus mapping for those types |
| `src/hand.ts`, `schemas/bfcl.schema.haus` | a hand-written haus schema → the same types (for BFCL, which has no schema) |
| `src/corpus.ts` | the documents of each source (YAML 1.1 → JSON for Kubernetes, with `yaml` 2.9.1) |
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

### `kubernetes`: Kubernetes example manifests

Every `.yaml` and `.yml` file of [kubernetes/examples](https://github.com/kubernetes/examples) at commit `22934a040acbb0c0aa103023ccbd871507bf17f6` (2026-10-27), in every directory, `_archived/` included: 250 files, pinned together by the SHA-256 of their listing (paths below the repository's root). The schema is Kubernetes' own OpenAPI v3 description, `api/openapi-spec/v3/*_openapi.json` (65 files, one per API group and version) of [kubernetes/kubernetes](https://github.com/kubernetes/kubernetes) at tag **v1.37.2** (`c50e5395f1ae2d4a2c05f28fdcc38c0916cc1a32`, 2026-10-27), also pinned by a listing; the files are merged into one description (862 schemas; a schema in several files is the same in each but for its `x-kubernetes-group-version-kind` list).

YAML is read with [`yaml`](https://eemeli.org/yaml/) 2.9.1 (2026-09-11) as **YAML 1.1**, the way Kubernetes reads manifests (sigs.k8s.io/yaml, go-yaml): `0644` is octal (420), `yes` is a boolean. Each YAML document of a file is one JSON document (numbers as JavaScript writes them). Of 279 YAML documents, **240 documents, 0.09 MB of minified JSON**, are left; out:

| Left out | Documents |
|---|---:|
| an API version Kubernetes v1.37 doesn't serve any more (`extensions/v1beta1` DaemonSet, `policy/v1beta1` PodSecurityPolicy and PodDisruptionBudget, `storage.k8s.io/v1beta1` StorageClass, `admissionregistration.k8s.io/v1alpha1` InitializerConfiguration) | 12 |
| the same JSON as another document | 11 |
| a template, not YAML data (a map key `{{ x }}`) | 5 |
| a YAML error (a key twice in a map) | 5 |
| a custom resource without a schema (`monitoring.coreos.com/v1` ServiceMonitor ×3, PrometheusRule) | 4 |
| not a Kubernetes object (no `apiVersion` and `kind`: Cassandra's own config files) | 2 |

### `stripe`: Stripe's fixtures

`openapi/fixtures3.json` and `openapi/spec3.json` (the OpenAPI 3.0.0 description, 1,538 schemas) of [stripe/openapi](https://github.com/stripe/openapi) at tag v2590 (`af2d19d63ea42049abecf784482898c654ab42d5`, 2026-10-23). The fixtures file holds one example object per resource, `{ resources: { <component name>: object } }`; each is one document, of the component of its name (`customer` → `#/components/schemas/customer`). Of 181 fixtures, 6 have no component of that name (`reserve.hold`, `billing.alert_triggered`, …) and 2 repeat another's JSON: **173 documents, 0.12 MB of minified JSON**.

### `bfcl`: Berkeley Function Calling Leaderboard

The data files of [BFCL v4](https://github.com/ShishirPatil/gorilla/tree/main/berkeley-function-call-leaderboard) at commit `6ea57973c7a6097fd7c5915698c54c17c5b1b6c8` (2026-03-23): `bfcl_eval/data/*.json` (20 question files, JSON Lines despite the name) and `bfcl_eval/data/possible_answer/*.json` (16 answer files), each set pinned by a listing. One document is one entry of the ten single-turn categories (`simple_python`, `simple_java`, `simple_javascript`, `multiple`, `parallel`, `parallel_multiple` and the four `live_` ones): its `id`, `question` (the messages), `function` (the function definitions, each with a JSON Schema for its parameters) and, from the answer file, `ground_truth` (the expected calls, with every acceptable value of each argument): **2,501 documents, 5.7 MB of minified JSON**. Left out, 2,196 entries of the other categories, whose shape is another or that have no call: multi-turn (800: several turns, an initial state, calls as Python strings), irrelevance and relevance (1,140: no expected call), memory (155) and web search (100: no function definitions), and `format_sensitivity` (a list of ids).

BFCL has no schema for its files, so its schema is **written by hand**, [`schemas/bfcl.schema.haus`](schemas/bfcl.schema.haus), and labelled so: `Entry`, `Message` (role a closed variant `User | System | Assistant`, `"user"` in JSON), `Function`, `Parameters` and `Parameter` (the JSON Schema keywords BFCL uses; defaults, enum values and items as `Any`); the expected calls are `Array (Map (Map (Array Any)))`, since arguments are free-form. `src/hand.ts` turns it into the converter's types; the JSON mapping is the same as for generated schemas.

### `gh-archive`: GitHub events

One hour of [GH Archive](https://www.gharchive.org): `https://data.gharchive.org/2026-11-02-15.json.gz` (Monday 2 November 2026, 15:00–16:00 UTC; 4,994,332 bytes, pinned by SHA-256), 4,630 public events of 12 types (none of them `PushEvent` in this hour). GH Archive states no license for its files; the events are GitHub's public data, under GitHub's terms. The sample is **stratified by event type** with a seeded generator (mulberry32, seed 20261102): each type's share of 2,000, at least 20 (or all) of each, which gives **2,027 events, 9.8 MB of minified JSON** (PullRequestEvent 790, IssueCommentEvent 359, IssuesEvent 313, WatchEvent 135, ReleaseEvent 119, PullRequestReviewEvent 113, ForkEvent 22, MemberEvent 18, GollumEvent 12, CommitCommentEvent 11, DiscussionEvent 5, PublicEvent 4).

The schema is GitHub's `event` schema from the same description as `github-rest` (fetched again, into the source's own directory): the root is a closed variant by `type` (the tag is the event type, `IssuesEvent { … }`, and in JSON the member `type`), each case the event's fields with `payload` the description's component of that type (`IssuesEvent` → `issues-event`; the description has one for all 12 types). The documents are measured one by one and **as one stream**: JSON Lines against a haus stream (`type GhEvents = Stream GhEvent`, spec §6).

### `geojson`: Natural Earth countries

`geojson/ne_110m_admin_0_countries.geojson` of [nvkelso/natural-earth-vector](https://github.com/nvkelso/natural-earth-vector) at commit `ca96624a56bd078437bca8184e78163e5039ad19` (2022-06-02; Natural Earth is public domain): one document per feature, **177 documents, 0.84 MB of minified JSON**, almost all of it coordinates. The schema is the GeoJSON Feature JSON Schema of [geojson/schema](https://github.com/geojson/schema) (MIT) at tag 1.0.5. That repository holds only the JavaScript modules the JSON Schemas are built from (which this benchmark doesn't run), so the built `Feature.json` comes from the npm package `geojson-schema` 1.0.5, the same release: a dependency of `bench/` pinned exactly, its file also pinned by SHA-256 in `sources.haus`.

All repositories are fetched with git from github.com: a shallow, blob-less fetch of the pinned commit, then the files' blobs (for a directory, all of them in one request). The usual archive and raw URLs (`codeload.github.com`, `raw.githubusercontent.com`) were not reachable from the sandbox this benchmark was built in; git over github.com gives the same bytes, checked by the SHA-256s in the manifest. GH Archive's file comes over HTTPS from `data.gharchive.org`.

## From JSON to haus

Each document is measured in three haus forms, next to JSON minified (`JSON.stringify(v)`) and pretty (`JSON.stringify(v, null, 2)`), with numbers exactly as written in the source:

- **idiomatic** (the main form, "typed"): read with a schema generated from the source's own schema (an OpenAPI description, a JSON Schema), or for BFCL the hand-written one, enums as tags;
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

The const rule alone finds almost nothing to type in Vega-Lite (3 unions in the whole schema: `type: boxplot | errorbar | errorband`, the GeoJSON geometries, gradients). Its unions are mostly a value or an expression (`number | ExprRef`), or **records told apart by which keys they have**: the view compositions, the transforms, the data sources. The documents' root type, `TopLevelSpec`, is one of those (`anyOf` of unit, facet, layer, repeat, concat, vconcat and hconcat specs, told apart by keys like `layer` or `facet`). Without a rule for them, every Vega-Lite document was `Any`, its idiomatic form its plain form. So there is a second rule.

### Unions of records told apart by required keys

On for the JSON Schema sources and the new ones (`vega-lite`, `kubernetes`, `stripe`, `gh-archive`, `geojson`; `rules` in `sources.haus`), off for `github-rest`, like the const rule, so GitHub's numbers stay those it was first measured with.

- **When:** a `oneOf`/`anyOf` without a discriminator (and not told apart by a const) whose branches are all records once `$ref`s are followed, where each branch has a required key that no other branch declares, or else a set of required keys (all of its required keys) that no other branch declares all of. A branch that is itself a union of records is flattened into its records when that tells them all apart; otherwise it is one case, picked by the keys all its records require, with that union's type as its payload (Vega-Lite's `TopLevelRepeatSpec`, two repeat specs with the same keys, is such a case: `Repeat` with an `Any` payload).
- **Then:** a closed variant whose cases are the branches. The tag is the branch's definition name in PascalCase with the words every branch's name starts and ends with left out (`TopLevelUnitSpec`, `TopLevelLayerSpec`, … → `Unit`, `Layer`, …; `LookupData`, `LookupSelection` → `Data`, `Selection`), at least one word kept; an inline branch is named after its identifying key (`layer` → `Layer`). Where trimming makes two tags the same the full names are the tags; where those collide too, the union stays `Any` and is counted (none in Vega-Lite, 1 in GitHub's description).
- **In haus** the tag is written (`Layer { layer: [...] }`); **in JSON** it isn't: the round trip reads a JSON object as the one case whose identifying keys it has (none or several is a mismatch, and the document is excluded), and writes the case's payload alone, as the enum's tag → value map does for enums.
- **Otherwise `Any`, counted by what the union mixes:** records and other types (`string | ExprRef`: a value or an expression, the most common in Vega-Lite), only non-records (`string | number`), or records the keys don't tell apart.

| Unions without a discriminator | Vega-Lite, reachable | Vega-Lite, whole schema |
|---|---:|---:|
| **variant, told apart by required keys** | **8** | **39** |
| variant, told apart by a const property | 0 | 3 |
| `Any`: records and other types (`number \| ExprRef`) | 1,041 | 1,375 |
| `Any`: only non-records (`string \| number`) | 51 | 82 |
| `Any`: records not told apart by required keys | 30 | 40 |

(Reachable: each union converted once on the way from the documents' root type; whole schema: every definition converted. Converting a union's branches now reaches inline unions that an `Any` union used to hide, so these totals are larger than the old 1,506.)

The 8 reachable variants are `TopLevelSpec` (Unit 430 documents, Layer 114, VConcat 28, Repeat 20, HConcat 18, Facet 9, Concat 6), `Transform` (19 transforms by their key: `Aggregate { aggregate: … }`, `Calculate { calculate: …, as: … }`, `Filter { filter: … }`, …), `Spec` (the specs inside a composition), the layers of a layer spec (`LayerSpec`, `GenericUnitSpecEncodingAnyMark`: no common words to trim, so long tags), a facet's `spec`, and a lookup's `from` (`Data`, `Selection`). The data sources stay `Any`: `NamedData` requires only `name`, which the other sources declare too, so no key picks it.

**625 of 628 Vega-Lite documents round-trip; 3 are excluded** (`facet_*_future.vl.json`: their `spec` has none of the keys any spec case requires, specs for a future version of the schema).

**Typed or plain, for Vega-Lite:** see [Results](#results-typed-against-plain). The tags cost bytes and tokens (`Unit`, `Calculate`, `GenericUnitSpecEncodingAnyMark`), so does `Some(…)` for every present nullable field (190 `Maybe` types reachable; `data: Some { … }` in almost every document), and little is saved: enums as tags (`mark` is a `string | MarkDef` union, so `Any`, and stays `"bar"`).

**With the rule on, GitHub would change** (not measured that way; numbers from a run with the rule turned on): 13 more reachable unions become variants (29 in the whole description), 4 more documents are excluded (a now-typed user or team case misses its required `type`: 528 documents round-trip instead of 532), and on the 528 documents both runs measure, haus minimised is 494 bytes larger (783,529 against 783,035, +0.06%). With the const rule on too: 3 more variants, 438 bytes larger than measured.

### The other sources' schemas

- **Kubernetes.** A document's type is the schema whose `x-kubernetes-group-version-kind` names its `apiVersion` and `kind`. The root type is `Manifest`, a closed variant by `kind`: the tag is the kind (`Deployment { apiVersion: "apps/v1", metadata: { … }, spec: { … } }`), and in JSON the member `kind`, as a discriminator; `apiVersion` stays a field. It has one case per kind the documents use (21: Service 52, Pod 54, ReplicationController 34, Deployment 19, PersistentVolumeClaim 18, StorageClass 17, …; no kind comes in two API versions here, which would have been a skip, counted). Type names are the last part of the schema's name where that is unique (`io.k8s.api.apps.v1.Deployment` → `Deployment`, `ObjectMeta`), else with the group and version (`RbacV1Subject`; `MetaV1Time`, because `Time` is std/time's). **int-or-string** (`IntOrString`: `oneOf [integer, string]`, `format: int-or-string`) is `type IntOrString = Any`: haus has no untagged union, and `Any` keeps the value as written (`targetPort: 8080`, `targetPort: "http"`), where a tagged variant (`Port(8080)`, `Name("http")`) would add a tag to every port. **Quantity** (`oneOf [string, number]`) is `type Quantity = Any` for the same reason (`memory: "1Gi"`, `cpu: 1`; a `String` would reject the numbers YAML gives for `cpu: 1`). `Time` (date-time) is `Instant`. **239 of 240 documents round-trip**; 1 is excluded (`fc.lun: "0"`, a string where the schema says int32).
- **Stripe.** OpenAPI 3.0: `nullable: true` is `Maybe` (2,703 reachable `Maybe` types: Stripe writes `null` for most absent values, and each present one becomes `Some(…)`). Expandable fields, `anyOf [an id string, the object]`, are `Any` (321 unions mixing records and other types). The const rule finds 5 reachable variants (7 in the whole description) by the one-value enum `object` Stripe gives each resource; 74 unions of records stay `Any` (records whose keys don't tell them apart). **173 of 173 documents round-trip.**
- **GH Archive.** `event` with its typed payloads, as described above; with the rules on, 1 more union is a variant (by required keys) and 2 are `Any`. **1,901 of 2,027 events round-trip; 126 are excluded** because GitHub's description doesn't match the events: `payload.review.body` is `null` where the description says string (119), `payload.label` or `payload.assignee` is `null` where it says object (7).
- **GeoJSON.** `Feature.json` is the root (inline, so the type is named `Feature`): `type` is a one-tag enum (`type: Feature`), `geometry` a closed variant by `type` (the const rule: `Polygon { coordinates: … }`, `MultiPolygon { … }`, `GeometryCollection { geometries: … }`) inside `Maybe`, as `null` is allowed; coordinates are `Array Float64` nested 1 to 4 deep; `properties` is `Maybe (Map Any)` (`oneOf [null, object]`); `id` is `Any` (number or string). **177 of 177 documents round-trip**, every coordinate's digits as written.
- **BFCL.** Hand-written (above); its 52 members the schema doesn't list (rare JSON Schema keywords: `optional`, `format`, `maximum`, …) are kept as imported JSON. **2,501 of 2,501 documents round-trip.**

### The JSON mapping and the round trip

GitHub's JSON is not schema-based JSON (§16.3), so the conversion uses §16.3 with the reader options the plan names: an enum is its JSON string (by the tag → value map), integers are JSON numbers (§16.3 quotes `Int`), a discriminated union's tag is its discriminator member (`"user_view_type": "public"`) instead of `"_tag"`, and unlisted members are kept. `Any` maps as the import (§16.1) and back. With enums as strings, the enum part is exactly §16.3.

Every document must round-trip, in every form: the minimised, compact and pretty texts parse to the same haus value; it decodes with the compiled schema (`h.decode`); written back to JSON it **equals the original** (`equalsJson`: member order ignored, numbers compared by their exact text, strings exactly); the plain form maps back to the same JSON too. A document that fails is excluded from every number, and counted. One exception to "exact text": haus keeps a number's digits and scale but writes its exponent one way (spec §3: `1e-09` → `1e-9`, `1E5` → `1e5`), so numbers are compared in that normalized spelling where the exact text differs; 5 BFCL documents have such numbers (`1e-09`, `2e-09`), none of the other sources.

**532 of 619 GitHub documents round-trip; 87 are excluded**, because the example doesn't match GitHub's own schema for that response:

| Reason | Documents |
|---|---:|
| a `required` field is missing from the example | 63 |
| a value of another type than the schema says (string, number, object, array) | 16 |
| an `integer` written with a fraction (`budget_amount: 100.0`) | 3 |
| a discriminator value the union doesn't list | 3 |
| an enum value the schema doesn't list | 2 |

Excluding them keeps the comparison to documents that are valid against their schema; the lift rate (benchmarks plan §4.2) is 86%.

## Results: typed against plain

The full tables are in `bench/.out/results.md` after a run; this is the headline per source, from the run this README was written with (Node 26, M1 Max). Ratios are haus / JSON (below 1: haus is smaller); tokens are the average of the four tokenizers' total ratios; "typed / plain" is idiomatic haus against plain haus, what the schema's types cost (above 1) or save. Minimised haus against minified JSON; compressed: all documents as one stream, brotli 11 and gzip 6. Each source is its own population: the rows are not to be averaged.

| Category | Source | Documents | Bytes typed / JSON | Bytes plain / JSON | Tokens typed / JSON | Tokens plain / JSON | Tokens typed / plain | brotli 11 stream, typed / JSON | gzip 6 stream, typed / JSON |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| API responses | `github-rest` | 532 | 0.973 | 0.958 | 1.004 | 0.988 | 1.016 | 1.022 | 1.015 |
| API responses | `stripe` | 173 | 0.937 | 0.913 | 1.018 | 0.979 | 1.040 | 1.052 | 1.036 |
| Configuration | `vega-lite` | 625 | 0.945 | 0.890 | 1.024 | 0.978 | 1.047 | 1.016 | 1.006 |
| Configuration | `kubernetes` | 239 | 0.882 | 0.902 | 0.970 | 0.996 | 0.974 | 0.988 | 0.980 |
| LLM tool calls | `bfcl` | 2,501 | 0.948 | 0.949 | 0.983 | 0.983 | 0.999 | 0.997 | 0.992 |
| Events and logs | `gh-archive` (stream) | 1,901 | 0.976 | 0.963 | 1.003 | 0.991 | 1.012 | 1.001 | 1.001 |
| Geo | `geojson` | 177 | 0.997 | 0.997 | 1.001 | 1.000 | 1.001 | 1.001 | 1.000 |

What this says, source by source:

- **Vega-Lite, typed: it hurts.** With `TopLevelSpec`, the transforms and the specs typed, idiomatic haus is 5.5% smaller than JSON in bytes but **2.4% more tokens** (o200k 121,788 against 119,823; Gemma 4 +2.9%, Qwen 3.8 +3.9%, DeepSeek V4 +1.2%), where plain haus is 11% smaller in bytes and 2.2% fewer tokens. Typed against plain: +6.1% bytes, **+4.7% tokens**. The tags (`Unit`, `Layer`, `Calculate`, the long `GenericUnitSpecEncodingAnyMark`) and `Some(…)` around nullable fields (`data: Some { … }`) are what JSON doesn't write; the enums the schema types save little, since most of Vega-Lite's values are `Any` unions. Typing helps a reader (a decoder knows a `Layer` from a `Unit` by its tag), not the size.
- **Kubernetes, typed: it helps.** The root variant writes the kind as a tag and drops the member: `Deployment { apiVersion: "apps/v1", … }` against `{"apiVersion":"apps/v1","kind":"Deployment",…}`. Typed haus is 11.8% smaller in bytes, 3.0% fewer tokens than JSON, 2.6% fewer than plain haus; the only case here where the typed form wins on every measure, compressed too.
- **Stripe: the nullable fields cost.** 2,703 `Maybe` types: every present nullable value is `Some(…)`. Typed haus is 6% smaller in bytes but 1.8% more tokens than JSON; plain haus 2.1% fewer. Compressed, typed haus is 3.6% (gzip) to 5.2% (brotli 11) larger than JSON.
- **BFCL (hand-written schema):** typed and plain are the same within 0.1% (the only types that change the text are the role tags, `User` for `"user"`); haus is 5% smaller in bytes and 1.7% fewer tokens than JSON, mostly unquoted keys. Compressed: 0.3–1.8% smaller.
- **GH Archive, as a stream:** JSON Lines against a haus stream: typed +0.3% tokens, plain −0.9%; bytes −2.4% typed, −3.7% plain; compressed, the same as JSON within 0.5%. The `type` member becomes the tag (saved), but `created_at` is `Maybe Instant` (`Some(Instant("…"))` on every event) and the payload types bring more `Maybe`s.
- **GeoJSON, the expected worst case:** coordinates are numbers in both formats, written the same way; the only difference is the few keys and the geometry's `type`. Typed and plain are both within 0.3% of JSON in bytes and 0.1% in tokens, minified and compressed; pretty haus is worse: both put each coordinate on its own line, haus adds a comma after every last item, and typed haus nests the geometry one level deeper (`geometry: Some(\n    Polygon { … })`), so +0.6% bytes plain and +6.5% typed (tokens +0.6% typed).
- **GitHub** is unchanged from its first measurement: bytes and every tokenizer's counts are identical to before this rule and these sources were added.

Compression shrinks every difference: the stream ratios are all within about ±5% of JSON, the per-document ones within ±8%. haus's savings come from what a compressor removes anyway (quotes, repeated keys); its costs (tags, `Some`) are new bytes, which survive.

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

### The documents as one stream

Every source is also measured as one file of all its documents: **JSON Lines** (minified JSON, a line feed after each) against a **haus stream** (minimised, each item followed by `,` and a line feed: spec §6, §11), and the plain haus stream. Bytes, and tokens of the whole text with every tokenizer (a stream tokenizes a little differently from its documents one by one, at the separators). For `gh-archive` this is the main comparison: events travel and are stored as streams.

### Compressed

Over the wire, JSON is usually compressed. `compress` (`src/compress.ts`) measures, for minified JSON, minimised haus and plain haus (and the pretty forms), the bytes after **gzip** (levels 6 and 9), **brotli** (quality 4, as for dynamic responses, and 11, as for static files) and **zstd** (level 3), with the runtime's `node:zlib` (Node 26; Bun and Deno have the same functions): each document compressed alone (the sum over documents: small documents compress badly) and all documents as one stream (JSON Lines, a haus stream), since a large stream compresses very differently. Ratios are haus / JSON.

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

- **Examples, not traffic.** GitHub's and Stripe's documents are hand-written examples, small (a few hundred bytes to a few KB) and heavy in URLs and ids, which neither format can shorten; Vega-Lite's and Kubernetes' are examples too. Only `gh-archive` is traffic, and one hour of it. Tabular data is still to come (plan §4.1).
- **Seven sources, from 173 to 2,501 documents**, each reported on its own, never averaged together, not even within a category: enough for a first number per category, not "on average".
- **The schema decides the haus form.** A nullable field is `Maybe T`, so every present value is written `Some(…)` (in GitHub's corpus 1,110 times, about 6.7 KB; Stripe has 2,703 nullable types), dates are `Instant("…")` (703 times in GitHub's), and a union of records told apart by keys writes a tag JSON doesn't (Vega-Lite). These are what a schema author following the source's description writes; they cost bytes and tokens that the plain form doesn't pay, which is why plain haus is often smaller than idiomatic haus. Where the schema removes something JSON writes (Kubernetes' `kind`, GH Archive's `type`, enums' quotes), typed haus is smaller.
- **A hand-written schema** (BFCL) is one reasonable schema, not the only one; it types what is regular (messages, functions, parameter keywords) and leaves arguments and defaults `Any`.
- **Minimised vs compact.** Compact haus keeps a space after `:` and `,` and is larger than minified JSON; the like-for-like comparison is minimised haus against minified JSON.
- **Unlisted members** (388 in GitHub's corpus) are kept as imported JSON, so the haus text holds all of the document's data; a strict reader with a closed schema would reject these documents.
- **Speed**: pure-JS haus against the engine's native `JSON.parse`/`JSON.stringify`; one machine, wall-clock. Ratios measured in the same run are more stable than absolute numbers. The quick mode (`--quick`, used by `smoke`) is a harness check only.
- **Tokenizers are proxies** for what each provider bills, and tokenizers.js reproduces each tokenizer's regex closely but not perfectly in every edge case (see its README).
