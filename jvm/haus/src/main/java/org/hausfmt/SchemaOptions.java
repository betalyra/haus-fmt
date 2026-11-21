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
 *     shop/src/common}; null: the path from the root file's directory
 * @param projectDir the directory of {@code project}
 * @param withoutAttributes leaves out the attributes of every file, as if they weren't written:
 *     decoding is the same (spec §15); for tests of that
 */
public record SchemaOptions(
    PackageLocator packages, String id, String project, String projectDir, boolean withoutAttributes) {
  /** No packages, the default ids, with attributes. */
  public static final SchemaOptions DEFAULT = new SchemaOptions(null, null, null, null, false);

  /** These options with the package locator. */
  public SchemaOptions withPackages(PackageLocator value) {
    return new SchemaOptions(value, id, project, projectDir, withoutAttributes);
  }

  /** These options with the root file's id. */
  public SchemaOptions withId(String value) {
    return new SchemaOptions(packages, value, project, projectDir, withoutAttributes);
  }

  /** These options with the project that names files outside packages, and its directory. */
  public SchemaOptions withProject(String name, String dir) {
    return new SchemaOptions(packages, id, name, dir, withoutAttributes);
  }

  /** These options, leaving out (or not) every attribute. */
  public SchemaOptions withoutAttributes(boolean value) {
    return new SchemaOptions(packages, id, project, projectDir, value);
  }
}
