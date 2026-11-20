package org.hausfmt.kotlin

import java.math.BigInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import org.hausfmt.ErrorCode
import org.hausfmt.HausException
import org.hausfmt.Layout
import org.hausfmt.Value

class HausTest {
    private val order = """{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }"""

    /** What a value is, by an exhaustive `when` over the sealed [Value]. */
    private fun describe(v: Value): String = when (v) {
        is Value.Number -> "number ${v.literal()}"
        is Value.Text -> "string ${v.value()}"
        is Value.Bytes -> "bytes ${v.hex()}"
        is Value.Array -> "array of ${v.size()}"
        is Value.Record -> "record of ${v.size()}"
        is Value.Variant -> "variant ${v.tag()}"
    }

    @Test
    fun readsAndLooksIntoValues() {
        val v = order.parseHaus()
        assertEquals("record of 3", describe(v))
        assertEquals(BigInteger.valueOf(7), v["id"]?.bigInteger)
        val (tag, args) = v["total"] as Value.Variant
        assertEquals("Money", tag)
        assertEquals("44.40", args[0].bigDecimal.toString())
        assertEquals("DE-4711", (v["status"] as Value.Variant).payload()["tracking"]?.string)
        assertNull(v["missing"])
        assertNull(v[0])
        val keys = (v as Value.Record).map { (key, _) -> key }
        assertEquals(listOf("id", "total", "status"), keys)
    }

    @Test
    fun writesValues() {
        val v = order.parseHaus()
        assertEquals("""{ id: 7, total: Money(44.40, EUR), status: Shipped { tracking: "DE-4711" } }""", v.toHaus())
        assertEquals("""{id:7,total:Money(44.40,EUR),status:Shipped{tracking:"DE-4711"}}""", v.toHaus(Layout.MINIMISED))
        assertEquals("1,\n2,\n", listOf(1.haus, 2.haus).toHaus())
        assertEquals("[\n  1,\n]\n", "[1]".formatHaus())
        assertEquals("Order{id:255}", "Order { id: 0xFF }".parseHaus().canonical)
        assertEquals(v.hash, listOf(v).hashAll())
    }

    @Test
    fun buildsValues() {
        val built = hausRecord(
            "id" to 7.haus,
            "total" to hausVariant("Money", "44.40".toBigDecimal().haus, hausVariant("EUR")),
            "tags" to listOf("a".haus, "b".haus).toHausArray(),
            "paid" to true.haus,
        )
        assertEquals("""{ id: 7, total: Money(44.40, EUR), tags: ["a", "b"], paid: True }""", built.toHaus())
        assertEquals(built, built.toHaus().parseHaus())
        val e = assertFailsWith<HausException> { hausRecord("a" to 1.haus, "a" to 2.haus) }
        assertEquals(ErrorCode.DUPLICATE_KEY, e.code())
    }

    @Test
    fun readsStreamsAsSequences() {
        val values = "Log { a: 1 },\nHeartbeat,\n".byteInputStream().hausValues().toList()
        assertEquals(listOf("Log", "Heartbeat"), values.map { (it as Value.Variant).tag() })
        val e = assertFailsWith<HausException> { "1, 2".byteInputStream().hausValues(strict = true).toList() }
        assertEquals(ErrorCode.STREAM_TRUNCATED, e.code())
    }

    @Test
    fun convertsJson() {
        val v = """{"price": 19.90, "tags": ["a"], "note": null}""".importJson()
        assertEquals("""{ price: 19.90, tags: ["a"], note: None }""", v.toHaus())
        assertEquals(v, v.toHausJson().fromHausJson())
    }
}
