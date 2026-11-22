package org.hausfmt;

/**
 * The resource limits of spec §7, enforced while parsing and checked by the writers. {@link
 * #DEFAULT} holds the defaults; the {@code with…} methods change one limit:
 *
 * <pre>{@code Limits limits = Limits.DEFAULT.withMaxDepth(64);}</pre>
 *
 * @param maxDepth the deepest nesting of records, arrays and payloads, counted on the text as
 *     written (spec §7). Default 256; at most {@link #MAX_SUPPORTED_DEPTH}.
 * @param maxNumberLength the most characters in one number literal, sign, separators and exponent
 *     included. Default 1000. It also limits hex literals to the most hex digits whose value fits
 *     the limit in decimal ({@link #maxHexDigits()}).
 * @param maxExponent the largest absolute exponent of a number. Default 6144.
 * @param maxStringLength the most characters (code points) in one string, record key or tag, or
 *     between the quotes of a byte string. Default 16 Mi.
 * @param maxValueLength the most characters in one top-level value of a stream. Default 64 Mi.
 *     Only a {@link StreamReader} applies it; parsing a whole text doesn't (spec §7).
 * @param maxNodes the most values written for one top-level value built in code: the value and
 *     every element, field value and argument inside it, each as often as it is written (spec §7,
 *     "Values written"). A value whose parts share one another is small in memory and can be
 *     exponentially larger written out; the writers, {@link Haus#check}, the canonical form and
 *     hashing stop at this limit with {@code too-many-nodes}. Default 64 Mi.
 */
public record Limits(
    int maxDepth,
    int maxNumberLength,
    int maxExponent,
    int maxStringLength,
    int maxValueLength,
    int maxNodes) {

  /**
   * The deepest nesting this binding supports (spec §7). The parser, the writers, the checks and
   * the schema codecs recurse once per level of nesting, so the depth limit is bounded to keep
   * them within a thread's stack (256 levels fit in 512 KiB, which the tests check); a larger
   * {@link #maxDepth} is rejected with the code {@code unsupported-depth}. No parsed value is
   * nested deeper. A value built in code may be: the writers and checks reject it ({@code
   * nesting-too-deep}), and equality, hash codes, the canonical form, hashing and comparison take
   * any depth.
   */
  public static final int MAX_SUPPORTED_DEPTH = 256;

  /** The default limits of spec §7. */
  public static final Limits DEFAULT = new Limits(256, 1000, 6144, 16 << 20, 64 << 20, 64 << 20);

  /**
   * Checks the limits.
   *
   * @throws HausException with the code {@code unsupported-depth} if {@code maxDepth} isn't between
   *     1 and {@link #MAX_SUPPORTED_DEPTH}
   * @throws IllegalArgumentException if another limit isn't positive
   */
  public Limits {
    if (maxDepth < 1 || maxDepth > MAX_SUPPORTED_DEPTH) {
      throw HausException.of(
          ErrorCode.UNSUPPORTED_DEPTH,
          "maxDepth "
              + maxDepth
              + " is outside the supported range, 1 to "
              + MAX_SUPPORTED_DEPTH);
    }
    if (maxNumberLength < 1 || maxExponent < 0 || maxStringLength < 0 || maxValueLength < 1 || maxNodes < 1) {
      throw new IllegalArgumentException("limits must be positive: " + this);
    }
  }

  /** These limits with another depth limit. */
  public Limits withMaxDepth(int value) {
    return new Limits(value, maxNumberLength, maxExponent, maxStringLength, maxValueLength, maxNodes);
  }

  /** These limits with another number length limit. */
  public Limits withMaxNumberLength(int value) {
    return new Limits(maxDepth, value, maxExponent, maxStringLength, maxValueLength, maxNodes);
  }

  /** These limits with another exponent limit. */
  public Limits withMaxExponent(int value) {
    return new Limits(maxDepth, maxNumberLength, value, maxStringLength, maxValueLength, maxNodes);
  }

  /** These limits with another string length limit. */
  public Limits withMaxStringLength(int value) {
    return new Limits(maxDepth, maxNumberLength, maxExponent, value, maxValueLength, maxNodes);
  }

  /** These limits with another value length limit, for stream readers. */
  public Limits withMaxValueLength(int value) {
    return new Limits(maxDepth, maxNumberLength, maxExponent, maxStringLength, value, maxNodes);
  }

  /** These limits with another node limit, for writers, the canonical form and hashing. */
  public Limits withMaxNodes(int value) {
    return new Limits(maxDepth, maxNumberLength, maxExponent, maxStringLength, maxValueLength, value);
  }

  /**
   * The most hex digits (leading zeros counted, {@code _} not) in one hex literal: the largest h
   * with 16^h ≤ 10^(n−1) for the number limit n, so that every integer's decimal form, sign
   * included, fits in n characters (spec §7). 829 for the default 1000.
   */
  public int maxHexDigits() {
    // 16^h ≤ 10^(n−1) ⇔ h·log10(16) ≤ n−1; the float is corrected at the boundary.
    double log16 = Math.log10(16);
    int h = (int) ((maxNumberLength - 1) / log16);
    while (h > 0 && h * log16 > maxNumberLength - 1 + 1e-9) {
      h--;
    }
    while ((h + 1) * log16 <= maxNumberLength - 1 - 1e-9) {
      h++;
    }
    return h;
  }
}
