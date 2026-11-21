package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

/** The conformance suite (test-suite/README.md): valid and invalid files, and the format suite. */
class SuiteTest {

  @TestFactory
  Stream<DynamicTest> valid() {
    Path dir = Suite.suite("valid");
    return Suite.names(dir, ".haus").stream().map(name -> dynamicTest(name, () -> {
      List<Value> values = Haus.parseAll(Suite.bytes(dir.resolve(name + ".haus")));
      List<Value> want = HausJson.fromHausJsonLines(Suite.text(dir.resolve(name + ".jsonl")));
      assertEquals(want, values, "values");
      for (int i = 0; i < values.size(); i++) {
        assertReadAlike(want.get(i), values.get(i));
      }
      StringBuilder canonical = new StringBuilder();
      for (Value v : values) {
        canonical.append(Haus.canonical(v)).append('\n');
      }
      assertEquals(Suite.text(dir.resolve(name + ".canonical")), canonical.toString(), "canonical");
      assertEquals(Suite.text(dir.resolve(name + ".hash")).trim(), Haus.hashAll(values), "hash");
    }));
  }

  /**
   * What the parser works out as it reads, without asking the values: each value's depth, the
   * same as for a value built in code, and records whose keys it read as identifiers.
   */
  private static void assertReadAlike(Value built, Value read) {
    assertEquals(built.depth(), read.depth(), "depth of " + read);
    if (read instanceof Value.Record r) {
      for (int i = 0; i < r.size(); i++) {
        assertTrue(!r.bareKeys() || Scan.isIdent(r.keyAt(i)), "a bare key that isn't an identifier: " + r.keyAt(i));
        assertReadAlike(((Value.Record) built).get(r.keyAt(i)), r.valueAt(i));
      }
    } else if (read instanceof Value.Array a) {
      for (int i = 0; i < a.size(); i++) {
        assertReadAlike(((Value.Array) built).get(i), a.get(i));
      }
    } else if (read instanceof Value.Variant v) {
      for (int i = 0; i < v.size(); i++) {
        assertReadAlike(((Value.Variant) built).get(i), v.get(i));
      }
    }
  }

  @TestFactory
  Stream<DynamicTest> invalid() {
    Path dir = Suite.suite("invalid");
    return Suite.names(dir, ".haus").stream().map(name -> dynamicTest(name, () -> {
      String want = Suite.text(dir.resolve(name + ".error")).trim();
      HausException e = assertThrows(HausException.class, () -> Haus.parseAll(Suite.bytes(dir.resolve(name + ".haus"))));
      assertEquals(want, e.code().code(), e.getMessage());
      assertTrue(e.line() >= 1 && e.column() >= 1, "no position: " + e.getMessage());
    }));
  }

  @TestFactory
  Stream<DynamicTest> codesInCatalogue() {
    List<Path> files = new ArrayList<>();
    for (String dir : new String[] {"invalid", "schema/invalid"}) {
      Path d = Suite.suite(dir.split("/"));
      Suite.names(d, ".error").forEach(n -> files.add(d.resolve(n + ".error")));
    }
    return files.stream().map(p -> dynamicTest(p.getFileName().toString(),
        () -> assertNotNull(ErrorCode.fromCode(Suite.text(p).trim()), p.toString())));
  }

  /** An input of the format suite and the expected outputs, without their extension. */
  private record FormatCase(String name, Path input, Path expected) {}

  private static List<FormatCase> formatCases() {
    List<FormatCase> cases = new ArrayList<>();
    for (String dir : new String[] {"cases", "examples"}) {
      Path d = Suite.suite("format", dir);
      for (String name : Suite.names(d, ".haus")) {
        cases.add(new FormatCase(dir + "/" + name, d.resolve(name + ".haus"), d.resolve(name)));
      }
    }
    Path valid = Suite.suite("valid");
    for (String name : Suite.names(valid, ".haus")) {
      cases.add(new FormatCase("valid/" + name, valid.resolve(name + ".haus"), Suite.suite("format", "valid", name)));
    }
    return cases;
  }

  private static FormatOptions options(FormatCase c) {
    Path file = c.expected.resolveSibling(c.expected.getFileName() + ".options");
    FormatOptions o = FormatOptions.PRETTY;
    if (!file.toFile().exists()) {
      return o;
    }
    for (Map.Entry<String, Value> e : ((Value.Record) Haus.parse(Suite.bytes(file))).toMap().entrySet()) {
      int n = ((Value.Number) e.getValue()).toBigInteger().intValueExact();
      switch (e.getKey()) {
        case "indent":
          o = o.withIndent(n);
          break;
        case "width":
          o = o.withWidth(n);
          break;
        default:
          throw new AssertionError("unknown option " + e.getKey());
      }
    }
    return o;
  }

  private static Path expected(FormatCase c, Layout l) {
    return c.expected.resolveSibling(c.expected.getFileName() + "." + l.name().toLowerCase());
  }

  private static void sameValues(String what, String a, byte[] b) {
    assertEquals(Haus.hashAll(Haus.parseAll(b)), Haus.hashAll(Haus.parseAll(a)), what + ": different values");
  }

  @TestFactory
  Stream<DynamicTest> format() {
    return formatCases().stream().map(c -> dynamicTest(c.name, () -> {
      byte[] input = Suite.bytes(c.input);
      FormatOptions o = options(c);
      Map<Layout, String> outs = new java.util.EnumMap<>(Layout.class);
      for (Layout l : Layout.values()) {
        String got = Haus.format(input, o.withLayout(l));
        outs.put(l, got);
        assertEquals(Suite.text(expected(c, l)), got, l.toString());
        assertEquals(got, Haus.format(got, o.withLayout(l)), l + " is not idempotent");
        sameValues(l.toString(), got, input);
      }
      String back = Haus.format(outs.get(Layout.MINIMISED), o);
      assertEquals(Haus.format(outs.get(Layout.COMPACT), o), back, "minimised and compact, formatted as pretty, differ");
      assertEquals(withoutBlankLines(withoutComments(input, o)), withoutBlankLines(back),
          "minimised, formatted as pretty, is not the pretty file without comments");
      sameValues("pretty with trailing blanks trimmed", outs.get(Layout.PRETTY).replaceAll("(?m)[ \\t]+$", ""), input);
    }));
  }

  /** The text formatted as pretty with its comments removed. */
  private static String withoutComments(byte[] text, FormatOptions o) {
    Syntax.File f = Haus.syntax(new Source(text), Limits.DEFAULT);
    Syntax.stripComments(f);
    return Printer.print(f, o);
  }

  private static String withoutBlankLines(String s) {
    return s.replaceAll("(?m)^\n", "");
  }
}
