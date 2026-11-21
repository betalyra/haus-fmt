import Foundation
import Haus
import Testing

/// Parsing, errors, limits, writers and streams, beyond the shared suite.
struct APITests {
    @Test func parseOneValue() throws {
        #expect(try parse("19.90") == .number(try HausNumber("19.90")))
        #expect(try parse(bytes: Array("[1, 2]".utf8)) == [1, 2])
        #expect((#expect(throws: HausError.self) { try parse("1, 2") })?.code == .notOneValue)
        #expect((#expect(throws: HausError.self) { try parse("") })?.code == .notOneValue)
        #expect(try parseAll("Log { a: 1 },\nHeartbeat,\n") == [.tag("Log", ["a": 1]), .tag("Heartbeat")])
    }

    @Test func errorsHavePositionsInCodePoints() {
        let error = #expect(throws: HausError.self) { try parse("{ ok: true }") }
        #expect(error?.code == .booleanLiteral)
        #expect(error?.position == SourcePosition(line: 1, column: 7))
        // An emoji is one column; a byte order mark is one too (spec §8).
        let emoji = #expect(throws: HausError.self) { try parse("[\"😀\", x]") }
        #expect(emoji?.position == SourcePosition(line: 1, column: 7))
        let bom = #expect(throws: HausError.self) { try parse("\u{FEFF}{ a }") }
        #expect(bom?.position == SourcePosition(line: 1, column: 6))
        let crlf = #expect(throws: HausError.self) { try parse("{\r\n  a: ,\r\n}") }
        #expect(crlf?.position == SourcePosition(line: 2, column: 6))
    }

