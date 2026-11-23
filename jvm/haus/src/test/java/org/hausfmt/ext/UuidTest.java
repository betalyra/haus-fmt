package org.hausfmt.ext;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Stream;
import org.hausfmt.Codecs;
import org.hausfmt.DecodeOptions;
import org.hausfmt.ErrorCode;
import org.hausfmt.Haus;
import org.hausfmt.HausException;
import org.hausfmt.PackageLocator;
import org.hausfmt.Schema;
import org.hausfmt.SchemaOptions;
import org.hausfmt.SchemaType;
import org.hausfmt.Value;
import org.hausfmt.ext.uuid.UuidCodecs;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;

/** The codecs of the profile @haus-fmt/uuid/rfc9562 (extensions/uuid/profiles/rfc9562.md). */
class UuidTest {
  private static final String ID = "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57";

  @TestFactory
  Stream<DynamicTest> rfc9562Vectors() {
    return Vectors.run("uuid", "rfc9562", Map.of("Uuid", UuidCodecs.RFC9562));
  }

  @TestFactory
  Stream<DynamicTest> rfc9562VectorsAsUuid() {
    return Vectors.run("uuid", "rfc9562", Map.of("Uuid", UuidCodecs.RFC9562_AS_UUID));
  }

  @Test
  void theLowercaseTextFormOfAnyVersion() {
    for (String s : List.of(ID, "00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff")) {
      assertTrue(UuidCodecs.isValid(s), s);
    }
    for (char v : "0123456789abcdef".toCharArray()) {
      assertTrue(UuidCodecs.isValid("0190c7a8-5b6e-" + v + "d3f-" + v + "a41-6c2e8f1b0d57"));
    }
    for (String s :
        List.of(
            ID.toUpperCase(Locale.ROOT),
            "{" + ID + "}",
            "urn:uuid:" + ID,
            ID.replace("-", ""),
            ID.substring(1),
            ID + "0",
            " " + ID,
            ID + "\n",
            ID.substring(0, 35) + "٧",
            "",
            "0190c7a-85b6e-7d3f-9a41-6c2e8f1b0d57",
            ID.replaceFirst("-", "0"),
            ID.replaceFirst("d", "g"))) {
      assertFalse(UuidCodecs.isValid(s), s);
    }
  }

  @Test
  void decodesToTheTextOrAUuid() {
    Value v = Haus.parse("Uuid(\"" + ID + "\")");
    assertEquals(ID, UuidCodecs.RFC9562.decode(v));
    assertEquals(UUID.fromString(ID), UuidCodecs.RFC9562_AS_UUID.decode(v));
    assertEquals("Uuid(\"" + ID + "\")", Haus.canonical(UuidCodecs.RFC9562.encode(ID)));
    assertEquals(
        "Uuid(\"ffffffff-ffff-ffff-ffff-ffffffffffff\")",
        Haus.canonical(UuidCodecs.RFC9562_AS_UUID.encode(new UUID(-1L, -1L))));
  }

  @Test
  void encodeChecksTheRule() {
    // cannot-encode, as in Go.
    HausException e =
        assertThrows(HausException.class, () -> UuidCodecs.RFC9562.encode(ID.toUpperCase(Locale.ROOT)));
    assertEquals(ErrorCode.CANNOT_ENCODE, e.code());
  }

  @Test
  void appliesInsideImportedTypesAtTheUuidsPlace() {
    Schema s =
        Schema.parse(
            "import @haus-fmt/uuid@1 (Uuid)\ntype User = { id: Uuid, friends: Array Uuid }",
            SchemaOptions.DEFAULT.withPackages(PackageLocator.explicit().packageDir(Vectors.extension("uuid"))));
    SchemaType user = s.type("User");
    DecodeOptions options = DecodeOptions.DEFAULT.withCodecs(Codecs.of(UuidCodecs.RFC9562));
    String upper = ID.toUpperCase(Locale.ROOT);
    HausException e =
        assertThrows(
            HausException.class,
            () -> user.decode(Haus.parse("{ id: Uuid(\"" + ID + "\"), friends: [Uuid(\"" + upper + "\")] }"), options));
    assertEquals(ErrorCode.CODEC_REJECTED, e.code(), e.getMessage());
    assertEquals("$.friends[0]", e.path(), e.getMessage());
  }
}
