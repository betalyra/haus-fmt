package org.hausfmt;

import java.nio.charset.StandardCharsets;

/**
 * Byte and character classes for the readers and writers. Text is read as UTF-8 bytes, so the
 * characters spec §4 doesn't allow raw are found by their bytes: a C1 control starts with {@link
 * #C1_LEAD}, a bidi control with {@link #BIDI_LEAD}, and the scanners look closer only at those.
 * Every byte table and every number about characters lives here.
 */
final class Scan {
  private Scan() {}

  // ── The UTF-8 bytes of the characters that may not appear raw (spec §4) ──

  /** DEL, a control character. */
  static final int DEL = 0x7F;
  /** The lead byte of U+0080–U+00BF; followed by 0x80–{@link #C1_LAST_SECOND} it is a C1 control. */
  static final int C1_LEAD = 0xC2;
  /** The last second byte of a C1 control, U+009F. */
  static final int C1_LAST_SECOND = 0x9F;
  /**
   * The lead byte of U+2000–U+2FFF. The bidi controls are U+202A–U+202E ({@code E2 80 AA–AE}) and
   * U+2066–U+2069 ({@code E2 81 A6–A9}).
   */
  static final int BIDI_LEAD = 0xE2;

  // ── Code points ──

  /** The first and last C1 control. */
  static final int C1_FIRST = 0x80;

  static final int C1_LAST = 0x9F;
  /** The bidi embeddings and overrides, U+202A–U+202E. */
  static final int BIDI_EMBEDDING_FIRST = 0x202A;

  static final int BIDI_EMBEDDING_LAST = 0x202E;
  /** The bidi isolates, U+2066–U+2069. */
  static final int BIDI_ISOLATE_FIRST = 0x2066;

  static final int BIDI_ISOLATE_LAST = 0x2069;
  /** The line and paragraph separators, which some software splits lines at. */
  static final int LINE_SEPARATOR = 0x2028;

  static final int PARAGRAPH_SEPARATOR = 0x2029;
  /** The byte order mark. */
  static final int BOM = 0xFEFF;

  /** The UTF-8 bytes of the byte order mark. */
  static final byte[] BOM_BYTES = {(byte) 0xEF, (byte) 0xBB, (byte) 0xBF};

  // ── Byte tables ──

  /**
   * The bytes that need a closer look in text that may hold any other character (comments, block
   * strings): control characters but tab and line feed, DEL, and the lead bytes of C1 and bidi
   * controls.
   */
  static final boolean[] RAW_CHECK = table(DEL, C1_LEAD, BIDI_LEAD);

  /** The bytes that end a plain run in a {@code "…"} string: {@link #RAW_CHECK}, tab, line feed, quote and backslash. */
  static final boolean[] STRING_STOP = table(DEL, C1_LEAD, BIDI_LEAD, '\t', '\n', '"', '\\');

  /** The bytes that end a plain run in a block comment. */
  static final boolean[] COMMENT_STOP = table(DEL, C1_LEAD, BIDI_LEAD, '*', '/');

  /** Marks the control characters but tab and line feed, and {@code bytes}. */
  private static boolean[] table(int... bytes) {
    boolean[] t = new boolean[256];
    for (int c = 0; c < 0x20; c++) {
      t[c] = c != '\t' && c != '\n';
    }
    for (int b : bytes) {
      t[b] = true;
    }
    return t;
  }

  /** The end of the run of bytes from {@code s[i]} that {@code stop} doesn't mark. */
  static int plainRun(byte[] s, int i, int end, boolean[] stop) {
    while (i < end && !stop[s[i] & 0xFF]) {
      i++;
    }
    return i;
  }

  /**
   * The code for a character at {@code s[i]} that may not appear raw where it is (spec §4): a
   * control character other than tab and line feed, a carriage return not followed by a line feed,
   * or a bidi control; null for any other character.
   */
  static ErrorCode rawCharCode(byte[] s, int i, int end) {
    int c = s[i] & 0xFF;
    if (c == '\t' || c == '\n') {
      return null;
    }
    if (c == '\r') {
      return i + 1 < end && s[i + 1] == '\n' ? null : ErrorCode.LONE_CARRIAGE_RETURN;
    }
    if (c < 0x20 || c == DEL) {
      return ErrorCode.CONTROL_CHARACTER;
    }
    if (c == C1_LEAD) {
      int c1 = i + 1 < end ? s[i + 1] & 0xFF : 0;
      return c1 >= 0x80 && c1 <= C1_LAST_SECOND ? ErrorCode.CONTROL_CHARACTER : null;
    }
    if (c == BIDI_LEAD && i + 2 < end && isBidi(codePointAt(s, i))) {
      return ErrorCode.BIDI_CONTROL;
    }
    return null;
  }

