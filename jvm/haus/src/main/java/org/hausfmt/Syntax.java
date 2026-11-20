package org.hausfmt;

import java.util.ArrayList;
import java.util.List;

/**
 * The syntax tree the formatter works on: values with their source spellings, and the comments
 * and blank lines around them (spec §11). The parser builds it only for formatting; parsing
 * builds values alone.
 */
final class Syntax {
  private Syntax() {}

  /** A comment as written (a CR LF inside it read as LF). */
  static final class Comment {
    final String text;
    /**
     * The most line breaks in a row (with only blanks between them) since the previous comment or
     * item: 0 if the comment is on that line, 2 or more if a blank line comes before it.
     */
    int nl;

    Comment(String text, int nl) {
      this.text = text;
      this.nl = nl;
    }

    boolean blank() {
      return nl >= 2;
    }

    boolean multiline() {
      return text.indexOf('\n') >= 0;
    }
  }

  /** The comments and line breaks between two items. */
  static final class Gap {
    List<Comment> comments = new ArrayList<>();
    /** The most line breaks in a row after the last comment (or since the item). */
    int nl;
    /** The line breaks in a row so far: a comment or a comma ends a row. */
    int run;

    void lineBreak() {
      run++;
      nl = Math.max(nl, run);
    }

    void comment(String text) {
      comments.add(new Comment(text, nl));
      nl = 0;
      run = 0;
    }

    void clear() {
      comments = new ArrayList<>();
      nl = 0;
      run = 0;
    }
  }

  /** How a variant's payload is written. */
  enum Form {
    /** {@code Tag} */
    BARE,
    /** {@code Tag { … }}, also for {@code Tag({ … })} */
    BRACES,
    /** {@code Tag(a, b)} */
    PARENS
  }

  /** One value in the syntax tree. */
  static final class Node {
    Value value;
    /** The spelling of a number, byte string or {@code "…"} string; null to write it from the value. */
    String text;
    Form form = Form.BARE;
    /** The fields of a record (also a record payload), elements of an array, arguments of a payload. */
    List<Item> items = new ArrayList<>();
    /** Comments after the last item, before the closer. */
    List<Comment> dangling = new ArrayList<>();
    /** Whether the closer is on the line where the last item ends. */
    boolean sameLine;
    /** Line breaks before the closer, after the last item or comment. */
    int closeNl;
    /** Memo for the inline width: 0 unknown, −1 never inline, else width + 1. */
    int inlineWidth;

    Node(Value value, String text) {
      this.value = value;
      this.text = text;
    }

    boolean empty() {
      return items.isEmpty() && dangling.isEmpty();
    }

    boolean hasComments() {
      return !dangling.isEmpty() || items.stream().anyMatch(Item::hasComments);
    }
  }

  /** An entry of a container or file: a field, an element or an argument, with its comments. */
  static final class Item {
    /** Comments on lines of their own above it. */
    List<Comment> leading = new ArrayList<>();
    /** A blank line directly before it. */
    boolean blank;
    /** The key of a record field, written bare when it can be; null for other items. */
    String key;

    Node node;
    /** Comments after it on its last line. */
    List<Comment> trailing = new ArrayList<>();

    boolean keyed() {
      return key != null;
    }

    boolean hasComments() {
      return !leading.isEmpty() || !trailing.isEmpty() || node.hasComments();
    }
  }

  /** A whole file: its top-level items and the comments after them. */
  static final class File {
    final List<Item> items = new ArrayList<>();
    List<Comment> dangling = new ArrayList<>();

    boolean hasComments() {
      return !dangling.isEmpty() || items.stream().anyMatch(Item::hasComments);
    }
  }

  /**
   * How many of the comments in g start on the line of the previous token: those with no line
   * break before them, up to the first that spans lines (a comment after it starts on a later
   * line).
   */
  private static int trailingCount(Gap g) {
    int n = 0;
    while (n < g.comments.size() && g.comments.get(n).nl == 0) {
      n++;
      if (g.comments.get(n - 1).multiline()) {
        break;
      }
    }
    return n;
  }

