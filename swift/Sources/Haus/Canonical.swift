#if canImport(CryptoKit)
    import CryptoKit
#endif

/// The canonical form of a value (spec §12): one exact text, so that two
/// values are equal exactly when their canonical forms are identical.
/// Records are sorted by key, numbers normalized and in decimal, and there is
/// no whitespace outside strings.
///
/// ```swift
/// let v = try parse(#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }"#)
/// try canonical(v) // Order{id:255,total:19.90,"x-y":1e5}
/// ```
///
/// It fails only for values built in code that have no text: a tag that
/// isn't `[A-Z][A-Za-z0-9_]*` (`invalid-tag`), or nesting deeper than
/// ``Limits/maxSupportedDepth`` (`nesting-too-deep`).
public func canonical(_ value: HausValue) throws(HausError) -> String {
    var out: [UInt8] = []
    try writeCanonical(value, depth: 0, to: &out)
    return String(decoding: out, as: UTF8.self)
}

#if canImport(CryptoKit)
    /// The SHA-256 digest of the canonical form of a value, as 64 lowercase
    /// hex digits (spec §12). It fails as ``canonical(_:)`` does.
    ///
    /// The hash is unkeyed: anyone who can guess a document can confirm the
    /// guess with its hash (spec §9).
    public func hash(_ value: HausValue) throws(HausError) -> String {
        try hashAll([value])
    }

    /// The hash of a list of values, such as a whole file (spec §12): the
    /// SHA-256 digest of their canonical forms joined by `,`. A list of one
    /// value hashes like the value, and the empty list to the digest of the
    /// empty text. The items of a stream are hashed one by one with
    /// ``hash(_:)``.
    public func hashAll(_ values: [HausValue]) throws(HausError) -> String {
        var out: [UInt8] = []
        for (i, value) in values.enumerated() {
            if i > 0 { out.append(ASCII.comma) }
            try writeCanonical(value, depth: 0, to: &out)
        }
        return SHA256.hash(data: out).map { hexByte($0) }.joined()
    }
#endif

/// Two lowercase hex digits.
func hexByte(_ byte: UInt8) -> String {
    let digits = Array("0123456789abcdef".utf8)
    return String(decoding: [digits[Int(byte >> 4)], digits[Int(byte & 0xF)]], as: UTF8.self)
}

/// Appends the canonical form of `value`, a container at `depth` levels.
private func writeCanonical(_ value: HausValue, depth: Int, to out: inout [UInt8]) throws(HausError) {
    func enter() throws(HausError) {
        if depth >= Limits.maxSupportedDepth {
            throw HausError(.nestingTooDeep, "nesting deeper than the limit of \(Limits.maxSupportedDepth)")
        }
    }
    func items(_ items: [HausValue], _ open: UInt8, _ close: UInt8) throws(HausError) {
        try enter()
        out.append(open)
        for (i, item) in items.enumerated() {
            if i > 0 { out.append(ASCII.comma) }
            try writeCanonical(item, depth: depth + 1, to: &out)
        }
        out.append(close)
    }
    func record(_ r: HausRecord) throws(HausError) {
        try enter()
        let inOrder = zip(r.fields, r.fields.dropFirst()).allSatisfy { !precedes($1.key, $0.key) }
        let fields = inOrder ? r.fields : r.fields.sorted { precedes($0.key, $1.key) }
        out.append(ASCII.openBrace)
        for (i, field) in fields.enumerated() {
            if i > 0 { out.append(ASCII.comma) }
            appendKey(field.key, to: &out)
            out.append(ASCII.colon)
            try writeCanonical(field.value, depth: depth + 1, to: &out)
        }
        out.append(ASCII.closeBrace)
    }

    switch value {
    case .number(let n): out += n.literal.utf8
    case .string(let s): appendQuoted(s, to: &out)
    case .bytes(let bytes):
        out += #"x""#.utf8
        out += bytes.map(hexByte).joined().utf8
        out.append(ASCII.quote)
    case .array(let elements): try items(elements, ASCII.openBracket, ASCII.closeBracket)
    case .record(let r): try record(r)
    case .variant(let tag, let args):
        try checkTag(tag)
        out += tag.utf8
        switch args.first {
        case nil: break
        case .record(let r) where args.count == 1: try record(r)
        default: try items(args, ASCII.openParen, ASCII.closeParen)
        }
    }
}

/// Whether key `a` sorts before key `b`: by their code points, which is the
/// order of their UTF-8 bytes (spec §12).
func precedes(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// Appends a record key: bare if it is an identifier, otherwise quoted.
func appendKey(_ key: String, to out: inout [UInt8]) {
    if isIdentifier(key) {
        out += key.utf8
    } else {
        appendQuoted(key, to: &out)
    }
}

/// Fails with `invalid-tag` if `tag` can't be written: it isn't `[A-Z][A-Za-z0-9_]*`.
func checkTag(_ tag: String) throws(HausError) {
    if !isTag(tag) { throw HausError(.invalidTag, invalidTag(tag)) }
}

/// The message of `invalid-tag`.
func invalidTag(_ tag: String) -> String {
    "the tag \(quoteForMessage(tag)) isn't [A-Z][A-Za-z0-9_]*"
}
