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
/// Every value has a canonical form, however deep or long (spec §12): of
/// `limits`, only ``Limits/maxNodes`` applies. It fails only for a value
/// whose arrays share each other so much that its canonical form would hold
/// more values than that (`too-many-nodes`, at `$`).
public func canonical(_ value: HausValue, limits: Limits = Limits()) throws(HausError) -> String {
    var out: [UInt8] = []
    try appendCanonical(value, limits: limits, to: &out)
    return String(decoding: out, as: UTF8.self)
}

#if canImport(CryptoKit)
    /// The SHA-256 digest of the canonical form of a value, as 64 lowercase
    /// hex digits (spec §12). It fails as ``canonical(_:limits:)`` does.
    ///
    /// The hash is unkeyed: anyone who can guess a document can confirm the
    /// guess with its hash (spec §9).
    public func hash(_ value: HausValue, limits: Limits = Limits()) throws(HausError) -> String {
        var out: [UInt8] = []
        try appendCanonical(value, limits: limits, to: &out)
        return sha256Hex(out)
    }

    /// The hash of a list of values, such as a whole file (spec §12): the
    /// SHA-256 digest of their canonical forms joined by `,`. A list of one
    /// value hashes like the value, and the empty list to the digest of the
    /// empty text. The items of a stream are hashed one by one with
    /// ``hash(_:limits:)``. The node limit applies to each value on its own;
    /// its error is at the value's index (`$[3]`).
    public func hashAll(_ values: [HausValue], limits: Limits = Limits()) throws(HausError) -> String {
        var out: [UInt8] = []
        for (i, value) in values.enumerated() {
            if i > 0 { out.append(ASCII.comma) }
            try appendCanonical(value, limits: limits, prefix: [.index(i)], to: &out)
        }
        return sha256Hex(out)
    }

    /// The SHA-256 digest of `bytes`, as 64 lowercase hex digits.
    private func sha256Hex(_ bytes: [UInt8]) -> String {
        var hex: [UInt8] = []
        appendHex(SHA256.hash(data: bytes), to: &hex)
        return String(decoding: hex, as: UTF8.self)
    }
#endif

/// The lowercase hex digits.
private let hexDigits = Array("0123456789abcdef".utf8)

/// Appends two lowercase hex digits per byte.
func appendHex(_ bytes: some Sequence<UInt8>, to out: inout [UInt8]) {
    for byte in bytes {
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0xF)])
    }
}

/// Appends the canonical form of `value`, within the node limit of `limits`.
func appendCanonical(
    _ value: HausValue, limits: Limits, prefix: [PathStep] = [], to out: inout [UInt8]
) throws(HausError) {
    var walk = Walk(HausSpelling.canonical, checks: .canonical(limits), prefix: prefix)
    try walk.write(value, to: &out)
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
