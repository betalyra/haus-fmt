package org.hausfmt.ext.money;

import java.util.Objects;

/**
 * An ISO-shaped currency code: {@code EUR}. Any string can be held, as a host value can be built
 * from anything; the codecs check the profile's rule when they encode it.
 *
 * @param code the code, three letters A–Z for the profile
 */
public record Currency(String code) {
  /** A currency; the code may not be null. */
  public Currency {
    Objects.requireNonNull(code, "code");
  }

  /** The code itself: {@code EUR}. */
  @Override
  public String toString() {
    return code;
  }
}
