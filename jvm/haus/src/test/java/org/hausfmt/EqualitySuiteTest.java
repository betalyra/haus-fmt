package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

/**
 * The equality suite (test-suite/README.md, "Equality and order"): {@link Value#equals} and {@link
 * Haus#compare}, both ways.
 */
class EqualitySuiteTest {

  @TestFactory
  Stream<DynamicTest> equality() {
    List<Value> cases = Haus.parseAll(Suite.bytes(Suite.suite("equality", "cases.haus")));
    assertTrue(cases.size() > 0, "no cases");
    return cases.stream().map(c -> {
      Value.Record r = (Value.Record) c;
      Value a = r.get("a");
      Value b = r.get("b");
      boolean equal = ((Value.Variant) r.get("equal")).tag().equals("True");
      int order = ((Value.Number) r.get("order")).toBigInteger().intValueExact();
      return dynamicTest(Haus.canonical(a) + " " + Haus.canonical(b), () -> assertEquals(
          List.of(equal, equal, order, -order),
          List.of(a.equals(b), b.equals(a), Integer.signum(Haus.compare(a, b)), Integer.signum(Haus.compare(b, a)))));
    });
  }
}
