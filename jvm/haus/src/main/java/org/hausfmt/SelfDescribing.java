package org.hausfmt;

/**
 * Reads self-describing JSON (spec §16.2) from the JSON read by {@link JsonReader}: the envelope
 * {@code {"_haus": 1, "_value": …}} and exactly the forms of §16.2, so that every accepted text is
 * the form of exactly one value. Errors have the path of the JSON member, such as {@code
 * $._value._rec.price._num}.
 */
final class SelfDescribing {
  private final Limits lim;
  private final Path path;

  private SelfDescribing(Limits lim, String root) {
    this.lim = lim;
    this.path = new Path(root);
  }

  /** The value of the envelope {@code j}; error paths start at {@code root}. */
  static Value envelope(Value j, Limits lim, String root) {
    return new SelfDescribing(lim, root).envelope(j);
  }

  /**
   * The self-describing value {@code j} without the envelope, as inside schema-based JSON (§16.3:
   * {@code Any}), for a value at {@code depth}; error paths start at {@code root}.
   */
  static Value value(Value j, Limits lim, int depth, String root) {
    return new SelfDescribing(lim, root).value(j, depth);
  }

  /** The {@code _args} of an unknown tag of schema-based JSON (§16.3), as self-describing values. */
  static Value args(String tag, Value args, Limits lim, int depth, String root) {
    return new SelfDescribing(lim, root).variant(tag, args, depth);
  }

  private HausException fail(ErrorCode code, String reason) {
    return path.error(code, reason);
  }

  private Value envelope(Value j) {
    Value version = null;
    Value value = null;
    if (j instanceof Value.Record && ((Value.Record) j).size() == 2) {
      version = ((Value.Record) j).get("_haus");
      value = ((Value.Record) j).get("_value");
    }
    if (version == null || value == null) {
      throw fail(ErrorCode.HAUS_JSON_FORM, "expected the envelope {\"_haus\": 1, \"_value\": …}, found " + describe(j));
    }
    if (!(version instanceof Value.Number) || !((Value.Number) version).literal().equals("1")) {
      path.key("_haus");
      throw fail(ErrorCode.HAUS_JSON_VERSION, "expected version 1 of self-describing JSON in '_haus', found " + describe(version));
    }
    path.key("_value");
    return value(value, 0);
  }

  /** The depth below a container at {@code depth}. */
  private int deeper(int depth) {
    if (depth >= lim.maxDepth()) {
      throw fail(ErrorCode.NESTING_TOO_DEEP, "nesting deeper than " + lim.maxDepth() + " levels");
    }
    return depth + 1;
  }

  /** What a container being read is: an array, a record's fields, or a variant's arguments. */
  private enum Kind { ARRAY, RECORD, ARGS }

  /**
   * A container being read, on a stack on the heap: self-describing JSON nests up to four levels
   * per haus level (spec §16.2), which a thread with a small stack couldn't recurse through (§7).
   */
  private static final class Open {
    final Kind kind;
    final Value[] items;
    /** The keys of a record's fields. */
    final String[] keys;
    final Value[] out;
    /** The depth of the items. */
    final int depth;
    /** The tag of a variant's arguments, or of a record that is a variant's payload, {@code Tag { … }}. */
    final String tag;
    int next;

    Open(Kind kind, Value[] items, String[] keys, int depth, String tag) {
      this.kind = kind;
      this.items = items;
      this.keys = keys;
      this.out = new Value[items.length];
      this.depth = depth;
      this.tag = tag;
    }
  }

  private final java.util.ArrayDeque<Open> open = new java.util.ArrayDeque<>();

  /**
   * Reads the self-describing value {@code j} at {@code depth}, in the order a recursive walk would
   * (so that the first mistake is the one reported, at its path).
   */
  private Value value(Value j, int depth) {
    return walk(start(j, depth));
  }

