/// Reads the top-level values of a file or stream (spec §6) from chunks of
/// UTF-8, one value at a time: whatever the chunks, it gives what parsing
/// the whole input gives. Memory stays bounded by the largest value
/// (``Limits/maxValueLength``). Errors carry the line and column in the whole
/// input, and the same codes as when the whole input is parsed at once.
///
/// ```swift
/// var reader = StreamReader(strict: true)
/// for try await chunk in socket {
///     reader.push(chunk)
///     while let value = try reader.next() { handle(value) }
/// }
/// reader.finish()
/// while let value = try reader.next() { handle(value) } // stream-truncated if the last value has no comma
/// ```
///
/// ``HausValues`` does the same for an `AsyncSequence` of chunks.
public struct StreamReader: Sendable {
    private let limits: Limits
    /// Requires a comma after the last value (spec §6).
    public let strict: Bool
    /// The error of the limits, or the first error read: sticky.
    private var failure: HausError?
    /// The input from the start of the current value on.
    private var buffer: [UInt8] = []
    /// Where the current value starts in `buffer`.
    private var start = 0
    /// How far the scanner has read.
    private var scanned = 0
    /// No more input comes.
    private var ended = false
    /// The current value is the first of the stream.
    private var first = true
    /// The characters of the current value so far.
    private var characters = 0
    /// The position of `buffer[start]` in the whole input.
    private var line = 1
    private var column = 1
    private var scan = ScanState()

    /// A reader with these limits; with `strict`, a stream must end with a
    /// comma after its last value, so that one cut off after a
    /// complete-looking value is reported (`stream-truncated`) instead of
    /// read as valid.
    public init(limits: Limits = Limits(), strict: Bool = false) {
        self.limits = limits
        self.strict = strict
        do {
            _ = try limits.checked()
        } catch {
            failure = error
        }
    }

    /// Adds a chunk of UTF-8 to the input.
    public mutating func push(_ chunk: some Collection<UInt8>) {
        precondition(!ended, "StreamReader: push after finish")
        compact()
        buffer += chunk
    }

    /// Adds a chunk of text to the input.
    public mutating func push(_ chunk: String) {
        push(chunk.utf8)
    }

    /// Ends the input: ``next()`` then reads the last value, which in strict
    /// mode must be followed by a comma.
    public mutating func finish() {
        ended = true
    }

    /// The next value; nil if it needs more input, or after ``finish()`` if
    /// there are no more values. After an error, it throws that error again.
    public mutating func next() throws(HausError) -> HausValue? {
        if let failure { throw failure }
        do {
            return try read()
        } catch {
            failure = error
            throw error
        }
    }

    /// Drops the input before the current value once it is half the buffer.
    private mutating func compact() {
        guard start > 0 && start >= buffer.count / 2 else { return }
        buffer.removeFirst(start)
        scanned -= start
        start = 0
    }

    /// The next value, or nil if more input is needed or there is none.
    private mutating func read() throws(HausError) -> HausValue? {
        while true {
            if let comma = try findComma() {
                let value = try parse(to: comma + 1)
                advance(to: comma + 1)
                // Only whitespace and comments: impossible before a comma, but harmless.
                if let value { return value }
                continue
            }
            guard ended, start < buffer.count else { return nil }
            // The rest of the input, after the last comma.
            let (line, column) = (self.line, self.column)
            let value = try parse(to: buffer.count)
            advance(to: buffer.count)
            if value != nil && strict {
                throw HausError(
                    .streamTruncated, "the stream ends without a comma after its last value, which may be cut off",
                    position: SourcePosition(line: line, column: column), expected: "','", found: "end of input")
            }
            return value
        }
    }

    /// Parses one value's text, up to `end`: whitespace and comments, at most
    /// one value, and the comma after it, if any. Nil if there is no value.
    private func parse(to end: Int) throws(HausError) -> HausValue? {
        try buffer[start..<end].withUnsafeBufferPointer { (b) throws(HausError) in
            var p = Parser(b, limits: limits, keep: false)
            p.fileStart = first
            (p.line, p.column) = (line, column)
            // Two values would need a comma between them, which ends the text.
            return try p.file().values.first
        }
    }

    /// Moves past a value whose text ends at `end`, keeping the position.
    private mutating func advance(to end: Int) {
        let text = buffer[start..<end]
        if let lf = text.lastIndex(of: ASCII.lf) {
            line += text.count { $0 == ASCII.lf }
            column = 1 + codePoints(in: buffer[(lf + 1)..<end])
        } else {
            column += codePoints(in: text)
        }
        start = end
        scanned = max(scanned, end)
        first = false
        characters = 0
        scan = ScanState()
    }

