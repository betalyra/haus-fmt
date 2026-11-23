package org.hausfmt;

/** The part of the error catalogue a code belongs to (spec §17). */
public enum ErrorCategory {
  /** Reading haus text (§1–§5). */
  SYNTAX("syntax"),
  /** The resource limits of §7. */
  LIMITS("limits"),
  /** Sequences of values (§6). */
  STREAMS("streams"),
  /** Schema files that implementations must reject (§14). */
  SCHEMA_FILES("schema-files"),
  /** Standard modules, schema packages and files (§13.3). */
  IMPORTS("imports"),
  /** Values that don't fit a schema type (§15), and values a program can't encode. */
  DECODING("decoding"),
  /** The JSON mappings (§16). */
  JSON("json"),
  /** Reported without failing, by checkers and editors (§14) and by schema bindings (§13.4). */
  HINTS("hints");

  private final String id;

  ErrorCategory(String id) {
    this.id = id;
  }

  /** The category's id in the catalogue, such as {@code schema-files}. */
  public String id() {
    return id;
  }

  @Override
  public String toString() {
    return id;
  }
}
