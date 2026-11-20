package org.hausfmt.fuzz;

import java.io.ByteArrayInputStream;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.function.BiFunction;
import java.util.function.Function;
import java.util.function.Supplier;
import org.hausfmt.FormatOptions;
import org.hausfmt.Haus;
import org.hausfmt.HausException;
import org.hausfmt.HausJson;
import org.hausfmt.Layout;
import org.hausfmt.Limits;
import org.hausfmt.StreamReader;
import org.hausfmt.Value;

/**
 * The JVM runner of the differential fuzzers (fuzz/README.md): one program for the fuzzers' modes,
 * the mode first, speaking the protocol of the Go runner (fuzz/go).
 *
 * <pre>
 * jvm-runner [--stream | --canonical] DIR N                       the parser, stream reader, canonical form
 * jvm-runner --format STYLE [--indent N] [--width N] DIR N        Haus.format
 * jvm-runner --write STYLE [--indent N] [--width N] DIR N         the value writers, Haus.write and writeAll
 * jvm-runner --json MODE FILE                                     haus-json-write, haus-json-read, import
 * </pre>
 *
 * <p>The modes with DIR N read DIR/00000.haus … DIR/{N-1}.haus; --json reads a FILE of lines, each a
 * case's bytes in hex. Each prints one line per case:
 *
 * <ul>
 *   <li>parse: {@code ok <values>} in the test-suite JSON encoding, or {@code err <line> <column>
 *       <code> <reason>};
 *   <li>--stream: the same through the stream reader, the input in chunks of [1, 2, 3, 5, 8, 13,
 *       64][(i + k) % 7] bytes;
 *   <li>--canonical: {@code ok} and the canonical form of each value, a JSON array of strings;
 *   <li>--format: {@code ok} and the output as a JSON string;
 *   <li>--write: {@code ok {"values": [...], "file": ...}}, each value written alone (without the
 *       line break after it) and all of them as a file;
 *   <li>--json: {@code ok <JSON>} (haus-json-write) or {@code ok <canonical form>}, or {@code err
 *       <place> <code> <reason>}, the place in the value ({@code $} for an error in the text).
 * </ul>
 */
public final class Runner {
  private static final String USAGE =
      "usage: jvm-runner [--stream | --canonical | --format STYLE [--indent N] [--width N] | --write STYLE [--indent N] [--width N]] DIR N"
          + " | --json MODE FILE";
  private static final int[] CHUNKS = {1, 2, 3, 5, 8, 13, 64};

  private Runner() {}

  public static void main(String[] args) throws IOException {
    PrintStream out = new PrintStream(new FileOutputStream(FileDescriptor.out), false, "UTF-8");
    try {
      run(args, out);
    } catch (IllegalArgumentException e) {
      out.flush();
      System.err.println(e.getMessage());
      System.exit(2);
    }
    out.flush();
  }

  private static void run(String[] args, PrintStream out) throws IOException {
    if (args.length == 0) {
      throw new IllegalArgumentException(USAGE);
    }
    if (args[0].equals("--json")) {
      if (args.length != 3) {
        throw new IllegalArgumentException(USAGE);
      }
      Function<byte[], String> one = jsonMode(args[1]);
      for (String line : Files.readAllLines(Paths.get(args[2]), StandardCharsets.UTF_8)) {
        if (!line.isEmpty()) {
          out.println(oneLine(one.apply(unhex(line))));
        }
      }
      return;
    }
    if (args.length < 2) {
      throw new IllegalArgumentException(USAGE);
    }
    Path dir = Paths.get(args[args.length - 2]);
    int n = Integer.parseInt(args[args.length - 1]);
    BiFunction<byte[], Integer, String> one = fileMode(Arrays.copyOf(args, args.length - 2));
    for (int i = 0; i < n; i++) {
      byte[] src = Files.readAllBytes(dir.resolve(String.format("%05d.haus", i)));
      out.println(oneLine(one.apply(src, i)));
    }
  }

