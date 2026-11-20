/// An exact decimal number (spec §3), kept as its normalized literal
/// (spec §2): digit separators removed, the exponent written `e` and its
/// value, and hex and binary literals converted to decimal. Scale and
/// notation are part of the value: `1.0` and `1` are different numbers, and
/// so are `1e2` and `100`. Converting to a binary float is up to the
/// application (or a schema), never the parser.
public struct HausNumber: Sendable, Hashable, CustomStringConvertible {
    /// The normalized literal: `255`, `19.90`, `-0`, `1e5`. It is ASCII, so
    /// Swift's `==` compares it exactly.
    public let literal: String

    init(normalized literal: String) { self.literal = literal }

    /// The integer `value`.
    public init(_ value: some BinaryInteger) { self.literal = String(value) }

    /// Reads a number literal (spec §3, §7), such as `19.90`, `-1e10`, `0xFF`
    /// or `1_000`. It fails with `invalid-number` if `literal` is not one,
    /// or with the code of the limit it is over.
    public init(_ literal: String, limits: Limits = Limits()) throws(HausError) {
        self = try withUTF8(literal) { (b) throws(HausError) -> HausNumber in
            let notANumber = HausError(.invalidNumber, "not a number literal: \(quoteForMessage(literal))")
            guard let first = b.first, isDigit(first) || [ASCII.minus, ASCII.plus, ASCII.dot].contains(first) else {
                throw notANumber
            }
            let scanned: (end: Int, normalized: String)
            do throws(NumberError) {
                scanned = try scanNumber(b, at: 0, limits: limits)
            } catch {
                throw HausError(error.code, error.message)
            }
            guard scanned.end == b.count else { throw notANumber }
            return HausNumber(normalized: scanned.normalized)
        }
    }

    public var description: String { literal }

    /// Whether the literal has neither a fraction nor an exponent. `1e2` and
    /// `1.0` are not integers in this sense: notation is part of a haus
    /// number (spec §2), and whether `1.0` is an integer is up to a schema.
    public var isInteger: Bool { !literal.utf8.contains { $0 == ASCII.dot || $0 == ASCII.e } }

    /// The number as an integer of type `T`, if it is an integer
    /// (``isInteger``) that `T` can hold.
    public func integer<T: FixedWidthInteger>(as type: T.Type = Int.self) -> T? {
        isInteger ? T(literal) : nil
    }
}

/// A mistake in a number literal, at a byte offset.
struct NumberError: Error {
    let code: HausError.Code
    let message: String
    let at: Int
}

