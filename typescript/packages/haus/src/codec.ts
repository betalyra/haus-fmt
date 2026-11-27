/**
 * Compiled codecs: for a schema of schema.ts, a reader that decodes straight
 * from the `Reader` (reader.ts) into the output values, with no `Value` tree
 * in between, and a writer that encodes straight into compact or minimised
 * text. Each is built once per schema object (cached in a WeakMap) out of
 * closures, without `eval`, and used by `h.parse`, `h.stringify`,
 * `h.formatAll`, `h.encodeStream` and `h.decodeStream` by default. codegen.ts
 * writes the same codecs out as source (for schemas marked by `h.optimize`),
 * and chooses between them.
 *
 * The generic path (parse to a `Value`, then `schema.decode`; `schema.encode`,
 * then the formatter) stays the reference. The compiled codecs give the same
 * results:
 *
 * - **Values.** Each reader builds what the schema's `decode` builds: the
 *   same objects (records with their fields in the schema's order, `_tag`
 *   first in a case), Maps, arrays, bigints, `None` (the one frozen object),
 *   `Secret`s, `Unknown`s and `Any` values (read by `readValue`, the generic
 *   parser). Each writer writes what the formatter writes for the encoded value.
 * - **Errors.** On any error at all (a syntax error, a value the schema
 *   rejects, a limit, the step budget, an exception from a schema written by
 *   hand), the compiled attempt is dropped and the generic path runs from the
 *   start; it reports the error. That is not only simpler, it is needed:
 *   the generic path parses the whole text before decoding, so a syntax error
 *   late in the text wins over a decode error early in it (spec §4), while a
 *   reader that decodes as it parses meets the decode error first. Errors are
 *   rare, so running twice costs nothing in the common case. Code of the
 *   application (a codec's check, a schema written by hand) can run twice then.
 * - **Limits** are those of the generic path: the reader enforces the
 *   parser's, readers and writers count schema steps as `decode` and
 *   `encode` do (the budget is checked again at the end, once the number of
 *   values is known), and writers stop at the depth limit (a cyclic value
 *   ends there too, and the generic path names it).
 *
 * Schemas without a shape (written by hand) are read as a `Value` and decoded
 * by their own `decode` (written: encoded by their own `encode`), at the depth
 * the generic path gives them. A schema is not compiled at all, and always
 * takes the generic path, when compiling it throws (a Recursive whose build
 * fails), when a Recursive can apply itself to the same value again
 * (`Recursive(self => Secret(self))`, an error of the generic path), or when a
 * Recursive reaches a schema written by hand without a value in between
 * (which could do the same).
 */
import { BARE_KEY, TAG } from "./chars.js"
import type { Origin } from "./errors.js"
import { keyText, quote, stringify as stringifyValue, toHex } from "./format.js"
import { floatValue, specialFloat, toFloat, type FloatType } from "./float.js"
import { INTEGER, normalizeNumber, numberLimitIssue } from "./number.js"
import { defineOwn } from "./own.js"
import { readValue, readVariantAfter } from "./parser.js"
import { ARGS, ARRAY, BYTES, CLOSE_ARGS, CLOSE_ARRAY, NO_PAYLOAD, NUMBER, PAYLOAD_RECORD, Reader, RECORD, STRING, VARIANT } from "./reader.js"
import { At, checkedValue, decodeContext, decodeSteps, encodeContext, Maybe, recursionOf, shapeOf, type AnySchema, type CaseShape, type Context, type Limits, type Shape, type Unknown } from "./schema.js"
import { Secret } from "./secret.js"
import { uncheckedVariant, type HVariant, type Value } from "./value.js"

/**
 * Reads one value at the reader's position, counting it as the generic parser
 * does. `depth`: the value's depth as `At` counts it (the record fields,
 * items and arguments it is inside), for schemas written by hand.
 */
export type Read = (r: Reader, cx: Context, depth: number) => unknown

/** Writes `a`, at its depth as `At` counts it, onto `w`. */
export type Write = (w: Out, a: unknown, cx: Context, depth: number) => void

/** Thrown to give up on the compiled path; the generic path runs instead. Preallocated: throwing it is cheap. */
const FALLBACK = Object.freeze({ fallback: "compiled codec" })

export const fail = (): never => {
  throw FALLBACK
}

/** Count one schema step, as `At.step` does; beyond the budget, give up (the generic path reports it). */
const step = (cx: Context): void => {
  if (++cx.steps > cx.maxSteps) throw FALLBACK
}

/** A schema that can't be compiled; compiling gives up. */
export class NotCompilable extends Error {}

export type RecursiveShape = Extract<Shape, { kind: "recursive" }>
export type RecordShape = Extract<Shape, { kind: "record" }>

/**
 * Entering a Recursive, as `run` in schema.ts: one step, and one level more of
 * it (within its `maxDepth`); the caller takes the level back after it. No
 * `finally`: after an error, the whole call's state is dropped.
 */
const enterRecursive = (shape: RecursiveShape, cx: Context): { depth: number } => {
  step(cx)
  const state = recursionOf(cx, shape.self)
  if (state.depth >= shape.maxDepth) fail()
  state.depth++
  return state
}

// ── checking a schema ────────────────────────────────────────

