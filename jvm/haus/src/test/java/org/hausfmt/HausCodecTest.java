package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.lang.reflect.Type;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import org.junit.jupiter.api.Test;

/** Typed codecs: records, sealed interfaces and enums, decoded and encoded with a schema. */
class HausCodecTest {
  private static final Schema SCHEMA = Schema.parse(String.join("\n",
      "import std/time (Date, Instant)",
      "type Order = {",
      "  id: Int64,",
      "  big: Int,",
      "  placed: Date,",
      "  at: Instant,",
      "  lines: Array Line,",
      "  status: Status,",
      "  level: Level,",
      "  note?: String,",
      "  gift?: Maybe String,",
      "  coupon: Maybe String,",
      "  labels: Map String,",
      "  key: Secret String,",
      "  extra: Any,",
      "  \"pt-BR\"?: String,",
      "}",
      "type Line = { sku: String, price: Decimal, qty: Int32, weight: Float64 }",
      "type Status = < Pending | Shipped { tracking: String } | Moved String Int32 >",
      "type Level = closed < Low | High >",
      "type Tree = { label: String, kids: Array Tree }",
      "type Envelope e = { id: String, event: e }",
      "type Ping = { n: Int8 }",
      "type Pings = Envelope Ping",
      "type Small = { n: Int }",
      ""));

  record Line(String sku, BigDecimal price, int qty, double weight) {}

  sealed interface Status permits Pending, Shipped, Moved, Other {}

  record Pending() implements Status {}

  record Shipped(String tracking) implements Status {}

  record Moved(String to, int floor) implements Status {}

  record Other(Value.Variant value) implements Status {}

  enum Level { Low, High }

  record Order(
      long id,
      BigInteger big,
      LocalDate placed,
      String at,
      List<Line> lines,
      Status status,
      Level level,
      String note,
      Optional<String> gift,
      String coupon,
      Map<String, String> labels,
      Secret<String> key,
      Value extra,
      @HausName("pt-BR") String ptBr) {}

  private static final String ORDER = "{ id: 7, big: 123456789012345678901234567890, placed: Date(\"2026-11-09\"),"
      + " at: Instant(\"2026-11-09T10:00:00.250+01:00\"), lines: [{ sku: \"a\", price: 19.90, qty: 2, weight: 0.10 }],"
      + " status: Shipped { tracking: \"DE-4711\" }, level: High, gift: None, coupon: Some(\"X\"),"
      + " labels: { en: \"hi\" }, key: \"sk-1\", extra: [1, Tag(2)], unlisted: 1 }";

  @Test
  void decodesAndEncodesRecords() {
    HausCodec<Order> codec = SCHEMA.codec("Order", Order.class);
    Order o = codec.decode(ORDER);
    assertEquals(7, o.id());
    assertEquals(new BigInteger("123456789012345678901234567890"), o.big());
    assertEquals(LocalDate.of(2026, 11, 9), o.placed());
    assertEquals("2026-11-09T10:00:00.250+01:00", o.at());
    assertEquals(List.of(new Line("a", new BigDecimal("19.90"), 2, 0.1)), o.lines());
    assertEquals(new Shipped("DE-4711"), o.status());
    assertEquals(Level.High, o.level());
    assertEquals(null, o.note());
    assertEquals(Optional.empty(), o.gift());
    assertEquals("X", o.coupon());
    assertEquals(Map.of("en", "hi"), o.labels());
    assertEquals("<redacted>", o.key().toString());
    assertEquals("sk-1", o.key().reveal());
    assertEquals(Haus.parse("[1, Tag(2)]"), o.extra());
    // Encoding gives the decoded value back: the unlisted field is gone, 0.10 is 0.1.
    Value back = codec.toValue(o);
    assertEquals(SCHEMA.type("Order").decode(Haus.parse(ORDER)), back);
    assertEquals(o, codec.decode(codec.encode(o, FormatOptions.COMPACT)));
    assertEquals(o, codec.fromJson(codec.toJson(o)));
  }

  @Test
  void variantsAndUnknownTags() {
    record Holder(Status status) {}
    Schema s = Schema.parse("type Status = < Pending | Shipped { tracking: String } | Moved String Int32 >\n"
        + "type Holder = { status: Status }");
    HausCodec<Holder> c = HausCodec.of(s.type("Holder"), Holder.class);
    assertEquals(new Holder(new Pending()), c.decode("{ status: Pending }"));
    assertEquals(new Holder(new Moved("up", 3)), c.decode("{ status: Moved(\"up\", 3) }"));
    Holder unknown = c.decode("{ status: Lost { at: 1 } }");
    assertEquals(new Holder(new Other((Value.Variant) Haus.parse("Lost { at: 1 }"))), unknown);
    assertEquals(Haus.parse("{ status: Lost { at: 1 } }"), c.toValue(unknown));
  }

