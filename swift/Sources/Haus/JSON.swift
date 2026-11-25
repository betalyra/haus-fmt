// JSON (spec §16): a strict reader of I-JSON that keeps numbers exact, a
// writer, and the two forms that need no schema, the JSON import (§16.1)
// and self-describing JSON (§16.2). Schema-based JSON (§16.3) reads JSON
// with the same reader.
//
// The reader turns JSON into the haus value the import gives (§16.1):
// objects are records, arrays arrays, strings strings, numbers numbers with
// their literal normalized, true, false and null the tags True, False and
// None. Since JSON has no other tags, the other forms read that value
// without losing anything of the JSON: a variant in it is a JSON literal.

// ── the public API ──────────────────────────────────────────────

/// Reads any JSON text as a haus value (spec §16.1): an object as a record,
/// an array as an array, a string as a string, a number as a number with its
/// literal normalized (`1E+05` is `1e5`, `19.90` stays `19.90`), `true` and
/// `false` as `True` and `False`, and `null` as `None`. Nothing in the data
/// is special: `{"_tag": "A"}` is a record.
///
/// ```swift
/// let v = try importJSON(#"{"total": 19.90, "paid": true}"#) // { total: 19.90, paid: True }
/// ```
///
/// The JSON must be I-JSON (RFC 7493): no duplicate member names
/// (`duplicate-key`), no unpaired surrogates (`unpaired-surrogate`). A
/// leading byte order mark is ignored. The depth limit is the JSON nesting,
/// and strings and member names count their characters after escapes are
/// read. Errors have the position in the JSON text.
public func importJSON(_ text: String, limits: Limits = Limits()) throws(HausError) -> HausValue {
    try withUTF8(text) { (b) throws(HausError) in
        try readJSON(b, limits: limits.checked(), mode: .import, skipBOM: true)
    }
}

