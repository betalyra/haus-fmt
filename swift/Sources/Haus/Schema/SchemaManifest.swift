// The manifest of a schema package (spec §13.3), `package.haus`, and how
// text from files is shown in messages.

/// The files of a schema package, and the extension of schema files.
enum PackageFile {
    /// A schema package's manifest: `{ name, version }`.
    static let manifest = "package.haus"
    /// A schema package's one schema file, next to its manifest.
    static let schema = "schema.haus"
    /// The extension of schema files, always added to relative imports:
    /// `import ./common` reads `common.schema.haus`.
    static let schemaExtension = ".schema.haus"
}

/// A schema package's manifest, `package.haus` (spec §13.3):
/// `{ name: "@haus-fmt/money", version: "1.2.0" }`. Other fields are ignored.
public struct HausManifest: Sendable, Hashable {
    /// `@org/name`, in lowercase.
    public let name: String
    /// A semantic version: `1.2.0`.
    public let version: String

    /// The most bytes in a manifest: 64 KiB.
    public static let maxSize = 64 << 10

    /// Reads a manifest: one record with a string `name` that is a package
    /// name (`@org/name` in lowercase) and a string `version` that is a
    /// semantic version. It fails with the code `package-manifest`.
    public init(parsing text: some Collection<UInt8>) throws(HausError) {
        switch Self.parse(Array(text)) {
        case .success(let m): self = m
        case .failure(let why): throw HausError(.packageManifest, why.message)
        }
    }

    init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    /// The major version: `1` for `1.2.0`.
    public var major: Substring { version.prefix { $0 != "." } }

    /// The package's id (spec §13.3): `@haus-fmt/money@1`.
    public var id: String { "\(name)@\(major)" }

    /// Why a manifest is invalid.
    struct Invalid: Error {
        let message: String
    }

    static func parse(_ text: [UInt8]) -> Result<HausManifest, Invalid> {
        let invalid = { (why: String) in Result<HausManifest, Invalid>.failure(Invalid(message: why)) }
        if text.count > maxSize { return invalid("the manifest has \(text.count) bytes, more than 64 KiB") }
        let values: [HausValue]
        do {
            values = try parseAll(bytes: text)
        } catch {
            return invalid("the manifest is not valid haus: \(error)")
        }
        guard values.count == 1, case .record(let r) = values[0] else {
            return invalid(#"a manifest is one record: { name: "@org/name", version: "1.0.0" }"#)
        }
        guard case .string(let name)? = r["name"] else { return invalid("the manifest needs a string field name") }
        guard case .string(let version)? = r["version"] else {
            return invalid("the manifest needs a string field version")
        }
        guard isPackageName(name) else {
            return invalid(
                "\"\(quoteFromFile(name))\" is not a package name: @org/name in lowercase, each part starting with a "
                    + "letter or digit, made of a-z, 0-9, -, . and _, and not node_modules, at most 214 characters")
        }
        guard isSemanticVersion(version) else {
            return invalid("\"\(quoteFromFile(version))\" is not a semantic version, like 1.2.0")
        }
        return .success(HausManifest(name: name, version: version))
    }
}

/// Whether `version` is a semantic version (SemVer 2.0): `1.2.0`,
/// `1.0.0-rc.1+build.5`.
func isSemanticVersion(_ version: String) -> Bool {
    let isNumber = { (s: Substring) in
        !s.isEmpty && s.utf8.allSatisfy(isDigit) && !(s.utf8.count > 1 && s.utf8.first == ASCII.zero)
    }
    let isIdentifier = { (s: Substring) in
        !s.isEmpty && s.utf8.allSatisfy { isLower($0) || isUpper($0) || isDigit($0) || $0 == ASCII.minus }
    }
    let ids = { (s: Substring) in s.split(separator: ".", omittingEmptySubsequences: false) }
    let (rest, build) = cut(Substring(version), at: "+")
    let (core, pre) = cut(rest, at: "-")
    let parts = ids(core)
    guard parts.count == 3, parts.allSatisfy(isNumber) else { return false }
    let preOK = pre.map { ids($0).allSatisfy { isIdentifier($0) && (!$0.utf8.allSatisfy(isDigit) || isNumber($0)) } }
    let buildOK = build.map { ids($0).allSatisfy(isIdentifier) }
    return preOK ?? true && buildOK ?? true
}

/// `s` before and after the first `separator`; nil after if there is none.
func cut(_ s: Substring, at separator: Character) -> (Substring, Substring?) {
    guard let i = s.utf8.firstIndex(of: separator.asciiValue!) else { return (s, nil) }
    return (s[..<i], s[s.utf8.index(after: i)...])
}

/// Text from a file for a message (spec §9.2): control and bidirectional
/// characters escaped as `\u{…}`, at most 40 characters, cut with an
/// ellipsis. Unlike ``quoteForMessage(_:)``, it adds no quotes.
func quoteFromFile(_ text: String) -> String {
    let maxCharacters = 40
    // One character more than fits is enough to know whether to cut.
    let pieces = text.unicodeScalars.prefix(maxCharacters + 1).map { c in
        isControlOrBidi(c.value) ? unicodeEscape(c.value) : String(c)
    }
    let lengths = pieces.map(\.unicodeScalars.count)
    if lengths.reduce(0, +) <= maxCharacters { return pieces.joined() }
    // Whole pieces in 39 characters, and the ellipsis.
    var used = 0
    let kept = zip(pieces, lengths).prefix { _, n in
        used += n
        return used < maxCharacters
    }
    return kept.map(\.0).joined() + "…"
}

/// A path for a message, with its control and bidirectional characters
/// escaped (spec §9.2).
func shown(_ path: String) -> String {
    path.unicodeScalars.map { isControlOrBidi($0.value) ? unicodeEscape($0.value) : String($0) }.joined()
}

/// A control, bidirectional or line-separator character, and the marks
/// U+061C, U+200E and U+200F, which file names and manifests must not show
/// raw in a message.
func isControlOrBidi(_ c: UInt32) -> Bool {
    needsEscape(c) || c == 0x61C || c == 0x200E || c == 0x200F
}
