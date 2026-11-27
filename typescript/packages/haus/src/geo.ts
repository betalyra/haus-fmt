/**
 * `@haus-fmt/geo` (an official package, built into every compile): points
 * and boxes on the earth, in degrees of WGS 84, latitude first, with the rule
 * wgs84 (extensions/geo/profiles/wgs84.md): −90 ≤ lat ≤ 90,
 * −180 ≤ lng ≤ 180, and a box's south-west corner not north of its
 * north-east one.
 *
 *   import { LatLng } from "@haus-fmt/haus/geo"
 *   Schema.decode(schema, LatLng)(`LatLng(38.7223, -9.1393)`)   // { _tag: "LatLng", values: [38.7223, -9.1393] }
 */
import { bboxProblem, geo, latLngProblem } from "./official.js"
import { Type, type Host, type TypeLambda } from "./types.js"

export { bboxProblem, geo, latLngProblem }

/** The ids of the package's types (spec §13.3, "Identity"). */
export const LATLNG_ID = "@haus-fmt/geo@1#LatLng"
export const BBOX_ID = "@haus-fmt/geo@1#BBox"

/** A point, latitude first, in degrees. */
export type LatLng<H = {}> = {
  readonly _tag: "LatLng"
  readonly values: readonly [lat: Host<H, "prelude#Float64", number>, lng: Host<H, "prelude#Float64", number>]
}
/** A box from its south-west corner to its north-east corner. */
export type BBox<H = {}> = {
  readonly _tag: "BBox"
  readonly values: readonly [sw: Host<H, typeof LATLNG_ID, LatLng<H>>, ne: Host<H, typeof LATLNG_ID, LatLng<H>>]
}

export interface LatLng$ extends TypeLambda {
  readonly type: Host<this["hosts"], typeof LATLNG_ID, LatLng<this["hosts"]>>
}
export interface BBox$ extends TypeLambda {
  readonly type: Host<this["hosts"], typeof BBOX_ID, BBox<this["hosts"]>>
}

/** The handle of `@haus-fmt/geo@1#LatLng`. */
export const LatLng: Type<LatLng$, typeof LATLNG_ID> = Type.make(LATLNG_ID)
/** The handle of `@haus-fmt/geo@1#BBox`. */
export const BBox: Type<BBox$, typeof BBOX_ID> = Type.make(BBOX_ID)
