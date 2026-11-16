/**
 * JSON (spec §16): a strict I-JSON reader that keeps every number exactly as
 * written, a writer, and the two forms that need no schema:
 *
 *   importJson('{"total": 19.90, "ok": true}')   // any JSON read as haus (§16.1): { total: 19.90, ok: True }
 *   toHausJson(value)                            // self-describing JSON (§16.2): {"_haus":1,"_value":{"_rec":{"total":{"_num":"19.90"}}}}
 *   fromHausJson(text)                           // and back, to an equal value
 *
 * Schema-based JSON with a schema type (§16.3) is in json-schema-based.ts,
 * and in `h.toJson` / `h.fromJson` for schemas.
 */
import { HausDecodeError, HausEncodeError, HausSyntaxError, locate, START, type ErrorCode, type ErrorDetails, type Origin, type Path, type Problem } from "./errors.js"
import { toHex } from "./format.js"
import { isNormalizedNumber, normalizeNumber, numberLimitIssue } from "./number.js"
import { checkLimits, longerThan, MAX_DEPTH, MAX_SUPPORTED_DEPTH, withDefaults, type Limits } from "./parser.js"
import { chunks, type ChunkSource } from "./stream.js"
import { arr, bytes as bytesValue, num, rec, str, variant, type Value } from "./value.js"

// ── the JSON data model ──────────────────────────────────────

/**
 * A JSON number, exactly as written (`"19.90"`, `"1E+05"`): never rounded
 * through a binary float. `JSON.stringify` writes it exactly where the engine
 * has `JSON.rawJSON`; `stringifyJson` always does.
 */
export class JsonNumber {
  constructor(
    /** The literal, in JSON's number syntax. */
    readonly text: string,
  ) {}

  toJSON(): unknown {
    const raw = (JSON as { readonly rawJSON?: (text: string) => unknown }).rawJSON
    if (raw === undefined) throw new Error("JsonNumber: this engine has no JSON.rawJSON; write the JSON with stringifyJson")
    return raw(this.text)
  }
}

/**
 * A JSON value. Objects have own properties only (a member named
 * `__proto__` is data), arrays are arrays, numbers are `JsonNumber`s.
 */
export type Json = null | boolean | string | JsonNumber | readonly Json[] | JsonObject

export interface JsonObject {
  readonly [key: string]: Json
}

/** Whether `j` is a JSON object (not null, an array or a number). */
export const isJsonObject = (j: Json): j is JsonObject => typeof j === "object" && j !== null && !Array.isArray(j) && !(j instanceof JsonNumber)

/** An object with these members, in this order. A member named `__proto__` is an own property, never the prototype. */
export const jsonObject = (entries: Iterable<readonly [string, Json]>): JsonObject => {
  const out = Object.create(null) as Record<string, Json>
  for (const [k, v] of entries) setMember(out, k, v)
  return out
}

const setMember = (out: Record<string, Json>, key: string, value: Json) =>
  Object.defineProperty(out, key, { value, enumerable: true, writable: true, configurable: true })

/**
 * Whether two JSON values are the same data (spec §16): member order and
 * whitespace don't matter, numbers compare by their text.
 */
export const equalsJson = (a: Json, b: Json): boolean => {
  if (a === null || typeof a !== "object") return a === b
  if (a instanceof JsonNumber) return b instanceof JsonNumber && a.text === b.text
  if (Array.isArray(a)) return Array.isArray(b) && a.length === b.length && a.every((x, i) => equalsJson(x, (b as readonly Json[])[i]!))
  if (b === null || typeof b !== "object" || Array.isArray(b) || b instanceof JsonNumber) return false
  const ka = Object.keys(a)
  return ka.length === Object.keys(b).length && ka.every((k) => Object.hasOwn(b, k) && equalsJson((a as JsonObject)[k]!, (b as JsonObject)[k]!))
}

// ── reading ──────────────────────────────────────────────────

/** A JSON number literal (RFC 8259). */
const JSON_NUMBER = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y
const WHOLE_JSON_NUMBER = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/

/** Whether `text` is one JSON number literal. */
export const isJsonNumber = (text: string): boolean => WHOLE_JSON_NUMBER.test(text)

/** Why a JSON number literal is beyond the limits of §7 (its length, its exponent), or undefined. */
export const jsonNumberIssue = (text: string, limits: Limits): Problem | undefined => {
  if (text.length > limits.maxNumberLength) return { code: "number-too-long", reason: `number literal longer than ${limits.maxNumberLength} characters` }
  const exponent = /[eE][+-]?0*(\d+)$/.exec(text)?.[1]
  if (exponent !== undefined && (exponent.length > 15 || Number(exponent) > limits.maxExponent)) return { code: "exponent-too-large", reason: `exponent larger than ${limits.maxExponent}` }
  return undefined
}