/**
 * Follow the schemas `s` applies to the same value (Secret, refine and
 * Recursive pass the value on to one inner schema): a schema reached twice
 * is a Recursive applying itself to the same value again, which the generic
 * path rejects (`unguarded-recursion`). A schema written by hand after a
 * Recursive could do the same: neither is compiled.
 */
export const checkChain = (s: AnySchema): void => {
  const seen = new Set<AnySchema>()
  let recursive = false
  for (let x = s; ;) {
    const shape = shapeOf(x)
    if (shape === undefined) {
      if (recursive) throw new NotCompilable("a Recursive reaches a schema written by hand without consuming a value")
      return
    }
    if (shape.kind === "secret" || shape.kind === "refine" || shape.kind === "transform") x = shape.inner
    else if (shape.kind === "recursive") {
      recursive = true
      x = shape.body()
    } else return
    if (seen.has(x)) throw new NotCompilable("unguarded recursion")
    seen.add(x)
  }
}

// ── readers ──────────────────────────────────────────────────

/** The value of a variant an open type doesn't list (schema.ts decodes it so too): the tag, and the variant as it was parsed. */
export const unknownOf = (v: HVariant): Unknown => ({ _tag: "@unknown", tag: v.tag, value: v })

/** The value is a number: its normalized text. */
const numberText = (r: Reader): string => (r.next() === NUMBER ? r.number() : fail())

/** After the last argument a variant's schema takes: its `)` (another argument gives up). */
const endArguments = (r: Reader): void => {
  r.endItem(CLOSE_ARGS)
  if (r.more(CLOSE_ARGS)) fail()
}

/**
 * After a variant's tag and `payload`: its one argument, read by `read` at
 * `depth` (the variant's depth + 1). `Tag(x)`, or `Tag { … }`, whose record is
 * the argument.
 */
const oneArgument = (r: Reader, cx: Context, depth: number, payload: number, read: Read): unknown => {
  if (payload === PAYLOAD_RECORD) return read(r, cx, depth)
  if (payload !== ARGS) fail()
  const value = read(r, cx, depth)
  endArguments(r)
  return value
}

/** A placeholder in a record's slots: the field hasn't been read. */
export const HOLE: unknown = Symbol("hole")

/** What a record's fields reader needs, built once per record schema. */
interface Fields {
  readonly keys: readonly string[]
  readonly index: ReadonlyMap<string, number>
  readonly readers: Read[]
  readonly optional: readonly boolean[]
  /**
   * Keys the prototype chain of `{}` has (`__proto__`, `toString`, …): set with
   * defineProperty, as `setOwn` in schema.ts does, so they become own data
   * properties. Decided when the schema is compiled.
   */
  readonly special: readonly boolean[]
  /** How many fields are required. */
  readonly required: number
  readonly closed: boolean
  /** Keys that can be written bare (identifiers): matched in place (`Reader.keyIs`). */
  readonly bare: readonly boolean[]
}

/** Set field `i` on `out`: a new own data property. */
const setField = (f: Fields, out: Record<string, unknown>, i: number, value: unknown): void => {
  if (f.special[i]) defineOwn(out, f.keys[i]!, value)
  else out[f.keys[i]!] = value
}

/**
 * At a record's `{` (counted): its fields, into a new object `{}` (or
 * `{ _tag: tag }` for a variant's record case) in the schema's order, as
 * `decodeRecord` builds it; the record is at `depth`, its fields one deeper.
 * Hot.
 *
 * Fields usually come in the schema's order: each is set on the object as it
 * is read. The first one out of order moves the values into slots (by the
 * field's index), and the object is built from them at the end. A field
 * seen twice, a missing one, or (closed) an unknown one gives up; unknown
 * fields of an open record are read (checked) and dropped.
 */
const readFields = (f: Fields, r: Reader, cx: Context, depth: number, tag: string | undefined): Record<string, unknown> => {
  r.openRecord()
  const { keys, index, readers, optional } = f
  const n = keys.length
  let out: Record<string, unknown> = tag === undefined ? {} : { _tag: tag }
  /** The index of the last field set on `out`: in order, the next is after it. */
  let last = -1
  let slots: unknown[] | undefined
  let required = 0
  let unknown: Set<string> | undefined
  for (;;) {
    let i: number
    // The next field in order first, compared in place; else the key and a lookup.
    if (last + 1 < n && f.bare[last + 1] && r.keyIs(keys[last + 1]!)) i = last + 1
    else {
      const key = r.key()
      if (key === undefined) break
      i = index.get(key) ?? -1
      if (i < 0) {
        if (f.closed) fail()
        unknown ??= new Set()
        const size = unknown.size
        unknown.add(key)
        if (unknown.size === size) fail() // a duplicate key
        readValue(r)
        r.endField()
        continue
      }
    }
    const value = readers[i]!(r, cx, depth + 1)
    if (slots === undefined && i > last) {
      setField(f, out, i, value)
      last = i
    } else {
      if (slots === undefined) {
        // Out of order: the values set so far into slots.
        slots = new Array<unknown>(n).fill(HOLE)
        for (let j = 0; j <= last; j++) if (Object.hasOwn(out, keys[j]!)) slots[j] = out[keys[j]!]
      }
      if (slots[i] !== HOLE) fail() // a duplicate key
      slots[i] = value
    }
    if (!optional[i]) required++
    r.endField()
  }
  if (required !== f.required) fail() // a missing field (a duplicate one has failed already)
  if (slots !== undefined) {
    out = tag === undefined ? {} : { _tag: tag }
    for (let i = 0; i < n; i++) if (slots[i] !== HOLE) setField(f, out, i, slots[i])
  }
  return out
}

