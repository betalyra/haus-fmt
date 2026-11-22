package org.hausfmt;

import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.Arrays;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.Spliterator;
import java.util.Spliterators;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;

/**
 * Reads the top-level values of a file or stream (spec §6) one at a time from an {@link
 * InputStream}, holding at most one value's text in memory. Errors carry the line and column in
 * the whole input, and have the same codes as when the whole input is parsed at once.
 *
 * <pre>{@code
 * try (StreamReader reader = new StreamReader(in, StreamOptions.DEFAULT.withStrict(true))) {
 *   for (Value v; (v = reader.read()) != null; ) {
 *     handle(v);
 *   }
 * }
 * }</pre>
 *
 * <p>It is also an {@link Iterator}, and {@link #stream()} gives the values as a {@link Stream};
 * those throw I/O errors as {@link UncheckedIOException}. After an error, every call throws it
 * again.
 */
public final class StreamReader implements Iterator<Value>, Closeable {
  private static final int READ_SIZE = 64 << 10;

  private final InputStream in;
  private final StreamOptions options;
  private RuntimeException error;
  private IOException ioError;
  private Value peeked;

  private byte[] buf = new byte[READ_SIZE];
  private int len;
  /** The start of the current value's text in buf. */
  private int start;
  /** How far the scanner has read. */
  private int pos;
  /** Whether the input has no more bytes. */
  private boolean eof;
  /** Whether the current value is the first of the stream. */
  private boolean first = true;
  /** Characters of the current value so far. */
  private int chars;
  /** The position of buf[start] in the whole input. */
  private int line = 1;

  private int column = 1;
  private final ScanState scan = new ScanState();

  /** A reader of the values in {@code in}, with the default options. */
  public StreamReader(InputStream in) {
    this(in, StreamOptions.DEFAULT);
  }

  /** A reader of the values in {@code in}. */
  public StreamReader(InputStream in, StreamOptions options) {
    this.in = in;
    this.options = options;
  }

  /**
   * The next value, or null when there are no more.
   *
   * @throws HausException for invalid input, a value longer than {@link Limits#maxValueLength()},
   *     or, in strict mode, a stream that ends without a comma ({@code stream-truncated})
   * @throws IOException if the input can't be read
   */
  public Value read() throws IOException {
    if (peeked != null) {
      Value v = peeked;
      peeked = null;
      return v;
    }
    if (error != null) {
      throw error;
    }
    if (ioError != null) {
      throw ioError;
    }
    try {
      return next0();
    } catch (HausException e) {
      error = e;
      throw e;
    } catch (IOException e) {
      ioError = e;
      throw e;
    }
  }

