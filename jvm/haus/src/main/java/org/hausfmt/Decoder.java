package org.hausfmt;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import org.hausfmt.SchemaTypes.CaseType;
import org.hausfmt.SchemaTypes.FieldType;
import org.hausfmt.SchemaTypes.Kind;
import org.hausfmt.SchemaTypes.Payload;
import org.hausfmt.SchemaTypes.RecordType;
import org.hausfmt.SchemaTypes.Typ;
import org.hausfmt.SchemaTypes.VariantType;

/**
 * Decodes (or, encoding, checks) one value with a type (spec §15). The result is a haus value: the
 * one an encoder writes back, with floats in their one spelling, integers in decimal ({@code -0}
 * as {@code 0}), and the fields an open record ignores left out. Parts the type keeps as they are
 * are the input's own values, not copies.
 *
 * <p>Reading schema-based JSON (§16.3) is the same walk over the JSON read as the import reads it
 * (§16.1), so that every rule of decoding, the work budget and codecs apply alike.
 *
 * <p>The walk recurses once per level of the value, at most {@link Limits#MAX_SUPPORTED_DEPTH}
 * levels, and a few frames per level of JSON.
 */
final class Decoder {
  /** The work budget of one decode: steps per value of the input, after a start (spec §9.8). */
  private static final int STEPS_PER_VALUE = 16;

  private static final int BUDGET_START = 1024;

  static final Value NONE = Value.Variant.NONE;
  private static final Value NAN = new Value.Variant("NaN", new Value[0]);
  private static final Value INFINITY = new Value.Variant("Infinity", new Value[0]);
  private static final Value NEG_INFINITY = new Value.Variant("NegInfinity", new Value[0]);
  private static final Value ZERO = new Value.Number("0");

  private final Limits lim;
  private final boolean encoding;
  private final boolean reading; // the value is JSON read as by the import: schema-based JSON (§16.3)
  private final Codecs codecs;
  private final Path path;
  private int depth;
  private int nodes;
  private int steps;
  private int budget = BUDGET_START;
  /**
   * The fields of the keys of the records being decoded, the innermost record's last: a record
   * looks up each key's field once, before its values are decoded.
   */
  private FieldType[] fieldStack = new FieldType[16];

  private int fieldTop;

  private Decoder(Limits lim, boolean encoding, boolean reading, Codecs codecs, String root) {
    this.lim = lim;
    this.encoding = encoding;
    this.reading = reading;
    this.codecs = codecs;
    this.path = new Path(root);
  }

  /** Decodes {@code v} with {@code t}, or checks it for encoding; error paths start at {@code root}. */
  static Value run(Typ t, Value v, DecodeOptions opts, boolean encoding, String root) {
    return new Decoder(opts.limits(), encoding, false, opts.codecs(), root).value(v, t);
  }

  /** Reads JSON {@code j} (as the import reads it) with {@code t}. */
  static Value readJson(Typ t, Value j, DecodeOptions opts, String root) {
    return new Decoder(opts.limits(), false, true, opts.codecs(), root).value(j, t);
  }

  private HausException fail(ErrorCode code, String reason) {
    return path.error(code, reason);
  }

  private Value childAt(int index, Value v, Typ t) {
    path.index(index);
    Value out = nest(v, t);
    path.pop();
    return out;
  }

  private Value childAt(String key, Value v, Typ t) {
    path.key(key);
    Value out = nest(v, t);
    path.pop();
    return out;
  }

  /** Decodes {@code v} with {@code t} one level deeper. */
  private Value nest(Value v, Typ t) {
    if (depth >= lim.maxDepth()) {
      throw fail(ErrorCode.NESTING_TOO_DEEP, "nesting deeper than " + lim.maxDepth() + " levels");
    }
    if (++nodes > ValueCheck.MAX_NODES) {
      throw fail(ErrorCode.TOO_MANY_NODES, "the value has more than " + ValueCheck.MAX_NODES + " nodes");
    }
    budget += STEPS_PER_VALUE;
    depth++;
    Value out = value(v, t);
    depth--;
    return out;
  }

  /** Decodes {@code v} with {@code t}; the result is {@code v} itself when nothing changes. */
  Value value(Value v, Typ t) {
    if (++steps > budget) {
      throw fail(ErrorCode.STEP_BUDGET,
          "decode budget of " + budget + " steps exceeded (a schema doing more work than the input justifies)");
    }
    Typ rt = t.resolve();
    Value out = reading ? readJson(v, rt, t) : resolved(v, rt, t);
    if (depth >= lim.maxDepth() && emptyLevel(out)) {
      // An empty record, array or record payload is a level, as when parsing (spec §7), though
      // it has nothing in it to nest.
      throw fail(ErrorCode.NESTING_TOO_DEEP, "nesting deeper than " + lim.maxDepth() + " levels");
    }
    if (codecs.isEmpty()) {
      return out;
    }
    // A codec applies wherever its type occurs, also behind other names.
    for (Typ x = t; ; x = x.inst.body) {
      Codec<?> codec = codecs.forType(x);
      if (codec != null) {
        applyCodec(codec, out);
      }
      if (x.kind != Kind.REF) {
        return out;
      }
    }
  }

  private void applyCodec(Codec<?> codec, Value v) {
    try {
      codec.decode(v);
    } catch (HausException e) {
      throw fail(e.code(), codec.typeId() + " rejects the value: " + e.reason());
    } catch (RuntimeException e) {
      throw fail(ErrorCode.CODEC_REJECTED, codec.typeId() + " rejects the value: " + e.getMessage());
    }
  }

