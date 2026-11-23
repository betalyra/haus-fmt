package org.hausfmt.ext.uuid;

import java.util.UUID;
import org.hausfmt.Codec;
import org.hausfmt.ErrorCode;
import org.hausfmt.HausException;
import org.hausfmt.Value;

/**
 * The codecs of the profile {@code @haus-fmt/uuid/rfc9562} (extensions/uuid/profiles/rfc9562.md)
 * and the id of the package's type.
 */
public final class UuidCodecs {
  private UuidCodecs() {}

  /** The id of the type {@code Uuid} (spec §13.3). */
  public static final String UUID_ID = "@haus-fmt/uuid@1#Uuid";

  /**
   * The codec of the rfc9562 profile for {@code Uuid}, with the host type {@link String}: the text,
   * {@code 0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57}, checked to be 32 digits 0–9, a–f in groups
   * 8-4-4-4-12, lowercase only, of any version.
   */
  public static final Codec<String> RFC9562 =
      Codec.of(UUID_ID, String.class, UuidCodecs::decodeText, UuidCodecs::encodeText);

  /**
   * The codec of the rfc9562 profile for {@code Uuid}, with the host type {@link UUID}. It checks
   * the same rule and keeps the value: the text is the UUID's one spelling, and {@link
   * UUID#toString()} writes it.
   */
  public static final Codec<UUID> RFC9562_AS_UUID =
      Codec.of(UUID_ID, UUID.class, v -> UUID.fromString(decodeText(v)), u -> encodeText(u.toString()));

  /** Why the profile rejects a text; it doesn't quote the text, which can be anything. */
  private static final String REJECTED =
      "not a UUID of the rfc9562 profile: 32 digits 0–9, a–f in groups of 8-4-4-4-12, joined by hyphens";

  /**
   * Whether the rfc9562 profile accepts {@code s}: 36 characters, hyphens at 8, 13, 18 and 23, and
   * 0–9, a–f everywhere else.
   */
  public static boolean isValid(String s) {
    if (s.length() != 36) {
      return false;
    }
    for (int i = 0; i < 36; i++) {
      char c = s.charAt(i);
      boolean hyphen = i == 8 || i == 13 || i == 18 || i == 23;
      boolean ok = hyphen ? c == '-' : (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
      if (!ok) {
        return false;
      }
    }
    return true;
  }

  private static String decodeText(Value v) {
    if (!(v instanceof Value.Variant x) || !x.tag().equals("Uuid") || x.size() != 1) {
      throw new IllegalArgumentException("expected Uuid(text)");
    }
    if (!(x.get(0) instanceof Value.Text t) || !isValid(t.value())) {
      throw new IllegalArgumentException(REJECTED);
    }
    return t.value();
  }

  private static Value encodeText(String s) {
    // The rule is checked here too: a host value can be any string.
    if (!isValid(s)) {
      throw HausException.of(ErrorCode.CANNOT_ENCODE, REJECTED);
    }
    return Value.variant("Uuid", Value.string(s));
  }
}
