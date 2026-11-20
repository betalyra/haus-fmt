package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;

class ApiTest {

  private static ErrorCode code(Executable e) {
    return assertThrows(HausException.class, e).code();
  }

  private static String repeat(String s, int n) {
    return String.join("", Collections.nCopies(n, s));
  }

  @Test
  void positions() {
    Object[][] cases = {
      {"[1 2]", 1, 4},
      {"\uFEFF[1 2]", 1, 5}, // a byte order mark is a character (spec §8)
      {"[\"😀\" 2]", 1, 6}, // an emoji is one column
      {"[\r\n  1 2]", 2, 5}, // CR LF is one line break
      {"[\"\u2028\" 2]", 1, 6}, // U+2028 doesn't start a line
      {"{\n  a: 1,\n  b: x }", 3, 6},
      {"// c\n\"a\u0001b\"", 2, 3},
      {"\"\"\"\n  ok\n bad\n  \"\"\"", 3, 1},
    };
    for (Object[] c : cases) {
      HausException e = assertThrows(HausException.class, () -> Haus.parseAll((String) c[0]));
      assertEquals(c[1], e.line(), e.getMessage());
      assertEquals(c[2], e.column(), e.getMessage());
    }
    HausException e = assertThrows(HausException.class, () -> Haus.parseAll(new byte[] {'[', '1', ',', ' ', (byte) 0xFF, ']'}));
    assertEquals(ErrorCode.INVALID_UTF8, e.code());
    assertEquals(5, e.column());
    assertEquals(ErrorCode.INVALID_UTF8, code(() -> Haus.parseAll("\"a\uD800\"")));
  }

  @Test
  void versionDirective() {
    assertEquals(ErrorCode.VERSION_DIRECTIVE, code(() -> Haus.parseAll("#haus 2\n{ a: 1 }")));
    assertEquals(ErrorCode.VERSION_DIRECTIVE, code(() -> Haus.parseAll("\uFEFF#haus 2\n{ a: 1 }")));
    assertEquals(ErrorCode.EXPECTED_VALUE, code(() -> Haus.parseAll("#hello")));
    assertEquals(ErrorCode.EXPECTED_VALUE, code(() -> Haus.parseAll(" #haus 2")));
  }

  @Test
  void limits() {
    Limits d = Limits.DEFAULT;
    Object[][] cases = {
      {deep(256, "[", "]"), d, null},
      {deep(257, "[", "]"), d, ErrorCode.NESTING_TOO_DEEP},
      {deep(3, "A(", ")"), d.withMaxDepth(3), null},
      {deep(4, "A(", ")"), d.withMaxDepth(3), ErrorCode.NESTING_TOO_DEEP},
      {"Some { a: 1 }", d.withMaxDepth(1), null},
      {"Some({ a: 1 })", d.withMaxDepth(1), ErrorCode.NESTING_TOO_DEEP},
      {"\"ééé\"", d.withMaxStringLength(3), null},
      {"\"éééé\"", d.withMaxStringLength(3), ErrorCode.STRING_TOO_LONG},
      {"\"a\\u{41}\\n\"", d.withMaxStringLength(3), null},
      {"\"\"\"\n    abc\n    \"\"\"", d.withMaxStringLength(3), null},
      {"\"\"\"\n    abcd\n    \"\"\"", d.withMaxStringLength(3), ErrorCode.STRING_TOO_LONG},
      {"{ abcd: 1 }", d.withMaxStringLength(3), ErrorCode.KEY_TOO_LONG},
      {"{ \"abcd\": 1 }", d.withMaxStringLength(3), ErrorCode.KEY_TOO_LONG},
      {"Abcd", d.withMaxStringLength(3), ErrorCode.TAG_TOO_LONG},
      {"x\"00 11\"", d.withMaxStringLength(5), null},
      {"x\"00  11\"", d.withMaxStringLength(5), ErrorCode.STRING_TOO_LONG},
      {"12345", d.withMaxNumberLength(5), null},
      {"-12345", d.withMaxNumberLength(5), ErrorCode.NUMBER_TOO_LONG},
      {"1_000", d.withMaxNumberLength(5), null},
      {"0xFFFF", d.withMaxNumberLength(6), null},
      {"0xFFFFF", d.withMaxNumberLength(7), ErrorCode.NUMBER_TOO_LONG},
      {"1e10", d.withMaxExponent(10), null},
      {"1e-11", d.withMaxExponent(10), ErrorCode.EXPONENT_TOO_LARGE},
      {"1e0000000000000000000010", d.withMaxExponent(10), null},
    };
    for (Object[] c : cases) {
      Executable parse = () -> Haus.parseAll((String) c[0], (Limits) c[1]);
      if (c[2] == null) {
        Haus.parseAll((String) c[0], (Limits) c[1]);
      } else {
        assertEquals(c[2], code(parse), (String) c[0]);
      }
    }
    assertEquals(ErrorCode.UNSUPPORTED_DEPTH, code(() -> d.withMaxDepth(Limits.MAX_SUPPORTED_DEPTH + 1)));
    assertEquals(ErrorCode.UNSUPPORTED_DEPTH, code(() -> d.withMaxDepth(0)));
    assertEquals(829, d.maxHexDigits());
    int[][] hex = {{1, 0}, {2, 0}, {3, 1}, {5, 3}, {6, 4}, {7, 4}, {1000, 829}};
    for (int[] h : hex) {
      assertEquals(h[1], d.withMaxNumberLength(h[0]).maxHexDigits(), "maxHexDigits " + h[0]);
    }
  }