  /** Whether {@code v} is an empty record or array, or a variant with an empty record payload. */
  private static boolean emptyLevel(Value v) {
    switch (v.kind()) {
      case ARRAY:
        return ((Value.Array) v).size() == 0;
      case RECORD:
        return ((Value.Record) v).size() == 0;
      case VARIANT:
        Value.Record r = ((Value.Variant) v).payload();
        return r != null && r.size() == 0;
      default:
        return false;
    }
  }

  private Value resolved(Value v, Typ rt, Typ t) {
    switch (rt.kind) {
      case TIME:
        return time(v, rt.name, t);
      case ARRAY: {
        if (!(v instanceof Value.Array)) {
          throw mismatch(v, t);
        }
        Value[] a = ((Value.Array) v).unsafeItems();
        Value[] out = null;
        for (int i = 0; i < a.length; i++) {
          Value y = childAt(i, a[i], rt.elem);
          if (y != a[i] && out == null) {
            out = a.clone();
          }
          if (out != null) {
            out[i] = y;
          }
        }
        return out == null ? v : new Value.Array(out);
      }
      case MAP:
        if (!(v instanceof Value.Record)) {
          throw mismatch(v, t);
        }
        return mapEntries((Value.Record) v, rt.elem);
      case MAYBE: {
        if (v instanceof Value.Variant) {
          Value.Variant x = (Value.Variant) v;
          if (x.tag().equals("None") && x.size() == 0) {
            return v;
          }
          if (x.tag().equals("Some") && x.size() == 1) {
            Value y = childAt(0, x.get(0), rt.elem);
            return y == x.get(0) ? v : new Value.Variant("Some", new Value[] {y});
          }
        }
        throw fail(notCase(v, "None", "Some"),
            "expected None or Some(…) (" + SchemaTypes.describe(t) + "), found " + found(v));
      }
      case SECRET:
        return secret(v, rt.elem);
      case RECORD:
        if (!(v instanceof Value.Record)) {
          throw mismatch(v, t);
        }
        return record((Value.Record) v, rt.rec);
      case VARIANT:
        return variant(v, rt.vrt, t);
      case PARAM:
        return v;
      default:
        return builtin(v, rt.kind, t);
    }
  }

  private HausException mismatch(Value v, Typ t) {
    return fail(ErrorCode.TYPE_MISMATCH, "expected " + SchemaTypes.describe(t) + ", found " + found(v));
  }

  /**
   * The code for a value that isn't one of the cases of a closed variant with the tags (Bool,
   * Maybe): a known tag with the wrong payload, an unknown tag, or not a variant at all.
   */
  private static ErrorCode notCase(Value v, String a, String b) {
    if (!(v instanceof Value.Variant)) {
      return ErrorCode.TYPE_MISMATCH;
    }
    String tag = ((Value.Variant) v).tag();
    return tag.equals(a) || tag.equals(b) ? ErrorCode.WRONG_PAYLOAD : ErrorCode.UNKNOWN_TAG;
  }

  /**
   * Decodes {@code v} as {@code item}, and replaces any error inside by one at the secret itself,
   * with its type only (spec §15): messages quote values, keys and tags of the data, and paths may
   * name keys.
   */
  private Value secret(Value v, Typ item) {
    int at = path.size();
    int d = depth;
    try {
      return value(v, item);
    } catch (HausException e) {
      path.truncate(at);
      depth = d;
      throw fail(ErrorCode.INVALID_SECRET, "expected " + SchemaTypes.describe(item) + " (a Secret: the value is not shown)");
    }
  }

  private void text(String s) {
    if (encoding && Quoting.hasLoneSurrogate(s)) {
      throw fail(ErrorCode.CANNOT_ENCODE, "a string that isn't valid UTF-8");
    }
  }

  private Value builtin(Value v, Kind k, Typ t) {
    switch (k) {
      case ANY:
        return raw(v);
      case STRING:
        if (v instanceof Value.Text) {
          text(((Value.Text) v).value());
          return v;
        }
        break;
      case BYTES:
        if (v instanceof Value.Bytes) {
          return v;
        }
        break;
      case BOOL:
        if (v instanceof Value.Variant) {
          Value.Variant x = (Value.Variant) v;
          boolean known = x.tag().equals("True") || x.tag().equals("False");
          if (known && x.size() == 0) {
            return v;
          }
          if (known) {
            throw fail(ErrorCode.WRONG_PAYLOAD,
                "expected " + SchemaTypes.describe(t) + ", found " + found(v) + " with a payload");
          }
          throw fail(ErrorCode.UNKNOWN_TAG, "expected " + SchemaTypes.describe(t) + " (True or False), found " + found(v));
        }
        break;
      case FLOAT32:
      case FLOAT64:
        if (v instanceof Value.Variant && ((Value.Variant) v).size() == 0 && isFloatTag(((Value.Variant) v).tag())) {
          return v;
        }
        if (v instanceof Value.Number) {
          return floatValue((Value.Number) v, k);
        }
        break;
      case DECIMAL:
        if (v instanceof Value.Number) {
          number((Value.Number) v);
          return v;
        }
        break;
      default: // the integer types
        if (v instanceof Value.Number) {
          return integer((Value.Number) v, k);
        }
    }
    throw mismatch(v, t);
  }

