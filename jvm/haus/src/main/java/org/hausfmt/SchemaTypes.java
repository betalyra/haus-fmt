package org.hausfmt;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Resolved types: what a schema means once its names are looked up, its imports loaded and its
 * generic types applied (spec §14, §15). Named types are instances, shared by every use; a
 * reference to one is a {@link Typ} of kind {@code REF}, which decoding follows to the instance's
 * resolved body in one step.
 */
final class SchemaTypes {
  private SchemaTypes() {}

  enum Kind {
    STRING("String"),
    BYTES("Bytes"),
    BOOL("Bool"),
    DECIMAL("Decimal"),
    INT("Int"),
    INT8("Int8"),
    INT16("Int16"),
    INT32("Int32"),
    INT64("Int64"),
    UINT8("UInt8"),
    UINT16("UInt16"),
    UINT32("UInt32"),
    UINT64("UInt64"),
    FLOAT32("Float32"),
    FLOAT64("Float64"),
    ANY("Any"),
    TIME(null), // a std/time type: name
    ARRAY(null), // elem
    MAP(null), // elem
    MAYBE(null), // elem
    SECRET(null), // elem
    RECORD(null), // rec
    VARIANT(null), // vrt (Result too, as closed < Err e | Ok a >)
    REF(null), // inst: a named type
    PARAM(null); // name: a type parameter, only in the template of a generic type

    /** The prelude's name of a builtin type without parameters; null for the others. */
    final String builtin;

    Kind(String builtin) {
      this.builtin = builtin;
    }

    boolean isInteger() {
      return compareTo(INT) >= 0 && compareTo(UINT64) <= 0;
    }
  }

  /** The prelude's types without parameters, by name. */
  static final Map<String, Kind> BUILTINS = new HashMap<>();

  static {
    for (Kind k : Kind.values()) {
      if (k.builtin != null) {
        BUILTINS.put(k.builtin, k);
      }
    }
  }

  /** The number of fields or cases from which lookups use a map. */
  static final int INDEX_FROM = 9;

  /** A resolved type. */
  static final class Typ {
    final Kind kind;
    String name; // TIME, PARAM
    Typ elem; // ARRAY, MAP, MAYBE, SECRET
    RecordType rec;
    VariantType vrt;
    Instance inst; // REF
    /** For a MAYBE: whether its schema-based JSON writes None as null (spec §16.3). */
    boolean jsonNull;

    Typ(Kind kind) {
      this.kind = kind;
    }

    static Typ of(Kind kind, Typ elem) {
      Typ t = new Typ(kind);
      t.elem = elem;
      return t;
    }

    static Typ named(Kind kind, String name) {
      Typ t = new Typ(kind);
      t.name = name;
      return t;
    }

    /** The type a reference stands for; other types themselves. */
    Typ resolve() {
      return kind == Kind.REF ? inst.resolved : this;
    }
  }

  /** {@code { … }} or {@code closed { … }}. */
  static final class RecordType {
    final boolean closed;
    final FieldType[] fields;
    private final Map<String, Integer> index; // for records with many fields; null for small ones

    RecordType(boolean closed, List<FieldType> fields) {
      this.closed = closed;
      this.fields = fields.toArray(new FieldType[0]);
      if (this.fields.length >= INDEX_FROM) {
        index = new HashMap<>();
        for (int i = 0; i < this.fields.length; i++) {
          index.put(this.fields[i].key, i);
        }
      } else {
        index = null;
      }
    }

    /** The place of the field {@code key}, or -1. */
    int indexOf(String key) {
      if (index != null) {
        Integer i = index.get(key);
        return i == null ? -1 : i;
      }
      for (int i = 0; i < fields.length; i++) {
        if (fields[i].key.equals(key)) {
          return i;
        }
      }
      return -1;
    }

    /** The field {@code key}, or null. */
    FieldType field(String key) {
      int i = indexOf(key);
      return i < 0 ? null : fields[i];
    }
  }

  /** A field of a record; {@code deprecated} is the {@code @deprecated} message, null if not deprecated. */
  record FieldType(String key, boolean optional, Typ typ, String deprecated) {}

  /** What a tag takes (spec §15, "Variants"). */
  enum Payload {
    NONE, // Tag
    RECORD, // Tag { … }: one record
    NAMED, // Tag R, R a named type that is a record: a record case too
    POSITIONAL // Tag A B: exactly these values
  }

