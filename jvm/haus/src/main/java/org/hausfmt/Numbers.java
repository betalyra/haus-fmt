package org.hausfmt;

import java.math.BigInteger;

/**
 * Number literals (spec §3): reads one, checks its limits (spec §7) and normalizes it (spec §2):
 * digit separators removed, the exponent written {@code e} and its value (no {@code +}, no leading
 * zeros, no {@code -} on zero), hex and binary in decimal.
 */
final class Numbers {
  private Numbers() {}

  /** A literal read: where it ends, and its normalized text. */
  record Scanned(int end, String literal) {}

  /**
   * Reads the number literal that starts at {@code s[pos]} (a {@code -} or a digit, or a {@code +}
   * or {@code .} to report).
   *
   * @throws SyntaxError for a literal that breaks the grammar or the limits
   */
  static Scanned scan(byte[] s, int pos, int end, Limits lim) {
    int start = pos;
    if (pos < end && (s[pos] == '+' || s[pos] == '.')) {
      throw invalid(pos, "a number can't start with '" + (char) s[pos] + "'");
    }
    boolean negative = pos < end && s[pos] == '-';
    if (negative) {
      pos++;
    }
    if (pos >= end || !Scan.isDigit(s[pos])) {
      throw invalid(pos, "expected a digit after '-', found " + Scan.describeChar(s, pos, end));
    }
    if (s[pos] == '0' && pos + 1 < end) {
      int c = s[pos + 1];
      if (c == 'x' || c == 'b') {
        return radix(s, start, pos + 2, end, negative, c == 'x' ? 16 : 2, lim);
      }
      if (c == 'X' || c == 'B') {
        throw invalid(pos + 1, "the prefix is lowercase: '0" + (char) (c | 0x20) + "', not '0" + (char) c + "'");
      }
      if (Scan.isDigit(c) || c == '_') {
        throw invalid(pos, "a number can't have a leading zero");
      }
    }
    // int frac? exp?
    int i = s[pos] == '0' ? pos + 1 : digits(s, pos, end, 10);
    if (i < end && s[i] == '.') {
      if (i + 1 >= end || !Scan.isDigit(s[i + 1])) {
        throw invalid(i, "expected a digit after '.', found " + Scan.describeChar(s, i + 1, end));
      }
      i = digits(s, i + 1, end, 10);
    }
    int mantissaEnd = i;
    int exponentAt = -1;
    int exponentDigits = -1;
    if (i < end && (s[i] == 'e' || s[i] == 'E')) {
      exponentAt = i++;
      if (i < end && (s[i] == '+' || s[i] == '-')) {
        i++;
      }
      if (i >= end || !Scan.isDigit(s[i])) {
        throw invalid(i, "expected a digit in the exponent, found " + Scan.describeChar(s, i, end));
      }
      exponentDigits = i;
      i = digits(s, i, end, 10);
    }
    followed(s, i, end);
    if (i - start > lim.maxNumberLength()) {
      throw tooLong(start, i - start, lim);
    }
    if (exponentAt < 0) {
      return new Scanned(i, withoutSeparators(s, start, i));
    }
    // The exponent: no '+', no leading zeros, no '-' on zero.
    String exponent = stripZeros(withoutSeparators(s, exponentDigits, i));
    boolean negativeExponent = s[exponentDigits - 1] == '-' && !exponent.equals("0");
    if (exponent.length() > 9 || Integer.parseInt(exponent) > lim.maxExponent()) {
      throw new SyntaxError(
          exponentAt, ErrorCode.EXPONENT_TOO_LARGE, "the exponent is larger than the limit of " + lim.maxExponent());
    }
    String mantissa = withoutSeparators(s, start, mantissaEnd);
    return new Scanned(i, mantissa + (negativeExponent ? "e-" : "e") + exponent);
  }

  /** A hex or binary literal: its digits start at {@code s[i]}, after the prefix. */
  private static Scanned radix(byte[] s, int start, int i, int end, boolean negative, int base, Limits lim) {
    if (i >= end || !isDigit(s[i], base)) {
      throw invalid(i, "expected a digit after '0" + (base == 16 ? 'x' : 'b') + "', found " + Scan.describeChar(s, i, end));
    }
    int j = digits(s, i, end, base);
    followed(s, j, end);
    if (j - start > lim.maxNumberLength()) {
      throw tooLong(start, j - start, lim);
    }
    String text = withoutSeparators(s, i, j);
    if (base == 16 && text.length() > lim.maxHexDigits()) {
      throw new SyntaxError(
          start,
          ErrorCode.NUMBER_TOO_LONG,
          "a hex literal with " + text.length() + " hex digits, more than the limit of " + lim.maxHexDigits());
    }
    String decimal = new BigInteger(text, base).toString();
    return new Scanned(j, negative ? "-" + decimal : decimal);
  }

