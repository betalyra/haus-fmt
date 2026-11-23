/**
 * What the steps write to the results directory and read back, as Effect
 * Schemas: convert → corpus.json, tokens → tokens.json, compress →
 * compression.json, speed → speed-<lang>.json (every language, one shape).
 * The `Results` service reads and writes them as JSON, checked both ways.
 */
import { Context, Effect, FileSystem, Layer, Option, Path, Schema } from "effect"
import { MissingResultsError, ResultsFileError } from "./errors.ts"
import { BenchPaths } from "./paths.ts"

/** One document in every form that is measured. */
export const Converted = Schema.Struct({
  id: Schema.String,
  kind: Schema.String,
  /** The named type of the whole document, in both schema files. */
  root: Schema.String,
  json_min: Schema.String,
  json_pretty: Schema.String,
  /** Idiomatic haus, enums as tags. */
  haus_min: Schema.String,
  haus_compact: Schema.String,
  haus_pretty: Schema.String,
  /** The same with enums as strings. */
  str_min: Schema.String,
  str_pretty: Schema.String,
  /** Plain haus: the import, no schema. */
  plain_min: Schema.String,
  plain_pretty: Schema.String,
})
export type Converted = typeof Converted.Type

/** The forms of each document that are measured, in report order. */
export const FORMS = ["json_min", "json_pretty", "haus_min", "haus_compact", "haus_pretty", "str_min", "str_pretty", "plain_min", "plain_pretty"] as const satisfies readonly (keyof Converted)[]
export const Form = Schema.Literals(FORMS)
export type Form = typeof Form.Type

const Counts = Schema.Record(Schema.String, Schema.Finite)

export const Excluded = Schema.Struct({ id: Schema.String, reason: Schema.String, path: Schema.String })
export type Excluded = typeof Excluded.Type

export const CorpusOut = Schema.Struct({
  source: Schema.Struct({
    name: Schema.String,
    repo: Schema.String,
    commit: Schema.String,
    path: Schema.String,
    license: Schema.String,
    category: Schema.String,
    /** What a document is: "example responses", "specifications". */
    unit: Schema.String,
  }),
  /** Examples (files) in the source, documents found, and the sample taken (`--limit`). */
  examples: Schema.Finite,
  found: Schema.Finite,
  sample: Schema.optionalKey(Schema.Finite),
  skipped: Counts,
  documents: Schema.Array(Converted),
  excluded: Schema.Array(Excluded),
  schemas: Schema.Struct({ tags: Schema.String, strings: Schema.String }),
  /** Decisions the converter made, counted where they were made. */
  decisions: Counts,
  /** Types reachable from the documents' types, by what they are (each type once). */
  positions: Counts,
  /** The decisions when every named type of the schema is converted, reachable from the documents or not. */
  schemaWide: Counts,
  /** Members in the examples that the description doesn't list (kept, as imported JSON). */
  unlistedMembers: Schema.Finite,
  /** Documents with a number haus writes in its normalized spelling (`1e-09` → `1e-9`): the same number, other text. */
  respelledNumbers: Schema.optionalKey(Schema.Finite),
  notes: Schema.Array(Schema.String),
})
export type CorpusOut = typeof CorpusOut.Type

export const TokenizerInfo = Schema.Struct({
  name: Schema.String,
  family: Schema.String,
  repo: Schema.String,
  revision: Schema.String,
  vocab: Schema.Finite,
  seconds: Schema.Finite,
})
export type TokenizerInfo = typeof TokenizerInfo.Type

/** Tokens per document of each form. */
export const FormCounts = Schema.Record(Form, Schema.Array(Schema.Finite))
export type FormCounts = typeof FormCounts.Type

export const TokensOut = Schema.Struct({
  tokenizers: Schema.Array(TokenizerInfo),
  documents: Schema.Array(Schema.String),
  /** counts[tokenizer][form][i]: tokens of document i. */
  counts: Schema.Record(Schema.String, FormCounts),
  /** stream[tokenizer][form]: tokens of all documents as one stream (JSON Lines, a haus stream; compress.ts `streamText`). */
  stream: Schema.Record(Schema.String, Schema.Record(Schema.String, Schema.Finite)),
})
export type TokensOut = typeof TokensOut.Type

/** One form compressed (compress.ts): uncompressed bytes, and by codec the sum over documents and the stream. */
export const FormCompression = Schema.Struct({ bytes: Schema.Finite, streamBytes: Schema.Finite, perDoc: Counts, stream: Counts })

export const CompressionOut = Schema.Struct({
  /** The runtime (`navigator.userAgent`): its compressor builds decide the exact sizes. */
  runtime: Schema.String,
  codecs: Schema.Array(Schema.String),
  /** The documents compressed (ids, in order), to match the results to a convert run. */
  documents: Schema.Array(Schema.String),
  forms: Schema.Record(Schema.String, FormCompression),
})
export type CompressionOut = typeof CompressionOut.Type

