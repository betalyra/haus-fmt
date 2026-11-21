package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

/**
 * The checker suite (test-suite/README.md, "Checker suite"): the warnings of schema files ({@link
 * Schema#warnings}). The {@code Data} cases are not run: this binding has no data checker that
 * reports hints ({@code unlisted-field}, {@code unlisted-tag}, {@code deprecated}) without failing;
 * decoding ignores what open types don't list and stops at the first error.
 */
class CheckSuiteTest {

  /** {@code Warning("code", 1, 2)} as {@code Warning code 1 2}. */
  private static String show(Value v) {
    Value.Variant w = (Value.Variant) v;
    StringBuilder b = new StringBuilder(w.tag());
    for (int i = 0; i < w.size(); i++) {
      b.append(' ').append(w.get(i) instanceof Value.Text t ? t.value() : w.get(i).toString());
    }
    return b.toString();
  }

  @TestFactory
  Stream<DynamicTest> schemaWarnings() {
    List<Value.Variant> all = Suite.cases(Suite.suite("check", "cases.haus"));
    assertTrue(all.size() > 0, "no cases");
    List<Value.Variant> cases = all.stream().filter(c -> c.tag().equals("Schema")).collect(Collectors.toList());
    assertTrue(cases.size() > 0, "no Schema cases");
    return cases.stream().map(c -> {
      String schema = Suite.str(c, "schema");
      List<String> want = ((Value.Array) c.payload().get("warnings")).items().stream()
          .map(CheckSuiteTest::show).collect(Collectors.toList());
      return dynamicTest(schema, () -> {
        List<String> got = Schema.parse(schema).warnings().stream()
            .sorted(Comparator.comparingInt(HausException::line).thenComparingInt(HausException::column))
            .map(w -> "Warning " + w.code().code() + " " + w.line() + " " + w.column())
            .collect(Collectors.toList());
        assertEquals(want, got);
      });
    });
  }
}
