package org.hausfmt;

import java.util.Objects;

/**
 * A value that must not end up in logs (spec §15), such as an API key: printed, logged or written
 * to JSON it shows {@code <redacted>}, and {@link #reveal} gives it out. It is the host type of
 * {@code Secret a} for typed decoding; the data is the same as for {@code a}.
 *
 * @param <T> the type of the value
 */
public final class Secret<T> {
  private static final String REDACTED = "<redacted>";

  private final T value;

  private Secret(T value) {
    this.value = Objects.requireNonNull(value, "value");
  }

  /** Wraps a value. */
  public static <T> Secret<T> of(T value) {
    return new Secret<>(value);
  }

  /** The value. */
  public T reveal() {
    return value;
  }

  /** {@code <redacted>}. */
  @Override
  public String toString() {
    return REDACTED;
  }

  /** Whether {@code o} is a secret with an equal value. */
  @Override
  public boolean equals(Object o) {
    return o instanceof Secret && ((Secret<?>) o).value.equals(value);
  }

  @Override
  public int hashCode() {
    return value.hashCode();
  }
}
