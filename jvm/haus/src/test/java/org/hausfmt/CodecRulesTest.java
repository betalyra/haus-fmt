package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import org.hausfmt.ext.money.MoneyCodecs;
import org.junit.jupiter.api.Test;

/** The rules of codecs (spec §13.4): which types they apply to, and how they fail. */
class CodecRulesTest {
  private static Schema withMoney(String text) {
    var money = java.nio.file.Paths.get(System.getProperty("haus.root"), "extensions", "money");
    return Schema.parse(text, SchemaOptions.DEFAULT.withPackages(PackageLocator.explicit().packageDir(money)));
  }

  /** A codec for {@code id} that keeps the value, counting its runs. */
  private static Codec<Value> counting(String id, AtomicInteger runs) {
    return Codec.of(id, Value.class, v -> {
      runs.incrementAndGet();
      return v;
    }, v -> v);
  }

  /** A codec for {@code id} that rejects every value, and every host value it is given to encode. */
  private static Codec<Value> rejecting(String id) {
    return Codec.of(id, Value.class, v -> {
      throw new IllegalArgumentException("not this one");
    }, v -> {
      throw new IllegalArgumentException("can't write this one");
    });
  }

  private static HausException fails(Runnable r, ErrorCode code, String path) {
    HausException e = assertThrows(HausException.class, r::run);
    assertEquals(code, e.code(), e.getMessage());
    assertEquals(path, e.path(), e.getMessage());
    return e;
  }

  @Test
  void preludeAndStdCodecsApplyEverywhere() {
    Schema s = withMoney("import @haus-fmt/money@1 (Money)\nimport std/time (Instant)\n"
        + "type Root = { price: Decimal, total: Money, at: Instant }");
    AtomicInteger decimals = new AtomicInteger();
    AtomicInteger instants = new AtomicInteger();
    Codecs codecs = Codecs.of(counting("prelude#Decimal", decimals), counting("std/time#Instant", instants));
    Value v = Haus.parse("{ price: 1.5, total: Money(2.50, EUR), at: Instant(\"2026-11-25T10:00:00Z\") }");
    s.type("Root").decode(v, DecodeOptions.DEFAULT.withCodecs(codecs));
    assertEquals(2, decimals.get(), "price and Money's amount");
    assertEquals(1, instants.get());
    assertEquals(List.of(), s.unusedCodecs(codecs));
    fails(() -> s.type("Root").decode(v, DecodeOptions.DEFAULT.withCodecs(Codecs.of(rejecting("prelude#Decimal")))),
        ErrorCode.CODEC_REJECTED, "$.price");
  }

  @Test
  void theCodecOfTheDecodedTypeRuns() {
    Schema s = withMoney("import @haus-fmt/money@1 (Currency)\ntype Root = Currency");
    fails(() -> s.type("Currency").decode(Haus.parse("CHF"),
        DecodeOptions.DEFAULT.withCodecs(Codecs.of(rejecting(MoneyCodecs.CURRENCY_ID)))), ErrorCode.CODEC_REJECTED, "$");
  }

  @Test
  void oneCodecPerId() {
    AtomicInteger runs = new AtomicInteger();
    assertThrows(IllegalArgumentException.class, () -> Codecs.of(counting("prelude#Int", runs), counting("prelude#Int", runs)));
  }

  @Test
  void aRejectionInsideASecretIsInvalidSecret() {
    Schema s = withMoney("import @haus-fmt/money@1 (Currency)\ntype Root = { key: Secret Currency }");
    HausException e = fails(() -> s.type("Root").decode(Haus.parse("{ key: CHF }"),
        DecodeOptions.DEFAULT.withCodecs(Codecs.of(rejecting(MoneyCodecs.CURRENCY_ID)))), ErrorCode.INVALID_SECRET, "$.key");
    assertFalse(e.getMessage().contains("CHF"), e.getMessage());
  }

  record Bill(BigDecimal total) {}

  @Test
  void anEncodeRejectionIsCannotEncode() {
    Schema s = Schema.parse("type Bill = { total: Decimal }");
    Codec<BigDecimal> strict = Codec.of("prelude#Decimal", BigDecimal.class,
        v -> ((Value.Number) v).toBigDecimal(), x -> {
          throw new IllegalArgumentException("not this one");
        });
    HausCodec<Bill> bills = s.codec("Bill", Bill.class, DecodeOptions.DEFAULT.withCodecs(Codecs.of(strict)));
    assertEquals(new Bill(new BigDecimal("1.5")), bills.decode("{ total: 1.5 }"));
    fails(() -> bills.encode(new Bill(BigDecimal.ONE)), ErrorCode.CANNOT_ENCODE, "$.total");
  }

  @Test
  void unusedCodecs() {
    Schema s = withMoney("import @haus-fmt/money@1 (Currency)\ntype Root = { c: Currency }");
    AtomicInteger runs = new AtomicInteger();
    Codecs codecs = Codecs.of(
        counting("@haus-fmt/money@2#Money", runs),
        counting(MoneyCodecs.MONEY_ID, runs), // a type of an imported package, though not imported by name
        counting(MoneyCodecs.CURRENCY_ID, runs),
        counting("prelude#Int", runs),
        counting("std/time#Date", runs),
        counting("prelude#Price", runs));
    List<String> warned = new ArrayList<>();
    for (HausException w : s.unusedCodecs(codecs)) {
      assertEquals(ErrorCode.UNUSED_CODEC, w.code());
      assertEquals(null, w.path());
      warned.add(w.reason());
    }
    assertEquals(2, warned.size(), warned.toString());
    assertEquals(true, warned.get(0).contains("@haus-fmt/money@2#Money"), warned.toString());
    assertEquals(true, warned.get(1).contains("prelude#Price"), warned.toString());
  }
}
