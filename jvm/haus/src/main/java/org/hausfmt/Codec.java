package org.hausfmt;

import java.util.Objects;
import java.util.function.Function;

/**
 * Chooses the host type of a named type without arguments (spec §13.4), selected by the type's
 * id. A codec runs after the type's schema: it can reject more values, never fewer; it encodes
 * back to the type's values, so that decode, encode, decode is the same as decode; and it never
 * changes what a value means. Codecs are part of the application, not of the schema.
 *
 * <p>A typed codec ({@link HausCodec}) uses a codec wherever its type occurs and the host type is
 * asked for: a record component of type {@code Amount} for a field of type {@code Money}, with a
 * codec for {@code Money} to {@code Amount}.
 *
 * @param <T> the host type
 */
public interface Codec<T> {
  /** The id of the type the codec is for (spec §13.3): {@code std/time#Instant}, {@code @haus-fmt/money@1#Money}. */
  String typeId();

  /** The host type. */
  Class<T> hostType();

  /**
   * Turns a value the type's schema decoded into the host value, or rejects it by throwing: a
   * {@link HausException} keeps its code, any other exception is {@code codec-rejected}.
   */
  T decode(Value v);

  /** Turns a host value back into a value of the type. */
  Value encode(T x);

  /** A codec for the type with the id, from two functions on the host type. */
  static <T> Codec<T> of(String typeId, Class<T> hostType, Function<Value, T> decode, Function<T, Value> encode) {
    Objects.requireNonNull(typeId, "typeId");
    Objects.requireNonNull(hostType, "hostType");
    Objects.requireNonNull(decode, "decode");
    Objects.requireNonNull(encode, "encode");
    return new Codec<>() {
      @Override
      public String typeId() {
        return typeId;
      }

      @Override
      public Class<T> hostType() {
        return hostType;
      }

      @Override
      public T decode(Value v) {
        return decode.apply(v);
      }

      @Override
      public Value encode(T x) {
        return encode.apply(x);
      }

      @Override
      public String toString() {
        return "Codec(" + typeId + " ↔ " + hostType.getName() + ")";
      }
    };
  }
}
