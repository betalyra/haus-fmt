/**
 * The plain JSON mapping (spec §16.3): the values of a schema type as the
 * JSON a JSON consumer expects. A `JsonType` describes the type's JSON form;
 * the conversion maps haus values (as a schema encodes them) to JSON and
 * back, and the schema itself checks the rest (ranges, std/time, …).
 *
 *   String, std/time → "…"          Bytes → "CzQ=" (base64)        Bool → true / false
 *   Int8 … UInt32 → 12               Int, Int64, UInt64 → "12"       Float32/64 → 0.1, "NaN", "Infinity", "-Infinity"
 *   Decimal → "19.90"                Any → its lossless form         Secret a → as a
 *   Array a → […]                    Map v, records → {…}            Maybe a → null / x, or tagged when a's JSON can be null
 *   closed < Debug | Info > → "Debug"                                 other variants → {"_tag": "Circle", "r": 1.5}, "value", "values"
 *   an unknown value → {"_tag": "Hexagon", "args": [lossless…]}
 */
import { HausDecodeError, HausEncodeError } from "./errors.js"
import {
  describeJson, fromLossless, isJsonNumber, jsonDepth, isJsonObject, jsonObject, JsonNumber, losslessJson, numberOfJson, Place, stringOfJson, valueOfJson, type Json,
  type JsonObject, normalizeJsonNumber,
} from "./json.js"
import { numberLimitIssue } from "./number.js"
import { longerThan, withDefaults, type Limits } from "./parser.js"
import { arr, bytes as bytesValue, num, rec, variant, type HVariant, type Value } from "./value.js"

// ── JSON types ───────────────────────────────────────────────

/**
 * The plain JSON form of a schema type (spec §16.3). Schemas carry one
 * (`h.String.json`, …); adapters build them for their own schemas.
 */
export type JsonType =
  | { readonly kind: "string" }
  | { readonly kind: "bytes" }
  | { readonly kind: "bool" }
  /** Int8 … UInt32 as JSON numbers; `quoted` (Int, Int64, UInt64) as strings. */
  | { readonly kind: "integer"; readonly quoted: boolean }
  | { readonly kind: "float" }
  | { readonly kind: "decimal" }
  /** A std/time type: `Date("2026-11-13")` ↔ `"2026-11-13"`. */
  | { readonly kind: "time"; readonly tag: string }
  | { readonly kind: "any" }
  /** `Secret a`: as `a`; errors inside name `expected` only, never the value. */
  | { readonly kind: "secret"; readonly item: JsonType; readonly expected: string }
  | { readonly kind: "array"; readonly item: JsonType }
  /** A fixed-length array (Effect tuples), with an optional rest. */
  | { readonly kind: "tuple"; readonly items: readonly JsonType[]; readonly rest?: JsonType | undefined }
  | { readonly kind: "map"; readonly value: JsonType }
  | JsonRecordType
  | { readonly kind: "maybe"; readonly item: JsonType }
  | JsonVariantType
  /** A recursive type's back edge. `get` must return the same object every time. */
  | { readonly kind: "lazy"; readonly get: () => JsonType }
  /** A type without a plain form (a hand-written schema that declares none). */
  | { readonly kind: "none"; readonly expected: string }

export interface JsonRecordType {
  readonly kind: "record"
  /** The listed fields. Optional fields need nothing more: a missing member stays missing. */
  readonly fields: ReadonlyMap<string, JsonType>
  readonly closed: boolean
}

export interface JsonVariantType {
  readonly kind: "variant"
  readonly cases: ReadonlyMap<string, JsonCase>
  readonly open: boolean
}

/** A variant case: no payload, a record payload (its fields beside `_tag`), or positional arguments. */
export type JsonCase =
  | { readonly kind: "unit" }
  | { readonly kind: "record"; readonly record: JsonRecordType }
  | { readonly kind: "positional"; readonly items: readonly JsonType[] }

/** Whether a case takes no payload (a positional case with no items takes none either). */
const isUnitCase = (c: JsonCase) => c.kind === "unit" || (c.kind === "positional" && c.items.length === 0)

const enums = new WeakMap<JsonVariantType, boolean>()

/** A closed variant whose tags have no payload: written as a string (spec §16.3). Bool has its own kind. */
const isEnum = (t: JsonVariantType): boolean => {
  let known = enums.get(t)
  if (known === undefined) enums.set(t, (known = !t.open && t.cases.size > 0 && [...t.cases.values()].every(isUnitCase)))
  return known
}

