package org.hausfmt;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/** The shared conformance suite (test-suite/README.md) and the repository's files. */
final class Suite {
  private Suite() {}

  /** The repository, from the system property the build sets. */
  static Path root() {
    String root = System.getProperty("haus.root");
    if (root == null) {
      throw new IllegalStateException("haus.root is not set: run the tests with Gradle");
    }
    return Paths.get(root);
  }

  static Path suite(String... path) {
    return root().resolve(Paths.get("test-suite", path));
  }

  /** The names (without extension) of the files {@code dir/*ext}, sorted. */
  static List<String> names(Path dir, String ext) {
    try (Stream<Path> files = Files.list(dir)) {
      List<String> names = files.map(p -> p.getFileName().toString())
          .filter(n -> n.endsWith(ext))
          .map(n -> n.substring(0, n.length() - ext.length()))
          .sorted()
          .collect(Collectors.toList());
      if (names.isEmpty()) {
        throw new IllegalStateException("no " + ext + " files in " + dir);
      }
      return names;
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  static byte[] bytes(Path p) {
    try {
      return Files.readAllBytes(p);
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  static String text(Path p) {
    return new String(bytes(p), java.nio.charset.StandardCharsets.UTF_8);
  }

  /** The values of a cases file, each {@code Tag { … }}. */
  static List<Value.Variant> cases(Path p) {
    return Haus.parseAll(bytes(p)).stream().map(v -> (Value.Variant) v).collect(Collectors.toList());
  }

  /** {@code v} with every secret a decoder hid in it revealed, for comparing decoded values. */
  static Value revealed(Value v) {
    if (v instanceof Value.Secret s) {
      return revealed(s.reveal());
    }
    if (v instanceof Value.Array a) {
      return Value.array(a.items().stream().map(Suite::revealed).toList());
    }
    if (v instanceof Value.Variant x) {
      return Value.variant(x.tag(), x.args().stream().map(Suite::revealed).toList());
    }
    if (v instanceof Value.Record r) {
      List<Value.Field> fields = new java.util.ArrayList<>();
      for (int i = 0; i < r.size(); i++) {
        fields.add(Value.field(r.keyAt(i), revealed(r.valueAt(i))));
      }
      return Value.record(fields);
    }
    return v;
  }

  /** A string field of a case. */
  static String str(Value.Variant c, String key) {
    return ((Value.Text) c.payload().get(key)).value();
  }
}