  /** Whether a code point is a bidi control (spec §4). */
  static boolean isBidi(int cp) {
    return cp >= BIDI_EMBEDDING_FIRST && cp <= BIDI_EMBEDDING_LAST
        || cp >= BIDI_ISOLATE_FIRST && cp <= BIDI_ISOLATE_LAST;
  }

  /** Whether a code point is a control character: C0, DEL or C1. */
  static boolean isControl(int cp) {
    return cp < 0x20 || cp >= DEL && cp <= C1_LAST;
  }

  /**
   * Whether a character is never written raw in a string: control characters, bidi controls, and
   * the line and paragraph separators.
   */
  static boolean needsEscape(int cp) {
    return isControl(cp) || isBidi(cp) || cp == LINE_SEPARATOR || cp == PARAGRAPH_SEPARATOR;
  }

  // ── ASCII classes ──

  static boolean isDigit(int c) {
    return c >= '0' && c <= '9';
  }

  static boolean isHexDigit(int c) {
    int lower = c | 0x20;
    return isDigit(c) || lower >= 'a' && lower <= 'f';
  }

  static int hexValue(int c) {
    return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
  }

  static boolean isLower(int c) {
    return c >= 'a' && c <= 'z';
  }

  static boolean isUpper(int c) {
    return c >= 'A' && c <= 'Z';
  }

  /** Whether c can continue an identifier or tag: {@code [A-Za-z0-9_]}. */
  static boolean isWordChar(int c) {
    return isLower(c) || isUpper(c) || isDigit(c) || c == '_';
  }

  /** Whether c may not directly follow a number: {@code [A-Za-z0-9_.]} (grammar). */
  static boolean isWordByte(int c) {
    return isWordChar(c) || c == '.';
  }

  /** Whether a key can be written bare: {@code [a-z_][A-Za-z0-9_]*}. */
  static boolean isIdent(String s) {
    return !s.isEmpty() && (isLower(s.charAt(0)) || s.charAt(0) == '_') && isWordTail(s);
  }

  /** Whether s is a tag: {@code [A-Z][A-Za-z0-9_]*}. */
  static boolean isTag(String s) {
    return !s.isEmpty() && isUpper(s.charAt(0)) && isWordTail(s);
  }

  private static boolean isWordTail(String s) {
    for (int i = 1; i < s.length(); i++) {
      if (!isWordChar(s.charAt(i))) {
        return false;
      }
    }
    return true;
  }

  /** The end of the identifier or tag that starts at {@code s[i]}. */
  static int wordEnd(byte[] s, int i, int end) {
    i++;
    while (i < end && isWordChar(s[i])) {
      i++;
    }
    return i;
  }

  // ── UTF-8 ──

  /** Whether a byte continues a UTF-8 sequence: {@code 10xxxxxx}. */
  static boolean isContinuation(byte b) {
    return (b & 0xC0) == 0x80;
  }

  /** The number of bytes of the UTF-8 sequence that starts with {@code lead}. */
  static int sequenceLength(byte lead) {
    int b = lead & 0xFF;
    return b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
  }

  /** The code point of the valid UTF-8 sequence at {@code s[i]}. */
  static int codePointAt(byte[] s, int i) {
    int b = s[i] & 0xFF;
    switch (sequenceLength(s[i])) {
      case 1:
        return b;
      case 2:
        return (b & 0x1F) << 6 | s[i + 1] & 0x3F;
      case 3:
        return (b & 0x0F) << 12 | (s[i + 1] & 0x3F) << 6 | s[i + 2] & 0x3F;
      default:
        return (b & 0x07) << 18 | (s[i + 1] & 0x3F) << 12 | (s[i + 2] & 0x3F) << 6 | s[i + 3] & 0x3F;
    }
  }

