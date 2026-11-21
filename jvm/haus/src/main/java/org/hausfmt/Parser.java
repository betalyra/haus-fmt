package org.hausfmt;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.hausfmt.Syntax.Form;
import org.hausfmt.Syntax.Gap;
import org.hausfmt.Syntax.Item;
import org.hausfmt.Syntax.Node;

/**
 * A recursive-descent parser over one complete text (spec §1–§8, grammar.ebnf). It reads UTF-8
 * bytes by index; the text is checked to be valid UTF-8 first, so multi-byte characters only need
 * a look where they could be a control or bidi character. Errors are thrown as {@link SyntaxError}
 * at their byte offset.
 *
 * <p>For the formatter it also builds the syntax tree, with comments and spellings ({@code keep});
 * its gaps are null otherwise, and nothing of the tree is built.
 */
final class Parser {
  private final byte[] s;
  private final int end;
  private int pos;
  private final Limits lim;
  private final boolean keep;
  /**
   * The text starts the file: a byte order mark at its start is skipped, and {@code #haus} after
   * it is a version directive. A stream reader's later values don't start the file.
   */
  private final boolean fileStart;

  private int depth;
  /** The syntax tree of the file, when the parser keeps it. */
  private Syntax.File file;

  // Scratch stacks, the innermost container's entries last: the fields of the records and the
  // items of the arrays and payloads being read. A container's entries are copied out at its
  // closer, into arrays of their exact length. Entries above the top aren't cleared: the parser
  // lives for one text.
  private String[] keyStack = new String[16];
  private Value[] fieldStack = new Value[16];
  private int fieldTop;
  private Value[] itemStack = new Value[16];
  private int itemTop;
  /** Decoded string bytes, when a string has escapes. */
  private byte[] buffer = new byte[64];
  /** The depth ({@link Value#depth}) of the value read last. */
  private int height;
  /** The integers 0 to 99, shared: values never change. */
  private static final Value.Number[] SMALL_INTEGERS = new Value.Number[100];

  static {
    for (int i = 0; i < SMALL_INTEGERS.length; i++) {
      SMALL_INTEGERS[i] = new Value.Number(Integer.toString(i));
    }
  }

  /** The arguments of a tag without payload, shared: an empty array never changes. */
  private static final Value[] NO_ARGS = new Value[0];

  Parser(Source src, Limits lim, boolean keep, boolean fileStart) {
    this.s = src.bytes;
    this.pos = src.from;
    this.end = src.to;
    this.lim = lim;
    this.keep = keep;
    this.fileStart = fileStart;
  }

  /** The syntax tree of the file read, when the parser keeps it. */
  Syntax.File syntax() {
    return file;
  }

  // ── Errors ──

  private SyntaxError fail(int at, ErrorCode code, String reason) {
    return new SyntaxError(at, code, reason);
  }

  /** An error with what was expected and what was found at {@code at}. */
  private SyntaxError failFound(int at, ErrorCode code, String expected) {
    String found = Scan.describeChar(s, at, end);
    return new SyntaxError(at, code, "expected " + expected + ", found " + found, expected, found);
  }

  private SyntaxError rawCharError(int at, ErrorCode code, String where) {
    switch (code) {
      case LONE_CARRIAGE_RETURN:
        return fail(at, code, "a carriage return not followed by a line feed");
      case BIDI_CONTROL:
        return fail(at, code, "a raw bidirectional control character, " + Scan.describeChar(s, at, end) + ", " + where);
      default:
        return fail(at, code, "a raw control character, " + Scan.describeChar(s, at, end) + ", " + where);
    }
  }

  private SyntaxError expectedValue(int at) {
    return failFound(at, ErrorCode.EXPECTED_VALUE, "a value");
  }

  private SyntaxError unclosed(int open, char closer) {
    return new SyntaxError(
        open,
        ErrorCode.UNCLOSED_BRACKET,
        "'" + (char) s[open] + "' is never closed: the input ends before its '" + closer + "'",
        "'" + closer + "'",
        "end of input");
  }

