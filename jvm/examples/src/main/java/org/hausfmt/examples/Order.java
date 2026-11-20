package org.hausfmt.examples;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.LocalDate;
import java.time.format.TextStyle;
import java.util.Locale;
import org.hausfmt.FormatOptions;
import org.hausfmt.Haus;
import org.hausfmt.Value;

/**
 * The order: the steps of go/examples/order and rust/examples/order, on the same file. The order
 * is read as plain values, then as the app's own types: cents, a date, [lng, lat] and a sealed
 * status, and written back. The other bindings do the second part with codecs on the types of
 * examples/order.schema.haus, which also add the iso and wgs84 rules (the {@code Eur} and {@code
 * 44.405} lines there); here it is done by hand, until the JVM binding has schemas.
 * Run: {@code ./gradlew :examples:order} (from jvm/).
 */
public final class Order {
  private Order() {}

  /** An amount in integer cents, as payment APIs want them, and an ISO 4217 currency. */
  record Amount(BigInteger cents, String currency) {}

  /** A point in GeoJSON order. */
  record LngLat(double lng, double lat) {
    @Override
    public String toString() {
      return "[" + lng + ", " + lat + "]";
    }
  }

  /** One of Pending, Shipped and Cancelled. */
  sealed interface Status permits Pending, Shipped, Cancelled {}

  record Pending() implements Status {}

  record Shipped(String tracking) implements Status {}

  record Cancelled() implements Status {}

  /** The app's type for the order. */
  record AppOrder(BigInteger id, String customer, LocalDate placed, Amount total, LngLat deliverTo, Status status) {}

  private static Value.Variant variant(Value v) {
    return (Value.Variant) v;
  }

  private static String text(Value v) {
    return ((Value.Text) v).value();
  }

  /** The first argument of {@code Tag(x)}. */
  private static Value arg(Value.Record r, String key) {
    return variant(r.get(key)).get(0);
  }

  /** The order as the app's types: Money(44.40, EUR) is 4440 cents, LatLng(lat, lng) is [lng, lat]. */
  static AppOrder decode(Value v) {
    Value.Record r = (Value.Record) v;
    Value.Variant total = variant(r.get("total"));
    BigInteger cents = ((Value.Number) total.get(0)).toBigDecimal().movePointRight(2).toBigIntegerExact();
    Value.Variant at = variant(r.get("deliverTo"));
    double lat = ((Value.Number) at.get(0)).toBigDecimal().doubleValue();
    double lng = ((Value.Number) at.get(1)).toBigDecimal().doubleValue();
    Value.Variant status = variant(r.get("status"));
    Status s;
    switch (status.tag()) {
      case "Pending":
        s = new Pending();
        break;
      case "Cancelled":
        s = new Cancelled();
        break;
      default:
        s = new Shipped(text(status.payload().get("tracking")));
    }
    return new AppOrder(
        ((Value.Number) r.get("id")).toBigInteger(),
        text(arg(r, "customer")),
        LocalDate.parse(text(arg(r, "placed"))),
        new Amount(cents, variant(total.get(1)).tag()),
        new LngLat(lng, lat),
        s);
  }

  /** The order as haus values again. */
  static Value encode(AppOrder o) {
    Value status;
    if (o.status() instanceof Shipped) {
      status = Value.variant("Shipped", Value.record(Value.field("tracking", Value.string(((Shipped) o.status()).tracking()))));
    } else {
      status = Value.variant(o.status() instanceof Pending ? "Pending" : "Cancelled");
    }
    return Value.record(
        Value.field("id", Value.number(o.id())),
        Value.field("customer", Value.variant("UserId", Value.string(o.customer()))),
        Value.field("placed", Value.variant("Date", Value.string(o.placed().toString()))),
        Value.field("total", Value.variant("Money",
            Value.number(new BigDecimal(o.total().cents(), 2)), Value.variant(o.total().currency()))),
        Value.field("deliverTo", Value.variant("LatLng",
            Value.number(BigDecimal.valueOf(o.deliverTo().lat())), Value.number(BigDecimal.valueOf(o.deliverTo().lng())))),
        Value.field("status", status));
  }

  public static void main(String[] args) {
    Value order = Haus.parse(SharedFiles.read("order.haus"));

    // Plain values: Money(44.40, EUR) is a tag with a number, kept exactly, and a tag.
    Value.Record r = (Value.Record) order;
    Value.Variant total = variant(r.get("total"));
    System.out.printf("plain:  %s pays %s %s%n", text(arg(r, "customer")), total.get(0), variant(total.get(1)).tag());

    // The app's types.
    AppOrder typed = decode(order);
    System.out.printf("typed:  %s pays %s cents, deliver to [lng, lat] %s%n", typed.customer(), typed.total().cents(), typed.deliverTo());
    System.out.printf("placed: %s, a %s%n", typed.placed(), typed.placed().getDayOfWeek().getDisplayName(TextStyle.FULL, Locale.ENGLISH));

    // The status is a sealed interface.
    if (typed.status() instanceof Shipped) {
      System.out.printf("status: shipped, tracking %s%n", ((Shipped) typed.status()).tracking());
    } else {
      System.out.println("status: not on its way");
    }

    // Writing the app's order gives back the same haus text.
    System.out.print(Haus.write(encode(typed), FormatOptions.COMPACT));
  }
}
