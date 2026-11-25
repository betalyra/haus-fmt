/// One of the three standard layouts (spec §11).
public enum Layout: String, Sendable, Hashable, CaseIterable {
    /// For people who edit: one entry per line, comments and blank lines kept.
    case pretty
    /// Each top-level item on one line, with spaces, comments dropped: for
    /// logs and streams people look at.
    case compact
    /// Compact without whitespace between tokens: for the wire and storage.
    case minimised
}

/// How to write text: the layout, and in the pretty layout the indentation
/// and line width.
///
/// `indent` and `width` are whole numbers of zero or more, taken literally
/// (spec §11): 0 is 0. Options with a negative one can't be made: the
/// initializer that takes them throws ``FormatOptionsError``.
///
/// ```swift
/// let options = try FormatOptions(indent: 4, width: 100)
/// ```
public struct FormatOptions: Sendable, Hashable {
    public var layout: Layout
    /// The number of spaces per level in the pretty layout. Default 2.
    public private(set) var indent: Int
    /// The line width in code points, which only decides whether a
    /// positional payload fits on one line in the pretty layout. Default 80.
    public private(set) var width: Int
    /// The limits of the text read (``format(_:_:)``), or of the reader the
    /// text is written for (``stringify(_:_:)``, ``stringifyAll(_:_:)``).
    public var limits: Limits

    /// Options with the default indent (2) and width (80).
    public init(layout: Layout = .pretty, limits: Limits = Limits()) {
        self.layout = layout
        self.indent = 2
        self.width = 80
        self.limits = limits
    }

    /// Options with an indent and a width: whole numbers of zero or more. A
    /// negative one is a misuse of the API and throws ``FormatOptionsError``
    /// (it has no error code of spec §17).
    public init(layout: Layout = .pretty, indent: Int = 2, width: Int = 80, limits: Limits = Limits())
        throws(FormatOptionsError)
    {
        guard indent >= 0 else { throw FormatOptionsError("indent must be 0 or more, not \(indent)") }
        guard width >= 0 else { throw FormatOptionsError("width must be 0 or more, not \(width)") }
        self.layout = layout
        self.indent = indent
        self.width = width
        self.limits = limits
    }
}

/// Format options that can't be used: a negative indent or width (spec §11).
/// A misuse of the API, not a mistake in text, so it is no ``HausError`` and
/// has no error code.
public struct FormatOptionsError: Error, Sendable, Hashable, CustomStringConvertible {
    /// What is wrong: `indent must be 0 or more, not -1`.
    public let message: String

    init(_ message: String) { self.message = message }

    public var description: String { message }
}

/// Reformats haus text in a standard layout (spec §11). Numbers, byte
/// strings and `"…"` strings keep their spelling. The pretty layout keeps
/// comments and blank lines; compact and minimised drop them (see
/// ``hasComments(_:limits:)`` for tools that rewrite files in place).
public func format(_ text: String, _ options: FormatOptions = FormatOptions()) throws(HausError) -> String {
    let file = try parseFile(text, limits: options.limits, keep: true).syntax!
    return Printer(options).file(file)
}

/// Whether haus text has comments, which the compact and minimised layouts
/// drop (spec §11: a tool that rewrites a file in place in those layouts
/// refuses when it has comments, unless asked to drop them).
public func hasComments(_ text: String, limits: Limits = Limits()) throws(HausError) -> Bool {
    try parseFile(text, limits: limits, keep: true).syntax!.hasComments
}

/// Writes one value in a layout, as a file holding it alone, with a line
/// break at the end. With no source text, numbers are written normalized and
/// in decimal, byte strings in lowercase hex without spaces, and strings with
/// the fewest escapes.
///
/// ```swift
/// try stringify(["a": 1], FormatOptions(layout: .compact)) // "{ a: 1 }\n"
/// ```
///
/// It checks every limit of the options' ``FormatOptions/limits`` (spec §7,
/// §11), so that a reader with those limits reads the text back: a number
/// longer than the number limit (`number-too-long`) or with an exponent over
/// the exponent limit (`exponent-too-large`), a string, byte string (two
/// characters a byte), key or tag longer than the string limit
/// (`string-too-long`, `key-too-long`, `tag-too-long`), nesting deeper than
/// the depth limit (`nesting-too-deep`, a record payload counting one level
/// and an empty container a level), and more values written than
/// ``Limits/maxNodes`` (`too-many-nodes`, at `$`, for a value whose arrays
/// share each other).
public func stringify(_ value: HausValue, _ options: FormatOptions = FormatOptions()) throws(HausError) -> String {
    try write([value], options, indexed: false)
}

