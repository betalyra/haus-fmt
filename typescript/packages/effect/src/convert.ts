/**
 * haus `Value` → the encoded JS shape an Effect schema expects.
 *
 * A schema is compiled once into a tree of small converter functions
 * (pattern matching on the schema AST happens here, at compile time). Per
 * value only those closures run, which keeps stream decoding fast. Effect's
 * own decoder then validates the result. Where the haus value decides the
 * error code (spec §17: a tag of a closed variant, a payload, a whole number,
 * a float too large) a converter fails with a ConversionError and its code;
 * elsewhere it falls back to a schema-less conversion and lets Effect report
 * the error with its path (errors.ts gives Effect's issues their codes).
 */
import {
  arr as vArr, bytes as vBytes, checkStdTime, DEFAULT_LIMITS, equals, floatValue as coreFloatValue, MAX_DEPTH, num as vNum, rec as vRec, specialFloat, str as vStr, toFloat,
  payloadHint, quoteText, variant as vVariant, type CasePayload, type ErrorCode, type FloatType, type HVariant, type StdTimeType, type Value,
} from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"
import { Array as Arr, BigDecimal, DateTime, Duration, Match, Option, Predicate, Redacted, SchemaAST } from "effect"

export type Converter = (value: Value) => unknown

type AST = SchemaAST.AST

/** Tag of the payload-less variant produced for unknown tags in an OpenUnion. */
export const UNKNOWN_TAG = "@unknown"

/** Annotation set by `Haus.Positional`: positional args may fill the struct's fields in order. */
export const POSITIONAL = "hausPositional"

/** Annotation set by `Haus.Date` & co.: a string written as a prelude tag, `Date("…")`. */
export const PRELUDE_TAG = "hausPreludeTag"

/** Annotation on a string schema: the value is a bare tag, `EUR` ↔ "EUR". */
export const BARE_TAG = "hausBareTag"

/** Annotation on a tagged struct `{ _tag, values }`: the variant's positional arguments are `values`. */
export const VALUES = "hausValues"

/**
 * Annotation on a tagged struct `{ _tag, value }`: the variant's record payload
 * is `value`, a struct of its own. A schema file's case whose record payload
 * lists a field named `_tag` (`< Odd { _tag: Int32 } >`): its fields can't go
 * beside the tag.
 */
export const NESTED = "hausNested"

/** Annotation on a struct: a closed record `{| … |}`, other fields are an error. */
export const CLOSED = "hausClosed"

/** Annotation on a string schema: only a haus string, never a number or `Tag("…")` (a schema file's `String`). */
export const STRICT = "hausStrict"

/** Annotation on a string schema (`Haus.Decimal`): a haus number, as its exact normalized literal (`"19.90"`, `"1.5e3"`, `"-0"`). */
export const DECIMAL = "hausDecimal"

/** Annotation on an `Any` schema (`Haus.Any`): the value is the parsed haus `Value`, unchanged. */
export const VALUE = "hausValue"

/**
 * Annotation on a `Schema.Redacted` (a schema file's `Secret a`): the haus
 * type inside, for error messages that name it without the value.
 */
export const SECRET = "hausSecret"

/**
 * Annotation on a number schema: which haus number type it is. "Int" takes
 * whole numbers only (Int8 … UInt32), "Float32" rounds to binary32; without
 * it, a number schema is a Float64.
 */
export const NUMBER = "hausNumber"

export type NumberType = "Int" | FloatType

/**
 * Thrown during conversion; `decodeValue` turns it into a HausSchemaError.
 * `code` is its error code (spec §17), `path` is where, as in Effect's issues
 * (a number on a variant: its argument).
 */
export class ConversionError {
  /** `hint`: a concrete fix (`wrong-payload`: what the tag's case takes); without one, the catalogue's. */
  constructor(readonly message: string, readonly code: ErrorCode, readonly path: ReadonlyArray<string | number> = [], readonly hint?: string) {}
}

/** Convert the value at `key`: an error inside names its place. */
const at = <A>(key: string | number, f: () => A): A => {
  try {
    return f()
  } catch (e) {
    if (e instanceof ConversionError) throw new ConversionError(e.message, e.code, [key, ...e.path], e.hint)
    throw e
  }
}

/** A short description of a value, for errors. */
const describe = (v: Value): string => {
  switch (v.kind) {
    case "string":
      return `a string "${quoteText(v.value)}"`
    case "number":
      return `the number ${quoteText(v.text)}`
    case "bytes":
      return "a byte string"
    case "array":
      return "an array"
    case "record":
      return "a record"
    case "variant":
      return v.args.length === 0 ? `the tag ${quoteText(v.tag)}` : `${quoteText(v.tag)} with ${v.args.length === 1 && v.args[0]!.kind === "record" ? "a record" : `${v.args.length} argument(s)`}`
  }
}

/**
 * A value the schema doesn't take (spec §15: no conversion between kinds).
 * An error here, rather than a schema-less conversion that a lenient Effect
 * schema might accept (a struct takes any object, a string literal any equal string).
 */
const mismatch = (expected: string, v: Value, code: ErrorCode = "type-mismatch", hint?: string): never => {
  throw new ConversionError(`expected ${expected}, got ${describe(v)}`, code, [], hint)
}

/** A listed tag with another payload than its case takes (spec §15): the hint names the case. */
const wrongPayload = (expected: string, v: HVariant, takes: CasePayload): never => mismatch(expected, v, "wrong-payload", payloadHint(v.tag, takes))

/**
 * The code for a value that isn't one of these tags as a closed variant takes
 * them (spec §17, as the core decides): an unknown tag is `unknown-tag`, a
 * listed tag with another payload `wrong-payload`, anything else `type-mismatch`.
 */
const caseCode = (v: Value, tags: ReadonlyArray<string>): ErrorCode =>
  v.kind !== "variant" ? "type-mismatch" : tags.includes(v.tag) ? "wrong-payload" : "unknown-tag"

/** A value that is none of these tags of a closed variant (`Bool`, `Maybe`, an enum); `takes` is what a tag's case takes (default: no payload). */
const notCase = (expected: string, v: Value, tags: ReadonlyArray<string>, takes: (tag: string) => CasePayload = () => ({ kind: "none" })): never =>
  v.kind === "variant" && tags.includes(v.tag) ? wrongPayload(expected, v, takes(v.tag)) : mismatch(expected, v, caseCode(v, tags))

/** For an integer type: a number with a fraction or an exponent is `not-an-integer`, anything else a mismatch. */
const notInteger = (v: Value): never => mismatch("a whole number", v, v.kind === "number" ? "not-an-integer" : "type-mismatch")

const INTEGER = /^-?\d+$/

const BOOL_TAGS = ["True", "False"]
const MAYBE_TAGS = ["None", "Some"]

// ── value helpers ────────────────────────────────────────────

const variant = (v: Value, tag?: string, arity?: number): Option.Option<HVariant> =>
  v.kind === "variant" && (tag === undefined || v.tag === tag) && (arity === undefined || v.args.length === arity)
    ? Option.some(v)
    : Option.none()

/** A prelude scalar like `Instant("…")`: the tag with one string argument. */
const scalarString = (v: Value, tag?: string): Option.Option<string> =>
  variant(v, tag, 1).pipe(
    Option.flatMap(({ args: [arg] }) => (arg?.kind === "string" ? Option.some(arg.value) : Option.none())),
  )

// ── limits ───────────────────────────────────────────────────

/**
 * Limits for one conversion. Converters are plain closures shared by all
 * calls, so the entry points set these around each (synchronous) conversion.
 */
interface Guard {
  steps: number
  readonly maxSteps: number
  depth: number
  /** Most nested converter calls (see `maxNesting`). */
  readonly maxNesting: number
  /** The call's limits, for checking raw values and decimals when encoding (spec §9.8). */
  readonly limits: h.Limits
}

/** Nested converter calls per level of a value: schema wrappers plus the value's own level. */
const NESTING_PER_LEVEL = 8
/**
 * Nested converter calls for values within `maxDepth` levels: at least 2048,
 * comfortably above the parser's default 256 levels. A guard against cycles
 * and runaway schemas: the depth itself is checked on the value (`decodeBudget`, `encoding`).
 */
