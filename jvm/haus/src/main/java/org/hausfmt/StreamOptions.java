package org.hausfmt;

import java.util.Objects;

/**
 * How a {@link StreamReader} reads.
 *
 * @param limits the limits of each value; {@link Limits#maxValueLength()} bounds how much of the
 *     input is held at once
 * @param strict whether a comma must follow the last value (spec §6), so that a stream cut off
 *     after a complete-looking value is reported ({@code stream-truncated}) instead of read as valid
 */
public record StreamOptions(Limits limits, boolean strict) {
  /** The default limits, not strict. */
  public static final StreamOptions DEFAULT = new StreamOptions(Limits.DEFAULT, false);

  public StreamOptions {
    Objects.requireNonNull(limits, "limits");
  }

  public StreamOptions withLimits(Limits value) {
    return new StreamOptions(value, strict);
  }

  public StreamOptions withStrict(boolean value) {
    return new StreamOptions(limits, value);
  }
}
