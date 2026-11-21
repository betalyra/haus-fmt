// The std/time profile (spec/std/time.md): which strings each type of
// std/time accepts. These are built-in rules, like the range of UInt8, and
// a schema binding checks exactly these. Each type reads its whole shape
// first, then checks the values, so that a string of the wrong shape says
// how to write the type, whatever its values.

/// Checks that `text` is a valid value of the std/time type `type`
/// (`"Date"`, `"Instant"`, …), as decoding with a schema does. It fails with
/// `invalid-time` and why, or with `unknown-type` if `type` isn't one of
/// ``timeTypes``.
///
/// ```swift
/// try checkTime("Date", "2026-11-13")  // fine
/// try checkTime("Date", "2026-02-30")  // invalid-time: 2026-02 has no day 30
/// ```
public func checkTime(_ type: String, _ text: String) throws(HausError) {
    guard timeExamples[type] != nil else {
        throw HausError(.unknownType, "\(quoteForMessage(type)) is not a std/time type")
    }
    if let why = timeError(type, text) { throw HausError(.invalidTime, why) }
}

let timeExamples = [
    "Date": "2026-11-09", "Time": "14:30:00", "DateTime": "2026-11-09T14:30:00",
    "Instant": "2026-11-09T14:30:00Z", "ZonedDateTime": "2026-11-09T14:30:00+01:00[Europe/Lisbon]",
    "Duration": "PT1H30M", "YearMonth": "2026-11", "TimeZone": "Europe/Lisbon",
]

/// Why `text` isn't a valid value of the std/time type `type`, or nil if it is.
func timeError(_ type: String, _ text: String) -> String? {
    var c = TimeCursor(Array(text.utf8))
    let result: Result<Void, TimeMistake>
    switch type {
    case "Date": result = c.dateOnly()
    case "Time": result = c.timeOnly()
    case "DateTime": result = c.dateTime(offset: false, zone: false)
    case "Instant": result = c.dateTime(offset: true, zone: false)
    case "ZonedDateTime": result = c.dateTime(offset: true, zone: true)
    case "Duration": result = c.duration()
    case "YearMonth": result = c.yearMonth()
    case "TimeZone": result = checkZone(c.s[...])
    default: return "\(type) is not a std/time type"
    }
    switch result {
    case .success: return nil
    case .failure(.shape): return "\(quoteForMessage(text)) is not a \(type); write it like \(timeExamples[type]!)"
    case .failure(.invalid(let why)): return "\(quoteForMessage(text)) is not a valid \(type): \(why)"
    }
}

/// Why a time string is rejected.
enum TimeMistake: Error {
    /// It doesn't have its type's shape at all.
    case shape
    /// It has the shape, but a value is wrong.
    case invalid(String)
}

/// The text of digits, as a number (never more than a few digits).
private func number(_ digits: ArraySlice<UInt8>) -> Int { digits.reduce(0) { $0 * 10 + Int($1 - ASCII.zero) } }

private func string(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }

struct TimeCursor {
    let s: [UInt8]
    var i = 0

    init(_ s: [UInt8]) { self.s = s }

    var atEnd: Bool { i == s.count }

    func finish() throws(TimeMistake) { if !atEnd { throw .shape } }

    mutating func optional(_ c: Character) -> Bool {
        guard i < s.count, s[i] == c.asciiValue! else { return false }
        i += 1
        return true
    }

    mutating func literal(_ c: Character) throws(TimeMistake) { if !optional(c) { throw .shape } }

    /// Exactly `n` digits.
    mutating func digits(_ n: Int) throws(TimeMistake) -> ArraySlice<UInt8> {
        guard i + n <= s.count, s[i..<(i + n)].allSatisfy(isDigit) else { throw .shape }
        i += n
        return s[(i - n)..<i]
    }

    /// One or more digits, or none.
    mutating func run() -> ArraySlice<UInt8> {
        let start = i
        while i < s.count && isDigit(s[i]) { i += 1 }
        return s[start..<i]
    }

    /// A fraction of 1–9 digits after a `.`, if there is a `.`.
    mutating func fraction() throws(TimeMistake) {
        if optional(".") {
            let f = run()
            if f.isEmpty || f.count > 9 { throw .shape }
        }
    }

    mutating func date() throws(TimeMistake) -> (y: ArraySlice<UInt8>, m: ArraySlice<UInt8>, d: ArraySlice<UInt8>) {
        let y = try digits(4)
        try literal("-")
        let m = try digits(2)
        try literal("-")
        return (y, m, try digits(2))
    }

