package org.hausfmt.examples;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;

/**
 * Runs the examples and compares their output with the lines of go/examples/quickstart and
 * go/examples/order. Lines that need a schema there (its errors, and the codecs' rules) are the
 * JVM binding's own until it has schemas; error messages are each binding's own (spec §17 fixes
 * codes, not messages).
 */
class ExamplesTest {
  private static final String QUICKSTART = String.join("\n",
      "thread by ada: 15 levels, 30 likes",
      "Comment { author: \"me\", at: Instant(\"2026-11-16T09:00:00Z\"), text: \"+1\", likes: 1, replies: [] }",
      // go: error: $.likes: expected Int, found the string "lots" [type-mismatch]
      "error: 1:81: a lowercase word, \"lots\", where a value must be [bare-identifier]",
      "");

  private static final String ORDER = String.join("\n",
      "plain:  usr_ada pays 44.40 EUR",
      "typed:  usr_ada pays 4440 cents, deliver to [lng, lat] [-9.1393, 38.7223]",
      "placed: 2026-11-09, a Monday",
      "status: shipped, tracking DE-4711",
      "{ id: 7, customer: UserId(\"usr_ada\"), placed: Date(\"2026-11-09\"), total: Money(44.40, EUR), "
          + "deliverTo: LatLng(38.7223, -9.1393), status: Shipped { tracking: \"DE-4711\" } }",
      // go: the Eur and 44.405 lines, which need the codecs' iso rules
      "");

  private static String output(Runnable main) {
    PrintStream stdout = System.out;
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    System.setOut(new PrintStream(out, true, StandardCharsets.UTF_8));
    try {
      main.run();
    } finally {
      System.setOut(stdout);
    }
    return out.toString(StandardCharsets.UTF_8).replace(System.lineSeparator(), "\n");
  }

  @Test
  void quickstart() {
    assertEquals(QUICKSTART, output(() -> Quickstart.main(new String[0])));
    assertEquals(QUICKSTART, output(org.hausfmt.examples.quickstart.QuickstartKt::main));
  }

  @Test
  void order() {
    assertEquals(ORDER, output(() -> Order.main(new String[0])));
    assertEquals(ORDER, output(org.hausfmt.examples.order.OrderKt::main));
  }
}