/** Reads a record (at its counted `{`) into an object, `_tag` first when `tag` is given. */
type RecordRead = (r: Reader, cx: Context, depth: number, tag: string | undefined) => Record<string, unknown>

/**
 * A record case's payload, after `payload`: `Tag { … }`, or `Tag({ … })` (one
 * argument, a record), read by `fields` as `decodeRecord` reads it: at the
 * variant's depth, `_tag` first when `tag` is given.
 */
const recordPayload = (r: Reader, cx: Context, depth: number, payload: number, fields: RecordRead, tag: string | undefined): Record<string, unknown> => {
  if (payload === PAYLOAD_RECORD) return r.next() === RECORD ? fields(r, cx, depth, tag) : fail()
  if (payload !== ARGS || r.next() !== RECORD) fail()
  const out = fields(r, cx, depth, tag)
  endArguments(r)
  return out
}

/** Reads a variant's payload, after its tag. */
type CaseRead = (r: Reader, cx: Context, depth: number, tag: string) => unknown

/** One compilation of a schema's reader: every schema it reaches, once. */
export class ReadCompiler {
  private readonly readers = new Map<AnySchema, Read>()
  private readonly records = new Map<AnySchema, RecordRead>()

  /** The reader of `s`; a schema that reaches itself (a Recursive) gets a link to its reader while it is built. */
  read(s: AnySchema): Read {
    const known = this.readers.get(s)
    if (known !== undefined) return known
    let built: Read | undefined
    this.readers.set(s, (r, cx, depth) => built!(r, cx, depth))
    built = this.build(s)
    this.readers.set(s, built)
    return built
  }

  private build(s: AnySchema): Read {
    const shape = shapeOf(s)
    // Written by hand: read as a Value, decoded by the schema itself.
    if (shape === undefined) return (r, cx, depth) => s.decode(readValue(r), At.nested(cx, depth))
    switch (shape.kind) {
      case "string":
        return (r, cx) => {
          step(cx)
          return r.next() === STRING ? r.string() : fail()
        }
      case "int":
        return (r, cx) => {
          step(cx)
          const text = numberText(r)
          return INTEGER.test(text) ? BigInt(text) : fail()
        }
      case "smallInt": {
        const { min, max } = shape
        return (r, cx) => {
          step(cx)
          const text = numberText(r)
          if (!INTEGER.test(text)) fail()
          const n = Number(text) + 0 // + 0: -0 is 0, as in schema.ts
          return n >= min && n <= max ? n : fail()
        }
      }
      case "bigInt": {
        const { min, max } = shape
        return (r, cx) => {
          step(cx)
          const text = numberText(r)
          if (!INTEGER.test(text)) fail()
          const n = BigInt(text)
          return n >= min && n <= max ? n : fail()
        }
      }
      case "float":
        return floatRead(shape.name)
      case "decimal":
        return (r, cx) => {
          step(cx)
          return numberText(r)
        }
      case "bool":
        return (r, cx) => {
          step(cx)
          if (r.next() !== VARIANT) fail()
          const tag = r.tag()
          if (r.payload(tag) !== NO_PAYLOAD) fail()
          return tag === "True" ? true : tag === "False" ? false : fail()
        }
      case "bytes":
        return (r, cx) => {
          step(cx)
          return r.next() === BYTES ? r.bytes() : fail()
        }
      case "tagged": {
        const { tag, format, convert } = shape
        return (r, cx) => {
          step(cx)
          if (r.next() !== VARIANT || r.tag() !== tag || r.payload(tag) !== ARGS || r.next() !== STRING) fail()
          const text = r.string()
          endArguments(r)
          const out = format.test(text) ? convert(text) : undefined
          return out === undefined ? fail() : out
        }
      }
      case "array": {
        const item = this.read(shape.item)
        return (r, cx, depth) => {
          step(cx)
          if (r.next() !== ARRAY) fail()
          r.openList()
          const out: unknown[] = []
          while (r.more(CLOSE_ARRAY)) {
            out.push(item(r, cx, depth + 1))
            r.endItem(CLOSE_ARRAY)
          }
          return out
        }
      }
      case "map": {
        const value = this.read(shape.value)
        return (r, cx, depth) => {
          step(cx)
          if (r.next() !== RECORD) fail()
          r.openRecord()
          const out = new Map<string, unknown>()
          for (let key = r.key(); key !== undefined; key = r.key()) {
            const size = out.size
            out.set(key, value(r, cx, depth + 1))
            if (out.size === size) fail() // a duplicate key
            r.endField()
          }
          return out
        }
      }
      case "maybe": {
        const inner = this.read(shape.inner)
        const none = shape.none
        return (r, cx, depth) => {
          step(cx)
          if (r.next() !== VARIANT) fail()
          const tag = r.tag()
          const payload = r.payload(tag)
          if (tag === "None" && payload === NO_PAYLOAD) return none
          if (tag !== "Some") fail()
          return { _tag: "Some", value: oneArgument(r, cx, depth + 1, payload, inner) }
        }
      }
      case "record": {
        const fields = this.recordRead(s)
        return (r, cx, depth) => {
          step(cx)
          if (r.next() !== RECORD) fail()
          return fields(r, cx, depth, undefined)
        }
      }
      case "variant":
        return this.variant(shape.open, shape.cases())
      case "enum": {
        const tags = shape.tags
        return (r, cx) => {
          step(cx)
          if (r.next() !== VARIANT) fail()
          const tag = r.tag()
          return r.payload(tag) === NO_PAYLOAD && tags.has(tag) ? tag : fail()
        }
      }
      case "anyTag":
        return (r, cx) => {
          step(cx)
          if (r.next() !== VARIANT) fail()
          const v = readVariantAfter(r, r.tag()) as HVariant
          return v.args.length === 0 ? v.tag : unknownOf(v)
        }
      case "any":
        return (r, cx) => {
          step(cx)
          return readValue(r)
        }
      case "secret": {
        checkChain(s)
        const inner = this.read(shape.inner)
        return (r, cx, depth) => {
          step(cx)
          return new Secret(inner(r, cx, depth))
        }
      }
      case "refine": {
        checkChain(s)
        const inner = this.read(shape.inner)
        const check = shape.check as (a: unknown) => string | undefined
        return (r, cx, depth) => {
          const a = inner(r, cx, depth)
          return check(a) === undefined ? a : fail()
        }
      }
      case "transform": {
        checkChain(s)
        const inner = this.read(shape.inner)
        const decode = shape.decode as (a: unknown) => unknown
        // A decode that throws: the generic path reports it (codec-rejected, or rethrows a stack overflow).
        return (r, cx, depth) => {
          const a = inner(r, cx, depth)
          try {
            return decode(a)
          } catch {
            return fail()
          }
        }
      }
      case "recursive": {
        checkChain(s)
        const body = this.read(shape.body())
        return (r, cx, depth) => {
          const state = enterRecursive(shape, cx)
          const out = body(r, cx, depth)
          state.depth--
          return out
        }
      }
    }
  }

