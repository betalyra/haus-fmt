/**
 * Inputs for the JSON fuzzer (json.ts, spec §16): JSON text as data (`J`),
 * written with varied formatting and escapes, and generated for each mapping:
 *
 * - plain JSON (§16.3) for a resolved type of the schema suite, mostly what
 *   the type reads, plus near misses: the wrong kind, extra and missing
 *   members, `_tag` games, `null` against the tagged `Maybe`, base64 and
 *   integer strings at their edges, unknown tags with members or `args`;
 * - lossless JSON (§16.2) of any haus value, and mutations of it;
 * - any JSON (§16.1): numbers, strings, duplicate names, lone surrogates,
 *   nesting at the limits.
 *
 * Also a lenient JSON reader (duplicate names and lone surrogates kept) to
 * compare written JSON as data and to shrink inputs.
 */
import { parseAll, type Value } from "../../typescript/packages/haus/dist/index.js"
import { Rng, value as hausValue } from "./generate.ts"
import {
  BIG_INTS, bits, decimalLiteral, exact, EXTRA_KEYS, F32, F64, randomFloat, RANGES, shuffle, TIME_TYPES, timeText,
  type Case, type Env, type RecordType, type Type,
} from "./schema-gen.ts"

// ── JSON as data ─────────────────────────────────────────────

/** A JSON number, kept as written. */
export class Num {
  readonly text: string
  constructor(text: string) {
    this.text = text
  }
}
/** A JSON object, its members in order (names may repeat). */
export class Obj {
  readonly members: readonly (readonly [string, J])[]
  constructor(members: readonly (readonly [string, J])[]) {
    this.members = members
  }
}
export type J = null | boolean | string | Num | readonly J[] | Obj

const obj = (...members: (readonly [string, J])[]) => new Obj(members)
const num = (text: string) => new Num(text)

// ── writing ──────────────────────────────────────────────────

function u4(code: number, r?: Rng): string {
  const h = code.toString(16).padStart(4, "0")
  return "\\u" + (r?.chance(0.3) ? h.toUpperCase() : h)
}

const SHORT: Readonly<Record<number, string>> = { 8: "\\b", 9: "\\t", 10: "\\n", 12: "\\f", 13: "\\r" }

/** A JSON string literal: with `r`, some characters escaped that needn't be. Lone surrogates are always escaped. */
export function writeString(s: string, r?: Rng): string {
  let out = '"'
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {
      out += r?.chance(0.15) ? u4(c, r) + u4(s.charCodeAt(i + 1), r) : s[i]! + s[i + 1]!
      i++
    } else if (c >= 0xd800 && c <= 0xdfff) out += u4(c, r)
    else if (c === 0x22) out += '\\"'
    else if (c === 0x5c) out += "\\\\"
    else if (c < 0x20) out += SHORT[c] !== undefined && !r?.chance(0.3) ? SHORT[c] : u4(c, r)
    else if (c === 0x2f && r?.chance(0.2)) out += "\\/"
    else if (r?.chance(0.03)) out += u4(c, r)
    else out += s[i]
  }
  return out + '"'
}

const WS = ["", "", "", " ", " ", "\n", "\t", "\r\n", "  ", "\n  "]
const ws = (r?: Rng) => (r ? r.pick(WS) : "")

/** JSON text: compact without `r`, with varied whitespace and escapes with it. */
export function writeJ(j: J, r?: Rng): string {
  if (j === null) return "null"
  if (j === true) return "true"
  if (j === false) return "false"
  if (typeof j === "string") return writeString(j, r)
  if (j instanceof Num) return j.text
  if (j instanceof Obj) {
    if (j.members.length === 0) return "{" + ws(r) + "}"
    return "{" + ws(r) + j.members.map(([k, v]) => writeString(k, r) + ws(r) + ":" + ws(r) + writeJ(v, r)).join(ws(r) + "," + ws(r)) + ws(r) + "}"
  }
  if (j.length === 0) return "[" + ws(r) + "]"
  return "[" + ws(r) + j.map((x) => writeJ(x, r)).join(ws(r) + "," + ws(r)) + ws(r) + "]"
}

// ── reading (leniently) ──────────────────────────────────────

const NUMBER = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/

/**
 * JSON text as data, or undefined if it isn't JSON (RFC 8259). Lenient
 * where I-JSON is strict: duplicate names and lone surrogates are kept, so
 * that they can be compared and shrunk. No byte order mark.
 */
export function parseJ(text: string): J | undefined {
  let i = 0
  const skip = () => {
    while (i < text.length && " \t\n\r".includes(text[i]!)) i++
  }
  const fail = (): never => {
    throw new SyntaxError()
  }
  const str = (): string => {
    i++ // "
    let out = ""
    for (;;) {
      if (i >= text.length) fail()
      const c = text[i]!
      if (c === '"') return (i++, out)
      if (c.charCodeAt(0) < 0x20) fail()
      if (c !== "\\") {
        out += c
        i++
        continue
      }
      const e = text[i + 1]
      const simple: Record<string, string> = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" }
      if (e !== undefined && simple[e] !== undefined) {
        out += simple[e]
        i += 2
      } else if (e === "u" && /^[0-9a-fA-F]{4}$/.test(text.slice(i + 2, i + 6))) {
        out += String.fromCharCode(parseInt(text.slice(i + 2, i + 6), 16))
        i += 6
      } else fail()
    }
  }
  const val = (depth: number): J => {
    if (depth > 5000) fail()
    skip()
    const c = text[i]
    if (c === "{") {
      i++
      const members: [string, J][] = []
      skip()
      if (text[i] === "}") return (i++, new Obj(members))
      for (;;) {
        skip()
        if (text[i] !== '"') fail()
        const k = str()
        skip()
        if (text[i] !== ":") fail()
        i++
        members.push([k, val(depth + 1)])
        skip()
        if (text[i] === ",") i++
        else if (text[i] === "}") return (i++, new Obj(members))
        else fail()
      }
    }
    if (c === "[") {
      i++
      const items: J[] = []
      skip()
      if (text[i] === "]") return (i++, items)
      for (;;) {
        items.push(val(depth + 1))
        skip()
        if (text[i] === ",") i++
        else if (text[i] === "]") return (i++, items)
        else fail()
      }
    }
    if (c === '"') return str()
    for (const [w, v] of [["true", true], ["false", false], ["null", null]] as const) {
      if (text.startsWith(w, i)) return (i += w.length, v)
    }
    const m = NUMBER.exec(text.slice(i, i + 20000))
    if (!m) fail()
    i += m![0].length
    return new Num(m![0])
  }
  try {
    const j = val(0)
    skip()
    return i === text.length ? j : undefined
  } catch (e) {
    if (e instanceof SyntaxError || e instanceof RangeError) return undefined
    throw e
  }
}

