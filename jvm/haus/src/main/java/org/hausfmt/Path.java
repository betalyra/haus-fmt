package org.hausfmt;

import java.util.Arrays;

/**
 * The place of the value being written or read (spec §15): steps from {@code $}, kept as steps
 * and written out only for an error: {@code .key} for an identifier, {@code ["key"]} with the key
 * in canonical form otherwise, {@code [i]} for an index.
 */
final class Path {
  /** The key of each step, or null for an index. */
  private String[] keys = new String[16];

  private int[] indexes = new int[16];
  private int size;
  /** The path the steps start from, such as {@code $[3]}; {@code $} by default. */
  private final String root;

  Path() {
    this("$");
  }

  Path(String root) {
    this.root = root;
  }

  void key(String key) {
    push(key, -1);
  }

  void index(int index) {
    push(null, index);
  }

  private void push(String key, int index) {
    if (size == keys.length) {
      keys = Arrays.copyOf(keys, 2 * size);
      indexes = Arrays.copyOf(indexes, 2 * size);
    }
    keys[size] = key;
    indexes[size++] = index;
  }

  void pop() {
    keys[--size] = null;
  }

  void clear() {
    Arrays.fill(keys, 0, size, null);
    size = 0;
  }

  @Override
  public String toString() {
    StringBuilder b = new StringBuilder(root);
    for (int i = 0; i < size; i++) {
      if (keys[i] == null) {
        b.append('[').append(indexes[i]).append(']');
      } else {
        Quoting.appendPathKey(b, keys[i]);
      }
    }
    return b.toString();
  }

  /** An error at this place. */
  HausException error(ErrorCode code, String reason) {
    return HausException.at(toString(), code, reason);
  }

  /** {@code $} followed by the steps of {@code path} after its own {@code $}: {@code $[3]} and {@code $.a} give {@code $[3].a}. */
  static String under(String prefix, String path) {
    return prefix + path.substring(1);
  }
}
