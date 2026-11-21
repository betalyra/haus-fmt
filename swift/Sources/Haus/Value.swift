/// A haus value (spec §1).
///
/// Equality and hashing are haus equality (spec §2): numbers by their
/// normalized literals, strings by code points (not by Swift's canonical
/// equivalence: `"café"` in NFC and in NFD are different values), records by
/// their keys and values whatever the order, and `Tag { … }` the same as
/// `Tag({ … })`, both a variant with one record argument.
///
/// Equality doesn't recurse, and hashing covers the first
/// ``hashedLevels`` levels; releasing a value recurses once per level of
/// nesting: the parser never gives values deeper than
/// ``Limits/maxSupportedDepth``, and values built in code should stay within
/// it too.
///
/// ```swift
/// let order = try parse(#"{ id: 7, status: Shipped { tracking: "DE-4711" } }"#)
/// if case .variant("Shipped", let args)? = order["status"] {
///     print(args[0]["tracking"]!) // "DE-4711"
/// }
/// ```
public enum HausValue: Sendable {
    /// An exact decimal number, kept as its normalized literal (spec §3).
    case number(HausNumber)
    /// A sequence of Unicode code points (spec §4).
    case string(String)
    /// A sequence of bytes, written `x"0b34ff"`.
    case bytes([UInt8])
    /// An ordered sequence of values.
    case array([HausValue])
    /// Fields with distinct string keys, in the order they were written.
    case record(HausRecord)
    /// A tag with zero or more arguments: `None`, `Some(1)`, `Circle { r: 1 }`
    /// (one record argument).
    case variant(String, [HausValue])
}

extension HausValue {
    /// The variant `tag(args…)`: `.tag("None")`, `.tag("Some", 1)`.
    public static func tag(_ tag: String, _ args: HausValue...) -> HausValue {
        .variant(tag, args)
    }

    /// The value of the field `key`, for a record or a variant whose one
    /// argument is a record (`Tag { … }`); nil otherwise.
    public subscript(key: String) -> HausValue? {
        switch self {
        case .record(let r): r[key]
        case .variant(_, let args) where args.count == 1:
            if case .record(let r) = args[0] { r[key] } else { nil }
        default: nil
        }
    }

    /// The element at `index` of an array, or argument of a variant; nil if
    /// there is none.
    public subscript(index: Int) -> HausValue? {
        switch self {
        case .array(let items), .variant(_, let items): items.indices.contains(index) ? items[index] : nil
        default: nil
        }
    }
}

// ── equality (spec §2) ──────────────────────────────────────────

extension HausValue: Hashable {
    /// Haus equality (spec §2). It doesn't recurse: the pairs of values
    /// still to compare are kept in a list.
    public static func == (a: HausValue, b: HausValue) -> Bool {
        var pending = [(a, b)]
        while let (x, y) = pending.popLast() {
            guard x.sameShape(y, adding: &pending) else { return false }
        }
        return true
    }

    /// Whether this value and `other` are the same but for their items, which
    /// are added to `pending` in pairs.
    private func sameShape(_ other: HausValue, adding pending: inout [(HausValue, HausValue)]) -> Bool {
        switch (self, other) {
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return sameCodePoints(x, y)
        case (.bytes(let x), .bytes(let y)): return x == y
        case (.array(let x), .array(let y)): return sameItems(x, y, adding: &pending)
        case (.variant(let t, let x), .variant(let u, let y)):
            return sameCodePoints(t, u) && sameItems(x, y, adding: &pending)
        case (.record(let x), .record(let y)):
            guard x.count == y.count else { return false }
            for (key, value) in x.fields {
                guard let other = y[key] else { return false }
                pending.append((value, other))
            }
            return true
        default: return false
        }
    }

    /// The levels of a value that its hash covers: values that differ only
    /// deeper down hash alike, which keeps hashing linear and flat.
    static let hashedLevels = 4

    public func hash(into hasher: inout Hasher) {
        hash(into: &hasher, levels: Self.hashedLevels)
    }

    /// Hashes this value, and its items down to `levels` levels.
    func hash(into hasher: inout Hasher, levels: Int) {
        switch self {
        case .number(let n):
            hasher.combine(0)
            hasher.combine(n)
        case .string(let s):
            hasher.combine(1)
            hashCodePoints(s, into: &hasher)
        case .bytes(let b):
            hasher.combine(2)
            hasher.combine(b)
        case .array(let items):
            hasher.combine(3)
            hashItems(items, into: &hasher, levels: levels)
        case .record(let r):
            hasher.combine(4)
            r.hash(into: &hasher, levels: levels)
        case .variant(let tag, let args):
            hasher.combine(5)
            hashCodePoints(tag, into: &hasher)
            hashItems(args, into: &hasher, levels: levels)
        }
    }
}

