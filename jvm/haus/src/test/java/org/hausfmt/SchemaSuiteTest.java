package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * The schema suites of test-suite/README.md: test-suite/schema (decoding and encoding, each schema
 * with and without its attributes), test-suite/schema/invalid, and the schema-based JSON cases of
 * test-suite/json.
 */
class SchemaSuiteTest {
  private static Value field(Value.Variant c, String key) {
    return c.payload().get(key);
  }

  private static String code(HausException e) {
    return e.code().code();
  }

  private static String path(HausException e) {
    return e.path() == null ? "$" : e.path();
  }

  @Test
  void schemaSuite() {
    Path dir = Suite.suite("schema");
    List<String> failures = new ArrayList<>();
    int count = 0;
    for (String name : Suite.names(dir, ".schema.haus")) {
      String text = Suite.text(dir.resolve(name + ".schema.haus"));
      List<Value.Variant> cases = Suite.cases(dir.resolve(name + ".cases.haus"));
      for (boolean without : new boolean[] {false, true}) {
        Schema s = Schema.parse(text, SchemaOptions.DEFAULT.withoutAttributes(without));
        for (Value.Variant c : cases) {
          count++;
          String label = name + ": " + c.tag() + " " + Suite.str(c, "type") + " " + Haus.canonical(field(c, "input"))
              + (without ? " (without attributes)" : "");
          SchemaType t = s.type(Suite.str(c, "type"));
          Value input = field(c, "input");
          if (c.tag().equals("Ok")) {
            Value want = field(c, "output") != null ? field(c, "output") : input;
            try {
              Value out = t.decode(input);
              if (!Haus.canonical(out).equals(Haus.canonical(want))) {
                failures.add(label + ": decoded as " + Haus.canonical(out));
                continue;
              }
              Value enc = t.encode(out);
              if (!Haus.canonical(enc).equals(Haus.canonical(out))) {
                failures.add(label + ": encoded as " + Haus.canonical(enc));
              }
              Haus.write(out);
            } catch (HausException e) {
              failures.add(label + ": " + e.getMessage());
            }
          } else {
            String wantCode = Suite.str(c, "code");
            String wantPath = Suite.str(c, "path");
            HausException d = catching(() -> t.decode(input));
            if (d == null) {
              failures.add(label + ": decoded, expected " + wantCode);
              continue;
            }
            if (!code(d).equals(wantCode) || !path(d).equals(wantPath)) {
              failures.add(label + ": " + d.getMessage() + ", expected " + wantCode + " at " + wantPath);
            }
            HausException e = catching(() -> t.encode(input));
            if (e == null || !code(e).equals(code(d)) || !path(e).equals(path(d))) {
              failures.add(label + ": encoding fails with " + (e == null ? "nothing" : e.getMessage()));
            }
          }
        }
      }
    }
    assertEquals(List.of(), failures, failures.size() + " of " + count + " cases failed");
    assertTrue(count > 100);
  }

  private static HausException catching(Runnable r) {
    try {
      r.run();
      return null;
    } catch (HausException e) {
      return e;
    }
  }

  @Test
  void invalidSchemas() {
    Path dir = Suite.suite("schema", "invalid");
    List<String> failures = new ArrayList<>();
    for (String name : Suite.names(dir, ".schema.haus")) {
      String want = Suite.text(dir.resolve(name + ".error")).trim();
      HausException e = catching(() -> Schema.parse(Suite.bytes(dir.resolve(name + ".schema.haus")), SchemaOptions.DEFAULT));
      if (e == null || !code(e).equals(want)) {
        failures.add(name + ": " + (e == null ? "accepted" : e.getMessage()) + ", expected " + want);
      }
    }
    assertEquals(List.of(), failures);
  }

  @Test
  void schemaBasedJson() {
    Path dir = Suite.suite("json");
    String text = Suite.text(dir.resolve("schema-based.schema.haus"));
    List<String> failures = new ArrayList<>();
    for (boolean without : new boolean[] {false, true}) {
      Schema s = Schema.parse(text, SchemaOptions.DEFAULT.withoutAttributes(without));
      for (Value.Variant c : Suite.cases(dir.resolve("schema-based.cases.haus"))) {
        SchemaType t = s.type(Suite.str(c, "type"));
        String json = Suite.str(c, "json");
        String label = c.tag() + " " + t.name() + " " + (json.length() > 60 ? json.substring(0, 60) + "…" : json);
        Value got = null;
        HausException readError = null;
        try {
          got = t.fromJson(json);
        } catch (HausException e) {
          readError = e;
        }
        switch (c.tag()) {
          case "Ok": {
            try {
              String written = t.toJson(t.decode(field(c, "input")));
              if (!HausJson.importJson(written).equals(HausJson.importJson(json))) {
                failures.add(label + ": wrote " + written);
              }
            } catch (HausException e) {
              failures.add(label + ": write: " + e.getMessage());
            }
            Value want = field(c, "output") != null ? field(c, "output") : field(c, "input");
            checkRead(failures, label, t, got, readError, want);
            break;
          }
          case "Read":
            checkRead(failures, label, t, got, readError, field(c, "output"));
            break;
          default: {
            String want = Suite.str(c, "code");
            if (readError == null || !code(readError).equals(want)) {
              failures.add(label + ": got " + (readError == null ? "a value" : readError.getMessage()) + ", want " + want);
            } else if (field(c, "path") != null && !path(readError).equals(Suite.str(c, "path"))) {
              failures.add(label + ": at " + path(readError) + ", want " + Suite.str(c, "path"));
            }
          }
        }
      }
    }
    assertEquals(List.of(), failures);
  }

