/**
 * Differential testing of the official profiles' codecs (spec §13.3, §13.4;
 * extensions/money/profiles/iso.md, extensions/geo/profiles/wgs84.md,
 * extensions/uuid/profiles/rfc9562.md):
 * generated values and near misses through the Lean reference checkers
 * (spec/lean/Haus/Profiles, proven to compute the rules) and every binding's
 * codecs, reporting where they disagree. See ../README.md, "Profiles".
 *
 *   node fuzz/src/profiles.ts [--count N] [--seed S] [--profiles iso,wgs84,rfc9562] [--runners lean,rust,…] [--out DIR]
 *
 * `--count` is the number of cases for each profile.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { join } from "node:path"
import { pathToFileURL } from "node:url"
import { parseArgs } from "node:util"
import { canonical, compileSchemaFile, parseAll } from "../../typescript/packages/haus/dist/index.js"
import { schemaOptions } from "../../typescript/packages/haus/dist/node.js"
import * as h from "../../typescript/packages/haus/dist/schema.js"
import { COMMENTS, Rng } from "./generate.ts"
import { runProgram, timeoutFor } from "./spawn.ts"

const { values: args } = parseArgs({
  options: {
    count: { type: "string", default: "5000" },
    seed: { type: "string", default: String(Date.now() % 1_000_000) },
    profiles: { type: "string" },
    runners: { type: "string" },
    out: { type: "string", default: "fuzz/.out/profiles" },
  },
})
const count = Number(args.count)
const seed = Number(args.seed)
const out = args.out!
const root = new URL("../..", import.meta.url).pathname

// ── the profiles ─────────────────────────────────────────────

interface Profile {
  /** The profile's name, for `haus-ref --profile-batch`. */
  readonly name: string
  readonly short: string
  /** The package's directory, under extensions/. */
  readonly dir: string
  readonly types: readonly string[]
}

const PROFILES: readonly Profile[] = [
  { name: "@haus-fmt/money/iso", short: "iso", dir: "money", types: ["Money", "Currency"] },
  { name: "@haus-fmt/geo/wgs84", short: "wgs84", dir: "geo", types: ["LatLng", "BBox"] },
  { name: "@haus-fmt/uuid/rfc9562", short: "rfc9562", dir: "uuid", types: ["Uuid"] },
]

interface Case {
  readonly type: string
  readonly text: string
}

// ── generating: formatting ───────────────────────────────────

/** Space between tokens: mostly none or one, sometimes a line break or a comment. */
function sp(r: Rng): string {
  const x = r.next()
  if (x < 0.5) return ""
  if (x < 0.85) return " "
  if (x < 0.93) return r.pick(["\n", "\t", "\r\n", "  "])
  return r.pick([" ", "\n"]) + r.pick(COMMENTS) + r.pick(["", " "])
}

/** Between a tag and its `(`: on the same line (a line break makes it two values). */
const tagSp = (r: Rng) => (r.chance(0.9) ? "" : r.chance(0.95) ? r.pick([" ", "\t", "  "]) : "\n")

/** `Tag(a, b)`, with varied spacing and sometimes a trailing comma. */
function call(r: Rng, tag: string, xs: readonly string[]): string {
  if (xs.length === 0) return tag + (r.chance(0.3) ? "()" : "")
  const inner = xs.map((x) => sp(r) + x + sp(r)).join(",")
  return `${tag}${tagSp(r)}(${inner}${r.chance(0.05) ? "," + sp(r) : ""})`
}

/** Removes, inserts or replaces a character now and then (40% of the near misses are syntax). */
const NOISE = ["0", "9", "-", ".", "e", "E", "_", "x", ",", "(", ")", "{", "}", " ", "\n", "A", "Z", "a", "é", "\0", "/", "*"]
function mutate(r: Rng, s: string): string {
  const cs = [...s]
  for (let k = 1 + r.int(2); k > 0; k--) {
    const at = r.int(cs.length + 1)
    switch (r.int(5)) {
      case 0: cs.splice(at, 1); break
      case 1: cs.splice(at, 0, r.pick(NOISE)); break
      case 2: cs.splice(at, 1, r.pick(NOISE)); break
      case 3: cs.splice(at, 0, ...cs.slice(at, at + 1 + r.int(4))); break
      case 4: cs.length = at; break
    }
  }
  return cs.join("")
}

/** Values of other kinds, where a number or a tag goes. */
const OTHER_KINDS = ['"EUR"', '"90"', "true", "false", "[]", "[1]", "{}", "{ a: 1 }", 'x"00"', "Some(1)", "None"]

// ── generating: numbers ──────────────────────────────────────

const view = new DataView(new ArrayBuffer(8))
const bitsOf = (x: number): bigint => (view.setFloat64(0, x), view.getBigUint64(0))
const ofBits = (b: bigint): number => (view.setBigUint64(0, b), view.getFloat64(0))

/** The next float away from zero (for x ≥ 0 towards +∞, for x < 0 towards −∞), and the one towards zero. */
const away = (x: number) => ofBits(bitsOf(x) + 1n)
const towards = (x: number) => (x === 0 ? -0 : ofBits(bitsOf(x) - 1n))

