// Decoding with a schema (spec §15). The result is a haus value: the one an
// encoder writes back, with floats in their one spelling, integers in
// decimal (-0 as 0), and the fields an open record ignores left out. Parts
// the type keeps as they are are the input's own values.

/// Decodes (or, encoding, checks) one value with a type. Its functions
/// return the value decoded, or nil when that is the value given, unchanged.
/// With `reading`, the value is JSON read as by the import, and is read as
/// schema-based JSON (§16.3, SchemaJSON.swift).
///
/// The recursion is `child`, `value` and `decode`: a value is first planned
/// (checked, and its parts that go one level deeper listed, ``Plan``) by a
/// function that returns before the parts are decoded. A debug build gives a
/// function a stack slot for every temporary, so this keeps the frames of
/// the recursion small, and values as deep as the depth limit decode on the
/// 512 KiB stack of a thread of Swift's concurrency pool.
struct SchemaWalker {
    /// The work budget of one decode: steps per value of the input, after a
    /// start (spec §9.8).
    static let stepsPerValue = 16
    static let budgetStart = 1024

    let limits: Limits
    let encoding: Bool
    let reading: Bool
    var path: [PathStep]
    var depth = 0
    var nodes = 0
    var steps = 0
    var budget = budgetStart

    init(limits: Limits, encoding: Bool = false, reading: Bool = false, path: [PathStep] = []) {
        self.limits = limits
        self.encoding = encoding
        self.reading = reading
        self.path = path
    }

    // ── errors ──────────────────────────────────────────────────

    @inline(never)
    func fail(_ code: HausError.Code, _ message: String) -> HausError {
        HausError(code, message, path: pathString(path))
    }

    @inline(never)
    func mismatch(_ v: HausValue, _ t: SchemaNode) -> HausError {
        fail(.typeMismatch, "expected \(t.described), found \(found(v))")
    }

    @inline(never)
    func tooDeep() -> HausError { fail(.nestingTooDeep, "nesting deeper than \(limits.maxDepth) levels") }

    @inline(never)
    func overBudget() -> HausError {
        fail(
            .stepBudget, "decode budget of \(budget) steps exceeded (a schema doing more work than the input justifies)"
        )
    }

    @inline(never)
    func tooManyNodes() -> HausError { fail(.tooManyNodes, "the value has more than \(Limits.maxNodes) nodes") }

    // ── the recursion ───────────────────────────────────────────

    /// What decoding a value takes.
    enum Plan {
        /// Nothing deeper: the value decoded, nil if unchanged.
        case done(HausValue?)
        /// A container, whose parts decode one level deeper.
        case parts(Parts)
        /// A record case by name, `Tag R`: the record, decoded with `R` at
        /// the variant's level and place, is the payload of `tag`.
        case payload(tag: String, HausValue, SchemaNode)
        /// A `Secret a`: the value, decoded as `a`.
        case secret(HausValue, SchemaNode)
    }

    /// Decodes `v` with `t`. A container's parts are decoded here too, one
    /// level deeper, so that the recursion has one frame per level.
    mutating func value(_ v: HausValue, _ t: SchemaNode) throws(HausError) -> HausValue? {
        var out: HausValue?
        guard let parts = try parts(v, t, &out) else { return out }
        var results: [HausValue]?
        for i in 0..<parts.count {
            guard let type = try enter(parts, i) else { continue }
            let y = try value(parts.item(i), type)
            try leave(parts, i, y, &results)
        }
        return parts.assemble(results, fresh: reading)
    }

    /// The parts of `v` to decode one level deeper with `t`; nil if it has
    /// none, and then `out` is its value (nil if unchanged).
    @inline(never)
    mutating func parts(_ v: HausValue, _ t: SchemaNode, _ out: inout HausValue?) throws(HausError) -> Parts? {
        switch try plan(v, t) {
        case .parts(let parts): return parts
        case .done(let value): out = value
        case .payload(let tag, let record, let type): out = try value(record, type).map { .variant(tag, [$0]) }
        case .secret(let x, let item): out = try secret(x, item)
        }
        return nil
    }

    /// Starts part `i` of a container, one level deeper: its type, or nil
    /// if the part is dropped (a field an open record doesn't list).
    @inline(never)
    mutating func enter(_ parts: Parts, _ i: Int) throws(HausError) -> SchemaNode? {
        if i == 0, let prefix = parts.prefix { path.append(prefix) }
        guard let type = try partType(parts, i) else { return nil }
        try enter(parts.step(i))
        return type
    }

    /// Ends part `i` of a container, decoded as `y`.
    @inline(never)
    mutating func leave(_ parts: Parts, _ i: Int, _ y: HausValue?, _ results: inout [HausValue]?) throws(HausError) {
        try leave(y, parts.item(i), popping: parts.step(i) != nil)
        if let y { parts.set(&results, i, y) }
        if i == parts.count - 1 && parts.prefix != nil { path.removeLast() }
    }