  private static BiFunction<byte[], Integer, String> fileMode(String[] flags) {
    if (flags.length == 0) {
      return (src, i) -> values(() -> Haus.parseAll(src));
    }
    if (flags.length == 1 && flags[0].equals("--stream")) {
      return (src, i) -> values(() -> streamed(src, i));
    }
    if (flags.length == 1 && flags[0].equals("--canonical")) {
      return (src, i) -> canonical(src);
    }
    if (flags.length >= 2 && flags[0].equals("--format")) {
      FormatOptions options = options(flags);
      return (src, i) -> {
        try {
          return "ok " + json(Haus.format(src, options));
        } catch (HausException e) {
          return syntaxLine(e);
        }
      };
    }
    if (flags.length >= 2 && flags[0].equals("--write")) {
      FormatOptions options = options(flags);
      return (src, i) -> write(src, options);
    }
    throw new IllegalArgumentException(USAGE);
  }

  /** Reads {@code STYLE [--indent N] [--width N]} after the mode's flag. */
  private static FormatOptions options(String[] flags) {
    FormatOptions o = FormatOptions.of(layout(flags[1]));
    for (int k = 2; k < flags.length; k += 2) {
      if (k + 1 >= flags.length) {
        throw new IllegalArgumentException(USAGE);
      }
      int v = Integer.parseInt(flags[k + 1]);
      switch (flags[k]) {
        case "--indent":
          o = o.withIndent(v);
          break;
        case "--width":
          o = o.withWidth(v);
          break;
        default:
          throw new IllegalArgumentException(USAGE);
      }
    }
    return o;
  }

  private static Layout layout(String name) {
    switch (name) {
      case "pretty":
        return Layout.PRETTY;
      case "compact":
        return Layout.COMPACT;
      case "minimised":
        return Layout.MINIMISED;
      default:
        throw new IllegalArgumentException("unknown style " + name + ": pretty, compact or minimised");
    }
  }

  // ── Parsing ──

  private interface Parse {
    List<Value> get() throws IOException;
  }

  private static String values(Parse parse) {
    try {
      List<Value> vs = parse.get();
      StringBuilder b = new StringBuilder("ok [");
      for (int i = 0; i < vs.size(); i++) {
        if (i > 0) {
          b.append(',');
        }
        suiteJson(b, vs.get(i));
      }
      return b.append(']').toString();
    } catch (HausException e) {
      return syntaxLine(e);
    } catch (IOException e) {
      throw new IllegalStateException(e);
    }
  }

  /** The chunks of case i, the same in every runner: chunk k has size CHUNKS[(i + k) % 7]. */
  private static List<Value> streamed(byte[] src, int i) throws IOException {
    List<byte[]> chunks = new ArrayList<>();
    for (int at = 0, k = 0; at < src.length; k++) {
      int end = Math.min(src.length, at + CHUNKS[(i + k) % CHUNKS.length]);
      chunks.add(Arrays.copyOfRange(src, at, end));
      at = end;
    }
    List<Value> values = new ArrayList<>();
    try (StreamReader r = new StreamReader(new Chunks(chunks))) {
      for (Value v; (v = r.read()) != null; ) {
        values.add(v);
      }
    }
    return values;
  }

  /** Gives at most one chunk per read. */
  private static final class Chunks extends InputStream {
    private final List<byte[]> chunks;
    private int next;
    private ByteArrayInputStream current = new ByteArrayInputStream(new byte[0]);

    Chunks(List<byte[]> chunks) {
      this.chunks = chunks;
    }

    @Override
    public int read() {
      byte[] b = new byte[1];
      return read(b, 0, 1) < 0 ? -1 : b[0] & 0xFF;
    }

    @Override
    public int read(byte[] b, int off, int len) {
      while (current.available() == 0) {
        if (next == chunks.size()) {
          return -1;
        }
        current = new ByteArrayInputStream(chunks.get(next++));
      }
      return current.read(b, off, len);
    }
  }

  private static String canonical(byte[] src) {
    try {
      List<Value> vs = Haus.parseAll(src);
      StringBuilder b = new StringBuilder("ok [");
      for (int i = 0; i < vs.size(); i++) {
        if (i > 0) {
          b.append(',');
        }
        b.append(json(Haus.canonical(vs.get(i))));
      }
      return b.append(']').toString();
    } catch (HausException e) {
      return syntaxLine(e);
    }
  }

