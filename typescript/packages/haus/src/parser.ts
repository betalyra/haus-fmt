/**
 * The generic parser: `readValue` builds the `Value` tree from the `Reader`
 * (reader.ts), which is the one parser of the format. `Parser` keeps the
 * entry points the rest of the package uses (whole files, stream items,
 * values inside schema files, number literals). Also the limits (spec §7).
 */
import { limitsError, START, type Origin } from "./errors.js"
import { ARGS, ARRAY, BYTES, CLOSE_ARGS, CLOSE_ARRAY, DEFAULT_LIMITS, NUMBER, PAYLOAD_RECORD, Reader, RECORD, STRING, type Limits } from "./reader.js"
import { arr, bytes, num, rec, str, variant, type HRecord, type Value } from "./value.js"

export { DEFAULT_LIMITS, longerThan, MAX_DEPTH, maxHexDigits, Reader, type Limits } from "./reader.js"

/**
 * The deepest nesting this binding supports (spec §7): 512 levels. The
 * parser, the schema decoders and encoders and the JSON mappings recurse, one
 * call (or a few) per level, so a `maxDepth` above this is rejected with a
 * RangeError when the limits are given, instead of overflowing the stack on
 * deep input. Measured to fit Node's default stack with room to spare (the
 * shallowest path, encoding with a schema, overflows near 750 levels).
 * Formatting, the canonical form and hashing don't recurse: any depth works.
 */
export const MAX_SUPPORTED_DEPTH = 512

/**
 * Why `limits` can't be used, or undefined if they can: a `maxDepth` that
 * isn't a whole number from 0 to `max` (MAX_SUPPORTED_DEPTH; for JSON
 * nesting, `jsonDepth(MAX_SUPPORTED_DEPTH)`). The message names the maximum.
 */
export const limitsIssue = (limits: { readonly maxDepth?: number | undefined }, max: number = MAX_SUPPORTED_DEPTH, what = "nesting"): string | undefined => {
  const depth = limits.maxDepth
  if (depth === undefined || (Number.isInteger(depth) && depth >= 0 && depth <= max)) return undefined
  return depth > max
    ? `maxDepth ${depth} is above ${max}, the deepest ${what} this binding supports (spec §7)`
    : `maxDepth must be a whole number from 0 to ${max}, not ${depth}`
}

/** Throw a RangeError if `limits` can't be used (see `limitsIssue`). */
export const checkLimits = (limits: { readonly maxDepth?: number | undefined }, max?: number, what?: string): void => {
  const issue = limitsIssue(limits, max, what)
  if (issue !== undefined) throw limitsError(issue)
}

/**
 * `limits` with DEFAULT_LIMITS for the ones not given (an `undefined` field
 * counts as not given). Throws a RangeError for a `maxDepth` above
 * MAX_SUPPORTED_DEPTH (see `limitsIssue`).
 */
export const withDefaults = (limits: Partial<Limits>): Limits => {
  checkLimits(limits)
  return {
    maxDepth: limits.maxDepth ?? DEFAULT_LIMITS.maxDepth,
    maxNumberLength: limits.maxNumberLength ?? DEFAULT_LIMITS.maxNumberLength,
    maxExponent: limits.maxExponent ?? DEFAULT_LIMITS.maxExponent,
    maxStringLength: limits.maxStringLength ?? DEFAULT_LIMITS.maxStringLength,
  }
}

// ── the Value tree ───────────────────────────────────────────

/** The value at the reader's position, as a `Value` tree (with `start`/`end` when the reader records locations). */
export const readValue = (r: Reader): Value => {
  if (!r.locations) return readAt(r)
  const start = r.pos
  const v = readAt(r)
  return Object.assign(v, { start, end: r.pos })
}

const readAt = (r: Reader): Value => {
  switch (r.next()) {
    case RECORD: return readRecord(r)
    case ARRAY: return readArray(r)
    case STRING: return str(r.string())
    case NUMBER: return num(r.number())
    case BYTES: return bytes(r.bytes())
    default: return readVariantAfter(r, r.tag())
  }
}

