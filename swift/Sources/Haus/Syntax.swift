// The syntax tree the formatter works on: values with their source
// spellings, and the comments and blank lines around them. The parser builds
// it only for formatting; `parseAll` builds values alone.

/// A comment as written (a CR LF inside it read as LF).
struct Comment {
    var text: [UInt8]
    /// The most line breaks in a row (with only blanks between them) since
    /// the previous comment or item: 0 if the comment is on that line, 2 or
    /// more if a blank line comes before it.
    var lineBreaks: Int

    /// Whether a blank line comes before the comment.
    var blank: Bool { lineBreaks >= 2 }

    /// Whether the comment spans several lines.
    var multiline: Bool { text.contains(ASCII.lf) }
}

/// The comments and line breaks between two items.
struct Gap {
    var comments: [Comment] = []
    /// The most line breaks in a row after the last comment (or since the item).
    var lineBreaks = 0
    /// The line breaks in a row so far: a comment or a comma ends a row.
    var run = 0

    mutating func lineBreak() {
        run += 1
        lineBreaks = max(lineBreaks, run)
    }

    mutating func add(_ text: [UInt8]) {
        comments.append(Comment(text: text, lineBreaks: lineBreaks))
        lineBreaks = 0
        run = 0
    }

    /// How many of the comments start on the line of the previous token:
    /// those with no line break before them, up to the first that spans
    /// lines (a comment after it starts on a later line).
    var trailingCount: Int {
        var n = 0
        while n < comments.count && comments[n].lineBreaks == 0 {
            n += 1
            if comments[n - 1].multiline { break }
        }
        return n
    }
}

/// The line breaks that stand for a blank line, or none.
func blankLineBreaks(_ blank: Bool) -> Int { blank ? 2 : 0 }

/// How a variant's payload is written.
enum Form {
    /// `Tag`
    case bare
    /// `Tag { … }`, also for `Tag({ … })`
    case braces
    /// `Tag(a, b)`
    case parens
}

/// One value in the syntax tree.
final class Node {
    var value: HausValue
    /// The spelling of a number, byte string or `"…"` string; nil to write it from the value.
    var text: [UInt8]?
    /// For variants.
    var form: Form
    /// The fields of a record (also a record payload), elements of an array, arguments of a payload.
    var items: [Item]
    /// Comments after the last item, before the closer.
    var dangling: [Comment] = []
    /// The closer is on the line where the last item ends.
    var sameLine = false
    /// Line breaks before the closer, after the last item or comment.
    var closeLineBreaks = 0
    /// The width on one line, once measured: nil unknown, .some(nil) never inline.
    var inlineWidth: Int??

    init(_ value: HausValue, text: [UInt8]? = nil, form: Form = .bare, items: [Item] = []) {
        self.value = value
        self.text = text
        self.form = form
        self.items = items
    }

    /// Whether the node holds a comment, at any depth.
    var hasComments: Bool { !dangling.isEmpty || items.contains { $0.hasComments } }
}

/// An entry of a container or file: a field, an element or an argument, with
/// its comments.
final class Item {
    /// Comments on lines of their own above it.
    var leading: [Comment]
    /// A blank line directly before it.
    var blank: Bool
    /// The key of a record field; nil for an element or argument.
    var key: String?
    var node: Node
    /// Comments after it on its last line.
    var trailing: [Comment] = []

    init(_ start: ItemStart = ItemStart(), key: String? = nil, node: Node) {
        self.leading = start.leading
        self.blank = start.blank
        self.key = key
        self.node = node
    }

    /// The record field `key` that `start` began, with the comments of `g`,
    /// between the key and the value, moved above it, after its blank line.
    /// It empties `g`.
    @inline(never)
    convenience init(field key: String, _ start: ItemStart, _ node: Node, _ g: inout Gap) {
        var start = start
        if !g.comments.isEmpty {
            g.comments[0].lineBreaks = max(g.comments[0].lineBreaks, blankLineBreaks(start.blank))
            start.blank = false
        }
        start.leading += g.comments
        g = Gap()
        self.init(start, key: key, node: node)
    }