  static final class CaseType {
    final String tag;
    final Payload payload;
    final RecordType rec; // RECORD
    final Typ named; // NAMED
    final Typ[] items; // POSITIONAL
    final String deprecated;

    CaseType(String tag, Payload payload, RecordType rec, Typ named, Typ[] items, String deprecated) {
      this.tag = tag;
      this.payload = payload;
      this.rec = rec;
      this.named = named;
      this.items = items;
      this.deprecated = deprecated;
    }
  }

  /** {@code < … >} or {@code closed < … >}. */
  static final class VariantType {
    final boolean open;
    final CaseType[] cases;
    private final Map<String, Integer> index;
    /** A closed variant whose tags have no payload: its schema-based JSON is the tag as a string. */
    final boolean enumLike;

    VariantType(boolean open, List<CaseType> cases) {
      this.open = open;
      this.cases = cases.toArray(new CaseType[0]);
      boolean e = !open;
      for (CaseType c : this.cases) {
        if (c.payload != Payload.NONE) {
          e = false;
        }
      }
      enumLike = e;
      if (this.cases.length >= INDEX_FROM) {
        index = new HashMap<>();
        for (int i = 0; i < this.cases.length; i++) {
          index.put(this.cases[i].tag, i);
        }
      } else {
        index = null;
      }
    }

    /** The place of the case of {@code tag}, or -1: dispatch is one lookup (§9.8). */
    int indexOf(String tag) {
      if (index != null) {
        Integer i = index.get(tag);
        return i == null ? -1 : i;
      }
      for (int i = 0; i < cases.length; i++) {
        if (cases[i].tag.equals(tag)) {
          return i;
        }
      }
      return -1;
    }

    CaseType caseOf(String tag) {
      int i = indexOf(tag);
      return i < 0 ? null : cases[i];
    }
  }

  /** A named type applied to arguments: its body with the parameters replaced. */
  static final class Instance {
    final String name;
    final String id; // the type's id (spec §13.3): @haus-fmt/money@1#Money
    final List<Typ> args;
    Typ body;
    /** The body with references followed: never a REF. */
    Typ resolved;
    /** Set for {@code type Events = Stream Event}: a file of bodies. */
    boolean stream;
    final int idx; // its index among the schema's instances

    Instance(String name, String id, List<Typ> args, int idx) {
      this.name = name;
      this.id = id;
      this.args = args;
      this.idx = idx;
      this.body = new Typ(Kind.ANY);
    }
  }

  /**
   * A short description of a type, as in a schema: {@code Array Line}, {@code Maybe Int}, {@code
   * one of A, B} (for messages; bounded). Arguments nested deeper than a few levels are left out:
   * they can be shared, so written in full they could double at every level.
   */
  static String describe(Typ t) {
    return describe(t, 0);
  }

  private static String describe(Typ t, int depth) {
    switch (t.kind) {
      case TIME:
      case PARAM:
        return t.name;
      case ARRAY:
        return "Array " + atom(t.elem, depth);
      case MAP:
        return "Map " + atom(t.elem, depth);
      case MAYBE:
        return "Maybe " + atom(t.elem, depth);
      case SECRET:
        return "Secret " + atom(t.elem, depth);
      case RECORD:
        return "a record";
      case VARIANT:
        return tags(t.vrt);
      case REF: {
        if (t.inst.args.isEmpty()) {
          return t.inst.name;
        }
        List<String> args = new ArrayList<>();
        for (Typ a : t.inst.args) {
          args.add(depth < 2 ? atom(a, depth + 1) : "…");
        }
        String s = t.inst.name + " " + String.join(" ", args);
        return s.length() > 80 ? t.inst.name + " …" : s;
      }
      default:
        return t.kind.builtin;
    }
  }

  private static String atom(Typ t, int depth) {
    String d = describe(t, depth);
    if (d.contains(" ") && !d.startsWith("one of") && !d.equals("a record") && !d.equals("any tag")) {
      return "(" + d + ")";
    }
    return d;
  }

  /** The tags of a variant, for messages: {@code one of A, B}, or {@code any tag} for {@code < >}. */
  static String tags(VariantType v) {
    List<String> names = new ArrayList<>();
    for (int i = 0; i < v.cases.length; i++) {
      if (i == 6) {
        return "one of " + String.join(", ", names) + ", …";
      }
      names.add(v.cases[i].tag);
    }
    return names.isEmpty() ? "any tag" : "one of " + String.join(", ", names);
  }
}