  /**
   * Finishes the walk that {@code first} began: a value read, or null when a container was
   * opened.
   */
  private Value walk(Value first) {
    Value done = first;
    while (true) {
      if (done == null) {
        Open f = open.peek();
        if (f.next < f.items.length) {
          // The next item: its path, then the item.
          if (f.kind == Kind.RECORD) {
            String key = f.keys[f.next];
            if (key.length() > lim.maxStringLength() && key.codePointCount(0, key.length()) > lim.maxStringLength()) {
              throw fail(ErrorCode.KEY_TOO_LONG, "a key longer than the limit of " + lim.maxStringLength() + " characters");
            }
            path.key(key);
          } else {
            path.index(f.next);
          }
          done = start(f.items[f.next], f.depth);
          continue;
        }
        open.pop();
        done = close(f);
      }
      Open parent = open.peek();
      if (parent == null) {
        return done;
      }
      path.pop();
      parent.out[parent.next++] = done;
      done = null;
    }
  }

  /** The value a container read gives, its path steps taken back. */
  private Value close(Open f) {
    switch (f.kind) {
      case ARRAY:
        return new Value.Array(f.out);
      case ARGS:
        path.pop(); // _args
        return new Value.Variant(f.tag, f.out);
      default: {
        path.pop(); // _rec
        Value rec = new Value.Record(f.keys, f.out, Keys.of(f.keys, f.keys.length));
        if (f.tag == null) {
          return rec;
        }
        // Tag { … }: the payload at _args[0].
        path.pop();
        path.pop();
        return new Value.Variant(f.tag, new Value[] {rec});
      }
    }
  }

  /**
   * Starts reading {@code j} at {@code depth}: a value that has no items is read and returned; a
   * container is opened (pushed), and null returned.
   */
  private Value start(Value j, int depth) {
    if (j instanceof Value.Text) {
      String s = ((Value.Text) j).value();
      if (s.length() > lim.maxStringLength() && s.codePointCount(0, s.length()) > lim.maxStringLength()) {
        throw fail(ErrorCode.STRING_TOO_LONG, "a string longer than the limit of " + lim.maxStringLength() + " characters");
      }
      return j;
    }
    if (j instanceof Value.Array) {
      int d = deeper(depth);
      open.push(new Open(Kind.ARRAY, ((Value.Array) j).unsafeItems(), null, d, null));
      return null;
    }
    if (j instanceof Value.Record) {
      return object((Value.Record) j, depth);
    }
    throw fail(ErrorCode.HAUS_JSON_FORM, "expected the self-describing form of a haus value, found " + describe(j));
  }

  /** Reads {@code {"_rec": …}}, {@code {"_num": …}}, {@code {"_bytes": …}}, {@code {"_tag": …}} or {@code {"_tag": …, "_args": […]}}. */
  private Value object(Value.Record r, int depth) {
    String first = r.size() > 0 ? r.keyAt(0) : null;
    if (r.size() == 1 && first.equals("_rec")) {
      return record(r.valueAt(0), depth, null);
    }
    if (r.size() == 1 && first.equals("_num")) {
      return number(r.valueAt(0));
    }
    if (r.size() == 1 && first.equals("_bytes")) {
      return bytes(r.valueAt(0));
    }
    if (r.size() == 1 && first.equals("_tag")) {
      return new Value.Variant(tag(r.valueAt(0)), new Value[0]);
    }
    if (r.size() == 2 && r.containsKey("_tag") && r.containsKey("_args")) {
      String tag = tag(r.get("_tag"));
      return startVariant(tag, r.get("_args"), depth);
    }
    throw fail(ErrorCode.HAUS_JSON_FORM, "expected the self-describing form of a haus value, found " + describe(r));
  }

  private Value number(Value j) {
    path.key("_num");
    if (!(j instanceof Value.Text) || !Numbers.isNormalized(((Value.Text) j).value())) {
      throw fail(ErrorCode.HAUS_JSON_NUMBER, "expected a normalized number literal in '_num', found " + describe(j));
    }
    String literal = ((Value.Text) j).value();
    HausException e = Numbers.overLimits(literal, lim);
    if (e != null) {
      throw e.withPath(path.toString());
    }
    path.pop();
    return new Value.Number(literal);
  }