  /**
   * What stands at {@code pos} after a value, where a comma or the closer (0 at the top level)
   * must be. {@code open} is the opening bracket.
   */
  private SyntaxError afterValue(Value v, int open, char closer) {
    if (pos >= end) {
      return unclosed(open, closer);
    }
    String expected = closer == 0 ? "','" : "',' or '" + closer + "'";
    char c = (char) s[pos];
    if (c == '}' || c == ']' || c == ')') {
      return closer == 0
          ? fail(pos, ErrorCode.UNEXPECTED_CLOSER, "a closing '" + c + "' without an opening bracket")
          : fail(pos, ErrorCode.UNEXPECTED_CLOSER, "expected '" + closer + "', found '" + c + "'");
    }
    if ((c == '(' || c == '{') && v instanceof Value.Variant && ((Value.Variant) v).size() == 0) {
      return new SyntaxError(
          pos,
          ErrorCode.PAYLOAD_NEWLINE,
          "the payload of " + ((Value.Variant) v).tag() + " must start on its line: expected " + expected + ", found '" + c + "'",
          expected,
          "'" + c + "'");
    }
    return failFound(pos, ErrorCode.MISSING_COMMA, expected);
  }

  // ── The file ──

  /**
   * Reads the whole text: a sequence of top-level values (spec §6).
   *
   * <p>Invalid UTF-8 anywhere in the text is the error, whatever else is wrong with it (spec §4).
   * The text is checked as a whole only once something is wrong: bytes beyond ASCII can only stand
   * in strings and comments, which are checked as they are read, and anywhere else they are an
   * error, so text read without an error is valid UTF-8.
   */
  List<Value> file() {
    int from = pos;
    try {
      return values();
    } catch (RuntimeException e) { // a SyntaxError, or anything else invalid UTF-8 led to
      new Source(s, from, end, 1, 1).checkUtf8();
      throw e;
    }
  }

  /** An error at invalid UTF-8 found in a string or comment ({@link #file} reports the first). */
  private SyntaxError invalidUtf8(int at) {
    return fail(at, ErrorCode.INVALID_UTF8, "invalid UTF-8");
  }

  /** Checks that {@code s[from..to)}, a comment or the content of a block string, is valid UTF-8. */
  private void checkUtf8(int from, int to) {
    int bad = Scan.invalidUtf8(s, from, to);
    if (bad < to) {
      throw invalidUtf8(bad);
    }
  }

  private List<Value> values() {
    if (fileStart && Scan.isBom(s, pos, end)) {
      pos += Scan.BOM_BYTES.length;
    }
    if (fileStart && Scan.startsWith(s, pos, end, "#haus")) {
      throw fail(pos, ErrorCode.VERSION_DIRECTIVE, "the file starts with a version directive: it needs a newer version of haus");
    }
    List<Value> values = new ArrayList<>();
    Gap g = keep ? new Gap() : null;
    if (keep) {
      file = new Syntax.File();
    }
    ws(g);
    Item previous = null;
    while (pos < end) {
      if (s[pos] == ',') {
        throw expectedValue(pos);
      }
      Item it = keep ? Syntax.newItem(previous, g) : null;
      Value v = value(it);
      values.add(v);
      if (keep) {
        file.items.add(it);
        previous = it;
      }
      ws(g);
      if (pos >= end) {
        break;
      }
      if (s[pos] != ',') {
        throw afterValue(v, 0, (char) 0);
      }
      pos++;
      endRun(g);
      ws(g);
    }
    if (keep) {
      Node rest = new Node(null, null);
      Syntax.close(rest, previous, g);
      file.dangling = rest.dangling;
    }
    return values;
  }

  /** A comma ends a run of line breaks. */
  private static void endRun(Gap g) {
    if (g != null) {
      g.run = 0;
    }
  }

  // ── Whitespace and comments ──

  /** Skips whitespace and comments; records the comments and line breaks in g, if not null. */
  private void ws(Gap g) {
    int i = pos;
    while (i < end) {
      switch (s[i]) {
        case ' ':
        case '\t':
          i++;
          break;
        case '\n':
          i++;
          if (g != null) {
            g.lineBreak();
          }
          break;
        case '\r':
          if (i + 1 < end && s[i + 1] == '\n') {
            i += 2;
            if (g != null) {
              g.lineBreak();
            }
            break;
          }
          throw rawCharError(i, ErrorCode.LONE_CARRIAGE_RETURN, "");
        case '/':
          int start = i;
          if (i + 1 < end && s[i + 1] == '/') {
            i = lineComment(i);
          } else if (i + 1 < end && s[i + 1] == '*') {
            i = blockComment(i);
          } else {
            throw fail(i, ErrorCode.STRAY_SLASH, "a '/' that doesn't start a comment");
          }
          checkUtf8(start, i);
          if (g != null) {
            g.comment(Scan.utf8(s, start, i).replace("\r\n", "\n"));
          }
          break;
        default:
          pos = i;
          return;
      }
    }
    pos = i;
  }

