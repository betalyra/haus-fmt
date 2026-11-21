package org.hausfmt;

import java.util.Collections;
import java.util.List;
import java.util.Objects;

/**
 * Reading and writing haus text (spec §1–§12).
 *
 * <pre>{@code
 * Value order = Haus.parse("{ id: 7, total: Money(44.40, EUR) }");
 * Value.Record r = (Value.Record) order;
 * String text = Haus.write(order, FormatOptions.COMPACT);   // { id: 7, total: Money(44.40, EUR) }
 * String hash = Haus.hash(order);                           // SHA-256 of the canonical form
 * }</pre>
 *
 * <p>Text is UTF-8: a {@code byte[]} is read as it is (invalid UTF-8 is an error), a {@code String}
 * as its UTF-8 bytes. A leading byte order mark is skipped. Every error is a {@link HausException}
 * with a code from the catalogue (spec §17).
 */
public final class Haus {
  private Haus() {}

  // ── Parsing ──

  /**
   * Reads text that must hold exactly one value (spec §6), with the default limits.
   *
   * @throws HausException for invalid text, or none or several values ({@code not-one-value})
   */
  public static Value parse(String text) {
    return parse(text, Limits.DEFAULT);
  }

  /** {@link #parse(String)} with the given limits. */
  public static Value parse(String text, Limits limits) {
    return one(parseAll(text, limits));
  }

  /** {@link #parse(String)} of UTF-8 bytes. */
  public static Value parse(byte[] text) {
    return parse(text, Limits.DEFAULT);
  }

  /** {@link #parse(String)} of UTF-8 bytes, with the given limits. */
  public static Value parse(byte[] text, Limits limits) {
    return one(parseAll(text, limits));
  }

  /**
   * Reads a file (spec §1, §6): zero or more top-level values, separated by commas, with an
   * optional comma after the last, with the default limits.
   */
  public static List<Value> parseAll(String text) {
    return parseAll(text, Limits.DEFAULT);
  }

  /** {@link #parseAll(String)} with the given limits. */
  public static List<Value> parseAll(String text, Limits limits) {
    return parseAll(Source.of(text), limits);
  }

  /** {@link #parseAll(String)} of UTF-8 bytes. */
  public static List<Value> parseAll(byte[] text) {
    return parseAll(text, Limits.DEFAULT);
  }

  /** {@link #parseAll(String)} of UTF-8 bytes, with the given limits. */
  public static List<Value> parseAll(byte[] text, Limits limits) {
    return parseAll(new Source(text), limits);
  }

  private static List<Value> parseAll(Source src, Limits limits) {
    Objects.requireNonNull(limits, "limits");
    try {
      return Collections.unmodifiableList(new Parser(src, limits, false, true).file());
    } catch (SyntaxError e) {
      throw src.error(e);
    }
  }

  private static Value one(List<Value> values) {
    return one(values, null);
  }

  /**
   * The one value of a single document (spec §6), or {@code not-one-value}; {@code path} is the
   * error's path: {@code $} when the value is read with a type, none for untyped text.
   */
  static Value one(List<Value> values, String path) {
    if (values.size() != 1) {
      throw new HausException(ErrorCode.NOT_ONE_VALUE, "expected exactly one value, found " + values.size(),
          0, 0, path, "one value", values.size() + " values");
    }
    return values.get(0);
  }

  // ── Formatting ──

  /**
   * Reformats haus text in a standard layout (spec §11). Numbers, byte strings and {@code "…"}
   * strings keep their spelling. The pretty layout keeps comments and blank lines; compact and
   * minimised drop them (see {@link #hasComments}).
   */
  public static String format(String text, FormatOptions options) {
    return format(Source.of(text), options);
  }

  /** {@link #format(String, FormatOptions)} of UTF-8 bytes. */
  public static String format(byte[] text, FormatOptions options) {
    return format(new Source(text), options);
  }

  private static String format(Source src, FormatOptions options) {
    return Printer.print(syntax(src, options.limits()), options);
  }

  /**
   * Whether haus text has comments, which the compact and minimised layouts drop (spec §11: a
   * tool that rewrites a file in place in those layouts refuses when it has comments, unless asked
   * to drop them).
   */
  public static boolean hasComments(String text) {
    return syntax(Source.of(text), Limits.DEFAULT).hasComments();
  }

