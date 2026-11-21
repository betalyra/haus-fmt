package org.hausfmt;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.GenericArrayType;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Parameter;
import java.lang.reflect.ParameterizedType;
import java.lang.reflect.RecordComponent;
import java.lang.reflect.Type;
import java.lang.reflect.TypeVariable;
import java.lang.reflect.WildcardType;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.DateTimeException;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import org.hausfmt.SchemaTypes.CaseType;
import org.hausfmt.SchemaTypes.FieldType;
import org.hausfmt.SchemaTypes.Kind;
import org.hausfmt.SchemaTypes.Payload;
import org.hausfmt.SchemaTypes.RecordType;
import org.hausfmt.SchemaTypes.Typ;
import org.hausfmt.SchemaTypes.VariantType;

/**
 * Binds a schema type to host types, for {@link HausCodec}: a tree of {@link Bind}s built once, by
 * reflection, that turns a decoded value into host objects and back. The schema's rules are
 * checked by the decoder and the encoder around it; a bind only converts, and fails where a host
 * type can't hold a valid value (a {@code long} for a larger {@code Int}).
 */
final class Binder {
  /** A conversion between a schema type's decoded values and a host type. */
  abstract static class Bind {
    /** The host value of {@code v}, which the type decoded. */
    abstract Object read(Value v, Path path);

    /** The value of the host value {@code x}, before the encoder checks it. */
    abstract Value write(Object x, Path path);
  }

  private final Codecs codecs;
  /** The binds of named types by instance and host type, so that recursive types bind once. */
  private final Map<Object, Map<Type, Bind>> named = new IdentityHashMap<>();

  private Binder(Codecs codecs) {
    this.codecs = codecs;
  }

  /** The bind of {@code t} to {@code host}; fails with {@link IllegalArgumentException} where they don't fit. */
  static Bind of(Typ t, Type host, Codecs codecs) {
    return new Binder(codecs).bind(t, normalize(host, Map.of()), "$");
  }

  private static IllegalArgumentException misfit(String where, Type host, String why) {
    return new IllegalArgumentException(where + ": " + host.getTypeName() + " " + why);
  }

  static HausException error(Path path, ErrorCode code, String reason) {
    return path.error(code, reason);
  }

  // ── Building ──

  private Bind bind(Typ t, Type host, String where) {
    Class<?> raw = rawClass(host);
    // A codec applies wherever its type occurs, also behind other names, if it gives the host type.
    for (Typ x = t; ; x = x.inst.body) {
      Codec<?> codec = codecs.forType(x);
      if (codec != null && box(raw).isAssignableFrom(codec.hostType())) {
        return new CodecBind(codec);
      }
      if (x.kind != Kind.REF) {
        break;
      }
    }
    if (Value.class.isAssignableFrom(raw)) {
      return new ValueBind(raw);
    }
    if (t.kind == Kind.REF) {
      Map<Type, Bind> byHost = named.computeIfAbsent(t.inst, k -> new HashMap<>());
      Bind known = byHost.get(host);
      if (known != null) {
        return known;
      }
      Lazy lazy = new Lazy();
      byHost.put(host, lazy);
      lazy.bind = bind(t.inst.resolved, host, where + " (" + t.inst.name + ")");
      byHost.put(host, lazy.bind);
      return lazy.bind;
    }
    switch (t.kind) {
      case STRING:
        return expect(raw == String.class, Scalar.STRING, where, host, "is not a String");
      case BYTES:
        return expect(raw == byte[].class, Scalar.BYTES, where, host, "is not a byte[]");
      case BOOL:
        return expect(box(raw) == Boolean.class, Scalar.BOOL, where, host, "is not a boolean");
      case DECIMAL:
        return expect(raw == BigDecimal.class, Scalar.DECIMAL, where, host, "is not a BigDecimal or a Value.Number");
      case FLOAT32:
      case FLOAT64:
        if (box(raw) == Double.class || box(raw) == Float.class && t.kind == Kind.FLOAT32) {
          return new FloatBind(t.kind == Kind.FLOAT32, box(raw) == Float.class);
        }
        throw misfit(where, host, "is not a double" + (t.kind == Kind.FLOAT32 ? " or a float" : ""));
      case ANY:
        throw misfit(where, host, "is not a Value (Any keeps the value as parsed)");
      case TIME:
        return TimeBind.of(t.name, raw, where, host);
      case ARRAY:
        if (raw == List.class) {
          return new ListBind(bind(t.elem, typeArgument(host, 0, where), where + "[i]"));
        }
        throw misfit(where, host, "is not a List");
      case MAP:
        if (raw == Map.class && typeArgument(host, 0, where) == String.class) {
          return new MapBind(bind(t.elem, typeArgument(host, 1, where), where + "[key]"));
        }
        throw misfit(where, host, "is not a Map<String, …>");
      case MAYBE:
        if (raw == Optional.class) {
          return new OptionalBind(bind(t.elem, typeArgument(host, 0, where), where + "[0]"));
        }
        if (t.elem.resolve().kind == Kind.MAYBE) {
          throw misfit(where, host, "can't tell None from Some(None): use Optional<…>");
        }
        return new NullableBind(bind(t.elem, host, where + "[0]"));
      case SECRET:
        if (raw == Secret.class) {
          return new SecretBind(bind(t.elem, typeArgument(host, 0, where), where));
        }
        throw misfit(where, host, "is not a Secret<…>");
      case RECORD:
        return record(t.rec, host, where);
      case VARIANT:
        return variant(t.vrt, host, where);
      case PARAM:
        throw misfit(where, host, "stands for a type parameter, which a value isn't decoded with");
      default:
        return IntBind.of(t.kind, raw, where, host);
    }
  }

