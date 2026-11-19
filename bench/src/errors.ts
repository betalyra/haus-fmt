/**
 * What can go wrong in the benchmark, one error per reason. Platform errors
 * (files, processes, HTTP) keep their own types (PlatformError,
 * HttpClientError); these are the benchmark's.
 */
import { Schema } from "effect"

/** `sources.haus` doesn't parse or doesn't match the manifest's schema. */
export class ManifestError extends Schema.TaggedError<ManifestError, { readonly brand: unique symbol }>()("ManifestError", {
  path: Schema.String,
  message: Schema.String,
}) {}

/** A downloaded file isn't the one the manifest pins. */
export class HashMismatchError extends Schema.TaggedError<HashMismatchError, { readonly brand: unique symbol }>()("HashMismatchError", {
  what: Schema.String,
  expected: Schema.String,
  actual: Schema.String,
  message: Schema.String,
}) {}

/** `git` exited with an error. */
export class GitError extends Schema.TaggedError<GitError, { readonly brand: unique symbol }>()("GitError", {
  args: Schema.Array(Schema.String),
  exitCode: Schema.Finite,
  message: Schema.String,
}) {}

/** An HTTP download answered with an error status (a gated repository needs a login). */
export class DownloadError extends Schema.TaggedError<DownloadError, { readonly brand: unique symbol }>()("DownloadError", {
  url: Schema.String,
  status: Schema.Finite,
  message: Schema.String,
}) {}

/** A corpus source file isn't what its reader expects (not JSON, not an OpenAPI description, …). */
export class CorpusError extends Schema.TaggedError<CorpusError, { readonly brand: unique symbol }>()("CorpusError", {
  path: Schema.String,
  message: Schema.String,
}) {}

/** A step needs the results of an earlier one that hasn't run. */
export class MissingResultsError extends Schema.TaggedError<MissingResultsError, { readonly brand: unique symbol }>()("MissingResultsError", {
  path: Schema.String,
  message: Schema.String,
}) {}

/** A results file in .out/ doesn't match its schema (written by another version of the benchmark?). */
export class ResultsFileError extends Schema.TaggedError<ResultsFileError, { readonly brand: unique symbol }>()("ResultsFileError", {
  path: Schema.String,
  message: Schema.String,
}) {}

/** `--tokenizers` names a tokenizer the manifest doesn't list. */
export class UnknownTokenizerError extends Schema.TaggedError<UnknownTokenizerError, { readonly brand: unique symbol }>()("UnknownTokenizerError", {
  tokenizer: Schema.String,
  message: Schema.String,
}) {}

/** `--sources` names a corpus source the manifest doesn't list. */
export class UnknownSourceError extends Schema.TaggedError<UnknownSourceError, { readonly brand: unique symbol }>()("UnknownSourceError", {
  source: Schema.String,
  message: Schema.String,
}) {}

/** tokenizers.js can't load a tokenizer's files. */
export class TokenizerLoadError extends Schema.TaggedError<TokenizerLoadError, { readonly brand: unique symbol }>()("TokenizerLoadError", {
  tokenizer: Schema.String,
  message: Schema.String,
}) {}

/** A check before timing failed: the inputs of a speed task aren't what convert proved. */
export class SpeedCheckError extends Schema.TaggedError<SpeedCheckError, { readonly brand: unique symbol }>()("SpeedCheckError", {
  message: Schema.String,
}) {}

/** tinybench failed a task, or the run itself. */
export class BenchmarkError extends Schema.TaggedError<BenchmarkError, { readonly brand: unique symbol }>()("BenchmarkError", {
  task: Schema.String,
  message: Schema.String,
}) {}

/** The message of an unknown thrown value. */
export const messageOf = (e: unknown): string => (e instanceof Error ? e.message : String(e))
