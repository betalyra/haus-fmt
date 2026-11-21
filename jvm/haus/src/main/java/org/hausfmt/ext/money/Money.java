package org.hausfmt.ext.money;

import java.util.Objects;
import org.hausfmt.Value;

/**
 * A value of the type {@code Money}: {@code Money(19.90, EUR)}. The amount is the haus number
 * itself, so it keeps its scale ({@code 19.90} is not {@code 19.9}) and is written back exactly.
 *
 * @param amount the amount, any {@code Decimal}
 * @param currency the currency
 */
public record Money(Value.Number amount, Currency currency) {
  /** A value of the type; neither part may be null. */
  public Money {
    Objects.requireNonNull(amount, "amount");
    Objects.requireNonNull(currency, "currency");
  }
}
