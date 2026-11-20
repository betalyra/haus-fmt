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

    /// Runs `body` on a thread with a stack of the size given.
    func onStack<T: Sendable>(kibibytes: Int, _ body: @escaping @Sendable () throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, any Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result(catching: body)
            done.signal()
        }
        thread.stackSize = kibibytes << 10
        thread.start()
        done.wait()
        return try result!.get()
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
        let badTag = #expect(throws: HausError.self) { try Haus.stringify(["a": [.tag("lower")]]) }
        #expect(badTag?.code == .invalidTag)
        #expect(badTag?.path == "$.a[0]")
        #expect((#expect(throws: HausError.self) { try canonical(.tag("")) })?.code == .invalidTag)
        let long = HausValue.number(try HausNumber("0x" + String(repeating: "f", count: 829)))
        #expect(
            (#expect(throws: HausError.self) {
                try Haus.stringify(long, FormatOptions(limits: Limits(maxNumberLength: 10)))
            })?.code == .numberTooLong)
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
