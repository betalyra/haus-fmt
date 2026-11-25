package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;

/**
 * Secrets stay hidden (spec §15, "Hiding"): the untyped decoder gives a {@link Value.Secret},
 * which shows {@code <redacted>}, which the writers that don't apply its schema refuse, and which
 * encoding with the schema writes in full.
 */
class SecretTest {
  private static final SchemaType CONFIG =
      Schema.parse("type Config = { name: String, key: Secret String }").type("Config");

  @Test
  void theUntypedDecoderHidesSecrets() {
    String text = "{ name: \"a\", key: \"hunter2\" }";
    List<Value> decoded = List.of(
        CONFIG.decode(Haus.parse(text)),
        CONFIG.fromJson("{\"name\": \"a\", \"key\": \"hunter2\"}"));
    for (Value v : decoded) {
      Value key = ((Value.Record) v).get("key");
      Value.Secret secret = assertInstanceOf(Value.Secret.class, key);
      assertEquals(Value.string("hunter2"), secret.reveal());
      assertEquals(Value.Kind.SECRET, key.kind());
      assertEquals("<redacted>", key.toString());
      assertFalse(v.toString().contains("hunter2"), v.toString());
      List<Supplier<String>> writers = List.of(
          () -> Haus.write(v), () -> Haus.canonical(v), () -> Haus.hash(v), () -> HausJson.toHausJson(v));
      for (Supplier<String> w : writers) {
        HausException e = assertThrows(HausException.class, w::get);
        assertEquals(ErrorCode.CANNOT_ENCODE, e.code(), e.getMessage());
        assertFalse(e.getMessage().contains("hunter2"), e.getMessage());
      }
      assertNotEquals(v, CONFIG.decode(Haus.parse(text)));
      // With the schema, it is written in full, and decodes again.
      Value encoded = CONFIG.encode(v);
      assertTrue(Haus.write(encoded).contains("\"hunter2\""));
      assertTrue(CONFIG.toJson(v).contains("\"hunter2\""));
      assertInstanceOf(Value.Secret.class, ((Value.Record) CONFIG.decode(encoded)).get("key"));
    }
  }
}
