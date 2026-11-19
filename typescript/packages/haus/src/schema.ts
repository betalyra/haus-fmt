/**
 * Schemas in code: describe the expected shape once, get a TypeScript type
 * and a decoder from the generic haus `Value` tree into plain JS values.
 *
 *   import * as h from "@haus-fmt/haus/schema"
 *   const User = h.Record({ id: h.Int, name: h.String })
 *   type User = h.Infer<typeof User>
 *   const user = h.parse(User, text)
 *
 * Decoding never loses precision silently: `Int` is a bigint of any size,
 * `Int32` etc. are JS numbers in their range, `Decimal` keeps the exact literal text.
 *
 * Every schema also encodes: `h.stringify(User, user)` writes haus text,
 * `h.encodeStream(Event, events)` writes a stream. `h.toJson(User, user)`
 * and `h.fromJson(User, json)` write and read schema-based JSON (spec §16.3).
 *
 * Decoding is linear in the input whatever the schema (spec §9.8): variants
 * dispatch on the tag, depth is limited, and every call has a work budget.
 * Types that contain themselves are declared with `h.Recursive`.
 */
import { HausDecodeError, HausEncodeError, payloadHint, START, type CasePayload, type ErrorCode, type ErrorDetails, type Path } from "./errors.js"
import { format, stringify as stringifyValue, type FormatOptions } from "./format.js"
import { INTEGER, normalizeNumber, numberLimitIssue } from "./number.js"
import { checkLimits, longerThan, Parser, withDefaults, type Limits as ValueLimits } from "./parser.js"
import { parseStream, type ChunkSource } from "./stream.js"
import { checkStdTime, type StdTimeType } from "./std-time.js"
import { floatValue, specialFloat, toFloat, type FloatType } from "./float.js"
import { arr, bytes as bytesValue, num, rec, str, variant, type HNumber, type HRecord, type HVariant, type Value } from "./value.js"
import { issuesOf, type StandardSchemaV1 } from "./standard.js"
import { atJsonPlace, jsonTextLimits, parseJson, Place, readJson, readLines, stringifyJson, type Json, type JsonLinesOptions, type JsonPlaces } from "./json.js"
import { fromSchemaBasedJson, toSchemaBasedJson, type JsonCase, type JsonRecordType, type JsonType } from "./json-schema-based.js"
import { Secret as SecretValue } from "./secret.js"

export type { Json, JsonType, Value }

// ── core ─────────────────────────────────────────────────────

export { errorCode, errorJson, formatPath, HausDecodeError, HausEncodeError, type ErrorCode, type ErrorJson, type Path } from "./errors.js"

/**
 * Limits for one decode or encode call. They hold whatever the schema looks
 * like, so a mistake in a schema (or a hostile input meeting a recursive one)
 * ends in an error instead of exhausting CPU, memory or the stack.
 */
export interface Limits extends Partial<ValueLimits> {
  /**
   * Deepest nesting of values (default 256, the parser's limit), at most
   * MAX_SUPPORTED_DEPTH (512): a larger one is a RangeError naming it.
   */
  readonly maxDepth?: number
  /**
   * Most schema steps (one per schema applied to a value). Decoding defaults
   * to 16 per value in the input plus 1024, so decoding is linear in the
   * input. Encoding defaults to 16 Mi steps, which also bounds values that
   * share sub-objects (a DAG of depth 64 would otherwise expand to 2^64 nodes).
   */
  readonly maxSteps?: number
  // The parser's limits (maxNumberLength, maxExponent, maxStringLength, default
  // DEFAULT_LIMITS) apply when `parse` reads the text, and when a raw value
  // (an `Any`, an unknown variant) is written again (spec §9.8): pass the same
  // limits to both, and a parsed value always encodes again.
}

const DEFAULT_MAX_DEPTH = 256
const STEPS_PER_VALUE = 16
const DEFAULT_ENCODE_STEPS = 16 * 1024 * 1024

interface Context {
  readonly mode: "decode" | "encode"
  /** The parser's limits, for raw values. */
  readonly values: ValueLimits
  readonly maxDepth: number
  readonly maxSteps: number
  steps: number
  /** Per `h.Recursive`: how deeply it is nested, and the value it was last entered with. */
  readonly recursion: Map<object, { depth: number; current: unknown }>
  /** Encoding: the objects being encoded on the current path, to detect cycles. */
  readonly ancestors: Set<object>
}

/**
 * Where a schema is applied: the path (linked to its parent and only turned
 * into an array when an error is reported), the depth, and the limits shared
 * by the whole call. Schemas receive it and pass `at.child(key)` down.
 */
export class At {
  private constructor(
    private readonly ctx: Context,
    private readonly parent: At | undefined,
    private readonly key: string | number | undefined,
    readonly depth: number,
  ) {}

  /** @internal */
  static root(ctx: Context, key?: string | number): At {
    return new At(ctx, undefined, key, 0)
  }

  /** The position of a child value. Fails beyond the depth limit. */
  child(key: string | number): At {
    if (this.depth >= this.ctx.maxDepth) this.reject("nesting-too-deep", `nesting deeper than ${this.ctx.maxDepth} levels`, { key })
    return new At(this.ctx, this, key, this.depth + 1)
  }

  /**
   * The record payload of `Tag { … }`: the same nesting level as the variant,
   * as the parser counts it (one level for `Tag {`).
   */
  payload(key: string | number): At {
    return new At(this.ctx, this, key, this.depth)
  }

  /** Opening a container here: fails if it would nest deeper than the limit, as in the parser. */
  open(): void {
    if (this.depth >= this.ctx.maxDepth) this.reject("nesting-too-deep", `nesting deeper than ${this.ctx.maxDepth} levels`)
  }

  /** The parser's limits for this call, for checking raw values (spec §9.8). */
  get limits(): ValueLimits {
    return this.ctx.values
  }

  /** Count one schema step. Fails when the budget is used up. */
  step(): void {
    if (++this.ctx.steps > this.ctx.maxSteps) {
      this.reject("step-budget", `${this.ctx.mode} budget of ${this.ctx.maxSteps} steps exceeded (a schema doing more work than the input justifies)`)
    }
  }

  path(): Path {
    const out: (string | number)[] = []
    for (let at: At | undefined = this; at; at = at.parent) if (at.key !== undefined) out.push(at.key)
    return out.reverse()
  }

  /**
   * Fail here (or at the child `childKey`), for schemas written by hand: the
   * code is `type-mismatch` when decoding and `cannot-encode` when encoding.
   * `reject` takes the code.
   */
  fail(reason: string, childKey?: string | number): never {
    return this.reject(this.ctx.mode === "decode" ? "type-mismatch" : "cannot-encode", reason, childKey === undefined ? {} : { key: childKey })
  }

  /** Fail here (or at the child `details.key`) with an error code (spec §17). */
  reject(code: ErrorCode, reason: string, details: ErrorDetails & { readonly key?: string | number | undefined } = {}): never {
    const { key, ...rest } = details
    const path = key === undefined ? this.path() : [...this.path(), key]
    throw this.ctx.mode === "decode" ? new HausDecodeError(reason, path, code, rest) : new HausEncodeError(reason, path, code, rest)
  }

  /** @internal Bookkeeping for `h.Recursive`. */
  recursion(schema: object) {
    let state = this.ctx.recursion.get(schema)
    if (!state) this.ctx.recursion.set(schema, (state = { depth: 0, current: NOTHING }))
    return state
  }

  /** Encoding: is `value` an object currently being encoded further up? */
  isEncoding(value: unknown): boolean {
    return typeof value === "object" && value !== null && this.ctx.ancestors.has(value)
  }

  /** Encoding: run `f` with `obj` marked as being encoded; a cycle back to it fails. */
  enter<R>(obj: unknown, f: () => R): R {
    if (typeof obj !== "object" || obj === null) return f()
    if (this.ctx.ancestors.has(obj)) this.reject("cyclic-value", "cyclic value: an object contains itself")
    this.ctx.ancestors.add(obj)
    try {
      return f()
    } finally {
      this.ctx.ancestors.delete(obj)
    }
  }
}

const NOTHING = Symbol("nothing")

const context = (mode: "decode" | "encode", maxSteps: number, limits: Limits): Context => ({
  mode,
  values: withDefaults(limits),
  maxDepth: limits.maxDepth ?? DEFAULT_MAX_DEPTH,
  maxSteps: limits.maxSteps ?? maxSteps,
  steps: 0,
  recursion: new Map(),
  ancestors: new Set(),
})

