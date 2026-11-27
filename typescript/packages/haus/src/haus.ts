/**
 * @haus-fmt/haus: the haus data format, without dependencies.
 *
 * - The text layer: `parse`, `stringify`, `format`, `canonical`, `hash`,
 *   `equals`, `compare`, values built in code (`Value.record(…)`), JSON.
 * - Schemas: `Sources` (read with `readSources` from `@haus-fmt/haus/node`,
 *   or made from data), `Package`, `Schema.compile`, typed decoding and
 *   encoding with `Type` handles, `Codec`s, package rules.
 *
 * Every step that can fail gives a `Result` (`Result.match`, `pipe`); none
 * throws. A `Value` is valid and within its limits once it exists, so what
 * takes one (the writers, `canonical`, `hash`, `equals`, `compare`) is total.
 * Values are read-only: one changed after it was built throws `value-changed`
 * from the writers, a programming error (spec §11).
 *
 * The recommended way for most applications is `@haus-fmt/effect`; this
 * package is the barebones foundation it builds on.
 */
import { HausConfigError, isHausError, type HausError, type HausSyntaxError } from "./errors.js"
import { format as formatValues, stringify as stringifyValue, wholeOptionIssue, type FormatOptions, type FormatStyle } from "./format.js"
import * as internal from "./index.js"
import * as json from "./json.js"
import type { Limits } from "./parser.js"
import { attempt, Result } from "./result.js"
import * as plain from "./plain.js"
import type { StandardSchemaV1 } from "./standard.js"
import * as standard from "./standard.js"
import { parseStream as parseStreamThrowing, type ChunkSource, type StreamOptions } from "./stream.js"
import type { Value } from "./value.js"

export { pipe, Result, type Failure, type Success } from "./result.js"
export { isValue, Value, type HArray, type HBytes, type HNumber, type HRecord, type HString, type HVariant, type Located, type Part } from "./value.js"
export {
  ERROR_CODES, errorCode, errorDocs, errorHint, errorJson, formatPath, HausConfigError, HausDecodeError, HausEncodeError, HausPackageError, HausSyntaxError, isErrorCode, isHausError,
  type ErrorCategory, type ErrorCode, type ErrorJson, type HausError, type Path,
} from "./errors.js"
export { HausSchemaFileError, type SchemaFile, type SchemaWarning } from "./schema-file.js"
export { DEFAULT_LIMITS, MAX_SUPPORTED_DEPTH, STACK_NEEDED_MB, type Limits } from "./parser.js"
export { canonical, compare, compareCodePoints, equals, hash, hashAll } from "./canonical.js"
export { JsonNumber, stringifyJson, toHausJson, toHausJsonLines, toHausJsonValue, type Json, type JsonObject } from "./json.js"
export { toPlain } from "./plain.js"
export { infer, inferSchema, printShape, type Inference, type PrintOptions } from "./infer.js"
export { Secret } from "./secret.js"
export type { StandardSchemaV1 } from "./standard.js"
export type { ChunkSource, StreamOptions } from "./stream.js"
export type { FormatStyle } from "./format.js"
export { Codec, Schema, Sources, type DecodeOptions, type EncodeOptions, type Folder, type WriteSchemaOptions } from "./compile.js"
export { Package, type PackageData, type PackageOrigin, type Rule } from "./package.js"
export { Prelude, StdTime, Type, type Builtin, type Const, type Host, type StreamType, type TypeLambda, type TypeOf } from "./types.js"
export type { CodecWarning } from "./codec-ids.js"
export type { Unknown } from "./schema.js"

const isSyntaxError = (e: unknown): e is HausSyntaxError => e instanceof internal.HausSyntaxError
const asResult = <A>(run: () => A): Result<A, HausError> => attempt(run, isHausError)

// ── reading ──────────────────────────────────────────────────

/**
 * Parse a text holding exactly one value (spec §8), within `limits` (spec
 * §7; the defaults for those not given). None or several is `not-one-value`.
 */
export const parse = (text: string, limits: Partial<Limits> = {}): Result<Value, HausSyntaxError> => attempt(() => internal.parse(text, limits), isSyntaxError)

