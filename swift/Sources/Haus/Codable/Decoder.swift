// The `Decoder` of typed values: a decoded haus value and its type, read by
// a Swift type's `Decodable` conformance. Records are keyed containers;
// variants are keyed containers in the shape of Swift's synthesized enum
// conformances (one key, the case name, whose nested container holds the
// payload: a record case's fields, `_0`, `_1`… for positional arguments);
// arrays and byte strings unkeyed containers; the rest single values.

/// Decodes a `T` with `decoder`. The recursion is this function (or its
/// copy in the keyed container's `decode(_:forKey:)`) and the conformance's
/// `init(from:)`, so it only dispatches: a debug build gives a function a
/// stack slot for every temporary, and values as deep as the depth limit
/// decode on the 512 KiB stack of a thread of Swift's concurrency pool.
func decodeValue<T: Decodable>(_ type: T.Type, _ decoder: SchemaDecoder) throws -> T {
    if let special = try decodeSpecial(type, decoder) { return special }
    do {
        return try T(from: decoder)
    } catch {
        throw decoder.converted(error)
    }
}

/// A `T` at a `Maybe` or a `Secret`, a ``HausValue`` or a ``HausNumber``;
/// nil for the others.
@inline(never)
func decodeSpecial<T: Decodable>(_ type: T.Type, _ d: SchemaDecoder) throws -> T? {
    switch d.node?.resolved.kind {
    case .maybe(let element)?: return try decodeMaybe(type, d, element)
    case .secret(let item)?: return try decodeSecret(type, d, item)
    default:
        if T.self == HausValue.self { return (d.value as! T) }
        return T.self == HausNumber.self ? (try d.number() as! T) : nil
    }
}

/// A `T` at a `Maybe`: an `Optional` is nil for `None`; `Some(x)` is `x`.
@inline(never)
func decodeMaybe<T: Decodable>(_ type: T.Type, _ d: SchemaDecoder, _ element: SchemaNode) throws -> T {
    guard case .variant("Some", let args) = d.value, args.count == 1 else {
        guard let optional = T.self as? any OptionalCoding.Type else {
            throw d.fail(.typeMismatch, "None, but the Swift type \(T.self) isn't Optional")
        }
        return optional.noValue as! T
    }
    return try decodeValue(type, SchemaDecoder(args[0], element, d.state, at: d, .index(0), nil))
}

/// A `T` at a `Secret a`: a ``Secret``, whose errors don't show the value.
@inline(never)
func decodeSecret<T: Decodable>(_ type: T.Type, _ d: SchemaDecoder, _ item: SchemaNode) throws -> T {
    guard T.self is any SecretCoding.Type else { throw d.fail(.typeMismatch, secretNeeded) }
    let inside = SchemaDecoder(d.value, item, d.state, at: d, nil, nil)
    inside.secret = true
    do {
        return try T(from: inside)
    } catch {
        throw inside.fail(.invalidSecret, "")
    }
}

/// The decoder of one value: its keyed, unkeyed or single-value container.
/// A decoder is the place of its value (``Place``), so that a value costs
/// one object.
final class SchemaDecoder: Place, Decoder, SingleValueDecodingContainer {
    let value: HausValue
    /// The value's type, as written (a reference is followed when needed,
    /// so that codecs see the type's id); nil if it has none (`Any`, the
    /// arguments of an unknown value).
    let node: SchemaNode?
    let state: CodingState
    /// The tag of a variant whose case the Swift type lacks, once its
    /// container found out.
    var missingCase: String?

    /// The decoder of `value`, at `step` (and `key`) from `parent`.
    init(
        _ value: HausValue, _ node: SchemaNode?, _ state: CodingState, at parent: Place, _ step: PathStep?,
        _ key: (any CodingKey)?
    ) {
        self.value = value
        self.node = node
        self.state = state
        super.init(parent, step, key)
    }

    /// The decoder of a whole value, whose path starts with `prefix`.
    init(root value: HausValue, _ node: SchemaNode?, _ state: CodingState, prefix: [PathStep]) {
        self.value = value
        self.node = node
        self.state = state
        super.init(prefix: prefix)
    }

    var place: Place { self }
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    var slot: Slot { Slot(value: value, node: node, parent: place, step: nil) }