/** `m · 2^e` exactly in decimal. */
function dyadic(m: bigint, e: number): string {
  const neg = m < 0n
  const a = neg ? -m : m
  let s: string
  if (e >= 0) s = (a << BigInt(e)).toString()
  else {
    const digits = (a * 5n ** BigInt(-e)).toString().padStart(-e + 1, "0")
    const cut = digits.length + e
    s = `${digits.slice(0, cut)}.${digits.slice(cut)}`.replace(/\.?0+$/, "")
  }
  return (neg ? "-" : "") + s
}

/** A finite float as `m · 2^e`. */
function parts(x: number): [bigint, number] {
  const b = bitsOf(x)
  const exp = Number((b >> 52n) & 0x7ffn)
  const frac = b & ((1n << 52n) - 1n)
  const m = exp === 0 ? frac : frac | (1n << 52n)
  const sign = b >> 63n ? -1n : 1n
  return [sign * m, (exp === 0 ? 1 : exp) - 1075]
}

/** The exact decimal value of a finite float. */
const exact = (x: number) => (Object.is(x, -0) ? "-0" : dyadic(...parts(x)))

/** The exact decimal value halfway between two adjacent finite floats of the same sign. */
function halfway(x: number, y: number): string {
  const [m1, e1] = parts(x)
  const [m2, e2] = parts(y)
  const e = Math.min(e1, e2)
  const sum = (m1 << BigInt(e1 - e)) + (m2 << BigInt(e2 - e))
  return dyadic(sum, e - 1)
}

/** A decimal literal nudged just above (`+`) or below (`-`) its value in magnitude, by digits far past the float's precision. */
function nudge(lit: string, up: boolean): string {
  const s = lit.includes(".") ? lit : lit + "."
  if (up) return s + "00000001"
  // Below in magnitude: …x - 10^-k, as digits: the last nonzero digit decreased, followed by nines.
  const digits = s.replace(/\.$/, ".0")
  const i = digits.search(/[1-9][0]*$/)
  if (i < 0) return digits
  return digits.slice(0, i) + String(Number(digits[i]) - 1) + digits.slice(i + 1).replace(/0/g, "9") + "9".repeat(8)
}

/** A float written in one of its spellings: shortest, fixed, with an exponent, as an integer, hex or binary when it is one. */
function spell(r: Rng, x: number): string {
  if (Object.is(x, -0)) return r.pick(["-0", "-0.0", "-0e0", "-0.000e-10", "-0E+5", "-0x0", "-0b0", "-0.0_0"])
  if (x === 0) return r.pick(["0", "0.0", "0e0", "0.000", "0E-7", "0x0", "0b0"])
  const neg = x < 0 ? "-" : ""
  const a = Math.abs(x)
  const k = r.int(10)
  if (Number.isInteger(a) && a < 2 ** 53) {
    const n = BigInt(a)
    if (k === 0) return neg + "0x" + n.toString(16)[r.chance(0.5) ? "toUpperCase" : "toLowerCase"]()
    if (k === 1) return neg + "0b" + n.toString(2)
    if (k === 2) return neg + n.toString() + ".0"
    if (k === 3 && n >= 10n) return neg + n.toString().split("").join("_")
    if (k === 4 && n % 10n === 0n) return neg + (n / 10n).toString() + "e1"
    if (k === 5) {
      const z = 1 + r.int(3)
      return neg + n.toString() + "0".repeat(z) + "e-" + z
    }
  }
  if (k === 6 && exact(x).length <= 1000) return exact(x)
  if (k === 7) return neg + a.toExponential().replace("e+", r.pick(["e", "E+", "e+"]))
  if (k === 8) return neg + a.toPrecision(1 + r.int(21))
  return String(x)
}

