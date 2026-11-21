package org.hausfmt.ext.money;

import org.hausfmt.Codec;
import org.hausfmt.ErrorCode;
import org.hausfmt.HausException;
import org.hausfmt.Value;

/**
 * The codecs of the profile {@code @haus-fmt/money/iso} (extensions/money/profiles/iso.md) and the
 * ids of the package's types.
 */
public final class MoneyCodecs {
  private MoneyCodecs() {}

  /** The id of the type {@code Money} (spec §13.3). */
  public static final String MONEY_ID = "@haus-fmt/money@1#Money";

  /** The id of the type {@code Currency} (spec §13.3). */
  public static final String CURRENCY_ID = "@haus-fmt/money@1#Currency";

  /**
   * The codec of the iso profile for {@code Money}, with the host type {@link Money}: it accepts a
   * {@code Money} whose currency is three letters A–Z, and any amount.
   */
  public static final Codec<Money> ISO = Codec.of(MONEY_ID, Money.class, MoneyCodecs::decodeMoney, MoneyCodecs::encodeMoney);

  /**
   * The codec of the iso profile for {@code Currency}, with the host type {@link Currency}: a tag
   * of three letters A–Z, without a payload.
   */
  public static final Codec<Currency> ISO_CURRENCY =
      Codec.of(CURRENCY_ID, Currency.class, MoneyCodecs::decodeCurrency, MoneyCodecs::encodeCurrency);

  private static Money decodeMoney(Value v) {
    if (!(v instanceof Value.Variant x) || !x.tag().equals("Money") || x.size() != 2) {
      throw rejected("expected Money(amount, currency)");
    }
    if (!(x.get(0) instanceof Value.Number amount)) {
      throw rejected("expected a Decimal amount");
    }
    return new Money(amount, decodeCurrency(x.get(1)));
  }

  private static Value encodeMoney(Money m) {
    return Value.variant("Money", m.amount(), encodeCurrency(m.currency()));
  }

  private static Currency decodeCurrency(Value v) {
    if (!(v instanceof Value.Variant x)) {
      throw rejected("a currency is a tag");
    }
    if (x.size() > 0) {
      throw rejected("the currency " + shortened(x.tag()) + " has a payload; a currency is three letters A–Z (ISO 4217)");
    }
    if (!isIso(x.tag())) {
      throw rejected(shortened(x.tag()) + " is not a currency: three letters A–Z (ISO 4217)");
    }
    return new Currency(x.tag());
  }

  private static Value encodeCurrency(Currency c) {
    // The rule is checked here too: a host value can be built from any string.
    if (!isIso(c.code())) {
      throw cannotEncode("\"" + shortened(c.code()) + "\" is not a currency: three letters A–Z (ISO 4217)");
    }
    return Value.variant(c.code());
  }

  /** Whether {@code s} is three capital letters A–Z. */
  private static boolean isIso(String s) {
    return s.length() == 3 && upper(s.charAt(0)) && upper(s.charAt(1)) && upper(s.charAt(2));
  }

  private static boolean upper(char c) {
    return c >= 'A' && c <= 'Z';
  }

  /** At most 20 code points of a tag, for messages. */
  private static String shortened(String s) {
    return s.codePointCount(0, s.length()) <= 20 ? s : s.substring(0, s.offsetByCodePoints(0, 20)) + "…";
  }

  /** A value the profile rejects: the decoder reports it as {@code codec-rejected}, at the value. */
  private static IllegalArgumentException rejected(String message) {
    return new IllegalArgumentException(message);
  }

  /** A host value the profile doesn't allow to be written. */
  private static HausException cannotEncode(String message) {
    return HausException.of(ErrorCode.CANNOT_ENCODE, message);
  }
}