  private static String deep(int n, String open, String closer) {
    return repeat(open, n) + "1" + repeat(closer, n);
  }

  /**
   * The deepest nesting supported, on the default stack of a thread: parsing, writing in every
   * layout, the canonical form, equality, hashing and JSON.
   */
  @Test
  void supportedDepth() {
    Limits deepest = Limits.DEFAULT.withMaxDepth(Limits.MAX_SUPPORTED_DEPTH);
    for (String[] brackets : new String[][] {{"[", "]"}, {"A(", ")"}, {"{ a: ", " }"}, {"T { a: ", " }"}}) {
      String text = deep(Limits.MAX_SUPPORTED_DEPTH, brackets[0], brackets[1]);
      Value v = Haus.parse(text, deepest);
      assertEquals(Limits.MAX_SUPPORTED_DEPTH, v.depth());
      assertEquals(v, Haus.parse(text, deepest));
      assertEquals(Haus.parse(text, deepest).hashCode(), v.hashCode());
      for (Layout l : Layout.values()) {
        FormatOptions o = FormatOptions.of(l).withLimits(deepest);
        assertEquals(v, Haus.parse(Haus.write(v, o), deepest));
        Haus.format(text, o);
      }
      assertEquals(v, Haus.parse(Haus.canonical(v), deepest));
      Haus.hash(v);
      assertEquals(v, HausJson.fromHausJson(HausJson.toHausJson(v, deepest), deepest));
      assertEquals(ErrorCode.NESTING_TOO_DEEP, code(() -> Haus.parse(deep(Limits.MAX_SUPPORTED_DEPTH + 1, brackets[0], brackets[1]), deepest)));
    }
    Value v = Value.number(0);
    for (int i = 0; i < Limits.MAX_SUPPORTED_DEPTH; i++) {
      v = Value.array(v);
    }
    Value deepestValue = v;
    assertEquals(ErrorCode.NESTING_TOO_DEEP, code(() -> Value.array(deepestValue)));
    // A configured depth below the value's depth is reported by the writers.
    FormatOptions shallower = FormatOptions.of(Layout.COMPACT).withLimits(Limits.DEFAULT.withMaxDepth(Limits.MAX_SUPPORTED_DEPTH - 1));
    assertEquals(ErrorCode.NESTING_TOO_DEEP, code(() -> Haus.write(deepestValue, shallower)));
  }

