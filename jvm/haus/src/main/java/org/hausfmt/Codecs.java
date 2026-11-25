package org.hausfmt;

import java.util.Collection;
import java.util.Collections;
import java.util.EnumMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** A set of {@link Codec}s, at most one per type id. Immutable. */
public final class Codecs {
  /** No codecs. */
  public static final Codecs NONE = new Codecs(Map.of());

  private final Map<String, Codec<?>> byId;

  private Codecs(Map<String, Codec<?>> byId) {
    this.byId = byId;
  }

  /**
   * The codecs, which must be for different types.
   *
   * @throws IllegalArgumentException if two codecs are for the same type
   */
  public static Codecs of(Codec<?>... codecs) {
    return of(List.of(codecs));
  }

  /** {@link #of(Codec...)} of a collection. */
  public static Codecs of(Collection<? extends Codec<?>> codecs) {
    Map<String, Codec<?>> byId = new LinkedHashMap<>();
    for (Codec<?> c : codecs) {
      if (byId.putIfAbsent(c.typeId(), c) != null) {
        throw new IllegalArgumentException("two codecs for the type " + c.typeId());
      }
    }
    return new Codecs(Collections.unmodifiableMap(byId));
  }

  /** The codec for the type id, or null. */
  public Codec<?> get(String typeId) {
    return byId.get(typeId);
  }

  /** Whether the set is empty. */
  public boolean isEmpty() {
    return byId.isEmpty();
  }

  /**
   * The codec for a named type without arguments: a type of the schema's files or packages, of
   * std/time, or of the prelude (a codec for {@code prelude#Decimal} applies to every {@code
   * Decimal}, spec §13.4); null if none.
   */
  Codec<?> forType(SchemaTypes.Typ t) {
    if (byId.isEmpty()) {
      return null;
    }
    if (t.kind == SchemaTypes.Kind.REF && t.inst.args.isEmpty()) {
      return byId.get(t.inst.id);
    }
    if (t.kind == SchemaTypes.Kind.TIME) {
      return byId.get("std/time#" + t.name);
    }
    String prelude = PRELUDE_IDS.get(t.kind);
    return prelude == null ? null : byId.get(prelude);
  }

  /** The ids of the prelude's types without parameters, by kind: {@code prelude#Decimal}. */
  private static final Map<SchemaTypes.Kind, String> PRELUDE_IDS = preludeIds();

  private static Map<SchemaTypes.Kind, String> preludeIds() {
    Map<SchemaTypes.Kind, String> ids = new EnumMap<>(SchemaTypes.Kind.class);
    for (SchemaTypes.Kind k : SchemaTypes.Kind.values()) {
      if (k.builtin != null) {
        ids.put(k, "prelude#" + k.builtin);
      }
    }
    return Collections.unmodifiableMap(ids);
  }

  /** The type ids of the codecs, in the order they were given. */
  Collection<String> ids() {
    return byId.keySet();
  }

  @Override
  public String toString() {
    return "Codecs" + byId.keySet();
  }
}
