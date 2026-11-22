import { unpairedSurrogate } from "./chars.js"
import { ERROR_CODES, type ErrorCode } from "./error-codes.js"
import { escaped } from "./format.js"

export { ERROR_CODES, type ErrorCategory, type ErrorCode } from "./error-codes.js"

/** Where a chunk of text starts within the whole input. */
export interface Origin {
  /** Absolute offset (UTF-16 code units). */
  readonly offset: number
  /** 1-based line. */
  readonly line: number
  /** 1-based column, in Unicode code points. */
  readonly column: number
}

export const START: Origin = { offset: 0, line: 1, column: 1 }

/** What an error can say beyond its message (spec §17): the fix, and what was expected and found. */
export interface ErrorDetails {
  /** A concrete fix. Without one, the catalogue's fix for the code is given. */
  readonly hint?: string
  /** What should be there, e.g. `','` or `Int`. */
  readonly expected?: string
  /** What is there instead, e.g. `'{'` or `the string "42"`. */
  readonly found?: string
}

/** An error's code and message, before it has a place. */
export interface Problem {
  readonly code: ErrorCode
  readonly reason: string
}

/** The documentation of an error code: `https://haus-fmt.org/docs/errors#<code>`. */
export const errorDocs = (code: ErrorCode): string => `https://haus-fmt.org/docs/errors#${code}`

/** The catalogue's fix for an error code, reported as the hint when the error has none of its own. */
export const errorHint = (code: ErrorCode): string => ERROR_CODES[code].hint

/**
 * What a variant's case takes (spec §15): no payload, one record (its type, if
 * known), or positional arguments (their types, or just how many).
 */
export type CasePayload =
  | { readonly kind: "none" }
  | { readonly kind: "record"; readonly type?: string }
  | { readonly kind: "args"; readonly types: readonly string[] }
  | { readonly kind: "args"; readonly count: number }

/**
 * The hint of a `wrong-payload` error: the case the tag has, instead of the
 * catalogue's generic fix. `Point takes 2 arguments (Float64, Float64): write
 * \`Point(…, …)\`.`
 */
export const payloadHint = (tag: string, takes: CasePayload): string => {
  switch (takes.kind) {
    case "none":
      return `${tag} takes no payload: write \`${tag}\`.`
    case "record":
      return `${tag} takes one argument, a record${takes.type === undefined ? "" : ` ${takes.type}`}: write \`${tag} { … }\`.`
    case "args": {
      const types = "types" in takes ? takes.types : undefined
      const n = types?.length ?? ("count" in takes ? takes.count : 0)
      const listed = types === undefined ? "" : ` (${types.join(", ")})`
      return `${tag} takes ${n} argument${n === 1 ? "" : "s"}${listed}: write \`${tag}(${Array.from({ length: n }, () => "…").join(", ")})\`.`
    }
  }
}

/** Whether `s` is an error code of the catalogue (spec §17). */
export const isErrorCode = (s: unknown): s is ErrorCode => typeof s === "string" && Object.hasOwn(ERROR_CODES, s)

/** An error's JSON form (spec §17). `line`/`column` for errors in text, `path` for errors in a value. */
export interface ErrorJson {
  readonly code: ErrorCode
  readonly message: string
  readonly line?: number
  readonly column?: number
  readonly path?: string
  readonly expected?: string
  readonly found?: string
  readonly hint?: string
  readonly docs: string
}

const detailsJson = (code: ErrorCode, d: ErrorDetails) => ({
  ...(d.expected !== undefined ? { expected: d.expected } : {}),
  ...(d.found !== undefined ? { found: d.found } : {}),
  hint: d.hint ?? errorHint(code),
  docs: errorDocs(code),
})

export class HausSyntaxError extends Error {
  override readonly name = "HausSyntaxError"
  /** What can be done about it; the catalogue's fix for the code unless the error knows a better one. */
  readonly hint: string
  readonly expected?: string
  readonly found?: string

