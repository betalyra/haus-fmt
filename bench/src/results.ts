/**
 * What the steps write to the results directory and read back, as Effect
 * Schemas: convert → corpus.json, tokens → tokens.json, speed → speed.json.
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
})
export type TokensOut = typeof TokensOut.Type

export const SpeedRow = Schema.Struct({
  group: Schema.Literals(["parse", "typed", "write"]),
  input: Schema.Literals(["corpus", "per doc"]),
  impl: Schema.String,
  /** Bytes read (parse, typed) or written (write) per iteration. */
  bytes: Schema.Finite,
  docs: Schema.Finite,
  hz: Schema.Finite,
  mean_ms: Schema.Finite,
  p75_ms: Schema.Finite,
  p99_ms: Schema.Finite,
  samples: Schema.Finite,
  mb_s: Schema.Finite,
  us_per_doc: Schema.Finite,
})
export type SpeedRow = typeof SpeedRow.Type

export const Machine = Schema.Struct({
  cpu: Schema.String,
  cores: Schema.Finite,
  memory_gb: Schema.Finite,
  os: Schema.String,
  runtime: Schema.String,
  gc: Schema.Boolean,
})
export type Machine = typeof Machine.Type

export const SpeedOut = Schema.Struct({
  machine: Machine,
  options: Schema.Struct({ time_ms: Schema.Finite, warmup_ms: Schema.Finite, quick: Schema.Boolean }),
  /** The documents measured (ids, in order), to match the results to a convert run. */
  documents: Schema.Array(Schema.String),
  /** Documents whose JSON.parse → JSON.stringify doesn't give the same text (numbers JS can't hold exactly). */
  jsonNotStable: Schema.Finite,
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
export const SPEED = { file: "speed.json", schema: SpeedOut, indent: 2 } as const satisfies ResultsFile<typeof SpeedOut>

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