  private static Bind expect(boolean fits, Bind bind, String where, Type host, String why) {
    if (!fits) {
      throw misfit(where, host, why);
    }
    return bind;
  }

  /** The bind of a named type, set once it is built; a recursive type refers to it before. */
  private static final class Lazy extends Bind {
    Bind bind;

    @Override
    Object read(Value v, Path path) {
      return bind.read(v, path);
    }

    @Override
    Value write(Object x, Path path) {
      return bind.write(x, path);
    }
  }

  // ── Host classes ──

  /** How a record or case class is built and read: its constructor and, per component, a name, type and accessor. */
  private static final class Shape {
    final Constructor<?> ctor;
    final String[] names;
    final Type[] types;
    final Method[] accessors;

    Shape(Constructor<?> ctor, String[] names, Type[] types, Method[] accessors) {
      this.ctor = ctor;
      this.names = names;
      this.types = types;
      this.accessors = accessors;
    }

    Object create(Object[] args, Path path) {
      try {
        return ctor.newInstance(args);
      } catch (InvocationTargetException e) {
        Throwable cause = e.getCause();
        // A Kotlin constructor rejects null for a parameter that isn't nullable.
        throw error(path, ErrorCode.TYPE_MISMATCH,
            ctor.getDeclaringClass().getName() + " rejects the value: " + cause);
      } catch (ReflectiveOperationException e) {
        throw new IllegalStateException(e);
      }
    }

    Object get(int i, Object x) {
      try {
        return accessors[i].invoke(x);
      } catch (InvocationTargetException e) {
        throw new IllegalStateException(e.getCause());
      } catch (IllegalAccessException e) {
        throw new IllegalStateException(e);
      }
    }
  }

  /**
   * The shape of a record, or of a Kotlin data class (its primary constructor's parameters, read
   * by {@code componentN()}; it needs parameter names, {@code javaParameters} in the Kotlin
   * compiler options); null for other classes.
   */
  private static Shape shape(Class<?> c, Type host, String where) {
    Map<TypeVariable<?>, Type> vars = typeVariables(c, host);
    if (c.isRecord()) {
      RecordComponent[] rc = c.getRecordComponents();
      Class<?>[] params = new Class<?>[rc.length];
      String[] names = new String[rc.length];
      Type[] types = new Type[rc.length];
      Method[] accessors = new Method[rc.length];
      for (int i = 0; i < rc.length; i++) {
        params[i] = rc[i].getType();
        HausName n = rc[i].getAnnotation(HausName.class);
        names[i] = n != null ? n.value() : rc[i].getName();
        types[i] = normalize(rc[i].getGenericType(), vars);
        accessors[i] = accessible(rc[i].getAccessor());
      }
      try {
        return new Shape(accessible(c.getDeclaredConstructor(params)), names, types, accessors);
      } catch (NoSuchMethodException e) {
        throw new IllegalStateException(e);
      }
    }
    List<Method> components = new ArrayList<>();
    for (int i = 1; ; i++) {
      try {
        components.add(c.getMethod("component" + i));
      } catch (NoSuchMethodException e) {
        break;
      }
    }
    for (Constructor<?> ctor : c.getDeclaredConstructors()) {
      Parameter[] ps = ctor.getParameters();
      if (components.isEmpty() || ps.length != components.size() || ctor.isSynthetic()) {
        continue;
      }
      String[] names = new String[ps.length];
      Type[] types = new Type[ps.length];
      for (int i = 0; i < ps.length; i++) {
        HausName n = ps[i].getAnnotation(HausName.class);
        if (n == null && !ps[i].isNamePresent()) {
          throw misfit(where, host, "has no parameter names: compile it with javaParameters (Kotlin) or -parameters (Java)");
        }
        names[i] = n != null ? n.value() : ps[i].getName();
        types[i] = normalize(ps[i].getParameterizedType(), vars);
      }
      return new Shape(accessible(ctor), names, types, components.stream().map(Binder::accessible).toArray(Method[]::new));
    }
    return null;
  }

