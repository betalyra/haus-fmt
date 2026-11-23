package org.hausfmt.fuzz;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.function.Supplier;
import org.hausfmt.FormatOptions;
import org.hausfmt.Haus;
import org.hausfmt.HausException;
import org.hausfmt.HausJson;
import org.hausfmt.Schema;
import org.hausfmt.SchemaDefinition;
import org.hausfmt.SchemaOptions;
import org.hausfmt.Value;

/**
 * The build, import and string-API fuzzers' modes (fuzz/README.md).
 *
 * <ul>
 *   <li>{@code --build}: each line builds a value with the constructors (spec §11, "Values built in
 *       code"; fuzz/src/build.ts has the instructions) and writes it: {@code err CODE} if a
 *       constructor rejects it, else {@code ok C H W}, the canonical form (hex of UTF-8), the hash
 *       and the compact writer's text (hex), each {@code !CODE} if it fails. Text is hex of
 *       generalized UTF-8: a lone surrogate's three bytes are that surrogate in a String.
 *   <li>{@code --imports}: each line is {@code ENTRY ROOT} (hex of UTF-8; ROOT {@code -} for
 *       none), loaded with {@code Schema.load} and no packages: {@code ok OWN IMPORTED} (type names,
 *       sorted, joined by {@code ,}; {@code -} for none) or {@code err CODE}.
 *   <li>{@code --strings}: each line is {@code KIND HEX}, a String as hex of its UTF-16 code units,
 *       through the APIs that take a String (fuzz/src/strings.ts has the kinds and outcomes).
 * </ul>
 */
final class ApiModes {
  private ApiModes() {}

  private static final HexFormat HEX = HexFormat.of();

  private static String hex(String s) {
    return HEX.formatHex(s.getBytes(StandardCharsets.UTF_8));
  }

