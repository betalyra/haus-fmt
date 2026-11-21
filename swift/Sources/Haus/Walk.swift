// Writing values without recursion, for every writer that writes a value on
// one line: the compact and minimised layouts, the canonical form,
// self-describing JSON, and the value checker (which writes nothing). The
// containers being written are on a stack of their own, so how deep a value
// is never depends on the thread's stack, in a debug build either.

/// How a writer spells values.
protocol Spelling {
    /// Whether the fields of a record are written sorted by key (the canonical form).
    var sortsKeys: Bool { get }
    /// A number, string, byte string or tag without arguments.
    mutating func leaf(_ v: HausValue, to out: inout [UInt8])
    mutating func open(_ c: Opening, to out: inout [UInt8])
    mutating func close(_ c: Opening, to out: inout [UInt8])
    /// Between two items of a container.
    mutating func separator(to out: inout [UInt8])
    /// Before the value of a field.
    mutating func key(_ key: String, to out: inout [UInt8])
}

/// A container a writer opens.
enum Opening {
    case array
    /// A record, and whether it has no fields.
    case record(empty: Bool)
    /// `Tag(…)`
    case payload(tag: String)
    /// `Tag { … }`, and whether the record has no fields.
    case recordPayload(tag: String, empty: Bool)
}

/// What a walk checks (spec §7, §9.8).
enum WalkChecks {
    /// Tags, and nesting within ``Limits/maxSupportedDepth``: the canonical form.
    case canonical
    /// Tags, nesting, and numbers (length and exponent), within the limits: the
    /// writers of a layout.
    case writer(Limits)
    /// Every limit, and the number of nodes: ``checkValue(_:limits:)``.
    case value(Limits)
    /// Nesting within ``Limits/maxSupportedDepth`` only: values checked already.
    case none

    var maxDepth: Int {
        switch self {
        case .canonical, .none: Limits.maxSupportedDepth
        case .writer(let limits), .value(let limits): limits.maxDepth
        }
    }
}

/// Writes a value with a spelling, checking it as it goes. Errors have the
/// path of the value they are about, after `prefix` (`$[3]` for an item of
/// a stream).
struct Walk<S: Spelling> {
    private(set) var spelling: S
    let prefix: [PathStep]
    /// The most nodes, for ``WalkChecks/value(_:)``; tests make it smaller.
    var maxNodes = Limits.maxNodes
    /// The checks, taken apart once: the loop below reads them for every value.
    private let level: Level
    private let limits: Limits
    private let maxDepth: Int
    /// The innermost container being written, and the ones around it.
    private var top: Frame?
    private var stack: [Frame] = []
    private var nodes = 0

    private enum Level {
        case canonical, writer, value, none
    }

    init(_ spelling: S, checks: WalkChecks, prefix: [PathStep] = []) {
        self.spelling = spelling
        self.prefix = prefix
        maxDepth = checks.maxDepth
        switch checks {
        case .canonical: (level, limits) = (.canonical, Limits())
        case .writer(let l): (level, limits) = (.writer, l)
        case .value(let l): (level, limits) = (.value, l)
        case .none: (level, limits) = (.none, Limits())
        }
    }

    /// A container being written: its items (values, or the fields of a
    /// record), and the next one.
    private struct Frame {
        let opening: Opening
        let values: [HausValue]
        let fields: [HausRecord.Field]
        var next = 0

        var count: Int { fields.isEmpty ? values.count : fields.count }
    }

    /// Writes `value`.
    mutating func write(_ value: HausValue, to out: inout [UInt8]) throws(HausError) {
        var current = value
        while true {
            try enter(current, &out)
            guard let next = try advance(&out) else { return }
            current = next
        }
    }

    /// Writes a value without items, or opens a container.
    private mutating func enter(_ v: HausValue, _ out: inout [UInt8]) throws(HausError) {
        if level == .value { try count() }
        switch v {
        case .array(let items):
            try push(.array, values: items, &out)
        case .record(let r):
            try push(.record(empty: r.isEmpty), fields: fields(r), &out)
        case .variant(let tag, let args) where !args.isEmpty:
            try checkTag(tag)
            if args.count == 1, case .record(let r) = args[0] {
                // Tag { … }: the record is the payload's one level.
                if level == .value { try count() }
                try push(.recordPayload(tag: tag, empty: r.isEmpty), fields: fields(r), &out)
            } else {
                try push(.payload(tag: tag), values: args, &out)
            }
        default:
            if case .variant(let tag, _) = v {
                try checkTag(tag)
            } else if level == .writer || level == .value {
                try checkLeaf(v)
            }
            spelling.leaf(v, to: &out)
        }
    }