/** A string that two JSON values share exactly when they are the same data: members sorted, numbers by their text. */
export function normJ(j: J): string {
  if (j === null || typeof j === "boolean") return String(j)
  if (typeof j === "string") return JSON.stringify(j)
  if (j instanceof Num) return "#" + j.text
  if (j instanceof Obj) {
    const ms = j.members.map(([k, v]) => JSON.stringify(k) + ":" + normJ(v)).sort()
    return "{" + ms.join(",") + "}"
  }
  return "[" + j.map(normJ).join(",") + "]"
}

/** JSON values one step smaller, for shrinking. */
export function* smallerJ(j: J): IterableIterator<J> {
  if (typeof j === "string") {
    const cs = [...j]
    if (cs.length > 0) {
      yield ""
      yield cs.slice(0, cs.length >> 1).join("")
      yield cs.slice(cs.length >> 1).join("")
      for (let i = 0; i < cs.length && i < 40; i++) yield [...cs.slice(0, i), ...cs.slice(i + 1)].join("")
    }
    return
  }
  if (j instanceof Num) {
    if (j.text !== "0") yield num("0")
    if (j.text !== "1") yield num("1")
    return
  }
  if (j instanceof Obj) {
    const ms = j.members
    for (const [, v] of ms) yield v
    for (let i = 0; i < ms.length; i++) yield new Obj(ms.filter((_, k) => k !== i))
    for (let i = 0; i < ms.length; i++) for (const x of smallerJ(ms[i]![1])) yield new Obj(ms.map((m, k) => (k === i ? [m[0], x] as const : m)))
    return
  }
  if (Array.isArray(j)) {
    yield* j
    for (let i = 0; i < j.length; i++) yield j.filter((_, k) => k !== i)
    for (let i = 0; i < j.length; i++) for (const x of smallerJ(j[i]!)) yield j.map((y, k) => (k === i ? x : y))
  }
}

// ── leaves ───────────────────────────────────────────────────

const STRING_PARTS = ["a", "hello", " ", "é", "e\u0301", "😀", "中文", "\u{10FFFF}", "\n", "\t", "\r", '"', "\\", "/", "\u0000", "\u001b", "\u001f",
  "\u007f", "\u0085", "\u2028", "\u2029", "\u202e", "\ufeff", "\uffff", "\ufffd", "<redacted>", "_tag", "Some", "null", "${x}", "'", "\b", "\f"]