/** A latitude (bound 90) or longitude (bound 180), weighted towards the edges of the range. */
function coordinate(r: Rng, bound: number): string {
  const k = r.next()
  const edge = r.pick([bound, -bound, bound, -bound, 0, -0])
  if (k < 0.25) {
    // At an edge, or one float either side of it.
    const x = r.pick([edge, edge, away(edge), towards(edge)])
    return spell(r, Object.is(edge, -0) && r.chance(0.5) ? -0 : x)
  }
  if (k < 0.37) {
    // Halfway to the next float beyond a bound (ties to even: onto the bound), and a hair either side.
    const b = r.pick([bound, -bound])
    const lit = halfway(b, away(b))
    return r.pick([lit, nudge(lit, true), nudge(lit, false), lit.slice(0, lit.length - 1 - r.int(5))])
  }
  if (k < 0.47) {
    // Literals that round onto the edge, or just past it: 90.000…01, 89.999…9.
    const zeros = r.pick([5, 10, 13, 14, 15, 16, 17, 20, 25, 40])
    const sign = edge < 0 || Object.is(edge, -0) ? "-" : ""
    const a = Math.abs(edge)
    return r.chance(0.5) ? `${sign}${a}.${"0".repeat(zeros)}1` : `${sign}${a === 0 ? 0 : a - 1}.${"9".repeat(zeros)}`
  }
  if (k < 0.62) {
    // Anywhere in the range, with any precision.
    const x = (r.next() * 2 - 1) * bound
    return spell(r, r.chance(0.3) ? Math.round(x) : r.chance(0.5) ? Number(x.toFixed(r.int(8))) : x)
  }
  if (k < 0.72) {
    // Out of range, near and far.
    const x = (bound + r.pick([1e-9, 0.5, 1, 10, 90, 1000, 1e10]) * r.next()) * (r.chance(0.5) ? -1 : 1)
    return spell(r, x)
  }
  if (k < 0.78) return r.pick(["NaN", "Infinity", "NegInfinity"])
  // Not numbers: rejected by every parser.
  if (k < 0.8) return r.pick(["-Infinity", "nan", "Inf", "-NaN", "+1", ".5", "5.", "1e", "0x", "00", "-00", "01.5"])
  if (k < 0.88) {
    // Huge and tiny exponents: overflow, underflow to (negative) zero, subnormals, the exponent limit (6144).
    return r.pick([
      "1e308", "1.7976931348623157e308", "1.7976931348623158e308", "1.8e308", "-1.8e308", "1e400", "-1e400", "1e6144", "1e6145",
      "5e-324", "-5e-324", "1e-400", "-1e-400", "2.4703282292062327e-324", "2.4703282292062328e-324", "-2.4703282292062328e-324",
      "4.9406564584124654e-324", "2.2250738585072014e-308", "1e-6144", "-1e-6144", "0e6144", "-0e-6144",
      `9${"0".repeat(r.pick([1, 300, 400]))}e-${r.pick([300, 400, 401])}`, "0.000000000000000000001", "-0.000000000000000000001",
      exact(5e-324), exact(-5e-324), halfway(2 ** -1022, away(2 ** -1022)),
    ])
  }
  if (k < 0.94) {
    // Many digits.
    return r.pick([
      `${bound}.${"0".repeat(400)}1`, `-${bound}.${"0".repeat(400)}1`, `0.${"0".repeat(330)}1`, "9".repeat(r.pick([20, 309, 400])),
      `${bound - 1}.${"9".repeat(r.pick([16, 17, 30, 400]))}`, "1_8_0", "9_0.0_0", `${bound}${"0".repeat(r.pick([2, 300]))}e-${r.pick([2, 300])}`,
      `${bound}.${"0".repeat(997 - String(bound).length)}1`, `${bound}.${"0".repeat(998 - String(bound).length)}1`,
    ])
  }
  return r.pick(OTHER_KINDS)
}

const LAT = (r: Rng) => coordinate(r, 90)
const LNG = (r: Rng) => coordinate(r, 180)

/** A point: mostly two coordinates, sometimes the wrong shape. */
function latLng(r: Rng, lat = LAT(r), lng = LNG(r)): string {
  if (r.chance(0.9)) return call(r, "LatLng", [lat, lng])
  return r.pick([
    call(r, "LatLng", [lat]),
    call(r, "LatLng", [lat, lng, LNG(r)]),
    call(r, "LatLng", []),
    `LatLng${tagSp(r)}{ lat: ${lat}, lng: ${lng} }`,
    call(r, r.pick(["Latlng", "LatLon", "Point", "LATLNG"]), [lat, lng]),
    call(r, "LatLng", [`"${lat}"`, lng]),
    `[${lat}, ${lng}]`,
    call(r, "BBox", [lat, lng]),
  ])
}

/** A box: corners in or out of order, across the antimeridian, at ±180, with -0 and 0. */
function bbox(r: Rng): string {
  const k = r.next()
  let a: string, b: string, c: string, d: string
  if (k < 0.3) {
    // Ordered or swapped latitudes, some of them equal, -0 and 0, one float apart.
    const x = (r.next() * 2 - 1) * 90
    const y = r.pick([x, -x, (r.next() * 2 - 1) * 90, away(x), towards(x), x === 0 ? -0 : x])
    const pair = r.pick<[number, number]>([[x, y], [y, x], [0, -0], [-0, 0], [-0, -0], [90, -90], [-90, 90], [90, 90], [-1e-300, -1e-301], [-1e-301, -1e-300]])
    ;[a, c] = [spell(r, pair[0]), spell(r, pair[1])]
    ;[b, d] = [LNG(r), LNG(r)]
  } else if (k < 0.5) {
    // Longitudes across the antimeridian, at ±180, from -180 to 180.
    const lngs = r.pick<[string, string]>([["170", "-170"], ["-170", "170"], ["180", "-180"], ["-180", "180"], ["180", "180"], ["-180", "-180"],
      ["0", "-0"], ["-0", "0"], ["179.99999999999997", "-179.99999999999997"], [String(away(180)), "-180"], ["180", String(-away(180))]])
    ;[a, c] = r.chance(0.7) ? ["-10", "10"] : [LAT(r), LAT(r)]
    ;[b, d] = lngs.map((s) => (r.chance(0.8) ? s : spell(r, Number(s)))) as [string, string]
  } else {
    ;[a, b, c, d] = [LAT(r), LNG(r), LAT(r), LNG(r)]
  }
  const sw = r.chance(0.93) ? call(r, "LatLng", [a, b]) : latLng(r, a, b)
  const ne = r.chance(0.93) ? call(r, "LatLng", [c, d]) : latLng(r, c, d)
  if (r.chance(0.93)) return call(r, "BBox", [sw, ne])
  return r.pick([
    call(r, "BBox", [sw]),
    call(r, "BBox", [sw, ne, ne]),
    call(r, "BBox", [a, b]),
    call(r, "BBox", [sw, a]),
    `BBox${tagSp(r)}{ sw: ${sw}, ne: ${ne} }`,
    call(r, "Bbox", [sw, ne]),
    sw,
  ])
}

