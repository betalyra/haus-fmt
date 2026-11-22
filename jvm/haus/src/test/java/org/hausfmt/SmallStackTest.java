package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

/**
 * Every path that recurses once per level, at the supported depth, on a thread with a small stack,
 * 512 KiB (spec §7, {@code limits.depth.small-stack-tested}); and the host's hooks on a value built
 * in code of any depth ({@code limits.depth.host-hooks}): {@code hashCode}, {@code equals} and
 * {@code toString}. The build runs this class a second time interpreted ({@code -Xint}), whose
 * frames are the largest.
 */
class SmallStackTest {
  private static final int STACK = 512 << 10;

  private static void inSmallStack(Runnable r) throws InterruptedException {
    AtomicReference<Throwable> failed = new AtomicReference<>();
    Thread t = new Thread(null, () -> {
      try {
        r.run();
      } catch (Throwable e) {
        failed.set(e);
      }
    }, "small-stack", STACK);
    t.start();
    t.join();
    if (failed.get() != null) {
      throw new AssertionError(failed.get());
    }
  }

  private static String deep(int n, String open, String closer) {
    return open.repeat(n) + "1" + closer.repeat(n);
  }

  /** Parsing, the writers in every layout, the formatter, the canonical form, hashing and JSON at 256 levels. */
  @Test
  void supportedDepth() throws InterruptedException {
    inSmallStack(() -> {
      Limits deepest = Limits.DEFAULT.withMaxDepth(Limits.MAX_SUPPORTED_DEPTH);
      for (String[] brackets : new String[][] {{"[", "]"}, {"A(", ")"}, {"{ a: ", " }"}, {"T { a: ", " }"}}) {
        String text = deep(Limits.MAX_SUPPORTED_DEPTH, brackets[0], brackets[1]);
        Value v = Haus.parse(text, deepest);
        assertEquals(Limits.MAX_SUPPORTED_DEPTH, v.depth());
        for (Layout l : Layout.values()) {
          FormatOptions o = FormatOptions.of(l).withLimits(deepest);
          assertEquals(v, Haus.parse(Haus.write(v, o), deepest));
          Haus.format(text, o);
        }
        Haus.check(v, deepest);
        assertEquals(v, Haus.parse(Haus.canonical(v), deepest));
        Haus.hash(v);
        // Self-describing JSON: up to 4·256+2 levels.
        assertEquals(v, HausJson.fromHausJson(HausJson.toHausJson(v, deepest), deepest));
        assertEquals(ErrorCode.NESTING_TOO_DEEP, assertThrows(HausException.class,
            () -> Haus.parse(deep(Limits.MAX_SUPPORTED_DEPTH + 1, brackets[0], brackets[1]), deepest)).code());
      }
    });
  }

  /** hashCode, equals and toString of a value built in code 100,000 levels deep. */
  @Test
  void hostHooksAtAnyDepth() throws InterruptedException {
    inSmallStack(() -> {
      Value a = ApiTest.veryDeep(100_000, Value.number(1));
      Value b = ApiTest.veryDeep(100_000, Value.number(1));
      Value c = ApiTest.veryDeep(100_000, Value.number(2));
      assertEquals(100_000, a.depth());
      assertEquals(a.hashCode(), b.hashCode());
      assertEquals(a.hashCode(), a.hashCode());
      assertTrue(a.equals(b));
      assertFalse(a.equals(c));
      assertNotEquals(Haus.hash(a), Haus.hash(c));
      // Cut off below the supported depth, as debug output may be.
      String shown = a.toString();
      assertTrue(shown.startsWith("[Node { next: Some([Node"), shown.substring(0, 40));
      assertTrue(shown.contains("…"), "cut off");
      assertTrue(shown.length() < 100_000, "cut off");
      // The writers check the depth before they go deeper.
      assertEquals(ErrorCode.NESTING_TOO_DEEP, assertThrows(HausException.class, () -> Haus.write(a)).code());
      // Hash codes of equal values built differently agree: a record's fields in another order.
      Value r1 = Value.record(Value.field("a", Value.number(1)), Value.field("b", Value.array()));
      Value r2 = Value.record(Value.field("b", Value.array()), Value.field("a", Value.number(1)));
      assertEquals(r1, r2);
      assertEquals(r1.hashCode(), r2.hashCode());
      assertEquals(Value.variant("T", r1).hashCode(), Value.variant("T", r2).hashCode());
    });
  }
}
