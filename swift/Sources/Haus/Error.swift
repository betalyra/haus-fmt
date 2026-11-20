/// An error reported by this package. Every error has a ``Code`` from the
/// catalogue (spec §17); an error in text has a ``position`` (spec §8), one in
/// a value written from code a ``path`` (`$.items[2]`).
///
/// ```swift
/// do {
///     _ = try parse("{ ok: true }")
/// } catch {
///     print(error.code, error.position!) // booleanLiteral 1:7
/// }
/// ```
public struct HausError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The members, behind one reference: the parser and the writers throw
    /// errors through every level of nesting, and a small error keeps their
    /// stack frames small.
    private final class Details: Sendable {
        let code: Code
        let message: String
        let position: SourcePosition?
        let path: String?
        let expected: String?
        let found: String?

        init(
            _ code: Code, _ message: String, _ position: SourcePosition?, _ path: String?, _ expected: String?,
            _ found: String?
        ) {
            self.code = code
            self.message = message
            self.position = position
            self.path = path
            self.expected = expected
            self.found = found
        }

        var members: [AnyHashable?] { [code, message, position, path, expected, found] }
    }

    private let details: Details

    /// Which mistake this is: the same in every binding.
    public var code: Code { details.code }
    /// What went wrong, for people, without the position. Messages differ
    /// between bindings; codes don't.
    public var message: String { details.message }
    /// Where the error is in the text, for an error in text.
    public var position: SourcePosition? { details.position }
    /// The place in the value, for an error in a value (spec §15): `$.items[2].price`.
    public var path: String? { details.path }
    /// What should be there, where that is natural: `"','"`.
    public var expected: String? { details.expected }
    /// What is there instead, where that is natural: `"'{'"`, `"end of input"`.
    public var found: String? { details.found }

    init(
        _ code: Code, _ message: String, position: SourcePosition? = nil, path: String? = nil,
        expected: String? = nil, found: String? = nil
    ) {
        details = Details(code, message, position, path, expected, found)
    }

    public static func == (a: HausError, b: HausError) -> Bool { a.details.members == b.details.members }
    public func hash(into hasher: inout Hasher) { hasher.combine(details.members) }

    /// A concrete fix: the catalogue's fix for the code.
    public var hint: String { code.hint }

    /// The documentation of the code.
    public var docs: String { "https://haus-fmt.org/docs/errors#\(code.rawValue)" }

    /// `line:column: message [code]`, leaving out what the error doesn't have.
    public var description: String {
        let place = position.map { "\($0.line):\($0.column): " } ?? path.map { "\($0): " } ?? ""
        return "\(place)\(message) [\(code.rawValue)]"
    }

    /// The error's JSON form (spec §17): code, message, line, column, path,
    /// expected, found, hint and docs, leaving out members that don't apply.
    public var json: String {
        let strings: [(String, String?)] = [("path", path), ("expected", expected), ("found", found), ("hint", hint)]
        var members = [("code", jsonString(code.rawValue)), ("message", jsonString(message))]
        if let position {
            members += [("line", String(position.line)), ("column", String(position.column))]
        }
        members += strings.compactMap { name, value in value.map { (name, jsonString($0)) } }
        members.append(("docs", jsonString(docs)))
        return "{" + members.map { "\(jsonString($0)):\($1)" }.joined(separator: ",") + "}"
    }
}

/// A place in text (spec §8): a 1-based line, and a 1-based column counted in
/// code points.
public struct SourcePosition: Sendable, Hashable, CustomStringConvertible {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "\(line):\(column)" }
}

/// The position of byte offset `i` of valid UTF-8 text whose first byte is
/// at `start` (spec §8).
func sourcePosition(of i: Int, in b: Bytes, from start: SourcePosition = SourcePosition(line: 1, column: 1))
    -> SourcePosition
{
    let i = min(i, b.count)
    var lines = 0
    var lineStart = 0
    for k in 0..<i where b[k] == ASCII.lf {
        lines += 1
        lineStart = k + 1
    }
    let column = codePoints(in: b[lineStart..<i]) + 1
    return SourcePosition(line: start.line + lines, column: lines == 0 ? start.column + column - 1 : column)
}

// ── text for messages ───────────────────────────────────────────

/// `text` quoted for an error message: quotes and backslashes escaped,
/// control, bidi and line-separator characters as `\u{…}`, and cut to 40
/// characters (spec §9).
func quoteForMessage(_ text: String) -> String {
    let maxCharacters = 40
    var out = "\""
    for (n, c) in text.unicodeScalars.enumerated() {
        if n == maxCharacters {
            out += "…"
            break
        }
        switch c {
        case "\"", "\\": out += "\\\(c)"
        case _ where needsEscape(c.value): out += unicodeEscape(c.value)
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}

/// `\u{…}` with uppercase hex digits and no leading zeros (spec §12).
func unicodeEscape(_ c: UInt32) -> String {
    "\\u{" + String(c, radix: 16, uppercase: true) + "}"
}

/// `U+0007`: a code point as people write it, at least four hex digits.
func codePointName(_ c: UInt32) -> String {
    let hex = String(c, radix: 16, uppercase: true)
    return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
}

/// A JSON string, with the characters writers never write raw escaped
/// (spec §16).
func jsonString(_ s: String) -> String {
    var out: [UInt8] = []
    appendJSONString(s, to: &out)
    return String(decoding: out, as: UTF8.self)
}
