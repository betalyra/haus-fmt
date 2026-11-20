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

  private Value value(Value j, int depth) {
    if (j instanceof Value.Text) {
      String s = ((Value.Text) j).value();
      if (s.length() > lim.maxStringLength() && s.codePointCount(0, s.length()) > lim.maxStringLength()) {
        throw fail(ErrorCode.STRING_TOO_LONG, "a string longer than the limit of " + lim.maxStringLength() + " characters");
      }
      return j;
    }
    if (j instanceof Value.Array) {
      return new Value.Array(items(((Value.Array) j).unsafeItems(), deeper(depth)));
    }
    if (j instanceof Value.Record) {
      return object((Value.Record) j, depth);
    }
    throw fail(ErrorCode.HAUS_JSON_FORM, "expected the self-describing form of a haus value, found " + describe(j));
  }

  private Value[] items(Value[] items, int depth) {
    Value[] out = new Value[items.length];
    for (int i = 0; i < items.length; i++) {
      path.index(i);
      out[i] = value(items[i], depth);
      path.pop();
    }
    return out;
  }

  /** Reads {@code {"_rec": …}}, {@code {"_num": …}}, {@code {"_bytes": …}}, {@code {"_tag": …}} or {@code {"_tag": …, "_args": […]}}. */
  private Value object(Value.Record r, int depth) {
    String first = r.size() > 0 ? r.keyAt(0) : null;
    if (r.size() == 1 && first.equals("_rec")) {
      return record(r.valueAt(0), depth);
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
      return variant(tag, r.get("_args"), depth);
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

  /** Reads the {@code _args} of {@code tag}. */
  private Value variant(String tag, Value args, int depth) {
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
        Value rec = record(r.valueAt(0), depth);
        path.pop();
        path.pop();
        return new Value.Variant(tag, new Value[] {rec});
      }
    }
    Value[] out = items(items, deeper(depth));
    path.pop();
    return new Value.Variant(tag, out);
  }

  private Value record(Value fields, int depth) {
    path.key("_rec");
    if (!(fields instanceof Value.Record)) {
      throw fail(ErrorCode.HAUS_JSON_FORM, "expected the fields of a record (an object), found " + describe(fields));
    }
    Value.Record r = (Value.Record) fields;
    int d = deeper(depth);
    Value[] out = new Value[r.size()];
    for (int i = 0; i < r.size(); i++) {
      String key = r.keyAt(i);
      if (key.length() > lim.maxStringLength() && key.codePointCount(0, key.length()) > lim.maxStringLength()) {
        throw fail(ErrorCode.KEY_TOO_LONG, "a key longer than the limit of " + lim.maxStringLength() + " characters");
      }
      path.key(key);
      out[i] = value(r.valueAt(i), d);
      path.pop();
    }
    path.pop();
    String[] keys = r.unsafeKeys();
    return new Value.Record(keys, out, Keys.of(keys, keys.length));
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