    /// The next item to write, after closing the containers that are done;
    /// nil at the end of the value.
    private mutating func advance(_ out: inout [UInt8]) throws(HausError) -> HausValue? {
        while let i = top?.next {
            guard i < top!.count else {
                spelling.close(top!.opening, to: &out)
                top = stack.popLast()
                continue
            }
            top!.next = i + 1
            if i > 0 { spelling.separator(to: &out) }
            guard !top!.fields.isEmpty else { return top!.values[i] }
            let key = top!.fields[i].key
            if level == .value { try checkKey(key) }
            spelling.key(key, to: &out)
            return top!.fields[i].value
        }
        return nil
    }

    private mutating func push(
        _ opening: Opening, values: [HausValue] = [], fields: [HausRecord.Field] = [], _ out: inout [UInt8]
    ) throws(HausError) {
        if let top {
            if stack.count + 1 >= maxDepth { throw tooDeep() }
            stack.append(top)
        } else if maxDepth == 0 {
            throw tooDeep()
        }
        spelling.open(opening, to: &out)
        top = Frame(opening: opening, values: values, fields: fields)
    }

    /// The fields of a record in the order they are written.
    private func fields(_ r: HausRecord) -> [HausRecord.Field] {
        guard spelling.sortsKeys, zip(r.fields, r.fields.dropFirst()).contains(where: { precedes($1.key, $0.key) })
        else { return r.fields }
        return r.fields.sorted { precedes($0.key, $1.key) }
    }

    // ── checks ──────────────────────────────────────────────────

    /// The path of the value being written: the item each container is at.
    private var path: [PathStep] {
        (stack + (top.map { [$0] } ?? [])).reduce(into: prefix) { path, frame in
            path.append(frame.fields.isEmpty ? .index(frame.next - 1) : .key(frame.fields[frame.next - 1].key))
        }
    }

    @inline(never)
    private func fail(_ code: HausError.Code, _ message: String) -> HausError {
        HausError(code, message, path: pathString(path))
    }

    @inline(never)
    private func tooDeep() -> HausError {
        fail(.nestingTooDeep, "nesting deeper than the limit of \(maxDepth)")
    }

    private mutating func count() throws(HausError) {
        nodes += 1
        if nodes > maxNodes { throw fail(.tooManyNodes, "the value has more than \(maxNodes) nodes") }
    }

    private func checkTag(_ tag: String) throws(HausError) {
        guard level != .none else { return }
        if !isTag(tag) { throw fail(.invalidTag, invalidTag(tag)) }
        if level == .value && tag.utf8.count > limits.maxStringLength {
            throw fail(.tagTooLong, "a tag longer than the limit of \(limits.maxStringLength) characters")
        }
    }

    @inline(never)
    private func checkKey(_ key: String) throws(HausError) {
        if longerThan(key, limits.maxStringLength) != nil {
            throw fail(.keyTooLong, "a key longer than the limit of \(limits.maxStringLength) characters")
        }
    }

    /// Checks a number, string or byte string for the writers' and the
    /// value checker's limits.
    @inline(never)
    private func checkLeaf(_ v: HausValue) throws(HausError) {
        switch v {
        case .number(let n):
            // Any literal, a decimal or an exponent too: what a parser with these limits reads back.
            if let (code, message) = numberLimitError(n.literal, limits) { throw fail(code, message) }
        case .string(let s) where level == .value:
            if let n = longerThan(s, limits.maxStringLength) {
                throw fail(
                    .stringTooLong, "a string of \(n) characters, more than the limit of \(limits.maxStringLength)")
            }
        case .bytes(let b) where level == .value && 2 * b.count > limits.maxStringLength:
            throw fail(
                .stringTooLong,
                "a byte string of \(b.count) bytes, more than the limit of \(limits.maxStringLength) characters")
        default:
            break
        }
    }
}

// ── spellings ───────────────────────────────────────────────────

/// haus on one line: the compact layout, the minimised layout (no spaces),
/// or the canonical form (minimised, with records sorted by key).
struct HausSpelling: Spelling {
    /// Spaces between tokens, as in the compact layout.
    let spaces: Bool
    let sortsKeys: Bool

