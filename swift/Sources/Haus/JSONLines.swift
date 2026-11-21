// JSON Lines (spec §16, "Streams"): one JSON text per value, each followed
// by a line feed. Readers accept a missing line feed after the last value
// and CR LF line ends; an empty line is an error. A byte order mark is
// ignored only at the start of the stream.

/// Reads JSON Lines (spec §16, "Streams") from chunks of UTF-8, one line at
/// a time: self-describing JSON (an envelope per line, §16.2) or the JSON
/// import (§16.1). It holds at most one line; JSON Lines has no limit on a
/// line's length, only the limits of the value read from it.
///
/// ```swift
/// var reader = JSONLinesReader(.selfDescribing)
/// for try await chunk in socket {
///     reader.push(chunk)
///     while let value = try reader.next() { handle(value) }
/// }
/// reader.finish()
/// while let value = try reader.next() { handle(value) } // the last line may lack its line feed
/// ```
///
/// An error in a line's text has its line in the whole stream; an error
/// with a path starts with the line's index: `$[3]._value._num`.
public struct JSONLinesReader: Sendable {
    /// How each line is read.
    public enum Form: Sendable {
        /// Self-describing JSON (§16.2): an envelope per line.
        case selfDescribing
        /// The JSON import (§16.1).
        case `import`
    }

    /// Reads one line: its text, the limits, and whether it is the first.
    typealias Convert = @Sendable (Bytes, Limits, _ first: Bool) throws(HausError) -> HausValue

    private let convert: Convert
    private let limits: Limits
    /// The error of the limits, or the first error read: sticky.
    private var failure: HausError?
    private var buffer: [UInt8] = []
    /// Where the current line starts in `buffer`.
    private var start = 0
    /// How far `buffer` has been searched for the current line's line feed.
    private var scanned = 0
    /// The index of the current line.
    private var line = 0
    /// No more input comes.
    private var ended = false

    /// A reader of `form`, with these limits for each value.
    public init(_ form: Form, limits: Limits = Limits()) {
        self.init(limits: limits, convert: Self.converter(form))
    }

    init(limits: Limits, convert: @escaping Convert) {
        self.limits = limits
        self.convert = convert
        do {
            _ = try limits.checked()
        } catch {
            failure = error
        }
    }

    static func converter(_ form: Form) -> Convert {
        switch form {
        case .selfDescribing:
            { (b, limits, first) throws(HausError) in try readHausJSON(b, limits: limits, skipBOM: first) }
        case .import:
            { (b, limits, first) throws(HausError) in try readJSON(b, limits: limits, mode: .import, skipBOM: first) }
        }
    }

    /// Adds a chunk of UTF-8 to the input.
    public mutating func push(_ chunk: some Collection<UInt8>) {
        precondition(!ended, "JSONLinesReader: push after finish")
        if start > 0 {
            buffer.removeFirst(start)
            scanned -= start
            start = 0
        }
        buffer += chunk
    }

    /// Adds a chunk of text to the input.
    public mutating func push(_ chunk: String) { push(chunk.utf8) }

    /// Ends the input: ``next()`` then reads the last line, which needs no
    /// line feed.
    public mutating func finish() { ended = true }

    /// The next value; nil if it needs more input, or after ``finish()`` if
    /// there are no more lines. After an error, it throws that error again.
    public mutating func next() throws(HausError) -> HausValue? {
        if let failure { throw failure }
        do {
            return try read()
        } catch {
            failure = error
            throw error
        }
    }

    private mutating func read() throws(HausError) -> HausValue? {
        let lineFeed = buffer[scanned...].firstIndex(of: ASCII.lf)
        guard let end = lineFeed ?? (ended ? buffer.count : nil) else {
            scanned = buffer.count
            return nil
        }
        guard end > start || lineFeed != nil else { return nil }  // the end, after the last line feed
        let n = line
        var text = buffer[start..<end]
        if text.last == ASCII.cr { text = text.dropLast() }
        start = lineFeed.map { $0 + 1 } ?? end
        scanned = start
        line += 1
        guard !text.isEmpty else {
            throw HausError(
                .jsonSyntax, "an empty line in JSON Lines", position: SourcePosition(line: n + 1, column: 1),
                expected: "a JSON value", found: "end of line")
        }
        do {
            return try withBytes(text) { (b) throws(HausError) in try convert(b, limits, n == 0) }
        } catch {
            throw error.inLine(n)
        }
    }

    /// Every value of a whole text, or the first error.
    mutating func readAll(_ bytes: some Collection<UInt8>) throws(HausError) -> [HausValue] {
        push(bytes)
        finish()
        var values: [HausValue] = []
        while let value = try next() { values.append(value) }
        return values
    }
}

extension HausError {
    /// The error of line `n` (counted from 0) of a stream: its position in
    /// the whole stream, or its path starting with the line's index, `$[3]`.
    func inLine(_ n: Int) -> HausError {
        if let position {
            return HausError(
                code, message, position: SourcePosition(line: position.line + n, column: position.column),
                expected: expected, found: found)
        }
        return HausError(code, message, path: "$[\(n)]" + (path?.dropFirst() ?? ""), expected: expected, found: found)
    }
}

/// Reads a whole text of self-describing JSON Lines (spec §16): every
/// value, or the first error. The value limit doesn't apply, as the text is
/// held whole already (spec §7).
public func fromHausJSONLines(_ text: String, limits: Limits = Limits()) throws(HausError) -> [HausValue] {
    try fromHausJSONLines(bytes: text.utf8, limits: limits)
}

/// Reads a whole text of self-describing JSON Lines in UTF-8. See
/// ``fromHausJSONLines(_:limits:)``.
public func fromHausJSONLines(bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(HausError)
    -> [HausValue]
{
    var reader = JSONLinesReader(limits: limits, convert: JSONLinesReader.converter(.selfDescribing))
    return try reader.readAll(bytes)
}

/// Reads a whole text of JSON Lines with the JSON import (spec §16.1).
public func importJSONLines(_ text: String, limits: Limits = Limits()) throws(HausError) -> [HausValue] {
    try importJSONLines(bytes: text.utf8, limits: limits)
}

/// Reads a whole text of JSON Lines in UTF-8 with the JSON import.
public func importJSONLines(bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(HausError)
    -> [HausValue]
{
    var reader = JSONLinesReader(limits: limits, convert: JSONLinesReader.converter(.import))
    return try reader.readAll(bytes)
}

/// Writes values as self-describing JSON Lines (spec §16): an envelope per
/// value, each followed by a line feed. An error names the value's index in
/// its path, `$[3]`.
public func toHausJSONLines(_ values: [HausValue], limits: Limits = Limits()) throws(HausError) -> String {
    var out: [UInt8] = []
    for (i, value) in values.enumerated() {
        do {
            try appendHausJSON(value, limits: limits, to: &out)
        } catch {
            throw error.inLine(i)
        }
        out.append(ASCII.lf)
    }
    return String(decoding: out, as: UTF8.self)
}
