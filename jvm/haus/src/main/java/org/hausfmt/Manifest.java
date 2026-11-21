package org.hausfmt;

import java.util.List;

/**
 * A schema package's manifest, its {@code package.haus} (spec §13.3): {@code { name:
 * "@haus-fmt/money", version: "1.2.0" }}. Other fields are ignored, so later versions can add
 * some.
 */
public final class Manifest {
  /** The longest package name (npm's limit). */
  private static final int MAX_NAME = 214;

  private final String name;
  private final String version;

  private Manifest(String name, String version) {
    this.name = name;
    this.version = version;
  }

  /** The package's name, such as {@code @haus-fmt/money}. */
  public String name() {
    return name;
  }

  /** The package's version, a semantic version such as {@code 1.2.0}. */
  public String version() {
    return version;
  }

  /** The major version: {@code 1} for {@code 1.2.0}. */
  public String major() {
    int dot = version.indexOf('.');
    return dot < 0 ? version : version.substring(0, dot);
  }

  /** The package's id (spec §13.3): {@code @haus-fmt/money@1}. */
  public String id() {
    return name + "@" + major();
  }

  /**
   * Reads a manifest: one record with a string {@code name} that is a package name ({@code
   * @org/name} in lowercase) and a string {@code version} that is a semantic version, in at most
   * 64 KiB.
   *
   * @throws HausException with the code {@code package-manifest}
   */
  public static Manifest parse(byte[] text) {
    if (text.length > SchemaFiles.MAX_MANIFEST) {
      throw invalid("the manifest has " + text.length + " bytes, more than 64 KiB");
    }
    List<Value> values;
    try {
      values = Haus.parseAll(text);
    } catch (HausException e) {
      throw invalid("the manifest is not valid haus: " + e.getMessage());
    }
    if (values.size() != 1 || !(values.get(0) instanceof Value.Record)) {
      throw invalid("a manifest is one record: { name: \"@org/name\", version: \"1.0.0\" }");
    }
    Value.Record rec = (Value.Record) values.get(0);
    if (!(rec.get("name") instanceof Value.Text name)) {
      throw invalid("the manifest needs a string field name");
    }
    if (!(rec.get("version") instanceof Value.Text version)) {
      throw invalid("the manifest needs a string field version");
    }
    if (!isPackageName(name.value())) {
      throw invalid(Quoting.forMessage(name.value()) + " is not a package name: @org/name in lowercase, each part "
          + "starting with a letter or digit, made of a-z, 0-9, -, . and _, and not node_modules, at most "
          + MAX_NAME + " characters");
    }
    if (!isSemver(version.value())) {
      throw invalid(Quoting.forMessage(version.value()) + " is not a semantic version, like 1.2.0");
    }
    return new Manifest(name.value(), version.value());
  }

  private static HausException invalid(String why) {
    return HausException.of(ErrorCode.PACKAGE_MANIFEST, why);
  }

  /**
   * Whether name is {@code @org/name} (spec §13.3): npm's rules for scoped names in lowercase.
   * Only ASCII passes, so its length in chars is its length in bytes.
   */
  static boolean isPackageName(String name) {
    if (!name.startsWith("@") || name.length() > MAX_NAME) {
      return false;
    }
    int slash = name.indexOf('/');
    return slash > 0 && isNameSegment(name, 1, slash) && isNameSegment(name, slash + 1, name.length());
  }

  private static boolean isNameSegment(String s, int from, int to) {
    if (from == to || s.startsWith("node_modules", from) && to - from == "node_modules".length()) {
      return false;
    }
    if (!Scan.isLower(s.charAt(from)) && !Scan.isDigit(s.charAt(from))) {
      return false;
    }
    for (int i = from; i < to; i++) {
      char c = s.charAt(i);
      if (!Scan.isLower(c) && !Scan.isDigit(c) && c != '-' && c != '.' && c != '_') {
        return false;
      }
    }
    return true;
  }

  /** Whether version is a semantic version (SemVer 2.0): {@code 1.2.0}, {@code 1.0.0-rc.1+build.5}. */
  static boolean isSemver(String version) {
    int plus = version.indexOf('+');
    String rest = plus < 0 ? version : version.substring(0, plus);
    int dash = rest.indexOf('-');
    String core = dash < 0 ? rest : rest.substring(0, dash);
    String[] parts = core.split("\\.", -1);
    if (parts.length != 3) {
      return false;
    }
    for (String p : parts) {
      if (!isNumber(p)) {
        return false;
      }
    }
    if (dash >= 0) {
      for (String id : rest.substring(dash + 1).split("\\.", -1)) {
        if (!isIdentifier(id) || allDigits(id) && !isNumber(id)) {
          return false;
        }
      }
    }
    if (plus >= 0) {
      for (String id : version.substring(plus + 1).split("\\.", -1)) {
        if (!isIdentifier(id)) {
          return false;
        }
      }
    }
    return true;
  }

  /** A numeric identifier: digits without a leading zero. */
  private static boolean isNumber(String s) {
    return !s.isEmpty() && (s.length() == 1 || s.charAt(0) != '0') && allDigits(s);
  }

  /** An identifier of a pre-release or build: {@code [0-9A-Za-z-]+}. */
  private static boolean isIdentifier(String s) {
    if (s.isEmpty()) {
      return false;
    }
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if ((!Scan.isWordChar(c) || c == '_') && c != '-') {
        return false;
      }
    }
    return true;
  }

  private static boolean allDigits(String s) {
    for (int i = 0; i < s.length(); i++) {
      if (!Scan.isDigit(s.charAt(i))) {
        return false;
      }
    }
    return true;
  }

  /** Whether o is a manifest with the same name and version. */
  @Override
  public boolean equals(Object o) {
    return o instanceof Manifest m && m.name.equals(name) && m.version.equals(version);
  }

  @Override
  public int hashCode() {
    return name.hashCode() * 31 + version.hashCode();
  }

  /** The manifest as {@code @org/name 1.2.0}. */
  @Override
  public String toString() {
    return name + " " + version;
  }
}
