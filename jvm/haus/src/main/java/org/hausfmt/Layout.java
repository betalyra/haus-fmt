package org.hausfmt;

/** The three standard layouts of spec §11. */
public enum Layout {
  /** For people who edit: one entry per line, comments and blank lines kept. */
  PRETTY,
  /** Each top-level item on one line, with spaces; comments dropped. For logs and streams people look at. */
  COMPACT,
  /** Compact without whitespace between tokens: for the wire and storage. */
  MINIMISED
}
