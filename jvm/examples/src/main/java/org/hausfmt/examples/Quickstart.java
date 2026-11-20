package org.hausfmt.examples;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import org.hausfmt.FormatOptions;
import org.hausfmt.Haus;
import org.hausfmt.HausException;
import org.hausfmt.Value;

/**
 * The quickstart: the steps of go/examples/quickstart and rust/examples/quickstart, on the same
 * files: read a recursive thread, change a comment and write it back, and an error that says
 * where. The other bindings check the data with examples/thread.schema.haus; this one reads the
 * values as they are, until the JVM binding has schemas, so its error is one in the text.
 * Run: {@code ./gradlew :examples:quickstart} (from jvm/).
 */
public final class Quickstart {
  private Quickstart() {}

  static final String REPLY =
      "Comment { author: \"me\", at: Instant(\"2026-11-16T09:00:00Z\"), text: \"+1\", likes: 0, replies: [] }";

  /** The record of a {@code Comment { … }}. */
  private static Value.Record comment(Value v) {
    return ((Value.Variant) v).payload();
  }

  private static List<Value> replies(Value v) {
    return ((Value.Array) comment(v).get("replies")).items();
  }

  /** The likes of a comment and of all its replies. */
  private static BigInteger likes(Value v) {
    BigInteger n = ((Value.Number) comment(v).get("likes")).toBigInteger();
    for (Value r : replies(v)) {
      n = n.add(likes(r));
    }
    return n;
  }

  /** How many levels of comments the thread has. */
  private static int depth(Value v) {
    return 1 + replies(v).stream().mapToInt(Quickstart::depth).max().orElse(0);
  }

  public static void main(String[] args) {
    // 1. The thread: a Comment, whose replies are Comments.
    Value thread = Haus.parse(SharedFiles.read("thread.haus"));
    String author = ((Value.Text) comment(thread).get("author")).value();
    System.out.printf("thread by %s: %d levels, %s likes%n", author, depth(thread), likes(thread));

    // 2. Read haus text, change it, write it back.
    List<Value.Field> fields = new ArrayList<>();
    for (Value.Field f : comment(Haus.parse(REPLY))) {
      Value value = f.key().equals("likes")
          ? Value.number(((Value.Number) f.value()).toBigInteger().add(BigInteger.ONE))
          : f.value();
      fields.add(Value.field(f.key(), value));
    }
    Value liked = Value.variant("Comment", Value.record(fields));
    System.out.print(Haus.write(liked, FormatOptions.COMPACT));

    // 3. Text that isn't haus is an error that says where.
    try {
      Haus.parse(REPLY.replace("likes: 0", "likes: lots"));
    } catch (HausException e) {
      System.out.println("error: " + e.getMessage());
    }
  }
}
