package org.hausfmt.fuzz;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Stream;
import org.hausfmt.DecodeOptions;
import org.hausfmt.Haus;
import org.hausfmt.HausException;
import org.hausfmt.Schema;
import org.hausfmt.SchemaType;
import org.hausfmt.Value;

/**
 * The schema fuzzers' modes, as the Go runner's (fuzz/go/schema.go, check.go, json.go):
 *
 * <ul>
 *   <li>{@code --schema FILE}: lines {@code SUITE TYPE HEX} (haus text): decode with the type of
 *       the suite's schema file, encode what was decoded: {@code ok <canonical form>}, {@code err
 *       <place> <code> <reason>}, or {@code crash …} if encoding fails;
 *   <li>{@code --schema-check FILE}: lines {@code HEX}, a schema file: {@code ok}, or {@code err
 *       <line> <column> <code> <reason>};
 *   <li>{@code --json write FILE} and {@code --json read FILE}: lines {@code SUITE TYPE HEX}: decode
 *       the haus text and write its schema-based JSON ({@code ok <JSON>}), or read the JSON and
 *       encode it ({@code ok <canonical form>}).
 * </ul>
 */
final class SchemaModes {
  private SchemaModes() {}

  /** The checkout the runner was built from: fuzz/.build/jvm-runner/lib/*.jar is five levels below. */
  static Path root() {
    try {
      Path jar = Paths.get(SchemaModes.class.getProtectionDomain().getCodeSource().getLocation().toURI());
      return jar.getParent().getParent().getParent().getParent().getParent();
    } catch (URISyntaxException e) {
      throw new IllegalStateException(e);
    }
  }

  /** A schema file of the fuzzers, or why it is rejected. */
  private record Loaded(Schema schema, HausException error) {}

  /** Every schema file of the directories (relative to the checkout), by suite name. */
  private static Map<String, Loaded> schemas(String... dirs) {
    Map<String, Loaded> out = new HashMap<>();
    for (String dir : dirs) {
      try (Stream<Path> files = Files.list(root().resolve(dir))) {
        for (Path p : (Iterable<Path>) files::iterator) {
          String name = p.getFileName().toString();
          if (!name.endsWith(".schema.haus")) {
            continue;
          }
          String suite = name.substring(0, name.length() - ".schema.haus".length());
          try {
            out.put(suite, new Loaded(Schema.parse(Files.readString(p, StandardCharsets.UTF_8)), null));
          } catch (HausException e) {
            out.put(suite, new Loaded(null, e));
          }
        }
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
    }
    return out;
  }

  /** The line for a type that isn't there, or null and the type in {@code found[0]}. */
  private static String typeOf(Map<String, Loaded> suites, String suite, String name, SchemaType[] found) {
    Loaded l = suites.get(suite);
    if (l == null) {
      return "crash no schema " + suite;
    }
    if (l.error != null) {
      return "err $ - the schema is rejected: " + l.error.getMessage();
    }
    try {
      found[0] = l.schema.type(name);
      return null;
    } catch (HausException e) {
      return "crash no type " + suite + "." + name;
    }
  }

  /** A mode for lines {@code SUITE TYPE HEX}: the type and the case's bytes. */
  private interface Typed {
    String run(SchemaType t, byte[] data);
  }

  private static Function<String, String> typed(Map<String, Loaded> suites, Typed one) {
    return line -> {
      String[] parts = line.split(" ", -1);
      if (parts.length != 3) {
        return "err $ - bad line";
      }
      SchemaType[] t = new SchemaType[1];
      String bad = typeOf(suites, parts[0], parts[1], t);
      return bad != null ? bad : one.run(t[0], Runner.unhex(parts[2]));
    };
  }

  static Function<String, String> schema() {
    return typed(schemas("test-suite/schema", "fuzz/schema"), (t, data) -> {
      Value v;
      try {
        v = single(data);
      } catch (NotOne e) {
        return e.line;
      }
      return roundtrip(t, v, DecodeOptions.DEFAULT);
    });
  }

  /** Decodes {@code v} with the type and encodes what it decoded. */
  static String roundtrip(SchemaType t, Value v, DecodeOptions options) {
    Value decoded;
    try {
      decoded = t.decode(v, options);
    } catch (HausException e) {
      return Runner.placed(e);
    }
    try {
      return "ok " + Haus.canonical(t.encode(decoded, options));
    } catch (HausException e) {
      return "crash encoding failed: " + e.getMessage();
    }
  }

  static Function<String, String> schemaCheck() {
    return line -> {
      try {
        Schema.parse(Runner.unhex(line), org.hausfmt.SchemaOptions.DEFAULT);
        return "ok";
      } catch (HausException e) {
        return "err " + e.line() + " " + e.column() + " " + e.code() + " " + e.reason();
      }
    };
  }

  static Function<String, String> json(String mode) {
    Map<String, Loaded> suites = schemas("test-suite/schema", "fuzz/schema", "test-suite/json", "fuzz/json");
    if (mode.equals("write")) {
      return typed(suites, (t, data) -> {
        Value v;
        try {
          v = single(data);
        } catch (NotOne e) {
          return e.line;
        }
        try {
          return "ok " + t.toJson(t.decode(v));
        } catch (HausException e) {
          return Runner.placed(e);
        }
      });
    }
    return typed(suites, (t, data) -> {
      Value read;
      try {
        read = t.fromJson(data, DecodeOptions.DEFAULT);
      } catch (HausException e) {
        return Runner.placed(e);
      }
      try {
        return "ok " + Haus.canonical(t.encode(read));
      } catch (HausException e) {
        return "crash encoding what was read failed: " + e.getMessage();
      }
    });
  }

  /** A case's text isn't one value: the line to print. */
  static final class NotOne extends Exception {
    private static final long serialVersionUID = 1L;
    final String line;

    NotOne(String line) {
      super(line, null, false, false);
      this.line = line;
    }
  }

  /** The one value of a case's text. */
  static Value single(byte[] data) throws NotOne {
    List<Value> vs;
    try {
      vs = Haus.parseAll(data);
    } catch (HausException e) {
      throw new NotOne("err $ - not a single value: " + e.getMessage());
    }
    if (vs.size() != 1) {
      throw new NotOne("err $ - not a single value");
    }
    return vs.get(0);
  }
}
