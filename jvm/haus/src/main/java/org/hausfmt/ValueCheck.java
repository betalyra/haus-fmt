package org.hausfmt;

/**
 * Checks that a value built in code can be written within the limits (spec §7, §9.8), as {@link
 * Haus#check} documents.
 */
final class ValueCheck extends WriteCheck {
  private ValueCheck(Limits lim) {
    super(lim, true);
  }

  static void check(Value v, Limits lim) {
    ValueCheck c = new ValueCheck(lim);
    c.start(0, false);
    c.value(v, 0);
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
        checkLength(s, ErrorCode.STRING_TOO_LONG, "string");
        break;
      case BYTES:
        checkBytes((Value.Bytes) v);
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
        checkTag(variant.tag());
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
      checkLength(key, ErrorCode.KEY_TOO_LONG, "key");
      value(r.valueAt(i), depth + 1);
      path.pop();
    }
  }
}