const maxNesting = (maxDepth: number): number => Math.max(2048, NESTING_PER_LEVEL * maxDepth)
/** Steps per input value when decoding: conversion stays linear in the input. */
const STEPS_PER_VALUE = 16
/** Default budget when encoding, which also bounds objects shared many times (a DAG). */
const DEFAULT_ENCODE_STEPS = 16 * 1024 * 1024
/** Values beyond the node limit (`maxNodes`, default 64 Mi, spec §7) are rejected: the parser's 64 Mi characters can't produce more. */
const nodesOf = (limits: h.Limits): number => limits.maxNodes ?? DEFAULT_LIMITS.maxNodes

/** The nesting limit of a call (spec §7): `maxDepth`, 256 by default. */
const depthOf = (limits: h.Limits): number => limits.maxDepth ?? MAX_DEPTH

let guard: Guard = { steps: 0, maxSteps: Infinity, depth: 0, maxNesting: maxNesting(MAX_DEPTH), limits: {} }

/** Run `f` with a fresh budget of `maxSteps`, within `limits`. */
const guarded = <R>(limits: h.Limits, maxSteps: number, f: () => R): R => {
  const saved = guard
  guard = { steps: 0, maxSteps, depth: 0, maxNesting: maxNesting(depthOf(limits)), limits }
  try {
    return f()
  } finally {
    guard = saved
  }
}

const enter = () => {
  if (++guard.steps > guard.maxSteps) throw new ConversionError(`conversion budget of ${guard.maxSteps} steps exceeded`, "step-budget")
  if (guard.depth >= guard.maxNesting) throw new ConversionError(`value nested deeper than ${guard.maxNesting} levels (or cyclic)`, "nesting-too-deep")
  guard.depth++
}

const leave = () => {
  guard.depth--
}

/** Whether the parser counts `v` as a level of nesting: records, arrays and `Tag(…)`. */
const isNested = (v: Value): boolean => v.kind === "array" || v.kind === "record" || (v.kind === "variant" && v.args.length > 0)

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
 * Count the values in a tree, failing when it nests deeper than `maxDepth`
 * levels (counted as the parser counts them) or has too many values. A
 * parsed value is a tree within the parser's limits; a `Value` built in code
 * might be deeper, share nodes (a DAG) or even contain itself. A shared value
 * counts each time it is reached, as decoding visits it, but is walked once:
 * its count and the levels it needs are remembered, so a DAG that expands
 * beyond the limit fails at once instead of after 64 Mi steps.
 */
const countValues = (value: Value, maxDepth: number, maxNodes: number): number => {
  const tooMany = () => {
    throw new ConversionError(`value has more than ${maxNodes} nodes`, "too-many-nodes")
  }
  const tooDeep = () => {
    throw new ConversionError(`value nested deeper than ${maxDepth} levels (or cyclic)`, "nesting-too-deep")
  }
  if (!isNested(value)) return 1
  /** Containers holding containers, counted (or `OPEN`, being counted). */
  const known = new Map<Value, { readonly size: number; readonly need: number }>()
  const stack: Counting[] = []
  const enter = (v: Value, depth: number) => {
    if (depth >= maxDepth) tooDeep()
    const items = v.kind === "array" ? v.items : v.kind === "variant" ? v.args : undefined
    const fields = v.kind === "record" ? v.fields.values() : undefined
    const payload = v.kind === "variant" && v.args.length === 1 && v.args[0]!.kind === "record"
    stack.push({ value: v, depth, items, fields, next: 0, payload, size: 1, need: 1, holds: false })
  }
  enter(value, 0)
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
        if (parent.size > maxNodes) tooMany()
        continue
      }
    }
    if (!isNested(child)) {
      if (++top.size > maxNodes) tooMany()
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
      if (top.size > maxNodes) tooMany()
    }
  }
}

/**
 * The decode budget for `value`: proportional to its size (or `maxSteps`).
 * Fails on values too deep (beyond `maxDepth`) or too large to be parsed input.
 */
const decodeBudget = (value: Value, limits: h.Limits): number => {
  const budget = STEPS_PER_VALUE * countValues(value, depthOf(limits), nodesOf(limits)) + 1024
  return limits.maxSteps ?? budget
}

/** Decode `value` with `convert`, within `limits` (see `decodeBudget`). */
export const decoding = <R>(value: Value, limits: h.Limits, convert: (value: Value) => R): R =>
  guarded(limits, decodeBudget(value, limits), () => convert(value))

/**
 * Encode with `encode`, within `limits`: a budget of `maxSteps` (16 Mi by
 * default), and a value nested at most `maxDepth` levels, as the parser reads it.
 */
export const encoding = (limits: h.Limits, encode: () => Value): Value => {
  const value = guarded(limits, limits.maxSteps ?? DEFAULT_ENCODE_STEPS, encode)
  countValues(value, depthOf(limits), nodesOf(limits))
  return value
}

// ── the value handed to Effect's encoder ─────────────────────

/**
 * Levels of objects a value to encode may nest, for a `maxDepth`: twice as
 * many plus 16, room for host objects around values (a Redacted, a
 * BigDecimal, a class around a field), and well below the ~1900 levels at
 * which Effect's encoder overflows Node's default stack. The value it
 * produces is then held to `maxDepth` itself (`encoding`).
 */
const hostLevelsOf = (maxDepth: number): number => 2 * maxDepth + 16

type Key = string | number

/**
 * Objects Effect's encoder doesn't walk into: binary data, dates, and
 * Effect's scalars, whose own properties hold caches (a BigDecimal's normal
 * form, which refers to itself) rather than values.
 */
const isOpaque = (o: object): boolean =>
  !isPlain(o) && (ArrayBuffer.isView(o) || o instanceof ArrayBuffer || o instanceof Date || o instanceof RegExp
    || BigDecimal.isBigDecimal(o) || DateTime.isDateTime(o) || Duration.isDuration(o))

/** An array or an object literal: the common case, told apart quickly. */
const isPlain = (o: object): boolean => {
  const proto = Object.getPrototypeOf(o)
  return proto === Object.prototype || proto === Array.prototype || proto === null
}

/** A Redacted, the one wrapper that adds no level (`isPlain` first: it is quicker). */
const isSecret = (o: object): o is Redacted.Redacted<unknown> => !isPlain(o) && Redacted.isRedacted(o)

/** A haus `Value` (in a `Haus.Any`, an Unknown's payload), whose levels count as the parser counts them. */
const isValueNode = (o: object): o is Value => {
  const v = o as { readonly kind?: unknown; readonly items?: unknown; readonly fields?: unknown; readonly args?: unknown }
  switch (v.kind) {
    case "array":
      return Array.isArray(v.items)
    case "record":
      return v.fields instanceof Map
    case "variant":
      return Array.isArray(v.args)
    default:
      return v.kind === "string" || v.kind === "number" || v.kind === "bytes"
  }
}

/** The levels an object adds below the one holding it: a haus value as the parser counts it, a Redacted none, other objects one. */
const levelsOf = (o: object): number => (isSecret(o) ? 0 : isValueNode(o) ? (isNested(o) ? 1 : 0) : 1)

/** Walk without the schema: everything reachable from the object (see `checkEncodable`). */
const GENERIC = Symbol("generic")

/** How an object is walked: by a structural node of the schema's type side, or without the schema. */
type Guide = SchemaAST.Objects | SchemaAST.Arrays | SchemaAST.Declaration | typeof GENERIC

/**
 * A child of an object, walked by `ast` (or without the schema). `flat`: it
 * adds no level (a variant's record payload; a class instance's fields,
 * walked on the instance itself).
 */
interface Edge {
  readonly value: unknown
  readonly key: Key | undefined
  readonly ast: AST | typeof GENERIC
  readonly flat?: boolean
}

const generic_ = (value: unknown, key: Key | undefined, flat?: boolean): Edge => ({ value, key, ast: GENERIC, ...(flat ? { flat } : {}) })

/** Own enumerable properties of `o`, but `skip`. */
const ownEdges = (o: object, skip: string): Edge[] => Object.keys(o).flatMap((k) => (k === skip ? [] : [generic_((o as Record<string, unknown>)[k], k)]))

