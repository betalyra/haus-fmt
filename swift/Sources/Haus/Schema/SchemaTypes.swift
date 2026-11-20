// Resolved types: what a schema means once its names are looked up, its
// imports loaded and its generic types applied (spec §14, §15). Named types
// are instances, shared by every use; a reference to one is a node of kind
// `.ref`, which decoding follows to the instance's resolved body in one step.
//
// The nodes are classes: types refer to themselves through instances, and
// what the loader decides about a node (`jsonNull`) is kept on it. They are
// only changed while the schema loads, and immutable after.

/// The prelude's types without parameters.
enum Builtin: String, CaseIterable, Sendable {
    case string = "String"
    case bytes = "Bytes"
    case bool = "Bool"
    case decimal = "Decimal"
    case int = "Int"
    case int8 = "Int8"
    case int16 = "Int16"
    case int32 = "Int32"
    case int64 = "Int64"
    case uint8 = "UInt8"
    case uint16 = "UInt16"
    case uint32 = "UInt32"
    case uint64 = "UInt64"
    case float32 = "Float32"
    case float64 = "Float64"
    case any = "Any"

    /// The bits and signedness of a fixed-size integer type; nil for the others.
    var range: (bits: Int, signed: Bool)? {
        switch self {
        case .int8: (8, true)
        case .int16: (16, true)
        case .int32: (32, true)
        case .int64: (64, true)
        case .uint8: (8, false)
        case .uint16: (16, false)
        case .uint32: (32, false)
        case .uint64: (64, false)
        default: nil
        }
    }

    var isInteger: Bool { self == .int || range != nil }
    var isFloat: Bool { self == .float32 || self == .float64 }
}

/// A resolved type.
final class SchemaNode: @unchecked Sendable {
    enum Kind {
        case builtin(Builtin)
        /// A std/time type, by name.
        case time(String)
        case array(SchemaNode)
        case map(SchemaNode)
        case maybe(SchemaNode)
        case secret(SchemaNode)
        case record(RecordShape)
        /// A variant (`Result` too, as `closed < Err e | Ok a >`).
        case variant(VariantShape)
        /// A named type.
        case ref(Instance)
        /// A type parameter, only in the template of a generic type.
        case param(String)
    }

    let kind: Kind
    /// For a `Maybe` whose schema-based JSON writes `None` as `null`
    /// (spec §16.3); see `markJSONNull`.
    var jsonNull = false

    init(_ kind: Kind) { self.kind = kind }

    /// The type a reference stands for; the node itself otherwise.
    var resolved: SchemaNode {
        if case .ref(let inst) = kind { return inst.resolved }
        return self
    }

    /// The element of an array, map, maybe or secret.
    var element: SchemaNode? {
        switch kind {
        case .array(let e), .map(let e), .maybe(let e), .secret(let e): e
        default: nil
        }
    }
}

/// The number of fields or cases from which lookups use a dictionary.
let shapeIndexFrom = 9

/// `{ … }` or `closed { … }`.
final class RecordShape: @unchecked Sendable {
    let closed: Bool
    let fields: [FieldType]
    private let index: [CodePointKey: Int]?

    init(closed: Bool, fields: [FieldType]) {
        self.closed = closed
        self.fields = fields
        index =
            fields.count >= shapeIndexFrom
            ? Dictionary(
                fields.enumerated().map { (CodePointKey(string: $1.key), $0) }, uniquingKeysWith: { a, _ in a })
            : nil
    }

    /// The field `key`, or nil.
    func field(_ key: String) -> FieldType? {
        guard let index else { return fields.first { sameCodePoints($0.key, key) } }
        return index[CodePointKey(string: key)].map { fields[$0] }
    }
}

struct FieldType {
    let key: String
    let optional: Bool
    let type: SchemaNode
    let deprecated: Deprecation?
}

/// `@deprecated` or `@deprecated("why")` (spec §14).
struct Deprecation {
    let why: String
}

/// `< … >` or `closed < … >`.
final class VariantShape: @unchecked Sendable {
    let open: Bool
    let cases: [CaseType]
    private let index: [String: Int]?
    /// A closed variant whose tags have no payload: its schema-based JSON is
    /// the tag as a string (spec §16.3).
    let isEnum: Bool

