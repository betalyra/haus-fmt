package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

/**
 * Decoding, encoding, schema-based JSON and typed codecs recurse once per level of a value: at the
 * supported depth, 256, they fit in a small thread stack (512 KiB), JSON's four levels per haus
 * level included.
 */
class SchemaDepthTest {
  private static final int STACK = 512 << 10;

  record Node(List<Node> kids) {}

  private static void inSmallStack(Runnable r) throws InterruptedException {
    AtomicReference<Throwable> failed = new AtomicReference<>();
    Thread t = new Thread(null, () -> {
      try {
        r.run();
      } catch (Throwable e) {
        failed.set(e);
      }
    }, "small-stack", STACK);
    t.start();
    t.join();
    if (failed.get() != null) {
      throw new AssertionError(failed.get());
    }
  }

  @Test
  void deepestValues() throws InterruptedException {
    Schema s = Schema.parse("type A = Array A\ntype N = { kids: Array N }\ntype M = { next: Maybe (Maybe M) }");
    int depth = Limits.MAX_SUPPORTED_DEPTH;
    inSmallStack(() -> {
      // [[[…]]]: 256 arrays.
      String arrays = "[".repeat(depth) + "]".repeat(depth);
      SchemaType a = s.type("A");
      Value v = a.decode(Haus.parse(arrays));
      assertEquals(depth, a.encode(v).depth());
      assertEquals(v, a.fromJson(a.toJson(v)));
      // { kids: [{ kids: [ … ] }] }: 128 records in 128 arrays, as records.
      StringBuilder b = new StringBuilder();
      for (int i = 0; i < depth / 2 - 1; i++) {
        b.append("{ kids: [");
      }
      b.append("{ kids: [] }");
      b.append("] }".repeat(depth / 2 - 1));
      HausCodec<Node> nodes = s.codec("N", Node.class);
      Node n = nodes.decode(b.toString());
      assertEquals(n, nodes.fromJson(nodes.toJson(n)));
      // Maybe (Maybe M) is tagged JSON: four JSON levels for each record and its two Somes.
      StringBuilder m = new StringBuilder();
      int levels = depth / 3;
      for (int i = 0; i < levels; i++) {
        m.append("{ next: Some(Some(");
      }
      m.append("{ next: None }");
      m.append(")) }".repeat(levels));
      SchemaType mt = s.type("M");
      Value mv = mt.decode(Haus.parse(m.toString()));
      assertEquals(mv, mt.fromJson(mt.toJson(mv)));
    });
  }
}