/** Without the schema, the children of an object that isn't an array or an ordinary object: a Redacted's value, Map and Set entries, a haus value's. */
const genericEdges = (o: object): ReadonlyArray<Edge> | undefined => {
  if (isSecret(o)) {
    try {
      return [generic_(Redacted.value(o), undefined)]
    } catch {
      return [] // wiped
    }
  }
  if (o instanceof Map) return Array.from(o, ([k, x]): Edge[] => [generic_(k, undefined), generic_(x, typeof k === "string" || typeof k === "number" ? k : undefined)]).flat()
  if (o instanceof Set) return Array.from(o, (x): Edge => generic_(x, undefined))
  if (!isValueNode(o)) return undefined
  // The parser's levels: `[…]`, `{…}` and `Tag(…)` are one each, `Tag { … }` one in all.
  switch (o.kind) {
    case "array":
      return [...ownEdges(o, "items"), ...Array.from(o.items, (x, i): Edge => generic_(x, i))]
    case "record":
      return [...ownEdges(o, "fields"), ...Array.from(o.fields, ([k, x]): Edge => generic_(x, k))]
    case "variant": {
      const [first] = o.args
      const payload = o.args.length === 1 && typeof first === "object" && first !== null && isValueNode(first) && first.kind === "record"
      return [...ownEdges(o, "args"), ...Array.from(o.args, (x, i): Edge => generic_(x, i, payload))]
    }
    default:
      return ownEdges(o, "")
  }
}

/**
 * How Effect's encoder walks `value` at `ast` (its type side): the structural
 * node it applies, several for a union whose members the value's tag doesn't
 * tell apart (Effect may try each), none for a scalar. Union members are
 * those the tag allows. `Unknown`, `Any` (`Haus.Any`) and `object` are walked
 * without the schema, as the haus converter after Effect's encoder walks them.
 */
const guideOf = (ast: AST, value: object): Guide | ReadonlyArray<Guide> | undefined => {
  switch (ast._tag) {
    case "Objects":
    case "Arrays":
      return ast
    case "Suspend":
      return guideOf(ast.thunk(), value)
    case "Declaration":
      return ast.typeParameters.length > 0 ? ast : undefined
    case "Unknown":
    case "Any":
    case "ObjectKeyword":
      return GENERIC
    case "Union": {
      const tag = (value as { readonly _tag?: unknown })._tag
      const out: Guide[] = []
      for (const member of ast.types) {
        if (typeof tag === "string" && Option.getOrElse(tagOf(member), () => tag) !== tag) continue
        const g = guideOf(member, value)
        if (isGuides(g)) out.push(...g)
        else if (g !== undefined) out.push(g)
      }
      return out.length === 0 ? undefined : out.length === 1 ? out[0] : out
    }
    default:
      return undefined
  }
}

const isGuides = (g: Guide | ReadonlyArray<Guide> | undefined): g is ReadonlyArray<Guide> => Array.isArray(g)

/** The element type at index `i` of an array of `length` (none for an excess element, which Effect rejects without walking it). */
const elementAst = (ast: SchemaAST.Arrays, i: number, length: number): AST | undefined => {
  const { elements, rest } = ast
  if (i < elements.length) return elements[i]
  if (rest.length === 0) return undefined
  const restEnd = length - (rest.length - 1)
  return i < restEnd ? rest[0] : rest[1 + i - restEnd]
}

/** Iterate `o` if it is iterable (a Map, a Set, a Chunk, a HashMap…); nothing otherwise, which Effect rejects. */
const entriesOf = (o: object): ReadonlyArray<unknown> => (Symbol.iterator in o ? Array.from(o as Iterable<unknown>) : [])

/**
 * The children of a declaration with type parameters, as Effect's encoder
 * reaches them: a class instance's fields (on the instance itself), an
 * Option's value, a Redacted's value, the entries of a Map, Set, Chunk,
 * HashMap or HashSet. Other declarations (Exit, Cause, a user's) are walked
 * without the schema.
 */
const declarationEdges = (ast: SchemaAST.Declaration, o: object): ReadonlyArray<Edge> => {
  const [a, b] = ast.typeParameters as ReadonlyArray<AST>
  if (ast.annotations?.["~constructor"] !== undefined && ast.typeParameters.length === 1) return [{ value: o, key: undefined, ast: a!, flat: true }]
  switch (Option.getOrUndefined(declarationId(ast))) {
    case "effect/schema/Option":
      return Option.isOption(o) && Option.isSome(o) ? [{ value: o.value, key: "value", ast: a! }] : []
    case "effect/schema/Redacted":
      return isSecret(o) ? (genericEdges(o) ?? []).map((e) => ({ ...e, ast: a! })) : []
    case "effect/schema/ReadonlyMap":
    case "effect/schema/HashMap":
      return entriesOf(o).flatMap((entry): Edge[] => {
        if (!Array.isArray(entry)) return []
        const [k, x] = entry as [unknown, unknown]
        return [{ value: k, key: undefined, ast: a! }, { value: x, key: typeof k === "string" || typeof k === "number" ? k : undefined, ast: b! }]
      })
    case "effect/schema/ReadonlySet":
    case "effect/schema/HashSet":
    case "effect/schema/Chunk":
      return entriesOf(o).map((x): Edge => ({ value: x, key: undefined, ast: a! }))
    default:
      return [{ value: o, key: undefined, ast: GENERIC, flat: true }]
  }
}

/** A child still to walk by another guide (a union's other members). */
interface Pending {
  readonly value: object
  readonly key: Key | undefined
  readonly flat: boolean
  readonly guide: Guide
}

/** An object being walked by a guide: where it is, how deep, its children, and what of it is counted so far. */
interface Frame {
  readonly node: object
  readonly guide: Guide
  readonly key: Key | undefined
  /** Levels from the root, this object's included. */
  readonly depth: number
  /** The children: an array's by index, an object's by key (`keys`, own keys without the schema; `props`, a struct's fields) or listed (`edges`), in that order. */
  readonly keys: ReadonlyArray<string> | undefined
  readonly props: ReadonlyArray<SchemaAST.PropertySignature> | undefined
  readonly edges: ReadonlyArray<Edge> | undefined
  readonly count: number
  next: number
  pending: Pending[] | undefined
  /** Whether it holds objects: only then can it be in a cycle, and is it remembered. */
  holdsObjects: boolean
  /** Values in it, counting a shared object each time it is reached. */
  size: number
  /** Most levels below it. */
  height: number
}

/** The guides an object is walked by (on the stack, or done): a list, nearly always of one. */
interface Open {
  readonly guide: Guide
  readonly next: Open | undefined
}
interface Done extends Open {
  readonly size: number
  readonly height: number
  readonly next: Done | undefined
}

const hasGuide = (list: Open | undefined, guide: Guide): boolean => {
  for (let at = list; at !== undefined; at = at.next) if (at.guide === guide) return true
  return false
}

const doneBy = (list: Done | undefined, guide: Guide): Done | undefined => {
  for (let at = list; at !== undefined; at = at.next) if (at.guide === guide) return at
  return undefined
}

/**
 * Check a value before Effect's encoder walks it with `ast` (the schema's
 * type side; spec §9.8). Effect's encoder has no budget: it visits an object
 * shared many times (a DAG) each time it is reached, so 30 levels of
 * `{ a: x, b: x }` cost 2^30 visits there, and it recurses into a cycle until
 * the stack overflows. This walk follows the schema as Effect's encoder does
 * (struct fields and index signatures, tuple and array elements, union
 * members by tag, recursion, the contents of classes, Options, Redacteds,
 * Maps, Sets, Chunks), visits each object once per schema node, remembering
 * how many values it holds and how deep it nests, and fails like `h.*` when
 * encoding:
 * - `step-budget` beyond `maxSteps` values (16 Mi by default), counting a
 *   shared object each time it is reached, as Effect's encoder visits them;
 * - `cyclic-value` for an object that contains itself along the schema;
 * - `nesting-too-deep` beyond `hostLevelsOf(maxDepth)` levels of objects.
 * Its work is bounded by the budget, and by the objects in the value: far
 * less for a DAG. Properties outside the schema aren't walked, so a
 * back-reference there (an entity's `parent`) is no error.
 *
 * Where the schema doesn't say how Effect reaches into a value, the walk
 * goes through everything reachable (own enumerable properties, Map and Set
 * entries, a Redacted's value, a haus value's parts): below `Unknown`, `Any`
 * and `object`, which the haus converter walks just as fully, and in
 * declarations it doesn't know (Exit, Cause, a user's `Schema.declare`). The
 * output of a transformation is made by its code while Effect encodes, so it
 * can't be checked here; the haus converter after Effect's encoder holds it
 * to the limits. Inside a Redacted, errors name the secret's place only
 * (spec §15).
 */
