package org.hausfmt;

import java.io.IOException;
import java.net.URISyntaxException;
import java.net.URL;
import java.nio.file.DirectoryIteratorException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.InvalidPathException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Packages given explicitly (spec §13.3): each by its directory ({@link #packageDir}), as
 * classpath resources ({@link #resources}), or the packages in a folder ({@link #folder}). Their
 * manifests name them, whatever the directories are called. They count as declared wherever they
 * are imported. A package given by its directory or as resources comes before other locators for
 * its name ({@link PackageLocator#or}); one found in a folder doesn't: if the next locator finds a
 * package with its name and other files, the schema has two packages with one name.
 *
 * <p>A set is immutable: adding packages returns a new set. Manifests are read and checked when
 * a package is added.
 *
 * <pre>{@code
 * PackageLocator packages = PackageLocator.explicit()
 *     .folder(Path.of("extensions"))
 *     .resources(Orders.class.getClassLoader(), "schemas/orders");
 * }</pre>
 */
public final class ExplicitPackages extends PackageLocator {
  static final ExplicitPackages EMPTY = new ExplicitPackages(Map.of(), List.of());

  /**
   * A package given: its manifest, its real path (for resources in a jar, the URL of its
   * directory, and {@code resources} set), whether it was found in a folder, and how messages
   * name it (as the application gave it).
   */
  private record Given(Manifest manifest, String dir, boolean scanned, SchemaFiles.Resources resources, String shown) {}

  /** A subdirectory of a folder whose manifest couldn't be read: named when an import isn't found. */
  private record Unreadable(String dir, String why) {}

  /** The packages by name. */
  private final Map<String, Given> packages;
  private final List<Unreadable> unreadable;

  private ExplicitPackages(Map<String, Given> packages, List<Unreadable> unreadable) {
    this.packages = packages;
    this.unreadable = unreadable;
  }

  /**
   * The set with the package in {@code dir} added. Its manifest is read and checked now: a
   * directory without one is {@code import-not-found}, an invalid one {@code package-manifest}.
   * Two packages with one name are {@code duplicate-package}, unless they are copies (the same
   * {@code package.haus} and {@code schema.haus}).
   *
   * @throws HausException if the package can't be added
   */
  public ExplicitPackages packageDir(Path dir) {
    return packageDir(dir.toString(), dir.toString());
  }

  private ExplicitPackages packageDir(String dir, String shown) {
    String resolved;
    try {
      resolved = SchemaFiles.realPath(dir);
    } catch (IOException e) {
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, SchemaFiles.shown(shown) + ": " + SchemaFiles.describe(e));
    }
    Manifest m = SchemaFiles.readManifest(resolved, shown);
    Builder b = new Builder(this);
    b.add(new Given(m, resolved, false, null, shown));
    return b.build();
  }

  /**
   * The set with the package whose files are the classpath resources {@code prefix/package.haus},
   * {@code prefix/schema.haus} and, if there, {@code prefix/package.json} of {@code loader} added
   * (spec §13.3: a package given explicitly may be a read-only file tree given by code), such as
   * a schema package published inside a library's jar. The same rules hold as for a directory:
   * the manifest is read and checked now, the files are regular files spelled exactly, within
   * their limits, and the version of a {@code package.json} is checked. A resource that is a file
   * on disk (a class loader over a directory) is read as that directory, never through a link at
   * its last name; a jar holds no links.
   *
   * @param prefix the resources' directory, {@code /}-separated, without a leading or trailing
   *     {@code /} ({@code schemas/orders}); empty for the class loader's root
   * @throws HausException if the package can't be added: no {@code package.haus} is {@code
   *     import-not-found}, an invalid one {@code package-manifest}
   */
  public ExplicitPackages resources(ClassLoader loader, String prefix) {
    Objects.requireNonNull(loader, "loader");
    String p = Objects.requireNonNull(prefix, "prefix");
    while (p.startsWith("/")) {
      p = p.substring(1);
    }
    while (p.endsWith("/")) {
      p = p.substring(0, p.length() - 1);
    }
    SchemaFiles.Resources res = new SchemaFiles.Resources(loader, p);
    URL manifest = res.url(SchemaFiles.MANIFEST_FILE);
    URL dir = manifest != null ? manifest : loader.getResource(p);
    if (dir == null) {
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND,
          SchemaFiles.shown(res.label()) + " is not a schema package: it has no " + SchemaFiles.MANIFEST_FILE);
    }
    if (dir.getProtocol().equals("file")) {
      Path path;
      try {
        path = Paths.get(dir.toURI());
      } catch (URISyntaxException | IllegalArgumentException e) {
        throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, SchemaFiles.shown(res.label()) + ": it can't be read");
      }
      return packageDir((manifest != null ? path.getParent() : path).toString(), res.label());
    }
    if (manifest == null) {
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND,
          SchemaFiles.shown(res.label()) + " is not a schema package: it has no " + SchemaFiles.MANIFEST_FILE);
    }
    Manifest m = SchemaFiles.readManifest(res);
    Builder b = new Builder(this);
    b.add(new Given(m, SchemaFiles.Resources.dirOf(manifest), false, res, res.label()));
    return b.build();
  }

  /**
   * The set with the packages in {@code folder} added: its subdirectories (or links to
   * directories) that have a {@code package.haus}, spelled so, not deeper. A folder that can't be
   * read is {@code import-not-found}, one with more than 4096 entries {@code too-many-files}. A
   * subdirectory whose manifest is invalid, or whose {@code package.json} gives another version,
   * is left out; an import that isn't found names it by the last name of the folder's real path
   * and its own ({@code schemas/broken}), however the folder was given.
   *
   * @throws HausException if the folder can't be read, or two packages share a name
   */
  public ExplicitPackages folder(Path folder) {
    String shownFolder = SchemaFiles.shown(folder.toString());
    List<String> dirs = new ArrayList<>();
    int entries = 0;
    Path real;
    try {
      real = Path.of(SchemaFiles.realPath(folder.toString()));
    } catch (IOException e) {
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, shownFolder + ": " + SchemaFiles.describe(e));
    }
    Path realName = real.getFileName();
    try (DirectoryStream<Path> listing = Files.newDirectoryStream(real)) {
      for (Path entry : listing) {
        if (++entries > SchemaFiles.MAX_FOLDER_ENTRIES) {
          throw HausException.of(ErrorCode.TOO_MANY_FILES, shownFolder
              + ": the folder of packages has more than " + SchemaFiles.MAX_FOLDER_ENTRIES + " entries");
        }
        if (SchemaFiles.listed(entry.resolve(SchemaFiles.MANIFEST_FILE).toString())) {
          dirs.add(entry.toString());
        }
      }
    } catch (IOException e) {
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, shownFolder + ": " + SchemaFiles.describe(e));
    } catch (DirectoryIteratorException e) {
      // A listing that fails part way.
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, shownFolder + ": " + SchemaFiles.describe(e.getCause()));
    }
    Collections.sort(dirs);
    Builder b = new Builder(this);
    SchemaFiles files = new SchemaFiles();
    for (String dir : dirs) {
      Path entryName = Path.of(dir).getFileName();
      String named = realName == null ? entryName.toString() : realName.resolve(entryName).toString();
      Manifest m;
      String resolved;
      try {
        resolved = SchemaFiles.realPath(dir);
        m = SchemaFiles.readManifest(resolved, named);
        checkVersion(m, files.lenientVersion(resolved));
      } catch (IOException e) {
        b.unreadable.add(new Unreadable(named, SchemaFiles.describe(e)));
        continue;
      } catch (HausException e) {
        b.unreadable.add(new Unreadable(named, e.reason()));
        continue;
      }
      b.add(new Given(m, resolved, true, null, named));
    }
    return b.build();
  }

  /**
   * The version check of a package found in a folder: a package.json beside its manifest, read
   * leniently, that gives another version is {@code package-version}, and the subdirectory is
   * skipped (spec §13.3).
   */
  private static void checkVersion(Manifest m, SchemaFiles.Version version) {
    if (version.present() && !version.text().equals(m.version())) {
      throw HausException.of(ErrorCode.PACKAGE_VERSION, "the package.haus of " + m.name() + " says version "
          + Quoting.forMessage(m.version()) + ", the package.json next to it " + Quoting.forMessage(version.text()));
    }
  }

  /** A new set, built from a copy of one: each call copies the set once. */
  private static final class Builder {
    final Map<String, Given> packages;
    final List<Unreadable> unreadable;

    Builder(ExplicitPackages from) {
      packages = new LinkedHashMap<>(from.packages);
      unreadable = new ArrayList<>(from.unreadable);
    }

    void add(Given n) {
      Manifest m = n.manifest();
      Given g = packages.get(m.name());
      if (g == null) {
        packages.put(m.name(), n);
      } else if (g.dir().equals(n.dir()) || SchemaFiles.sameFiles(g.dir(), g.resources(), n.dir(), n.resources())) {
        packages.put(m.name(), new Given(g.manifest(), g.dir(), g.scanned() && n.scanned(), g.resources(), g.shown()));
      } else {
        throw SchemaFiles.duplicate(g.manifest(), g.shown(), m, n.shown());
      }
    }

    ExplicitPackages build() {
      return new ExplicitPackages(Collections.unmodifiableMap(packages), Collections.unmodifiableList(unreadable));
    }
  }

  @Override
  Location locate(String name, String from, SchemaFiles files) {
    Given g = packages.get(name);
    if (g != null) {
      SchemaFiles.Version version = g.resources() != null ? files.lenientVersion(g.resources()) : files.lenientVersion(g.dir());
      return new Location(g.dir(), version.text(), version.present(), g.scanned(), null, g.resources());
    }
    StringBuilder why = new StringBuilder("package ").append(name).append(" is not among the packages given");
    if (!unreadable.isEmpty()) {
      why.append(" (packages in the folders given that could not be read: ");
      for (int i = 0; i < unreadable.size(); i++) {
        Unreadable u = unreadable.get(i);
        if (i > 0) {
          why.append(", ");
        }
        why.append(SchemaFiles.shown(u.dir())).append(" (").append(u.why()).append(')');
      }
      why.append(')');
    }
    throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, why.toString());
  }
}