  private static boolean isFloatTag(String tag) {
    return tag.equals("NaN") || tag.equals("Infinity") || tag.equals("NegInfinity");
  }

  /** Checks a number built in code against the number limits. */
  private void number(Value.Number n) {
    if (encoding) {
      HausException e = Numbers.overLimits(n.literal(), lim);
      if (e != null) {
        throw fail(e.code(), e.reason());
      }
    }
  }

  private Value integer(Value.Number n, Kind k) {
    number(n);
    String text = n.literal();
    int start = text.startsWith("-") ? 1 : 0;
    boolean digits = text.length() > start;
    boolean zero = true;
    for (int i = start; i < text.length(); i++) {
      char c = text.charAt(i);
      digits &= c >= '0' && c <= '9';
      zero &= c == '0';
    }
    if (!digits) {
      throw fail(ErrorCode.NOT_AN_INTEGER, "expected a whole number (" + k.builtin + "), found " + shortNumber(text));
    }
    if (k != Kind.INT && !zero && !inRange(text, k)) {
      throw fail(ErrorCode.OUT_OF_RANGE,
          shortNumber(text) + " is out of range for " + k.builtin + " (" + low(k) + " to " + high(k) + ")");
    }
    if (zero && !text.equals("0")) {
      return ZERO; // -0 is 0 (spec §15)
    }
    return n;
  }

  /** The bits of a fixed-size integer type. */
  static int bits(Kind k) {
    switch (k) {
      case INT8:
      case UINT8:
        return 8;
      case INT16:
      case UINT16:
        return 16;
      case INT32:
      case UINT32:
        return 32;
      default:
        return 64;
    }
  }

  static boolean signed(Kind k) {
    return k == Kind.INT8 || k == Kind.INT16 || k == Kind.INT32 || k == Kind.INT64;
  }

  private static final BigInteger LONG_MAX = BigInteger.valueOf(Long.MAX_VALUE);

  static String low(Kind k) {
    return signed(k) ? Long.toString(-1L << (bits(k) - 1)) : "0";
  }

  static String high(Kind k) {
    if (signed(k)) {
      return Long.toString((1L << (bits(k) - 1)) - 1);
    }
    return bits(k) == 64 ? LONG_MAX.shiftLeft(1).add(BigInteger.ONE).toString() : Long.toString((1L << bits(k)) - 1);
  }

  /** Whether the decimal integer {@code text} (not zero) is within the range of {@code k}. */
  private static boolean inRange(String text, Kind k) {
    boolean negative = text.charAt(0) == '-';
    if (negative && !signed(k)) {
      return false;
    }
    int length = text.length() - (negative ? 1 : 0);
    if (length > 20) {
      return false;
    }
    if (length <= 18) {
      // Fits a long: every bound but UInt64's maximum does too.
      long n = Long.parseLong(text);
      int bits = bits(k);
      if (signed(k)) {
        return bits == 64 || n >= -1L << (bits - 1) && n <= (1L << (bits - 1)) - 1;
      }
      return bits == 64 || n <= (1L << bits) - 1;
    }
    BigInteger n = new BigInteger(text);
    return n.compareTo(new BigInteger(low(k))) >= 0 && n.compareTo(new BigInteger(high(k))) <= 0;
  }

  /**
   * Rounds a number to the nearest float of the type, directly from its exact decimal value, and
   * writes it in its one spelling (spec §15).
   */
  private Value floatValue(Value.Number n, Kind k) {
    number(n);
    boolean f32 = k == Kind.FLOAT32;
    String text = n.literal();
    if (SchemaFloats.isOneSpelling(text, f32)) {
      return n;
    }
    double f = SchemaFloats.parse(text, f32);
    if (Double.isInfinite(f)) {
      throw fail(ErrorCode.OUT_OF_RANGE, shortNumber(text) + " is too large for " + k.builtin);
    }
    String spelled = SchemaFloats.format(f, f32);
    return spelled.equals(text) ? n : new Value.Number(spelled);
  }

  /** A value kept as it is (an Any, an unknown tag): one a writer takes, within the limits (§9.8). */
  private Value raw(Value v) {
    try {
      ValueCheck.check(v, lim);
    } catch (HausException e) {
      ErrorCode code = e.code() == ErrorCode.CANNOT_ENCODE && !encoding ? ErrorCode.TYPE_MISMATCH : e.code();
      String inner = e.path() == null ? "" : e.path().substring(1);
      throw HausException.at(path + inner, code, e.reason());
    }
    nodes++;
    return v;
  }

  private Value time(Value v, String name, Typ t) {
    if (!(v instanceof Value.Variant) || !((Value.Variant) v).tag().equals(name)) {
      throw mismatch(v, t);
    }
    Value.Variant x = (Value.Variant) v;
    if (x.size() != 1 || !(x.get(0) instanceof Value.Text)) {
      throw fail(ErrorCode.TYPE_MISMATCH, "write " + name + "(\"…\") with one string");
    }
    String s = ((Value.Text) x.get(0)).value();
    text(s);
    String why = StdTime.problem(name, s);
    if (why != null) {
      path.index(0);
      throw fail(ErrorCode.INVALID_TIME, why);
    }
    return v;
  }

  private void key(String k) {
    if (encoding && Quoting.hasLoneSurrogate(k)) {
      throw fail(ErrorCode.CANNOT_ENCODE, "a key that isn't valid UTF-8");
    }
  }