/** Parse a complete text into its top-level values (a stream, spec §6). */
export const parseAll = (text: string, limits: Partial<Limits> = {}): Result<readonly Value[], HausSyntaxError> => attempt(() => internal.parseAll(text, limits), isSyntaxError)

/** As `parseAll`, every value with its `start`/`end` offsets and records with `keySpans`: for editors. */
export const parseWithLocations = (text: string, limits: Partial<Limits> = {}): Result<readonly Value[], HausSyntaxError> =>
  attempt(() => internal.parseWithLocations(text, limits), isSyntaxError)

/** As `parseWithLocations`, with the [start, end) span of every comment. */
export const parseDocument = (text: string, limits: Partial<Limits> = {}): Result<{ readonly values: readonly Value[]; readonly comments: readonly (readonly [number, number])[] }, HausSyntaxError> =>
  attempt(() => internal.parseDocument(text, limits), isSyntaxError)

/**
 * Read a stream (spec §6) as its chunks arrive: each top-level value a
 * Result; after a failure the stream ends. Limits apply per value.
 */
export async function* parseStream(source: ChunkSource, options: StreamOptions = {}): AsyncGenerator<Result<Value, HausError>, void, undefined> {
  const values = parseStreamThrowing(source, options)
  for (;;) {
    let next: IteratorResult<Value>
    try {
      next = await values.next()
    } catch (e) {
      const code = internal.errorCode(e)
      if (isHausError(e)) return void (yield Result.fail(e))
      // The platform's UTF-8 decoder: invalid-utf8 with no position.
      if (code === "invalid-utf8") return void (yield Result.fail(new internal.HausSyntaxError("invalid UTF-8", 0, 1, 1, "invalid-utf8")))
      throw e
    }
    if (next.done === true) return
    yield Result.succeed(next.value)
  }
}

// ── writing ──────────────────────────────────────────────────

/** The options of the writers (spec §11), checked when made: `WriteOptions.make`. */
export interface WriteOptions {
  readonly _tag: "WriteOptions"
  /** `"pretty"` (default), `"compact"` or `"minimised"`. */
  readonly style: FormatStyle
  /** Spaces per indentation level, pretty (default 2). */
  readonly indent: number
  /** The width up to which positional payloads stay inline, pretty (default 80). */
  readonly width: number
  /** Write a comma after every top-level value, a single one too (spec §11, streams). */
  readonly stream: boolean
}

/** A layout without indent or width, which can't be wrong: `{ style: "compact" }`. */
export interface Layout {
  readonly style?: FormatStyle
  readonly stream?: boolean
}

/**
 * Writer options (spec §11, "checked when made"): an indent or width that
 * isn't a whole number of at least 0 is a HausConfigError here, so writing
 * can't fail on it.
 */
export const WriteOptions = Object.freeze({
  make: (options: { readonly style?: FormatStyle; readonly indent?: number; readonly width?: number; readonly stream?: boolean } = {}): Result<WriteOptions, HausConfigError> => {
    const issue = (options.indent === undefined ? undefined : wholeOptionIssue("indent", options.indent)) ?? (options.width === undefined ? undefined : wholeOptionIssue("width", options.width))
    if (issue !== undefined) return Result.fail(new HausConfigError(issue))
    const style = options.style ?? "pretty"
    if (style !== "pretty" && style !== "compact" && style !== "minimised") return Result.fail(new HausConfigError(`style must be "pretty", "compact" or "minimised", not ${String(style)}`))
    return Result.succeed(Object.freeze({ _tag: "WriteOptions", style, indent: options.indent ?? 2, width: options.width ?? 80, stream: options.stream === true }))
  },
})

/** The formatter's options from made options or a layout. */
const formatOptions = (o: WriteOptions | Layout | undefined): FormatOptions =>
  o === undefined ? {}
  : "_tag" in o ? { style: o.style, indent: o.indent, width: o.width, stream: o.stream }
  : { ...(o.style === undefined ? {} : { style: o.style }), ...(o.stream === undefined ? {} : { stream: o.stream }) }

/** Write one value (no trailing newline). Total (spec §11). */
export const stringify = (value: Value, options?: WriteOptions | Layout): string => stringifyValue(value, formatOptions(options))

