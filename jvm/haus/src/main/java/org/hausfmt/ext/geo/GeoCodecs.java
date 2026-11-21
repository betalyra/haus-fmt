package org.hausfmt.ext.geo;

import java.util.OptionalDouble;
import org.hausfmt.Codec;
import org.hausfmt.ErrorCode;
import org.hausfmt.HausException;
import org.hausfmt.Value;

/**
 * The codecs of the profile {@code @haus-fmt/geo/wgs84} (extensions/geo/profiles/wgs84.md) and the
 * ids of the package's types.
 */
public final class GeoCodecs {
  private GeoCodecs() {}

  /** The id of the type {@code LatLng} (spec §13.3). */
  public static final String LATLNG_ID = "@haus-fmt/geo@1#LatLng";

  /** The id of the type {@code BBox} (spec §13.3). */
  public static final String BBOX_ID = "@haus-fmt/geo@1#BBox";

  /** The codec of the wgs84 profile for {@code LatLng}, with the host type {@link LatLng}. */
  public static final Codec<LatLng> WGS84 = Codec.of(LATLNG_ID, LatLng.class, GeoCodecs::decodeLatLng, GeoCodecs::encodeLatLng);

  /**
   * The codec of the wgs84 profile for {@code BBox}, with the host type {@link BBox}. It checks
   * both corners itself.
   */
  public static final Codec<BBox> WGS84_BBOX = Codec.of(BBOX_ID, BBox.class, GeoCodecs::decodeBBox, GeoCodecs::encodeBBox);

  private static LatLng decodeLatLng(Value v) {
    if (!(v instanceof Value.Variant x) || !x.tag().equals("LatLng") || x.size() != 2) {
      throw rejected("expected LatLng(lat, lng)");
    }
    OptionalDouble lat = decodedFloat(x.get(0));
    OptionalDouble lng = decodedFloat(x.get(1));
    if (lat.isEmpty() || lng.isEmpty()) {
      throw rejected("a latitude and a longitude are finite numbers");
    }
    LatLng p = new LatLng(lat.getAsDouble(), lng.getAsDouble());
    String problem = problem(p);
    if (problem != null) {
      throw rejected(problem);
    }
    return p;
  }

  private static Value encodeLatLng(LatLng p) {
    String problem = problem(p);
    if (problem != null) {
      throw cannotEncode(problem);
    }
    return Value.variant("LatLng", Value.float64(p.lat()), Value.float64(p.lng()));
  }

  private static BBox decodeBBox(Value v) {
    if (!(v instanceof Value.Variant x) || !x.tag().equals("BBox") || x.size() != 2) {
      throw rejected("expected BBox(sw, ne)");
    }
    BBox b = new BBox(decodeLatLng(x.get(0)), decodeLatLng(x.get(1)));
    String problem = problem(b);
    if (problem != null) {
      throw rejected(problem);
    }
    return b;
  }

  private static Value encodeBBox(BBox b) {
    String problem = problem(b);
    if (problem != null) {
      throw cannotEncode(problem);
    }
    return Value.variant("BBox", encodeLatLng(b.sw()), encodeLatLng(b.ne()));
  }

  /**
   * A decoded {@code Float64}: a number in its one spelling, which reads back to the same float
   * (both round to nearest, ties to even, from the exact decimal). NaN and the infinities are tags,
   * so they are empty here.
   */
  private static OptionalDouble decodedFloat(Value v) {
    if (!(v instanceof Value.Number n)) {
      return OptionalDouble.empty();
    }
    double f = Double.parseDouble(n.literal());
    return Double.isInfinite(f) ? OptionalDouble.empty() : OptionalDouble.of(f);
  }

  /** A float's one spelling, for messages: {@code 90}, {@code -0}, {@code NaN}. */
  private static String floatText(double f) {
    Value v = Value.float64(f);
    return v instanceof Value.Number n ? n.literal() : ((Value.Variant) v).tag();
  }

  /** Why {@code p} breaks the rule, or null. NaN fails every comparison. */
  private static String problem(LatLng p) {
    if (!(p.lat() >= -90 && p.lat() <= 90)) {
      return "latitude " + floatText(p.lat()) + " is outside −90 to 90";
    }
    if (!(p.lng() >= -180 && p.lng() <= 180)) {
      return "longitude " + floatText(p.lng()) + " is outside −180 to 180";
    }
    return null;
  }

  /** Why {@code b} breaks the rule, or null. */
  private static String problem(BBox b) {
    String corner = problem(b.sw());
    if (corner != null) {
      return "south-west corner: " + corner;
    }
    corner = problem(b.ne());
    if (corner != null) {
      return "north-east corner: " + corner;
    }
    if (b.sw().lat() > b.ne().lat()) {
      return "the south-west corner (latitude " + floatText(b.sw().lat()) + ") is north of the north-east one ("
          + floatText(b.ne().lat()) + ")";
    }
    return null;
  }

  /** A value the profile rejects: the decoder reports it as {@code type-mismatch}, at the value. */
  private static IllegalArgumentException rejected(String message) {
    return new IllegalArgumentException(message);
  }

  /** A host value the profile doesn't allow to be written. */
  private static HausException cannotEncode(String message) {
    return HausException.of(ErrorCode.CANNOT_ENCODE, message);
  }
}
