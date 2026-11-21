package org.hausfmt;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Random;
import org.junit.jupiter.api.Test;

/**
 * The shortcut of {@link SchemaFloats#isOneSpelling}: where it says a literal is its own spelling,
 * rounding it to a float and spelling that float gives the literal back.
 */
class SchemaFloatsTest {
  private static String spelled(String literal, boolean float32) {
    return SchemaFloats.format(SchemaFloats.parse(literal, float32), float32);
  }

  @Test
  void examples() {
    for (String s : new String[] {"1", "-61.68667", "0.1", "0.000001", "123456789012345", "100000000000000000000",
        "0.3", "9007199254740.99"}) {
      assertTrue(SchemaFloats.isOneSpelling(s, false), s);
      assertEquals(s, spelled(s, false), s);
    }
    for (String s : new String[] {"0", "-0", "0.0", "1.50", "1e5", "0.0000001", "1000000000000000000000",
        "1234567890123456", "0.30000000000000004", "1.5e-7"}) {
      assertFalse(SchemaFloats.isOneSpelling(s, false), s);
    }
    assertTrue(SchemaFloats.isOneSpelling("3.14159", true));
    assertFalse(SchemaFloats.isOneSpelling("3.141592", true));
  }

  @Test
  void agreesWithRounding() {
    Random random = new Random(42);
    int shortcuts = 0;
    for (int n = 0; n < 200_000; n++) {
      boolean float32 = random.nextInt(4) == 0;
      StringBuilder b = new StringBuilder();
      if (random.nextBoolean()) {
        b.append('-');
      }
      int intDigits = random.nextInt(24);
      if (intDigits == 0) {
        b.append('0');
      } else {
        b.append((char) ('1' + random.nextInt(9)));
        for (int i = 1; i < intDigits; i++) {
          b.append(random.nextInt(3) == 0 ? '0' : (char) ('0' + random.nextInt(10)));
        }
      }
      int fracDigits = random.nextInt(3) == 0 ? 0 : 1 + random.nextInt(18);
      if (fracDigits > 0) {
        b.append('.');
        for (int i = 0; i < fracDigits; i++) {
          b.append(random.nextInt(3) == 0 ? '0' : (char) ('0' + random.nextInt(10)));
        }
      }
      String literal = b.toString();
      if (!Numbers.isNormalized(literal)) {
        continue;
      }
      if (SchemaFloats.isOneSpelling(literal, float32)) {
        shortcuts++;
        assertEquals(literal, spelled(literal, float32), literal + (float32 ? " (Float32)" : ""));
      }
    }
    assertTrue(shortcuts > 20_000, "shortcuts: " + shortcuts);
  }
}
