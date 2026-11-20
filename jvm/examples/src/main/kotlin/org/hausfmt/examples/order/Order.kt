// The order in Kotlin: the same steps as Order.java (and go/examples/order), on the same file,
// with the app's types as data classes and a sealed interface. Run: ./gradlew :examples:orderKotlin
// (from jvm/).
package org.hausfmt.examples.order

import java.math.BigDecimal
import java.math.BigInteger
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale
import org.hausfmt.Value
import org.hausfmt.examples.SharedFiles
import org.hausfmt.kotlin.bigDecimal
import org.hausfmt.kotlin.bigInteger
import org.hausfmt.kotlin.component1
import org.hausfmt.kotlin.component2
import org.hausfmt.kotlin.get
import org.hausfmt.kotlin.haus
import org.hausfmt.kotlin.hausRecord
import org.hausfmt.kotlin.hausVariant
import org.hausfmt.kotlin.parseHaus
import org.hausfmt.kotlin.string
import org.hausfmt.kotlin.toHaus

/** Integer cents, as payment APIs want them, and an ISO 4217 currency. */
public data class Amount(val cents: BigInteger, val currency: String)

/** A point in GeoJSON order. */
public data class LngLat(val lng: Double, val lat: Double) {
    override fun toString(): String = "[$lng, $lat]"
}

public sealed interface Status {
    public data object Pending : Status
    public data class Shipped(val tracking: String) : Status
    public data object Cancelled : Status
}

public data class AppOrder(
    val id: BigInteger,
    val customer: String,
    val placed: LocalDate,
    val total: Amount,
    val deliverTo: LngLat,
    val status: Status,
)

/** The order as the app's types: Money(44.40, EUR) is 4440 cents, LatLng(lat, lng) is [lng, lat]. */
public fun Value.toAppOrder(): AppOrder {
    val (_, money) = this["total"] as Value.Variant
    val (_, at) = this["deliverTo"] as Value.Variant
    val status = this["status"] as Value.Variant
    return AppOrder(
        id = this["id"]!!.bigInteger!!,
        customer = this["customer"]?.get(0)?.string!!,
        placed = LocalDate.parse(this["placed"]?.get(0)?.string),
        total = Amount(money[0].bigDecimal!!.movePointRight(2).toBigIntegerExact(), (money[1] as Value.Variant).tag()),
        deliverTo = LngLat(lng = at[1].bigDecimal!!.toDouble(), lat = at[0].bigDecimal!!.toDouble()),
        status = when (status.tag()) {
            "Pending" -> Status.Pending
            "Cancelled" -> Status.Cancelled
            else -> Status.Shipped(status.payload()["tracking"]?.string!!)
        },
    )
}

/** The order as haus values again. */
public fun AppOrder.toHausValue(): Value = hausRecord(
    "id" to id.haus,
    "customer" to hausVariant("UserId", customer.haus),
    "placed" to hausVariant("Date", placed.toString().haus),
    "total" to hausVariant("Money", BigDecimal(total.cents, 2).haus, hausVariant(total.currency)),
    "deliverTo" to hausVariant("LatLng", BigDecimal.valueOf(deliverTo.lat).haus, BigDecimal.valueOf(deliverTo.lng).haus),
    "status" to when (status) {
        Status.Pending -> hausVariant("Pending")
        Status.Cancelled -> hausVariant("Cancelled")
        is Status.Shipped -> hausVariant("Shipped", hausRecord("tracking" to status.tracking.haus))
    },
)

public fun main() {
    val order = SharedFiles.read("order.haus").parseHaus()

    // Plain values: Money(44.40, EUR) is a tag with a number, kept exactly, and a tag.
    val (_, money) = order["total"] as Value.Variant
    println("plain:  ${order["customer"]?.get(0)?.string} pays ${money[0]} ${(money[1] as Value.Variant).tag()}")

    // The app's types.
    val typed = order.toAppOrder()
    println("typed:  ${typed.customer} pays ${typed.total.cents} cents, deliver to [lng, lat] ${typed.deliverTo}")
    println("placed: ${typed.placed}, a ${typed.placed.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.ENGLISH)}")

    // The status is a sealed interface: `when` is exhaustive.
    when (val s = typed.status) {
        is Status.Shipped -> println("status: shipped, tracking ${s.tracking}")
        Status.Pending, Status.Cancelled -> println("status: not on its way")
    }

    // Writing the app's order gives back the same haus text.
    println(typed.toHausValue().toHaus())
}
