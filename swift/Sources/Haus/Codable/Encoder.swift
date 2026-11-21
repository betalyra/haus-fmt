// The `Encoder` of typed values: a Swift value's `Encodable` conformance
// writes a haus value, built with its type, the mirror of Decoder.swift. The
// type decides what Swift's values become: `nil` is `None` for a `Maybe`
// and a missing field otherwise, a `String` is a std/time value's text or a
// tag, a `Double` a float in its one spelling (spec §15).

/// The value `x` writes with `encoder`. The recursion is this function (or
/// its copy in the keyed container's `encode(_:forKey:)`) and the
/// conformance's `encode(to:)`, so it only dispatches.
func encodeValue<T: Encodable>(_ x: T, _ encoder: SchemaEncoder) throws -> HausValue {
    if let special = try encodeSpecial(x, encoder) { return special }
    do {
        try x.encode(to: encoder)
        return try encoder.finish()
    } catch {
        throw encoder.converted(error)
    }
}

/// `x` at a `Maybe` or a `Secret`, a ``HausValue`` or a ``HausNumber``; nil
/// for the others.
@inline(never)
func encodeSpecial<T: Encodable>(_ x: T, _ e: SchemaEncoder) throws -> HausValue? {
    switch e.node?.resolved.kind {
    case .maybe(let element)?: return try encodeMaybe(x, e, element)
    case .secret(let item)?: return try encodeSecret(x, e, item)
    default:
        if let v = x as? HausValue { return v }
        return (x as? HausNumber).map { .number($0) }
    }
}

/// `x` at a `Maybe`: `None` for a nil `Optional`, `Some(…)` otherwise.
@inline(never)
func encodeMaybe<T: Encodable>(_ x: T, _ e: SchemaEncoder, _ element: SchemaNode) throws -> HausValue {
    guard let optional = x as? any OptionalCoding else { return try some(x, e, element) }
    guard let wrapped = optional.wrapped as? any Encodable else { return .tag("None") }
    return try some(wrapped, e, element)
}

/// `Some(x)`, `x` written with the `Maybe`'s element type.
func some<T: Encodable>(_ x: T, _ e: SchemaEncoder, _ element: SchemaNode) throws -> HausValue {
    .tag("Some", try encodeValue(x, SchemaEncoder(element, e.state, at: e, .index(0), nil)))
}

/// `x` at a `Secret a`: it must be a ``Secret``, whose errors don't show the value.
@inline(never)
func encodeSecret<T: Encodable>(_ x: T, _ e: SchemaEncoder, _ item: SchemaNode) throws -> HausValue {
    guard x is any SecretCoding else { throw e.fail(.typeMismatch, secretNeeded) }
    let inside = SchemaEncoder(item, e.state, at: e, nil, nil)
    inside.secret = true
    do {
        try x.encode(to: inside)
        return try inside.finish()
    } catch {
        throw inside.fail(.invalidSecret, "")
    }
}

/// A scalar a Swift value writes.
enum Scalar {
    case bool(Bool)
    case string(String)
    case integer(HausNumber)
    case double(Double)
    case float(Float)
}

extension Place {
    /// The value of a scalar at the type `n`, at this place or `step` below
    /// it: a `Secret` needs a ``Secret`` (`type-mismatch`), and a string for
    /// a variant must be a tag (`invalid-tag`).
    func scalarValue(_ s: Scalar, _ n: SchemaNode?, at step: PathStep? = nil) throws(HausError) -> HausValue {
        let v: HausValue?
        do {
            v = try scalarOf(s, n)
        } catch {
            throw fail(error.code, error.message, at: step)
        }
        guard let v else { throw fail(.typeMismatch, secretNeeded, at: step) }
        return v
    }
}

