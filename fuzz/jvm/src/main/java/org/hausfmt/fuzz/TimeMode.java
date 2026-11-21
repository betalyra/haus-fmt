package org.hausfmt.fuzz;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.hausfmt.HausException;
import org.hausfmt.StdTime;

/**
 * The std/time fuzzer's mode (fuzz/src/time.ts), {@code jvm-runner --time FILE}: lines {@code TYPE
 * HEX}, the text as hex UTF-8; prints {@code ok} if the text is a valid value of the std/time type
 * ({@link StdTime#check}), {@code no} if not, and {@code err invalid UTF-8} for bytes that aren't
 * UTF-8, as the Go runner does.
 */
final class TimeMode {
  private TimeMode() {}

  static void run(Path file, PrintStream out) throws IOException {
    for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
      if (!line.isEmpty()) {
        out.println(one(line));
      }
    }
  }

  private static String one(String line) {
    int space = line.indexOf(' ');
    String type = space < 0 ? line : line.substring(0, space);
    String text;
    try {
      // Strict, unlike new String(bytes, UTF_8), which would replace bad bytes with U+FFFD.
      text =
          StandardCharsets.UTF_8
              .newDecoder()
              .onMalformedInput(CodingErrorAction.REPORT)
              .onUnmappableCharacter(CodingErrorAction.REPORT)
              .decode(ByteBuffer.wrap(unhex(space < 0 ? "" : line.substring(space + 1))))
              .toString();
    } catch (CharacterCodingException e) {
      return "err invalid UTF-8";
    }
    try {
      StdTime.check(type, text);
      return "ok";
    } catch (HausException e) {
      return "no";
    }
  }

  /** A case's text, written in hex; nothing if it isn't hex, as Go's runner reads it. */
  private static byte[] unhex(String s) {
    if (s.length() % 2 != 0) {
      return new byte[0];
    }
    byte[] b = new byte[s.length() / 2];
    for (int i = 0; i < b.length; i++) {
      int hi = Character.digit(s.charAt(2 * i), 16);
      int lo = Character.digit(s.charAt(2 * i + 1), 16);
      if (hi < 0 || lo < 0) {
        return new byte[0];
      }
      b[i] = (byte) (hi << 4 | lo);
    }
    return b;
  }
}
