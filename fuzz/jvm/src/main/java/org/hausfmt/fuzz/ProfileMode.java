package org.hausfmt.fuzz;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.hausfmt.Codec;
import org.hausfmt.Codecs;
import org.hausfmt.DecodeOptions;
import org.hausfmt.Haus;
import org.hausfmt.HausException;
import org.hausfmt.Schema;
import org.hausfmt.SchemaType;
import org.hausfmt.Value;
import org.hausfmt.ext.geo.GeoCodecs;
import org.hausfmt.ext.money.MoneyCodecs;
import org.hausfmt.ext.uuid.UuidCodecs;

/**
 * The profile fuzzer's mode ({@code profiles.ts}), as the Go runner's (fuzz/go/profile.go): lines
 * {@code TYPE HEX} (a value's haus text as hex UTF-8). The value is decoded with the type of its
 * package's schema (extensions/money, extensions/geo, extensions/uuid) and the codecs of the
 * official profile ({@link MoneyCodecs#ISO} and {@link MoneyCodecs#ISO_CURRENCY}, {@link
 * GeoCodecs#WGS84} and {@link GeoCodecs#WGS84_BBOX}, {@link UuidCodecs#RFC9562_AS_UUID}, which
 * runs the rule and {@code java.util.UUID} both ways), turned into the host value by the type's codec and encoded again: {@code
 * ok <canonical form>}, or {@code err <place> <code> <reason>}. Encoding what was decoded must
 * work, so an encoding error is {@code crash …}.
 */
final class ProfileMode {
  private ProfileMode() {}

  /** A type of a package's schema, its codec and its profile's codecs. */
  private record Profiled(SchemaType type, Codec<?> codec, DecodeOptions options) {}

  /** A package and its profile's codecs, by type name. */
  private record Extension(String dir, Map<String, Codec<?>> codecs) {}

  private static final List<Extension> EXTENSIONS = List.of(
      new Extension("money", Map.of("Money", MoneyCodecs.ISO, "Currency", MoneyCodecs.ISO_CURRENCY)),
      new Extension("geo", Map.of("LatLng", GeoCodecs.WGS84, "BBox", GeoCodecs.WGS84_BBOX)),
      new Extension("uuid", Map.of("Uuid", UuidCodecs.RFC9562_AS_UUID)));

  /** Each package's schema with its profile's codecs, by type name. */
  private static Map<String, Profiled> types() {
    Map<String, Profiled> out = new HashMap<>();
    for (Extension p : EXTENSIONS) {
      Schema s = Schema.load(SchemaModes.root().resolve("extensions").resolve(p.dir).resolve("schema.haus"));
      DecodeOptions options = DecodeOptions.DEFAULT.withCodecs(Codecs.of(p.codecs.values()));
      p.codecs.forEach((name, codec) -> out.put(name, new Profiled(s.type(name), codec, options)));
    }
    return out;
  }

  static Function<String, String> lines() {
    Map<String, Profiled> types = types();
    return line -> {
      int space = line.indexOf(' ');
      String name = space < 0 ? line : line.substring(0, space);
      Profiled t = types.get(name);
      if (t == null) {
        return "crash no type " + name;
      }
      Value v;
      try {
        v = SchemaModes.single(Runner.unhex(space < 0 ? "" : line.substring(space + 1)));
      } catch (SchemaModes.NotOne e) {
        return e.line;
      }
      return roundtrip(t.type, t.codec, v, t.options);
    };
  }

  /**
   * Decodes {@code v} with the type and the codecs, and encodes it again through the host value:
   * the type's codec decodes what the schema decoded and encodes it back, so both directions of
   * the codec run, then the type encodes that value with the codecs.
   */
  private static <T> String roundtrip(SchemaType t, Codec<T> codec, Value v, DecodeOptions options) {
    Value decoded;
    try {
      decoded = t.decode(v, options);
    } catch (HausException e) {
      return Runner.placed(e);
    }
    try {
      return "ok " + Haus.canonical(t.encode(codec.encode(codec.decode(decoded)), options));
    } catch (RuntimeException e) {
      return "crash encoding failed: " + e;
    }
  }
}