/** The normalized haus literal (spec §2) of a JSON number literal: `1E+05` → `1e5`, `1e-0` → `1e0`. */
export const normalizeJsonNumber = (text: string): string => {
  const m = /^(-?[\d.]+)(?:[eE]([+-]?)0*(\d+))?$/.exec(text)
  if (!m) throw new Error(`not a JSON number: ${text}`)
  const [, mantissa, sign, exponent] = m
  return exponent === undefined ? mantissa! : `${mantissa}e${sign === "-" && exponent !== "0" ? "-" : ""}${exponent}`
}

const hex4 = (c: number) => c.toString(16).toUpperCase().padStart(4, "0")
const short = (s: string) => JSON.stringify(s.length > 30 ? s.slice(0, 30) + "…" : s)

/** DEL, C1 and the bidi controls (spec §4): what JSON writers escape, and the self-describing reader rejects raw. */
const DISPLAY_CONTROL = /[\u007f-\u009f\u202a-\u202e\u2066-\u2069]/
const DISPLAY_CONTROLS = new RegExp(DISPLAY_CONTROL.source, "g")
const isBidi = (c: number) => (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069)

/**
 * Recursive descent over one JSON text (RFC 8259) restricted to I-JSON
 * (RFC 7493): no duplicate member names, no unpaired surrogates, and the
 * limits of spec §7 (nesting, number literals, string lengths). With
 * `rejectControls` (self-describing JSON, §16), also no raw DEL, C1 or bidi
 * controls in strings and member names.
 */
class Reader {
  private pos = 0

  constructor(
    private readonly src: string,
    private readonly limits: Limits,
    private readonly origin: Origin,
    private readonly rejectControls: boolean,
  ) {}

  document(): Json {
    this.space()
    const value = this.value(0)
    this.space()
    if (this.pos < this.src.length) this.fail("json-syntax", `unexpected ${this.found()} after the JSON value`, this.pos, { expected: "the end of the JSON text", found: this.found() })
    return value
  }

  private fail(code: ErrorCode, reason: string, at = this.pos, details?: ErrorDetails): never {
    const p = locate(this.src, at, this.origin)
    throw new HausSyntaxError(`JSON: ${reason}`, p.offset, p.line, p.column, code, details)
  }

  private found(): string {
    if (this.pos >= this.src.length) return "end of input"
    const c = this.src.codePointAt(this.pos)!
    return c < 0x20 ? `U+${hex4(c)}` : `'${String.fromCodePoint(c)}'`
  }

  private space() {
    for (;;) {
      const c = this.src.charCodeAt(this.pos)
      if (c === 32 || c === 9 || c === 10 || c === 13) this.pos++
      else return
    }
  }

  private value(depth: number): Json {
    switch (this.src[this.pos]) {
      case "{":
        return this.object(depth)
      case "[":
        return this.array(depth)
      case '"':
        return this.string()
      case "t":
        return this.word("true", true)
      case "f":
        return this.word("false", false)
      case "n":
        return this.word("null", null)
      default:
        return this.number()
    }
  }

  private word<T extends Json>(word: string, value: T): T {
    if (!this.src.startsWith(word, this.pos)) this.fail("json-syntax", `unexpected ${this.found()}`, this.pos, { expected: "a JSON value", found: this.found() })
    this.pos += word.length
    return value
  }

  private number(): JsonNumber {
    JSON_NUMBER.lastIndex = this.pos
    const text = JSON_NUMBER.exec(this.src)?.[0]
    if (text === undefined) this.fail("json-syntax", `unexpected ${this.found()}`, this.pos, { expected: "a JSON value", found: this.found() })
    const issue = jsonNumberIssue(text, this.limits)
    if (issue !== undefined) this.fail(issue.code, issue.reason)
    this.pos += text.length
    return new JsonNumber(text)
  }

  private open(depth: number) {
    if (depth >= this.limits.maxDepth) this.fail("nesting-too-deep", `nesting deeper than ${this.limits.maxDepth} levels`)
    this.pos++
    this.space()
  }

  private array(depth: number): Json[] {
    this.open(depth)
    const out: Json[] = []
    if (this.src[this.pos] === "]") {
      this.pos++
      return out
    }
    for (;;) {
      this.space()
      out.push(this.value(depth + 1))
      this.space()
      const c = this.src[this.pos]
      if (c !== "," && c !== "]") this.fail("json-syntax", `expected ',' or ']', found ${this.found()}`, this.pos, { expected: "',' or ']'", found: this.found() })
      this.pos++
      if (c === "]") return out
    }
  }

