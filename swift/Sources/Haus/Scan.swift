// Scanning bytes, for the parser and the writers: the classes of bytes, the
// characters a string can't hold raw and how to find them, identifiers,
// UTF-8. Plain ASCII string text is skipped eight bytes at a time: a word of
// eight bytes is tested for a byte of interest with a few operations.

/// The bytes being read: the parser's input, or the UTF-8 of a string being written.
typealias Bytes = UnsafeBufferPointer<UInt8>

/// The ASCII bytes of the syntax.
enum ASCII {
    static let tab = UInt8(ascii: "\t")
    static let lf = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let quote = UInt8(ascii: "\"")
    static let hash = UInt8(ascii: "#")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let star = UInt8(ascii: "*")
    static let plus = UInt8(ascii: "+")
    static let comma = UInt8(ascii: ",")
    static let minus = UInt8(ascii: "-")
    static let dot = UInt8(ascii: ".")
    static let slash = UInt8(ascii: "/")
    static let zero = UInt8(ascii: "0")
    static let one = UInt8(ascii: "1")
    static let colon = UInt8(ascii: ":")
    static let B = UInt8(ascii: "B")
    static let E = UInt8(ascii: "E")
    static let X = UInt8(ascii: "X")
    static let openBracket = UInt8(ascii: "[")
    static let backslash = UInt8(ascii: "\\")
    static let closeBracket = UInt8(ascii: "]")
    static let underscore = UInt8(ascii: "_")
    static let b = UInt8(ascii: "b")
    static let e = UInt8(ascii: "e")
    static let n = UInt8(ascii: "n")
    static let r = UInt8(ascii: "r")
    static let t = UInt8(ascii: "t")
    static let u = UInt8(ascii: "u")
    static let x = UInt8(ascii: "x")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
}

/// The byte order mark, U+FEFF, in UTF-8.
let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

// ── characters a string can't hold raw (spec §4) ────────────────

/// The C0 control characters, U+0000–U+001F: one byte each in UTF-8.
let c0Controls: ClosedRange<UInt32> = 0x00...0x1F
/// DEL, U+007F: one byte.
let del: UInt32 = 0x7F
/// The C1 control characters, U+0080–U+009F: `C2 80`–`C2 9F` in UTF-8.
let c1Controls: ClosedRange<UInt32> = 0x80...0x9F
/// The line and paragraph separators, U+2028 and U+2029: `E2 80 A8` and
/// `E2 80 A9`. The parser takes them raw; the writers escape them.
let lineSeparators: ClosedRange<UInt32> = 0x2028...0x2029
/// The bidirectional embeddings and overrides, U+202A–U+202E: `E2 80 AA`–`E2 80 AE`.
let bidiEmbeddings: ClosedRange<UInt32> = 0x202A...0x202E
/// The bidirectional isolates, U+2066–U+2069: `E2 81 A6`–`E2 81 A9`.
let bidiIsolates: ClosedRange<UInt32> = 0x2066...0x2069

/// A raw control character: C0, DEL or C1 (spec §4).
func isControl(_ c: UInt32) -> Bool {
    c0Controls.contains(c) || c == del || c1Controls.contains(c)
}

/// A bidirectional control: never raw in the input (spec §4).
func isBidi(_ c: UInt32) -> Bool {
    bidiEmbeddings.contains(c) || bidiIsolates.contains(c)
}

/// A character the writers never write raw in a string: a control or bidi
/// character, or a line or paragraph separator (spec §11, §12).
func needsEscape(_ c: UInt32) -> Bool {
    isControl(c) || isBidi(c) || lineSeparators.contains(c)
}

/// The first byte of the UTF-8 of a character below U+10000.
private func leadByte(_ c: UInt32) -> UInt8 {
    switch c {
    case ..<0x80: UInt8(c)
    case ..<0x800: UInt8(0xC0 | c >> 6)
    default: UInt8(0xE0 | c >> 12)
    }
}

/// A character that ends a run of plain string text.
enum Special: Equatable {
    /// `"`, which closes a string.
    case quote
    /// `\`, which starts an escape.
    case backslash
    /// A C0 control character or DEL, the byte itself (line feed, carriage
    /// return and tab included).
    case control(UInt8)
    /// A C1 control character.
    case c1
    /// A bidirectional control.
    case bidi
    /// The line or paragraph separator.
    case lineSeparator

    /// Its length in UTF-8.
    var width: Int {
        switch self {
        case .quote, .backslash, .control: 1
        case .c1: 2
        case .bidi, .lineSeparator: 3
        }
    }

    /// Which special character `c` is, if it is one.
    init?(_ c: UInt32) {
        switch c {
        case 0x22: self = .quote
        case 0x5C: self = .backslash
        case c0Controls, del: self = .control(UInt8(c))
        case c1Controls: self = .c1
        case lineSeparators: self = .lineSeparator
        case bidiEmbeddings, bidiIsolates: self = .bidi
        default: return nil
        }
    }
}

