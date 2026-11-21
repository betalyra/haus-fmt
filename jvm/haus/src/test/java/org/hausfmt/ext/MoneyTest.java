package org.hausfmt.ext;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.nio.charset.StandardCharsets;
import java.util.Map;
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
import org.hausfmt.ext.money.Currency;
import org.hausfmt.ext.money.Money;
import org.hausfmt.ext.money.MoneyCodecs;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;

/** The codecs of the profile @haus-fmt/money/iso (extensions/money/profiles/iso.md). */
class MoneyTest {
  @TestFactory
  Stream<DynamicTest> isoVectors() {
    return Vectors.run("money", "iso", Map.of("Money", MoneyCodecs.ISO, "Currency", MoneyCodecs.ISO_CURRENCY));
  }

  @Test
  void decodesToTheHostTypeKeepingTheScale() {
    Money m = MoneyCodecs.ISO.decode(Haus.parse("Money(19.90, EUR)"));
    assertEquals("19.90", m.amount().literal());
    assertEquals(new Currency("EUR"), m.currency());
    assertEquals("Money(19.90,EUR)", Haus.canonical(MoneyCodecs.ISO.encode(m)));
  }

  private static void assertCannotEncode(org.junit.jupiter.api.function.Executable e) {
    assertEquals(org.hausfmt.ErrorCode.CANNOT_ENCODE, assertThrows(org.hausfmt.HausException.class, e).code());
  }

  @Test
  void encodeChecksTheRule() {
    // cannot-encode, as in Go.
    assertCannotEncode(
        () -> MoneyCodecs.ISO.encode(new Money(Value.number(1), new Currency("Eur"))));
    assertCannotEncode(() -> MoneyCodecs.ISO_CURRENCY.encode(new Currency("EURO")));
  }

  @Test
  void rejectionsSayWhy() {
    SchemaType money = Schema.load(Vectors.extension("money").resolve("schema.haus")).type("Money");
    HausException e = assertThrows(HausException.class,
        () -> money.decode(Haus.parse("Money(1, Eur)"), DecodeOptions.DEFAULT.withCodecs(Codecs.of(MoneyCodecs.ISO))));
    assertEquals("@haus-fmt/money@1#Money rejects the value: Eur is not a currency: three letters A–Z (ISO 4217)",
        e.reason());
  }

  /**
   * With codecs for Money and Currency, the Currency's codec runs first and its rejection is at the
   * currency's own place (spec §13.4), in a haus value and in schema-based JSON alike.
   */
  @TestFactory
  Stream<DynamicTest> codecsRunInsideOut() {
    Schema s = Schema.parse("import @haus-fmt/money@1 (Money)\ntype Order = { total: Money, lines: Array Money }",
        SchemaOptions.DEFAULT.withPackages(PackageLocator.explicit().packageDir(Vectors.extension("money"))));
    SchemaType order = s.type("Order");
    SchemaType m = s.type("Money");
    Codecs both = Codecs.of(MoneyCodecs.ISO, MoneyCodecs.ISO_CURRENCY);
    Codecs onlyMoney = Codecs.of(MoneyCodecs.ISO);
    record Case(SchemaType ty, Codecs codecs, String text, String json, String path, String inJson) {}
    Stream<Case> cases = Stream.of(
        new Case(m, both, "Money(1, Eur)", "{\"_tag\": \"Money\", \"values\": [\"1\", {\"_tag\": \"Eur\"}]}",
            "$[1]", "$.values[1]"),
        new Case(m, onlyMoney, "Money(1, Eur)", "{\"_tag\": \"Money\", \"values\": [\"1\", {\"_tag\": \"Eur\"}]}",
            "$", "$"),
        new Case(order, both, "{ total: Money(1, EUR), lines: [Money(2, EUR), Money(3, Eur)] }",
            "{\"total\": {\"_tag\": \"Money\", \"values\": [\"1\", {\"_tag\": \"EUR\"}]}, \"lines\": [{\"_tag\": \"Money\", "
                + "\"values\": [\"2\", {\"_tag\": \"EUR\"}]}, {\"_tag\": \"Money\", \"values\": [\"3\", {\"_tag\": \"Eur\"}]}]}",
            "$.lines[1][1]", "$.lines[1].values[1]"));
    return cases.map(c -> dynamicTest(c.text + " with " + c.codecs, () -> {
      DecodeOptions options = DecodeOptions.DEFAULT.withCodecs(c.codecs);
      HausException e = assertThrows(HausException.class, () -> c.ty.decode(Haus.parse(c.text), options));
      assertEquals(ErrorCode.TYPE_MISMATCH, e.code(), e.getMessage());
      assertEquals(c.path, e.path(), e.getMessage());
      e = assertThrows(HausException.class, () -> c.ty.fromJson(c.json.getBytes(StandardCharsets.UTF_8), options));
      assertEquals(ErrorCode.TYPE_MISMATCH, e.code(), e.getMessage());
      assertEquals(c.inJson, e.path(), e.getMessage());
    }));
  }
}