  /**
   * Starts the item that follows the gap g: the comments of g on the line of the previous item
   * (if any) trail it, the others lead the new item. Clears g.
   */
  static Item newItem(Item previous, Gap g) {
    Item it = new Item();
    it.blank = g.nl >= 2;
    List<Comment> cs = g.comments;
    if (previous != null) {
      int n = trailingCount(g);
      previous.trailing.addAll(cs.subList(0, n));
      cs = cs.subList(n, cs.size());
    }
    it.leading.addAll(cs);
    g.clear();
    return it;
  }

  /**
   * Ends a container whose last item is {@code last} (null if it has none), with the gap g before
   * the closer: the comments that dangle at its end, whether the closer is on the line where the
   * last item ends, and the line breaks before the closer go to {@code node}. Clears g.
   */
  static void close(Node node, Item last, Gap g) {
    List<Comment> cs = g.comments;
    if (last != null) {
      int n = trailingCount(g);
      last.trailing.addAll(cs.subList(0, n));
      cs = cs.subList(n, cs.size());
    }
    node.dangling = new ArrayList<>(cs);
    node.sameLine = last != null && cs.isEmpty() && g.nl == 0;
    node.closeNl = g.nl;
    g.clear();
  }

  /** The {@link Comment#nl} of a comment that takes a blank line. */
  static int blankNl(boolean blank) {
    return blank ? 2 : 0;
  }

  /**
   * Turns the payload of {@code Tag({ … })}, a parenthesized payload whose one argument is a
   * record, into a record payload, {@code Tag { … }}. The comments inside the parentheses but
   * outside the braces move inside the braces (spec §11).
   */
  static Node mergeRecordArg(Node parens) {
    Item arg = parens.items.get(0);
    Node rec = arg.node;
    rec.value = parens.value;
    rec.form = Form.BRACES;
    rec.inlineWidth = 0;
    // Comments before the record lead its first entry. In an empty record a blank line between
    // them and the record goes to the comment after them (pending, if that comment comes from
    // after the record).
    int pending = 0;
    if (!arg.leading.isEmpty()) {
      if (!rec.items.isEmpty()) {
        Item first = rec.items.get(0);
        if (!first.leading.isEmpty()) {
          first.leading.get(0).nl = Math.max(first.leading.get(0).nl, blankNl(arg.blank));
        } else {
          first.blank = first.blank || arg.blank;
        }
        first.leading.addAll(0, arg.leading);
      } else {
        if (!rec.dangling.isEmpty()) {
          rec.dangling.get(0).nl = Math.max(rec.dangling.get(0).nl, blankNl(arg.blank));
        } else {
          pending = blankNl(arg.blank);
        }
        rec.dangling.addAll(0, arg.leading);
      }
    }
    // Comments after the record: on the line of its last entry they trail that entry (unless a
    // comment over several lines already ends that line), otherwise they dangle at its end, after
    // the line breaks before its closing brace (a blank line there stays).
    List<Comment> moved = new ArrayList<>();
    Item last = rec.items.isEmpty() ? null : rec.items.get(rec.items.size() - 1);
    if (!arg.trailing.isEmpty()
        && last != null
        && rec.dangling.isEmpty()
        && rec.sameLine
        && !endsMultiline(last.trailing)) {
      last.trailing.addAll(arg.trailing);
    } else {
      moved.addAll(arg.trailing);
    }
    moved.addAll(parens.dangling);
    if (!moved.isEmpty()) {
      moved.get(0).nl = Math.max(moved.get(0).nl, Math.max(rec.closeNl, pending));
      rec.dangling.addAll(moved);
    }
    return rec;
  }

  /** Whether the last of the comments spans several lines. */
  private static boolean endsMultiline(List<Comment> cs) {
    return !cs.isEmpty() && cs.get(cs.size() - 1).multiline();
  }

  /** Removes every comment, for tests: the pretty file without its comments. */
  static void stripComments(File f) {
    f.dangling = new ArrayList<>();
    f.items.forEach(Syntax::stripComments);
  }

  private static void stripComments(Item it) {
    it.leading = new ArrayList<>();
    it.trailing = new ArrayList<>();
    it.node.dangling = new ArrayList<>();
    it.node.items.forEach(Syntax::stripComments);
  }
}