  private static String write(byte[] src, FormatOptions options) {
    try {
      List<Value> vs = Haus.parseAll(src);
      StringBuilder b = new StringBuilder("ok {\"values\":[");
      for (int i = 0; i < vs.size(); i++) {
        if (i > 0) {
          b.append(',');
        }
        String text = Haus.write(vs.get(i), options);
        b.append(json(text.endsWith("\n") ? text.substring(0, text.length() - 1) : text));
      }
      return b.append("],\"file\":").append(json(Haus.writeAll(vs, options))).append('}').toString();
    } catch (HausException e) {
      return syntaxLine(e);
    }
  }

  /** A parser's error: {@code err <line> <column> <code> <reason>}. */
  private static String syntaxLine(HausException e) {
    return "err " + e.line() + " " + e.column() + " " + e.code() + " " + e.reason();
  }

  // ── JSON ──

  private static Function<byte[], String> jsonMode(String mode) {
    switch (mode) {
      case "haus-json-write":
        return data -> {
          List<Value> vs;
          try {
            vs = Haus.parseAll(data);
          } catch (HausException e) {
            return "err $ - not a single value: " + e.getMessage();
          }
          if (vs.size() != 1) {
            return "err $ - not a single value";
          }
          try {
            return "ok " + HausJson.toHausJson(vs.get(0));
          } catch (HausException e) {
            return placed(e);
          }
        };
      case "haus-json-read":
        return data -> canonicalOr(() -> HausJson.fromHausJson(data, Limits.DEFAULT));
      case "import":
        return data -> canonicalOr(() -> HausJson.importJson(data, Limits.DEFAULT));
      default:
        throw new IllegalArgumentException("unsupported JSON mode " + mode + ": haus-json-write, haus-json-read or import");
    }
  }

  private static String canonicalOr(Supplier<Value> read) {
    try {
      return "ok " + Haus.canonical(read.get());
    } catch (HausException e) {
      return placed(e);
    }
  }

  /** {@code err <place> <code> <reason>}: the place in the value, {@code $} for one in the text. */
  private static String placed(HausException e) {
    return "err " + (e.path() == null ? "$" : e.path()) + " " + e.code() + " " + e.reason();
  }

  // ── Output ──

  /** A value in the test suite's JSON encoding (test-suite/README.md). */
  private static void suiteJson(StringBuilder b, Value v) {
    switch (v.kind()) {
      case STRING:
        b.append(json(((Value.Text) v).value()));
        break;
      case NUMBER:
        b.append("{\"num\":").append(json(((Value.Number) v).literal())).append('}');
        break;
      case BYTES:
        b.append("{\"bytes\":\"").append(((Value.Bytes) v).hex()).append("\"}");
        break;
      case ARRAY:
        items(b, ((Value.Array) v).items());
        break;
      case RECORD:
        b.append("{\"rec\":{");
        Value.Record r = (Value.Record) v;
        for (int i = 0; i < r.size(); i++) {
          if (i > 0) {
            b.append(',');
          }
          b.append(json(r.keyAt(i))).append(':');
          suiteJson(b, r.valueAt(i));
        }
        b.append("}}");
        break;
      case VARIANT:
        Value.Variant x = (Value.Variant) v;
        b.append("{\"tag\":").append(json(x.tag()));
        if (x.size() > 0) {
          b.append(",\"args\":");
          items(b, x.args());
        }
        b.append('}');
        break;
    }
  }

  private static void items(StringBuilder b, List<Value> vs) {
    b.append('[');
    for (int i = 0; i < vs.size(); i++) {
      if (i > 0) {
        b.append(',');
      }
      suiteJson(b, vs.get(i));
    }
    b.append(']');
  }

  /** A JSON string: the quote, the backslash and every character below U+0020 escaped. */
  private static String json(String s) {
    StringBuilder b = new StringBuilder("\"");
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if (c == '"' || c == '\\') {
        b.append('\\').append(c);
      } else if (c < 0x20 || c == 0x2028 || c == 0x2029) {
        b.append(String.format("\\u%04x", (int) c));
      } else {
        b.append(c);
      }
    }
    return b.append('"').toString();
  }

  /** Keeps a result on its line. */
  private static String oneLine(String s) {
    return s.replace('\n', ' ').replace('\r', ' ');
  }

  /** A case's bytes, written in hex. */
  private static byte[] unhex(String s) {
    byte[] b = new byte[s.length() / 2];
    for (int i = 0; i < b.length; i++) {
      b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
    }
    return b;
  }
}
