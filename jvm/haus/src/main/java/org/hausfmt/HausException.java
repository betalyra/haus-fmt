package org.hausfmt;

/**
 * An error reported by haus. Every error has a {@link ErrorCode} from the catalogue (spec §17).
 * An error in text has a 1-based {@link #line()} and {@link #column()}, counted in code points
 * (spec §8); both are 0 for an error without a place in text. An error in a value has a {@link
 * #path()}, such as {@code $.items[2]}.
 *
 * <p>{@link #getMessage()} is {@code line:column: path: reason [code]}, leaving out what the error
 * doesn't have; {@link #reason()} is the message for people alone, and {@link #toJson()} the JSON
 * form of spec §17.
 */
public final class HausException extends RuntimeException {
  private static final long serialVersionUID = 1L;

  private final ErrorCode code;
  private final String reason;
  private final int line;
  private final int column;
  private final String path;
  private final String expected;
  private final String found;

  HausException(
      ErrorCode code, String reason, int line, int column, String path, String expected, String found) {
    super(null, null, false, false);
    this.code = code;
    this.reason = reason;
    this.line = line;
    this.column = column;
    this.path = path;
    this.expected = expected;
    this.found = found;
  }

  /**
   * An error without a place, with a code from the catalogue: for codecs ({@link Codec}) that
   * reject a value or a host value with a code of their own, such as {@code cannot-encode}.
   */
  public static HausException of(ErrorCode code, String reason) {
    return new HausException(code, reason, 0, 0, null, null, null);
  }

  /** An error at a place in a value. */
  static HausException at(String path, ErrorCode code, String reason) {
    return new HausException(code, reason, 0, 0, path, null, null);
  }

  /** The error at another place in a value. */
  HausException withPath(String newPath) {
    return new HausException(code, reason, line, column, newPath, expected, found);
  }

  /** The error with another message for people. */
  HausException withReason(String newReason) {
    return new HausException(code, newReason, line, column, path, expected, found);
  }

  /** The error at another place in text. */
  HausException withPosition(int newLine, int newColumn) {
    return new HausException(code, reason, newLine, newColumn, path, expected, found);
  }

  /** The code of the mistake (spec §17). */
  public ErrorCode code() {
    return code;
  }

  /** What went wrong, for people, without the position. */
  public String reason() {
    return reason;
  }

  /** The 1-based line of an error in text, or 0. */
  public int line() {
    return line;
  }

  /** The 1-based column of an error in text, in code points, or 0. */
  public int column() {
    return column;
  }

  /** The place in a value, such as {@code $.items[2]}, or null. */
  public String path() {
    return path;
  }

  /** What should be there, where that is natural, or null. */
  public String expected() {
    return expected;
  }

  /** What is there instead, where that is natural, or null. */
  public String found() {
    return found;
  }

  /** A concrete fix: the catalogue's fix for the code. */
  public String hint() {
    return code.hint();
  }

  @Override
  public String getMessage() {
    StringBuilder b = new StringBuilder();
    if (line > 0) {
      b.append(line).append(':').append(column).append(": ");
    }
    if (path != null) {
      b.append(path).append(": ");
    }
    return b.append(reason).append(" [").append(code.code()).append(']').toString();
  }

  /**
   * The error as JSON (spec §17): code, message, line, column, path, expected, found, hint and
   * docs, leaving out members that don't apply.
   */
  public String toJson() {
    StringBuilder b = new StringBuilder("{");
    member(b, "code", code.code());
    member(b, "message", reason);
    if (line > 0) {
      b.append(",\"line\":").append(line).append(",\"column\":").append(column);
    }
    member(b, "path", path);
    member(b, "expected", expected);
    member(b, "found", found);
    member(b, "hint", hint());
    member(b, "docs", code.docs());
    return b.append('}').toString();
  }

  private static void member(StringBuilder b, String name, String value) {
    if (value == null) {
      return;
    }
    if (b.length() > 1) {
      b.append(',');
    }
    JsonWriter.appendString(b, name);
    b.append(':');
    JsonWriter.appendString(b, value);
  }
}