  private static <T extends java.lang.reflect.AccessibleObject> T accessible(T o) {
    o.setAccessible(true);
    return o;
  }

  /** A record of the schema as a record or data class: every component a field of the record, every required field a component. */
  private Bind record(RecordType rt, Type host, String where) {
    Class<?> c = rawClass(host);
    Shape s = shape(c, host, where);
    if (s == null) {
      throw misfit(where, host, "is not a record (or a Kotlin data class)");
    }
    int n = s.names.length;
    FieldType[] fields = new FieldType[n];
    Bind[] binds = new Bind[n];
    for (int i = 0; i < n; i++) {
      FieldType f = rt.field(s.names[i]);
      if (f == null) {
        throw misfit(where, host, "has a component " + s.names[i] + ", which is no field of the record");
      }
      fields[i] = f;
      Bind b = bind(f.typ(), s.types[i], where + "." + s.names[i]);
      if (f.optional() && b instanceof NullableBind) {
        throw misfit(where + "." + s.names[i], s.types[i], "can't tell a missing field from None: use Optional<…>");
      }
      if (f.optional() && rawClass(s.types[i]).isPrimitive()) {
        throw misfit(where + "." + s.names[i], s.types[i], "can't be missing: use a boxed type");
      }
      binds[i] = b;
    }
    for (FieldType f : rt.fields) {
      if (!f.optional() && !Arrays.asList(s.names).contains(f.key())) {
        throw misfit(where, host, "has no component for the field " + SchemaText.quoteKey(f.key()));
      }
    }
    return new RecordBind(s, fields, binds);
  }

  private Bind variant(VariantType vt, Type host, String where) {
    Class<?> c = rawClass(host);
    if (c.isEnum()) {
      return EnumBind.of(vt, c, where, host);
    }
    List<Class<?>> classes = caseClasses(c);
    if (classes.isEmpty() && !vt.open && vt.cases.length == 1 && !c.isInterface() && !Modifier.isAbstract(c.getModifiers())) {
      classes = List.of(c); // a closed variant of one case, such as < UserId String >, as that case's class
    }
    if (classes.isEmpty()) {
      throw misfit(where, host, "is no enum and no sealed interface or class with a class per case");
    }
    Map<String, CaseBind> byTag = new HashMap<>();
    Map<Class<?>, CaseBind> byClass = new HashMap<>();
    Shape unknown = null;
    for (Class<?> k : classes) {
      HausName n = k.getAnnotation(HausName.class);
      String tag = n != null ? n.value() : k.getSimpleName();
      CaseType ct = vt.caseOf(tag);
      if (ct == null) {
        Shape s = shape(k, k, where);
        if (s != null && s.names.length == 1 && s.types[0] == Value.Variant.class && vt.open && unknown == null) {
          unknown = s;
          continue;
        }
        throw misfit(where, k, "is no case of the variant (" + SchemaTypes.tags(vt) + ")"
            + (vt.open ? "; a case for unknown tags has one component, a Value.Variant" : ""));
      }
      CaseBind cb = caseBind(ct, k, where + "." + tag);
      byTag.put(tag, cb);
      byClass.put(k, cb);
    }
    if (!vt.open || vt.cases.length > 0) {
      for (CaseType ct : vt.cases) {
        if (!byTag.containsKey(ct.tag)) {
          throw misfit(where, host, "has no class for the case " + ct.tag);
        }
      }
    }
    return new VariantBind(byTag, byClass, unknown);
  }

  /** The classes of a sealed type's cases: its permitted subclasses, or the classes nested in it that extend it. */
  private static List<Class<?>> caseClasses(Class<?> c) {
    List<Class<?>> out = new ArrayList<>();
    if (c.isSealed()) {
      out.addAll(Arrays.asList(c.getPermittedSubclasses()));
    } else if (c.isInterface() || Modifier.isAbstract(c.getModifiers())) {
      for (Class<?> k : c.getDeclaredClasses()) {
        if (c.isAssignableFrom(k) && !k.isInterface() && !Modifier.isAbstract(k.getModifiers())) {
          out.add(k);
        }
      }
    }
    return out;
  }

  private CaseBind caseBind(CaseType ct, Class<?> k, String where) {
    Object singleton = singleton(k);
    if (ct.payload == Payload.NONE) {
      if (singleton != null) {
        return new CaseBind(ct.tag, singleton, null, null, null);
      }
      Shape s = shape(k, k, where);
      if (s != null && s.names.length == 0) {
        return new CaseBind(ct.tag, s.create(new Object[0], new Path()), null, null, null);
      }
      throw misfit(where, k, "is no object and no record without components, for a tag without payload");
    }
    Shape s = shape(k, k, where);
    if (s == null) {
      throw misfit(where, k, "is not a record (or a Kotlin data class)");
    }
    RecordType rec = SchemaLoader.caseRecord(ct);
    if (rec != null) {
      return new CaseBind(ct.tag, null, (RecordBind) record(rec, k, where), null, null);
    }
    if (s.names.length != ct.items.length) {
      throw misfit(where, k, "has " + s.names.length + " components for " + ct.items.length + " arguments");
    }
    Bind[] binds = new Bind[ct.items.length];
    for (int i = 0; i < binds.length; i++) {
      binds[i] = bind(ct.items[i], s.types[i], where + "[" + i + "]");
    }
    return new CaseBind(ct.tag, null, null, s, binds);
  }

