package org.hausfmt;

import java.io.IOException;
import java.io.InputStream;
import java.net.JarURLConnection;
import java.net.URISyntaxException;
import java.net.URL;
import java.net.URLConnection;
import java.nio.channels.Channels;
import java.nio.channels.SeekableByteChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AccessDeniedException;
import java.nio.file.DirectoryIteratorException;
import java.nio.file.DirectoryStream;
import java.nio.file.FileSystemException;
import java.nio.file.FileSystemLoopException;
import java.nio.file.Files;
import java.nio.file.InvalidPathException;
import java.nio.file.LinkOption;
import java.nio.file.NoSuchFileException;
import java.nio.file.NotDirectoryException;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.function.Supplier;
import java.util.jar.JarEntry;

/**
 * Reading the files a schema imports (spec §13.3), the same wherever a package is found: a {@link
 * PackageLocator} says where a package is, and the rules here say whether it may be read.
 * Resolution happens when a schema is loaded, never while data is parsed, and never over the
 * network (§9).
 *
 * <p>Every file is read the same way ("Files read", §13.3): the entry file by its real path, the
 * files of relative imports by the path their names walk down to (which has no links), a package's {@code package.haus}, {@code schema.haus} and
 * {@code package.json} by name in the package's real directory, each without following a link at
 * its last name ({@link LinkOption#NOFOLLOW_LINKS}, O_NOFOLLOW on Unix). Java can't open a file
 * without blocking or ask an open channel for its type, so the type is checked just before the
 * open, without following links, and a regular file is opened; after the open the file at the
 * path must still be a regular file with the same {@link BasicFileAttributes#fileKey() key}
 * (device and inode on Unix), where the platform gives one. The size is checked on the opened
 * channel, and the file is read from it, at most one byte past the limit. <b>The race that is
 * left</b>: a regular file swapped for a FIFO between the check and the open blocks the open,
 * and so the build, until something writes to the FIFO. Only someone who may write to the
 * schema's directories can do that.
 *
 * <p>The names a build looks up itself ({@code package.haus}, {@code schema.haus}, {@code
 * package.json}) and each name of a relative import match only an entry their directory lists
 * with that spelling, also on file systems that ignore case; a directory that can't be listed
 * finds no name.
 *
 * <p>A build has a root (§13.3, "The root"): the directory of the entry file's real path, or the
 * {@link SchemaOptions#root() root option}; both are resolved to real paths once, at the start. A
 * relative import follows no link: each of its names is listed by its directory and is no
 * symbolic link (else {@code import-not-found}), so a relative import stays inside the root when
 * its {@code ..} names do; one whose {@code ..} names go above it is {@code import-outside-root}
 * before anything is looked at. Messages show paths relative to the root ({@code ../vendor/x} for
 * a package outside it).
 *
 * <p>An instance is the files one schema reads, each once, by real path: a file needed in two
 * roles is read once, and every use sees the same bytes. Each use keeps its own checks: a
 * package's files are never read through a link, and each kind of file has its own size limit.
 *
 * <p>Paths are strings: real paths (absolute, every link resolved) where the comments say so. A
 * package given as classpath resources that aren't files on disk (in a jar) has the URL of its
 * directory as its path, and is shown as {@code classpath:prefix}.
 */
final class SchemaFiles {
  /** A schema package's manifest: {@code { name, version }}. */
  static final String MANIFEST_FILE = "package.haus";
  /** A schema package's one schema file, next to its manifest. */
  static final String SCHEMA_FILE = "schema.haus";
  /** The npm wrapper of a package, whose version the manifest's must equal. */
  static final String PACKAGE_JSON = "package.json";
  /** The extension of schema files, always added to relative imports: ./common is common.schema.haus. */
  static final String EXTENSION = ".schema.haus";

  /** The largest package.haus, in bytes (64 KiB). */
  static final int MAX_MANIFEST = 64 << 10;
  /** The largest schema file and package.json, in bytes (1 MiB). */
  static final int MAX_FILE = 1 << 20;
  /** The most entries a folder of packages may have. */
  static final int MAX_FOLDER_ENTRIES = 4096;
  /**
   * The most schema files one schema reads, the root included (manifests and package.json don't
   * count). The resolver counts them: files read once, and copies of packages whose imports are
   * resolved again.
   */
  static final int MAX_FILES = 256;

  private static final LinkOption[] NOFOLLOW = {LinkOption.NOFOLLOW_LINKS};
  private static final Set<OpenOption> READ_NOFOLLOW = Set.of(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS);

  /** Which file is read, and so its limit. */
  private enum Kind {
    /** A package's package.haus: at most 64 KiB. */
    MANIFEST(MAX_MANIFEST),
    /** A package's schema.haus. */
    PACKAGE_SCHEMA(MAX_FILE),
    /** A package's package.json. */
    PACKAGE_JSON(MAX_FILE),
    /** A schema file outside packages, read at its real path. */
    SCHEMA(MAX_FILE);

    final int limit;

    Kind(int limit) {
      this.limit = limit;
    }
  }