// ── which Maybes use null ────────────────────────────────────

const nullable = new WeakMap<JsonType, boolean>()

type Link = Extract<JsonType, { readonly kind: "maybe" | "secret" | "lazy" }>
const isLink = (t: JsonType): t is Link => t.kind === "maybe" || t.kind === "secret" || t.kind === "lazy"
const next = (t: Link): JsonType => (t.kind === "lazy" ? t.get() : t.item)

/**
 * Whether a type's JSON can be `null` (spec §16.3): only a Maybe that uses
 * `null`, directly or through named types and Secret. A Maybe uses `null`
 * when its item's JSON can't be `null`.
 *
 * Each step follows one link (Maybe → item, Secret → item, a back edge →
 * its type), so the links from a type form a chain that ends in another
 * type or runs into a cycle. A cycle made only of such links (`type L =
 * Maybe L`) has no consistent answer: there every Maybe is tagged, the form
 * that can never be confused, whatever type the question started from.
 */
export const canBeNull = (t: JsonType): boolean => {
  if (!isLink(t)) return false
  const known = nullable.get(t)
  if (known !== undefined) return known
  const chain: Link[] = []
  const index = new Map<JsonType, number>()
  let end = false
  for (let cur: JsonType = t; ;) {
    if (!isLink(cur)) break
    const k = nullable.get(cur)
    if (k !== undefined) {
      end = k
      break
    }
    const i = index.get(cur)
    if (i !== undefined || chain.length > 100_000) {
      for (const x of chain.splice(i ?? 0)) nullable.set(x, false)
      break
    }
    index.set(cur, chain.length)
    chain.push(cur)
    cur = next(cur)
  }
  for (let i = chain.length - 1; i >= 0; i--) {
    const x = chain[i]!
    if (x.kind === "maybe") end = !end
    nullable.set(x, end)
  }
  return nullable.get(t)!
}

/** Whether a Maybe is written as `null` / its value (else tagged). */
const usesNull = (m: Extract<JsonType, { readonly kind: "maybe" }>): boolean => canBeNull(m)

// ── base64 (RFC 4648 §4, with padding) ───────────────────────

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const B64_INDEX = new Int16Array(128).fill(-1)
for (let i = 0; i < 64; i++) B64_INDEX[B64.charCodeAt(i)] = i

/** Base64 with padding. */
export const toBase64 = (data: Uint8Array): string => {
  let out = ""
  for (let i = 0; i < data.length; i += 3) {
    const n = data.length - i
    const x = (data[i]! << 16) | ((n > 1 ? data[i + 1]! : 0) << 8) | (n > 2 ? data[i + 2]! : 0)
    out += B64[(x >> 18) & 63]! + B64[(x >> 12) & 63]! + (n > 1 ? B64[(x >> 6) & 63]! : "=") + (n > 2 ? B64[x & 63]! : "=")
  }
  return out
}

/**
 * Strict base64 with padding: the alphabet of RFC 4648 §4, a length that is
 * a multiple of 4, and zero bits after the last byte, so that every byte
 * string has exactly one spelling. Undefined for anything else.
 */
export const fromBase64 = (s: string): Uint8Array | undefined => {
  if (s.length % 4 !== 0) return undefined
  const pad = s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0
  const out = new Uint8Array((s.length / 4) * 3 - pad)
  const at = (i: number) => {
    const c = s.charCodeAt(i)
    return c < 128 ? B64_INDEX[c]! : -1
  }
  let o = 0
  for (let i = 0; i < s.length; i += 4) {
    const last = i + 4 === s.length
    const a = at(i)
    const b = at(i + 1)
    const c = last && pad === 2 ? 0 : at(i + 2)
    const d = last && pad >= 1 ? 0 : at(i + 3)
    if (a < 0 || b < 0 || c < 0 || d < 0) return undefined
    if (last && ((pad === 2 && (b & 15) !== 0) || (pad === 1 && (c & 3) !== 0))) return undefined
    const x = (a << 18) | (b << 12) | (c << 6) | d
    out[o++] = x >> 16
    if (o < out.length) out[o++] = (x >> 8) & 255
    if (o < out.length) out[o++] = x & 255
  }
  return out
}

// ── shared ───────────────────────────────────────────────────

/** Links (named types, Secret, a Maybe's null form) followed without consuming a value: more means a type that only refers to itself. */
const MAX_HOPS = 1024