  /** Reads a {@code //} comment from {@code s[i]} and returns its end: the line break or the end of input. */
  private int lineComment(int i) {
    for (i += 2; i < end; i++) {
      int c = s[i] & 0xFF;
      if (c == '\n') {
        return i;
      }
      if (!Scan.RAW_CHECK[c]) {
        continue;
      }
      if (c == '\r' && i + 1 < end && s[i + 1] == '\n') {
        return i;
      }
      ErrorCode code = Scan.rawCharCode(s, i, end);
      if (code != null) {
        throw rawCharError(i, code, "in a comment");
      }
    }
    return i;
  }

  /** Reads a nested {@code /* *}{@code /} comment from {@code s[i]} and returns its end. */
  private int blockComment(int i) {
    int start = i;
    int nesting = 0;
    while (i < end) {
      int c = s[i] & 0xFF;
      if (!Scan.COMMENT_STOP[c]) {
        i++;
      } else if (c == '/' && i + 1 < end && s[i + 1] == '*') {
        nesting++;
        i += 2;
      } else if (c == '*' && i + 1 < end && s[i + 1] == '/') {
        nesting--;
        i += 2;
        if (nesting == 0) {
          return i;
        }
      } else if (c != '*' && c != '/') {
        ErrorCode code = Scan.rawCharCode(s, i, end);
        if (code != null) {
          throw rawCharError(i, code, "in a comment");
        }
        i++;
      } else {
        i++;
      }
    }
    throw fail(start, ErrorCode.UNTERMINATED_COMMENT, "a /* comment that is never closed");
  }

  // ── Values ──

  /** Starts a record, array or payload at {@code at}, one level deeper. */
  private void enter(int at) {
    depth++;
    if (depth > lim.maxDepth()) {
      throw fail(at, ErrorCode.NESTING_TOO_DEEP, "nesting deeper than the limit of " + lim.maxDepth());
    }
  }

  /** Reads the value at {@code pos}; its syntax node goes to {@code it} when the parser keeps the tree. */
  private Value value(Item it) {
    if (pos >= end) {
      throw expectedValue(pos);
    }
    int c = s[pos];
    int start = pos;
    if (c == '{') {
      return record(it, null);
    }
    if (c == '[') {
      return array(it);
    }
    height = 0; // a scalar, or a tag (which sets its own)
    if (c == '"') {
      if (pos + 2 < end && s[pos + 1] == '"' && s[pos + 2] == '"') {
        Value v = blockString();
        node(it, v, null);
        return v;
      }
      Value v = new Value.Text(basicString(ErrorCode.STRING_TOO_LONG));
      node(it, v, keep ? Scan.utf8(s, start, pos) : null);
      return v;
    }
    if (Scan.isDigit(c)) {
      // One or two digits, not followed by more of a number: one of the shared small integers.
      int j = pos + 1;
      int small = c - '0';
      if (c != '0' && j < end && Scan.isDigit(s[j])) {
        small = 10 * small + s[j++] - '0';
      }
      if ((j >= end || !Scan.isWordByte(s[j])) && j - pos <= lim.maxNumberLength()) {
        pos = j;
        Value v = SMALL_INTEGERS[small];
        node(it, v, keep ? Scan.ascii(s, start, pos) : null);
        return v;
      }
    }
    if (c == '-' || c == '+' || c == '.' || Scan.isDigit(c)) {
      Numbers.Scanned n = Numbers.scan(s, pos, end, lim);
      pos = n.end();
      Value v = new Value.Number(n.literal());
      node(it, v, keep ? Scan.ascii(s, start, pos) : null);
      return v;
    }
    if (Scan.isUpper(c)) {
      return variant(it);
    }
    if (c == 'x' && pos + 1 < end && s[pos + 1] == '"') {
      Value v = bytes();
      node(it, v, keep ? Scan.utf8(s, start, pos) : null);
      return v;
    }
    if (Scan.isLower(c) || c == '_') {
      String word = Scan.ascii(s, start, Scan.wordEnd(s, start, end));
      switch (word) {
        case "null":
          throw fail(start, ErrorCode.NULL_LITERAL, "null is not a value: haus has no null");
        case "true":
        case "false":
          throw fail(start, ErrorCode.BOOLEAN_LITERAL, word + " is not a value: booleans are the tags True and False");
        default:
          throw fail(start, ErrorCode.BARE_IDENTIFIER, "a lowercase word, " + Quoting.forMessage(word) + ", where a value must be");
      }
    }
    throw expectedValue(pos);
  }

