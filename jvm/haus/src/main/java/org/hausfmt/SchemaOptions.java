package org.hausfmt;

/**
 * How a schema is loaded ({@link Schema#load}, {@link Schema#parse}).
 *
 * @param packages finds the packages imports name (spec §13.3): {@link PackageLocator#explicit()},
 *     or null for none (a schema that imports a package fails with {@code import-unavailable})
 * @param id the root file's id, for the ids of its types ({@code shop/order} gives {@code
 *     shop/order#Order}); null: from its manifest for a package's schema.haus, else from the path
 * @param project with {@code projectDir}, the ids of files outside packages: project {@code shop}
 *     and directory {@code dir} give {@code dir/src/common.schema.haus} the id {@code
 *     shop/src/common}; null: the path from the root file's directory. A file's id never has the
 *     form of a package's, {@code @org/name@N}: one that would start with {@code @} gets {@code
 *     ./} in front
 * @param projectDir the directory of {@code project}
 * @param withoutAttributes leaves out the attributes of every file, as if they weren't written:
 *     decoding is the same (spec §15); for tests of that
 * @param root the build's root directory (spec §13.3, "The root"), which relative imports stay
 *     inside ({@code import-outside-root}): a directory that contains the file {@link Schema#load}
 *     starts from, such as a repository's schema directory whose files share files across folders
 *     (one that doesn't contain it is {@code import-outside-root}); a relative one is from the
 *     directory of that file's real path, and it is resolved to its real path once; null: that
 *     directory
 */
public record SchemaOptions(
    PackageLocator packages, String id, String project, String projectDir, boolean withoutAttributes, String root) {
  /** No packages, the default ids, with attributes, the default root. */
  public static final SchemaOptions DEFAULT = new SchemaOptions(null, null, null, null, false, null);

  /** These options with the package locator. */
  public SchemaOptions withPackages(PackageLocator value) {
    return new SchemaOptions(value, id, project, projectDir, withoutAttributes, root);
  }

  /** These options with the root file's id. */
  public SchemaOptions withId(String value) {
    return new SchemaOptions(packages, value, project, projectDir, withoutAttributes, root);
  }

  /** These options with the project that names files outside packages, and its directory. */
  public SchemaOptions withProject(String name, String dir) {
    return new SchemaOptions(packages, id, name, dir, withoutAttributes, root);
  }

  /** These options, leaving out (or not) every attribute. */
  public SchemaOptions withoutAttributes(boolean value) {
    return new SchemaOptions(packages, id, project, projectDir, value, root);
  }

  /** These options with the build's root directory (null: the entry file's directory). */
  public SchemaOptions withRoot(java.nio.file.Path value) {
    return new SchemaOptions(packages, id, project, projectDir, withoutAttributes, value == null ? null : value.toString());
  }
}