  /**
   * A record schema's fields reader (for a record, or a variant's record case):
   * a RecordSchema's, or a Recursive's that is a record case, entered through
   * the Recursive (its step and depth), as its `decodeRecord` does.
   */
  private recordRead(s: AnySchema): RecordRead {
    const known = this.records.get(s)
    if (known !== undefined) return known
    let built: RecordRead | undefined
    this.records.set(s, (r, cx, depth, tag) => built!(r, cx, depth, tag))
    built = this.buildRecordRead(s)
    this.records.set(s, built)
    return built
  }

  private buildRecordRead(s: AnySchema): RecordRead {
    const shape = shapeOf(s)
    if (shape?.kind === "recursive") {
      // A record case through a Recursive: its body is the record, or another such Recursive (see `caseShape`).
      const inner = this.recordRead(shape.body())
      return (r, cx, depth, tag) => {
        const state = enterRecursive(shape, cx)
        const out = inner(r, cx, depth, tag)
        state.depth--
        return out
      }
    }
    if (shape?.kind !== "record") throw new NotCompilable("a record case written by hand")
    const keys = shape.entries.map(([k]) => k)
    const f: Fields = {
      keys,
      index: new Map(keys.map((k, i) => [k, i])),
      readers: [],
      optional: shape.entries.map(([, schema]) => schema.optional === true),
      special: keys.map((k) => k in {}),
      required: shape.entries.filter(([, schema]) => schema.optional !== true).length,
      closed: shape.closed,
      bare: keys.map((k) => BARE_KEY.test(k)),
    }
    // The readers after the plan is registered: a field may refer back to this record.
    for (const [, schema] of shape.entries) f.readers.push(this.read(schema))
    return (r, cx, depth, tag) => readFields(f, r, cx, depth, tag)
  }

  private variant(open: boolean, shapes: ReadonlyMap<string, CaseShape>): Read {
    const cases = new Map<string, CaseRead>()
    for (const [tag, c] of shapes) cases.set(tag, this.case(c))
    return (r, cx, depth) => {
      step(cx)
      if (r.next() !== VARIANT) fail()
      const tag = r.tag()
      const c = cases.get(tag)
      if (c !== undefined) return c(r, cx, depth, tag)
      if (!open) fail()
      return unknownOf(readVariantAfter(r, tag) as HVariant)
    }
  }