    func container<Key: CodingKey>(keyedBy: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(try SchemaKeyedDecoding<Key>(self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try SchemaUnkeyedDecoding(self)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { self }

    // ── the single value ────────────────────────────────────────

    func decodeNil() -> Bool { slot.isNone }
    func decode(_ type: Bool.Type) throws -> Bool { try slot.bool() }
    func decode(_ type: String.Type) throws -> String { try slot.string() }
    func decode(_ type: Double.Type) throws -> Double { try slot.float() }
    func decode(_ type: Float.Type) throws -> Float { try slot.float() }
    func decode(_ type: Int.Type) throws -> Int { try slot.integer() }
    func decode(_ type: Int8.Type) throws -> Int8 { try slot.integer() }
    func decode(_ type: Int16.Type) throws -> Int16 { try slot.integer() }
    func decode(_ type: Int32.Type) throws -> Int32 { try slot.integer() }
    func decode(_ type: Int64.Type) throws -> Int64 { try slot.integer() }
    func decode(_ type: UInt.Type) throws -> UInt { try slot.integer() }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try slot.integer() }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try slot.integer() }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try slot.integer() }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try slot.integer() }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decodeValue(type, self) }

    /// The value as a number, for ``HausNumber``.
    func number() throws -> HausNumber { try slot.number() }

    // ── codecs and errors ───────────────────────────────────────

    /// A codec's rejection of the value (spec §13.4).
    func rejection(_ id: String, _ error: any Error) -> HausError {
        place.fail(.codecRejected, "\(id) rejects the value: \(error)")
    }

    /// An error of a conformance, as a ``HausError`` at this value.
    @inline(never)
    override func converted(_ error: any Error) -> HausError {
        guard let tag = missingCase, !(error is HausError) else { return super.converted(error) }
        if case .variant(let shape)? = node?.resolved.kind, shape.caseOf(tag) != nil {
            return place.fail(.typeMismatch, "the Swift type has no case \(state.name(tag)) for the tag \(tag)")
        }
        return place.fail(
            .unknownTag,
            "the tag \(tag) isn't a case of the Swift type: give it a case \(state.name(tag)), or a case unknown(HausValue) for every tag it lacks"
        )
    }
}

/// Fails unless `node` is the type of the codec `id` (spec §13.4).
func expectCodec(_ codec: Any.Type, _ id: String, _ node: SchemaNode?, _ place: Place) throws {
    guard !(node.map(typeIDs) ?? []).contains(id) else { return }
    throw place.fail(.typeMismatch, "\(codec) is the codec of \(id), but the type here is \(node?.described ?? "Any")")
}

/// The ids of a type (spec §13.3): a named type's, and those of the types it
/// is defined as (`type A = Money`).
func typeIDs(_ node: SchemaNode) -> [String] {
    switch node.kind {
    case .ref(let inst): [inst.id] + typeIDs(inst.body)
    case .time(let name): ["std/time#" + name]
    case .builtin(let b): ["prelude#" + b.rawValue]
    default: []
    }
}

// ── one value and its type ──────────────────────────────────────

/// A value to decode where a container is: its type, and the step to it.
struct Slot {
    let value: HausValue
    let node: SchemaNode?
    let parent: Place
    let step: PathStep?

    @inline(never)
    func fail(_ code: HausError.Code, _ message: String) -> HausError { parent.fail(code, message, at: step) }

    @inline(never)
    func mismatch(_ swift: String) -> HausError {
        let schema = node.map { ", the type \($0.described)" } ?? ""
        return fail(.typeMismatch, "the Swift type \(swift) doesn't fit \(found(value))\(schema)")
    }

    var isNone: Bool {
        guard case .variant("None", let args) = value, args.isEmpty else { return false }
        switch node?.resolved.kind {
        case nil, .maybe?, .builtin(.any)?: return true
        default: return false
        }
    }

    /// The value under `Some` at a `Maybe`: what a Swift type that isn't
    /// `Optional` decodes.
    func present() throws -> HausValue {
        if case .secret? = node?.resolved.kind { throw fail(.typeMismatch, secretNeeded) }
        guard case .maybe? = node?.resolved.kind else { return value }
        guard case .variant("Some", let args) = value, args.count == 1 else {
            throw fail(.typeMismatch, "None, but the Swift type isn't Optional")
        }
        return args[0]
    }