  /** The number of characters (code points) in valid UTF-8 text: the bytes that start one. */
  static int countChars(byte[] s, int from, int to) {
    int n = 0;
    for (int i = from; i < to; i++) {
      if (!isContinuation(s[i])) {
        n++;
      }
    }
    return n;
  }

  /**
   * The offset of the first byte in {@code s[from..to)} that doesn't start or continue a valid
   * UTF-8 sequence (an overlong form, a surrogate, above U+10FFFF, cut short), or {@code to} if
   * the text is valid.
   */
  static int invalidUtf8(byte[] s, int from, int to) {
    int i = from;
    while (i < to) {
      int b = s[i];
      if (b >= 0) {
        i++;
        continue;
      }
      int n = validSequence(s, i, to);
      if (n == 0) {
        return i;
      }
      i += n;
    }
    return to;
  }

  /** The length of the valid multi-byte sequence at {@code s[i]}, or 0 (RFC 3629). */
  private static int validSequence(byte[] s, int i, int to) {
    int b = s[i] & 0xFF;
    int n;
    int lo = 0x80;
    int hi = 0xBF;
    if (b >= 0xC2 && b <= 0xDF) {
      n = 2;
    } else if (b >= 0xE0 && b <= 0xEF) {
      n = 3;
      lo = b == 0xE0 ? 0xA0 : 0x80; // no overlong forms
      hi = b == 0xED ? 0x9F : 0xBF; // no surrogates
    } else if (b >= 0xF0 && b <= 0xF4) {
      n = 4;
      lo = b == 0xF0 ? 0x90 : 0x80;
      hi = b == 0xF4 ? 0x8F : 0xBF; // nothing above U+10FFFF
    } else {
      return 0;
    }
    if (i + n > to) {
      return 0;
    }
    int second = s[i + 1] & 0xFF;
    if (second < lo || second > hi) {
      return 0;
    }
    for (int k = 2; k < n; k++) {
      if (!isContinuation(s[i + k])) {
        return 0;
      }
    }
    return n;
  }

  /** Whether {@code s} starts with the byte order mark at {@code i}. */
  static boolean isBom(byte[] s, int i, int end) {
    return i + 3 <= end
        && s[i] == BOM_BYTES[0]
        && s[i + 1] == BOM_BYTES[1]
        && s[i + 2] == BOM_BYTES[2];
  }

  /** Whether {@code s} has the ASCII text {@code word} at {@code i}. */
  static boolean startsWith(byte[] s, int i, int end, String word) {
    if (i + word.length() > end) {
      return false;
    }
    for (int k = 0; k < word.length(); k++) {
      if (s[i + k] != word.charAt(k)) {
        return false;
      }
    }
    return true;
  }

  /** ASCII bytes as a string. */
  static String ascii(byte[] s, int from, int to) {
    return new String(s, from, to - from, StandardCharsets.ISO_8859_1);
  }

  /** Valid UTF-8 bytes as a string. */
  static String utf8(byte[] s, int from, int to) {
    return new String(s, from, to - from, StandardCharsets.UTF_8);
  }

  /** Names the character at {@code s[i]} for a message: 'x', U+0007, or end of input. */
  static String describeChar(byte[] s, int i, int end) {
    if (i >= end) {
      return "end of input";
    }
    int cp = codePointAt(s, i);
    if (needsEscape(cp) || cp == ' ' || cp == BOM) {
      return String.format("U+%04X", cp);
    }
    return "'" + new String(Character.toChars(cp)) + "'";
  }

  /**
   * Compares two strings by their code points, which is the order of their UTF-8 bytes (and not
   * of their UTF-16 units: a character above U+FFFF sorts after U+E000–U+FFFF).
   */
  static int compareCodePoints(String a, String b) {
    int n = Math.min(a.length(), b.length());
    for (int i = 0; i < n; i++) {
      char x = a.charAt(i);
      char y = b.charAt(i);
      if (x != y) {
        return Integer.compare(codePointOrder(x), codePointOrder(y));
      }
    }
    return Integer.compare(a.length(), b.length());
  }

  /** A UTF-16 unit, moved so that surrogates (characters above U+FFFF) sort after U+E000–U+FFFF. */
  private static int codePointOrder(char c) {
    return Character.isSurrogate(c) ? c + 0x2000 : c >= 0xE000 ? c - 0x800 : c;
  }
}