/// The value of a scalar at the type `n`; nil at a `Secret`, which needs a ``Secret``.
func scalarOf(_ s: Scalar, _ n: SchemaNode?) throws(HausError) -> HausValue? {
    let kind = n?.resolved.kind
    if case .maybe(let element)? = kind { return try scalarOf(s, element).map { .tag("Some", $0) } }
    switch (s, kind) {
    case (_, .secret?): return nil
    case (.bool(let b), _): return .tag(b ? "True" : "False")
    case (.string(let text), .time(let name)?): return .tag(HausTag(valid: name), .string(text))
    case (.string(let tag), .variant?): return .tag(try HausTag(tag))
    case (.string(let s), _): return .string(s)
    case (.integer(let n), _): return .number(n)
    case (.double(let d), .builtin(.float32)?): return floatValue(Double(Float(d)), .bits32)
    case (.double(let d), _): return floatValue(d, .bits64)
    case (.float(let f), .builtin(.float64)?): return floatValue(Double(f), .bits64)
    case (.float(let f), _): return floatValue(Double(f), .bits32)
    }
}

/// The encoder of one value: what its keyed, unkeyed or single-value
/// container wrote, made a value by ``finish()``. An encoder is the place
/// of its value (``Place``).
final class SchemaEncoder: Place, Encoder, SingleValueEncodingContainer {
    enum Stored {
        case nothing
        case value(HausValue)
        case fields(FieldsBox)
        case items(ItemsBox)
    }

    let node: SchemaNode?
    let state: CodingState
    var stored = Stored.nothing

    /// The encoder of a value at `step` (and `key`) from `parent`.
    init(_ node: SchemaNode?, _ state: CodingState, at parent: Place, _ step: PathStep?, _ key: (any CodingKey)?) {
        self.node = node
        self.state = state
        super.init(parent, step, key)
    }

    /// The encoder of a whole value.
    init(root node: SchemaNode?, _ state: CodingState) {
        self.node = node
        self.state = state
        super.init(prefix: [])
    }

    var place: Place { self }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func store(_ v: HausValue) { stored = .value(v) }

    /// An encoder of another value at this place and type.
    var again: SchemaEncoder { SchemaEncoder(node, state, at: self, nil, nil) }

    func container<Key: CodingKey>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .fields(let box) = stored { return KeyedEncodingContainer(SchemaKeyedEncoding<Key>(self, box)) }
        let box = FieldsBox(node.map { FieldTypes(of: $0.resolved) } ?? .untyped)
        stored = .fields(box)
        return KeyedEncodingContainer(SchemaKeyedEncoding<Key>(self, box))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if case .items(let box) = stored { return SchemaUnkeyedEncoding(self, box) }
        let box = ItemsBox(node?.resolved)
        stored = .items(box)
        return SchemaUnkeyedEncoding(self, box)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer { self }

    // ── the single value ────────────────────────────────────────

    func encodeNil() throws {
        switch node?.resolved.kind {
        case nil, .builtin(.any)?: stored = .value(.tag("None"))
        default: throw place.fail(.typeMismatch, "nil for \(node!.described), which isn't a Maybe")
        }
    }

    func scalar(_ s: Scalar) throws {
        stored = .value(try place.scalarValue(s, node))
    }

    func encode(_ value: Bool) throws { try scalar(.bool(value)) }
    func encode(_ value: String) throws { try scalar(.string(value)) }
    func encode(_ value: Double) throws { try scalar(.double(value)) }
    func encode(_ value: Float) throws { try scalar(.float(value)) }
    func encode(_ value: Int) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: Int8) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: Int16) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: Int32) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: Int64) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: UInt) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: UInt8) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: UInt16) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: UInt32) throws { try scalar(.integer(HausNumber(value))) }
    func encode(_ value: UInt64) throws { try scalar(.integer(HausNumber(value))) }
    func encode<T: Encodable>(_ value: T) throws { stored = .value(try encodeValue(value, again)) }

    // ── the value written ───────────────────────────────────────

    /// The value the containers wrote.
    func finish() throws -> HausValue {
        switch stored {
        case .nothing: throw place.fail(.typeMismatch, "the Swift value wrote nothing")
        case .value(let v): return v
        case .items(let box): return try box.value
        case .fields(let box): return try fieldsValue(box)
        }
    }

    /// The value of a keyed container: a record, or a variant.
    @inline(never)
    func fieldsValue(_ box: FieldsBox) throws -> HausValue {
        if let chosen = box.chosen { return try chosen.value(state, at: place) }
        switch box.types {
        case .variant(let shape):
            // A struct for a variant of one case: its payload.
            guard shape.cases.count == 1 else {
                throw place.fail(.typeMismatch, "a struct for \(shape.tagList): only a variant of one case can be one")
            }
            return try Chosen(tag: shape.cases[0].tag, shape.cases[0], box).value(state, at: place)
        case .shape(let shape): return .record(try box.record(filling: shape))
        default: return .record(try box.record(filling: nil))
        }
    }
}

