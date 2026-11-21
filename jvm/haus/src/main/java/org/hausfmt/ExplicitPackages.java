package org.hausfmt;

import java.io.IOException;
import java.nio.file.DirectoryIteratorException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Packages given explicitly (spec §13.3): each by its directory ({@link #packageDir}), or the
 * packages in a folder ({@link #folder}). Their manifests name them, whatever the directories are
 * called. They count as declared wherever they are imported. A package given by its directory
 * comes before other locators for its name ({@link PackageLocator#or}); one found in a folder
 * doesn't: if the next locator finds a package with its name and other files, the schema has two
 * packages with one name.
 *
 * <p>A set is immutable: adding packages returns a new set. Manifests are read and checked when
 * a package is added.
 *
 * <pre>{@code
 * PackageLocator packages = PackageLocator.explicit().folder(Path.of("extensions"));
 * }</pre>
 */
public final class ExplicitPackages extends PackageLocator {
  static final ExplicitPackages EMPTY = new ExplicitPackages(Map.of(), List.of());

  /** A package given: its manifest, its real path, and whether it was found in a folder. */
  private record Given(Manifest manifest, String dir, boolean scanned) {}

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
    String shown = dir.toString();
    String resolved;
    try {
      resolved = SchemaFiles.realPath(shown);
    } catch (IOException e) {
      throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, SchemaFiles.shown(shown) + ": " + SchemaFiles.describe(e));
    }
    Manifest m = SchemaFiles.readManifest(resolved);
    Builder b = new Builder(this);
    b.add(m, resolved, false);
    return b.build();
  }

  /**
   * The set with the packages in {@code folder} added: its subdirectories (or links to
   * directories) that have a {@code package.haus}, not deeper. A folder that can't be read is
   * {@code import-not-found}, one with more than 4096 entries {@code too-many-files}. A
   * subdirectory whose manifest is invalid is left out; an import that isn't found names it.
   *
   * @throws HausException if the folder can't be read, or two packages share a name
   */
  public ExplicitPackages folder(Path folder) {
    String shownFolder = SchemaFiles.shown(folder.toString());
    List<String> dirs = new ArrayList<>();
    int entries = 0;
    try (DirectoryStream<Path> listing = Files.newDirectoryStream(folder)) {
      for (Path entry : listing) {
        if (++entries > SchemaFiles.MAX_FOLDER_ENTRIES) {
          throw HausException.of(ErrorCode.TOO_MANY_FILES, shownFolder
              + ": the folder of packages has more than " + SchemaFiles.MAX_FOLDER_ENTRIES + " entries");
        }
        if (SchemaFiles.exists(entry.resolve(SchemaFiles.MANIFEST_FILE).toString())) {
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
    for (String dir : dirs) {
      Manifest m;
      String resolved;
      try {
        resolved = SchemaFiles.realPath(dir);
        m = SchemaFiles.readManifest(resolved);
      } catch (IOException e) {
        b.unreadable.add(new Unreadable(dir, SchemaFiles.describe(e)));
        continue;
      } catch (HausException e) {
        b.unreadable.add(new Unreadable(dir, e.reason()));
        continue;
      }
      b.add(m, resolved, true);
    }
    return b.build();
  }

  /** A new set, built from a copy of one: each call copies the set once. */
  private static final class Builder {
    final Map<String, Given> packages;
    final List<Unreadable> unreadable;

    Builder(ExplicitPackages from) {
      packages = new LinkedHashMap<>(from.packages);
      unreadable = new ArrayList<>(from.unreadable);
    }

    void add(Manifest m, String dir, boolean scanned) {
      Given g = packages.get(m.name());
      if (g == null) {
        packages.put(m.name(), new Given(m, dir, scanned));
      } else if (g.dir().equals(dir) || SchemaFiles.sameFiles(g.dir(), dir)) {
        packages.put(m.name(), new Given(g.manifest(), g.dir(), g.scanned() && scanned));
      } else {
        throw SchemaFiles.duplicate(g.manifest(), g.dir(), m, dir);
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
      SchemaFiles.Version version = files.npmVersion(g.dir());
      return new Location(g.dir(), version.text(), version.present(), g.scanned(), null);
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
