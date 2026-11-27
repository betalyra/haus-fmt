/**
 * The official packages, built into every compile (packages.md §3), with
 * their rules (packages.md §6, `extensions/<name>/profiles/<rule>.md`):
 *
 *   @haus-fmt/money  Currency: iso      a tag of three letters A–Z (Money through its Currency)
 *   @haus-fmt/geo    LatLng, BBox: wgs84  −90 ≤ lat ≤ 90, −180 ≤ lng ≤ 180; a box's south-west corner not north of its north-east one
 *   @haus-fmt/uuid   Uuid: rfc9562      the text of RFC 9562 in lowercase, 8-4-4-4-12
 *
 * Each rule is checked on the value the type's schema decoded, before any
 * codec, and rejects any shape it doesn't expect.
 */
import { packageOf, type Package, type Rule } from "./package.js"
import { GEO_MANIFEST, GEO_SCHEMA, MONEY_MANIFEST, MONEY_SCHEMA, UUID_MANIFEST, UUID_SCHEMA } from "./official-texts.js"
import { Result } from "./result.js"

// ── @haus-fmt/money, iso ─────────────────────────────────────

const CODE = /^[A-Z]{3}$/

/** Why the rule iso rejects a `Currency` as its schema decodes it (a tag's name; a tag with a payload is an `Unknown`), or undefined. */
export const currencyProblem = (currency: unknown): string | undefined =>
  typeof currency === "string" && CODE.test(currency) ? undefined
  : typeof currency === "string" ? `${JSON.stringify(currency)} is not a currency of the rule iso: three letters A–Z`
  : "not a currency of the rule iso: a tag of three letters A–Z, without payload"

// ── @haus-fmt/geo, wgs84 ─────────────────────────────────────

const isObject = (u: unknown): u is Readonly<Record<string, unknown>> => typeof u === "object" && u !== null

/** The arguments of `Tag(…)` as a schema decodes it (`{ _tag, values }`), if `u` is one with `n` of them. */
const args = (u: unknown, tag: string, n: number): readonly unknown[] | undefined =>
  isObject(u) && u._tag === tag && Array.isArray(u.values) && u.values.length === n ? (u.values as readonly unknown[]) : undefined

/** `x` is a float in [min, max]; NaN and the infinities are not. */
const within = (x: unknown, min: number, max: number): x is number => typeof x === "number" && x >= min && x <= max

/** Why the rule wgs84 rejects a `LatLng`, or undefined: −90 ≤ lat ≤ 90 and −180 ≤ lng ≤ 180. */
export const latLngProblem = (point: unknown): string | undefined => {
  const p = args(point, "LatLng", 2)
  if (!p) return "not a LatLng"
  const [lat, lng] = p
  if (!within(lat, -90, 90)) return `latitude ${String(lat)} out of range: the rule wgs84 takes -90 to 90`
  if (!within(lng, -180, 180)) return `longitude ${String(lng)} out of range: the rule wgs84 takes -180 to 180`
  return undefined
}

/**
 * Why the rule wgs84 rejects a `BBox`, or undefined: both corners are
 * accepted as `LatLng`s and `sw.lat` ≤ `ne.lat`. The longitudes aren't
 * ordered: `sw.lng` > `ne.lng` crosses the antimeridian.
 */
export const bboxProblem = (box: unknown): string | undefined => {
  const b = args(box, "BBox", 2)
  if (!b) return "not a BBox"
  const [sw, ne] = b
  const corner = latLngProblem(sw) ?? latLngProblem(ne)
  if (corner !== undefined) return `a corner: ${corner}`
  const [swLat] = args(sw, "LatLng", 2)!
  const [neLat] = args(ne, "LatLng", 2)!
  return (swLat as number) <= (neLat as number) ? undefined : `the south-west corner (latitude ${String(swLat)}) is north of the north-east one (${String(neLat)})`
}

// ── @haus-fmt/uuid, rfc9562 ──────────────────────────────────

const UUID_TEXT = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/** Why the rule rfc9562 rejects a `Uuid` as its schema decodes it (`{ _tag: "Uuid", values: [text] }`), or undefined. */
export const uuidProblem = (uuid: unknown): string | undefined => {
  const [text] = args(uuid, "Uuid", 1) ?? []
  return typeof text === "string" && UUID_TEXT.test(text) ? undefined : "not a UUID of the rule rfc9562: 32 digits 0–9, a–f in groups of 8-4-4-4-12, joined by hyphens"
}

// ── the packages ─────────────────────────────────────────────

/** A rule from a function giving why it rejects a value. */
const rule = (problem: (value: unknown) => string | undefined): Rule => (value) => {
  const why = problem(value)
  return why === undefined ? Result.succeed(value) : Result.fail(why)
}

const official = (manifest: string, schema: string, rules: Readonly<Record<string, Rule>>): Package =>
  packageOf({ manifest, schema, rules }, { kind: "built-in" })

/** `@haus-fmt/money`, with the rule iso for `Currency`. */
export const money: Package = official(MONEY_MANIFEST, MONEY_SCHEMA, { Currency: rule(currencyProblem) })
/** `@haus-fmt/geo`, with the rule wgs84 for `LatLng` and `BBox`. */
export const geo: Package = official(GEO_MANIFEST, GEO_SCHEMA, { LatLng: rule(latLngProblem), BBox: rule(bboxProblem) })
/** `@haus-fmt/uuid`, with the rule rfc9562 for `Uuid`. */
export const uuid: Package = official(UUID_MANIFEST, UUID_SCHEMA, { Uuid: rule(uuidProblem) })

/** The built-in packages, by name. */
export const OFFICIAL: ReadonlyMap<string, Package> = new Map([money, geo, uuid].map((p) => [p.name, p]))