  /** {@link #hasComments(String)} of UTF-8 bytes. */
  public static boolean hasComments(byte[] text) {
    return syntax(new Source(text), Limits.DEFAULT).hasComments();
  }

  /** The syntax tree of a text, with its comments. */
  static Syntax.File syntax(Source src, Limits limits) {
    try {
      Parser p = new Parser(src, limits, true, true);
      p.file();
      return p.syntax();
    } catch (SyntaxError e) {
      throw src.error(e);
    }
  }

  // ── Writing values ──

  /** Writes a value in the pretty layout, as a file holding it alone. See {@link #write(Value, FormatOptions)}. */
  public static String write(Value value) {
    return write(value, FormatOptions.PRETTY);
  }

  /**
   * Writes a value in a layout, as a file holding it alone. Without source text, numbers are
   * written normalized and in decimal, byte strings in lowercase hex without spaces, and strings
   * with the fewest escapes. The text ends with a line break.
   *
   * @throws HausException for a value that has no text within the limits of {@code options}: a
   *     number longer than the number limit ({@code number-too-long}) or with an exponent over the
   *     exponent limit ({@code exponent-too-large}), nesting deeper than the
   *     depth limit ({@code nesting-too-deep}, a record payload counting one level), or a string or
   *     key with an unpaired surrogate ({@code cannot-encode}); the error's path says where
   */
  public static String write(Value value, FormatOptions options) {
    return writeAll(Collections.singletonList(value), options);
  }

  /**
   * Writes values as a file (spec §6): one value alone, two or more as a stream with a comma after
   * each. See {@link #write(Value, FormatOptions)}; an error's path starts with the value's index,
   * {@code $[3]}, in a stream.
   */
  public static String writeAll(List<Value> values, FormatOptions options) {
    if (options.layout() == Layout.PRETTY) {
      return Printer.print(TreeBuilder.file(values, options.limits()), options);
    }
    return LineWriter.file(values, options.limits(), options.layout() == Layout.MINIMISED);
  }

  /**
   * Checks that a value built in code can be written within the limits (spec §7, §9.8): numbers,
   * strings, keys, tags and byte strings within their limits, nesting within the depth limit (a
   * record payload counting one level, an empty container one level), strings and keys with a
   * UTF-8 form ({@code cannot-encode}), and at most 64 Mi nodes ({@code too-many-nodes}, for values
   * that share containers many times). Values that {@link #parse} returns pass with the limits they
   * were parsed with.
   *
   * @throws HausException with the path of the problem, such as {@code $.items[2]}
   */
  public static void check(Value value, Limits limits) {
    ValueCheck.check(value, limits);
  }

  // ── Canonical form and hashing ──

  /**
   * The canonical form of a value (spec §12): one exact text, so that two values are equal
   * exactly when their canonical forms are identical. Records are sorted by key, numbers
   * normalized and in decimal, and there is no whitespace outside strings.
   *
   * @throws HausException with the code {@code cannot-encode} for a string or key with an unpaired
   *     surrogate, which has no text
   */
  public static String canonical(Value value) {
    return Canonical.of(value);
  }

  /**
   * The SHA-256 digest of the canonical form of a value, as 64 lowercase hex digits (spec §12). It
   * fails as {@link #canonical} does. The hash is unkeyed: don't publish the hash of a document
   * with private content (spec §9).
   */
  public static String hash(Value value) {
    return Canonical.sha256(Canonical.of(value));
  }

  /**
   * The hash of a list of values, such as a whole file (spec §12): the SHA-256 digest of their
   * canonical forms joined by {@code ,}. A list of one value hashes like the value, and the empty
   * list to the digest of the empty text. The items of a stream are hashed one by one with {@link
   * #hash}.
   */
  public static String hashAll(List<Value> values) {
    return Canonical.sha256(Canonical.ofAll(values));
  }

  /**
   * Orders values by the UTF-8 bytes of their canonical forms, shorter first when one is a prefix
   * of the other (spec §12): a total order consistent with equality, for sorting. It is not
   * numeric order: {@code 10} sorts before {@code 9}.
   */
  public static int compare(Value a, Value b) {
    return Canonical.compare(a, b);
  }
}
