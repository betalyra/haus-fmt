/**
 * The profile @haus-fmt/geo/wgs84 (profiles/wgs84.md) for haus schemas
 * (`@haus-fmt/haus/schema`): codecs for schema files and the types as
 * schemas.
 *
 *   import { wgs84 } from "@haus-fmt/geo"
 *
 *   const { schemas } = compileSchemaFile(text, { ...schemaOptions(path), codecs: wgs84 })
 *   h.parse(schemas.Trip!, `{ to: LatLng(38.7223, -9.1393) }`)   // ok
 *   h.parse(schemas.Trip!, `{ to: LatLng(91, 0) }`)              // HausDecodeError: latitude out of range
 *
 * The codecs keep the value (spec §13.4): the floats as decoded, `-0`
 * included, the poles and the antimeridian not normalised. They only reject more.
 */
import type { Codec } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"

/** The type ids the codecs target (spec §13.3, "Identity"). */
export const LATLNG_ID = "@haus-fmt/geo@1#LatLng"
export const BBOX_ID = "@haus-fmt/geo@1#BBox"

/** A point, latitude first, in degrees. */
export interface LatLng {
  readonly _tag: "LatLng"
  readonly values: readonly [lat: number, lng: number]
}

/** A box from its south-west corner to its north-east corner. */
export interface BBox {
  readonly _tag: "BBox"
  readonly values: readonly [sw: LatLng, ne: LatLng]
}

const isObject = (u: unknown): u is Readonly<Record<string, unknown>> => typeof u === "object" && u !== null

/** The arguments of `Tag(…)` as a schema decodes it (`{ _tag, values }`), if `u` is one with `n` of them. */
const args = (u: unknown, tag: string, n: number): readonly unknown[] | undefined =>
  isObject(u) && u._tag === tag && Array.isArray(u.values) && u.values.length === n ? (u.values as readonly unknown[]) : undefined

/** `x` is a float in [min, max]; NaN and the infinities are not. */
const within = (x: unknown, min: number, max: number): x is number => typeof x === "number" && x >= min && x <= max

/** Why the wgs84 profile rejects a `LatLng`, or undefined: −90 ≤ lat ≤ 90 and −180 ≤ lng ≤ 180. */
export const latLngProblem = (point: unknown): string | undefined => {
  const p = args(point, "LatLng", 2)
  if (!p) return "not a LatLng"
  const [lat, lng] = p
  if (!within(lat, -90, 90)) return `latitude ${String(lat)} out of range: the wgs84 profile takes -90 to 90`
  if (!within(lng, -180, 180)) return `longitude ${String(lng)} out of range: the wgs84 profile takes -180 to 180`
  return undefined
}

/**
 * Why the wgs84 profile rejects a `BBox`, or undefined: both corners are
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

export const isLatLng = (point: unknown): point is LatLng => latLngProblem(point) === undefined
export const isBBox = (box: unknown): box is BBox => bboxProblem(box) === undefined

/**
 * The wgs84 profile's codecs, for `compileSchemaFile(…, { codecs: wgs84 })`.
 * They apply wherever their types occur, inside imported packages too; the
 * one for `BBox` checks its corners as well.
 */
export const wgs84: readonly Codec[] = [
  { id: LATLNG_ID, apply: (base) => h.refine(base, latLngProblem) },
  { id: BBOX_ID, apply: (base) => h.refine(base, bboxProblem) },
]

/** `LatLng` with the wgs84 profile, for schemas written with `h.*`: `h.Record({ at: LatLng })`. */
export const LatLng: h.Schema<LatLng> = h.refine(h.Variant({ LatLng: h.Tuple(h.Float64, h.Float64) }), latLngProblem)

/** `BBox` with the wgs84 profile, for schemas written with `h.*`. */
export const BBox: h.Schema<BBox> = h.refine(h.Variant({ BBox: h.Tuple(LatLng, LatLng) }), bboxProblem)
