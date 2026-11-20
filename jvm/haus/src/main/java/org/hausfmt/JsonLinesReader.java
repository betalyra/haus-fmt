package org.hausfmt;

import java.io.ByteArrayInputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;

/**
 * Reads JSON Lines (spec §16, "Streams"): one JSON text per value, each followed by a line feed,
 * holding one line at a time. A missing line feed after the last value and CR LF line ends are
 * accepted; an empty line is an error ({@code json-syntax}). A byte order mark is ignored only at
 * the start of the stream. Errors in a line's text have its line; errors with a path have the
 * index of the line's value first, {@code $[3]}. Made by {@link HausJson#hausJsonLinesReader} and
 * {@link HausJson#importJsonLinesReader}; after an error, every call throws it again.
 */
public final class JsonLinesReader implements Iterator<Value>, Closeable {
  /** Reads one line's JSON text, the line {@code index} (0-based) of the stream. */
  interface Converter {
    Value convert(Source line, int index);
  }

  private static final int READ_SIZE = 64 << 10;

  private final InputStream in;
  private final Converter converter;
  /** The most characters of a line, or 0 for input that is held whole already. */
  private final int maxLine;

  private byte[] buf = new byte[READ_SIZE];
  private int start;
  private int len;
  private boolean eof;
  private int index;
  private RuntimeException error;
  private IOException ioError;
  private Value peeked;

  JsonLinesReader(InputStream in, int maxLine, Converter converter) {
    this.in = in;
    this.maxLine = maxLine;
    this.converter = converter;
  }

  /** Every value of a whole text, or the first error. */
  static List<Value> readAll(byte[] text, Converter converter) {
    JsonLinesReader r = new JsonLinesReader(new ByteArrayInputStream(text), 0, converter);
    List<Value> values = new ArrayList<>();
    r.forEachRemaining(values::add);
    return values;
  }

  /**
   * The next value, or null when there are no more.
   *
   * @throws HausException for a line that isn't valid, or longer than the limit
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

  /** Closes the input. */
  @Override
  public void close() throws IOException {
    in.close();
  }

  private Value next0() throws IOException {
    int scanned = start;
    int nl;
    while (true) {
      nl = indexOf('\n', scanned);
      if (nl >= 0 || eof) {
        break;
      }
      scanned = len;
      if (maxLine > 0 && len - start > 4L * maxLine + 1) {
        throw tooLong();
      }
      scanned -= fill();
    }
    if (nl < 0 && start == len) {
      return null;
    }
    int from = start;
    int to = nl >= 0 ? nl : len;
    start = nl >= 0 ? nl + 1 : len;
    if (to > from && buf[to - 1] == '\r') {
      to--;
    }
    if (maxLine > 0 && to - from > maxLine && Scan.countChars(buf, from, to) > maxLine) {
      throw tooLong();
    }
    int n = index++;
    if (to == from) {
      throw new HausException(ErrorCode.JSON_SYNTAX, "an empty line in JSON Lines", n + 1, 1, null, "a JSON value", "end of line");
    }
    try {
      return converter.convert(new Source(buf, from, to, n + 1, 1), n);
    } catch (HausException e) {
      throw inLine(e, n);
    }
  }

  private HausException tooLong() {
    return new HausException(ErrorCode.VALUE_TOO_LONG, "a line longer than the limit of " + maxLine + " characters",
        index + 1, 1, null, null, null);
  }

  /** Places an error of line n (0-based) of the stream: an error with a path gets the line's index first. */
  static HausException inLine(HausException e, int n) {
    if (e.line() > 0) {
      return e;
    }
    String prefix = "$[" + n + "]";
    return e.withPath(e.path() == null ? prefix : Path.under(prefix, e.path()));
  }

  private int indexOf(char c, int from) {
    for (int i = from; i < len; i++) {
      if (buf[i] == c) {
        return i;
      }
    }
    return -1;
  }

  /** Reads more input, keeping the current line; returns how far the bytes moved back. */
  private int fill() throws IOException {
    int moved = 0;
    if (start > 0) {
      System.arraycopy(buf, start, buf, 0, len - start);
      len -= start;
      moved = start;
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
    return moved;
  }
}
