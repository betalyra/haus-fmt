package org.hausfmt.ext;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.util.List;
import org.hausfmt.Codec;
import org.hausfmt.Codecs;
import org.hausfmt.ErrorCode;
import org.hausfmt.Haus;
import org.hausfmt.HausException;
import org.hausfmt.PackageLocator;
import org.hausfmt.Schema;
import org.hausfmt.SchemaOptions;
import org.hausfmt.SchemaType;
import org.hausfmt.Value;
import org.hausfmt.ext.geo.GeoCodecs;
import org.hausfmt.ext.money.MoneyCodecs;
import org.junit.jupiter.api.Test;

/**
 * {@code missing-codec} (spec §13.4, "A profile without its codec"): a type that an official profile
 * has a rule for, reached without a codec for its id.
 */
class MissingCodecTest {
  private static final String CURRENCY = "@haus-fmt/money@1#Currency";
  private static final String LAT_LNG = "@haus-fmt/geo@1#LatLng";
  private static final String BBOX = "@haus-fmt/geo@1#BBox";

  private static Schema schema(String text) {
    var packages =
        PackageLocator.explicit()
            .packageDir(Vectors.extension("money"))
            .packageDir(Vectors.extension("geo"));
    return Schema.parse(text, SchemaOptions.DEFAULT.withPackages(packages));
  }

  private static List<String> ids(List<HausException> warnings) {
    return warnings.stream()
        .map(
            w -> {
              assertEquals(ErrorCode.MISSING_CODEC, w.code());
              assertNull(w.path());
              return w.reason().split(" ")[0];
            })
        .toList();
  }

  /** A codec for the type id that keeps the value. */
  private static Codec<Value> keep(String id) {
    return Codec.of(id, Value.class, v -> v, v -> v);
  }

  private static final String ORDER =
      "import @haus-fmt/money (Money)\nimport @haus-fmt/geo (LatLng, BBox)\n"
          + "type Order = { total: Money, at?: Maybe LatLng, area: Array BBox }";

  @Test
  void eachListedTypeOnceNotWithItsCodecNorInsideATypeWithOne() {
    Schema s = schema(ORDER);
    SchemaType order = s.type("Order");
    // Money reaches Currency, and has no rule of its own; BBox reaches LatLng too: once.
    assertEquals(List.of(BBOX, LAT_LNG, CURRENCY), ids(order.missingCodecs(Codecs.NONE)));
    assertEquals(List.of(BBOX, LAT_LNG, CURRENCY), ids(s.missingCodecs(Codecs.NONE)));
    assertEquals(
        "@haus-fmt/money@1#Currency has profiles (iso), but no codec is set for it: its values are"
            + " checked for their shape only",
        order.missingCodecs(Codecs.NONE).get(2).reason());
    // The official profiles' codecs; a codec for Money covers its Currency.
    assertEquals(
        List.of(), ids(order.missingCodecs(Codecs.of(MoneyCodecs.ISO, GeoCodecs.WGS84, GeoCodecs.WGS84_BBOX))));
    assertEquals(
        List.of(), ids(order.missingCodecs(Codecs.of(keep(CURRENCY), keep(LAT_LNG), keep(BBOX)))));
    // A codec for BBox covers the LatLngs inside it, not the one of `at`.
    assertEquals(List.of(LAT_LNG), ids(order.missingCodecs(Codecs.of(MoneyCodecs.ISO, GeoCodecs.WGS84_BBOX))));
    // Only a warning: decoding is the same.
    order.decode(Haus.parse("{ total: Money(1, Eur), area: [] }"));
  }

  @Test
  void onlyWhatIsReached() {
    // BBox is imported, but no definition uses it.
    Schema s = schema("import @haus-fmt/geo (LatLng, BBox)\ntype Root = { at: LatLng }");
    assertEquals(List.of(LAT_LNG), ids(s.missingCodecs(Codecs.NONE)));
    assertEquals(List.of(BBOX, LAT_LNG), ids(s.type("BBox").missingCodecs(Codecs.NONE)));
    // Through generic types, variants, maps and secrets.
    s =
        schema(
            "import @haus-fmt/money (Currency)\ntype Page a = { items: Array a }\n"
                + "type Root = < A (Page (Map (Secret Currency))) | B >");
    assertEquals(List.of(CURRENCY), ids(s.missingCodecs(Codecs.NONE)));
    assertEquals(List.of(), ids(schema("import std/time (Date)\ntype Root = { d: Date }").missingCodecs(Codecs.NONE)));
  }
}
