package org.hausfmt;

import java.util.List;
import org.hausfmt.Syntax.Form;
import org.hausfmt.Syntax.Item;
import org.hausfmt.Syntax.Node;

/**
 * Turns values built in code into syntax nodes for the pretty layout, which decides where lines
 * break, checking that they can be written: numbers normalized, byte strings in lowercase hex,
 * strings with the fewest escapes.
 */
final class TreeBuilder extends WriteCheck {
  private TreeBuilder(Limits lim) {
    super(lim, true);
  }

  /** The values as a file: one alone, two or more as a stream. */
  static Syntax.File file(List<Value> values, Limits lim, boolean indexed) {
    TreeBuilder builder = new TreeBuilder(lim);
    Syntax.File f = new Syntax.File();
    for (int i = 0; i < values.size(); i++) {
      builder.start(i, indexed);
      Item it = new Item();
      it.node = builder.node(values.get(i), 0);
      f.items.add(it);
    }
    return f;
  }

  private Node node(Value v, int depth) {
    node();
    switch (v.kind()) {
      case STRING:
        String s = ((Value.Text) v).value();
        checkString(s);
        checkLength(s, ErrorCode.STRING_TOO_LONG, "string");
        return new Node(v, null);
      case NUMBER:
        return new Node(v, literal((Value.Number) v));
      case BYTES:
        checkBytes((Value.Bytes) v);
        StringBuilder b = new StringBuilder();
        appendBytes(b, (Value.Bytes) v);
        return new Node(v, b.toString());
      case ARRAY:
        enter(depth);
        return items(new Node(v, null), ((Value.Array) v).unsafeItems(), depth);
      case RECORD:
        enter(depth);
        return fields(new Node(v, null), (Value.Record) v, depth);
      case SECRET:
        throw secretRefused(path);
      default:
        Value.Variant variant = (Value.Variant) v;
        checkTag(variant.tag());
        Node n = new Node(v, null);
        if (variant.size() == 0) {
          return n;
        }
        enter(depth);
        Value.Record payload = variant.payload();
        if (payload != null) {
          node(); // Tag { … }: the record is one value written
          n.form = Form.BRACES;
          return fields(n, payload, depth);
        }
        n.form = Form.PARENS;
        return items(n, variant.unsafeArgs(), depth);
    }
  }

  private Node items(Node n, Value[] vs, int depth) {
    for (int i = 0; i < vs.length; i++) {
      path.index(i);
      Item it = new Item();
      it.node = node(vs[i], depth + 1);
      path.pop();
      n.items.add(it);
    }
    return n;
  }

  private Node fields(Node n, Value.Record r, int depth) {
    for (int i = 0; i < r.size(); i++) {
      Item it = new Item();
      it.key = r.keyAt(i);
      checkKey(it.key);
      checkLength(it.key, ErrorCode.KEY_TOO_LONG, "key");
      path.key(it.key);
      it.node = node(r.valueAt(i), depth + 1);
      path.pop();
      n.items.add(it);
    }
    return n;
  }
}
