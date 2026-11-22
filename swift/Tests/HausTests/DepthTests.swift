import Testing

@testable import Haus

/// The deepest values, through every form, on a stack of 512 KiB (the size
/// of Swift concurrency's threads), in a debug build too: everything that
/// recurses does so once per level, within ``Limits/maxSupportedDepth``.
struct DepthTests {
    static let depth = Limits.maxSupportedDepth

    /// `n` levels of `open`, around `leaf`.
    static func nested(_ open: String, _ close: String, _ n: Int, _ leaf: String) -> String {
        String(repeating: open, count: n) + leaf + String(repeating: close, count: n)
    }

    /// A record payload on every level: the most JSON levels per level in
    /// self-describing JSON, `{"_tag": …, "_args": [{"_rec": {…}}]}`.
    static let payloads = nested("T { a: ", " }", depth, "Leaf")
    /// A payload, an array and a record, in turn.
    static let mixed = nested("Some([{ a: ", " }])", depth / 3, "None")

    static let schema = """
        type Payloads = closed < T { a: Payloads } | Leaf >
        type Mixed = Maybe (Array { a: Mixed })
        """

    @Test(arguments: [(payloads, "Payloads"), (mixed, "Mixed")])
    func everyForm(_ text: String, _ typeName: String) throws {
        try onStack(kibibytes: 512) { () throws in
            let v = try parse(text)
            #expect(try parse(stringify(v)) == v)
            #expect(try parse(stringify(v, FormatOptions(layout: .minimised))) == v)
            #expect(try parse(format(text, FormatOptions(layout: .compact))) == v)
            #expect(try canonical(v).utf8.count > Self.depth)
            #expect(try fromHausJSON(toHausJSON(v)) == v)
            #expect(try fromHausJSONLines(toHausJSONLines([v, v])) == [v, v])
            let type = try HausSchema(parsing: Self.schema).type(typeName)
            let decoded = try type.decode(v)
            #expect(decoded == v)
            #expect(try type.encode(decoded) == v)
            #expect(try type.fromJSON(type.toJSON(decoded)) == decoded)
        }
    }

    @Test func importJSONOnASmallStack() throws {
        let deepest = Self.nested(#"{"a": ["#, "]}", Self.depth / 2, "null")
        try onStack(kibibytes: 512) { () throws in
            #expect(try importJSON(deepest) != .tag("None"))
            let error = #expect(throws: HausError.self) { try importJSON("[" + deepest + "]") }
            #expect(error?.code == .nestingTooDeep)
        }
    }

    @Test func oneLevelTooDeep() throws {
        let tooDeep = Self.nested("T { a: ", " }", Self.depth + 1, "Leaf")
        #expect(#expect(throws: HausError.self) { try parse(tooDeep) }?.code == .nestingTooDeep)
        var v: HausValue = .tag("Leaf")
        for _ in 0...Self.depth { v = .tag("T", ["a": v]) }
        #expect(#expect(throws: HausError.self) { try toHausJSON(v) }?.code == .nestingTooDeep)
        let json = Self.nested(
            #"{"_tag": "T", "_args": [{"_rec": {"a": "#, "}}]}", Self.depth + 1, #"{"_tag": "Leaf"}"#)
        let read = #expect(throws: HausError.self) { try fromHausJSON(#"{"_haus": 1, "_value": \#(json)}"#) }
        #expect(read?.code == .nestingTooDeep)
        #expect(
            #expect(throws: HausError.self) { try parse("1", limits: Limits(maxDepth: Self.depth + 1)) }?.code
                == .unsupportedDepth)
    }

    /// A value built in code `n` levels deep, by turns an array, a variant
    /// with arguments and a variant with a record payload, around `inner`.
    static func veryDeep(_ n: Int, _ inner: HausValue) -> HausValue {
        var v = inner
        for i in 0..<n {
            switch i % 3 {
            case 0: v = .array([v])
            case 1: v = .tag("Some", v, .number(HausNumber(i)))
            default: v = .tag("Node", ["next": v, "a b": "x"])
            }
        }
        return v
    }

    /// Values built in code of any depth are freed without overflowing the
    /// stack (spec §7, `limits.depth.host-hooks`): ``HausValue/release()``
    /// on a 512 KiB thread, with parts shared with a value kept.
    @Test func releaseAnyDepth() throws {
        try onStack(kibibytes: 512) { () throws in
            var v = Self.veryDeep(100_000, 1)
            v.release()
            #expect(v == [])
            var record: HausValue = "leaf"
            for _ in 0..<100_000 { record = ["next": record] }
            var shared = HausValue.array([record])
            var outer = HausValue.tag("Pair", shared, record)
            outer.release()
            #expect(shared[0]?["next"]?["next"] != nil)
            // The last holder releases it: `record` first, then `shared`, which still holds it.
            record.release()
            shared.release()
        }
    }

    /// The canonical form, hashing and equality work at any depth, bounded
    /// only by memory (spec §12), on a thread with the default stack of a
    /// secondary thread (512 KiB): 100,000 levels, far deeper than the parser's
    /// maximum.
    @Test func anyDepthInCode() throws {
        try onStack(kibibytes: 512) { () throws in
            var a = Self.veryDeep(100_000, 1)
            var b = Self.veryDeep(100_000, 1)
            var c = Self.veryDeep(100_000, 2)
            let ca = try canonical(a)
            let cb = try canonical(b)
            let cc = try canonical(c)
            #expect(ca.hasPrefix(#"[Node{"a b":"x",next:Some([Node{"a b":"x",next:"#))
            #expect(ca == cb)
            #expect(ca != cc)
            let same = a == b
            let differs = a == c
            #expect(same)
            #expect(!differs)
            #if canImport(CryptoKit)
                let ha = try hash(a)
                let hb = try hash(b)
                let hc = try hash(c)
                #expect(ha == hb)
                #expect(ha != hc)
                #expect(try hashAll([a, c]).count == 64)
            #endif
            a.release()
            b.release()
            c.release()
        }
    }

    /// Typed values (Codable) of recursive types, as deep as the depth limit,
    /// decoded and encoded on the small stack: a variant of one positional
    /// payload per level, and a record and an array per level.
    @Test func typedValues() throws {
        indirect enum List: Codable, Equatable, Sendable {
            case cons(Int, List)
            case `nil`
        }
        struct Tree: Codable, Equatable, Sendable { let kids: [Tree] }
        let schema = try HausSchema(parsing: "type List = < Cons Int List | Nil >\ntype Tree = { kids: Array Tree }")
        let list = try parse(Self.nested("Cons(1, ", ")", Self.depth, "Nil"))
        let tree = try parse(Self.nested("{ kids: [", "] }", Self.depth / 2 - 1, "{ kids: [] }"))
        try onStack(kibibytes: 512) { () throws in
            let listType = try schema.type("List")
            let swiftList = try listType.decode(List.self, from: list)
            #expect(try listType.encode(swiftList) == list)
            let treeType = try schema.type("Tree")
            let swiftTree = try treeType.decode(Tree.self, from: tree)
            #expect(try treeType.encode(swiftTree) == tree)
        }
    }
}