  private case(c: CaseShape): CaseRead {
    switch (c.kind) {
      case "unit":
        return (r, _cx, _depth, tag) => (r.payload(tag) === NO_PAYLOAD ? { _tag: tag } : fail())
      case "record": {
        const fields = this.recordRead(c.schema)
        if (c.nests) return (r, cx, depth, tag) => ({ _tag: tag, value: recordPayload(r, cx, depth, r.payload(tag), fields, undefined) })
        return (r, cx, depth, tag) => recordPayload(r, cx, depth, r.payload(tag), fields, tag)
      }
      case "tuple": {
        const items = c.items.map((s) => this.read(s))
        const n = items.length
        if (n === 0) return (r, _cx, _depth, tag) => (r.payload(tag) === NO_PAYLOAD ? { _tag: tag, values: [] } : fail())
        if (n === 1) {
          const item = items[0]!
          return (r, cx, depth, tag) => ({ _tag: tag, values: [oneArgument(r, cx, depth + 1, r.payload(tag), item)] })
        }
        return (r, cx, depth, tag) => {
          if (r.payload(tag) !== ARGS) fail()
          const values: unknown[] = []
          for (let i = 0; i < n; i++) {
            if (i > 0 && !r.more(CLOSE_ARGS)) fail()
            values.push(items[i]!(r, cx, depth + 1))
            r.endItem(CLOSE_ARGS)
          }
          if (r.more(CLOSE_ARGS)) fail()
          return { _tag: tag, values }
        }
      }
      case "value": {
        const inner = this.read(c.schema)
        return (r, cx, depth, tag) => ({ _tag: tag, value: oneArgument(r, cx, depth + 1, r.payload(tag), inner) })
      }
    }
  }
}

const floatRead = (name: FloatType): Read => (r, cx) => {
  step(cx)
  const kind = r.next()
  if (kind === NUMBER) return toFloat(r.number(), name) ?? fail()
  if (kind !== VARIANT) fail()
  const tag = r.tag()
  if (r.payload(tag) !== NO_PAYLOAD) fail()
  return specialFloat(uncheckedVariant(tag)) ?? fail()
}

/**
 * `cache`'s codec of `schema`, compiled by `compile` on first use (once,
 * whatever the outcome); undefined if it can't be compiled.
 */
const compiledOnce = <F>(cache: WeakMap<AnySchema, F | null>, schema: AnySchema, compile: (schema: AnySchema) => F): F | undefined => {
  let f = cache.get(schema)
  if (f === undefined) {
    try {
      f = compile(schema)
    } catch {
      f = null
    }
    cache.set(schema, f)
  }
  return f ?? undefined
}

const readers = new WeakMap<AnySchema, Read | null>()

const compileReader = (s: AnySchema): Read => new ReadCompiler().read(s)

/** The compiled reader of `schema`, built on first use; undefined if it can't be compiled. */
export const compiledReader = (schema: AnySchema): Read | undefined => compiledOnce(readers, schema, compileReader)

/**
 * Decode one value with a compiled reader: a whole text (`item` false), or
 * one item of a stream (its text with the comma that ends it, and where it
 * starts), as `Parser.parseSequence` and `Parser.parseSingle` read them.
 * Undefined to say "run the generic path" (for anything wrong at all).
 */
const decodeOne = (read: Read, text: string, origin: Origin | undefined, limits: Limits, item: boolean): { readonly value: unknown } | undefined => {
  try {
    // A text has at most as many values as characters: the default step
    // budget for that many bounds the work; the exact one is checked below.
    const cx = decodeContext(limits, text.length)
    const r = new Reader(text, origin, cx.values)
    r.begin()
    if (r.atEnd()) return undefined // no value
    const value = read(r, cx, 0)
    if (item) r.endSingle()
    else if (r.nextTop()) return undefined // more values
    // The budget of the generic path, now that the values are counted.
    if (cx.steps > decodeSteps(limits, r.valueCount)) return undefined
    return { value }
  } catch {
    return undefined
  }
}

/** Decode `text` (exactly one value) with a compiled reader; undefined to say "run the generic path". */
export const decodeCompiled = (read: Read, text: string, limits: Limits): { readonly value: unknown } | undefined => decodeOne(read, text, undefined, limits, false)

/**
 * Decode one item of a stream (its text, with the comma that ends it, and
 * where it starts) with a compiled reader; undefined to say "run the generic path".
 */
export const decodeItem = (read: Read, text: string, origin: Origin, limits: Limits): { readonly value: unknown } | undefined => decodeOne(read, text, origin, limits, true)

// ── writers ──────────────────────────────────────────────────

/** The text being written, in compact or minimised layout (spec §11). */
export class Out {
  s = ""
  readonly tight: boolean
  /** The whitespace between tokens: `, `, `{ `, ` }`, and between a tag and its record. */
  readonly comma: string
  readonly open: string
  readonly close: string
  readonly tag: string

  constructor(readonly style: "compact" | "minimised") {
    this.tight = style === "minimised"
    this.comma = this.tight ? "," : ", "
    this.open = this.tight ? "{" : "{ "
    this.close = this.tight ? "}" : " }"
    this.tag = this.tight ? "" : " "
  }

  /** A `Value` (raw, or from a schema written by hand), as the formatter writes it in this layout. */
  value(v: Value): void {
    this.s += stringifyValue(v, { style: this.style })
  }
}

/** An integer's decimal text, within the number limit of the reader written for (spec §7). */
const integerText = (text: string, cx: Context): string => (text.length > cx.values.maxNumberLength ? fail() : text)

/** What a record's fields writer needs, built once per record schema. */
interface FieldWriters {
  readonly keys: readonly string[]
  readonly writers: Write[]
  readonly optional: readonly boolean[]
  /** `key: ` and `key:` (the key bare or quoted), for compact and minimised. */
  readonly spaced: readonly string[]
  readonly tight: readonly string[]
}

