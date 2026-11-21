/**
 * The codecs of the profile {@code @haus-fmt/geo/wgs84} for the types of the schema package
 * {@code @haus-fmt/geo} (extensions/geo): {@link org.hausfmt.ext.geo.LatLng}, a point, and {@link
 * org.hausfmt.ext.geo.BBox}, a box, in degrees of WGS 84, latitude first.
 *
 * <p>The schema fixes the shape; the profile's rule, which these codecs check, is on the decoded
 * floats (extensions/geo/profiles/wgs84.md): −90 ≤ lat ≤ 90 and −180 ≤ lng ≤ 180, so NaN and the
 * infinities are rejected, and a box's south-west corner is not north of its north-east one.
 * Negative zero is kept, and nothing is normalised.
 */
package org.hausfmt.ext.geo;
