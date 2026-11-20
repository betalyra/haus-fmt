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
 * Every file in a directory whose name ends in one of `suffixes` (with
 * `recursive`, in its subdirectories too; names are then paths below `dir`).
 * `sha256` pins them all: the SHA-256 of the listing
 * `<name>\t<SHA-256 of the file>\n`, sorted by name (see `listingText`).
 */
export const PinnedFiles = Schema.Struct({
  dir: Schema.String,
  suffixes: Schema.Array(Schema.String),
  recursive: Schema.optionalKey(Schema.Boolean),
  count: Schema.Int,
  sha256: Sha256,
})
export type PinnedFiles = typeof PinnedFiles.Type

/** Another git repository a source reads (a schema kept apart from the documents). */
export const Upstream = Schema.Struct({
  repo: Schema.String,
  /** The release the commit is, if it is one. */
  tag: Schema.optionalKey(Schema.String),
  commit: Schema.String,
  committed: Haus.Instant,
  license: Schema.String,
})
export type Upstream = typeof Upstream.Type

/** A file downloaded over HTTPS, pinned by its SHA-256. */
export const PinnedUrl = Schema.Struct({ url: Schema.String, sha256: Sha256 })
export type PinnedUrl = typeof PinnedUrl.Type

/** A file of an npm package the benchmark depends on (pinned exactly in package.json), and its SHA-256. */
export const PackageFile = Schema.Struct({ package: Schema.String, version: Schema.String, file: Schema.String, sha256: Sha256 })
export type PackageFile = typeof PackageFile.Type

/** What the documents are, and how to read them. */
export const Layout = Schema.Union([
  /** The example responses of an OpenAPI description, each with its response's schema. */
  Schema.TaggedStruct("OpenApiExamples", { description: PinnedFile }),
  /** The example objects of an OpenAPI description's fixtures file (Stripe), each of the component its `object` names. */
  Schema.TaggedStruct("OpenApiFixtures", { description: PinnedFile, fixtures: PinnedFile }),
  /** One JSON document per file, all of the type at the JSON Schema's root `$ref`. */
  Schema.TaggedStruct("JsonSchemaDocuments", { schema: PinnedFile, documents: PinnedFiles }),
  /**
   * Kubernetes YAML manifests, one document per YAML document, typed by the OpenAPI v3
   * description of a Kubernetes release (`api/openapi-spec/v3/*.json`, another repository).
   */
  Schema.TaggedStruct("KubernetesManifests", {
    documents: PinnedFiles,
    schema: Schema.Struct({ from: Upstream, files: PinnedFiles }),
  }),
  /**
   * Function-calling entries (BFCL): question files (JSON Lines) and their possible answers,
   * one document per entry of `categories`, typed by a hand-written haus schema (`schema`, a
   * path in bench/).
   */
  Schema.TaggedStruct("FunctionCalls", {
    questions: PinnedFiles,
    answers: PinnedFiles,
    categories: Schema.Array(Schema.String),
    schema: Schema.String,
  }),
  /** The features of a GeoJSON FeatureCollection, one document each, typed by the GeoJSON Feature JSON Schema. */
  Schema.TaggedStruct("GeoJsonFeatures", { documents: PinnedFile, schema: PackageFile }),
  /**
   * An hour of GH Archive (gzipped JSON Lines of public GitHub events), sampled down to
   * `sample` events, stratified by event type with a seeded generator, typed with the event
   * schemas of GitHub's OpenAPI description (another repository).
   */
  Schema.TaggedStruct("GhArchiveEvents", {
    archive: PinnedUrl,
    sample: Schema.Int,
    seed: Schema.Int,
    schema: Schema.Struct({ from: Upstream, description: PinnedFile }),
  }),
])
export type Layout = typeof Layout.Type

/** Converter rules a source turns on (openapi.ts); each layout has its defaults. */
export const Rules = Schema.Struct({
  constDiscriminators: Schema.optionalKey(Schema.Boolean),
  keyedUnions: Schema.optionalKey(Schema.Boolean),
})

export const CorpusSource = Schema.Struct({
  name: Schema.String,
  title: Schema.String,
  category: Category,
  license: Schema.String,
  repo: Schema.String,
  commit: Schema.String,
  committed: Haus.Instant,
  layout: Layout,
  rules: Schema.optionalKey(Rules),
})
export type CorpusSource = typeof CorpusSource.Type

const pattern = (f: PinnedFiles) => `${f.dir}/${f.recursive ? "**/" : ""}*${f.suffixes.length === 1 ? f.suffixes[0] : `{${f.suffixes.join(",")}}`}`

/** The source's main path, for listings: the description, or the documents' pattern. */
export const sourcePath = (s: CorpusSource): string => {
  const l = s.layout
  switch (l._tag) {
    case "OpenApiExamples": return l.description.path
    case "OpenApiFixtures": return l.fixtures.path
    case "JsonSchemaDocuments": return pattern(l.documents)
    case "KubernetesManifests": return pattern(l.documents)
    case "FunctionCalls": return pattern(l.questions)
    case "GeoJsonFeatures": return l.documents.path
    case "GhArchiveEvents": return l.archive.url
  }
}

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