    @Test func invalidUTF8() {
        let error = #expect(throws: HausError.self) { try parseAll(bytes: [0x22, 0x61, 0xFF, 0x22]) }
        #expect(error?.code == .invalidUtf8)
        #expect(error?.position == SourcePosition(line: 1, column: 3))
        for bad: [UInt8] in [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]] {
            #expect((#expect(throws: HausError.self) { try parseAll(bytes: bad) })?.code == .invalidUtf8)
        }
    }

    @Test func errorJSON() {
        let error = #expect(throws: HausError.self) { try parse("Heartbeat\n{ a: 1 }") }
        #expect(error?.code == .payloadNewline)
        #expect(
            error?.json
                == #"{"code":"payload-newline","message":"the payload of Heartbeat must start on its line: expected ',', found '{'","line":2,"column":1,"expected":"','","found":"'{'","hint":"Put the payload on the tag's line, or add a comma if they are two values.","docs":"https://haus-fmt.org/docs/errors#payload-newline"}"#
        )
        #expect(
            error?.description
                == "2:1: the payload of Heartbeat must start on its line: expected ',', found '{' [payload-newline]")
    }

    @Test func limits() {
        #expect(Limits().maxHexDigits == 829)
        let deep = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        #expect(
            (#expect(throws: HausError.self) { try parse(deep, limits: Limits(maxDepth: 64)) })?.code == .nestingTooDeep
        )
        #expect(throws: Never.self) { try parse(deep, limits: Limits(maxDepth: 65)) }
        let unsupported = #expect(throws: HausError.self) {
            try parse("1", limits: Limits(maxDepth: Limits.maxSupportedDepth + 1))
        }
        #expect(unsupported?.code == .unsupportedDepth)
        #expect(unsupported?.message.contains("\(Limits.maxSupportedDepth)") == true)
        #expect(
            (#expect(throws: HausError.self) { try parse("\"abcd\"", limits: Limits(maxStringLength: 3)) })?.code
                == .stringTooLong)
        #expect(
            (#expect(throws: HausError.self) { try parse("{ abcd: 1 }", limits: Limits(maxStringLength: 3)) })?.code
                == .keyTooLong)
        #expect(
            (#expect(throws: HausError.self) { try parse("Abcd", limits: Limits(maxStringLength: 3)) })?.code
                == .tagTooLong)
        // Characters, not bytes.
        #expect(throws: Never.self) { try parse("\"ééé\"", limits: Limits(maxStringLength: 3)) }
    }

    /// The deepest nesting supported, on a stack of 512 KiB, the size of
    /// Swift concurrency's threads: the parser doesn't recurse.
    @Test func deepNestingOnASmallStack() throws {
        let depth = Limits.maxSupportedDepth
        let levels =
            String(repeating: "Some([{ a: ", count: depth / 3) + "1" + String(repeating: " }])", count: depth / 3)
        let text = String(repeating: "[", count: depth % 3) + levels + String(repeating: "]", count: depth % 3)
        let limits = Limits(maxDepth: depth)
        // The value is released on that thread too, which recurses (but less).
        let code = try onStack(kibibytes: 512) { () throws -> HausError.Code? in
            _ = try parse(text, limits: limits)
            do throws(HausError) {
                _ = try parse("[" + text + "]", limits: limits)
                return nil
            } catch {
                return error.code
            }
        }
        #expect(code == .nestingTooDeep)
    }

    /// Repeated keys are found in linear time, also among keys made to
    /// collide (spec §7): 200 000 keys take well under a second.
    @Test(.timeLimit(.minutes(1))) func manyKeys() throws {
        let n = 200_000
        let text = "{" + (0..<n).map { "\"k\(String(repeating: "x", count: 8))\($0)\": 1" }.joined(separator: ",") + "}"
        let start = Date()
        guard case .record(let r) = try parse(text) else { Issue.record("not a record"); return }
        #expect(r.count == n)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func stringify() throws {
        let v: HausValue = ["id": 7, "tags": ["a", "b"], "note": "two\nlines", "raw": .bytes([0x0B, 0xFF])]
        #expect(
            try Haus.stringify(v, FormatOptions(layout: .compact))
                == "{ id: 7, tags: [\"a\", \"b\"], note: \"two\\nlines\", raw: x\"0bff\" }\n")
        #expect(
            try Haus.stringify(v, FormatOptions(layout: .minimised))
                == "{id:7,tags:[\"a\",\"b\"],note:\"two\\nlines\",raw:x\"0bff\"}\n")
        #expect(
            try Haus.stringify(v)
                == "{\n  id: 7,\n  tags: [\n    \"a\",\n    \"b\",\n  ],\n  note: \"\"\"\n    two\n    lines\n    \"\"\",\n  raw: x\"0bff\",\n}\n"
        )
        #expect(try stringifyAll([1, 2], FormatOptions(layout: .compact)) == "1,\n2,\n")
        let long = HausValue.number(try HausNumber("0x" + String(repeating: "f", count: 829)))
        #expect(
            (#expect(throws: HausError.self) {
                try Haus.stringify(long, FormatOptions(limits: Limits(maxNumberLength: 10)))
            })?.code == .numberTooLong)
        // Every number, a decimal or an exponent too: what a parser with the same limits reads back.
        for layout in [Layout.pretty, .compact, .minimised] {
            let small = FormatOptions(layout: layout, limits: Limits(maxNumberLength: 10, maxExponent: 99))
            for (literal, code) in [
                ("1.0000000000", HausError.Code.numberTooLong), ("1e100", .exponentTooLarge),
                ("-1.5e-100", .exponentTooLarge),
            ] {
                let n = HausValue.number(try HausNumber(literal))
                #expect((#expect(throws: HausError.self) { try Haus.stringify(n, small) })?.code == code)
            }
        }
    }

    /// A value whose arrays share one array: `levels` levels of two
    /// elements each, so 2^(levels+1) - 1 values written from `levels + 1`
    /// arrays (a DAG).
    static func shared(_ levels: Int) -> HausValue {
        var v: HausValue = []
        for _ in 0..<levels { v = [v, v] }
        return v
    }

    /// Every writer of values checks every limit a value built in code can
    /// break (spec §11), with the limit's code and the value's path.
    @Test func writersCheckEveryLimit() throws {
        let small = Limits(maxDepth: 2, maxNumberLength: 4, maxExponent: 9, maxStringLength: 3, maxNodes: 6)
        let tooLong = try HausTag("Long")
        // Two places for one array: 9 values written, from 2 arrays, 2 levels.
        let three: HausValue = [1, 2, 3]
        let pair: HausValue = [three, three]
        let cases: [(HausValue, HausError.Code, String)] = [
            (["a": ["abcd"]], .stringTooLong, "$.a[0]"),
            ([.bytes([1, 2])], .stringTooLong, "$[0]"),  // 2 characters a byte
            (["abcd": 1], .keyTooLong, "$.abcd"),
            ([.tag(tooLong)], .tagTooLong, "$[0]"),
            ([.variant(tooLong, [1])], .tagTooLong, "$[0]"),
            ([.number(try HausNumber("12345"))], .numberTooLong, "$[0]"),
            ([.number(try HausNumber("1e10"))], .exponentTooLarge, "$[0]"),
            ([[[]]], .nestingTooDeep, "$[0][0]"),  // an empty array is a level
            ([.tag("A", ["a": [1]])], .nestingTooDeep, "$[0].a"),  // Tag { … } is one level
            (pair, .tooManyNodes, "$"),
        ]
        for (value, code, path) in cases {
            // A writer of a stream (here JSON Lines, and haus text of two values) starts the path with the index.
            let inStream = "$[1]" + path.dropFirst()
            let writers: [(String, String, () throws -> Void)] = [
                ("pretty", path, { _ = try Haus.stringify(value, FormatOptions(limits: small)) }),
                ("compact", path, { _ = try Haus.stringify(value, FormatOptions(layout: .compact, limits: small)) }),
                (
                    "minimised", path,
                    { _ = try Haus.stringify(value, FormatOptions(layout: .minimised, limits: small)) }
                ),
                (
                    "stream", inStream,
                    { _ = try stringifyAll([1, value], FormatOptions(layout: .compact, limits: small)) }
                ),
                ("self-describing JSON", path, { _ = try toHausJSON(value, limits: small) }),
                ("JSON Lines", inStream, { _ = try toHausJSONLines([1, value], limits: small) }),
                ("checkValue", path, { try checkValue(value, limits: small) }),
            ]
            for (name, place, write) in writers {
                let error = #expect(throws: HausError.self, "\(name): \(value)") { try write() }
                #expect(error?.code == code, "\(name): \(value)")
                #expect(error?.path == place, "\(name): \(value)")
            }
        }
        // Within the limits: 5 values (Tag { … } counts its record), 2 levels.
        let fits: HausValue = [.tag("A", ["abc": .bytes([1])]), "abc"]
        let compact = FormatOptions(layout: .compact, limits: small)
        #expect(try Haus.stringify(fits, compact) == #"[A { abc: x"01" }, "abc"]"# + "\n")
        #expect(throws: HausError.self) { try Haus.stringify(fits, FormatOptions(limits: Limits(maxNodes: 4))) }
        // In a stream, the limit applies to each value on its own, at its index.
        let stream = #expect(throws: HausError.self) { try stringifyAll([three, pair], compact) }
        #expect(stream?.code == .tooManyNodes)
        #expect(stream?.path == "$[1]")
        // Schema-based JSON checks the value it writes too.
        let type = try HausSchema(parsing: "type S = { s: String, k: Map Int, t: < Long > }").type("S")
        for (value, code, path) in [
            (["s": "abcd", "k": [:], "t": .tag("A")], HausError.Code.stringTooLong, "$.s"),
            (["s": "a", "k": ["abcd": 1], "t": .tag("A")], .keyTooLong, "$.k.abcd"),
            (["s": "a", "k": [:], "t": .tag(tooLong)], .tagTooLong, "$.t"),
        ] as [(HausValue, HausError.Code, String)] {
            let error = #expect(throws: HausError.self, "\(value)") { try type.toJSON(value, limits: small) }
            #expect(error?.code == code, "\(value)")
            #expect(error?.path == path, "\(value)")
        }
    }

    /// The canonical form and hashing apply only the node limit (spec §12):
    /// a value deeper or longer than a writer's limits has a canonical form.
    @Test func canonicalAppliesOnlyTheNodeLimit() throws {
        let deep = (0..<1000).reduce(HausValue.string(String(repeating: "x", count: 100))) { v, _ in [v] }
        let tight = Limits(maxDepth: 1, maxNumberLength: 1, maxExponent: 0, maxStringLength: 1)
        let big: HausValue = [
            deep, .number(try HausNumber("1e99999")), .tag(try HausTag("T" + String(repeating: "x", count: 50))),
            ["long key": 12345],
        ]
        let text = try canonical(big, limits: tight)
        #expect(text == (try canonical(big)))
        #expect(try hash(big, limits: tight) == (try hash(big)))
        #expect(throws: HausError.self) { try Haus.stringify(big, FormatOptions(layout: .minimised, limits: tight)) }
        // The node limit: 2^21 - 1 values written from 21 arrays.
        let dag = Self.shared(20)
        let nodes = Limits(maxNodes: 1 << 20)
        // At the value given (`$`); hashAll at the value's index, even of one value.
        for (name, place, run) in [
            ("canonical", "$", { () throws in _ = try canonical(dag, limits: nodes) }),
            ("hash", "$", { () throws in _ = try hash(dag, limits: nodes) }),
            ("hashAll", "$[0]", { () throws in _ = try hashAll([dag], limits: nodes) }),
        ] as [(String, String, () throws -> Void)] {
            let error = #expect(throws: HausError.self, "\(name)") { try run() }
            #expect(error?.code == .tooManyNodes, "\(name)")
            #expect(error?.path == place, "\(name)")
        }
        #expect(try canonical(Self.shared(3), limits: Limits(maxNodes: 15)) == "[[[[],[]],[[],[]]],[[[],[]],[[],[]]]]")
        #expect(throws: HausError.self) { try canonical(Self.shared(3), limits: Limits(maxNodes: 14)) }
        let item = #expect(throws: HausError.self) { try hashAll([[], Self.shared(3)], limits: Limits(maxNodes: 14)) }
        #expect(item?.path == "$[1]")
        // A record payload counts its record: Tag { a: 1 } is 3 values.
        #expect(try canonical(.tag("T", ["a": 1]), limits: Limits(maxNodes: 3)) == "T{a:1}")
        #expect(throws: HausError.self) { try canonical(.tag("T", ["a": 1]), limits: Limits(maxNodes: 2)) }
    }

    /// Indent and width are taken literally (spec §11): 0 is 0, and options
    /// with a negative one can't be made (no trap, no error code).
    @Test func formatOptionsTakenLiterally() throws {
        #expect(
            try format("{ a: { b: [1] } }", FormatOptions(indent: 0)) == "{\na: {\nb: [\n1,\n],\n},\n}\n")
        #expect(try format("Point(1, 2)", FormatOptions(width: 0)) == "Point(\n  1,\n  2,\n)\n")
        #expect(try format("Point(1, 2)", FormatOptions(indent: 0, width: 0)) == "Point(\n1,\n2,\n)\n")
        #expect(
            try format("{ a: Point(1, 2) }", FormatOptions(width: 0)) == "{\n  a: Point(\n    1,\n    2,\n  ),\n}\n")
        for (indent, width) in [(2, -1), (-1, 80), (-2, 40), (Int.min, 80), (2, Int.min)] {
            let error = #expect(throws: FormatOptionsError.self) { try FormatOptions(indent: indent, width: width) }
            #expect(error?.message.contains("must be 0 or more") == true)
        }
        #expect(FormatOptions().indent == 2 && FormatOptions().width == 80)
    }

    @Test func formatAndComments() throws {
        let text = "{ a: 1, // one\n  b: [2,3] }"
        #expect(try format(text) == "{\n  a: 1, // one\n  b: [\n    2,\n    3,\n  ],\n}\n")
        #expect(try format(text, FormatOptions(layout: .compact)) == "{ a: 1, b: [2, 3] }\n")
        #expect(try hasComments(text))
        #expect(try !hasComments("{ a: 1 }"))
    }

    #if canImport(CryptoKit)
        @Test func hashes() throws {
            let v = try parse(#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5, p: Point(1, 2) }"#)
            #expect(try canonical(v) == #"Order{id:255,p:Point(1,2),total:19.90,"x-y":1e5}"#)
            #expect(try hashAll([v]) == hash(v))
            #expect(try hashAll([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            #expect(try hashAll([1, "a"]) != hashAll(["a", 1]))
        }
    #endif

    @Test func streamErrorsComeAfterTheValuesBeforeThem() throws {
        var reader = StreamReader()
        reader.push("1, 2, [3,,], 4")
        #expect(try reader.next() == 1)
        #expect(try reader.next() == 2)
        let error = #expect(throws: HausError.self) { try reader.next() }
        #expect(error?.code == .expectedValue)
        #expect(error?.position == SourcePosition(line: 1, column: 10))
        // Sticky.
        #expect((#expect(throws: HausError.self) { try reader.next() })?.code == .expectedValue)
    }

    @Test func streamOverAsyncChunks() async throws {
        let text = Array("Log { a: 1 },\n\"é\",\n[1, 2],".utf8)
        let chunks = AsyncStream<[UInt8]> { continuation in
            for byte in text { continuation.yield([byte]) }
            continuation.finish()
        }
        var values: [HausValue] = []
        for try await v in HausValues(chunks, strict: true) { values.append(v) }
        #expect(values == [.tag("Log", ["a": 1]), "é", [1, 2]])
        let truncated = AsyncStream<[UInt8]> { continuation in
            continuation.yield(Array("1, 2".utf8))
            continuation.finish()
        }
        await #expect(throws: HausError.self) { for try await _ in HausValues(truncated, strict: true) {} }
    }
}