  @Test
  void parseOne() {
    for (String text : new String[] {"", "// nothing", "1, 2", "1, 2,"}) {
      assertEquals(ErrorCode.NOT_ONE_VALUE, code(() -> Haus.parse(text)), text);
    }
    assertEquals(Value.number(1), Haus.parse("1,"));
  }

  @Test
  void numbers() {
    Map<String, String> normalized = new LinkedHashMap<>();
    normalized.put("1_000", "1000");
    normalized.put("0xFF", "255");
    normalized.put("-0x0", "-0");
    normalized.put("0b1010", "10");
    normalized.put("1E+05", "1e5");
    normalized.put("1e-07", "1e-7");
    normalized.put("1e-0", "1e0");
    normalized.put("19.90", "19.90");
    normalized.put("-0", "-0");
    normalized.put("1.5e00_1", "1.5e1");
    normalized.forEach((lit, want) -> assertEquals(want, Value.number(lit).literal(), lit));
    for (String bad : new String[] {"", "1 ", "+1", "007", "1.", "0X1", "1e", "1__0", "-"}) {
      assertThrows(HausException.class, () -> Value.number(bad), bad);
    }
    assertEquals("-42", Value.number(-42).literal());
    BigInteger big = new BigInteger("123456789012345678901234567890");
    assertEquals(big, Value.number(big).toBigInteger());
    assertEquals("19.90", Value.number(new BigDecimal("19.90")).literal());
    assertEquals("1e3", Value.number(new BigDecimal("1E+3")).literal());
    assertFalse(Value.number("1e2").isInteger());
    assertThrows(ArithmeticException.class, () -> Value.number("1e2").toBigInteger());
    assertEquals(BigInteger.valueOf(255), Value.number("0xFF").toBigInteger());
    assertEquals(new BigDecimal("1e5"), Value.number("1E+05").toBigDecimal());
  }

  @Test
  void records() {
    assertEquals(ErrorCode.DUPLICATE_KEY,
        code(() -> Value.record(Value.field("a", Value.string("x")), Value.field("a", Value.string("y")))));
    List<Value.Field> fields = new ArrayList<>();
    StringBuilder text = new StringBuilder("{");
    for (int i = 0; i < 40; i++) {
      String key = (char) ('a' + i % 26) + repeat("x", i / 26);
      fields.add(Value.field(key, Value.number(i)));
      text.append(key).append(": 1, ");
    }
    Value.Record r = Value.record(fields);
    assertEquals(Value.number(39), r.get("nx"));
    assertNull(r.get("zz"));
    assertEquals(40, r.size());
    Haus.parse(text + "}");
    assertEquals(ErrorCode.DUPLICATE_KEY, code(() -> Haus.parse(text + "kx: 2 }")));
    assertEquals(0, Value.record().size());
    // Keys whose String.hashCode collide ("Aa" and "BB"): the parser's table is seeded.
    List<String> colliding = new ArrayList<>(Collections.singletonList("k"));
    for (int k = 0; k < 10; k++) {
      List<String> next = new ArrayList<>();
      for (String s : colliding) {
        next.add(s + "Aa");
        next.add(s + "BB");
      }
      colliding = next;
    }
    StringBuilder crafted = new StringBuilder("{");
    for (String k : colliding) {
      crafted.append(k).append(": 1, ");
    }
    assertEquals(1024, ((Value.Record) Haus.parse(crafted + "}")).size());
    String repeated = crafted + colliding.get(512) + ": 2 }";
    assertEquals(ErrorCode.DUPLICATE_KEY, code(() -> Haus.parse(repeated)));
  }