// ── generating: money ────────────────────────────────────────

const UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const LOWER = "abcdefghijklmnopqrstuvwxyz"

/** A tag of 2–4 characters (sometimes 1 or 5–6): mostly capitals, sometimes lowercase, digits, `_`, non-ASCII. */
function tag(r: Rng): string {
  if (r.chance(0.05)) return r.pick(["EUR", "USD", "CHF", "BTC", "XXX", "AAA", "ZZZ", "NaN", "Infinity", "NegInfinity", "Some", "None", "Money", "Currency"])
  const n = r.pick([2, 3, 3, 3, 3, 3, 4, 4, 1, 5, 6])
  const odd = r.chance(0.35)
  let s = ""
  for (let i = 0; i < n; i++) {
    if (!odd || r.chance(0.65)) s += r.pick([...UPPER])
    else if (i === 0 && r.chance(0.8)) s += r.pick([...UPPER])
    else if (r.chance(0.92)) s += r.pick([...LOWER, ..."0123456789", "_"])
    // Not in a tag: the letters around A and Z, non-ASCII capitals.
    else s += r.pick(["Ä", "É", "@", "["])
  }
  return s
}

/** A payload for a currency's tag: rejected by the profile, whatever it is. */
const PAYLOADS = ["(1)", "(1, 2)", "()", " {}", "{ a: 1 }", "([])", '("x")', "(EUR)", "(USD(1))", "({})", "(-0)"]

function currency(r: Rng): string {
  const k = r.next()
  const t = tag(r)
  if (k < 0.8) return t
  if (k < 0.93) return t + r.pick(PAYLOADS)
  return r.pick([...OTHER_KINDS, "eur", "Eur", "1", "-0", "EUR EUR", "EUR,", "EUR // note\n", "/* c */ EUR"])
}

/** An amount: a Decimal in every spelling, at the number limits, and things that aren't Decimals. */
function amount(r: Rng): string {
  const k = r.next()
  if (k < 0.3) return r.pick(["0", "-0", "19.90", "19.9", "0.000", "-0.00", "1e3", "1E+3", "15e-2", "-1.50e-2", "0.00005", "100", "1_000.000_1"])
  if (k < 0.55) {
    const int = String(r.int(10 ** r.int(9)))
    const frac = r.chance(0.5) ? "." + String(r.int(10 ** (1 + r.int(6)))).padStart(1 + r.int(6), "0") : ""
    const exp = r.chance(0.2) ? r.pick(["e", "E"]) + r.pick(["", "+", "-"]) + String(r.int(400)) : ""
    return (r.chance(0.3) ? "-" : "") + int + frac + exp
  }
  if (k < 0.65) return r.pick(["0x1F", "-0x0", "0xff", "0b101", "-0b0", "0x" + "f".repeat(r.pick([8, 16, 17, 40]))])
  if (k < 0.8) {
    // At the number limits: 1000 characters, exponents up to 6144.
    return r.pick([
      "1".repeat(r.pick([20, 39, 40, 309, 999, 1000, 1001])), `0.${"0".repeat(r.pick([20, 400, 997, 998]))}1`,
      `1e${r.pick(["6144", "-6144", "6145", "-6145", "+6144", "06144", "2147483648"])}`, `9.99e6144`, `-1.5e-6144`,
      `-0e${r.pick(["5", "-5", "6144", "6145"])}`, `${"9".repeat(r.pick([30, 400]))}.${"9".repeat(r.pick([30, 400]))}`,
    ])
  }
  if (k < 0.9) return coordinate(r, 90)
  return r.pick(["NaN", "Infinity", "NegInfinity", '"19.90"', "true", "[]", "{}", "EUR", "+1", ".5", "1.", "1e", "01"])
}

function money(r: Rng): string {
  if (r.chance(0.9)) return call(r, "Money", [amount(r), currency(r)])
  return r.pick([
    call(r, "Money", [amount(r)]),
    call(r, "Money", [amount(r), currency(r), amount(r)]),
    call(r, "Money", [currency(r), amount(r)]),
    `Money${tagSp(r)}{ amount: ${amount(r)}, currency: ${currency(r)} }`,
    call(r, r.pick(["money", "MONEY", "Mony", "Amount"]), [amount(r), currency(r)]),
    call(r, "Money", [amount(r), call(r, "Money", [amount(r), currency(r)])]),
    currency(r),
    "Money",
  ])
}

