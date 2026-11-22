package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.fail;
import static org.junit.jupiter.api.DynamicTest.dynamicTest;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermission;
import java.time.Duration;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;
import org.junit.jupiter.api.io.TempDir;

/**
 * The package suite (test-suite/README.md, "Package suite", spec §13.3): each case is a file
 * tree, written into a temporary directory, a schema file loaded from it with the packages given
 * explicitly, and the result.
 *
 * <p>This binding is no implementation of the npm ecosystem and doesn't read node_modules: it runs
 * every {@code ecosystem: "core"} case and skips the {@code "npm"} ones, counting them. Cases with
 * {@code os: "unix"} are skipped on Windows, and those with a {@code Mode} entry when the tests run
 * as root, which permissions don't stop; both are counted. The core cases whose packages are given
 * by their directories run a second time with each package given as classpath resources, through
 * a class loader over the temporary directory (spec §13.3, a file tree given by code); those with
 * folders of packages can't (a class loader lists no directories).
 */
class PackageSuiteTest {
  /** The cases in the suite, and how many of them are of the npm ecosystem. */
  private static final int CASES = 133;
  private static final int NPM_CASES = 46;
  /** How long a case may take: a resolver that opens a FIFO blocking would hang. */
  private static final Duration TIMEOUT = Duration.ofSeconds(10);
  private static final boolean WINDOWS = System.getProperty("os.name", "").startsWith("Windows");
  private static final boolean ROOT_USER = "root".equals(System.getProperty("user.name"));

  @TempDir Path temp;

  @TestFactory
  List<DynamicTest> packageSuite() {
    List<Value.Variant> cases = Suite.cases(Suite.suite("packages", "cases.haus"));
    List<DynamicTest> tests = new ArrayList<>();
    int npm = 0;
    int core = 0;
    int otherOs = 0;
    int asRoot = 0;
    int asResources = 0;
    int withFolders = 0;
    for (int i = 0; i < cases.size(); i++) {
      Value.Variant c = cases.get(i);
      assertEquals("Case", c.tag(), "every entry is Case { … }");
      Value.Record r = c.payload();
      String ecosystem = text(r.get("ecosystem"));
      String mode = ((Value.Variant) r.get("mode")).tag();
      assertEquals(ecosystem.equals("npm") ? "Npm" : "Explicit", mode, "the mode of an ecosystem's case");
      if (ecosystem.equals("npm")) {
        // The npm ecosystem: packages from node_modules, which this binding must not read.
        npm++;
        continue;
      }
      assertEquals("core", ecosystem, "unknown ecosystem");
      core++;
      if (r.get("os") != null && WINDOWS) {
        assertEquals("unix", text(r.get("os")));
        otherOs++;
        continue;
      }
      if (ROOT_USER && hasEntry(r, "Mode")) {
        asRoot++;
        continue;
      }
      String name = Suite.str(c, "name");
      Path root = temp.resolve("case" + i);
      tests.add(dynamicTest(name, () -> assertTimeoutPreemptively(TIMEOUT, () -> run(root, r, false))));
      Value.Record given = ((Value.Variant) r.get("mode")).payload();
      if (given != null && given.get("folders") != null) {
        withFolders++;
      } else {
        asResources++;
        Path again = temp.resolve("case" + i + "-resources");
        tests.add(dynamicTest(name + " (classpath resources)",
            () -> assertTimeoutPreemptively(TIMEOUT, () -> run(again, r, true))));
      }
    }
    assertEquals(CASES, cases.size(), "cases in the suite");
    assertEquals(NPM_CASES, npm, "npm cases skipped");
    System.out.println("package suite: " + core + " core cases (" + otherOs + " skipped on this OS, " + asRoot
        + " skipped as root, " + asResources + " run again as classpath resources, " + withFolders
        + " with folders not), " + npm + " npm cases skipped");
    return tests;
  }

  private static boolean hasEntry(Value.Record c, String tag) {
    for (Value f : (Value.Array) c.get("files")) {
      if (((Value.Variant) f).tag().equals(tag)) {
        return true;
      }
    }
    return false;
  }

  /** Runs a case in the empty directory root, its packages given as classpath resources if {@code resources}. */
  private static void run(Path root, Value.Record c, boolean resources) throws IOException {
    writeTree(root, c);
    try {
      check(root, c, resources);
    } finally {
      // Give back the owner's permissions, so that the temporary directory can be removed.
      restore(root);
    }
  }

  private static void check(Path root, Value.Record c, boolean resources) throws IOException {
    Value.Variant expect = (Value.Variant) c.get("expect");
    Value.Record want = expect.payload();
    List<String> reached;
    boolean[] loading = {false};
    try {
      reached = load(root, c, resources, loading);
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
      // Messages of a load show paths relative to the root, never the temporary directory's.
      // (Packages are given, and checked, before there is a root: their messages show their
      // directories as the application gave them, here absolute.)
      String abs = root.toRealPath().toString();
      if (loading[0] && (message.contains(abs) || message.contains(root.toString()))) {
        fail("the message shows an absolute path: " + message);
      }
      return;
    }
    if (!expect.tag().equals("Ok")) {
      fail("loaded (reaching " + reached + "), expected " + text(want.get("code")));
    }
    assertEquals(strings(want.get("packages")), reached, "packages reached");
  }