  /** Gives {@code it} the node of a scalar, when the parser keeps the tree. */
  private void node(Item it, Value v, String text) {
    if (it != null) {
      it.node = new Node(v, text);
    }
  }

  /**
   * Reads {@code { … }} at {@code pos}: a record, or the record payload of {@code tag} if it isn't
   * null.
   */
  private Value record(Item it, String tag) {
    int open = pos;
    enter(open);
    pos++;
    int base = fieldTop; // this record's fields are the stacks' entries from base
    Keys index = null;
    boolean bare = true; // every key so far an identifier
    int deepest = 0; // the depth of the deepest value so far
    Node syn = it != null ? new Node(null, null) : null;
    Gap g = keep ? new Gap() : null;
    ws(g);
    Item previous = null;
    while (true) {
      if (pos >= end) {
        throw unclosed(open, '}');
      }
      if (s[pos] == '}') {
        pos++;
        depth--;
        height = deepest + 1;
        Value v = popRecord(base, index, tag, bare, height);
        if (syn != null) {
          syn.value = v;
          syn.form = tag != null ? Form.BRACES : Form.BARE;
          Syntax.close(syn, previous, g);
          it.node = syn;
        }
        return v;
      }
      int keyAt = pos;
      bare &= s[keyAt] != '"';
      String key = key();
      int count = fieldTop - base;
      if (index == null && count + 1 >= Keys.FEW) {
        index = new Keys(Keys.FEW);
        for (int i = base; i < fieldTop; i++) {
          index.add(keyStack[i], i - base);
        }
      }
      if (index != null ? !index.add(key, count) : Keys.find(keyStack, base, fieldTop, key) >= 0) {
        throw fail(keyAt, ErrorCode.DUPLICATE_KEY, "the key " + Quoting.forMessage(key) + " is already in this record");
      }
      Item field = keep ? Syntax.newItem(previous, g) : null;
      if (field != null) {
        field.key = key;
      }
      ws(g);
      if (pos >= end || s[pos] != ':') {
        String found = Scan.describeChar(s, pos, end);
        throw new SyntaxError(pos, ErrorCode.MISSING_COLON,
            "expected ':' after the key " + Quoting.forMessage(key) + ", found " + found, "':'", found);
      }
      pos++;
      endRun(g);
      ws(g);
      Value v = value(field);
      deepest = Math.max(deepest, height);
      pushField(key, v);
      if (field != null) {
        // Comments between the key and the value move above the entry, after its blank line.
        if (!g.comments.isEmpty()) {
          g.comments.get(0).nl = Math.max(g.comments.get(0).nl, Syntax.blankNl(field.blank));
          field.blank = false;
        }
        field.leading.addAll(g.comments);
        g.clear();
        syn.items.add(field);
        previous = field;
      }
      if (!separator(g, '}')) {
        throw afterValue(v, open, '}');
      }
    }
  }

  /**
   * After a value in a container: skips the comma and what follows it, or stops before the
   * closer. False if neither is there.
   */
  private boolean separator(Gap g, char closer) {
    ws(g);
    if (pos < end && s[pos] == ',') {
      pos++;
      endRun(g);
      ws(g);
      return true;
    }
    return pos < end && s[pos] == closer;
  }

  private void pushField(String key, Value v) {
    if (fieldTop == keyStack.length) {
      keyStack = Arrays.copyOf(keyStack, 2 * fieldTop);
      fieldStack = Arrays.copyOf(fieldStack, 2 * fieldTop);
    }
    keyStack[fieldTop] = key;
    fieldStack[fieldTop++] = v;
  }

  /** Takes a record's fields, from base, off the stacks. */
  private Value popRecord(int base, Keys index, String tag, boolean bare, int depth) {
    String[] keys = Arrays.copyOfRange(keyStack, base, fieldTop);
    Value[] values = Arrays.copyOfRange(fieldStack, base, fieldTop);
    fieldTop = base;
    Value.Record r = new Value.Record(keys, values, index, bare, depth);
    // Tag { … }: the record is the payload's one level.
    return tag == null ? r : new Value.Variant(tag, new Value[] {r}, depth);
  }