  private Value mapEntries(Value.Record r, Typ elem) {
    String[] keys = r.unsafeKeys();
    Value[] values = r.unsafeValues();
    Value[] out = null;
    for (int i = 0; i < keys.length; i++) {
      key(keys[i]);
      Value y = childAt(keys[i], values[i], elem);
      if (y != values[i] && out == null) {
        out = values.clone();
      }
      if (out != null) {
        out[i] = y;
      }
    }
    return out == null ? r : new Value.Record(keys, out, Keys.of(keys, keys.length), r.bareKeys());
  }

  private void missingFields(Value.Record r, RecordType rt) {
    List<String> missing = null;
    for (FieldType f : rt.required) {
      if (!r.containsKey(f.key())) {
        if (missing == null) {
          missing = new ArrayList<>();
        }
        missing.add(SchemaText.quoteKey(f.key()));
      }
    }
    if (missing != null) {
      String s = missing.size() > 1 ? "s" : "";
      if (missing.size() > 5) {
        missing = new ArrayList<>(missing.subList(0, 5));
        missing.add("…");
      }
      throw fail(ErrorCode.MISSING_FIELD, "missing field" + s + " " + String.join(", ", missing));
    }
  }

  private HausException unknownField(String k) {
    path.key(k);
    return fail(ErrorCode.UNKNOWN_FIELD, SchemaText.quoteKey(k) + " is not a field of this closed record");
  }

  private Value record(Value.Record r, RecordType rt) {
    String[] keys = r.unsafeKeys();
    Value[] values = r.unsafeValues();
    // Each key's field, looked up once; the keys are distinct, so all required fields are there
    // when as many keys name one. Missing fields are reported before anything else.
    int base = fieldTop;
    if (base + keys.length > fieldStack.length) {
      fieldStack = Arrays.copyOf(fieldStack, Math.max(2 * fieldStack.length, base + keys.length));
    }
    int required = 0;
    for (int i = 0; i < keys.length; i++) {
      FieldType f = rt.field(keys[i]);
      fieldStack[base + i] = f;
      if (f != null && !f.optional()) {
        required++;
      }
    }
    if (required < rt.required.length) {
      missingFields(r, rt);
    }
    fieldTop = base + keys.length;
    // Unchanged until a field is dropped or a value changes; then the fields kept so far are copied.
    String[] outKeys = null;
    Value[] outValues = null;
    int n = 0;
    for (int i = 0; i < keys.length; i++) {
      String k = keys[i];
      FieldType f = fieldStack[base + i]; // the stack may have grown below: read the field
      if (f == null) {
        if (rt.closed) {
          throw unknownField(k);
        }
        if (outKeys == null) {
          outKeys = Arrays.copyOf(keys, keys.length);
          outValues = Arrays.copyOf(values, keys.length);
          n = i;
        }
        continue;
      }
      if (!r.bareKeys()) {
        key(k); // an identifier is ASCII
      }
      Value y = childAt(k, values[i], f.typ());
      if (y != values[i] && outKeys == null) {
        outKeys = Arrays.copyOf(keys, keys.length);
        outValues = Arrays.copyOf(values, keys.length);
        n = i;
      }
      if (outKeys != null) {
        outKeys[n] = k;
        outValues[n++] = y;
      }
    }
    fieldTop = base; // the schema's fields: nothing to let go of
    if (outKeys == null) {
      return r;
    }
    if (n == keys.length) {
      // The same keys in the same places: the record's index of them still holds.
      return new Value.Record(outKeys, outValues, r.index(), r.bareKeys());
    }
    return owned(outKeys, outValues, n, r.bareKeys());
  }

  /** A record of the first {@code n} fields, whose keys are distinct. */
  static Value.Record owned(String[] keys, Value[] values, int n) {
    return owned(keys, values, n, false);
  }

  /** {@link #owned(String[], Value[], int)}, and whether every key is known to be an identifier. */
  private static Value.Record owned(String[] keys, Value[] values, int n, boolean bareKeys) {
    if (n < keys.length) {
      keys = Arrays.copyOf(keys, n);
      values = Arrays.copyOf(values, n);
    }
    return new Value.Record(keys, values, Keys.of(keys, n), bareKeys);
  }

  private Value variant(Value v, VariantType vt, Typ t) {
    if (!(v instanceof Value.Variant)) {
      throw mismatch(v, t);
    }
    Value.Variant x = (Value.Variant) v;
    CaseType c = vt.caseOf(x.tag());
    if (c == null) {
      if (vt.open) {
        return raw(v);
      }
      throw fail(ErrorCode.UNKNOWN_TAG,
          SchemaText.quote(x.tag()) + " is not allowed here: expected " + SchemaTypes.tags(vt));
    }
    Value[] args = x.unsafeArgs();
    switch (c.payload) {
      case NONE:
        if (args.length == 0) {
          return v;
        }
        throw fail(ErrorCode.WRONG_PAYLOAD, x.tag() + " takes no payload");
      case RECORD:
      case NAMED: {
        Value.Record r = x.payload();
        if (r == null) {
          throw fail(ErrorCode.WRONG_PAYLOAD,
              x.tag() + " takes one argument, a record; found " + foundArgs(args));
        }
        // Tag { … }: the record is at the variant's level and place.
        Value y = c.payload == Payload.RECORD ? record(r, c.rec) : value(r, c.named);
        return y == r ? v : new Value.Variant(x.tag(), new Value[] {y});
      }
      default:
        break;
    }
    if (c.items.length != args.length) {
      List<String> described = new ArrayList<>();
      for (Typ it : c.items) {
        described.add(SchemaTypes.describe(it));
      }
      throw fail(ErrorCode.WRONG_PAYLOAD, x.tag() + " takes " + c.items.length + " argument" + (c.items.length == 1 ? "" : "s")
          + " (" + String.join(", ", described) + "), found " + args.length);
    }
    Value[] out = null;
    for (int i = 0; i < args.length; i++) {
      Value y = childAt(i, args[i], c.items[i]);
      if (y != args[i] && out == null) {
        out = args.clone();
      }
      if (out != null) {
        out[i] = y;
      }
    }
    return out == null ? v : new Value.Variant(x.tag(), out);
  }

