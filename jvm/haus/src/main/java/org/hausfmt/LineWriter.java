package org.hausfmt;

import java.util.List;

/**
 * Writes values built in code in the compact or minimised layout (spec §11): each top-level value
 * on a line of its own, followed by a comma in a stream of two or more. These layouts make no
 * decisions about lines, so the values are written as they are checked, without a syntax tree.
 */
final class LineWriter extends WriteCheck {
  private final StringBuilder b;
  private final boolean minimised;

  private LineWriter(StringBuilder b, Limits lim, boolean check, boolean minimised) {
    super(lim, check);
    this.b = b;
    this.minimised = minimised;
  }

  /** Values as a file in the compact or minimised layout. */
  static String file(List<Value> values, Limits lim, boolean minimised) {
    StringBuilder b = new StringBuilder();
    LineWriter w = new LineWriter(b, lim, true, minimised);
    boolean stream = values.size() > 1;
    for (int i = 0; i < values.size(); i++) {
      w.path.clear();
      if (stream) {
        w.path.index(i);
      }
      w.value(values.get(i), 0);
      if (stream) {
        b.append(',');
      }
      b.append('\n');
    }
    return b.toString();
  }

  /** A value on one line in the compact layout, written as far as it can be: for {@link Value#toString}. */
  static String toText(Value v) {
    StringBuilder b = new StringBuilder();
    new LineWriter(b, Limits.DEFAULT, false, false).value(v, 0);
    return b.toString();
  }

  /** The comma between two entries. */
  private void separator() {
    b.append(minimised ? "," : ", ");
  }

  private void space() {
    if (!minimised) {
      b.append(' ');
    }
  }

  void value(Value v, int depth) {
    switch (v.kind()) {
      case STRING:
        String s = ((Value.Text) v).value();
        checkString(s);
        Quoting.appendQuoted(b, s);
        break;
      case NUMBER:
        b.append(literal((Value.Number) v));
        break;
      case BYTES:
        appendBytes(b, (Value.Bytes) v);
        break;
      case ARRAY:
        enter(depth);
        items('[', ']', ((Value.Array) v).unsafeItems(), depth);
        break;
      case RECORD:
        enter(depth);
        fields((Value.Record) v, depth);
        break;
      case VARIANT:
        variant((Value.Variant) v, depth);
        break;
    }
  }

  private void variant(Value.Variant v, int depth) {
    b.append(v.tag());
    if (v.size() == 0) {
      return;
    }
    Value.Record payload = v.payload();
    if (payload != null) {
      // Tag { … }: the record is the payload's one level.
      enter(depth);
      space();
      fields(payload, depth);
      return;
    }
    enter(depth);
    items('(', ')', v.unsafeArgs(), depth);
  }

  /** Writes the elements of an array or the arguments of a payload, in the container at depth. */
  private void items(char open, char closer, Value[] vs, int depth) {
    b.append(open);
    for (int i = 0; i < vs.length; i++) {
      if (i > 0) {
        separator();
      }
      path.index(i);
      value(vs[i], depth + 1);
      path.pop();
    }
    b.append(closer);
  }

  /** Writes the fields of a record (also a record payload) at depth. */
  private void fields(Value.Record r, int depth) {
    if (r.size() == 0) {
      b.append("{}");
      return;
    }
    b.append('{');
    space();
    for (int i = 0; i < r.size(); i++) {
      if (i > 0) {
        separator();
      }
      String key = r.keyAt(i);
      checkKey(key);
      appendKey(b, key);
      b.append(':');
      space();
      path.key(key);
      value(r.valueAt(i), depth + 1);
      path.pop();
    }
    space();
    b.append('}');
  }
}