export const checkEncodable = (js: unknown, ast: AST, limits: h.Limits): void => {
  if (typeof js !== "object" || js === null || isOpaque(js)) return
  const maxSteps = limits.maxSteps ?? DEFAULT_ENCODE_STEPS
  const maxDepth = depthOf(limits)
  const maxLevels = hostLevelsOf(maxDepth)
  const done = new Map<object, Done>()
  const open = new Map<object, Open>()
  const stack: Frame[] = []
  let work = 0

  /** The place of the top object's `key`, stopping at a secret. */
  const path = (key: Key | undefined): ReadonlyArray<Key> => {
    const out: Key[] = []
    for (const frame of stack) {
      if (frame.key !== undefined) out.push(frame.key)
      if (isSecret(frame.node)) return out
    }
    if (key !== undefined) out.push(key)
    return out
  }
  const fail = (message: string, code: ErrorCode, key?: Key): never => {
    throw new ConversionError(message, code, path(key))
  }
  const tooLarge = (key?: Key) =>
    fail(`encode budget of ${maxSteps} steps exceeded: the value holds more values, counting an object shared in it each time it is reached`, "step-budget", key)
  const tooDeep = (key?: Key) => fail(`value nested deeper than ${maxLevels} levels of objects (twice maxDepth ${maxDepth}, plus 16)`, "nesting-too-deep", key)

  const push = (node: object, guide: Guide, key: Key | undefined, depth: number) => {
    if (depth > maxLevels) tooDeep(key)
    let edges: ReadonlyArray<Edge> | undefined
    let keys: ReadonlyArray<string> | undefined
    let props: ReadonlyArray<SchemaAST.PropertySignature> | undefined
    let count = 0
    if (guide === GENERIC) {
      if (Array.isArray(node)) count = node.length
      else if ((edges = genericEdges(node)) !== undefined) count = edges.length
      else count = (keys = Object.keys(node)).length
    } else if (guide._tag === "Arrays") count = Array.isArray(node) ? node.length : 0
    else if (guide._tag === "Objects") {
      props = guide.propertySignatures
      if (guide.indexSignatures.length > 0) {
        const declared = new Set<PropertyKey>(props.map((p) => p.name))
        edges = Object.keys(node).flatMap((k) =>
          declared.has(k) ? [] : guide.indexSignatures.map((is): Edge => ({ value: (node as Record<string, unknown>)[k], key: k, ast: is.type })))
      }
      count = props.length + (edges?.length ?? 0)
    } else count = (edges = declarationEdges(guide, node)).length
    if ((work += count + 1) > maxSteps) tooLarge(key)
    stack.push({ node, guide, key, depth, keys, props, edges, count, next: 0, pending: undefined, holdsObjects: false, size: 1, height: 0 })
  }

  // The root, below a frame of its own that counts nothing: a union may walk it more than once.
  stack.push({
    node: {}, guide: GENERIC, key: undefined, depth: 0, keys: undefined, props: undefined, edges: [{ value: js, key: undefined, ast }], count: 1, next: 0,
    pending: undefined, holdsObjects: false, size: 0, height: 0,
  })

  while (stack.length > 0) {
    const top = stack[stack.length - 1]!
    let value: object
    let key: Key | undefined
    let flat = false
    let guide: Guide
    const pending = top.pending?.pop()
    if (pending !== undefined) ({ value, key, flat, guide } = pending)
    else {
      if (top.next === top.count) {
        stack.pop()
        // An object of primitives is walked again where it is shared: that costs no more than counting it.
        if (top.holdsObjects) {
          const below = open.get(top.node)!.next
          if (below === undefined) open.delete(top.node)
          else open.set(top.node, below)
          done.set(top.node, { guide: top.guide, size: top.size, height: top.height, next: done.get(top.node) })
        }
        const parent = stack[stack.length - 1]
        if (parent !== undefined) {
          parent.size += top.size
          parent.height = Math.max(parent.height, top.depth - parent.depth + top.height)
          if (parent.size > maxSteps) tooLarge()
        }
        continue
      }
      const i = top.next++
      const node = top.node as Record<PropertyKey, unknown>
      let child: unknown
      let at: AST | typeof GENERIC | undefined
      const nprops = top.props?.length ?? 0
      if (i < nprops) {
        const { name, type } = top.props![i]!
        child = name in node ? node[name] : undefined
        key = typeof name === "symbol" ? undefined : name
        at = type
      } else if (top.edges !== undefined) {
        const e = top.edges[i - nprops]!
        child = e.value
        key = e.key
        at = e.ast
        flat = e.flat === true
      } else if (top.keys !== undefined) {
        key = top.keys[i]!
        child = node[key]
        at = GENERIC
      } else {
        key = i
        child = node[i]
        at = top.guide === GENERIC ? GENERIC : elementAst(top.guide as SchemaAST.Arrays, i, (node as unknown as ReadonlyArray<unknown>).length)
      }
      const g = typeof child !== "object" || child === null || at === undefined || isOpaque(child) ? undefined : at === GENERIC ? GENERIC : guideOf(at, child)
      if (g === undefined) {
        // A primitive, or an object where Effect doesn't look inside (a scalar's place, an excess element).
        if (++top.size > maxSteps) tooLarge()
        continue
      }
      value = child as object
      if (isGuides(g)) {
        top.pending = g.slice(1).reverse().map((other): Pending => ({ value, key, flat, guide: other }))
        guide = g[0]!
      } else guide = g
    }
    // The objects below `top` on the stack each hold the one above: all of them are open.
    if (!top.holdsObjects) {
      top.holdsObjects = true
      open.set(top.node, { guide: top.guide, next: open.get(top.node) })
    }
    // Walked without the schema, an object on the stack (by any guide) leads back to itself.
    const guidesOpen = open.get(value)
    if (guidesOpen !== undefined && (hasGuide(guidesOpen, guide) || (guide === GENERIC && !flat))) {
      fail("cyclic value: an object contains itself", "cyclic-value", key)
    }
    const levels = flat ? 0 : levelsOf(value)
    const seen = doneBy(done.get(value), guide)
    if (seen === undefined) {
      push(value, guide, key, top.depth + levels)
      continue
    }
    if (top.depth + levels + seen.height > maxLevels) tooDeep(key)
    top.size += seen.size
    top.height = Math.max(top.height, levels + seen.height)
    if (top.size > maxSteps) tooLarge()
  }
}

/** Schema-less conversion, used where the schema gives no guidance. */
const genericNode: Converter = Match.type<Value>().pipe(
  Match.discriminatorsExhaustive("kind")({
    string: (v) => v.value,
    bytes: (v) => v.bytes,
    // Exact, as spec §3 requires without a schema: whole numbers are bigints (whatever their
    // size, so the type never depends on the data), decimals BigDecimals (keeping their scale: 19.90).
    number: (v) => (/^-?\d+$/.test(v.text) ? BigInt(v.text) : BigDecimal.fromStringUnsafe(v.text)),
    array: (v) => v.items.map(generic),
    record: (v) => Object.fromEntries(Arr.map([...v.fields], ([k, x]) => [k, generic(x)])),
    variant: (v) =>
      Arr.match(v.args, {
        onEmpty: () => ({ _tag: v.tag }),
        onNonEmpty: (args) =>
          args.length === 1 && args[0].kind === "record"
            ? { _tag: v.tag, ...(generic(args[0]) as object) }
            : { _tag: v.tag, values: args.map(generic) },
      }),
  }),
)

/** Schema-less conversion, used where the schema gives no guidance. */
export const generic: Converter = (v) => {
  enter()
  try {
    return genericNode(v)
  } finally {
    leave()
  }
}

// ── AST helpers ──────────────────────────────────────────────

export const resolve = (ast: AST): AST => (ast._tag === "Suspend" ? resolve(ast.thunk()) : ast)

export const declarationId = (ast: SchemaAST.Declaration): Option.Option<unknown> =>
  Option.fromNullishOr((ast.annotations?.["representation"] as { readonly id?: unknown } | undefined)?.id)

/** Whether `ast` is a `Schema.Redacted`. */
export const isRedacted = (ast: AST): boolean => ast._tag === "Declaration" && Option.contains(declarationId(ast), "effect/schema/Redacted")

/** What a secret's errors say instead of anything about its value (spec §15): its type. */
export const secretMessage = (ast: AST): string => {
  const type = ast.annotations?.[SECRET]
  return `expected ${typeof type === "string" ? type : "a valid value"} (a Secret: the value is not shown)`
}

