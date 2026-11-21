package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
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
    assertEquals(new JsonData(want).read(), new JsonData(got).read(), got);
  }

  /**
   * JSON as data, to compare: a string, a {@link Literal} (a number's text, true, false, null), a
   * list, or a map of the members, whose order doesn't matter. Not {@link HausJson#importJson},
   * which stops at 256 JSON levels (spec §16): the .jsonl of a value 256 levels deep has more.
   */
  private static final class JsonData {
    record Literal(String text) {}

    private final String s;
    private int i;

    JsonData(String s) {
      this.s = s;
    }

    Object read() {
      Object v = value();
      space();
      if (i != s.length()) {
        throw new IllegalArgumentException("text after the JSON at " + i + ": " + s);
      }
      return v;
    }

    private void space() {
      while (i < s.length() && " \t\r\n".indexOf(s.charAt(i)) >= 0) {
        i++;
      }
    }

    private void expect(char c) {
      space();
      if (i >= s.length() || s.charAt(i) != c) {
        throw new IllegalArgumentException("expected " + c + " at " + i + ": " + s);
      }
      i++;
    }

    /** Whether the next character, after whitespace, is {@code c}; if so, it is read. */
    private boolean next(char c) {
      space();
      if (i < s.length() && s.charAt(i) == c) {
        i++;
        return true;
      }
      return false;
    }

    private Object value() {
      space();
      if (next('[')) {
        List<Object> items = new ArrayList<>();
        if (!next(']')) {
          do {
            items.add(value());
          } while (next(','));
          expect(']');
        }
        return items;
      }
      if (next('{')) {
        Map<String, Object> members = new HashMap<>();
        if (!next('}')) {
          do {
            space();
            String key = string();
            expect(':');
            members.put(key, value());
          } while (next(','));
          expect('}');
        }
        return members;
      }
      if (i < s.length() && s.charAt(i) == '"') {
        return string();
      }
      int start = i;
      while (i < s.length() && ",]} \t\r\n".indexOf(s.charAt(i)) < 0) {
        i++;
      }
      return new Literal(s.substring(start, i));
    }

    private String string() {
      expect('"');
      StringBuilder out = new StringBuilder();
      for (char c = s.charAt(i++); c != '"'; c = s.charAt(i++)) {
        if (c != '\\') {
          out.append(c);
          continue;
        }
        char e = s.charAt(i++);
        switch (e) {
          case 'n' -> out.append('\n');
          case 'r' -> out.append('\r');
          case 't' -> out.append('\t');
          case 'b' -> out.append('\b');
          case 'f' -> out.append('\f');
          case 'u' -> {
            out.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
            i += 4;
          }
          default -> out.append(e);
        }
      }
      return out.toString();
    }
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
