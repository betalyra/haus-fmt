/**
 * `@haus-fmt/geo` with Effect: the official package, built into every
 * compile with its rule wgs84 (extensions/geo/profiles/wgs84.md) on by
 * default, and a codec for host types.
 *
 *   import { geo, wgs84Types } from "@haus-fmt/effect/geo"
 *
 *   const trip = yield* Haus.decode(schemas.Trip, wgs84Types)(text)   // trip.to: LatLng
 *   Haus.Package.shapeOnly(geo)                                        // to check coordinates for their shape only
 *
 * The rule is checked whatever the codecs (`LatLng(91, 0)` fails with
 * `codec-rejected`); the codecs give the types `LatLng` and `BBox` below and
 * keep the value (spec §13.4): the floats as decoded, `-0` included.
 */
import { BBOX_ID, bboxProblem, geo, LATLNG_ID, latLngProblem } from "@haus-fmt/haus/geo"
import { Schema } from "effect"
import { codecs, CodecTypeId, type Codec } from "./codec.js"
import { CODEC_REJECTED } from "./index.js"

export { BBOX_ID, bboxProblem, geo, LATLNG_ID, latLngProblem }

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

const latLng: Codec<{ readonly [LATLNG_ID]: LatLng }, typeof LATLNG_ID> = {
  [CodecTypeId]: [{ id: LATLNG_ID, apply: (base) => base.pipe(Schema.check(Schema.makeFilter(latLngProblem, CODEC_REJECTED))) }],
}

const bbox: Codec<{ readonly [BBOX_ID]: BBox }, typeof BBOX_ID> = {
  [CodecTypeId]: [{ id: BBOX_ID, apply: (base) => base.pipe(Schema.check(Schema.makeFilter(bboxProblem, CODEC_REJECTED))) }],
}

/**
 * A codec group: `LatLng` and `BBox` wherever they occur, inside imported
 * packages too, as the types above. A group: a schema with only one of the
 * types takes it too.
 */
export const wgs84Types = codecs(latLng, bbox)