  constructor(
    /** Message without position. */
    readonly reason: string,
    readonly offset: number,
    readonly line: number,
    readonly column: number,
    /** The error's code (spec §17): stable, the same in every binding. */
    readonly code: ErrorCode,
    details: ErrorDetails = {},
  ) {
    super(`${reason} at ${line}:${column}`)
    this.hint = details.hint ?? errorHint(code)
    if (details.expected !== undefined) this.expected = details.expected
    if (details.found !== undefined) this.found = details.found
  }

  /** `https://haus-fmt.org/docs/errors#<code>` */
  get docs(): string {
    return errorDocs(this.code)
  }

  /** The JSON form of spec §17: `{ code, message, line, column, expected?, found?, hint, docs }`. */
  toJSON(): ErrorJson {
    return { code: this.code, message: this.reason, line: this.line, column: this.column, ...detailsJson(this.code, this) }
  }
}

/**
 * Text given as a string, before it is read as haus or JSON: an unpaired
 * surrogate has no UTF-8 form, so it is rejected as invalid UTF-8 is
 * (`invalid-utf8`, spec §4), at the first one, whatever comes before it.
 */
export function checkWellFormed(text: string, origin: Origin = START): void {
  const at = unpairedSurrogate(text)
  if (at < 0) return
  const p = locate(text, at, origin)
  throw new HausSyntaxError("an unpaired surrogate, which has no UTF-8 form", p.offset, p.line, p.column, "invalid-utf8")
}

/**
 * Position of `pos` within `text`, given that `text` starts at `origin`.
 * Columns count Unicode code points (spec), so a surrogate pair is one column.
 */
export function locate(text: string, pos: number, origin: Origin): Origin {
  let line = origin.line
  let column = origin.column
  for (let i = 0; i < pos && i < text.length; i++) {
    const c = text.charCodeAt(i)
    if (c === 10) {
      line++
      column = 1
    } else if (c < 0xdc00 || c > 0xdfff) {
      column++
    }
  }
  return { offset: origin.offset + pos, line, column }
}

/** A place in a value: field names and array (or argument) indexes. */
export type Path = readonly (string | number)[]

/**
 * `$.items[2].price`, `$.m["pt-BR"]` (spec §15): a key that isn't an
 * identifier as a haus string in canonical form (§12).
 */
export const formatPath = (path: Path) =>
  "$" + path.map((p) => (typeof p === "number" ? `[${p}]` : /^[a-z_]\w*$/.test(p) ? `.${p}` : `[${escaped(p)}]`)).join("")

/** Valid input (haus or JSON) that doesn't fit what is expected: a schema, or a JSON mapping (spec §15, §16). */
export class HausDecodeError extends Error {
  override readonly name = "HausDecodeError"
  readonly hint: string
  readonly expected?: string
  readonly found?: string

  constructor(
    /** Message without the path. */
    readonly reason: string,
    /** Where in the value the mismatch is, e.g. ["events", 2, "amount"]. */
    readonly path: Path,
    /** The error's code (spec §17). */
    readonly code: ErrorCode,
    details: ErrorDetails = {},
  ) {
    super(`${reason} at ${formatPath(path)}`)
    this.hint = details.hint ?? errorHint(code)
    if (details.expected !== undefined) this.expected = details.expected
    if (details.found !== undefined) this.found = details.found
  }

  get docs(): string {
    return errorDocs(this.code)
  }

  /** The JSON form of spec §17: `{ code, message, path, expected?, found?, hint, docs }`. */
  toJSON(): ErrorJson {
    return { code: this.code, message: this.reason, path: formatPath(this.path), ...detailsJson(this.code, this) }
  }
}

/** A value that can't be written (e.g. an Int that isn't a bigint, or a value with no JSON form). */
export class HausEncodeError extends Error {
  override readonly name = "HausEncodeError"
  readonly hint: string
  readonly expected?: string
  readonly found?: string

  constructor(
    readonly reason: string,
    readonly path: Path,
    /** The error's code (spec §17). */
    readonly code: ErrorCode,
    details: ErrorDetails = {},
  ) {
    super(`${reason} at ${formatPath(path)}`)
    this.hint = details.hint ?? errorHint(code)
    if (details.expected !== undefined) this.expected = details.expected
    if (details.found !== undefined) this.found = details.found
  }

