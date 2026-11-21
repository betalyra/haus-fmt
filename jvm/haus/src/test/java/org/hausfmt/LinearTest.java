package org.hausfmt;

import static org.junit.jupiter.api.Assertions.fail;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.function.IntFunction;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

/**
 * The parser and the writers take time linear in the input (spec §7, §9.8): a duplicate-key check
 * that scans a list, or hashes with a known hash, would make crafted records quadratic; so would
 * copying a container at every level. Each case runs at n and at 4n; linear time grows about 4×,
 * quadratic 16×, and the test asks for less than 8×. The best of a few runs of each counts, after
 * the JIT has warmed up, and a busy machine gets a few more tries.
 */
class LinearTest {
  private static final int RUNS = 5;
  private static final int TRIES = 4;

  private static long fastest(Runnable work) {
    long best = Long.MAX_VALUE;
    for (int i = 0; i < RUNS; i++) {
      long start = System.nanoTime();
      work.run();
      best = Math.min(best, System.nanoTime() - start);
    }
    return best;
  }

  /** Checks that work(4n) takes less than 8× work(n). */
  private static void assertLinear(int n, IntFunction<Runnable> work) {
    Runnable small = work.apply(n);
    Runnable large = work.apply(4 * n);
    for (int i = 0; i < 3; i++) {
      large.run(); // warm up
    }
    double ratio = 0;
    for (int i = 0; i < TRIES; i++) {
      ratio = (double) fastest(large) / Math.max(fastest(small), 1000);
      if (ratio < 8) {
        return;
      }
    }
    fail(String.format("4× the input took %.1f× the time", ratio));
  }

  private static String joined(int n, String open, String closer, IntFunction<String> entry) {
    StringBuilder b = new StringBuilder(open);
    for (int i = 0; i < n; i++) {
      if (i > 0) {
        b.append(", ");
      }
      b.append(entry.apply(i));
    }
    return b.append(closer).toString();
  }

  private static String repeat(String s, int n) {
    return String.join("", Collections.nCopies(n, s));
  }

  /** Keys whose String.hashCode collide: every string of n blocks "Aa" or "BB". */
  private static List<String> colliding(int count) {
    List<String> keys = new ArrayList<>(Collections.singletonList("k"));
    while (keys.size() < count) {
      List<String> next = new ArrayList<>();
      for (String k : keys) {
        next.add(k + "Aa");
        next.add(k + "BB");
      }
      keys = next;
    }
    return keys.subList(0, count);
  }

  private static Runnable parsing(String text, Limits limits) {
    byte[] bytes = text.getBytes(java.nio.charset.StandardCharsets.UTF_8);
    return () -> Haus.parseAll(bytes, limits);
  }

  @TestFactory
  Stream<DynamicTest> parse() {
    Limits deep = Limits.DEFAULT.withMaxDepth(Limits.MAX_SUPPORTED_DEPTH);
    Limits d = Limits.DEFAULT;
    return Stream.of(
        dynamicTest("many keys", () -> assertLinear(20_000, n -> parsing(joined(n, "{ ", " }", i -> "k" + i + ": " + i), d))),
        dynamicTest("keys alike", () -> assertLinear(20_000,
            n -> parsing(joined(n, "{ ", " }", i -> repeat("a", 40) + String.format("%08d", i) + ": 1"), d))),
        dynamicTest("keys with one String.hashCode", () -> assertLinear(8_192, n -> {
          List<String> keys = colliding(n);
          return parsing(joined(n, "{ ", " }", i -> keys.get(i) + ": 1"), d);
        })),
        dynamicTest("many small records", () -> assertLinear(5_000,
            n -> parsing(joined(n, "[", "]", i -> "{ a: " + i + ", b: \"x\", c: None }"), d))),
        dynamicTest("long string", () -> assertLinear(200_000,
            n -> parsing("\"" + repeat("abc\\n\\u{1F600}é", n / 10) + "\"", d))),
        // Strings and comments are checked to be UTF-8 as they are read.
        dynamicTest("long string beyond ASCII", () -> assertLinear(100_000,
            n -> parsing("\"" + repeat("日本語é\uD83D\uDE00", n / 5) + "\"", d))),
        dynamicTest("long comments beyond ASCII", () -> assertLinear(100_000,
            n -> parsing(repeat("// 日本語é\n/* ü \uD83D\uDE00 */\n", n / 20) + "1", d))),
        dynamicTest("many small integers", () -> assertLinear(50_000, n -> parsing(joined(n, "[", "]", i -> String.valueOf(i % 100)), d))),
        dynamicTest("deep nesting", () -> assertLinear(60, n -> parsing(repeat("[", n) + repeat("]", n), deep))),
        dynamicTest("deep payloads", () -> assertLinear(60, n -> parsing(repeat("Some(", n) + "1" + repeat(")", n), deep))),
        dynamicTest("many short values", () -> assertLinear(50_000, n -> parsing(joined(n, "[", "]", i -> String.valueOf(i % 10)), d))));
  }

