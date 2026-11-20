/// A haus value (spec §1).
///
/// Equality and hashing are haus equality (spec §2): numbers by their
/// normalized literals, strings by code points (not by Swift's canonical
/// equivalence: `"café"` in NFC and in NFD are different values), records by
/// their keys and values whatever the order, and `Tag { … }` the same as
/// `Tag({ … })`, both a variant with one record argument.
///
/// Equality, hashing and releasing a value recurse once per level of
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
    public static func == (a: HausValue, b: HausValue) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): x == y
        case (.string(let x), .string(let y)): sameCodePoints(x, y)
        case (.bytes(let x), .bytes(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.record(let x), .record(let y)): x == y
        case (.variant(let t, let x), .variant(let u, let y)): sameCodePoints(t, u) && x == y
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
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
            hasher.combine(items)
        case .record(let r):
            hasher.combine(4)
            hasher.combine(r)
        case .variant(let tag, let args):
            hasher.combine(5)
            hashCodePoints(tag, into: &hasher)
            hasher.combine(args)
        }
    }
}

/// Whether two strings are the same code points (spec §2, §4). Swift's `==`
/// compares strings by canonical equivalence, which haus doesn't.
func sameCodePoints(_ a: String, _ b: String) -> Bool {
    a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
}

/// Hashes the code points of a string, consistent with ``sameCodePoints(_:_:)``.
func hashCodePoints(_ s: String, into hasher: inout Hasher) {
    hasher.combine(s.utf8.count)
    for c in s.utf8 { hasher.combine(c) }
}

/// A string compared and hashed by its code points, for dictionaries of
/// record keys.
struct CodePointKey: Hashable {
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
    /// Where each key is, for records of at least ``indexFrom`` fields.
    private let index: [CodePointKey: Int]?

    /// The number of fields from which a record keeps an index of its keys;
    /// smaller ones are searched in order. Swift's `Hasher` is seeded at
    /// random per process, as spec §7 asks of duplicate-key checks.
    static let indexFrom = 17

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

    /// A record of fields with distinct keys, and their index if there are
    /// at least ``indexFrom``.
    fileprivate init(unique fields: [Field], index: [CodePointKey: Int]?) {
        self.fields = fields
        self.index = index
    }

    /// The empty record.
    public init() { self.init(unique: [], index: nil) }

    /// The value of the field `key`, or nil if there is none.
    public subscript(key: String) -> HausValue? {
        guard let index else {
            return fields.first { sameCodePoints($0.key, key) }?.value
        }
        return index[CodePointKey(string: key)].map { fields[$0].value }
    }

    /// The keys, in order.
    public var keys: [String] { fields.map(\.key) }

    public var startIndex: Int { fields.startIndex }
    public var endIndex: Int { fields.endIndex }
    public subscript(position: Int) -> Field { fields[position] }

    public static func == (a: HausRecord, b: HausRecord) -> Bool {
        a.count == b.count && a.fields.allSatisfy { field in b[field.key] == field.value }
    }

    /// Hashes the fields whatever their order.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        hasher.combine(
            fields.reduce(0) { sum, field in
                var h = Hasher()
                hashCodePoints(field.key, into: &h)
                h.combine(field.value)
                return sum &+ h.finalize()
            })
    }
}

/// The fields of a record being built, for the parser and
/// ``HausRecord/init(_:)``: repeated keys are found in linear time whatever
/// the keys (spec §7), by a scan while the record is small and by an index
/// of its keys (`Hasher`, seeded at random) from ``HausRecord/indexFrom`` on.
struct RecordBuilder {
    private var fields: [HausRecord.Field] = []
    private var index: [CodePointKey: Int]?

    /// Whether no field so far has the key `key`.
    @inline(never)
    mutating func isNew(_ key: String) -> Bool {
        if let index { return index[CodePointKey(string: key)] == nil }
        guard !fields.contains(where: { sameCodePoints($0.key, key) }) else { return false }
        if fields.count + 1 >= HausRecord.indexFrom {
            index = Dictionary(uniqueKeysWithValues: fields.enumerated().map { (CodePointKey(string: $1.key), $0) })
        }
        return true
    }

    /// Adds a field whose key ``isNew(_:)`` said is new.
    mutating func append(_ key: String, _ value: HausValue) {
        index?[CodePointKey(string: key)] = fields.count
        fields.append((key, value))
    }

    var record: HausRecord { HausRecord(unique: fields, index: index) }
}
