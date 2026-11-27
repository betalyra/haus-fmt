/**
 * Retired: `@haus-fmt/geo` is built into `@haus-fmt/haus` (import
 * `@haus-fmt/haus/geo`), with its rule wgs84 on by default; with Effect,
 * `@haus-fmt/effect/geo`. This module is no longer published.
 */
import { BBOX_ID, bboxProblem, LATLNG_ID, latLngProblem } from "@haus-fmt/haus/geo"

export { BBOX_ID, bboxProblem, LATLNG_ID, latLngProblem }

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

export const isLatLng = (point: unknown): point is LatLng => latLngProblem(point) === undefined
export const isBBox = (box: unknown): box is BBox => bboxProblem(box) === undefined
