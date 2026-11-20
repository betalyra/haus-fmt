package org.hausfmt;

import java.util.Objects;

/**
 * How text is formatted or values are written (spec §11). Like {@code gofmt}, the layouts have no
 * other options.
 *
 * <pre>{@code FormatOptions.COMPACT}  {@code FormatOptions.PRETTY.withIndent(4).withWidth(100)}</pre>
 *
 * @param layout the layout
 * @param indent spaces per level in the pretty layout; default 2
 * @param width the line width in code points, which only decides whether a positional payload fits
 *     on one line in the pretty layout; default 80
 * @param limits the limits of the text read ({@link Haus#format}), or of the reader the text is
 *     written for ({@link Haus#write})
 */
public record FormatOptions(Layout layout, int indent, int width, Limits limits) {
  /** The pretty layout with the default indent and width. */
  public static final FormatOptions PRETTY = new FormatOptions(Layout.PRETTY, 2, 80, Limits.DEFAULT);
  /** The compact layout. */
  public static final FormatOptions COMPACT = PRETTY.withLayout(Layout.COMPACT);
  /** The minimised layout. */
  public static final FormatOptions MINIMISED = PRETTY.withLayout(Layout.MINIMISED);

  /** Checks the options: indent and width may not be negative. */
  public FormatOptions {
    Objects.requireNonNull(layout, "layout");
    Objects.requireNonNull(limits, "limits");
    if (indent < 0 || width < 0) {
      throw new IllegalArgumentException("indent and width may not be negative");
    }
  }

  /** The default options of a layout. */
  public static FormatOptions of(Layout layout) {
    return PRETTY.withLayout(layout);
  }

  public FormatOptions withLayout(Layout value) {
    return new FormatOptions(value, indent, width, limits);
  }

  public FormatOptions withIndent(int value) {
    return new FormatOptions(layout, value, width, limits);
  }

  public FormatOptions withWidth(int value) {
    return new FormatOptions(layout, indent, value, limits);
  }

  public FormatOptions withLimits(Limits value) {
    return new FormatOptions(layout, indent, width, value);
  }
}
