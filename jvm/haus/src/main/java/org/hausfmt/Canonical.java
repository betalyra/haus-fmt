package org.hausfmt;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.List;

/**
 * The canonical form (spec §12): one exact text per value, so that two values are equal exactly
 * when their canonical forms are identical. Records are sorted by key code points, numbers
 * normalized and in decimal, and there is no whitespace outside strings.
 */
final class Canonical {
  private final StringBuilder b = new StringBuilder();
  /** Whether to fail for a string or key without a UTF-8 form; without, it is written as U+FFFD. */
  private final boolean check;

  private Canonical(boolean check) {
    this.check = check;
  }

  static String of(Value v) {
    Canonical c = new Canonical(true);
    c.value(v);
    return c.b.toString();
  }

  /** The values' canonical forms joined by {@code ,} (spec §12, {@code hashAll}). */
  static String ofAll(List<Value> values) {
    Canonical c = new Canonical(true);
    for (int i = 0; i < values.size(); i++) {
      if (i > 0) {
        c.b.append(',');
      }
      c.value(values.get(i));
    }
    return c.b.toString();
  }

  /** The SHA-256 digest of the text's UTF-8 bytes, as 64 lowercase hex digits. */
  static String sha256(String text) {
    try {
      byte[] digest = MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8));
      StringBuilder hex = new StringBuilder(64);
      WriteCheck.appendHex(hex, digest);
      return hex.toString();
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException("every Java platform has SHA-256", e);
    }
  }

  /**
   * Orders values by the UTF-8 bytes of their canonical forms, shorter first when one is a prefix
   * of the other (spec §12). A string without a UTF-8 form sorts as if it held U+FFFD there.
   */
  static int compare(Value x, Value y) {
    Canonical cx = new Canonical(false);
    cx.value(x);
    Canonical cy = new Canonical(false);
    cy.value(y);
    return Scan.compareCodePoints(cx.b.toString(), cy.b.toString());
  }

  private void value(Value v) {
    switch (v.kind()) {
      case NUMBER:
        b.append(((Value.Number) v).literal());
        break;
      case STRING:
        string(((Value.Text) v).value(), "string");
        break;
      case BYTES:
        WriteCheck.appendBytes(b, (Value.Bytes) v);
        break;
      case ARRAY:
        items('[', ']', ((Value.Array) v).unsafeItems());
        break;
      case RECORD:
        record((Value.Record) v);
        break;
      case VARIANT:
        Value.Variant variant = (Value.Variant) v;
        b.append(variant.tag());
        if (variant.payload() != null) {
          record(variant.payload());
        } else if (variant.size() > 0) {
          items('(', ')', variant.unsafeArgs());
        }
        break;
    }
  }

  private void string(String s, String what) {
    if (!Quoting.appendQuoted(b, s) && check) {
      throw HausException.of(ErrorCode.CANNOT_ENCODE, "a " + what + " with an unpaired surrogate, which has no UTF-8 form");
    }
  }

  private void items(char open, char closer, Value[] vs) {
    b.append(open);
    for (int i = 0; i < vs.length; i++) {
      if (i > 0) {
        b.append(',');
      }
      value(vs[i]);
    }
    b.append(closer);
  }

  private void record(Value.Record r) {
    String[] keys = r.unsafeKeys();
    Integer[] order = new Integer[keys.length];
    for (int i = 0; i < order.length; i++) {
      order[i] = i;
    }
    Arrays.sort(order, (x, y) -> Scan.compareCodePoints(keys[x], keys[y]));
    b.append('{');
    for (int k = 0; k < order.length; k++) {
      if (k > 0) {
        b.append(',');
      }
      String key = keys[order[k]];
      if (Scan.isIdent(key)) {
        b.append(key);
      } else {
        string(key, "key");
      }
      b.append(':');
      value(r.valueAt(order[k]));
    }
    b.append('}');
  }
}
