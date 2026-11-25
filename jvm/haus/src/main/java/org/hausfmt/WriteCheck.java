package org.hausfmt;

/**
 * What the writers of values share: the checks that a value can be written within the limits of
 * the reader it is written for (spec §7, §11), in one order, so that every layout fails with the
 * same error at the same place.
 */
abstract class WriteCheck {
  final Limits lim;
  final Path path = new Path();
  /** Whether to check; without, the writer writes what it can (for {@link Value#toString}). */
  final boolean check;

  /** The values written for the current top-level value, against the node limit. */
  private int nodes;
  /** The steps of the current top-level value's path: 0, or 1 in a stream ({@code $[i]}). */
  private int top;

  WriteCheck(Limits lim, boolean check) {
    this.lim = lim;
    this.check = check;
  }

  /** Starts the top-level value {@code i}, of a stream or alone. */
  final void start(int i, boolean stream) {
    path.clear();
    if (stream) {
      path.index(i);
    }
    top = path.size();
    nodes = 0;
  }

  /**
   * Counts one more value written (spec §7, "Values written"): {@code too-many-nodes} above the
   * node limit, at the top-level value.
   */
  final void node() {
    if (++nodes > lim.maxNodes() && check) {
      path.truncate(top);
      throw tooManyNodes(path, lim);
    }
  }

  static HausException tooManyNodes(Path at, Limits lim) {
    return at.error(
        ErrorCode.TOO_MANY_NODES,
        "the value writes more than " + lim.maxNodes() + " values, the node limit: its parts share one another");
  }

  /** A string or key within the string limit, in code points. */
  final void checkLength(String s, ErrorCode code, String what) {
    if (check && s.length() > lim.maxStringLength() && s.codePointCount(0, s.length()) > lim.maxStringLength()) {
      throw path.error(
          code,
          "a " + what + " of " + s.codePointCount(0, s.length()) + " characters, more than the limit of "
              + lim.maxStringLength());
    }
  }

  /** A tag within the string limit; its characters are ASCII. */
  final void checkTag(String tag) {
    if (check && tag.length() > lim.maxStringLength()) {
      throw path.error(
          ErrorCode.TAG_TOO_LONG,
          "a tag of " + tag.length() + " characters, more than the limit of " + lim.maxStringLength());
    }
  }

  /** A byte string within the string limit: two characters between the quotes per byte. */
  final void checkBytes(Value.Bytes v) {
    if (check && 2L * v.size() > lim.maxStringLength()) {
      throw path.error(
          ErrorCode.STRING_TOO_LONG,
          "a byte string of " + v.size() + " bytes, more than the limit of " + lim.maxStringLength() + " characters");
    }
  }

  /** Starts a container at {@code depth} (its parent's), one level deeper. */
  final void enter(int depth) {
    if (check && depth + 1 > lim.maxDepth()) {
      throw path.error(ErrorCode.NESTING_TOO_DEEP, "nesting deeper than the limit of " + lim.maxDepth());
    }
  }

  /**
   * The literal of a number, which must fit the number limits: its length and its exponent, a
   * decimal's too, so that a parser with the same limits reads it back.
   */
  final String literal(Value.Number n) {
    String text = n.literal();
    if (check) {
      HausException e = Numbers.overLimits(text, lim);
      if (e != null) {
        throw path.error(e.code(), e.reason());
      }
    }
    return text;
  }

  /** A string, which must have a UTF-8 form: no unpaired surrogate. */
  final void checkString(String s) {
    if (check && Quoting.hasLoneSurrogate(s)) {
      throw notEncodable("string");
    }
  }

  /** A key, which must have a UTF-8 form: no unpaired surrogate. */
  final void checkKey(String key) {
    if (check && Quoting.hasLoneSurrogate(key)) {
      throw notEncodable("key");
    }
  }

  /**
   * The error of a writer that doesn't apply a secret's schema, given a {@link Value.Secret} at
   * {@code at} (spec §15, "Hiding"): {@code cannot-encode}, without the value.
   */
  static HausException secretRefused(Path at) {
    return at.error(ErrorCode.CANNOT_ENCODE,
        "a Secret, which is written only with its schema (SchemaType.encode): its value is not shown");
  }

  /** The error for a string or key with an unpaired surrogate, here. */
  final HausException notEncodable(String what) {
    return path.error(ErrorCode.CANNOT_ENCODE, "a " + what + " with an unpaired surrogate, which has no UTF-8 form");
  }

  /**
   * Appends a string as {@link Quoting#appendQuoted} does, checked as {@link #checkString} checks
   * it, in one pass: an unpaired surrogate is the same error, at the same place.
   */
  final void appendString(StringBuilder b, String s) {
    if (!Quoting.appendQuoted(b, s) && check) {
      throw notEncodable("string");
    }
  }

  /** Appends a key as {@link #appendKey} does, checked as {@link #checkKey} checks it, in one pass. */
  final void appendCheckedKey(StringBuilder b, String key) {
    if (Scan.isIdent(key)) {
      b.append(key);
    } else if (!Quoting.appendQuoted(b, key) && check) {
      throw notEncodable("key");
    }
  }

  /** Appends a key: bare when it can be, quoted otherwise. */
  static void appendKey(StringBuilder b, String key) {
    if (Scan.isIdent(key)) {
      b.append(key);
    } else {
      Quoting.appendQuoted(b, key);
    }
  }

  private static final char[] LOWER_HEX = "0123456789abcdef".toCharArray();

  /** Appends bytes as lowercase hex, two digits per byte. */
  static void appendHex(StringBuilder b, byte[] bytes) {
    for (byte x : bytes) {
      b.append(LOWER_HEX[x >> 4 & 0xF]).append(LOWER_HEX[x & 0xF]);
    }
  }

  /** Appends a byte string, {@code x"…"}, in lowercase hex. */
  static void appendBytes(StringBuilder b, Value.Bytes v) {
    b.append("x\"");
    appendHex(b, v.unsafeBytes());
    b.append('"');
  }
}
