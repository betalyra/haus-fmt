package org.hausfmt;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.List;

/**
 * The canonical form (spec §12): one exact text per value, so that two values are equal exactly
 * when their canonical forms are identical. Records are sorted by key code points, numbers
 * normalized and in decimal, and there is no whitespace outside strings.
 *
 * <p>The canonical form, hashing, equality and order work at any depth: they walk a value with a
 * stack of their own, not the thread's, so the depth is bounded only by memory.
 */
final class Canonical {
  private final StringBuilder b = new StringBuilder();
  /** Whether to fail for a string or key without a UTF-8 form; without, it is written as U+FFFD. */
  private final boolean check;
  /** The node limit (spec §7), the one limit of the canonical form (spec §12). */
  private final Limits lim;
  /** The values written for the current top-level value. */
  private int nodes;
  /** Where the current top-level value is: {@code $}, or {@code $[i]} for value i of {@code hashAll}. */
  private String place = "$";

  private Canonical(boolean check, Limits lim) {
    this.check = check;
    this.lim = lim;
  }

  static String of(Value v, Limits lim) {
    Canonical c = new Canonical(true, lim);
    c.top(v);
    return c.b.toString();
  }

  /** The values' canonical forms joined by {@code ,} (spec §12, {@code hashAll}). */
  static String ofAll(List<Value> values, Limits lim) {
    Canonical c = new Canonical(true, lim);
    for (int i = 0; i < values.size(); i++) {
      if (i > 0) {
        c.b.append(',');
      }
      c.place = "$[" + i + "]";
      c.top(values.get(i));
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
   * of the other (spec §12). A string without a UTF-8 form sorts as if it held U+FFFD there. The
   * node limit applies to each value; its error is at {@code $}, and its message says which value.
   */
  static int compare(Value x, Value y, Limits lim) {
    return Scan.compareCodePoints(operand(x, lim, "first"), operand(y, lim, "second"));
  }

  /** The canonical form of an operand of {@link #compare}; an error's message names the operand. */
  private static String operand(Value v, Limits lim, String which) {
    Canonical c = new Canonical(false, lim);
    try {
      c.top(v);
    } catch (HausException e) {
      throw e.withReason("the " + which + " value: " + e.reason());
    }
    return c.b.toString();
  }

  /** Writes one top-level value, which has the node limit to itself. */
  private void top(Value v) {
    nodes = 0;
    value(v);
  }

  /**
   * Counts one more value written: {@code too-many-nodes} above the node limit, at {@code $}, or at
   * {@code $[i]} for value i of {@code hashAll}.
   */
  private void node() {
    if (++nodes > lim.maxNodes()) {
      throw WriteCheck.tooManyNodes(new Path(place), lim);
    }
  }

  /**
   * A container being written: its items, or a record's keys in code point order, the next one
   * to write, and its closing bracket.
   */
  private static final class Frame {
    final Value[] items;
    final Value.Record record;
    final int[] order;
    final char closer;
    int next;

    Frame(Value[] items, char closer) {
      this.items = items;
      this.record = null;
      this.order = null;
      this.closer = closer;
    }

    Frame(Value.Record record) {
      this.items = null;
      this.record = record;
      this.order = sortedOrder(record.unsafeKeys());
      this.closer = '}';
    }

    int size() {
      return items != null ? items.length : order.length;
    }
  }

  /**
   * Writes a value with a stack of its own rather than recursion, so that any depth works (spec
   * §12): the depth is bounded only by memory, never by the thread's stack.
   */
  private void value(Value root) {
    ArrayDeque<Frame> stack = new ArrayDeque<>();
    Value v = root;
    while (true) {
      node();
      Frame opened = null;
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
          b.append('[');
          opened = new Frame(((Value.Array) v).unsafeItems(), ']');
          break;
        case RECORD:
          b.append('{');
          opened = new Frame((Value.Record) v);
          break;
        case VARIANT:
          Value.Variant variant = (Value.Variant) v;
          b.append(variant.tag());
          if (variant.payload() != null) {
            node(); // Tag { … }: the record is one value written
            b.append('{');
            opened = new Frame(variant.payload());
          } else if (variant.size() > 0) {
            b.append('(');
            opened = new Frame(variant.unsafeArgs(), ')');
          }
          break;
        case SECRET:
          throw WriteCheck.secretRefused(new Path(place));
      }
      if (opened != null) {
        if (opened.size() == 0) {
          b.append(opened.closer);
        } else {
          stack.push(opened);
        }
      }
      // The next value: the next item of the innermost container not done, after closing those done.
      v = null;
      while (v == null) {
        Frame top = stack.peek();
        if (top == null) {
          return;
        }
        if (top.next == top.size()) {
          b.append(top.closer);
          stack.pop();
          continue;
        }
        if (top.next > 0) {
          b.append(',');
        }
        int at = top.next++;
        if (top.items != null) {
          v = top.items[at];
        } else {
          v = field(top.record, top.order[at]);
        }
      }
    }
  }

  /** Writes the key of field i of a record and its colon, and returns the field's value. */
  private Value field(Value.Record r, int i) {
    String key = r.unsafeKeys()[i];
    if (r.bareKeys() || Scan.isIdent(key)) {
      b.append(key);
    } else {
      string(key, "key");
    }
    b.append(':');
    return r.valueAt(i);
  }

  private void string(String s, String what) {
    if (!Quoting.appendQuoted(b, s) && check) {
      throw HausException.of(ErrorCode.CANNOT_ENCODE, "a " + what + " with an unpaired surrogate, which has no UTF-8 form");
    }
  }

  /** A pair of containers being compared by {@link #equal}, and the next item to compare. */
  private static final class Pair {
    final Value[] xs;
    final Value[] ys;
    final Value.Record rx;
    final Value.Record ry;
    int next;

    Pair(Value[] xs, Value[] ys, Value.Record rx, Value.Record ry) {
      this.xs = xs;
      this.ys = ys;
      this.rx = rx;
      this.ry = ry;
    }

    int size() {
      return xs != null ? xs.length : rx.size();
    }
  }

  /**
   * Haus equality (spec §2), with a stack of its own rather than recursion, so that any depth
   * works: numbers by their normalized literals, strings by code points, records by their keys and
   * values whatever the order, variants by tag and arguments.
   */
  static boolean equal(Value x, Value y) {
    ArrayDeque<Pair> stack = new ArrayDeque<>();
    while (true) {
      if (x != y) {
        if (y == null || x.kind() != y.kind()) {
          return false;
        }
        Pair opened = null;
        switch (x.kind()) {
          case NUMBER:
          case STRING:
          case BYTES:
            if (!x.equals(y)) {
              return false;
            }
            break;
          case ARRAY:
            opened = new Pair(((Value.Array) x).unsafeItems(), ((Value.Array) y).unsafeItems(), null, null);
            break;
          case RECORD:
            opened = new Pair(null, null, (Value.Record) x, (Value.Record) y);
            if (opened.rx.size() != opened.ry.size()) {
              return false;
            }
            break;
          case VARIANT:
            Value.Variant vx = (Value.Variant) x;
            Value.Variant vy = (Value.Variant) y;
            if (!vx.tag().equals(vy.tag())) {
              return false;
            }
            opened = new Pair(vx.unsafeArgs(), vy.unsafeArgs(), null, null);
            break;
          case SECRET:
            return false; // a secret is equal to itself only (x == y above)
        }
        if (opened != null) {
          if (opened.xs != null && opened.xs.length != opened.ys.length) {
            return false;
          }
          if (opened.size() > 0) {
            stack.push(opened);
          }
        }
      }
      // The next pair: the next items of the innermost containers not done.
      x = null;
      while (x == null) {
        Pair top = stack.peek();
        if (top == null) {
          return true;
        }
        if (top.next == top.size()) {
          stack.pop();
          continue;
        }
        int at = top.next++;
        if (top.xs != null) {
          x = top.xs[at];
          y = top.ys[at];
        } else {
          x = top.rx.valueAt(at);
          y = top.ry.get(top.rx.unsafeKeys()[at]);
        }
      }
    }
  }

  /** Records with at most this many keys are sorted by insertion. */
  private static final int INSERTION_SORT = 24;

  /**
   * The places of the keys in code point order. The keys of a record are distinct, so the order
   * is the same however it is found: by insertion for a few keys (quadratic only in a bounded
   * number), by the library's merge sort otherwise.
   */
  private static int[] sortedOrder(String[] keys) {
    int n = keys.length;
    int[] order = new int[n];
    for (int i = 0; i < n; i++) {
      order[i] = i;
    }
    if (n <= INSERTION_SORT) {
      for (int i = 1; i < n; i++) {
        int x = order[i];
        int j = i - 1;
        while (j >= 0 && Scan.compareCodePoints(keys[order[j]], keys[x]) > 0) {
          order[j + 1] = order[j];
          j--;
        }
        order[j + 1] = x;
      }
      return order;
    }
    Integer[] boxed = new Integer[n];
    for (int i = 0; i < n; i++) {
      boxed[i] = i;
    }
    Arrays.sort(boxed, (x, y) -> Scan.compareCodePoints(keys[x], keys[y]));
    for (int i = 0; i < n; i++) {
      order[i] = boxed[i];
    }
    return order;
  }
}