/** A container, as the parser counts levels: an array, a record, or a variant with arguments (empty or not). */
const isContainer = (v: Value): boolean => v.kind === "array" || v.kind === "record" || (v.kind === "variant" && v.args.length > 0)

/** A container being counted by `countValues`. */
interface Counting {
  readonly value: Value
  readonly depth: number
  /** Its children: an array's items or a variant's arguments by index, a record's fields by iterator. */
  readonly items: ReadonlyArray<Value> | undefined
  readonly fields: Iterator<Value> | undefined
  next: number
  /** `Tag { … }`: its record is at its own level, as in the parser; `Tag(a, b)` nests its arguments. */
  readonly payload: boolean
  /** Values in it, counting a shared one each time it is reached. */
  size: number
  /** Levels it needs, its own included. */
  need: number
  /** Whether it holds containers: only then can it be in a cycle, and is it remembered. */
  holds: boolean
}

/** How `countValues` marks a container while counting it: reaching it again is a cycle. */
const OPEN = { size: 0, need: 0 }

/**
 * Count the values in a tree, failing beyond `maxDepth` or `cap` values. A
 * parsed value is a tree within the parser's limits; a `Value` built in code
 * might be deeper, share nodes (a DAG) or even contain itself. A shared
 * value counts each time it is reached, as decoding visits it, but is walked
 * once: its count and the levels it needs are remembered, so a DAG that
 * expands beyond `cap` fails at once instead of after `cap` steps.
 */
const countValues = (root: Value, maxDepth: number, cap: number, at: At): number => {
  const tooMany = () => at.reject("too-many-nodes", `value has more than ${cap} nodes`)
  const tooDeep = () => at.reject("nesting-too-deep", `value nested deeper than ${maxDepth} levels`)
  if (!isContainer(root)) return 1
  /** Containers holding containers, counted (or `OPEN`, being counted). */
  const known = new Map<Value, { readonly size: number; readonly need: number }>()
  const stack: Counting[] = []
  const enter = (v: Value, depth: number) => {
    // A container here is one level more, as the parser counts it.
    if (depth >= maxDepth) tooDeep()
    const items = v.kind === "array" ? v.items : v.kind === "variant" ? v.args : undefined
    const fields = v.kind === "record" ? v.fields.values() : undefined
    const payload = v.kind === "variant" && v.args.length === 1 && v.args[0]!.kind === "record"
    stack.push({ value: v, depth, items, fields, next: 0, payload, size: 1, need: 1, holds: false })
  }
  enter(root, 0)
  for (;;) {
    const top = stack[stack.length - 1]!
    let child: Value
    if (top.items !== undefined && top.next < top.items.length) child = top.items[top.next++]!
    else {
      const field = top.fields?.next()
      if (field !== undefined && field.done !== true) child = field.value
      else {
        stack.pop()
        if (top.holds) known.set(top.value, { size: top.size, need: top.need })
        const parent = stack[stack.length - 1]
        if (parent === undefined) return top.size
        parent.size += top.size
        parent.need = Math.max(parent.need, top.depth - parent.depth + top.need)
        if (parent.size > cap) tooMany()
        continue
      }
    }
    if (!isContainer(child)) {
      if (++top.size > cap) tooMany()
      continue
    }
    if (!top.holds) {
      top.holds = true
      known.set(top.value, OPEN)
    }
    const seen = known.get(child)
    // A value that contains itself nests without end.
    if (seen === OPEN) tooDeep()
    const depth = top.payload ? top.depth : top.depth + 1
    if (seen === undefined) enter(child, depth)
    else {
      if (depth + seen.need > maxDepth) tooDeep()
      top.size += seen.size
      top.need = Math.max(top.need, depth - top.depth + seen.need)
      if (top.size > cap) tooMany()
    }
  }
}

/** Values beyond this are rejected before decoding (the parser's 64 Mi characters can't produce more). */
const MAX_VALUES = 64 * 1024 * 1024

const decodeAt = (value: Value, limits: Limits, key?: string | number): At => {
  if (limits.maxSteps !== undefined) return decodeWithin(limits, 0, key)
  const maxDepth = limits.maxDepth ?? DEFAULT_MAX_DEPTH
  const probe = At.root(context("decode", Infinity, limits), key)
  return decodeWithin(limits, countValues(value, maxDepth, MAX_VALUES, probe), key)
}

/** Decoding a value of `size` values (counted by `countValues`, or by the parser that read it: a tree within the limits). */
const decodeWithin = (limits: Limits, size: number, key?: string | number): At =>
  At.root(context("decode", limits.maxSteps ?? STEPS_PER_VALUE * size + 1024, limits), key)

const encodeAt = (limits: Limits, key?: string | number): At => At.root(context("encode", DEFAULT_ENCODE_STEPS, limits), key)

/**
 * Every schema is also a Standard Schema (standard.ts), so it plugs into
 * libraries that accept one. Its input is haus: a text holding exactly one
 * value, or a parsed `Value`.
 */
export interface Schema<A> extends StandardSchemaV1<string | Value, A> {
  /** Human-readable description used in error messages. */
  readonly expected: string
  readonly decode: (value: Value, at: At) => A
  readonly encode: (value: A, at: At) => Value
  /**
   * Set by `h.Optional`: as a record field, it may be missing (`name?: T`).
   * A missing field stays missing in the decoded object; it never becomes
   * `None` or any other value (spec §1).
   */
  readonly optional?: true | undefined
  /**
   * The schema-based JSON form of the type (spec §16.3), for `h.toJson` and
   * `h.fromJson`. Every schema of this module has one; a schema written by
   * hand without one has no schema-based JSON form.
   */
  readonly json?: JsonType | undefined
}

/** The schema-based JSON form of a schema: its own, or none. */
export const jsonType = (schema: AnySchema): JsonType => schema.json ?? { kind: "none", expected: schema.expected }

export type Infer<S> = S extends Schema<infer A> ? A : never

/** Any schema; schemas both produce and consume their type, so `Schema<unknown>` won't do as a bound. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type AnySchema = Schema<any>

const describe = (v: Value): string => {
  switch (v.kind) {
    case "number": return `number ${v.text.length > 30 ? v.text.slice(0, 30) + "…" : v.text}`
    case "string": return `string ${JSON.stringify(v.value.length > 30 ? v.value.slice(0, 30) + "…" : v.value)}`
    case "bytes": return `bytes (${v.bytes.length})`
    case "array": return "array"
    case "record": return "record"
    case "variant": return `variant ${v.tag}`
  }
}

/** A short description of a JS value for encode errors. Never calls the value's own methods. */
const describeJs = (value: unknown): string => {
  switch (typeof value) {
    case "string": return JSON.stringify(value.length > 30 ? value.slice(0, 30) + "…" : value)
    case "number":
    case "bigint":
    case "boolean":
    case "undefined": return String(value)
    case "symbol": return "a symbol"
    case "function": return "a function"
    default: return value === null ? "null" : Array.isArray(value) ? `an array of ${value.length}` : "an object"
  }
}

const mismatch = (expected: string, v: Value, at: At, code: ErrorCode = "type-mismatch", hint?: string): never =>
  at.reject(code, `expected ${expected}, found ${describe(v)}`, { expected, found: describe(v), ...(hint === undefined ? {} : { hint }) })

/**
 * For a closed variant with these tags (`Bool`, `Maybe`, an enum): an unknown
 * tag is `unknown-tag`, a known one with the wrong payload `wrong-payload`
 * (its hint says what the tag's case takes: `takes`, or no payload), anything
 * else a mismatch.
 */
const notCase = (expected: string, v: Value, at: At, tags: ReadonlySet<string>, takes: (tag: string) => CasePayload = () => ({ kind: "none" })): never =>
  v.kind !== "variant" ? mismatch(expected, v, at)
  : tags.has(v.tag) ? mismatch(expected, v, at, "wrong-payload", payloadHint(v.tag, takes(v.tag)))
  : mismatch(expected, v, at, "unknown-tag")

const BOOL_TAGS: ReadonlySet<string> = new Set(["True", "False"])
const MAYBE_TAGS: ReadonlySet<string> = new Set(["None", "Some"])

/** For an integer type: a number with a fraction or an exponent is `not-an-integer`, anything else a mismatch. */
const notInteger = (expected: string, v: Value, at: At): never => mismatch(expected, v, at, v.kind === "number" ? "not-an-integer" : "type-mismatch")