/// Reads JSON text in UTF-8 with the JSON import; invalid UTF-8 fails with
/// the code `invalid-utf8`. See ``importJSON(_:limits:)``.
public func importJSON(bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(HausError) -> HausValue {
    try withBytes(bytes) { (b) throws(HausError) in
        try readJSON(b, limits: limits.checked(), mode: .import, skipBOM: true)
    }
}

/// Writes a value as self-describing JSON (spec §16.2), in its envelope,
/// on one line without spaces: `{"_haus":1,"_value":{"_num":"19.90"}}`. The
/// value is checked first, as ``checkValue(_:limits:)`` does. Strings are
/// written as UTF-8, with controls, DEL, C1 and bidi controls and U+2028
/// and U+2029 escaped.
public func toHausJSON(_ value: HausValue, limits: Limits = Limits()) throws(HausError) -> String {
    var out: [UInt8] = []
    try appendHausJSON(value, limits: limits, to: &out)
    return String(decoding: out, as: UTF8.self)
}

/// Reads self-describing JSON (spec §16.2). The text must be an envelope
/// `{"_haus": 1, "_value": …}`, and the value exactly one of the forms of
/// §16.2 (`haus-json-form` otherwise): every accepted text is the form of
/// exactly one value. Errors in the JSON text have its position; errors in
/// the form have the path of the JSON member, such as
/// `$._value._rec.price._num`.
///
/// The limits are counted on the haus value read; the JSON nesting is
/// limited to 4·d + 2 for the depth limit d (spec §16, "Limits").
public func fromHausJSON(_ text: String, limits: Limits = Limits()) throws(HausError) -> HausValue {
    try withUTF8(text) { (b) throws(HausError) in try readHausJSON(b, limits: limits.checked(), skipBOM: true) }
}

/// Reads self-describing JSON in UTF-8. See ``fromHausJSON(_:limits:)``.
public func fromHausJSON(bytes: some Collection<UInt8>, limits: Limits = Limits()) throws(HausError) -> HausValue {
    try withBytes(bytes) { (b) throws(HausError) in try readHausJSON(b, limits: limits.checked(), skipBOM: true) }
}

/// Appends the self-describing JSON of `value` in its envelope, after
/// checking it against `limits`.
func appendHausJSON(_ value: HausValue, limits: Limits, to out: inout [UInt8]) throws(HausError) {
    out += #"{"_haus":1,"_value":"#.utf8
    var walk = Walk(SelfDescribingSpelling(), checks: .writer(limits))
    try walk.write(value, to: &out)
    out.append(ASCII.closeBrace)
}

/// Reads one self-describing JSON text, in its envelope.
func readHausJSON(_ b: Bytes, limits: Limits, skipBOM: Bool) throws(HausError) -> HausValue {
    let j = try readJSON(b, limits: limits, mode: .selfDescribing, skipBOM: skipBOM)
    var form = SelfDescribing(limits: limits)
    return try form.envelope(j)
}

// ── reading JSON ────────────────────────────────────────────────

/// What a JSON text is read for: it sets the nesting limit and which checks
/// happen while reading.
enum JSONMode {
    /// The import (§16.1): nesting up to d, and the string limits of §7
    /// checked on every string and member name.
    case `import`
    /// Schema-based JSON (§16.3): nesting up to 4·d + 1; the limits are
    /// checked on the value read with the type.
    case schema
    /// Self-describing JSON (§16.2): nesting up to 4·d + 2 (the envelope),
    /// and raw DEL, C1 and bidi controls rejected.
    case selfDescribing

    /// The JSON nesting the mode reads (spec §16, "Limits"): a form can take
    /// up to four JSON levels for one haus level (`Tag { … }` is
    /// `{"_tag": …, "_args": [{"_rec": {…}}]}`), one more for a number
    /// (`{"_num": …}`), and one more for the envelope.
    func maxDepth(_ limits: Limits) -> Int {
        switch self {
        case .import: limits.maxDepth
        case .schema: 4 * limits.maxDepth + 1
        case .selfDescribing: 4 * limits.maxDepth + 2
        }
    }
}

/// Reads one JSON text (RFC 8259, restricted to I-JSON, RFC 7493) for
/// `mode`, as the haus value the import gives. A leading byte order mark is
/// skipped if `skipBOM`.
func readJSON(_ b: Bytes, limits: Limits, mode: JSONMode, skipBOM: Bool) throws(HausError) -> HausValue {
    var reader = JSONReader(b, limits: limits, mode: mode)
    return try reader.text(skipBOM: skipBOM)
}

/// A JSON reader over bytes. It doesn't recurse: the containers being read
/// are on a stack of their own (``value()``).
struct JSONReader {
    let b: Bytes
    var pos = 0
    let limits: Limits
    let mode: JSONMode
    let maxDepth: Int

    init(_ b: Bytes, limits: Limits, mode: JSONMode) {
        self.b = b
        self.limits = limits
        self.mode = mode
        maxDepth = mode.maxDepth(limits)
    }

    /// An object or array being read.
    struct Open {
        let isObject: Bool
        var items: [HausValue] = []
        var fields = RecordBuilder()
        /// The member name of the value being read, in an object.
        var key = ""

        var closer: UInt8 { isObject ? ASCII.closeBrace : ASCII.closeBracket }

        mutating func add(_ v: HausValue) {
            if isObject { fields.append(key, v) } else { items.append(v) }
        }

        consuming func close() -> HausValue {
            isObject ? .record(fields.record) : .array(items)
        }
    }

    @inline(__always)
    func byte(_ i: Int) -> UInt8? { i < b.count ? b[i] : nil }

    /// The whole text: one value, with whitespace around it.
    mutating func text(skipBOM: Bool) throws(HausError) -> HausValue {
        if let bad = firstInvalidUTF8(b) { throw fail(bad, .invalidUtf8, "invalid UTF-8") }
        if skipBOM && b.starts(with: byteOrderMark) { pos = byteOrderMark.count }
        skipWhitespace()
        let v = try value()
        skipWhitespace()
        guard pos == b.count else {
            throw syntax(expected: "the end of the JSON text", "unexpected text after the JSON value")
        }
        return v
    }

    mutating func skipWhitespace() {
        while let c = byte(pos), c == ASCII.space || c == ASCII.tab || c == ASCII.lf || c == ASCII.cr { pos += 1 }
    }

    // ── errors ──────────────────────────────────────────────────

    @inline(never)
    func fail(_ i: Int, _ code: HausError.Code, _ message: String, expected: String? = nil, found: String? = nil)
        -> HausError
    {
        HausError(code, message, position: sourcePosition(of: i, in: b), expected: expected, found: found)
    }

    /// Text that isn't JSON: `expected` should be at `pos`.
    @inline(never)
    func syntax(expected: String, _ reason: String) -> HausError {
        let found = describeCharacter(at: pos, in: b)
        return fail(pos, .jsonSyntax, "\(reason), found \(found)", expected: expected, found: found)
    }

    // ── values ──────────────────────────────────────────────────

    /// The value at `pos`.
    mutating func value() throws(HausError) -> HausValue {
        var open: [Open] = []
        while true {
            var read = try begin(&open)
            while let v = read {
                guard !open.isEmpty else { return v }
                read = try add(v, to: &open)
            }
        }
    }

    /// Reads a value at `pos`: a scalar or an empty object or array, or nil
    /// after opening one whose first value comes next.
    mutating func begin(_ open: inout [Open]) throws(HausError) -> HausValue? {
        switch byte(pos) {
        case ASCII.openBrace:
            try enter(depth: open.count)
            if byte(pos) == ASCII.closeBrace {
                pos += 1
                return .record(HausRecord())
            }
            var object = Open(isObject: true)
            try memberName(&object)
            open.append(object)
            return nil
        case ASCII.openBracket:
            try enter(depth: open.count)
            if byte(pos) == ASCII.closeBracket {
                pos += 1
                return .array([])
            }
            open.append(Open(isObject: false))
            return nil
        default:
            return try leaf()
        }
    }

    /// Moves past the bracket that opens a container `depth` levels deep.
    mutating func enter(depth: Int) throws(HausError) {
        if depth >= maxDepth { throw fail(pos, .nestingTooDeep, "JSON nesting deeper than \(maxDepth) levels") }
        pos += 1
        skipWhitespace()
    }

    /// Adds the value read to the innermost container, and reads the comma
    /// after it (and the next member name) or its closer: the closed
    /// container's value, or nil when its next value comes next.
    mutating func add(_ v: HausValue, to open: inout [Open]) throws(HausError) -> HausValue? {
        let top = open.count - 1
        open[top].add(v)
        skipWhitespace()
        switch byte(pos) {
        case ASCII.comma:
            pos += 1
            skipWhitespace()
            if open[top].isObject { try memberName(&open[top]) }
            return nil
        case open[top].closer:
            pos += 1
            return open.removeLast().close()
        default:
            throw syntax(
                expected: open[top].isObject ? "',' or '}'" : "',' or ']'",
                open[top].isObject ? "expected ',' or '}'" : "expected ',' or ']'")
        }
    }

    /// Reads a member name and the colon after it.
    mutating func memberName(_ object: inout Open) throws(HausError) {
        guard byte(pos) == ASCII.quote else {
            throw syntax(expected: "a member name", "expected a member name (a string)")
        }
        let at = pos
        let key = try string(tooLong: .keyTooLong)
        guard object.fields.isNew(key) else {
            throw fail(at, .duplicateKey, "duplicate member name \(quoteForMessage(key))")
        }
        object.key = key
        skipWhitespace()
        guard byte(pos) == ASCII.colon else { throw syntax(expected: "':'", "expected ':' after the member name") }
        pos += 1
        skipWhitespace()
    }

    /// `true`, `false` and `null`.
    static let literals: [(text: [UInt8], value: HausValue)] = [
        (Array("true".utf8), .tag("True")), (Array("false".utf8), .tag("False")), (Array("null".utf8), .tag("None")),
    ]

    /// A string, number or literal at `pos`.
    @inline(never)
    mutating func leaf() throws(HausError) -> HausValue {
        switch byte(pos) {
        case ASCII.quote:
            return .string(try string(tooLong: .stringTooLong))
        case let c? where c == ASCII.minus || isDigit(c):
            return try number()
        case nil:
            throw syntax(expected: "a JSON value", "unexpected end of the JSON text, expected a value")
        default:
            let rest = Bytes(rebasing: b[pos...])
            guard let literal = Self.literals.first(where: { rest.starts(with: $0.text) }) else {
                throw syntax(expected: "a JSON value", "expected a JSON value")
            }
            pos += literal.text.count
            return literal.value
        }
    }

    /// The end of the run of digits from `i`.
    func digitsEnd(from i: Int) -> Int {
        var i = i
        while let c = byte(i), isDigit(c) { i += 1 }
        return i
    }

    /// A JSON number token, normalized (spec §2). Its length and exponent
    /// are checked against the number limits (§16, "Limits").
    mutating func number() throws(HausError) -> HausValue {
        let start = pos
        var i = byte(pos) == ASCII.minus ? pos + 1 : pos
        if byte(i) == ASCII.zero {
            i += 1
        } else {
            let end = digitsEnd(from: i)
            guard end > i else {
                pos = i
                throw syntax(expected: "a digit", "invalid number")
            }
            i = end
        }
        if byte(i) == ASCII.dot {
            let end = digitsEnd(from: i + 1)
            guard end > i + 1 else {
                pos = i + 1
                throw syntax(expected: "a digit", "invalid number: expected a digit after '.'")
            }
            i = end
        }
        if let e = byte(i), e == ASCII.e || e == ASCII.E {
            i += 1
            if let sign = byte(i), sign == ASCII.plus || sign == ASCII.minus { i += 1 }
            let end = digitsEnd(from: i)
            guard end > i else {
                pos = i
                throw syntax(expected: "a digit", "invalid number: expected a digit in the exponent")
            }
            i = end
        }
        pos = i
        do throws(NumberError) {
            let normalized = try scanNumber(Bytes(rebasing: b[start..<i]), at: 0, limits: limits).normalized
            return .number(HausNumber(normalized: normalized))
        } catch {
            throw fail(start + error.at, error.code, error.message)
        }
    }

    /// A string token at `pos` (a `"`). Its length is checked only by the
    /// import: the other forms count the haus value (§16, "Limits"), and a
    /// JSON string can be a member name of the form, a number or base64.
    @inline(never)
    mutating func string(tooLong: HausError.Code) throws(HausError) -> String {
        let start = pos
        let strict = mode == .selfDescribing
        var i = start + 1
        var decoded: [UInt8]?  // the value, once an escape needs decoding
        var plain = i  // the start of the current run of plain characters
        while true {
            guard let (at, special) = nextSpecial(b, from: i, to: b.count) else {
                throw fail(start, .unterminatedString, "unterminated string")
            }
            i = at + special.width
            switch special {
            case .quote:
                pos = i
                let value =
                    decoded.map { String(decoding: $0 + b[plain..<at], as: UTF8.self) }
                    ?? String(decoding: Bytes(rebasing: b[plain..<at]), as: UTF8.self)
                try checkLength(value, start, tooLong)
                return value
            case .backslash:
                decoded = (decoded ?? []) + b[plain..<at]
                i = try escape(at: at, into: &decoded!)
                plain = i
            case .control(let c) where c < 0x20:
                throw rawControl(at, .controlCharacter, "raw control character")
            case .control, .c1:
                if strict { throw rawControl(at, .controlCharacter, "raw control character") }
            case .bidi:
                if strict { throw rawControl(at, .bidiControl, "raw bidirectional control") }
            case .lineSeparator:
                break
            }
        }
    }

    @inline(never)
    func rawControl(_ i: Int, _ code: HausError.Code, _ what: String) -> HausError {
        fail(i, code, "\(what) \(codePointName(scalar(at: i, in: b))) in a string (write it as an escape)")
    }

    /// Fails with `code` if the import reads a string longer than the limit.
    func checkLength(_ value: String, _ start: Int, _ code: HausError.Code) throws(HausError) {
        guard mode == .import, longerThan(value, limits.maxStringLength) != nil else { return }
        let what = code == .keyTooLong ? "member name" : "string"
        throw fail(start, code, "a \(what) longer than the limit of \(limits.maxStringLength) characters")
    }

    /// Decodes the escape whose backslash is at `i`, appends its character
    /// to `out`, and returns the offset after it.
    func escape(at i: Int, into out: inout [UInt8]) throws(HausError) -> Int {
        guard let c = byte(i + 1) else { throw fail(i, .invalidEscape, "invalid escape at the end of the text") }
        let simple: UInt8? =
            switch c {
            case ASCII.quote, ASCII.backslash, ASCII.slash: c
            case ASCII.b: 0x08
            case UInt8(ascii: "f"): 0x0C
            case ASCII.n: ASCII.lf
            case ASCII.r: ASCII.cr
            case ASCII.t: ASCII.tab
            default: nil
            }
        if let simple {
            out.append(simple)
            return i + 2
        }
        guard c == ASCII.u else {
            throw fail(i, .invalidEscape, "invalid escape \\\(describeCharacter(at: i + 1, in: b))")
        }
        let unpaired = fail(i, .unpairedSurrogate, #"an unpaired surrogate in a \u escape"#)
        let unit = try hex4(at: i + 2)
        switch unit {
        case 0xDC00...0xDFFF:
            throw unpaired
        case 0xD800...0xDBFF:
            // A \u after a high surrogate is an escape like any other: four hex digits first.
            guard byte(i + 6) == ASCII.backslash && byte(i + 7) == ASCII.u else { throw unpaired }
            let low = try hex4(at: i + 8)
            guard (0xDC00...0xDFFF).contains(low) else { throw unpaired }
            out += UTF8.encode(Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))!)!
            return i + 12
        default:
            out += UTF8.encode(Unicode.Scalar(unit)!)!
            return i + 6
        }
    }

    /// The four hex digits at `i`, of a `\u` escape.
    func hex4(at i: Int) throws(HausError) -> UInt32 {
        var unit: UInt32 = 0
        for k in i..<(i + 4) {
            guard let d = byte(k).flatMap(hexValue) else {
                throw fail(i, .invalidUnicodeEscape, #"expected four hex digits after \u"#)
            }
            unit = unit << 4 | UInt32(d)
        }
        return unit
    }
}

// ── writing JSON ────────────────────────────────────────────────

/// Appends `s` as a JSON string. Besides `"` and `\`, it escapes what
/// writers must (§16): every character below U+0020, DEL, C1 controls, bidi
/// controls and U+2028 and U+2029.
func appendJSONString(_ s: String, to out: inout [UInt8]) {
    appendQuoted(s, to: &out) { special, i, b, out in
        switch special {
        case .quote: out += #"\""#.utf8
        case .backslash: out += #"\\"#.utf8
        case .control(ASCII.lf): out += #"\n"#.utf8
        case .control(ASCII.cr): out += #"\r"#.utf8
        case .control(ASCII.tab): out += #"\t"#.utf8
        case .control, .c1, .bidi, .lineSeparator:
            // \u and four lowercase hex digits: every such character is below U+10000.
            let c = scalar(at: i, in: b)
            out += #"\u"#.utf8
            appendHex([UInt8(c >> 8), UInt8(c & 0xFF)], to: &out)
        }
    }
}

/// Appends the self-describing form of `v` (§16.2), without the envelope,
/// for a value checked already.
func appendSelfDescribing(_ v: HausValue, to out: inout [UInt8]) throws(HausError) {
    var walk = Walk(SelfDescribingSpelling(), checks: .none)
    try walk.write(v, to: &out)
}

// ── self-describing JSON (§16.2) ────────────────────────────────

/// Reads the self-describing form of a value from the JSON read as the
/// import's value. Errors have the path of the JSON member, from `path`
/// (empty for `$`, or the place of the form inside schema-based JSON).
struct SelfDescribing {
    let limits: Limits
    var path: [PathStep] = []

    @inline(never)
    func fail(_ code: HausError.Code, _ message: String) -> HausError {
        HausError(code, message, path: pathString(path))
    }

    /// `{"_haus": 1, "_value": …}`.
    mutating func envelope(_ j: HausValue) throws(HausError) -> HausValue {
        guard case .record(let r) = j, r.count == 2, let version = r["_haus"], let value = r["_value"] else {
            throw fail(.hausJsonForm, #"expected the envelope {"_haus": 1, "_value": …}, found \#(describeJSON(j))"#)
        }
        guard case .number(let n) = version, n.literal == "1" else {
            path.append(.key("_haus"))
            throw fail(
                .hausJsonVersion,
                "expected version 1 of self-describing JSON in '_haus', found \(describeJSON(version))")
        }
        path.append(.key("_value"))
        return try self.value(value, depth: 0)
    }

    /// One level deeper than `depth`, within the depth limit.
    func deeper(_ depth: Int) throws(HausError) -> Int {
        guard depth < limits.maxDepth else { throw tooDeep() }
        return depth + 1
    }

    @inline(never)
    func tooDeep() -> HausError { fail(.nestingTooDeep, "nesting deeper than \(limits.maxDepth) levels") }

    /// The value of the form `j`, inside containers `depth` levels deep.
    mutating func value(_ j: HausValue, depth: Int) throws(HausError) -> HausValue {
        try read(.form(j), depth: depth)
    }

    /// The value of `{"_tag": tag, "_args": args}`, inside containers
    /// `depth` levels deep.
    mutating func variant(_ tag: HausTag, _ args: HausValue, depth: Int) throws(HausError) -> HausValue {
        try read(.arguments(tag, args), depth: depth)
    }

    /// What is read next: a form, or the `_args` of a tag.
    enum Next {
        case form(HausValue)
        case arguments(HausTag, HausValue)
    }

    /// A container of the form being read: the forms of its items, and the
    /// values read from them so far.
    struct Frame {
        enum Kind {
            case array
            /// The fields of `{"_rec": …}`, which has their keys.
            case record(HausRecord)
            /// The arguments of a tag.
            case arguments(HausTag)
            /// The fields of a tag's record payload, which has their keys.
            case recordPayload(HausTag, HausRecord)
        }

        let kind: Kind
        let items: [HausValue]
        var values: [HausValue] = []
        /// The steps from the container's form to its items on the path.
        let steps: Int
        /// The depth of its items.
        let depth: Int

        var value: HausValue {
            switch kind {
            case .array: .array(values)
            case .record(let r): .record(HausRecord(keysOf: r, values: values))
            case .arguments(let tag): .variant(tag, values)
            case .recordPayload(let tag, let r): .variant(tag, [.record(HausRecord(keysOf: r, values: values))])
            }
        }

        /// The step to item `i`.
        func step(_ i: Int) -> PathStep {
            switch kind {
            case .array, .arguments: .index(i)
            case .record(let r), .recordPayload(_, let r): .key(r.fields[i].key)
            }
        }
    }

    /// Reads `next` and everything in it. It doesn't recurse: the containers
    /// being read are on a stack of their own, so the depth limit, not the
    /// thread's stack, bounds the nesting (a self-describing value takes up
    /// to four JSON levels for one level).
    mutating func read(_ next: Next, depth: Int) throws(HausError) -> HausValue {
        var stack: [Frame] = []
        var next = next
        var depth = depth
        while true {
            guard var read = try begin(next, depth: depth, &stack) else {
                // A container opened: its first item is next.
                (next, depth) = (.form(stack[stack.count - 1].items[0]), stack[stack.count - 1].depth)
                continue
            }
            while let top = stack.indices.last {
                path.removeLast()
                stack[top].values.append(read)
                let i = stack[top].values.count
                guard i == stack[top].items.count else {
                    try enter(i, of: stack[top])
                    (next, depth) = (.form(stack[top].items[i]), stack[top].depth)
                    break
                }
                let done = stack.removeLast()
                path.removeLast(done.steps)
                read = done.value
            }
            if stack.isEmpty { return read }
        }
    }

    /// Reads `next`: a value, or nil after opening a container whose first
    /// item comes next (with its step on the path).
    mutating func begin(_ next: Next, depth: Int, _ stack: inout [Frame]) throws(HausError) -> HausValue? {
        switch next {
        case .form(.array(let items)):
            return try open(.array, items, steps: 0, depth: deeper(depth), &stack)
        case .form(.record(let r)):
            switch try form(of: r) {
            case .value(let v): return v
            case .record(let fields): return try record(fields, depth: depth, &stack)
            case .variant(let tag, let args): return try arguments(tag, args, depth: depth, &stack)
            }
        case .form(let j):
            return try leaf(j)
        case .arguments(let tag, let args):
            return try arguments(tag, args, depth: depth, &stack)
        }
    }

    /// The fields of `{"_rec": …}`.
    mutating func record(_ fields: HausValue, depth: Int, _ stack: inout [Frame]) throws(HausError) -> HausValue? {
        path.append(.key("_rec"))
        guard case .record(let r) = fields else { throw notFields(fields) }
        return try open(.record(r), r.fields.map(\.value), steps: 1, depth: deeper(depth), &stack)
    }

    /// The `_args` of `tag`.
    mutating func arguments(_ tag: HausTag, _ args: HausValue, depth: Int, _ stack: inout [Frame]) throws(HausError)
        -> HausValue?
    {
        path.append(.key("_args"))
        guard case .array(let items) = args, !items.isEmpty else { throw emptyArgs() }
        if items.count == 1, case .record(let p) = items[0], p.count == 1, sameCodePoints(p.fields[0].key, "_rec") {
            // Tag { … } is one level, as in the parser.
            path += [.index(0), .key("_rec")]
            guard case .record(let r) = p.fields[0].value else { throw notFields(p.fields[0].value) }
            return try open(.recordPayload(tag, r), r.fields.map(\.value), steps: 3, depth: deeper(depth), &stack)
        }
        return try open(.arguments(tag), items, steps: 1, depth: deeper(depth), &stack)
    }

    /// Opens a container whose items are `depth` levels deep, with its first
    /// item's step on the path; or its value if it has no items.
    mutating func open(_ kind: Frame.Kind, _ items: [HausValue], steps: Int, depth: Int, _ stack: inout [Frame])
        throws(HausError) -> HausValue?
    {
        let frame = Frame(kind: kind, items: items, steps: steps, depth: depth)
        guard !items.isEmpty else {
            path.removeLast(steps)
            return frame.value
        }
        try enter(0, of: frame)
        stack.append(frame)
        return nil
    }

    /// Puts the step to item `i` of `frame` on the path, after checking its key.
    mutating func enter(_ i: Int, of frame: Frame) throws(HausError) {
        let step = frame.step(i)
        if case .key(let key) = step { try checkKey(key) }
        path.append(step)
    }

    /// What an object stands for.
    enum Form {
        /// A number, byte string or tag without arguments.
        case value(HausValue)
        /// `{"_rec": …}`, with the member's value.
        case record(HausValue)
        /// `{"_tag": …, "_args": …}`, with the tag and the arguments' member.
        case variant(HausTag, HausValue)
    }

    /// The form of an object: `{"_rec": …}`, `{"_num": …}`, `{"_bytes": …}`,
    /// `{"_tag": …}` or `{"_tag": …, "_args": […]}`.
    @inline(never)
    mutating func form(of r: HausRecord) throws(HausError) -> Form {
        let f = r.fields
        let only = { (key: String) in f.count == 1 && sameCodePoints(f[0].key, key) }
        if only("_rec") { return .record(f[0].value) }
        if only("_num") { return .value(try number(f[0].value)) }
        if only("_bytes") { return .value(try bytes(f[0].value)) }
        if only("_tag") { return .value(.variant(try tag(f[0].value), [])) }
        if f.count == 2, let tag = r["_tag"], let args = r["_args"] { return .variant(try self.tag(tag), args) }
        throw notAForm(.record(r))
    }

    /// A string, or the error for a JSON literal or number.
    @inline(never)
    func leaf(_ j: HausValue) throws(HausError) -> HausValue {
        guard case .string(let s) = j else { throw notAForm(j) }
        if longerThan(s, limits.maxStringLength) != nil {
            throw fail(.stringTooLong, "a string longer than the limit of \(limits.maxStringLength) characters")
        }
        return j
    }

    @inline(never)
    func notAForm(_ j: HausValue) -> HausError {
        fail(.hausJsonForm, "expected the self-describing form of a haus value, found \(describeJSON(j))")
    }

    mutating func number(_ j: HausValue) throws(HausError) -> HausValue {
        path.append(.key("_num"))
        guard case .string(let text) = j, isNormalized(text) else {
            throw fail(.hausJsonNumber, "expected a normalized number literal in '_num', found \(describeJSON(j))")
        }
        if let (code, message) = numberLimitError(text, limits) { throw fail(code, message) }
        path.removeLast()
        return .number(HausNumber(normalized: text))
    }

    mutating func bytes(_ j: HausValue) throws(HausError) -> HausValue {
        path.append(.key("_bytes"))
        let isLowerHex = { (c: UInt8) in isDigit(c) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(c) }
        guard case .string(let digits) = j, digits.utf8.count % 2 == 0, digits.utf8.allSatisfy(isLowerHex) else {
            throw fail(.hausJsonBytes, "expected two lowercase hex digits per byte in '_bytes'")
        }
        if digits.utf8.count > limits.maxStringLength {
            throw fail(.stringTooLong, "a byte string longer than the limit of \(limits.maxStringLength) characters")
        }
        let hex = Array(digits.utf8)
        path.removeLast()
        return .bytes(stride(from: 0, to: hex.count, by: 2).map { hexValue(hex[$0])! << 4 | hexValue(hex[$0 + 1])! })
    }

    @inline(never)
    func emptyArgs() -> HausError {
        fail(.hausJsonForm, "'_args' must be a non-empty array (a tag without arguments has no '_args')")
    }

    @inline(never)
    func notFields(_ j: HausValue) -> HausError {
        fail(.hausJsonForm, "expected the fields of a record (an object), found \(describeJSON(j))")
    }

    @inline(never)
    func checkKey(_ key: String) throws(HausError) {
        if longerThan(key, limits.maxStringLength) != nil {
            throw fail(.keyTooLong, "a key longer than the limit of \(limits.maxStringLength) characters")
        }
    }

    /// A `_tag`; its errors are at the variant, the object that holds it.
    @inline(never)
    func tag(_ j: HausValue) throws(HausError) -> HausTag {
        guard case .string(let t) = j, isTag(t) else {
            throw fail(.invalidTag, "expected a tag ([A-Z][A-Za-z0-9_]*) in '_tag', found \(describeJSON(j))")
        }
        if t.utf8.count > limits.maxStringLength {
            throw fail(.tagTooLong, "a tag longer than the limit of \(limits.maxStringLength) characters")
        }
        return HausTag(valid: t)
    }
}

/// Whether `text` is a normalized number literal (spec §2):
/// `-?(0|[1-9][0-9]*)(\.[0-9]+)?(e(0|-?[1-9][0-9]*))?`.
func isNormalized(_ text: String) -> Bool {
    let s = Array(text.utf8)
    var i = 0
    func byte(_ k: Int) -> UInt8? { k < s.count ? s[k] : nil }
    func digits(from k: Int) -> Int {
        var k = k
        while let c = byte(k), isDigit(c) { k += 1 }
        return k
    }
    /// `0` or a digit run without a leading zero, from `k`; nil if neither.
    func integer(from k: Int) -> Int? {
        switch byte(k) {
        case ASCII.zero: k + 1
        case let c? where isDigit(c): digits(from: k)
        default: nil
        }
    }
    if byte(i) == ASCII.minus { i += 1 }
    guard let end = integer(from: i) else { return false }
    i = end
    if byte(i) == ASCII.dot {
        guard digits(from: i + 1) > i + 1 else { return false }
        i = digits(from: i + 1)
    }
    if byte(i) == ASCII.e {
        i += 1
        if byte(i) == ASCII.zero {
            i += 1
        } else {
            if byte(i) == ASCII.minus { i += 1 }
            guard let c = byte(i), isDigit(c), c != ASCII.zero else { return false }
            i = digits(from: i)
        }
    }
    return i == s.count
}

/// A short description of a JSON value read as a haus value, for messages.
func describeJSON(_ j: HausValue) -> String {
    switch j {
    case .string(let s): "the string \(quoteForMessage(s))"
    case .number(let n): "the number " + (n.literal.utf8.count > 30 ? n.literal.prefix(30) + "…" : n.literal)
    case .array: "an array"
    case .record(let r): describeObject(r)
    case .variant("True", _): "true"
    case .variant("False", _): "false"
    case .variant, .bytes: "null"
    case .secret: "a Secret"
    }
}

/// A short description of a JSON object, for messages: its first member names.
func describeObject(_ r: HausRecord) -> String {
    guard !r.isEmpty else { return "an empty object" }
    let names = r.keys.prefix(3).map(quoteForMessage) + (r.count > 3 ? ["…"] : [])
    return "an object with " + names.joined(separator: ", ")
}
