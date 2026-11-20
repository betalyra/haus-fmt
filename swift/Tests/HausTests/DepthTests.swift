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