/** The `_tag` literal of a tagged-struct AST. */
export const tagOf = (ast: AST): Option.Option<string> => {
  const a = resolve(ast)
  return a._tag === "Objects"
    ? Arr.findFirst(a.propertySignatures, (p) => p.name === "_tag").pipe(
      Option.flatMap(({ type }) =>
        type._tag === "Literal" && Predicate.isString(type.literal) ? Option.some(type.literal) : Option.none()),
    )
    : Option.none()
}

/**
 * Set an own property. Plain `out[key] = …` with key "__proto__" would
 * replace the object's prototype, letting data inject fields it doesn't
 * contain (`{ "__proto__": { role: "admin" } }` → `out.role === "admin"`).
 */
const setOwn = (out: Record<string, unknown>, key: string, value: unknown) => {
  Object.defineProperty(out, key, { value, enumerable: true, writable: true, configurable: true })
}

// ── compilation ──────────────────────────────────────────────

const cache = new WeakMap<AST, Converter>()

/** Compile an encoded-side AST into a converter (memoised; handles recursive schemas). */
export const compile = (ast: AST): Converter => {
  const cached = cache.get(ast)
  if (cached) return cached
  let compiled: Converter | undefined
  const lazy: Converter = (v) => {
    enter()
    try {
      return (compiled ??= compileNode(resolve(ast)))(v)
    } finally {
      leave()
    }
  }
  cache.set(ast, lazy)
  return lazy
}

/** `Haus.Any`: the parsed value as it is. */
const asValue: Converter = (v) => v

const compileNode = (ast: AST): Converter => (ast.annotations?.[VALUE] === true ? asValue : compileByTag(ast))

const compileByTag: (ast: AST) => Converter = Match.type<AST>().pipe(
  Match.tag("String", "TemplateLiteral", compileString),
  Match.tag("Number", compileNumber),
  // Nothing but a number can be a bigint: anything else fails here, in the order of the value,
  // rather than after the conversion, behind errors further on (spec §15: the first error).
  Match.tag("BigInt", (): Converter => (v) => (v.kind === "number" && INTEGER.test(v.text) ? BigInt(v.text) : notInteger(v))),
  Match.tag("Boolean", (): Converter => (v) =>
    Option.isSome(variant(v, "True", 0)) ? true : Option.isSome(variant(v, "False", 0)) ? false : notCase("True or False", v, BOOL_TAGS)),
  // A literal takes exactly the value it is written as: `EUR` for "EUR", `"a b"` for "a b".
  Match.tag("Literal", (ast): Converter => {
    const written = literalValue(ast.literal)
    return (v) => (equals(v, written) ? ast.literal
      : written.kind === "variant" ? notCase(describe(written), v, [written.tag])
      : mismatch(describe(written), v))
  }),
  Match.tag("Enum", (): Converter => (v) =>
    Option.match(variant(v, undefined, 0), { onSome: (x) => x.tag, onNone: () => generic(v) })),
  Match.tag("Arrays", (ast): Converter => {
    const elements = ast.elements.map(compile)
    const rest = Arr.head(ast.rest).pipe(Option.map(compile), Option.getOrElse(() => generic))
    return (v) => (v.kind === "array" ? v.items.map((item, i) => at(i, () => (elements[i] ?? rest)(item))) : generic(v))
  }),
  Match.tag("Objects", compileObject),
  Match.tag("Union", compileUnion),
  Match.tag("Declaration", compileDeclaration),
  Match.orElse((): Converter => generic),
)

function compileString(ast: SchemaAST.String | SchemaAST.TemplateLiteral): Converter {
  const tag = ast.annotations?.[PRELUDE_TAG]
  // `Haus.Date` & co.: the type's own tag around a string, `Date("…")`.
  if (typeof tag === "string") return (v) => Option.getOrElse(scalarString(v, tag), () => mismatch(`${tag}("…")`, v))
  // `< >` (only ever a member of a union, which hands it bare tags).
  if (ast.annotations?.[BARE_TAG] === true) return (v) => (v.kind === "variant" && v.args.length === 0 ? v.tag : mismatch("a tag", v))
  if (ast.annotations?.[STRICT] === true) return (v) => (v.kind === "string" ? v.value : mismatch("a string", v))
  // `Decimal`: the literal exactly as parsed (normalized, spec §2), scale, exponent and `-0` included.
  if (ast.annotations?.[DECIMAL] === true) return (v) => (v.kind === "number" ? v.text : mismatch("a number (Decimal)", v))
  return (v) =>
    v.kind === "string" ? v.value
    : v.kind === "number" ? v.text // exact, for BigDecimalFromString, NumberFromString, …
    : Option.getOrElse(scalarString(v), () => generic(v))
}

/** The haus number type of a number schema (Float64 unless annotated). */
const numberType = (ast: AST): NumberType => {
  const t = ast.annotations?.[NUMBER]
  return t === "Int" || t === "Float32" ? t : "Float64"
}

/** Spec §15: Int* take whole numbers only (`-0` is 0); floats round to the nearest value, and a number too large is an error. */
function compileNumber(ast: SchemaAST.Number): Converter {
  const type = numberType(ast)
  if (type === "Int") return (v) => (v.kind === "number" && INTEGER.test(v.text) ? Number(v.text) + 0 : notInteger(v))
  return (v) =>
    v.kind === "number" ? (toFloat(v.text, type) ?? fail(`${describe(v)} is too large for ${type}`, "out-of-range"))
    : (specialFloat(v) ?? mismatch(`a number (${type})`, v))
}

const fail = (message: string, code: ErrorCode): never => {
  throw new ConversionError(message, code)
}

/**
 * A case with a record payload given something else (spec §15): no argument,
 * several, or one that isn't a record (`Circle(1.5)`) is the wrong payload,
 * at the variant.
 */
const notRecord = (v: HVariant, message: string): never => {
  throw new ConversionError(message, "wrong-payload", [], payloadHint(v.tag, { kind: "record" }))
}

function compileObject(ast: SchemaAST.Objects): Converter {
  const tag = tagOf(ast)
  // An optionalKey is a haus optional field (`name?: T`): missing stays missing.
  // Option is a haus Maybe: always written as None / Some(…). The two are never
  // converted into each other.
  const props = new Map(ast.propertySignatures.map((p) => [String(p.name), { convert: compile(p.type) }] as const))
  const positional = ast.propertySignatures.filter((p) => p.name !== "_tag").map((p) => String(p.name))
  const allowPositional = ast.annotations?.[POSITIONAL] === true
  const values = ast.annotations?.[VALUES] === true
  const nested = ast.annotations?.[NESTED] === true
  const closed = ast.annotations?.[CLOSED] === true
  // `Map v`: a record with an index signature converts every field with its value schema.
  const rest = Arr.head(ast.indexSignatures).pipe(Option.map((i) => compile(i.type)), Option.getOrElse(() => generic))
  // The number of arguments of `{ _tag, values }`: the length of its tuple.
  const arity = Arr.findFirst(ast.propertySignatures, (p) => p.name === "values").pipe(
    Option.map((p) => resolve(p.type)),
    Option.flatMap((t) => (t._tag === "Arrays" && t.rest.length === 0 ? Option.some(t.elements.length) : Option.none())),
    Option.getOrUndefined,
  )

  /**
   * Fields of the value: a record for a struct; for a tagged struct, the
   * payload its variant takes (spec §15): none without fields, else one record.
   */
  const fieldsOf = (v: Value): ReadonlyArray<readonly [string, Value]> => {
    if (Option.isNone(tag)) return v.kind === "record" ? [...v.fields] : mismatch("a record", v)
    const name = tag.value
    if (v.kind !== "variant" || v.tag !== name) return mismatch(`the variant ${name}`, v, v.kind === "variant" ? "unknown-tag" : "type-mismatch")
    // Point(1, 2) → { values: [1, 2] }, with as many arguments as the case lists (spec §15).
    if (values) return arity === undefined || v.args.length === arity ? [["values", vArr(v.args)]] : wrongPayload(`${name} with ${arity} argument(s)`, v, { kind: "args", count: arity })
    const [first] = v.args
    const record = `${name} { ${positional.map((n) => `${n}: …`).join(", ")} }`
    if (nested) return v.args.length === 1 && first?.kind === "record" ? [["value", first]] : notRecord(v, `expected ${name} { … }, got ${describe(v)}`) // Odd { _tag: 1 } → { value: { _tag: 1 } }
    if (positional.length === 0) return v.args.length === 0 ? [] : wrongPayload(`${name} without a payload`, v, { kind: "none" }) // Heartbeat
    if (v.args.length === 1 && first?.kind === "record") return [...first.fields] // Circle { radius: 5 }
    if (v.args.length === 0) return wrongPayload(record, v, { kind: "record" })
    // Point(1, 2) fills fields in declaration order, but only when the schema
    // opts in: otherwise reordering fields would silently swap values.
    if (!allowPositional) return notRecord(v, `'${name}' has positional arguments; write ${record} or wrap its schema in Haus.Positional`)
    return v.args.map((arg, i) => [positional[i] ?? `#${i}`, arg] as const)
  }

  return (v) => {
    const out: Record<string, unknown> = Option.match(tag, { onNone: () => ({}), onSome: (t) => ({ _tag: t }) })
    for (const [key, field] of fieldsOf(v)) {
      // A payload field `_tag` that the case doesn't list (its own `_tag` is the tag): an unlisted
      // field like any other, ignored by an open record. A plain record's or a map's `_tag` is data.
      if (key === "_tag" && Option.isSome(tag)) {
        if (closed) throw new ConversionError(`unexpected field "_tag" in a closed record`, "unknown-field", [key])
        continue
      }
      const prop = props.get(key)
      if (prop !== undefined) setOwn(out, key, at(key, () => prop.convert(field)))
      else if (closed) throw new ConversionError(`unexpected field "${quoteText(key)}" in a closed record`, "unknown-field", [key])
      else setOwn(out, key, at(key, () => rest(field))) // excess property: ignored by the decoder (records are open), or a Map entry
    }
    return out
  }
}