    var hasComments: Bool { !leading.isEmpty || !trailing.isEmpty || node.hasComments }
}

/// What comes before an item: its comments and whether a blank line does.
struct ItemStart {
    var leading: [Comment] = []
    var blank = false

    /// The start of the item after the gap `g`: the comments of `g` on the
    /// line of the previous item `previous` (if any) trail it, the others
    /// lead the new item. It empties `g`.
    init(after previous: Item?, _ g: inout Gap) {
        blank = g.lineBreaks >= 2
        leading = Array(g.comments[trail(previous, g)...])
        g = Gap()
    }

    init() {}
}

/// Moves the comments of `g` on the line of `previous` to it, and returns
/// how many they were.
private func trail(_ previous: Item?, _ g: Gap) -> Int {
    guard let previous else { return 0 }
    let n = g.trailingCount
    previous.trailing += g.comments[..<n]
    return n
}

/// A whole file: its top-level items and the comments after them.
struct FileNode {
    var items: [Item] = []
    var dangling: [Comment] = []

    var hasComments: Bool { !dangling.isEmpty || items.contains { $0.hasComments } }

    /// Ends the file, whose last item is `last`, with the gap `g` after it.
    mutating func close(after last: Item?, _ g: inout Gap) {
        dangling = Array(g.comments[trail(last, g)...])
        g = Gap()
    }
}

extension Node {
    /// Ends the container, whose last item is `last` (nil if it has none),
    /// with the gap `g` before the closer: the comments that dangle at its
    /// end, whether the closer is on the line where the last item ends, and
    /// the line breaks before it. It empties `g`.
    func close(after last: Item?, _ g: inout Gap) {
        dangling = Array(g.comments[trail(last, g)...])
        sameLine = last != nil && dangling.isEmpty && g.lineBreaks == 0
        closeLineBreaks = g.lineBreaks
        g = Gap()
    }
}

/// Turns the payload of `Tag({ … })`, a parenthesized payload whose one
/// argument is a record, into a record payload, `Tag { … }`. The comments
/// inside the parentheses but outside the braces move inside the braces
/// (spec §11).
func mergeRecordArgument(_ parens: Node) -> Node {
    let argument = parens.items[0]
    let record = argument.node
    record.value = parens.value
    record.form = .braces
    record.inlineWidth = nil
    // Comments before the record lead its first entry. In an empty record a
    // blank line between them and the record goes to the comment after them
    // (pending, if that comment comes from after the record).
    var pending = 0
    if !argument.leading.isEmpty {
        if let first = record.items.first {
            if first.leading.isEmpty {
                first.blank = first.blank || argument.blank
            } else {
                first.leading[0].lineBreaks = max(first.leading[0].lineBreaks, blankLineBreaks(argument.blank))
            }
            first.leading = argument.leading + first.leading
        } else {
            if record.dangling.isEmpty {
                pending = blankLineBreaks(argument.blank)
            } else {
                record.dangling[0].lineBreaks = max(record.dangling[0].lineBreaks, blankLineBreaks(argument.blank))
            }
            record.dangling = argument.leading + record.dangling
        }
    }
    // Comments after the record: on the line of its last entry they trail
    // that entry (unless a comment over several lines already ends that
    // line), otherwise they dangle at its end, after the line breaks before
    // its closing brace (a blank line there stays).
    var moved: [Comment] = []
    if let last = record.items.last, !argument.trailing.isEmpty, record.dangling.isEmpty, record.sameLine,
        !(last.trailing.last?.multiline ?? false)
    {
        last.trailing += argument.trailing
    } else {
        moved = argument.trailing
    }
    moved += parens.dangling
    if !moved.isEmpty {
        moved[0].lineBreaks = max(moved[0].lineBreaks, record.closeLineBreaks, pending)
        record.dangling += moved
    }
    return record
}
