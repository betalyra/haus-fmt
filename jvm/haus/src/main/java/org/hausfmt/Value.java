package org.hausfmt;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.AbstractList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * A haus value (spec §1): a {@link Number}, {@link Text}, {@link Bytes}, {@link Array}, {@link
 * Record} or {@link Variant}. The set is closed, and every value is immutable.
 *
 * <p>{@code equals} is haus equality (spec §2): numbers by their normalized literals, strings by
 * code points, records by their sets of keys whatever the order, {@code Tag { … }} and {@code
 * Tag({ … })} alike. {@code toString} is the value in the compact layout, on one line.
 *
 * <p>Values are built with the static methods, {@code Value.record(Value.field("id",
 * Value.number(7)))}, or read by {@link Haus#parse}. A value built in code may nest as deeply as
 * memory allows (spec §7): {@code equals}, {@code hashCode} (computed once per container, without
 * recursion), {@link Haus#canonical canonical}, {@link Haus#hash hash} and {@link Haus#compare
 * compare} take any depth, {@code toString} writes containers deeper than {@link
 * Limits#MAX_SUPPORTED_DEPTH} as {@code …}, and the writers, checks and codecs, which recurse once
 * per level, reject one deeper than their depth limit with {@code nesting-too-deep}.
 */
public sealed interface Value permits Value.Number, Value.Text, Value.Bytes, Value.Array, Value.Record, Value.Variant {

  /** The six kinds of value. */
  enum Kind {
    NUMBER,
    STRING,
    BYTES,
    ARRAY,
    RECORD,
    VARIANT
  }

  /** Which of the six kinds this value is. */
  Kind kind();

  /**
   * How deeply the value nests records, arrays and payloads, as spec §7 counts it for values: a
   * record payload, {@code Tag { … }}, is one level, an empty container too, a number or string
   * none.
   */
  int depth();

  // ── Building values ──

  /**
   * The number written {@code literal} in any spelling: {@code "19.90"}, {@code "0xFF"}, {@code
   * "1_000"}, {@code "1E+05"} (spec §3), normalized as the parser does ({@code 255} for {@code
   * "0xFF"}). No limit applies (spec §11, "Values built in code"): a number longer than the number
   * limit, or with a larger exponent, is still a number, which a writer with those limits rejects.
   *
   * @throws HausException if it isn't a number literal ({@code invalid-number})
   */
  static Number number(String literal) {
    return Number.parse(literal);
  }

  /** The integer {@code n}. */
  static Number number(long n) {
    return new Number(Long.toString(n));
  }

  /** The integer {@code n}. */
  static Number number(BigInteger n) {
    return new Number(n.toString());
  }

  /** The exact decimal {@code n}, scale included: {@code 19.90} stays {@code 19.90}. */
  static Number number(BigDecimal n) {
    return Number.parse(n.toString());
  }

  /**
   * The float {@code f} as the schema type {@code Float64} writes it (spec §15): a number in its
   * one spelling (the fewest digits that read back to {@code f}), or the tag {@code NaN}, {@code
   * Infinity} or {@code NegInfinity}.
   */
  static Value float64(double f) {
    return floatValue(f, false);
  }

  /** The float {@code f} as the schema type {@code Float32} writes it; see {@link #float64}. */
  static Value float32(float f) {
    return floatValue(f, true);
  }

  private static Value floatValue(double f, boolean float32) {
    if (Double.isNaN(f)) {
      return new Variant("NaN", new Value[0]);
    }
    if (Double.isInfinite(f)) {
      return new Variant(f > 0 ? "Infinity" : "NegInfinity", new Value[0]);
    }
    return new Number(SchemaFloats.format(f, float32));
  }

  /**
   * The string {@code s}.
   *
   * @throws HausException with the code {@code cannot-encode} if {@code s} has an unpaired
   *     surrogate, which has no UTF-8 form (spec §11)
   */
  static Text string(String s) {
    return new Text(encodable(Objects.requireNonNull(s, "value"), "string"));
  }

  /** {@code s}, if it has a UTF-8 form: else {@code cannot-encode}, with no place (spec §11). */
  private static String encodable(String s, String what) {
    if (Quoting.hasLoneSurrogate(s)) {
      throw HausException.of(
          ErrorCode.CANNOT_ENCODE, "a " + what + " with an unpaired surrogate, which has no UTF-8 form");
    }
    return s;
  }

  /** The byte string holding a copy of {@code bytes}. */
  static Bytes bytes(byte[] bytes) {
    return new Bytes(bytes.clone());
  }

  /** The array of {@code items}. */
  static Array array(Value... items) {
    return new Array(copyOf(items));
  }

  /** The array of {@code items}. */
  static Array array(List<? extends Value> items) {
    return new Array(copyOf(items.toArray(new Value[0])));
  }

  /** A field of a record. */
  static Field field(String key, Value value) {
    return new Field(key, value);
  }

  /**
   * The record of {@code fields}, in order.
   *
   * @throws HausException with the code {@code duplicate-key} if two fields have the same key, or
   *     {@code cannot-encode} if a key has an unpaired surrogate
   */
  static Record record(Field... fields) {
    return record(Arrays.asList(fields));
  }

  /**
   * The record of {@code fields}, in order.
   *
   * @throws HausException with the code {@code duplicate-key} if two fields have the same key, or
   *     {@code cannot-encode} if a key has an unpaired surrogate
   */
  static Record record(List<Field> fields) {
    int n = fields.size();
    String[] keys = new String[n];
    Value[] values = new Value[n];
    for (int i = 0; i < n; i++) {
      Field f = fields.get(i);
      keys[i] = encodable(f.key(), "key");
      values[i] = f.value();
    }
    return Record.withUniqueKeys(keys, values);
  }

  /**
   * The record of the entries of {@code fields}, in its order.
   *
   * @throws HausException with the code {@code cannot-encode} if a key has an unpaired surrogate
   */
  static Record record(Map<String, ? extends Value> fields) {
    int n = fields.size();
    String[] keys = new String[n];
    Value[] values = new Value[n];
    int i = 0;
    for (Map.Entry<String, ? extends Value> e : fields.entrySet()) {
      keys[i] = encodable(Objects.requireNonNull(e.getKey(), "key"), "key");
      values[i] = Objects.requireNonNull(e.getValue(), "value");
      i++;
    }
    return new Record(keys, values, Keys.of(keys, n));
  }

  /**
   * The variant {@code tag} with the arguments {@code args}: {@code None}, {@code Some(1)}, or
   * {@code Circle { r: 1 }} as a tag with one record argument.
   *
   * @throws HausException with the code {@code invalid-tag} if the tag isn't {@code
   *     [A-Z][A-Za-z0-9_]*}
   */
  static Variant variant(String tag, Value... args) {
    return new Variant(Variant.checkTag(tag), copyOf(args));
  }

  /** The variant {@code tag} with the arguments {@code args}. See {@link #variant(String, Value...)}. */
  static Variant variant(String tag, List<? extends Value> args) {
    return new Variant(Variant.checkTag(tag), copyOf(args.toArray(new Value[0])));
  }

  /** The tag {@code True} or {@code False} of the prelude's {@code Bool}. */
  static Variant bool(boolean b) {
    return b ? Variant.TRUE : Variant.FALSE;
  }

  private static Value[] copyOf(Value[] items) {
    Value[] copy = items.clone();
    for (Value v : copy) {
      Objects.requireNonNull(v, "value");
    }
    return copy;
  }

  /** The depth of a container of {@code items}: one more than its deepest item. */
  private static int containerDepth(Value[] items) {
    int deepest = 0;
    for (Value v : items) {
      deepest = Math.max(deepest, v.depth());
    }
    return deepest + 1;
  }

  /** The hash code of a value whose containers below have theirs: a container's stored one. */
  private static int storedHash(Value v) {
    if (v instanceof Array a) {
      return a.hash;
    }
    if (v instanceof Record r) {
      return r.hash;
    }
    if (v instanceof Variant x) {
      return x.hash;
    }
    return v.hashCode();
  }

  /** The children of a container; empty for the other kinds. */
  private static Value[] children(Value v) {
    if (v instanceof Array a) {
      return a.unsafeItems();
    }
    if (v instanceof Record r) {
      return r.unsafeValues();
    }
    if (v instanceof Variant x) {
      return x.unsafeArgs();
    }
    return new Value[0];
  }

  /**
   * The hash code of a container whose children's hash codes are known: {@code Arrays.hashCode}
   * of an array's items, the sum of {@code key.hashCode() ^ value.hashCode()} over a record's
   * fields (whatever their order), {@code 31 * tag.hashCode()} plus the arguments' {@code
   * Arrays.hashCode} for a variant. 0 is taken as 1, so that 0 can mean "not computed yet".
   */
  private static int combine(Value v) {
    int h;
    if (v instanceof Record r) {
      h = 0;
      String[] keys = r.unsafeKeys();
      Value[] values = r.unsafeValues();
      for (int i = 0; i < keys.length; i++) {
        h += keys[i].hashCode() ^ storedHash(values[i]);
      }
    } else {
      h = 1;
      for (Value c : children(v)) {
        h = 31 * h + storedHash(c);
      }
      if (v instanceof Variant x) {
        h += 31 * x.tag().hashCode();
      }
    }
    return h == 0 ? 1 : h;
  }

  /**
   * The hash code of a container (spec §7, "host hooks"): computed once, from the children's, which
   * are computed first, with a stack on the heap instead of recursion, so that a value built in
   * code of any depth has one. It is kept in the container, as {@link String} keeps its own: a
   * race computes the same number twice.
   */
  private static int hashOf(Value root) {
    java.util.ArrayDeque<Value> stack = new java.util.ArrayDeque<>();
    stack.push(root);
    while (!stack.isEmpty()) {
      Value top = stack.peek();
      if (storedHash(top) != 0) {
        stack.pop();
        continue;
      }
      boolean ready = true;
      for (Value c : children(top)) {
        boolean container = c instanceof Array || c instanceof Record || c instanceof Variant;
        if (container && storedHash(c) == 0) {
          stack.push(c);
          ready = false;
        }
      }
      if (ready) {
        stack.pop();
        int h = combine(top);
        if (top instanceof Array a) {
          a.hash = h;
        } else if (top instanceof Record r) {
          r.hash = h;
        } else {
          ((Variant) top).hash = h;
        }
      }
    }
    return storedHash(root);
  }

  // ── The kinds ──

  /**
   * An exact decimal number (spec §3), kept as its normalized literal (spec §2): digit separators
   * removed, the exponent written {@code e} and its value, hex and binary literals in decimal.
   * Scale and notation are part of the value: {@code 1.0} and {@code 1} are different numbers, and
   * so are {@code 1e2} and {@code 100}.
   */
  final class Number implements Value {
    private final String literal;

    /** A number from its normalized literal. */
    Number(String literal) {
      this.literal = literal;
    }

    static Number parse(String literal) {
      byte[] bytes = Source.utf8(literal);
      try {
        Numbers.Scanned n = Numbers.scan(bytes, 0, bytes.length, null);
        if (n.end() != bytes.length) {
          throw new SyntaxError(
              n.end(), ErrorCode.INVALID_NUMBER, "not a number literal: " + Quoting.forMessage(literal));
        }
        return new Number(n.literal());
      } catch (SyntaxError e) {
        throw HausException.of(e.code, e.reason);
      }
    }

    @Override
    public Kind kind() {
      return Kind.NUMBER;
    }

    @Override
    public int depth() {
      return 0;
    }

    /** The normalized literal, as in the canonical form: {@code 255}, {@code 19.90}, {@code -0}, {@code 1e5}. */
    public String literal() {
      return literal;
    }

    /**
     * Whether the literal has neither a fraction nor an exponent. {@code 1e2} and {@code 1.0} are
     * not integers in this sense: notation is part of a haus number (spec §2).
     */
    public boolean isInteger() {
      return literal.indexOf('.') < 0 && literal.indexOf('e') < 0;
    }

    /**
     * The nearest double (ties to even), rounded directly from the exact decimal; {@code -0} is
     * negative zero, and a number too large for a double is infinite.
     */
    public double toDouble() {
      return Double.parseDouble(literal);
    }

    /** The exact value; {@code -0} is zero. */
    public BigDecimal toBigDecimal() {
      return new BigDecimal(literal);
    }

    /**
     * The value as an integer.
     *
     * @throws ArithmeticException if the number isn't an integer by its spelling ({@link
     *     #isInteger})
     */
    public BigInteger toBigInteger() {
      if (!isInteger()) {
        throw new ArithmeticException(literal + " is not an integer");
      }
      return new BigInteger(literal);
    }

    @Override
    public boolean equals(Object o) {
      return o instanceof Number && ((Number) o).literal.equals(literal);
    }

    @Override
    public int hashCode() {
      return literal.hashCode();
    }

    @Override
    public String toString() {
      return literal;
    }
  }

  /**
   * A string: a sequence of Unicode code points. {@link Value#string} rejects a string with an
   * unpaired surrogate ({@code cannot-encode}): it has no UTF-8 form.
   */
  final class Text implements Value {
    private final String value;

    Text(String value) {
      this.value = Objects.requireNonNull(value, "value");
    }

    @Override
    public Kind kind() {
      return Kind.STRING;
    }

    @Override
    public int depth() {
      return 0;
    }

    /** The string. */
    public String value() {
      return value;
    }

    @Override
    public boolean equals(Object o) {
      return o instanceof Text && ((Text) o).value.equals(value);
    }

    @Override
    public int hashCode() {
      return value.hashCode();
    }

    @Override
    public String toString() {
      StringBuilder b = new StringBuilder();
      Quoting.appendQuoted(b, value);
      return b.toString();
    }
  }

  /** A byte string, written {@code x"0b34ff"}. */
  final class Bytes implements Value {
    private final byte[] bytes;

    /** A byte string that keeps {@code bytes}, which nothing else changes. */
    Bytes(byte[] bytes) {
      this.bytes = bytes;
    }

    @Override
    public Kind kind() {
      return Kind.BYTES;
    }

    @Override
    public int depth() {
      return 0;
    }

    /** A copy of the bytes. */
    public byte[] toByteArray() {
      return bytes.clone();
    }

    /** The number of bytes. */
    public int size() {
      return bytes.length;
    }

    /** The byte at {@code i}. */
    public byte get(int i) {
      return bytes[i];
    }

    /** The bytes as lowercase hex, two digits per byte. */
    public String hex() {
      StringBuilder b = new StringBuilder(2 * bytes.length);
      WriteCheck.appendHex(b, bytes);
      return b.toString();
    }

    byte[] unsafeBytes() {
      return bytes;
    }

    @Override
    public boolean equals(Object o) {
      return o instanceof Bytes && Arrays.equals(((Bytes) o).bytes, bytes);
    }

    @Override
    public int hashCode() {
      return Arrays.hashCode(bytes);
    }

    @Override
    public String toString() {
      return "x\"" + hex() + "\"";
    }
  }

  /** An ordered sequence of values. */
  final class Array implements Value, Iterable<Value> {
    private final Value[] items;
    private final int depth;
    /** The hash code, once computed; 0 before. */
    int hash;

    /** An array that keeps {@code items}, which nothing else changes. */
    Array(Value[] items) {
      this(items, containerDepth(items));
    }

    /** {@link #Array(Value[])} of a depth known already: one more than its deepest item's. */
    Array(Value[] items, int depth) {
      this.items = items;
      this.depth = depth;
    }

    @Override
    public Kind kind() {
      return Kind.ARRAY;
    }

    @Override
    public int depth() {
      return depth;
    }

    /** The items, as an unmodifiable list. */
    public List<Value> items() {
      return listOf(items);
    }

    /** The number of items. */
    public int size() {
      return items.length;
    }

    /** The item at {@code i}. */
    public Value get(int i) {
      return items[i];
    }

    @Override
    public Iterator<Value> iterator() {
      return items().iterator();
    }

    Value[] unsafeItems() {
      return items;
    }

    @Override
    public boolean equals(Object o) {
      return o instanceof Array && Canonical.equal(this, (Array) o);
    }

    @Override
    public int hashCode() {
      int h = hash;
      return h != 0 ? h : hashOf(this);
    }

    @Override
    public String toString() {
      return LineWriter.toText(this);
    }
  }

  /** One field of a {@link Record}: a key and its value. */
  record Field(String key, Value value) {
    /** A field; neither may be null. */
    public Field {
      Objects.requireNonNull(key, "key");
      Objects.requireNonNull(value, "value");
    }
  }

  /**
   * A set of fields with distinct string keys, in the order they were written. The order is kept
   * for writing, but doesn't take part in equality (spec §2).
   */
  final class Record implements Value, Iterable<Field> {
    private final String[] keys;
    private final Value[] values;
    /** The fields by key, for records of {@link Keys#FEW} fields or more; null for smaller ones. */
    private final Keys index;
    private final int depth;
    /**
     * Whether every key is known to be an identifier, written bare (the parser read each as one);
     * false where that isn't known, and each key is looked at when it is written.
     */
    private final boolean bareKeys;
    /** The hash code, once computed; 0 before. */
    int hash;

    /** A record that keeps its arrays, whose keys are distinct and which nothing else changes. */
    Record(String[] keys, Value[] values, Keys index) {
      this(keys, values, index, false);
    }

    /** {@link #Record(String[], Value[], Keys)}, and whether every key is known to be an identifier. */
    Record(String[] keys, Value[] values, Keys index, boolean bareKeys) {
      this(keys, values, index, bareKeys, containerDepth(values));
    }

    /** {@link #Record(String[], Value[], Keys, boolean)} of a depth known already: one more than its deepest value's. */
    Record(String[] keys, Value[] values, Keys index, boolean bareKeys, int depth) {
      this.keys = keys;
      this.values = values;
      this.index = index;
      this.depth = depth;
      this.bareKeys = bareKeys;
    }

    /** Whether every key is known to be an identifier, which is written bare. */
    boolean bareKeys() {
      return bareKeys;
    }

    /** The index of the keys, or null for a small record. */
    Keys index() {
      return index;
    }

    /** A record of fields whose keys are checked to be distinct. */
    static Record withUniqueKeys(String[] keys, Value[] values) {
      int n = keys.length;
      Keys index = n < Keys.FEW ? null : new Keys(n);
      for (int i = 0; i < n; i++) {
        Objects.requireNonNull(keys[i], "key");
        Objects.requireNonNull(values[i], "value");
        boolean repeated = index != null ? !index.add(keys[i], i) : Keys.find(keys, 0, i, keys[i]) >= 0;
        if (repeated) {
          throw HausException.of(ErrorCode.DUPLICATE_KEY, "duplicate key " + Quoting.forMessage(keys[i]));
        }
      }
      return new Record(keys, values, index);
    }

    @Override
    public Kind kind() {
      return Kind.RECORD;
    }

    @Override
    public int depth() {
      return depth;
    }

    /** The number of fields. */
    public int size() {
      return keys.length;
    }

    /** Whether the record has a field with the key. */
    public boolean containsKey(String key) {
      return placeOf(key) >= 0;
    }

    /** The value of the field with the key, or null if there is none. */
    public Value get(String key) {
      int i = placeOf(key);
      return i < 0 ? null : values[i];
    }

    private int placeOf(String key) {
      return index != null ? index.placeOf(key) : Keys.find(keys, 0, keys.length, key);
    }

    /** The key of the field at {@code i}, in order. */
    public String keyAt(int i) {
      return keys[i];
    }

    /** The value of the field at {@code i}, in order. */
    public Value valueAt(int i) {
      return values[i];
    }

    /** The keys, in order, as an unmodifiable list. */
    public List<String> keys() {
      return listOf(keys);
    }

    /** The fields, in order, as an unmodifiable list. */
    public List<Field> fields() {
      return new AbstractList<>() {
        @Override
        public Field get(int i) {
          return new Field(keys[i], values[i]);
        }

        @Override
        public int size() {
          return keys.length;
        }
      };
    }

    /** The fields as an unmodifiable map, in order. */
    public Map<String, Value> toMap() {
      Map<String, Value> map = new LinkedHashMap<>();
      for (int i = 0; i < keys.length; i++) {
        map.put(keys[i], values[i]);
      }
      return Collections.unmodifiableMap(map);
    }

    @Override
    public Iterator<Field> iterator() {
      return fields().iterator();
    }

    String[] unsafeKeys() {
      return keys;
    }

    Value[] unsafeValues() {
      return values;
    }

    @Override
    public boolean equals(Object o) {
      return o instanceof Record && Canonical.equal(this, (Record) o);
    }

    @Override
    public int hashCode() {
      int h = hash;
      return h != 0 ? h : hashOf(this);
    }

    @Override
    public String toString() {
      return LineWriter.toText(this);
    }
  }

  /**
   * A tag with zero or more argument values: {@code None}, {@code Some(1)}, {@code Circle { r: 1
   * }}. A record payload, {@code Tag { … }}, is one record argument.
   */
  final class Variant implements Value {
    static final Variant TRUE = new Variant("True", new Value[0]);
    static final Variant FALSE = new Variant("False", new Value[0]);
    static final Variant NONE = new Variant("None", new Value[0]);

    private final String tag;
    private final Value[] args;
    private final int depth;
    /** The hash code, once computed; 0 before. */
    int hash;

    /** A variant that keeps {@code args}, which nothing else changes; the tag is valid. */
    Variant(String tag, Value[] args) {
      this(tag, args, depthOf(args));
    }

    /** {@link #Variant(String, Value[])} of a depth known already. */
    Variant(String tag, Value[] args, int depth) {
      this.tag = tag;
      this.args = args;
      this.depth = depth;
    }

    private static int depthOf(Value[] args) {
      if (args.length == 0) {
        return 0;
      }
      if (args.length == 1 && args[0] instanceof Record) {
        return args[0].depth(); // Tag { … }: the record is the payload's one level
      }
      return containerDepth(args);
    }

    static String checkTag(String tag) {
      if (!Scan.isTag(tag)) {
        throw HausException.of(
            ErrorCode.INVALID_TAG, "the tag " + Quoting.forMessage(tag) + " isn't [A-Z][A-Za-z0-9_]*");
      }
      return tag;
    }

    @Override
    public Kind kind() {
      return Kind.VARIANT;
    }

    @Override
    public int depth() {
      return depth;
    }

    /** The tag. */
    public String tag() {
      return tag;
    }

    /** The arguments, as an unmodifiable list: empty for a tag without payload. */
    public List<Value> args() {
      return listOf(args);
    }

    /** The number of arguments. */
    public int size() {
      return args.length;
    }

    /** The argument at {@code i}. */
    public Value get(int i) {
      return args[i];
    }

    /** The record of a record payload, {@code Tag { … }}, or null if the payload is no one record. */
    public Record payload() {
      return args.length == 1 && args[0] instanceof Record ? (Record) args[0] : null;
    }

    Value[] unsafeArgs() {
      return args;
    }

    @Override
    public boolean equals(Object o) {
      return o instanceof Variant && Canonical.equal(this, (Variant) o);
    }

    @Override
    public int hashCode() {
      int h = hash;
      return h != 0 ? h : hashOf(this);
    }

    @Override
    public String toString() {
      return LineWriter.toText(this);
    }
  }

  private static <T> List<T> listOf(T[] items) {
    return Collections.unmodifiableList(Arrays.asList(items));
  }
}
