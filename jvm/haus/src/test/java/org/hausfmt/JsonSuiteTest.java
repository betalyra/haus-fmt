package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;
import org.junit.jupiter.api.function.Executable;

/**
 * The JSON suite (test-suite/README.md, "JSON suite") for the forms without a schema: the import
 * and self-describing JSON, and every valid/NAME.jsonl as self-describing JSON Lines.
 */
class JsonSuiteTest {

  /** JSON compared as data: member order and whitespace don't matter, numbers compare by their text. */
  static void sameJson(String want, String got) {
    assertEquals(HausJson.importJson(want), HausJson.importJson(got), got);
  }

  /** An Err case: the code, and the path when the case gives one. */
  private static void checkErr(Value.Variant c, Executable read) {
    HausException e = assertThrows(HausException.class, read);
    assertEquals(Suite.str(c, "code"), e.code().code(), e.getMessage());
    Value path = c.payload().get("path");
    if (path != null) {
      assertEquals(((Value.Text) path).value(), e.path(), e.getMessage());
    }
  }

  @TestFactory
  Stream<DynamicTest> importJson() {
    return Suite.cases(Suite.suite("json", "import.cases.haus")).stream().map(c -> {
      String json = Suite.str(c, "json");
      return dynamicTest(c.tag() + " " + json, () -> {
        switch (c.tag()) {
          case "Read":
            assertEquals(c.payload().get("output"), HausJson.importJson(json));
            break;
          case "Err":
            checkErr(c, () -> HausJson.importJson(json));
            break;
          default:
            throw new AssertionError("unknown case " + c.tag());
        }
      });
    });
  }

  @TestFactory
  Stream<DynamicTest> selfDescribing() {
    return Suite.cases(Suite.suite("json", "self-describing.cases.haus")).stream().map(c -> {
      String json = Suite.str(c, "json");
      return dynamicTest(c.tag() + " " + json, () -> {
        switch (c.tag()) {
          case "Ok":
            Value input = c.payload().get("input");
            assertEquals(input, HausJson.fromHausJson(json));
            sameJson(json, HausJson.toHausJson(input));
            break;
          case "Err":
            checkErr(c, () -> HausJson.fromHausJson(json));
            break;
          default:
            throw new AssertionError("unknown case " + c.tag());
        }
      });
    });
  }

  @TestFactory
  Stream<DynamicTest> validJsonLines() {
    Path dir = Suite.suite("valid");
    return Suite.names(dir, ".haus").stream().map(name -> dynamicTest(name, () -> {
      List<Value> values = Haus.parseAll(Suite.bytes(dir.resolve(name + ".haus")));
      String text = Suite.text(dir.resolve(name + ".jsonl"));
      assertEquals(values, HausJson.fromHausJsonLines(text));
      String[] lines = text.split("\n");
      for (int i = 0; i < values.size(); i++) {
        sameJson(lines[i], HausJson.toHausJson(values.get(i)));
      }
      assertEquals(values, HausJson.fromHausJsonLines(HausJson.toHausJsonLines(values)));
    }));
  }
}