  /** The one instance of a Kotlin {@code object}, or null. */
  private static Object singleton(Class<?> k) {
    try {
      Field f = k.getField("INSTANCE");
      return Modifier.isStatic(f.getModifiers()) && f.getType() == k ? f.get(null) : null;
    } catch (NoSuchFieldException | IllegalAccessException e) {
      return null;
    }
  }

  // ── Types ──

  /** A parameterized type with its type variables replaced. */
  private record Parameterized(Class<?> raw, List<Type> args) implements ParameterizedType {
    @Override
    public Type[] getActualTypeArguments() {
      return args.toArray(new Type[0]);
    }

    @Override
    public Type getRawType() {
      return raw;
    }

    @Override
    public Type getOwnerType() {
      return null;
    }

    @Override
    public String getTypeName() {
      StringBuilder b = new StringBuilder(raw.getTypeName()).append('<');
      for (int i = 0; i < args.size(); i++) {
        b.append(i > 0 ? ", " : "").append(args.get(i).getTypeName());
      }
      return b.append('>').toString();
    }
  }

  /** {@code t} with type variables replaced by {@code vars}, and wildcards by their upper bound. */
  private static Type normalize(Type t, Map<TypeVariable<?>, Type> vars) {
    if (t instanceof Class) {
      return t;
    }
    if (t instanceof ParameterizedType) {
      ParameterizedType p = (ParameterizedType) t;
      List<Type> args = new ArrayList<>();
      for (Type a : p.getActualTypeArguments()) {
        args.add(normalize(a, vars));
      }
      return new Parameterized((Class<?>) p.getRawType(), Collections.unmodifiableList(args));
    }
    if (t instanceof TypeVariable) {
      Type bound = vars.get(t);
      if (bound == null) {
        throw new IllegalArgumentException("the type variable " + t + " is not given: pass the parameterized type");
      }
      return bound;
    }
    if (t instanceof WildcardType) {
      return normalize(((WildcardType) t).getUpperBounds()[0], vars);
    }
    if (t instanceof GenericArrayType) {
      throw new IllegalArgumentException("arrays of " + t.getTypeName() + ": use a List");
    }
    return t;
  }

  /** The type variables of {@code c} as {@code host} gives them. */
  private static Map<TypeVariable<?>, Type> typeVariables(Class<?> c, Type host) {
    TypeVariable<?>[] params = c.getTypeParameters();
    if (params.length == 0) {
      return Map.of();
    }
    if (!(host instanceof Parameterized)) {
      throw new IllegalArgumentException(c.getName() + " has type parameters: pass the parameterized type");
    }
    Map<TypeVariable<?>, Type> vars = new HashMap<>();
    for (int i = 0; i < params.length; i++) {
      vars.put(params[i], ((Parameterized) host).args().get(i));
    }
    return vars;
  }

  private static Class<?> rawClass(Type t) {
    return t instanceof Parameterized ? ((Parameterized) t).raw() : (Class<?>) t;
  }

  private static Type typeArgument(Type host, int i, String where) {
    if (!(host instanceof Parameterized)) {
      throw misfit(where, host, "is a raw type: give its type arguments");
    }
    return ((Parameterized) host).args().get(i);
  }

  private static Class<?> box(Class<?> c) {
    if (!c.isPrimitive()) {
      return c;
    }
    if (c == int.class) {
      return Integer.class;
    }
    if (c == long.class) {
      return Long.class;
    }
    if (c == double.class) {
      return Double.class;
    }
    if (c == float.class) {
      return Float.class;
    }
    if (c == boolean.class) {
      return Boolean.class;
    }
    if (c == short.class) {
      return Short.class;
    }
    if (c == byte.class) {
      return Byte.class;
    }
    return c == char.class ? Character.class : Void.class;
  }

  // ── The binds ──

  /** A value kept as the binding's value: {@code Any}, or any type asked for as a {@link Value}. */
  private static final class ValueBind extends Bind {
    private final Class<?> host;

    ValueBind(Class<?> host) {
      this.host = host;
    }

    @Override
    Object read(Value v, Path path) {
      if (!host.isInstance(v)) {
        throw error(path, ErrorCode.TYPE_MISMATCH, "the host type " + host.getSimpleName() + " can't hold " + Decoder.found(v));
      }
      return v;
    }

