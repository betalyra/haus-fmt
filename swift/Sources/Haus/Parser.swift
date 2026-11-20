/// Reads text that must hold exactly one value (spec §6). Two or more values,
/// or none, fail with the code `not-one-value`.
///
/// ```swift
/// let price = try parse("19.90") // .number(19.90): exact, never a float
/// ```
public func parse(_ text: String, limits: Limits = Limits()) throws(HausError) -> HausValue {
    try single(parseAll(text, limits: limits))
}

/// Reads UTF-8 text that must hold exactly one value. See ``parse(_:limits:)``.
public func parse(bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(HausError) -> HausValue {
    try single(parseAll(bytes: bytes, limits: limits))
}

/// Reads a file (spec §1, §6): zero or more top-level values, separated by
/// commas, with an optional comma after the last. A leading byte order mark
/// is skipped.
///
/// ```swift
/// let values = try parseAll("Log { a: 1 },\nHeartbeat,\n") // a stream: every top-level value
/// ```
public func parseAll(_ text: String, limits: Limits = Limits()) throws(HausError) -> [HausValue] {
    try parseFile(text, limits: limits, keep: false).values
}

/// Reads a file of UTF-8 bytes; invalid UTF-8 fails with the code
/// `invalid-utf8`. See ``parseAll(_:limits:)``.
public func parseAll(bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(HausError) -> [HausValue] {
    try withBytes(bytes) { (b) throws(HausError) in
        var p = Parser(b, limits: try limits.checked(), keep: false)
        return try p.file().values
    }
}

private func single(_ values: [HausValue]) throws(HausError) -> HausValue {
    guard values.count == 1 else {
        throw HausError(
            .notOneValue, "expected exactly one value, found \(values.count)", expected: "one value",
            found: "\(values.count) values")
    }
    return values[0]
}

/// Parses a whole text, and with `keep` builds its syntax tree too.
func parseFile(_ text: String, limits: Limits, keep: Bool) throws(HausError) -> (values: [HausValue], syntax: FileNode?)
{
    try withUTF8(text) { (b) throws(HausError) in
        var p = Parser(b, limits: try limits.checked(), keep: keep)
        return try p.file()
    }
}

/// Calls `body` with the bytes in contiguous memory.
func withBytes<T>(_ bytes: some Collection<UInt8>, _ body: (Bytes) throws(HausError) -> T) throws(HausError) -> T {
    let result = bytes.withContiguousStorageIfAvailable { b in Result { () throws(HausError) in try body(b) } }
    return try (result ?? Array(bytes).withUnsafeBufferPointer { b in Result { () throws(HausError) in try body(b) } })
        .get()
}

/// Calls `body` with the UTF-8 of `text`.
func withUTF8<T, E: Error>(_ text: String, _ body: (Bytes) throws(E) -> T) throws(E) -> T {
    var text = text
    return try text.withUTF8 { b in Result { () throws(E) in try body(b) } }.get()
}

/// A parser over one complete text. It reads bytes by index; the text is
/// valid UTF-8 (checked first), so multi-byte characters only need a look
/// where they could be a control or bidi character. It doesn't recurse: the
/// containers being read are on a stack of their own (``value()``).
struct Parser {
    let b: Bytes
    var pos = 0
    let limits: Limits
    /// Also build the syntax tree, with comments, for the formatter.
    let keep: Bool
    /// `b` starts the file: a byte order mark at its start is skipped, and
    /// `#haus` after it is a version directive.
    var fileStart = true
    /// The position of `b[0]` in the whole input.
    var line = 1
    var column = 1

    init(_ b: Bytes, limits: Limits, keep: Bool) {
        self.b = b
        self.limits = limits
        self.keep = keep
    }

    /// The byte at `i`, or nil at the end of input.
    @inline(__always)
    func byte(_ i: Int) -> UInt8? { i < b.count ? b[i] : nil }

    func hasPrefix(_ prefix: some Sequence<UInt8>, at i: Int) -> Bool {
        var i = i
        for c in prefix {
            guard byte(i) == c else { return false }
            i += 1
        }
        return true
    }

    // ── errors ──────────────────────────────────────────────────

    /// The position of byte offset `i` in the whole input (spec §8).
    func position(of i: Int) -> SourcePosition {
        let i = min(i, b.count)
        var lines = 0
        var lineStart = 0
        for k in 0..<i where b[k] == ASCII.lf {
            lines += 1
            lineStart = k + 1
        }
        let col = codePoints(in: b[lineStart..<i]) + 1
        return SourcePosition(line: line + lines, column: lines == 0 ? column + col - 1 : col)
    }

    @inline(never)
    func fail(_ i: Int, _ code: HausError.Code, _ message: String, expected: String? = nil, found: String? = nil)
        -> HausError
    {
        HausError(code, message, position: position(of: i), expected: expected, found: found)
    }

    /// An error with what was expected and what is at `i`.
    @inline(never)
    func failFound(_ i: Int, _ code: HausError.Code, expected: String) -> HausError {
        let found = describeCharacter(at: i, in: b)
        return fail(i, code, "expected \(expected), found \(found)", expected: expected, found: found)
    }

    @inline(never)
    func expectedValue(_ i: Int) -> HausError { failFound(i, .expectedValue, expected: "a value") }

    /// The end of input inside the bracket opened at `open`.
    @inline(never)
    func unclosed(_ open: Int, _ closer: UInt8) -> HausError {
        let o = Character(Unicode.Scalar(b[open]))
        let c = Character(Unicode.Scalar(closer))
        return fail(
            open, .unclosedBracket, "'\(o)' is never closed: the input ends before its '\(c)'", expected: "'\(c)'",
            found: "end of input")
    }

    /// The code for a character at `i` that may not appear raw where it is
    /// (spec §4): a control character other than tab and line feed, a
    /// carriage return not followed by a line feed, or a bidi control. Nil
    /// for any other character.
    func rawCharacterCode(at i: Int) -> HausError.Code? {
        switch b[i] {
        case ASCII.tab, ASCII.lf: return nil
        case ASCII.cr: return byte(i + 1) == ASCII.lf ? nil : .loneCarriageReturn
        default:
            switch special(at: i, in: b) {
            case .control, .c1: return .controlCharacter
            case .bidi: return .bidiControl
            case .quote, .backslash, .lineSeparator, nil: return nil
            }
        }
    }

    @inline(never)
    func rawCharacterError(_ i: Int, _ code: HausError.Code, _ place: String) -> HausError {
        switch code {
        case .loneCarriageReturn: fail(i, code, "a carriage return not followed by a line feed")
        case .bidiControl:
            fail(i, code, "a raw bidirectional control character, \(describeCharacter(at: i, in: b)), \(place)")
        default: fail(i, code, "a raw control character, \(describeCharacter(at: i, in: b)), \(place)")
        }
    }

    // ── the file ────────────────────────────────────────────────

    /// The whole text: a sequence of top-level values.
    mutating func file() throws(HausError) -> (values: [HausValue], syntax: FileNode?) {
        if let bad = firstInvalidUTF8(b) { throw fail(bad, .invalidUtf8, "invalid UTF-8") }
        if fileStart && hasPrefix(byteOrderMark, at: 0) { pos = byteOrderMark.count }
        if fileStart && hasPrefix("#haus".utf8, at: pos) {
            throw fail(
                pos, .versionDirective, "the file starts with a version directive: it needs a newer version of haus")
        }
        var values: [HausValue] = []
        var syntax = FileNode()
        var g = Gap()
        var last: Item?
        try whitespace(&g)
        while let c = byte(pos) {
            if c == ASCII.comma { throw expectedValue(pos) }
            let start = keep ? ItemStart(after: last, &g) : ItemStart()
            let (v, n) = try value()
            values.append(v)
            if let n {
                last = Item(start, node: n)
                syntax.items.append(last!)
            }
            try whitespace(&g)
            guard let c = byte(pos) else { break }
            guard c == ASCII.comma else { throw afterValue(v, open: 0, closer: nil) }
            pos += 1
            g.run = 0
            try whitespace(&g)
        }
        guard keep else { return (values, nil) }
        syntax.close(after: last, &g)
        return (values, syntax)
    }

    // ── whitespace and comments ─────────────────────────────────

    /// Skips whitespace and comments; when the parser keeps them, records
    /// them in `g`.
    mutating func whitespace(_ g: inout Gap) throws(HausError) {
        while let c = byte(pos) {
            switch c {
            case ASCII.space, ASCII.tab:
                pos += 1
            case ASCII.lf:
                pos += 1
                if keep { g.lineBreak() }
            case ASCII.cr:
                guard byte(pos + 1) == ASCII.lf else { throw rawCharacterError(pos, .loneCarriageReturn, "") }
                pos += 2
                if keep { g.lineBreak() }
            case ASCII.slash:
                let start = pos
                switch byte(pos + 1) {
                case ASCII.slash: pos = try lineComment(from: pos)
                case ASCII.star: pos = try blockComment(from: pos)
                default: throw fail(pos, .straySlash, "a '/' that doesn't start a comment")
                }
                if keep { g.add(withoutCarriageReturns(start, pos)) }
            default:
                return
            }
        }
    }

    /// The text from `from` to `to` with every CR LF read as LF.
    func withoutCarriageReturns(_ from: Int, _ to: Int) -> [UInt8] {
        b[from..<to].enumerated().filter { k, c in !(c == ASCII.cr && byte(from + k + 1) == ASCII.lf) }.map(\.1)
    }

    /// Reads a `//` comment from `i` and returns its end: the line break or
    /// the end of input.
    @inline(never)
    func lineComment(from i: Int) throws(HausError) -> Int {
        var i = i + 2
        while true {
            i = skip(b, from: i, to: b.count, until: .textStop)
            guard let c = byte(i), c != ASCII.lf, !(c == ASCII.cr && byte(i + 1) == ASCII.lf) else { return i }
            if let code = rawCharacterCode(at: i) { throw rawCharacterError(i, code, "in a comment") }
            i += 1
        }
    }

    /// Reads a nested `/* */` comment from `i` and returns its end.
    @inline(never)
    func blockComment(from start: Int) throws(HausError) -> Int {
        var i = start
        var depth = 0
        while true {
            i = skip(b, from: i, to: b.count, until: .commentStop)
            guard let c = byte(i) else { break }
            let next = byte(i + 1)
            if c == ASCII.slash && next == ASCII.star {
                depth += 1
                i += 2
            } else if c == ASCII.star && next == ASCII.slash {
                depth -= 1
                i += 2
                if depth == 0 { return i }
            } else {
                if c != ASCII.star && c != ASCII.slash, let code = rawCharacterCode(at: i) {
                    throw rawCharacterError(i, code, "in a comment")
                }
                i += 1
            }
        }
        throw fail(start, .unterminatedComment, "a /* comment that is never closed")
    }

    // ── values ──────────────────────────────────────────────────

    /// The value at `pos`, and its node when the parser keeps the syntax
    /// tree. Nesting doesn't recurse: the containers being read are kept on
    /// a stack of their own, so the depth limit, not the thread's stack,
    /// bounds the nesting (spec §7).
    mutating func value() throws(HausError) -> (HausValue, Node?) {
        var open: [Container] = []
        while true {
            var read = try begin(&open)
            while true {
                if let (v, n) = read {
                    guard !open.isEmpty else { return (v, n) }
                    try add(v, n, to: &open[open.count - 1])
                }
                // The next entry of the innermost container, or its end.
                guard let closed = try entry(&open) else { break }
                read = closed
            }
        }
    }

    /// Reads a value at `pos`: a scalar or a tag without payload, or nil
    /// after opening a container, whose entries come next.
    mutating func begin(_ open: inout [Container]) throws(HausError) -> (HausValue, Node?)? {
        switch byte(pos) {
        case ASCII.openBrace:
            try self.open(.record, depth: open.count, into: &open)
            return nil
        case ASCII.openBracket:
            try self.open(.array, depth: open.count, into: &open)
            return nil
        case let c? where isUpper(c):
            let start = pos
            let end = identEnd(b, from: start)
            if end - start > limits.maxStringLength {
                throw fail(start, .tagTooLong, "a tag longer than the limit of \(limits.maxStringLength) characters")
            }
            let tag = String(decoding: Bytes(rebasing: b[start..<end]), as: UTF8.self)
            // A payload starts on the tag's line (spec §5).
            var j = end
            while let c = byte(j), c == ASCII.space || c == ASCII.tab { j += 1 }
            switch byte(j) {
            case ASCII.openBrace:
                pos = j
                try self.open(.recordPayload(tag), depth: open.count, into: &open)
                return nil
            case ASCII.openParen:
                pos = j
                try self.open(.payload(tag), depth: open.count, into: &open)
                return nil
            default:
                pos = end
                let v = HausValue.variant(tag, [])
                return (v, keep ? Node(v) : nil)
            }
        default:
            return try scalar()
        }
    }

    /// Opens a container at `pos`, `depth` levels deep, and skips the
    /// whitespace after its opening bracket.
    mutating func open(_ kind: Container.Kind, depth: Int, into open: inout [Container]) throws(HausError) {
        if depth + 1 > limits.maxDepth {
            throw fail(pos, .nestingTooDeep, "nesting deeper than the limit of \(limits.maxDepth)")
        }
        open.append(Container(kind, at: pos, node: keep ? Node(.array([])) : nil))
        pos += 1
        try whitespace(&open[open.count - 1].gap)
    }

    /// At the start of an entry of the innermost container: its end, which
    /// closes it and gives its value, or nil once the entry's value comes
    /// next (after its key and colon, in a record).
    mutating func entry(_ open: inout [Container]) throws(HausError) -> (HausValue, Node?)? {
        let top = open.count - 1
        guard let c = byte(pos) else { throw unclosed(open[top].at, open[top].closer) }
        if c == open[top].closer {
            if case .payload = open[top].kind, open[top].values.isEmpty {
                throw fail(open[top].at, .emptyPayload, "empty parentheses after a tag: write the tag alone")
            }
            pos += 1
            return open.removeLast().close()
        }
        if open[top].isRecord {
            let keyAt = pos
            let key = try self.key()
            guard open[top].fields.isNew(key) else { throw duplicateKey(keyAt, key) }
            open[top].key = key
            if keep { open[top].start = ItemStart(after: open[top].last, &open[top].gap) }
            try whitespace(&open[top].gap)
            guard byte(pos) == ASCII.colon else { throw missingColon(after: key) }
            pos += 1
            open[top].gap.run = 0
            try whitespace(&open[top].gap)
        } else if keep {
            open[top].start = ItemStart(after: open[top].last, &open[top].gap)
        }
        return nil
    }

    /// Adds the value read to the container, and reads the comma or sees the
    /// closer after it.
    mutating func add(_ v: HausValue, _ n: Node?, to container: inout Container) throws(HausError) {
        container.add(v, n)
        try whitespace(&container.gap)
        switch byte(pos) {
        case ASCII.comma:
            pos += 1
            container.gap.run = 0
            try whitespace(&container.gap)
        case container.closer:
            break
        default:
            throw afterValue(v, open: container.at, closer: container.closer)
        }
    }

    /// What stands at `pos` after a value, where a comma or the closer (nil
    /// at the top level) must be. `open` is the opening bracket.
    @inline(never)
    func afterValue(_ v: HausValue, open: Int, closer: UInt8?) -> HausError {
        guard let c = byte(pos) else { return unclosed(open, closer!) }
        let expected = closer.map { "',' or '\(Character(Unicode.Scalar($0)))'" } ?? "','"
        let found = Character(Unicode.Scalar(c))
        switch c {
        case ASCII.closeBrace, ASCII.closeBracket, ASCII.closeParen:
            guard let closer else {
                return fail(pos, .unexpectedCloser, "a closing '\(found)' without an opening bracket")
            }
            return fail(pos, .unexpectedCloser, "expected '\(Character(Unicode.Scalar(closer)))', found '\(found)'")
        case ASCII.openParen, ASCII.openBrace:
            if case .variant(let tag, let args) = v, args.isEmpty {
                return fail(
                    pos, .payloadNewline,
                    "the payload of \(tag) must start on its line: expected \(expected), found '\(found)'",
                    expected: expected, found: "'\(found)'")
            }
        default: break
        }
        return failFound(pos, .missingComma, expected: expected)
    }

    /// A string, block string, number or byte string at `pos`.
    @inline(never)
    mutating func scalar() throws(HausError) -> (HausValue, Node?) {
        guard let c = byte(pos) else { throw expectedValue(pos) }
        switch c {
        case ASCII.quote:
            if hasPrefix(#"""""#.utf8, at: pos) { return try blockString() }
            let start = pos
            let v = HausValue.string(try basicString(tooLong: .stringTooLong))
            return (v, keep ? Node(v, text: Array(b[start..<pos])) : nil)
        case _ where isDigit(c) || c == ASCII.minus || c == ASCII.plus || c == ASCII.dot:
            let start = pos
            do throws(NumberError) {
                let (end, normalized) = try scanNumber(b, at: pos, limits: limits)
                pos = end
                let v = HausValue.number(HausNumber(normalized: normalized))
                return (v, keep ? Node(v, text: Array(b[start..<end])) : nil)
            } catch {
                throw fail(error.at, error.code, error.message)
            }
        case ASCII.x where byte(pos + 1) == ASCII.quote:
            return try bytes()
        case _ where isLower(c) || c == ASCII.underscore:
            let word = String(decoding: Bytes(rebasing: b[pos..<identEnd(b, from: pos)]), as: UTF8.self)
            switch word {
            case "null": throw fail(pos, .nullLiteral, "null is not a value: haus has no null")
            case "true", "false":
                throw fail(pos, .booleanLiteral, "\(word) is not a value: booleans are the tags True and False")
            default:
                throw fail(pos, .bareIdentifier, "a lowercase word, \(quoteForMessage(word)), where a value must be")
            }
        default:
            throw expectedValue(pos)
        }
    }

    @inline(never)
    func missingColon(after key: String) -> HausError {
        let found = describeCharacter(at: pos, in: b)
        return fail(
            pos, .missingColon, "expected ':' after the key \(quoteForMessage(key)), found \(found)", expected: "':'",
            found: found)
    }

    @inline(never)
    func duplicateKey(_ i: Int, _ key: String) -> HausError {
        fail(i, .duplicateKey, "the key \(quoteForMessage(key)) is already in this record")
    }

    /// A record key at `pos`: an identifier or a `"…"` string.
    @inline(never)
    mutating func key() throws(HausError) -> String {
        let c = b[pos]
        if isLower(c) || c == ASCII.underscore {
            let start = pos
            pos = identEnd(b, from: pos)
            if pos - start > limits.maxStringLength {
                throw fail(start, .keyTooLong, "a key longer than the limit of \(limits.maxStringLength) characters")
            }
            return String(decoding: Bytes(rebasing: b[start..<pos]), as: UTF8.self)
        }
        if c == ASCII.quote {
            if hasPrefix(#"""""#.utf8, at: pos) {
                throw fail(pos, .blockStringKey, #"a block string (""") can't be a key"#)
            }
            return try basicString(tooLong: .keyTooLong)
        }
        if isUpper(c) {
            let word = String(decoding: Bytes(rebasing: b[pos..<identEnd(b, from: pos)]), as: UTF8.self)
            throw fail(
                pos, .uppercaseKey,
                "the key \(quoteForMessage(word)) starts with a capital letter: quote it, or start it with a lowercase letter"
            )
        }
        throw failFound(pos, .expectedKey, expected: "a key")
    }

    // ── strings ─────────────────────────────────────────────────

    /// A `"…"` string at `pos`, and its value. `tooLong` is the error for a
    /// string over the length limit.
    @inline(never)
    mutating func basicString(tooLong: HausError.Code) throws(HausError) -> String {
        let start = pos
        var i = start + 1
        var decoded: [UInt8]?  // the value, once an escape needs decoding
        var plain = i  // the start of the current run of plain characters
        while true {
            guard let (at, special) = nextSpecial(b, from: i, to: b.count) else {
                throw fail(start, .unterminatedString, #"a string without its closing '"'"#)
            }
            switch special {
            case .quote:
                pos = at + 1
                let value =
                    decoded.map { String(decoding: $0 + b[plain..<at], as: UTF8.self) }
                    ?? String(decoding: Bytes(rebasing: b[plain..<at]), as: UTF8.self)
                try checkLength(value, start, tooLong)
                return value
            case .backslash:
                decoded = (decoded ?? []) + b[plain..<at]
                i = try escape(at: at, into: &decoded!)
                plain = i
            case .lineSeparator:
                i = at + special.width
            case .control(ASCII.lf):
                throw fail(at, .stringLineBreak, #"a line break in a "…" string: write \n, or use a """ block string"#)
            case .control, .c1:
                // A carriage return in a "…" string is a control character, also
                // directly before a line feed (spec §4, "Which error").
                throw rawCharacterError(at, .controlCharacter, "in a string: write it as an escape")
            case .bidi:
                throw rawCharacterError(at, .bidiControl, "in a string: write it as an escape")
            }
        }
    }

    /// Fails with `code` if the string that starts at `start` is longer than the limit.
    func checkLength(_ value: String, _ start: Int, _ code: HausError.Code) throws(HausError) {
        guard value.utf8.count > limits.maxStringLength else { return }
        let n = value.unicodeScalars.count
        if n > limits.maxStringLength {
            throw fail(start, code, "a string of \(n) characters, more than the limit of \(limits.maxStringLength)")
        }
    }

    /// Decodes the escape whose backslash is at `i`, appends its character to
    /// `out`, and returns the offset after it.
    func escape(at i: Int, into out: inout [UInt8]) throws(HausError) -> Int {
        guard let c = byte(i + 1) else { throw fail(i, .invalidEscape, "a backslash at the end of the input") }
        switch c {
        case ASCII.quote, ASCII.backslash: out.append(c)
        case ASCII.n: out.append(ASCII.lf)
        case ASCII.r: out.append(ASCII.cr)
        case ASCII.t: out.append(ASCII.tab)
        case ASCII.u:
            guard byte(i + 2) == ASCII.openBrace else {
                throw fail(i, .invalidUnicodeEscape, #"a \u escape is written with braces: \u{1F600}"#)
            }
            let from = i + 3
            var k = from
            var scalar: UInt32 = 0
            while k - from < 7, let d = byte(k).flatMap(hexValue) {
                scalar = scalar << 4 | UInt32(d)
                k += 1
            }
            guard k > from, k - from <= 6, byte(k) == ASCII.closeBrace else {
                throw fail(i, .invalidUnicodeEscape, #"a \u{…} escape needs 1 to 6 hex digits and a closing '}'"#)
            }
            guard let s = Unicode.Scalar(scalar) else {
                let digits = String(decoding: Bytes(rebasing: b[from..<k]), as: UTF8.self)
                throw fail(i, .invalidUnicodeEscape, #"\u{\#(digits)} is not a Unicode scalar value"#)
            }
            out += UTF8.encode(s)!
            return k + 1
        default:
            let next = String(decoding: Bytes(rebasing: b[i..<(i + 1 + characterLength(at: i + 1))]), as: UTF8.self)
            throw fail(
                i, .invalidEscape,
                #"\#(quoteForMessage(next)) doesn't start an escape: use \", \\, \n, \r, \t or \u{…}"#)
        }
        return i + 2
    }

    /// The length in UTF-8 of the character at `i`.
    func characterLength(at i: Int) -> Int {
        var n = 1
        while i + n < b.count && isContinuation(b[i + n]) { n += 1 }
        return n
    }

    /// A `"""` block string at `pos` (spec §4).
    @inline(never)
    mutating func blockString() throws(HausError) -> (HausValue, Node?) {
        let start = pos
        var i = start + 3
        while let c = byte(i), c == ASCII.space || c == ASCII.tab { i += 1 }
        switch byte(i) {
        case nil:
            // Nothing after the opening: no line break, at the block string.
            throw fail(start, .blockStringOpening, #"the opening """ must be followed by a line break"#)
        case ASCII.lf:
            i += 1
        case ASCII.cr where byte(i + 1) == ASCII.lf:
            i += 2
        default:
            throw fail(i, .blockStringOpening, #"text after the opening """: the content starts on the next line"#)
        }
        // The closing """, skipping escaped characters; then the lines before it.
        var end = i
        while end < b.count && !hasPrefix(#"""""#.utf8, at: end) {
            end += b[end] == ASCII.backslash ? 2 : 1
        }
        guard end < b.count else {
            throw fail(start, .unterminatedBlockString, #"a block string without its closing """"#)
        }
        var lines = self.lines(from: i, to: end)
        let closing = lines.removeLast()
        guard b[closing].allSatisfy({ $0 == ASCII.space || $0 == ASCII.tab }) else {
            throw fail(end, .blockStringClosing, #"the closing """ must stand on a line of its own"#)
        }
        pos = end + 3
        // Line by line: the indent, then the content in order, raw characters
        // and escapes (spec §4, "Which error": the same order in every binding).
        let indent = b[closing]
        var out: [UInt8] = []
        for (k, line) in lines.enumerated() {
            if k > 0 { out.append(ASCII.lf) }
            if b[line].starts(with: indent) {
                try blockLine(from: line.lowerBound + indent.count, to: line.upperBound, into: &out)
            } else if !b[line].allSatisfy({ $0 == ASCII.space || $0 == ASCII.tab }) {
                throw fail(
                    line.lowerBound, .blockStringIndent, #"a line of a block string indented less than its closing """"#
                )
            }
        }
        let value = String(decoding: out, as: UTF8.self)
        try checkLength(value, start, .stringTooLong)
        let v = HausValue.string(value)
        return (v, keep ? Node(v) : nil)
    }

    /// The lines from `from` to `to`, without their line breaks.
    func lines(from: Int, to: Int) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var at = from
        while let lf = b[at..<to].firstIndex(of: ASCII.lf) {
            lines.append(at..<(lf > at && b[lf - 1] == ASCII.cr ? lf - 1 : lf))
            at = lf + 1
        }
        lines.append(at..<to)
        return lines
    }

    /// Decodes the content of one line of a block string, after its indent.
    func blockLine(from: Int, to: Int, into out: inout [UInt8]) throws(HausError) {
        var j = from
        while j < to {
            let run = skip(b, from: j, to: to, until: .blockStringStop)
            out += b[j..<run]
            j = run
            guard j < to else { return }
            if b[j] == ASCII.backslash {
                j = try escape(at: j, into: &out)
                if j > to { throw fail(j, .invalidEscape, "an escape across a line break") }
                continue
            }
            if let code = rawCharacterCode(at: j) {
                // A carriage return that isn't part of a line break is a
                // control character here (spec §4, "Which error").
                let code = code == .loneCarriageReturn ? .controlCharacter : code
                throw rawCharacterError(j, code, "in a block string: write it as an escape")
            }
            out.append(b[j])
            j += 1
        }
    }

    /// A byte string `x"…"` at `pos`.
    @inline(never)
    mutating func bytes() throws(HausError) -> (HausValue, Node?) {
        let start = pos
        var i = start + 2
        var out: [UInt8] = []
        while true {
            while let c = byte(i), c == ASCII.space || c == ASCII.tab { i += 1 }
            guard let c = byte(i) else {
                throw fail(start, .unterminatedBytes, #"a byte string without its closing '"'"#)
            }
            if c == ASCII.quote { break }
            guard let high = hexValue(c) else {
                throw fail(
                    i, .bytesNotHex,
                    "\(describeCharacter(at: i, in: b)) in a byte string: only hex digits, spaces and tabs")
            }
            guard let d = byte(i + 1) else {
                throw fail(start, .unterminatedBytes, #"a byte string without its closing '"'"#)
            }
            guard let low = hexValue(d) else {
                throw fail(i, .bytesOddDigits, "a byte with one hex digit: write two hex digits per byte")
            }
            out.append(high << 4 | low)
            i += 2
        }
        pos = i + 1
        if i - start - 2 > limits.maxStringLength {
            throw fail(
                start, .stringTooLong,
                "a byte string of \(i - start - 2) characters, more than the limit of \(limits.maxStringLength)")
        }
        let v = HausValue.bytes(out)
        return (v, keep ? Node(v, text: Array(b[start..<pos])) : nil)
    }
}

/// A record, array or payload being read.
struct Container {
    enum Kind {
        case record
        case array
        /// `Tag { … }`
        case recordPayload(String)
        /// `Tag( … )`
        case payload(String)
    }

    let kind: Kind
    /// Where its opening bracket is.
    let at: Int
    /// Its node, when the parser keeps the syntax tree.
    let node: Node?
    /// The elements of an array or the arguments of a payload.
    var values: [HausValue] = []
    /// The fields of a record or record payload.
    var fields = RecordBuilder()
    /// The key of the field whose value is being read.
    var key = ""
    /// The start of the item being read, when the parser keeps the syntax tree.
    var start = ItemStart()
    var gap = Gap()
    var last: Item?

    init(_ kind: Kind, at: Int, node: Node?) {
        self.kind = kind
        self.at = at
        self.node = node
    }

    var isRecord: Bool {
        switch kind {
        case .record, .recordPayload: true
        case .array, .payload: false
        }
    }

    var closer: UInt8 {
        switch kind {
        case .record, .recordPayload: ASCII.closeBrace
        case .array: ASCII.closeBracket
        case .payload: ASCII.closeParen
        }
    }

    /// Adds the value of the entry being read, and its node.
    mutating func add(_ v: HausValue, _ n: Node?) {
        if isRecord {
            fields.append(key, v)
        } else {
            values.append(v)
        }
        guard let n, let node else { return }
        last = isRecord ? Item(field: key, start, n, &gap) : Item(start, node: n)
        node.items.append(last!)
    }

    /// Its value and node, once its closer is read.
    consuming func close() -> (HausValue, Node?) {
        let v: HausValue =
            switch kind {
            case .record: .record(fields.record)
            case .array: .array(values)
            case .recordPayload(let tag): .variant(tag, [.record(fields.record)])
            case .payload(let tag): .variant(tag, values)
            }
        guard let node else { return (v, nil) }
        node.value = v
        node.close(after: last, &gap)
        switch kind {
        case .recordPayload:
            node.form = .braces
        case .payload:
            node.form = .parens
            if values.count == 1, case .record = values[0] { return (v, mergeRecordArgument(node)) }
        case .record, .array:
            break
        }
        return (v, node)
    }
}

/// The character at `i` for a message: `'x'`, `U+0007`, or `end of input`.
func describeCharacter(at i: Int, in b: Bytes) -> String {
    guard i < b.count else { return "end of input" }
    let c = scalar(at: i, in: b)
    if needsEscape(c) || c == 0x20 || c == 0xFEFF { return codePointName(c) }
    return "'\(Character(Unicode.Scalar(c)!))'"
}
