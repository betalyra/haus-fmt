package org.hausfmt.ext;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Map;
import java.util.stream.Stream;
import org.hausfmt.Codec;
import org.hausfmt.Codecs;
import org.hausfmt.DecodeOptions;
import org.hausfmt.ErrorCode;
import org.hausfmt.Haus;
import org.hausfmt.HausException;
import org.hausfmt.Schema;
import org.hausfmt.SchemaType;
import org.hausfmt.Value;
import org.junit.jupiter.api.DynamicTest;

/** The test vectors of a profile (spec §13.3, "Profiles"): extensions/*\/profiles/*.vectors.haus. */
final class Vectors {
  private Vectors() {}

  /** The directory of an official extension, from the repository the build names. */
  static Path extension(String name) {
    String root = System.getProperty("haus.root");
    if (root == null) {
      throw new IllegalStateException("haus.root is not set: run the tests with Gradle");
    }
    return Paths.get(root, "extensions", name);
  }

  /**
   * A test for each vector of the profile {@code profile} of the extension, with its codecs by
   * type name:
   *
   * <ul>
   *   <li>{@code Accept}: {@code value} (haus text of {@code type}) is accepted, and encoding what
   *       the codec decoded writes exactly {@code output}, or {@code value} when there is none;
   *   <li>{@code Reject}: {@code value} is valid for the schema of {@code type}, and the codec
   *       rejects it with {@code codec-rejected}, at the value.
   * </ul>
   */
  static Stream<DynamicTest> run(String extension, String profile, Map<String, Codec<?>> codecs) {
    Path dir = extension(extension);
    Schema schema = Schema.load(dir.resolve("schema.haus"));
    Codecs all = Codecs.of(codecs.values());
    byte[] file;
    try {
      file = Files.readAllBytes(dir.resolve("profiles").resolve(profile + ".vectors.haus"));
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
    return Haus.parseAll(file).stream().map(v -> {
      Value.Variant x = (Value.Variant) v;
      Value.Record r = (Value.Record) x.get(0);
      String name = text(r, "type");
      String value = text(r, "value");
      String output = r.containsKey("output") ? text(r, "output") : value;
      return dynamicTest(x.tag() + " " + value, () -> {
        SchemaType ty = schema.type(name);
        Codec<?> codec = codecs.get(name);
        assertTrue(codec != null && codec.typeId().equals(ty.id()), "no codec for " + name + " (" + ty.id() + ")");
        Value parsed = Haus.parse(value);
        DecodeOptions own = DecodeOptions.DEFAULT.withCodecs(Codecs.of(codec));
        switch (x.tag()) {
          case "Accept":
            assertEquals(output, written(ty, parsed, codec, own, DecodeOptions.DEFAULT.withCodecs(all)));
            break;
          case "Reject":
            ty.decode(parsed);
            // With the type's own codec, at the value; with all of them, a codec of a part may
            // reject it first, at the part.
            HausException e = assertThrows(HausException.class, () -> ty.decode(parsed, own));
            assertEquals(ErrorCode.CODEC_REJECTED, e.code(), e.getMessage());
            assertTrue(e.path() == null || e.path().equals("$"), e.getMessage());
            e = assertThrows(HausException.class, () -> ty.decode(parsed, DecodeOptions.DEFAULT.withCodecs(all)));
            assertEquals(ErrorCode.CODEC_REJECTED, e.code(), e.getMessage());
            break;
          default:
            throw new AssertionError("unknown vector " + x.tag());
        }
      });
    });
  }

  /** Decodes with the type and its codec, encodes the host value back, and writes it on its line. */
  private static <T> String written(SchemaType ty, Value v, Codec<T> codec, DecodeOptions own, DecodeOptions all) {
    T host = codec.decode(ty.decode(v, own));
    String out = Haus.write(ty.encode(codec.encode(host), all));
    return out.endsWith("\n") ? out.substring(0, out.length() - 1) : out;
  }

  private static String text(Value.Record r, String key) {
    return ((Value.Text) r.get(key)).value();
  }
}