/// Reads the number literal that starts at `b[pos]` (a `-` or a digit, or a
/// `+` or `.` to report). Returns the end of the literal and its normalized
/// text (spec §2).
func scanNumber(_ b: Bytes, at pos: Int, limits: Limits) throws(NumberError) -> (end: Int, normalized: String) {
    let start = pos
    func invalid(_ at: Int, _ message: String) -> NumberError {
        NumberError(code: .invalidNumber, message: message, at: at)
    }
    func byte(_ i: Int) -> UInt8? { i < b.count ? b[i] : nil }
    func describe(_ i: Int) -> String { describeCharacter(at: i, in: b) }
    /// The end of `digit ("_"? digit)*` from the digit at `i`, or the place of a misplaced `_`.
    func digits(from i: Int, _ isDigit: (UInt8) -> Bool) throws(NumberError) -> Int {
        var i = i + 1
        while true {
            if byte(i) == ASCII.underscore {
                guard let next = byte(i + 1), isDigit(next) else {
                    throw invalid(i, "'_' must stand between two digits")
                }
                i += 2
            } else if let c = byte(i), isDigit(c) {
                i += 1
            } else {
                return i
            }
        }
    }
    /// The number must not be followed directly by `[A-Za-z0-9_.]`.
    func checkEnd(_ i: Int) throws(NumberError) {
        if let c = byte(i), c == ASCII.dot || classOf(c).contains(.ident) {
            throw invalid(i, "a number can't be followed directly by \(describe(i))")
        }
        if i - start > limits.maxNumberLength {
            throw NumberError(
                code: .numberTooLong,
                message:
                    "a number literal of \(i - start) characters, more than the limit of \(limits.maxNumberLength)",
                at: start)
        }
    }
    func text(_ from: Int, _ to: Int) -> String { String(decoding: Bytes(rebasing: b[from..<to]), as: UTF8.self) }
    /// The bytes from `from` to `to` without digit separators.
    func withoutSeparators(_ from: Int, _ to: Int) -> [UInt8] { b[from..<to].filter { $0 != ASCII.underscore } }

    var i = pos
    if let c = byte(i), c == ASCII.plus || c == ASCII.dot {
        throw invalid(i, "a number can't start with '\(Character(Unicode.Scalar(c)))'")
    }
    let negative = byte(i) == ASCII.minus
    if negative { i += 1 }
    guard let first = byte(i), isDigit(first) else {
        throw invalid(i, "expected a digit after '-', found \(describe(i))")
    }

    // 0x… and 0b…: integers, written in decimal.
    if first == ASCII.zero, let prefix = byte(i + 1) {
        switch prefix {
        case ASCII.x, ASCII.b:
            let base = prefix == ASCII.x ? 16 : 2
            let isDigitOfBase: (UInt8) -> Bool =
                base == 16 ? { classOf($0).contains(.hexDigit) } : { $0 == ASCII.zero || $0 == ASCII.one }
            let from = i + 2
            guard let d = byte(from), isDigitOfBase(d) else {
                throw invalid(
                    from, "expected a digit after '0\(Character(Unicode.Scalar(prefix)))', found \(describe(from))")
            }
            let end = try digits(from: from, isDigitOfBase)
            try checkEnd(end)
            let values = withoutSeparators(from, end).map { hexValue($0)! }
            if base == 16 && values.count > limits.maxHexDigits {
                throw NumberError(
                    code: .numberTooLong,
                    message:
                        "a hex literal with \(values.count) hex digits, more than the limit of \(limits.maxHexDigits)",
                    at: start)
            }
            return (end, (negative ? "-" : "") + decimal(digits: values, base: base))
        case ASCII.X, ASCII.B:
            throw invalid(i + 1, "the prefix is lowercase: '0\(Character(Unicode.Scalar(prefix | 0x20)))'")
        case _ where isDigit(prefix) || prefix == ASCII.underscore:
            throw invalid(i, "a number can't have a leading zero")
        default:
            break
        }
    }

    // int frac? exp?
    i = first == ASCII.zero ? i + 1 : try digits(from: i, isDigit)
    if byte(i) == ASCII.dot {
        guard let d = byte(i + 1), isDigit(d) else {
            throw invalid(i, "expected a digit after '.', found \(describe(i + 1))")
        }
        i = try digits(from: i + 1, isDigit)
    }
    let mantissaEnd = i
    guard let e = byte(i), e == ASCII.e || e == ASCII.E else {
        try checkEnd(i)
        let plain = !b[start..<i].contains(ASCII.underscore)
        return (i, plain ? text(start, i) : String(decoding: withoutSeparators(start, i), as: UTF8.self))
    }
    let exponentStart = i
    i += 1
    if let sign = byte(i), sign == ASCII.plus || sign == ASCII.minus { i += 1 }
    guard let d = byte(i), isDigit(d) else {
        throw invalid(i, "expected a digit in the exponent, found \(describe(i))")
    }
    let exponentDigits = i
    i = try digits(from: i, isDigit)
    try checkEnd(i)

    // The exponent normalized: no `+`, no leading zeros, no `-` on zero.
    let significant = withoutSeparators(exponentDigits, i).drop { $0 == ASCII.zero }
    guard significant.count <= 9, significant.reduce(0, { $0 * 10 + Int($1 - ASCII.zero) }) <= limits.maxExponent else {
        throw NumberError(
            code: .exponentTooLarge, message: "the exponent is larger than the limit of \(limits.maxExponent)",
            at: exponentStart)
    }
    let exponentNegative = b[exponentDigits - 1] == ASCII.minus && !significant.isEmpty
    let mantissa = withoutSeparators(start, mantissaEnd)
    var normalized = mantissa + [ASCII.e] + (exponentNegative ? [ASCII.minus] : []) + significant
    if significant.isEmpty { normalized.append(ASCII.zero) }
    // Already normalized: the text is mantissa, `e`, exponent as written.
    if normalized.elementsEqual(b[start..<i]) { return (i, text(start, i)) }
    return (i, String(decoding: normalized, as: UTF8.self))
}

/// The decimal form of a non-negative integer from its digits in `base`,
/// most significant first. Quadratic in the number of digits, which the
/// number limit bounds (spec §7).
func decimal(digits: [UInt8], base: Int) -> String {
    // Limbs of nine decimal digits, least significant first.
    let limbBase: UInt64 = 1_000_000_000
    var limbs: [UInt64] = [0]
    for d in digits {
        var carry = UInt64(d)
        for k in limbs.indices {
            let x = limbs[k] * UInt64(base) + carry
            limbs[k] = x % limbBase
            carry = x / limbBase
        }
        if carry > 0 { limbs.append(carry) }
    }
    let rest = limbs.dropLast().reversed().map { limb in
        let s = String(limb)
        return String(repeating: "0", count: 9 - s.count) + s
    }
    return String(limbs.last!) + rest.joined()
}