  /**
   * Loads the case's root with its packages: each one reached, as name@version, sorted. {@code
   * loading[0]} is set once the packages are given and the schema is loaded.
   */
  private static List<String> load(Path root, Value.Record c, boolean resources, boolean[] loading) throws IOException {
    Value.Variant mode = (Value.Variant) c.get("mode");
    ExplicitPackages packages = PackageLocator.explicit();
    Value.Record given = mode.payload();
    SchemaOptions options = SchemaOptions.DEFAULT;
    if (c.get("rootDir") != null) {
      options = options.withRoot(root.resolve(text(c.get("rootDir"))));
    }
    try (URLClassLoader loader = new URLClassLoader(new URL[] {root.toUri().toURL()}, null)) {
      if (given != null) {
        for (String dir : strings(given.get("packages"))) {
          packages = resources ? packages.resources(loader, dir) : packages.packageDir(root.resolve(dir));
        }
        for (String dir : strings(given.get("folders"))) {
          packages = packages.folder(root.resolve(dir));
        }
      }
      loading[0] = true;
      Schema s = Schema.load(root.resolve(text(c.get("root"))), options.withPackages(packages));
      return s.packages().stream().map(p -> p.name() + "@" + p.version()).sorted().collect(Collectors.toList());
    }
  }

  /** Writes a case's files under root: links once their targets exist, permissions last. */
  private static void writeTree(Path root, Value.Record c) throws IOException {
    Files.createDirectories(root);
    Value.Array files = (Value.Array) c.get("files");
    for (String pass : new String[] {"files", "Link", "Mode"}) {
      for (Value f : files) {
        Value.Variant entry = (Value.Variant) f;
        String tag = entry.tag();
        boolean in = tag.equals("Link") || tag.equals("Mode") ? tag.equals(pass) : pass.equals("files");
        if (in) {
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
      case "Large": {
        Path path = root.resolve(arg(entry, 0));
        Files.createDirectories(path.getParent());
        Files.write(path, " ".repeat(((Value.Number) entry.get(1)).toBigInteger().intValueExact()).getBytes(StandardCharsets.UTF_8));
        break;
      }
      case "Fifo": {
        Path path = root.resolve(arg(entry, 0));
        Files.createDirectories(path.getParent());
        mkfifo(path);
        break;
      }
      case "Mode":
        Files.setPosixFilePermissions(root.resolve(arg(entry, 0)), permissions(arg(entry, 1)));
        break;
      default:
        fail("unknown file entry " + entry.tag());
    }
  }

  /** Makes a FIFO at path: Java has no call for it, so mkfifo(1). */
  private static void mkfifo(Path path) throws IOException {
    Process p = new ProcessBuilder("mkfifo", path.toString()).inheritIO().start();
    try {
      if (p.waitFor() != 0) {
        fail("mkfifo failed for " + path);
      }
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new IOException(e);
    }
  }

  /** The permissions of an octal mode such as 711. */
  private static Set<PosixFilePermission> permissions(String octal) {
    int mode = Integer.parseInt(octal, 8);
    PosixFilePermission[] bits = {
      PosixFilePermission.OTHERS_EXECUTE, PosixFilePermission.OTHERS_WRITE, PosixFilePermission.OTHERS_READ,
      PosixFilePermission.GROUP_EXECUTE, PosixFilePermission.GROUP_WRITE, PosixFilePermission.GROUP_READ,
      PosixFilePermission.OWNER_EXECUTE, PosixFilePermission.OWNER_WRITE, PosixFilePermission.OWNER_READ,
    };
    Set<PosixFilePermission> set = EnumSet.noneOf(PosixFilePermission.class);
    for (int i = 0; i < bits.length; i++) {
      if ((mode & (1 << i)) != 0) {
        set.add(bits[i]);
      }
    }
    return set;
  }

  /** chmod -R u+rwx on the directories under root (not through links). */
  private static void restore(Path root) throws IOException {
    if (WINDOWS || !Files.exists(root, LinkOption.NOFOLLOW_LINKS)) {
      return;
    }
    Files.walkFileTree(root, new SimpleFileVisitor<>() {
      @Override
      public FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes attrs) throws IOException {
        Set<PosixFilePermission> p = EnumSet.copyOf(Files.getPosixFilePermissions(dir, LinkOption.NOFOLLOW_LINKS));
        p.addAll(Set.of(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE, PosixFilePermission.OWNER_EXECUTE));
        Files.setPosixFilePermissions(dir, p);
        return FileVisitResult.CONTINUE;
      }

      @Override
      public FileVisitResult visitFileFailed(Path file, IOException exc) {
        return FileVisitResult.CONTINUE;
      }
    });
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