/** The `~standard` property of a schema: validate haus text or a parsed Value. */
const standard = <A>(self: () => Schema<A>): StandardSchemaV1.Props<string | Value, A> => ({
  version: 1,
  vendor: "haus",
  validate: (input) => {
    try {
      if (typeof input === "string") return { value: parse(self(), input) }
      if (isValueNode(input)) return { value: decode(self(), input) }
      return { issues: [{ message: "expected haus text or a parsed haus Value" }] }
    } catch (e) {
      return issuesOf(e)
    }
  },
})

/** A schema written by hand (`expected`, `decode`, `encode`), made a Standard Schema too. */
export const withStandard = <A, S extends Omit<Schema<A>, "~standard">>(schema: S & Omit<Schema<A>, "~standard">): S & Schema<A> => {
  const self = { ...schema, "~standard": standard(() => self) } as S & Schema<A>
  return self
}

/**
 * `schema` with a rule beyond it, as a codec adds one (spec §13.4): a value
 * that `check` rejects is an error when decoding (`type-mismatch`) and when
 * encoding (`cannot-encode`). `check` returns undefined, or why it rejects
 * the value. Accepted values are written as `schema` writes them.
 *
 *   const Currency = h.refine(h.AnyTag, (c) => (typeof c === "string" && /^[A-Z]{3}$/.test(c) ? undefined : "three letters A–Z"))
 */
export const refine = <A>(schema: Schema<A>, check: (value: A) => string | undefined): Schema<A> =>
  withStandard<A, Omit<Schema<A>, "~standard">>({
    expected: schema.expected,
    json: schema.json,
    decode: (v, at) => {
      const a = schema.decode(v, at)
      const why = check(a)
      return why === undefined ? a : at.fail(why)
    },
    encode: (a, at) => {
      const why = check(a)
      return why === undefined ? schema.encode(a, at) : at.fail(why)
    },
  })

/** A schema from its decoder and encoder; every application counts one step. */
const make = <A>(expected: string, decode: (value: Value, at: At) => A, encode: (value: A, at: At) => Value, json: JsonType): Schema<A> => {
  const self: Schema<A> = {
  "~standard": standard(() => self),
  expected,
  json,
  decode: (v, at) => {
    at.step()
    return decode(v, at)
  },
  encode: (a, at) => {
    at.step()
    return encode(a, at)
  },
  }
  return self
}

const invalid = (what: string, value: unknown, at: At): never =>
  at.reject("cannot-encode", `expected ${what}, got ${describeJs(value)}`, { expected: what, found: describeJs(value) })

// ── scalars ──────────────────────────────────────────────────

const string_ = make(
  "String",
  (v, p) => (v.kind === "string" ? v.value : mismatch("String", v, p)),
  (s, p) => (typeof s === "string" ? str(s) : invalid("a string", s, p)),
  { kind: "string" },
)

const short = (text: string) => (text.length > 30 ? text.slice(0, 30) + "…" : text)
/** A type's description inside another's, at most 80 characters. */
const brief = (text: string) => (text.length > 80 ? text.slice(0, 79) + "…" : text)

/**
 * An integer as a number value, always decimal (spec §11): one longer than
 * the number limit of the reader written for can't be written (spec §7).
 */
const integer = (text: string, at: At): HNumber =>
  text.length > at.limits.maxNumberLength ? at.reject("number-too-long", `number literal longer than ${at.limits.maxNumberLength} characters`) : num(text)

/** Any integer, as a bigint (the prelude's arbitrary-size `Int`). */
const int = make(
  "Int",
  (v, p) => (v.kind === "number" && INTEGER.test(v.text) ? BigInt(v.text) : notInteger("Int", v, p)),
  (n, p) => (typeof n === "bigint" ? integer(n.toString(), p) : invalid("a bigint", n, p)),
  { kind: "integer", quoted: true },
)

/** A bounded integer as a JS number (Int8 … UInt32). Out of range is an error. */
const smallInt = (name: string, min: number, max: number) =>
  make(name, (v, p) => {
    if (v.kind !== "number" || !INTEGER.test(v.text)) return notInteger(name, v, p)
    const n = Number(v.text) + 0 // exact within these ranges (a longer literal is out of range anyway); + 0 turns -0 into 0
    return n >= min && n <= max ? n : p.reject("out-of-range", `${short(v.text)} is out of range for ${name} (${min} to ${max})`, { expected: `${name} (${min} to ${max})`, found: short(v.text) })
  }, (n, p) => (typeof n === "number" && Number.isInteger(n) && n >= min && n <= max ? integer(String(n), p) : invalid(`an integer from ${min} to ${max}`, n, p)), { kind: "integer", quoted: false })

/** A bounded integer as a bigint (Int64, UInt64). Out of range is an error. */
const bigInt = (name: string, min: bigint, max: bigint) =>
  make(name, (v, p) => {
    if (v.kind !== "number" || !INTEGER.test(v.text)) return notInteger(name, v, p)
    const n = BigInt(v.text)
    return n >= min && n <= max ? n : p.reject("out-of-range", `${short(v.text)} is out of range for ${name} (${min} to ${max})`, { expected: `${name} (${min} to ${max})`, found: short(v.text) })
  }, (n, p) => (typeof n === "bigint" && n >= min && n <= max ? integer(n.toString(), p) : invalid(`a bigint from ${min} to ${max}`, n, p)), { kind: "integer", quoted: true, bounded: true })

const int8 = smallInt("Int8", -128, 127)
const int16 = smallInt("Int16", -32768, 32767)
const int32 = smallInt("Int32", -2147483648, 2147483647)
const uint8 = smallInt("UInt8", 0, 255)
const uint16 = smallInt("UInt16", 0, 65535)
const uint32 = smallInt("UInt32", 0, 4294967295)
const int64 = bigInt("Int64", -(2n ** 63n), 2n ** 63n - 1n)
const uint64 = bigInt("UInt64", 0n, 2n ** 64n - 1n)

/** @deprecated Use `Int`, which is a bigint of any size. */
const bigint_ = int

/**
 * Binary floating point (spec §15): the nearest value, too large is an error.
 * Also `NaN`, `Infinity`, `NegInfinity` (prelude). Written in one spelling:
 * the fewest digits that read back as the same value.
 */
const float = (name: FloatType) => make(
  name,
  (v, p) =>
    v.kind === "number" ? (toFloat(v.text, name) ?? p.reject("out-of-range", `${short(v.text)} is too large for ${name}`, { expected: name, found: short(v.text) }))
    : (specialFloat(v) ?? mismatch(name, v, p)),
  (n, p) => (typeof n === "number" ? (floatValue(n, name) ?? invalid(`a number within the range of ${name}`, n, p)) : invalid("a number", n, p)),
  { kind: "float" },
)

const float64 = float("Float64")
/** A binary32 value, as a JS number (an exact `Math.fround` value). */
const float32 = float("Float32")

/**
 * Exact decimal, returned as its normalized literal text (e.g. "19.90",
 * "1.5e3"): any number, scale and exponent kept. Pass it to a decimal library.
 */
const decimal = make(
  "Decimal",
  (v, p) => (v.kind === "number" ? v.text : mismatch("Decimal", v, p)),
  (d, p) => numberFromText(d, 'a decimal string like "19.90"', p),
  { kind: "decimal" },
)

/**
 * A number given as literal text (a `Decimal`, a number in a raw value) as a
 * number value: normalized as the parser would (`1E5` → `1e5`, `0xFF` →
 * `255`), and within the call's limits (spec §9.8).
 */
const numberFromText = (text: unknown, expected: string, at: At): HNumber => {
  const normalized = typeof text === "string" ? normalizeNumber(text, at.limits) : undefined
  if (normalized === undefined) return invalid(expected, text, at)
  const issue = numberLimitIssue(normalized, at.limits)
  return issue === undefined ? num(normalized) : at.reject(issue.code, issue.reason)
}

const bool = make(
  "Bool",
  (v, p) =>
    v.kind === "variant" && v.args.length === 0 && (v.tag === "True" || v.tag === "False")
      ? v.tag === "True"
      : notCase("Bool (True | False)", v, p, BOOL_TAGS),
  (b, p) => (typeof b === "boolean" ? variant(b ? "True" : "False") : invalid("a boolean", b, p)),
  { kind: "bool" },
)

