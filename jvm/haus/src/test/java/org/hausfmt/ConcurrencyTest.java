package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;

/**
 * One schema, its types, codecs, options and the inputs, shared by many threads doing everything at
 * once: each must get what one thread alone gets. Schema, SchemaType, HausCodec, Codecs, Limits and
 * the options are documented as immutable and safe for concurrent use.
 */
class ConcurrencyTest {
  private static final Schema SCHEMA = Schema.parse(String.join("\n",
      "import std/time (Instant, Date)",
      "type Order = { id: Int64, total: Decimal, placed: Instant, due?: Date, items: Array Item, status: Status,"
          + " level: Level, note: Maybe String, tags: Map Int32, key: Secret String }",
      "type Item = { sku: String, price: Float64, qty: Int32 }",
      "type Status = < Open | Shipped Date | Cancelled { reason: String } >",
      "type Level = closed < Low | High >",
      "type Orders = Stream Order",
      ""));

  private static final String TEXT = String.join("\n",
      "// two orders",
      "{ id: 0x10, total: 19.90, placed: Instant(\"2026-01-02T03:04:05Z\"), items: [{ sku: \"A1\", price: 0.10,"
          + " qty: 2 }], status: Shipped(Date(\"2026-01-03\")), level: High, note: Some(\"leave at door\"),"
          + " tags: { a: 1, b: 2 }, key: \"k1\", extra: \"ignored\" },",
      "{ id: 17, total: 1, placed: Instant(\"2026-01-02T03:04:05+01:00\"), due: Date(\"2026-02-01\"), items: [],"
          + " status: Cancelled { reason: \"late\" }, level: Low, note: None, tags: {}, key: \"k2\" },",
      "");

  /** Texts every path fails on, so that errors are compared too. */
  private static final List<String> BAD = List.of(
      "{ id: 1, total: 1, placed: Instant(\"2026-01-02T03:04:05Z\"), items: [{ sku: \"A1\", price: \"0.10\","
          + " qty: 1 }], status: Open, level: Low, note: None, tags: {}, key: \"k\" }",
      "{ id: 1, total: 1, placed: Instant(\"2026-02-30T00:00:00Z\"), items: [], status: Open, level: Low,"
          + " note: None, tags: {}, key: \"k\" }",
      "{ id: 99999999999999999999, total: 1, placed: Instant(\"2026-01-02T03:04:05Z\"), items: [], status: Open,"
          + " level: Low, note: None, tags: {}, key: \"k\" }",
      "[1, 2, { a: }]",
      "{ a: 1, a: 2 }");

  record Item(String sku, double price, int qty) {}

  sealed interface Status permits Open, Shipped, Cancelled {}

  record Open() implements Status {}

  record Shipped(java.time.LocalDate on) implements Status {}

  record Cancelled(String reason) implements Status {}

  enum Level { Low, High }

  record Order(long id, BigDecimal total, java.time.Instant placed, java.time.LocalDate due, List<Item> items,
      Status status, Level level, String note, Map<String, Integer> tags, Secret<String> key) {}

  private static final List<FormatOptions> LAYOUTS = List.of(
      FormatOptions.PRETTY.withWidth(40), FormatOptions.COMPACT, FormatOptions.MINIMISED);

  private static final HausCodec<Order> CODEC = SCHEMA.codec("Order", Order.class);

