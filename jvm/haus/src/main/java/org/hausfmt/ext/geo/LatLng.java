package org.hausfmt.ext.geo;

/**
 * A point: {@code LatLng(38.7223, -9.1393)} is Lisbon. Any doubles can be held; the codecs check
 * the profile's ranges when they encode it.
 *
 * @param lat the latitude in degrees, −90 to 90 for the profile
 * @param lng the longitude in degrees, −180 to 180 for the profile
 */
public record LatLng(double lat, double lng) {}