  /** What opening a file gave. */
  private enum State {
    OPENED,
    MISSING,
    /** A symbolic link, a directory, a FIFO, …: not read. */
    NOT_REGULAR,
    TOO_LARGE,
    FAILED
  }

  /** A file opened: its bytes, its size if too large, or why it failed. */
  private record Opened(State state, byte[] bytes, long size, String why) {
    static final Opened MISSING = new Opened(State.MISSING, null, 0, null);
    static final Opened NOT_REGULAR = new Opened(State.NOT_REGULAR, null, 0, null);

    static Opened tooLarge(long size) {
      return new Opened(State.TOO_LARGE, null, size, null);
    }

    static Opened failed(String why) {
      return new Opened(State.FAILED, null, 0, why);
    }

    static Opened read(byte[] bytes, int limit) {
      return bytes.length > limit ? tooLarge(bytes.length) : new Opened(State.OPENED, bytes, bytes.length, null);
    }

    /** The file read for one use, as another use with its own limit sees it. */
    Opened within(Kind kind) {
      return state == State.OPENED && bytes.length > kind.limit ? tooLarge(bytes.length) : this;
    }
  }

  /**
   * A package given as classpath resources (spec §13.3, a read-only file tree given by code):
   * its files are the resources {@code prefix/package.haus}, {@code prefix/schema.haus} and
   * {@code prefix/package.json} of the class loader. Used for resources that aren't files on disk
   * (in a jar); a resource that is a file is read as the directory it is in.
   */
  record Resources(ClassLoader loader, String prefix) {
    Resources {
      Objects.requireNonNull(loader, "loader");
      Objects.requireNonNull(prefix, "prefix");
    }

    /** The resource name of a file of the package. */
    String name(String file) {
      return prefix.isEmpty() ? file : prefix + "/" + file;
    }

    URL url(String file) {
      return loader.getResource(name(file));
    }

    /** How messages name the package. */
    String label() {
      return "classpath:" + prefix;
    }

    /** The package's path: the URL of its directory, from its manifest's. */
    static String dirOf(URL manifest) {
      String u = manifest.toString();
      return u.substring(0, u.length() - MANIFEST_FILE.length());
    }
  }

  /** A schema file an import names, read. */
  static final class Source {
    /** Its real path: two imports reach the same file when it is the same. */
    final String path;
    final String text;
    /** The package, for a package's schema.haus; null otherwise. */
    final FoundPackage pkg;

    Source(String path, String text, FoundPackage pkg) {
      this.path = path;
      this.text = text;
      this.pkg = pkg;
    }
  }

  /** A package, with its manifest checked. */
  static final class FoundPackage {
    final Manifest manifest;
    /** Its real path (for classpath resources in a jar, the URL of its directory). */
    final String dir;
    /** The text of its package.haus: copies of a package have the same. */
    final String manifestText;

    FoundPackage(Manifest manifest, String dir, String manifestText) {
      this.manifest = manifest;
      this.dir = dir;
      this.manifestText = manifestText;
    }
  }

  /** The version a package.json gives, if {@code present}. */
  record Version(String text, boolean present) {
    static final Version NONE = new Version(null, false);
  }

  /** The files read, by real path (or URL). */
  private final Map<String, Opened> opened = new HashMap<>();
  /** The package.json files parsed, by real path; null for one that isn't JSON. */
  private final Map<String, Value> json = new HashMap<>();
  /** The packages whose schema.haus has been read, by its path: they import no files. */
  private final Map<String, FoundPackage> packageSchemas = new HashMap<>();
  /** How messages name the paths of packages of classpath resources in a jar. */
  private final Map<String, String> labels = new HashMap<>();
  /** The root (a real path); null until the entry file is read, and for a schema given as text. */
  private String root;
  /** The entry file as messages show it. */
  private String entry;

  /** A cache for one schema: each file is read at most once, by its real path. */
  SchemaFiles() {}

  // ── reading files ──

  /**
   * Reads the file at path, a regular file, not through a link at its last name, of at most
   * {@code limit} bytes, whose size is checked on the opened channel.
   */
  private static Opened readFile(String path, int limit) {
    Path p;
    try {
      p = Paths.get(path);
    } catch (InvalidPathException e) {
      return Opened.MISSING;
    }
    BasicFileAttributes before;
    try {
      before = Files.readAttributes(p, BasicFileAttributes.class, NOFOLLOW);
    } catch (IOException e) {
      return failedOpen(p, e);
    }
    // Checked before the open, which would block on a FIFO: the race left is in the class comment.
    if (!before.isRegularFile()) {
      return Opened.NOT_REGULAR;
    }
    try (SeekableByteChannel channel = Files.newByteChannel(p, READ_NOFOLLOW)) {
      // Still the file checked, where the platform gives files a key (device and inode).
      Object key = before.fileKey();
      if (key != null) {
        BasicFileAttributes after = Files.readAttributes(p, BasicFileAttributes.class, NOFOLLOW);
        if (!after.isRegularFile() || !key.equals(after.fileKey())) {
          return Opened.NOT_REGULAR;
        }
      }
      long size = channel.size();
      if (size > limit) {
        return Opened.tooLarge(size);
      }
      InputStream in = Channels.newInputStream(channel);
      return Opened.read(in.readNBytes(limit + 1), limit);
    } catch (IOException e) {
      // Replaced by a link between the check and the open (O_NOFOLLOW refused it), or removed.
      return failedOpen(p, e);
    }
  }