/** A byte string, `x"0b34ff"`, as a Uint8Array. */
const bytes_ = make(
  "Bytes",
  (v, p) => (v.kind === "bytes" ? v.bytes : mismatch("Bytes", v, p)),
  (b, p) => (b instanceof Uint8Array ? bytesValue(b) : invalid("a Uint8Array", b, p)),
  { kind: "bytes" },
)

/** A prelude scalar: `Tag("text")` where the text must match `format`. */
const taggedString = <A>(tag: string, format: RegExp, convert: (s: string) => A | undefined, toText: (a: A) => string) =>
  make(tag, (v, p) => {
    if (v.kind !== "variant" || v.tag !== tag) return mismatch(`${tag}("…")`, v, p)
    const arg = v.args[0]
    if (v.args.length !== 1 || arg?.kind !== "string") return mismatch(`${tag}("…")`, v, p)
    const out = format.test(arg.value) ? convert(arg.value) : undefined
    if (out === undefined) return p.reject("invalid-time", `invalid ${tag} ${JSON.stringify(arg.value.length > 40 ? arg.value.slice(0, 40) + "…" : arg.value)}`, { key: 0 })
    return out
  }, (a, p) => {
    const text = toText(a)
    if (!format.test(text) || convert(text) === undefined) return invalid(`a valid ${tag}`, text, p)
    return variant(tag, [str(text)])
  }, { kind: "time", tag })

/** `Date("2026-11-07")`, returned as the validated ISO string. */
const date = taggedString("Date", /^\d{4}-\d{2}-\d{2}$/, (s) => (checkStdTime("Date", s) === undefined ? s : undefined), (s) => s)

/**
 * `Instant("2026-11-07T10:00:00Z")` as a JS Date, for applications that want
 * one. Lossy (spec §13.4): a Date keeps the instant in milliseconds, not the
 * offset or the fraction as written, so `Instant("…10:00:00.250+01:00")` is
 * written back as `Instant("…09:00:00.250Z")`, a different haus value with
 * another hash. `h.Instant` keeps the text.
 */
export const InstantAsDate: Schema<globalThis.Date> = taggedString(
  "Instant",
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/,
  (s) => (checkStdTime("Instant", s) === undefined ? new globalThis.Date(s) : undefined),
  (d) => (d instanceof globalThis.Date && !isNaN(d.getTime()) ? d.toISOString() : String(d)),
)

/**
 * Any std/time type as its validated text, exactly as written:
 * `Time("09:30:00")` → "09:30:00", `Duration("PT48H")` → "PT48H". Encoding
 * writes it back unchanged, offsets and fractions included.
 */
export const StdTime = (type: StdTimeType): Schema<string> =>
  taggedString(type, /^/, (s) => (checkStdTime(type, s) === undefined ? s : undefined), (s) => s)

/** `Instant("2026-11-07T10:00:00.250+01:00")` → "2026-11-07T10:00:00.250+01:00", as written. For a JS Date, `h.InstantAsDate`. */
const instant = StdTime("Instant")

export {
  bigint_ as BigInt,
  bool as Bool,
  bytes_ as Bytes,
  date as Date,
  decimal as Decimal,
  float32 as Float32,
  float64 as Float64,
  instant as Instant,
  int as Int,
  int8 as Int8,
  int16 as Int16,
  int32 as Int32,
  int64 as Int64,
  string_ as String,
  uint8 as UInt8,
  uint16 as UInt16,
  uint32 as UInt32,
  uint64 as UInt64,
}

// ── containers ───────────────────────────────────────────────

const array_ = <A>(item: Schema<A>): Schema<readonly A[]> =>
  make<readonly A[]>(
    `Array ${item.expected}`,
    (v, p) => (v.kind === "array" ? v.items.map((x, i) => item.decode(x, p.child(i))) : mismatch(`Array ${item.expected}`, v, p)),
    (xs, p) => {
      if (!Array.isArray(xs)) return invalid("an array", xs, p)
      p.open()
      return p.enter(xs, () => arr((xs as readonly A[]).map((x, i) => item.encode(x, p.child(i)))))
    },
    { kind: "array", item: jsonType(item) },
  )

export { array_ as Array }

/**
 * A record used as a dictionary: any string keys, one value type
 * (`Map v` in the prelude). `{ en: "Hello", "pt-BR": "Olá" }` →
 * `Map { "en" => "Hello", "pt-BR" => "Olá" }`. A JS Map, so keys like
 * `__proto__` are plain data.
 */
const map_ = <A>(value: Schema<A>): Schema<ReadonlyMap<string, A>> =>
  make<ReadonlyMap<string, A>>(
    `Map ${value.expected}`,
    (v, p) => {
      if (v.kind !== "record") return mismatch(`Map ${value.expected} (a record)`, v, p)
      const out = new Map<string, A>()
      for (const [k, x] of v.fields) out.set(k, value.decode(x, p.child(k)))
      return out
    },
    (m, p) => {
      if (!(m instanceof Map)) return invalid("a Map", m, p)
      p.open()
      return p.enter(m, () => rec(new Map([...m].map(([k, x]) => {
        if (typeof k !== "string") return invalid("string keys", k, p)
        return [k, value.encode(x, p.child(k))] as const
      }))))
    },
    { kind: "map", value: jsonType(value) },
  )

export { map_ as Map }

/**
 * `Maybe a`: `None` → `{ _tag: "None" }`, `Some(x)` → `{ _tag: "Some", value: x }`,
 * like every other variant with one argument. Tagged, never `x | null`, so
 * that `Maybe (Maybe Int)` keeps `None` and `Some(None)` apart. Always written
 * out in the data: `Maybe` is an ordinary variant, and a missing field is not
 * `None` (use `h.Optional`: `h.Optional(h.Maybe(T))` has three states, key
 * missing, None and Some).
 *
 *   const note = h.parse(h.Maybe(h.String), `Some("gift")`)   // { _tag: "Some", value: "gift" }
 *   h.Maybe.toNullable(note)                                   // "gift"
 *   h.stringify(h.Maybe(h.String), h.Maybe.none)               // "None"
 */
export type Maybe<A> = { readonly _tag: "None" } | { readonly _tag: "Some"; readonly value: A }

const none: Maybe<never> = Object.freeze({ _tag: "None" })

const isMaybe = (u: unknown): u is Maybe<unknown> =>
  typeof u === "object" && u !== null &&
  ((u as { _tag?: unknown })._tag === "None" || ((u as { _tag?: unknown })._tag === "Some" && Object.hasOwn(u, "value")))

const maybe_ = <A>(inner: Schema<A>): Schema<Maybe<A>> =>
  make(
    `Maybe ${inner.expected}`,
    (v, p) => {
      if (v.kind === "variant" && v.tag === "None" && v.args.length === 0) return none
      if (v.kind === "variant" && v.tag === "Some" && v.args.length === 1) return { _tag: "Some", value: inner.decode(v.args[0]!, p.child(0)) }
      return notCase(`None | Some(${inner.expected})`, v, p, MAYBE_TAGS, (tag) => (tag === "Some" ? { kind: "args", types: [inner.expected] } : { kind: "none" }))
    },
    (a, p) => {
      if (!isMaybe(a)) return invalid(`a Maybe ({ _tag: "None" } or { _tag: "Some", value })`, a, p)
      if (a._tag === "None") return variant("None")
      return p.enter(a, () => variant("Some", [inner.encode((a as { readonly value: A }).value, p.child(0))]))
    },
    { kind: "maybe", item: jsonType(inner) },
  )

export const Maybe = Object.assign(maybe_, {
  /** `None`. */
  none,
  /** `Some(value)`. */
  some: <A>(value: A): Maybe<A> => ({ _tag: "Some", value }),
  /** `Some(value)` for a value, `None` for null and undefined. */
  fromNullable: <A>(value: A | null | undefined): Maybe<A> => (value === null || value === undefined ? none : { _tag: "Some", value }),
  /** The value of a `Some`, or null for `None`. Collapses `Some(None)` and `None` of a nested Maybe: use it at the edge only. */
  toNullable: <A>(m: Maybe<A>): A | null => (m._tag === "Some" ? m.value : null),
  /** The value of a `Some`, or `orElse()` for `None`. */
  getOrElse: <A, B>(m: Maybe<A>, orElse: () => B): A | B => (m._tag === "Some" ? m.value : orElse()),
  /** Whether `u` is a Maybe: `{ _tag: "None" }` or `{ _tag: "Some", value }`. */
  is: isMaybe,
})

