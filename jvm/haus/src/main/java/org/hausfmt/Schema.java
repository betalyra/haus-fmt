package org.hausfmt;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import org.hausfmt.SchemaTypes.Instance;

/**
 * A schema file (spec §14) with its imports (spec §13.3) resolved and every rule of §14 and §13.3
 * checked, so that its types decode in time linear in the input. Immutable and safe for
 * concurrent use.
 *
 * <pre>{@code
 * Schema s = Schema.load(Path.of("order.schema.haus"),
 *     SchemaOptions.DEFAULT.withPackages(PackageLocator.explicit().folder(Path.of("schemas"))));
 * Value order = s.type("Order").decode(Haus.parse(text));
 * }</pre>
 *
 * <p>Errors are {@link HausException}s with a code (spec §17) and, for a mistake in a schema file,
 * its line and column; a mistake in an imported file is reported at the import, with its place in
 * that file.
 */
public final class Schema {
  private final List<SchemaDefinition> definitions;
  private final List<Instance> templates;
  private final int own;
  private final List<HausException> warnings;
  private final List<SchemaPackage> packages;
  private final Map<String, Integer> byName = new HashMap<>();
  /** The ids of the types of every file loaded: its own, and those of the files and packages it imports. */
  private final Set<String> ids;

  Schema(List<SchemaDefinition> definitions, List<Instance> templates, int own, List<HausException> warnings,
      List<SchemaPackage> packages, Set<String> ids) {
    this.definitions = List.copyOf(definitions);
    this.templates = List.copyOf(templates);
    this.own = own;
    this.warnings = List.copyOf(warnings);
    this.packages = List.copyOf(packages);
    this.ids = Set.copyOf(ids);
    for (int i = 0; i < definitions.size(); i++) {
      byName.put(definitions.get(i).name(), i);
    }
  }

  /**
   * Reads a schema from text, which imports std/time and the packages {@code options} finds;
   * relative imports fail ({@code import-unavailable}), as text has no place among files.
   */
  public static Schema parse(String text, SchemaOptions options) {
    return SchemaLoader.parse(text, options);
  }

  /** {@link #parse(String, SchemaOptions)} with the default options. */
  public static Schema parse(String text) {
    return parse(text, SchemaOptions.DEFAULT);
  }

  /** {@link #parse(String, SchemaOptions)} of UTF-8 bytes. */
  public static Schema parse(byte[] text, SchemaOptions options) {
    Source src = new Source(text);
    try {
      src.checkUtf8();
    } catch (SyntaxError e) {
      throw src.error(e);
    }
    return parse(Scan.utf8(text, 0, text.length), options);
  }

  /**
   * Reads the schema file at {@code path}, its relative imports next to it, and the packages it
   * imports, found by {@code options}' locator. Errors in an imported file are reported at the
   * import, with their place in that file.
   *
   * <p>Relative imports stay inside the build's root (spec §13.3): the directory of the file's
   * real path, or {@code options}' {@link SchemaOptions#root() root}; one that leaves it is {@code
   * import-outside-root}. Messages show paths relative to the root. Every file read is a regular
   * file, opened without following a link at its last name; the type is checked just before the
   * open, as Java can't open a file without blocking, so a file swapped for a FIFO in between can
   * block the load (only someone who may write to the schema's directories can do that).
   */
  public static Schema load(Path path, SchemaOptions options) {
    return SchemaLoader.load(path.toString(), Objects.requireNonNull(options, "options"));
  }

  /** {@link #load(Path, SchemaOptions)} with the default options: no packages. */
  public static Schema load(Path path) {
    return load(path, SchemaOptions.DEFAULT);
  }

  /**
   * The definition called {@code name}, which must have no parameters.
   *
   * @throws HausException {@code unknown-type} if there is none, {@code wrong-arity} if it has
   *     parameters
   */
  public SchemaType type(String name) {
    Integer i = byName.get(name);
    if (i == null) {
      throw HausException.of(ErrorCode.UNKNOWN_TYPE, "the schema has no type " + SchemaText.quote(name));
    }
    if (!definitions.get(i).params().isEmpty()) {
      throw HausException.of(ErrorCode.WRONG_ARITY, name + " needs arguments, so it can't describe a whole file");
    }
    return new SchemaType(templates.get(i), name);
  }

  /** Decodes {@code v} with the type called {@code name}; see {@link SchemaType#decode}. */
  public Value decode(String name, Value v) {
    return type(name).decode(v);
  }

  /**
   * The typed codec of the type called {@code name} as the host class; see {@link HausCodec}.
   *
   * @throws IllegalArgumentException if the class doesn't fit the type
   */
  public <T> HausCodec<T> codec(String name, Class<T> host) {
    return HausCodec.of(type(name), host);
  }

  /** {@link #codec(String, Class)} with options: limits, and codecs for named types. */
  public <T> HausCodec<T> codec(String name, Class<T> host, DecodeOptions options) {
    return HausCodec.of(type(name), host, options);
  }

  /** The file's own definitions, in source order. */
  public List<SchemaDefinition> definitions() {
    return definitions.subList(0, own);
  }

  /** The types the file imports from packages and files (not std/time), by the name they have in it. */
  public List<SchemaDefinition> imported() {
    return definitions.subList(own, definitions.size());
  }

  /** Every schema package the schema reaches, by name. */
  public List<SchemaPackage> packages() {
    return packages;
  }

  /**
   * What to point out in the file (not in the files it imports), in source order: attributes this
   * version doesn't define ({@code unknown-attribute}), uses of deprecated types ({@code
   * deprecated}), and record cases with no schema-based JSON form ({@code no-json-form}).
   */
  public List<HausException> warnings() {
    return warnings;
  }

  /**
   * The {@code missing-codec} warnings of {@link SchemaType#missingCodecs} for every type the file's
   * own definitions reach, decoded with {@code codecs} (spec §13.4).
   */
  public List<HausException> missingCodecs(Codecs codecs) {
    List<SchemaTypes.Typ> roots = new ArrayList<>();
    for (Instance template : templates.subList(0, own)) {
      roots.add(template.body);
    }
    return Profiles.missingCodecs(roots, Objects.requireNonNull(codecs, "codecs"));
  }

  /**
   * The {@code unused-codec} warnings for decoding the schema's types with {@code codecs} (spec
   * §13.4, "A codec that matches no type"): one for each codec whose id is no type of the prelude,
   * of std/time, nor of the schema's files and the packages they import, such as a typo or {@code
   * @haus-fmt/money@2#Money} when the schema imports major 1. Such a codec never runs, and the
   * values it was meant to check pass. Sorted by id, at no place, like {@link #warnings()}.
   */
  public List<HausException> unusedCodecs(Codecs codecs) {
    return Profiles.unusedCodecs(ids, Objects.requireNonNull(codecs, "codecs"));
  }
}