// ── generating: uuids ────────────────────────────────────────

const HEX = "0123456789abcdef"
/** Where the text form has its hyphens. */
const HYPHENS = [8, 13, 18, 23]

/** A UUID's text: lowercase, any version and variant, sometimes the nil or the max UUID. */
function uuidText(r: Rng): string {
  if (r.chance(0.05)) return r.pick(["00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"])
  let s = ""
  for (let i = 0; i < 36; i++) s += HYPHENS.includes(i) ? "-" : r.pick([...HEX])
  return s
}

/** Characters that are near a lowercase hexadecimal digit or a hyphen, and aren't one. */
const NOT_HEX = ["A", "B", "F", "G", "g", "z", "/", ":", "`", "@", "_", " ", "\t", "\n", "\0", "٧", "０", "ａ", "é", "‐", "−", "–", "{", "}"]

/** A near miss of a text: a character off, a hyphen moved or gone, a length off, another spelling. */
function nearUuid(r: Rng, s: string): string {
  const cs = [...s]
  switch (r.int(10)) {
    case 0: {
      // One digit or all of them in uppercase.
      if (r.chance(0.5)) return s.toUpperCase()
      const i = r.pick([...cs.keys()].filter((k) => !HYPHENS.includes(k)))
      cs[i] = cs[i]!.toUpperCase() === cs[i] ? "A" : cs[i]!.toUpperCase()
      return cs.join("")
    }
    case 1:
      cs[r.int(cs.length)] = r.pick(NOT_HEX)
      return cs.join("")
    case 2: {
      // A hyphen moved, or a digit in its place.
      const h = r.pick(HYPHENS)
      cs[h] = r.pick([...HEX])
      if (r.chance(0.5)) cs[r.int(cs.length)] = "-"
      return cs.join("")
    }
    case 3:
      return r.chance(0.5) ? s.slice(0, 35) : s + r.pick([...HEX, "-"])
    case 4:
      return r.chance(0.5) ? s.slice(1) : r.pick([...HEX]) + s
    case 5:
      return r.pick([`{${s}}`, `urn:uuid:${s}`, `URN:UUID:${s}`, `(${s})`])
    case 6:
      return s.replaceAll("-", r.chance(0.8) ? "" : "_")
    case 7:
      return r.pick([" ", "\n", "\t", "\r\n"]) + s + r.pick(["", " "])
    case 8:
      return r.pick(["", "-", "0", "uuid", "nil", "0".repeat(36), "-".repeat(36), "0".repeat(32), s + s])
    default:
      // The same length, everything shifted by one: hyphens in the wrong places.
      return s.slice(1) + r.pick([...HEX])
  }
}

/** A haus string for `s`: plain, or with some characters escaped (the rule is on the decoded string). */
function quoted(r: Rng, s: string): string {
  const k = r.next()
  const escape = (c: string) => {
    if (c === '"') return '\\"'
    if (c === "\\") return "\\\\"
    if (c === "\n") return r.chance(0.5) ? "\\n" : "\\u{a}"
    if (c === "\t") return "\\t"
    if (c === "\r") return "\\r"
    const cp = c.codePointAt(0)!
    // Controls and bidi controls can't be raw in a string (spec §4).
    if (cp < 0x20 || (cp >= 0x7f && cp <= 0x9f) || (cp >= 0x202a && cp <= 0x202e) || (cp >= 0x2066 && cp <= 0x2069)) return `\\u{${cp.toString(16)}}`
    return c
  }
  if (k < 0.85) return `"${[...s].map(escape).join("")}"`
  // Some characters as \u{…}, in either case and with leading zeros.
  return `"${[...s].map((c) => (r.chance(0.2) ? `\\u{${r.pick(["", "0", "00"])}${c.codePointAt(0)!.toString(16)[r.chance(0.5) ? "toUpperCase" : "toLowerCase"]()}}` : escape(c))).join("")}"`
}

function uuid(r: Rng): string {
  const k = r.next()
  const text = uuidText(r)
  const s = k < 0.45 ? text : k < 0.93 ? nearUuid(r, text) : r.pick(["", "x", "0190c7a8-5b6e-7d3f-9a41", text.toUpperCase(), "\u{202E}" + text])
  if (r.chance(0.92)) return call(r, "Uuid", [quoted(r, s)])
  return r.pick([
    call(r, "Uuid", []),
    call(r, "Uuid", [quoted(r, s), quoted(r, s)]),
    call(r, r.pick(["uuid", "UUID", "Guid", "Id"]), [quoted(r, s)]),
    call(r, "Uuid", [r.pick(OTHER_KINDS)]),
    call(r, "Uuid", [`x"${"00".repeat(16)}"`]),
    `Uuid${tagSp(r)}{ text: ${quoted(r, s)} }`,
    quoted(r, s),
    "Uuid",
  ])
}

// ── generating: cases ────────────────────────────────────────

const valueFor: Record<string, (r: Rng) => string> = {
  Money: money,
  Currency: currency,
  LatLng: (r) => latLng(r),
  BBox: bbox,
  Uuid: uuid,
}