/**
 * A record field that may be missing: `name?: T` in a schema. In the decoded
 * object the key is then absent (`name?: T` in TypeScript); when encoding, an
 * absent key (or `undefined`) leaves the field out. Only meaningful as a
 * record field.
 *
 *   h.Record({ name: h.String, nickname: h.Optional(h.String) })
 *   // { name: "Ada" } and { name: "Ada", nickname: "ada" } are both valid
 *
 * For a partial update that can also clear a value, combine it with Maybe:
 * `h.Optional(h.Maybe(h.String))` reads a missing key (not given), `None`
 * (`{ _tag: "None" }`: clear) and `Some(x)` (`{ _tag: "Some", value: x }`: set).
 */
export const Optional = <A>(inner: Schema<A>): OptionalSchema<A> => {
  const self: OptionalSchema<A> = { ...inner, "~standard": standard(() => self), optional: true }
  return self
}

export interface OptionalSchema<A> extends Schema<A> {
  readonly optional: true
}

// ── records ──────────────────────────────────────────────────

export type Fields = Readonly<Record<string, AnySchema>>
type OptionalKeys<F extends Fields> = { [K in keyof F]: F[K] extends { readonly optional: true } ? K : never }[keyof F]
type Simplify<T> = { [K in keyof T]: T[K] } & {}
/** Required fields as `key: T`, `h.Optional` fields as `key?: T`. */
export type RecordOf<F extends Fields> = Simplify<
  { readonly [K in Exclude<keyof F, OptionalKeys<F>>]: Infer<F[K]> } & { readonly [K in OptionalKeys<F>]?: Infer<F[K]> }
>

export interface RecordSchema<A> extends Schema<A> {
  readonly kind: "record"
  /** The record's field names, in order. */
  readonly keys: ReadonlyArray<string>
  readonly decodeRecord: (value: HRecord, at: At) => A
  readonly encodeRecord: (value: A, at: At) => HRecord
}

/**
 * A record with these fields. Open by default: extra fields are ignored, so
 * a newer sender can add fields without breaking this reader.
 * `{ closed: true }` rejects unknown fields instead.
 */
const record_ = <F extends Fields>(fields: F, options: { closed?: boolean } = {}): RecordSchema<RecordOf<F>> => {
  const entries = Object.entries(fields)
  // Field types shortened: records nested in records (P a a inside P a a …) would otherwise double the text at every level.
  const expected = `{ ${entries.map(([k, s]) => `${k}${s.optional ? "?" : ""}: ${brief(s.expected)}`).join(", ")}${options.closed ? "" : " | _"} }`
  const decodeRecord = (v: HRecord, at: At) => {
    const out: Record<string, unknown> = {}
    for (const [key, schema] of entries) {
      const field = v.fields.get(key)
      if (field !== undefined) setOwn(out, key, schema.decode(field, at.child(key)))
      else if (!schema.optional) at.reject("missing-field", `missing field '${key}'`, { expected: `the field '${key}'` })
    }
    if (options.closed) {
      for (const key of v.fields.keys()) {
        if (!Object.hasOwn(fields, key)) at.reject("unknown-field", `unexpected field '${key}' (record is closed)`, { key })
      }
    }
    return out as RecordOf<F>
  }
  const encodeRecord = (a: RecordOf<F>, at: At): HRecord => {
    if (typeof a !== "object" || a === null) return invalid("an object", a, at)
    at.open()
    return at.enter(a, () => {
      const out = new Map<string, Value>()
      for (const [key, schema] of entries) {
        const value = Object.hasOwn(a, key) ? (a as Record<string, unknown>)[key] : undefined
        // An optional field without a value is left out; nothing is written in its place.
        if (schema.optional && value === undefined) continue
        out.set(key, schema.encode(value, at.child(key)))
      }
      return rec(out)
    })
  }
  const json: JsonRecordType = { kind: "record", fields: new globalThis.Map(entries.map(([k, s]) => [k, jsonType(s)])), closed: options.closed ?? false }
  const self: RecordSchema<RecordOf<F>> = {
    "~standard": standard(() => self),
    kind: "record",
    keys: entries.map(([k]) => k),
    expected,
    json,
    decodeRecord,
    encodeRecord,
    decode: (v, at) => {
      at.step()
      return v.kind === "record" ? decodeRecord(v, at) : mismatch("record", v, at)
    },
    encode: (a, at) => {
      at.step()
      return encodeRecord(a, at)
    },
  }
  return self
}

/**
 * A new own property: defineProperty, so that a field named "__proto__" (or
 * any name the prototype chain has, maybe as a setter or read-only) can't
 * replace the object's prototype or be refused. Hot: a name the chain doesn't
 * have is assigned, which makes the same property and is much faster.
 */
const setOwn = (out: Record<string, unknown>, key: string, value: unknown): void => {
  if (key in out) Object.defineProperty(out, key, { value, enumerable: true, writable: true, configurable: true })
  else out[key] = value
}

export { record_ as Record }

// ── variants ─────────────────────────────────────────────────

/** A case without payload: `Heartbeat`. */
export const Unit: { readonly kind: "unit" } = { kind: "unit" }

/** A case with positional payload: `Point(1, 2)` → `{ _tag: "Point", values: [1, 2] }`. */
export const Tuple = <const S extends readonly AnySchema[]>(...items: S) => ({ kind: "tuple" as const, items })

export type TupleSchema<S extends readonly AnySchema[]> = { readonly kind: "tuple"; readonly items: S }

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Case = typeof Unit | RecordSchema<any> | TupleSchema<readonly AnySchema[]> | AnySchema
type Cases = Readonly<Record<string, Case>>

/**
 * The decoded form of each case:
 *   Unit          → { _tag }
 *   Record({...}) → { _tag, ...fields }        (`Circle { radius: 5 }`)
 *                   { _tag, value: { ...fields } } when one of the fields is
 *                   named `_tag`, which can't go beside the tag (`Odd { _tag: 1 }`)
 *                   A `Recursive` whose schema is a record is a record case too,
 *                   as a named record is in a schema file (spec §15).
 *   Tuple(a, b)   → { _tag, values: [a, b] }    (`Point(1, 2)`)
 *   any schema    → { _tag, value }             (`Ok("done")`)
 */
export type CaseOf<T extends string, C> =
  C extends typeof Unit ? { readonly _tag: T }
  : C extends RecordSchema<infer A> | RecursiveRecord<infer A> ? ("_tag" extends keyof A ? { readonly _tag: T; readonly value: A } : { readonly _tag: T } & A)
  : C extends TupleSchema<infer S> ? { readonly _tag: T; readonly values: { readonly [I in keyof S]: Infer<S[I]> } }
  : C extends Schema<infer A> ? { readonly _tag: T; readonly value: A }
  : never

export type VariantOf<C extends Cases> = { [T in keyof C & string]: CaseOf<T, C[T]> }[keyof C & string]

/** A tag an open variant doesn't know. The raw value is kept for logging or forwarding. */
export interface Unknown {
  readonly _tag: "@unknown"
  readonly tag: string
  readonly value: HVariant
}

/** The unknown value for a variant an open type doesn't list: the tag, and the variant as it was parsed. */
const unknownOf = (v: HVariant): Unknown => ({ _tag: "@unknown", tag: v.tag, value: v })

/** Whether `u` is an `Unknown` (to encode: its raw value, after `checkedValue`). */
const isUnknown = (u: unknown): u is { readonly _tag: "@unknown"; readonly value: unknown } =>
  typeof u === "object" && u !== null && (u as { readonly _tag?: unknown })._tag === "@unknown"

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const isRecordSchema = (c: Case): c is RecordSchema<any> => "kind" in c && c.kind === "record"
const isTuple = (c: Case): c is TupleSchema<readonly AnySchema[]> => "kind" in c && c.kind === "tuple"

/** A record payload with a field named `_tag`: its fields can't go beside the tag, so they are nested, `{ _tag, value: { … } }`. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const nestsPayload = (c: RecordSchema<any>): boolean => c.keys.includes("_tag")

/** A record case's type for hints, without the open record's `| _`: `{ r: Float64 }`. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const recordType = (c: RecordSchema<any>): string => c.expected.replace(/ \| _ \}$/, " }")

/** A variant's payload as an error describes it: `no payload`, `1 argument (a number)`, `a record`. */
const payloadFound = (v: HVariant): string =>
  v.args.length === 0 ? "no payload"
  : v.args.length === 1 && v.args[0]!.kind === "record" ? "a record"
  : v.args.length === 1 ? `1 argument (${describe(v.args[0]!)})`
  : `${v.args.length} arguments`