/// Writes values as a file (spec §6): one value alone, two or more as a
/// stream with a comma after each. See ``stringify(_:_:)``. Each value has
/// its own node count, and an error in the i-th value is at its index
/// (`$[3]`), also when there is one value (`$[0]`, spec §11).
public func stringifyAll(_ values: [HausValue], _ options: FormatOptions = FormatOptions()) throws(HausError) -> String
{
    try write(values, options, indexed: true)
}

/// Writes values as a file; with `indexed`, an error's path starts with the
/// index of its value.
private func write(_ values: [HausValue], _ options: FormatOptions, indexed: Bool) throws(HausError) -> String {
    let limits = try options.limits.checked()
    guard options.layout == .pretty else { return try writeLines(values, options.layout, limits, indexed: indexed) }
    var file = FileNode()
    for (i, value) in values.enumerated() {
        var walk = Walk(TreeSpelling(), checks: .writer(limits), prefix: indexed ? [.index(i)] : [])
        var nothing: [UInt8] = []
        try walk.write(value, to: &nothing)
        file.items.append(Item(node: walk.spelling.root!))
    }
    return Printer(options).file(file)
}

/// Writes values in the compact or minimised layout, directly: one line per
/// value, with a comma after each in a stream.
private func writeLines(
    _ values: [HausValue], _ layout: Layout, _ limits: Limits, indexed: Bool
) throws(HausError) -> String {
    let spelling = layout == .compact ? HausSpelling.compact : .minimised
    let stream = values.count > 1
    var out: [UInt8] = []
    for (i, value) in values.enumerated() {
        var walk = Walk(spelling, checks: .writer(limits), prefix: indexed ? [.index(i)] : [])
        try walk.write(value, to: &out)
        if stream { out.append(ASCII.comma) }
        out.append(ASCII.lf)
    }
    return String(decoding: out, as: UTF8.self)
}

// ── values to syntax nodes ──────────────────────────────────────

/// One step of a path (spec §15): a key or an index.
enum PathStep {
    case key(String)
    case index(Int)
}

/// A path from `$` (spec §15): `.key` for an identifier, `["key"]` with the
/// key in canonical form otherwise, `[i]` for an index.
func pathString(_ steps: [PathStep]) -> String {
    steps.reduce(into: "$") { path, step in
        switch step {
        case .index(let i): path += "[\(i)]"
        case .key(let key) where isIdentifier(key): path += "." + key
        case .key(let key):
            var quoted: [UInt8] = []
            appendQuoted(key, to: &quoted)
            path += "[" + String(decoding: quoted, as: UTF8.self) + "]"
        }
    }
}

/// Builds the syntax tree of a value written by a ``Walk``, which checks it,
/// for the pretty layout. A container's node stands for its kind (and tag);
/// its items are the nodes of its items.
struct TreeSpelling: Spelling {
    var sortsKeys: Bool { false }
    /// The containers being built, the outermost first, with their items so far.
    private var open: [(node: Node, items: [Item])] = []
    /// The key of the next field.
    private var pending: String?
    /// The value's node, once it is built.
    private(set) var root: Node?

    mutating func leaf(_ v: HausValue, to out: inout [UInt8]) {
        switch v {
        case .number(let n):
            add(Node(v, text: Array(n.literal.utf8)))
        case .bytes(let bytes):
            var text = Array(#"x""#.utf8)
            appendHex(bytes, to: &text)
            text.append(ASCII.quote)
            add(Node(v, text: text))
        default:
            add(Node(v))
        }
    }

    mutating func open(_ c: Opening, to out: inout [UInt8]) {
        let node =
            switch c {
            case .array: Node(.array([]))
            case .record: Node(.record(HausRecord()))
            case .payload(let tag): Node(.variant(tag, []), form: .parens)
            case .recordPayload(let tag, _): Node(.variant(tag, []), form: .braces)
            }
        add(node)
        open.append((node, []))
    }

    mutating func close(_ c: Opening, to out: inout [UInt8]) {
        let (node, items) = open.removeLast()
        node.items = items
    }

    mutating func separator(to out: inout [UInt8]) {}

    mutating func key(_ key: String, to out: inout [UInt8]) { pending = key }

    /// Adds a node to the container being built, or makes it the root.
    private mutating func add(_ node: Node) {
        guard !open.isEmpty else {
            root = node
            return
        }
        open[open.count - 1].items.append(Item(key: pending, node: node))
        pending = nil
    }
}

// ── syntax nodes to text ────────────────────────────────────────

/// Writes a syntax tree in a layout.
struct Printer {
    var out: [UInt8] = []
    let indent: Int
    let width: Int
    let layout: Layout

    init(_ options: FormatOptions) {
        indent = options.indent
        width = options.width
        layout = options.layout
    }