  /** Generalized UTF-8 (a surrogate as its three bytes) as a String. */
  static String wtf8(String hex) {
    byte[] b = HEX.parseHex(hex);
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < b.length; ) {
      int x = b[i] & 0xff;
      int c;
      if (x < 0x80) {
        c = x;
        i += 1;
      } else if (x < 0xe0) {
        c = ((x & 31) << 6) | (b[i + 1] & 63);
        i += 2;
      } else if (x < 0xf0) {
        c = ((x & 15) << 12) | ((b[i + 1] & 63) << 6) | (b[i + 2] & 63);
        i += 3;
      } else {
        c = ((x & 7) << 18) | ((b[i + 1] & 63) << 12) | ((b[i + 2] & 63) << 6) | (b[i + 3] & 63);
        i += 4;
      }
      out.appendCodePoint(c);
    }
    return out.toString();
  }

  // ── --build ──────────────────────────────────────────────────

  /** The tokens of a line and where the next one is. */
  private static final class Tokens {
    final String[] all;
    int at;

    Tokens(String line) {
      all = line.trim().split(" +");
    }

    String next() {
      return all[at++];
    }
  }

  private static Supplier<Value> build(Tokens t) {
    String[] parts = t.next().split(":", -1);
    switch (parts[0]) {
      case "n": {
        String literal = wtf8(parts[1]);
        return () -> Value.number(literal);
      }
      case "s": {
        String s = wtf8(parts[1]);
        return () -> Value.string(s);
      }
      case "b": {
        byte[] data = HEX.parseHex(parts[1]);
        return () -> Value.bytes(data);
      }
      case "a": {
        List<Supplier<Value>> items = new ArrayList<>();
        for (int i = Integer.parseInt(parts[1]); i > 0; i--) {
          items.add(build(t));
        }
        return () -> Value.array(items.stream().map(Supplier::get).toList());
      }
      case "r": {
        List<String> keys = new ArrayList<>();
        List<Supplier<Value>> values = new ArrayList<>();
        for (int i = Integer.parseInt(parts[1]); i > 0; i--) {
          keys.add(wtf8(t.next().substring(2)));
          values.add(build(t));
        }
        return () -> {
          List<Value.Field> fields = new ArrayList<>();
          for (int i = 0; i < keys.size(); i++) {
            fields.add(Value.field(keys.get(i), values.get(i).get()));
          }
          return Value.record(fields);
        };
      }
      case "v": {
        String tag = wtf8(parts[1]);
        List<Supplier<Value>> args = new ArrayList<>();
        for (int i = Integer.parseInt(parts[2]); i > 0; i--) {
          args.add(build(t));
        }
        return () -> Value.variant(tag, args.stream().map(Supplier::get).toList());
      }
      default:
        throw new IllegalArgumentException("bad token " + parts[0]);
    }
  }

  private static String attempt(Supplier<String> f) {
    try {
      return f.get();
    } catch (HausException e) {
      return "!" + e.code().code();
    }
  }

  static String buildLine(String line) {
    Value v;
    try {
      v = build(new Tokens(line)).get();
    } catch (HausException e) {
      return "err " + e.code().code();
    }
    String canon = attempt(() -> hex(Haus.canonical(v)));
    String digest = attempt(() -> Haus.hash(v));
    // The value alone, without the line break the writer ends a file with.
    String written = attempt(() -> hex(Haus.write(v, FormatOptions.COMPACT).replaceFirst("\n$", "")));
    return "ok " + canon + " " + digest + " " + written;
  }

  // ── --imports ────────────────────────────────────────────────

  private static String names(List<SchemaDefinition> ds) {
    List<String> ns = ds.stream().map(SchemaDefinition::name).sorted().toList();
    return ns.isEmpty() ? "-" : String.join(",", ns);
  }

  static String importLine(String line) {
    String[] parts = line.split(" ");
    String entry = new String(HEX.parseHex(parts[0]), StandardCharsets.UTF_8);
    SchemaOptions options = SchemaOptions.DEFAULT;
    if (!parts[1].equals("-")) {
      options = options.withRoot(Path.of(new String(HEX.parseHex(parts[1]), StandardCharsets.UTF_8)));
    }
    try {
      Schema s = Schema.load(Path.of(entry), options);
      return "ok " + names(s.definitions()) + " " + names(s.imported());
    } catch (HausException e) {
      return "err " + e.code().code();
    }
  }

  // ── --strings ────────────────────────────────────────────────

  private static String utf16(String hex) {
    StringBuilder out = new StringBuilder();
    for (int i = 0; i < hex.length(); i += 4) {
      out.append((char) Integer.parseInt(hex.substring(i, i + 4), 16));
    }
    return out.toString();
  }

  private static String placed(HausException e) {
    return "err " + e.line() + " " + e.column() + " " + e.code().code();
  }

  private static String one(Runnable f) {
    try {
      f.run();
      return "ok";
    } catch (HausException e) {
      return e.code().code();
    }
  }

  private static String write(Supplier<Value> make) {
    Value v;
    try {
      v = make.get();
    } catch (HausException e) {
      return "!" + e.code().code();
    }
    return one(() -> Haus.canonical(v)) + "/" + one(() -> Haus.hash(v)) + "/" + one(() -> Haus.write(v, FormatOptions.COMPACT));
  }

  static String stringsLine(String line) {
    int space = line.indexOf(' ');
    String kind = line.substring(0, space);
    String s = utf16(line.substring(space + 1));
    try {
      switch (kind) {
        case "P": {
          List<String> cs = Haus.parseAll(s).stream().map(v -> hex(Haus.canonical(v))).toList();
          return "ok " + (cs.isEmpty() ? "-" : String.join(",", cs));
        }
        case "F":
          return "ok " + hex(Haus.format(s, FormatOptions.PRETTY));
        case "S":
          Schema.parse(s);
          return "ok";
        case "J":
          try {
            return "ok " + hex(Haus.canonical(HausJson.importJson(s)));
          } catch (HausException e) {
            return "err " + e.code().code();
          }
        case "W":
          return "ok "
              + write(() -> Value.string(s))
              + " "
              + write(() -> Value.record(Value.field(s, Value.number("1"))))
              + " "
              + write(() -> Value.variant(s));
        default:
          throw new IllegalArgumentException("bad kind " + kind);
      }
    } catch (HausException e) {
      return placed(e);
    }
  }
}