    @Override
    Value write(Object x, Path path) {
      return (Value) x;
    }
  }

  private static final class CodecBind extends Bind {
    private final Codec<?> codec;

    CodecBind(Codec<?> codec) {
      this.codec = codec;
    }

    @Override
    Object read(Value v, Path path) {
      return codec.decode(v); // the decoder ran the codec already: it accepts the value
    }

    @Override
    Value write(Object x, Path path) {
      return encode(codec, x, path);
    }

    private static <T> Value encode(Codec<T> codec, Object x, Path path) {
      if (!codec.hostType().isInstance(x)) {
        throw error(path, ErrorCode.CANNOT_ENCODE, codec.typeId() + " takes a " + codec.hostType().getName() + ", not "
            + (x == null ? "null" : "a " + x.getClass().getName()));
      }
      try {
        return codec.encode(codec.hostType().cast(x));
      } catch (HausException e) {
        throw error(path, e.code(), e.reason());
      }
    }
  }

  /** String, bytes, Bool and Decimal. */
  private abstract static class Scalar extends Bind {
    static final Scalar STRING = new Scalar() {
      @Override
      Object read(Value v, Path path) {
        return ((Value.Text) v).value();
      }

      @Override
      Value write(Object x, Path path) {
        return new Value.Text(cast(x, String.class, path));
      }
    };

    static final Scalar BYTES = new Scalar() {
      @Override
      Object read(Value v, Path path) {
        return ((Value.Bytes) v).toByteArray();
      }

      @Override
      Value write(Object x, Path path) {
        return Value.bytes(cast(x, byte[].class, path));
      }
    };

    static final Scalar BOOL = new Scalar() {
      @Override
      Object read(Value v, Path path) {
        return ((Value.Variant) v).tag().equals("True");
      }

      @Override
      Value write(Object x, Path path) {
        return Value.bool(cast(x, Boolean.class, path));
      }
    };

    static final Scalar DECIMAL = new Scalar() {
      @Override
      Object read(Value v, Path path) {
        return ((Value.Number) v).toBigDecimal();
      }

      @Override
      Value write(Object x, Path path) {
        return Value.Number.parse(cast(x, BigDecimal.class, path).toString());
      }
    };
  }

  static <T> T cast(Object x, Class<T> c, Path path) {
    if (!c.isInstance(x)) {
      throw error(path, ErrorCode.CANNOT_ENCODE, "expected a " + c.getSimpleName() + ", found " + (x == null ? "null" : "a " + x.getClass().getName()));
    }
    return c.cast(x);
  }

  /** The integer types, as {@code long}, {@code int}, {@code short}, {@code byte} or {@link BigInteger}. */
  private static final class IntBind extends Bind {
    private final Class<?> host; // boxed
    private final long min;
    private final long max;

    private IntBind(Class<?> host, long min, long max) {
      this.host = host;
      this.min = min;
      this.max = max;
    }

    static Bind of(Kind k, Class<?> raw, String where, Type host) {
      Class<?> c = box(raw);
      if (c == BigInteger.class) {
        return new IntBind(c, 0, 0);
      }
      if (c == Long.class) {
        return new IntBind(c, Long.MIN_VALUE, Long.MAX_VALUE);
      }
      if (c == Integer.class) {
        return new IntBind(c, Integer.MIN_VALUE, Integer.MAX_VALUE);
      }
      if (c == Short.class) {
        return new IntBind(c, Short.MIN_VALUE, Short.MAX_VALUE);
      }
      if (c == Byte.class) {
        return new IntBind(c, Byte.MIN_VALUE, Byte.MAX_VALUE);
      }
      throw misfit(where, host, "is not an integer type (long, int, short, byte, BigInteger) for " + k.builtin);
    }

    @Override
    Object read(Value v, Path path) {
      String text = ((Value.Number) v).literal();
      if (host == BigInteger.class) {
        return new BigInteger(text);
      }
      long n;
      if (text.length() <= 18) {
        n = Long.parseLong(text);
      } else {
        BigInteger b = new BigInteger(text);
        if (b.bitLength() > 63) {
          throw outOfRange(text, path);
        }
        n = b.longValue();
      }
      if (n < min || n > max) {
        throw outOfRange(text, path);
      }
      if (host == Long.class) {
        return n;
      }
      if (host == Integer.class) {
        return (int) n;
      }
      return host == Short.class ? (Object) (short) n : (Object) (byte) n;
    }

    private HausException outOfRange(String text, Path path) {
      return error(path, ErrorCode.OUT_OF_RANGE, Decoder.shortNumber(text) + " is out of range for the host type "
          + host.getSimpleName() + " (" + min + " to " + max + ")");
    }