    /// `hh:mm:ss`, then an optional fraction.
    mutating func clock() throws(TimeMistake) -> (h: ArraySlice<UInt8>, m: ArraySlice<UInt8>, s: ArraySlice<UInt8>) {
        let h = try digits(2)
        try literal(":")
        let m = try digits(2)
        try literal(":")
        let sec = try digits(2)
        try fraction()
        return (h, m, sec)
    }

    /// `Z` or `±hh:mm`.
    mutating func offset() throws(TimeMistake) -> ArraySlice<UInt8> {
        let start = i
        if !optional("Z") {
            guard optional("+") || optional("-") else { throw .shape }
            _ = try digits(2)
            try literal(":")
            _ = try digits(2)
        }
        return s[start..<i]
    }

    mutating func dateOnly() -> Result<Void, TimeMistake> {
        Result { () throws(TimeMistake) in
            let d = try date()
            try finish()
            try checkDate(d)
        }
    }

    mutating func timeOnly() -> Result<Void, TimeMistake> {
        Result { () throws(TimeMistake) in
            let t = try clock()
            try finish()
            try checkClock(t)
        }
    }

    /// A `DateTime`, with an offset for an `Instant`, and a zone in brackets
    /// for a `ZonedDateTime`.
    mutating func dateTime(offset withOffset: Bool, zone withZone: Bool) -> Result<Void, TimeMistake> {
        Result { () throws(TimeMistake) in
            let d = try date()
            try literal("T")
            let t = try clock()
            let o = withOffset ? try offset() : []
            var zone: ArraySlice<UInt8> = []
            if withZone {
                try literal("[")
                guard let end = s[i...].firstIndex(of: UInt8(ascii: "]")) else { throw .shape }
                zone = s[i..<end]
                i = end + 1
            }
            try finish()
            try checkDate(d)
            try checkClock(t)
            if withOffset { try checkOffset(o) }
            if withZone { try checkZone(zone).get() }
        }
    }

    mutating func yearMonth() -> Result<Void, TimeMistake> {
        Result { () throws(TimeMistake) in
            _ = try digits(4)
            try literal("-")
            let m = try digits(2)
            try finish()
            if !(1...12).contains(number(m)) { throw .invalid("month \(string(m)) doesn't exist") }
        }
    }

    /// A duration component, digits (and a fraction, if allowed) and its unit
    /// letter, if the next one is that unit; otherwise it reads nothing.
    mutating func component(_ unit: Character, fraction allowed: Bool) throws(TimeMistake) -> ArraySlice<UInt8>? {
        let start = i
        guard !run().isEmpty else {
            i = start
            return nil
        }
        if allowed { try fraction() }
        let text = s[start..<i]
        if optional(unit) { return text }
        i = start
        return nil
    }

    /// `-?P[nY][nM][nW][nD][T[nH][nM][n[.f]S]]`.
    mutating func duration() -> Result<Void, TimeMistake> {
        Result { () throws(TimeMistake) in
            let negative = optional("-")
            try literal("P")
            // years, months, weeks, days, hours, minutes, seconds (with their fraction)
            var texts: [ArraySlice<UInt8>?] = []
            for unit in "YMWD" { texts.append(try component(unit, fraction: false)) }
            let hasTime = optional("T")
            let endsWithT = hasTime && atEnd
            for unit in "HMS" { texts.append(hasTime ? try component(unit, fraction: unit == "S") : nil) }
            try finish()
            try checkDuration(texts, negative: negative, endsWithT: endsWithT)
        }
    }

    func checkDuration(_ texts: [ArraySlice<UInt8>?], negative: Bool, endsWithT: Bool) throws(TimeMistake) {
        // Without the fraction.
        let values = texts.map { $0.map { t in t.prefix { $0 != ASCII.dot } } }
        guard values.contains(where: { $0 != nil }) else {
            throw .invalid("a duration needs at least one component, like PT0S")
        }
        if endsWithT { throw .invalid("a T must be followed by hours, minutes or seconds") }
        if let v = values.compactMap({ $0 }).first(where: { $0.count > 1 && $0.first == ASCII.zero }) {
            throw .invalid("\(string(v)) has a leading zero")
        }
        let isZero = { (t: ArraySlice<UInt8>) in t.allSatisfy { $0 == ASCII.zero || $0 == ASCII.dot } }
        let leftOut = TimeMistake.invalid("a duration leaves out components that are zero (zero is PT0S)")
        let others = texts.prefix(6).compactMap { $0 }
        if others.contains(where: isZero) { throw leftOut }
        if let seconds = texts[6], isZero(seconds), !others.isEmpty { throw leftOut }
        if negative && s.allSatisfy({ "-PYMWDTHS0.".utf8.contains($0) }) {
            throw .invalid("a zero duration has no sign")
        }
        // Exact bounds, whatever the number of digits.
        let limit32: [UInt8] = Array("4294967296".utf8)
        for v in values.prefix(3).compactMap({ $0 }) where atLeast(v, limit32) {
            throw .invalid("\(string(v)) is too large (years, months and weeks stay below 2^32)")
        }
        // Days and time below 2^53 seconds: the whole seconds decide, as a fraction is below one second.
        let perUnit: [UInt64] = [86400, 3600, 60, 1]
        var total: UInt64 = 0
        var tooLarge = false
        for (v, per) in zip(values.suffix(4), perUnit) {
            guard let v else { continue }
            guard v.count <= 16 else {
                tooLarge = true
                break
            }
            let (product, o1) = UInt64(number(v)).multipliedReportingOverflow(by: per)
            let (sum, o2) = total.addingReportingOverflow(product)
            total = sum
            tooLarge = tooLarge || o1 || o2
        }
        if tooLarge || total >= 1 << 53 { throw .invalid("days and time together must stay below 2^53 seconds") }
    }
}

