package org.hausfmt;

/**
 * Checks that a value built in code can be written within the limits (spec §7, §9.8), as {@link
 * Haus#check} documents.
 */
final class ValueCheck extends WriteCheck {
  /**
   * The most values (nodes) one value built in code may have. A value whose arrays or records
   * share one another many times expands when written out; this bounds the work of writing it
   * (spec §9.8). 64 Mi, as many as the largest top-level value of a stream can hold.
   */
  static final int MAX_NODES = 64 << 20;

  private int nodes;

  private ValueCheck(Limits lim) {
    super(lim, true);
  }

  static void check(Value v, Limits lim) {
    new ValueCheck(lim).value(v, 0);
  }

  private void node() {
    if (++nodes > MAX_NODES) {
      throw path.error(ErrorCode.TOO_MANY_NODES, "the value has more than " + MAX_NODES + " nodes");
    }
  }

  private void value(Value v, int depth) {
    node();
    switch (v.kind()) {
      case NUMBER:
        HausException e = Numbers.overLimits(((Value.Number) v).literal(), lim);
        if (e != null) {
          throw e.withPath(path.toString());
        }
        break;
      case STRING:
        String s = ((Value.Text) v).value();
        checkString(s);
        if (s.length() > lim.maxStringLength() && s.codePointCount(0, s.length()) > lim.maxStringLength()) {
          throw path.error(ErrorCode.STRING_TOO_LONG,
              "a string of " + s.codePointCount(0, s.length()) + " characters, more than the limit of " + lim.maxStringLength());
        }
        break;
      case BYTES:
        int n = ((Value.Bytes) v).size();
        if (2L * n > lim.maxStringLength()) {
          throw path.error(ErrorCode.STRING_TOO_LONG,
              "a byte string of " + n + " bytes, more than the limit of " + lim.maxStringLength() + " characters");
        }
        break;
      case ARRAY:
        enter(depth);
        items(((Value.Array) v).unsafeItems(), depth);
        break;
      case RECORD:
        enter(depth);
        fields((Value.Record) v, depth);
        break;
      case VARIANT:
        Value.Variant variant = (Value.Variant) v;
        if (variant.tag().length() > lim.maxStringLength()) {
          throw path.error(ErrorCode.TAG_TOO_LONG, "a tag longer than the limit of " + lim.maxStringLength() + " characters");
        }
        if (variant.size() == 0) {
          break;
        }
        enter(depth);
        if (variant.payload() != null) {
          // Tag { … }: the record is the payload's one level.
          node();
          fields(variant.payload(), depth);
        } else {
          items(variant.unsafeArgs(), depth);
        }
        break;
    }
  }

  private void items(Value[] vs, int depth) {
    for (int i = 0; i < vs.length; i++) {
      path.index(i);
      value(vs[i], depth + 1);
      path.pop();
    }
  }

  private void fields(Value.Record r, int depth) {
    for (int i = 0; i < r.size(); i++) {
      String key = r.keyAt(i);
      path.key(key);
      checkKey(key);
      if (key.length() > lim.maxStringLength() && key.codePointCount(0, key.length()) > lim.maxStringLength()) {
        throw path.error(ErrorCode.KEY_TOO_LONG, "a key longer than the limit of " + lim.maxStringLength() + " characters");
      }
      value(r.valueAt(i), depth + 1);
      path.pop();
    }
  }
}
