/**
 * The haus data model (spec §1, §2), and the constructors that build it in
 * code. A `Value` is always a valid haus value within the limits it was built
 * with (spec §7, §11): building one is the only step that can fail, and what
 * takes a value (the writers, `canonical`, `equals`, `hash`, `compare`) can't.
 *
 *   Value.record({ id: Value.number("0xFF"), status: Value.variant("Shipped"), tags: Value.array([Value.string("new")]) })
 *   // Success: { id: 255, status: Shipped, tags: ["new"] }
 *
 *   Value.number("01")       // Failure: HausEncodeError invalid-number
 *   Value.variant("lower")   // Failure: HausEncodeError invalid-tag
 *
 * Each container records its *size* (itself and every value inside it, each
 * counted as often as it is written: a part shared by two places counts
 * twice) and its *depth* (spec §7), when it is built. A value whose parts
 * share each other too much (x(n+1) = [x(n), x(n)]) is refused where it is
 * built (`too-many-nodes`), so every value that exists is writable.
 *
 * Values are read-only (spec §11, "Values don't change"): their types are
 * readonly, the arrays inside them frozen. Changing one anyway (a cast, a
 * Map's `set`) is a programming error; the writers notice it from the
 * recorded sizes and throw `value-changed` instead of hanging or writing
 * something else.
 */
import { quoteText, TAG, unpairedSurrogate } from "./chars.js"
import { HausEncodeError, type ErrorCode } from "./errors.js"
import { canonicalNumber, numberLimitIssue } from "./number.js"
import { DEFAULT_LIMITS, longerThan } from "./reader.js"
import { attempt, Result } from "./result.js"

/** The mark of a value the constructors built: an object literal is not a `Value`. Type-level only. */
declare const built: unique symbol

/**
 * The haus data model, exactly as written in the source. No schema has been
 * applied: numbers are their normalized literal text (spec §2), and variants
 * are generic. Build one with the `Value` constructors; narrow it by `kind`.
 */
export type Value = HNumber | HString | HBytes | HArray | HRecord | HVariant

/**
 * Source positions, only set when parsing with locations (editor tooling).
 * Offsets are UTF-16 indexes into the parsed text, `end` exclusive.
 */
export interface Located {
  readonly start?: number
  readonly end?: number
}

