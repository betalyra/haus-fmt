package org.hausfmt;

/**
 * A mistake in text, at a byte offset. The readers throw it where they find the mistake; {@link
 * Source#error} turns it into a {@link HausException} with the line and column, which only an error
 * needs to compute.
 */
final class SyntaxError extends RuntimeException {
  private static final long serialVersionUID = 1L;

  final int pos;
  final ErrorCode code;
  final String reason;
  final String expected;
  final String found;

  SyntaxError(int pos, ErrorCode code, String reason, String expected, String found) {
    super(reason, null, false, false);
    this.pos = pos;
    this.code = code;
    this.reason = reason;
    this.expected = expected;
    this.found = found;
  }

  SyntaxError(int pos, ErrorCode code, String reason) {
    this(pos, code, reason, null, null);
  }
}
