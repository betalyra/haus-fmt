// The quickstart in Kotlin: the same steps as Quickstart.java (and go/examples/quickstart), on
// the same files. Run: ./gradlew :examples:quickstartKotlin (from jvm/).
package org.hausfmt.examples.quickstart

import java.math.BigInteger
import org.hausfmt.HausException
import org.hausfmt.Value
import org.hausfmt.examples.SharedFiles
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

private const val REPLY = """Comment { author: "me", at: Instant("2026-11-16T09:00:00Z"), text: "+1", likes: 0, replies: [] }"""

/** The record of a `Comment { … }`. */
private val Value.comment: Value.Record get() = (this as Value.Variant).payload()

private val Value.replies: List<Value> get() = (comment["replies"] as Value.Array).items()

private fun likes(v: Value): BigInteger = v.replies.fold(v.comment["likes"]!!.bigInteger!!) { n, r -> n + likes(r) }

private fun depth(v: Value): Int = 1 + (v.replies.maxOfOrNull(::depth) ?: 0)

public fun main() {
    // 1. The thread: a Comment, whose replies are Comments.
    val thread = SharedFiles.read("thread.haus").parseHaus()
    println("thread by ${thread.comment["author"]?.string}: ${depth(thread)} levels, ${likes(thread)} likes")

    // 2. Read haus text, change it, write it back.
    val fields = REPLY.parseHaus().comment.map { (key, value) ->
        key to if (key == "likes") (value.bigInteger!! + BigInteger.ONE).haus else value
    }
    println(hausVariant("Comment", hausRecord(*fields.toTypedArray())).toHaus())

    // 3. Text that isn't haus is an error that says where.
    try {
        REPLY.replace("likes: 0", "likes: lots").parseHaus()
    } catch (e: HausException) {
        println("error: ${e.message}")
    }
}