    func string() throws -> String {
        switch try present() {
        case .string(let s): return s
        // A tag without payload (a closed enum, an unknown value), or a std/time value's text.
        case .variant(let tag, let args) where args.isEmpty: return tag.name
        case .variant(_, let args) where args.count == 1:
            if case .string(let text) = args[0], isTime { return text }
        default: break
        }
        throw mismatch("String")
    }

    var isTime: Bool {
        if case .time? = node?.resolved.kind {
            true
        } else if case .maybe(let e)? = node?.resolved.kind, case .time = e.resolved.kind {
            true
        } else {
            false
        }
    }

    func bool() throws -> Bool {
        switch try present() {
        case .variant("True", let args) where args.isEmpty: return true
        case .variant("False", let args) where args.isEmpty: return false
        default: throw mismatch("Bool")
        }
    }

    func number() throws -> HausNumber {
        guard case .number(let n) = try present() else { throw mismatch("HausNumber") }
        return n
    }

    func integer<T: FixedWidthInteger>() throws -> T {
        guard case .number(let n) = try present(), n.isInteger else { throw mismatch("\(T.self)") }
        guard let x = T(n.literal) else {
            throw fail(.outOfRange, "\(n.literal) is out of the range of the Swift type \(T.self)")
        }
        return x
    }

    func float<T: BinaryFloatingPoint & LosslessStringConvertible>() throws -> T {
        switch try present() {
        case .number(let n):
            guard let x = T(n.literal), x.isFinite else {
                throw fail(.outOfRange, "\(n.literal) is out of the range of the Swift type \(T.self)")
            }
            return x
        case .variant("NaN", let args) where args.isEmpty: return .nan
        case .variant("Infinity", let args) where args.isEmpty: return .infinity
        case .variant("NegInfinity", let args) where args.isEmpty: return -.infinity
        default: throw mismatch("\(T.self)")
        }
    }

    @inline(never)
    func decoder(key: (any CodingKey)?, _ state: CodingState) -> SchemaDecoder {
        SchemaDecoder(value, node, state, at: parent, step, key)
    }
}

// ── keyed containers ────────────────────────────────────────────

/// The entries a keyed container reads: a record's fields, or a variant's
/// arguments, with their types.
struct Entries {
    enum Source {
        case record(HausRecord)
        case args([HausValue])
    }

    enum Types {
        case shape(RecordShape)
        case element(SchemaNode)
        case each([SchemaNode])
        case untyped
    }

    let source: Source
    let types: Types
    /// What the key `_0` stands for if no entry has it: a record case's
    /// record (`case circle(Disc)`), or an unknown value (`case unknown(HausValue)`).
    var whole: (value: HausValue, node: SchemaNode?)?

    static let none = Entries(source: .args([]), types: .untyped)

    /// The entries of a value without a type.
    static func of(_ v: HausValue) -> Entries {
        switch v {
        case .record(let r): Entries(source: .record(r), types: .untyped)
        case .variant(_, let args):
            if args.count == 1, case .record(let r) = args[0] {
                Entries(source: .record(r), types: .untyped, whole: (args[0], nil))
            } else {
                Entries(source: .args(args), types: .untyped)
            }
        default: none
        }
    }

    /// The entry called `name`: its value, type and step.
    func entry(_ name: String) -> (value: HausValue, node: SchemaNode?, step: PathStep?)? {
        switch source {
        case .record(let r):
            if let v = r[name] { return (v, type(name), .key(name)) }
        case .args(let args):
            if let i = argumentIndex(name, args.count) {
                if case .each(let items) = types { return (args[i], items[i], .index(i)) }
                return (args[i], nil, .index(i))
            }
        }
        guard name == "_0", let whole else { return nil }
        return (whole.value, whole.node, nil)
    }

    func type(_ key: String) -> SchemaNode? {
        switch types {
        case .shape(let shape): shape.field(key)?.type
        case .element(let element): element
        case .each, .untyped: nil
        }
    }

    var keys: [String] {
        switch source {
        case .record(let r): r.keys
        case .args(let args): args.indices.map { "_\($0)" }
        }
    }
}