    consuming func file(_ file: FileNode) -> String {
        let stream = file.items.count > 1
        if layout == .pretty {
            var first = true
            var multiline = false
            for (i, item) in file.items.enumerated() {
                leading(item, level: 0, first: &first, forceBlank: i > 0 && multiline)
                multiline = entry(item, level: 0, comma: stream)
            }
            comments(file.dangling, level: 0, first: &first)
        } else {
            for item in file.items {
                compact(item.node)
                if stream { out.append(ASCII.comma) }
                out.append(ASCII.lf)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // ── pretty ──────────────────────────────────────────────────

    /// A blank line if one is wanted and this isn't the first thing in its container.
    mutating func blankLine(_ blank: Bool, first: inout Bool) {
        if blank && !first { out.append(ASCII.lf) }
        first = false
    }

    mutating func writeIndent(_ level: Int) {
        out += repeatElement(ASCII.space, count: level * indent)
    }

    /// Comments on lines of their own. `forceBlank` asks for a blank line
    /// before the first.
    mutating func comments(_ comments: [Comment], level: Int, first: inout Bool, forceBlank: Bool = false) {
        for (i, comment) in comments.enumerated() {
            blankLine(comment.blank || forceBlank && i == 0, first: &first)
            writeIndent(level)
            out += comment.text
            out.append(ASCII.lf)
        }
    }

    /// The comments above an item and the blank line before it. `forceBlank`
    /// asks for a blank line before whatever comes first.
    mutating func leading(_ item: Item, level: Int, first: inout Bool, forceBlank: Bool) {
        comments(item.leading, level: level, first: &first, forceBlank: forceBlank)
        blankLine(item.blank || forceBlank && item.leading.isEmpty, first: &first)
    }

    /// An item on its line(s), and whether its value took more than one line.
    /// The pretty layout recurses through here, `value(_:level:column:suffix:)`
    /// and `container(_:level:)`, which keep small frames (also in a debug
    /// build, which inlines nothing): their work is done by functions that
    /// return before the recursion goes on.
    mutating func entry(_ item: Item, level: Int, comma: Bool) -> Bool {
        let column = startEntry(item, level: level)
        let start = out.count
        value(item.node, level: level, column: column, suffix: comma ? 1 : 0)
        return endEntry(item, from: start, comma: comma)
    }

    /// Writes the indent and key of an entry: the column its value starts at.
    mutating func startEntry(_ item: Item, level: Int) -> Int {
        writeIndent(level)
        guard let key = item.key else { return level * indent }
        let start = out.count
        appendKey(key, to: &out)
        out += ": ".utf8
        return level * indent + codePoints(in: out[start...])
    }

    /// Ends an entry whose value starts at `start`: whether it took more
    /// than one line.
    mutating func endEntry(_ item: Item, from start: Int, comma: Bool) -> Bool {
        let multiline = out[start...].contains(ASCII.lf)
        if comma { out.append(ASCII.comma) }
        for comment in item.trailing {
            out.append(ASCII.space)
            out += comment.text
        }
        out.append(ASCII.lf)
        return multiline
    }

    /// A value in the pretty layout, starting at `column` (in code points),
    /// with `suffix` characters to follow it on its last line.
    mutating func value(_ node: Node, level: Int, column: Int, suffix: Int) {
        if startValue(node, level: level, column: column, suffix: suffix) { container(node, level: level) }
    }

    /// Writes a value that has no entries of its own lines, or the start of
    /// one that has: whether its container comes next.
    mutating func startValue(_ node: Node, level: Int, column: Int, suffix: Int) -> Bool {
        switch node.value {
        case .string(let s) where s.utf8.contains(ASCII.lf):
            blockString(s, level: level)
        case .record, .array:
            return true
        case .variant(let tag, _):
            switch node.form {
            case .bare:
                out += tag.name.utf8
            case .braces:
                out += tag.name.utf8
                out.append(ASCII.space)
                return true
            case .parens:
                if let w = inlineWidth(node), column + w + suffix <= width {
                    compact(node)
                } else {
                    out += tag.name.utf8
                    return true
                }
            }
        default:
            scalar(node)
        }
        return false
    }

    /// The brackets of a record, array or payload.
    func brackets(_ node: Node) -> (open: UInt8, close: UInt8) {
        switch (node.value, node.form) {
        case (.array, _): (ASCII.openBracket, ASCII.closeBracket)
        case (.variant, .parens): (ASCII.openParen, ASCII.closeParen)
        default: (ASCII.openBrace, ASCII.closeBrace)
        }
    }

    /// A record, array or payload, one entry per line.
    mutating func container(_ node: Node, level: Int) {
        guard openContainer(node) else { return }
        var first = true
        var i = 0
        while i < node.items.count {
            leading(node.items[i], level: level + 1, first: &first, forceBlank: false)
            _ = entry(node.items[i], level: level + 1, comma: true)
            i += 1
        }
        closeContainer(node, level: level, first: &first)
    }

    /// Writes the opening bracket and line break of a container: false if it
    /// is empty, written whole.
    mutating func openContainer(_ node: Node) -> Bool {
        let (open, close) = brackets(node)
        guard !node.items.isEmpty || !node.dangling.isEmpty else {
            out += [open, close]
            return false
        }
        out += [open, ASCII.lf]
        return true
    }

    /// Writes the comments at the end of a container and its closer.
    mutating func closeContainer(_ node: Node, level: Int, first: inout Bool) {
        comments(node.dangling, level: level + 1, first: &first)
        writeIndent(level)
        out.append(brackets(node).close)
    }

    /// The width of a value written on one line in the compact layout, or nil
    /// if the pretty layout never writes it on one line: it holds a
    /// non-empty record or array, a multi-line string or a comment.
    func inlineWidth(_ node: Node) -> Int? {
        if let known = node.inlineWidth { return known }
        let w = measure(node)
        node.inlineWidth = .some(w)
        return w
    }

    func measure(_ node: Node) -> Int? {
        let empty = node.items.isEmpty && node.dangling.isEmpty
        switch node.value {
        case .string(let s):
            if s.utf8.contains(ASCII.lf) { return nil }
            var text: [UInt8] = []
            if let spelling = node.text { appendSpelling(spelling, to: &text) } else { appendQuoted(s, to: &text) }
            return codePoints(in: text[...])
        case .record, .array:
            return empty ? 2 : nil
        case .variant(let tag, _):
            switch node.form {
            case .bare: return tag.name.utf8.count
            case .braces: return empty ? tag.name.utf8.count + 3 : nil
            case .parens:
                guard node.dangling.isEmpty else { return nil }
                var w = tag.name.utf8.count + 2 + 2 * (node.items.count - 1)
                for item in node.items {
                    guard item.leading.isEmpty, item.trailing.isEmpty, let a = inlineWidth(item.node) else {
                        return nil
                    }
                    w += a
                }
                return w
            }
        case .number, .bytes:
            return codePoints(in: node.text![...])
        case .secret:
            return nil  // never written: the writers refuse it
        }
    }

    /// A number, byte string or single-line string.
    mutating func scalar(_ node: Node) {
        if let text = node.text {
            appendSpelling(text, to: &out)
        } else if case .string(let s) = node.value {
            appendQuoted(s, to: &out)
        }
    }

    /// A string with line feeds as a `"""` block string, its content one level
    /// deeper than the entry (spec §11).
    mutating func blockString(_ s: String, level: Int) {
        out += #"""""#.utf8
        out.append(ASCII.lf)
        for line in Array(s.utf8).split(separator: ASCII.lf, omittingEmptySubsequences: false) {
            if !line.isEmpty {
                writeIndent(level + 1)
                appendBlockLine(line, to: &out)
            }
            out.append(ASCII.lf)
        }
        writeIndent(level + 1)
        out += #"""""#.utf8
    }

    // ── compact and minimised ───────────────────────────────────

    /// A value on one line, in the compact or minimised layout.
    mutating func compact(_ node: Node) {
        switch (node.value, node.form) {
        case (.record, _):
            fields(node)
        case (.array, _):
            items(node)
        case (.variant(let tag, _), let form):
            out += tag.name.utf8
            switch form {
            case .bare: break
            case .braces:
                space()
                fields(node)
            case .parens: items(node)
            }
        default:
            scalar(node)
        }
    }

    /// A space, except in the minimised layout.
    mutating func space() {
        if layout != .minimised { out.append(ASCII.space) }
    }

    /// A comma between items, and a space after it except in the minimised layout.
    mutating func separator() {
        out.append(ASCII.comma)
        space()
    }

    mutating func items(_ node: Node) {
        let (open, close) = brackets(node)
        out.append(open)
        for (i, item) in node.items.enumerated() {
            if i > 0 { separator() }
            compact(item.node)
        }
        out.append(close)
    }

    mutating func fields(_ node: Node) {
        guard !node.items.isEmpty else {
            out += [ASCII.openBrace, ASCII.closeBrace]
            return
        }
        out.append(ASCII.openBrace)
        space()
        for (i, item) in node.items.enumerated() {
            if i > 0 { separator() }
            appendKey(item.key!, to: &out)
            out.append(ASCII.colon)
            space()
            compact(item.node)
        }
        space()
        out.append(ASCII.closeBrace)
    }
}