/// Whether two lists of items have the same length, adding their items to
/// `pending` in pairs unless they are the same storage.
private func sameItems(_ x: [HausValue], _ y: [HausValue], adding pending: inout [(HausValue, HausValue)]) -> Bool {
    guard x.count == y.count else { return false }
    let shared = x.withUnsafeBufferPointer { a in y.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
    if !shared { pending += zip(x, y) }
    return true
}

/// Hashes the number of items, and the items down to `levels` levels.
private func hashItems(_ items: [HausValue], into hasher: inout Hasher, levels: Int) {
    hasher.combine(items.count)
    guard levels > 0 else { return }
    for item in items { item.hash(into: &hasher, levels: levels - 1) }
}

/// Whether two strings are the same code points (spec §2, §4). Swift's `==`
/// compares strings by canonical equivalence, which haus doesn't.
func sameCodePoints(_ a: String, _ b: String) -> Bool {
    a.utf8.count == b.utf8.count && withUTF8(a) { x in withUTF8(b) { y in sameBytes(x, y) } }
}

/// Hashes the code points of a string, consistent with ``sameCodePoints(_:_:)``.
func hashCodePoints(_ s: String, into hasher: inout Hasher) {
    hasher.combine(s.utf8.count)
    withUTF8(s) { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
}

/// A string compared and hashed by its code points, for dictionaries of
/// record keys.
struct CodePointKey: Hashable, Sendable {
    let string: String

    static func == (a: CodePointKey, b: CodePointKey) -> Bool { sameCodePoints(a.string, b.string) }
    func hash(into hasher: inout Hasher) { hashCodePoints(string, into: &hasher) }
}

// ── literals ────────────────────────────────────────────────────

extension HausValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension HausValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(HausNumber(value)) }
}

extension HausValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: HausValue...) { self = .array(elements) }
}

extension HausValue: ExpressibleByDictionaryLiteral {
    /// A record of the fields, in order. The keys must be distinct.
    public init(dictionaryLiteral elements: (String, HausValue)...) {
        do {
            self = .record(try HausRecord(elements.map { (key: $0, value: $1) }))
        } catch {
            preconditionFailure("\(error)")
        }
    }
}

extension HausValue: CustomStringConvertible {
    /// The value in the compact layout (spec §11).
    public var description: String {
        do {
            return String(try stringify(self, FormatOptions(layout: .compact)).dropLast())
        } catch {
            return "<\(error)>"
        }
    }
}

// ── records ─────────────────────────────────────────────────────

/// The fields of a record: distinct string keys, in the order they were
/// written. Field order is kept for formatting but doesn't take part in
/// equality (spec §2). Keys are compared by code point (spec §4).
public struct HausRecord: Sendable, Hashable, RandomAccessCollection {
    public typealias Field = (key: String, value: HausValue)

    /// The fields, in order.
    public let fields: [Field]
    /// Where each key is.
    private let index: KeyIndex

    /// A record of the fields, in order. It fails with the code
    /// `duplicate-key` if two fields have the same key.
    public init(_ fields: [Field]) throws(HausError) {
        var builder = RecordBuilder()
        for (key, value) in fields {
            guard builder.isNew(key) else {
                throw HausError(.duplicateKey, "the key \(quoteForMessage(key)) is in the record twice")
            }
            builder.append(key, value)
        }
        self = builder.record
    }

    /// A record of fields with distinct keys, and their index.
    fileprivate init(unique fields: [Field], index: KeyIndex) {
        self.fields = fields
        self.index = index
    }

    /// A record of fields whose keys are known to be distinct.
    init(distinct fields: [Field]) {
        var builder = RecordBuilder()
        for (key, value) in fields {
            _ = builder.isNew(key)
            builder.append(key, value)
        }
        self = builder.record
    }

    /// The empty record.
    public init() { self.init(unique: [], index: KeyIndex()) }

    /// The record with the keys of `record`, in order, and `values`, one per key.
    init(keysOf record: HausRecord, values: [HausValue]) {
        self.init(unique: zip(record.fields, values).map { ($0.key, $1) }, index: record.index)
    }

    /// The value of the field `key`, or nil if there is none.
    public subscript(key: String) -> HausValue? {
        index.find(key, in: fields).map { fields[$0].value }
    }

    /// The keys, in order.
    public var keys: [String] { fields.map(\.key) }

    public var startIndex: Int { fields.startIndex }
    public var endIndex: Int { fields.endIndex }
    public subscript(position: Int) -> Field { fields[position] }

    public static func == (a: HausRecord, b: HausRecord) -> Bool {
        HausValue.record(a) == .record(b)
    }

    /// Hashes the fields whatever their order, down to
    /// ``HausValue/hashedLevels`` levels.
    public func hash(into hasher: inout Hasher) {
        hash(into: &hasher, levels: HausValue.hashedLevels)
    }

    func hash(into hasher: inout Hasher, levels: Int) {
        hasher.combine(count)
        guard levels > 0 else { return }
        hasher.combine(
            fields.reduce(0) { sum, field in
                var h = Hasher()
                hashCodePoints(field.key, into: &h)
                field.value.hash(into: &h, levels: levels - 1)
                return sum &+ h.finalize()
            })
    }
}

/// The fields of a record being built, for the parsers and
/// ``HausRecord/init(_:)``: repeated keys are found in linear time whatever
/// the keys (spec §7, ``KeyIndex``).
struct RecordBuilder {
    private var fields: [HausRecord.Field] = []
    private var index = KeyIndex()

    /// Whether no field so far has the key `key`. If so, the key is added:
    /// the next field appended must have it.
    mutating func isNew(_ key: String) -> Bool {
        index.insert(key, after: fields)
    }

    /// Adds the field of the key ``isNew(_:)`` added.
    mutating func append(_ key: String, _ value: HausValue) {
        fields.append((key, value))
    }

    var record: HausRecord { HausRecord(unique: fields, index: index) }
}