/** Members of nested unions, flattened: Union([Literals([…]), Unknown]). */
export const members = (ast: SchemaAST.Union): ReadonlyArray<AST> =>
  ast.types.flatMap((m) => {
    const r = resolve(m)
    return r._tag === "Union" ? members(r) : [r]
  })

function compileUnion(ast: SchemaAST.Union): Converter {
  const types = members(ast)
  // Variants are routed by tag: tagged-struct members and literals written as tags (`EUR`, `True`).
  const byTag = new Map<string, Converter>()
  // Literals written as other values (`"a b"`, `1`), with that value.
  const literals: Array<readonly [Value, unknown]> = []
  for (const m of types) {
    Option.match(tagOf(m), {
      onSome: (t) => byTag.set(t, compile(m)),
      onNone: () => {
        if (m._tag !== "Literal") return
        const written = literalValue(m.literal)
        if (written.kind === "variant") byTag.set(written.tag, compile(m))
        else literals.push([written, m.literal])
      },
    })
  }
  const open = byTag.has(UNKNOWN_TAG)
  // `< >`: any bare tag, as its name.
  const anyTag = types.find((m) => m._tag === "String" && m.annotations?.[BARE_TAG] === true)
  // Other members (Option, Boolean, string-encoded scalars, …), by value kind.
  const others = types.filter((m) => Option.isNone(tagOf(m)) && m._tag !== "Literal" && m !== anyTag)
  const forKind = (kinds: ReadonlyArray<AST["_tag"]>) =>
    Arr.findFirst(others, (m) => kinds.includes(resolve(m)._tag)).pipe(Option.map(compile))
  const byKind = {
    string: forKind(["String", "TemplateLiteral"]),
    number: forKind(["Number", "BigInt", "Declaration", "String"]),
    bytes: forKind(["Declaration"]),
    array: forKind(["Arrays"]),
    record: forKind(["Objects"]),
    variant: Arr.head(others).pipe(Option.map(compile)),
  }
  // A value no member takes: Effect's Any / Unknown take anything, otherwise it is an error.
  const tags = [...byTag.keys()].filter((t) => t !== UNKNOWN_TAG)
  // No members: a closed variant whose spreads copy no tag (`closed < ...E >`, E empty) takes no value.
  const none = types.length === 0
  const expected = [
    ...(open || anyTag || none ? ["a variant"] : tags.length > 0 ? [`one of the tags ${tags.join(", ")}`] : []),
    ...literals.map(([written]) => describe(written)),
    ...others.map((m) => `a value of ${resolve(m)._tag}`),
  ].join(" or ")
  const otherwise: Converter = others.some((m) => m.annotations?.[VALUE] === true) ? asValue
    : others.some((m) => m._tag === "Any" || m._tag === "Unknown") ? generic
    : (v) => mismatch(expected, v)
  return (v) => {
    if (v.kind === "variant") {
      const exact = byTag.get(v.tag)
      if (exact) return exact(v)
      if (anyTag && v.args.length === 0) return v.tag
      if (Option.isSome(byKind.variant)) return byKind.variant.value(v)
      if (open) return { _tag: UNKNOWN_TAG, tag: v.tag, value: v }
      // Closed: no member takes this tag.
      return mismatch(none ? "no tag (a closed variant with no tags)" : expected, v, tags.length > 0 || none ? "unknown-tag" : "type-mismatch")
    }
    for (const [written, literal] of literals) if (equals(v, written)) return literal
    return Option.match(byKind[v.kind], { onSome: (convert) => convert(v), onNone: () => otherwise(v) })
  }
}

/** A std/time string that follows the profile (spec/std/time.md); anything else is an error, whatever the host type accepts. */
const stdTime = (type: StdTimeType, s: string): string => {
  const reason = checkStdTime(type, s)
  // The place of an invalid-time error is the tag's argument (spec §17), added where the error is reported.
  if (reason !== undefined) throw new ConversionError(reason, "invalid-time")
  return s
}

function compileDeclaration(ast: SchemaAST.Declaration): Converter {
  const id = Option.getOrUndefined(declarationId(ast))
  switch (id) {
    case "effect/schema/Uint8Array":
      return (v) => (v.kind === "bytes" ? v.bytes : generic(v))
    case "effect/schema/BigDecimal":
      // Exact: never goes through a JS number.
      return (v) => (v.kind === "number" && !/[xb]/.test(v.text) ? BigDecimal.fromStringUnsafe(v.text) : generic(v))
    case "effect/schema/DateTimeUtc":
      return (v) =>
        Option.match(scalarString(v, "Instant"), {
          onNone: () => generic(v),
          onSome: (s) => Option.getOrElse(DateTime.make(stdTime("Instant", s)), () => s),
        })
    case "effect/schema/DateTimeZoned":
      return (v) =>
        Option.match(scalarString(v, "ZonedDateTime"), {
          onNone: () => generic(v),
          onSome: (s) => Option.getOrElse(DateTime.makeZonedFromString(stdTime("ZonedDateTime", s)), () => s),
        })
    case "effect/schema/Option": {
      const inner = Arr.head(ast.typeParameters).pipe(Option.map(compile), Option.getOrElse(() => generic))
      // The value inside is at "value", as in Effect's issues.
      return (v) =>
        Option.isSome(variant(v, "None", 0)) ? Option.none()
        : Option.match(variant(v, "Some", 1), {
          onSome: (s) => Option.some(at("value", () => inner(s.args[0]!))),
          onNone: () => notCase("None or Some(…)", v, MAYBE_TAGS, (tag) => (tag === "Some" ? { kind: "args", count: 1 } : { kind: "none" })),
        })
    }
    case "effect/schema/Redacted": {
      // `Secret a`: the value converted as `a`, in a Redacted. An error inside
      // is replaced by one at the secret's place that doesn't show the value.
      const inner = Arr.head(ast.typeParameters).pipe(Option.map(compile), Option.getOrElse(() => generic))
      const message = secretMessage(ast)
      return (v) => {
        try {
          return Redacted.make(inner(v))
        } catch (e) {
          if (e instanceof ConversionError) throw new ConversionError(message, "invalid-secret")
          throw e
        }
      }
    }
    default:
      return generic
  }
}

// ── encoding: JS (Effect's encoded form) → haus Value ────────
// Built with the core's constructors, which build only haus values (spec
// §11): what isn't one (a string with an unpaired surrogate, a schema's tag
// such as `lower`, a number that isn't finite) is their HausEncodeError, with
// its code, which `encodeValue` (index.ts) reports as a HausSchemaError.

export type Encoder = (js: unknown) => Value

const TAG_NAME = /^[A-Z][A-Za-z0-9_]*$/

