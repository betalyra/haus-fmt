/**
 * The haus data model (spec §1, §2), and the constructors that build it in
 * code. A value is built only by these constructors (or read by a parser),
 * so every `Value` is a haus value: the constructors reject anything else
 * with the code of the mistake (spec §11, "Values built in code"), and what
 * takes a value (the writers, `canonical`, `equals`, `hash`, `compare`) need
 * not check it again.
 *
 *   rec({ id: num("0xFF"), status: variant("Shipped"), tags: arr([str("new")]) })
 *   // { id: 255, status: Shipped, tags: ["new"] }
 *
 *   num("01")          // HausEncodeError invalid-number
 *   variant("lower")   // HausEncodeError invalid-tag
 */
import { quoteText, TAG, unpairedSurrogate } from "./chars.js"
import { HausEncodeError, type ErrorCode } from "./errors.js"
import { canonicalNumber } from "./number.js"

/** The mark of a value the constructors built: an object literal is not a `Value`. Type-level only. */
declare const built: unique symbol

/**
 * The haus data model, exactly as written in the source. No schema has been
 * applied: numbers are their normalized literal text (spec §2), and variants
 * are generic. Build one with `num`, `str`, `bytes`, `arr`, `rec` and
 * `variant`; narrow it by `kind`.
 */
export type Value = HNumber | HString | HBytes | HArray | HRecord | HVariant

/**
 * Source positions, only set when parsing with `{ locations: true }` (editor
 * tooling). Offsets are UTF-16 indexes into the parsed text, `end` exclusive.
 */
export interface Located {
  readonly start?: number
  readonly end?: number
}

/** What every value has: source positions when parsed with them, and the mark of a built value. */
interface Built extends Located {
  readonly [built]: true
}

export interface HNumber extends Built {
  readonly kind: "number"
  /**
   * The normalized literal (spec §2): digit separators removed, hex and
   * binary literals as decimal integers, no `+` or `E`. Example: "19.90",
   * "-1e10", "255".
   */
  readonly text: string
}

export interface HString extends Built {
  readonly kind: "string"
  readonly value: string
}

/** A byte string, written `x"0b34ff"`. */
export interface HBytes extends Built {
  readonly kind: "bytes"
  readonly bytes: Uint8Array
}

export interface HArray extends Built {
  readonly kind: "array"
  readonly items: readonly Value[]
}

export interface HRecord extends Built {
  readonly kind: "record"
  /** Fields in source order. */
  readonly fields: ReadonlyMap<string, Value>
  /** With `{ locations: true }`: where each key starts and ends. */
  readonly keySpans?: ReadonlyMap<string, readonly [start: number, end: number]>
}

export interface HVariant extends Built {
  readonly kind: "variant"
  readonly tag: string
  /** Empty for a bare tag. `Tag { ... }` has a single record arg. */
  readonly args: readonly Value[]
}

// ── the runtime classes ──────────────────────────────────────
// Plain data with a prototype: what `isValue` recognizes. Not exported from
// the package, so only the constructors and the readers make one.

abstract class Node {
  declare readonly [built]: true
  declare start?: number
  declare end?: number
}

class NumberNode extends Node implements HNumber {
  declare readonly kind: "number"
  declare readonly text: string
  constructor(text: string) {
    super()
    this.kind = "number"
    this.text = text
  }
}

class StringNode extends Node implements HString {
  declare readonly kind: "string"
  declare readonly value: string
  constructor(value: string) {
    super()
    this.kind = "string"
    this.value = value
  }
}

class BytesNode extends Node implements HBytes {
  declare readonly kind: "bytes"
  declare readonly bytes: Uint8Array
  constructor(bytes: Uint8Array) {
    super()
    this.kind = "bytes"
    this.bytes = bytes
  }
}

class ArrayNode extends Node implements HArray {
  declare readonly kind: "array"
  declare readonly items: readonly Value[]
  constructor(items: readonly Value[]) {
    super()
    this.kind = "array"
    this.items = items
  }
}

class RecordNode extends Node implements HRecord {
  declare readonly kind: "record"
  declare readonly fields: ReadonlyMap<string, Value>
  declare readonly keySpans?: ReadonlyMap<string, readonly [start: number, end: number]>
  constructor(fields: ReadonlyMap<string, Value>) {
    super()
    this.kind = "record"
    this.fields = fields
  }
}

class VariantNode extends Node implements HVariant {
  declare readonly kind: "variant"
  declare readonly tag: string
  declare readonly args: readonly Value[]
  constructor(tag: string, args: readonly Value[]) {
    super()
    this.kind = "variant"
    this.tag = tag
    this.args = args
  }
}

/**
 * Whether `x` is a value: one the constructors built or a reader read (not
 * an object that only looks like one). A value of another copy of this
 * package, or one passed through `structuredClone`, is not.
 */
export const isValue = (x: unknown): x is Value => x instanceof Node

// ── the constructors (spec §11, "Values built in code") ──────

const NO_ARGS: readonly Value[] = Object.freeze([])

const rejected = (reason: string, code: ErrorCode): never => {
  throw new HausEncodeError(reason, [], code)
}

/** Text with a UTF-8 form: a string without an unpaired surrogate (spec §4), else `cannot-encode`. */
const text = (s: unknown, what: "a string" | "a key" | "a tag"): string => {
  if (typeof s !== "string") return rejected(`${what} must be a string, not ${typeof s}`, "cannot-encode")
  if (unpairedSurrogate(s) >= 0) return rejected(`${what} with an unpaired surrogate, which has no UTF-8 form`, "cannot-encode")
  return s
}