  private static String foundArgs(Value[] args) {
    switch (args.length) {
      case 0:
        return "no payload";
      case 1:
        return found(args[0]);
      default:
        return args.length + " arguments";
    }
  }

  /** At most 30 characters of a number's text, for messages. */
  static String shortNumber(String text) {
    return text.codePointCount(0, text.length()) > 30 ? text.substring(0, 30) + "…" : text;
  }

  /** A short description of a value, for messages. */
  static String found(Value v) {
    switch (v.kind()) {
      case STRING: {
        String s = ((Value.Text) v).value();
        if (s.codePointCount(0, s.length()) > 20 || Quoting.hasLoneSurrogate(s)) {
          return "a string";
        }
        return "the string " + SchemaText.quoted(s);
      }
      case NUMBER:
        return "the number " + shortNumber(((Value.Number) v).literal());
      case BYTES:
        return "bytes";
      case ARRAY:
        return "an array";
      case RECORD:
        return "a record";
      default:
        return "the tag " + SchemaText.quote(((Value.Variant) v).tag());
    }
  }

  // ── Reading schema-based JSON (§16.3) ──

  /** Reads the JSON {@code j} (as the import reads it) with the type {@code t}, resolved {@code rt}. */
  private Value readJson(Value j, Typ rt, Typ t) {
    switch (rt.kind) {
      case STRING:
        if (j instanceof Value.Text) {
          length(((Value.Text) j).value(), ErrorCode.STRING_TOO_LONG, "string");
          return j;
        }
        throw jsonMismatch(j, t, "a string");
      case TIME: {
        if (!(j instanceof Value.Text)) {
          throw jsonMismatch(j, t, "a string");
        }
        String why = StdTime.problem(rt.name, ((Value.Text) j).value());
        if (why != null) {
          throw fail(ErrorCode.INVALID_TIME, why);
        }
        return new Value.Variant(rt.name, new Value[] {j});
      }
      case BYTES: {
        if (!(j instanceof Value.Text)) {
          throw jsonMismatch(j, t, "a string in base64 with padding");
        }
        byte[] b = fromBase64(((Value.Text) j).value());
        if (b == null) {
          throw fail(ErrorCode.INVALID_BASE64, "expected base64 with padding (RFC 4648 §4), found " + describeJson(j));
        }
        if (2L * b.length > lim.maxStringLength()) {
          throw fail(ErrorCode.STRING_TOO_LONG, "a byte string of " + b.length + " bytes, more than the limit of "
              + lim.maxStringLength() + " characters");
        }
        return new Value.Bytes(b);
      }
      case BOOL:
        if (j instanceof Value.Variant && !((Value.Variant) j).tag().equals("None")) {
          return j;
        }
        throw jsonMismatch(j, t, "true or false");
      case INT8:
      case INT16:
      case INT32:
      case UINT8:
      case UINT16:
      case UINT32:
        if (j instanceof Value.Number) {
          return integer((Value.Number) j, rt.kind);
        }
        throw jsonMismatch(j, t, "a number");
      case INT:
      case INT64:
      case UINT64:
        if (j instanceof Value.Text) {
          return intString(((Value.Text) j).value(), rt.kind);
        }
        throw jsonMismatch(j, t, "a string of a decimal integer");
      case FLOAT32:
      case FLOAT64:
        if (j instanceof Value.Number) {
          return floatValue((Value.Number) j, rt.kind);
        }
        if (j instanceof Value.Text) {
          switch (((Value.Text) j).value()) {
            case "NaN":
              return NAN;
            case "Infinity":
              return INFINITY;
            case "-Infinity":
              return NEG_INFINITY;
            default:
              break;
          }
        }
        throw jsonMismatch(j, t, "a number, \"NaN\", \"Infinity\" or \"-Infinity\"");
      case DECIMAL:
        if (j instanceof Value.Text) {
          return decimalString(((Value.Text) j).value());
        }
        throw jsonMismatch(j, t, "a string of a number");
      case ANY:
        return SelfDescribing.value(j, lim, depth, path.toString());
      case ARRAY: {
        if (!(j instanceof Value.Array)) {
          throw jsonMismatch(j, t, "an array");
        }
        Value[] a = ((Value.Array) j).unsafeItems();
        Value[] out = new Value[a.length];
        for (int i = 0; i < a.length; i++) {
          out[i] = childAt(i, a[i], rt.elem);
        }
        return new Value.Array(out);
      }
      case MAP: {
        if (!(j instanceof Value.Record)) {
          throw jsonMismatch(j, t, "an object");
        }
        Value.Record r = (Value.Record) j;
        String[] keys = r.unsafeKeys();
        Value[] values = r.unsafeValues();
        Value[] out = new Value[keys.length];
        for (int i = 0; i < keys.length; i++) {
          path.key(keys[i]);
          length(keys[i], ErrorCode.KEY_TOO_LONG, "key");
          out[i] = nest(values[i], rt.elem);
          path.pop();
        }
        return new Value.Record(keys, out, Keys.of(keys, keys.length));
      }
      case MAYBE:
        return readMaybe(j, rt, t);
      case SECRET:
        return secret(j, rt.elem);
      case RECORD:
        if (!(j instanceof Value.Record)) {
          throw jsonMismatch(j, t, "an object");
        }
        return readRecord((Value.Record) j, rt.rec, false);
      case VARIANT:
        return readVariant(j, rt.vrt, t);
      default:
        // A type parameter: only in the template of a generic type, which values aren't read with.
        imported(j, depth);
        return j;
    }
  }

