// How the writers spell strings (spec §11, §12): with the fewest escapes,
// and never a control, bidi or line-separator character raw.

/// Appends `\u{…}` with uppercase hex digits and no leading zeros.
func appendUnicodeEscape(_ c: UInt32, to out: inout [UInt8]) {
    out += unicodeEscape(c).utf8
}

/// Appends the escape of the special character at `i`.
private func escape(_ special: Special, at i: Int, in b: Bytes, to out: inout [UInt8]) {
    switch special {
    case .quote: out += #"\""#.utf8
    case .backslash: out += #"\\"#.utf8
    case .control(ASCII.lf): out += #"\n"#.utf8
    case .control(ASCII.cr): out += #"\r"#.utf8
    case .control(ASCII.tab): out += #"\t"#.utf8
    case .control, .c1, .bidi, .lineSeparator: appendUnicodeEscape(scalar(at: i, in: b), to: &out)
    }
}

/// Appends `s` as a `"…"` string with the fewest escapes: the same in every
/// layout and in the canonical form.
func appendQuoted(_ s: String, to out: inout [UInt8]) {
    out.append(ASCII.quote)
    withUTF8(s) { b in
        var plain = 0
        while let (at, special) = nextSpecial(b, from: plain, to: b.count) {
            out += b[plain..<at]
            escape(special, at: at, in: b, to: &out)
            plain = at + special.width
        }
        out += b[plain...]
    }
    out.append(ASCII.quote)
}

/// Appends a scalar as written in the source, with raw U+2028 and U+2029
/// escaped, which no layout writes raw (spec §11).
func appendSpelling(_ text: [UInt8], to out: inout [UInt8]) {
    text.withUnsafeBufferPointer { b in
        var plain = 0
        var i = 0
        while let (at, special) = nextSpecial(b, from: i, to: b.count) {
            i = at + special.width
            guard special == .lineSeparator else { continue }
            out += b[plain..<at]
            appendUnicodeEscape(scalar(at: at, in: b), to: &out)
            plain = i
        }
        out += b[plain...]
    }
}

/// Appends one content line of a block string: a quote followed by two more
/// is escaped, a carriage return is `\r`, and the last character is escaped
/// if it is a space or tab, so that no line ends in one (spec §11).
func appendBlockLine(_ line: ArraySlice<UInt8>, to out: inout [UInt8]) {
    let blank = line.last.flatMap { $0 == ASCII.space || $0 == ASCII.tab ? $0 : nil }
    let body = blank == nil ? line : line.dropLast()
    body.withUnsafeBufferPointer { b in
        var plain = 0
        while let (at, special) = nextSpecial(b, from: plain, to: b.count) {
            out += b[plain..<at]
            switch special {
            case .quote where !b[at...].starts(with: #"""""#.utf8): out.append(ASCII.quote)
            case .control(ASCII.tab): out.append(ASCII.tab)
            default: escape(special, at: at, in: b, to: &out)
            }
            plain = at + special.width
        }
        out += b[plain...]
    }
    switch blank {
    case ASCII.space: out += #"\u{20}"#.utf8
    case ASCII.tab: out += #"\t"#.utf8
    default: break
    }
}