  @Test
  void valuesAreImmutableAndCompareAsHaus() {
    List<Value> items = new ArrayList<>(Arrays.asList(Value.number(1), Value.string("a")));
    Value.Array a = Value.array(items);
    items.clear();
    assertEquals(2, a.size());
    assertThrows(UnsupportedOperationException.class, () -> a.items().add(Value.number(2)));
    byte[] raw = {1, 2};
    Value.Bytes b = Value.bytes(raw);
    raw[0] = 9;
    assertEquals("x\"0102\"", b.toString());
    assertEquals(ErrorCode.INVALID_TAG, code(() -> Value.variant("lower")));
    assertEquals("[1, \"a\"]", a.toString());
    assertEquals("Circle { r: 1 }", Value.variant("Circle", Value.record(Value.field("r", Value.number(1)))).toString());
  }

  @Test
  void canonical() {
    Map<String, String> cases = new LinkedHashMap<>();
    cases.put("Order { total: 19.90, id: 0xFF, \"x-y\": 1e+5, p: Point(1, 2) }", "Order{id:255,p:Point(1,2),total:19.90,\"x-y\":1e5}");
    cases.put("Tag({ b: 1, a: 2 })", "Tag{a:2,b:1}");
    cases.put("[\"\\u{41}\", x\"0B 34\", \"a\\tb\\u{1b}\\u{202E}\"]", "[\"A\",x\"0b34\",\"a\\tb\\u{1B}\\u{202E}\"]");
    // Keys sort by code point, not UTF-16 unit: U+FF61 before U+1F600.
    cases.put("{ \"😀\": 1, \"｡\": 2, \"Z\": 3, a: 4 }", "{\"Z\":3,a:4,\"｡\":2,\"😀\":1}");
    cases.forEach((text, want) -> assertEquals(want, Haus.canonical(Haus.parse(text)), text));
    assertEquals(Haus.hashAll(Haus.parseAll("1,\"a\",Order{id:255}")), Haus.hashAll(Haus.parseAll("1, \"a\", Order { id: 0xFF },")));
    assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", Haus.hashAll(Collections.emptyList()));
    Value v = Haus.parse("{ a: 1 }");
    assertEquals(Haus.hash(v), Haus.hashAll(Collections.singletonList(v)));
    assertEquals(ErrorCode.CANNOT_ENCODE, code(() -> Haus.canonical(Value.string("\uD800"))));
    assertEquals(ErrorCode.CANNOT_ENCODE, code(() -> Haus.canonical(Value.record(Value.field("\uDC00", Value.number(1))))));
  }

  @Test
  void check() {
    Limits d = Limits.DEFAULT;
    Object[][] cases = {
      {Value.string("ok"), d, null, null},
      {Value.array(Value.string("ok"), Value.string("\uD800")), d, ErrorCode.CANNOT_ENCODE, "$[1]"},
      {Value.number("1e100"), d.withMaxExponent(99), ErrorCode.EXPONENT_TOO_LARGE, "$"},
      {Value.string("abc"), d.withMaxStringLength(2), ErrorCode.STRING_TOO_LONG, "$"},
      {Value.bytes(new byte[] {1, 2}), d.withMaxStringLength(3), ErrorCode.STRING_TOO_LONG, "$"},
      {Value.record(Value.field("a-b", Value.array(Value.string("ok")))), d, null, null},
      {Value.variant("T", Value.array(Value.array())), d.withMaxDepth(1), ErrorCode.NESTING_TOO_DEEP, "$[0]"},
    };
    for (Object[] c : cases) {
      if (c[2] == null) {
        Haus.check((Value) c[0], (Limits) c[1]);
        continue;
      }
      HausException e = assertThrows(HausException.class, () -> Haus.check((Value) c[0], (Limits) c[1]));
      assertEquals(c[2], e.code());
      assertEquals(c[3], e.path());
    }
    // An empty record, array or record payload is a level, as when parsing (spec §7).
    Value.Record empty = Value.record();
    Limits one = d.withMaxDepth(1);
    Object[][] levels = {
      {Value.array(Value.array()), "$[0]"},
      {Value.record(Value.field("a", empty)), "$.a"},
      {Value.array(Value.variant("T", empty)), "$[0]"},
      {Value.variant("T", Value.array()), "$[0]"},
    };
    for (Object[] c : levels) {
      Value v = (Value) c[0];
      String text = Haus.canonical(v);
      assertEquals(2, v.depth(), text);
      assertEquals(ErrorCode.NESTING_TOO_DEEP, code(() -> Haus.parse(text, one)), text);
      HausException e = assertThrows(HausException.class, () -> Haus.check(v, one));
      assertEquals(c[1], e.path(), text);
      assertEquals(ErrorCode.NESTING_TOO_DEEP, code(() -> Haus.write(v, FormatOptions.PRETTY.withLimits(one))), text);
      assertEquals(ErrorCode.NESTING_TOO_DEEP, code(() -> HausJson.toHausJson(v, one)), text);
      Haus.check(v, d.withMaxDepth(2));
    }
    for (Value v : new Value[] {Value.array(), empty, Value.variant("T", empty), Value.variant("T", Value.record(Value.field("a", Value.number(1))))}) {
      Haus.check(v, one);
    }
  }

