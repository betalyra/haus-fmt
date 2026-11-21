package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;
import org.junit.jupiter.api.io.TempDir;

/**
 * Manifests, package names and versions, packages given explicitly, and the rules for reading a
 * package's files (spec §13.3), without a schema: the package suite tests them through {@code
 * Schema.load}.
 */
class ManifestTest {
  @TempDir Path temp;

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static void write(Path path, String text) {
    try {
      Files.createDirectories(path.getParent());
      Files.write(path, utf8(text));
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  /** Writes a package: its manifest and schema.haus. */
  private static Path pkg(Path dir, String name, String version, String schema) {
    write(dir.resolve("package.haus"), "{ name: \"" + name + "\", version: \"" + version + "\" }");
    write(dir.resolve("schema.haus"), schema);
    return dir;
  }

  private static HausException fails(String code, Executable run) {
    HausException e = assertThrows(HausException.class, run);
    assertEquals(code, e.code().code(), e.getMessage());
    return e;
  }

  // ── manifests ──

  @Test
  void parsesAManifest() {
    Manifest m = Manifest.parse(utf8("{ name: \"@haus-fmt/money\", version: \"1.2.0\", description: \"x\" }"));
    assertEquals("@haus-fmt/money", m.name());
    assertEquals("1.2.0", m.version());
    assertEquals("1", m.major());
    assertEquals("@haus-fmt/money@1", m.id());
    assertEquals("0", Manifest.parse(utf8("{ version: \"0.3.0-rc.1+build.7\", name: \"@a/b\" }")).major());
  }

  @Test
  void rejectsInvalidManifests() {
    for (String text : new String[] {
      "",
      "{ name: \"@acme/common\", version: \"1.0.0\" }, { name: \"@acme/common\", version: \"1.0.0\" }",
      "[\"@acme/common\", \"1.0.0\"]",
      "{ name: \"@Acme/Common\", version: \"1.0.0\" }",
      "{ name: \"@acme/common\", version: \"1.0\" }",
      "{ name: \"@acme/common\", version: \"v1.0.0\" }",
      "{ name: \"@acme/common\", version: \"1\\u{662}.0.0\" }",
      "{ name: \"@acme/common\\n\", version: \"1.0.0\" }",
      "{ name: \"@acme/common\", version: \"1.0.0\\n\" }",
      "{ name: Name(\"@acme/common\"), version: \"1.0.0\" }",
      "{ name: \"@acme/common\" }",
      "{ version: \"1.0.0\" }",
      "{ name: \"@acme/.common\", version: \"1.0.0\" }",
      "{ name: \"@acme/common\" ",
    }) {
      fails("package-manifest", () -> Manifest.parse(utf8(text)));
    }
    byte[] big = utf8("{ name: \"@a/b\", version: \"1.0.0\" }" + " ".repeat(64 << 10));
    assertTrue(fails("package-manifest", () -> Manifest.parse(big)).reason().contains("more than 64 KiB"));
  }

  @Test
  void quotesWhatItRejects() {
    String reason = fails("package-manifest",
        () -> Manifest.parse(utf8("{ name: \"@acme/\\u{202E}" + "x".repeat(60) + "\", version: \"1.0.0\" }"))).reason();
    assertTrue(reason.startsWith("\"@acme/\\u{202E}xxx"), reason);
    assertTrue(reason.contains("…\" is not a package name"), reason);
  }

  @Test
  void packageNames() {
    for (String ok : new String[] {"@acme/common", "@haus-fmt/money", "@0/1", "@a.b/c_d-e", "@a/" + "x".repeat(211)}) {
      assertTrue(Manifest.isPackageName(ok), ok);
    }
    for (String bad : new String[] {
      "acme/common", "@acme", "@acme/", "@/common", "@Acme/common", "@acme/Common", "@acme/common/x",
      "@acme/-common", "@acme/.common", "@acme/_common", "@node_modules/x", "@acme/node_modules",
      "@acme/com mon", "@acme/cömmon", "@a/" + "x".repeat(212),
    }) {
      assertFalse(Manifest.isPackageName(bad), bad);
    }
    assertTrue(Manifest.isPackageName("@acme/node_modules2"));
  }

  @Test
  void semanticVersions() {
    for (String ok : new String[] {
      "0.0.0", "1.2.3", "10.20.30", "1.0.0-rc.1", "1.0.0-0a", "1.0.0-x-y.0", "1.0.0+build.5", "1.0.0+001",
      "1.0.0-rc.1+build.5", "18446744073709551616.0.0",
    }) {
      assertTrue(Manifest.isSemver(ok), ok);
    }
    for (String bad : new String[] {
      "", "1", "1.0", "1.0.0.0", "01.0.0", "1.00.0", "v1.0.0", "1.0.0-", "1.0.0+", "1.0.0-01", "1.0.0-rc..1",
      "1.0.0-rc_1", "1.0.0+b_1", " 1.0.0", "1.0.0 ", "1.٢.0", "1.0.0-rc.1 do-not-print",
    }) {
      assertFalse(Manifest.isSemver(bad), bad);
    }
  }

  // ── packages given explicitly ──

  @Test
  void packageDirectories() {
    Path common = pkg(temp.resolve("vendor/common"), "@acme/common", "1.0.0", "type Address = { city: String }");
    ExplicitPackages empty = PackageLocator.explicit();
    ExplicitPackages one = empty.packageDir(common);
    SchemaFiles files = new SchemaFiles();
    fails("import-not-found", () -> files.openPackageFor(empty, "@acme/common", null));
    SchemaFiles.Source found = files.openPackageFor(one, "@acme/common", null);
    assertEquals("type Address = { city: String }", found.text);
    assertEquals("@acme/common@1", found.pkg.manifest.id());
    assertEquals(found.pkg.dir, Paths.get(found.path).getParent().toString());

    // A copy is the same package; another package with the name isn't.
    Path copy = pkg(temp.resolve("b/common"), "@acme/common", "1.0.0", "type Address = { city: String }");
    one.packageDir(copy);
    Path other = pkg(temp.resolve("c/common"), "@acme/common", "1.1.0", "type Address = { city: String }");
    HausException e = fails("duplicate-package", () -> one.packageDir(other));
    assertTrue(e.reason().contains("\"1.0.0\"") && e.reason().contains("\"1.1.0\""), e.reason());

    fails("import-not-found", () -> empty.packageDir(temp.resolve("missing")));
    write(temp.resolve("empty/x.txt"), "");
    fails("import-not-found", () -> empty.packageDir(temp.resolve("empty")));
    write(temp.resolve("broken/package.haus"), "{ name: \"@Acme/Broken\" ");
    HausException broken = fails("package-manifest", () -> empty.packageDir(temp.resolve("broken")));
    assertTrue(broken.reason().contains("package.haus: "), broken.reason());
  }

  @Test
  void foldersOfPackages() throws IOException {
    Path folder = temp.resolve("schemas");
    pkg(folder.resolve("common"), "@acme/common", "1.0.0", "type Address = { city: String }");
    pkg(folder.resolve("deeper/money"), "@acme/money", "1.0.0", "type Money = { amount: Decimal }");
    write(folder.resolve("broken/package.haus"), "{ name: \"@Acme/Broken\" ");
    write(folder.resolve("notes.txt"), "not a package");
    pkg(temp.resolve("elsewhere/orders"), "@acme/orders", "1.0.0", "type Order = { id: Int }");
    Files.createSymbolicLink(folder.resolve("orders"), Paths.get("../elsewhere/orders"));

    ExplicitPackages packages = PackageLocator.explicit().folder(folder);
    SchemaFiles files = new SchemaFiles();
    assertEquals("@acme/common", files.openPackageFor(packages, "@acme/common", null).pkg.manifest.name());
    // A subdirectory that is a link to a package is one.
    assertEquals("@acme/orders", files.openPackageFor(packages, "@acme/orders", null).pkg.manifest.name());
    // Not deeper; and an import that isn't found names the subdirectories that couldn't be read.
    HausException e = fails("import-not-found", () -> files.openPackageFor(packages, "@acme/money", null));
    assertTrue(e.reason().replace('\\', '/').contains("schemas/broken ("), e.reason());

    fails("import-not-found", () -> PackageLocator.explicit().folder(temp.resolve("missing")));
    // Two packages in a folder with one name and other files.
    pkg(folder.resolve("common2"), "@acme/common", "1.0.0", "type Address = { city: String, zip: String }");
    fails("duplicate-package", () -> PackageLocator.explicit().folder(folder));
  }

  @Test
  void foldersHaveAtMost4096Entries() throws IOException {
    Path folder = Files.createDirectories(temp.resolve("many"));
    for (int i = 0; i < SchemaFiles.MAX_FOLDER_ENTRIES; i++) {
      Files.createFile(folder.resolve("f" + i));
    }
    PackageLocator.explicit().folder(folder);
    Files.createFile(folder.resolve("one-more"));
    fails("too-many-files", () -> PackageLocator.explicit().folder(folder));
  }

  @Test
  void aPackageGivenByItsDirectoryComesFirst() {
    Path shared = temp.resolve("shared");
    pkg(shared.resolve("common"), "@acme/common", "1.0.0", "type Address = { city: String, note?: String }");
    Path local = pkg(temp.resolve("local/common"), "@acme/common", "1.1.0", "type Address = { city: String }");
    ExplicitPackages folder = PackageLocator.explicit().folder(shared);
    ExplicitPackages dir = PackageLocator.explicit().packageDir(local);
    SchemaFiles files = new SchemaFiles();
    // Given by its directory, first: it wins.
    assertEquals("1.1.0", files.openPackageFor(PackageLocator.or(dir, folder), "@acme/common", null).pkg.manifest.version());
    // Found in a folder, first: the next locator's package has other files.
    fails("duplicate-package", () -> files.openPackageFor(PackageLocator.or(folder, dir), "@acme/common", null));
    // The next locator doesn't have it: the folder's is used.
    assertEquals("1.0.0", files.openPackageFor(PackageLocator.or(folder, PackageLocator.explicit()), "@acme/common", null)
        .pkg.manifest.version());
    fails("import-unavailable", () -> files.openPackageFor(PackageLocator.none(), "@acme/common", null));
    HausException neither = fails("import-not-found",
        () -> files.openPackageFor(PackageLocator.or(PackageLocator.explicit(), PackageLocator.explicit()), "@acme/x", null));
    assertTrue(neither.reason().contains("; "), neither.reason());
  }

  // ── reading a package's files ──

  @Test
  void packageFilesAreNeverLinks() throws IOException {
    Path orders = temp.resolve("vendor/orders");
    write(orders.resolve("package.haus"), "{ name: \"@acme/orders\", version: \"1.0.0\" }");
    write(orders.resolve("v1.haus"), "type Order = { id: Int }");
    Files.createSymbolicLink(orders.resolve("schema.haus"), Paths.get("v1.haus"));
    ExplicitPackages packages = PackageLocator.explicit().packageDir(orders);
    fails("package-path", () -> new SchemaFiles().openPackageFor(packages, "@acme/orders", null));

    Path linked = temp.resolve("vendor/linked");
    write(temp.resolve("secret/creds.haus"), "{ name: \"@acme/linked\", version: \"1.0.0\", token: \"do-not-print\" }");
    Files.createDirectories(linked);
    Files.createSymbolicLink(linked.resolve("package.haus"), Paths.get("../../secret/creds.haus"));
    HausException e = fails("package-path", () -> PackageLocator.explicit().packageDir(linked));
    assertFalse(e.getMessage().contains("do-not-print"), e.getMessage());

    // A package.json that is a link isn't read either.
    Path common = pkg(temp.resolve("vendor/common"), "@acme/common", "1.0.0", "type Address = { city: String }");
    write(temp.resolve("secret/package.json"), "{ \"version\": \"9.9.9-do-not-print\" }");
    Files.createSymbolicLink(common.resolve("package.json"), Paths.get("../../secret/package.json"));
    ExplicitPackages withJson = PackageLocator.explicit().packageDir(common);
    HausException j = fails("package-path", () -> new SchemaFiles().openPackageFor(withJson, "@acme/common", null));
    assertFalse(j.getMessage().contains("do-not-print"), j.getMessage());
  }

  @Test
  void versionsOfPackageJson() {
    Path common = pkg(temp.resolve("vendor/common"), "@acme/common", "1.0.0", "type Address = { city: String }");
    ExplicitPackages packages = PackageLocator.explicit().packageDir(common);
    write(common.resolve("package.json"), "{ \"name\": \"@acme/common\", \"version\": \"1.1.0\" }");
    HausException e = fails("package-version", () -> new SchemaFiles().openPackageFor(packages, "@acme/common", null));
    assertTrue(e.reason().contains("\"1.0.0\"") && e.reason().contains("\"1.1.0\""), e.reason());
    write(common.resolve("package.json"), "{ \"version\": \"1.0.0 do-not-print\" }");
    e = fails("package-version", () -> new SchemaFiles().openPackageFor(packages, "@acme/common", null));
    assertFalse(e.reason().contains("do-not-print"), e.reason());
    // Not JSON, or no string version: no version to check.
    write(common.resolve("package.json"), "{ \"version\": 1 ");
    new SchemaFiles().openPackageFor(packages, "@acme/common", null);
    write(common.resolve("package.json"), "{ \"version\": 1 }");
    new SchemaFiles().openPackageFor(packages, "@acme/common", null);
    write(common.resolve("package.json"), "{ \"version\": \"1.0.0\" }");
    new SchemaFiles().openPackageFor(packages, "@acme/common", null);
    write(common.resolve("package.json"), "{\"version\": \"1.0.0\", \"x\": \"" + "x".repeat(1 << 20) + "\"}");
    fails("file-too-large", () -> new SchemaFiles().openPackageFor(packages, "@acme/common", null));
  }

  @Test
  void eachFileIsReadOnce() {
    Path common = pkg(temp.resolve("vendor/common"), "@acme/common", "1.0.0", "type Address = { city: String }");
    ExplicitPackages packages = PackageLocator.explicit().packageDir(common);
    SchemaFiles files = new SchemaFiles();
    String first = files.openPackageFor(packages, "@acme/common", null).text;
    write(common.resolve("schema.haus"), "type Address = { changed: String }");
    assertEquals(first, files.openPackageFor(packages, "@acme/common", null).text);
    assertEquals("type Address = { changed: String }", new SchemaFiles().openPackageFor(packages, "@acme/common", null).text);
  }

  @Test
  void schemaFilesOfAtMost1MiB() {
    Path big = temp.resolve("big.schema.haus");
    write(big, "type A = Int\n" + "// padding\n".repeat(100_000));
    fails("file-too-large", () -> new SchemaFiles().rootSource(big.toString()));
    fails("import-not-found", () -> new SchemaFiles().rootSource(temp.resolve("missing.schema.haus").toString()));
    Path bad = temp.resolve("bad.schema.haus");
    try {
      Files.write(bad, new byte[] {'t', 'y', 'p', 'e', '\n', (byte) 0xFF});
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
    HausException e = fails("invalid-utf8", () -> new SchemaFiles().rootSource(bad.toString()));
    assertEquals(2, e.line());
    assertTrue(e.reason().contains("bad.schema.haus: invalid UTF-8"), e.reason());
  }

  // ── relative imports ──

  @Test
  void relativeImports() throws IOException {
    Path app = temp.resolve("app");
    write(app.resolve("app.schema.haus"), "import ./billing/common (Iban)");
    write(app.resolve("billing/common.schema.haus"), "type Iban = { number: String }");
    write(app.resolve("shared.schema.haus"), "type Address = { city: String }");
    SchemaFiles files = new SchemaFiles();
    String[] root = files.rootSource(app.resolve("app.schema.haus").toString());
    assertEquals("import ./billing/common (Iban)", root[1]);
    assertNull(files.packageOfFile(root[0]));
    SchemaFiles.Source common = files.openRelative("./billing/common", root[0]);
    assertEquals("type Iban = { number: String }", common.text);
    assertNull(common.pkg);
    assertEquals("type Address = { city: String }", files.openRelative("../shared", common.path).text);
    assertEquals("billing/common", SchemaFiles.relativeID(Paths.get(root[0]).getParent().toString(), common.path));

    fails("import-unavailable", () -> files.openRelative("./common", null));
    fails("import-not-found", () -> files.openRelative("./missing", root[0]));
    // Names are spelled as the directory lists them, also where the file system ignores case.
    HausException e = fails("import-not-found", () -> files.openRelative("./Billing/common", root[0]));
    assertTrue(e.reason().contains("\"Billing\""), e.reason());
    // A file whose real path doesn't end in .schema.haus is not read.
    write(temp.resolve("secret/creds.txt"), "API_TOKEN=do-not-print");
    Files.createSymbolicLink(app.resolve("pins.schema.haus"), Paths.get("../secret/creds.txt"));
    e = fails("import-not-found", () -> files.openRelative("./pins", root[0]));
    assertFalse(e.getMessage().contains("do-not-print"), e.getMessage());
  }

  @Test
  void packagesAndFilesDontMix() {
    Path orders = pkg(temp.resolve("vendor/orders"), "@acme/orders", "1.0.0", "import ./common (Address)");
    write(orders.resolve("common.schema.haus"), "type Address = { city: String }");
    write(temp.resolve("app/app.schema.haus"), "import ../vendor/orders/common (Address)");
    SchemaFiles files = new SchemaFiles();
    String[] root = files.rootSource(orders.resolve("schema.haus").toString());
    SchemaFiles.FoundPackage pkg = files.packageOfFile(root[0]);
    assertEquals("@acme/orders", pkg.manifest.name());
    assertEquals("{ name: \"@acme/orders\", version: \"1.0.0\" }", pkg.manifestText);
    HausException e = fails("package-path", () -> files.openRelative("./common", root[0]));
    assertTrue(e.reason().contains("@acme/orders"), e.reason());
    String[] app = files.rootSource(temp.resolve("app/app.schema.haus").toString());
    fails("package-path", () -> files.openRelative("../vendor/orders/common", app[0]));
  }

  // ── messages ──

  @Test
  void messages() {
    assertEquals("/a/\\u{202E}b\\u{200F}c\\u{A}", SchemaFiles.shown("/a/\u202Eb\u200Fc\n"));
    assertEquals("/plain/path", SchemaFiles.shown("/plain/path"));
    HausException placed = new HausException(ErrorCode.UNKNOWN_TYPE, "unknown type X", 3, 5, null, null, null);
    HausException in = SchemaFiles.inFile(placed, "/app/app.schema.haus");
    assertEquals("/app/app.schema.haus: unknown type X", in.reason());
    assertEquals(3, in.line());
    assertSame(in, SchemaFiles.inFile(in, "/app/app.schema.haus"));
    HausException unplaced = HausException.of(ErrorCode.IMPORT_NOT_FOUND, "file not found: /x");
    assertSame(unplaced, SchemaFiles.inFile(unplaced, "/app/app.schema.haus"));
    Manifest a = Manifest.parse(utf8("{ name: \"@acme/ids\", version: \"3.1.0\" }"));
    Manifest b = Manifest.parse(utf8("{ name: \"@acme/ids\", version: \"3.1.0\" }"));
    assertEquals("two packages are called \"@acme/ids\": \"3.1.0\" in /a and \"3.1.0\" in /b (two copies of \"3.1.0\" "
        + "whose files or imports differ)", SchemaFiles.duplicate(a, "/a", b, "/b").reason());
  }
}
