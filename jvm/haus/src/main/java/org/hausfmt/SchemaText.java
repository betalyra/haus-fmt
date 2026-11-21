package org.hausfmt;

/**
 * Text from schemas and data in the messages of schema errors (spec §9.2): never repeated
 * unescaped, and cut when long.
 */
final class SchemaText {
  private SchemaText() {}

  private static final int MESSAGE_CHARS = 40;

  /**
   * Text from a file for a message, without quotes around it: control and bidirectional
   * characters escaped as <code>&#92;u{…}</code>, at most 40 characters, cut with an ellipsis.
   */
  static String quote(String text) {
    StringBuilder b = new StringBuilder();
    int total = 0;
    int i = 0;
    int cut = -1; // the length of b when the next piece would pass 39 characters
    while (i < text.length()) {
      int cp = text.codePointAt(i);
      i += Character.charCount(cp);
      if (Character.isSurrogate((char) cp) && cp <= 0xFFFF) {
        cp = 0xFFFD;
      }
      String piece = isControlOrBidi(cp) ? String.format("\\u{%X}", cp) : new String(Character.toChars(cp));
      int n = piece.codePointCount(0, piece.length());
      if (cut < 0 && total + n > MESSAGE_CHARS - 1) {
        cut = b.length();
      }
      b.append(piece);
      total += n;
      if (total > MESSAGE_CHARS) {
        b.setLength(cut);
        return b.append('…').toString();
      }
    }
    return b.toString();
  }

  private static boolean isControlOrBidi(int r) {
    return r < 0x20 || r >= 0x7f && r <= 0x9f || r == 0x61c || r == 0x200e || r == 0x200f
        || r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069 || r == 0x2028 || r == 0x2029;
  }

  /** A key as data writes it, for a message: bare if it can be, else quoted. */
  static String quoteKey(String k) {
    if (Scan.isIdent(k)) {
      return k;
    }
    StringBuilder b = new StringBuilder();
    Quoting.appendQuoted(b, k);
    return quote(b.toString());
  }

  /** A string from the data, quoted for a message: {@code "lots"}. */
  static String quoted(String s) {
    return "\"" + quote(s).replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
  }
}