/** A float in its one spelling (spec §15); a Float32 as the nearest binary32 value. */
const floatValue = (n: number, type: FloatType = "Float64"): Value => coreFloatValue(n, type) ?? fail(`${n} is too large for ${type}`, "cannot-encode")

const numberValue = (n: number): Value => floatValue(n)

/** A number schema's writer: integers as decimal integers (`-0` as 0), floats in their one spelling. */
const numberWriter = (type: NumberType) => (n: number): Value => (type === "Int" ? vNum(String(n + 0)) : floatValue(n, type))

/** A literal: tag-like strings become tags (`"EUR"` → `EUR`), others stay strings. */
const literalValue = (js: unknown): Value =>
  typeof js === "string" ? (TAG_NAME.test(js) ? vVariant(js) : vStr(js))
  : typeof js === "number" ? numberValue(js)
  : typeof js === "boolean" ? vVariant(js ? "True" : "False")
  : encodeGeneric(js)

/**
 * Exact text of a BigDecimal, keeping its scale (7.90 stays "7.90"). A
 * negative scale, or a long run of leading zeros, is written with an exponent
 * and one digit before the point, as `1.5e3` decodes (value 15, scale -2):
 * not as `1500`, a different haus value (§2), and within the number limit.
 */
export const decimalText = ({ value, scale }: BigDecimal.BigDecimal): string => {
  const sign = value < 0n ? "-" : ""
  const digits = (value < 0n ? -value : value).toString()
  if (scale === 0) return sign + digits
  if (scale < 0 || scale - digits.length > 6) {
    const exponent = digits.length - 1 - scale
    return `${sign}${digits[0]}${digits.length > 1 ? `.${digits.slice(1)}` : ""}e${exponent}`
  }
  const padded = digits.padStart(scale + 1, "0")
  return `${sign}${padded.slice(0, -scale)}.${padded.slice(-scale)}`
}

/** A decimal's text as a number value: a number literal within the limits (spec §9.8), normalized as the parser would. */
const decimalValue = (text: string): Value => {
  try {
    return h.encode(h.Decimal, text, guard.limits)
  } catch (e) {
    if (e instanceof h.HausEncodeError) throw new ConversionError(e.reason, e.code, e.path)
    throw e
  }
}

/** Schema-less conversion of plain JS data. */
export const encodeGeneric = (js: unknown): Value => {
  enter()
  try {
    return encodeGenericNode(js)
  } finally {
    leave()
  }
}

const encodeGenericNode = (js: unknown): Value => {
  if (typeof js === "string") return vStr(js)
  if (typeof js === "number") return numberValue(js)
  if (typeof js === "bigint") return vNum(js.toString())
  if (typeof js === "boolean") return vVariant(js ? "True" : "False")
  if (js instanceof Uint8Array) return vBytes(js)
  if (js === null || js === undefined) return vVariant("None")
  if (Array.isArray(js)) return vArr(js.map(encodeGeneric))
  if (Option.isOption(js)) return Option.match(js, { onNone: () => vVariant("None"), onSome: (x) => vVariant("Some", [encodeGeneric(x)]) })
  if (BigDecimal.isBigDecimal(js)) return decimalValue(decimalText(js))
  if (DateTime.isDateTime(js)) return dateTimeValue(js)
  const entries = Object.entries(js as Record<string, unknown>).filter(([, v]) => v !== undefined)
  const tag = (js as { _tag?: unknown })._tag
  if (typeof tag === "string" && TAG_NAME.test(tag)) {
    const fields = entries.filter(([k]) => k !== "_tag")
    return fields.length === 0 ? vVariant(tag) : vVariant(tag, [vRec(new Map(fields.map(([k, v]) => [k, encodeGeneric(v)])))])
  }
  return vRec(new Map(entries.map(([k, v]) => [k, encodeGeneric(v)])))
}

/** Without a zero fraction: `…T09:00:00Z`, not `…T09:00:00.000Z` (the same instant, as written). */
const noZeroFraction = (iso: string) => iso.replace(/\.000(?=Z|[+-]\d{2}:\d{2})/, "")

/**
 * An Effect DateTime as std/time text: `DateTime.Utc` as an Instant,
 * `DateTime.Zoned` as a ZonedDateTime. A zone that is an offset is written in
 * brackets too (`…+01:00[+01:00]`), as std/time requires one zone. Text that
 * std/time doesn't accept (a year beyond 9999, an offset with seconds) is an
 * error, never written.
 */
export const dateTimeText = (d: DateTime.DateTime): { readonly type: "Instant" | "ZonedDateTime"; readonly text: string } => {
  const utc = noZeroFraction(DateTime.formatIso(d))
  if (!DateTime.isZoned(d)) return { type: "Instant", text: stdTimeText("Instant", utc) }
  const zone = DateTime.zoneToString(d.zone)
  // Effect rounds an offset with seconds (local mean time before 1900) when formatting, which
  // would move the instant: such a time is written in UTC, with its zone.
  const text = DateTime.zonedOffset(d) % 60_000 !== 0 ? `${utc}[${zone}]` : `${noZeroFraction(DateTime.formatIsoOffset(d))}[${zone}]`
  return { type: "ZonedDateTime", text: stdTimeText("ZonedDateTime", text) }
}

/** `text` when std/time accepts it as `type`, else a ConversionError. */
const stdTimeText = (type: StdTimeType, text: string): string => {
  const reason = checkStdTime(type, text)
  if (reason !== undefined) throw new ConversionError(`can't write ${type}("${text}"): ${reason}`, "cannot-encode")
  return text
}

const dateTimeValue = (d: DateTime.DateTime): Value => {
  const { type, text } = dateTimeText(d)
  return vVariant(type, [vStr(text)])
}

const encCache = new WeakMap<AST, Encoder>()

/** Compile an encoded-side AST into an encoder (memoised; handles recursive schemas). */
export const compileEncoder = (ast: AST): Encoder => {
  const cached = encCache.get(ast)
  if (cached) return cached
  let compiled: Encoder | undefined
  const lazy: Encoder = (js) => {
    enter()
    try {
      return (compiled ??= encodeNode(resolve(ast)))(js)
    } finally {
      leave()
    }
  }
  encCache.set(ast, lazy)
  return lazy
}

/**
 * `Haus.Any`: the value is written back unchanged, after the checks of the
 * core's `Any`: a haus value the parser could produce, within the limits.
 */
const encodeValue: Encoder = (js) => {
  try {
    return h.encode(h.Any, js as Value, guard.limits)
  } catch (e) {
    if (e instanceof h.HausEncodeError) throw new ConversionError(e.reason, e.code, e.path)
    throw e
  }
}

const encodeNode = (ast: AST): Encoder => (ast.annotations?.[VALUE] === true ? encodeValue : encodeByTag(ast))

const encodeByTag: (ast: AST) => Encoder = Match.type<AST>().pipe(
  Match.tag("String", "TemplateLiteral", (ast): Encoder => {
    const tag = ast.annotations?.[PRELUDE_TAG]
    const bare = ast.annotations?.[BARE_TAG] === true
    if (ast.annotations?.[DECIMAL] === true) return (js) => (typeof js === "string" ? decimalValue(js) : encodeGeneric(js))
    return (js) =>
      typeof js !== "string" ? encodeGeneric(js)
      : bare && TAG_NAME.test(js) ? vVariant(js)
      : typeof tag === "string" ? vVariant(tag, [vStr(js)])
      : vStr(js)
  }),
  Match.tag("Number", (ast): Encoder => {
    const write = numberWriter(numberType(ast))
    return (js) => (typeof js === "number" ? write(js) : encodeGeneric(js))
  }),
  Match.tag("BigInt", (): Encoder => (js) => (typeof js === "bigint" ? vNum(js.toString()) : encodeGeneric(js))),
  Match.tag("Boolean", (): Encoder => (js) => (typeof js === "boolean" ? vVariant(js ? "True" : "False") : encodeGeneric(js))),
  Match.tag("Literal", "Enum", (): Encoder => literalValue),
  Match.tag("Arrays", (ast): Encoder => {
    const elements = ast.elements.map(compileEncoder)
    const rest = Arr.head(ast.rest).pipe(Option.map(compileEncoder), Option.getOrElse(() => encodeGeneric))
    return (js) => (Array.isArray(js) ? vArr(js.map((x, i) => (elements[i] ?? rest)(x))) : encodeGeneric(js))
  }),
  Match.tag("Objects", encodeObject),
  Match.tag("Union", encodeUnion),
  Match.tag("Declaration", encodeDeclaration),
  Match.orElse((): Encoder => encodeGeneric),
)

