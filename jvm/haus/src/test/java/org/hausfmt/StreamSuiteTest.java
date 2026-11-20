package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

/**
 * The stream suite (test-suite/README.md, "Stream suite"): each case whole, one character at a
 * time, and in two pieces split at every byte.
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
    assertEquals(19, cases.size());
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
}