  private Value bytes(Value j) {
    path.key("_bytes");
    String digits = j instanceof Value.Text ? ((Value.Text) j).value() : null;
    if (digits == null || digits.length() % 2 != 0 || !lowerHex(digits)) {
      throw fail(ErrorCode.HAUS_JSON_BYTES, "expected two lowercase hex digits per byte in '_bytes'");
    }
    if (digits.length() > lim.maxStringLength()) {
      throw fail(ErrorCode.STRING_TOO_LONG, "a byte string longer than the limit of " + lim.maxStringLength() + " characters");
    }
    byte[] out = new byte[digits.length() / 2];
    for (int i = 0; i < out.length; i++) {
      out[i] = (byte) (Scan.hexValue(digits.charAt(2 * i)) << 4 | Scan.hexValue(digits.charAt(2 * i + 1)));
    }
    path.pop();
    return new Value.Bytes(out);
  }

  private static boolean lowerHex(String s) {
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      if (!(Scan.isDigit(c) || c >= 'a' && c <= 'f')) {
        return false;
      }
    }
    return true;
  }

  /** Reads the {@code _args} of {@code tag} (whole, through the walk). */
  private Value variant(String tag, Value args, int depth) {
    return walk(startVariant(tag, args, depth));
  }

  /** Starts the {@code _args} of {@code tag}: opens the arguments, or the record of {@code Tag { … }}. */
  private Value startVariant(String tag, Value args, int depth) {
    path.key("_args");
    if (!(args instanceof Value.Array) || ((Value.Array) args).size() == 0) {
      throw fail(ErrorCode.HAUS_JSON_FORM, "'_args' must be a non-empty array (a tag without arguments has no '_args')");
    }
    Value[] items = ((Value.Array) args).unsafeItems();
    if (items.length == 1 && items[0] instanceof Value.Record) {
      Value.Record r = (Value.Record) items[0];
      if (r.size() == 1 && r.keyAt(0).equals("_rec")) {
        // Tag { … } is one level, as in the parser.
        path.index(0);
        return record(r.valueAt(0), depth, tag);
      }
    }
    int d = deeper(depth);
    open.push(new Open(Kind.ARGS, items, null, d, tag));
    return null;
  }

  /** Opens the fields of a record; {@code tag} is the variant whose payload it is, or null. */
  private Value record(Value fields, int depth, String tag) {
    path.key("_rec");
    if (!(fields instanceof Value.Record)) {
      throw fail(ErrorCode.HAUS_JSON_FORM, "expected the fields of a record (an object), found " + describe(fields));
    }
    Value.Record r = (Value.Record) fields;
    int d = deeper(depth);
    open.push(new Open(Kind.RECORD, r.unsafeValues(), r.unsafeKeys(), d, tag));
    return null;
  }

  /** Reads a {@code _tag}; its errors are at the variant, the object that holds it. */
  private String tag(Value j) {
    if (!(j instanceof Value.Text) || !Scan.isTag(((Value.Text) j).value())) {
      throw fail(ErrorCode.INVALID_TAG, "expected a tag ([A-Z][A-Za-z0-9_]*) in '_tag', found " + describe(j));
    }
    String tag = ((Value.Text) j).value();
    if (tag.length() > lim.maxStringLength()) {
      throw fail(ErrorCode.TAG_TOO_LONG, "a tag longer than the limit of " + lim.maxStringLength() + " characters");
    }
    return tag;
  }

  /** A short description of a JSON value read as a haus value, for messages. */
  static String describe(Value j) {
    switch (j.kind()) {
      case STRING:
        return "the string " + Quoting.forMessage(((Value.Text) j).value());
      case NUMBER:
        String t = ((Value.Number) j).literal();
        return "the number " + (t.length() > 30 ? t.substring(0, 30) + "…" : t);
      case ARRAY:
        return "an array";
      case RECORD:
        Value.Record r = (Value.Record) j;
        if (r.size() == 0) {
          return "an empty object";
        }
        StringBuilder b = new StringBuilder("an object with ");
        for (int i = 0; i < r.size(); i++) {
          if (i > 0) {
            b.append(", ");
          }
          if (i == 3) {
            b.append('…');
            break;
          }
          JsonWriter.appendString(b, r.keyAt(i));
        }
        return b.toString();
      case VARIANT:
        String tag = ((Value.Variant) j).tag();
        return tag.equals("True") ? "true" : tag.equals("False") ? "false" : "null";
      default:
        return "nothing";
    }
  }
}