/** What every value has: source positions when parsed with them, its size and depth (spec §7), and the mark of a built value. */
interface Built extends Located {
  readonly [built]: true
  /** The values it is written as: itself and every value inside it, each as often as it is written (spec §7). 1 for a scalar. */
  readonly size: number
  /** The levels it needs, as values built in code count them (spec §7): 0 for a scalar, one more than its deepest part for a container. */
  readonly depth: number
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
  /** With locations: where each key starts and ends. */
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

abstract class Scalar extends Node {
  get size(): number {
    return 1
  }
  get depth(): number {
    return 0
  }
}

class NumberNode extends Scalar implements HNumber {
  declare readonly kind: "number"
  declare readonly text: string
  constructor(text: string) {
    super()
    this.kind = "number"
    this.text = text
  }
}

class StringNode extends Scalar implements HString {
  declare readonly kind: "string"
  declare readonly value: string
  constructor(value: string) {
    super()
    this.kind = "string"
    this.value = value
  }
}

class BytesNode extends Scalar implements HBytes {
  declare readonly kind: "bytes"
  declare readonly bytes: Uint8Array
  constructor(bytes: Uint8Array) {
    super()
    this.kind = "bytes"
    this.bytes = bytes
  }
}

/** The size and depth of a container of `parts` (spec §7): one more than the deepest part, one plus their sizes. */
const measure = (parts: Iterable<Value>): { size: number; depth: number } => {
  let size = 1
  let deepest = 0
  for (const p of parts) {
    size += p.size
    if (p.depth > deepest) deepest = p.depth
  }
  return { size, depth: deepest + 1 }
}

class ArrayNode extends Node implements HArray {
  declare readonly kind: "array"
  declare readonly items: readonly Value[]
  declare readonly size: number
  declare readonly depth: number
  constructor(items: readonly Value[]) {
    super()
    this.kind = "array"
    this.items = items
    const { size, depth } = measure(items)
    this.size = size
    this.depth = depth
  }
}

class RecordNode extends Node implements HRecord {
  declare readonly kind: "record"
  declare readonly fields: ReadonlyMap<string, Value>
  declare readonly keySpans?: ReadonlyMap<string, readonly [start: number, end: number]>
  declare readonly size: number
  declare readonly depth: number
  constructor(fields: ReadonlyMap<string, Value>) {
    super()
    this.kind = "record"
    this.fields = fields
    const { size, depth } = measure(fields.values())
    this.size = size
    this.depth = depth
  }
}

class VariantNode extends Node implements HVariant {
  declare readonly kind: "variant"
  declare readonly tag: string
  declare readonly args: readonly Value[]
  declare readonly size: number
  declare readonly depth: number
  constructor(tag: string, args: readonly Value[]) {
    super()
    this.kind = "variant"
    this.tag = tag
    this.args = args
    if (args.length === 0) {
      this.size = 1
      this.depth = 0
    } else {
      const { size, depth } = measure(args)
      this.size = size
      // `Tag { … }` is one level, the record's: the shorter spelling (spec §7).
      this.depth = args.length === 1 && args[0]!.kind === "record" ? args[0]!.depth : depth
    }
  }
}

/**
 * Whether `x` is a value: one the constructors built or a reader read (not
 * an object that only looks like one). A value of another copy of this
 * package, or one passed through `structuredClone`, is not.
 */
export const isValue = (x: unknown): x is Value => x instanceof Node

/** Whether `v` is a container (spec §7): an array, a record, or a variant with a payload. */
export const isContainer = (v: Value): v is HArray | HRecord | HVariant =>
  v.kind === "array" || v.kind === "record" || (v.kind === "variant" && v.args.length > 0)

// ── the constructors (spec §11, "Values built in code") ──────
// These throw HausEncodeError; the `Value` namespace below gives Results.

const NO_ARGS: readonly Value[] = Object.freeze([])
const { maxDepth: MAX_DEPTH, maxNodes: MAX_NODES, maxStringLength: MAX_STRING } = DEFAULT_LIMITS

const rejected = (reason: string, code: ErrorCode): never => {
  throw new HausEncodeError(reason, [], code)
}

/** A value built here: frozen, so that plain assignment can't change it. */
const sealed = <V extends Value>(v: V): V => Object.freeze(v)

/** Text with a UTF-8 form: a string without an unpaired surrogate (spec §4), else `cannot-encode`; within the string limit (spec §7). */
const text = (s: unknown, what: "string" | "key"): string => {
  if (typeof s !== "string") return rejected(`a ${what} must be a string, not ${typeof s}`, "cannot-encode")
  if (unpairedSurrogate(s) >= 0) return rejected(`a ${what} with an unpaired surrogate, which has no UTF-8 form`, "cannot-encode")
  if (longerThan(s, MAX_STRING)) rejected(`${what} longer than ${MAX_STRING} characters`, what === "key" ? "key-too-long" : "string-too-long")
  return s
}

/** Something where a value belongs that isn't one (an object that only looks like one is none): `cannot-encode`. */
const notAValue = (where: string): never => rejected(`${where} is not a haus value (build one with the Value constructors)`, "cannot-encode")

/** A part given to a container: a value, or a Result of building one (its failure is the container's). */
export type Part<V extends Value = Value> = V | Result<V, HausEncodeError>

/** The value of a part: a failed Result's error is thrown, as the container's. */
const partValue = (p: unknown, where: string): Value => {
  if (isValue(p)) return p
  if (Result.isResult(p)) {
    if (p._tag === "Failure") throw p.failure
    if (isValue(p.success)) return p.success
  }
  return notAValue(where)
}

/** `items` copied and frozen, each a value. */
const values = (items: Iterable<Part>, what: "item" | "argument"): readonly Value[] => {
  if (typeof items !== "object" || items === null || !(Symbol.iterator in items)) return rejected(`the ${what}s must be an array or another iterable`, "cannot-encode")
  return Object.freeze(Array.from(items, (x, i) => partValue(x, `${what} ${i}`)))
}

/** A container built here, within the depth and node limits (spec §7). */
const within = <V extends HArray | HRecord | HVariant>(v: V): V => {
  if (v.depth > MAX_DEPTH) rejected(`value nested deeper than ${MAX_DEPTH} levels`, "nesting-too-deep")
  if (v.size > MAX_NODES) rejected(`value of more than ${MAX_NODES} nodes (its parts share each other: written out, it would be larger than the node limit)`, "too-many-nodes")
  return sealed(v)
}

/**
 * A number (spec §2), from the text of a number literal in any spelling,
 * normalized as the parser normalizes it: `num("1E+05").text` is "1e5",
 * `num("0xFF").text` "255", `num("1_000")` "1000". A JS number or bigint is
 * taken by its text (`num(1)`, `num(10n ** 30n)`). Text that isn't one
 * number literal (`"01"`, `"NaN"`, `""`, `" 1"`) is `invalid-number`; one
 * beyond the number limits, on its normalized literal, `number-too-long` or
 * `exponent-too-large` (spec §7). Throws HausEncodeError.
 */
export const num = (literal: string | number | bigint): HNumber => {
  const source = typeof literal === "number" || typeof literal === "bigint" ? String(literal) : literal
  if (typeof source !== "string") return rejected(`the text of a number must be a string, not ${typeof literal}`, "cannot-encode")
  const normalized = canonicalNumber(source) ?? rejected(`'${quoteText(source)}' is not a number literal`, "invalid-number")
  const issue = numberLimitIssue(normalized, DEFAULT_LIMITS)
  if (issue !== undefined) rejected(issue.reason, issue.code)
  return sealed(new NumberNode(normalized))
}

/** A string. One with an unpaired surrogate has no UTF-8 form (spec §4): `cannot-encode`. Throws HausEncodeError. */
export const str = (s: string): HString => sealed(new StringNode(text(s, "string")))

/**
 * A byte string, `x"0b34ff"`: a copy of `data`, so changing `data` later
 * doesn't change the value. Anything but a Uint8Array is `cannot-encode`.
 * Throws HausEncodeError.
 */
export const bytes = (data: Uint8Array): HBytes => {
  if (!(data instanceof Uint8Array)) return rejected("a byte string must be a Uint8Array", "cannot-encode")
  if (data.length * 2 > MAX_STRING) rejected(`byte string longer than ${MAX_STRING} hex digits`, "string-too-long")
  return sealed(new BytesNode(new Uint8Array(data)))
}

/** An array of values, copied (and frozen). An item that isn't a value is `cannot-encode`. Throws HausEncodeError. */
export const arr = (items: Iterable<Part>): HArray => within(new ArrayNode(values(items, "item")))

/**
 * A record, its fields in the order given: a `Map`, `[key, value]` pairs or
 * a plain object, copied. A key given twice is `duplicate-key`; a key with
 * an unpaired surrogate or a field that isn't a value is `cannot-encode`.
 * Throws HausEncodeError.
 *
 *   rec({ id: num("1"), name: str("Ada") })
 *   rec([["x-y", num("1")]])
 */
export const rec = (fields: Iterable<readonly [string, Part]> | Readonly<Record<string, Part>>): HRecord => {
  if (typeof fields !== "object" || fields === null) return rejected("the fields of a record must be a Map, [key, value] pairs or an object", "cannot-encode")
  const entries = Symbol.iterator in fields ? (fields as Iterable<readonly [string, Part]>) : Object.entries(fields)
  const out = new Map<string, Value>()
  for (const [k, v] of entries) {
    const key = text(k, "key")
    const value = partValue(v, `the field '${quoteText(key)}'`)
    // One lookup: a key seen before leaves the size as it was.
    const size = out.size
    out.set(key, value)
    if (out.size === size) rejected(`duplicate key '${quoteText(key)}'`, "duplicate-key")
  }
  return within(new RecordNode(out))
}

/**
 * A variant: a tag (`[A-Z][A-Za-z0-9_]*`, spec §4) and its payload, none
 * (`variant("None")`), one record (`variant("Circle", [rec({ r: num("1") })])`,
 * written `Circle { r: 1 }`) or positional arguments (`variant("Point",
 * [num("1"), num("2")])`). The arguments are copied (and frozen). A tag that
 * isn't one is `invalid-tag` (one with an unpaired surrogate too: the tag is
 * checked before it is encoded, spec §11), one longer than the string limit
 * `tag-too-long`; a tag that isn't a string, or an argument that isn't a
 * value, is `cannot-encode`. Throws HausEncodeError.
 */
export const variant = (tag: string, args: Iterable<Part> = NO_ARGS): HVariant => {
  if (typeof tag !== "string") rejected(`a tag must be a string, not ${typeof tag}`, "cannot-encode")
  // Tags are ASCII: their length is their number of characters.
  if (tag.length > MAX_STRING && TAG.test(tag)) rejected(`tag longer than ${MAX_STRING} characters`, "tag-too-long")
  if (!TAG.test(tag)) rejected(`the tag '${quoteText(tag)}' is not [A-Z][A-Za-z0-9_]*`, "invalid-tag")
  const parts = args === NO_ARGS ? NO_ARGS : values(args, "argument")
  return parts.length === 0 ? sealed(new VariantNode(tag, NO_ARGS)) : within(new VariantNode(tag, parts))
}

const isEncodeError = (e: unknown): e is HausEncodeError => e instanceof HausEncodeError

/**
 * The constructors of values built in code (spec §11), each giving a Result:
 * the value, or the mistake with its code (spec §17). Children may be values
 * or the Results of building them; the first failure is the container's.
 *
 *   Value.record({ id: Value.number(1), status: Value.variant("Paid") })   // Result<HRecord, HausEncodeError>
 *   Value.number("0xFF")      // Success: 255
 *   Value.variant("lower")    // Failure: invalid-tag
 */
export const Value = Object.freeze({
  /** A number from a literal in any spelling (normalized), or a JS number or bigint by its text. */
  number: (literal: string | number | bigint): Result<HNumber, HausEncodeError> => attempt(() => num(literal), isEncodeError),
  /** A string. */
  string: (s: string): Result<HString, HausEncodeError> => attempt(() => str(s), isEncodeError),
  /** A byte string, a copy of `data`. */
  bytes: (data: Uint8Array): Result<HBytes, HausEncodeError> => attempt(() => bytes(data), isEncodeError),
  /** An array. */
  array: (items: Iterable<Part>): Result<HArray, HausEncodeError> => attempt(() => arr(items), isEncodeError),
  /** A record, from a Map, `[key, value]` pairs or a plain object. */
  record: (fields: Iterable<readonly [string, Part]> | Readonly<Record<string, Part>>): Result<HRecord, HausEncodeError> => attempt(() => rec(fields), isEncodeError),
  /** A variant: a tag and its arguments (one record for `Tag { … }`). */
  variant: (tag: string, args?: Iterable<Part>): Result<HVariant, HausEncodeError> => attempt(() => variant(tag, args), isEncodeError),
  /** Whether `x` is a value built by these constructors or read by a reader. */
  is: isValue,
})

// ── for the readers: values already checked ──────────────────
// Not exported from the package. The parser, the JSON readers and the
// encoders build values from what they have read and checked, so they skip
// the constructors' checks and copies; sizes and depths are recorded all the same.

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
