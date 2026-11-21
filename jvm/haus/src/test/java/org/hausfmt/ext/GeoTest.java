package org.hausfmt.ext;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.Map;
import java.util.stream.Stream;
import org.hausfmt.Haus;
import org.hausfmt.ext.geo.BBox;
import org.hausfmt.ext.geo.GeoCodecs;
import org.hausfmt.ext.geo.LatLng;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;

/** The codecs of the profile @haus-fmt/geo/wgs84 (extensions/geo/profiles/wgs84.md). */
class GeoTest {
  @TestFactory
  Stream<DynamicTest> wgs84Vectors() {
    return Vectors.run("geo", "wgs84", Map.of("LatLng", GeoCodecs.WGS84, "BBox", GeoCodecs.WGS84_BBOX));
  }

  private static void assertCannotEncode(org.junit.jupiter.api.function.Executable e) {
    assertEquals(org.hausfmt.ErrorCode.CANNOT_ENCODE, assertThrows(org.hausfmt.HausException.class, e).code());
  }

  @Test
  void encodeChecksTheRule() {
    // cannot-encode, as in Go.
    assertCannotEncode(() -> GeoCodecs.WGS84.encode(new LatLng(Double.NaN, 0)));
    assertCannotEncode(() -> GeoCodecs.WGS84.encode(new LatLng(0, 181)));
    assertCannotEncode(
        () -> GeoCodecs.WGS84_BBOX.encode(new BBox(new LatLng(1, 0), new LatLng(0, 0))));
  }

  @Test
  void negativeZeroIsKept() {
    assertEquals("LatLng(-0,0)", Haus.canonical(GeoCodecs.WGS84.encode(new LatLng(-0.0, 0))));
    assertEquals(new LatLng(-0.0, 0), GeoCodecs.WGS84.decode(Haus.parse("LatLng(-0, 0)")));
  }

  @Test
  void floatsAreWrittenInTheirOneSpelling() {
    assertEquals("LatLng(38.8,-9.09)", Haus.canonical(GeoCodecs.WGS84.encode(new LatLng(38.80, -9.09))));
    assertEquals("LatLng(1e-7,5e-324)", Haus.canonical(GeoCodecs.WGS84.encode(new LatLng(1e-7, Double.MIN_VALUE))));
  }

  @Test
  void rejectionsSayWhy() {
    IllegalArgumentException e = assertThrows(IllegalArgumentException.class,
        () -> GeoCodecs.WGS84_BBOX.decode(Haus.parse("BBox(LatLng(10, 0), LatLng(-0, 1))")));
    assertEquals("the south-west corner (latitude 10) is north of the north-east one (-0)", e.getMessage());
    e = assertThrows(IllegalArgumentException.class, () -> GeoCodecs.WGS84.decode(Haus.parse("LatLng(0, -180.5)")));
    assertEquals("longitude -180.5 is outside −180 to 180", e.getMessage());
  }
}