export const SpeedRow = Schema.Struct({
  group: Schema.Literals(["parse", "typed", "write"]),
  input: Schema.Literals(["corpus", "per doc"]),
  /** What the task reads or writes: the JSON rows are the baseline of the haus rows of the same group and input. */
  format: Schema.Literals(["json", "haus"]),
  impl: Schema.String,
  /** Bytes read (parse, typed) or written (write) per iteration. */
  bytes: Schema.Finite,
  docs: Schema.Finite,
  hz: Schema.Finite,
  mean_ms: Schema.Finite,
  /** Quantiles over the samples: one call each in TypeScript (tinybench), the mean of a batch of calls in Rust (criterion). */
  p75_ms: Schema.Finite,
  p99_ms: Schema.Finite,
  samples: Schema.Finite,
  mb_s: Schema.Finite,
  us_per_doc: Schema.Finite,
  /** Allocations and bytes allocated per iteration, where the harness counts them (Go: testing's -benchmem; JVM: bytes only, JMH's gc profiler). */
  allocs: Schema.optionalKey(Schema.Finite),
  alloc_bytes: Schema.optionalKey(Schema.Finite),
})
export type SpeedRow = typeof SpeedRow.Type

export const Machine = Schema.Struct({
  cpu: Schema.String,
  cores: Schema.Finite,
  memory_gb: Schema.Finite,
  os: Schema.String,
  /** `node v26.13.1`, `bun 1.4.0`, `rustc 1.99.0 (…)`, `go1.27.4`, `java 25.0.1+8-LTS (…)`, `zig 0.17.1 (fast)`. */
  runtime: Schema.String,
  /** Garbage collected before each task (false where there is no collector: Rust; Go's testing collects before each run, JMH between iterations). */
  gc: Schema.Boolean,
})
export type Machine = typeof Machine.Type

/** The languages with a speed benchmark (bench/speed/<lang>/), in report order. */
export const LANGS = ["typescript", "rust", "go", "python", "jvm", "zig"] as const
export const Lang = Schema.Literals(LANGS)
export type Lang = typeof Lang.Type

/**
 * One language's speed results on one source, the same shape for every
 * language: speed-typescript.json (bench/speed/ts), speed-rust.json
 * (bench/speed/rust), speed-go.json (bench/speed/go), speed-python.json
 * (bench/speed/py), speed-jvm.json (bench/speed/jvm), speed-zig.json
 * (bench/speed/zig).
 */
export const SpeedOut = Schema.Struct({
  lang: Lang,
  /** The harness: `tinybench 6.2.3`, `criterion 0.8.2`, `testing.Benchmark (b.Loop)`, `JMH 1.37 (…)`. */
  harness: Schema.String,
  machine: Machine,
  options: Schema.Struct({ time_ms: Schema.Finite, warmup_ms: Schema.Finite, quick: Schema.Boolean }),
  /** The documents measured (ids, in order), to match the results to a convert run. */
  documents: Schema.Array(Schema.String),
  /**
   * Documents whose JSON doesn't come back as it was through the JSON
   * library's values: TypeScript, JSON.parse → JSON.stringify gives other
   * text (numbers a JS number can't hold exactly); Rust, serde_json's
   * `Value` writes another document (numbers in another spelling; serde_json
   * sorts members, which isn't counted); Go, the same with encoding/json
   * through `any` (numbers as float64); Python, json.loads → json.dumps
   * gives another document (numbers as float); JVM, the same with Jackson's
   * `JsonNode` tree (floating-point numbers as double).
   */
  jsonNotStable: Schema.Finite,
  /**
   * The checks of the JSON baselines of the typed tasks, built from the
   * source's JSON Schema. TypeScript: JSON.parse + a validator, a
   * schema-compiled JSON writer (bench/speed/ts/validators.ts). Go: Go types
   * generated from it, decoded and encoded by encoding/json and goccy/go-json
   * (bench/speed/go/cmd/jsontypes). Python: pydantic and msgspec, models
   * generated from it (bench/speed/py, models.py).
   */
  typedBaselines: Schema.optionalKey(Schema.Struct({
    /** The libraries and their versions. */
    versions: Schema.Record(Schema.String, Schema.String),
    /** Mutated documents every validator rejected, by kind of mutation (bench/speed/ts/mutate.ts, bench/speed/go/mutate.go; Python: bench/speed/py, mutate.py). */
    rejected: Schema.Record(Schema.String, Schema.Finite),
    /** Go: the mutated documents made, by kind (the Go types don't reject every one: TypeScript's validators must). */
    mutated: Schema.optionalKey(Schema.Record(Schema.String, Schema.Finite)),
    /** Documents whose typed haus write isn't the document's text: members in the schema's order, members it doesn't list dropped (decoding drops them). */
    typedWriteOtherText: Schema.Finite,
    /** Documents whose typed JSON write isn't the reference text: TypeScript, fast-json-stringify's against JSON.stringify's (members the schema doesn't list, member order); Go, encoding/json's write of the Go types against the document. */
    jsonWriterOtherText: Schema.Finite,
    /** Root types whose fast-json-stringify writer writes the variants by keys as JSON.stringify does: it can't build them (bench/speed/ts/validators.ts). */
    jsonWriterKeyedAsAny: Schema.optionalKey(Schema.Array(Schema.String)),
    /** Go: each library's typed round trip (decode into the Go types, encode), by what changes in documents (bench/speed/go/typed.go). */
    roundTrip: Schema.optionalKey(Schema.Record(Schema.String, Schema.Struct({
      numbersRounded: Schema.Finite,
      timesRespelled: Schema.Finite,
      nullsDropped: Schema.Finite,
      otherText: Schema.Finite,
    }))),
  })),
  rows: Schema.Array(SpeedRow),
  checksum: Schema.Finite,
})
export type SpeedOut = typeof SpeedOut.Type