  @TestFactory
  Stream<DynamicTest> decode() {
    Schema s = Schema.parse("type M = Map Int\ntype Rs = Array R\ntype R = { a: Int, b: String, c?: Float64, d: Array Int32 }");
    SchemaType map = s.type("M");
    SchemaType records = s.type("Rs");
    return Stream.of(
        dynamicTest("many keys", () -> assertLinear(20_000, n -> {
          Value v = Haus.parse(joined(n, "{ ", " }", i -> "k" + i + ": " + i));
          return () -> map.decode(v);
        })),
        dynamicTest("keys with one String.hashCode", () -> assertLinear(8_192, n -> {
          List<String> keys = colliding(n);
          Value v = Haus.parse(joined(n, "{ ", " }", i -> keys.get(i) + ": 1"));
          return () -> map.decode(v);
        })),
        dynamicTest("many records", () -> assertLinear(5_000, n -> {
          Value v = Haus.parse(joined(n, "[", "]", i -> "{ a: " + i + ", b: \"x\", c: 1.50, d: [1, 2, " + i + "], e: 0 }"));
          return () -> {
            records.decode(v);
            records.encode(v);
          };
        })));
  }

  @TestFactory
  Stream<DynamicTest> write() {
    Limits deep = Limits.DEFAULT.withMaxDepth(Limits.MAX_SUPPORTED_DEPTH);
    IntFunction<Value> record = n -> {
      List<Value.Field> fields = new ArrayList<>();
      for (int i = 0; i < n; i++) {
        fields.add(Value.field("key " + i, Value.string("a\tb")));
      }
      return Value.record(fields);
    };
    IntFunction<Value> nested = n -> {
      Value v = Value.array();
      for (int i = 0; i < n; i++) {
        v = Value.variant("Some", Value.array(v));
      }
      return v;
    };
    List<DynamicTest> tests = new ArrayList<>();
    for (Layout layout : Layout.values()) {
      FormatOptions o = FormatOptions.of(layout);
      tests.add(dynamicTest(layout + " many keys", () -> assertLinear(10_000, n -> {
        Value v = record.apply(n);
        return () -> Haus.write(v, o);
      })));
      if (layout == Layout.PRETTY) {
        continue; // its indentation makes the text of deep nesting quadratic
      }
      tests.add(dynamicTest(layout + " deep nesting", () -> assertLinear(30, n -> {
        Value v = nested.apply(n);
        return () -> Haus.write(v, o.withLimits(deep));
      })));
    }
    tests.add(dynamicTest("long string", () -> assertLinear(100_000, n -> {
      Value v = Value.string(repeat("abc\n\"日本\uD83D\uDE00\u2028é ", n / 10));
      return () -> Haus.write(v, FormatOptions.MINIMISED);
    })));
    tests.add(dynamicTest("canonical, many keys", () -> assertLinear(10_000, n -> {
      Value v = record.apply(n);
      return () -> Haus.canonical(v);
    })));
    tests.add(dynamicTest("canonical, many small records", () -> assertLinear(5_000, n -> {
      Value v = Haus.parse(joined(n, "[", "]", i -> "{ k" + (n - i) + ": 1, j: 2, \"x y\": 3, a: [" + i + "] }"));
      return () -> Haus.canonical(v);
    })));
    tests.add(dynamicTest("lookups of keys with one String.hashCode", () -> assertLinear(8_192, n -> {
      List<String> keys = colliding(n);
      Value.Record r = (Value.Record) Haus.parse(joined(n, "{ ", " }", i -> keys.get(i) + ": 1"));
      return () -> {
        for (String k : keys) {
          r.get(k);
          r.get(k + "x");
        }
      };
    })));
    tests.add(dynamicTest("record keys with one String.hashCode", () -> assertLinear(8_192, n -> {
      List<String> keys = colliding(n);
      return () -> {
        List<Value.Field> fields = new ArrayList<>();
        for (String k : keys) {
          fields.add(Value.field(k, Value.number(1)));
        }
        Value.record(fields);
      };
    })));
    return tests.stream();
  }
}