function generate(r: Rng, p: Profile): Case {
  const type = r.pick(p.types)
  // Sometimes a value made for the other type of the profile.
  const text = valueFor[r.chance(0.08) ? r.pick(p.types) : type]!(r)
  const padded = r.chance(0.1) ? r.pick(["", " ", "\n", "﻿", "/* c */ "]) + text + r.pick(["", "\n", " // end\n", ","]) : text
  return { type, text: r.chance(0.08) ? mutate(r, padded) : padded }
}

// ── running ──────────────────────────────────────────────────

/** `ok` with the canonical form of what the codec writes, `err` at a place with a code (`-` for none), or a crash. */
type Outcome =
  | { readonly kind: "ok"; readonly text: string }
  | { readonly kind: "err"; readonly place: string; readonly code: string; readonly reason: string }
  | { readonly kind: "crash"; readonly reason: string }

function parseOutcome(line: string): Outcome {
  if (line.startsWith("ok ")) return { kind: "ok", text: line.slice(3) }
  const m = /^err (\S+) (\S+) ?(.*)$/s.exec(line)
  if (m) return { kind: "err", place: m[1]!, code: m[2]!, reason: m[3]! }
  return { kind: "crash", reason: line.slice(0, 300) }
}

const show = (o: Outcome) =>
  o.kind === "ok" ? `ok ${o.text}` : o.kind === "err" ? `err ${o.place} ${o.code} ${o.reason}`.slice(0, 300) : o.reason

interface Runner {
  readonly name: string
  run(p: Profile, file: string, cases: readonly Case[]): Outcome[]
}

const hex = (s: string) => Buffer.from(s, "utf8").toString("hex")
const writeCases = (file: string, cases: readonly Case[]) => writeFileSync(file, cases.map((c) => `${c.type} ${hex(c.text)}\n`).join(""))

/**
 * A runner that is a separate program: `program [...args(profile)] FILE`.
 * When it crashes, the cases are split in halves until the ones that crash it are found.
 */
function external(name: string, program: string, args: (p: Profile) => readonly string[] = () => []): Runner {
  const run = (p: Profile, file: string, cases: readonly Case[]): Outcome[] => {
    const part = `${file}.${name}`
    writeCases(part, cases)
    const r = runProgram(name, program, [...args(p), part], timeoutFor(cases.length))
    const lines = (r.stdout ?? "").split("\n").filter((l) => l !== "")
    if (r.status === 0 && lines.length === cases.length) return lines.map(parseOutcome)
    if (cases.length === 1) {
      const why = r.error ? String(r.error) : r.signal ? `signal ${r.signal}` : `exit ${r.status}, ${lines.length} lines`
      return [{ kind: "crash", reason: `CRASH (${why}): ${(r.stderr ?? "").trim().split("\n").slice(0, 3).join(" ").slice(0, 300)}` }]
    }
    const mid = cases.length >> 1
    return [...run(p, file, cases.slice(0, mid)), ...run(p, file, cases.slice(mid))]
  }
  return { name, run }
}

/** The single value of a case's text, or the error line Lean prints for it. */
function single(text: string): { value: any } | { error: Outcome } {
  try {
    const vs = parseAll(text)
    return vs.length === 1 ? { value: vs[0] } : { error: { kind: "err", place: "$", code: "-", reason: "not a single value" } }
  } catch (e) {
    return { error: { kind: "err", place: "$", code: "-", reason: (e as Error).message } }
  }
}

/** A runner in this process: decode and encode one value, or throw. */
function inProcess(name: string, roundtrip: (p: Profile, type: string, value: any) => Outcome): Runner {
  return {
    name,
    run: (p, _file, cases) =>
      cases.map((c) => {
        const v = single(c.text)
        if ("error" in v) return v.error
        try {
          return roundtrip(p, c.type, v.value)
        } catch (e) {
          return { kind: "crash", reason: `CRASH: ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`.slice(0, 300) }
        }
      }),
  }
}

/** `h.decode`, then `h.encode` and its canonical form. */
function hRoundtrip(schema: h.Schema<unknown> | undefined, value: any): Outcome {
  if (!schema) return { kind: "crash", reason: "CRASH: no such type" }
  let decoded: unknown
  try {
    decoded = h.decode(schema, value)
  } catch (e) {
    if (e instanceof h.HausDecodeError) return { kind: "err", place: h.formatPath(e.path), code: e.code ?? "-", reason: e.message }
    throw e
  }
  try {
    return { kind: "ok", text: canonical(h.encode(schema, decoded)) }
  } catch (e) {
    // Encoding what was decoded must work (spec §13.4: the codec writes back what it decoded).
    if (e instanceof h.HausEncodeError) return { kind: "crash", reason: `CRASH: encoding failed: ${e.message}` }
    throw e
  }
}

const schemaPath = (p: Profile) => join(root, "extensions", p.dir, "schema.haus")
const extension = (p: Profile, entry: string) => import(pathToFileURL(join(root, "extensions", p.dir, "dist", entry)).href)

