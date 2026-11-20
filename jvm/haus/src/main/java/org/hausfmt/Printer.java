package org.hausfmt;

import java.util.List;
import org.hausfmt.Syntax.Comment;
import org.hausfmt.Syntax.Form;
import org.hausfmt.Syntax.Item;
import org.hausfmt.Syntax.Node;

/** Writes a syntax tree in one of the layouts of spec §11. */
final class Printer {
  private final StringBuilder b = new StringBuilder();
  private final int indent;
  private final int width;
  private final Layout layout;

  private Printer(FormatOptions options) {
    this.indent = options.indent();
    this.width = options.width();
    this.layout = options.layout();
  }

  /** The file in the layout of {@code options}. */
  static String print(Syntax.File f, FormatOptions options) {
    return new Printer(options).file(f);
  }

  private String file(Syntax.File f) {
    boolean stream = f.items.size() > 1;
    if (layout != Layout.PRETTY) {
      for (Item it : f.items) {
        compact(it.node);
        if (stream) {
          b.append(',');
        }
        b.append('\n');
      }
      return b.toString();
    }
    boolean[] first = {true};
    boolean multiline = false;
    for (int i = 0; i < f.items.size(); i++) {
      Item it = f.items.get(i);
      leading(it, 0, first, i > 0 && multiline);
      multiline = entry(it, 0, stream);
    }
    comments(f.dangling, 0, first);
    return b.toString();
  }

  // ── Pretty ──

  /** Writes a blank line if one is wanted and this isn't the first thing in its container. */
  private void blankLine(boolean blank, boolean[] first) {
    if (blank && !first[0]) {
      b.append('\n');
    }
    first[0] = false;
  }

  private void writeIndent(int level) {
    for (int i = level * indent; i > 0; i--) {
      b.append(' ');
    }
  }

  private void commentLine(Comment c, int level) {
    writeIndent(level);
    b.append(c.text).append('\n');
  }

  /** Writes comments on lines of their own. */
  private void comments(List<Comment> cs, int level, boolean[] first) {
    for (Comment c : cs) {
      blankLine(c.blank(), first);
      commentLine(c, level);
    }
  }

  /** Writes the comments above an item and the blank line before it; {@code force} asks for a blank line before whatever comes first. */
  private void leading(Item it, int level, boolean[] first, boolean force) {
    for (int i = 0; i < it.leading.size(); i++) {
      Comment c = it.leading.get(i);
      blankLine(c.blank() || force && i == 0, first);
      commentLine(c, level);
    }
    blankLine(it.blank || force && it.leading.isEmpty(), first);
  }

  /** Writes an item on its line(s) in the pretty layout; whether its value took more than one line. */
  private boolean entry(Item it, int level, boolean comma) {
    writeIndent(level);
    int col = level * indent;
    if (it.keyed()) {
      int start = b.length();
      WriteCheck.appendKey(b, it.key);
      b.append(": ");
      col += b.codePointCount(start, b.length());
    }
    int start = b.length();
    value(it.node, level, col, comma ? 1 : 0);
    boolean multiline = b.indexOf("\n", start) >= 0;
    if (comma) {
      b.append(',');
    }
    for (Comment c : it.trailing) {
      b.append(' ').append(c.text);
    }
    b.append('\n');
    return multiline;
  }

  /**
   * Writes a value in the pretty layout, starting at column {@code col} (in code points), with
   * {@code suffix} characters to follow it on its last line.
   */
  private void value(Node n, int level, int col, int suffix) {
    switch (n.value.kind()) {
      case STRING:
        String s = ((Value.Text) n.value).value();
        if (s.indexOf('\n') >= 0) {
          blockString(s, level);
        } else {
          scalar(n);
        }
        break;
      case RECORD:
        container('{', '}', n, level);
        break;
      case ARRAY:
        container('[', ']', n, level);
        break;
      case VARIANT:
        String tag = ((Value.Variant) n.value).tag();
        switch (n.form) {
          case BARE:
            b.append(tag);
            break;
          case BRACES:
            b.append(tag).append(' ');
            container('{', '}', n, level);
            break;
          case PARENS:
            int w = inlineWidth(n);
            if (w >= 0 && col + w + suffix <= width) {
              compact(n);
            } else {
              b.append(tag);
              container('(', ')', n, level);
            }
            break;
        }
        break;
      default:
        scalar(n);
    }
  }

  /** Writes a record, array or payload one entry per line. */
  private void container(char open, char closer, Node n, int level) {
    if (n.empty()) {
      b.append(open).append(closer);
      return;
    }
    b.append(open).append('\n');
    boolean[] first = {true};
    for (Item it : n.items) {
      leading(it, level + 1, first, false);
      entry(it, level + 1, true);
    }
    comments(n.dangling, level + 1, first);
    writeIndent(level);
    b.append(closer);
  }

