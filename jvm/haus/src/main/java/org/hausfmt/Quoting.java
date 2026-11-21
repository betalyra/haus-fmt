package org.hausfmt;

/**
 * Strings as the writers write them (spec §11, §12): {@code "…"} with the fewest escapes, the
 * lines of block strings, source spellings, and text quoted in messages. Every layout and the
 * canonical form escape alike.
 */
final class Quoting {
  private Quoting() {}

  private static final char[] UPPER_HEX = "0123456789ABCDEF".toCharArray();
  /** The most characters of a text quoted in a message (spec §9). */
  private static final int MESSAGE_CHARS = 40;

  /**
   * Appends {@code s} as a {@code "…"} string with the fewest escapes: {@code \"}, {@code \\},
   * {@code \n}, {@code \r}, {@code \t}, and <code>&#92;u{…}</code> for the other characters of {@link
   * Scan#needsEscape}. Returns false if {@code s} has an unpaired surrogate, which no UTF-8 text
   * holds; it is written as <code>&#92;u{FFFD}</code>.
   */
  static boolean appendQuoted(StringBuilder b, String s) {
    int n = s.length();
    int i = 0;
    while (i < n && isPlain(s.charAt(i))) {
      i++;
    }
    b.append('"');
    if (i == n) {
      // The common case: printable ASCII but quote and backslash, written as it is.
      b.append(s).append('"');
      return true;
    }
    return appendQuotedFrom(b, s, i);
  }

  /** Printable ASCII but {@code "} and {@code \\}: the characters that need no look in a {@code "…"} string. */
  private static final boolean[] PLAIN = new boolean[128];

  static {
    for (int c = 0x20; c < Scan.DEL; c++) {
      PLAIN[c] = c != '"' && c != '\\';
    }
  }

  private static boolean isPlain(char c) {
    return c < 128 && PLAIN[c];
  }

  /**
   * Most characters beyond ASCII, which are written raw: not the C1 controls, the line and
   * paragraph separators, the bidi controls (U+2028–U+2069 holds them all) or a surrogate. False
   * for some that are written raw too, which {@link Scan#needsEscape} then tells apart.
   */
  private static boolean isPlainBeyondAscii(char c) {
    return c >= 0xA0 && (c < 0x2028 || c > 0x2069 && c < Character.MIN_SURROGATE || c > Character.MAX_SURROGATE);
  }

  /** {@link #appendQuoted} from {@code s[from]}, the first character that isn't plain; the quote is written. */
  private static boolean appendQuotedFrom(StringBuilder b, String s, int from) {
    boolean valid = true;
    int plain = 0;
    int n = s.length();
    for (int i = from; i < n; i++) {
      char c = s.charAt(i);
      if (isPlain(c) || isPlainBeyondAscii(c)) {
        continue;
      }
      if (Character.isHighSurrogate(c) && i + 1 < n && Character.isLowSurrogate(s.charAt(i + 1))) {
        i++;
        continue;
      }
      boolean lone = Character.isSurrogate(c);
      if (!lone && c > Scan.DEL && !Scan.needsEscape(c)) {
        continue;
      }
      b.append(s, plain, i);
      if (lone) {
        valid = false;
        appendUnicodeEscape(b, 0xFFFD);
      } else {
        appendEscape(b, c);
      }
      plain = i + 1;
    }
    b.append(s, plain, n);
    b.append('"');
    return valid;
  }

  /** Appends the escape of a character that is never written raw in a {@code "…"} string. */
  private static void appendEscape(StringBuilder b, char c) {
    switch (c) {
      case '"':
        b.append("\\\"");
        break;
      case '\\':
        b.append("\\\\");
        break;
      case '\n':
        b.append("\\n");
        break;
      case '\r':
        b.append("\\r");
        break;
      case '\t':
        b.append("\\t");
        break;
      default:
        appendUnicodeEscape(b, c);
    }
  }