    @Override
    Value write(Object x, Path path) {
      if (host == BigInteger.class) {
        return Value.number(cast(x, BigInteger.class, path));
      }
      return Value.number(((java.lang.Number) cast(x, host, path)).longValue());
    }
  }

  private static final class FloatBind extends Bind {
    private final boolean float32;
    private final boolean hostFloat;

    FloatBind(boolean float32, boolean hostFloat) {
      this.float32 = float32;
      this.hostFloat = hostFloat;
    }

    @Override
    Object read(Value v, Path path) {
      double f;
      if (v instanceof Value.Number) {
        f = ((Value.Number) v).toDouble();
      } else {
        String tag = ((Value.Variant) v).tag();
        f = tag.equals("NaN") ? Double.NaN : tag.equals("Infinity") ? Double.POSITIVE_INFINITY : Double.NEGATIVE_INFINITY;
      }
      return hostFloat ? (Object) (float) f : (Object) f;
    }

    @Override
    Value write(Object x, Path path) {
      Class<? extends java.lang.Number> c = hostFloat ? Float.class : Double.class;
      double f = cast(x, c, path).doubleValue();
      return float32 ? Value.float32((float) f) : Value.float64(f);
    }
  }

  /**
   * A std/time type: the checked text as a {@link String} (the default, which keeps the value), or
   * a {@code java.time} type, which keeps what the value means but may drop its spelling (spec
   * §13.4): {@code Instant} keeps the instant and not the offset, {@code OffsetDateTime} the offset
   * and not a fraction's trailing zeros.
   */
  private static final class TimeBind extends Bind {
    private final String name;
    private final Class<?> host;

    private TimeBind(String name, Class<?> host) {
      this.name = name;
      this.host = host;
    }

    private static final Map<String, List<Class<?>>> HOSTS = Map.of(
        "Date", List.of(LocalDate.class),
        "YearMonth", List.of(YearMonth.class),
        "Time", List.of(LocalTime.class),
        "DateTime", List.of(LocalDateTime.class),
        "Instant", List.of(Instant.class, OffsetDateTime.class),
        "TimeZone", List.of(ZoneId.class));

    static Bind of(String name, Class<?> raw, String where, Type host) {
      if (raw == String.class || HOSTS.getOrDefault(name, List.of()).contains(raw)) {
        return new TimeBind(name, raw);
      }
      throw misfit(where, host, "is not a String" + (HOSTS.containsKey(name) ? " or " + HOSTS.get(name) : "") + " for " + name);
    }

    @Override
    Object read(Value v, Path path) {
      String text = ((Value.Text) ((Value.Variant) v).get(0)).value();
      try {
        if (host == String.class) {
          return text;
        }
        if (host == LocalDate.class) {
          return LocalDate.parse(text);
        }
        if (host == YearMonth.class) {
          return YearMonth.parse(text);
        }
        if (host == LocalTime.class) {
          return LocalTime.parse(text);
        }
        if (host == LocalDateTime.class) {
          return LocalDateTime.parse(text);
        }
        if (host == OffsetDateTime.class) {
          return OffsetDateTime.parse(text);
        }
        if (host == Instant.class) {
          return OffsetDateTime.parse(text).toInstant();
        }
        return ZoneId.of(text);
      } catch (DateTimeException e) {
        path.index(0);
        throw error(path, ErrorCode.TYPE_MISMATCH, "the host type " + host.getSimpleName() + " can't hold " + name + " "
            + SchemaText.quoted(text));
      }
    }

    @Override
    Value write(Object x, Path path) {
      Object t = cast(x, host, path);
      String text;
      if (t instanceof String) {
        text = (String) t;
      } else if (t instanceof LocalTime) {
        text = DateTimeFormatter.ISO_LOCAL_TIME.format((LocalTime) t);
      } else if (t instanceof LocalDateTime) {
        text = DateTimeFormatter.ISO_LOCAL_DATE_TIME.format((LocalDateTime) t);
      } else if (t instanceof OffsetDateTime) {
        text = DateTimeFormatter.ISO_OFFSET_DATE_TIME.format((OffsetDateTime) t);
      } else if (t instanceof ZoneId) {
        text = ((ZoneId) t).getId();
      } else {
        text = t.toString(); // LocalDate, YearMonth, Instant: the ISO forms of the profile
      }
      return new Value.Variant(name, new Value[] {new Value.Text(text)});
    }
  }

  private static final class ListBind extends Bind {
    private final Bind elem;

    ListBind(Bind elem) {
      this.elem = elem;
    }

    @Override
    Object read(Value v, Path path) {
      Value[] items = ((Value.Array) v).unsafeItems();
      Object[] out = new Object[items.length];
      for (int i = 0; i < items.length; i++) {
        path.index(i);
        out[i] = elem.read(items[i], path);
        path.pop();
      }
      return Collections.unmodifiableList(Arrays.asList(out));
    }

