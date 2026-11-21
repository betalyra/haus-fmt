package org.hausfmt;

import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;

/**
 * Floats of the schema types {@code Float64} and {@code Float32} (spec §15): rounded directly from
 * a number's exact decimal value, and written in their one spelling.
 */
final class SchemaFloats {
  private SchemaFloats() {}

  /**
   * Whether the runtime's {@code Double.toString} and {@code Float.toString} give the shortest
   * digits that round back, the closest of them (Java 19 and later). Older runtimes, Android's
   * among them, take the exact search below.
   */
  private static final boolean SHORTEST_TO_STRING = shortestToString();

  private static boolean shortestToString() {
    try {
      return Runtime.version().feature() >= 19;
    } catch (LinkageError e) {
      return false;
    }
  }

  /**
   * The float nearest to a normalized literal (ties to even), as a double; for {@code Float32}
   * rounded to binary32 directly from the decimal, not through binary64. Infinite if the number is
   * too large for the type.
   */
  static double parse(String literal, boolean float32) {
    return float32 ? Float.parseFloat(literal) : Double.parseDouble(literal);
  }

  /**
   * A finite float in the one spelling of spec §15: the fewest digits that round back to it (the
   * closest of them, then the one ending in an even digit), laid out as JavaScript's {@code
   * Number.prototype.toString} does, without {@code +} in the exponent.
   */
  static String format(double f, boolean float32) {
    if (f == 0) {
      return 1 / f < 0 ? "-0" : "0";
    }
    StringBuilder b = new StringBuilder();
    if (f < 0) {
      b.append('-');
      f = -f;
    }
    Digits d = SHORTEST_TO_STRING ? fromToString(f, float32) : search(f, float32);
    layout(b, d.digits, d.exponent);
    return b.toString();
  }

  /** The value {@code 0.digits × 10^exponent}. */
  private record Digits(String digits, int exponent) {}

  /** The digits of {@code Double.toString} or {@code Float.toString}, which are shortest and closest. */
  private static Digits fromToString(double f, boolean float32) {
    String s = float32 ? Float.toString((float) f) : Double.toString(f);
    int e = s.indexOf('E');
    int exp = e < 0 ? 0 : Integer.parseInt(s.substring(e + 1));
    String mantissa = e < 0 ? s : s.substring(0, e);
    int dot = mantissa.indexOf('.');
    String digits = mantissa.substring(0, dot) + mantissa.substring(dot + 1);
    int point = dot + exp; // digits before the decimal point
    int lead = 0;
    while (lead < digits.length() - 1 && digits.charAt(lead) == '0') {
      lead++;
    }
    digits = digits.substring(lead);
    point -= lead;
    int end = digits.length();
    while (end > 1 && digits.charAt(end - 1) == '0') {
      end--;
    }
    digits = digits.substring(0, end);
    // Java writes two digits where one digit rounds back but a two-digit decimal is closer
    // (4.9E-324); the spec wants the fewest digits.
    if (digits.length() == 2) {
      Digits one = closest(f, float32, 1);
      if (one != null) {
        return one;
      }
    }
    return new Digits(digits, point);
  }

  /** The shortest digits that round back to {@code f}, by trying each length. */
  private static Digits search(double f, boolean float32) {
    for (int k = 1; ; k++) {
      Digits d = closest(f, float32, k);
      if (d != null) {
        return d;
      }
    }
  }

  /**
   * The {@code k}-digit decimal closest to {@code f} that rounds back to it (of two equally close,
   * the one with an even last digit), or null if none does. Only the two {@code k}-digit decimals
   * around {@code f} can: any other is farther on the same side.
   */
  private static Digits closest(double f, boolean float32, int k) {
    BigDecimal exact = new BigDecimal(f);
    BigDecimal down = exact.round(new MathContext(k, RoundingMode.FLOOR));
    BigDecimal up = exact.round(new MathContext(k, RoundingMode.CEILING));
    boolean downOk = roundsBack(down, f, float32);
    boolean upOk = roundsBack(up, f, float32);
    BigDecimal pick;
    if (downOk && upOk && down.compareTo(up) != 0) {
      int c = exact.subtract(down).compareTo(up.subtract(exact));
      if (c != 0) {
        pick = c < 0 ? down : up;
      } else {
        pick = down.unscaledValue().testBit(0) ? up : down;
      }
    } else if (downOk) {
      pick = down;
    } else if (upOk) {
      pick = up;
    } else {
      return null;
    }
    BigDecimal stripped = pick.stripTrailingZeros();
    String digits = stripped.unscaledValue().toString();
    return new Digits(digits, digits.length() - stripped.scale());
  }

  private static boolean roundsBack(BigDecimal d, double f, boolean float32) {
    String s = d.toString();
    return float32 ? Float.parseFloat(s) == (float) f : Double.parseDouble(s) == f;
  }

  /** Writes {@code 0.digits × 10^n} as JavaScript's {@code Number.prototype.toString} does. */
  private static void layout(StringBuilder b, String digits, int n) {
    int k = digits.length();
    if (k <= n && n <= 21) {
      b.append(digits);
      for (int i = k; i < n; i++) {
        b.append('0');
      }
    } else if (0 < n && n <= 21) {
      b.append(digits, 0, n).append('.').append(digits, n, k);
    } else if (-6 < n && n <= 0) {
      b.append("0.");
      for (int i = 0; i < -n; i++) {
        b.append('0');
      }
      b.append(digits);
    } else {
      b.append(digits.charAt(0));
      if (k > 1) {
        b.append('.').append(digits, 1, k);
      }
      b.append('e').append(n - 1);
    }
  }
}