  private HausException jsonMismatch(Value j, Typ t, String form) {
    return fail(ErrorCode.TYPE_MISMATCH, "expected " + SchemaTypes.describe(t) + " (" + form + "), found " + describeJson(j));
  }

  /** Checks a string or key of the value read against the string limit, in characters after escapes. */
  private void length(String s, ErrorCode code, String what) {
    if (s.length() > lim.maxStringLength() && s.codePointCount(0, s.length()) > lim.maxStringLength()) {
      throw fail(code, "a " + what + " longer than the limit of " + lim.maxStringLength() + " characters");
    }
  }

  /** Checks the name of a member that is a key of the value read (a listed field's), at that member. */
  private void keyLength(String k) {
    if (k.length() > lim.maxStringLength()) {
      path.key(k);
      length(k, ErrorCode.KEY_TOO_LONG, "key");
      path.pop();
    }
  }

  /** Checks a tag of the value read, a {@code "_tag"} or an enum's string, against the string limit (§16, "Limits"). */
  private void tagLength(String tag) {
    if (tag.length() > lim.maxStringLength()) {
      throw fail(ErrorCode.TAG_TOO_LONG, "a tag longer than the limit of " + lim.maxStringLength() + " characters");
    }
  }

  /** Reads Int, Int64 and UInt64, written as a string of a decimal integer: {@code -?(0|[1-9][0-9]*)}. */
  private Value intString(String s, Kind k) {
    if (!isDecimalInteger(s)) {
      ErrorCode code = isJsonNumber(s) ? ErrorCode.NOT_AN_INTEGER : ErrorCode.INVALID_NUMBER;
      throw fail(code, "expected a decimal integer in a string (" + k.builtin + "), found " + SchemaText.quote(s));
    }
    // A sized type checks its range: a number too long for the limit is out of range for it.
    if (k == Kind.INT && s.length() > lim.maxNumberLength()) {
      throw fail(ErrorCode.NUMBER_TOO_LONG,
          "a number of " + s.length() + " characters, more than the limit of " + lim.maxNumberLength());
    }
    return integer(new Value.Number(s), k);
  }

  /** Reads a Decimal: a JSON number literal in a string, normalized (spec §2). */
  private Value decimalString(String s) {
    if (!isJsonNumber(s)) {
      throw fail(ErrorCode.INVALID_NUMBER, "expected a number literal in a string (Decimal), found " + SchemaText.quote(s));
    }
    Value.Number n = new Value.Number(normalizeJsonNumber(s));
    HausException e = Numbers.overLimits(n.literal(), lim);
    if (e != null) {
      throw fail(e.code(), e.reason());
    }
    return n;
  }

  private Value readMaybe(Value j, Typ rt, Typ t) {
    if (rt.jsonNull) {
      if (isNull(j)) {
        return NONE;
      }
      // Some(x) is one level deeper than the JSON shows.
      return new Value.Variant("Some", new Value[] {nest(j, rt.elem)});
    }
    if (!(j instanceof Value.Record)) {
      throw jsonMismatch(j, t, "{\"_tag\": \"None\"} or {\"_tag\": \"Some\", \"value\": …}");
    }
    Value.Record r = (Value.Record) j;
    String tag = tagMember(r);
    switch (tag) {
      case "None":
        onlyMembers(r, null);
        return NONE;
      case "Some":
        return new Value.Variant("Some", new Value[] {childAt("value", member(r, "value", tag), rt.elem)});
      default:
        throw fail(ErrorCode.UNKNOWN_TAG, SchemaText.quote(tag) + " is not allowed here: expected None or Some");
    }
  }

  /** The {@code "_tag"} of an object: missing-member without one, invalid-tag if it isn't a tag, at the object. */
  private String tagMember(Value.Record r) {
    Value j = r.get("_tag");
    if (j == null) {
      throw fail(ErrorCode.MISSING_MEMBER, "expected the member \"_tag\", found " + describeJson(r));
    }
    if (!(j instanceof Value.Text)) {
      throw fail(ErrorCode.INVALID_TAG, "expected a tag in '_tag', found " + describeJson(j));
    }
    String s = ((Value.Text) j).value();
    if (!Scan.isTag(s)) {
      throw fail(ErrorCode.INVALID_TAG, "expected a tag ([A-Z][A-Za-z0-9_]*) in '_tag', found " + SchemaText.quote(s));
    }
    return s;
  }

  /** The member {@code name} of an object with {@code "_tag"} (and no other). */
  private Value member(Value.Record r, String name, String tag) {
    Value x = r.get(name);
    if (x == null) {
      throw fail(ErrorCode.MISSING_MEMBER, tag + " needs the member \"" + name + "\"");
    }
    onlyMembers(r, name);
    return x;
  }