  @Test
  void equalsAndCompare() {
    String[][] equal = {
      {"1_000", "1000"}, {"0xFF", "255"}, {"1E+05", "1e5"}, {"-0x0", "-0"},
      {"\"\\u{41}\"", "\"A\""}, {"x\"0B 34\"", "x\"0b34\""}, {"{ a: 1, b: 2 }", "{ b: 2, a: 1 }"},
      {"Tag({ a: 1 })", "Tag { a: 1 }"},
    };
    for (String[] c : equal) {
      Value a = Haus.parse(c[0]);
      Value b = Haus.parse(c[1]);
      assertEquals(a, b);
      assertEquals(a.hashCode(), b.hashCode());
      assertEquals(0, Haus.compare(a, b));
    }
    String[][] differ = {
      {"1.0", "1"}, {"1e2", "100"}, {"x\"41\"", "\"A\""}, {"x\"01\"", "[1]"}, {"{}", "{ x: None }"},
      {"A", "A(1)"}, {"[1]", "[1, 2]"}, {"{ a: 1 }", "{ b: 1 }"},
    };
    for (String[] c : differ) {
      Value a = Haus.parse(c[0]);
      Value b = Haus.parse(c[1]);
      assertNotEquals(a, b);
      assertNotEquals(0, Haus.compare(a, b));
    }
    assertTrue(Haus.compare(Haus.parse("10"), Haus.parse("9")) < 0);
    assertTrue(Haus.compare(Haus.parse("1"), Haus.parse("10")) < 0);
  }

  /** Where comments and blank lines land, as the other formatters put them (found by the differential fuzzer). */
  @Test
  void formatComments() {
    String[][] cases = {
      {"{b:T(/**/{/**/\n\n}//\n),/**/a:F}//", "{\n  b: T {\n    /**/\n    /**/\n\n    //\n  }, /**/\n  a: F,\n} //\n"},
      {"F,//\nF({a:0/**/\n\n}\n/**/)", "F, //\nF {\n  a: 0, /**/\n\n  /**/\n},\n"},
      {"T(/**/\n\n{}/*x*/)", "T {\n  /**/\n\n  /*x*/\n}\n"},
      {"E(//\n\n{}//a\n)", "E {\n  //\n\n  //a\n}\n"},
      {"N({a:0/*\n*/}//\n)", "N {\n  a: 0, /*\n*/\n  //\n}\n"},
      {"N(\"\"\"\n\"\"\")/*\n*///", "N(\"\") /*\n*/\n//\n"},
      {"[A(5)/*\n*/,//c\n\"\"]", "[\n  A(5), /*\n*/\n  //c\n  \"\",\n]\n"},
      {"\"\"//\n,\n\"\"//", "\"\", //\n\"\", //\n"},
      {"{b:{b:\"\"},\n\na://\n\"x\"}", "{\n  b: {\n    b: \"\",\n  },\n\n  //\n  a: \"x\",\n}\n"},
    };
    for (String[] c : cases) {
      assertEquals(c[1], Haus.format(c[0], FormatOptions.PRETTY), c[0]);
    }
  }

