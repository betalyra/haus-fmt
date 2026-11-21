package org.hausfmt.bench.speed;

import java.util.function.Consumer;

/**
 * One timed task: what it is, and its body, one iteration of the library calls.
 *
 * @param group parse, typed or write (the canonical form is a write)
 * @param input corpus or per doc
 * @param format json or haus: the JSON rows are the baseline of the haus rows of the same group and input
 * @param size the bytes read (parse, typed) or written (write) per iteration, found only when the
 *     results are written: a fork that times the task doesn't need them
 */
record Task(String id, String group, String input, String format, String impl, Size size, Body body) {

  /** The bytes read or written per iteration. */
  long bytes() {
    try {
      return size.bytes();
    } catch (Exception e) {
      throw new IllegalStateException(id + ": " + e.getMessage(), e);
    }
  }

  /** How many bytes a task reads or writes per iteration. */
  @FunctionalInterface
  interface Size {
    long bytes() throws Exception;
  }

  /**
   * One iteration: every output goes to {@code out} (JMH's Blackhole when timed), and the result is
   * a size, for the checksum.
   */
  @FunctionalInterface
  interface Body {
    long run(Consumer<Object> out) throws Exception;
  }
}