  /**
   * The width of a value written on one line in the compact layout, or −1 if the pretty layout
   * never writes it on one line: it holds a non-empty record or array, a multi-line string or a
   * comment.
   */
  private int inlineWidth(Node n) {
    if (n.inlineWidth == 0) {
      int w = measure(n);
      n.inlineWidth = w < 0 ? -1 : w + 1;
    }
    return n.inlineWidth < 0 ? -1 : n.inlineWidth - 1;
  }

  private int measure(Node n) {
    switch (n.value.kind()) {
      case STRING:
        String s = ((Value.Text) n.value).value();
        if (s.indexOf('\n') >= 0) {
          return -1;
        }
        return width(scalarText(n));
      case RECORD:
      case ARRAY:
        return n.empty() ? 2 : -1;
      case VARIANT:
        String tag = ((Value.Variant) n.value).tag();
        if (n.form == Form.BARE) {
          return tag.length();
        }
        if (n.form == Form.BRACES) {
          return n.empty() ? tag.length() + 3 : -1;
        }
        if (!n.dangling.isEmpty()) {
          return -1;
        }
        int w = tag.length() + 2 + 2 * (n.items.size() - 1);
        for (Item it : n.items) {
          if (!it.leading.isEmpty() || !it.trailing.isEmpty()) {
            return -1;
          }
          int a = inlineWidth(it.node);
          if (a < 0) {
            return -1;
          }
          w += a;
        }
        return w;
      default:
        return width(scalarText(n));
    }
  }

  private static int width(String text) {
    return text.codePointCount(0, text.length());
  }

  /** A number, byte string or single-line string, as {@link #scalar} writes it. */
  private static String scalarText(Node n) {
    StringBuilder t = new StringBuilder();
    appendScalar(t, n);
    return t.toString();
  }

  private void scalar(Node n) {
    appendScalar(b, n);
  }

  /** A number, byte string or single-line string: its spelling, or, without one, written from the value. */
  private static void appendScalar(StringBuilder b, Node n) {
    if (n.text != null) {
      Quoting.appendSpelling(b, n.text);
    } else {
      Quoting.appendQuoted(b, ((Value.Text) n.value).value());
    }
  }

  // ── Compact and minimised ──

  /** Writes a value on one line, in the compact or minimised layout. */
  private void compact(Node n) {
    boolean minimised = layout == Layout.MINIMISED;
    switch (n.value.kind()) {
      case RECORD:
        compactFields(n, minimised);
        break;
      case ARRAY:
        compactItems('[', ']', n, minimised);
        break;
      case VARIANT:
        b.append(((Value.Variant) n.value).tag());
        if (n.form == Form.BRACES) {
          if (!minimised) {
            b.append(' ');
          }
          compactFields(n, minimised);
        } else if (n.form == Form.PARENS) {
          compactItems('(', ')', n, minimised);
        }
        break;
      default:
        scalar(n);
    }
  }

  private void compactItems(char open, char closer, Node n, boolean minimised) {
    b.append(open);
    for (int i = 0; i < n.items.size(); i++) {
      if (i > 0) {
        b.append(minimised ? "," : ", ");
      }
      compact(n.items.get(i).node);
    }
    b.append(closer);
  }

  private void compactFields(Node n, boolean minimised) {
    if (n.items.isEmpty()) {
      b.append("{}");
      return;
    }
    b.append(minimised ? "{" : "{ ");
    for (int i = 0; i < n.items.size(); i++) {
      if (i > 0) {
        b.append(minimised ? "," : ", ");
      }
      Item it = n.items.get(i);
      WriteCheck.appendKey(b, it.key);
      b.append(minimised ? ":" : ": ");
      compact(it.node);
    }
    b.append(minimised ? "}" : " }");
  }

  /** Writes a string with line feeds as a {@code """} block string, its content one level deeper than the entry (spec §11). */
  private void blockString(String s, int level) {
    b.append("\"\"\"\n");
    int from = 0;
    while (true) {
      int nl = s.indexOf('\n', from);
      String line = s.substring(from, nl < 0 ? s.length() : nl);
      if (!line.isEmpty()) {
        writeIndent(level + 1);
        Quoting.appendBlockLine(b, line);
      }
      b.append('\n');
      if (nl < 0) {
        break;
      }
      from = nl + 1;
    }
    writeIndent(level + 1);
    b.append("\"\"\"");
  }
}