/** @haus-fmt/money, @haus-fmt/geo and @haus-fmt/uuid: the schema file compiled with the profile's codecs (`compileSchemaFile(…, { codecs })`). */
async function typescriptRunner(): Promise<Runner> {
  const compiled = new Map<string, Record<string, h.Schema<unknown>>>()
  for (const p of PROFILES) {
    const m = await extension(p, "index.js")
    // Each package exports its profile's codecs by the profile's short name: iso, wgs84, rfc9562.
    const codecs = m[p.short]
    const text = readFileSync(schemaPath(p), "utf8")
    compiled.set(p.name, compileSchemaFile(text, { ...schemaOptions(schemaPath(p)), codecs }).schemas as Record<string, h.Schema<unknown>>)
  }
  return inProcess("typescript", (p, type, value) => hRoundtrip(compiled.get(p.name)![type], value))
}

/** The same packages' `h.*` schemas (`Money`, `Currency`, `LatLng`, `BBox`, `Uuid`), for schemas written in TypeScript. */
async function typescriptHRunner(): Promise<Runner> {
  const schemas = new Map<string, Record<string, h.Schema<unknown>>>()
  for (const p of PROFILES) {
    const m = await extension(p, "index.js")
    schemas.set(p.name, Object.fromEntries(p.types.map((t) => [t, m[t]])))
  }
  return inProcess("typescript-h", (p, type, value) => hRoundtrip(schemas.get(p.name)![type], value))
}

/** Their `./effect` codec groups: `Haus.compileSchemaFile`, `decodeValue(schema, codecs)`, `encodeValue(schema, codecs)`. */
async function effectRunner(): Promise<Runner> {
  const dir = join(root, "typescript/packages/effect")
  const Haus = await import(pathToFileURL(join(dir, "dist/index.js")).href)
  const { Effect, Exit, Cause, Option } = await import(pathToFileURL(createRequire(join(dir, "package.json")).resolve("effect")).href)
  const coders = new Map<string, Record<string, { decode: (v: unknown) => unknown; encode: (v: unknown) => unknown }>>()
  for (const p of PROFILES) {
    const m = await extension(p, "effect.js")
    // Each package exports its profile's codecs by the profile's short name: iso, wgs84, rfc9562.
    const codecs = m[p.short]
    const schemas = Haus.compileSchemaFile(readFileSync(schemaPath(p), "utf8"), schemaOptions(schemaPath(p))).schemas
    coders.set(p.name, Object.fromEntries(p.types.map((t) => [t, { decode: Haus.decodeValue(schemas[t], codecs), encode: Haus.encodeValue(schemas[t], codecs) }])))
  }
  return inProcess("effect", (p, type, value) => {
    const coder = coders.get(p.name)![type]
    if (!coder) return { kind: "crash", reason: "CRASH: no such type" }
    const decoded = Effect.runSyncExit(coder.decode(value))
    if (Exit.isFailure(decoded)) {
      if (Cause.hasDies(decoded.cause)) return { kind: "crash", reason: `CRASH: ${String(decoded.cause).slice(0, 300)}` }
      const e = Option.getOrUndefined(Cause.findErrorOption(decoded.cause))
      return { kind: "err", place: e?.place ?? "$", code: e?.code ?? "-", reason: String(e?.message ?? decoded.cause).slice(0, 300) }
    }
    const encoded = Effect.runSyncExit(coder.encode(decoded.value))
    if (Exit.isFailure(encoded)) return { kind: "crash", reason: `CRASH: encoding failed: ${String(encoded.cause).slice(0, 300)}` }
    return { kind: "ok", text: canonical(encoded.value) }
  })
}

const allRunners: Runner[] = [
  external("lean", join(root, "spec/lean/.lake/build/bin/haus-ref"), (p) => ["--profile-batch", p.name]),
  await typescriptRunner(),
  await typescriptHRunner(),
  await effectRunner(),
  external("rust", join(root, "fuzz/schema-rust/target/release/profile_runner")),
  external("roc", join(root, "fuzz/.build/roc-profile-runner")),
  external("python", join(root, "python/.venv/bin/python"), () => [join(root, "python/fuzz/profile_runner.py")]),
  external("go", join(root, "fuzz/.build/go-runner"), () => ["--profile"]),
  external("jvm", join(root, "fuzz/.build/jvm-runner/bin/jvm-runner"), () => ["--profile"]),
]
const wanted = args.runners?.split(",")
const runners = allRunners.filter((r) => r.name === "lean" || !wanted || wanted.includes(r.name))
const profiles = PROFILES.filter((p) => !args.profiles || args.profiles.split(",").some((s) => s === p.short || s === p.name))

/** results[case][runner] */
function runAll(p: Profile, cases: readonly Case[]): Outcome[][] {
  mkdirSync(out, { recursive: true })
  const file = join(out, `cases-${p.short}.txt`)
  const byRunner = runners.map((r) => r.run(p, file, cases))
  return cases.map((_, i) => byRunner.map((rs) => rs[i]!))
}

// ── comparing ────────────────────────────────────────────────