/** A list of tags for error messages, shortened for very large variants. */
const tagList = (tags: readonly string[]) => (tags.length > 10 ? `${tags.slice(0, 10).join(" | ")} | … (${tags.length} tags)` : tags.join(" | "))

/**
 * A case as it is used: a `Recursive` whose schema is a record is a record
 * case (spec §15: a case with one argument of a record type), entered through
 * the `Recursive`. Decided when the variant is first used, since the
 * `Recursive` may not be built yet when the variant is made.
 */
const caseOf = (c: Case): Case => recordBodies.get(c)?.() ?? c

const variantSchema = <C extends Cases, A>(cases: C, open: boolean): Schema<A> => {
  const tags = Object.keys(cases)
  const expected = `< ${tagList(tags)}${open ? " | _" : ""} >`
  const written = Object.entries(cases)
  // Dispatch is one hash lookup on the tag: never "try each case and backtrack".
  let resolved: Map<string, Case> | undefined
  const byTag = (): Map<string, Case> => (resolved ??= new Map(written.map(([tag, c]) => [tag, caseOf(c)])))
  const jsonOf = (): JsonType => ({ kind: "variant", open, cases: new Map([...byTag()].map(([tag, c]) => [tag, jsonCase(c)])) })
  let lazyJson: JsonType | undefined
  // With a Recursive among the cases, the form is known once it is built: a lazy link (the same object every time).
  const json: JsonType = written.some(([, c]) => recordBodies.has(c)) ? { kind: "lazy", get: () => (lazyJson ??= jsonOf()) } : jsonOf()
  return make(expected, (v, at) => {
    if (v.kind !== "variant") return mismatch(expected, v, at)
    const c = byTag().get(v.tag)
    if (c === undefined) {
      if (open) return unknownOf(v) as A
      return at.reject("unknown-tag", `unknown tag '${v.tag}', expected one of ${tagList(tags)}`, { expected: `one of ${tagList(tags)}`, found: v.tag })
    }
    const wrong = (shape: string, takes: CasePayload): never =>
      at.reject("wrong-payload", `'${v.tag}' expects ${shape}, found ${payloadFound(v)}`, { expected: shape, found: payloadFound(v), hint: payloadHint(v.tag, takes) })
    const arity = (n: number, shape: string, takes: CasePayload) => {
      if (v.args.length !== n) wrong(shape, takes)
    }
    if (c === Unit) {
      arity(0, "no payload", { kind: "none" })
      return { _tag: v.tag } as A
    }
    if (isRecordSchema(c)) {
      // One argument that is a record: `Circle(1.5)` is the wrong payload, at the variant (spec §15).
      const [arg] = v.args
      if (v.args.length !== 1 || arg?.kind !== "record") return wrong("a record payload", { kind: "record", type: recordType(c) })
      const out = c.decodeRecord(arg, at) as Record<string, unknown>
      if (nestsPayload(c)) return { _tag: v.tag, value: out } as A
      return Object.defineProperties({ _tag: v.tag }, Object.getOwnPropertyDescriptors(out)) as A
    }
    if (isTuple(c)) {
      arity(c.items.length, `${c.items.length} argument(s)`, { kind: "args", types: c.items.map((s) => s.expected) })
      return { _tag: v.tag, values: c.items.map((s, i) => s.decode(v.args[i]!, at.child(i))) } as A
    }
    arity(1, "one argument", { kind: "args", types: [(c as AnySchema).expected] })
    return { _tag: v.tag, value: (c as AnySchema).decode(v.args[0]!, at.child(0)) } as A
  }, (a, at) => {
    const obj = a as { _tag?: unknown; tag?: unknown; value?: unknown; values?: unknown }
    if (typeof obj !== "object" || obj === null || typeof obj._tag !== "string") return invalid("an object with a _tag", a, at)
    // Unknown variants are written back as they were received, after checking
    // that what's there really is a haus value within the limits.
    if (open && isUnknown(obj)) {
      const raw = checkedValue(obj.value, at)
      // An unknown value is one whose tag the variant doesn't list (spec §15).
      if (raw.kind !== "variant") return invalid("a variant", raw, at)
      if (byTag().has(raw.tag)) return invalid(`a tag the variant doesn't list (${raw.tag} is one of its cases)`, raw.tag, at)
      return raw
    }
    const c = byTag().get(obj._tag)
    if (c === undefined) return invalid(`one of ${tagList(tags)}`, obj._tag, at)
    if (c === Unit) return variant(obj._tag)
    return at.enter(obj, () => {
      const tag = obj._tag as string
      if (isRecordSchema(c)) {
        if (nestsPayload(c)) return variant(tag, [c.encodeRecord(obj.value, at)])
        const { _tag, ...fields } = obj as Record<string, unknown>
        return variant(tag, [c.encodeRecord(fields, at)])
      }
      if (isTuple(c)) {
        const values = obj.values
        if (!Array.isArray(values) || values.length !== c.items.length) return invalid(`${c.items.length} values`, values, at)
        return variant(tag, c.items.map((s, i) => s.encode(values[i], at.child(i))))
      }
      return variant(tag, [(c as AnySchema).encode(obj.value, at.child(0))])
    })
  }, json)
}

/** The schema-based JSON form of a variant case: a record payload's fields go beside `_tag`, other payloads are positional. */
const jsonCase = (c: Case): JsonCase => {
  if (c === Unit) return { kind: "unit" }
  if (isRecordSchema(c)) return c.json?.kind === "record" ? { kind: "record", record: c.json } : { kind: "positional", items: [jsonType(c)] }
  if (isTuple(c)) return { kind: "positional", items: c.items.map(jsonType) }
  return { kind: "positional", items: [jsonType(c as AnySchema)] }
}

const VALUE_KINDS: ReadonlySet<unknown> = new Set<Value["kind"]>(["number", "string", "bytes", "array", "record", "variant"])

/** Whether `u` looks like a haus `Value` at its top (its kind); `checkedValue` checks the rest. */
const isValueNode = (u: unknown): u is Value => typeof u === "object" && u !== null && VALUE_KINDS.has((u as { readonly kind?: unknown }).kind)

/** `xs` mapped with `f`, or `xs` itself when `f` changed nothing. */
const mapSame = <T>(xs: readonly T[], f: (x: T, i: number) => T): readonly T[] => {
  const ys = xs.map(f)
  return ys.every((y, i) => y === xs[i]) ? xs : ys
}

/**
 * A raw `Value` handed to the encoder (an `Any`, an Unknown's payload): a
 * haus value within the call's limits (spec §9.5, §9.8), checked node by
 * node: shape, depth, work, number literals, string lengths, tags. It is
 * written back as it is, except that number literals are normalized as the
 * parser would (`1E5` → `1e5`); parts without such a change are kept as they
 * are (the same objects), so a parsed value comes back unchanged.
 */
const checkedValue = (raw: unknown, at: At): Value => {
  at.step()
  if (!isValueNode(raw)) return invalid("a haus value", raw, at)
  const { maxStringLength } = at.limits
  /** A string, key or tag within the string limit (spec §7). */
  const checkedString = (s: unknown, what: string, kind: "string" | "key" | "tag" = "string"): string => {
    if (typeof s !== "string") return invalid(what, s, at)
    return longerThan(s, maxStringLength) ? at.reject(kind === "key" ? "key-too-long" : kind === "tag" ? "tag-too-long" : "string-too-long", `${kind} longer than ${maxStringLength} characters`) : s
  }
  switch (raw.kind) {
    case "number": {
      const n = numberFromText(raw.text, "a number literal", at)
      return n.text === raw.text ? raw : n
    }
    case "string":
      checkedString(raw.value, "a string value")
      return raw
    case "bytes":
      return raw.bytes instanceof Uint8Array ? raw : invalid("a Uint8Array", raw.bytes, at)
    case "array": {
      if (!Array.isArray(raw.items)) return invalid("an array of items", raw.items, at)
      at.open()
      const items = mapSame(raw.items, (x, i) => checkedValue(x, at.child(i)))
      return items === raw.items ? raw : arr(items)
    }
    case "record": {
      if (!(raw.fields instanceof globalThis.Map)) return invalid("a Map of fields", raw.fields, at)
      at.open()
      const fields = new globalThis.Map<string, Value>()
      let changed = false
      for (const [k, x] of raw.fields) {
        const y = checkedValue(x, at.child(checkedString(k, "a string key", "key")))
        changed ||= y !== x
        fields.set(k, y)
      }
      return changed ? rec(fields) : raw
    }
    case "variant": {
      if (typeof raw.tag !== "string" || !TAG.test(raw.tag)) return invalid("a tag name", raw.tag, at)
      checkedString(raw.tag, "a tag name", "tag")
      if (!Array.isArray(raw.args)) return invalid("an array of arguments", raw.args, at)
      if (raw.args.length > 0) at.open()
      // `Tag { … }` is one level, as in the parser; `Tag(a, b)` nests its arguments.
      const [first] = raw.args
      const single = raw.args.length === 1 && isValueNode(first) && first.kind === "record"
      const args = mapSame(raw.args, (x, i) => checkedValue(x, single ? at.payload(i) : at.child(i)))
      return args === raw.args ? raw : variant(raw.tag, args)
    }
  }
}