export const isEnumerable = Object.prototype.propertyIsEnumerable

/**
 * `a`'s fields in the schema's order, as `encodeRecord` encodes them, at
 * `depth` (the record's). `enumerable`: a variant's record case, whose fields
 * are the object's own enumerable properties but `_tag` (`{ _tag, ...fields }`);
 * else its own properties. An optional field without a value is left out. Hot.
 */
const writeFields = (f: FieldWriters, w: Out, a: unknown, cx: Context, depth: number, enumerable: boolean): void => {
  if (typeof a !== "object" || a === null) fail()
  if (depth >= cx.maxDepth) fail() // `at.open()`
  const obj = a as Record<string, unknown>
  const { keys, writers, optional } = f
  const prefix = w.tight ? f.tight : f.spaced
  let first = true
  // Its own enumerable keys, in order (a variant's record case has its `_tag`
  // first, not a field): a field that is the next of them is its own, the
  // others are checked. An object built in the schema's order has them all.
  const own = Object.keys(obj)
  let j = enumerable && own[0] === "_tag" ? 1 : 0
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i]!
    let value: unknown
    if (own[j] === key) {
      j++
      value = obj[key]
    } else value = (enumerable ? isEnumerable.call(obj, key) : Object.hasOwn(obj, key)) ? obj[key] : undefined
    if (optional[i] && value === undefined) continue
    if (first) {
      w.s += w.open
      first = false
    } else w.s += w.comma
    w.s += prefix[i]!
    writers[i]!(w, value, cx, depth + 1)
  }
  w.s += first ? "{}" : w.close
}

/** Writes a record's fields (`writeFields`), entered through Recursives as a record case is. */
type RecordWrite = (w: Out, a: unknown, cx: Context, depth: number, enumerable: boolean) => void
type CaseWrite = (w: Out, a: Record<string, unknown>, cx: Context, depth: number, tag: string) => void

/**
 * How a schema's encoded value is written as a variant's one argument: a
 * record as `Tag { … }` ("record"), anything else as `Tag(…)` ("other"), or
 * known only once written ("either": a raw value, a schema written by hand).
 */
export type ArgumentForm = "record" | "other" | "either"

/** How `s`'s encoded value is written as a variant's one argument (`ArgumentForm`). */
export const argumentForm = (s: AnySchema, seen: Set<AnySchema> = new Set()): ArgumentForm => {
  const shape = shapeOf(s)
  if (shape === undefined || seen.has(s)) return "either"
  seen.add(s)
  switch (shape.kind) {
    case "record":
    case "map":
      return "record"
    case "secret":
    case "refine":
    case "transform":
      return argumentForm(shape.inner, seen)
    case "recursive":
      return argumentForm(shape.body(), seen)
    case "any":
    case "anyTag": // an Unknown's raw value can be anything
      return "either"
    default:
      return "other"
  }
}

/** One compilation of a schema's writer: every schema it reaches, once. */
export class WriteCompiler {
  private readonly writers = new Map<AnySchema, Write>()
  private readonly records = new Map<AnySchema, RecordWrite>()

  write(s: AnySchema): Write {
    const known = this.writers.get(s)
    if (known !== undefined) return known
    let built: Write | undefined
    this.writers.set(s, (w, a, cx, depth) => built!(w, a, cx, depth))
    built = this.build(s)
    this.writers.set(s, built)
    return built
  }