/** Something where a value belongs that isn't one (an object that only looks like one is none): `cannot-encode`. */
const notAValue = (where: string): never => rejected(`${where} is not a haus value (build one with num, str, bytes, arr, rec or variant)`, "cannot-encode")

/** `items` copied and frozen, each a value. */
const values = (items: Iterable<Value>, what: "item" | "argument"): readonly Value[] => {
  if (typeof items !== "object" || items === null || !(Symbol.iterator in items)) return rejected(`the ${what}s must be an array or another iterable`, "cannot-encode")
  const out = Array.from(items)
  for (let i = 0; i < out.length; i++) if (!isValue(out[i])) notAValue(`${what} ${i}`)
  return Object.freeze(out)
}

/**
 * A number (spec §2), from the text of a number literal in any spelling,
 * normalized as the parser normalizes it: `num("1E+05").text` is "1e5",
 * `num("0xFF").text` "255", `num("1_000")` "1000". Any length and exponent:
 * the limits (spec §7) are the writers' concern. Text that isn't one number
 * literal (`"01"`, `"NaN"`, `""`, `" 1"`) is HausEncodeError `invalid-number`.
 */
export const num = (literal: string): HNumber => {
  if (typeof literal !== "string") return rejected(`the text of a number must be a string, not ${typeof literal}`, "cannot-encode")
  const normalized = canonicalNumber(literal)
  return new NumberNode(normalized ?? rejected(`'${quoteText(literal)}' is not a number literal`, "invalid-number"))
}

/** A string. One with an unpaired surrogate has no UTF-8 form (spec §4): HausEncodeError `cannot-encode`. */
export const str = (s: string): HString => new StringNode(text(s, "a string"))

/**
 * A byte string, `x"0b34ff"`: a copy of `data`, so changing `data` later
 * doesn't change the value. Anything but a Uint8Array is HausEncodeError
 * `cannot-encode`.
 */
export const bytes = (data: Uint8Array): HBytes =>
  new BytesNode(data instanceof Uint8Array ? new Uint8Array(data) : rejected("a byte string must be a Uint8Array", "cannot-encode"))

/**
 * An array of values, copied (and frozen). An item that isn't a value is
 * HausEncodeError `cannot-encode`.
 */
export const arr = (items: Iterable<Value>): HArray => new ArrayNode(values(items, "item"))

/**
 * A record, its fields in the order given: a `Map`, `[key, value]` pairs or
 * a plain object, copied. A key given twice is HausEncodeError
 * `duplicate-key`; a key with an unpaired surrogate or a field that isn't a
 * value is `cannot-encode`.
 *
 *   rec({ id: num("1"), name: str("Ada") })
 *   rec([["x-y", num("1")]])
 *   rec(new Map([["a", str("x")]]))
 */
export const rec = (fields: Iterable<readonly [string, Value]> | Readonly<Record<string, Value>>): HRecord => {
  if (typeof fields !== "object" || fields === null) return rejected("the fields of a record must be a Map, [key, value] pairs or an object", "cannot-encode")
  const entries = Symbol.iterator in fields ? (fields as Iterable<readonly [string, Value]>) : Object.entries(fields)
  const out = new Map<string, Value>()
  for (const [k, v] of entries) {
    const key = text(k, "a key")
    if (!isValue(v)) notAValue(`the field '${quoteText(key)}'`)
    // One lookup: a key seen before leaves the size as it was.
    const size = out.size
    out.set(key, v)
    if (out.size === size) rejected(`duplicate key '${quoteText(key)}'`, "duplicate-key")
  }
  return new RecordNode(out)
}

/**
 * A variant: a tag (`[A-Z][A-Za-z0-9_]*`, spec §4) and its payload, none
 * (`variant("None")`), one record (`variant("Circle", [rec({ r: num("1") })])`,
 * written `Circle { r: 1 }`) or positional arguments (`variant("Point",
 * [num("1"), num("2")])`). The arguments are copied (and frozen). A tag that
 * isn't one is HausEncodeError `invalid-tag` (one with an unpaired surrogate
 * `cannot-encode`); an argument that isn't a value is `cannot-encode`.
 */
export const variant = (tag: string, args: Iterable<Value> = NO_ARGS): HVariant => {
  if (!TAG.test(text(tag, "a tag"))) rejected(`the tag '${quoteText(tag)}' is not [A-Z][A-Za-z0-9_]*`, "invalid-tag")
  return new VariantNode(tag, args === NO_ARGS ? NO_ARGS : values(args, "argument"))
}

// ── for the readers: values already checked ──────────────────
// Not exported from the package. The parser, the JSON readers and the
// decoders build values from what they have read and checked, so they skip
// the constructors' checks and copies.

export const uncheckedNum = (normalized: string): HNumber => new NumberNode(normalized)
export const uncheckedStr = (s: string): HString => new StringNode(s)
export const uncheckedBytes = (data: Uint8Array): HBytes => new BytesNode(data)
export const uncheckedArr = (items: readonly Value[]): HArray => new ArrayNode(items)
export const uncheckedVariant = (tag: string, args: readonly Value[] = NO_ARGS): HVariant => new VariantNode(tag, args)
export const uncheckedRec = (fields: ReadonlyMap<string, Value>, keySpans?: ReadonlyMap<string, readonly [number, number]>): HRecord => {
  const r = new RecordNode(fields)
  if (keySpans !== undefined) (r as { keySpans?: typeof keySpans }).keySpans = keySpans
  return r
}
