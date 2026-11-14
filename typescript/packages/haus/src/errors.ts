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

export class HausSyntaxError extends Error {
  override readonly name = "HausSyntaxError"

  constructor(
    /** Message without position. */
    readonly reason: string,
    readonly offset: number,
    readonly line: number,
    readonly column: number,
  ) {
    super(`${reason} at ${line}:${column}`)
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

  constructor(
    /** Message without the path. */
    readonly reason: string,
    /** Where in the value the mismatch is, e.g. ["events", 2, "amount"]. */
    readonly path: Path,
  ) {
    super(`${reason} at ${formatPath(path)}`)
  }
}

/** A value that can't be written (e.g. an Int that isn't a bigint, or a value with no JSON form). */
export class HausEncodeError extends Error {
  override readonly name = "HausEncodeError"

  constructor(
    readonly reason: string,
    readonly path: Path,
  ) {
    super(`${reason} at ${formatPath(path)}`)
  }
}