const SMALL_INTEGER = /^-?(?:0|[1-9]\d*)$/
const SPECIAL_FLOATS: ReadonlyMap<string, string> = new Map([["NaN", "NaN"], ["Infinity", "Infinity"], ["NegInfinity", "-Infinity"]])
const FLOAT_TAGS: ReadonlyMap<string, string> = new Map([["NaN", "NaN"], ["Infinity", "Infinity"], ["-Infinity", "NegInfinity"]])

const tagList = (tags: Iterable<string>) => {
  const all = [...tags]
  return all.length > 10 ? `${all.slice(0, 10).join(", ")}, … (${all.length} tags)` : all.join(", ")
}

/** `f`, for a secret: an error inside is replaced by one at the secret's place that names its type only (spec §15). */
const concealed = <R>(t: Extract<JsonType, { readonly kind: "secret" }>, place: Place, decoding: boolean, f: () => R): R => {
  try {
    return f()
  } catch (e) {
    if (!(e instanceof HausDecodeError || e instanceof HausEncodeError)) throw e
    const reason = `expected ${t.expected} (a Secret: the value is not shown)`
    throw decoding ? new HausDecodeError(reason, place.path()) : new HausEncodeError(reason, place.path())
  }
}

// ── writing: haus value → plain JSON ─────────────────────────

/**
 * The plain JSON (spec §16.3) of a haus value of the type `type`: the value
 * a schema of that type encodes. Throws HausEncodeError where the value
 * doesn't fit the type, and for a record payload with a field named `_tag`
 * (it has no plain form).
 */