/** A results file: its name in a source's results directory, its schema, and how it's indented. */
export interface ResultsFile<S extends Schema.Codec<any, any>> {
  readonly file: string
  readonly schema: S
  readonly indent?: number
}

export const CORPUS = { file: "corpus.json", schema: CorpusOut } as const satisfies ResultsFile<typeof CorpusOut>
export const TOKENS = { file: "tokens.json", schema: TokensOut } as const satisfies ResultsFile<typeof TokensOut>
/** A language's speed results: `speed-typescript.json`, `speed-rust.json`, `speed-go.json`, `speed-python.json`, `speed-jvm.json`, `speed-zig.json`. */
export const speedFile = (lang: Lang) => ({ file: `speed-${lang}.json`, schema: SpeedOut, indent: 2 }) as const satisfies ResultsFile<typeof SpeedOut>
export const COMPRESSION = { file: "compression.json", schema: CompressionOut, indent: 2 } as const satisfies ResultsFile<typeof CompressionOut>

/**
 * Reads and writes the results directory: each corpus source's results in
 * its own subdirectory (`<out>/<source>/corpus.json`), the report beside them.
 */
export class Results extends Context.Service<Results, {
  /** Fails with MissingResultsError (naming the step to run) when the file isn't there. */
  readonly read: <S extends Schema.Codec<any, any>>(source: string, f: ResultsFile<S>, step: string) => Effect.Effect<S["Type"], MissingResultsError | ResultsFileError>
  /** None when the file isn't there. */
  readonly readOptional: <S extends Schema.Codec<any, any>>(source: string, f: ResultsFile<S>) => Effect.Effect<Option.Option<S["Type"]>, ResultsFileError>
  readonly write: <S extends Schema.Codec<any, any>>(source: string, f: ResultsFile<S>, value: S["Type"]) => Effect.Effect<string, ResultsFileError>
  /** Writes a text file into the results directory (`["results.md"]`, `[source, file]`); returns its path. */
  readonly writeText: (segments: readonly string[], text: string) => Effect.Effect<string, ResultsFileError>
}>()("haus-bench/Results") {
  static readonly layer: Layer.Layer<Results, never, BenchPaths | FileSystem.FileSystem | Path.Path> = Layer.effect(
    Results,
    Effect.gen(function* () {
      const paths = yield* BenchPaths
      const fs = yield* FileSystem.FileSystem
      const p = yield* Path.Path
      const fileError = (path: string) => (e: { readonly message: string }) => Effect.fail(new ResultsFileError({ path, message: e.message }))

      const decode = <S extends Schema.Codec<any, any>>(f: ResultsFile<S>, path: string, text: string) =>
        Schema.decodeEffect(Schema.fromJsonString(f.schema))(text).pipe(
          Effect.catchTag("SchemaError", fileError(path)),
        ) as Effect.Effect<S["Type"], ResultsFileError>

      const readOptional = <S extends Schema.Codec<any, any>>(source: string, f: ResultsFile<S>) => {
        const path = paths.outFile(source, f.file)
        return fs.exists(path).pipe(
          Effect.flatMap((exists) =>
            exists ? fs.readFileString(path).pipe(Effect.flatMap((text) => decode(f, path, text)), Effect.asSome) : Effect.succeedNone,
          ),
          Effect.catchTag("PlatformError", fileError(path)),
        )
      }

      const read = <S extends Schema.Codec<any, any>>(source: string, f: ResultsFile<S>, step: string) =>
        readOptional(source, f).pipe(
          Effect.flatMap(
            Option.match({
              onNone: () => Effect.fail(new MissingResultsError({ path: paths.outFile(source, f.file), message: `no ${source}/${f.file}: run ${step} first` })),
              onSome: (value) => Effect.succeed(value as S["Type"]),
            }),
          ),
        )

      const writeText = (segments: readonly string[], text: string) => {
        const path = paths.outFile(...segments)
        return fs.makeDirectory(p.dirname(path), { recursive: true }).pipe(
          Effect.andThen(fs.writeFileString(path, text)),
          Effect.as(path),
          Effect.catchTag("PlatformError", fileError(path)),
        )
      }

      const write = <S extends Schema.Codec<any, any>>(source: string, f: ResultsFile<S>, value: S["Type"]) =>
        Schema.encodeEffect(f.schema)(value).pipe(
          Effect.catchTag("SchemaError", fileError(paths.outFile(source, f.file))),
          Effect.flatMap((encoded) => writeText([source, f.file], JSON.stringify(encoded, null, f.indent))),
        )

      return Results.of({ read, readOptional, write, writeText })
    }),
  )
}
