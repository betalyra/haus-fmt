package org.hausfmt.ext.geo;

import java.util.Objects;

/**
 * A box from its south-west corner to its north-east corner. A box whose south-west longitude is
 * greater than its north-east one crosses the antimeridian.
 *
 * @param sw the south-west corner
 * @param ne the north-east corner
 */
public record BBox(LatLng sw, LatLng ne) {
  /** A box; neither corner may be null. */
  public BBox {
    Objects.requireNonNull(sw, "sw");
    Objects.requireNonNull(ne, "ne");
  }
}