  private build(s: AnySchema): Write {
    const shape = shapeOf(s)
    if (shape === undefined) return (w, a, cx, depth) => w.value(s.encode(a, At.nested(cx, depth)))
    switch (shape.kind) {
      case "string":
        return (w, a, cx) => {
          step(cx)
          // Within the string limit (spec §7: encoding checks what the constructors check), else the generic path reports it.
          w.s += typeof a === "string" && a.length <= cx.values.maxStringLength ? quote(a) : fail()
        }
      case "int":
        return (w, a, cx) => {
          step(cx)
          w.s += typeof a === "bigint" ? integerText(a.toString(), cx) : fail()
        }
      case "smallInt": {
        const { min, max } = shape
        return (w, a, cx) => {
          step(cx)
          w.s += typeof a === "number" && Number.isInteger(a) && a >= min && a <= max ? integerText(String(a), cx) : fail()
        }
      }
      case "bigInt": {
        const { min, max } = shape
        return (w, a, cx) => {
          step(cx)
          w.s += typeof a === "bigint" && a >= min && a <= max ? integerText(a.toString(), cx) : fail()
        }
      }
      case "float": {
        const name = shape.name
        return (w, a, cx) => {
          step(cx)
          const v = typeof a === "number" ? (floatValue(a, name) ?? fail()) : fail()
          w.s += v.kind === "number" ? v.text : v.tag
        }
      }
      case "decimal":
        return (w, a, cx) => {
          step(cx)
          const text = typeof a === "string" ? (normalizeNumber(a, cx.values) ?? fail()) : fail()
          w.s += numberLimitIssue(text, cx.values) === undefined ? text : fail()
        }
      case "bool":
        return (w, a, cx) => {
          step(cx)
          w.s += a === true ? "True" : a === false ? "False" : fail()
        }
      case "bytes":
        return (w, a, cx) => {
          step(cx)
          // Two hex digits a byte, within the string limit (spec §7), else the generic path reports it.
          w.s += a instanceof Uint8Array && a.length * 2 <= cx.values.maxStringLength ? `x"${toHex(a)}"` : fail()
        }
      case "tagged": {
        const { tag, format, convert } = shape
        const toText = shape.toText as (a: unknown) => string
        return (w, a, cx) => {
          step(cx)
          const text = toText(a)
          w.s += typeof text === "string" && format.test(text) && convert(text) !== undefined ? `${tag}(${quote(text)})` : fail()
        }
      }
      case "array": {
        const item = this.write(shape.item)
        return (w, a, cx, depth) => {
          step(cx)
          if (!Array.isArray(a) || depth >= cx.maxDepth) fail()
          const xs = a as readonly unknown[]
          w.s += "["
          for (let i = 0; i < xs.length; i++) {
            if (i > 0) w.s += w.comma
            const x = xs[i]
            if (x === undefined && !(i in xs)) fail() // a hole: the generic path fails on it
            item(w, x, cx, depth + 1)
          }
          w.s += "]"
        }
      }
      case "map": {
        const value = this.write(shape.value)
        return (w, a, cx, depth) => {
          step(cx)
          if (!(a instanceof Map) || depth >= cx.maxDepth) fail()
          const m = a as ReadonlyMap<unknown, unknown>
          if (m.size === 0) return void (w.s += "{}")
          const colon = w.tight ? ":" : ": "
          let first = true
          for (const [k, x] of m) {
            // Within the string limit, as the generic path checks a key (spec §7, key-too-long), which reports it.
            if (typeof k !== "string" || k.length > cx.values.maxStringLength) fail()
            w.s += (first ? w.open : w.comma) + keyText(k as string) + colon
            first = false
            value(w, x, cx, depth + 1)
          }
          w.s += w.close
        }
      }
      case "maybe": {
        const inner = this.argument(shape.inner)
        return (w, a, cx, depth) => {
          step(cx)
          if (!Maybe.is(a)) return fail()
          if (a._tag === "None") return void (w.s += "None")
          if (depth >= cx.maxDepth) fail() // `at.child(0)`
          w.s += "Some"
          inner(w, a.value, cx, depth + 1)
        }
      }
      case "record": {
        const fields = this.recordWrite(s)
        return (w, a, cx, depth) => {
          step(cx)
          fields(w, a, cx, depth, false)
        }
      }
      case "variant":
        return this.variant(shape.open, shape.cases())
      case "enum": {
        const tags = shape.tags
        return (w, a, cx) => {
          step(cx)
          w.s += typeof a === "string" && tags.has(a) ? a : fail()
        }
      }
      case "anyTag":
        return (w, a, cx, depth) => {
          step(cx)
          if (typeof a === "string") w.s += TAG.test(a) ? a : fail()
          else if (typeof a === "object" && a !== null && (a as { _tag?: unknown })._tag === "@unknown") w.value(checkedValue((a as { value?: unknown }).value, At.nested(cx, depth)))
          else fail()
        }
      case "any":
        return (w, a, cx, depth) => {
          step(cx)
          w.value(checkedValue(a, At.nested(cx, depth)))
        }
      case "secret": {
        checkChain(s)
        const inner = this.write(shape.inner)
        return (w, a, cx, depth) => {
          step(cx)
          // Without revealSecrets the generic path refuses it (spec §15, "Encoding a secret").
          if (!(a instanceof Secret) || !cx.revealSecrets) fail()
          inner(w, (a as Secret<unknown>).expose(), cx, depth)
        }
      }
      case "refine": {
        checkChain(s)
        const inner = this.write(shape.inner)
        const check = shape.check as (a: unknown) => string | undefined
        return (w, a, cx, depth) => (check(a) === undefined ? inner(w, a, cx, depth) : fail())
      }
      case "transform": {
        checkChain(s)
        const inner = this.write(shape.inner)
        const encode = shape.encode as (b: unknown) => unknown
        return (w, b, cx, depth) => {
          let a: unknown
          try {
            a = encode(b)
          } catch {
            return fail()
          }
          inner(w, a, cx, depth)
        }
      }
      case "recursive": {
        checkChain(s)
        const body = this.write(shape.body())
        return (w, a, cx, depth) => {
          const state = enterRecursive(shape, cx)
          body(w, a, cx, depth)
          state.depth--
        }
      }
    }
  }

  /**
   * The writer of `s` as a variant's one argument, after the tag: ` { … }`
   * for a record, `(…)` for anything else, as the formatter writes them.
   */
  private argument(s: AnySchema): Write {
    const inner = this.write(s)
    switch (argumentForm(s)) {
      case "record":
        return (w, a, cx, depth) => {
          w.s += w.tag
          inner(w, a, cx, depth)
        }
      case "other":
        return (w, a, cx, depth) => {
          w.s += "("
          inner(w, a, cx, depth)
          w.s += ")"
        }
      case "either":
        return (w, a, cx, depth) => {
          // Written apart first: a record is the only value that starts with `{`.
          const part = new Out(w.style)
          inner(part, a, cx, depth)
          w.s += part.s.startsWith("{") ? w.tag + part.s : `(${part.s})`
        }
    }
  }