export const toPlainJson = (type: JsonType, value: Value, limits: Partial<Limits> = {}, place: Place = Place.root()): Json => {
  const l = withDefaults(limits)
  const maxDepth = jsonDepth(l.maxDepth)
  const fail = (reason: string, at: Place): never => {
    throw new HausEncodeError(reason, at.path())
  }
  const describe = (v: Value) =>
    v.kind === "variant" ? `the tag ${v.tag}${v.args.length ? ` with ${v.args.length} argument(s)` : ""}`
    : v.kind === "number" ? "a number" : v.kind === "string" ? "a string" : v.kind === "bytes" ? "bytes" : `an ${v.kind}`
  const mismatch = (expected: string, v: Value, at: Place): never => fail(`expected ${expected}, found ${describe(v)}`, at)
  const text = (s: string, at: Place): string => {
    if (/\p{Cs}/u.test(s)) fail("a string with an unpaired surrogate has no JSON form (I-JSON)", at)
    return s
  }

  const write = (t: JsonType, v: Value, at: Place, depth: number, hops: number): Json => {
    if (typeof v !== "object" || v === null) return fail("not a haus value", at)
    if (depth > maxDepth) fail(`value nested deeper than ${l.maxDepth} levels (or cyclic)`, at)
    const hop = () => (hops < MAX_HOPS ? hops + 1 : fail("a type that refers only to itself (unguarded recursion)", at))
    switch (t.kind) {
      case "lazy":
        return write(t.get(), v, at, depth, hop())
      case "secret":
        return concealed(t, at, false, () => write(t.item, v, at, depth, hop()))
      case "string":
        return v.kind === "string" ? text(v.value, at) : mismatch("a string", v, at)
      case "bytes":
        return v.kind === "bytes" ? toBase64(v.bytes) : mismatch("bytes", v, at)
      case "bool":
        return v.kind === "variant" && v.args.length === 0 && (v.tag === "True" || v.tag === "False") ? v.tag === "True" : mismatch("True or False", v, at)
      case "integer":
        if (v.kind !== "number" || !SMALL_INTEGER.test(v.text)) return mismatch("a whole number", v, at)
        return t.quoted ? v.text : new JsonNumber(v.text)
      case "float":
        if (v.kind === "number") return isJsonNumber(v.text) ? new JsonNumber(v.text) : fail(`${v.text.slice(0, 30)} has no JSON form`, at)
        return (v.kind === "variant" && v.args.length === 0 ? SPECIAL_FLOATS.get(v.tag) : undefined) ?? mismatch("a number, NaN, Infinity or NegInfinity", v, at)
      case "decimal":
        return v.kind === "number" ? v.text : mismatch("a number", v, at)
      case "time": {
        const [arg] = v.kind === "variant" && v.tag === t.tag && v.args.length === 1 ? v.args : []
        return arg?.kind === "string" ? text(arg.value, at) : mismatch(`${t.tag}("…")`, v, at)
      }
      case "any":
        return losslessJson(v, l, at)
      case "array":
        if (v.kind !== "array") return mismatch("an array", v, at)
        return v.items.map((x, i) => write(t.item, x, at.child(i), depth + 1, 0))
      case "tuple": {
        if (v.kind !== "array") return mismatch("an array", v, at)
        if (t.rest === undefined && v.items.length !== t.items.length) fail(`expected ${t.items.length} elements, found ${v.items.length}`, at)
        return v.items.map((x, i) => write(t.items[i] ?? t.rest!, x, at.child(i), depth + 1, 0))
      }
      case "map":
        if (v.kind !== "record") return mismatch("a record", v, at)
        return jsonObject([...v.fields].map(([k, x]) => [text(k, at), write(t.value, x, at.child(k), depth + 1, 0)] as const))
      case "record":
        if (v.kind !== "record") return mismatch("a record", v, at)
        return jsonObject(fields(t, v.fields, at, depth))
      case "maybe": {
        const [some] = v.kind === "variant" && v.tag === "Some" && v.args.length === 1 ? v.args : []
        const none = v.kind === "variant" && v.tag === "None" && v.args.length === 0
        if (!none && some === undefined) return mismatch("None or Some(…)", v, at)
        if (usesNull(t)) return some === undefined ? null : write(t.item, some, at, depth, hop())
        return some === undefined ? jsonObject([["_tag", "None"]]) : jsonObject([["_tag", "Some"], ["value", write(t.item, some, at.child("value"), depth + 1, 0)]])
      }
      case "variant":
        return v.kind === "variant" ? writeVariant(t, v, at, depth) : mismatch("a variant", v, at)
      case "none":
        return fail(`${t.expected} has no plain JSON form`, at)
    }
  }

  const fields = (t: JsonRecordType, fs: ReadonlyMap<string, Value>, at: Place, depth: number): [string, Json][] =>
    [...fs].map(([k, x]) => {
      const type = t.fields.get(k)
      if (type === undefined) return fail(`field '${k.slice(0, 30)}' is not in the record type`, at)
      return [text(k, at), write(type, x, at.child(k), depth + 1, 0)]
    })

  const writeVariant = (t: JsonVariantType, v: HVariant, at: Place, depth: number): Json => {
    const c = t.cases.get(v.tag)
    if (c === undefined) {
      if (!t.open) return fail(`unknown tag ${v.tag}, expected one of ${tagList(t.cases.keys())}`, at)
      // An unknown value: its tag, and its arguments in their lossless form.
      const args = v.args.map((x, i) => losslessJson(x, l, at.child(i)))
      return jsonObject([["_tag", v.tag], ...(args.length > 0 ? [["args", args] as const] : [])])
    }
    if (isEnum(t)) return v.args.length === 0 ? v.tag : fail(`'${v.tag}' takes no payload`, at)
    const tag = ["_tag", v.tag] as const
    if (isUnitCase(c)) return v.args.length === 0 ? jsonObject([tag]) : fail(`'${v.tag}' takes no payload`, at)
    if (c.kind === "record") {
      const [payload] = v.args
      if (v.args.length !== 1 || payload!.kind !== "record") return fail(`'${v.tag}' takes a record payload`, at)
      if (c.record.fields.has("_tag") || payload!.fields.has("_tag")) return fail(`'${v.tag}' has a field named _tag: a record payload with one has no plain JSON form`, at)
      return jsonObject([tag, ...fields(c.record, payload!.fields, at, depth)])
    }
    const { items } = c as Extract<JsonCase, { kind: "positional" }>
    if (v.args.length !== items.length) return fail(`'${v.tag}' takes ${items.length} argument(s), found ${v.args.length}`, at)
    if (items.length === 1) return jsonObject([tag, ["value", write(items[0]!, v.args[0]!, at.child("value"), depth + 1, 0)]])
    const values = at.child("values")
    return jsonObject([tag, ["values", v.args.map((x, i) => write(items[i]!, x, values.child(i), depth + 2, 0))]])
  }

  return write(type, value, place, 0, 0)
}

// ── reading: plain JSON → haus value ─────────────────────────

/**
 * The haus value of plain JSON (spec §16.3) of the type `type`, for the
 * type's schema to decode. Checks the JSON's form: kinds, tags, members;
 * the schema checks the rest (ranges, whole numbers, std/time…). Throws
 * HausDecodeError.
 */
