import { ERROR_CODES, type ErrorCode } from "./error-codes.js"

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

/** `$.items[2].price` */
export const formatPath = (path: Path) =>
  "$" + path.map((p) => (typeof p === "number" ? `[${p}]` : /^[a-z_]\w*$/.test(p) ? `.${p}` : `[${JSON.stringify(p)}]`)).join("")

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