// ── classes of bytes ────────────────────────────────────────────

/// What a byte can be, for the loops that skip runs of bytes.
struct ByteClass: OptionSet {
    let rawValue: UInt8

    /// `[A-Za-z0-9_]`: a byte of identifiers and tags.
    static let ident = ByteClass(rawValue: 1 << 0)
    /// `[0-9A-Fa-f]`.
    static let hexDigit = ByteClass(rawValue: 1 << 1)
    /// The first bytes of the ``Special`` characters: `"`, `\`, the C0
    /// controls and DEL themselves, and the lead bytes of the others (`C2`
    /// of U+0080–U+00BF, `E2` of U+2000–U+2FFF). Plain text has none of them
    /// but as the start of another character of those two blocks (`°`, `€`).
    static let stringStop = ByteClass(rawValue: 1 << 2)
    /// The bytes that end a run of comment text: the C0 controls but tab (the
    /// line feed and carriage return included), DEL, and the lead bytes of C1
    /// and bidi controls.
    static let textStop = ByteClass(rawValue: 1 << 3)
    /// ``textStop``, `*` and `/`: the end of a run in a block comment.
    static let commentStop = ByteClass(rawValue: 1 << 4)
    /// ``textStop`` and `\`: the end of a run in a line of a block string.
    static let blockStringStop = ByteClass(rawValue: 1 << 5)
}

/// The class of each byte.
let byteClasses: [ByteClass] = (0...255).map { (i: Int) -> ByteClass in
    let c = UInt8(i)
    let leads = [c1Controls.lowerBound, lineSeparators.lowerBound, bidiEmbeddings.lowerBound, bidiIsolates.lowerBound]
        .map(leadByte)
    let lead = leads.contains(c)
    let control = c0Controls.contains(UInt32(c)) || UInt32(c) == del
    var classes: ByteClass = []
    if isLower(c) || isUpper(c) || isDigit(c) || c == ASCII.underscore { classes.insert(.ident) }
    if hexValue(c) != nil { classes.insert(.hexDigit) }
    if control || lead || c == ASCII.quote || c == ASCII.backslash { classes.insert(.stringStop) }
    if (control && c != ASCII.tab) || lead { classes.formUnion([.textStop, .commentStop, .blockStringStop]) }
    if c == ASCII.star || c == ASCII.slash { classes.insert(.commentStop) }
    if c == ASCII.backslash { classes.insert(.blockStringStop) }
    return classes
}

/// The class of a byte.
@inline(__always)
func classOf(_ c: UInt8) -> ByteClass { byteClasses[Int(c)] }

func isDigit(_ c: UInt8) -> Bool { c &- ASCII.zero < 10 }

/// The value of a hex digit, or nil if `c` isn't one.
func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case _ where isDigit(c): c - ASCII.zero
    case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
    default: nil
    }
}

/// Where the run of bytes from `i` that aren't in `stop` ends: the first
/// byte in `stop`, or `end`.
@inline(__always)
func skip(_ b: Bytes, from i: Int, to end: Int, until stop: ByteClass) -> Int {
    var i = i
    while i < end && !classOf(b[i]).contains(stop) { i += 1 }
    return i
}

/// Where the identifier bytes (`[A-Za-z0-9_]`) from `i` end.
func identEnd(_ b: Bytes, from i: Int) -> Int {
    var i = i
    while i < b.count && classOf(b[i]).contains(.ident) { i += 1 }
    return i
}

/// Whether `s` is a bare key: `[a-z_][A-Za-z0-9_]*`.
func isIdentifier(_ s: String) -> Bool {
    guard let first = s.utf8.first, first == ASCII.underscore || isLower(first) else { return false }
    return s.utf8.allSatisfy { classOf($0).contains(.ident) }
}

/// Whether `s` is a tag: `[A-Z][A-Za-z0-9_]*`.
func isTag(_ s: String) -> Bool {
    guard let first = s.utf8.first, isUpper(first) else { return false }
    return s.utf8.allSatisfy { classOf($0).contains(.ident) }
}

func isLower(_ c: UInt8) -> Bool { c &- UInt8(ascii: "a") < 26 }
func isUpper(_ c: UInt8) -> Bool { c &- UInt8(ascii: "A") < 26 }

// ── characters ──────────────────────────────────────────────────

/// Whether `c` continues a character in UTF-8: `10xxxxxx`.
@inline(__always)
func isContinuation(_ c: UInt8) -> Bool { c & 0xC0 == 0x80 }