/// Whether the digits without leading zeros `v` are at least `limit`.
private func atLeast(_ v: ArraySlice<UInt8>, _ limit: [UInt8]) -> Bool {
    v.count != limit.count ? v.count > limit.count : !v.lexicographicallyPrecedes(limit)
}

private func checkDate(_ d: (y: ArraySlice<UInt8>, m: ArraySlice<UInt8>, d: ArraySlice<UInt8>)) throws(TimeMistake) {
    let (year, month, day) = (number(d.y), number(d.m), number(d.d))
    guard (1...12).contains(month) else { throw .invalid("month \(string(d.m)) doesn't exist") }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let last =
        switch month {
        case 2: leap ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    if (1...last).contains(day) { return }
    let (y, m) = (string(d.y), string(d.m))
    if month == 2 && day == 29 { throw .invalid("\(y)-\(m) has no day \(string(d.d)) (\(y) is not a leap year)") }
    throw .invalid("\(y)-\(m) has no day \(string(d.d))")
}

private func checkClock(_ t: (h: ArraySlice<UInt8>, m: ArraySlice<UInt8>, s: ArraySlice<UInt8>)) throws(TimeMistake) {
    let (h, m, s) = (number(t.h), number(t.m), number(t.s))
    if h == 24 { throw .invalid("24:00 is not allowed; write 00:00 of the next day") }
    if h > 24 { throw .invalid("hour \(string(t.h)) doesn't exist") }
    if m >= 60 { throw .invalid("minute \(string(t.m)) doesn't exist") }
    if s == 60 { throw .invalid("leap seconds (:60) are not allowed") }
    if s > 60 { throw .invalid("second \(string(t.s)) doesn't exist") }
}

/// `Z` or `±hh:mm`: up to ±23:59, never -00:00.
private func checkOffset(_ o: ArraySlice<UInt8>) throws(TimeMistake) {
    let text = string(o)
    if text == "Z" { return }
    if text == "-00:00" { throw .invalid("-00:00 is not allowed; write Z") }
    let start = o.startIndex
    if number(o[(start + 1)..<(start + 3)]) > 23 || number(o[(start + 4)..<(start + 6)]) > 59 {
        throw .invalid("offset \(text) is out of range (±23:59 at most)")
    }
}

/// Checks an IANA zone name by its syntax (it is never looked up), or an offset.
func checkZone(_ z: ArraySlice<UInt8>) -> Result<Void, TimeMistake> {
    // `Z` is the offset letter, not a zone name.
    if z.elementsEqual("Z".utf8) {
        return .failure(.invalid("Z is an offset letter, not a zone: write +00:00, or a zone name like Etc/UTC"))
    }
    var c = TimeCursor(Array(z))
    if let o = try? c.offset(), c.atEnd {
        return Result { () throws(TimeMistake) in try checkOffset(o) }
    }
    let partBytes = Set("._+-".utf8)
    func part(_ p: ArraySlice<UInt8>) -> Bool {
        !p.isEmpty && !p.elementsEqual(".".utf8) && !p.elementsEqual("..".utf8)
            && p.allSatisfy { (classOf($0).contains(.ident) && $0 != ASCII.underscore) || partBytes.contains($0) }
    }
    let ok =
        z.count <= 255 && z.first.map { isUpper($0) || isLower($0) } == true
        && z.split(separator: ASCII.slash, omittingEmptySubsequences: false).allSatisfy(part)
    if ok { return .success(()) }
    return .failure(
        .invalid(
            "\(quoteForMessage(string(z))) is not an IANA zone name (like Europe/Lisbon) or an offset (like +01:00)"))
}