/** A string; lone surrogates sometimes (I-JSON rejects them). */
export function jsonString(r: Rng, lone = 0.01): string {
  if (r.chance(0.01)) return "x".repeat(r.pick([1000, 5000]))
  let s = Array.from({ length: r.int(6) }, () => r.pick(STRING_PARTS)).join("")
  if (r.chance(lone)) {
    const at = r.int(s.length + 1)
    s = s.slice(0, at) + r.pick(["\ud800", "\udbff", "\udc00", "\udfff", "\ude00\ud83d"]) + s.slice(at)
  }
  return s
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

export function base64(bytes: readonly number[]): string {
  let out = ""
  for (let i = 0; i < bytes.length; i += 3) {
    const [a, b, c] = [bytes[i]!, bytes[i + 1], bytes[i + 2]]
    const n = (a << 16) | ((b ?? 0) << 8) | (c ?? 0)
    out += B64[(n >> 18) & 63]! + B64[(n >> 12) & 63]! + (b === undefined ? "=" : B64[(n >> 6) & 63]!) + (c === undefined ? "=" : B64[n & 63]!)
  }
  return out
}

function randomBytes(r: Rng): number[] {
  const n = r.pick([0, 0, 1, 2, 3, 4, 5, 8, 33])
  return Array.from({ length: n }, () => (r.chance(0.2) ? r.pick([0, 0xff, 0xfb, 0x3e, 0x3f]) : r.int(256)))
}

/** Base64 that isn't the canonical form, or isn't base64. */
function badBase64(r: Rng): string {
  const good = base64(randomBytes(r).concat([r.int(256)]))
  switch (r.int(10)) {
    case 0: return good.replace(/=+$/, "") // no padding
    case 1: return good.replace(/\+/g, "-").replace(/\//g, "_") + (good.includes("+") || good.includes("/") ? "" : "-_8=") // URL alphabet
    case 2: return good.slice(0, 2) + r.pick([" ", "\n", "\r\n", "\t"]) + good.slice(2) // whitespace
    case 3: return r.pick(["CzR=", "CzQ9", "AB==", "AAB=", "QR==", "QUJ=", "/w==", "//8="]) // pad bits (only some zero)
    case 4: return good + r.pick(["A", "AB", "ABC", "="])
    case 5: return r.pick(["=", "==", "===", "====", "A===", "AA=A", "A=AA", "=AAA"])
    case 6: return good.slice(0, 1) + "=" + good.slice(2)
    case 7: return good + "\u0000"
    case 8: return good.toLowerCase() === good ? good + "é" : good.toLowerCase()
    default: return r.pick(["0b34", "0x0b34", "x\"0b34\"", "CzQ=\n", "Cz Q=", "-_8="])
  }
}

const big = (n: number | bigint) => BigInt(n)

/** An integer for a type: in range, at its edges, or just past them. */
function integerValue(r: Rng, name: string): bigint {
  const range = RANGES[name]
  const x = r.next()
  if (x < 0.3 && range) return r.pick([range[0], range[1], range[0] - 1n, range[1] + 1n, range[0] + 1n, range[1] - 1n])
  if (x < 0.5 && range) return range[0] + bits(r, 70) % (range[1] - range[0] + 1n)
  if (x < 0.7) return big(r.int(2000) - 1000)
  if (x < 0.85) return r.pick(BIG_INTS)
  return (r.chance(0.5) ? -1n : 1n) * bits(r, r.pick([8, 16, 31, 32, 53, 63, 64, 65, 100, 300, 3300, 3330]))
}

/** Numbers that aren't integers by spelling, or aren't JSON. */
const NOT_INTEGER_NUMS = ["1.0", "1e3", "1E0", "0.0", "-0.0", "0e0", "1.5", "-1e-1", "1e-0", "1E+2", "10e-1", "01", "+1", "-", ".5", "1.", "0x10", "Infinity", "NaN", "1_000"]

/** A string that isn't an integer as plain JSON reads one (`-?(0|[1-9][0-9]*)`), or is one at the edges. */
const INTEGER_STRINGS = ["+1", "007", "00", "-00", "1e3", "1E3", " 1", "1 ", "0x10", "0b1", "1_000", "", "-", "--1", "1.0", "1.", ".1", "\uff11", "٣",
  "-0", "0", "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "18446744073709551615", "18446744073709551616",
  "1" + "0".repeat(999), "1" + "0".repeat(1000), "-1" + "0".repeat(999), "1" + "0".repeat(1203), "9".repeat(1204), "1" + "0".repeat(1210), "NaN", "Infinity"]

/** A float in JSON spelling: the float exactly, halfway to the next one, or a hair either side. */
function floatText(r: Rng, name: string): string {
  const f = name === "Float32" ? F32 : F64
  const neg = r.chance(0.3)
  const x = r.next()
  let text: string
  if (x < 0.1) {
    text = r.pick(["0", "-0", "0.0", "-0.0", "0e5", "-0e-3", "1e-400", "-1e-400", "1e-6144", "1e400", "-1e309", "1e6144", "1e6145", "1e39", "-3.5e38", "1e38",
      "1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308", "3.4028235e38", "3.4028236e38", "5e-324", "2.4703282292062328e-324",
      "2.4703282292062327e-324", "1e-45", "7e-46", "0.1", "19.90", "9007199254740993", "16777217", "1" + "0".repeat(999), "0." + "0".repeat(997) + "1",
      "1." + "0".repeat(998), "1e-1074", "4.9406564584124654e-324", "1.401298464324817e-45"])
    return text
  }
  if (x < 0.15) return (neg ? "-" : "") + bits(r, r.pick([24, 25, 53, 54, 64, 128, 1024, 1100])).toString()
  const { m, e } = randomFloat(r, f)
  if (r.chance(0.35)) {
    const { digits, exp } = exact(m, e)
    text = decimalLiteral(r, digits, exp, neg)
  } else {
    const half = exact(2n * m + 1n, e - 1)
    const nudge = r.int(3)
    if (nudge === 0) text = decimalLiteral(r, half.digits, half.exp, neg)
    else {
      const k = r.pick([1, 3, 20, 40])
      text = decimalLiteral(r, half.digits * 10n ** big(k) + (nudge === 1 ? 1n : -1n), half.exp - k, neg)
    }
  }
  // JSON allows `E` and `e+`.
  if (r.chance(0.2)) text = text.replace("e", r.pick(["E", "e+", "E+"])).replace(/[eE]\+-/, "e-")
  return text
}

/** A decimal as JSON number text: scale, exponents and zeros at their edges. */
function decimalText(r: Rng): string {
  const sign = r.chance(0.3) ? "-" : ""
  const ds = () => (1 + r.int(9)) + Array.from({ length: r.int(8) }, () => r.int(10)).join("")
  switch (r.int(8)) {
    case 0: return sign + r.pick(["0", "0.0", "0.00", "0e0", "0e5", "0e-3", "0.0e1", "0E+0", "0e-0", "0e+00"])
    case 1: return sign + ds()
    case 2: return sign + r.int(100) + "." + Array.from({ length: 1 + r.int(5) }, () => r.int(10)).join("") + "0".repeat(r.int(3))
    case 3: return sign + ds() + (r.chance(0.4) ? "." + r.int(100) : "") + r.pick(["e", "E", "e+", "E-", "e-"]) + r.pick(["0", "00", "05", "1", "07", "6144", "6145", "06144", String(r.int(400))])
    case 4: return sign + "19.90"
    case 5: return sign + "1" + "0".repeat(r.pick([20, 998, 999, 1000]))
    case 6: return sign + "0." + "0".repeat(r.int(30)) + ds()
    default: return sign + bits(r, r.pick([8, 64, 200])).toString()
  }
}

const NOT_DECIMAL_STRINGS = ["0xFF", "1_000", ".5", "5.", "+1", "01", "NaN", "Infinity", "-Infinity", " 1", "1 ", "1e", "", "-", "1.5e3.2", "1,5", "19,90", "0b1", "１", "1e+-1"]

// ── lossless JSON (§16.2) ────────────────────────────────────

/** The lossless form of a value: the mapping itself, for generating inputs. */
export function losslessJ(v: Value): J {
  switch (v.kind) {
    case "number": return obj(["num", v.text])
    case "string": return v.value
    case "bytes": return obj(["bytes", [...v.bytes].map((b) => b.toString(16).padStart(2, "0")).join("")])
    case "array": return v.items.map(losslessJ)
    case "record": return obj(["rec", new Obj([...v.fields].map(([k, x]) => [k, losslessJ(x)] as const))])
    case "variant": return v.args.length ? obj(["tag", v.tag], ["args", v.args.map(losslessJ)]) : obj(["tag", v.tag])
  }
}

/** A haus value from haus text, if the text is exactly one value. */
export function single(text: string): Value | undefined {
  try {
    const vs = parseAll(text)
    return vs.length === 1 ? vs[0] : undefined
  } catch {
    return undefined
  }
}

/** A random haus value (generate.ts), as lossless JSON. */
export function randomLossless(r: Rng, depth = 0): J {
  for (let i = 0; i < 5; i++) {
    const v = single(hausValue(r, depth))
    if (v) return losslessJ(v)
  }
  return obj(["num", "1"])
}

/** Lossless forms that are near misses, or not lossless forms at all. */
export function badLosslessJ(r: Rng): J {
  const ok = () => randomLossless(r, 3)
  return r.pick<() => J>([
    () => num(r.pick(["1", "0", "-1.5"])), () => true, () => false, () => null, () => obj(),
    () => obj(["num", r.pick(["01", "1E5", "1e+5", "+1", "1e05", "0x10", "1_0", "-0e0", "0e-0", "1e-0", "1.", ".5", "", " 1", "NaN", "1e6145", "1e-6145",
      "1" + "0".repeat(1000), "-1" + "0".repeat(1000), "1" + "0".repeat(1210), (2n ** 3988n).toString(), (2n ** 3989n).toString(), (2n ** 3988n - 1n).toString(),
      "1." + "0".repeat(999), "1e6144", "-0", "0.0", "1.50", "1e2"])]),
    () => obj(["num", num("1")]), () => obj(["num", "1"], ["x", num("2")]), () => obj(["num", "1"], ["num", "2"]),
    () => obj(["bytes", r.pick(["0B34", "0b3", "", "0b 34", "0x0b", "zz", "0b340", "ÿ"])]), () => obj(["bytes", ["0b"]]),
    () => obj(["tag", r.pick(["circle", "", "T_1", "_T", "Tä", "T-1", "T x", "1T", "None", "Some", "Ok", "\u0000"])]),
    () => obj(["tag", "T"], ["args", r.pick<J>([[], null, num("5"), obj(), "x"])]), () => obj(["tag", "T"], ["args", [ok()]], ["x", null]),
    () => obj(["tag", num("1")]), () => obj(["args", [ok()]]), () => obj(["tag", "T"], ["tag", "U"]),
    () => obj(["rec", obj(["a", num("1")])]), () => obj(["rec", [ok()]]), () => obj(["rec", obj()], ["tag", "X"]),
    () => obj(["rec", obj(["a", ok()], ["a", ok()])]), () => obj(["rec", null]),
    () => obj(["Num", "1"]), () => obj(["_tag", "None"]),
  ])()
}

/** A path into a JSON value, and a way to replace what is there. */
function nodes(j: J, out: { j: J; set: (x: J) => J }[] = [], set: (x: J) => J = (x) => x): { j: J; set: (x: J) => J }[] {
  out.push({ j, set })
  if (j instanceof Obj) {
    j.members.forEach(([k, v], i) => nodes(v, out, (x) => set(new Obj(j.members.map((m, n) => (n === i ? [k, x] as const : m))))))
  } else if (Array.isArray(j)) {
    j.forEach((v, i) => nodes(v, out, (x) => set(j.map((y, n) => (n === i ? x : y)))))
  }
  return out
}

/** JSON with one node changed: replaced, given an extra, repeated or missing member, a number respelled, a string given a lone surrogate. */
export function mutateJ(r: Rng, j: J, wrong: (r: Rng) => J): J {
  const all = nodes(j)
  const { j: at, set } = r.chance(0.3) ? all[0]! : r.pick(all)
  if (at instanceof Obj && r.chance(0.7)) {
    const ms = at.members
    switch (r.int(8)) {
      case 0: if (ms.length) return set(new Obj([...ms, [r.pick(ms)[0], wrong(r)]])) // duplicate name
        break
      case 1: if (ms.length) return set(new Obj(ms.filter((_, i) => i !== r.int(ms.length))))
        break
      case 2: return set(new Obj([...ms, [r.pick(["x", "_tag", "value", "values", "args", "tag", "", "_Tag", "__proto__"]), wrong(r)]]))
      case 3: return set(new Obj(ms.map(([k, v]) => [k === "_tag" ? r.pick(["tag", "_TAG", "_tag "]) : k, v] as const)))
      case 4: return set(new Obj(ms.map(([k, v]) => [k, k === "_tag" || k === "tag" ? r.pick<J>(["", "x", "None", "Some", "Unknown", num("1"), null, ["A"], "Bad Tag", "lower"]) : v] as const)))
      case 5: return set(new Obj([...ms].reverse()))
      case 6: return set(new Obj(ms.map(([k, v]) => [k === "value" ? "values" : k === "values" ? "value" : k, v] as const)))
      default: return set(ms.length ? new Obj([...ms, ...ms.slice(0, 1)]) : obj(["_tag", "None"]))
    }
  }
  if (at instanceof Num && r.chance(0.7)) {
    const t = at.text
    return set(num(r.pick([t + ".0", t + "e0", t.replace(/^-/, "") === t ? "-" + t : t.slice(1), t + "0", "1e400", t.replace(/e/i, "E+"), "-0", t.length > 1 ? t.slice(0, -1) : "0"])))
  }
  if (typeof at === "string" && r.chance(0.6)) {
    return set(r.pick([at + "\ud800", "\udfff" + at, at.toLowerCase(), at.toUpperCase(), at + " ", " " + at, at.slice(1), at + "=", at + "\u0000", num(/^-?[0-9]+$/.test(at) ? at : "1")]))
  }
  if (Array.isArray(at) && at.length && r.chance(0.6)) {
    return set(r.chance(0.5) ? at.slice(1) : [...at, at[0]!])
  }
  return set(wrong(r))
}

// ── text mutations ───────────────────────────────────────────

const SNIPPETS = [",", "]", "}", "{", "[", '"', "\\", ":", "null", "0", "-", "e", ".", "\ufeff", "\u0000", " ", "\u00a0", "/*x*/", "//", "\\ud800", "\\u",
  "NaN", "\t", "\n", "\f", "'", "1", "true", "\\x", "\u2028", "\u001f"]

/** One to three edits of JSON text: delete, insert a snippet, duplicate a slice, cut short. */
export function mutateText(r: Rng, text: string): string {
  let cs = [...text]
  for (let n = 1 + r.int(3); n > 0; n--) {
    const at = r.int(cs.length + 1)
    switch (r.int(5)) {
      case 0: cs = [...cs.slice(0, at), ...cs.slice(at + 1 + r.int(3))]; break
      case 1:
      case 2: cs = [...cs.slice(0, at), ...r.pick(SNIPPETS), ...cs.slice(at)]; break
      case 3: {
        const end = Math.min(cs.length, at + 1 + r.int(8))
        cs = [...cs.slice(0, end), ...cs.slice(at, end), ...cs.slice(end)]
        break
      }
      default: cs = cs.slice(0, at)
    }
  }
  return cs.join("")
}

/** JSON text for `j`: varied formatting, sometimes a byte order mark or trailing whitespace, sometimes edited. */
export function textOf(r: Rng, j: J, mutate: number): string {
  let text = (r.chance(0.03) ? "\ufeff" : "") + (r.chance(0.1) ? r.pick([" ", "\n", "\t", "\r\n"]) : "") + writeJ(j, r.chance(0.6) ? r : undefined) +
    (r.chance(0.1) ? r.pick([" ", "\n", "\r\n", "\n\n"]) : "")
  if (r.chance(mutate)) text = mutateText(r, text)
  return text
}

// ── any JSON (§16.1) ─────────────────────────────────────────

const JSON_NUMBERS = ["0", "-0", "0.0", "-0.0", "1E+05", "1e5", "1e-5", "1E-0", "1e00", "1e+0", "19.90", "0.000", "1e6144", "1e-6144", "1e6145", "1e-6145",
  "1" + "0".repeat(999), "1" + "0".repeat(1000), "-1" + "0".repeat(999), "1." + "0".repeat(998), "1." + "0".repeat(1000), "123456789012345678901234567890",
  "9007199254740993", "1e400", "2.5e-324", "0e99999", "1e99999999999999999999"]

/** A JSON number: random or at an edge. */
function anyNumber(r: Rng): string {
  if (r.chance(0.3)) return r.pick(JSON_NUMBERS)
  const sign = r.chance(0.2) ? "-" : ""
  const int = r.chance(0.3) ? "0" : String(1 + r.int(9)) + Array.from({ length: r.int(12) }, () => r.int(10)).join("")
  const frac = r.chance(0.3) ? "." + Array.from({ length: 1 + r.int(6) }, () => r.int(10)).join("") : ""
  const exp = r.chance(0.2) ? r.pick(["e", "E"]) + r.pick(["", "+", "-"]) + r.pick(["0", "00", "5", "05", String(r.int(500))]) : ""
  return sign + int + frac + exp
}

const KEYS = ["a", "b", "id", "x", "", "_tag", "tag", "num", "rec", "bytes", "args", "value", "values", "__proto__", "constructor", "café", "😀", "\uFF61", "\uE000",
  "\u0000", "a b", "None"]

/** Any JSON value, `depth` levels down. */
export function anyJ(r: Rng, depth = 0): J {
  const leaf = depth > 4 || r.chance(0.4)
  switch (r.int(leaf ? 5 : 7)) {
    case 0: return num(anyNumber(r))
    case 1: return jsonString(r)
    case 2: return r.pick([true, false, null])
    case 3: return r.chance(0.3) ? r.pick(["", "None", "Some"]) : num(anyNumber(r))
    case 4: return jsonString(r, 0.03)
    case 5: return Array.from({ length: r.pick([0, 1, 2, 3, 5]) }, () => anyJ(r, depth + 1))
    default: {
      const ks = shuffle(r, [...KEYS]).slice(0, r.pick([0, 1, 2, 3, 4]))
      if (ks.length && r.chance(0.05)) ks.push(ks[0]!) // a duplicate name
      return new Obj(ks.map((k) => [k, anyJ(r, depth + 1)] as const))
    }
  }
}

/** JSON nesting `n` levels: arrays, objects or both. */
export function nested(r: Rng, n: number, inner: J = num("1")): J {
  let j = inner
  const shape = r.int(3)
  for (let i = 0; i < n; i++) j = shape === 0 || (shape === 2 && r.chance(0.5)) ? [j] : obj(["a", j])
  return j
}

/** Text that isn't JSON, or is at its edges. */
export const NOT_JSON = ["", " ", "\ufeff", "\ufeff\ufeff1", "1 2", "[1,]", "[,1]", "{\"a\":1,}", "{a:1}", "{'a':1}", "NaN", "Infinity", "-Infinity", "01", "+1", ".5",
  "1.", "-", "1e", "1e+", "TRUE", "nul", "\"\\x\"", "\"\\u12\"", "\"\\u{41}\"", "\"a\nb\"", "\"\u0000\"", "[1]]", "[[1]", "{\"a\"}", "{\"a\" 1}", "// x\n1",
  "/* x */1", "1 // x", "\u00a01", "\f1", "1\u00a0", "\"\\ud800\\udc00\"", "\"\\udc00\\ud800\"", "\"\\uD83D\\uDE00\"", "[\"\\ud800\"]", "\"\\ud800x\"",
  "\"\\/\"", "\u20281", "0x10", "1_000", "[1\n,\n2]", "\r\n[]\r\n", "{\"a\":1,\"a\":1}", "{\"\":1,\"\":2}", "\"\\u0000\""]

// ── plain JSON (§16.3) ───────────────────────────────────────

export interface PlainOpts {
  readonly miss: number
  readonly maxDepth: number
  readonly deep: number
}

/** A value of the wrong kind for most types. */
const WRONG: readonly J[] = [num("0"), num("1.5"), "x", "", [], [num("1")], obj(), obj(["a", num("1")]), null, true, false, obj(["_tag", "None"]),
  obj(["_tag", "Some"], ["value", num("1")]), obj(["num", "1"]), "AA==", "True", "None", obj(["tag", "None"])]
export const wrongJ = (r: Rng): J => r.pick(WRONG)

type Maybe = { readonly maybe: Type }
type Variant = { readonly variant: { readonly closed: boolean; readonly cases: readonly Case[] } }

/** Plain JSON for the resolved types of one schema file. */
export class PlainGen {
  private readonly nullable = new Map<object, boolean>()
  private readonly minimals = new Map<string, J | undefined>()
  readonly env: Env
  constructor(env: Env) {
    this.env = env
  }

  /** Through names and `Secret`. */
  private resolve(t: Type): Type {
    for (let i = 0; i < 1000 && ("ref" in t || "secret" in t); i++) t = "ref" in t ? this.env.get(t.ref)! : t.secret
    return t
  }

  /** Whether a type's JSON can be `null` (spec §16.3). */
  canBeNull(t: Type): boolean {
    const x = this.resolve(t)
    return "maybe" in x && this.usesNull(x)
  }

  /** Whether this `Maybe` writes `None` as `null`: it doesn't reach itself through Maybe, Secret and names, and its inner JSON can't be null. */
  usesNull(m: Maybe): boolean {
    const known = this.nullable.get(m)
    if (known !== undefined) return known
    this.nullable.set(m, false)
    const seen = new Set<object>()
    let t = m.maybe
    let loops = false
    for (let i = 0; i < 1000; i++) {
      if ("ref" in t) t = this.env.get(t.ref)!
      else if ("secret" in t) t = t.secret
      else if ("maybe" in t) {
        if (t === m) {
          loops = true
          break
        }
        if (seen.has(t)) break
        seen.add(t)
        t = t.maybe
      } else break
    }
    const r = !loops && !this.canBeNull(m.maybe)
    this.nullable.set(m, r)
    return r
  }

  /** Whether a variant is written as a bare string: closed, every case without payload. */
  private enumLike(v: Variant["variant"]): boolean {
    return v.closed && v.cases.length > 0 && v.cases.every((k) => k.payload === "none")
  }

  value(r: Rng, t: Type, opts: PlainOpts): J {
    return this.gen(r, t, opts, 0, opts.deep)
  }

  private gen(r: Rng, t: Type, c: PlainOpts, depth: number, deep: number): J {
    if (depth > c.maxDepth && deep <= 0) {
      const m = this.minimal(t)
      if (m !== undefined) return m
    }
    if (r.chance(c.miss * 0.15)) return wrongJ(r)
    const miss = r.chance(c.miss)
    if ("builtin" in t) return this.builtin(r, t.builtin, miss, depth)
    if ("time" in t) {
      if (miss) return r.pick<() => J>([() => timeText(r, r.pick(TIME_TYPES)), () => `${t.time}("${timeText(r, t.time)}")`, () => num("1"), () => obj(["_tag", t.time]), () => timeText(r, t.time) + " "])()
      return timeText(r, t.time)
    }
    if ("ref" in t) return this.gen(r, this.env.get(t.ref)!, c, depth, deep)
    if ("secret" in t) return this.gen(r, t.secret, c, depth, deep)
    if ("maybe" in t) {
      const inner = () => this.gen(r, t.maybe, c, depth + 1, deep - 1)
      if (this.usesNull(t)) {
        if (miss) return r.pick<() => J>([() => obj(["_tag", "None"]), () => obj(["_tag", "Some"], ["value", inner()]), () => [inner()], () => obj(["value", inner()]), () => "None"])()
        if (deep <= 0 && r.chance(0.3)) return null
        return inner()
      }
      if (miss) {
        return r.pick<() => J>([() => null, inner, () => obj(["_tag", "Some"]), () => obj(["_tag", "None"], ["value", num("1")]), () => obj(["_tag", "Some"], ["value", inner()], ["x", num("1")]),
          () => obj(["_tag", "Some"], ["values", [inner()]]), () => obj(["_tag", r.pick(["none", "some", "Nothing", "Just"])]), () => obj(["_tag", "Some"], ["args", [randomLossless(r)]]),
          () => obj(["_tag", "None"], ["_tag", "None"]), () => "None"])()
      }
      if (deep <= 0 && r.chance(0.3)) return obj(["_tag", "None"])
      return r.chance(0.5) ? obj(["_tag", "Some"], ["value", inner()]) : obj(["value", inner()], ["_tag", "Some"])
    }
    if ("array" in t) {
      if (miss) return r.pick<() => J>([() => obj(["a", this.gen(r, t.array, c, depth + 1, 0)]), () => this.gen(r, t.array, c, depth + 1, 0), () => null, () => "[]"])()
      const n = deep > 0 ? 1 + r.int(2) : r.pick([0, 0, 1, 1, 2, 3, 5])
      const spine = r.int(n)
      return Array.from({ length: n }, (_, i) => this.gen(r, t.array, c, depth + 1, i === spine ? deep - 1 : 0))
    }
    if ("map" in t) {
      if (miss) return r.pick<() => J>([() => [this.gen(r, t.map, c, depth + 1, 0)], () => null, () => obj(["a", this.gen(r, t.map, c, depth + 1, 0)], ["a", this.gen(r, t.map, c, depth + 1, 0)])])()
      const keys = shuffle(r, [...EXTRA_KEYS, "a", "b", "id", "name", "_tag", "value", "\ud800"]).slice(0, deep > 0 ? 1 : r.pick([0, 1, 2, 3, 5]))
      const spine = r.int(keys.length)
      return new Obj(keys.map((k, i) => [k, this.gen(r, t.map, c, depth + 1, i === spine ? deep - 1 : 0)] as const))
    }
    if ("record" in t) {
      if (miss && r.chance(0.25)) return r.pick<() => J>([() => [], () => [this.fields(r, t.record, c, depth + 1, 0, false)], () => obj(["rec", this.fields(r, t.record, c, depth + 1, 0, false)])])()
      return this.fields(r, t.record, c, depth, deep, miss)
    }
    return this.variant(r, t.variant, c, depth, deep, miss)
  }

  private builtin(r: Rng, name: string, miss: boolean, depth: number): J {
    switch (name) {
      case "String": return miss ? r.pick<() => J>([() => num("1"), () => null, () => [jsonString(r)], () => jsonString(r, 1), () => true])() : jsonString(r)
      case "Bytes": return miss ? (r.chance(0.8) ? badBase64(r) : r.pick<J>([[num("0")], num("0"), null, obj(["bytes", "00"])])) : base64(randomBytes(r))
      case "Bool": return miss ? r.pick<J>(["true", "True", "False", num("1"), num("0"), null, obj(["_tag", "True"]), "false"]) : r.chance(0.5)
      case "Decimal": return miss ? (r.chance(0.7) ? r.pick(NOT_DECIMAL_STRINGS) : num(decimalText(r))) : decimalText(r)
      case "Float32":
      case "Float64": {
        if (miss) return r.pick<J>(["nan", "-NaN", "+Infinity", "inf", "Inf", "1.5", "NegInfinity", "-0", "0", num("1e400"), num("-1e400"), num("1e99999"), null, true, "infinity", " NaN"])
        if (r.chance(0.06)) return r.pick(["NaN", "Infinity", "-Infinity"])
        return num(floatText(r, name))
      }
      case "Any": return miss ? (r.chance(0.7) ? badLosslessJ(r) : mutateJ(r, randomLossless(r, depth), badLosslessJ)) : randomLossless(r, depth)
      case "Int":
      case "Int64":
      case "UInt64": {
        if (miss) return r.chance(0.6) ? r.pick(INTEGER_STRINGS) : r.chance(0.5) ? num(integerValue(r, name).toString()) : r.pick<J>([null, true, num("1.0"), [integerValue(r, name).toString()]])
        return integerValue(r, name).toString()
      }
      default: {
        if (miss) return r.chance(0.6) ? num(r.pick(NOT_INTEGER_NUMS)) : r.pick<J>([integerValue(r, name).toString(), null, true, "1", num("-0"), num("1" + "0".repeat(1000))])
        return num(integerValue(r, name).toString())
      }
    }
  }

  private fields(r: Rng, rec: RecordType, c: PlainOpts, depth: number, deep: number, miss: boolean, lead: readonly (readonly [string, J])[] = []): Obj {
    const declared = new Set(rec.fields.map((f) => f.key))
    const out: (readonly [string, J])[] = []
    const spineCandidates = rec.fields.filter((f) => !f.optional || r.chance(0.5))
    const spine = deep > 0 && spineCandidates.length ? r.pick(spineCandidates).key : undefined
    const drop = miss && r.chance(0.4) ? r.pick(rec.fields.filter((f) => !f.optional).map((f) => f.key).concat([""])) : undefined
    for (const f of rec.fields) {
      if (f.key === drop) continue
      if (f.optional && f.key !== spine && r.chance(0.5)) {
        // A missing optional field is a missing member: `null` is a value, which only a Maybe that uses it reads.
        if (miss && r.chance(0.3)) out.push([f.key, null])
        continue
      }
      out.push([f.key, this.gen(r, f.type, c, depth + 1, f.key === spine ? deep - 1 : 0)])
    }
    const extras = (!rec.closed && r.chance(0.3)) || (miss && drop === undefined) ? 1 + r.int(2) : 0
    const candidates = [...EXTRA_KEYS, "_tag", "value", "values", "args", "tag"].filter((k) => !declared.has(k))
    for (const k of shuffle(r, candidates).slice(0, extras)) out.push([k, anyJ(r, depth + 1)])
    if (miss && out.length && r.chance(0.2)) out.push([r.pick(out)[0], anyJ(r, depth + 1)]) // a duplicate name
    return new Obj([...lead, ...shuffle(r, out)])
  }

  private variant(r: Rng, v: Variant["variant"], c: PlainOpts, depth: number, deep: number, miss: boolean): J {
    const unknownTag = () => r.pick(["Unknown", "Other", "X", "None", "Some", "True", "Ok", "Err", "Nil", "Num", "Leaf", "Hexagon"].filter((t) => !v.cases.some((k) => k.tag === t)))
    const bare = this.enumLike(v)
    if (v.cases.length === 0 || r.chance(miss ? 0.4 : v.closed ? 0 : 0.12)) {
      const tag = miss && v.cases.length && r.chance(0.3) ? r.pick(v.cases).tag : miss && r.chance(0.2) ? r.pick(["lower", "", "_X", "X y", "1X", "Xé", "X-1"]) : unknownTag()
      if (bare && r.chance(0.5)) return tag
      const form = r.int(miss ? 8 : 5)
      switch (form) {
        case 0:
        case 1: return obj(["_tag", tag])
        case 2: return obj(["_tag", tag], ["args", Array.from({ length: 1 + r.int(3) }, () => randomLossless(r, depth + 2))])
        case 3:
        case 4: {
          // Other members: a record payload read without a schema (§16.1).
          const ks = shuffle(r, ["sides", "value", "values", "args", "x", "", "r", "_tag2", "tag"]).slice(0, 1 + r.int(3))
          return new Obj(shuffle(r, [["_tag", tag] as const, ...ks.map((k) => [k, k === "args" && r.chance(0.5) ? [randomLossless(r, depth + 2)] : anyJ(r, depth + 2)] as const)]))
        }
        case 5: return obj(["_tag", tag], ["args", r.pick<J>([[], num("5"), null, obj(), "x", [num("1")], [null], [true]])])
        case 6: return obj(["_tag", r.pick<J>([num("1"), null, true, [tag], obj()])])
        default: return r.pick<J>([tag, obj(), obj(["tag", tag]), obj(["_tag", tag], ["_tag", tag])])
      }
    }
    const recursive = v.cases.filter((k) => this.recurses(k))
    const kase = deep > 0 && recursive.length ? r.pick(recursive) : r.pick(v.cases)
    const p = kase.payload
    const tagged = (...ms: (readonly [string, J])[]) => new Obj(r.chance(0.7) ? [["_tag", kase.tag], ...ms] : [...ms, ["_tag", kase.tag]])
    if (p === "none") {
      if (bare) return miss ? r.pick<J>([obj(["_tag", kase.tag]), kase.tag.toLowerCase(), kase.tag + " ", num("0"), true, [kase.tag]]) : kase.tag
      if (miss) return r.pick<J>([tagged(["value", num("1")]), tagged(["x", num("1")]), kase.tag, tagged(["values", []]), tagged(["args", [obj(["num", "1"])]]), obj(["_tag", kase.tag], ["_tag", kase.tag])])
      return tagged()
    }
    if ("record" in p) {
      if (miss && r.chance(0.5)) {
        return r.pick<() => J>([() => obj(["_tag", kase.tag], ["value", this.fields(r, p.record, c, depth + 1, 0, false)]), () => this.fields(r, p.record, c, depth + 1, 0, false),
          () => this.fields(r, p.record, c, depth + 1, 0, false, [["_tag", kase.tag], ["_tag", kase.tag]]), () => kase.tag,
          () => obj(["_tag", kase.tag], ["args", [obj(["rec", obj()])]])])()
      }
      return this.fields(r, p.record, c, depth + 1, deep, miss, [["_tag", kase.tag]])
    }
    const types = p.positional
    let n = types.length
    if (miss && r.chance(0.6)) n = r.pick([0, n + 1, Math.max(0, n - 1)].filter((x) => x !== types.length))
    const spineCandidates = types.map((t, i) => [t, i] as const).filter(([t]) => this.mentionsRef(t)).map(([, i]) => i)
    const spine = deep > 0 && spineCandidates.length ? r.pick(spineCandidates) : -1
    const args = Array.from({ length: n }, (_, i) => (i < types.length ? this.gen(r, types[i]!, c, depth + 1, i === spine ? deep - 1 : 0) : anyJ(r, depth + 2)))
    // One argument is "value", several are "values" (the schema's case decides); near misses swap them.
    const swap = miss && r.chance(0.5)
    if (types.length === 1 && !swap) return n === 0 ? tagged() : n === 1 ? tagged(["value", args[0]!]) : tagged(["value", args[0]!], ["values", args])
    if (types.length === 1) return tagged(["values", args])
    if (swap) return r.pick<J>([tagged(["value", args[0] ?? null]), tagged(["value", args]), tagged(["values", obj()]), tagged(["values", args], ["value", args[0] ?? null])])
    return tagged(["values", args])
  }

  private mentionsRef(t: Type): boolean {
    if ("ref" in t) return true
    if ("array" in t) return this.mentionsRef(t.array)
    if ("map" in t) return this.mentionsRef(t.map)
    if ("maybe" in t) return this.mentionsRef(t.maybe)
    if ("secret" in t) return this.mentionsRef(t.secret)
    if ("record" in t) return t.record.fields.some((f) => this.mentionsRef(f.type))
    if ("variant" in t) return t.variant.cases.some((k) => this.recurses(k))
    return false
  }

  private recurses(k: Case): boolean {
    const p = k.payload
    if (p === "none") return false
    if ("record" in p) return p.record.fields.some((f) => this.mentionsRef(f.type))
    return p.positional.some((t) => this.mentionsRef(t))
  }

  /** The smallest JSON `t` reads (to end recursion), or undefined if it has none. */
  minimal(t: Type, seen: ReadonlySet<string> = new Set()): J | undefined {
    if ("ref" in t) {
      if (this.minimals.has(t.ref)) return this.minimals.get(t.ref)
      if (seen.has(t.ref)) return undefined
      const m = this.minimal(this.env.get(t.ref)!, new Set([...seen, t.ref]))
      if (seen.size === 0 || m !== undefined) this.minimals.set(t.ref, m)
      return m
    }
    if ("builtin" in t) {
      const b = t.builtin
      if (b === "String" || b === "Bytes") return ""
      if (b === "Bool") return true
      if (b === "Any") return obj(["num", "0"])
      if (b === "Int" || b === "Int64" || b === "UInt64" || b === "Decimal") return "0"
      return num("0")
    }
    if ("time" in t) {
      return ({ Date: "2026-11-14", Time: "10:00:00", DateTime: "2026-11-14T10:00:00", Instant: "2026-11-14T10:00:00Z", ZonedDateTime: "2026-11-14T10:00:00+01:00[Europe/Paris]", Duration: "PT1H", YearMonth: "2026-11", TimeZone: "UTC" } as Record<string, string>)[t.time]!
    }
    if ("array" in t) return []
    if ("map" in t) return obj()
    if ("maybe" in t) return this.usesNull(t) ? null : obj(["_tag", "None"])
    if ("secret" in t) return this.minimal(t.secret, seen)
    if ("record" in t) return this.minimalFields(t.record, seen, [])
    const v = t.variant
    if (v.cases.length === 0) return obj(["_tag", "X"])
    if (this.enumLike(v)) return v.cases[0]!.tag
    for (const k of [...v.cases].sort((a, b) => Number(this.recurses(a)) - Number(this.recurses(b)))) {
      const p = k.payload
      if (p === "none") return obj(["_tag", k.tag])
      if ("record" in p) {
        const f = this.minimalFields(p.record, seen, [["_tag", k.tag]])
        if (f !== undefined) return f
        continue
      }
      const args = p.positional.map((a) => this.minimal(a, seen))
      if (args.every((a) => a !== undefined)) return args.length === 1 ? obj(["_tag", k.tag], ["value", args[0]!]) : obj(["_tag", k.tag], ["values", args as J[]])
    }
    return undefined
  }

  private minimalFields(rec: RecordType, seen: ReadonlySet<string>, lead: (readonly [string, J])[]): J | undefined {
    const ms = [...lead]
    for (const f of rec.fields) {
      if (f.optional) continue
      const m = this.minimal(f.type, seen)
      if (m === undefined) return undefined
      ms.push([f.key, m])
    }
    return new Obj(ms)
  }
}
