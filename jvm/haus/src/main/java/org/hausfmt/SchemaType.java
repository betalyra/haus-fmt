package org.hausfmt;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;
import java.util.stream.Stream;
import org.hausfmt.SchemaTypes.Instance;
import org.hausfmt.SchemaTypes.Kind;
import org.hausfmt.SchemaTypes.Typ;

/**
 * A named type of a {@link Schema}, without parameters: what a whole value (or, for a {@code
 * Stream} definition, each value of a stream) is decoded with (spec §15). Get one with {@link
 * Schema#type}. Immutable and safe for concurrent use.
 *
 * <p>{@link #decode} gives the value an encoder writes back: integers in decimal ({@code -0} as
 * {@code 0}), floats in their one spelling, the fields an open record doesn't list left out, and
 * everything else as it was. Errors are {@link HausException}s with a code (spec §17) and the path
 * of the failing value ({@code $.items[2].price}).
 */
public final class SchemaType {
  private final Typ t;
  private final String name;

  SchemaType(Instance inst, String name) {
    Typ ref = new Typ(Kind.REF);
    ref.inst = inst;
    this.t = ref;
    this.name = name;
  }

  Typ typ() {
    return t;
  }

  /** The type's name in the schema. */
  public String name() {
    return name;
  }

  /** The type's id (spec §13.3): {@code @haus-fmt/money@1#Money}. */
  public String id() {
    return t.inst.id;
  }

  /**
   * Whether the type is a {@code Stream} definition, {@code type Events = Stream Event}: it
   * describes a file, each of whose values {@link #decode} decodes as an {@code Event}.
   */
  public boolean isStream() {
    return t.inst.stream;
  }

  /**
   * Decodes {@code v} with the type, with the default limits, and returns the value an encoder
   * writes back (spec §15). An error inside a {@code Secret} is {@code invalid-secret}, at the
   * secret. For a {@code Stream} definition, {@code v} is one value of the stream.
   *
   * @throws HausException with the code and the path of the failing value
   */
  public Value decode(Value v) {
    return decode(v, DecodeOptions.DEFAULT);
  }

  /** {@link #decode(Value)} with options: limits and codecs. */
  public Value decode(Value v, DecodeOptions options) {
    return Decoder.run(t, Objects.requireNonNull(v, "value"), options, false, "$");
  }

  /**
   * Checks a value built in code against the type and returns the value to write (spec §15): what
   * {@link #decode} gives for it. Besides decode's errors, it detects strings and keys with an
   * unpaired surrogate ({@code cannot-encode}) and numbers beyond the limits.
   */
  public Value encode(Value v) {
    return encode(v, DecodeOptions.DEFAULT);
  }

  /** {@link #encode(Value)} with options. */
  public Value encode(Value v, DecodeOptions options) {
    return Decoder.run(t, Objects.requireNonNull(v, "value"), options, true, "$");
  }

  /**
   * Decodes the values of a file with the type: each on its own with the type a {@code Stream}
   * definition holds; any other type expects exactly one value ({@code not-one-value}). An error's
   * path starts with the value's index for a stream: {@code $[3].total}.
   */
  public List<Value> decodeAll(List<Value> values) {
    if (!isStream()) {
      if (values.size() != 1) {
        throw HausException.of(ErrorCode.NOT_ONE_VALUE,
            name + " is not a Stream: expected one value, found " + values.size());
      }
      return List.of(decode(values.get(0)));
    }
    List<Value> out = new ArrayList<>(values.size());
    for (int i = 0; i < values.size(); i++) {
      out.add(Decoder.run(t, values.get(i), DecodeOptions.DEFAULT, false, "$[" + i + "]"));
    }
    return Collections.unmodifiableList(out);
  }

  /**
   * Reads a stream from {@code in} and decodes each value with the type as it is read (spec §6,
   * §15). An error's path starts with the value's index: {@code $[3].total}. The stream throws
   * at the first error; close it to close the input.
   */
  public Stream<Value> decodeStream(InputStream in, StreamOptions options) {
    StreamReader reader = new StreamReader(in, options);
    DecodeOptions opts = DecodeOptions.DEFAULT.withLimits(options.limits());
    int[] index = {0};
    return reader.stream().map(v -> Decoder.run(t, v, opts, false, "$[" + index[0]++ + "]"));
  }

  // ── Schema-based JSON (§16.3) ──

  /**
   * The type's schema-based JSON of {@code v} (spec §16.3), on one line without spaces. {@code v}
   * is checked and encoded as {@link #encode} does first, so it can be a value built in code; what
   * an open record doesn't list is left out. A value of a record case with a field named {@code
   * _tag} or {@code _args} has no schema-based form ({@code no-json-form}).
   */
  public String toJson(Value v) {
    return toJson(v, DecodeOptions.DEFAULT);
  }

  /** {@link #toJson(Value)} with options. */
  public String toJson(Value v, DecodeOptions options) {
    StringBuilder b = new StringBuilder();
    new SchemaJsonWriter(b).value(encode(v, options), t);
    return b.toString();
  }

  /**
   * Reads the type's schema-based JSON (spec §16.3) and returns the decoded value: what {@link
   * #decode} gives for the haus value the JSON stands for. Open records ignore members they don't
   * list; a tag an open variant doesn't list reads as an unknown value. Errors in the JSON text
   * have its position; errors in the value have the path of the JSON member.
   */
  public Value fromJson(String json) {
    return fromJson(Source.of(json), DecodeOptions.DEFAULT, true, "$");
  }

  /** {@link #fromJson(String)} of UTF-8 bytes, with options. */
  public Value fromJson(byte[] json, DecodeOptions options) {
    return fromJson(new Source(json), options, true, "$");
  }

  private Value fromJson(Source src, DecodeOptions options, boolean skipBom, String root) {
    Value j = JsonReader.read(src, options.limits(), JsonReader.Mode.SCHEMA, skipBom);
    return Decoder.readJson(t, j, options, root);
  }

  /**
   * Writes values as JSON Lines (spec §16, "Streams"): the schema-based JSON of each, followed by
   * a line feed. An error's path starts with the value's index, {@code $[3].total}.
   */
  public String toJsonLines(List<Value> values) {
    StringBuilder b = new StringBuilder();
    for (int i = 0; i < values.size(); i++) {
      try {
        b.append(toJson(values.get(i))).append('\n');
      } catch (HausException e) {
        throw e.withPath(Path.under("$[" + i + "]", e.path() == null ? "$" : e.path()));
      }
    }
    return b.toString();
  }

  /** Reads a whole text of JSON Lines with the type: every value, or the first error. */
  public List<Value> fromJsonLines(String text) {
    return Collections.unmodifiableList(JsonLinesReader.readAll(Source.utf8(text), jsonLine(DecodeOptions.DEFAULT)));
  }

  /**
   * A reader of JSON Lines from {@code in}, each line the schema-based JSON of a value of the type,
   * holding one line at a time, at most {@link Limits#maxValueLength()} characters.
   */
  public JsonLinesReader jsonLinesReader(InputStream in, DecodeOptions options) {
    return new JsonLinesReader(in, options.limits().maxValueLength(), jsonLine(options));
  }

  private JsonLinesReader.Converter jsonLine(DecodeOptions options) {
    return (line, index) -> fromJson(line, options, index == 0, "$");
  }

  @Override
  public String toString() {
    return "SchemaType(" + id() + ")";
  }
}