export const fromPlainJson = (type: JsonType, json: Json, limits: Partial<Limits> = {}, place: Place = Place.root()): Value => {
  const l = withDefaults(limits)
  const maxDepth = jsonDepth(l.maxDepth)
  const fail = (reason: string, at: Place): never => {
    throw new HausDecodeError(reason, at.path())
  }
  const mismatch = (expected: string, j: Json, at: Place): never => fail(`expected ${expected}, found ${describeJson(j)}`, at)
  /** A number in a string (Int, Decimal): a JSON number literal, within the limits. */
  const numberText = (s: string, at: Place): Value => {
    const normalized = isJsonNumber(s) ? normalizeJsonNumber(s) : undefined
    if (normalized === undefined) return fail(`expected a number literal in the string, found ${describeJson(s)}`, at)
    const issue = numberLimitIssue(normalized, l)
    return issue === undefined ? num(normalized) : fail(issue, at)
  }
  const object = (j: Json, expected: string, at: Place): JsonObject => (isJsonObject(j) ? j : mismatch(expected, j, at))
  /** Members of a tagged object other than `_tag` and `allowed`: an error. */
  const only = (j: JsonObject, allowed: readonly string[], tag: string, at: Place) => {
    for (const k of Object.keys(j)) {
      if (k !== "_tag" && !allowed.includes(k)) fail(`unexpected member ${JSON.stringify(k.slice(0, 30))} for '${tag}'`, at)
    }
  }
  const member = (j: JsonObject, name: string, tag: string, at: Place): Json =>
    Object.hasOwn(j, name) ? j[name]! : fail(`'${tag}' needs a member "${name}"`, at)

  const read = (t: JsonType, j: Json, at: Place, depth: number, hops: number): Value => {
    if (depth > maxDepth) fail(`nesting deeper than ${l.maxDepth} levels`, at)
    const hop = () => (hops < MAX_HOPS ? hops + 1 : fail("a type that refers only to itself (unguarded recursion)", at))
    switch (t.kind) {
      case "lazy":
        return read(t.get(), j, at, depth, hop())
      case "secret":
        return concealed(t, at, true, () => read(t.item, j, at, depth, hop()))
      case "string":
        return typeof j === "string" ? stringOfJson(j, l, at) : mismatch("a string", j, at)
      case "bytes": {
        if (typeof j !== "string") return mismatch("a base64 string", j, at)
        const data = fromBase64(j)
        if (data === undefined) return fail("expected base64 with padding (RFC 4648 §4)", at)
        return data.length * 2 > l.maxStringLength ? fail(`byte string longer than ${l.maxStringLength} hex digits`, at) : bytesValue(data)
      }
      case "bool":
        return typeof j === "boolean" ? variant(j ? "True" : "False") : mismatch("true or false", j, at)
      case "integer":
        if (!t.quoted) return j instanceof JsonNumber ? numberOfJson(j, l, at) : mismatch("a number", j, at)
        if (typeof j !== "string") return mismatch("a whole number in a string", j, at)
        return SMALL_INTEGER.test(j) ? numberText(j, at) : fail(`expected a whole number in a string, found ${describeJson(j)}`, at)
      case "float":
        if (j instanceof JsonNumber) return numberOfJson(j, l, at)
        return (typeof j === "string" ? FLOAT_TAGS.get(j) : undefined) !== undefined ? variant(FLOAT_TAGS.get(j as string)!)
          : mismatch(`a number, "NaN", "Infinity" or "-Infinity"`, j, at)
      case "decimal":
        return typeof j === "string" ? numberText(j, at) : mismatch(`a decimal in a string ("19.90")`, j, at)
      case "time":
        return typeof j === "string" ? variant(t.tag, [stringOfJson(j, l, at)]) : mismatch(`a ${t.tag} string`, j, at)
      case "any":
        return fromLossless(j, l, at)
      case "array":
        if (!Array.isArray(j)) return mismatch("an array", j, at)
        return arr(j.map((x, i) => read(t.item, x, at.child(i), depth + 1, 0)))
      case "tuple": {
        if (!Array.isArray(j)) return mismatch("an array", j, at)
        if (j.length < t.items.length || (t.rest === undefined && j.length > t.items.length)) fail(`expected ${t.items.length} elements, found ${j.length}`, at)
        return arr(j.map((x, i) => read(t.items[i] ?? t.rest!, x, at.child(i), depth + 1, 0)))
      }
      case "map": {
        const o = object(j, "an object", at)
        return rec(new Map(Object.keys(o).map((k) => [key(k, at), read(t.value, o[k]!, at.child(k), depth + 1, 0)] as const)))
      }
      case "record":
        return rec(fields(t, object(j, "an object", at), [], at, depth))
      case "maybe": {
        if (usesNull(t)) return j === null ? variant("None") : variant("Some", [read(t.item, j, at, depth, hop())])
        const o = object(j, `{"_tag": "None"} or {"_tag": "Some", "value": …}`, at)
        const tag = o["_tag"]
        if (tag === "None") return only(o, [], tag, at), variant("None")
        if (tag === "Some") return only(o, ["value"], tag, at), variant("Some", [read(t.item, member(o, "value", tag, at), at.child("value"), depth + 1, 0)])
        return fail(`expected "_tag": "None" or "Some"`, at)
      }
      case "variant":
        return readVariant(t, j, at, depth)
      case "none":
        return fail(`${t.expected} has no plain JSON form`, at)
    }
  }

  const key = (k: string, at: Place) => (longerThan(k, l.maxStringLength) ? fail(`key longer than ${l.maxStringLength} characters`, at) : k)

  /** The fields of a record (or record payload): listed members read with their types; others ignored (open) or an error (closed). */
  const fields = (t: JsonRecordType, o: JsonObject, skip: readonly string[], at: Place, depth: number): Map<string, Value> => {
    const out = new Map<string, Value>()
    for (const k of Object.keys(o)) {
      if (skip.includes(k)) continue
      const type = t.fields.get(k)
      if (type !== undefined) out.set(k, read(type, o[k]!, at.child(k), depth + 1, 0))
      else if (t.closed) fail(`unexpected member ${JSON.stringify(k.slice(0, 30))} (the record is closed)`, at)
    }
    return out
  }

  const readVariant = (t: JsonVariantType, j: Json, at: Place, depth: number): Value => {
    if (isEnum(t)) {
      if (typeof j !== "string") return mismatch(`one of the strings ${tagList(t.cases.keys())}`, j, at)
      return t.cases.has(j) ? variant(j) : fail(`unknown tag ${describeJson(j)}, expected one of ${tagList(t.cases.keys())}`, at)
    }
    const o = object(j, `an object with "_tag"`, at)
    const tag = o["_tag"]
    if (typeof tag !== "string") return fail(`expected a member "_tag" with the tag, a string`, at)
    const c = t.cases.get(tag)
    if (c === undefined) {
      if (!t.open) return fail(`unknown tag ${describeJson(tag)}, expected one of ${tagList(t.cases.keys())}`, at)
      // An unknown value (spec §16.3).
      if (!/^[A-Z][A-Za-z0-9_]*$/.test(tag)) return fail(`"_tag" is not a tag name: ${describeJson(tag)}`, at)
      const members = Object.keys(o).filter((k) => k !== "_tag")
      if (members.length === 0) return variant(tag)
      // As written: the arguments, losslessly.
      if (members.length === 1 && members[0] === "args") {
        const args = o["args"]!
        if (!Array.isArray(args) || args.length === 0) return fail(`"args" must be a non-empty array`, at)
        const place = at.child("args")
        return variant(tag, args.map((x, i) => fromLossless(x, l, place.child(i))))
      }
      // A newer writer's case: its other members are a record payload, read without a schema (§16.1).
      return variant(tag, [rec(new Map(members.map((k) => [key(k, at), valueOfJson(o[k]!, l, at.child(k))] as const)))])
    }
    if (isUnitCase(c)) return only(o, [], tag, at), variant(tag)
    if (c.kind === "record") {
      if (c.record.fields.has("_tag")) return fail(`'${tag}' has a field named _tag: a record payload with one has no plain JSON form`, at)
      return variant(tag, [rec(fields(c.record, o, ["_tag"], at, depth))])
    }
    const { items } = c as Extract<JsonCase, { kind: "positional" }>
    if (items.length === 1) return only(o, ["value"], tag, at), variant(tag, [read(items[0]!, member(o, "value", tag, at), at.child("value"), depth + 1, 0)])
    only(o, ["values"], tag, at)
    const values = member(o, "values", tag, at)
    if (!Array.isArray(values) || values.length !== items.length) return fail(`'${tag}' needs "values", an array of ${items.length}`, at)
    const place = at.child("values")
    return variant(tag, values.map((x, i) => read(items[i]!, x, place.child(i), depth + 2, 0)))
  }

  return read(type, json, place, 0, 0)
}