  /** Reads a record key at {@code pos}: an identifier or a {@code "…"} string. */
  private String key() {
    int i = pos;
    int c = s[i];
    if (Scan.isLower(c) || c == '_') {
      pos = Scan.wordEnd(s, i, end);
      if (pos - i > lim.maxStringLength()) {
        throw fail(i, ErrorCode.KEY_TOO_LONG, "a key longer than the limit of " + lim.maxStringLength() + " characters");
      }
      return Scan.ascii(s, i, pos);
    }
    if (c == '"') {
      if (Scan.startsWith(s, i, end, "\"\"\"")) {
        throw fail(i, ErrorCode.BLOCK_STRING_KEY, "a block string (\"\"\") can't be a key");
      }
      return basicString(ErrorCode.KEY_TOO_LONG);
    }
    if (Scan.isUpper(c)) {
      String word = Scan.ascii(s, i, Scan.wordEnd(s, i, end));
      throw fail(i, ErrorCode.UPPERCASE_KEY,
          "the key " + Quoting.forMessage(word) + " starts with a capital letter: quote it, or start it with a lowercase letter");
    }
    throw failFound(i, ErrorCode.EXPECTED_KEY, "a key");
  }

  /** Reads {@code [ … ]} at {@code pos}. */
  private Value array(Item it) {
    Node syn = it != null ? new Node(null, null) : null;
    Value[] items = sequence(']', syn);
    Value v = new Value.Array(items, height);
    if (syn != null) {
      syn.value = v;
      it.node = syn;
    }
    return v;
  }

  /**
   * Reads the values of an array, or the arguments of a payload, from the opening bracket at
   * {@code pos} to the closer; their syntax goes to {@code syn} if it isn't null.
   */
  private Value[] sequence(char closer, Node syn) {
    int open = pos;
    enter(open);
    pos++;
    int base = itemTop;
    int deepest = 0; // the depth of the deepest value so far
    Gap g = keep ? new Gap() : null;
    ws(g);
    Item previous = null;
    while (true) {
      if (pos >= end) {
        throw unclosed(open, closer);
      }
      if (s[pos] == closer) {
        if (closer == ')' && itemTop == base) {
          throw fail(open, ErrorCode.EMPTY_PAYLOAD, "empty parentheses after a tag: write the tag alone");
        }
        pos++;
        depth--;
        height = deepest + 1;
        Value[] items = Arrays.copyOfRange(itemStack, base, itemTop);
        itemTop = base;
        if (syn != null) {
          Syntax.close(syn, previous, g);
        }
        return items;
      }
      Item it = keep ? Syntax.newItem(previous, g) : null;
      Value v = value(it);
      deepest = Math.max(deepest, height);
      if (itemTop == itemStack.length) {
        itemStack = Arrays.copyOf(itemStack, 2 * itemTop);
      }
      itemStack[itemTop++] = v;
      if (it != null) {
        syn.items.add(it);
        previous = it;
      }
      if (!separator(g, closer)) {
        throw afterValue(v, open, closer);
      }
    }
  }

  /** Reads a tag at {@code pos} and its payload, if one follows on the same line (spec §5). */
  private Value variant(Item it) {
    int start = pos;
    int tagEnd = Scan.wordEnd(s, start, end);
    if (tagEnd - start > lim.maxStringLength()) {
      throw fail(start, ErrorCode.TAG_TOO_LONG, "a tag longer than the limit of " + lim.maxStringLength() + " characters");
    }
    String tag = Scan.ascii(s, start, tagEnd);
    int j = tagEnd;
    while (j < end && (s[j] == ' ' || s[j] == '\t')) {
      j++;
    }
    if (j >= end || s[j] != '(' && s[j] != '{') {
      pos = tagEnd;
      height = 0;
      Value v = new Value.Variant(tag, NO_ARGS, 0);
      node(it, v, null);
      return v;
    }
    pos = j;
    if (s[j] == '{') {
      return record(it, tag);
    }
    Node syn = it != null ? new Node(null, null) : null;
    Value[] args = sequence(')', syn);
    if (args.length == 1 && args[0] instanceof Value.Record) {
      height--; // Tag({ … }) is Tag { … }: the record is the payload's one level
    }
    Value v = new Value.Variant(tag, args, height);
    if (syn != null) {
      syn.value = v;
      syn.form = Form.PARENS;
      it.node = args.length == 1 && args[0] instanceof Value.Record ? Syntax.mergeRecordArg(syn) : syn;
    }
    return v;
  }