/// The types of the entries a keyed container writes.
enum FieldTypes {
    case shape(RecordShape)
    case element(SchemaNode)
    case each([SchemaNode])
    case variant(VariantShape)
    case untyped

    init(of resolved: SchemaNode) {
        switch resolved.kind {
        case .record(let shape): self = .shape(shape)
        case .map(let element): self = .element(element)
        case .variant(let shape): self = .variant(shape)
        default: self = .untyped
        }
    }

    /// The types of a case's payload.
    init(of c: CaseType) {
        switch c.payload {
        case .none: self = .each([])
        case .positional(let items): self = .each(items)
        case .record, .named: self = c.record.map { .shape($0) } ?? .untyped
        }
    }

    /// The type and the step of the entry `key`.
    func entry(_ key: String) -> (node: SchemaNode?, step: PathStep?) {
        switch self {
        case .shape(let shape): (shape.field(key)?.type, .key(key))
        case .element(let element): (element, .key(key))
        case .each(let items):
            argumentIndex(key, items.count).map { (items[$0], .index($0)) } ?? (nil, .key(key))
        case .variant(let shape):
            shape.cases.count == 1 ? FieldTypes(of: shape.cases[0]).entry(key) : (nil, .key(key))
        case .untyped: (nil, .key(key))
        }
    }
}

/// What a keyed container wrote.
final class FieldsBox {
    enum Entry {
        case value(HausValue)
        case encoder(SchemaEncoder)
    }

    let types: FieldTypes
    var fields: [(key: String, entry: Entry)] = []
    /// The case a Swift enum chose (`nestedContainer(keyedBy:forKey:)`).
    var chosen: Chosen?

    init(_ types: FieldTypes) { self.types = types }

    func set(_ key: String, _ entry: Entry) {
        if let i = fields.firstIndex(where: { sameCodePoints($0.key, key) }) {
            fields[i].entry = entry
        } else {
            fields.append((key, entry))
        }
    }

    func value(_ i: Int) throws -> HausValue {
        switch fields[i].entry {
        case .value(let v): v
        case .encoder(let encoder): try encoder.finish()
        }
    }

    /// The fields as a record; with a shape, a `Maybe` field not written is `None`.
    func record(filling shape: RecordShape?) throws -> HausRecord {
        var out: [HausRecord.Field] = try fields.indices.map { (fields[$0].key, try value($0)) }
        for field in shape?.fields ?? [] where !field.optional {
            if case .maybe = field.type.resolved.kind, !out.contains(where: { sameCodePoints($0.key, field.key) }) {
                out.append((field.key, .tag("None")))
            }
        }
        return HausRecord(distinct: out)
    }

    /// The written entry called `key`.
    func entry(_ key: String) throws -> HausValue? {
        try fields.firstIndex { sameCodePoints($0.key, key) }.map(value)
    }
}

/// The case a Swift enum chose, and its payload.
struct Chosen {
    /// The tag; nil for `unknown`, whose `_0` is the whole value.
    let tag: String?
    let `case`: CaseType?
    let payload: FieldsBox

    init(tag: String?, _ c: CaseType?, _ payload: FieldsBox) {
        self.tag = tag
        self.case = c
        self.payload = payload
    }

