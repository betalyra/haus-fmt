package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

/**
 * The positions suite (test-suite/README.md, "Error positions"): the code, line and column of the
 * error when the whole text is parsed.
 */
class PositionsSuiteTest {

  @TestFactory
  Stream<DynamicTest> positions() {
    List<Value> cases = Haus.parseAll(Suite.bytes(Suite.suite("positions", "cases.haus")));
    assertTrue(cases.size() > 0, "no cases");
    return cases.stream().map(c -> {
      Value.Record r = (Value.Record) c;
      String text = ((Value.Text) r.get("text")).value();
      String want = ((Value.Text) r.get("code")).value() + " " + r.get("line") + ":" + r.get("column");
      return dynamicTest(c.toString(), () -> {
        String got;
        try {
          Haus.parseAll(text);
          got = "parsed";
        } catch (HausException e) {
          got = e.code().code() + " " + e.line() + ":" + e.column();
        }
        assertEquals(want, got);
      });
    });
  }
}