struct SchemaKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: SchemaDecoder
    /// What `decode(_:forKey:)` reads: a record's fields, or a variant's
    /// payload (a struct decodes the record of a record case).
    let entries: Entries
    /// At a variant: the key of its case, and what the case's nested container reads.
    let variant: (key: Key, entries: Entries)?

    init(_ decoder: SchemaDecoder) throws {
        self.decoder = decoder
        (entries, variant) = try keyedEntries(decoder, Key.self)
    }

    init(_ decoder: SchemaDecoder, entries: Entries) {
        self.decoder = decoder
        self.entries = entries
        variant = nil
    }

    var codingPath: [any CodingKey] { decoder.codingPath }

    var allKeys: [Key] {
        if let variant { return [variant.key] }
        if case .variant(let tag, _) = decoder.value, decoder.missingCase == nil { decoder.missingCase = tag.name }
        return entries.keys.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool {
        entries.entry(key.stringValue) != nil || variant?.key.stringValue == key.stringValue
    }

    @inline(never)
    func slot(_ key: Key) throws -> Slot {
        guard let (value, node, step) = entries.entry(key.stringValue) else {
            throw decoder.place.fail(
                .missingField, "the Swift type needs the field \(quoteForMessage(key.stringValue))")
        }
        return Slot(value: value, node: node, parent: decoder.place, step: step)
    }

    func decodeNil(forKey key: Key) throws -> Bool { try slot(key).isNone }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try slot(key).bool() }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try slot(key).string() }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try slot(key).float() }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try slot(key).float() }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try slot(key).integer() }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try slot(key).integer() }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try slot(key).integer() }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try slot(key).integer() }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try slot(key).integer() }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try slot(key).integer() }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try slot(key).integer() }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try slot(key).integer() }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try slot(key).integer() }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try slot(key).integer() }

    /// ``decodeValue(_:_:)``, inline: one frame per level.
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let child = try slot(key).decoder(key: key, decoder.state)
        if let special = try decodeSpecial(type, child) { return special }
        do {
            return try T(from: child)
        } catch {
            throw child.converted(error)
        }
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        if let variant, variant.key.stringValue == key.stringValue {
            return KeyedDecodingContainer(SchemaKeyedDecoding<NestedKey>(decoder, entries: variant.entries))
        }
        return try slot(key).decoder(key: key, decoder.state).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try slot(key).decoder(key: key, decoder.state).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder { decoder }

    func superDecoder(forKey key: Key) throws -> any Decoder { try slot(key).decoder(key: key, decoder.state) }
}

/// What a keyed container at the decoder's value reads.
@inline(never)
func keyedEntries<Key: CodingKey>(_ decoder: SchemaDecoder, _: Key.Type) throws -> (
    Entries, (key: Key, entries: Entries)?
) {
    let v = decoder.value
    switch (decoder.node?.resolved.kind, v) {
    case (.record(let shape)?, .record(let r)):
        return (Entries(source: .record(r), types: .shape(shape)), nil)
    case (.map(let element)?, .record(let r)):
        return (Entries(source: .record(r), types: .element(element)), nil)
    case (.variant(let shape)?, .variant(let tag, let args)):
        guard let c = shape.caseOf(tag.name) else { return unknown(decoder, Key.self) }
        let payload = payloadEntries(c, args)
        let key = Key(stringValue: decoder.state.name(tag.name)) ?? Key(stringValue: tag.name)
        return (payload, key.map { ($0, payload) })
    case (nil, .record), (nil, .variant), (.builtin(.any)?, .record), (.builtin(.any)?, .variant):
        guard case .variant = v else { return (Entries.of(v), nil) }
        return unknown(decoder, Key.self)
    default:
        throw Slot(value: v, node: decoder.node, parent: decoder.place, step: nil).mismatch(
            "with keys \(Key.self)")
    }
}

/// The entries of a record case, a positional case or a tag without payload.
func payloadEntries(_ c: CaseType, _ args: [HausValue]) -> Entries {
    switch c.payload {
    case .none: return .none
    case .positional(let items): return Entries(source: .args(args), types: .each(items))
    case .record(let shape):
        guard case .record(let r) = args[0] else { return .none }
        return Entries(source: .record(r), types: .shape(shape), whole: (args[0], SchemaNode(.record(shape))))
    case .named(let node):
        guard case .record(let r) = args[0], let shape = c.record else { return .none }
        return Entries(source: .record(r), types: .shape(shape), whole: (args[0], node))
    }
}