/** A closed variant: any other tag is an error. */
export const Variant = <const C extends Cases>(cases: C): Schema<VariantOf<C>> => variantSchema(cases, false)

/** An open variant (`< A | B | _ >`): other tags decode as `Unknown` instead of failing. */
export const OpenVariant = <const C extends Cases>(cases: C): Schema<VariantOf<C> | Unknown> => variantSchema(cases, true)

/** Shorthand for a closed variant of payload-less tags, decoded to string literals. */
export const Enum = <const T extends readonly string[]>(...tags: T): Schema<T[number]> => {
  const known = new Set<string>(tags)
  return make(
    `< ${tagList(tags)} >`,
    (v, at) =>
      v.kind === "variant" && v.args.length === 0 && known.has(v.tag)
        ? (v.tag as T[number])
        : notCase(`one of ${tagList(tags)}`, v, at, known),
    (t, at) => (typeof t === "string" && known.has(t) ? variant(t) : invalid(`one of ${tagList(tags)}`, t, at)),
    { kind: "variant", open: false, cases: new Map(tags.map((t) => [t, { kind: "unit" }])) },
  )
}

/**
 * `< >`, a variant with any tags (spec §15): every value is an unknown one. A
 * tag without payload decodes to its name (`EUR` → "EUR"); any other value
 * to an `Unknown` that keeps it exactly.
 */
export const AnyTag: Schema<string | Unknown> = make(
  "< >",
  (v, at) => (v.kind !== "variant" ? mismatch("a variant", v, at) : v.args.length === 0 ? v.tag : unknownOf(v)),
  (a, at) =>
    typeof a === "string" ? (TAG.test(a) ? variant(a) : invalid("a tag name", a, at))
    : isUnknown(a) ? checkedValue(a.value, at)
    : invalid("a tag name or an Unknown", a, at),
  { kind: "variant", open: true, cases: new Map() },
)

const TAG = /^[A-Z][A-Za-z0-9_]*$/

// ── Any and Secret ───────────────────────────────────────────

/**
 * `Any` (spec §15): any value, kept exactly as parsed, as the generic haus
 * `Value` tree. For a payload this schema passes on without knowing its
 * shape. Encoding writes it back unchanged, after checking that it is a haus
 * value within the limits. Treat its content as untrusted data.
 */
const any_: Schema<Value> = make("Any", (v) => v, (a, at) => checkedValue(a, at), { kind: "any" })

export { any_ as Any }

/**
 * `f`, for the secret at `at` of type `expected`. A secret's own errors give
 * its place and its type, never the value or any part of it (spec §15):
 * errors from inside (including paths, which may hold map keys from the
 * data) are replaced by one at the secret's place.
 */
const concealed = <R>(expected: string, at: At, f: () => R): R => {
  try {
    return f()
  } catch (e) {
    if (e instanceof HausDecodeError || e instanceof HausEncodeError) at.reject("invalid-secret", `expected ${expected} (a Secret: the value is not shown)`, { expected })
    throw e
  }
}

/**
 * `Secret a` (spec §15): the same data as `a`, decoded into a `Secret` that
 * shows `<redacted>` when printed, logged or converted to JSON; `expose()`
 * gives the value out. Errors never contain the value. Encode a
 * `h.Secret.make(value)` (or `new Secret(value)`).
 *
 *   const Config = h.Record({ apiKey: h.Secret(h.String) })
 *   const config = h.parse(Config, text)
 *   String(config.apiKey)    // "<redacted>"
 *   config.apiKey.expose()   // "sk-…"
 */
export const Secret = Object.assign(
  <A>(inner: Schema<A>): Schema<SecretValue<A>> =>
    make(
      `Secret ${inner.expected}`,
      (v, at) => new SecretValue(concealed(inner.expected, at, () => inner.decode(v, at))),
      (s, at) =>
        // Not even a short description of what was given instead: it may be the secret itself.
        s instanceof SecretValue ? concealed(inner.expected, at, () => inner.encode(s.expose(), at))
        : at.reject("cannot-encode", `expected a Secret (h.Secret.make(…)), got ${s === null ? "null" : Array.isArray(s) ? "an array" : typeof s}`),
      { kind: "secret", item: jsonType(inner), expected: inner.expected },
    ),
  {
    /** A secret holding `value`, to encode. */
    make: SecretValue.make,
    /** Whether `u` is a Secret. */
    is: SecretValue.is,
  },
)

/** A decoded `Secret a`: `expose()` gives the value; printing it shows `<redacted>`. */
export type Secret<A> = SecretValue<A>

// ── recursion ────────────────────────────────────────────────

export interface RecursiveOptions {
  /**
   * How deeply this type may be nested in itself. By default only the call's
   * nesting depth limit (`Limits.maxDepth`, 256) applies, so every binding
   * accepts the same values (spec §9.9); set a smaller limit here for a type
   * whose values should stay shallower.
   */
  readonly maxDepth?: number
}

/**
 * A `Recursive` whose schema is a record (`h.Recursive<Node>("Node", (self) =>
 * h.Record({ … }))`): as the payload of a variant case, it is a record case,
 * `{ _tag, ...fields }`, as a named record is in a schema file (spec §15).
 * Annotate such a schema as `h.RecursiveRecord<A>` rather than `h.Schema<A>`
 * so that the case's type says so too.
 */
export interface RecursiveRecord<A> extends Schema<A> {
  /** Type-level only: the schema of this Recursive is a record. */
  readonly [recordBody]: A
}
declare const recordBody: unique symbol

/** For each Recursive: its schema as a record case, if it is a record (through other Recursives). */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const recordBodies = new WeakMap<object, () => RecordSchema<any> | undefined>()

/**
 * A type that contains itself, such as a tree or a comment thread. Schemas
 * can't refer to themselves otherwise, so recursion is always visible.
 *
 *   interface Tree { readonly name: string; readonly children: readonly Tree[] }
 *   const Tree: h.Schema<Tree> = h.Recursive<Tree>("Tree", (self) =>
 *     h.Record({ name: h.String, children: h.Array(self) }))
 *
 * Every cycle must pass through a record field, array element or variant
 * payload ("guarded"), so each level consumes one level of the input. A
 * schema that refers to itself directly, or decodes or encodes the same value
 * with itself again, fails instead of looping.
 *
 * A Recursive whose schema is a record (`h.RecursiveRecord`) is a record
 * case as the one payload of a variant case, as a named record is in a
 * schema file (spec §15).
 */
