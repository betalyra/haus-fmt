// Schema-based JSON (spec §16.3): the values of a type written as the JSON a
// JSON consumer expects, and read back with the type. Reading parses the
// JSON as the import does (§16.1) and walks that value with the type, as
// decoding walks haus values (§15), so that every rule of decoding and the
// work budget apply alike; the result is the decoded value, the one an
// encoder writes back.

extension SchemaType {
    /// Writes `value` as the type's schema-based JSON (spec §16.3), on one
    /// line without spaces. The value is checked and encoded as
    /// ``encode(_:limits:)`` does first, so it can be a value built in code;
    /// what an open record doesn't list is left out. A value of a record
    /// case with a field named `_tag` or `_args` has no schema-based form
    /// (`no-json-form`).
    public func toJSON(_ value: HausValue, limits: Limits = Limits()) throws(HausError) -> String {
        var out: [UInt8] = []
        try appendJSON(value, limits: limits, to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    func appendJSON(_ value: HausValue, limits: Limits, to out: inout [UInt8]) throws(HausError) {
        let encoded = try encode(value, limits: limits)
        var writer = SchemaJSONWriter()
        try writer.value(encoded, node)
        out += writer.out
    }

    /// Reads the type's schema-based JSON (spec §16.3), and returns the
    /// decoded value: what ``decode(_:limits:)`` gives for the haus value the
    /// JSON stands for. The rules of decoding apply (§15): open records
    /// ignore members they don't list, a tag an open variant doesn't list
    /// reads as an unknown value. Errors in the JSON text have its position;
    /// errors in the value have the path of the JSON member, such as
    /// `$.items[2].price`. The limits apply to the value read; the JSON
    /// nesting is limited to 4·d + 1 for the depth limit d.
    public func fromJSON(_ text: String, limits: Limits = Limits()) throws(HausError) -> HausValue {
        try fromJSON(bytes: text.utf8, limits: limits)
    }

    /// Reads schema-based JSON in UTF-8. See ``fromJSON(_:limits:)``.
    public func fromJSON(bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(HausError) -> HausValue {
        let limits = try limits.checked()
        return try withBytes(bytes) { (b) throws(HausError) in try read(b, limits: limits, skipBOM: true) }
    }

    func read(_ b: Bytes, limits: Limits, skipBOM: Bool) throws(HausError) -> HausValue {
        let j = try readJSON(b, limits: limits, mode: .schema, skipBOM: skipBOM)
        var walker = SchemaWalker(limits: limits, reading: true)
        return try walker.value(j, node) ?? j
    }

    /// Writes values as JSON Lines (spec §16, "Streams"): the schema-based
    /// JSON of each, followed by a line feed. For a `Stream` definition each
    /// value is one of the stream. An error's path starts with the value's
    /// index, `$[3].total`.
    public func toJSONLines(_ values: [HausValue], limits: Limits = Limits()) throws(HausError) -> String {
        var out: [UInt8] = []
        for (i, value) in values.enumerated() {
            do {
                try appendJSON(value, limits: limits, to: &out)
            } catch {
                throw error.inLine(i)
            }
            out.append(ASCII.lf)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Reads a whole text of JSON Lines with the type: every value, or the
    /// first error. See ``jsonLinesReader(limits:)``.
    public func fromJSONLines(_ text: String, limits: Limits = Limits()) throws(HausError) -> [HausValue] {
        try fromJSONLines(bytes: text.utf8, limits: limits)
    }

    /// Reads a whole text of JSON Lines in UTF-8 with the type.
    public func fromJSONLines(bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(HausError)
        -> [HausValue]
    {
        var reader = JSONLinesReader(limits: limits, convert: lineReader)
        return try reader.readAll(bytes)
    }

    /// A reader of JSON Lines (spec §16, "Streams") from chunks, each line
    /// the schema-based JSON of a value of the type (of a stream's value,
    /// for a `Stream` definition). It holds one line at a time, of any
    /// length (JSON Lines has no limit on a line). Errors in a
    /// line's text have the line's number; errors in a value have a path
    /// that starts with its index, `$[3].total`.
    public func jsonLinesReader(limits: Limits = Limits()) -> JSONLinesReader {
        JSONLinesReader(limits: limits, convert: lineReader)
    }

    var lineReader: JSONLinesReader.Convert {
        { (b, limits, first) throws(HausError) in try read(b, limits: limits, skipBOM: first) }
    }
}

// ── reading ─────────────────────────────────────────────────────

extension SchemaWalker {
    /// The plan for reading the JSON `j` (as the import reads it) with the
    /// type `t`, whose resolved form is `rt`.
    mutating func planJSON(_ j: HausValue, _ rt: SchemaNode, _ t: SchemaNode) throws(HausError) -> Plan {
        switch (rt.kind, j) {
        case (.builtin(let b), _):
            return .done(try readBuiltin(j, b, t))
        case (.time(let name), .string(let s)):
            if let why = timeError(name, s) { throw fail(.invalidTime, why) }
            return .done(.variant(name, [j]))
        case (.time, _):
            throw jsonMismatch(j, t, "a string")
        case (.array(let element), .array(let items)):
            return .parts(Parts(.items(items), .all(element), .array))
        case (.array, _):
            throw jsonMismatch(j, t, "an array")
        case (.map(let element), .record(let r)):
            return .parts(Parts(.fields(r), .all(element), .record, checkKeys: true))
        case (.record(let shape), .record(let r)):
            try checkRequired(shape) { r[$0] != nil }
            return .parts(Parts(.fields(r), .shape(shape, payload: false), .record, checkKeys: true))
        case (.map, _), (.record, _):
            throw jsonMismatch(j, t, "an object")
        case (.maybe(let element), _):
            return try planMaybe(j, element, rt, t)
        case (.secret(let item), _):
            return .secret(j, item)
        case (.variant(let shape), _):
            return try planVariantJSON(j, shape, t)
        case (.param, _), (.ref, _):
            // A type parameter: only in the template of a generic type, which values aren't read with.
            try imported(j, depth: depth)
            return .done(j)
        }
    }

    @inline(never)
    func jsonMismatch(_ j: HausValue, _ t: SchemaNode, _ form: String) -> HausError {
        fail(.typeMismatch, "expected \(t.described) (\(form)), found \(describeJSON(j))")
    }

    mutating func readBuiltin(_ j: HausValue, _ b: Builtin, _ t: SchemaNode) throws(HausError) -> HausValue {
        switch (b, j) {
        case (.string, .string(let s)):
            try checkLength(s, .stringTooLong, "string")
            return j
        case (.bytes, .string(let s)):
            guard let bytes = fromBase64(s) else {
                throw fail(.invalidBase64, "expected base64 with padding (RFC 4648 §4), found \(describeJSON(j))")
            }
            if 2 * bytes.count > limits.maxStringLength {
                throw fail(
                    .stringTooLong,
                    "a byte string of \(bytes.count) bytes, more than the limit of \(limits.maxStringLength) characters"
                )
            }
            return .bytes(bytes)
        case (.bool, .variant("True", _)), (.bool, .variant("False", _)):
            return j
        case (.int8, .number(let n)), (.int16, .number(let n)), (.int32, .number(let n)),
            (.uint8, .number(let n)), (.uint16, .number(let n)), (.uint32, .number(let n)):
            return try integer(n, b) ?? j
        case (.int, .string(let s)), (.int64, .string(let s)), (.uint64, .string(let s)):
            return try intString(s, b)
        case (.float32, .number(let n)): return try float(n, .bits32) ?? j
        case (.float64, .number(let n)): return try float(n, .bits64) ?? j
        case (.float32, .string(let s)), (.float64, .string(let s)):
            switch s {
            case "NaN": return .tag("NaN")
            case "Infinity": return .tag("Infinity")
            case "-Infinity": return .tag("NegInfinity")
            default: break
            }
        case (.decimal, .string(let s)):
            return try decimalString(s)
        case (.any, _):
            var form = SelfDescribing(limits: limits, path: path)
            return try form.value(j, depth: depth)
        default:
            break
        }
        throw jsonMismatch(j, t, jsonForm(of: b))
    }

    /// The JSON a builtin type reads, for messages.
    func jsonForm(of b: Builtin) -> String {
        switch b {
        case .string: "a string"
        case .decimal: "a string of a number"
        case .bytes: "a string in base64 with padding"
        case .bool: "true or false"
        case .int, .int64, .uint64: "a string of a decimal integer"
        case .float32, .float64: #"a number, "NaN", "Infinity" or "-Infinity""#
        case .any: "any JSON"
        default: "a number"
        }
    }

    /// `Int`, `Int64` and `UInt64`, written as a string of a decimal integer:
    /// `-?(0|[1-9][0-9]*)`, `"-0"` being 0.
    func intString(_ s: String, _ b: Builtin) throws(HausError) -> HausValue {
        guard isDecimalInteger(s) else {
            throw fail(
                isJSONNumber(s) ? .notAnInteger : .invalidNumber,
                "expected a decimal integer in a string (\(b.rawValue)), found \(quoteForMessage(s))")
        }
        // A sized type checks its range: a number too long for the limit is out of range for it.
        if b == .int && s.utf8.count > limits.maxNumberLength {
            throw fail(
                .numberTooLong,
                "a number of \(s.utf8.count) characters, more than the limit of \(limits.maxNumberLength)")
        }
        let n = HausNumber(normalized: s)
        return try integer(n, b) ?? .number(n)
    }

    /// A `Decimal`: a JSON number literal in a string, normalized (spec §2).
    func decimalString(_ s: String) throws(HausError) -> HausValue {
        guard isJSONNumber(s) else {
            throw fail(.invalidNumber, "expected a number literal in a string (Decimal), found \(quoteForMessage(s))")
        }
        let n = HausNumber(normalized: normalizeJSONNumber(s))
        if let (code, message) = numberLimitError(n.literal, limits) { throw fail(code, message) }
        return .number(n)
    }

    mutating func planMaybe(_ j: HausValue, _ element: SchemaNode, _ rt: SchemaNode, _ t: SchemaNode)
        throws(HausError) -> Plan
    {
        if rt.jsonNull {
            if case .variant("None", _) = j { return .done(.tag("None")) }
            // Some(x) is one level deeper than the JSON shows.
            return .parts(Parts(.items([j]), .each([element]), .variant("Some"), steps: .none))
        }
        guard case .record(let r) = j else {
            throw jsonMismatch(j, t, #"{"_tag": "None"} or {"_tag": "Some", "value": …}"#)
        }
        switch try tagMember(r) {
        case "None":
            try onlyMembers(r, nil)
            return .done(.tag("None"))
        case "Some":
            let x = try member(r, "value", "Some")
            return .parts(Parts(.items([x]), .each([element]), .variant("Some"), steps: .member(.key("value"))))
        case let tag:
            throw fail(.unknownTag, "\(quoteForMessage(tag)) is not allowed here: expected None or Some")
        }
    }

    /// The `"_tag"` of an object: `missing-member` without one,
    /// `invalid-tag` if it isn't a string or isn't a tag (§16.3), at the object.
    func tagMember(_ r: HausRecord) throws(HausError) -> String {
        guard let j = r["_tag"] else {
            throw fail(.missingMember, #"expected the member "_tag", found \#(describeObject(r))"#)
        }
        guard case .string(let s) = j else {
            throw fail(.invalidTag, "expected a tag in '_tag', found \(describeJSON(j))")
        }
        guard isTag(s) else {
            throw fail(.invalidTag, "expected a tag ([A-Z][A-Za-z0-9_]*) in '_tag', found \(quoteForMessage(s))")
        }
        return s
    }

    /// The member `name` of an object with `"_tag"` (and no other).
    mutating func member(_ r: HausRecord, _ name: String, _ tag: String) throws(HausError) -> HausValue {
        guard let x = r[name] else { throw fail(.missingMember, #"\#(tag) needs the member "\#(name)""#) }
        try onlyMembers(r, name)
        return x
    }

    /// Checks that an object has no members besides `"_tag"` and `name`.
    mutating func onlyMembers(_ r: HausRecord, _ name: String?) throws(HausError) {
        for key in r.keys where !sameCodePoints(key, "_tag") && !(name.map { sameCodePoints(key, $0) } ?? false) {
            path.append(.key(key))
            throw fail(.unexpectedMember, "unexpected member \(quoteForMessage(key))")
        }
    }

    mutating func planVariantJSON(_ j: HausValue, _ shape: VariantShape, _ t: SchemaNode) throws(HausError) -> Plan {
        if shape.isEnum {
            guard case .string(let s) = j else { throw jsonMismatch(j, t, "a string") }
            guard isTag(s) else {
                throw fail(
                    .invalidTag,
                    "expected a tag ([A-Z][A-Za-z0-9_]*), \(shape.tagList), found \(quoteForMessage(s))")
            }
            guard let c = shape.caseOf(s) else { throw unknownTag(s, shape) }
            try checkTagLength(c.tag)
            return .done(.tag(c.tag))
        }
        guard case .record(let r) = j else { throw jsonMismatch(j, t, #"an object with "_tag""#) }
        let tag = try tagMember(r)
        guard let c = shape.caseOf(tag) else {
            if !shape.open { throw unknownTag(tag, shape) }
            return .done(try unknownJSON(tag, r))
        }
        try checkTagLength(c.tag)
        switch c.payload {
        case .none:
            try onlyMembers(r, nil)
            return .done(.tag(c.tag))
        case .record(let fields):
            try checkReserved(c)
            // The record's fields beside "_tag", at the variant's level and place.
            try checkRequired(fields) { r[$0] != nil }
            return .parts(Parts(.fields(r), .shape(fields, payload: true), .payload(c.tag), checkKeys: true))
        case .named(let named):
            try checkReserved(c)
            let fields = HausValue.record(HausRecord(distinct: r.fields.filter { !sameCodePoints($0.key, "_tag") }))
            return .payload(tag: c.tag, fields, named)
        case .positional(let items) where items.count == 1:
            let x = try member(r, "value", tag)
            return .parts(Parts(.items([x]), .each(items), .variant(c.tag), steps: .member(.key("value"))))
        case .positional(let items):
            let args = try values(try member(r, "values", tag), items, tag)
            return .parts(Parts(.items(args), .each(items), .variant(c.tag), prefix: .key("values")))
        }
    }

    /// The `"values"` of a case with several arguments. A wrong payload is at
    /// the variant (§15), as in haus text.
    func values(_ x: HausValue, _ items: [SchemaNode], _ tag: String) throws(HausError) -> [HausValue] {
        guard case .array(let a) = x else {
            throw fail(
                .wrongPayload,
                #"\#(tag) takes \#(items.count) arguments, as an array in "values"; found \#(describeJSON(x))"#)
        }
        guard a.count == items.count else {
            throw fail(.wrongPayload, "\(tag) takes \(items.count) arguments, found \(a.count)")
        }
        return a
    }

    /// Checks a tag of the value read, a `"_tag"` or an enum's string,
    /// against the string limit (§16, "Limits"). Tags are ASCII.
    func checkTagLength(_ tag: String) throws(HausError) {
        if tag.utf8.count > limits.maxStringLength {
            throw fail(.tagTooLong, "a tag longer than the limit of \(limits.maxStringLength) characters")
        }
    }

    /// Fails for a record case with a field named `_tag` or `_args`, which
    /// has no schema-based form (§16.3).
    func checkReserved(_ c: CaseType) throws(HausError) {
        if let f = c.reservedField {
            throw fail(.noJsonForm, "\(c.tag) has a field named \(f), so it has no schema-based JSON form")
        }
    }

    /// A tag an open variant doesn't list (§16.3): the bare tag; with
    /// `"_args"` alone, its arguments as self-describing values; otherwise
    /// its other members as a record payload, by the import.
    mutating func unknownJSON(_ tag: String, _ r: HausRecord) throws(HausError) -> HausValue {
        try checkTagLength(tag)
        if r.count == 1 { return .tag(tag) }
        if r.count == 2, let args = r["_args"] {
            var form = SelfDescribing(limits: limits, path: path)
            return try form.variant(tag, args, depth: depth)
        }
        let payload = HausValue.record(HausRecord(distinct: r.fields.filter { !sameCodePoints($0.key, "_tag") }))
        try imported(payload, depth: depth)
        return .variant(tag, [payload])
    }

    /// Checks a value the import gave (§16.1) against the limits: its strings
    /// and keys, and its nesting, for a value at `depth` (a record payload
    /// counts as the variant's level).
    mutating func imported(_ v: HausValue, depth: Int) throws(HausError) {
        switch v {
        case .string(let s):
            try checkLength(s, .stringTooLong, "string")
        case .array(let items):
            if !items.isEmpty && depth >= limits.maxDepth { throw tooDeep() }
            for (i, x) in items.enumerated() {
                path.append(.index(i))
                try imported(x, depth: depth + 1)
                path.removeLast()
            }
        case .record(let r):
            if !r.isEmpty && depth >= limits.maxDepth { throw tooDeep() }
            for (key, x) in r.fields {
                path.append(.key(key))
                try checkLength(key, .keyTooLong, "key")
                try imported(x, depth: depth + 1)
                path.removeLast()
            }
        case .number, .bytes, .variant:
            break
        }
    }
}

/// Whether `s` is `-?(0|[1-9][0-9]*)`.
func isDecimalInteger(_ s: String) -> Bool {
    let digits = s.utf8.dropFirst(s.hasPrefix("-") ? 1 : 0)
    guard let first = digits.first, first != ASCII.zero || digits.count == 1 else { return false }
    return digits.allSatisfy(isDigit)
}

/// Whether `s` is a JSON number literal (RFC 8259), as the JSON reader reads
/// one: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`. Over the number
/// limits or not, it is one.
func isJSONNumber(_ s: String) -> Bool {
    withUTF8(s) { b in
        var reader = JSONReader(b, limits: Limits(), mode: .schema)
        do throws(HausError) {
            _ = try reader.number()
        } catch {
            if error.code == .jsonSyntax { return false }
        }
        return reader.pos == b.count
    }
}

/// A JSON number literal normalized (spec §2): the exponent as `e`, without
/// `+` and leading zeros, and no `-` on a zero exponent: `1E+05` is `1e5`.
func normalizeJSONNumber(_ s: String) -> String {
    guard let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return s }
    let exponent = s[s.index(after: e)...]
    let negative = exponent.hasPrefix("-")
    let digits = exponent.drop { $0 == "+" || $0 == "-" }.drop { $0 == "0" }
    if digits.isEmpty { return s[..<e] + "e0" }
    return s[..<e] + (negative ? "e-" : "e") + digits
}

// ── writing ─────────────────────────────────────────────────────

/// Writes a decoded value with its type. As in decoding, a container is
/// first opened (written up to its parts, ``Opened``) by a function that
/// returns before its parts are written, so that the recursion, `value`,
/// has one small frame per level.
struct SchemaJSONWriter {
    var out: [UInt8] = []
    var path: [PathStep] = []

    /// A container being written: its parts, how they are separated, and its end.
    final class Opened {
        let parts: Parts
        /// Write the parts' keys: `"key":` (records and maps).
        let keyed: Bool
        /// Write a comma before the first part too (the fields beside `"_tag"`).
        let commaFirst: Bool
        let close: String
        /// The parts written so far.
        var written = 0

        init(_ parts: Parts, keyed: Bool = false, commaFirst: Bool = false, close: String) {
            self.parts = parts
            self.keyed = keyed
            self.commaFirst = commaFirst
            self.close = close
        }
    }

    @inline(never)
    func fail(_ code: HausError.Code, _ message: String) -> HausError {
        HausError(code, message, path: pathString(path))
    }

    @inline(never)
    func cannotEncode(_ v: HausValue, _ t: SchemaNode) -> HausError {
        fail(.cannotEncode, "expected \(t.described), found \(found(v))")
    }

    /// Writes `v`, which the type `t` decoded (or encoded).
    mutating func value(_ v: HausValue, _ t: SchemaNode) throws(HausError) {
        guard let opened = try open(v, t) else { return }
        for i in 0..<opened.parts.count {
            guard let type = start(opened, i) else { continue }
            try value(opened.parts.item(i), type)
            path.removeLast()
        }
        out += opened.close.utf8
    }

    /// Starts part `i` of a container: writes its separator and key, and
    /// returns its type; nil for a field the record type doesn't list (an
    /// open record ignores it).
    @inline(never)
    mutating func start(_ opened: Opened, _ i: Int) -> SchemaNode? {
        let parts = opened.parts
        let type: SchemaNode
        switch parts.types {
        case .all(let t): type = t
        case .each(let types): type = types[i]
        case .shape(let shape, _):
            guard case .fields(let r) = parts.source, let f = shape.field(r[i].key) else { return nil }
            type = f.type
        }
        if opened.written > 0 || opened.commaFirst { out.append(ASCII.comma) }
        opened.written += 1
        if opened.keyed, case .fields(let r) = parts.source {
            appendJSONString(r[i].key, to: &out)
            out.append(ASCII.colon)
        }
        path.append(parts.step(i)!)
        return type
    }

    /// Writes a scalar whole, or a container up to its parts, which it returns.
    @inline(never)
    mutating func open(_ v: HausValue, _ t: SchemaNode) throws(HausError) -> Opened? {
        let rt = t.resolved
        switch (rt.kind, v) {
        case (.array(let element), .array(let items)):
            out.append(ASCII.openBracket)
            return Opened(Parts(.items(items), .all(element), .array), close: "]")
        case (.map(let element), .record(let r)):
            out.append(ASCII.openBrace)
            return Opened(Parts(.fields(r), .all(element), .record), keyed: true, close: "}")
        case (.record(let shape), .record(let r)):
            out.append(ASCII.openBrace)
            return Opened(Parts(.fields(r), .shape(shape, payload: false), .record), keyed: true, close: "}")
        case (.maybe(let element), _):
            return try maybe(v, element, rt)
        case (.secret(let item), _):
            return try open(v, item)
        case (.variant(let shape), .variant(let tag, let args)):
            return try variant(tag, args, shape)
        default:
            try scalar(v, rt, t)
            return nil
        }
    }

    /// A string, number, byte string, boolean, float, time or `Any`.
    mutating func scalar(_ v: HausValue, _ rt: SchemaNode, _ t: SchemaNode) throws(HausError) {
        switch (rt.kind, v) {
        case (.builtin(.string), .string(let s)):
            appendJSONString(s, to: &out)
        case (.time, .variant(_, let args)) where args.count == 1:
            guard case .string(let s) = args[0] else { throw cannotEncode(v, t) }
            appendJSONString(s, to: &out)
        case (.builtin(.bytes), .bytes(let b)):
            out.append(ASCII.quote)
            appendBase64(b, to: &out)
            out.append(ASCII.quote)
        case (.builtin(.bool), .variant(let tag, _)):
            out += (tag == "True" ? "true" : "false").utf8
        case (.builtin(let b), .number(let n)) where b.range != nil && b.range!.bits < 64:
            out += n.literal.utf8
        case (.builtin(.int), .number(let n)), (.builtin(.int64), .number(let n)), (.builtin(.uint64), .number(let n)),
            (.builtin(.decimal), .number(let n)):
            appendJSONString(n.literal, to: &out)
        case (.builtin(.float32), .number(let n)), (.builtin(.float64), .number(let n)):
            out += n.literal.utf8
        case (.builtin(.float32), .variant(let tag, _)), (.builtin(.float64), .variant(let tag, _)):
            appendJSONString(tag == "NegInfinity" ? "-Infinity" : tag, to: &out)
        case (.builtin(.any), _):
            try appendSelfDescribing(v, to: &out)
        default:
            throw cannotEncode(v, t)
        }
    }

    mutating func maybe(_ v: HausValue, _ element: SchemaNode, _ rt: SchemaNode) throws(HausError) -> Opened? {
        switch v {
        case .variant("None", _):
            out += (rt.jsonNull ? "null" : #"{"_tag":"None"}"#).utf8
            return nil
        case .variant(_, let args) where args.count == 1:
            let some = Parts(.items(args), .each([element]), .array)
            if rt.jsonNull { return Opened(some, close: "") }
            out += #"{"_tag":"Some","value":"#.utf8
            return Opened(some, close: "}")
        default:
            throw fail(.cannotEncode, "expected None or Some(…), found \(found(v))")
        }
    }

    mutating func variant(_ tag: String, _ args: [HausValue], _ shape: VariantShape) throws(HausError) -> Opened? {
        if shape.isEnum {
            appendJSONString(tag, to: &out)
            return nil
        }
        out += #"{"_tag":"#.utf8
        appendJSONString(tag, to: &out)
        guard let c = shape.caseOf(tag) else {
            // An unknown value.
            if !args.isEmpty {
                out += #","_args":"#.utf8
                try appendSelfDescribing(.array(args), to: &out)
            }
            out.append(ASCII.closeBrace)
            return nil
        }
        switch c.payload {
        case .none:
            out.append(ASCII.closeBrace)
            return nil
        case .record, .named:
            if let f = c.reservedField {
                throw fail(.noJsonForm, "\(c.tag) has a field named \(f), so it has no schema-based JSON form")
            }
            guard args.count == 1, case .record(let r) = args[0] else {
                throw fail(.cannotEncode, "\(c.tag) takes one argument, a record")
            }
            let fields = Parts(.fields(r), .shape(c.record!, payload: false), .record)
            return Opened(fields, keyed: true, commaFirst: true, close: "}")
        case .positional(let items) where items.count == 1:
            out += #","value":"#.utf8
            return Opened(Parts(.items(args), .each(items), .array), close: "}")
        case .positional(let items):
            out += #","values":["#.utf8
            return Opened(Parts(.items(args), .each(items), .array), close: "]}")
        }
    }
}

// ── base64 (RFC 4648 §4) ────────────────────────────────────────

private let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

/// The value of each base64 digit; nil for other bytes.
private let base64Values: [UInt8?] = (0...255).map { c in base64Alphabet.firstIndex(of: UInt8(c)).map(UInt8.init) }

/// Appends `bytes` in base64 with padding.
func appendBase64(_ bytes: [UInt8], to out: inout [UInt8]) {
    for start in stride(from: 0, to: bytes.count, by: 3) {
        let chunk = bytes[start..<min(start + 3, bytes.count)]
        let n = chunk.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (16 - 8 * $1.offset) }
        for k in 0..<4 {
            out.append(k <= chunk.count ? base64Alphabet[Int(n >> (18 - 6 * k) & 0x3F)] : UInt8(ascii: "="))
        }
    }
}

/// Decodes canonical padded base64 (RFC 4648 §4): no whitespace, no URL
/// alphabet, zero pad bits. Nil for anything else.
func fromBase64(_ s: String) -> [UInt8]? {
    let digits = Array(s.utf8)
    guard digits.count % 4 == 0 else { return nil }
    let padding = digits.reversed().prefix { $0 == UInt8(ascii: "=") }.count
    guard padding <= 2 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(digits.count / 4 * 3)
    for start in stride(from: 0, to: digits.count, by: 4) {
        let group = digits[start..<(start + 4)]
        let pad = start + 4 == digits.count ? padding : 0
        var n: UInt32 = 0
        for c in group.dropLast(pad) {
            guard let v = base64Values[Int(c)] else { return nil }
            n = n << 6 | UInt32(v)
        }
        n <<= 6 * UInt32(pad)
        let kept = 3 - pad
        // The pad bits are zero.
        guard n & ((1 << (8 * UInt32(pad))) - 1) == 0 else { return nil }
        for k in 0..<kept { out.append(UInt8(n >> (16 - 8 * UInt32(k)) & 0xFF)) }
    }
    return out
}