    @Override
    Value write(Object x, Path path) {
      List<?> list = cast(x, List.class, path);
      Value[] out = new Value[list.size()];
      int i = 0;
      for (Object item : list) {
        path.index(i);
        out[i++] = elem.write(item, path);
        path.pop();
      }
      return new Value.Array(out);
    }
  }

  private static final class MapBind extends Bind {
    private final Bind elem;

    MapBind(Bind elem) {
      this.elem = elem;
    }

    @Override
    Object read(Value v, Path path) {
      Value.Record r = (Value.Record) v;
      Map<String, Object> out = new LinkedHashMap<>();
      for (int i = 0; i < r.size(); i++) {
        path.key(r.keyAt(i));
        out.put(r.keyAt(i), elem.read(r.valueAt(i), path));
        path.pop();
      }
      return Collections.unmodifiableMap(out);
    }

    @Override
    Value write(Object x, Path path) {
      Map<?, ?> map = cast(x, Map.class, path);
      String[] keys = new String[map.size()];
      Value[] values = new Value[map.size()];
      int i = 0;
      for (Map.Entry<?, ?> e : map.entrySet()) {
        keys[i] = cast(e.getKey(), String.class, path);
        path.key(keys[i]);
        values[i++] = elem.write(e.getValue(), path);
        path.pop();
      }
      return Value.Record.withUniqueKeys(keys, values);
    }
  }

  /** {@code Maybe a} as {@code Optional<A>}. */
  private static final class OptionalBind extends Bind {
    private final Bind elem;

    OptionalBind(Bind elem) {
      this.elem = elem;
    }

    @Override
    Object read(Value v, Path path) {
      Value.Variant x = (Value.Variant) v;
      if (x.size() == 0) {
        return Optional.empty();
      }
      path.index(0);
      Object out = elem.read(x.get(0), path);
      path.pop();
      return Optional.of(out);
    }

    @Override
    Value write(Object x, Path path) {
      Optional<?> o = cast(x, Optional.class, path);
      if (o.isEmpty()) {
        return Decoder.NONE;
      }
      path.index(0);
      Value out = elem.write(o.get(), path);
      path.pop();
      return new Value.Variant("Some", new Value[] {out});
    }
  }

  /** {@code Maybe a} as a value of A that is null for None. */
  private static final class NullableBind extends Bind {
    private final Bind elem;

    NullableBind(Bind elem) {
      this.elem = elem;
    }

    @Override
    Object read(Value v, Path path) {
      Value.Variant x = (Value.Variant) v;
      if (x.size() == 0) {
        return null;
      }
      path.index(0);
      Object out = elem.read(x.get(0), path);
      path.pop();
      return out;
    }

    @Override
    Value write(Object x, Path path) {
      if (x == null) {
        return Decoder.NONE;
      }
      path.index(0);
      Value out = elem.write(x, path);
      path.pop();
      return new Value.Variant("Some", new Value[] {out});
    }
  }

  private static final class SecretBind extends Bind {
    private final Bind elem;

    SecretBind(Bind elem) {
      this.elem = elem;
    }

    @Override
    Object read(Value v, Path path) {
      return Secret.of(elem.read(v, path));
    }

    @Override
    Value write(Object x, Path path) {
      return elem.write(cast(x, Secret.class, path).reveal(), path);
    }
  }

  private static final class RecordBind extends Bind {
    private final Shape shape;
    private final FieldType[] fields;
    private final Bind[] binds;

    RecordBind(Shape shape, FieldType[] fields, Bind[] binds) {
      this.shape = shape;
      this.fields = fields;
      this.binds = binds;
    }

    @Override
    Object read(Value v, Path path) {
      Value.Record r = (Value.Record) v;
      Object[] args = new Object[binds.length];
      for (int i = 0; i < binds.length; i++) {
        String key = fields[i].key();
        Value x = r.get(key);
        if (x == null) {
          continue; // an optional field that is missing: null
        }
        path.key(key);
        args[i] = binds[i].read(x, path);
        path.pop();
      }
      return shape.create(args, path);
    }

    @Override
    Value write(Object x, Path path) {
      cast(x, shape.ctor.getDeclaringClass(), path);
      String[] keys = new String[binds.length];
      Value[] values = new Value[binds.length];
      int n = 0;
      for (int i = 0; i < binds.length; i++) {
        Object c = shape.get(i, x);
        if (c == null && fields[i].optional()) {
          continue;
        }
        path.key(fields[i].key());
        if (c == null && !(binds[i] instanceof NullableBind)) {
          throw error(path, ErrorCode.CANNOT_ENCODE, "null for a field that isn't optional");
        }
        keys[n] = fields[i].key();
        values[n++] = binds[i].write(c, path);
        path.pop();
      }
      return Decoder.owned(keys, values, n);
    }
  }