  @Test
  void errorsHaveCodesAndPaths() {
    HausCodec<Order> codec = SCHEMA.codec("Order", Order.class);
    HausException e = assertThrows(HausException.class, () -> codec.decode(ORDER.replace("qty: 2", "qty: \"2\"")));
    assertEquals(ErrorCode.TYPE_MISMATCH, e.code());
    assertEquals("$.lines[0].qty", e.path());
    record Small(long n) {}
    HausCodec<Small> small = SCHEMA.codec("Small", Small.class);
    e = assertThrows(HausException.class, () -> small.decode("{ n: 9223372036854775808 }"));
    assertEquals(ErrorCode.OUT_OF_RANGE, e.code());
    assertEquals("$.n", e.path());
    assertEquals(new Small(-9223372036854775808L), small.decode("{ n: -9223372036854775808 }"));
    // Encoding checks the value: a null where a field is required.
    Order o = codec.decode(ORDER);
    Order bad = new Order(o.id(), o.big(), o.placed(), o.at(), o.lines(), o.status(), o.level(), o.note(), o.gift(),
        o.coupon(), o.labels(), o.key(), null, o.ptBr());
    e = assertThrows(HausException.class, () -> codec.toValue(bad));
    assertEquals(ErrorCode.CANNOT_ENCODE, e.code());
    assertEquals("$.extra", e.path());
    Order badDate = new Order(o.id(), o.big(), LocalDate.of(10000, 1, 1), o.at(), o.lines(), o.status(), o.level(),
        o.note(), o.gift(), o.coupon(), o.labels(), o.key(), o.extra(), o.ptBr());
    e = assertThrows(HausException.class, () -> codec.toValue(badDate));
    assertEquals(ErrorCode.INVALID_TIME, e.code());
  }

  @Test
  void hostTypesThatDontFit() {
    record WrongName(long id) {}
    IllegalArgumentException e = assertThrows(IllegalArgumentException.class, () -> SCHEMA.codec("Small", WrongName.class));
    assertTrue(e.getMessage().contains("component id"), e.getMessage());
    record Narrow(String n) {}
    e = assertThrows(IllegalArgumentException.class, () -> SCHEMA.codec("Small", Narrow.class));
    assertTrue(e.getMessage().contains("(Small).n: java.lang.String"), e.getMessage());
  }

  record Tree(String label, List<Tree> kids) {}

  record Envelope<E>(String id, E event) {}

  record Ping(byte n) {}

  @Test
  void recursiveAndGenericTypes() {
    HausCodec<Tree> trees = SCHEMA.codec("Tree", Tree.class);
    Tree t = trees.decode("{ label: \"a\", kids: [{ label: \"b\", kids: [] }] }");
    assertEquals(new Tree("a", List.of(new Tree("b", List.of()))), t);
    Type envelope = new Object() {
      @SuppressWarnings("unused")
      Envelope<Ping> field;
    }.getClass().getDeclaredFields()[0].getGenericType();
    HausCodec<Object> pings = HausCodec.of(SCHEMA.type("Pings"), envelope, DecodeOptions.DEFAULT);
    assertEquals(new Envelope<>("x", new Ping((byte) 5)), pings.decode("{ id: \"x\", event: { n: 5 } }"));
  }

  record Amount(BigInteger cents, String currency) {}

  record Price(Amount total) {}

  @Test
  void codecsGiveHostTypes() {
    Schema s = Schema.parse("type Money = < Money Decimal String >\ntype Price = { total: Money }",
        SchemaOptions.DEFAULT.withId("shop"));
    Codec<Amount> cents = Codec.of("shop#Money", Amount.class,
        v -> {
          Value.Variant m = (Value.Variant) v;
          return new Amount(((Value.Number) m.get(0)).toBigDecimal().movePointRight(2).toBigIntegerExact(),
              ((Value.Text) m.get(1)).value());
        },
        a -> Value.variant("Money", Value.number(new BigDecimal(a.cents(), 2)), Value.string(a.currency())));
    HausCodec<Price> c = s.codec("Price", Price.class, DecodeOptions.DEFAULT.withCodecs(Codecs.of(cents)));
    Price p = c.decode("{ total: Money(44.40, \"EUR\") }");
    assertEquals(new Price(new Amount(BigInteger.valueOf(4440), "EUR")), p);
    assertEquals("{ total: Money(44.40, \"EUR\") }\n", c.encode(p, FormatOptions.COMPACT));
    HausException e = assertThrows(HausException.class, () -> c.decode("{ total: Money(44.405, \"EUR\") }"));
    assertEquals("$.total", e.path());
  }

  record Times(Instant at) {}

  @Test
  void javaTimeTypes() {
    Schema s = Schema.parse("import std/time (Instant)\ntype Times = { at: Instant }");
    HausCodec<Times> c = s.codec("Times", Times.class);
    Times t = c.decode("{ at: Instant(\"2026-11-09T10:00:00.250+01:00\") }");
    assertEquals(Instant.parse("2026-11-09T09:00:00.250Z"), t.at());
    assertEquals("{ at: Instant(\"2026-11-09T09:00:00.250Z\") }\n", c.encode(t, FormatOptions.COMPACT));
  }
}
