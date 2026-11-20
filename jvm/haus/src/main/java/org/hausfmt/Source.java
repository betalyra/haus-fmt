package org.hausfmt;

import java.nio.charset.StandardCharsets;

/**
 * Text being read: UTF-8 bytes {@code bytes[from..to)}, and where they start in the whole input
 * (a stream reader reads one value's text at a time). It places errors: line and column are
 * counted only for an error (spec §8).
 */
final class Source {
  final byte[] bytes;
  final int from;
  final int to;
  /** The 1-based line and column of {@code bytes[from]} in the whole input. */
  private final int line;

  private final int column;

  Source(byte[] bytes, int from, int to, int line, int column) {
    this.bytes = bytes;
    this.from = from;
    this.to = to;
    this.line = line;
    this.column = column;
  }

  /** The whole of {@code bytes}, from the start of the input. */
  Source(byte[] bytes) {
    this(bytes, 0, bytes.length, 1, 1);
  }

  /** The UTF-8 bytes of {@code s}, or an error at its first unpaired surrogate (spec §4). */
  static Source of(String s) {
    return new Source(utf8(s));
  }

  /**
   * The UTF-8 bytes of a string.
   *
   * @throws HausException with the code {@code invalid-utf8} at an unpaired surrogate, which has
   *     no UTF-8 form
   */
  static byte[] utf8(String s) {
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if (!Character.isSurrogate(c)) {
        continue;
      }
      if (Character.isHighSurrogate(c) && i + 1 < s.length() && Character.isLowSurrogate(s.charAt(i + 1))) {
        i++;
        continue;
      }
      String before = s.substring(0, i);
      int lineStart = before.lastIndexOf('\n') + 1;
      int line = 1 + (int) before.chars().filter(ch -> ch == '\n').count();
      int column = 1 + before.codePointCount(lineStart, before.length());
      throw new HausException(ErrorCode.INVALID_UTF8, "an unpaired surrogate, which has no UTF-8 form", line, column, null, null, null);
    }
    return s.getBytes(StandardCharsets.UTF_8);
  }

  /** The first invalid UTF-8 byte (spec §4), as an error, or nothing if the text is valid. */
  void checkUtf8() {
    int bad = Scan.invalidUtf8(bytes, from, to);
    if (bad < to) {
      throw new SyntaxError(bad, ErrorCode.INVALID_UTF8, "invalid UTF-8");
    }
  }

  /** The error at its line and column in the whole input. */
  HausException error(SyntaxError e) {
    int pos = Math.min(e.pos, to);
    int lineStart = from;
    int lines = 0;
    for (int i = from; i < pos; i++) {
      if (bytes[i] == '\n') {
        lines++;
        lineStart = i + 1;
      }
    }
    int col = 1 + Scan.countChars(bytes, lineStart, pos);
    if (lines == 0) {
      col += column - 1;
    }
    return new HausException(e.code, e.reason, line + lines, col, null, e.expected, e.found);
  }
}