/// A variant the type doesn't list (or has no type for): the case named for
/// its tag, or else `unknown`, whose `_0` is the whole value.
func unknown<Key: CodingKey>(_ decoder: SchemaDecoder, _: Key.Type) -> (Entries, (key: Key, entries: Entries)?) {
    guard case .variant(let tag, _) = decoder.value else { return (.none, nil) }
    let payload = Entries.of(decoder.value)
    if let key = Key(stringValue: decoder.state.name(tag.name)) ?? Key(stringValue: tag.name) {
        return (payload, (key, payload))
    }
    if let key = Key(stringValue: "unknown") {
        return (payload, (key, Entries(source: .args([]), types: .untyped, whole: (decoder.value, nil))))
    }
    return (payload, nil)
}

// ── unkeyed containers ──────────────────────────────────────────

struct SchemaUnkeyedDecoding: UnkeyedDecodingContainer {
    enum Items {
        case values([HausValue], SchemaNode?)
        case bytes([UInt8])
    }

    let decoder: SchemaDecoder
    let items: Items
    var currentIndex = 0

    init(_ decoder: SchemaDecoder) throws {
        self.decoder = decoder
        switch (decoder.node?.resolved.kind, decoder.value) {
        case (.array(let element)?, .array(let values)): items = .values(values, element)
        case (nil, .array(let values)), (.builtin(.any)?, .array(let values)): items = .values(values, nil)
        case (_, .bytes(let bytes)): items = .bytes(bytes)
        default: throw decoder.slot.mismatch("with an unkeyed container")
        }
    }

    var codingPath: [any CodingKey] { decoder.codingPath }

    var count: Int? {
        switch items {
        case .values(let values, _): values.count
        case .bytes(let bytes): bytes.count
        }
    }

    var isAtEnd: Bool { currentIndex >= count! }

    /// The next item, and moves past it.
    mutating func next() throws -> Slot {
        guard !isAtEnd else {
            throw decoder.place.fail(.typeMismatch, "the Swift type reads more than the \(count!) items")
        }
        defer { currentIndex += 1 }
        let step = PathStep.index(currentIndex)
        switch items {
        case .values(let values, let element):
            return Slot(value: values[currentIndex], node: element, parent: decoder.place, step: step)
        case .bytes(let bytes):
            return Slot(value: .number(HausNumber(bytes[currentIndex])), node: nil, parent: decoder.place, step: step)
        }
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd, case .values(let values, let element) = items else { return false }
        let slot = Slot(value: values[currentIndex], node: element, parent: decoder.place, step: nil)
        if slot.isNone { currentIndex += 1 }
        return slot.isNone
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try next().bool() }
    mutating func decode(_ type: String.Type) throws -> String { try next().string() }
    mutating func decode(_ type: Double.Type) throws -> Double { try next().float() }
    mutating func decode(_ type: Float.Type) throws -> Float { try next().float() }
    mutating func decode(_ type: Int.Type) throws -> Int { try next().integer() }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try next().integer() }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try next().integer() }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try next().integer() }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try next().integer() }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try next().integer() }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next().integer() }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next().integer() }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next().integer() }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        // Bytes, one at a time (`[UInt8]`, `Data`), without making numbers.
        if case .bytes(let bytes) = items, !isAtEnd {
            defer { currentIndex += 1 }
            return bytes[currentIndex]
        }
        return try next().integer()
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let key = IndexKey(currentIndex)
        return try decodeValue(type, next().decoder(key: key, decoder.state))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        let key = IndexKey(currentIndex)
        return try next().decoder(key: key, decoder.state).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let key = IndexKey(currentIndex)
        return try next().decoder(key: key, decoder.state).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let key = IndexKey(currentIndex)
        return try next().decoder(key: key, decoder.state)
    }
}

/// The coding key of an item of an unkeyed container.
struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue!)" }
    init(_ index: Int) { intValue = index }
    init?(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { nil }
}

/// The argument a key names: `_0`, `_1`…, or any label of a case's one argument.
func argumentIndex(_ name: String, _ count: Int) -> Int? {
    if name.hasPrefix("_"), let i = Int(name.dropFirst()), i >= 0, i < count, name == "_\(i)" { return i }
    return count == 1 && !name.hasPrefix("_") ? 0 : nil
}

/// The message for a Swift type other than ``Secret`` at a `Secret a`.
let secretNeeded = "a Secret a needs the Swift type Secret (spec §15)"