    static let compact = HausSpelling(spaces: true, sortsKeys: false)
    static let minimised = HausSpelling(spaces: false, sortsKeys: false)
    static let canonical = HausSpelling(spaces: false, sortsKeys: true)

    func leaf(_ v: HausValue, to out: inout [UInt8]) {
        switch v {
        case .number(let n): out += n.literal.utf8
        case .string(let s): appendQuoted(s, to: &out)
        case .bytes(let bytes):
            out += #"x""#.utf8
            appendHex(bytes, to: &out)
            out.append(ASCII.quote)
        case .variant(let tag, _): out += tag.utf8
        case .array, .record: break
        }
    }

    func open(_ c: Opening, to out: inout [UInt8]) {
        switch c {
        case .array: out.append(ASCII.openBracket)
        case .record(let empty): openBrace(empty, &out)
        case .payload(let tag):
            out += tag.utf8
            out.append(ASCII.openParen)
        case .recordPayload(let tag, let empty):
            out += tag.utf8
            if spaces { out.append(ASCII.space) }
            openBrace(empty, &out)
        }
    }

    private func openBrace(_ empty: Bool, _ out: inout [UInt8]) {
        out.append(ASCII.openBrace)
        if spaces && !empty { out.append(ASCII.space) }
    }

    func close(_ c: Opening, to out: inout [UInt8]) {
        switch c {
        case .array: out.append(ASCII.closeBracket)
        case .payload: out.append(ASCII.closeParen)
        case .record(let empty), .recordPayload(_, let empty):
            if spaces && !empty { out.append(ASCII.space) }
            out.append(ASCII.closeBrace)
        }
    }

    func separator(to out: inout [UInt8]) {
        out.append(ASCII.comma)
        if spaces { out.append(ASCII.space) }
    }

    func key(_ key: String, to out: inout [UInt8]) {
        appendKey(key, to: &out)
        out.append(ASCII.colon)
        if spaces { out.append(ASCII.space) }
    }
}

/// Self-describing JSON (spec §16.2), without the envelope.
struct SelfDescribingSpelling: Spelling {
    var sortsKeys: Bool { false }

    func leaf(_ v: HausValue, to out: inout [UInt8]) {
        switch v {
        case .string(let s):
            appendJSONString(s, to: &out)
        case .number(let n):
            out += #"{"_num":""#.utf8
            out += n.literal.utf8
            out += #""}"#.utf8
        case .bytes(let bytes):
            out += #"{"_bytes":""#.utf8
            appendHex(bytes, to: &out)
            out += #""}"#.utf8
        case .variant(let tag, _):
            tagMember(tag, &out)
            out.append(ASCII.closeBrace)
        case .array, .record:
            break
        }
    }

    /// `{"_tag":"Tag"`.
    private func tagMember(_ tag: String, _ out: inout [UInt8]) {
        out += #"{"_tag":"#.utf8
        appendJSONString(tag, to: &out)
    }

    func open(_ c: Opening, to out: inout [UInt8]) {
        switch c {
        case .array:
            out.append(ASCII.openBracket)
        case .record:
            out += #"{"_rec":{"#.utf8
        case .payload(let tag):
            tagMember(tag, &out)
            out += #","_args":["#.utf8
        case .recordPayload(let tag, _):
            tagMember(tag, &out)
            out += #","_args":[{"_rec":{"#.utf8
        }
    }

    func close(_ c: Opening, to out: inout [UInt8]) {
        switch c {
        case .array: out.append(ASCII.closeBracket)
        case .record: out += "}}".utf8
        case .payload: out += "]}".utf8
        case .recordPayload: out += "}}]}".utf8
        }
    }

    func separator(to out: inout [UInt8]) { out.append(ASCII.comma) }

    func key(_ key: String, to out: inout [UInt8]) {
        appendJSONString(key, to: &out)
        out.append(ASCII.colon)
    }
}

/// Writes nothing: for checking a value.
struct NoSpelling: Spelling {
    var sortsKeys: Bool { false }
    mutating func leaf(_ v: HausValue, to out: inout [UInt8]) {}
    mutating func open(_ c: Opening, to out: inout [UInt8]) {}
    mutating func close(_ c: Opening, to out: inout [UInt8]) {}
    mutating func separator(to out: inout [UInt8]) {}
    mutating func key(_ key: String, to out: inout [UInt8]) {}
}