  /** Checks that an object has no members besides {@code "_tag"} and {@code name} (if not null). */
  private void onlyMembers(Value.Record r, String name) {
    for (int i = 0; i < r.size(); i++) {
      String k = r.keyAt(i);
      if (!k.equals("_tag") && (name == null || !k.equals(name))) {
        path.key(k);
        throw fail(ErrorCode.UNEXPECTED_MEMBER, "unexpected member " + SchemaText.quote(k));
      }
    }
  }

  /** Reads an object with a record type; with {@code payload}, its {@code "_tag"} is the case's, not a field. */
  private Value readRecord(Value.Record r, RecordType rt, boolean payload) {
    missingFields(r, rt);
    String[] keys = new String[Math.min(r.size(), rt.fields.length)];
    Value[] values = new Value[keys.length];
    int n = 0;
    for (int i = 0; i < r.size(); i++) {
      String k = r.keyAt(i);
      if (payload && k.equals("_tag")) {
        continue;
      }
      FieldType f = rt.field(k);
      if (f == null) {
        if (rt.closed) {
          throw unknownField(k);
        }
        continue;
      }
      keyLength(k);
      keys[n] = f.key();
      values[n++] = childAt(k, r.valueAt(i), f.typ());
    }
    return owned(keys, values, n);
  }

  private Value readVariant(Value j, VariantType vt, Typ t) {
    if (vt.enumLike) {
      if (!(j instanceof Value.Text)) {
        throw jsonMismatch(j, t, "a string");
      }
      String s = ((Value.Text) j).value();
      if (!Scan.isTag(s)) {
        throw fail(ErrorCode.INVALID_TAG, "expected a tag ([A-Z][A-Za-z0-9_]*), one of " + SchemaTypes.tags(vt)
            + ", found " + SchemaText.quote(s));
      }
      CaseType c = vt.caseOf(s);
      if (c == null) {
        throw fail(ErrorCode.UNKNOWN_TAG, SchemaText.quote(s) + " is not allowed here: expected " + SchemaTypes.tags(vt));
      }
      tagLength(c.tag);
      return new Value.Variant(c.tag, new Value[0]);
    }
    if (!(j instanceof Value.Record)) {
      throw jsonMismatch(j, t, "an object with \"_tag\"");
    }
    Value.Record r = (Value.Record) j;
    String tag = tagMember(r);
    CaseType c = vt.caseOf(tag);
    if (c == null) {
      if (!vt.open) {
        throw fail(ErrorCode.UNKNOWN_TAG, SchemaText.quote(tag) + " is not allowed here: expected " + SchemaTypes.tags(vt));
      }
      return unknownJson(tag, r);
    }
    tagLength(c.tag);
    switch (c.payload) {
      case NONE:
        onlyMembers(r, null);
        return new Value.Variant(c.tag, new Value[0]);
      case RECORD:
      case NAMED: {
        reserved(c);
        // The record's fields beside "_tag", at the variant's level and place.
        Value y = c.payload == Payload.RECORD ? readRecord(r, c.rec, true) : value(withoutTag(r), c.named);
        return new Value.Variant(c.tag, new Value[] {y});
      }
      default:
        break;
    }
    if (c.items.length == 1) {
      return new Value.Variant(c.tag, new Value[] {childAt("value", member(r, "value", tag), c.items[0])});
    }
    Value x = member(r, "values", tag);
    // A wrong payload is at the variant (§15), as in haus text.
    if (!(x instanceof Value.Array)) {
      throw fail(ErrorCode.WRONG_PAYLOAD, tag + " takes " + c.items.length + " arguments, as an array in \"values\"; found "
          + describeJson(x));
    }
    Value[] a = ((Value.Array) x).unsafeItems();
    if (a.length != c.items.length) {
      throw fail(ErrorCode.WRONG_PAYLOAD, tag + " takes " + c.items.length + " arguments, found " + a.length);
    }
    path.key("values");
    Value[] args = new Value[a.length];
    for (int i = 0; i < a.length; i++) {
      args[i] = childAt(i, a[i], c.items[i]);
    }
    path.pop();
    return new Value.Variant(c.tag, args);
  }

  /** The members of an object other than {@code "_tag"}, as a record. */
  private static Value.Record withoutTag(Value.Record r) {
    String[] keys = new String[r.size()];
    Value[] values = new Value[r.size()];
    int n = 0;
    for (int i = 0; i < r.size(); i++) {
      if (!r.keyAt(i).equals("_tag")) {
        keys[n] = r.keyAt(i);
        values[n++] = r.valueAt(i);
      }
    }
    return owned(keys, values, n);
  }

  /**
   * Reads a tag an open variant doesn't list (§16.3): the bare tag; with {@code "_args"} alone, its
   * arguments as self-describing values; otherwise its other members as a record payload, by the
   * import.
   */
  private Value unknownJson(String tag, Value.Record r) {
    tagLength(tag);
    if (r.size() == 1) {
      return new Value.Variant(tag, new Value[0]);
    }
    Value args = r.get("_args");
    if (args != null && r.size() == 2) {
      return SelfDescribing.args(tag, args, lim, depth, path.toString());
    }
    Value.Record payload = withoutTag(r);
    imported(payload, depth);
    return new Value.Variant(tag, new Value[] {payload});
  }