  /** What a failed open or check means: a missing file, something that isn't a file, or an error. */
  private static Opened failedOpen(Path p, IOException e) {
    BasicFileAttributes at;
    try {
      at = Files.readAttributes(p, BasicFileAttributes.class, NOFOLLOW);
    } catch (IOException lerr) {
      return e instanceof NoSuchFileException ? Opened.MISSING : Opened.failed(describe(e));
    }
    if (!at.isRegularFile()) {
      return Opened.NOT_REGULAR;
    }
    return e instanceof NoSuchFileException ? Opened.MISSING : Opened.failed(describe(e));
  }

  /**
   * Reads a resource that isn't a file on disk (in a jar): at most {@code limit} bytes. A jar
   * holds no links; an entry that is a directory is not a regular file. A file: URL is read as a
   * file, spelled as its directory lists it.
   */
  private static Opened readResource(URL url, int limit) {
    if (url == null) {
      return Opened.MISSING;
    }
    if (url.getProtocol().equals("file")) {
      String path;
      try {
        path = Paths.get(url.toURI()).toString();
      } catch (URISyntaxException | IllegalArgumentException e) {
        return Opened.MISSING;
      }
      return listed(path) ? readFile(path, limit) : Opened.MISSING;
    }
    try {
      URLConnection c = url.openConnection();
      c.setUseCaches(false);
      // Opened first, so that closing it closes the jar it opened.
      try (InputStream in = c.getInputStream()) {
        if (c instanceof JarURLConnection j) {
          JarEntry e = j.getJarEntry();
          if (e == null || e.isDirectory()) {
            return Opened.NOT_REGULAR;
          }
        }
        return Opened.read(in.readNBytes(limit + 1), limit);
      }
    } catch (IOException e) {
      return Opened.failed(describe(e));
    }
  }

  /** The cached read of the file at path, for a use of the kind, and the real path it is cached by. */
  private record Keyed(String key, Opened file) {}

  /**
   * Reads the file at path as {@code kind} says, once per real path. A package's file is found
   * only if its directory lists its name with that spelling.
   */
  private Keyed open(String path, Kind kind) {
    if (kind != Kind.SCHEMA && !listed(path)) {
      return new Keyed(path, Opened.MISSING);
    }
    try {
      if (Files.readAttributes(Paths.get(path), BasicFileAttributes.class, NOFOLLOW).isSymbolicLink()) {
        // Not cached: its target, read in another role at its own real path, may be readable.
        return new Keyed(path, Opened.NOT_REGULAR);
      }
    } catch (NoSuchFileException | InvalidPathException e) {
      return new Keyed(path, Opened.MISSING);
    } catch (IOException e) {
      // Read below, which says why it fails.
    }
    Opened r = opened.get(path);
    if (r == null) {
      r = readFile(path, Math.max(MAX_FILE, MAX_MANIFEST));
      opened.put(path, r);
    }
    return new Keyed(path, r.within(kind));
  }

  /** Reads a file of a package of classpath resources in a jar, once per URL. */
  private Keyed openResource(Resources res, String file, Kind kind) {
    URL url = res.url(file);
    if (url == null) {
      return new Keyed(res.name(file), Opened.MISSING);
    }
    String key = url.toString();
    Opened r = opened.get(key);
    if (r == null) {
      r = readResource(url, Math.max(MAX_FILE, MAX_MANIFEST));
      opened.put(key, r);
    }
    return new Keyed(key, r.within(kind));
  }

  /**
   * The version the package.json beside the manifest of a package given explicitly (dir is its
   * real path) gives, if it gives one. Such a package.json only gives a version: one that can't
   * be read (a link, not a regular file, too large, not JSON) is ignored, and is no error (spec
   * §13.3, "Package versions").
   */
  Version lenientVersion(String dir) {
    return versionOf(open(join(dir, PACKAGE_JSON), Kind.PACKAGE_JSON));
  }

  /** {@link #lenientVersion} for a package of classpath resources in a jar. */
  Version lenientVersion(Resources res) {
    return versionOf(openResource(res, PACKAGE_JSON, Kind.PACKAGE_JSON));
  }

  private Version versionOf(Keyed k) {
    Opened r = k.file();
    if (r.state() != State.OPENED) {
      return Version.NONE;
    }
    Value doc;
    if (json.containsKey(k.key())) {
      doc = json.get(k.key());
    } else {
      // The core's JSON import: a package.json that it rejects (not UTF-8, not JSON, a key twice)
      // gives no version.
      try {
        doc = HausJson.importJson(r.bytes(), Limits.DEFAULT);
      } catch (HausException e) {
        doc = null;
      }
      json.put(k.key(), doc);
    }
    if (doc instanceof Value.Record rec && rec.get("version") instanceof Value.Text version) {
      return new Version(version.value(), true);
    }
    return Version.NONE;
  }