  private object(depth: number): JsonObject {
    this.open(depth)
    const out = Object.create(null) as Record<string, Json>
    if (this.src[this.pos] === "}") {
      this.pos++
      return out
    }
    for (;;) {
      this.space()
      const at = this.pos
      if (this.src[this.pos] !== '"') this.fail("json-syntax", `expected a member name, found ${this.found()}`, this.pos, { expected: "a member name", found: this.found() })
      const key = this.string()
      // I-JSON: member names are unique. A hash lookup, so this stays linear.
      if (Object.hasOwn(out, key)) this.fail("duplicate-key", `duplicate member name ${short(key)}`, at)
      this.space()
      if (this.src[this.pos] !== ":") this.fail("json-syntax", `expected ':', found ${this.found()}`, this.pos, { expected: "':'", found: this.found() })
      this.pos++
      this.space()
      setMember(out, key, this.value(depth + 1))
      this.space()
      const c = this.src[this.pos]
      if (c !== "," && c !== "}") this.fail("json-syntax", `expected ',' or '}', found ${this.found()}`, this.pos, { expected: "',' or '}'", found: this.found() })
      this.pos++
      if (c === "}") return out
    }
  }

  private string(): string {
    const open = this.pos++
    let out = ""
    let start = this.pos
    for (;;) {
      if (this.pos >= this.src.length) this.fail("unterminated-string", "unterminated string", open)
      const c = this.src.charCodeAt(this.pos)
      if (c === 34) {
        out += this.src.slice(start, this.pos++)
        break
      }
      if (c === 92) {
        out += this.src.slice(start, this.pos)
        out += this.escape()
        start = this.pos
      } else if (c < 0x20) {
        this.fail("control-character", `raw control character U+${hex4(c)} in a string (write it as \\u${hex4(c)})`)
      } else if (this.rejectControls && (c === 0x7f || (c >= 0x80 && c <= 0x9f) || isBidi(c))) {
        // Self-describing JSON is written by haus tools only, which escape these (§16).
        if (isBidi(c)) this.fail("bidi-control", `raw bidi control U+${hex4(c)} in a string (write it as \\u${hex4(c)})`)
        this.fail("control-character", `raw control character U+${hex4(c)} in a string (write it as \\u${hex4(c)})`)
      } else if (c >= 0xd800 && c <= 0xdfff) {
        const d = this.src.charCodeAt(this.pos + 1)
        if (c > 0xdbff || !(d >= 0xdc00 && d <= 0xdfff)) this.fail("unpaired-surrogate", `unpaired surrogate U+${hex4(c)}`)
        this.pos += 2
      } else {
        this.pos++
      }
    }
    if (longerThan(out, this.limits.maxStringLength)) this.fail("string-too-long", `string longer than ${this.limits.maxStringLength} characters`, open)
    return out
  }

  private hex(at: number): number {
    const digits = this.src.slice(at, at + 4)
    if (!/^[0-9A-Fa-f]{4}$/.test(digits)) this.fail("invalid-unicode-escape", "expected four hex digits after \\u", at)
    return parseInt(digits, 16)
  }

  private escape(): string {
    const at = this.pos
    const e = this.src[at + 1]
    this.pos += 2
    switch (e) {
      case '"': return '"'
      case "\\": return "\\"
      case "/": return "/"
      case "b": return "\b"
      case "f": return "\f"
      case "n": return "\n"
      case "r": return "\r"
      case "t": return "\t"
      case "u": {
        const hi = this.hex(at + 2)
        this.pos = at + 6
        if (hi < 0xd800 || hi > 0xdfff) return String.fromCharCode(hi)
        // I-JSON: a surrogate escape must be half of a pair, high then low.
        if (hi <= 0xdbff && this.src.startsWith("\\u", this.pos)) {
          const lo = this.hex(this.pos + 2)
          if (lo >= 0xdc00 && lo <= 0xdfff) {
            this.pos += 6
            return String.fromCharCode(hi, lo)
          }
        }
        return this.fail("unpaired-surrogate", `unpaired surrogate \\u${hex4(hi)}`, at)
      }
      default:
        return this.fail("invalid-escape", `invalid escape \\${e ?? ""}`, at)
    }
  }
}

/**
 * Read one JSON text within `limits` (`maxDepth` counts JSON's arrays and
 * objects), starting at `origin`. `rejectControls`: raw DEL, C1 and bidi
 * controls in strings are errors, as in self-describing JSON (§16).
 */
export const readJson = (text: string, limits: Limits, origin: Origin = START, rejectControls = false): Json => {
  // A leading byte order mark is ignored, as in haus (spec §4).
  if (origin.offset === 0 && text.charCodeAt(0) === 0xfeff) return new Reader(text.slice(1), limits, { offset: 1, line: 1, column: 2 }, rejectControls).document()
  return new Reader(text, limits, origin, rejectControls).document()
}

/**
 * Read one JSON text, strictly: RFC 8259 restricted to I-JSON (RFC 7493),
 * within the limits of spec §7 (`maxDepth` counts arrays and objects, at most
 * `hausJsonDepth(MAX_SUPPORTED_DEPTH)`, 2050). Numbers keep their exact text.
 * Throws HausSyntaxError, with line and column; a RangeError for a larger
 * `maxDepth`.
 */