    init(open: Bool, cases: [CaseType]) {
        self.open = open
        self.cases = cases
        isEnum = !open && cases.allSatisfy { if case .none = $0.payload { true } else { false } }
        index =
            cases.count >= shapeIndexFrom
            ? Dictionary(cases.enumerated().map { ($1.tag, $0) }, uniquingKeysWith: { a, _ in a })
            : nil
    }

    /// The case of `tag`, or nil: dispatch is one lookup (§9.8).
    func caseOf(_ tag: String) -> CaseType? {
        guard let index else { return cases.first { sameCodePoints($0.tag, tag) } }
        return index[tag].map { cases[$0] }.flatMap { sameCodePoints($0.tag, tag) ? $0 : nil }
    }
}

/// What a tag takes (spec §15, "Variants").
enum Payload {
    /// `Tag`
    case none
    /// `Tag { … }`: one record.
    case record(RecordShape)
    /// `Tag R`, `R` a named type that is a record: a record case too.
    case named(SchemaNode)
    /// `Tag A B`: exactly these values.
    case positional([SchemaNode])
}

struct CaseType {
    let tag: String
    let payload: Payload
    let deprecated: Deprecation?

    /// The record of a record case, or nil.
    var record: RecordShape? {
        switch payload {
        case .record(let r): r
        case .named(let t): if case .record(let r) = t.resolved.kind { r } else { nil }
        case .none, .positional: nil
        }
    }

    /// `_tag` or `_args`, if a record case has such a field: then it has no
    /// schema-based JSON form (§16.3).
    var reservedField: String? {
        record?.fields.first { sameCodePoints($0.key, "_tag") || sameCodePoints($0.key, "_args") }?.key
    }
}

/// A named type applied to arguments: its body with the parameters replaced.
final class Instance: @unchecked Sendable {
    let name: String
    /// The type's id (spec §13.3): `@haus-fmt/money@1#Money`, `Order`.
    let id: String
    let args: [SchemaNode]
    var body = SchemaNode(.builtin(.any))
    /// The body with references followed: never a `.ref`.
    var resolved = SchemaNode(.builtin(.any))
    /// Set for `type Events = Stream Event`: a file of bodies.
    var stream = false
    /// Its index among the schema's instances.
    let index: Int

    init(name: String, id: String, args: [SchemaNode], index: Int) {
        self.name = name
        self.id = id
        self.args = args
        self.index = index
    }
}

// ── descriptions, for messages ──────────────────────────────────

extension SchemaNode {
    /// A short description, as in a schema: `Array Line`, `Maybe Int`, `one
    /// of A, B`. Arguments nested deeper than a few levels are left out
    /// (`P (P (P … …) …) …`): they can be shared, so written in full they
    /// could double at every level.
    var described: String { describe(depth: 0) }

    func describe(depth: Int) -> String {
        switch kind {
        case .builtin(let b): return b.rawValue
        case .time(let name), .param(let name): return name
        case .array(let e): return "Array " + e.atom(depth)
        case .map(let e): return "Map " + e.atom(depth)
        case .maybe(let e): return "Maybe " + e.atom(depth)
        case .secret(let e): return "Secret " + e.atom(depth)
        case .record: return "a record"
        case .variant(let v): return v.tagList
        case .ref(let inst):
            guard !inst.args.isEmpty else { return inst.name }
            let args = inst.args.map { depth < 2 ? $0.atom(depth + 1) : "…" }
            let s = ([inst.name] + args).joined(separator: " ")
            return s.count > 80 ? inst.name + " …" : s
        }
    }

    func atom(_ depth: Int) -> String {
        let d = describe(depth: depth)
        let bare = !d.contains(" ") || d.hasPrefix("one of") || d == "a record" || d == "any tag"
        return bare ? d : "(\(d))"
    }
}

extension VariantShape {
    /// The tags, for messages: `one of A, B`, or `any tag` for `< >`.
    var tagList: String {
        guard !cases.isEmpty else { return "any tag" }
        let names = cases.prefix(6).map(\.tag) + (cases.count > 6 ? ["…"] : [])
        return "one of " + names.joined(separator: ", ")
    }
}