    /// Starts a value one level deeper, at `step`.
    @inline(never)
    mutating func enter(_ step: PathStep?) throws(HausError) {
        if depth >= limits.maxDepth { throw tooDeep() }
        nodes += 1
        if nodes > Limits.maxNodes { throw tooManyNodes() }
        budget += Self.stepsPerValue
        if let step { path.append(step) }
        depth += 1
    }

    /// Ends the value `v` started by ``enter(_:)``, decoded as `out`.
    @inline(never)
    mutating func leave(_ out: HausValue?, _ v: HausValue, popping: Bool) throws(HausError) {
        // An empty record, array or record payload is a level, as when
        // parsing (spec §7), though it has nothing in it to nest.
        if depth >= limits.maxDepth && isEmptyLevel(out ?? v) { throw tooDeep() }
        depth -= 1
        if popping { path.removeLast() }
    }

    /// The plan for `v` with `t`, after counting a step of the work budget.
    @inline(never)
    mutating func plan(_ v: HausValue, _ t: SchemaNode) throws(HausError) -> Plan {
        steps += 1
        if steps > budget { throw overBudget() }
        let rt = t.resolved
        return reading ? try planJSON(v, rt, t) : try planDecode(v, rt, t)
    }

    /// The type of part `i`, or nil for a field an open record drops; it
    /// fails for a field a closed record doesn't list, and for a key of the
    /// value read over the limit in JSON (a `Map`'s, a listed field's).
    @inline(never)
    mutating func partType(_ parts: Parts, _ i: Int) throws(HausError) -> SchemaNode? {
        switch parts.types {
        case .all(let t):
            if parts.checkKeys, case .fields(let r) = parts.source { try checkKey(r[i].key) }
            return t
        case .each(let types):
            return types[i]
        case .shape(let shape, let payload):
            guard case .fields(let r) = parts.source else { return nil }
            let key = r[i].key
            if payload && sameCodePoints(key, "_tag") { return nil }
            guard let f = shape.field(key) else {
                if shape.closed { throw unknownField(key) }
                return nil
            }
            if parts.checkKeys { try checkKey(key) }
            return f.type
        }
    }

    /// Checks a key of the value read against the string limit, at its member.
    mutating func checkKey(_ key: String) throws(HausError) {
        path.append(.key(key))
        try checkLength(key, .keyTooLong, "key")
        path.removeLast()
    }

    /// Checks a string or key of the value read against the string limit,
    /// counted in characters after escapes (§16, "Limits").
    func checkLength(_ s: String, _ code: HausError.Code, _ what: String) throws(HausError) {
        if longerThan(s, limits.maxStringLength) != nil {
            throw fail(code, "a \(what) longer than the limit of \(limits.maxStringLength) characters")
        }
    }

    /// Decodes `v` as `item`, and replaces any error inside by one at the
    /// secret itself, with its type only (spec §15): messages quote values,
    /// keys and tags of the data, and paths may name keys.
    mutating func secret(_ v: HausValue, _ item: SchemaNode) throws(HausError) -> HausValue? {
        let (at, depth) = (path.count, self.depth)
        do {
            return try value(v, item)
        } catch {
            path.removeLast(path.count - at)
            self.depth = depth
            throw invalidSecret(item)
        }
    }

    @inline(never)
    func invalidSecret(_ item: SchemaNode) -> HausError {
        fail(.invalidSecret, "expected \(item.described) (a Secret: the value is not shown)")
    }

    // ── plans ───────────────────────────────────────────────────

    mutating func planDecode(_ v: HausValue, _ rt: SchemaNode, _ t: SchemaNode) throws(HausError) -> Plan {
        switch (rt.kind, v) {
        case (.array(let element), .array(let items)):
            return .parts(Parts(.items(items), .all(element), .array))
        case (.map(let element), .record(let r)):
            return .parts(Parts(.fields(r), .all(element), .record))
        case (.record(let shape), .record(let r)):
            try checkRequired(shape) { r[$0] != nil }
            return .parts(Parts(.fields(r), .shape(shape, payload: false), .record))
        case (.variant(let shape), _):
            return try planVariant(v, shape, t)
        case (.maybe(let element), _):
            switch v {
            case .variant("None", let args) where args.isEmpty:
                return .done(nil)
            case .variant("Some", let args) where args.count == 1:
                return .parts(Parts(.items(args), .each([element]), .variant("Some")))
            default:
                throw notCase(v, "None", "Some", "expected None or Some(…) (\(t.described)), found \(found(v))")
            }
        case (.secret(let item), _):
            return .secret(v, item)
        case (.time(let name), _):
            return .done(try time(v, name, t))
        case (.builtin(let b), _):
            return .done(try builtin(v, b, t))
        case (.param, _), (.ref, _):
            return .done(nil)
        case (.array, _), (.map, _), (.record, _):
            throw mismatch(v, t)
        }
    }

