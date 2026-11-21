package org.hausfmt;

import java.util.Objects;

/**
 * How values are decoded and encoded with a schema type.
 *
 * @param limits the limits of the reader (spec §7): the depth limit, and the limits raw values
 *     (an {@code Any}, an unknown tag) are checked against
 * @param codecs run after the schema of the types they are for (spec §13.4), and may reject more
 *     values
 */
public record DecodeOptions(Limits limits, Codecs codecs) {
  /** The default limits, no codecs. */
  public static final DecodeOptions DEFAULT = new DecodeOptions(Limits.DEFAULT, Codecs.NONE);

  /** Options; neither may be null. */
  public DecodeOptions {
    Objects.requireNonNull(limits, "limits");
    Objects.requireNonNull(codecs, "codecs");
  }

  /** These options with other limits. */
  public DecodeOptions withLimits(Limits value) {
    return new DecodeOptions(value, codecs);
  }

  /** These options with codecs. */
  public DecodeOptions withCodecs(Codecs value) {
    return new DecodeOptions(limits, value);
  }
}
