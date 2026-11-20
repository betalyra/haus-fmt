// Typed values: Swift's `Codable` types decoded from and encoded to haus
// values with a schema type (spec §15). The schema decodes first, so its
// rules and errors are the same as without Swift types; then a `Decoder`
// walks the decoded value together with its type, so that the type, not
// the value, decides what a Swift `Optional` or `String` stands for. Encoding
// goes the other way: an `Encoder` builds the value with the type, and the
// schema encodes it.

extension SchemaType {
    /// Decodes `value` with the type into a Swift value. The schema decodes
    /// first (spec §15), with its error codes and paths; then the decoded
    /// value becomes a `T`, whose `Decodable` conformance (synthesized, as a
    /// rule) must fit the type:
    ///
    /// ```swift
    /// struct Order: Codable { let id: Int, total: HausNumber, status: Status }
    /// enum Status: Codable { case pending, shipped(tracking: String), cancelled }
    /// let order = try schema.type("Order").decode(Order.self, from: parse(text))
    /// ```
    ///
    /// Records are structs, variants enums (the tag `Shipped` is the case
    /// `shipped`), `Maybe a` an `Optional`; see the binding's README for
    /// every type. A Swift type that doesn't fit the schema type fails with
    /// `type-mismatch` (or `missing-field`, `out-of-range`, `unknown-tag`),
    /// at the place of the value.
    public func decode<T: Decodable>(_ type: T.Type, from value: HausValue, limits: Limits = Limits())
        throws(HausError) -> T
    {
        try decodeTyped(type, decode(value, limits: limits), prefix: [])
    }

    /// Reads haus text holding one value and decodes it as a `T`. See
    /// ``decode(_:from:limits:)``.
    public func decode<T: Decodable>(_ type: T.Type, fromText text: String, limits: Limits = Limits())
        throws(HausError) -> T
    {
        try decode(type, from: parse(text, limits: limits), limits: limits)
    }

    /// Reads schema-based JSON (spec §16.3) and decodes it as a `T`.
    public func decode<T: Decodable>(_ type: T.Type, fromJSON text: String, limits: Limits = Limits())
        throws(HausError) -> T
    {
        try decodeTyped(type, fromJSON(text, limits: limits), prefix: [])
    }

    /// Decodes the values of a file: each value of a `Stream` definition on
    /// its own (an error's path starts with its index, `$[3].total`), or the
    /// one value of any other type.
    public func decodeAll<T: Decodable>(_ type: T.Type, from values: [HausValue], limits: Limits = Limits())
        throws(HausError) -> [T]
    {
        let decoded = try decodeAll(values, limits: limits)
        let state = CodingState()
        var out: [T] = []
        out.reserveCapacity(decoded.count)
        for (i, v) in decoded.enumerated() {
            out.append(try decodeTyped(type, v, prefix: isStream ? [.index(i)] : [], state: state))
        }
        return out
    }

    /// Encodes a Swift value with the type: the value its `Encodable`
    /// conformance writes, built with the type (`nil` as `None` for a
    /// `Maybe`, a float in its one spelling), and then encoded by the schema
    /// (spec §15), which checks it.
    public func encode(_ value: some Encodable, limits: Limits = Limits()) throws(HausError) -> HausValue {
        try encode(encodeTyped(value), limits: limits)
    }

    /// Writes a Swift value as haus text, encoded with the type as
    /// `encode(_:limits:)` encodes it.
    public func stringify(_ value: some Encodable, _ options: FormatOptions = FormatOptions()) throws(HausError)
        -> String
    {
        try Haus.stringify(encode(value, limits: options.limits), options)
    }

    /// Writes a Swift value as schema-based JSON (spec §16.3).
    public func toJSON(_ value: some Encodable, limits: Limits = Limits()) throws(HausError) -> String {
        try toJSON(encode(value, limits: limits), limits: limits)
    }

    func decodeTyped<T: Decodable>(
        _ type: T.Type, _ decoded: HausValue, prefix: [PathStep], state: CodingState = CodingState()
    ) throws(HausError) -> T {
        let decoder = SchemaDecoder(root: decoded, node, state, prefix: prefix)
        return try catching { try decodeValue(type, decoder) }
    }

    func encodeTyped(_ value: some Encodable) throws(HausError) -> HausValue {
        let encoder = SchemaEncoder(root: node, CodingState())
        return try catching { try encodeValue(value, encoder) }
    }
}

