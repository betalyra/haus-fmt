// Codecs: the application chooses Swift types for named haus types (spec
// §13.4). Each one is decoded from the value the schema decoded, so the
// schema's rules always run, and encodes back to it, so the haus text never
// changes.
import Foundation
import Haus

/// A codec's rejection of a value, with the reason.
struct Rejection: Error, CustomStringConvertible {
    let description: String
}

// ── the schema's own types ──────────────────────────────────────

/// @haus-fmt/money's `Money(Decimal, Currency)`: the amount exactly, and the
/// currency (`< >`, any tag) by its tag.
enum Money: Codable {
    case money(HausNumber, String)
}

/// @haus-fmt/geo's `LatLng(Float64, Float64)`: latitude first.
enum LatLng: Codable {
    case latLng(Double, Double)
}

// ── the codecs ──────────────────────────────────────────────────

/// Integer cents, as payment APIs want them: `Money(44.40, EUR)` ↔
/// `Amount(cents: 4440, currency: "EUR")`. More than 2 decimal places, or a
/// currency that isn't ISO-shaped (the iso profile of @haus-fmt/money), is
/// an error.
struct Amount: HausCodec {
    static let hausTypeID = "@haus-fmt/money@1#Money"

    let cents: Int
    /// An ISO 4217 code: three letters A–Z.
    let currency: String

    init(hausBase: Money) throws {
        guard case .money(let amount, let currency) = hausBase else { throw Rejection(description: "not Money") }
        guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw Rejection(description: "\(currency) is not a currency: three letters A–Z (ISO 4217)")
        }
        guard let cents = scaled(amount.literal, by: 2) else {
            throw Rejection(description: "\(amount.literal) has more than 2 decimal places")
        }
        self.cents = cents
        self.currency = currency
    }

    var hausBase: Money {
        get throws { .money(try HausNumber(decimal(cents, scale: 2)), currency) }
    }
}

/// `literal`, a normalized number (`44.40`, `-1.5e3`), times 10^`scale`, if
/// that is an integer that fits an `Int`.
func scaled(_ literal: String, by scale: Int) -> Int? {
    let negative = literal.hasPrefix("-")
    let parts = literal.drop { $0 == "-" }.split(separator: "e")
    let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    let fraction = mantissa.count > 1 ? mantissa[1] : ""
    let shift = (parts.count > 1 ? Int(parts[1])! : 0) - fraction.count + scale
    let digits = String(mantissa[0] + fraction)
    let whole =
        shift >= 0
        ? digits + String(repeating: "0", count: shift)
        : digits.dropLast(-shift).isEmpty ? "0" : String(digits.dropLast(-shift))
    guard shift >= 0 || digits.suffix(-shift).allSatisfy({ $0 == "0" }), let n = Int(whole) else { return nil }
    return negative ? -n : n
}

/// `n` / 10^`scale`, with `scale` decimal places: 4440 → `44.40`.
func decimal(_ n: Int, scale: Int) -> String {
    let digits = String(n.magnitude)
    let padded = String(repeating: "0", count: max(0, scale + 1 - digits.count)) + digits
    return (n < 0 ? "-" : "") + padded.dropLast(scale) + "." + padded.suffix(scale)
}

/// GeoJSON order: `LatLng(38.7223, -9.1393)` ↔ `[-9.1393, 38.7223]`. The swap
/// happens here, once, with the ranges of the wgs84 profile of @haus-fmt/geo.
struct LngLat: HausCodec {
    static let hausTypeID = "@haus-fmt/geo@1#LatLng"

    let lng: Double
    let lat: Double

    init(hausBase: LatLng) throws {
        guard case .latLng(let lat, let lng) = hausBase else { throw Rejection(description: "not LatLng") }
        guard (-90...90).contains(lat), (-180...180).contains(lng) else {
            throw Rejection(description: "LatLng(\(lat), \(lng)) is outside the earth's degrees")
        }
        (self.lng, self.lat) = (lng, lat)
    }

    var hausBase: LatLng { .latLng(lat, lng) }
}

/// std/time types take codecs too: `Date("2026-11-09")` ↔ a Foundation `Date`
/// at midnight UTC.
struct Day: HausCodec {
    static let hausTypeID = "std/time#Date"
    static let calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    let date: Date

    init(hausBase text: String) throws {
        // The std/time profile already ran: this can't fail for a valid Date.
        let parts = text.split(separator: "-").compactMap { Int($0) }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = Self.calendar.date(from: components) else { throw Rejection(description: "no such day") }
        self.date = date
    }

    var hausBase: String {
        let c = Self.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The name of the day of the week: `Monday`.
    var weekday: String { Self.calendar.weekdaySymbols[Self.calendar.component(.weekday, from: date) - 1] }
}
