/**
 * Kotlin for haus: extension functions over the Java core (`org.hausfmt`), which does all the
 * work. Values are the core's [Value] types, a sealed interface, so `when (v) { is Value.Record ->
 * … }` is exhaustive.
 *
 * ```kotlin
 * val order = """{ id: 7, total: Money(44.40, EUR) }""".parseHaus()
 * val (tag, args) = order["total"] as Value.Variant   // "Money", [44.40, EUR]
 * println(order.toHaus())                              // { id: 7, total: Money(44.40, EUR) }
 * ```
 */
package org.hausfmt.kotlin

import java.io.InputStream
import java.math.BigDecimal
import java.math.BigInteger
import org.hausfmt.FormatOptions
import org.hausfmt.Haus
import org.hausfmt.HausJson
import org.hausfmt.Layout
import org.hausfmt.Limits
import org.hausfmt.StreamOptions
import org.hausfmt.StreamReader
import org.hausfmt.Value

// ── Reading ──

/** The one value of this haus text (spec §6); see [Haus.parse]. */
public fun String.parseHaus(limits: Limits = Limits.DEFAULT): Value = Haus.parse(this, limits)

/** The one value of this UTF-8 haus text; see [Haus.parse]. */
public fun ByteArray.parseHaus(limits: Limits = Limits.DEFAULT): Value = Haus.parse(this, limits)

/** Every top-level value of this haus text, a file or stream (spec §6); see [Haus.parseAll]. */
public fun String.parseHausAll(limits: Limits = Limits.DEFAULT): List<Value> = Haus.parseAll(this, limits)

/** Every top-level value of this UTF-8 haus text; see [Haus.parseAll]. */
public fun ByteArray.parseHausAll(limits: Limits = Limits.DEFAULT): List<Value> = Haus.parseAll(this, limits)

/**
 * The values of this stream (spec §6), read one at a time as the sequence is iterated, holding at
 * most one value's text in memory; see [StreamReader]. The sequence can be iterated once; closing
 * the input is up to the caller.
 */
public fun InputStream.hausValues(
    limits: Limits = Limits.DEFAULT,
    strict: Boolean = false,
): Sequence<Value> {
    val reader = StreamReader(this, StreamOptions(limits, strict))
    return generateSequence { reader.read() }
}

// ── Writing ──

private fun options(layout: Layout, indent: Int, width: Int, limits: Limits) = FormatOptions(layout, indent, width, limits)

/** This haus text, reformatted in a standard layout (spec §11); see [Haus.format]. */
public fun String.formatHaus(
    layout: Layout = Layout.PRETTY,
    indent: Int = 2,
    width: Int = 80,
    limits: Limits = Limits.DEFAULT,
): String = Haus.format(this, options(layout, indent, width, limits))

/**
 * This value as haus text, in the compact layout by default, without the line break that ends a
 * file; see [Haus.write].
 */
public fun Value.toHaus(
    layout: Layout = Layout.COMPACT,
    indent: Int = 2,
    width: Int = 80,
    limits: Limits = Limits.DEFAULT,
): String = Haus.write(this, options(layout, indent, width, limits)).removeSuffix("\n")

/** These values as a haus file: one alone, more as a stream with a comma after each; see [Haus.writeAll]. */
public fun Iterable<Value>.toHaus(
    layout: Layout = Layout.COMPACT,
    indent: Int = 2,
    width: Int = 80,
    limits: Limits = Limits.DEFAULT,
): String = Haus.writeAll(toList(), options(layout, indent, width, limits))

/** The canonical form of this value (spec §12); see [Haus.canonical]. */
public val Value.canonical: String get() = Haus.canonical(this)

/** The SHA-256 of this value's canonical form, as 64 lowercase hex digits (spec §12); see [Haus.hash]. */
public val Value.hash: String get() = Haus.hash(this)

/** The hash of these values, such as a whole file (spec §12); see [Haus.hashAll]. */
public fun Iterable<Value>.hashAll(): String = Haus.hashAll(toList())

// ── JSON (spec §16) ──

/** This value as self-describing JSON (§16.2); see [HausJson.toHausJson]. */
public fun Value.toHausJson(limits: Limits = Limits.DEFAULT): String = HausJson.toHausJson(this, limits)

/** The value of this self-describing JSON (§16.2); see [HausJson.fromHausJson]. */
public fun String.fromHausJson(limits: Limits = Limits.DEFAULT): Value = HausJson.fromHausJson(this, limits)

/** This JSON text, any JSON, as a haus value (§16.1); see [HausJson.importJson]. */
public fun String.importJson(limits: Limits = Limits.DEFAULT): Value = HausJson.importJson(this, limits)

// ── Looking into values ──

/** The value of a record's field, or null if this isn't a record or has no such field. */
public operator fun Value.get(key: String): Value? = (this as? Value.Record)?.get(key)

/** An array's item or a variant's argument, or null if there is none at [index]. */
public operator fun Value.get(index: Int): Value? = when (this) {
    is Value.Array -> if (index in 0 until size()) get(index) else null
    is Value.Variant -> if (index in 0 until size()) get(index) else null
    else -> null
}

/** The tag of a variant: `val (tag, args) = variant`. */
public operator fun Value.Variant.component1(): String = tag()

/** The arguments of a variant: `val (tag, args) = variant`. */
public operator fun Value.Variant.component2(): List<Value> = args()

/** The key of a field: `for ((key, value) in record)`. */
public operator fun Value.Field.component1(): String = key()

/** The value of a field: `for ((key, value) in record)`. */
public operator fun Value.Field.component2(): Value = value()

/** The string of a [Value.Text], or null for another kind of value. */
public val Value.string: String? get() = (this as? Value.Text)?.value()

/** The integer of a [Value.Number] without fraction or exponent, or null otherwise. */
public val Value.bigInteger: BigInteger? get() = (this as? Value.Number)?.takeIf { it.isInteger }?.toBigInteger()

/** The exact decimal of a [Value.Number], or null for another kind of value. */
public val Value.bigDecimal: BigDecimal? get() = (this as? Value.Number)?.toBigDecimal()

// ── Building values ──

/** A record of the [fields], in order; a repeated key is an error (`duplicate-key`). */
public fun hausRecord(vararg fields: Pair<String, Value>): Value.Record =
    Value.record(fields.map { (key, value) -> Value.field(key, value) })

/** An array of the [items]. */
public fun hausArray(vararg items: Value): Value.Array = Value.array(*items)

/** An array of the [items]. */
public fun Iterable<Value>.toHausArray(): Value.Array = Value.array(toList())

/** A variant: `hausVariant("Some", 1.haus)`; `Tag { … }` is one record argument. */
public fun hausVariant(tag: String, vararg args: Value): Value.Variant = Value.variant(tag, *args)

/** The integer as a haus number. */
public val Int.haus: Value.Number get() = Value.number(toLong())

/** The integer as a haus number. */
public val Long.haus: Value.Number get() = Value.number(this)

/** The integer as a haus number. */
public val BigInteger.haus: Value.Number get() = Value.number(this)

/** The exact decimal as a haus number, scale included. */
public val BigDecimal.haus: Value.Number get() = Value.number(this)

/** The string as a haus string. */
public val String.haus: Value.Text get() = Value.string(this)

/** `True` or `False`. */
public val Boolean.haus: Value.Variant get() = Value.bool(this)

/** The bytes as a haus byte string (a copy). */
public val ByteArray.haus: Value.Bytes get() = Value.bytes(this)
