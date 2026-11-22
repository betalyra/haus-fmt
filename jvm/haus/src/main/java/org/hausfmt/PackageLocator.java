package org.hausfmt;

import java.util.Objects;

/**
 * Finds the packages a schema imports by name (spec §13.3): the directory of the package an
 * import names. Everything else is the same wherever a package is found and is checked when a
 * schema is loaded: the manifest, its name and version, the {@code @major} of the import, one
 * package per name, cycles and ids.
 *
 * <p>The locators are {@link #none()}, which finds no packages (a schema that imports one fails
 * with the code {@code import-unavailable}), {@link ExplicitPackages}, the packages given
 * explicitly (directories, folders of them, or classpath resources), and {@link #or}, which
 * combines two. This binding doesn't read {@code node_modules}, and MUST NOT (§13.3: only
 * implementations of the npm ecosystem do): the JVM's packages are given explicitly.
 */
public abstract sealed class PackageLocator permits ExplicitPackages, PackageLocator.None, PackageLocator.Or {
  PackageLocator() {}

  /** The locator of a schema that imports no packages: an import of one is {@code import-unavailable}. */
  public static PackageLocator none() {
    return None.INSTANCE;
  }

  /** An empty set of packages given explicitly, to add to with {@link ExplicitPackages#packageDir}. */
  public static ExplicitPackages explicit() {
    return ExplicitPackages.EMPTY;
  }

  /**
   * A locator that tries {@code first}, then {@code second} for the packages {@code first} doesn't
   * find. A package {@code first} found by scanning a folder doesn't replace one {@code second}
   * finds: their files must be the same, or the schema has two packages with one name.
   */
  public static PackageLocator or(PackageLocator first, PackageLocator second) {
    return new Or(Objects.requireNonNull(first, "first"), Objects.requireNonNull(second, "second"));
  }

  /**
   * Finds the package {@code name} ({@code @org/name}, without {@code @major}) for the file at
   * {@code from} (its real path; null for a schema given as text). A package that isn't there is
   * {@code import-not-found}, saying where it was looked for; {@link #or} then tries the next
   * locator.
   */
  abstract Location locate(String name, String from, SchemaFiles files);

  /**
   * A package directory a locator found. {@code dir} has {@code package.haus} and {@code
   * schema.haus}. {@code version} is the version the package manager gives the package (the
   * version of npm's package.json), if {@code hasVersion}: the manifest's must be the same
   * ({@code package-version}). {@code scanned} is set for a package found by scanning a folder:
   * it doesn't replace a package the next locator of {@link #or} finds. {@code sameAs} is a
   * package with the same name found by scanning a folder, or null: its files must be the same as
   * this one's ({@code duplicate-package}). {@code resources} is set for a package of classpath
   * resources in a jar, whose files are read from the class loader ({@code dir} is then the URL
   * of its directory).
   */
  record Location(
      String dir, String version, boolean hasVersion, boolean scanned, String sameAs, SchemaFiles.Resources resources) {
    Location withSameAs(String other) {
      return new Location(dir, version, hasVersion, scanned, other, resources);
    }
  }

  /** Finds no packages. */
  static final class None extends PackageLocator {
    static final None INSTANCE = new None();

    private None() {}

    @Override
    Location locate(String name, String from, SchemaFiles files) {
      throw HausException.of(
          ErrorCode.IMPORT_UNAVAILABLE, "no package locator (only std modules and files can be imported here)");
    }
  }

  /** Tries one locator, then another. */
  static final class Or extends PackageLocator {
    private final PackageLocator first;
    private final PackageLocator second;

    Or(PackageLocator first, PackageLocator second) {
      this.first = first;
      this.second = second;
    }

    @Override
    Location locate(String name, String from, SchemaFiles files) {
      Location found;
      try {
        found = first.locate(name, from, files);
      } catch (HausException e) {
        if (e.code() != ErrorCode.IMPORT_NOT_FOUND) {
          throw e;
        }
        try {
          return second.locate(name, from, files);
        } catch (HausException e2) {
          if (e2.code() != ErrorCode.IMPORT_NOT_FOUND) {
            throw e2;
          }
          throw HausException.of(ErrorCode.IMPORT_NOT_FOUND, e.reason() + "; " + e2.reason());
        }
      }
      if (!found.scanned()) {
        return found;
      }
      // A package found in a folder: the other locator's comes first, if it has the same files.
      try {
        return second.locate(name, from, files).withSameAs(found.dir());
      } catch (HausException e) {
        if (e.code() == ErrorCode.IMPORT_NOT_FOUND || e.code() == ErrorCode.UNDECLARED_PACKAGE) {
          return found;
        }
        throw e;
      }
    }
  }
}