  private static void checkRead(List<String> failures, String label, SchemaType t, Value got, HausException error, Value want) {
    if (error != null) {
      failures.add(label + ": read: " + error.getMessage());
      return;
    }
    // The value read is a decoded value: encoding gives it back.
    Value encoded = t.encode(got);
    if (!encoded.equals(want)) {
      failures.add(label + ": read " + Haus.canonical(encoded) + ", want " + Haus.canonical(want));
    }
  }

  @Test
  void noJsonFormWarnings() {
    Schema s = Schema.parse("type Odd = < Odd { _tag: Int32 } | Fine { a: Int32 } >\n"
        + "type Rec = { _args: Int32 }\n"
        + "type Named = < N Rec >\n"
        + "type Nested = { items: Array (< In { _tag: String } >) }\n");
    List<String> got = new ArrayList<>();
    for (HausException w : s.warnings()) {
      if (w.code() == ErrorCode.NO_JSON_FORM) {
        got.add(w.getMessage());
      }
    }
    assertEquals(List.of(
        "1:14: Odd has a field named _tag, so it has no schema-based JSON form [no-json-form]",
        "3:16: N has a field named _args, so it has no schema-based JSON form [no-json-form]",
        "4:33: In has a field named _tag, so it has no schema-based JSON form [no-json-form]"), got);
    SchemaType odd = s.type("Odd");
    assertEquals(ErrorCode.NO_JSON_FORM, catching(() -> odd.toJson(Haus.parse("Odd { _tag: 1 }"))).code());
    assertEquals(ErrorCode.NO_JSON_FORM, catching(() -> odd.fromJson("{\"_tag\": \"Odd\"}")).code());
    assertEquals("Fine{a:1}", Haus.canonical(odd.fromJson("{\"_tag\": \"Fine\", \"a\": 1}")));
  }

  @Test
  void jsonPaths() {
    Schema s = Schema.parse("type Line = { sku: String, price: Decimal, key?: Secret String }\n"
        + "type Order = { items: Array Line, tags: Map Int32, maybe?: Maybe (Maybe Int32) }\n");
    SchemaType order = s.type("Order");
    String[][] tests = {
      {"{\"items\": [{\"sku\": \"a\", \"price\": \"1\"}, {\"sku\": \"b\", \"price\": 1}], \"tags\": {}}", "type-mismatch", "$.items[1].price"},
      {"{\"items\": [], \"tags\": {\"pt-BR\": \"x\"}}", "type-mismatch", "$.tags[\"pt-BR\"]"},
      {"{\"items\": [], \"tags\": {}, \"maybe\": {\"_tag\": \"Some\", \"value\": \"x\"}}", "type-mismatch", "$.maybe.value"},
      {"{\"items\": [{\"sku\": \"a\", \"price\": \"1\", \"key\": 7}], \"tags\": {}}", "invalid-secret", "$.items[0].key"},
    };
    for (String[] t : tests) {
      HausException e = catching(() -> order.fromJson(t[0]));
      assertEquals(t[1] + " " + t[2], e == null ? "none" : code(e) + " " + path(e), t[0]);
      assertTrue(!e.getMessage().contains("7") || !t[1].equals("invalid-secret"));
    }
  }

  /**
   * Schema-based lengths count on the value read (§16, "Limits"): a {@code "_tag"} (listed or not)
   * and an enum's string are tags, a map's and a listed field's member names keys; an open record's
   * unlisted members aren't in the value and don't count.
   */
  @Test
  void jsonLengthsOnTheValue() {
    Schema s = Schema.parse("type M = Map String\ntype Open = < A >\ntype Known = < Abcdefg | Abcdef >\n"
        + "type Enum = closed < A | Abcdefg | Abcdef >\ntype Long = { abcdefg: String }\ntype R = { a: String }\n");
    DecodeOptions six = DecodeOptions.DEFAULT.withLimits(Limits.DEFAULT.withMaxStringLength(6));
    String[][] tests = {
      {"M", "{\"abcdefg\": \"x\"}", "key-too-long"},
      {"M", "{\"abcdef\": \"abcdefg\"}", "string-too-long"},
      {"Open", "{\"_tag\": \"Abcdefg\"}", "tag-too-long"},
      {"Known", "{\"_tag\": \"Abcdefg\"}", "tag-too-long"},
      {"Enum", "\"Abcdefg\"", "tag-too-long"},
      {"Long", "{\"abcdefg\": \"x\"}", "key-too-long"},
      {"M", "{\"abcdef\": \"x\"}", "none"},
      {"Open", "{\"_tag\": \"Abcdef\"}", "none"},
      {"Known", "{\"_tag\": \"Abcdef\"}", "none"},
      {"Enum", "\"Abcdef\"", "none"},
      {"R", "{\"a\": \"x\", \"abcdefg\": 1}", "none"},
      {"R", "{\"a\": \"x\", \"b\": \"abcdefg\"}", "none"},
    };
    for (String[] t : tests) {
      SchemaType type = s.type(t[0]);
      HausException e = catching(() -> type.fromJson(t[1].getBytes(StandardCharsets.UTF_8), six));
      assertEquals(t[2], e == null ? "none" : code(e), t[0] + " " + t[1]);
    }
  }
}
