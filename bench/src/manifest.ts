/**
 * The manifest, `sources.haus`: what the benchmark reads, pinned. Read with
 * the haus Effect binding into an Effect Schema.
 */
import * as Haus from "@haus-fmt/effect"
import { Context, Effect, FileSystem, Layer, Schema } from "effect"
import { ManifestError } from "./errors.ts"
import { BenchPaths } from "./paths.ts"

const Sha256 = Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/, { expected: "a SHA-256 in lowercase hex" }))

export const Category = Schema.Literals(["ApiResponses", "Config", "Events", "ToolCalls", "Tabular", "Geo"])

/** One file of a repository, pinned by its SHA-256. */
export const PinnedFile = Schema.Struct({ path: Schema.String, sha256: Sha256 })
export type PinnedFile = typeof PinnedFile.Type

/**
 * Every file in a directory whose name ends in `suffix` (not in
 * subdirectories). `sha256` pins them all: the SHA-256 of the listing
 * `<name>\t<SHA-256 of the file>\n`, sorted by name (see `listingHash`).
 */
export const PinnedFiles = Schema.Struct({ dir: Schema.String, suffix: Schema.String, count: Schema.Int, sha256: Sha256 })
export type PinnedFiles = typeof PinnedFiles.Type

/** What the documents are, and how to read them. */
export const Layout = Schema.Union([
  /** The example responses of an OpenAPI description, each with its response's schema. */
  Schema.TaggedStruct("OpenApiExamples", { description: PinnedFile }),
  /** One JSON document per file, all of the type at the JSON Schema's root `$ref`. */
  Schema.TaggedStruct("JsonSchemaDocuments", { schema: PinnedFile, documents: PinnedFiles }),
])
export type Layout = typeof Layout.Type

export const CorpusSource = Schema.Struct({
  name: Schema.String,
  title: Schema.String,
  category: Category,
  license: Schema.String,
  repo: Schema.String,
  commit: Schema.String,
  committed: Haus.Instant,
  layout: Layout,
})
export type CorpusSource = typeof CorpusSource.Type

/** The source's main path, for listings: the description, or the documents' pattern. */
export const sourcePath = (s: CorpusSource): string =>
  s.layout._tag === "OpenApiExamples" ? s.layout.description.path : `${s.layout.documents.dir}/*${s.layout.documents.suffix}`

export const TokenizerFile = Schema.Struct({ file: Schema.String, sha256: Sha256 })
export type TokenizerFile = typeof TokenizerFile.Type

export const TokenizerSource = Schema.Struct({
  name: Schema.String,
  family: Schema.String,
  repo: Schema.String,
  revision: Schema.String,
  files: Schema.Array(TokenizerFile),
})
export type TokenizerSource = typeof TokenizerSource.Type

export const ManifestSchema = Schema.Struct({
  corpus: Schema.Array(CorpusSource),
  tokenizers: Schema.Array(TokenizerSource),
})
export type ManifestShape = typeof ManifestSchema.Type

const decodeManifest = Haus.decode(ManifestSchema)

export class Manifest extends Context.Service<Manifest, ManifestShape>()("haus-bench/Manifest") {
  static readonly layer: Layer.Layer<Manifest, ManifestError, BenchPaths | FileSystem.FileSystem> = Layer.effect(
    Manifest,
    Effect.gen(function* () {
      const { manifest } = yield* BenchPaths
      const fs = yield* FileSystem.FileSystem
      const fail = (e: { readonly message: string }) => Effect.fail(new ManifestError({ path: manifest, message: e.message }))
      const text = yield* fs.readFileString(manifest).pipe(Effect.catchTag("PlatformError", fail))
      return yield* decodeManifest(text).pipe(Effect.catchTag(["HausParseError", "HausSchemaError", "HausLimitsError"], fail))
    }),
  )
}