export const parseJson = (text: string, limits: Partial<Limits> = {}): Json => readJson(text, withJsonDefaults(limits))

/** `withDefaults` for raw JSON, whose `maxDepth` counts JSON levels: at most `hausJsonDepth(MAX_SUPPORTED_DEPTH)`. */
const withJsonDefaults = (limits: Partial<Limits>): Limits => {
  const { maxDepth, ...rest } = limits
  checkLimits({ maxDepth }, hausJsonDepth(MAX_SUPPORTED_DEPTH), "JSON nesting")
  return { ...withDefaults(rest), maxDepth: maxDepth ?? MAX_DEPTH }
}

/**
 * How deeply schema-based JSON may nest to hold a value of `maxDepth` haus
 * levels (spec §16): it takes up to four JSON levels for one haus level
 * (`Tag { … }` of an unknown tag is `{"_tag": …, "_args": [{"_rec": {…}}]}`).
 * The haus value is then held to `maxDepth` itself.
 */
export const jsonDepth = (maxDepth: number): number => 4 * maxDepth + 1

/** How deeply self-describing JSON may nest for `maxDepth` haus levels: `jsonDepth`, and one more for the envelope. */
export const hausJsonDepth = (maxDepth: number): number => jsonDepth(maxDepth) + 1

/** `limits` for reading the schema-based JSON of values within them (see `jsonDepth`). */
export const jsonDepthFor = (limits: Limits): Limits => ({ ...limits, maxDepth: jsonDepth(limits.maxDepth) })

/** `limits` for reading the self-describing JSON of values within them (see `hausJsonDepth`). */
const hausJsonDepthFor = (limits: Limits): Limits => ({ ...limits, maxDepth: hausJsonDepth(limits.maxDepth) })

// ── writing ──────────────────────────────────────────────────

const LONE_SURROGATE = /\p{Cs}/u