  // ── Strings ──

  /** Reads a {@code "…"} string at {@code pos}. {@code tooLong} is the error for one over the length limit. */
  private String basicString(ErrorCode tooLong) {
    int start = pos;
    int i = start + 1;
    int length = 0; // of the decoded bytes in buffer, once an escape needs decoding
    boolean escaped = false;
    boolean ascii = true; // no byte beyond ASCII so far
    int plain = i; // start of the current run of plain characters
    while (true) {
      i = Scan.plainRun(s, i, end, Scan.STRING_STOP);
      if (i >= end) {
        throw fail(start, ErrorCode.UNTERMINATED_STRING, "a string without its closing '\"'");
      }
      int c = s[i];
      if (c == '"') {
        pos = i + 1;
        if (!escaped) {
          checkLength(s, plain, i, start, tooLong);
          return ascii ? Scan.ascii(s, plain, i) : Scan.utf8(s, plain, i);
        }
        length = append(length, plain, i);
        checkLength(buffer, 0, length, start, tooLong);
        return Scan.utf8(buffer, 0, length);
      }
      if (c == '\\') {
        length = append(escaped ? length : 0, plain, i);
        escaped = true;
        i = escape(i);
        length = appendEscaped(length);
        plain = i;
      } else if (c == '\n') {
        throw fail(i, ErrorCode.STRING_LINE_BREAK, "a line break in a \"…\" string: write \\n, or use a \"\"\" block string");
      } else if (c == '\r') {
        // A carriage return in a "…" string is a control character, also directly before a line
        // feed (spec §4, "Which error").
        throw rawCharError(i, ErrorCode.CONTROL_CHARACTER, "in a string: write it as an escape");
      } else {
        ErrorCode code = Scan.rawCharCode(s, i, end);
        if (code != null || c == '\t') {
          throw rawCharError(i, code != null ? code : ErrorCode.CONTROL_CHARACTER, "in a string: write it as an escape");
        }
        if (c >= 0) {
          i++;
        } else {
          int n = Scan.validSequence(s, i, end);
          if (n == 0) {
            throw invalidUtf8(i);
          }
          i += n;
          ascii = false;
        }
      }
    }
  }

  /** A string's characters against the length limit; its bytes are an upper bound. */
  private void checkLength(byte[] b, int from, int to, int start, ErrorCode tooLong) {
    if (to - from > lim.maxStringLength()) {
      int n = Scan.countChars(b, from, to);
      if (n > lim.maxStringLength()) {
        throw fail(start, tooLong, "a string of " + n + " characters, more than the limit of " + lim.maxStringLength());
      }
    }
  }

  /** Appends {@code s[from..to)} to the buffer, which holds {@code length} bytes; returns the new length. */
  private int append(int length, int from, int to) {
    int n = to - from;
    ensure(length + n);
    System.arraycopy(s, from, buffer, length, n);
    return length + n;
  }

  private void ensure(int capacity) {
    if (capacity > buffer.length) {
      buffer = Arrays.copyOf(buffer, Math.max(capacity, 2 * buffer.length));
    }
  }

  /** The code point of the last escape read. */
  private int escapedCodePoint;

  /** Appends the UTF-8 bytes of the last escape read; returns the new length. */
  private int appendEscaped(int length) {
    ensure(length + 4);
    int cp = escapedCodePoint;
    if (cp < 0x80) {
      buffer[length++] = (byte) cp;
    } else if (cp < 0x800) {
      buffer[length++] = (byte) (0xC0 | cp >> 6);
      buffer[length++] = (byte) (0x80 | cp & 0x3F);
    } else if (cp < 0x10000) {
      buffer[length++] = (byte) (0xE0 | cp >> 12);
      buffer[length++] = (byte) (0x80 | cp >> 6 & 0x3F);
      buffer[length++] = (byte) (0x80 | cp & 0x3F);
    } else {
      buffer[length++] = (byte) (0xF0 | cp >> 18);
      buffer[length++] = (byte) (0x80 | cp >> 12 & 0x3F);
      buffer[length++] = (byte) (0x80 | cp >> 6 & 0x3F);
      buffer[length++] = (byte) (0x80 | cp & 0x3F);
    }
    return length;
  }

