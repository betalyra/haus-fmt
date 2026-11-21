// The order in Kotlin: the same steps as Order.java (and go/examples/order), on the same file,
// with the app's types as data classes and a sealed interface, and codecs for Money and LatLng.
// Run: ./gradlew :examples:orderKotlin (from jvm/).
package org.hausfmt.examples.order

import java.math.BigDecimal
import java.math.BigInteger
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale
import org.hausfmt.Codec
import org.hausfmt.Codecs
import org.hausfmt.DecodeOptions
import org.hausfmt.FormatOptions
import org.hausfmt.HausException
import org.hausfmt.PackageLocator
import org.hausfmt.Schema
import org.hausfmt.SchemaOptions
import org.hausfmt.Value
import org.hausfmt.examples.SharedFiles
import org.hausfmt.ext.geo.GeoCodecs
import org.hausfmt.ext.geo.LatLng
import org.hausfmt.ext.money.Currency
import org.hausfmt.ext.money.Money
import org.hausfmt.ext.money.MoneyCodecs
import org.hausfmt.kotlin.codec
import org.hausfmt.kotlin.decodeHaus
import org.hausfmt.kotlin.get
import org.hausfmt.kotlin.string

/** Integer cents, as payment APIs want them, and an ISO 4217 currency. */
public data class Amount(val cents: BigInteger, val currency: String)

/** A point in GeoJSON order. */
public data class LngLat(val lng: Double, val lat: Double) {
    override fun toString(): String = "[$lng, $lat]"
}

/** The schema's `closed < UserId String >`. */
public data class UserId(val id: String)

public sealed interface Status {
    public data object Pending : Status
    public data class Shipped(val tracking: String) : Status
    public data object Cancelled : Status
}

/** The app's type for the schema's `Root`, with the codecs' types. */
public data class AppOrder(
    val id: BigInteger,
    val customer: UserId,
    val placed: LocalDate,
    val total: Amount,
    val deliverTo: LngLat,
    val status: Status,
)

/** Money(44.40, EUR) ↔ Amount(4440, "EUR"), on top of the iso profile. */
private val cents = Codec.of(
    MoneyCodecs.MONEY_ID, Amount::class.java,
    { v ->
        val m = MoneyCodecs.ISO.decode(v)
        val cents = m.amount().toBigDecimal().movePointRight(2)
        require(cents.stripTrailingZeros().scale() <= 0) { "${m.amount().literal()} has more than 2 decimal places" }
        Amount(cents.toBigIntegerExact(), m.currency().code())
    },
    { a -> MoneyCodecs.ISO.encode(Money(Value.number(BigDecimal(a.cents, 2)), Currency(a.currency))) },
)

/** LatLng(38.7223, -9.1393) ↔ [-9.1393, 38.7223], on top of the wgs84 profile. */
private val geoJson = Codec.of(
    GeoCodecs.LATLNG_ID, LngLat::class.java,
    { v -> GeoCodecs.WGS84.decode(v).let { LngLat(lng = it.lng(), lat = it.lat()) } },
    { p -> GeoCodecs.WGS84.encode(LatLng(p.lat, p.lng)) },
)

public fun main() {
    // The packages the schema imports, @haus-fmt/money and @haus-fmt/geo, given by their folder.
    val packages = PackageLocator.explicit().folder(SharedFiles.root().resolve("extensions"))
    val schema = Schema.load(SharedFiles.path("order.schema.haus"), SchemaOptions.DEFAULT.withPackages(packages))
    val root = schema.type("Root")
    val order = SharedFiles.read("order.haus").decodeToString()

    // Without codecs: Money is Money(Decimal, Currency), the Decimal as its exact text.
    val plain = order.decodeHaus(root)
    val total = plain["total"] as Value.Variant
    println("plain:  ${plain["customer"]?.get(0)?.string} pays ${total[0]} ${(total[1] as Value.Variant).tag()}")

    // With codecs: the fields have the codecs' types.
    val orders = schema.codec<AppOrder>("Root", DecodeOptions.DEFAULT.withCodecs(Codecs.of(cents, geoJson)))
    val typed = orders.decode(order)
    println("typed:  ${typed.customer.id} pays ${typed.total.cents} cents, deliver to [lng, lat] ${typed.deliverTo}")
    println("placed: ${typed.placed}, a ${typed.placed.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.ENGLISH)}")

    // The status is a sealed interface: `when` is exhaustive.
    when (val s = typed.status) {
        is Status.Shipped -> println("status: shipped, tracking ${s.tracking}")
        Status.Pending, Status.Cancelled -> println("status: not on its way")
    }

    // Encoding with the same codecs gives back the same haus text.
    print(orders.encode(typed, FormatOptions.COMPACT))

    // Codecs add rules on top of the schema's: Eur is a valid tag, but not ISO-shaped.
    val eur = order.replaceFirst("EUR", "Eur")
    eur.decodeHaus(root)
    println("Eur without codecs: accepted")
    try {
        orders.decode(eur)
    } catch (e: HausException) {
        println("Eur with codecs: ${e.message}")
    }
    try {
        orders.decode(order.replaceFirst("44.40", "44.405"))
    } catch (e: HausException) {
        println("44.405 with codecs: ${e.message}")
    }
}
