package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

/**
 * The stream suite (test-suite/README.md, "Stream suite"): each case of limits.cases.haus whole,
 * one character at a time, and in two pieces split at every byte, and parsed whole where it gives
 * {@code whole}; single documents (document.cases.haus); and streams decoded with a type
 * (typed.schema.haus, typed.cases.haus).
 */
class StreamSuiteTest {

  /** Gives its pieces one per read. */
  static final class Pieces extends InputStream {
    private final List<byte[]> pieces;
    private int piece;
    private int at;

    Pieces(List<byte[]> pieces) {
      this.pieces = pieces;
    }

    @Override
    public int read() {
      byte[] b = new byte[1];
      return read(b, 0, 1) < 0 ? -1 : b[0] & 0xFF;
    }

    @Override
    public int read(byte[] b, int off, int len) {
      while (piece < pieces.size() && at == pieces.get(piece).length) {
        piece++;
        at = 0;
      }
      if (piece == pieces.size()) {
        return -1;
      }
      int n = Math.min(len, pieces.get(piece).length - at);
      System.arraycopy(pieces.get(piece), at, b, off, n);
      at += n;
      return n;
    }
  }

  /** The values read, or the code of the error, as a string to compare. */
  static String read(List<byte[]> pieces, StreamOptions options) {
    List<Value> values = new ArrayList<>();
    try (StreamReader r = new StreamReader(new Pieces(pieces), options)) {
      for (Value v; (v = r.read()) != null; ) {
        values.add(v);
      }
    } catch (HausException e) {
      return "Err(" + e.code() + ")";
    } catch (IOException e) {
      throw new AssertionError(e);
    }
    return "Ok(" + values + ")";
  }

  private static Map<String, List<byte[]>> splits(byte[] text) {
    Map<String, List<byte[]>> out = new LinkedHashMap<>();
    out.put("whole", List.of(text));
    List<byte[]> chars = new ArrayList<>();
    String s = new String(text, StandardCharsets.UTF_8);
    s.codePoints().forEach(cp -> chars.add(new String(Character.toChars(cp)).getBytes(StandardCharsets.UTF_8)));
    out.put("by character", chars);
    for (int i = 0; i <= text.length; i++) {
      out.put("split at byte " + i, List.of(Arrays.copyOfRange(text, 0, i), Arrays.copyOfRange(text, i, text.length)));
    }
    return out;
  }

  @TestFactory
  Stream<DynamicTest> limits() {
    List<Value> cases = Haus.parseAll(Suite.bytes(Suite.suite("stream", "limits.cases.haus")));
    assertEquals(24, cases.size());
    return cases.stream().map(c -> {
      Value.Record r = (Value.Record) c;
      String text = ((Value.Text) r.get("text")).value();
      int max = ((Value.Number) r.get("maxValueLength")).toBigInteger().intValueExact();
      boolean strict = Value.bool(true).equals(r.get("strict"));
      Value.Variant result = (Value.Variant) r.get("result");
      String want = result.tag().equals("Ok")
          ? "Ok(" + ((Value.Array) result.get(0)).items() + ")"
          : "Err(" + ((Value.Text) result.get(0)).value() + ")";
      StreamOptions options = new StreamOptions(Limits.DEFAULT.withMaxValueLength(max), strict);
      return dynamicTest(c.toString(), () -> splits(text.getBytes(StandardCharsets.UTF_8))
          .forEach((how, pieces) -> assertEquals(want, read(pieces, options), how)));
    });
  }

  /** The canonical form of the values as an array (spec §12). */
  private static String canonical(List<Value> values) {
    return values.stream().map(Haus::canonical).collect(Collectors.joining(",", "[", "]"));
  }

  /**
   * The cases of limits.cases.haus with {@code whole}: the value limit is a stream reader's, so
   * parsing the whole text (default limits) gives the values.
   */
  @TestFactory
  Stream<DynamicTest> parsedWhole() {
    List<Value.Record> cases = Haus.parseAll(Suite.bytes(Suite.suite("stream", "limits.cases.haus"))).stream()
        .map(c -> (Value.Record) c)
        .filter(c -> c.get("whole") != null)
        .collect(Collectors.toList());
    assertTrue(cases.size() > 0, "no cases with whole");
    return cases.stream().map(r -> {
      String text = ((Value.Text) r.get("text")).value();
      Value.Variant whole = (Value.Variant) r.get("whole");
      String want = "Ok(" + canonical(((Value.Array) whole.get(0)).items()) + ")";
      return dynamicTest(r.toString(), () -> {
        String got;
        try {
          got = "Ok(" + canonical(Haus.parseAll(text)) + ")";
        } catch (HausException e) {
          got = "Err(" + e.code().code() + ")";
        }
        assertEquals(want, got);
      });
    });
  }

  /** document.cases.haus: text that must hold exactly one value (spec §6), read with {@link Haus#parse}. */
  @TestFactory
  Stream<DynamicTest> documents() {
    List<Value> cases = Haus.parseAll(Suite.bytes(Suite.suite("stream", "document.cases.haus")));
    assertTrue(cases.size() > 0, "no cases");
    return cases.stream().map(c -> {
      Value.Record r = (Value.Record) c;
      String text = ((Value.Text) r.get("text")).value();
      Value.Variant result = (Value.Variant) r.get("result");
      String want = result.tag().equals("Ok")
          ? "Ok(" + Haus.canonical(result.get(0)) + ")"
          : "Err(" + ((Value.Text) result.get(0)).value() + ")";
      return dynamicTest(c.toString(), () -> {
        String got;
        try {
          got = "Ok(" + Haus.canonical(Haus.parse(text)) + ")";
        } catch (HausException e) {
          got = "Err(" + e.code().code() + ")";
        }
        assertEquals(want, got);
      });
    });
  }

  /**
   * typed.cases.haus: a {@code Stream} type decodes with the binding's {@link
   * SchemaType#decodeStream}, so the index in an error's path is the binding's; any other type with
   * a codec's single-document {@link HausCodec#decode(String)}. The decoded values are encoded with
   * the type and compared with {@code output}.
   */
  @TestFactory
  Stream<DynamicTest> typed() {
    Schema schema = Schema.parse(Suite.text(Suite.suite("stream", "typed.schema.haus")));
    List<Value.Variant> cases = Suite.cases(Suite.suite("stream", "typed.cases.haus"));
    assertTrue(cases.size() > 0, "no cases");
    return cases.stream().map(c -> {
      SchemaType t = schema.type(Suite.str(c, "type"));
      String text = Suite.str(c, "text");
      String want = c.tag().equals("Ok")
          ? "Ok(" + Haus.canonical(c.payload().get("output")) + ")"
          : "Err(" + Suite.str(c, "code") + " at " + Suite.str(c, "path") + ")";
      return dynamicTest(c.toString(), () -> {
        String got;
        try {
          if (t.isStream()) {
            InputStream in = new ByteArrayInputStream(text.getBytes(StandardCharsets.UTF_8));
            try (Stream<Value> items = t.decodeStream(in, StreamOptions.DEFAULT)) {
              got = "Ok(" + canonical(items.map(t::encode).collect(Collectors.toList())) + ")";
            }
          } else {
            got = "Ok(" + Haus.canonical(t.encode(schema.codec(t.name(), Value.class).decode(text))) + ")";
          }
        } catch (HausException e) {
          got = "Err(" + e.code().code() + " at " + (e.path() == null ? "(no path)" : e.path()) + ")";
        }
        assertEquals(want, got);
      });
    });
  }
}