  /**
   * Reads the escape whose backslash is at {@code s[i]} into {@link #escapedCodePoint}, and returns the
   * offset after it.
   */
  private int escape(int i) {
    if (i + 1 >= end) {
      throw fail(i, ErrorCode.INVALID_ESCAPE, "a backslash at the end of the input");
    }
    int c = s[i + 1];
    switch (c) {
      case '"':
      case '\\':
        escapedCodePoint = c;
        return i + 2;
      case 'n':
        escapedCodePoint = '\n';
        return i + 2;
      case 'r':
        escapedCodePoint = '\r';
        return i + 2;
      case 't':
        escapedCodePoint = '\t';
        return i + 2;
      case 'u':
        return unicodeEscape(i);
      default:
        int to = i + 1 + Scan.sequenceLength(s[i + 1]);
        throw fail(i, ErrorCode.INVALID_ESCAPE,
            Quoting.forMessage(Scan.utf8(s, i, Math.min(to, end))) + " doesn't start an escape: use \\\", \\\\, \\n, \\r, \\t or \\u{…}");
    }
  }

  /** Reads <code>&#92;u{…}</code> at {@code s[i]}: 1 to 6 hex digits naming a Unicode scalar value. */
  private int unicodeEscape(int i) {
    int j = i + 2;
    if (j >= end || s[j] != '{') {
      throw fail(i, ErrorCode.INVALID_UNICODE_ESCAPE, "a \\u escape is written with braces: \\u{1F600}");
    }
    j++;
    int cp = 0;
    int k = j;
    while (k < end && Scan.isHexDigit(s[k]) && k - j < 7) {
      cp = cp << 4 | Scan.hexValue(s[k]);
      k++;
    }
    if (k == j || k - j > 6 || k >= end || s[k] != '}') {
      throw fail(i, ErrorCode.INVALID_UNICODE_ESCAPE, "a \\u{…} escape needs 1 to 6 hex digits and a closing '}'");
    }
    if (cp > Character.MAX_CODE_POINT || cp >= Character.MIN_SURROGATE && cp <= Character.MAX_SURROGATE) {
      throw fail(i, ErrorCode.INVALID_UNICODE_ESCAPE, "\\u{" + Scan.ascii(s, j, k) + "} is not a Unicode scalar value");
    }
    escapedCodePoint = cp;
    return k + 1;
  }