  /** Checks the manifest of a package, opened; {@code shown} names the package in messages, escaped. */
  private static FoundPackage manifestOf(String dir, String shown, Opened r) {
    String file = shown + "/" + MANIFEST_FILE;
    switch (r.state()) {
      case MISSING:
        throw notFound(shown + " is not a schema package: it has no " + MANIFEST_FILE);
      case NOT_REGULAR:
        throw HausException.of(ErrorCode.PACKAGE_PATH,
            "the manifest " + file + " is a symbolic link or not a regular file; it is not read");
      case TOO_LARGE:
        throw invalidManifest(file, "the manifest has " + r.size() + " bytes, more than 64 KiB");
      case FAILED:
        throw notFound(file + ": " + r.why());
      default:
        break;
    }
    byte[] bytes = r.bytes();
    if (Scan.invalidUtf8(bytes, 0, bytes.length) < bytes.length) {
      throw invalidManifest(file, "the manifest is not UTF-8");
    }
    Manifest m;
    try {
      m = Manifest.parse(bytes);
    } catch (HausException e) {
      throw invalidManifest(file, e.reason());
    }
    return new FoundPackage(m, dir, new String(bytes, StandardCharsets.UTF_8));
  }

  /** package-manifest, in the manifest {@code file} (shown, escaped). */
  private static HausException invalidManifest(String file, String why) {
    return HausException.of(ErrorCode.PACKAGE_MANIFEST, file + ": " + why);
  }

  /**
   * Reads the manifest of the package in dir (a real path) on its own, outside any schema's
   * cache; {@code display} names the package in messages, as the application gave it.
   */
  static Manifest readManifest(String dir, String display) {
    String path = join(dir, MANIFEST_FILE);
    Opened r = listed(path) ? readFile(path, MAX_MANIFEST) : Opened.MISSING;
    return manifestOf(dir, shown(display), r).manifest;
  }

  /** Reads the manifest of a package of classpath resources in a jar on its own. */
  static Manifest readManifest(Resources res) {
    return manifestOf(null, shown(res.label()), readResource(res.url(MANIFEST_FILE), MAX_MANIFEST)).manifest;
  }

  /**
   * Reads a schema file: a package's schema.haus, or a file outside packages at its real path.
   * {@code missingWhy} says why a missing one is missing.
   */
  private String schemaText(String path, Kind kind, Supplier<String> missingWhy) {
    return schemaText(open(path, kind).file(), path, kind, missingWhy);
  }

  private String schemaText(Opened r, String path, Kind kind, Supplier<String> missingWhy) {
    switch (r.state()) {
      case OPENED:
        return text(r.bytes());
      case MISSING:
        throw notFound(missingWhy.get());
      case NOT_REGULAR:
        if (kind == Kind.PACKAGE_SCHEMA) {
          throw HausException.of(ErrorCode.PACKAGE_PATH, show(path) + " is a symbolic link or not a regular file; it is not read");
        }
        throw notFound(show(path) + " is not a regular file; it is not read");
      case TOO_LARGE:
        throw tooLarge(show(path), r.size());
      default:
        throw notFound(show(path) + ": " + r.why());
    }
  }

  /**
   * The text of a schema file. Invalid UTF-8 is {@code invalid-utf8} at its line and column in
   * the file, as the schema parser would report it; the reason doesn't name the file.
   */
  private static String text(byte[] bytes) {
    int bad = Scan.invalidUtf8(bytes, 0, bytes.length);
    if (bad < bytes.length) {
      throw new org.hausfmt.Source(bytes).error(new SyntaxError(bad, ErrorCode.INVALID_UTF8, "invalid UTF-8"));
    }
    return new String(bytes, StandardCharsets.UTF_8);
  }

  // ── packages ──

  /**
   * Finds the package name for the file at from (a real path, or null for a schema given as text)
   * with the locator and checks it: the manifest ({@code package-manifest}) and its name ({@code
   * import-not-found}), its version ({@code package-version}), its files ({@code package-path},
   * {@code file-too-large}), and that a package found in a folder that the next locator has too
   * is the same ({@code duplicate-package}).
   */
  Source openPackageFor(PackageLocator packages, String name, String from) {
    PackageLocator.Location loc = packages.locate(name, from, this);
    Source src = loc.resources() != null
        ? openResources(loc.resources(), name, loc.version(), loc.hasVersion())
        : openPackage(loc.dir(), name, loc.version(), loc.hasVersion());
    if (loc.sameAs() != null) {
      Source other = openPackage(loc.sameAs(), name, null, false);
      FoundPackage a = src.pkg;
      FoundPackage b = other.pkg;
      if (!a.dir.equals(b.dir) && (!a.manifestText.equals(b.manifestText) || !src.text.equals(other.text))) {
        throw duplicate(a, b);
      }
    }
    return src;
  }

  /** Reads the package in dir, which must be called name, with the version its package manager gives it, if any. */
  private Source openPackage(String dir, String name, String version, boolean hasVersion) {
    String resolved;
    try {
      resolved = realPath(dir);
    } catch (IOException e) {
      throw notFound(show(dir) + ": " + describe(e));
    }
    FoundPackage pkg = manifestOf(resolved, show(resolved), open(join(resolved, MANIFEST_FILE), Kind.MANIFEST).file());
    String path = join(resolved, SCHEMA_FILE);
    checkPackage(pkg, name, version, hasVersion);
    String schema = schemaText(path, Kind.PACKAGE_SCHEMA,
        () -> name + " has no " + SCHEMA_FILE + " next to its manifest (" + show(resolved) + ")");
    packageSchemas.put(path, pkg);
    return new Source(path, schema, pkg);
  }

