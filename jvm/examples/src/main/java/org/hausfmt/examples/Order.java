package org.hausfmt.examples;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.LocalDate;
import java.time.format.TextStyle;
import java.util.Locale;
import org.hausfmt.Codec;
import org.hausfmt.Codecs;
import org.hausfmt.DecodeOptions;
import org.hausfmt.FormatOptions;
import org.hausfmt.Haus;
import org.hausfmt.HausCodec;
import org.hausfmt.HausException;
import org.hausfmt.PackageLocator;
import org.hausfmt.Schema;
import org.hausfmt.SchemaOptions;
import org.hausfmt.SchemaType;
import org.hausfmt.Value;
import org.hausfmt.ext.geo.GeoCodecs;
import org.hausfmt.ext.geo.LatLng;
import org.hausfmt.ext.money.Currency;
import org.hausfmt.ext.money.Money;
import org.hausfmt.ext.money.MoneyCodecs;

/**
 * The order: the steps of go/examples/order and rust/examples/order, on the same file. The order
 * is decoded with examples/order.schema.haus, first with the schema's own types, then into the
 * app's records with codecs that choose host types for named types (spec §13.4): integer cents for
 * {@code Money}, GeoJSON order for {@code LatLng}. Each codec takes the value the schema decoded,
 * so the schema's rules always run, and encodes back to it, so the haus text never changes.
 * Run: {@code ./gradlew :examples:order} (from jvm/).
 */
public final class Order {
  private Order() {}

  /** Integer cents, as payment APIs want them, and an ISO 4217 currency. */
  record Amount(BigInteger cents, String currency) {}

  /** A point in GeoJSON order. */
  record LngLat(double lng, double lat) {
    @Override
    public String toString() {
      return "[" + lng + ", " + lat + "]";
    }
  }

  /** The schema's {@code closed < UserId String >}. */
  record UserId(String id) {}

  /** One of Pending, Shipped and Cancelled. */
  sealed interface Status permits Pending, Shipped, Cancelled {}

  record Pending() implements Status {}

  record Shipped(String tracking) implements Status {}

  record Cancelled() implements Status {}

  /** The app's type for the schema's {@code Root}, with the codecs' types. */
  record AppOrder(BigInteger id, UserId customer, LocalDate placed, Amount total, LngLat deliverTo, Status status) {}

  /**
   * Money(44.40, EUR) ↔ Amount(4440, "EUR"). More than 2 decimal places, or a currency that isn't
   * ISO-shaped (the iso profile, which MoneyCodecs.ISO checks), is an error.
   */
  static final Codec<Amount> CENTS = Codec.of(MoneyCodecs.MONEY_ID, Amount.class,
      v -> {
        Money m = MoneyCodecs.ISO.decode(v);
        BigDecimal cents = m.amount().toBigDecimal().movePointRight(2);
        if (cents.stripTrailingZeros().scale() > 0) {
          throw new IllegalArgumentException(m.amount().literal() + " has more than 2 decimal places");
        }
        return new Amount(cents.toBigIntegerExact(), m.currency().code());
      },
      a -> MoneyCodecs.ISO.encode(new Money(Value.number(new BigDecimal(a.cents(), 2)), new Currency(a.currency()))));

  /** LatLng(38.7223, -9.1393) ↔ [-9.1393, 38.7223]: the swap happens here, once, on top of the wgs84 profile. */
  static final Codec<LngLat> GEOJSON = Codec.of(GeoCodecs.LATLNG_ID, LngLat.class,
      v -> {
        LatLng p = GeoCodecs.WGS84.decode(v);
        return new LngLat(p.lng(), p.lat());
      },
      p -> GeoCodecs.WGS84.encode(new LatLng(p.lat(), p.lng())));

  public static void main(String[] args) {
    // The packages the schema imports, @haus-fmt/money and @haus-fmt/geo, given by their folder.
    PackageLocator packages = PackageLocator.explicit().folder(SharedFiles.root().resolve("extensions"));
    Schema schema = Schema.load(SharedFiles.path("order.schema.haus"), SchemaOptions.DEFAULT.withPackages(packages));
    SchemaType root = schema.type("Root");
    String order = new String(SharedFiles.read("order.haus"), java.nio.charset.StandardCharsets.UTF_8);

    // Without codecs: Money is Money(Decimal, Currency), the Decimal as its exact text.
    Value.Record plain = (Value.Record) root.decode(Haus.parse(order));
    Value.Variant total = (Value.Variant) plain.get("total");
    String customer = ((Value.Text) ((Value.Variant) plain.get("customer")).get(0)).value();
    System.out.printf("plain:  %s pays %s %s%n", customer, total.get(0), ((Value.Variant) total.get(1)).tag());

    // With codecs: the fields have the codecs' types.
    HausCodec<AppOrder> orders = HausCodec.of(root, AppOrder.class, DecodeOptions.DEFAULT.withCodecs(Codecs.of(CENTS, GEOJSON)));
    AppOrder typed = orders.decode(order);
    System.out.printf("typed:  %s pays %s cents, deliver to [lng, lat] %s%n", typed.customer().id(), typed.total().cents(), typed.deliverTo());
    System.out.printf("placed: %s, a %s%n", typed.placed(), typed.placed().getDayOfWeek().getDisplayName(TextStyle.FULL, Locale.ENGLISH));

    // Variants are a sealed interface.
    if (typed.status() instanceof Shipped) {
      System.out.printf("status: shipped, tracking %s%n", ((Shipped) typed.status()).tracking());
    } else {
      System.out.println("status: not on its way");
    }

    // Encoding with the same codecs gives back the same haus text.
    System.out.print(orders.encode(typed, FormatOptions.COMPACT));

    // Codecs add rules on top of the schema's: Eur is a valid tag, but not ISO-shaped.
    String eur = order.replaceFirst("EUR", "Eur");
    root.decode(Haus.parse(eur));
    System.out.println("Eur without codecs: accepted");
    try {
      orders.decode(eur);
    } catch (HausException e) {
      System.out.println("Eur with codecs: " + e.getMessage());
    }
    try {
      orders.decode(order.replaceFirst("44\\.40", "44.405"));
    } catch (HausException e) {
      System.out.println("44.405 with codecs: " + e.getMessage());
    }
  }
}
