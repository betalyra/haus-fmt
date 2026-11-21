package org.hausfmt;

import java.io.InputStream;
import java.lang.reflect.Type;
import java.util.Objects;
import java.util.stream.Stream;

/**
 * Decodes and encodes values of a schema type as host objects: records, sealed interfaces, enums
 * (spec §15). It is built once from the type and the host type, by reflection, and checks that
 * they fit; decoding then runs the schema's rules ({@link SchemaType#decode}) and builds the host
 * objects, and encoding builds the value and checks it ({@link SchemaType#encode}). Immutable and
 * safe for concurrent use.
 *
 * <pre>{@code
 * record Line(String sku, BigDecimal price, Optional<String> note) {}
 * record Order(long id, List<Line> lines, Status status) {}
 * sealed interface Status permits Pending, Shipped {}
 * record Pending() implements Status {}
 * record Shipped(String tracking) implements Status {}
 *
 * HausCodec<Order> orders = schema.codec("Order", Order.class);
 * Order o = orders.decode(text);
 * String back = orders.encode(o, FormatOptions.COMPACT);
 * }</pre>
 *
 * <p>How types map:
 *
 * <ul>
 *   <li>a record: a Java record, or a Kotlin data class (compiled with {@code javaParameters}),
 *       whose components are the fields by name ({@link HausName} for a key that isn't a Java
 *       name); an optional field ({@code x?: T}) is null when missing, so a missing {@code x?:
 *       Maybe T} needs {@code Optional<T>} to tell it from {@code None};
 *   <li>a variant: a sealed interface (or abstract class) with a class per tag, named like the tag:
 *       a record or a Kotlin {@code object} for a tag without payload, a record of the fields for a
 *       record case, a record of the arguments, in order, for {@code Tag A B}; a closed variant
 *       whose tags have no payload may be an enum. In an open variant, a record with one component
 *       of type {@link Value.Variant} keeps the tags the schema doesn't list; without one, they are
 *       {@code unknown-tag};
 *   <li>{@code String}: String; {@code Bytes}: byte[]; {@code Bool}: boolean; integers: long, int,
 *       short, byte or BigInteger ({@code out-of-range} for a value the host type can't hold);
 *       {@code Float64}: double; {@code Float32}: float or double; {@code Decimal}: BigDecimal
 *       (which forgets {@code -0} and how an exponent is written) or {@link Value.Number}, which
 *       keeps it;
 *   <li>{@code Maybe a}: {@code Optional<A>}, or A with null for None; {@code Array a}: {@code
 *       List<A>}; {@code Map v}: {@code Map<String, V>}; {@code Secret a}: {@link Secret} (of A);
 *       {@code Any}: {@link Value};
 *   <li>std/time types: the text, a String, which keeps the value; or, keeping what it means but
 *       not how it is written (spec §13.4): {@code LocalDate} (Date), {@code YearMonth}, {@code
 *       LocalTime} (Time), {@code LocalDateTime} (DateTime), {@code java.time.Instant} (which drops
 *       the offset) or {@code OffsetDateTime} (Instant), {@code ZoneId} (TimeZone); a value the
 *       host type can't hold, such as a zone the JDK doesn't know, is {@code codec-rejected};
 *   <li>any type as a {@link Value} of its kind; a named type with a {@link Codec} as the codec's
 *       host type.
 * </ul>
 *
 * @param <T> the host type
 */
public final class HausCodec<T> {
  private final SchemaType type;
  private final Binder.Bind bind;
  private final DecodeOptions options;

  private HausCodec(SchemaType type, Binder.Bind bind, DecodeOptions options) {
    this.type = type;
    this.bind = bind;
    this.options = options;
  }

  /**
   * The codec of the schema type as the host class.
   *
   * @throws IllegalArgumentException if the class doesn't fit the type, with where and why
   */
  public static <T> HausCodec<T> of(SchemaType type, Class<T> host) {
    return of(type, host, DecodeOptions.DEFAULT);
  }

  /** {@link #of(SchemaType, Class)} with options: limits, and codecs for named types. */
  public static <T> HausCodec<T> of(SchemaType type, Class<T> host, DecodeOptions options) {
    return new HausCodec<>(type, Binder.of(type.typ(), host, options.codecs()), options);
  }

  /**
   * The codec of the schema type as a generic host type, such as {@code Envelope<Event>}, given as
   * a {@link Type} (from {@code Field.getGenericType()}, a type token, or Kotlin's {@code
   * typeOf<…>().javaType}).
   */
  public static HausCodec<Object> of(SchemaType type, Type host, DecodeOptions options) {
    return new HausCodec<>(type, Binder.of(type.typ(), host, options.codecs()), options);
  }

  /** The schema type. */
  public SchemaType type() {
    return type;
  }

  /**
   * The host value of {@code v}, decoded with the type.
   *
   * @throws HausException for a value the type doesn't accept, or the host type can't hold, with
   *     the path of the failing value
   */
  @SuppressWarnings("unchecked")
  public T fromValue(Value v) {
    return (T) bind.read(type.decode(v, options), new Path());
  }

  /** The value of the host value {@code x}, checked and encoded with the type ({@link SchemaType#encode}). */
  public Value toValue(T x) {
    return type.encode(bind.write(x, new Path()), options);
  }

  /** The host value of haus text holding one value. */
  public T decode(String text) {
    return fromValue(Haus.one(Haus.parseAll(text, options.limits()), "$"));
  }

  /** The host value of haus text holding one value, as UTF-8 bytes. */
  public T decode(byte[] text) {
    return fromValue(Haus.one(Haus.parseAll(text, options.limits()), "$"));
  }

  /** {@code x} as haus text in the layout of {@code format}, ending with a line break. */
  public String encode(T x, FormatOptions format) {
    return Haus.write(toValue(x), format);
  }

  /** {@code x} as haus text in the pretty layout. */
  public String encode(T x) {
    return encode(x, FormatOptions.PRETTY);
  }

  /** The host value of the type's schema-based JSON (spec §16.3). */
  @SuppressWarnings("unchecked")
  public T fromJson(String json) {
    return (T) bind.read(type.fromJson(Source.utf8(json), options), new Path());
  }

  /** {@code x} as the type's schema-based JSON (spec §16.3). */
  public String toJson(T x) {
    return type.toJson(bind.write(x, new Path()), options);
  }

  /**
   * The host values of a stream read from {@code in} (spec §6), each decoded with the type as it
   * is read; see {@link SchemaType#decodeStream}.
   */
  @SuppressWarnings("unchecked")
  public Stream<T> decodeStream(InputStream in, StreamOptions streamOptions) {
    Objects.requireNonNull(in, "in");
    int[] index = {0};
    return type.decodeStream(in, streamOptions).map(v -> (T) bind.read(v, new Path("$[" + index[0]++ + "]")));
  }

  @Override
  public String toString() {
    return "HausCodec(" + type.id() + ")";
  }
}
