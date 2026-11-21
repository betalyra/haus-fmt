/**
 * The profile @haus-fmt/geo/wgs84 (profiles/wgs84.md) for Effect
 * (`@haus-fmt/effect`): a codec group.
 *
 *   import { wgs84 } from "@haus-fmt/geo/effect"
 *
 *   const trip = yield* Haus.decode(Trip, wgs84)(text)   // LatLng(91, 0) fails
 *
 * The codecs keep the value and the type (spec §13.4): the floats as
 * decoded, `-0` included, the poles and the antimeridian not normalised.
 * They only reject more.
 */
import * as Haus from "@haus-fmt/effect"
import { Schema } from "effect"
import { BBOX_ID, bboxProblem, LATLNG_ID, latLngProblem, type BBox, type LatLng } from "./index.js"

export { BBOX_ID, bboxProblem, isBBox, isLatLng, LATLNG_ID, latLngProblem, type BBox, type LatLng } from "./index.js"

const latLng: Haus.Codec<{ readonly [LATLNG_ID]: LatLng }, typeof LATLNG_ID> = {
  [Haus.CodecTypeId]: [{ id: LATLNG_ID, apply: (base) => base.pipe(Schema.check(Schema.makeFilter(latLngProblem, Haus.CODEC_REJECTED))) }],
}

const bbox: Haus.Codec<{ readonly [BBOX_ID]: BBox }, typeof BBOX_ID> = {
  [Haus.CodecTypeId]: [{ id: BBOX_ID, apply: (base) => base.pipe(Schema.check(Schema.makeFilter(bboxProblem, Haus.CODEC_REJECTED))) }],
}

/**
 * The wgs84 profile's codecs, for `LatLng` and `BBox` wherever they occur,
 * inside imported packages too; the one for `BBox` checks its corners as
 * well. A group: a schema with only one of the types takes it too.
 */
export const wgs84 = Haus.codecs(latLng, bbox)