/** At `{`: the record, its fields in source order. */
const readRecord = (r: Reader): HRecord => {
  r.openRecord()
  const fields = new Map<string, Value>()
  const keySpans = r.locations ? new Map<string, readonly [number, number]>() : undefined
  for (let key = r.key(); key !== undefined; key = r.key()) {
    keySpans?.set(key, [r.keyStart, r.keyEnd])
    const value = readValue(r)
    // One lookup: a key seen before leaves the size as it was (the map is dropped with the error).
    const size = fields.size
    fields.set(key, value)
    if (fields.size === size) r.failDuplicate(key)
    r.endField()
  }
  return keySpans ? { ...rec(fields), keySpans } : rec(fields)
}

const readArray = (r: Reader): Value => {
  r.openList()
  const items: Value[] = []
  while (r.more(CLOSE_ARRAY)) {
    items.push(readValue(r))
    r.endItem(CLOSE_ARRAY)
  }
  return arr(items)
}

/** After a variant's tag (`r.tag()`): its payload, and the variant. */
export const readVariantAfter = (r: Reader, tag: string): Value => {
  switch (r.payload(tag)) {
    case ARGS: {
      const args: Value[] = []
      do {
        args.push(readValue(r))
        r.endItem(CLOSE_ARGS)
      } while (r.more(CLOSE_ARGS))
      return variant(tag, args)
    }
    case PAYLOAD_RECORD:
      return variant(tag, [readValue(r)])
    default:
      return variant(tag)
  }
}

/**
 * The parser's entry points over one complete piece of text. The streaming
 * reader cuts the input into pieces holding one value each; `parseAll`
 * runs over a whole file.
 */
export class Parser {
  private readonly r: Reader

  constructor(
    src: string,
    origin: Origin = START,
    limits: Limits = DEFAULT_LIMITS,
    /** Record source positions on every value (for editor tooling). */
    locations = false,
  ) {
    this.r = new Reader(src, origin, limits, locations)
  }

  /** With locations: [start, end) of every comment, in source order. */
  get comments(): [number, number][] {
    return this.r.comments
  }

  /**
   * The values read so far, nested ones included: a record payload `Tag { … }`
   * is a value of its own. For a single value, the size of its tree.
   */
  get valueCount(): number {
    return this.r.valueCount
  }

  /** A whole file: zero or more comma-separated values. */
  parseSequence(): Value[] {
    const r = this.r
    const out: Value[] = []
    r.begin()
    if (!r.atEnd()) {
      do out.push(readValue(r))
      while (r.nextTop())
    }
    return out
  }

  /**
   * Exactly one value surrounded by trivia, optionally followed by the ',' that
   * ends the text (used by the stream reader, which passes each item with its
   * comma). Fails as parseSequence fails on the same text: an empty item is
   * "expected a value, found ','", as in the whole text.
   */
  parseSingle(): Value {
    const r = this.r
    r.begin()
    const v = readValue(r)
    r.endSingle()
    return v
  }

  /**
   * One value starting exactly at `start` (no trivia before it), for values
   * inside other text, such as the arguments of a schema file's attributes.
   * Returns the value and the offset just after it.
   */
  valueAt(start: number): { readonly value: Value; readonly end: number } {
    this.r.pos = start
    const value = readValue(this.r)
    return { value, end: this.r.pos }
  }

  /** The whole text as one number literal, without trivia around it: its normalized text (spec §2). */
  parseNumberLiteral(): string {
    return this.r.numberLiteral()
  }

  /**
   * Whitespace and comments from `start`, as between values: the offset after
   * them. Schema files have the same (spec §14); a `/` that starts no comment
   * is left for the caller.
   */
  triviaEnd(start: number): number {
    return this.r.triviaEnd(start)
  }

  /** The `"…"` string at `start`, with the offset after it (spec §4): schema files' quoted keys (§14). */
  basicStringAt(start: number): { readonly value: string; readonly end: number } {
    return this.r.basicStringAt(start)
  }
}