  /** Reads a package of classpath resources in a jar, as {@link #openPackage} a directory. */
  private Source openResources(Resources res, String name, String version, boolean hasVersion) {
    URL manifest = res.url(MANIFEST_FILE);
    String dir = manifest == null ? res.label() : Resources.dirOf(manifest);
    labels.put(dir, res.label());
    FoundPackage pkg = manifestOf(dir, shown(res.label()), openResource(res, MANIFEST_FILE, Kind.MANIFEST).file());
    checkPackage(pkg, name, version, hasVersion);
    Keyed k = openResource(res, SCHEMA_FILE, Kind.PACKAGE_SCHEMA);
    labels.put(k.key(), res.label() + "/" + SCHEMA_FILE);
    String schema = schemaText(k.file(), k.key(), Kind.PACKAGE_SCHEMA,
        () -> name + " has no " + SCHEMA_FILE + " next to its manifest (" + shown(res.label()) + ")");
    packageSchemas.put(k.key(), pkg);
    return new Source(k.key(), schema, pkg);
  }

  /** The name and the version of a package found. */
  private void checkPackage(FoundPackage pkg, String name, String version, boolean hasVersion) {
    Manifest m = pkg.manifest;
    if (!m.name().equals(name)) {
      throw notFound("the manifest of " + show(pkg.dir) + " names the package " + Quoting.forMessage(m.name())
          + ", not " + name);
    }
    if (hasVersion && !version.equals(m.version())) {
      // Text from package.json is quoted only if it is a version (spec §9).
      String given = Manifest.isSemver(version)
          ? "its package manager " + Quoting.forMessage(version)
          : "and the version its package manager gives isn't a semantic version";
      throw HausException.of(ErrorCode.PACKAGE_VERSION, "the package.haus of " + name + " says version "
          + Quoting.forMessage(m.version()) + ", " + given + " (" + show(pkg.dir) + ")");
    }
  }

  /**
   * Reads the file module ({@code ./common}, {@code ../shared/money}, a path by grammar {@code
   * path}) imports, next to the file at from (a real path; null for a schema given as text, which
   * imports no files). A package imports no files ({@code package-path}). The other checks come in
   * the order of spec §13.3 ("Resolution"), the first that fails giving the error: the {@code ..}
   * names stay inside the root, checked on the text before anything is looked at ({@code
   * import-outside-root}); the walk down the names, each listed with that spelling and none a
   * symbolic link ({@code import-not-found}); a target outside a package's directory ({@code
   * package-path}); then the file, regular and within its limit.
   */
  Source openRelative(String module, String from) {
    if (from == null) {
      throw HausException.of(ErrorCode.IMPORT_UNAVAILABLE, "a schema read from text imports no files (load it from its file)");
    }
    FoundPackage importer = packageSchemas.get(from);
    if (importer != null) {
      throw HausException.of(ErrorCode.PACKAGE_PATH, "the schema of " + importer.manifest.name()
          + " can't import files, only packages by name");
    }
    // `..` only at the start (grammar `path`), and no link is followed: going up from the real
    // directory of the importing file means the same on the text and on the file system.
    List<String> names = List.of((module + EXTENSION).split("/", -1));
    int ups = (int) names.stream().takeWhile(".."::equals).count();
    Path top = Paths.get(parent(from));
    for (int i = 0; i < ups && top != null; i++) {
      top = top.getParent();
    }
    if (top == null || root != null && !top.startsWith(Paths.get(root))) {
      throw outsideRoot(shown(module) + " goes above the build's root directory; nothing there is looked at");
    }
    int first = (int) names.stream().takeWhile(n -> n.equals(".") || n.equals("..")).count();
    String path = walkNames(top, names.subList(first, names.size())).toString();
    checkOutsidePackages(path);
    String text = schemaText(path, Kind.SCHEMA, () -> "file not found: " + show(path));
    return new Source(path, text, null);
  }

