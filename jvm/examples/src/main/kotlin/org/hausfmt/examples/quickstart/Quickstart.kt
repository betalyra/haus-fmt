// The quickstart in Kotlin: the same steps as Quickstart.java (and go/examples/quickstart), on
// the same files, with the schema's Comment as a data class. Run: ./gradlew :examples:quickstartKotlin
// (from jvm/).
package org.hausfmt.examples.quickstart

import java.math.BigInteger
import org.hausfmt.FormatOptions
import org.hausfmt.HausException
import org.hausfmt.Schema
import org.hausfmt.examples.SharedFiles
import org.hausfmt.kotlin.codec

private const val REPLY = """Comment { author: "me", at: Instant("2026-11-16T09:00:00Z"), text: "+1", likes: 0, replies: [] }"""

/** A comment: the one case of the schema's closed variant `Comment`; the instant as its exact text. */
public data class Comment(
    val author: String,
    val at: String,
    val text: String,
    val likes: BigInteger,
    val replies: List<Comment>,
) {
    /** The likes of the comment and of all its replies. */
    val allLikes: BigInteger get() = replies.fold(likes) { n, r -> n + r.allLikes }

    /** How many levels of comments the thread has. */
    val depth: Int get() = 1 + (replies.maxOfOrNull { it.depth } ?: 0)
}

public fun main() {
    val schema = Schema.load(SharedFiles.path("thread.schema.haus"))
    val comments = schema.codec<Comment>("Comment")

    // 1. The thread, checked with its schema: Root is a Comment, whose replies are Comments.
    val thread = schema.codec<Comment>("Root").decode(SharedFiles.read("thread.haus"))
    println("thread by ${thread.author}: ${thread.depth} levels, ${thread.allLikes} likes")

    // 2. Decode haus text with the schema, change it, encode it back.
    val reply = comments.decode(REPLY)
    print(comments.encode(reply.copy(likes = reply.likes + BigInteger.ONE), FormatOptions.COMPACT))

    // 3. A value that doesn't match the schema is an error that says where.
    try {
        comments.decode(REPLY.replace("likes: 0", "likes: \"lots\""))
    } catch (e: HausException) {
        println("error: ${e.message}")
    }
}