/// The code point of the character that starts at `i` in valid UTF-8.
func scalar(at i: Int, in b: Bytes) -> UInt32 {
    let c = UInt32(b[i])
    let cont = { (k: Int) in UInt32(b[i + k] & 0x3F) }
    switch c {
    case ..<0x80: return c
    case ..<0xE0: return (c & 0x1F) << 6 | cont(1)
    case ..<0xF0: return (c & 0x0F) << 12 | cont(1) << 6 | cont(2)
    default: return (c & 0x07) << 18 | cont(1) << 12 | cont(2) << 6 | cont(3)
    }
}

/// The number of characters (code points) in valid UTF-8.
func codePoints(in text: some Sequence<UInt8>) -> Int {
    text.reduce(0) { n, c in isContinuation(c) ? n : n + 1 }
}

/// The special character that starts at `i` in valid UTF-8, if it is one.
func special(at i: Int, in b: Bytes) -> Special? {
    Special(scalar(at: i, in: b))
}

/// The next ``Special`` character in the valid UTF-8 from `i` (where a
/// character starts) to `end`: where it is and which one, or nil if there is
/// none.
func nextSpecial(_ b: Bytes, from i: Int, to end: Int) -> (at: Int, special: Special)? {
    var i = i
    while true {
        i = skipPlainASCII(b, from: i, to: end)
        // Then at most eight bytes, one at a time, up to the next stop byte.
        i = skip(b, from: i, to: min(i + 8, end), until: .stringStop)
        guard i < end else { return nil }
        if classOf(b[i]).contains(.stringStop) {
            // A whole character starts at a stop byte.
            if let s = special(at: i, in: b) { return (i, s) }
            // Another character of the block: its other bytes are no stop.
            i += 1
        }
    }
}

// ── eight bytes at a time ───────────────────────────────────────

/// A one in each byte of a word.
private let ones: UInt64 = 0x0101_0101_0101_0101
/// The high bit of each byte of a word.
private let high: UInt64 = 0x8080_8080_8080_8080

/// Whether one of the eight bytes of `x` is zero.
@inline(__always)
private func hasZero(_ x: UInt64) -> Bool { (x &- ones) & ~x & high != 0 }

/// Whether one of the eight bytes of `x` might end a run of plain string
/// text: not ASCII, a control character, `"`, `\` or DEL.
@inline(__always)
private func mayStop(_ x: UInt64) -> Bool {
    x & high != 0
        || (x &- ones &* 0x20) & high != 0
        || hasZero(x ^ (ones &* UInt64(ASCII.quote)))
        || hasZero(x ^ (ones &* UInt64(ASCII.backslash)))
        || hasZero(x ^ (ones &* UInt64(del)))
}

/// The eight bytes at `i` as a little-endian word (the first byte lowest).
@inline(__always)
private func word(_ b: Bytes, at i: Int) -> UInt64 {
    UnsafeRawPointer(b.baseAddress! + i).loadUnaligned(as: UInt64.self).littleEndian
}

/// Past the blocks of eight bytes of plain ASCII string text from `i` (see
/// ``mayStop(_:)``), up to the first block that might hold a stop byte.
@inline(__always)
private func skipPlainASCII(_ b: Bytes, from i: Int, to end: Int) -> Int {
    var i = i
    while i + 8 <= end && !mayStop(word(b, at: i)) { i += 8 }
    return i
}

/// Past the blocks of eight ASCII bytes from `i`.
@inline(__always)
private func skipASCII(_ b: Bytes, from i: Int) -> Int {
    var i = i
    while i + 8 <= b.count && word(b, at: i) & high == 0 { i += 8 }
    return i
}

// ── UTF-8 ───────────────────────────────────────────────────────

/// The offset of the first byte that isn't part of a valid UTF-8 sequence:
/// a byte that starts no character, a character cut short, an overlong form,
/// a surrogate or a code point above U+10FFFF. Nil if all of `b` is valid.
func firstInvalidUTF8(_ b: Bytes) -> Int? {
    var i = 0
    while i < b.count {
        i = skipASCII(b, from: i)
        guard i < b.count else { return nil }
        let c = b[i]
        if c < 0x80 {
            i += 1
            continue
        }
        // The length of the sequence and the range of its second byte,
        // which rules out overlong forms, surrogates and code points above
        // U+10FFFF.
        let (length, second): (Int, ClosedRange<UInt8>) =
            switch c {
            case 0xC2...0xDF: (2, 0x80...0xBF)
            case 0xE0: (3, 0xA0...0xBF)
            case 0xE1...0xEC, 0xEE...0xEF: (3, 0x80...0xBF)
            case 0xED: (3, 0x80...0x9F)
            case 0xF0: (4, 0x90...0xBF)
            case 0xF1...0xF3: (4, 0x80...0xBF)
            case 0xF4: (4, 0x80...0x8F)
            default: (0, 0...0)
            }
        guard length > 0, i + length <= b.count, second.contains(b[i + 1]),
            (2..<length).allSatisfy({ isContinuation(b[i + $0]) })
        else { return i }
        i += length
    }
    return nil
}