  @Test
  void writeValues() {
    Value.Record r = Value.record(
        Value.field("n", Value.number("0xFF")),
        Value.field("text", Value.string("a\nb ")),
        Value.field("bytes", Value.bytes(new byte[] {0x0b, 0x34})),
        Value.field("content-type", Value.string("x")),
        Value.field("shape", Value.variant("Circle", Value.record(Value.field("r", Value.number(1))))),
        Value.field("pair", Value.variant("Pair", Value.number(1), Value.string("two"))),
        Value.field("none", Value.variant("None")),
        Value.field("list", Value.array()));
    String pretty = "{\n"
        + "  n: 255,\n"
        + "  text: \"\"\"\n"
        + "    a\n"
        + "    b\\u{20}\n"
        + "    \"\"\",\n"
        + "  bytes: x\"0b34\",\n"
        + "  \"content-type\": \"x\",\n"
        + "  shape: Circle {\n"
        + "    r: 1,\n"
        + "  },\n"
        + "  pair: Pair(1, \"two\"),\n"
        + "  none: None,\n"
        + "  list: [],\n"
        + "}\n";
    assertEquals(pretty, Haus.write(r));
    assertEquals("{n:255,text:\"a\\nb \",bytes:x\"0b34\",\"content-type\":\"x\",shape:Circle{r:1},pair:Pair(1,\"two\"),none:None,list:[]},\n\"s\",\n",
        Haus.writeAll(Arrays.asList(r, Value.string("s")), FormatOptions.MINIMISED));
    for (Layout l : Layout.values()) {
      String out = Haus.write(r, FormatOptions.of(l));
      assertEquals(out, Haus.format(out, FormatOptions.of(l)));
      assertEquals(r, Haus.parse(out));
    }
    assertEquals(ErrorCode.CANNOT_ENCODE, code(() -> Haus.write(Value.string("\uD800"))));
    assertEquals(ErrorCode.NUMBER_TOO_LONG, code(() -> Haus.write(Value.number(BigInteger.TEN.pow(1000)))));
    assertEquals(ErrorCode.NESTING_TOO_DEEP,
        code(() -> Haus.write(Value.array(Value.array()), FormatOptions.PRETTY.withLimits(Limits.DEFAULT.withMaxDepth(1)))));
    Haus.write(Value.variant("Some", Value.record()), FormatOptions.PRETTY.withLimits(Limits.DEFAULT.withMaxDepth(1)));
    assertEquals("", Haus.writeAll(Collections.emptyList(), FormatOptions.COMPACT));
  }

  @Test
  void hasComments() {
    Map<String, Boolean> cases = new LinkedHashMap<>();
    cases.put("{ a: 1 }", false);
    cases.put("// c\n1", true);
    cases.put("[1 /* c */]", true);
    cases.put("1 // c", true);
    cases.put("\"// no\"", false);
    cases.forEach((text, want) -> assertEquals(want, Haus.hasComments(text), text));
  }

  @Test
  void errorJson() {
    HausException e = assertThrows(HausException.class, () -> Haus.parseAll("Heartbeat\n{ at: 1 }"));
    assertEquals(ErrorCode.PAYLOAD_NEWLINE, e.code());
    assertEquals("{\"code\":\"payload-newline\",\"message\":\"the payload of Heartbeat must start on its line: expected ',', found '{'\","
        + "\"line\":2,\"column\":1,\"expected\":\"','\",\"found\":\"'{'\","
        + "\"hint\":\"Put the payload on the tag's line, or add a comma if they are two values.\","
        + "\"docs\":\"https://haus-fmt.org/docs/errors#payload-newline\"}", e.toJson());
    assertEquals("2:1: the payload of Heartbeat must start on its line: expected ',', found '{' [payload-newline]", e.getMessage());
  }
}