  /** Reads a {@code """} block string at {@code pos} (spec §4). */
  private Value blockString() {
    int start = pos;
    int i = start + 3;
    while (i < end && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
    if (i >= end) {
      // Nothing after the opening: no line break, at the block string.
      throw fail(start, ErrorCode.BLOCK_STRING_OPENING, "the opening \"\"\" must be followed by a line break");
    } else if (s[i] == '\n') {
      i++;
    } else if (s[i] == '\r' && i + 1 < end && s[i + 1] == '\n') {
      i += 2;
    } else {
      throw fail(i, ErrorCode.BLOCK_STRING_OPENING, "text after the opening \"\"\": the content starts on the next line");
    }
    // The closing """, skipping escaped characters; then the lines before it.
    int close = -1;
    for (int j = i; j < end; j++) {
      if (s[j] == '\\') {
        j++;
      } else if (s[j] == '"' && Scan.startsWith(s, j, end, "\"\"\"")) {
        close = j;
        break;
      }
    }
    if (close < 0) {
      throw fail(start, ErrorCode.UNTERMINATED_BLOCK_STRING, "a block string without its closing \"\"\"");
    }
    checkUtf8(i, close);
    List<int[]> lines = new ArrayList<>(); // {from, to} of each line, without its line break
    for (int at = i; ; ) {
      int nl = at;
      while (nl < close && s[nl] != '\n') {
        nl++;
      }
      if (nl == close) {
        lines.add(new int[] {at, close});
        break;
      }
      int to = nl > at && s[nl - 1] == '\r' ? nl - 1 : nl;
      lines.add(new int[] {at, to});
      at = nl + 1;
    }
    int[] last = lines.remove(lines.size() - 1);
    int indentFrom = last[0];
    int indent = last[1] - last[0];
    if (!blanks(indentFrom, last[1])) {
      throw fail(close, ErrorCode.BLOCK_STRING_CLOSING, "the closing \"\"\" must stand on a line of its own");
    }
    pos = close + 3;
    // Line by line: the indent, then the content in order, raw characters and escapes (spec §4,
    // "Which error": the same order in every binding).
    int length = 0;
    for (int k = 0; k < lines.size(); k++) {
      if (k > 0) {
        ensure(length + 1);
        buffer[length++] = '\n';
      }
      int from = lines.get(k)[0];
      int to = lines.get(k)[1];
      if (startsWithIndent(from, to, indentFrom, indent)) {
        from += indent;
      } else if (blanks(from, to)) {
        continue;
      } else {
        throw fail(from, ErrorCode.BLOCK_STRING_INDENT, "a line of a block string indented less than its closing \"\"\"");
      }
      length = blockLine(from, to, length);
    }
    checkLength(buffer, 0, length, start, ErrorCode.STRING_TOO_LONG);
    return new Value.Text(Scan.utf8(buffer, 0, length));
  }

  /** Appends the content of a block string's line {@code s[from..to)}, after its indent; returns the new length. */
  private int blockLine(int from, int to, int length) {
    int j = from;
    while (j < to) {
      int c = s[j] & 0xFF;
      if (c == '\\') {
        j = escape(j);
        if (j > to) {
          throw fail(j, ErrorCode.INVALID_ESCAPE, "an escape across a line break");
        }
        length = appendEscaped(length);
        continue;
      }
      if (Scan.RAW_CHECK[c]) {
        ErrorCode code = Scan.rawCharCode(s, j, end);
        if (code != null) {
          // A carriage return that isn't part of a line break is a control character here (spec
          // §4, "Which error").
          throw rawCharError(j, code == ErrorCode.LONE_CARRIAGE_RETURN ? ErrorCode.CONTROL_CHARACTER : code,
              "in a block string: write it as an escape");
        }
      }
      int run = j + 1;
      while (run < to && s[run] != '\\' && !Scan.RAW_CHECK[s[run] & 0xFF]) {
        run++;
      }
      length = append(length, j, run);
      j = run;
    }
    return length;
  }

  /** Whether the line {@code s[from..to)} starts with the indent, {@code s[indentFrom..indentFrom + indent)}. */
  private boolean startsWithIndent(int from, int to, int indentFrom, int indent) {
    if (to - from < indent) {
      return false;
    }
    for (int k = 0; k < indent; k++) {
      if (s[from + k] != s[indentFrom + k]) {
        return false;
      }
    }
    return true;
  }

  /** Whether {@code s[from..to)} holds only spaces and tabs. */
  private boolean blanks(int from, int to) {
    for (int i = from; i < to; i++) {
      if (s[i] != ' ' && s[i] != '\t') {
        return false;
      }
    }
    return true;
  }

  // ── Byte strings ──

  /** Reads a byte string {@code x"…"} at {@code pos}. */
  private Value bytes() {
    int start = pos;
    int i = start + 2;
    int length = 0;
    while (true) {
      while (i < end && (s[i] == ' ' || s[i] == '\t')) {
        i++;
      }
      if (i >= end) {
        throw fail(start, ErrorCode.UNTERMINATED_BYTES, "a byte string without its closing '\"'");
      }
      int c = s[i];
      if (c == '"') {
        break;
      }
      if (!Scan.isHexDigit(c)) {
        throw fail(i, ErrorCode.BYTES_NOT_HEX, Scan.describeChar(s, i, end) + " in a byte string: only hex digits, spaces and tabs");
      }
      if (i + 1 >= end) {
        throw fail(start, ErrorCode.UNTERMINATED_BYTES, "a byte string without its closing '\"'");
      }
      if (!Scan.isHexDigit(s[i + 1])) {
        throw fail(i, ErrorCode.BYTES_ODD_DIGITS, "a byte with one hex digit: write two hex digits per byte");
      }
      ensure(length + 1);
      buffer[length++] = (byte) (Scan.hexValue(c) << 4 | Scan.hexValue(s[i + 1]));
      i += 2;
    }
    pos = i + 1;
    int chars = i - start - 2;
    if (chars > lim.maxStringLength()) {
      throw fail(start, ErrorCode.STRING_TOO_LONG,
          "a byte string of " + chars + " characters, more than the limit of " + lim.maxStringLength());
    }
    return new Value.Bytes(Arrays.copyOf(buffer, length));
  }
}
