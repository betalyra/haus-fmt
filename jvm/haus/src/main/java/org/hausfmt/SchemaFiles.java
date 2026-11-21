package org.hausfmt;

import java.io.IOException;
import java.io.InputStream;
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
import java.util.Map;
import java.util.Set;
import java.util.function.Supplier;

/**
 * Reading the files a schema imports (spec §13.3), the same wherever a package is found: a {@link
 * PackageLocator} says where a package is, and the rules here say whether it may be read.
 * Resolution happens when a schema is loaded, never while data is parsed, and never over the
 * network (§9).
 *
 * <p>A package's {@code package.haus}, {@code schema.haus} and {@code package.json} are opened
 * without following links ({@link LinkOption#NOFOLLOW_LINKS}, O_NOFOLLOW on Unix). Their type is
 * checked before the open (Java can't ask an open channel for it), so that a FIFO never blocks
 * the open; their size is checked on the opened channel, and they are read from it, at most one
 * byte past the limit, so the file whose size is checked is the file read.
 *
 * <p>An instance is the files one schema reads, each once, by real path: a file needed in two
 * roles (a package.json that is a link to a schema file) is read once, and every use sees the
 * same bytes. Each use keeps its own checks: a package's files are never read through a link,
 * and each kind of file has its own size limit.
 *
 * <p>Paths are strings: real paths (absolute, every link resolved) where the comments say so, and
 * paths in messages as the platform writes them, with control and bidirectional characters
 * escaped ({@link #shown}).
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

  private static final LinkOption[] FOLLOW = {};
  private static final LinkOption[] NOFOLLOW = {LinkOption.NOFOLLOW_LINKS};
  private static final Set<OpenOption> READ = Set.of(StandardOpenOption.READ);
  private static final Set<OpenOption> READ_NOFOLLOW = Set.of(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS);

  /** Which file is read, and so how. */
  private enum Kind {
    /** A package's package.haus: never through a link, at most 64 KiB. */
    MANIFEST(false, MAX_MANIFEST),
    /** A package's schema.haus: never through a link. */
    PACKAGE_SCHEMA(false, MAX_FILE),
    /** A package's package.json: never through a link. */
    PACKAGE_JSON(false, MAX_FILE),
    /** A schema file outside packages, read at its real path. */
    SCHEMA(true, MAX_FILE);

    final boolean followsLinks;
    final int limit;

    Kind(boolean followsLinks, int limit) {
      this.followsLinks = followsLinks;
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

    /** The file read for one use, as another use with its own limit sees it. */
    Opened within(Kind kind) {
      return state == State.OPENED && bytes.length > kind.limit ? tooLarge(bytes.length) : this;
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
    /** Its real path. */
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

  /** The files read, by real path. */
  private final Map<String, Opened> opened = new HashMap<>();
  /** The package.json files parsed, by real path; null for one that isn't JSON. */
  private final Map<String, Value> json = new HashMap<>();

  /** A cache for one schema: each file is read at most once, by its real path. */
  SchemaFiles() {}

  // ── reading files ──

  /**
   * Opens the file at path, following a link or not, and reads it: a regular file of at most
   * {@code limit} bytes, whose size is checked on the opened channel.
   */
  private static Opened readFile(String path, boolean follow, int limit) {
    Path p;
    try {
      p = Paths.get(path);
    } catch (InvalidPathException e) {
      return Opened.MISSING;
    }
    BasicFileAttributes before;
    try {
      before = Files.readAttributes(p, BasicFileAttributes.class, follow ? FOLLOW : NOFOLLOW);
    } catch (IOException e) {
      return failedOpen(p, e);
    }
    // Checked before the open, which would block on a FIFO.
    if (!before.isRegularFile()) {
      return Opened.NOT_REGULAR;
    }
    try (SeekableByteChannel channel = Files.newByteChannel(p, follow ? READ : READ_NOFOLLOW)) {
      long size = channel.size();
      if (size > limit) {
        return Opened.tooLarge(size);
      }
      InputStream in = Channels.newInputStream(channel);
      byte[] bytes = in.readNBytes(limit + 1);
      if (bytes.length > limit) {
        return Opened.tooLarge(bytes.length);
      }
      return new Opened(State.OPENED, bytes, bytes.length, null);
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
      // A link to nothing, when followed, is not a regular file either.
      return Opened.NOT_REGULAR;
    }
    return e instanceof NoSuchFileException ? Opened.MISSING : Opened.failed(describe(e));
  }

  /** The cached read of the file at path, for a use of the kind, and the real path it is cached by. */
  private record Keyed(String key, Opened file) {}

  /** Reads the file at path as {@code kind} says, once per real path. */
  private Keyed open(String path, Kind kind) {
    if (!kind.followsLinks) {
      try {
        if (Files.readAttributes(Paths.get(path), BasicFileAttributes.class, NOFOLLOW).isSymbolicLink()) {
          return new Keyed(path, Opened.NOT_REGULAR);
        }
      } catch (NoSuchFileException | InvalidPathException e) {
        return new Keyed(path, Opened.MISSING);
      } catch (IOException e) {
        // Read below, which says why it fails.
      }
    }
    String key;
    try {
      key = realPath(path);
    } catch (IOException e) {
      key = path;
    }
    Opened r = opened.get(key);
    if (r == null) {
      r = readFile(path, kind.followsLinks, Math.max(MAX_FILE, MAX_MANIFEST));
      opened.put(key, r);
    }
    return new Keyed(key, r.within(kind));
  }

  /**
   * The version the package.json in the package directory dir (a real path) gives, if there is
   * one. One that isn't valid JSON gives none. A package.json that is a link or not a regular file
   * is {@code package-path}, one over 1 MiB {@code file-too-large}.
   */
  Version npmVersion(String dir) {
    String path = join(dir, PACKAGE_JSON);
    Keyed k = open(path, Kind.PACKAGE_JSON);
    Opened r = k.file();
    switch (r.state()) {
      case MISSING:
        return Version.NONE;
      case NOT_REGULAR:
        throw HausException.of(ErrorCode.PACKAGE_PATH, shown(path) + " is a symbolic link or not a regular file; it is not read");
      case TOO_LARGE:
        throw tooLarge(path, r.size());
      case FAILED:
        throw notFound(shown(path) + ": " + r.why());
      default:
        break;
    }
    Value doc;
    if (json.containsKey(k.key())) {
      doc = json.get(k.key());
    } else {
      // The core's JSON import: a package.json that it rejects (not UTF-8, not JSON, a key twice)
      // declares nothing and gives no version.
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

  /** Reads and checks the manifest of the package in dir (a real path). */
  private FoundPackage manifest(String dir) {
    return manifestOf(dir, open(join(dir, MANIFEST_FILE), Kind.MANIFEST).file());
  }

  /** Checks the manifest at dir/package.haus, opened. */
  private static FoundPackage manifestOf(String dir, Opened r) {
    String path = join(dir, MANIFEST_FILE);
    switch (r.state()) {
      case MISSING:
        throw notFound(shown(dir) + " is not a schema package: it has no " + MANIFEST_FILE);
      case NOT_REGULAR:
        throw HausException.of(ErrorCode.PACKAGE_PATH,
            "the manifest " + shown(path) + " is a symbolic link or not a regular file; it is not read");
      case TOO_LARGE:
        throw invalidManifest(path, "the manifest has " + r.size() + " bytes, more than 64 KiB");
      case FAILED:
        throw notFound(shown(path) + ": " + r.why());
      default:
        break;
    }
    byte[] bytes = r.bytes();
    if (Scan.invalidUtf8(bytes, 0, bytes.length) < bytes.length) {
      throw invalidManifest(path, "the manifest is not UTF-8");
    }
    Manifest m;
    try {
      m = Manifest.parse(bytes);
    } catch (HausException e) {
      throw invalidManifest(path, e.reason());
    }
    return new FoundPackage(m, dir, new String(bytes, StandardCharsets.UTF_8));
  }

  /** package-manifest, in the manifest at path (Go's File: in front of the reason here). */
  private static HausException invalidManifest(String path, String why) {
    return HausException.of(ErrorCode.PACKAGE_MANIFEST, shown(path) + ": " + why);
  }

  /** Reads the manifest of the package in dir (a real path) on its own, outside any schema's cache. */
  static Manifest readManifest(String dir) {
    return manifestOf(dir, readFile(join(dir, MANIFEST_FILE), false, MAX_MANIFEST)).manifest;
  }

  /**
   * Reads a schema file: a package's schema.haus, or a file outside packages at its real path.
   * {@code missingWhy} says why a missing one is missing.
   */
  private String schemaText(String path, Kind kind, Supplier<String> missingWhy) {
    Opened r = open(path, kind).file();
    switch (r.state()) {
      case OPENED:
        return text(r.bytes());
      case MISSING:
        throw notFound(missingWhy.get());
      case NOT_REGULAR:
        if (kind == Kind.PACKAGE_SCHEMA) {
          throw HausException.of(ErrorCode.PACKAGE_PATH, shown(path) + " is a symbolic link or not a regular file; it is not read");
        }
        throw notFound(shown(path) + " is not a regular file");
      case TOO_LARGE:
        throw tooLarge(path, r.size());
      default:
        throw notFound(shown(path) + ": " + r.why());
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
    Source src = openPackage(loc.dir(), name, loc.version(), loc.hasVersion());
    if (loc.sameAs() != null) {
      Source other = openPackage(loc.sameAs(), name, null, false);
      FoundPackage a = src.pkg;
      FoundPackage b = other.pkg;
      if (!a.dir.equals(b.dir) && (!a.manifestText.equals(b.manifestText) || !src.text.equals(other.text))) {
        throw duplicate(a.manifest, a.dir, b.manifest, b.dir);
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
      throw notFound(shown(dir) + ": " + describe(e));
    }
    FoundPackage pkg = manifest(resolved);
    Manifest m = pkg.manifest;
    if (!m.name().equals(name)) {
      throw notFound(shown(join(resolved, MANIFEST_FILE)) + " names the package " + Quoting.forMessage(m.name())
          + ", not " + name);
    }
    if (hasVersion && !version.equals(m.version())) {
      // Text from package.json is quoted only if it is a version (spec §9).
      String given = Manifest.isSemver(version)
          ? "its package manager " + Quoting.forMessage(version)
          : "and the version its package manager gives isn't a semantic version";
      throw HausException.of(ErrorCode.PACKAGE_VERSION, "the package.haus of " + name + " says version "
          + Quoting.forMessage(m.version()) + ", " + given + " (" + shown(resolved) + ")");
    }
    String path = join(resolved, SCHEMA_FILE);
    String schema = schemaText(path, Kind.PACKAGE_SCHEMA,
        () -> name + " has no " + SCHEMA_FILE + " next to its manifest (" + shown(resolved) + ")");
    return new Source(path, schema, pkg);
  }

  /**
   * Reads the file module ({@code ./common}, {@code ../shared/money}) imports, next to the file at
   * from (a real path; null for a schema given as text, which imports no files). A package imports
   * no files, and a file outside a package no file inside one ({@code package-path}). Each name in
   * the path is spelled as its directory lists it, and the file's real path ends in {@code
   * .schema.haus} ({@code import-not-found}, the file not read).
   */
  Source openRelative(String module, String from) {
    if (from == null) {
      throw HausException.of(ErrorCode.IMPORT_UNAVAILABLE, "a schema read from text imports no files (load it from its file)");
    }
    String pkg = packageDirOf(from);
    if (pkg != null) {
      String name = shown(pkg);
      try {
        name = manifest(pkg).manifest.name();
      } catch (HausException e) {
        // Named by its directory.
      }
      throw HausException.of(ErrorCode.PACKAGE_PATH, "the schema of " + name + " can't import files, only packages by name");
    }
    String dir = parent(from);
    String relative = module + EXTENSION;
    String path;
    try {
      path = Paths.get(dir).resolve(relative).normalize().toString();
    } catch (InvalidPathException e) {
      throw notFound("file not found: " + shown(dir) + "/" + shown(relative));
    }
    String wrong = misspelled(dir, relative);
    if (wrong != null) {
      throw notFound("file not found: " + shown(path) + " (no " + Quoting.forMessage(wrong)
          + " in its directory: names are spelled as the directory lists them)");
    }
    String resolved;
    try {
      resolved = realPath(path);
    } catch (IOException e) {
      resolved = null;
    }
    String into = resolved == null ? null : packageDirOf(resolved);
    if (into == null) {
      into = packageDirOf(path);
    }
    if (into != null) {
      throw HausException.of(ErrorCode.PACKAGE_PATH, "the file is in the package directory " + shown(into)
          + ": import the package by its name");
    }
    if (resolved == null) {
      throw notFound("file not found: " + shown(path));
    }
    if (!fileName(resolved).endsWith(EXTENSION)) {
      throw notFound(shown(path) + " is not a schema file: its real path " + shown(resolved) + " doesn't end in "
          + EXTENSION + "; it is not read");
    }
    String text = schemaText(resolved, Kind.SCHEMA, () -> "file not found: " + shown(path));
    return new Source(resolved, text, null);
  }

  /**
   * The first name in relative (from dir) that its directory doesn't list char for char, or null:
   * on file systems that ignore case or Unicode normalization, ./Billing/common finds
   * billing/common.schema.haus.
   */
  private static String misspelled(String dir, String relative) {
    Path at = Paths.get(dir);
    for (String part : relative.split("/", -1)) {
      if (part.isEmpty() || part.equals(".")) {
        continue;
      }
      if (part.equals("..")) {
        at = at.resolve("..").normalize();
        continue;
      }
      boolean listed = false;
      try (DirectoryStream<Path> entries = Files.newDirectoryStream(at)) {
        for (Path e : entries) {
          if (e.getFileName().toString().equals(part)) {
            listed = true;
            break;
          }
        }
      } catch (IOException | DirectoryIteratorException e) {
        // A directory that can't be listed: the file isn't found later.
        return null;
      }
      if (!listed) {
        return part;
      }
      at = at.resolve(part);
    }
    return null;
  }

  /**
   * Reads the root schema file at path: {@code {real path, text}}. A package's schema.haus is read
   * as one (never through a link).
   */
  String[] rootSource(String path) {
    String resolved;
    try {
      resolved = realPath(path);
    } catch (IOException e) {
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, shown(path) + ": " + describe(e));
    }
    Kind kind = isPackageSchema(resolved) ? Kind.PACKAGE_SCHEMA : Kind.SCHEMA;
    try {
      return new String[] {resolved, schemaText(resolved, kind, () -> "file not found: " + shown(path))};
    } catch (HausException e) {
      throw inFile(e, path);
    }
  }

  /** Whether the file at path is a package's schema.haus: next to a package.haus. */
  private static boolean isPackageSchema(String path) {
    return fileName(path).equals(SCHEMA_FILE) && exists(join(parent(path), MANIFEST_FILE));
  }

  /**
   * The package whose schema.haus is the file at path (a real path), with its manifest checked,
   * or null if the file is no package's schema.haus.
   */
  FoundPackage packageOfFile(String path) {
    return isPackageSchema(path) ? manifest(parent(path)) : null;
  }

  /** The package directory a file is in: the nearest directory above it with a manifest, or null. */
  private static String packageDirOf(String path) {
    for (Path d = Paths.get(path).getParent(); d != null; d = d.getParent()) {
      if (exists(d.resolve(MANIFEST_FILE).toString())) {
        return d.toString();
      }
    }
    return null;
  }

  /**
   * Whether the packages in a and b are copies of one package: their manifests and schema files
   * are the same, byte for byte, and regular files (spec §13.3). Read outside any schema's cache,
   * when packages are given.
   */
  static boolean sameFiles(String a, String b) {
    Opened am = readFile(join(a, MANIFEST_FILE), false, MAX_MANIFEST);
    Opened as = readFile(join(a, SCHEMA_FILE), false, MAX_FILE);
    if (am.state() != State.OPENED || as.state() != State.OPENED) {
      return false;
    }
    Opened bm = readFile(join(b, MANIFEST_FILE), false, MAX_MANIFEST);
    Opened bs = readFile(join(b, SCHEMA_FILE), false, MAX_FILE);
    return bm.state() == State.OPENED && bs.state() == State.OPENED
        && Arrays.equals(am.bytes(), bm.bytes()) && Arrays.equals(as.bytes(), bs.bytes());
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
   * A path for a message, as the platform writes it, with its control and bidirectional
   * characters escaped (spec §9).
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

  private static HausException tooLarge(String path, long size) {
    return HausException.of(ErrorCode.FILE_TOO_LARGE, shown(path) + " has " + size + " bytes, more than 1 MiB; it is not read");
  }

  /**
   * The error in the file at path, for an error of the root file. HausException has no file of
   * its own: an error at a place in the text gets the shown path in front of its reason ({@code
   * 3:5: /app/app.schema.haus: reason}); an error without a place is returned as it is, as every
   * such error of these files names its file already. Idempotent.
   */
  static HausException inFile(HausException e, String path) {
    String prefix = shown(path) + ": ";
    if (e.line() == 0 || e.reason().startsWith(prefix)) {
      return e;
    }
    return new HausException(e.code(), prefix + e.reason(), e.line(), e.column(), e.path(), e.expected(), e.found());
  }

  /** {@code duplicate-package}: two packages with one name. */
  static HausException duplicate(Manifest a, String aDir, Manifest b, String bDir) {
    String copies = a.version().equals(b.version())
        ? " (two copies of " + Quoting.forMessage(a.version()) + " whose files or imports differ)"
        : "";
    return HausException.of(ErrorCode.DUPLICATE_PACKAGE, "two packages are called " + Quoting.forMessage(a.name()) + ": "
        + Quoting.forMessage(a.version()) + " in " + shown(aDir) + " and " + Quoting.forMessage(b.version()) + " in "
        + shown(bDir) + copies);
  }
}