  /**
   * The walk down the names of a relative import (spec §13.3, "Resolution") from the real
   * directory dir: each name must be an entry its directory lists with that exact spelling, also
   * on file systems that ignore case or Unicode normalization, and not a symbolic link (seen
   * without following it); each name but the last a directory. A directory that can't be listed
   * can't show how a name is spelled. Nothing behind a link is looked at, and a message about one
   * doesn't say where it points. The path reached has no links; what its last name is (a regular
   * file or not) is checked when it is opened.
   */
  private Path walkNames(Path dir, List<String> names) {
    // The file the import names, for messages.
    String target;
    try {
      target = show(dir.resolve(String.join("/", names)).toString());
    } catch (InvalidPathException e) {
      throw notFound("file not found: " + shown(String.join("/", names)));
    }
    Path at = dir;
    for (int i = 0; i < names.size(); i++) {
      String name = names.get(i);
      Path p = at.resolve(name);
      Boolean listed = lists(at, name);
      if (listed == null) {
        throw notFound("file not found: " + target + " (" + show(at.toString()) + " can't be listed, so how "
            + Quoting.forMessage(name) + " is spelled can't be checked)");
      }
      if (!listed) {
        throw notFound("file not found: " + target + " (no " + Quoting.forMessage(name)
            + " in its directory: names are spelled as the directory lists them)");
      }
      BasicFileAttributes a;
      try {
        a = Files.readAttributes(p, BasicFileAttributes.class, NOFOLLOW);
      } catch (IOException e) {
        throw notFound("file not found: " + target + " (" + show(p.toString()) + ": " + describe(e) + ")");
      }
      if (isLink(a)) {
        throw notFound(show(p.toString())
            + " is a symbolic link: a relative import follows no link, and nothing behind it is read");
      }
      if (!a.isDirectory() && i < names.size() - 1) {
        throw notFound("file not found: " + target + " (" + show(p.toString()) + " is not a directory)");
      }
      at = p;
    }
    return at;
  }

  /**
   * Whether attributes read without following links are a link's: a symbolic link, or on Windows a
   * directory that is a reparse point too (a junction), which Java gives as both a directory and
   * "other".
   */
  private static boolean isLink(BasicFileAttributes a) {
    return a.isSymbolicLink() || a.isDirectory() && a.isOther();
  }

  /**
   * Whether dir lists name with that spelling, also on file systems that ignore case; null if dir
   * can't be listed.
   */
  private static Boolean lists(Path dir, String name) {
    try (DirectoryStream<Path> entries = Files.newDirectoryStream(dir)) {
      for (Path e : entries) {
        if (e.getFileName().toString().equals(name)) {
          return true;
        }
      }
      return false;
    } catch (IOException | DirectoryIteratorException e) {
      return null;
    }
  }

  /**
   * Checks that the file at path (reached by a relative import, inside the root) is in no
   * package's directory (spec §13.3, "Imports"): the directories from its own up to the root, the
   * root included, each a package's when it lists {@code package.haus} ({@code package-path}). One
   * that can't be listed can't show whether it is a package's: the import fails ({@code
   * import-not-found}), and never passes as one outside a package.
   */
  private void checkOutsidePackages(String path) {
    Path rootPath = Paths.get(root);
    for (Path d = Paths.get(path).getParent(); d != null && d.startsWith(rootPath); d = d.getParent()) {
      Boolean pkg = lists(d, MANIFEST_FILE);
      if (pkg == null) {
        throw notFound("whether " + show(d.toString()) + " is a package's directory can't be checked (it can't be listed); "
            + show(path) + " is not read");
      }
      if (pkg) {
        throw HausException.of(ErrorCode.PACKAGE_PATH, "the file is in the package directory " + show(d.toString())
            + ": import the package by its name");
      }
    }
  }

  /**
   * Whether the last name of path is listed by its directory with that spelling, also on file
   * systems that ignore case. A directory that can't be listed lists nothing.
   */
  static boolean listed(String path) {
    Path p;
    try {
      p = Paths.get(path);
    } catch (InvalidPathException e) {
      return false;
    }
    Path dir = p.getParent();
    Path name = p.getFileName();
    if (dir == null || name == null || !exists(path)) {
      return false;
    }
    String want = name.toString();
    try (DirectoryStream<Path> entries = Files.newDirectoryStream(dir)) {
      for (Path e : entries) {
        if (e.getFileName().toString().equals(want)) {
          return true;
        }
      }
    } catch (IOException | DirectoryIteratorException e) {
      return false;
    }
    return false;
  }

  /**
   * Whether dir is a package's directory: it lists a {@code package.haus}. A directory that has
   * something at that name but can't be listed is taken for one, so that a file in it is never
   * read as a file outside packages.
   */
  private static boolean isPackageDir(Path dir) {
    Path manifest = dir.resolve(MANIFEST_FILE);
    if (!exists(manifest.toString())) {
      return false;
    }
    try (DirectoryStream<Path> entries = Files.newDirectoryStream(dir)) {
      for (Path e : entries) {
        if (e.getFileName().toString().equals(MANIFEST_FILE)) {
          return true;
        }
      }
      return false;
    } catch (IOException | DirectoryIteratorException e) {
      return true;
    }
  }

  /**
   * Reads the entry file at path: {@code {real path, text}}, with the root the directory of its
   * real path. A package's schema.haus is read as one.
   */
  String[] rootSource(String path) {
    return rootSource(path, null);
  }