export function Recursive<A>(name: string, build: (self: Schema<A>) => RecordSchema<A> | RecursiveRecord<A>, options?: RecursiveOptions): RecursiveRecord<A>
export function Recursive<A>(name: string, build: (self: Schema<A>) => Schema<A>, options?: RecursiveOptions): Schema<A>
export function Recursive<A>(name: string, build: (self: Schema<A>) => Schema<A>, options: RecursiveOptions = {}): Schema<A> {
  // Each level consumes a level of the value, so the call's depth limit bounds it too.
  const maxDepth = options.maxDepth ?? Infinity
  let body: Schema<A> | undefined
  let building = false
  // Built on first use, so it may refer to schemas defined after it (mutual recursion).
  const force = (): Schema<A> => {
    if (body) return body
    if (building) throw new Error(`h.Recursive("${name}"): used while it is being built`)
    building = true
    const built = build(self)
    if (built === self) throw new Error(`h.Recursive("${name}"): the schema is only itself (unguarded recursion)`)
    return (body = built)
  }
  const run = <R>(value: unknown, at: At, f: (body: Schema<A>) => R): R => {
    at.step()
    const b = force()
    const state = at.recursion(self)
    if (state.current === value) {
      // Entering again with the very value we're inside: an object that
      // contains itself, or a schema that consumed nothing in between.
      if (at.isEncoding(value)) at.reject("cyclic-value", "cyclic value: an object contains itself")
      at.reject("unguarded-recursion", `unguarded recursion in ${name}: it applies itself to the same value again`)
    }
    if (state.depth >= maxDepth) at.reject("nesting-too-deep", `${name} nested deeper than ${maxDepth} levels`)
    const saved = state.current
    state.depth++
    state.current = value
    try {
      return f(b)
    } finally {
      state.depth--
      state.current = saved
    }
  }
  let target: JsonType | undefined
  const self: Schema<A> = {
    "~standard": standard(() => self),
    expected: name,
    // The same object every time, so that a recursive type's JSON form is a finite graph.
    json: { kind: "lazy", get: () => (target ??= jsonType(force())) },
    decode: (v, at) => run(v, at, (b) => b.decode(v, at)),
    encode: (a, at) => run(a, at, (b) => b.encode(a, at)),
  }
  // As a record case: the record's own decodeRecord and encodeRecord, entered through this
  // Recursive (its depth and cycle checks). Decided once, when first asked, after it is built.
  let asRecord: RecordSchema<A> | null | undefined
  let resolving = false
  recordBodies.set(self, () => {
    if (asRecord !== undefined) return asRecord ?? undefined
    // Recursives that are only each other (unguarded, so never decoded): not a record.
    if (resolving) return undefined
    resolving = true
    try {
      const body = force()
      const record = isRecordSchema(body) ? (body as RecordSchema<A>) : recordBodies.get(body)?.()
      asRecord = record === undefined ? null : {
        ...self,
        kind: "record",
        expected: record.expected,
        keys: record.keys,
        json: record.json,
        decodeRecord: (v, at) => run(v, at, () => record.decodeRecord(v, at)),
        encodeRecord: (a, at) => run(a, at, () => record.encodeRecord(a, at)),
      }
    } finally {
      resolving = false
    }
    return asRecord ?? undefined
  })
  return self
}

// ── entry points ─────────────────────────────────────────────

export const decode = <A>(schema: Schema<A>, value: Value, limits: Limits = {}): A => schema.decode(value, decodeAt(value, limits))

/** Parse a text holding exactly one value and decode it. */
export const parse = <A>(schema: Schema<A>, text: string, limits: Limits = {}): A => {
  const parser = new Parser(text, START, withDefaults(limits))
  const values = parser.parseSequence()
  if (values.length !== 1) throw new HausDecodeError(`expected exactly one value, found ${values.length}`, [], "not-one-value", { expected: "one value", found: `${values.length} values` })
  // Hot: the parser counted the values as it read them (a tree, within the same depth limit), so they needn't be counted again.
  return schema.decode(values[0]!, decodeWithin(limits, parser.valueCount))
}

/** Parse and decode a stream; each element's errors carry its index in the path. Limits apply per element. */
export async function* decodeStream<A>(schema: Schema<A>, source: ChunkSource, limits: Limits = {}): AsyncGenerator<A, void, undefined> {
  let i = 0
  for await (const value of parseStream(source, { limits })) {
    yield schema.decode(value, decodeAt(value, limits, i))
    i++
  }
}

/** Encode a typed value into a haus `Value`. */
export const encode = <A>(schema: Schema<A>, value: A, limits: Limits = {}): Value => schema.encode(value, encodeAt(limits))

/** Encode and write as haus text in the standard format (no trailing newline). */
export const stringify = <A>(schema: Schema<A>, value: A, options: FormatOptions & Limits = {}): string =>
  stringifyValue(encode(schema, value, options), options)

/** Encode several values as a stream file: a comma after every value. */
export const formatAll = <A>(schema: Schema<A>, values: Iterable<A>, options: FormatOptions & Limits = {}): string => {
  checkLimits(options)
  return format([...values].map((v, i) => schema.encode(v, encodeAt(options, i))), options)
}

/**
 * Encode values one at a time as stream chunks, each ending in ",\n", e.g.
 * to write them to a response or a log file as they are produced.
 */
export async function* encodeStream<A>(
  schema: Schema<A>,
  values: AsyncIterable<A> | Iterable<A>,
  options: FormatOptions & Limits = {},
): AsyncGenerator<string, void, undefined> {
  let i = 0
  // Streams default to compact: one item per line.
  for await (const v of values) yield stringifyValue(schema.encode(v, encodeAt(options, i++)), { style: "compact", ...options }) + ",\n"
}

// ── JSON (spec §16.3) ────────────────────────────────────────

/**
 * The schema-based JSON of a value (spec §16.3), as a JSON value: what a JSON
 * consumer expects, with the schema saying what JSON can't (that a string is
 * a date or a decimal). `Int`, `Int64` and `UInt64` are strings, `Bytes`
 * base64, a `Maybe` `null` or its value (tagged when its value can be
 * `null`), closed enums strings, other variants `{ "_tag": …, … }`.
 */
export const toJsonValue = <A>(schema: Schema<A>, value: A, limits: Limits = {}): Json =>
  toSchemaBasedJson(jsonType(schema), encode(schema, value, limits), limits)

/**
 * The schema-based JSON text of a value (spec §16.3), compact.
 *
 *   h.toJson(User, { id: 1, name: "Ada", note: h.Maybe.none })   // '{"id":1,"name":"Ada","note":null}'
 */
export const toJson = <A>(schema: Schema<A>, value: A, limits: Limits = {}): string => stringifyJson(toJsonValue(schema, value, limits))

/**
 * Decode a value read from JSON by `read`; an error the schema finds (a
 * range, a std/time text, a codec) is reported at its place in the JSON
 * (spec §16.3 "Places"), as the reader's own errors are. `skip`: steps of
 * the error's path before the value's own (a JSON Lines line's index).
 */
const decodeRead = <A>(decodeIt: () => A, read: (places: JsonPlaces) => Value, skip = 0): A => {
  try {
    return decodeIt()
  } catch (e) {
    throw e instanceof HausDecodeError ? atJsonPlace(e, read, skip) : e
  }
}

/** Read the schema-based JSON of a value (spec §16.3) from a JSON value. Throws HausDecodeError, at its place in the JSON. */
export const fromJsonValue = <A>(schema: Schema<A>, json: Json, limits: Limits = {}): A => {
  const type = jsonType(schema)
  const read = (places?: JsonPlaces) => fromSchemaBasedJson(type, json, limits, Place.root(), places)
  const value = read()
  return decodeRead(() => decode(schema, value, limits), read)
}

/**
 * Read schema-based JSON text (spec §16.3) with a schema: the forms `h.toJson`
 * writes, with the rules of decoding haus (an open record ignores members
 * it doesn't list, an integer type takes only whole numbers, a float type
 * rounds…). Throws HausSyntaxError for text that isn't I-JSON, and
 * HausDecodeError for JSON that doesn't fit the schema.
 */
export const fromJson = <A>(schema: Schema<A>, text: string, limits: Limits = {}): A =>
  fromJsonValue(schema, parseJson(text, jsonTextLimits(withDefaults(limits))), limits)

/**
 * Read a JSON Lines stream (one schema-based JSON text per line, spec §16) and
 * decode each value as soon as its line is complete. Errors name the line's
 * index. Limits apply per value.
 */
export async function* decodeJsonLines<A>(
  schema: Schema<A>,
  source: ChunkSource,
  options: Limits & Omit<JsonLinesOptions, "limits"> = {},
): AsyncGenerator<A, void, undefined> {
  const type = jsonType(schema)
  const limits = withDefaults(options)
  yield* readLines(source, options, (text, origin, i) => {
    const json = readJson(text, jsonTextLimits(limits), origin)
    const read = (places?: JsonPlaces) => fromSchemaBasedJson(type, json, options, Place.root(i), places)
    const value = read()
    return decodeRead(() => schema.decode(value, decodeAt(value, options, i)), read, 1)
  })
}

/** Encode values as JSON Lines of their schema-based JSON (spec §16): one line per value, each ending in a line feed. */
export async function* encodeJsonLines<A>(
  schema: Schema<A>,
  values: AsyncIterable<A> | Iterable<A>,
  limits: Limits = {},
): AsyncGenerator<string, void, undefined> {
  const type = jsonType(schema)
  let i = 0
  for await (const v of values) {
    const place = Place.root(i)
    yield stringifyJson(toSchemaBasedJson(type, schema.encode(v, encodeAt(limits, i++)), limits, place)) + "\n"
  }
}
