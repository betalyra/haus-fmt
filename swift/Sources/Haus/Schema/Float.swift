// Floats (spec §15): a number rounded to the nearest float of the type,
// directly from its exact decimal value, and written in one spelling.

/// The bits of a float type: `Float32` or `Float64`.
enum FloatWidth {
    case bits32, bits64
}

/// The number `literal` (normalized, spec §2) rounded to the nearest float
/// of the width, ties to even, directly from its exact decimal value (for a
/// `Float32` never through a `Double`). A number too large for the type
/// gives an infinity of its sign; one too small, a zero of its sign.
func roundToFloat(_ literal: String, _ width: FloatWidth) -> Double {
    switch width {
    case .bits32: Double(Float(literal) ?? .nan)
    case .bits64: Double(literal) ?? .nan
    }
}

/// The value an encoder writes for a float (spec §15): a number in its one
/// spelling, or the tag `NaN`, `Infinity` or `NegInfinity`.
func floatValue(_ f: Double, _ width: FloatWidth) -> HausValue {
    switch f {
    case _ where f.isNaN: .tag("NaN")
    case .infinity: .tag("Infinity")
    case -.infinity: .tag("NegInfinity")
    default: .number(HausNumber(normalized: floatSpelling(f, width)))
    }
}

/// The one spelling of a finite float (spec §15): the fewest digits that
/// read back as the same float of the width (Swift's `description` gives
/// those, the closest of them), laid out as JavaScript's
/// `Number.prototype.toString` does, without `+` in the exponent.
func floatSpelling(_ f: Double, _ width: FloatWidth) -> String {
    if f == 0 { return f.sign == .minus ? "-0" : "0" }
    let shortest = width == .bits32 ? Float(f).description : f.description
    let negative = shortest.hasPrefix("-")
    let parts = shortest.drop { $0 == "-" }.split(separator: "e")
    let mantissa = parts[0]
    let exponent = parts.count > 1 ? Int(parts[1])! : 0
    // The value is 0.d₁…dₖ × 10ⁿ.
    let point =
        mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
    let all = mantissa.filter { $0 != "." }
    let leading = all.prefix { $0 == "0" }.count
    let digits = String(all.dropFirst(leading).reversed().drop { $0 == "0" }.reversed())
    let (k, n) = (digits.count, point + exponent - leading)
    let zeros = { (count: Int) in String(repeating: "0", count: count) }
    let body: String =
        switch n {
        case k...21: digits + zeros(n - k)
        case 1...21: digits.prefix(n) + "." + digits.dropFirst(n)
        case -5...0: "0." + zeros(-n) + digits
        default: digits.prefix(1) + (k > 1 ? "." + digits.dropFirst() : "") + "e\(n - 1)"
        }
    return (negative ? "-" : "") + body
}