  /** Every operation once, with the shared schema, codec and inputs: what each gave, in order. */
  private static List<String> run() throws Exception {
    List<String> out = new ArrayList<>();
    class Add {
      void of(String label, Callable<Object> body) {
        try {
          out.add(label + ": " + body.call());
        } catch (Exception e) {
          out.add(label + ": " + e);
        }
      }
    }
    Add add = new Add();
    SchemaType order = SCHEMA.type("Order");
    SchemaType orders = SCHEMA.type("Orders");
    List<Value> values = Haus.parseAll(TEXT);
    add.of("parse", values::size);
    for (FormatOptions layout : LAYOUTS) {
      add.of("format " + layout.layout(), () -> Haus.format(TEXT, layout));
      add.of("write " + layout.layout(), () -> Haus.writeAll(values, layout));
    }
    add.of("has comments", () -> Haus.hasComments(TEXT));
    add.of("stream", () -> {
      List<String> read = new ArrayList<>();
      try (StreamReader r = new StreamReader(new ByteArrayInputStream(TEXT.getBytes(StandardCharsets.UTF_8)))) {
        for (Value v; (v = r.read()) != null; ) {
          read.add(Haus.canonical(v));
        }
      }
      return read;
    });
    // A codec made on this thread, from the shared type, as well as the shared one.
    HausCodec<Order> mine = HausCodec.of(order, Order.class);
    for (int i = 0; i < values.size(); i++) {
      Value v = values.get(i);
      add.of("canonical", () -> Haus.canonical(v));
      add.of("hash", () -> Haus.hash(v));
      add.of("equals", () -> v.equals(values.get(0)) + " " + (v.hashCode() == values.get(0).hashCode()));
      add.of("compare", () -> Haus.compare(v, values.get(values.size() - 1)));
      add.of("check", () -> {
        Haus.check(v, Limits.DEFAULT.withMaxDepth(3));
        return "ok";
      });
      add.of("haus json", () -> HausJson.fromHausJson(HausJson.toHausJson(v)).equals(v));
      add.of("import json", () -> Haus.canonical(HausJson.importJson(HausJson.toHausJson(v))));
      add.of("decode", () -> Haus.canonical(order.decode(v)));
      add.of("encode", () -> Haus.canonical(order.encode(order.decode(v))));
      add.of("to json", () -> order.toJson(order.decode(v)));
      add.of("from json", () -> Haus.canonical(order.fromJson(order.toJson(order.decode(v)))));
      add.of("typed", () -> CODEC.fromValue(v));
      add.of("typed mine", () -> mine.fromValue(v));
      add.of("typed back", () -> Haus.canonical(CODEC.toValue(CODEC.fromValue(v))));
      add.of("typed json", () -> CODEC.fromJson(CODEC.toJson(CODEC.fromValue(v))));
      for (FormatOptions layout : LAYOUTS) {
        add.of("typed write " + layout.layout(), () -> Haus.canonical(Haus.parse(CODEC.encode(CODEC.fromValue(v), layout))));
        add.of("typed text " + layout.layout(), () -> CODEC.decode(Haus.write(v, layout)));
      }
    }
    add.of("decode all", () -> orders.decodeAll(values).size());
    add.of("decode stream", () -> orders
        .decodeStream(new ByteArrayInputStream(TEXT.getBytes(StandardCharsets.UTF_8)), StreamOptions.DEFAULT)
        .map(Haus::canonical).toList());
    add.of("json lines", () -> orders.fromJsonLines(orders.toJsonLines(orders.decodeAll(values))).size());
    for (String bad : BAD) {
      add.of("parse bad", () -> Haus.parse(bad));
      add.of("format bad", () -> Haus.format(bad, FormatOptions.COMPACT));
      add.of("decode bad", () -> order.decode(Haus.parse(bad)));
      add.of("typed bad", () -> CODEC.decode(bad));
    }
    return out;
  }

  @Test
  void sharedSchemaCodecsAndInputs() throws Exception {
    List<String> want = run();
    assertTrue(want.size() > 50);
    assertTrue(want.stream().noneMatch(s -> s.startsWith("typed:") && s.contains("Exception")), want::toString);
    int threads = 16;
    ExecutorService pool = Executors.newFixedThreadPool(threads);
    try {
      CountDownLatch start = new CountDownLatch(1);
      List<Future<List<String>>> futures = new ArrayList<>();
      for (int t = 0; t < threads; t++) {
        futures.add(pool.submit(() -> {
          start.await();
          List<String> got = want;
          for (int round = 0; round < 4 && got.equals(want); round++) {
            got = run();
          }
          return got;
        }));
      }
      start.countDown();
      for (Future<List<String>> f : futures) {
        List<String> got = f.get();
        for (int i = 0; i < Math.min(got.size(), want.size()); i++) {
          int at = i;
          Supplier<String> where = () -> "result " + at;
          assertEquals(want.get(i), got.get(i), where);
        }
        assertEquals(want.size(), got.size());
      }
    } finally {
      pool.shutdownNow();
    }
  }
}