  /**
   * Checks a value the import gave (§16.1) against the limits: its strings and keys, and its
   * nesting, for a value at {@code d} (a record payload counts as the variant's level).
   */
  private void imported(Value v, int d) {
    switch (v.kind()) {
      case STRING:
        length(((Value.Text) v).value(), ErrorCode.STRING_TOO_LONG, "string");
        break;
      case ARRAY: {
        Value[] a = ((Value.Array) v).unsafeItems();
        if (a.length > 0 && d >= lim.maxDepth()) {
          throw fail(ErrorCode.NESTING_TOO_DEEP, "nesting deeper than " + lim.maxDepth() + " levels");
        }
        for (int i = 0; i < a.length; i++) {
          path.index(i);
          imported(a[i], d + 1);
          path.pop();
        }
        break;
      }
      case RECORD: {
        Value.Record r = (Value.Record) v;
        if (r.size() > 0 && d >= lim.maxDepth()) {
          throw fail(ErrorCode.NESTING_TOO_DEEP, "nesting deeper than " + lim.maxDepth() + " levels");
        }
        for (int i = 0; i < r.size(); i++) {
          path.key(r.keyAt(i));
          length(r.keyAt(i), ErrorCode.KEY_TOO_LONG, "key");
          imported(r.valueAt(i), d + 1);
          path.pop();
        }
        break;
      }
      default:
        break;
    }
  }

  /** Fails for a record case with a field named {@code _tag} or {@code _args}, which has no JSON form. */
  private void reserved(CaseType c) {
    String f = SchemaLoader.reservedField(c);
    if (f != null) {
      throw fail(ErrorCode.NO_JSON_FORM, c.tag + " has a field named " + f + ", so it has no schema-based JSON form");
    }
  }

  static boolean isNull(Value j) {
    return j instanceof Value.Variant && ((Value.Variant) j).tag().equals("None");
  }

  /** Whether {@code s} is {@code -?(0|[1-9][0-9]*)}. */
  static boolean isDecimalInteger(String s) {
    int i = s.startsWith("-") ? 1 : 0;
    if (i == s.length() || s.charAt(i) == '0' && s.length() > i + 1) {
      return false;
    }
    for (; i < s.length(); i++) {
      if (s.charAt(i) < '0' || s.charAt(i) > '9') {
        return false;
      }
    }
    return true;
  }

  /** Whether {@code s} is a JSON number literal: {@code -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?}. */
  static boolean isJsonNumber(String s) {
    int[] i = {0};
    if (i[0] < s.length() && s.charAt(i[0]) == '-') {
      i[0]++;
    }
    if (i[0] < s.length() && s.charAt(i[0]) == '0') {
      i[0]++;
    } else if (digits(s, i) == 0) {
      return false;
    }
    if (i[0] < s.length() && s.charAt(i[0]) == '.') {
      i[0]++;
      if (digits(s, i) == 0) {
        return false;
      }
    }
    if (i[0] < s.length() && (s.charAt(i[0]) == 'e' || s.charAt(i[0]) == 'E')) {
      i[0]++;
      if (i[0] < s.length() && (s.charAt(i[0]) == '+' || s.charAt(i[0]) == '-')) {
        i[0]++;
      }
      if (digits(s, i) == 0) {
        return false;
      }
    }
    return i[0] == s.length();
  }

  private static int digits(String s, int[] i) {
    int start = i[0];
    while (i[0] < s.length() && s.charAt(i[0]) >= '0' && s.charAt(i[0]) <= '9') {
      i[0]++;
    }
    return i[0] - start;
  }

  /** A JSON number literal normalized (spec §2): the exponent as {@code e}, without {@code +} and leading zeros. */
  static String normalizeJsonNumber(String s) {
    int i = Math.max(s.indexOf('e'), s.indexOf('E'));
    if (i < 0) {
      return s;
    }
    String exp = s.substring(i + 1);
    boolean negative = exp.startsWith("-");
    int j = 0;
    while (j < exp.length() && (exp.charAt(j) == '+' || exp.charAt(j) == '-')) {
      j++;
    }
    while (j < exp.length() && exp.charAt(j) == '0') {
      j++;
    }
    exp = exp.substring(j);
    if (exp.isEmpty()) {
      return s.substring(0, i) + "e0";
    }
    return s.substring(0, i) + (negative ? "e-" : "e") + exp;
  }

  /** Canonical padded base64 (RFC 4648 §4) decoded, or null: no whitespace, no URL alphabet, zero pad bits. */
  static byte[] fromBase64(String s) {
    if (s.length() % 4 != 0) {
      return null;
    }
    byte[] b;
    try {
      b = Base64.getDecoder().decode(s);
    } catch (IllegalArgumentException e) {
      return null;
    }
    // The decoder ignores the pad bits: only the canonical text encodes back to itself.
    return Base64.getEncoder().encodeToString(b).equals(s) ? b : null;
  }

  /** A short description of JSON (read as the import reads it), for messages. */
  static String describeJson(Value j) {
    switch (j.kind()) {
      case STRING:
        return "the string " + SchemaText.quote(((Value.Text) j).value());
      case NUMBER:
        return "the number " + shortNumber(((Value.Number) j).literal());
      case ARRAY:
        return "an array";
      case RECORD:
        return ((Value.Record) j).size() == 0 ? "an empty object" : "an object";
      case VARIANT: {
        String tag = ((Value.Variant) j).tag();
        return tag.equals("True") ? "true" : tag.equals("False") ? "false" : "null";
      }
      default:
        return "nothing";
    }
  }
}
