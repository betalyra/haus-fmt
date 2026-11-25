package org.hausfmt;

import java.util.Base64;
import org.hausfmt.SchemaTypes.CaseType;
import org.hausfmt.SchemaTypes.FieldType;
import org.hausfmt.SchemaTypes.Payload;
import org.hausfmt.SchemaTypes.RecordType;
import org.hausfmt.SchemaTypes.Typ;
import org.hausfmt.SchemaTypes.VariantType;

/**
 * Writes a decoded value with its type as schema-based JSON (spec §16.3), on one line without
 * spaces. The value has been checked and encoded with the type first.
 */
final class SchemaJsonWriter {
  private final StringBuilder b;
  private final Path path = new Path();

  SchemaJsonWriter(StringBuilder b) {
    this.b = b;
  }

  private HausException fail(ErrorCode code, String reason) {
    return path.error(code, reason);
  }

  /** Writes {@code v}, which the type {@code t} decoded (or encoded). */
  void value(Value v, Typ t) {
    Typ rt = t.resolve();
    switch (rt.kind) {
      case STRING:
        if (v instanceof Value.Text) {
          JsonWriter.appendString(b, ((Value.Text) v).value());
          return;
        }
        break;
      case TIME:
        if (v instanceof Value.Variant && ((Value.Variant) v).size() == 1 && ((Value.Variant) v).get(0) instanceof Value.Text) {
          JsonWriter.appendString(b, ((Value.Text) ((Value.Variant) v).get(0)).value());
          return;
        }
        break;
      case BYTES:
        if (v instanceof Value.Bytes) {
          b.append('"').append(Base64.getEncoder().encodeToString(((Value.Bytes) v).unsafeBytes())).append('"');
          return;
        }
        break;
      case BOOL:
        if (v instanceof Value.Variant) {
          b.append(((Value.Variant) v).tag().equals("True") ? "true" : "false");
          return;
        }
        break;
      case INT8:
      case INT16:
      case INT32:
      case UINT8:
      case UINT16:
      case UINT32:
        if (v instanceof Value.Number) {
          b.append(((Value.Number) v).literal());
          return;
        }
        break;
      case INT:
      case INT64:
      case UINT64:
      case DECIMAL:
        if (v instanceof Value.Number) {
          b.append('"').append(((Value.Number) v).literal()).append('"');
          return;
        }
        break;
      case FLOAT32:
      case FLOAT64:
        if (v instanceof Value.Number) {
          b.append(((Value.Number) v).literal());
          return;
        }
        if (v instanceof Value.Variant) {
          String tag = ((Value.Variant) v).tag();
          b.append(tag.equals("NaN") ? "\"NaN\"" : tag.equals("Infinity") ? "\"Infinity\"" : "\"-Infinity\"");
          return;
        }
        break;
      case ANY:
        JsonWriter.appendSelfDescribing(b, v);
        return;
      case ARRAY:
        if (v instanceof Value.Array) {
          Value[] a = ((Value.Array) v).unsafeItems();
          b.append('[');
          for (int i = 0; i < a.length; i++) {
            if (i > 0) {
              b.append(',');
            }
            path.index(i);
            value(a[i], rt.elem);
            path.pop();
          }
          b.append(']');
          return;
        }
        break;
      case MAP:
        if (v instanceof Value.Record) {
          Value.Record r = (Value.Record) v;
          b.append('{');
          for (int i = 0; i < r.size(); i++) {
            member(i == 0, r.keyAt(i), r.valueAt(i), rt.elem);
          }
          b.append('}');
          return;
        }
        break;
      case MAYBE:
        maybe(v, rt);
        return;
      case SECRET:
        value(v instanceof Value.Secret s ? s.reveal() : v, rt.elem);
        return;
      case RECORD:
        if (v instanceof Value.Record) {
          b.append('{');
          fields(true, (Value.Record) v, rt.rec);
          b.append('}');
          return;
        }
        break;
      case VARIANT:
        if (v instanceof Value.Variant) {
          variant((Value.Variant) v, rt.vrt);
          return;
        }
        break;
      default:
        break;
    }
    throw fail(ErrorCode.CANNOT_ENCODE, "expected " + SchemaTypes.describe(t) + ", found " + Decoder.found(v));
  }

  /** Writes {@code "key": value}, after a comma unless first. */
  private void member(boolean first, String k, Value x, Typ t) {
    if (!first) {
      b.append(',');
    }
    JsonWriter.appendString(b, k);
    b.append(':');
    path.key(k);
    value(x, t);
    path.pop();
  }

  /** Writes the fields of {@code r} the record type lists; returns whether none was written and {@code first} still holds. */
  private boolean fields(boolean first, Value.Record r, RecordType rt) {
    for (int i = 0; i < r.size(); i++) {
      FieldType f = rt.field(r.keyAt(i));
      if (f == null) {
        continue; // ignored by an open record
      }
      member(first, r.keyAt(i), r.valueAt(i), f.typ());
      first = false;
    }
    return first;
  }

  private void maybe(Value v, Typ rt) {
    if (!(v instanceof Value.Variant)
        || !((Value.Variant) v).tag().equals("None") && ((Value.Variant) v).size() != 1) {
      throw fail(ErrorCode.CANNOT_ENCODE, "expected None or Some(…), found " + Decoder.found(v));
    }
    Value.Variant x = (Value.Variant) v;
    if (x.tag().equals("None")) {
      b.append(rt.jsonNull ? "null" : "{\"_tag\":\"None\"}");
      return;
    }
    path.index(0);
    if (rt.jsonNull) {
      value(x.get(0), rt.elem);
    } else {
      b.append("{\"_tag\":\"Some\",\"value\":");
      value(x.get(0), rt.elem);
      b.append('}');
    }
    path.pop();
  }

  private void variant(Value.Variant x, VariantType vt) {
    if (vt.enumLike) {
      JsonWriter.appendString(b, x.tag());
      return;
    }
    b.append("{\"_tag\":");
    JsonWriter.appendString(b, x.tag());
    CaseType c = vt.caseOf(x.tag());
    Value[] args = x.unsafeArgs();
    if (c == null) {
      if (args.length > 0) { // an unknown value
        b.append(",\"_args\":[");
        for (int i = 0; i < args.length; i++) {
          if (i > 0) {
            b.append(',');
          }
          JsonWriter.appendSelfDescribing(b, args[i]);
        }
        b.append(']');
      }
    } else if (c.payload == Payload.RECORD || c.payload == Payload.NAMED) {
      String f = SchemaLoader.reservedField(c);
      if (f != null) {
        throw fail(ErrorCode.NO_JSON_FORM, c.tag + " has a field named " + f + ", so it has no schema-based JSON form");
      }
      Value.Record r = x.payload();
      if (r == null) {
        throw fail(ErrorCode.CANNOT_ENCODE, c.tag + " takes one argument, a record");
      }
      fields(false, r, SchemaLoader.caseRecord(c));
    } else if (c.payload == Payload.POSITIONAL && c.items.length == 1) {
      b.append(",\"value\":");
      path.index(0);
      value(args[0], c.items[0]);
      path.pop();
    } else if (c.payload == Payload.POSITIONAL) {
      b.append(",\"values\":[");
      for (int i = 0; i < args.length; i++) {
        if (i > 0) {
          b.append(',');
        }
        path.index(i);
        value(args[i], c.items[i]);
        path.pop();
      }
      b.append(']');
    }
    b.append('}');
  }
}