function encodeObject(ast: SchemaAST.Objects): Encoder {
  const tag = Option.getOrUndefined(tagOf(ast))
  const positional = ast.annotations?.[POSITIONAL] === true
  const values = ast.annotations?.[VALUES] === true
  const nested = ast.annotations?.[NESTED] === true
  // A tagged struct's `_tag` is its tag; a plain struct's `_tag` is a field like any other.
  const isField = (key: string) => tag === undefined || key !== "_tag"
  const props = ast.propertySignatures
    .filter((p) => isField(String(p.name)))
    .map((p) => ({ name: String(p.name), encode: compileEncoder(p.type) }))
  const declared = new Set(props.map((p) => p.name))
  const rest = Arr.head(ast.indexSignatures).pipe(Option.map((i) => compileEncoder(i.type)))
  return (js) => {
    if (typeof js !== "object" || js === null) return encodeGeneric(js)
    const obj = js as Record<string, unknown>
    // The raw value of an unknown variant is written back as it was received,
    // after the same checks as an `Any` (spec §9.8).
    if (tag === UNKNOWN_TAG) return encodeValue(obj["value"])
    if (values && tag !== undefined) {
      const items = props.find((p) => p.name === "values")?.encode(obj["values"])
      return vVariant(tag, items?.kind === "array" ? items.items : [])
    }
    if (nested && tag !== undefined) {
      const payload = props.find((p) => p.name === "value")?.encode(obj["value"])
      return payload?.kind === "record" ? vVariant(tag, [payload]) : fail(`'${tag}' takes a record payload, its value`, "cannot-encode")
    }
    const present: { name: string; encode: Encoder }[] = props.filter((p) => Object.hasOwn(obj, p.name) && obj[p.name] !== undefined)
    if (Option.isSome(rest)) {
      for (const key of Object.keys(obj)) {
        if (!declared.has(key) && isField(key) && obj[key] !== undefined) present.push({ name: key, encode: rest.value })
      }
    }
    if (tag === undefined) return vRec(new Map(present.map((p) => [p.name, p.encode(obj[p.name])])))
    // A tag without fields takes no payload; one with fields always a record, `Tag {}` included (spec §15).
    if (props.length === 0 && Option.isNone(rest)) return vVariant(tag)
    if (positional) return vVariant(tag, present.map((p) => p.encode(obj[p.name])))
    return vVariant(tag, [vRec(new Map(present.map((p) => [p.name, p.encode(obj[p.name])])))])
  }
}

function encodeUnion(ast: SchemaAST.Union): Encoder {
  const types = members(ast)
  const byTag = new Map<string, Encoder>()
  for (const m of types) Option.match(tagOf(m), { onSome: (t) => byTag.set(t, compileEncoder(m)), onNone: () => undefined })
  const literals = types.filter((m): m is SchemaAST.Literal => m._tag === "Literal")
  const fits = (js: unknown, m: AST): boolean => {
    switch (m._tag) {
      case "String":
      case "TemplateLiteral":
        return typeof js === "string"
      case "Number":
        return typeof js === "number"
      case "BigInt":
        return typeof js === "bigint"
      case "Boolean":
        return typeof js === "boolean"
      case "Arrays":
        return Array.isArray(js)
      case "Objects":
        return typeof js === "object" && js !== null && !Array.isArray(js) && Option.isNone(tagOf(m))
      case "Declaration": {
        const id = Option.getOrUndefined(declarationId(m))
        return id === "effect/schema/Option" ? Option.isOption(js)
          : id === "effect/schema/BigDecimal" ? BigDecimal.isBigDecimal(js)
          : id === "effect/schema/DateTimeUtc" || id === "effect/schema/DateTimeZoned" ? DateTime.isDateTime(js)
          : id === "effect/schema/Redacted" ? Redacted.isRedacted(js)
          : false
      }
      default:
        return false
    }
  }
  return (js) => {
    const tag = typeof js === "object" && js !== null ? (js as { _tag?: unknown })._tag : undefined
    if (typeof tag === "string") {
      const byTagEncoder = byTag.get(tag)
      if (byTagEncoder) return byTagEncoder(js)
    }
    if (literals.some((l) => l.literal === js)) return literalValue(js)
    const member = types.find((m) => fits(js, m))
    return member ? compileEncoder(member)(js) : encodeGeneric(js)
  }
}

function encodeDeclaration(ast: SchemaAST.Declaration): Encoder {
  switch (Option.getOrUndefined(declarationId(ast))) {
    case "effect/schema/BigDecimal":
      return (js) => (BigDecimal.isBigDecimal(js) ? decimalValue(decimalText(js)) : encodeGeneric(js))
    case "effect/schema/DateTimeUtc":
    case "effect/schema/DateTimeZoned":
      return (js) => (DateTime.isDateTime(js) ? dateTimeValue(js) : encodeGeneric(js))
    case "effect/schema/Option": {
      const inner = Arr.head(ast.typeParameters).pipe(Option.map(compileEncoder), Option.getOrElse(() => encodeGeneric))
      return (js) =>
        Option.isOption(js) ? Option.match(js, { onNone: () => vVariant("None"), onSome: (x) => vVariant("Some", [inner(x)]) }) : encodeGeneric(js)
    }
    case "effect/schema/Redacted": {
      // Written in full (the receiver needs it), but never shown in an error.
      const inner = Arr.head(ast.typeParameters).pipe(Option.map(compileEncoder), Option.getOrElse(() => encodeGeneric))
      const message = secretMessage(ast)
      return (js) => {
        if (!Redacted.isRedacted(js)) throw new ConversionError("expected a Redacted (Redacted.make(…))", "cannot-encode")
        try {
          return inner(Redacted.value(js))
        } catch (e) {
          if (e instanceof ConversionError) throw new ConversionError(message, "invalid-secret")
          throw e
        }
      }
    }
    default:
      return encodeGeneric
  }
}

// ── schema checks ────────────────────────────────────────────

/** What a union member looks like in haus, for members that contain further values. */
const containerKind = (m: AST): string | undefined => {
  const tag = Option.getOrUndefined(tagOf(m))
  if (tag !== undefined) return `variant ${tag}`
  if (m._tag === "Objects") return "record"
  if (m._tag === "Arrays") return "array"
  if (m._tag === "Declaration" && m.typeParameters.length > 0) return `declaration ${String(Option.getOrUndefined(declarationId(m)))}`
  return undefined
}

/**
 * Reject recursive schemas with ambiguous unions. Effect decodes a union by
 * trying its members in turn; when two members can both start matching the
 * same nested value (two untagged structs, two array types), a recursive
 * schema makes that exponential in the nesting depth: a small hostile input
 * can keep a server busy for hours. Members told apart by a `_tag` are fine.
 */
export const checkSchema = (root: AST): void => {
  const seen = new Set<AST>()
  let recursive = false
  const ambiguous = new Set<string>()
  const visit = (ast: AST): void => {
    if (seen.has(ast)) return
    seen.add(ast)
    switch (ast._tag) {
      case "Suspend":
        recursive = true
        return visit(ast.thunk())
      case "Objects":
        ast.propertySignatures.forEach((p) => visit(p.type))
        ast.indexSignatures.forEach((i) => visit(i.type))
        return
      case "Arrays":
        ast.elements.forEach(visit)
        ast.rest.forEach(visit)
        return
      case "Declaration":
        ast.typeParameters.forEach(visit)
        return
      case "Union": {
        const kinds = new Map<string, number>()
        for (const m of members(ast)) {
          const kind = containerKind(m)
          if (kind !== undefined) kinds.set(kind, (kinds.get(kind) ?? 0) + 1)
        }
        for (const [kind, n] of kinds) if (n > 1) ambiguous.add(`${n} members of kind ${kind}`)
        ast.types.forEach(visit)
        return
      }
      default:
        return
    }
  }
  visit(root)
  if (recursive && ambiguous.size > 0) {
    throw new Error(
      `Haus: a recursive schema contains a union whose members can't be told apart (${[...ambiguous].join("; ")}). ` +
        "Decoding it takes exponential time on nested input. Give the members a _tag (Schema.TaggedStruct).",
    )
  }
}