  /**
   * Reads the entry file at path: {@code {real path, text}}. The root is {@code rootOption} (a
   * directory that contains the entry file, else {@code import-outside-root}; a relative one is
   * from the directory of the entry file's real path), or by default that directory. The entry
   * file and the root may be reached through links: both are resolved to real paths here, once. A
   * package's schema.haus is read as one.
   */
  String[] rootSource(String path, String rootOption) {
    String resolved;
    try {
      resolved = realPath(path);
    } catch (IOException e) {
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, shown(path) + ": " + describe(e));
    }
    String rootDir = parent(resolved);
    if (rootOption != null) {
      String given;
      try {
        given = realPath(Paths.get(rootDir).resolve(rootOption).toString());
      } catch (IOException e) {
        throw outsideRoot("the root option names no directory that contains the schema file: " + describe(e));
      } catch (InvalidPathException e) {
        throw outsideRoot("the root option names no directory that contains the schema file: it is no path");
      }
      Path entryPath = Paths.get(resolved);
      Path givenPath = Paths.get(given);
      if (!entryPath.startsWith(givenPath) || entryPath.equals(givenPath)) {
        // Shown relative to the root given, as every path of the build.
        String rel;
        try {
          rel = givenPath.relativize(entryPath).toString().replace(java.io.File.separatorChar, '/');
        } catch (IllegalArgumentException e) {
          rel = fileName(resolved);
        }
        throw outsideRoot("the root option doesn't contain the schema file the build starts from (" + shown(rel)
            + " from the root)");
      }
      rootDir = given;
    }
    root = rootDir;
    entry = display(resolved);
    Kind kind = isPackageSchema(resolved) ? Kind.PACKAGE_SCHEMA : Kind.SCHEMA;
    try {
      return new String[] {resolved, schemaText(resolved, kind, () -> "file not found: " + show(resolved))};
    } catch (HausException e) {
      throw inFile(e);
    }
  }

  /** Whether the file at path is a package's schema.haus: next to a package.haus. */
  private static boolean isPackageSchema(String path) {
    Path p = Paths.get(path);
    return fileName(path).equals(SCHEMA_FILE) && p.getParent() != null && isPackageDir(p.getParent());
  }

  /**
   * The package whose schema.haus is the file at path (a real path), with its manifest checked,
   * or null if the file is no package's schema.haus.
   */
  FoundPackage packageOfFile(String path) {
    if (!isPackageSchema(path)) {
      return null;
    }
    String dir = parent(path);
    FoundPackage pkg = manifestOf(dir, show(dir), open(join(dir, MANIFEST_FILE), Kind.MANIFEST).file());
    packageSchemas.put(path, pkg);
    return pkg;
  }

  /**
   * Whether two packages are copies of one package: their manifests and schema files are the
   * same, byte for byte, and regular files (spec §13.3). Each is a real directory, or classpath
   * resources in a jar ({@code res} not null). Read outside any schema's cache, when packages are
   * given.
   */
  static boolean sameFiles(String a, Resources ares, String b, Resources bres) {
    Opened am = packageFile(a, ares, MANIFEST_FILE, MAX_MANIFEST);
    Opened as = packageFile(a, ares, SCHEMA_FILE, MAX_FILE);
    if (am.state() != State.OPENED || as.state() != State.OPENED) {
      return false;
    }
    Opened bm = packageFile(b, bres, MANIFEST_FILE, MAX_MANIFEST);
    Opened bs = packageFile(b, bres, SCHEMA_FILE, MAX_FILE);
    return bm.state() == State.OPENED && bs.state() == State.OPENED
        && Arrays.equals(am.bytes(), bm.bytes()) && Arrays.equals(as.bytes(), bs.bytes());
  }

  private static Opened packageFile(String dir, Resources res, String file, int limit) {
    if (res != null) {
      return readResource(res.url(file), limit);
    }
    String path = join(dir, file);
    return listed(path) ? readFile(path, limit) : Opened.MISSING;
  }

  // ── paths ──

  /**
   * The absolute path with every link resolved, of a file that exists. Like Go's filepath.Abs, a
   * {@code ..} is removed before links are resolved.
   *
   * @throws IOException if the file doesn't exist or can't be reached ({@link
   *     NoSuchFileException} for a path that can't name a file)
   */
  static String realPath(String path) throws IOException {
    Path p;
    try {
      p = Paths.get(path);
    } catch (InvalidPathException e) {
      throw new NoSuchFileException(path);
    }
    return p.toAbsolutePath().normalize().toRealPath().toString();
  }

  /** Whether something is at path, without following a link. */
  static boolean exists(String path) {
    try {
      return Files.exists(Paths.get(path), LinkOption.NOFOLLOW_LINKS);
    } catch (InvalidPathException e) {
      return false;
    }
  }

  /**
   * The id of a file outside packages: its path from base, {@code /}-separated, without the
   * extension ({@code billing/common}, {@code ../shared/money}). Different files have different
   * ids.
   */
  static String relativeID(String base, String path) {
    String rel;
    try {
      rel = Paths.get(base).relativize(Paths.get(path)).toString();
    } catch (IllegalArgumentException e) {
      // On another drive (Windows): the path itself.
      rel = path;
    }
    rel = rel.replace(java.io.File.separatorChar, '/');
    return rel.endsWith(EXTENSION) ? rel.substring(0, rel.length() - EXTENSION.length()) : rel;
  }

  /**
   * A file's id never has the form of a package's id, {@code @org/name@N} (spec §13.3,
   * "Identity"): an id that starts with {@code @} (from a project's name or an entry file's name)
   * gets {@code ./} in front.
   */
  static String fileId(String id) {
    return id.startsWith("@") ? "./" + id : id;
  }

  private static String join(String dir, String name) {
    return Paths.get(dir, name).toString();
  }

  private static String parent(String path) {
    Path p = Paths.get(path).getParent();
    return p == null ? path : p.toString();
  }

  private static String fileName(String path) {
    Path name = Paths.get(path).getFileName();
    return name == null ? "" : name.toString();
  }

  /**
   * A path for a message, not escaped: relative to the root, {@code /}-separated ({@code
   * billing/common.schema.haus}, {@code ../vendor/x}), so that messages don't show the absolute
   * paths of users' directories; {@code classpath:prefix} for a package of classpath resources in
   * a jar; the path as it is before the root is known.
   */
  String display(String path) {
    String label = labels.get(path);
    if (label != null) {
      return label;
    }
    if (root != null) {
      try {
        Path p = Paths.get(path);
        if (p.isAbsolute()) {
          String rel = Paths.get(root).relativize(p).toString().replace(java.io.File.separatorChar, '/');
          return rel.isEmpty() ? "." : rel;
        }
      } catch (IllegalArgumentException e) {
        // On another drive (Windows), or no path: as it is.
      }
    }
    return path;
  }

  /** {@link #display} escaped, for a message. */
  String show(String path) {
    return shown(display(path));
  }

  /** The directory of a schema file, for a message: the package's, for a package's schema.haus. */
  String showDirOf(String schemaPath) {
    FoundPackage pkg = packageSchemas.get(schemaPath);
    return show(pkg != null ? pkg.dir : parent(schemaPath));
  }

  /**
   * A path for a message, as given, with its control and bidirectional characters escaped (spec
   * §9).
   */
  static String shown(String path) {
    StringBuilder b = null;
    for (int i = 0; i < path.length(); ) {
      int cp = path.codePointAt(i);
      int next = i + Character.charCount(cp);
      boolean escape = Scan.needsEscape(cp) || cp == 0x61C || cp == 0x200E || cp == 0x200F;
      if (escape && b == null) {
        b = new StringBuilder(path.length() + 16).append(path, 0, i);
      }
      if (escape) {
        Quoting.appendUnicodeEscape(b, cp);
      } else if (b != null) {
        b.append(path, i, next);
      }
      i = next;
    }
    return b == null ? path : b.toString();
  }

  /**
   * Why a file operation failed, for a message: the system's reason, without the path (which the
   * message shows escaped).
   */
  static String describe(IOException e) {
    if (e instanceof NoSuchFileException) {
      return "no such file or directory";
    }
    if (e instanceof AccessDeniedException) {
      return "permission denied";
    }
    if (e instanceof NotDirectoryException) {
      return "not a directory";
    }
    if (e instanceof FileSystemLoopException) {
      return "too many levels of symbolic links";
    }
    if (e instanceof FileSystemException f && f.getReason() != null) {
      return f.getReason();
    }
    return "it can't be read";
  }

  // ── errors ──

  private static HausException notFound(String why) {
    return HausException.of(ErrorCode.IMPORT_NOT_FOUND, why);
  }

  private static HausException outsideRoot(String why) {
    return HausException.of(ErrorCode.IMPORT_OUTSIDE_ROOT, why);
  }

  /** file-too-large, of the file {@code shown} (escaped). */
  private static HausException tooLarge(String shown, long size) {
    return HausException.of(ErrorCode.FILE_TOO_LARGE, shown + " has " + size + " bytes, more than 1 MiB; it is not read");
  }

  /** {@link #inFile(HausException, String)} with the entry file, relative to the root. */
  HausException inFile(HausException e) {
    return entry == null ? e : inFile(e, entry);
  }

  /**
   * The error in the file at path (as messages show it), for an error of the root file.
   * HausException has no file of its own: an error at a place in the text gets the shown path in
   * front of its reason ({@code 3:5: app.schema.haus: reason}); an error without a place is
   * returned as it is, as every such error of these files names its file already. Idempotent.
   */
  static HausException inFile(HausException e, String path) {
    String prefix = shown(path) + ": ";
    if (e.line() == 0 || e.reason().startsWith(prefix)) {
      return e;
    }
    return new HausException(e.code(), prefix + e.reason(), e.line(), e.column(), e.path(), e.expected(), e.found());
  }

  /** {@code duplicate-package}: two packages with one name, shown relative to the root. */
  HausException duplicate(FoundPackage a, FoundPackage b) {
    return duplicate(a.manifest, display(a.dir), b.manifest, display(b.dir));
  }

  /** {@code duplicate-package}: two packages with one name, in the directories shown (not escaped yet). */
  static HausException duplicate(Manifest a, String aDir, Manifest b, String bDir) {
    String copies = a.version().equals(b.version())
        ? " (two copies of " + Quoting.forMessage(a.version()) + " whose files or imports differ)"
        : "";
    return HausException.of(ErrorCode.DUPLICATE_PACKAGE, "two packages are called " + Quoting.forMessage(a.name()) + ": "
        + Quoting.forMessage(a.version()) + " in " + shown(aDir) + " and " + Quoting.forMessage(b.version()) + " in "
        + shown(bDir) + copies);
  }
}