/// Runs `body`, whose errors are all ``HausError``s (the coders convert
/// the others where they happen).
func catching<T>(_ body: () throws -> T) throws(HausError) -> T {
    do {
        return try body()
    } catch let error as HausError {
        throw error
    } catch {
        throw HausError(.typeMismatch, "\(error)")
    }
}

// ── codecs (spec §13.4) ─────────────────────────────────────────

/// A codec (spec §13.4): a Swift type the application chooses for a named
/// haus type, by the type's id. It is decoded from the type's base value, the
/// one the schema decoded, so the schema's rules always run, and can reject
/// more values; it encodes back to a base value.
///
/// ```swift
/// struct Cents: HausCodec {
///     static let hausTypeID = "@haus-fmt/money@1#Money"
///     let cents: Int
///     init(hausBase money: Money) throws { … }   // throws to reject the value
///     var hausBase: Money { … }
/// }
/// ```
///
/// A rejection is `type-mismatch` at the value's place, with the message
/// `<id> rejects the value: <the error>`. Decoding runs codecs from the
/// inside out: a part's codec before the codec of the value that holds it.
public protocol HausCodec: Codable {
    /// The value the schema decodes, which the codec converts.
    associatedtype HausBase: Codable
    /// The id of the haus type (spec §13.3): `@haus-fmt/money@1#Money`,
    /// `std/time#Date`, `prelude#Decimal`.
    static var hausTypeID: String { get }
    /// The Swift value of a base value; an error rejects the value.
    init(hausBase: HausBase) throws
    /// The base value the Swift value encodes to.
    var hausBase: HausBase { get throws }
}

extension HausCodec {
    public init(from decoder: any Decoder) throws {
        let haus = decoder as? SchemaDecoder
        if let haus { try expectCodec(Self.self, Self.hausTypeID, haus.node, haus.place) }
        let base = try HausBase(from: decoder)
        do {
            try self.init(hausBase: base)
        } catch {
            throw haus?.rejection(Self.hausTypeID, error) ?? error
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if let haus = encoder as? SchemaEncoder { try expectCodec(Self.self, Self.hausTypeID, haus.node, haus.place) }
        try hausBase.encode(to: encoder)
    }
}

// ── the haus types as Swift types ───────────────────────────────

/// `HausValue` decodes as the value itself: `Any`, unknown values, or any
/// part kept as it is. Other coders read and write its canonical form.
extension HausValue: Codable {
    public init(from decoder: any Decoder) throws {
        if let haus = decoder as? SchemaDecoder {
            self = haus.value
        } else {
            self = try parse(decoder.singleValueContainer().decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if let haus = encoder as? SchemaEncoder {
            haus.store(self)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(canonical(self))
        }
    }
}

/// `HausNumber` decodes a `Decimal` (or any number) exactly. Other coders
/// read and write its literal as a string.
extension HausNumber: Codable {
    public init(from decoder: any Decoder) throws {
        if let haus = decoder as? SchemaDecoder {
            self = try haus.number()
        } else {
            self = try HausNumber(decoder.singleValueContainer().decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if let haus = encoder as? SchemaEncoder {
            haus.store(.number(self))
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(literal)
        }
    }
}

/// The marker of ``Secret``, which the coders recognize.
protocol SecretCoding {}

extension Secret: SecretCoding {}

/// A `Secret a` decodes as `a` does, into a `Secret` (spec §15): an error
/// inside it is `invalid-secret`, at the secret, without the value.
extension Secret: Decodable where Wrapped: Decodable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Wrapped.self))
    }
}

extension Secret: Encodable where Wrapped: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(reveal())
    }
}

/// `Optional`, for the coders: a `Maybe` is `None` exactly when it is nil.
protocol OptionalCoding {
    static var noValue: Self { get }
    var wrapped: Any? { get }
}

extension Optional: OptionalCoding {
    static var noValue: Self { nil }
    var wrapped: Any? { self.map { $0 } }
}

// ── case names ──────────────────────────────────────────────────