  /** Appends <code>&#92;u{…}</code> with uppercase hex digits and no leading zeros. */
  static void appendUnicodeEscape(StringBuilder b, int cp) {
    b.append("\\u{");
    boolean started = false;
    for (int shift = 20; shift >= 0; shift -= 4) {
      int d = cp >> shift & 0xF;
      if (d != 0 || started || shift == 0) {
        b.append(UPPER_HEX[d]);
        started = true;
      }
    }
    b.append('}');
  }

  /** Whether {@code s} has an unpaired surrogate, which no UTF-8 text holds. */
  static boolean hasLoneSurrogate(String s) {
    int n = s.length();
    for (int i = 0; i < n; i++) {
      // Four characters below the surrogates at a time: most text has none.
      while (i + 4 <= n && (s.charAt(i) | s.charAt(i + 1) | s.charAt(i + 2) | s.charAt(i + 3)) < Character.MIN_SURROGATE) {
        i += 4;
      }
      if (i >= n) {
        break;
      }
      char c = s.charAt(i);
      if (!Character.isSurrogate(c)) {
        continue;
      }
      if (!Character.isHighSurrogate(c) || i + 1 >= s.length() || !Character.isLowSurrogate(s.charAt(i + 1))) {
        return true;
      }
      i++;
    }
    return false;
  }

  /**
   * Appends a number, byte string or {@code "…"} string as written in the source, with raw U+2028
   * and U+2029 escaped, which no layout writes raw (spec §11).
   */
  static void appendSpelling(StringBuilder b, String text) {
    int plain = 0;
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if (c == Scan.LINE_SEPARATOR || c == Scan.PARAGRAPH_SEPARATOR) {
        b.append(text, plain, i);
        appendUnicodeEscape(b, c);
        plain = i + 1;
      }
    }
    b.append(text, plain, text.length());
  }

  /**
   * Appends one content line of a block string (spec §11): a quote followed by two more is
   * escaped, a carriage return is {@code \r}, and the last character is escaped if it is a space
   * or tab, so that no line ends in one.
   */
  static void appendBlockLine(StringBuilder b, String line) {
    int last = line.length() - 1;
    for (int i = 0; i <= last; i++) {
      char c = line.charAt(i);
      if (c == '\\') {
        b.append("\\\\");
      } else if (c == '"' && line.startsWith("\"\"\"", i)) {
        b.append("\\\"");
      } else if (c == ' ' && i == last) {
        b.append("\\u{20}");
      } else if (c == '\t' && i == last) {
        b.append("\\t");
      } else if (c == '\r') {
        b.append("\\r");
      } else if (c == '\t' || !Character.isSurrogate(c) && !Scan.needsEscape(c)) {
        b.append(c);
      } else if (Character.isHighSurrogate(c) && i < last && Character.isLowSurrogate(line.charAt(i + 1))) {
        b.append(c).append(line.charAt(++i));
      } else {
        appendUnicodeEscape(b, Character.isSurrogate(c) ? 0xFFFD : c);
      }
    }
  }

  /**
   * Quotes text for an error message: quotes and backslashes escaped, control, bidi and
   * line-separator characters written as escapes, and long text cut to 40 characters (spec §9).
   */
  static String forMessage(String s) {
    StringBuilder b = new StringBuilder("\"");
    int chars = 0;
    for (int i = 0; i < s.length(); ) {
      if (chars == MESSAGE_CHARS) {
        b.append('…');
        break;
      }
      chars++;
      int cp = s.codePointAt(i);
      i += Character.charCount(cp);
      if (cp == '"' || cp == '\\') {
        b.append('\\').append((char) cp);
      } else if (Character.isSurrogate((char) cp) && cp <= 0xFFFF) {
        appendUnicodeEscape(b, 0xFFFD);
      } else if (Scan.needsEscape(cp)) {
        appendUnicodeEscape(b, cp);
      } else {
        b.appendCodePoint(cp);
      }
    }
    return b.append('"').toString();
  }

  /** Writes a key as a step of a path (spec §15): {@code .name} or {@code ["pt-BR"]}. */
  static void appendPathKey(StringBuilder b, String key) {
    if (Scan.isIdent(key)) {
      b.append('.').append(key);
    } else {
      b.append('[');
      appendQuoted(b, key);
      b.append(']');
    }
  }
}
