package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.fail;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;
import org.junit.jupiter.api.io.TempDir;

/**
 * The package suite (test-suite/README.md, "Package suite", spec §13.3): each case is a file
 * tree, written into a temporary directory, a schema file loaded from it with the packages given
 * explicitly, and the result.
 *
 * <p>This binding doesn't read node_modules, so it runs every {@code Explicit} case and skips the
 * {@code Npm} ones (they need a node_modules locator), counting them. It makes the SHOULD version
 * check (a package.json's version against the manifest's): the {@code should: True} cases are run
 * when their mode is {@code Explicit} (none is today).
 */
class PackageSuiteTest {
  /** The cases in the suite, and how many of them find packages in node_modules. */
  private static final int CASES = 85;
  private static final int NPM_CASES = 33;

  @TempDir Path temp;

  @TestFactory
  List<DynamicTest> packageSuite() {
    List<Value.Variant> cases = Suite.cases(Suite.suite("packages", "cases.haus"));
    List<DynamicTest> tests = new ArrayList<>();
    int npm = 0;
    for (int i = 0; i < cases.size(); i++) {
      Value.Variant c = cases.get(i);
      assertEquals("Case", c.tag(), "every entry is Case { … }");
      Value.Variant mode = (Value.Variant) c.payload().get("mode");
      if (mode.tag().equals("Npm")) {
        // Packages from node_modules: this binding has no node_modules locator.
        npm++;
        continue;
      }
      assertEquals("Explicit", mode.tag(), "unknown mode");
      Path root = temp.resolve("case" + i);
      tests.add(dynamicTest(Suite.str(c, "name"), () -> run(root, c.payload())));
    }
    assertEquals(CASES, cases.size(), "cases in the suite");
    assertEquals(NPM_CASES, npm, "Npm cases skipped");
    return tests;
  }

  /** Runs a case in the empty directory root. */
  private static void run(Path root, Value.Record c) throws IOException {
    writeTree(root, c);
    Value.Variant expect = (Value.Variant) c.get("expect");
    Value.Record want = expect.payload();
    List<String> reached;
    try {
      reached = load(root, c);
    } catch (HausException e) {
      if (expect.tag().equals("Ok")) {
        fail("failed: " + e.getMessage());
      }
      String message = e.getMessage();
      assertEquals(text(want.get("code")), e.code().code(), message);
      for (String m : strings(want.get("mentions"))) {
        if (!message.replace('\\', '/').contains(m)) {
          fail("the message doesn't mention \"" + m + "\": " + message);
        }
      }
      for (String h : strings(want.get("hides"))) {
        if (message.contains(h)) {
          fail("the message shows \"" + h + "\": " + message);
        }
      }
      return;
    }
    if (!expect.tag().equals("Ok")) {
      fail("loaded (reaching " + reached + "), expected " + text(want.get("code")));
    }
    assertEquals(strings(want.get("packages")), reached, "packages reached");
  }

  /** Loads the case's root with its packages: each one reached, as name@version, sorted. */
  private static List<String> load(Path root, Value.Record c) {
    Value.Variant mode = (Value.Variant) c.get("mode");
    ExplicitPackages packages = PackageLocator.explicit();
    Value.Record given = mode.payload();
    if (given != null) {
      for (String dir : strings(given.get("packages"))) {
        packages = packages.packageDir(root.resolve(dir));
      }
      for (String dir : strings(given.get("folders"))) {
        packages = packages.folder(root.resolve(dir));
      }
    }
    Schema s = Schema.load(root.resolve(text(c.get("root"))), SchemaOptions.DEFAULT.withPackages(packages));
    return s.packages().stream().map(p -> p.name() + "@" + p.version()).sorted().collect(Collectors.toList());
  }

  /** Writes a case's files under root: links last, once their targets exist. */
  private static void writeTree(Path root, Value.Record c) throws IOException {
    Value.Array files = (Value.Array) c.get("files");
    for (boolean links : new boolean[] {false, true}) {
      for (Value f : files) {
        Value.Variant entry = (Value.Variant) f;
        if (entry.tag().equals("Link") == links) {
          create(root, entry);
        }
      }
    }
  }

  /** Writes one entry of a case's files under root. */
  private static void create(Path root, Value.Variant entry) throws IOException {
    switch (entry.tag()) {
      case "File":
        write(root.resolve(arg(entry, 0)), arg(entry, 1));
        break;
      case "Package": {
        Path dir = root.resolve(arg(entry, 0));
        write(dir.resolve("package.haus"), "{ name: " + Haus.write(entry.get(1)) + ", version: " + Haus.write(entry.get(2)) + " }");
        write(dir.resolve("schema.haus"), arg(entry, 3));
        break;
      }
      case "Npm":
        write(root.resolve(arg(entry, 0)).resolve("package.json"), packageJson((Value.Record) entry.get(1)));
        break;
      case "Link": {
        // The target relative to the link's directory, as ln -s makes it.
        Path link = root.resolve(arg(entry, 0));
        Files.createDirectories(link.getParent());
        Files.createSymbolicLink(link, Paths.get(arg(entry, 1)));
        break;
      }
      default:
        fail("unknown file entry " + entry.tag());
    }
  }

  /** The package.json of an Npm entry: name and version, and each dependency list as an object to "*". */
  private static String packageJson(Value.Record fields) {
    StringBuilder b = new StringBuilder("{");
    for (String key : List.of("name", "version")) {
      if (fields.containsKey(key)) {
        member(b, key).append(jsonString(text(fields.get(key))));
      }
    }
    for (String key : List.of("dependencies", "peerDependencies", "devDependencies", "optionalDependencies")) {
      if (fields.containsKey(key)) {
        member(b, key).append('{');
        List<String> names = strings(fields.get(key));
        for (int i = 0; i < names.size(); i++) {
          b.append(i > 0 ? "," : "").append(jsonString(names.get(i))).append(":\"*\"");
        }
        b.append('}');
      }
    }
    return b.append('}').toString();
  }

  private static StringBuilder member(StringBuilder b, String key) {
    return b.append(b.length() > 1 ? "," : "").append(jsonString(key)).append(':');
  }

  /** A JSON string: the suite's strings need only quotes, backslashes and controls escaped. */
  private static String jsonString(String s) {
    StringBuilder b = new StringBuilder("\"");
    for (int i = 0; i < s.length(); i++) {
      char ch = s.charAt(i);
      if (ch == '"' || ch == '\\') {
        b.append('\\').append(ch);
      } else if (ch < 0x20) {
        b.append(String.format("\\u%04x", (int) ch));
      } else {
        b.append(ch);
      }
    }
    return b.append('"').toString();
  }

  private static void write(Path path, String text) {
    try {
      Files.createDirectories(path.getParent());
      Files.write(path, text.getBytes(StandardCharsets.UTF_8));
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  private static String arg(Value.Variant entry, int i) {
    return text(entry.get(i));
  }

  private static String text(Value v) {
    return ((Value.Text) v).value();
  }

  /** The strings of an array, or none for a missing field. */
  private static List<String> strings(Value v) {
    List<String> out = new ArrayList<>();
    if (v != null) {
      for (Value x : (Value.Array) v) {
        out.add(text(x));
      }
    }
    return out;
  }
}
