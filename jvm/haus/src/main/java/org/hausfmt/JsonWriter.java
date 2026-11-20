package org.hausfmt;

/** Writes JSON (spec §16): strings, and the self-describing form of values (§16.2). */
final class JsonWriter {
  private JsonWriter() {}

  private static final char[] LOWER_HEX = "0123456789abcdef".toCharArray();

  /**
   * Appends {@code s} as a JSON string. Besides the quote and the backslash, it escapes what
   * writers must (§16): every character below U+0020, DEL, C1 controls, bidi controls and U+2028
   * and U+2029; an unpaired surrogate, which values that are written don't hold, as its <code>&#92;u</code>
   * escape.
   */
  static void appendString(StringBuilder b, String s) {
    b.append('"');
    int plain = 0;
    int n = s.length();
    for (int i = 0; i < n; i++) {
      char c = s.charAt(i);
      if (c >= 0x20 && c < Scan.DEL && c != '"' && c != '\\') {
        continue;
      }
      if (Character.isHighSurrogate(c) && i + 1 < n && Character.isLowSurrogate(s.charAt(i + 1))) {
        i++;
        continue;
      }
      if (c > Scan.DEL && !Character.isSurrogate(c) && !Scan.needsEscape(c)) {
        continue;
      }
      b.append(s, plain, i);
      switch (c) {
        case '"':
          b.append("\\\"");
          break;
        case '\\':
          b.append("\\\\");
          break;
        case '\n':
          b.append("\\n");
          break;
        case '\r':
          b.append("\\r");
          break;
        case '\t':
          b.append("\\t");
          break;
        default:
          b.append("\\u")
              .append(LOWER_HEX[c >> 12 & 0xF])
              .append(LOWER_HEX[c >> 8 & 0xF])
              .append(LOWER_HEX[c >> 4 & 0xF])
              .append(LOWER_HEX[c & 0xF]);
      }
      plain = i + 1;
    }
    b.append(s, plain, n);
    b.append('"');
  }

  /** Appends {@code v} as self-describing JSON in its envelope, on one line without spaces. */
  static void appendEnvelope(StringBuilder b, Value v) {
    b.append("{\"_haus\":1,\"_value\":");
    appendSelfDescribing(b, v);
    b.append('}');
  }

  /** Appends the self-describing form of {@code v} (§16.2), without the envelope. */
  static void appendSelfDescribing(StringBuilder b, Value v) {
    switch (v.kind()) {
      case STRING:
        appendString(b, ((Value.Text) v).value());
        break;
      case NUMBER:
        b.append("{\"_num\":\"").append(((Value.Number) v).literal()).append("\"}");
        break;
      case BYTES:
        b.append("{\"_bytes\":\"");
        WriteCheck.appendHex(b, ((Value.Bytes) v).unsafeBytes());
        b.append("\"}");
        break;
      case ARRAY:
        appendItems(b, ((Value.Array) v).unsafeItems());
        break;
      case RECORD:
        Value.Record r = (Value.Record) v;
        b.append("{\"_rec\":{");
        for (int i = 0; i < r.size(); i++) {
          if (i > 0) {
            b.append(',');
          }
          appendString(b, r.keyAt(i));
          b.append(':');
          appendSelfDescribing(b, r.valueAt(i));
        }
        b.append("}}");
        break;
      case VARIANT:
        Value.Variant variant = (Value.Variant) v;
        b.append("{\"_tag\":");
        appendString(b, variant.tag());
        if (variant.size() > 0) {
          b.append(",\"_args\":");
          appendItems(b, variant.unsafeArgs());
        }
        b.append('}');
        break;
    }
  }

  private static void appendItems(StringBuilder b, Value[] items) {
    b.append('[');
    for (int i = 0; i < items.length; i++) {
      if (i > 0) {
        b.append(',');
      }
      appendSelfDescribing(b, items[i]);
    }
    b.append(']');
  }
}
