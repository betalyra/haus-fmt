package org.hausfmt;

import java.util.ArrayList;
import java.util.List;

/**
 * A strict reader of JSON (RFC 8259) restricted to I-JSON (RFC 7493), which keeps numbers exact
 * (spec §16). It reads JSON into the haus value the import gives (§16.1): objects are records,
 * arrays arrays, strings strings, numbers numbers with their literal normalized, {@code true},
 * {@code false} and {@code null} the tags {@code True}, {@code False} and {@code None}. Since JSON
 * has no other tags, self-describing JSON is read from that value without losing anything.
 */
final class JsonReader {
  /** What a JSON text is read for: it sets the nesting limit and which checks happen while reading. */
  enum Mode {
    /** The import (§16.1): nesting up to d, and the string limits checked on every string and member name. */
    IMPORT,
    /** Self-describing JSON (§16.2): nesting up to 4·d + 2 (the envelope), raw DEL, C1 and bidi controls rejected. */
    SELF_DESCRIBING
  }

  private final byte[] s;
  private final int end;
  private int pos;
  private final Limits lim;
  private final Mode mode;
  private final int maxDepth;
  private int depth;

  private JsonReader(Source src, Limits lim, Mode mode) {
    this.s = src.bytes;
    this.pos = src.from;
    this.end = src.to;
    this.lim = lim;
    this.mode = mode;
    // A form can take four JSON levels for one haus level (Tag { … } is {"_tag": …, "_args":
    // [{"_rec": {…}}]}), and the envelope one more (spec §16, "Limits").
    this.maxDepth = mode == Mode.IMPORT ? lim.maxDepth() : 4 * lim.maxDepth() + 2;
  }

  /**
   * Reads one JSON text. A leading byte order mark is skipped if {@code skipBom}.
   *
   * @throws HausException for text that isn't I-JSON or exceeds the limits, with its position
   */
  static Value read(Source src, Limits lim, Mode mode, boolean skipBom) {
    try {
      src.checkUtf8();
      JsonReader r = new JsonReader(src, lim, mode);
      if (skipBom && Scan.isBom(r.s, r.pos, r.end)) {
        r.pos += Scan.BOM_BYTES.length;
      }
      r.ws();
      Value v = r.value();
      r.ws();
      if (r.pos < r.end) {
        throw r.syntax("the end of the JSON text", "unexpected text after the JSON value");
      }
      return v;
    } catch (SyntaxError e) {
      throw src.error(e);
    }
  }

  /** Text that isn't JSON: {@code expected} should be here. */
  private SyntaxError syntax(String expected, String reason) {
    String found = Scan.describeChar(s, pos, end);
    return new SyntaxError(pos, ErrorCode.JSON_SYNTAX, reason + ", found " + found, expected, found);
  }