  /** One case of a variant: an object, a record case's fields, or positional arguments. */
  private static final class CaseBind {
    final String tag;
    final Object singleton;
    final RecordBind record;
    final Shape shape;
    final Bind[] items;

    CaseBind(String tag, Object singleton, RecordBind record, Shape shape, Bind[] items) {
      this.tag = tag;
      this.singleton = singleton;
      this.record = record;
      this.shape = shape;
      this.items = items;
    }

    Object read(Value.Variant x, Path path) {
      if (singleton != null) {
        return singleton;
      }
      if (record != null) {
        return record.read(x.get(0), path); // the record's fields are at the variant's place
      }
      Object[] args = new Object[items.length];
      for (int i = 0; i < items.length; i++) {
        path.index(i);
        args[i] = items[i].read(x.get(i), path);
        path.pop();
      }
      return shape.create(args, path);
    }

    Value write(Object o, Path path) {
      if (singleton != null) {
        return new Value.Variant(tag, new Value[0]);
      }
      if (record != null) {
        return new Value.Variant(tag, new Value[] {record.write(o, path)});
      }
      Value[] args = new Value[items.length];
      for (int i = 0; i < items.length; i++) {
        path.index(i);
        args[i] = items[i].write(shape.get(i, o), path);
        path.pop();
      }
      return new Value.Variant(tag, args);
    }
  }

  /** A variant as a sealed type with a class per case, and maybe one for unknown tags. */
  private static final class VariantBind extends Bind {
    private final Map<String, CaseBind> byTag;
    private final Map<Class<?>, CaseBind> byClass;
    private final Shape unknown;

    VariantBind(Map<String, CaseBind> byTag, Map<Class<?>, CaseBind> byClass, Shape unknown) {
      this.byTag = byTag;
      this.byClass = byClass;
      this.unknown = unknown;
    }

    @Override
    Object read(Value v, Path path) {
      Value.Variant x = (Value.Variant) v;
      CaseBind c = byTag.get(x.tag());
      if (c != null) {
        return c.read(x, path);
      }
      if (unknown != null) {
        return unknown.create(new Object[] {x}, path);
      }
      throw error(path, ErrorCode.UNKNOWN_TAG, SchemaText.quote(x.tag())
          + " has no case in the host type (a case for unknown tags has one component, a Value.Variant)");
    }

    @Override
    Value write(Object x, Path path) {
      if (x == null) {
        throw error(path, ErrorCode.CANNOT_ENCODE, "null for a variant");
      }
      CaseBind c = byClass.get(x.getClass());
      if (c != null) {
        return c.write(x, path);
      }
      if (unknown != null && unknown.ctor.getDeclaringClass() == x.getClass()) {
        return (Value) unknown.get(0, x);
      }
      throw error(path, ErrorCode.CANNOT_ENCODE, "a " + x.getClass().getName() + " is no case of the variant");
    }
  }

  /** A closed variant whose tags have no payload, as an enum whose constants are the tags. */
  private static final class EnumBind extends Bind {
    private final Map<String, Object> byTag;
    private final Map<Object, Value> byConstant = new IdentityHashMap<>();

    private EnumBind(Map<String, Object> byTag) {
      this.byTag = byTag;
      for (Map.Entry<String, Object> e : byTag.entrySet()) {
        byConstant.put(e.getValue(), new Value.Variant(e.getKey(), new Value[0]));
      }
    }

    static Bind of(VariantType vt, Class<?> c, String where, Type host) {
      Map<String, Object> byTag = new HashMap<>();
      for (Object constant : c.getEnumConstants()) {
        String tag = ((Enum<?>) constant).name();
        try {
          HausName n = c.getField(tag).getAnnotation(HausName.class);
          tag = n != null ? n.value() : tag;
        } catch (NoSuchFieldException e) {
          throw new IllegalStateException(e);
        }
        CaseType ct = vt.caseOf(tag);
        if (ct == null || ct.payload != Payload.NONE) {
          throw misfit(where, host, "has the constant " + tag + ", which is no tag without payload of the variant");
        }
        byTag.put(tag, constant);
      }
      for (CaseType ct : vt.cases) {
        if (!byTag.containsKey(ct.tag)) {
          throw misfit(where, host, "has no constant for the case " + ct.tag);
        }
      }
      return new EnumBind(byTag);
    }

    @Override
    Object read(Value v, Path path) {
      Object c = byTag.get(((Value.Variant) v).tag());
      if (c == null) {
        throw error(path, ErrorCode.UNKNOWN_TAG, SchemaText.quote(((Value.Variant) v).tag()) + " has no constant in the host enum");
      }
      return c;
    }

    @Override
    Value write(Object x, Path path) {
      Value v = byConstant.get(Objects.requireNonNullElse(x, ""));
      if (v == null) {
        throw error(path, ErrorCode.CANNOT_ENCODE, "expected a constant of the enum, found " + x);
      }
      return v;
    }
  }
}