/** Lean rejects the value by the profile's rule (the schema accepts it). */
const byProfile = (o: Outcome) => o.kind === "err" && o.code === "codec-rejected" && o.reason.startsWith("not accepted by")

/**
 * What is wrong with a runner's outcome, against Lean's, or undefined. The
 * text written must be the same; error codes are compared where both give
 * one at the same place; a value the profile rejects is `codec-rejected`
 * (profiles/*.md, "Encoding"), wherever the binding reports it. Reasons are
 * not compared.
 */
function problem(lean: Outcome, o: Outcome): string | undefined {
  if (lean.kind === "crash") return "lean crashed"
  if (o.kind === "crash") return "crash"
  if (lean.kind === "ok") return o.kind === "ok" ? (o.text === lean.text ? undefined : "writes another value") : "rejects"
  if (o.kind === "ok") return byProfile(lean) ? "accepts what the profile rejects" : "accepts what the schema rejects"
  if (byProfile(lean)) return o.code === "codec-rejected" ? undefined : `rejects with ${o.code}, not codec-rejected`
  if (lean.code !== "-" && o.code !== "-" && lean.place === o.place && lean.code !== o.code) return `code ${o.code}, Lean ${lean.code}`
  return undefined
}

/** The pattern of a case's disagreements: which runners, and how. Empty when all agree. */
const pattern = (rs: readonly Outcome[]) =>
  rs.slice(1).map((o, i) => [runners[i + 1]!.name, problem(rs[0]!, o)] as const).filter(([, why]) => why !== undefined).map(([n, why]) => `${n}: ${why}`).join("; ")

/** The shortest text with the same pattern of disagreement, by removing ever smaller slices. */
function shrink(p: Profile, c: Case, want: string): Case {
  let best = [...c.text]
  let size = Math.max(1, best.length >> 1)
  while (best.length > 0) {
    const candidates: Case[] = []
    for (let at = 0; at < best.length; at += size) candidates.push({ type: c.type, text: [...best.slice(0, at), ...best.slice(at + size)].join("") })
    const i = runAll(p, candidates).findIndex((rs) => pattern(rs) === want)
    if (i >= 0) best = [...candidates[i]!.text]
    else if (size > 1) size >>= 1
    else break
  }
  return { type: c.type, text: best.join("") }
}

// ── run ──────────────────────────────────────────────────────

const BATCH = 50_000
const SHRUNK_PER_PATTERN = 3
console.log(`seed ${seed}: ${count} cases per profile (${profiles.map((p) => p.short).join(", ")}) through ${runners.map((r) => r.name).join(", ")}`)
const found = new Map<string, { profile: Profile; case: Case; pattern: string; results: Outcome[] }>()
const shrunkPerPattern = new Map<string, number>()
let compared = 0
for (const p of profiles) {
  const rng = new Rng(seed * 31 + p.name.length)
  const stats = new Map(p.types.map((t) => [t, { accepted: 0, profile: 0, schema: 0, syntax: 0 }]))
  for (let done = 0; done < count; done += BATCH) {
    const cases = Array.from({ length: Math.min(BATCH, count - done) }, () => generate(rng, p))
    runAll(p, cases).forEach((rs, i) => {
      const c = cases[i]!
      const s = stats.get(c.type)!
      const lean = rs[0]!
      if (lean.kind === "ok") s.accepted++
      else if (byProfile(lean)) s.profile++
      else if (lean.kind === "err" && lean.code !== "-") s.schema++
      else s.syntax++
      for (const o of rs.slice(1)) if (lean.kind === "err" && o.kind === "err" && lean.code !== "-" && o.code !== "-" && lean.place === o.place) compared++
      const want = pattern(rs)
      if (want === "") return
      const n = shrunkPerPattern.get(want) ?? 0
      if (n >= SHRUNK_PER_PATTERN) return
      shrunkPerPattern.set(want, n + 1)
      const small = shrink(p, c, want)
      const key = `${p.short} ${small.type}(${JSON.stringify(small.text)})`
      if (!found.has(key)) found.set(key, { profile: p, case: small, pattern: want, results: runAll(p, [small])[0]! })
    })
  }
  console.log(`${p.name}:`)
  for (const [t, s] of stats) {
    console.log(`  ${t.padEnd(9)} ${s.accepted} accepted, ${s.profile} rejected by the profile, ${s.schema} by the schema, ${s.syntax} not one value (by lean)`)
  }
}
console.log(`${compared} error codes compared`)

if (found.size === 0) console.log("no disagreements")
for (const [key, f] of found) {
  console.log(`\nDISAGREEMENT (shrunk): ${key}\n  ${f.pattern}\n${f.results.map((o, i) => `  ${runners[i]!.name.padEnd(13)} ${show(o)}`).join("\n")}`)
}
mkdirSync(out, { recursive: true })
writeFileSync(join(out, "failures.txt"), [...found].map(([key, f]) => `${key}\n  ${f.pattern}\n${f.results.map((o, i) => `  ${runners[i]!.name.padEnd(13)} ${show(o)}`).join("\n")}\n`).join("\n"))
process.exitCode = found.size ? 1 : 0