  private void ws() {
    while (pos < end && (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n' || s[pos] == '\r')) {
      pos++;
    }
  }

  private Value value() {
    if (pos >= end) {
      throw syntax("a JSON value", "unexpected end of the JSON text, expected a value");
    }
    int c = s[pos];
    if (c == '{') {
      return object();
    }
    if (c == '[') {
      return array();
    }
    if (c == '"') {
      return new Value.Text(string(ErrorCode.STRING_TOO_LONG));
    }
    if (c == '-' || Scan.isDigit(c)) {
      return number();
    }
    if (Scan.startsWith(s, pos, end, "true")) {
      pos += 4;
      return Value.Variant.TRUE;
    }
    if (Scan.startsWith(s, pos, end, "false")) {
      pos += 5;
      return Value.Variant.FALSE;
    }
    if (Scan.startsWith(s, pos, end, "null")) {
      pos += 4;
      return Value.Variant.NONE;
    }
    throw syntax("a JSON value", "expected a JSON value");
  }

  /** Starts an object or array at {@code pos}. */
  private void enter() {
    if (depth >= maxDepth) {
      throw new SyntaxError(pos, ErrorCode.NESTING_TOO_DEEP, "JSON nesting deeper than " + maxDepth + " levels");
    }
    depth++;
    pos++;
    ws();
  }

  private Value object() {
    enter();
    List<String> keys = new ArrayList<>();
    List<Value> values = new ArrayList<>();
    Keys index = null;
    if (pos < end && s[pos] == '}') {
      pos++;
      depth--;
      return new Value.Record(new String[0], new Value[0], null);
    }
    while (true) {
      if (pos >= end || s[pos] != '"') {
        throw syntax("a member name", "expected a member name (a string)");
      }
      int at = pos;
      String key = string(ErrorCode.KEY_TOO_LONG);
      if (index == null && keys.size() + 1 >= Keys.FEW) {
        index = new Keys(Keys.FEW);
        for (int i = 0; i < keys.size(); i++) {
          index.add(keys.get(i), i);
        }
      }
      if (index != null ? !index.add(key, keys.size()) : keys.contains(key)) {
        throw new SyntaxError(at, ErrorCode.DUPLICATE_KEY, "duplicate member name " + Quoting.forMessage(key));
      }
      ws();
      if (pos >= end || s[pos] != ':') {
        throw syntax("':'", "expected ':' after the member name");
      }
      pos++;
      ws();
      keys.add(key);
      values.add(value());
      ws();
      if (pos < end && s[pos] == ',') {
        pos++;
        ws();
        continue;
      }
      if (pos < end && s[pos] == '}') {
        pos++;
        depth--;
        return new Value.Record(keys.toArray(new String[0]), values.toArray(new Value[0]), index);
      }
      throw syntax("',' or '}'", "expected ',' or '}'");
    }
  }

  private Value array() {
    enter();
    List<Value> items = new ArrayList<>();
    if (pos < end && s[pos] == ']') {
      pos++;
      depth--;
      return new Value.Array(new Value[0]);
    }
    while (true) {
      items.add(value());
      ws();
      if (pos < end && s[pos] == ',') {
        pos++;
        ws();
        continue;
      }
      if (pos < end && s[pos] == ']') {
        pos++;
        depth--;
        return new Value.Array(items.toArray(new Value[0]));
      }
      throw syntax("',' or ']'", "expected ',' or ']'");
    }
  }

  /** Reads a JSON number token and normalizes it (spec §2), within the number limits (§16, "Limits"). */
  private Value number() {
    int start = pos;
    if (s[pos] == '-') {
      pos++;
    }
    if (pos < end && s[pos] == '0') {
      pos++;
    } else if (!digits()) {
      throw syntax("a digit", "invalid number");
    }
    if (pos < end && s[pos] == '.') {
      pos++;
      if (!digits()) {
        throw syntax("a digit", "invalid number: expected a digit after '.'");
      }
    }
    if (pos < end && (s[pos] == 'e' || s[pos] == 'E')) {
      pos++;
      if (pos < end && (s[pos] == '+' || s[pos] == '-')) {
        pos++;
      }
      if (!digits()) {
        throw syntax("a digit", "invalid number: expected a digit in the exponent");
      }
    }
    return new Value.Number(Numbers.scan(s, start, pos, lim).literal());
  }

  private boolean digits() {
    int from = pos;
    while (pos < end && Scan.isDigit(s[pos])) {
      pos++;
    }
    return pos > from;
  }

  /**
   * Reads a string token at {@code pos} (a quote). Its length is checked only by the import: the
   * other forms count the haus value (§16, "Limits"), and a JSON string can be a member name of the
   * form, a number or bytes.
   */
  private String string(ErrorCode tooLong) {
    int start = pos;
    boolean strict = mode == Mode.SELF_DESCRIBING;
    StringBuilder b = null;
    int plain = start + 1;
    int i = plain;
    while (true) {
      if (i >= end) {
        throw new SyntaxError(start, ErrorCode.UNTERMINATED_STRING, "unterminated string");
      }
      int c = s[i] & 0xFF;
      if (c == '"') {
        break;
      }
      if (c == '\\') {
        if (b == null) {
          b = new StringBuilder();
        }
        b.append(Scan.utf8(s, plain, i));
        i = escape(b, i);
        plain = i;
        continue;
      }
      if (c < 0x20) {
        throw new SyntaxError(i, ErrorCode.CONTROL_CHARACTER,
            String.format("raw control character U+%04X in a string (write it as an escape)", c));
      }
      if (strict && c >= Scan.DEL) {
        ErrorCode code = Scan.rawCharCode(s, i, end);
        if (code != null) {
          String what = code == ErrorCode.BIDI_CONTROL ? "bidirectional control" : "control character";
          throw new SyntaxError(i, code,
              String.format("raw %s U+%04X in a string (write it as an escape)", what, Scan.codePointAt(s, i)));
        }
      }
      i++;
    }
    String out = b == null ? Scan.utf8(s, plain, i) : b.append(Scan.utf8(s, plain, i)).toString();
    pos = i + 1;
    if (mode == Mode.IMPORT
        && out.length() > lim.maxStringLength()
        && out.codePointCount(0, out.length()) > lim.maxStringLength()) {
      String what = tooLong == ErrorCode.KEY_TOO_LONG ? "member name" : "string";
      throw new SyntaxError(start, tooLong, "a " + what + " longer than the limit of " + lim.maxStringLength() + " characters");
    }
    return out;
  }

  /** Reads the escape at {@code s[i]} (a backslash), appends what it stands for, and returns the offset after it. */
  private int escape(StringBuilder b, int i) {
    if (i + 1 >= end) {
      throw new SyntaxError(i, ErrorCode.INVALID_ESCAPE, "invalid escape at the end of the text");
    }
    switch (s[i + 1]) {
      case '"':
        b.append('"');
        return i + 2;
      case '\\':
        b.append('\\');
        return i + 2;
      case '/':
        b.append('/');
        return i + 2;
      case 'b':
        b.append('\b');
        return i + 2;
      case 'f':
        b.append('\f');
        return i + 2;
      case 'n':
        b.append('\n');
        return i + 2;
      case 'r':
        b.append('\r');
        return i + 2;
      case 't':
        b.append('\t');
        return i + 2;
      case 'u':
        break;
      default:
        throw new SyntaxError(i, ErrorCode.INVALID_ESCAPE, "invalid escape \\" + Scan.describeChar(s, i + 1, end));
    }
    int unit = hex4(i + 2);
    if (unit < 0) {
      throw new SyntaxError(i + 2, ErrorCode.INVALID_UNICODE_ESCAPE, "expected four hex digits after \\u");
    }
    if (Character.isLowSurrogate((char) unit)) {
      throw unpaired(i);
    }
    if (!Character.isHighSurrogate((char) unit)) {
      b.append((char) unit);
      return i + 6;
    }
    int low = -1;
    if (Scan.startsWith(s, i + 6, end, "\\u")) {
      // A \\u after a high surrogate is an escape like any other: four hex digits first.
      low = hex4(i + 8);
      if (low < 0) {
        throw new SyntaxError(i + 8, ErrorCode.INVALID_UNICODE_ESCAPE, "expected four hex digits after \\u");
      }
    }
    if (low < 0 || !Character.isLowSurrogate((char) low)) {
      throw unpaired(i);
    }
    b.append((char) unit).append((char) low);
    return i + 12;
  }

  private SyntaxError unpaired(int at) {
    return new SyntaxError(at, ErrorCode.UNPAIRED_SURROGATE, "an unpaired surrogate in a \\u escape");
  }

  /** The four hex digits at {@code s[i]} as a number, or −1. */
  private int hex4(int i) {
    if (i + 4 > end) {
      return -1;
    }
    int u = 0;
    for (int k = i; k < i + 4; k++) {
      if (!Scan.isHexDigit(s[k])) {
        return -1;
      }
      u = u << 4 | Scan.hexValue(s[k]);
    }
    return u;
  }
}