    /// The offset of the next top-level comma, or nil if more input is needed
    /// (or there is none). It fails when the value is longer than the limit.
    private mutating func findComma() throws(HausError) -> Int? {
        if first && start == 0 && scanned == 0 && buffer.starts(with: byteOrderMark) {
            scanned = byteOrderMark.count  // the byte order mark is not part of the first value
        }
        var i = scanned
        defer { scanned = i }
        while i < buffer.count {
            // Keep up to three bytes of lookahead.
            if !ended && i + 3 > buffer.count { break }
            let c = buffer[i]
            if !isContinuation(c) { characters += 1 }
            let skipped = scan.step(c, at: i, in: buffer)
            if skipped < 0 {
                characters -= 1
                return i
            }
            characters += skipped
            i += 1 + skipped
            if characters > limits.maxValueLength {
                // At the first character counted: after the previous comma, or the
                // first of the stream, after a byte order mark (spec §7).
                let bom = first && start == 0 && buffer.starts(with: byteOrderMark) ? 1 : 0
                throw HausError(
                    .valueTooLong, "a top-level value of more than \(limits.maxValueLength) characters",
                    position: SourcePosition(line: line, column: column + bom))
            }
        }
        return nil
    }
}

/// What the scanner that finds the top-level commas is inside of.
private enum ScanMode {
    case code, lineComment, blockComment, string, blockString, bytes
}

/// The state of the scanner that finds the top-level commas. It only needs
/// to know where strings, comments and brackets are; the parser checks
/// everything else. On valid input it agrees with the parser, and on
/// invalid input it never ends a construct before the parser would, so the
/// text it hands the parser holds the first error.
private struct ScanState {
    var mode = ScanMode.code
    /// Open brackets.
    var depth = 0
    /// The nesting of block comments.
    var comments = 0
    /// In a block string: the line so far is spaces and tabs.
    var blanks = false
    /// In a block string: still on the line of the opening `"""`.
    var opening = false
    /// The previous byte is `[A-Za-z0-9_]`.
    var word = false

    /// Reads the byte `c` at `i`: -1 if it is a top-level comma, otherwise
    /// how many of the bytes after it it read too (all ASCII).
    mutating func step(_ c: UInt8, at i: Int, in b: [UInt8]) -> Int {
        let next = i + 1 < b.count ? b[i + 1] : nil
        let tripleQuote = next == ASCII.quote && i + 2 < b.count && b[i + 2] == ASCII.quote
        switch mode {
        case .code:
            var word = classOf(c).contains(.ident)
            defer { self.word = word }
            switch c {
            case ASCII.comma where depth == 0: return -1
            case ASCII.openBrace, ASCII.openBracket, ASCII.openParen: depth += 1
            case ASCII.closeBrace, ASCII.closeBracket, ASCII.closeParen: depth = max(depth - 1, 0)
            case ASCII.slash where next == ASCII.slash:
                mode = .lineComment
                return 1
            case ASCII.slash where next == ASCII.star:
                (mode, comments) = (.blockComment, 1)
                return 1
            case ASCII.quote where tripleQuote:
                (mode, blanks, opening) = (.blockString, false, true)
                return 2
            case ASCII.quote:
                mode = .string
            case ASCII.x where !self.word && next == ASCII.quote:
                mode = .bytes
                word = false
                return 1
            default: break
            }
        case .lineComment:
            if c == ASCII.lf { mode = .code }
        case .blockComment:
            if c == ASCII.slash && next == ASCII.star {
                comments += 1
                return 1
            }
            if c == ASCII.star && next == ASCII.slash {
                comments -= 1
                if comments == 0 { (mode, word) = (.code, false) }
                return 1
            }
        case .string:
            switch c {
            case ASCII.backslash where next == ASCII.quote || next == ASCII.backslash: return 1
            case ASCII.quote, ASCII.lf: (mode, word) = (.code, false)
            default: break
            }
        case .blockString:
            switch c {
            case ASCII.lf: (blanks, opening) = (true, false)
            case ASCII.space, ASCII.tab: break
            case ASCII.backslash:
                blanks = false
                if next == ASCII.quote || next == ASCII.backslash { return 1 }
            case ASCII.quote where tripleQuote && blanks && !opening:
                (mode, word) = (.code, false)
                return 2
            default:
                blanks = false
            }
        case .bytes:
            if c == ASCII.quote || c == ASCII.lf { (mode, word) = (.code, false) }
        }
        return 0
    }
}

/// The values of a stream of UTF-8 chunks, read by a ``StreamReader``.
///
/// ```swift
/// for try await value in HausValues(chunks, strict: true) { handle(value) }
/// ```
public struct HausValues<Chunks: AsyncSequence>: AsyncSequence
where Chunks.Element: Collection, Chunks.Element.Element == UInt8 {
    public typealias Element = HausValue

    let chunks: Chunks
    let limits: Limits
    let strict: Bool

    public init(_ chunks: Chunks, limits: Limits = Limits(), strict: Bool = false) {
        self.chunks = chunks
        self.limits = limits
        self.strict = strict
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks.makeAsyncIterator(), reader: StreamReader(limits: limits, strict: strict))
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: Chunks.AsyncIterator
        var reader: StreamReader
        var ended = false

        public mutating func next() async throws -> HausValue? {
            while true {
                if let value = try reader.next() { return value }
                if ended { return nil }
                if let chunk = try await chunks.next() {
                    reader.push(chunk)
                } else {
                    reader.finish()
                    ended = true
                }
            }
        }
    }
}

extension HausValues: Sendable where Chunks: Sendable {}