/// The name of the Swift enum case for a tag: its leading capitals in
/// lowercase, but the last one when a lowercase letter follows (`Shipped`
/// is `shipped`, `URL` `url`, `HTTPError` `httpError`, `NaN` `naN`), as
/// Swift names cases. A case named as the tag (`Shipped`) is accepted too.
func caseName(_ tag: String) -> String {
    let scalars = Array(tag.unicodeScalars)
    var upper = scalars.prefix { ("A"..."Z").contains($0) }.count
    if upper > 1 && upper < scalars.count && ("a"..."z").contains(scalars[upper]) { upper -= 1 }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars[..<upper].map { Unicode.Scalar($0.value | 0x20)! })
    out.append(contentsOf: scalars[upper...])
    return String(out)
}

/// The tag of an unknown value's case name, for values with no type: the
/// first letter in uppercase.
func tagName(_ caseName: String) -> String {
    guard let first = caseName.unicodeScalars.first, ("a"..."z").contains(first) else { return caseName }
    return String(Character(Unicode.Scalar(first.value & ~0x20)!)) + caseName.dropFirst()
}

/// What the coders of one value share: case names, computed once each.
final class CodingState {
    private var names: [String: String] = [:]
    private var tags: [ObjectIdentifier: [String: String]] = [:]

    /// The case name of `tag` (``caseName(_:)``).
    func name(_ tag: String) -> String {
        if let name = names[tag] { return name }
        let name = caseName(tag)
        names[tag] = name
        return name
    }

    /// The tag of `shape` whose case is called `name`, or nil.
    func tag(_ name: String, in shape: VariantShape) -> String? {
        let id = ObjectIdentifier(shape)
        if tags[id] == nil {
            tags[id] = Dictionary(shape.cases.map { (self.name($0.tag), $0.tag) }, uniquingKeysWith: { a, _ in a })
        }
        return tags[id]?[name] ?? shape.caseOf(name)?.tag
    }
}

// ── places ──────────────────────────────────────────────────────

/// Where a coder is: its parent and the step from it. Coders are places, made
/// per level, and a path (spec §15) or coding path is written out only when
/// asked for, so that the work stays linear in the value.
class Place {
    let parent: Place?
    /// The step from the parent: none for a record case's record, which is
    /// at the case's own place (spec §15).
    let step: PathStep?
    let key: (any CodingKey)?
    /// The path from `$` to the root (the index of a stream's value).
    let prefix: [PathStep]

    init(prefix: [PathStep]) {
        parent = nil
        step = nil
        key = nil
        self.prefix = prefix
    }

    init(_ parent: Place, _ step: PathStep?, _ key: (any CodingKey)?) {
        self.parent = parent
        self.step = step
        self.key = key
        prefix = []
    }

    var path: [PathStep] {
        var steps: [PathStep] = []
        var place: Place? = self
        while let p = place {
            if let step = p.step { steps.append(step) }
            if p.parent == nil { steps += p.prefix.reversed() }
            place = p.parent
        }
        return steps.reversed()
    }

    var codingPath: [any CodingKey] {
        var keys: [any CodingKey] = []
        var place: Place? = self
        while let p = place {
            if let key = p.key { keys.append(key) }
            place = p.parent
        }
        return keys.reversed()
    }

    /// Whether the place is inside a `Secret`.
    var inSecret: Bool { secret || (parent?.inSecret ?? false) }
    var secret = false

    /// An error here, at this place's path.
    @inline(never)
    func fail(_ code: HausError.Code, _ message: String, at step: PathStep? = nil) -> HausError {
        if inSecret { return HausError(.invalidSecret, "the secret doesn't fit its Swift type", path: secretPath) }
        return HausError(code, message, path: pathString(path + (step.map { [$0] } ?? [])))
    }

    /// The path of the outermost secret around this place.
    var secretPath: String {
        var place: Place? = self
        var outer = self
        while let p = place {
            if p.secret { outer = p }
            place = p.parent
        }
        return pathString(outer.path)
    }

    /// `error`, thrown by Swift code (a conformance) at this place, as a ``HausError``.
    @inline(never)
    func converted(_ error: any Error) -> HausError {
        if let error = error as? HausError { return error }
        let message: String
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return fail(.missingField, "the Swift type needs the field \(quoteForMessage(key.stringValue))")
        case DecodingError.typeMismatch(let type, let context), DecodingError.valueNotFound(let type, let context):
            message = "the Swift type \(type) doesn't fit: \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            message = context.debugDescription
        case EncodingError.invalidValue(_, let context):
            message = context.debugDescription
        default:
            message = "\(error)"
        }
        return fail(.typeMismatch, message)
    }
}