    /// The variant, at `place`. A Swift case name that makes no tag fails
    /// with `invalid-tag` (spec §11).
    func value(_ state: CodingState, at place: Place) throws -> HausValue {
        guard let name = tag else { return try payload.entry("_0") ?? .tag("None") }
        let tag: HausTag
        do {
            tag = try HausTag(name)
        } catch {
            throw place.fail(error.code, error.message)
        }
        switch self.case?.payload {
        case .none?: return .tag(tag)
        case .positional(let items)?: return .variant(tag, try arguments(items.count))
        case .record?, .named?:
            if let whole = try payload.entry("_0") { return .variant(tag, [whole]) }
            return .variant(tag, [.record(try payload.record(filling: self.case?.record))])
        case nil:
            // A tag the type doesn't list: positional if every key is `_i`.
            if payload.fields.isEmpty { return .tag(tag) }
            if payload.fields.allSatisfy({ $0.key.hasPrefix("_") }) {
                return .variant(tag, try arguments(payload.fields.count))
            }
            return .variant(tag, [.record(try payload.record(filling: nil))])
        }
    }

    /// The `n` arguments of a positional case: `_0`, `_1`…, or the one labelled argument.
    func arguments(_ n: Int) throws -> [HausValue] {
        if n == 1, payload.fields.count == 1 { return [try payload.value(0)] }
        return try (0..<n).compactMap { try payload.entry("_\($0)") }
    }
}

// ── keyed containers ────────────────────────────────────────────