    mutating func planVariant(_ v: HausValue, _ shape: VariantShape, _ t: SchemaNode) throws(HausError) -> Plan {
        guard case .variant(let tag, let args) = v else { throw mismatch(v, t) }
        guard let c = shape.caseOf(tag) else {
            if shape.open { return .done(try raw(v)) }
            throw unknownTag(tag, shape)
        }
        switch c.payload {
        case .none:
            if !args.isEmpty { throw fail(.wrongPayload, "\(tag) takes no payload") }
            return .done(nil)
        case .record(let fields):
            // Tag { … }: the record is at the variant's level and place.
            guard args.count == 1, case .record(let r) = args[0] else { throw notOneRecord(tag, args) }
            try checkRequired(fields) { r[$0] != nil }
            return .parts(Parts(.fields(r), .shape(fields, payload: false), .payload(tag)))
        case .named(let named):
            guard args.count == 1, case .record = args[0] else { throw notOneRecord(tag, args) }
            return .payload(tag: tag, args[0], named)
        case .positional(let items):
            if items.count != args.count { throw wrongArguments(tag, items, args.count) }
            return .parts(Parts(.items(args), .each(items), .variant(tag)))
        }
    }

    /// Fails with `missing-field` if a field the shape requires isn't `present`.
    func checkRequired(_ shape: RecordShape, _ present: (String) -> Bool) throws(HausError) {
        let missing = shape.fields.filter { !$0.optional && !present($0.key) }
        if !missing.isEmpty { throw missingFields(missing.map(\.key)) }
    }

    @inline(never)
    func missingFields(_ keys: [String]) -> HausError {
        let shown = keys.prefix(5).map(quoteKey) + (keys.count > 5 ? ["…"] : [])
        return fail(.missingField, "missing field\(keys.count > 1 ? "s" : "") \(shown.joined(separator: ", "))")
    }

    @inline(never)
    mutating func unknownField(_ key: String) -> HausError {
        path.append(.key(key))
        return fail(.unknownField, "\(quoteKey(key)) is not a field of this closed record")
    }

    @inline(never)
    func unknownTag(_ tag: String, _ shape: VariantShape) -> HausError {
        fail(.unknownTag, "\(quoteForMessage(tag)) is not allowed here: expected \(shape.tagList)")
    }

    @inline(never)
    func notOneRecord(_ tag: String, _ args: [HausValue]) -> HausError {
        let what =
            switch args.count {
            case 0: "no payload"
            case 1: found(args[0])
            default: "\(args.count) arguments"
            }
        return fail(.wrongPayload, "\(tag) takes one argument, a record; found \(what)")
    }

    @inline(never)
    func wrongArguments(_ tag: String, _ items: [SchemaNode], _ count: Int) -> HausError {
        let described = items.map(\.described).joined(separator: ", ")
        return fail(
            .wrongPayload,
            "\(tag) takes \(items.count) argument\(items.count == 1 ? "" : "s") (\(described)), found \(count)")
    }

    /// The error for a value that isn't one of the cases of a closed variant
    /// with the two tags (`Bool`, `Maybe`): a known tag with the wrong
    /// payload, an unknown tag, or not a variant at all.
    @inline(never)
    func notCase(_ v: HausValue, _ a: String, _ b: String, _ message: @autoclosure () -> String) -> HausError {
        guard case .variant(let tag, _) = v else { return fail(.typeMismatch, message()) }
        return fail(tag == a || tag == b ? .wrongPayload : .unknownTag, message())
    }

    // ── scalars ─────────────────────────────────────────────────

    mutating func builtin(_ v: HausValue, _ b: Builtin, _ t: SchemaNode) throws(HausError) -> HausValue? {
        switch (b, v) {
        case (.any, _): return try raw(v)
        case (.string, .string), (.bytes, .bytes): return nil
        case (.bool, .variant(let tag, let args)):
            if tag == "True" || tag == "False" {
                if args.isEmpty { return nil }
                throw fail(.wrongPayload, "expected \(t.described), found \(found(v)) with a payload")
            }
            throw fail(.unknownTag, "expected \(t.described) (True or False), found \(found(v))")
        case (.float32, .variant(let tag, let args)), (.float64, .variant(let tag, let args)):
            if args.isEmpty && ["NaN", "Infinity", "NegInfinity"].contains(tag) { return nil }
        case (.float32, .number(let n)): return try float(n, .bits32)
        case (.float64, .number(let n)): return try float(n, .bits64)
        case (.decimal, .number(let n)):
            try checkNumber(n)
            return nil
        case (_, .number(let n)) where b.isInteger:
            return try integer(n, b)
        default:
            break
        }
        throw mismatch(v, t)
    }