  /** Reads {@code digit ('_'? digit)*} from {@code s[i]}, a digit, and returns its end. */
  private static int digits(byte[] s, int i, int end, int base) {
    while (true) {
      i++;
      if (i < end && s[i] == '_') {
        if (i + 1 >= end || !isDigit(s[i + 1], base)) {
          throw invalid(i, "'_' must stand between two digits");
        }
        i++;
        continue;
      }
      if (i >= end || !isDigit(s[i], base)) {
        return i;
      }
    }
  }

  private static boolean isDigit(int c, int base) {
    switch (base) {
      case 2:
        return c == '0' || c == '1';
      case 16:
        return Scan.isHexDigit(c);
      default:
        return Scan.isDigit(c);
    }
  }

  /** A number must not be directly followed by {@code [A-Za-z0-9_.]} (grammar). */
  private static void followed(byte[] s, int i, int end) {
    if (i < end && Scan.isWordByte(s[i])) {
      throw invalid(i, "a number can't be followed directly by " + Scan.describeChar(s, i, end));
    }
  }

  private static String withoutSeparators(byte[] s, int from, int to) {
    StringBuilder b = null;
    for (int i = from; i < to; i++) {
      if (s[i] == '_' && b == null) {
        b = new StringBuilder(to - from);
        b.append(Scan.ascii(s, from, i));
      } else if (s[i] != '_' && b != null) {
        b.append((char) s[i]);
      }
    }
    return b == null ? Scan.ascii(s, from, to) : b.toString();
  }

  private static String stripZeros(String digits) {
    int i = 0;
    while (i < digits.length() - 1 && digits.charAt(i) == '0') {
      i++;
    }
    return digits.substring(i);
  }

  private static SyntaxError invalid(int pos, String reason) {
    return new SyntaxError(pos, ErrorCode.INVALID_NUMBER, reason);
  }

  private static SyntaxError tooLong(int start, int length, Limits lim) {
    return new SyntaxError(
        start,
        ErrorCode.NUMBER_TOO_LONG,
        "a number literal of " + length + " characters, more than the limit of " + lim.maxNumberLength());
  }

  /**
   * Whether text is a normalized number literal (spec §2): {@code
   * -?(0|[1-9][0-9]*)(\.[0-9]+)?(e(0|-?[1-9][0-9]*))?}.
   */
  static boolean isNormalized(String text) {
    int n = text.length();
    int i = text.startsWith("-") ? 1 : 0;
    if (i >= n || !Scan.isDigit(text.charAt(i))) {
      return false;
    }
    i = text.charAt(i) == '0' ? i + 1 : decimalDigits(text, i);
    if (i < n && text.charAt(i) == '.') {
      int j = decimalDigits(text, i + 1);
      if (j == i + 1) {
        return false;
      }
      i = j;
    }
    if (i < n && text.charAt(i) == 'e') {
      i++;
      if (i < n && text.charAt(i) == '0') {
        i++;
      } else {
        if (i < n && text.charAt(i) == '-') {
          i++;
        }
        if (i >= n || text.charAt(i) < '1' || text.charAt(i) > '9') {
          return false;
        }
        i = decimalDigits(text, i);
      }
    }
    return i == n;
  }

  private static int decimalDigits(String text, int i) {
    while (i < text.length() && Scan.isDigit(text.charAt(i))) {
      i++;
    }
    return i;
  }

  /**
   * The error of a normalized literal over the number limits (spec §7): {@code number-too-long}
   * or {@code exponent-too-large}, or null.
   */
  static HausException overLimits(String literal, Limits lim) {
    if (literal.length() > lim.maxNumberLength()) {
      return HausException.of(
          ErrorCode.NUMBER_TOO_LONG,
          "a number of " + literal.length() + " characters, more than the limit of " + lim.maxNumberLength());
    }
    int e = literal.indexOf('e');
    if (e >= 0) {
      String exponent = literal.substring(literal.charAt(e + 1) == '-' ? e + 2 : e + 1);
      if (exponent.length() > 9 || Integer.parseInt(exponent) > lim.maxExponent()) {
        return HausException.of(
            ErrorCode.EXPONENT_TOO_LARGE, "an exponent larger than the limit of " + lim.maxExponent());
      }
    }
    return null;
  }
}
