package org.hausfmt;

import java.io.InputStream;
import java.util.List;

/**
 * The two JSON forms that need no schema (spec §16): the JSON import (§16.1), which reads any
 * JSON as a haus value, and self-describing JSON (§16.2), which writes every haus value exactly
 * and reads it back. The caller says which form it reads; the data never decides.
 *
 * <pre>{@code
 * Value v = HausJson.importJson("{\"price\": 19.90, \"note\": null}");   // { price: 19.90, note: None }
 * String json = HausJson.toHausJson(v);   // {"_haus":1,"_value":{"_rec":{"price":{"_num":"19.90"},…}}}
 * Value back = HausJson.fromHausJson(json);   // equal to v
 * }</pre>
 *
 * <p>Readers accept I-JSON (RFC 7493): UTF-8, no duplicate member names, no unpaired surrogates.
 * Numbers keep their exact text, never a float. The limits of spec §7 count the haus value: a
 * string's characters after its escapes, bytes as two characters a byte.
 */
public final class HausJson {
  private HausJson() {}

  // ── The import (§16.1) ──

  /**
   * Reads any JSON text as a haus value, with the default limits: an object as a record, an array
   * as an array, a string as a string, a number as a number with its literal normalized ({@code
   * 1E+05} is {@code 1e5}, {@code 19.90} stays {@code 19.90}), {@code true} and {@code false} as
   * {@code True} and {@code False}, and {@code null} as {@code None}. Nothing in the data is
   * special: {@code {"_tag": "A"}} is a record. A leading byte order mark is ignored.
   */
  public static Value importJson(String json) {
    return importJson(json, Limits.DEFAULT);
  }

  /** {@link #importJson(String)} with limits: the depth limit is the JSON nesting. */
  public static Value importJson(String json, Limits limits) {
    return JsonReader.read(Source.of(json), limits, JsonReader.Mode.IMPORT, true);
  }

  /** {@link #importJson(String)} of UTF-8 bytes. */
  public static Value importJson(byte[] json, Limits limits) {
    return JsonReader.read(new Source(json), limits, JsonReader.Mode.IMPORT, true);
  }

  // ── Self-describing JSON (§16.2) ──

  /**
   * Writes a value as self-describing JSON in its envelope, {@code {"_haus":1,"_value":…}}, on one
   * line without spaces, after checking it as {@link Haus#check} does with the default limits.
   * Strings are written with controls, DEL, C1 and bidi controls and U+2028 and U+2029 escaped.
   */
  public static String toHausJson(Value value) {
    return toHausJson(value, Limits.DEFAULT);
  }

  /** {@link #toHausJson(Value)}, checking the value against {@code limits}. */
  public static String toHausJson(Value value, Limits limits) {
    Haus.check(value, limits);
    StringBuilder b = new StringBuilder();
    JsonWriter.appendEnvelope(b, value);
    return b.toString();
  }

  /**
   * Reads self-describing JSON with the default limits. The text must be an envelope {@code
   * {"_haus": 1, "_value": …}}, and the value exactly one of the forms of §16.2 ({@code
   * haus-json-form} otherwise): every accepted text is the form of exactly one value. Errors in
   * the JSON text have its position; errors in the form have the path of the JSON member, such as
   * {@code $._value._rec.price._num}.
   */
  public static Value fromHausJson(String json) {
    return fromHausJson(json, Limits.DEFAULT);
  }

  /** {@link #fromHausJson(String)} with limits, counted on the haus value read; the JSON nesting is limited to 4·d + 2. */
  public static Value fromHausJson(String json, Limits limits) {
    return fromHausJson(Source.of(json), limits, true);
  }

  /** {@link #fromHausJson(String)} of UTF-8 bytes. */
  public static Value fromHausJson(byte[] json, Limits limits) {
    return fromHausJson(new Source(json), limits, true);
  }

  private static Value fromHausJson(Source src, Limits limits, boolean skipBom) {
    Value j = JsonReader.read(src, limits, JsonReader.Mode.SELF_DESCRIBING, skipBom);
    return SelfDescribing.envelope(j, limits, "$");
  }

  // ── JSON Lines (§16, "Streams") ──

  /**
   * Writes values as self-describing JSON Lines: an envelope per value, each followed by a line
   * feed. An error names the value's index in its path, {@code $[3]}.
   */
  public static String toHausJsonLines(List<Value> values) {
    StringBuilder b = new StringBuilder();
    for (int i = 0; i < values.size(); i++) {
      try {
        Haus.check(values.get(i), Limits.DEFAULT);
      } catch (HausException e) {
        throw JsonLinesReader.inLine(e, i);
      }
      JsonWriter.appendEnvelope(b, values.get(i));
      b.append('\n');
    }
    return b.toString();
  }

  /** Reads a whole text of self-describing JSON Lines: every value, or the first error. */
  public static List<Value> fromHausJsonLines(String text) {
    return JsonLinesReader.readAll(Source.utf8(text), hausJsonLine(Limits.DEFAULT));
  }

  /** Reads a whole text of JSON Lines with the JSON import. */
  public static List<Value> importJsonLines(String text) {
    return JsonLinesReader.readAll(Source.utf8(text), importLine(Limits.DEFAULT));
  }

  /**
   * A reader of self-describing JSON Lines from {@code in}, holding one line at a time, at most
   * {@link Limits#maxValueLength()} characters ({@code value-too-long}).
   */
  public static JsonLinesReader hausJsonLinesReader(InputStream in, Limits limits) {
    return new JsonLinesReader(in, limits.maxValueLength(), hausJsonLine(limits));
  }

  /** A reader of JSON Lines from {@code in} with the JSON import, as {@link #hausJsonLinesReader}. */
  public static JsonLinesReader importJsonLinesReader(InputStream in, Limits limits) {
    return new JsonLinesReader(in, limits.maxValueLength(), importLine(limits));
  }

  private static JsonLinesReader.Converter hausJsonLine(Limits limits) {
    return (line, index) -> fromHausJson(line, limits, index == 0);
  }

  private static JsonLinesReader.Converter importLine(Limits limits) {
    return (line, index) -> JsonReader.read(line, limits, JsonReader.Mode.IMPORT, index == 0);
  }
}