  get docs(): string {
    return errorDocs(this.code)
  }

  /** The JSON form of spec §17: `{ code, message, path, expected?, found?, hint, docs }`. */
  toJSON(): ErrorJson {
    return { code: this.code, message: this.reason, path: formatPath(this.path), ...detailsJson(this.code, this) }
  }
}

/**
 * Whether `e` is the engine's stack overflow: V8's and JavaScriptCore's
 * RangeError "Maximum call stack size exceeded", SpiderMonkey's InternalError
 * "too much recursion". This package's own RangeErrors have a code, and are not.
 */
export const isStackOverflow = (e: unknown): boolean =>
  e instanceof Error &&
  (e as { code?: unknown }).code === undefined &&
  (e instanceof RangeError || e.name === "InternalError") &&
  /call stack|recursion/i.test(e.message)

/** Why a value is `nesting-too-deep` when the stack ran out before the depth limit was reached (spec §7). */
export const STACK_EXHAUSTED = "nesting too deep for the stack it runs on (512 levels, MAX_SUPPORTED_DEPTH, need STACK_NEEDED_MB of stack)"

/**
 * `run()`, with the engine's stack overflow reported as the error `tooDeep`
 * makes (`nesting-too-deep`, spec §7) instead of a RangeError: JavaScript
 * code can't set the size of the stack it runs on (a worker thread's may be
 * small), so a deep value on a small stack fails as too deep, never as a crash.
 */
export const guardStack = <T>(run: () => T, tooDeep: (reason: string) => Error): T => {
  try {
    return run()
  } catch (e) {
    throw isStackOverflow(e) ? tooDeep(STACK_EXHAUSTED) : e
  }
}

/** `nesting-too-deep` in a value read (decoding, JSON mappings), at `path` (`$` when the place isn't known). */
export const decodeTooDeep = (path: Path = []) => (reason: string): HausDecodeError => new HausDecodeError(reason, path, "nesting-too-deep")

/** `nesting-too-deep` in a value written (writers, encoding), at `path` (`$` when the place isn't known). */
export const encodeTooDeep = (path: Path = []) => (reason: string): HausEncodeError => new HausEncodeError(reason, path, "nesting-too-deep")

/** A RangeError for limits a binding can't use (spec §7), with the code `unsupported-depth`. */
export const limitsError = (message: string): RangeError & { readonly code: ErrorCode } =>
  Object.assign(new RangeError(message), { code: "unsupported-depth" as const })

/** The code of an error thrown by this package (spec §17), or undefined for any other value. */
export function errorCode(e: unknown): ErrorCode | undefined {
  if (e instanceof HausSyntaxError || e instanceof HausDecodeError || e instanceof HausEncodeError) return e.code
  const code = e instanceof RangeError ? (e as { code?: unknown }).code : undefined
  if (isErrorCode(code)) return code
  // The platform's UTF-8 decoder (TextDecoder with fatal: true), as used by parseStream.
  if (e instanceof TypeError && (e as { code?: unknown }).code === "ERR_ENCODING_INVALID_ENCODED_DATA") return "invalid-utf8"
  return undefined
}

/**
 * The JSON form of an error (spec §17), for tools and agents:
 *
 *   { code, message, line?, column?, path?, expected?, found?, hint, docs }
 *
 * `line` and `column` for errors in text (syntax, schema files, JSON text),
 * `path` (`$.items[2].price`) for errors in a value. Works for every error
 * this package throws, and for the UTF-8 decoder's TypeError (code
 * `invalid-utf8`, no position); undefined for anything else.
 */
export function errorJson(e: unknown): ErrorJson | undefined {
  if (e instanceof HausSyntaxError || e instanceof HausDecodeError || e instanceof HausEncodeError) return e.toJSON()
  const code = errorCode(e)
  if (code === undefined) return undefined
  return { code, message: code === "invalid-utf8" ? "invalid UTF-8" : (e as Error).message, ...detailsJson(code, {}) }
}