  @Override
  public boolean hasNext() {
    if (peeked == null) {
      try {
        peeked = read();
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
    }
    return peeked != null;
  }

  @Override
  public Value next() {
    if (!hasNext()) {
      throw new NoSuchElementException();
    }
    Value v = peeked;
    peeked = null;
    return v;
  }

  /** The values that remain, as a sequential stream. */
  public Stream<Value> stream() {
    return StreamSupport.stream(Spliterators.spliteratorUnknownSize(this, Spliterator.ORDERED | Spliterator.NONNULL), false);
  }

  /** Closes the input. */
  @Override
  public void close() throws IOException {
    in.close();
  }

  private Value next0() throws IOException {
    while (true) {
      int comma = findComma();
      if (comma >= 0) {
        Value v = parse(comma + 1);
        advance(comma + 1);
        if (v != null) {
          return v;
        }
        continue; // only whitespace and comments: impossible before a comma, but harmless
      }
      if (!eof) {
        fill();
        continue;
      }
      // The rest of the input, after the last comma.
      if (start == len) {
        return null;
      }
      Value v = parse(len);
      advance(len);
      if (v == null) {
        return null;
      }
      if (options.strict()) {
        throw new HausException(ErrorCode.STREAM_TRUNCATED,
            "the stream ends without a comma after its last value, which may be cut off",
            line, column, null, "','", "end of input");
      }
      return v;
    }
  }

  /** Reads more input, keeping the current value. */
  private void fill() throws IOException {
    if (start > 0 && start >= len / 2) {
      System.arraycopy(buf, start, buf, 0, len - start);
      len -= start;
      pos -= start;
      start = 0;
    }
    if (buf.length - len < READ_SIZE) {
      buf = Arrays.copyOf(buf, 2 * buf.length + READ_SIZE);
    }
    int n = in.read(buf, len, buf.length - len);
    if (n < 0) {
      eof = true;
    } else {
      len += n;
    }
  }

  /**
   * Parses one value's text, {@code buf[start..to)}: whitespace and comments, at most one value,
   * and the comma after it, if any. Null if there is no value.
   */
  private Value parse(int to) {
    Source src = new Source(buf, start, to, line, column);
    try {
      List<Value> values = new Parser(src, options.limits(), false, first).file();
      // Two values: the scanner found no comma between them, so the parser reported
      // missing-comma already.
      return values.isEmpty() ? null : values.get(0);
    } catch (SyntaxError e) {
      throw src.error(e);
    }
  }

  /** Moves past a value whose text ends at {@code to}, keeping the position. */
  private void advance(int to) {
    int lastLine = -1;
    for (int i = start; i < to; i++) {
      if (buf[i] == '\n') {
        line++;
        lastLine = i;
      }
    }
    column = lastLine >= 0 ? 1 + Scan.countChars(buf, lastLine + 1, to) : column + Scan.countChars(buf, start, to);
    start = to;
    pos = Math.max(pos, to);
    first = false;
    chars = 0;
    scan.reset();
  }

  /** What the scanner is inside of. */
  private enum Mode {
    CODE,
    LINE_COMMENT,
    BLOCK_COMMENT,
    STRING,
    BLOCK_STRING,
    BYTES
  }

  /**
   * The state of the scanner that finds the top-level commas. It only needs to know where strings,
   * comments and brackets are; the parser checks everything else. On valid input it agrees with
   * the parser, and on invalid input it never ends a construct before the parser would, so the text
   * it hands the parser holds the first error.
   */
  private static final class ScanState {
    Mode mode = Mode.CODE;
    /** Open brackets. */
    int depth;
    /** Nesting of block comments. */
    int comments;
    /** In a block string: the line so far is spaces and tabs. */
    boolean blanks;
    /** In a block string: still on the line of the opening {@code """}. */
    boolean opening;
    /** The previous byte is {@code [A-Za-z0-9_]}. */
    boolean word;

    void reset() {
      mode = Mode.CODE;
      depth = 0;
      comments = 0;
      blanks = false;
      opening = false;
      word = false;
    }

    /** Back in code after a string, comment or byte string. */
    void code() {
      mode = Mode.CODE;
      word = false;
    }
  }

  /** Scans for the next top-level comma: its offset in buf, or −1 if more input is needed (or there is none). */
  private int findComma() {
    ScanState st = scan;
    int limit = options.limits().maxValueLength();
    int i = pos;
    if (first && start == 0 && i == 0 && Scan.isBom(buf, 0, len)) {
      i = Scan.BOM_BYTES.length; // the byte order mark is not part of the first value
    }
    for (; i < len; i++) {
      if (!eof && i + 3 > len) {
        break; // keep up to three bytes of lookahead
      }
      byte c = buf[i];
      if (!Scan.isContinuation(c)) {
        chars++;
      }
      byte next = i + 1 < len ? buf[i + 1] : 0;
      switch (st.mode) {
        case CODE:
          boolean word = Scan.isWordChar(c);
          switch (c) {
            case ',':
              if (st.depth == 0) {
                pos = i;
                chars--;
                return i;
              }
              break;
            case '{':
            case '[':
            case '(':
              st.depth++;
              break;
            case '}':
            case ']':
            case ')':
              st.depth = Math.max(st.depth - 1, 0);
              break;
            case '/':
              if (next == '/') {
                st.mode = Mode.LINE_COMMENT;
                i++;
                chars++;
              } else if (next == '*') {
                st.mode = Mode.BLOCK_COMMENT;
                st.comments = 1;
                i++;
                chars++;
              }
              break;
            case '"':
              if (next == '"' && i + 2 < len && buf[i + 2] == '"') {
                st.mode = Mode.BLOCK_STRING;
                st.blanks = false;
                st.opening = true;
                i += 2;
                chars += 2;
              } else {
                st.mode = Mode.STRING;
              }
              break;
            case 'x':
              if (!st.word && next == '"') {
                st.mode = Mode.BYTES;
                i++;
                chars++;
                word = false;
              }
              break;
            default:
              break;
          }
          st.word = word;
          break;
        case LINE_COMMENT:
          if (c == '\n') {
            st.mode = Mode.CODE;
          }
          break;
        case BLOCK_COMMENT:
          if (c == '/' && next == '*') {
            st.comments++;
            i++;
            chars++;
          } else if (c == '*' && next == '/') {
            st.comments--;
            i++;
            chars++;
            if (st.comments == 0) {
              st.code();
            }
          }
          break;
        case STRING:
          if (c == '\\') {
            if (next == '"' || next == '\\') {
              i++;
              chars++;
            }
          } else if (c == '"' || c == '\n') {
            st.code();
          }
          break;
        case BLOCK_STRING:
          if (c == '\n') {
            st.blanks = true;
            st.opening = false;
          } else if (c == ' ' || c == '\t') {
            // blanks stay blanks
          } else if (c == '\\') {
            st.blanks = false;
            if (next == '"' || next == '\\') {
              i++;
              chars++;
            }
          } else if (c == '"' && next == '"' && i + 2 < len && buf[i + 2] == '"' && st.blanks && !st.opening) {
            st.code();
            i += 2;
            chars += 2;
          } else {
            st.blanks = false;
          }
          break;
        case BYTES:
          if (c == '"' || c == '\n') {
            st.code();
          }
          break;
      }
      if (chars > limit) {
        // At the first character counted: after the previous comma, or the first of the
        // stream, after a byte order mark (spec §7).
        int bom = first && start == 0 && Scan.isBom(buf, 0, len) ? 1 : 0;
        throw new HausException(ErrorCode.VALUE_TOO_LONG, "a top-level value of more than " + limit + " characters",
            line, column + bom, null, null, null);
      }
    }
    pos = i;
    return -1;
  }
}