struct SchemaKeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: SchemaEncoder
    let box: FieldsBox

    init(_ encoder: SchemaEncoder, _ box: FieldsBox) {
        self.encoder = encoder
        self.box = box
    }

    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func scalar(_ s: Scalar, _ key: Key) throws {
        let (node, step) = box.types.entry(key.stringValue)
        box.set(key.stringValue, .value(try encoder.place.scalarValue(s, node, at: step)))
    }

    /// `nil` for a field: `None` for a `Maybe`, and otherwise no field.
    mutating func encodeNil(forKey key: Key) throws {
        guard case .maybe? = box.types.entry(key.stringValue).node?.resolved.kind else { return }
        box.set(key.stringValue, .value(.tag("None")))
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws { try scalar(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { try scalar(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try scalar(.double(value), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try scalar(.float(value), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try scalar(.integer(HausNumber(value)), key) }

    /// ``encodeValue(_:_:_:_:)``, inline: one frame per level.
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let child = fieldEncoder(key)
        if let special = try encodeSpecial(value, child) {
            return box.set(key.stringValue, .value(special))
        }
        do {
            try value.encode(to: child)
            box.set(key.stringValue, .value(try child.finish()))
        } catch {
            throw child.place.converted(error)
        }
    }

    /// An encoder for the field `key`.
    @inline(never)
    func fieldEncoder(_ key: Key) -> SchemaEncoder {
        let (node, step) = box.types.entry(key.stringValue)
        return SchemaEncoder(node, encoder.state, at: encoder, step, key)
    }

    /// A present optional value: at a `Maybe`, `Some` of it, also when it
    /// is itself an `Optional` (`Maybe (Maybe a)` and `T??`).
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        guard let value else { return }
        let child = fieldEncoder(key)
        let v =
            if case .maybe(let element)? = child.node?.resolved.kind {
                try some(value, child, element)
            } else {
                try encodeValue(value, child)
            }
        box.set(key.stringValue, .value(v))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key)
        -> KeyedEncodingContainer<NestedKey>
    {
        if let chosen = choose(key.stringValue) {
            box.chosen = chosen
            return KeyedEncodingContainer(SchemaKeyedEncoding<NestedKey>(encoder, chosen.payload))
        }
        return child(key).container(keyedBy: keyType)
    }

    /// The case of a Swift enum's key: a case of the variant, `unknown`, or
    /// for a variant the type doesn't describe, a tag.
    func choose(_ name: String) -> Chosen? {
        switch box.types {
        case .variant(let shape):
            if let tag = encoder.state.tag(name, in: shape), let c = shape.caseOf(tag) {
                return Chosen(tag: tag, c, FieldsBox(FieldTypes(of: c)))
            }
        case .untyped:
            break
        default:
            return nil
        }
        return Chosen(tag: name == "unknown" ? nil : tagName(name), nil, FieldsBox(.untyped))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        child(key).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder { encoder }

    mutating func superEncoder(forKey key: Key) -> any Encoder { child(key) }

    /// An encoder for the field `key`, whose value it gives when the record is made.
    func child(_ key: Key) -> SchemaEncoder {
        let child = fieldEncoder(key)
        box.set(key.stringValue, .encoder(child))
        return child
    }
}

// ── unkeyed containers ──────────────────────────────────────────

/// What an unkeyed container wrote: the items of an array, or the bytes of a
/// byte string.
final class ItemsBox {
    let element: SchemaNode?
    let isBytes: Bool
    var items: [FieldsBox.Entry] = []
    var bytes: [UInt8] = []

    init(_ resolved: SchemaNode?) {
        switch resolved?.kind {
        case .array(let element)?:
            self.element = element
            isBytes = false
        case .builtin(.bytes)?:
            element = nil
            isBytes = true
        default:
            element = nil
            isBytes = false
        }
    }

    var count: Int { isBytes ? bytes.count : items.count }

    var value: HausValue {
        get throws {
            if isBytes { return .bytes(bytes) }
            return .array(
                try items.map {
                    switch $0 {
                    case .value(let v): v
                    case .encoder(let encoder): try encoder.finish()
                    }
                })
        }
    }
}

struct SchemaUnkeyedEncoding: UnkeyedEncodingContainer {
    let encoder: SchemaEncoder
    let box: ItemsBox

    init(_ encoder: SchemaEncoder, _ box: ItemsBox) {
        self.encoder = encoder
        self.box = box
    }

    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int { box.count }

    mutating func append(_ s: Scalar) throws {
        guard !box.isBytes else { throw encoder.place.fail(.typeMismatch, "only UInt8 values make a byte string") }
        box.items.append(.value(try encoder.place.scalarValue(s, box.element, at: .index(box.count))))
    }

    mutating func encodeNil() throws {
        guard !box.isBytes else { throw encoder.place.fail(.typeMismatch, "nil in a byte string") }
        box.items.append(.value(.tag("None")))
    }

    mutating func encode(_ value: Bool) throws { try append(.bool(value)) }
    mutating func encode(_ value: String) throws { try append(.string(value)) }
    mutating func encode(_ value: Double) throws { try append(.double(value)) }
    mutating func encode(_ value: Float) throws { try append(.float(value)) }
    mutating func encode(_ value: Int) throws { try append(.integer(HausNumber(value))) }
    mutating func encode(_ value: Int8) throws { try append(.integer(HausNumber(value))) }
    mutating func encode(_ value: Int16) throws { try append(.integer(HausNumber(value))) }
    mutating func encode(_ value: Int32) throws { try append(.integer(HausNumber(value))) }
    mutating func encode(_ value: Int64) throws { try append(.integer(HausNumber(value))) }
    mutating func encode(_ value: UInt) throws { try append(.integer(HausNumber(value))) }
    mutating func encode(_ value: UInt16) throws { try append(.integer(HausNumber(value))) }
    mutating func encode(_ value: UInt32) throws { try append(.integer(HausNumber(value))) }
    mutating func encode(_ value: UInt64) throws { try append(.integer(HausNumber(value))) }

    mutating func encode(_ value: UInt8) throws {
        // Bytes, one at a time (`[UInt8]`, `Data`), without making numbers.
        guard box.isBytes else { return try append(.integer(HausNumber(value))) }
        box.bytes.append(value)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        guard !box.isBytes else {
            guard let byte = value as? UInt8 else {
                throw encoder.place.fail(.typeMismatch, "only UInt8 values make a byte string")
            }
            return box.bytes.append(byte)
        }
        box.items.append(.value(try encodeValue(value, itemEncoder())))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type)
        -> KeyedEncodingContainer<NestedKey>
    {
        child().container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { child().unkeyedContainer() }

    mutating func superEncoder() -> any Encoder { child() }

    func child() -> SchemaEncoder {
        let child = itemEncoder()
        box.items.append(.encoder(child))
        return child
    }

    /// An encoder for the next item.
    func itemEncoder() -> SchemaEncoder {
        SchemaEncoder(box.element, encoder.state, at: encoder, .index(box.count), IndexKey(box.count))
    }
}
