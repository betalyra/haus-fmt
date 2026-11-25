package org.hausfmt;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Deque;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import org.hausfmt.SchemaTypes.CaseType;
import org.hausfmt.SchemaTypes.FieldType;
import org.hausfmt.SchemaTypes.Instance;
import org.hausfmt.SchemaTypes.Typ;

/**
 * Official profiles without their codecs (spec §13.4, "A profile without its codec"). A package's
 * rule is checked only where a codec applies it: a schema that reaches {@code Currency} without a
 * codec for it checks currencies for their shape only. That is allowed, never an error, but not
 * silent. Codecs are given to each decoding call ({@link DecodeOptions}), so the warnings are asked
 * for with them: {@link SchemaType#missingCodecs} and {@link Schema#missingCodecs}. Codecs for an
 * id that no type has are pointed out the same way, by {@link Schema#unusedCodecs}.
 */
public final class Profiles {
  private Profiles() {}

  /**
   * The types official profiles have a rule for, by id, with the profiles (spec §13.4). The {@code
   * iso} profile's rule for {@code Money} is its currency's, so {@code Currency} stands for it. A
   * build reads only a package's {@code package.haus} and {@code schema.haus}, so the binding keeps
   * this table itself.
   */
  public static final Map<String, List<String>> PROFILED_TYPES =
      Map.of(
          "@haus-fmt/money@1#Currency", List.of("iso"),
          "@haus-fmt/geo@1#LatLng", List.of("wgs84"),
          "@haus-fmt/geo@1#BBox", List.of("wgs84"),
          "@haus-fmt/uuid@1#Uuid", List.of("rfc9562"));

  /**
   * The {@code missing-codec} warnings for decoding the types {@code roots} with {@code codecs}:
   * one for each type of {@link #PROFILED_TYPES} they reach without a codec, sorted by id, at no
   * place. A type reached only inside a type that has a codec doesn't count.
   */
  static List<HausException> missingCodecs(List<Typ> roots, Codecs codecs) {
    Set<String> missing = new TreeSet<>();
    Set<Object> seen = Collections.newSetFromMap(new IdentityHashMap<>());
    // An explicit stack: types nest as deep as schema files allow, and instances form cycles.
    Deque<Typ> stack = new ArrayDeque<>(roots);
    while (!stack.isEmpty()) {
      Typ t = stack.pop();
      if (t == null || !seen.add(t)) {
        continue;
      }
      switch (t.kind) {
        case REF -> {
          Instance inst = t.inst;
          if (!seen.add(inst)) {
            continue;
          }
          boolean plain = inst.args.isEmpty();
          if (plain && codecs.get(inst.id) != null) {
            continue;
          }
          if (plain && PROFILED_TYPES.containsKey(inst.id)) {
            missing.add(inst.id);
          }
          stack.push(inst.body);
        }
        case ARRAY, MAP, MAYBE, SECRET -> stack.push(t.elem);
        case RECORD -> {
          for (FieldType f : t.rec.fields) {
            stack.push(f.typ());
          }
        }
        case VARIANT -> {
          for (CaseType c : t.vrt.cases) {
            if (c.rec != null) {
              for (FieldType f : c.rec.fields) {
                stack.push(f.typ());
              }
            }
            if (c.named != null) {
              stack.push(c.named);
            }
            if (c.items != null) {
              for (Typ item : c.items) {
                stack.push(item);
              }
            }
          }
        }
        default -> {}
      }
    }
    List<HausException> out = new ArrayList<>();
    for (String id : missing) {
      out.add(missingCodec(id));
    }
    return List.copyOf(out);
  }

  /**
   * The {@code unused-codec} warnings for {@code codecs} with a schema whose files have the type
   * ids {@code ids}: one for each codec whose id is none of them nor a type of the prelude or of
   * std/time, sorted by id, at no place.
   */
  static List<HausException> unusedCodecs(Set<String> ids, Codecs codecs) {
    Set<String> unused = new TreeSet<>();
    for (String id : codecs.ids()) {
      if (!ids.contains(id) && !standardId(id)) {
        unused.add(id);
      }
    }
    List<HausException> out = new ArrayList<>();
    for (String id : unused) {
      out.add(HausException.of(ErrorCode.UNUSED_CODEC, "a codec is set for " + id
          + ", but no type has that id: it never runs, and its values are checked for their shape only"));
    }
    return List.copyOf(out);
  }

  /** Whether {@code id} is the id of a type of the prelude or of std/time. */
  private static boolean standardId(String id) {
    if (id.startsWith("prelude#")) {
      String name = id.substring("prelude#".length());
      return SchemaTypes.BUILTINS.containsKey(name) || SchemaLoader.GENERIC.containsKey(name);
    }
    return id.startsWith("std/time#") && StdTime.TYPES.contains(id.substring("std/time#".length()));
  }

  /** The warning for a type of {@link #PROFILED_TYPES} without its codec. */
  static HausException missingCodec(String id) {
    String profiles = String.join(", ", PROFILED_TYPES.get(id));
    return HausException.of(
        ErrorCode.MISSING_CODEC,
        id
            + " has profiles ("
            + profiles
            + "), but no codec is set for it: its values are checked for their shape only");
  }
}