const escapeControl = (c: string) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`

/**
 * A JSON string literal, with DEL, C1 and bidi controls escaped besides
 * what JSON escapes (spec §16), so it can't display differently from what it
 * holds. A string with an unpaired surrogate has none (I-JSON).
 */
const quoteJson = (s: string, path: () => Path): string => {
  if (LONE_SURROGATE.test(s)) throw new HausEncodeError("a string with an unpaired surrogate has no JSON form (I-JSON)", path(), "no-json-form")
  const quoted = JSON.stringify(s)
  return DISPLAY_CONTROL.test(quoted) ? quoted.replace(DISPLAY_CONTROLS, escapeControl) : quoted
}

/**
 * JSON text for a JSON value, compact (no whitespace). Numbers are written
 * exactly as their text; DEL, C1 and bidi controls are escaped. Throws HausEncodeError for what isn't JSON or
 * I-JSON: a number that isn't a JSON literal, an unpaired surrogate, a cycle.
 * Iterative, with a stack of what is left to write, so any depth works.
 */
export const stringifyJson = (json: Json): string => {
  const out: string[] = []
  /** What is left to write: JSON values, text, and the end of a container (which leaves `open`). */
  type Work = { readonly json: Json } | { readonly text: string } | { readonly close: string; readonly container: object }
  const work: Work[] = [{ json }]
  /** The containers being written, to detect a cycle. */
  const open = new Set<object>()
  const enter = (container: object, close: string) => {
    if (open.has(container)) throw new HausEncodeError("JSON contains itself (cyclic)", [], "cyclic-value")
    open.add(container)
    work.push({ close, container })
  }
  while (work.length > 0) {
    const w = work.pop()!
    if ("text" in w) {
      out.push(w.text)
      continue
    }
    if ("close" in w) {
      out.push(w.close)
      open.delete(w.container)
      continue
    }
    const j = w.json
    if (j === null) out.push("null")
    else if (j === true || j === false) out.push(String(j))
    else if (typeof j === "string") out.push(quoteJson(j, () => []))
    else if (j instanceof JsonNumber) {
      if (!WHOLE_JSON_NUMBER.test(j.text)) throw new HausEncodeError(`not a JSON number: ${short(j.text)}`, [], "cannot-encode")
      out.push(j.text)
    } else if (Array.isArray(j)) {
      out.push("[")
      enter(j, "]")
      for (let i = j.length - 1; i >= 0; i--) {
        work.push({ json: j[i] as Json })
        if (i > 0) work.push({ text: "," })
      }
    } else if (typeof j === "object") {
      out.push("{")
      enter(j, "}")
      const keys = Object.keys(j)
      for (let i = keys.length - 1; i >= 0; i--) {
        work.push({ json: (j as JsonObject)[keys[i]!]! }, { text: `${i > 0 ? "," : ""}${quoteJson(keys[i]!, () => [])}:` })
      }
    } else {
      throw new HausEncodeError(`not a JSON value: ${typeof j}`, [], "cannot-encode")
    }
  }
  return out.join("")
}

// ── places, for errors ───────────────────────────────────────

/** Where a conversion is: linked to its parent, and turned into a Path only for an error. */
export class Place {
  private constructor(
    private readonly parent: Place | undefined,
    private readonly key: string | number | undefined,
  ) {}

  static root(key?: string | number): Place {
    return new Place(undefined, key)
  }

  child(key: string | number): Place {
    return new Place(this, key)
  }

  path(): Path {
    const out: (string | number)[] = []
    for (let p: Place | undefined = this; p; p = p.parent) if (p.key !== undefined) out.push(p.key)
    return out.reverse()
  }
}

/** A short description of a JSON value, for errors. */
export const describeJson = (j: Json): string =>
  j === null ? "null"
  : typeof j === "boolean" ? String(j)
  : typeof j === "string" ? `the string ${short(j)}`
  : j instanceof JsonNumber ? `the number ${j.text.length > 30 ? j.text.slice(0, 30) + "…" : j.text}`
  : Array.isArray(j) ? "an array"
  : "an object"

/** A JSON number as a haus number (its normalized literal), checked against the limits. */
export const numberOfJson = (n: JsonNumber, limits: Limits, place: Place) => {
  if (!WHOLE_JSON_NUMBER.test(n.text)) throw new HausDecodeError(`not a JSON number: ${short(n.text)}`, place.path(), "invalid-number")
  const issue = jsonNumberIssue(n.text, limits)
  if (issue !== undefined) throw new HausDecodeError(issue.reason, place.path(), issue.code)
  return num(normalizeJsonNumber(n.text))
}

/** A member name as a record key, checked against the string limit (spec §7: it counts keys too). */
export const keyOfJson = (k: string, limits: Limits, place: Place): string => {
  if (longerThan(k, limits.maxStringLength)) throw new HausDecodeError(`key longer than ${limits.maxStringLength} characters`, place.path(), "key-too-long")
  return k
}

/** A tag name within the string limit (spec §7: it counts tags too): undefined, or why not. */
export const tagLengthIssue = (tag: string, limits: Limits): Problem | undefined =>
  tag.length > limits.maxStringLength ? { code: "tag-too-long", reason: `tag longer than ${limits.maxStringLength} characters` } : undefined

/** A JSON string as a haus string, checked against the limits (a parsed one is within them already). */
export const stringOfJson = (s: string, limits: Limits, place: Place) => {
  if (longerThan(s, limits.maxStringLength)) throw new HausDecodeError(`string longer than ${limits.maxStringLength} characters`, place.path(), "string-too-long")
  if (LONE_SURROGATE.test(s)) throw new HausDecodeError("a string with an unpaired surrogate", place.path(), "unpaired-surrogate")
  return str(s)
}

// ── §16.1: JSON import ───────────────────────────────────────

/** JSON as a haus value (spec §16.1): objects → records, `true`/`false` → `True`/`False`, `null` → `None`, numbers exact. */
const imported = (j: Json, limits: Limits, depth: number, place: Place): Value => {
  if (j === null) return variant("None")
  if (j === true || j === false) return variant(j ? "True" : "False")
  if (typeof j === "string") return stringOfJson(j, limits, place)
  if (j instanceof JsonNumber) return numberOfJson(j, limits, place)
  if (depth >= limits.maxDepth) throw new HausDecodeError(`nesting deeper than ${limits.maxDepth} levels`, place.path(), "nesting-too-deep")
  if (Array.isArray(j)) return arr(j.map((x, i) => imported(x, limits, depth + 1, place.child(i))))
  if (typeof j !== "object") throw new HausDecodeError(`not a JSON value: ${typeof j}`, place.path(), "type-mismatch")
  return rec(new Map(Object.keys(j).map((k) => [keyOfJson(k, limits, place), imported((j as JsonObject)[k]!, limits, depth + 1, place.child(k))])))
}

/** JSON imported as a haus value (§16.1), from a place inside a larger conversion. */
export const importedValue = (j: Json, limits: Limits, place: Place): Value => imported(j, limits, 0, place)

/**
 * Import JSON text as a haus value, without a schema (spec §16.1): an object
 * as a record, an array as an array, a string as a string, a number as a
 * number with its literal normalized (`1E+05` → `1e5`, `19.90` stays
 * `19.90`), `true`/`false` as `True`/`False` and `null` as `None`. Nothing
 * in the data is special: `{"_tag": "Circle"}` is a record. It only reads.
 */
export const importJson = (text: string, limits: Partial<Limits> = {}): Value => {
  const l = withDefaults(limits)
  return imported(readJson(text, l), l, 0, Place.root())
}

/** `importJson` for a JSON value that is already parsed. */
export const importJsonValue = (json: Json, limits: Partial<Limits> = {}): Value => imported(json, withDefaults(limits), 0, Place.root())

// ── §16.2: self-describing JSON ──────────────────────────────

const TAG = /^[A-Z][A-Za-z0-9_]*$/
const LOWER_HEX = /^(?:[0-9a-f]{2})*$/

/** The version of self-describing JSON, `_haus` in the envelope. */
const VERSION = "1"

/**
 * The self-describing JSON of a value (spec §16.2), without the envelope (as
 * inside schema-based JSON): strings and arrays as themselves,
 * `{"_num": "19.90"}`, `{"_bytes": "0b34"}`, `{"_rec": {…}}`,
 * `{"_tag": "Circle", "_args": […]}`. A value built in code is checked
 * first: tag names, number literals (normalized as the parser would), the
 * limits.
 */
export const hausJsonOf = (value: Value, limits: Limits, place: Place): Json => {
  const fail = (reason: string, at: Place, code: ErrorCode = "cannot-encode"): never => {
    throw new HausEncodeError(reason, at.path(), code)
  }
  const write = (v: Value, depth: number, at: Place, payload: boolean): Json => {
    if (typeof v !== "object" || v === null) return fail("not a haus value", at)
    const open = () => {
      if (!payload && depth >= limits.maxDepth) fail(`value nested deeper than ${limits.maxDepth} levels (or cyclic)`, at, "nesting-too-deep")
    }
    const inner = payload ? depth : depth + 1
    switch (v.kind) {
      case "string":
        if (typeof v.value !== "string") return fail("not a haus value", at)
        if (longerThan(v.value, limits.maxStringLength)) fail(`string longer than ${limits.maxStringLength} characters`, at, "string-too-long")
        return v.value
      case "number": {
        const text = typeof v.text !== "string" ? undefined : isNormalizedNumber(v.text) ? v.text : normalizeNumber(v.text, limits)
        if (text === undefined) return fail("not a number literal", at)
        const issue = numberLimitIssue(text, limits)
        return issue === undefined ? jsonObject([["_num", text]]) : fail(issue.reason, at, issue.code)
      }
      case "bytes":
        return v.bytes instanceof Uint8Array ? jsonObject([["_bytes", toHex(v.bytes)]]) : fail("not a haus value", at)
      case "array":
        open()
        return v.items.map((x, i) => write(x, inner, at.child(i), false))
      case "record":
        open()
        return jsonObject([["_rec", jsonObject([...v.fields].map(([k, x]) => {
          if (longerThan(k, limits.maxStringLength)) fail(`key longer than ${limits.maxStringLength} characters`, at, "key-too-long")
          return [k, write(x, inner, at.child(k), false)] as const
        }))]])
      case "variant": {
        if (typeof v.tag !== "string" || !TAG.test(v.tag)) return fail("not a tag name", at, "invalid-tag")
        const tagIssue = tagLengthIssue(v.tag, limits)
        if (tagIssue !== undefined) fail(tagIssue.reason, at, tagIssue.code)
        if (v.args.length === 0) return jsonObject([["_tag", v.tag]])
        open()
        // `Tag { … }` is one level, as in the parser; `Tag(a, b)` nests its arguments.
        const single = v.args.length === 1 && v.args[0]!.kind === "record"
        return jsonObject([["_tag", v.tag], ["_args", v.args.map((x, i) => write(x, depth + 1, at.child(i), single))]])
      }
      default:
        return fail("not a haus value", at)
    }
  }
  return write(value, 0, place, false)
}

/** A haus value from its self-describing JSON without the envelope (spec §16.2, as inside schema-based JSON); any other JSON is an error. */
export const valueOfHausJson = (json: Json, limits: Limits, place: Place): Value => {
  const fail = (reason: string, at: Place, code: ErrorCode = "haus-json-form"): never => {
    throw new HausDecodeError(reason, at.path(), code)
  }
  const read = (j: Json, depth: number, at: Place, payload: boolean): Value => {
    const open = () => {
      if (!payload && depth >= limits.maxDepth) fail(`nesting deeper than ${limits.maxDepth} levels`, at, "nesting-too-deep")
    }
    const inner = payload ? depth : depth + 1
    if (typeof j === "string") return stringOfJson(j, limits, at)
    if (Array.isArray(j)) {
      open()
      return arr(j.map((x, i) => read(x, inner, at.child(i), false)))
    }
    if (!isJsonObject(j)) return fail(`not a self-describing form: ${describeJson(j)} (numbers are {"_num": "…"}, True is {"_tag": "True"}, None is {"_tag": "None"})`, at)
    const keys = Object.keys(j)
    const only = (...names: string[]) => keys.length === names.length && names.every((n) => Object.hasOwn(j, n))
    if (only("_num")) {
      const text = j["_num"]
      if (typeof text !== "string" || !isNormalizedNumber(text)) return fail(`"_num" must be a normalized number literal (spec §2), like "19.90" or "1e5"`, at, "haus-json-number")
      const issue = numberLimitIssue(text, limits)
      return issue === undefined ? num(text) : fail(issue.reason, at, issue.code)
    }
    if (only("_bytes")) {
      const hex = j["_bytes"]
      if (typeof hex !== "string" || !LOWER_HEX.test(hex)) return fail(`"_bytes" must be two lowercase hex digits per byte`, at, "haus-json-bytes")
      if (hex.length > limits.maxStringLength) fail(`byte string longer than ${limits.maxStringLength} characters`, at, "string-too-long")
      const out = new Uint8Array(hex.length / 2)
      for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(2 * i, 2 * i + 2), 16)
      return bytesValue(out)
    }
    if (only("_rec")) {
      const fields = j["_rec"]!
      if (!isJsonObject(fields)) return fail(`"_rec" must be an object`, at)
      open()
      return rec(new Map(Object.keys(fields).map((k) => [keyOfJson(k, limits, at), read(fields[k]!, inner, at.child(k), false)] as const)))
    }
    if (only("_tag") || only("_tag", "_args")) {
      const tag = j["_tag"]
      // The tag first, at its member, then "_args".
      if (typeof tag !== "string" || !TAG.test(tag)) return fail(`"_tag" must be a tag name ([A-Z][A-Za-z0-9_]*)`, at.child("_tag"), "invalid-tag")
      const tagIssue = tagLengthIssue(tag, limits)
      if (tagIssue !== undefined) fail(tagIssue.reason, at, tagIssue.code)
      if (!Object.hasOwn(j, "_args")) return variant(tag)
      const args = j["_args"]!
      if (!Array.isArray(args) || args.length === 0) return fail(`"_args" must be a non-empty array (a tag without arguments has no "_args")`, at)
      open()
      const single = args.length === 1 && isJsonObject(args[0]!) && Object.hasOwn(args[0], "_rec")
      return variant(tag, args.map((x, i) => read(x, depth + 1, at.child(i), single)))
    }
    const members = keys.slice(0, 5).map((k) => short(k)).join(", ")
    return fail(`not a self-describing form: an object with the members ${members}${keys.length > 5 ? ", …" : ""} (expected {"_num"}, {"_bytes"}, {"_rec"} or {"_tag"[, "_args"]})`, at)
  }
  return read(json, 0, place, false)
}

/** The envelope of self-describing JSON (spec §16.2): `{"_haus": 1, "_value": …}`. */
const envelope = (value: Json): JsonObject => jsonObject([["_haus", new JsonNumber(VERSION)], ["_value", value]])

/** The value in an envelope (spec §16.2), at `place`: the envelope adds no path segment. */
const unwrap = (json: Json, place: Place): Json => {
  const isEnvelope = isJsonObject(json) && Object.keys(json).length === 2 && Object.hasOwn(json, "_haus") && Object.hasOwn(json, "_value")
  if (!isEnvelope) {
    throw new HausDecodeError(`not self-describing JSON: expected the envelope {"_haus": 1, "_value": …}, found ${describeJson(json)}`, place.path(), "haus-json-form")
  }
  const version = json["_haus"]!
  if (!(version instanceof JsonNumber && version.text === VERSION)) {
    throw new HausDecodeError(`self-describing JSON of version ${describeJson(version)}: this reader reads version 1 ("_haus": 1)`, place.path(), "haus-json-version")
  }
  return json["_value"]!
}

/** The self-describing JSON of a value (spec §16.2), as a JSON value: the envelope. */
export const toHausJsonValue = (value: Value, limits: Partial<Limits> = {}): Json => envelope(hausJsonOf(value, withDefaults(limits), Place.root()))

/**
 * The self-describing JSON text of a value (spec §16.2),
 * `{"_haus":1,"_value":…}`: every haus value has one, and reading it gives
 * an equal value (§2). For carrying haus through systems that only store
 * JSON.
 */
export const toHausJson = (value: Value, limits: Partial<Limits> = {}): string => stringifyJson(toHausJsonValue(value, limits))

/**
 * A haus value from its self-describing JSON value (the envelope). Anything
 * that isn't exactly a self-describing form is a HausDecodeError. A parsed
 * value can't tell raw controls from escaped ones; `fromHausJson` rejects
 * raw ones.
 */
export const fromHausJsonValue = (json: Json, limits: Partial<Limits> = {}): Value => {
  const place = Place.root()
  return valueOfHausJson(unwrap(json, place), withDefaults(limits), place)
}

/**
 * Read self-describing JSON text (spec §16.2): exactly what `toHausJson`
 * writes. A text without the envelope, a `_haus` other than 1, a bare number,
 * `true`, `false`, `null`, a `_num` that isn't a normalized literal, an
 * object with other members, or a raw DEL, C1 or bidi control is an error.
 */
export const fromHausJson = (text: string, limits: Partial<Limits> = {}): Value => {
  const l = withDefaults(limits)
  const place = Place.root()
  return valueOfHausJson(unwrap(readJson(text, hausJsonDepthFor(l), START, true), place), l, place)
}

// ── JSON Lines (spec §16: a stream is one JSON text per value) ─

export interface JsonLinesOptions {
  /** Limits per value (spec §7); unspecified ones use the defaults. */
  readonly limits?: Partial<Limits>
  /** Most characters in one line (default 64 Mi, the stream limit of §7). */
  readonly maxLineLength?: number
  /**
   * Require a line feed after the last value. A stream that ends without one
   * is reported as truncated instead of yielding a possibly cut-off last
   * value. Recommended for network streams. Default: false.
   */
  readonly requireTerminator?: boolean
}

/**
 * The lines of a JSON Lines stream, each read as it is completed: `read`
 * gets a line's text, where it starts and its index. Memory stays bounded
 * by the longest line.
 */
export async function* readLines<T>(
  source: ChunkSource,
  options: JsonLinesOptions,
  read: (text: string, origin: Origin, index: number) => T,
): AsyncGenerator<T, void, undefined> {
  const maxLineLength = options.maxLineLength ?? 64 * 1024 * 1024
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })
  let pending: string[] = []
  let pendingLength = 0
  let origin: Origin = START
  let index = 0
  const tooLong = () => {
    throw new HausSyntaxError(`JSON Lines: line longer than ${maxLineLength} characters`, origin.offset, origin.line, origin.column, "value-too-long")
  }
  const line = (text: string): T => {
    // A byte order mark at the very start is ignored.
    const bom = origin.offset === 0 && text.charCodeAt(0) === 0xfeff
    const at = bom ? { offset: 1, line: 1, column: 2 } : origin
    const value = read(bom ? text.slice(1) : text, at, index++)
    origin = { offset: origin.offset + text.length + 1, line: origin.line + 1, column: 1 }
    return value
  }
  const push = function* (chunk: string): Generator<T> {
    let start = 0
    for (let nl = chunk.indexOf("\n"); nl >= 0; nl = chunk.indexOf("\n", start)) {
      if (pendingLength + nl - start > maxLineLength) tooLong()
      const text = pending.length === 0 ? chunk.slice(start, nl) : pending.join("") + chunk.slice(start, nl)
      pending = []
      pendingLength = 0
      start = nl + 1
      yield line(text)
    }
    if (start < chunk.length) {
      pending.push(chunk.slice(start))
      pendingLength += chunk.length - start
      if (pendingLength > maxLineLength) tooLong()
    }
  }
  for await (const chunk of chunks(source)) yield* push(typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true }))
  yield* push(decoder.decode())
  if (pendingLength > 0) {
    if (options.requireTerminator) {
      throw new HausSyntaxError("JSON Lines: the stream ended without a line feed after the last value (truncated?)", origin.offset, origin.line, origin.column, "stream-truncated")
    }
    yield line(pending.join(""))
  }
}

/**
 * Read a JSON Lines stream (one JSON text per line, spec §16) as JSON
 * values, each as soon as its line is complete. A fetch body, a Node stream
 * or any (async) iterable of text or UTF-8 chunks.
 */
export const parseJsonLines = (source: ChunkSource, options: JsonLinesOptions = {}): AsyncGenerator<Json, void, undefined> => {
  const limits = withJsonDefaults(options.limits ?? {})
  return readLines(source, options, (text, origin) => readJson(text, limits, origin))
}

/** Import a JSON Lines stream as haus values, without a schema (§16.1). Errors name the line's index. */
export const importJsonLines = (source: ChunkSource, options: JsonLinesOptions = {}): AsyncGenerator<Value, void, undefined> => {
  const limits = withDefaults(options.limits ?? {})
  return readLines(source, options, (text, origin, i) => imported(readJson(text, limits, origin), limits, 0, Place.root(i)))
}

/** Read a JSON Lines stream of self-describing JSON (§16.2), an envelope per line, as haus values. Errors name the line's index. */
export const fromHausJsonLines = (source: ChunkSource, options: JsonLinesOptions = {}): AsyncGenerator<Value, void, undefined> => {
  const limits = withDefaults(options.limits ?? {})
  return readLines(source, options, (text, origin, i) => {
    const place = Place.root(i)
    return valueOfHausJson(unwrap(readJson(text, hausJsonDepthFor(limits), origin, true), place), limits, place)
  })
}

/** Write values as JSON Lines of their self-describing JSON (§16.2): an envelope per line, each ending in a line feed. */
export async function* toHausJsonLines(values: AsyncIterable<Value> | Iterable<Value>, limits: Partial<Limits> = {}): AsyncGenerator<string, void, undefined> {
  const l = withDefaults(limits)
  let i = 0
  for await (const v of values) yield stringifyJson(envelope(hausJsonOf(v, l, Place.root(i++)))) + "\n"
}