  /** A record schema's fields writer: a RecordSchema's, or a Recursive's that is a record case (through its step and depth). */
  private recordWrite(s: AnySchema): RecordWrite {
    const known = this.records.get(s)
    if (known !== undefined) return known
    let built: RecordWrite | undefined
    this.records.set(s, (w, a, cx, depth, enumerable) => built!(w, a, cx, depth, enumerable))
    built = this.buildRecordWrite(s)
    this.records.set(s, built)
    return built
  }

  private buildRecordWrite(s: AnySchema): RecordWrite {
    const shape = shapeOf(s)
    if (shape?.kind === "recursive") {
      // A record case through a Recursive: its body is the record, or another such Recursive (see `caseShape`).
      const inner = this.recordWrite(shape.body())
      return (w, a, cx, depth, enumerable) => {
        const state = enterRecursive(shape, cx)
        inner(w, a, cx, depth, enumerable)
        state.depth--
      }
    }
    if (shape?.kind !== "record") throw new NotCompilable("a record case written by hand")
    const keys = shape.entries.map(([k]) => k)
    const f: FieldWriters = {
      keys,
      writers: [],
      optional: shape.entries.map(([, schema]) => schema.optional === true),
      spaced: keys.map((k) => `${keyText(k)}: `),
      tight: keys.map((k) => `${keyText(k)}:`),
    }
    for (const [, schema] of shape.entries) f.writers.push(this.write(schema))
    return (w, a, cx, depth, enumerable) => writeFields(f, w, a, cx, depth, enumerable)
  }

  private variant(open: boolean, shapes: ReadonlyMap<string, CaseShape>): Write {
    const cases = new Map<string, CaseWrite>()
    for (const [tag, c] of shapes) cases.set(tag, this.case(c))
    return (w, a, cx, depth) => {
      step(cx)
      if (typeof a !== "object" || a === null) fail()
      const obj = a as Record<string, unknown>
      const tag = obj._tag
      if (typeof tag !== "string") fail()
      if (open && tag === "@unknown") {
        // Written back as received, once checked (`checkedValue`): a variant the schema doesn't list.
        const raw = checkedValue(obj.value, At.nested(cx, depth))
        if (raw.kind !== "variant" || cases.has(raw.tag)) fail()
        return w.value(raw)
      }
      const c = cases.get(tag as string)
      if (c === undefined) fail()
      c!(w, obj, cx, depth, tag as string)
    }
  }

  private case(c: CaseShape): CaseWrite {
    switch (c.kind) {
      case "unit":
        return (w, _a, _cx, _depth, tag) => void (w.s += tag)
      case "record": {
        const fields = this.recordWrite(c.schema)
        if (c.nests) {
          return (w, a, cx, depth, tag) => {
            w.s += tag + w.tag
            fields(w, a.value, cx, depth, false)
          }
        }
        return (w, a, cx, depth, tag) => {
          w.s += tag + w.tag
          fields(w, a, cx, depth, true)
        }
      }
      case "tuple": {
        const n = c.items.length
        if (n === 1) {
          const item = this.argument(c.items[0]!)
          return (w, a, cx, depth, tag) => {
            const values = a.values
            if (!Array.isArray(values) || values.length !== 1) fail()
            if (depth >= cx.maxDepth) fail() // `at.child(0)`
            w.s += tag
            item(w, (values as readonly unknown[])[0], cx, depth + 1)
          }
        }
        const items = c.items.map((s) => this.write(s))
        return (w, a, cx, depth, tag) => {
          const values = a.values
          if (!Array.isArray(values) || values.length !== n) fail()
          const xs = values as readonly unknown[]
          if (n === 0) return void (w.s += tag)
          if (depth >= cx.maxDepth) fail() // `at.child(i)`
          w.s += `${tag}(`
          for (let i = 0; i < n; i++) {
            if (i > 0) w.s += w.comma
            items[i]!(w, xs[i], cx, depth + 1)
          }
          w.s += ")"
        }
      }
      case "value": {
        const inner = this.argument(c.schema)
        return (w, a, cx, depth, tag) => {
          if (depth >= cx.maxDepth) fail() // `at.child(0)`
          w.s += tag
          inner(w, a.value, cx, depth + 1)
        }
      }
    }
  }
}

const writers = new WeakMap<AnySchema, Write | null>()

const compileWriter = (s: AnySchema): Write => new WriteCompiler().write(s)

/** The compiled writer of `schema`, built on first use; undefined if it can't be compiled. */
export const compiledWriter = (schema: AnySchema): Write | undefined => compiledOnce(writers, schema, compileWriter)

/** Encode `value` as one line of text with a compiled writer; undefined to say "run the generic path". */
export const encodeCompiled = (write: Write, value: unknown, limits: Limits, style: "compact" | "minimised"): string | undefined => {
  try {
    const cx = encodeContext(limits)
    const w = new Out(style)
    write(w, value, cx, 0)
    // Generated code counts a leaf's step without checking it (codegen.ts): the budget, checked once more.
    return cx.steps > cx.maxSteps ? undefined : w.s
  } catch {
    return undefined
  }
}