    /// Checks a number built in code against the number limits.
    func checkNumber(_ n: HausNumber) throws(HausError) {
        guard encoding, let (code, message) = numberLimitError(n.literal, limits) else { return }
        throw fail(code, message)
    }

    func integer(_ n: HausNumber, _ b: Builtin) throws(HausError) -> HausValue? {
        try checkNumber(n)
        let text = n.literal
        let digits = text.utf8.drop { $0 == ASCII.minus }
        guard !digits.isEmpty, digits.allSatisfy(isDigit) else {
            throw fail(.notAnInteger, "expected a whole number (\(b.rawValue)), found \(short(text))")
        }
        let zero = digits.allSatisfy { $0 == ASCII.zero }
        if let range = b.range, !zero, !fits(text, range) { throw outOfRange(text, b, range) }
        // -0 is 0 (spec §15).
        return zero && text != "0" ? .number(HausNumber(0)) : nil
    }

    @inline(never)
    func outOfRange(_ text: String, _ b: Builtin, _ range: (bits: Int, signed: Bool)) -> HausError {
        let half = UInt64(1) << (range.bits - 1)
        let (lo, hi) = range.signed ? ("-\(half)", "\(half - 1)") : ("0", "\(UInt64.max >> (64 - range.bits))")
        return fail(.outOfRange, "\(short(text)) is out of range for \(b.rawValue) (\(lo) to \(hi))")
    }

    /// Rounds a number to the nearest float of the width, directly from its
    /// exact decimal value, and writes it in its one spelling (spec §15).
    func float(_ n: HausNumber, _ width: FloatWidth) throws(HausError) -> HausValue? {
        try checkNumber(n)
        let f = roundToFloat(n.literal, width)
        if f.isInfinite {
            throw fail(.outOfRange, "\(short(n.literal)) is too large for \(width == .bits32 ? "Float32" : "Float64")")
        }
        let spelled = floatSpelling(f, width)
        return spelled == n.literal ? nil : .number(HausNumber(normalized: spelled))
    }

    /// Checks a value kept as it is (an `Any`, an unknown tag): one a writer
    /// takes, within the limits (spec §9.8).
    mutating func raw(_ v: HausValue) throws(HausError) -> HausValue? {
        do {
            try checkValue(v, limits: limits)
        } catch {
            throw HausError(error.code, error.message, path: pathString(path) + (error.path?.dropFirst() ?? ""))
        }
        nodes += 1
        return nil
    }

    mutating func time(_ v: HausValue, _ name: String, _ t: SchemaNode) throws(HausError) -> HausValue? {
        guard case .variant(let tag, let args) = v, tag == name else { throw mismatch(v, t) }
        guard args.count == 1, case .string(let text) = args[0] else {
            throw fail(.typeMismatch, #"write \#(name)("…") with one string"#)
        }
        if let why = timeError(name, text) {
            path.append(.index(0))
            throw fail(.invalidTime, why)
        }
        return nil
    }
}

/// Whether the integer `text` (digits with an optional `-`) is in the range.
func fits(_ text: String, _ range: (bits: Int, signed: Bool)) -> Bool {
    if range.signed {
        guard let n = Int64(text) else { return false }
        return range.bits == 64 || (-(Int64(1) << (range.bits - 1))..<(Int64(1) << (range.bits - 1))).contains(n)
    }
    guard let n = UInt64(text) else { return false }
    return range.bits == 64 || n < UInt64(1) << range.bits
}

/// Whether `v` is an empty record or array, or a variant with an empty
/// record payload (`Tag {}`): a level of nesting with nothing below it.
func isEmptyLevel(_ v: HausValue) -> Bool {
    switch v {
    case .array(let items): items.isEmpty
    case .record(let r): r.isEmpty
    case .variant(_, let args):
        if args.count == 1, case .record(let r) = args[0] { r.isEmpty } else { false }
    default: false
    }
}

/// At most 30 characters of a number's text, for messages.
func short(_ text: String) -> String {
    text.unicodeScalars.count > 30 ? String(text.unicodeScalars.prefix(30)) + "…" : text
}

/// A short description of a value, for messages.
func found(_ v: HausValue) -> String {
    switch v {
    case .string(let s): s.unicodeScalars.count > 20 ? "a string" : "the string \(quoteForMessage(s))"
    case .number(let n): "the number \(short(n.literal))"
    case .bytes: "bytes"
    case .array: "an array"
    case .record: "a record"
    case .variant(let tag, _): "the tag \(quoteForMessage(tag))"
    }
}
