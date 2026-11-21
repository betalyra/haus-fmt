package org.hausfmt.examples;

import java.math.BigInteger;
import java.util.List;
import org.hausfmt.FormatOptions;
import org.hausfmt.HausCodec;
import org.hausfmt.HausException;
import org.hausfmt.Schema;

/**
 * The quickstart: the steps of go/examples/quickstart and rust/examples/quickstart, on the same
 * files: data checked by its schema (examples/thread.schema.haus), decoded into records, changed,
 * encoded back, and an error that says where. Run: {@code ./gradlew :examples:quickstart} (from
 * jvm/).
 */
public final class Quickstart {
  private Quickstart() {}

  static final String REPLY =
      "Comment { author: \"me\", at: Instant(\"2026-11-16T09:00:00Z\"), text: \"+1\", likes: 0, replies: [] }";

  /**
   * A comment: the one case of the schema's closed variant {@code Comment}. The instant is kept as
   * its text, which keeps the value exactly; {@code java.time.Instant} would keep the instant.
   */
  record Comment(String author, String at, String text, BigInteger likes, List<Comment> replies) {
    /** The likes of the comment and of all its replies. */
    BigInteger allLikes() {
      return replies.stream().map(Comment::allLikes).reduce(likes, BigInteger::add);
    }

    /** How many levels of comments the thread has. */
    int depth() {
      return 1 + replies.stream().mapToInt(Comment::depth).max().orElse(0);
    }
  }

  public static void main(String[] args) {
    Schema schema = Schema.load(SharedFiles.path("thread.schema.haus"));
    HausCodec<Comment> comments = schema.codec("Comment", Comment.class);

    // 1. The thread, checked with its schema: Root is a Comment, whose replies are Comments.
    Comment thread = schema.codec("Root", Comment.class).decode(SharedFiles.read("thread.haus"));
    System.out.printf("thread by %s: %d levels, %s likes%n", thread.author(), thread.depth(), thread.allLikes());

    // 2. Decode haus text with the schema, change it, encode it back.
    Comment reply = comments.decode(REPLY);
    Comment liked = new Comment(reply.author(), reply.at(), reply.text(), reply.likes().add(BigInteger.ONE), reply.replies());
    System.out.print(comments.encode(liked, FormatOptions.COMPACT));

    // 3. A value that doesn't match the schema is an error that says where.
    try {
      comments.decode(REPLY.replace("likes: 0", "likes: \"lots\""));
    } catch (HausException e) {
      System.out.println("error: " + e.getMessage());
    }
  }
}
