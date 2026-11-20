/// The resource limits of spec §7, enforced while parsing. The defaults are
/// the spec's; with them, every input within them is accepted.
///
/// ```swift
/// let values = try parseAll(text, limits: Limits(maxDepth: 64))
/// ```
public struct Limits: Sendable, Hashable {
    /// The deepest nesting supported. The parser doesn't recurse, but the
    /// writers, the canonical form, equality and releasing a value do, once
    /// per level. In an optimized build each of them handles this depth
    /// within 512 KiB of stack, the size of the threads of Swift's
    /// concurrency pool; an unoptimized (debug) build needs several times
    /// more per level, and handles the default depth, 256, in 512 KiB. A
    /// larger ``maxDepth`` is rejected with the code `unsupported-depth`
    /// (spec §7).
    public static let maxSupportedDepth = 1024

    /// The deepest nesting of records, arrays and payloads, counted on the
    /// text as written (spec §7). Default 256; at most ``maxSupportedDepth``.
    public var maxDepth: Int
    /// The most characters in one number literal, sign, separators and
    /// exponent included. Default 1000. It also limits hex literals, to
    /// ``maxHexDigits`` digits.
    public var maxNumberLength: Int
    /// The largest absolute exponent of a number. Default 6144.
    public var maxExponent: Int
    /// The most characters (code points) in one string, record key or tag,
    /// or between the quotes of a byte string. Default 16 Mi.
    public var maxStringLength: Int
    /// The most characters in one top-level value of a stream, counted from
    /// the previous top-level comma (or the start, after a byte order mark)
    /// up to the next one. Default 64 Mi. Only a ``StreamReader`` applies it,
    /// as it bounds the reader's memory; ``parseAll(_:limits:)`` and the
    /// others given the whole text don't.
    public var maxValueLength: Int

    public init(
        maxDepth: Int = 256, maxNumberLength: Int = 1000, maxExponent: Int = 6144,
        maxStringLength: Int = 16 << 20, maxValueLength: Int = 64 << 20
    ) {
        self.maxDepth = maxDepth
        self.maxNumberLength = maxNumberLength
        self.maxExponent = maxExponent
        self.maxStringLength = maxStringLength
        self.maxValueLength = maxValueLength
    }

    /// The most hex digits (leading zeros counted, `_` not) in one hex
    /// literal: the largest h with 16^h ≤ 10^(n−1) for the number limit n,
    /// so that every integer's decimal form, sign included, fits in n
    /// characters (spec §7). 829 for the default 1000.
    public var maxHexDigits: Int {
        guard maxNumberLength > 1 else { return 0 }
        // h = floor((n−1) / log10(16)); 16^h is never a power of ten for h > 0.
        let log16 = 1.2041199826559248
        return Int(Double(maxNumberLength - 1) / log16)
    }

    /// The limits, if this binding supports them.
    func checked() throws(HausError) -> Limits {
        guard maxDepth <= Self.maxSupportedDepth else {
            throw HausError(
                .unsupportedDepth,
                "maxDepth \(maxDepth) is more than the supported maximum, \(Self.maxSupportedDepth)")
        }
        return self
    }
}