/** Write a file of values: one value, or each followed by a comma (several, or with `stream`). Total. */
export const format = (values: readonly Value[], options?: WriteOptions | Layout): string => formatValues(values, formatOptions(options))

/**
 * Reformat haus text in a layout (spec §11), keeping comments and blank
 * lines (pretty), numbers' spellings and the comma after each value of a
 * stream. It parses, so it can fail.
 */
export const formatText = (text: string, options?: WriteOptions | Layout): Result<string, HausSyntaxError> =>
  attempt(() => {
    const { values, comments } = internal.parseDocument(text)
    return formatValues(values, { ...formatOptions(options), source: text, comments })
  }, isSyntaxError)

// ── JSON ─────────────────────────────────────────────────────

/** Read JSON text as haus (spec §16.1): any I-JSON, numbers exactly as written. */
export const importJson = (text: string, limits: Partial<Limits> = {}): Result<Value, HausError> => asResult(() => json.importJson(text, limits))

/** Read self-describing JSON (spec §16.2): exactly what `toHausJson` writes. */
export const fromHausJson = (text: string, limits: Partial<Limits> = {}): Result<Value, HausError> => asResult(() => json.fromHausJson(text, limits))

/** Read I-JSON text into the JSON data model, numbers exactly as written. */
export const parseJson = (text: string, limits: Partial<Limits> = {}): Result<json.Json, HausError> => asResult(() => json.parseJson(text, limits))

// ── without a schema ─────────────────────────────────────────

/** The plain JS view of haus text (strings, numbers, `null` for `None`, `{ _tag }` objects), for any validator. */
export const parsePlain = (text: string): Result<unknown, HausSyntaxError> => attempt(() => plain.parsePlain(text), isSyntaxError)

/**
 * Parse haus text and validate its plain view with any Standard Schema
 * (Zod, Valibot, ArkType, Effect Schema, …).
 */
export const parseWith = <S extends StandardSchemaV1>(schema: S, text: string): Result<StandardSchemaV1.InferOutput<S>, HausSyntaxError | standard.HausValidationError> =>
  attempt(() => standard.parseWith(schema, text), (e): e is HausSyntaxError | standard.HausValidationError => isSyntaxError(e) || e instanceof standard.HausValidationError)

/** `parseWith` for schemas that may validate asynchronously; the Promise never rejects for haus or validation errors. */
export const parseWithAsync = async <S extends StandardSchemaV1>(schema: S, text: string): Promise<Result<StandardSchemaV1.InferOutput<S>, HausSyntaxError | standard.HausValidationError>> => {
  try {
    return Result.succeed(await standard.parseWithAsync(schema, text))
  } catch (e) {
    if (isSyntaxError(e) || e instanceof standard.HausValidationError) return Result.fail(e)
    throw e
  }
}

export { HausValidationError } from "./standard.js"

// ── Maybe ────────────────────────────────────────────────────

/** `Maybe a` as decoded (spec §15): `{ _tag: "None" }` or `{ _tag: "Some", value }`, never `null`. */
export type Maybe<A> = { readonly _tag: "None" } | { readonly _tag: "Some"; readonly value: A }

const none: Maybe<never> = Object.freeze({ _tag: "None" })

/** Building and reading `Maybe` values. */
export const Maybe = Object.freeze({
  /** `None`. */
  none,
  /** `Some(value)`. */
  some: <A>(value: A): Maybe<A> => Object.freeze({ _tag: "Some", value }),
  /** `Some(value)` for a value, `None` for null and undefined. */
  fromNullable: <A>(value: A | null | undefined): Maybe<A> => (value === null || value === undefined ? none : Object.freeze({ _tag: "Some", value })),
  /** The value of a `Some`, or null for `None`. Collapses `Some(None)` and `None` of a nested Maybe: use it at the edge only. */
  toNullable: <A>(m: Maybe<A>): A | null => (m._tag === "Some" ? m.value : null),
  /** Whether `u` is a Maybe. */
  is: (u: unknown): u is Maybe<unknown> =>
    typeof u === "object" && u !== null && ((u as { _tag?: unknown })._tag === "None" || ((u as { _tag?: unknown })._tag === "Some" && Object.hasOwn(u, "value"))),
})
