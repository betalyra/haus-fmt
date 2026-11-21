import Foundation
import Testing

@testable import Haus

/// A case of a `.cases.haus` file: its tag and fields.
struct SuiteCase: CustomTestStringConvertible, Sendable {
    let tag: String
    let fields: HausRecord

    var testDescription: String { (try? canonical(.variant(tag, [.record(fields)]))) ?? tag }

    func string(_ key: String) -> String? {
        if case .string(let s)? = fields[key] { return s }
        return nil
    }

    /// The cases of a file of the suite.
    static func cases(in url: URL) -> [SuiteCase] {
        let values = (try? parseAll(bytes: read(url))) ?? []
        return values.map { v in
            guard case .variant(let tag, let args) = v, args.count == 1, case .record(let r) = args[0] else {
                fatalError("not a case: \(v)")
            }
            return SuiteCase(tag: tag, fields: r)
        }
    }

    /// Checks an `Err` case: the error's code, and its path when the case gives one.
    func check(_ error: HausError?) {
        #expect(error?.code.rawValue == string("code"), "\(testDescription): \(String(describing: error))")
        if let path = string("path") {
            #expect(error?.path == path, "\(testDescription): \(String(describing: error))")
        }
    }
}

/// Whether two JSON texts are the same data: member order and whitespace
/// don't matter, numbers compare by their (normalized) text.
func sameJSON(_ a: String, _ b: String) -> Bool {
    guard let x = try? importJSON(a), let y = try? importJSON(b) else { return false }
    return x == y
}

/// The JSON suite (test-suite/json): the import and self-describing JSON.
struct JSONSuiteTests {
    static let dir = suite.appendingPathComponent("json")
    static let importCases = SuiteCase.cases(in: dir.appendingPathComponent("import.cases.haus"))
    static let selfDescribingCases = SuiteCase.cases(in: dir.appendingPathComponent("self-describing.cases.haus"))

    @Test(arguments: importCases)
    func importJSON(_ c: SuiteCase) throws {
        let text = try #require(c.string("json"))
        switch c.tag {
        case "Read":
            #expect(try Haus.importJSON(text) == c.fields["output"])
        case "Err":
            c.check(#expect(throws: HausError.self) { try Haus.importJSON(text) })
        default:
            Issue.record("unknown case \(c.tag)")
        }
    }

    @Test(arguments: selfDescribingCases)
    func selfDescribing(_ c: SuiteCase) throws {
        let text = try #require(c.string("json"))
        switch c.tag {
        case "Ok":
            let input = try #require(c.fields["input"])
            #expect(try fromHausJSON(text) == input)
            let written = try toHausJSON(input)
            #expect(sameJSON(written, text), "\(written)")
        case "Err":
            c.check(#expect(throws: HausError.self) { try fromHausJSON(text) })
        default:
            Issue.record("unknown case \(c.tag)")
        }
    }

    /// Every valid/NAME.jsonl read as self-describing JSON Lines, and each
    /// file's values written as it.
    @Test(arguments: files(SuiteTests.validFiles, ".haus"))
    func validJSONLines(_ name: String) throws {
        let file = SuiteTests.validFiles.appendingPathComponent(name)
        let values = try parseAll(bytes: read(file.appendingPathExtension("haus")))
        let text = readText(file.appendingPathExtension("jsonl"))
        #expect(try fromHausJSONLines(text) == values)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (value, line) in zip(values, lines) {
            // The suite's JSON reader: importJSON stops at 256 JSON levels.
            let written = try toHausJSON(value)
            #expect(try onStack(kibibytes: suiteStack) { sameData(JSON.parse(written), JSON.parse(String(line))) })
        }
        #expect(try fromHausJSONLines(toHausJSONLines(values)) == values)
    }
}

struct JSONTests {
    @Test func importKeepsNumbersExact() throws {
        let v = try importJSON(#"{"total": 19.90, "big": 123456789012345678901234567890, "e": 1E+05, "n": null}"#)
        #expect(
            v == [
                "total": .number(try HausNumber("19.90")),
                "big": .number(try HausNumber("123456789012345678901234567890")), "e": .number(try HausNumber("1e5")),
                "n": .tag("None"),
            ])
    }

    @Test func errorsHavePositions() {
        let error = #expect(throws: HausError.self) { try importJSON("[1,\n  2,]") }
        #expect(error?.code == .jsonSyntax)
        #expect(error?.position == SourcePosition(line: 2, column: 5))
    }

    @Test func formErrorsHavePaths() {
        let error = #expect(throws: HausError.self) {
            try fromHausJSON(#"{"_haus": 1, "_value": {"_rec": {"price": {"_num": "1E5"}}}}"#)
        }
        #expect(error?.code == .hausJsonNumber)
        #expect(error?.path == "$._value._rec.price._num")
    }

    @Test func writesEscapes() throws {
        #expect(
            try toHausJSON("a\u{7F}\u{85}\u{202E}\u{2028}\n\"")
                == #"{"_haus":1,"_value":"a\u007f\u0085\u202e\u2028\n\""}"#)
        #expect(
            try toHausJSON(.tag("Circle", ["r": 1]))
                == #"{"_haus":1,"_value":{"_tag":"Circle","_args":[{"_rec":{"r":{"_num":"1"}}}]}}"#)
    }

    @Test func writingChecksTheValue() {
        let error = #expect(throws: HausError.self) { try toHausJSON(["a": [.tag("lower")]]) }
        #expect(error?.code == .invalidTag)
        #expect(error?.path == "$.a[0]")
        // Arrays that share their storage: 2^21 nodes in 21 arrays.
        var shared: HausValue = [1]
        for _ in 0..<20 { shared = [shared, shared] }
        var walk = Walk(NoSpelling(), checks: .value(Limits()))
        walk.maxNodes = 1 << 20
        var nothing: [UInt8] = []
        let many = #expect(throws: HausError.self) { try walk.write(shared, to: &nothing) }
        #expect(many?.code == .tooManyNodes)
    }

    @Test func importLimits() {
        let deep = String(repeating: "[", count: 5) + String(repeating: "]", count: 5)
        #expect(throws: HausError.self) { try importJSON(deep, limits: Limits(maxDepth: 4)) }
        #expect((try? importJSON(deep, limits: Limits(maxDepth: 5))) != nil)
        let long = #expect(throws: HausError.self) {
            try importJSON(#"{"abc": 1}"#, limits: Limits(maxStringLength: 2))
        }
        #expect(long?.code == .keyTooLong)
    }

    @Test func jsonLines() throws {
        let text = "\u{FEFF}{\"_haus\":1,\"_value\":{\"_num\":\"1\"}}\r\n{\"_haus\":1,\"_value\":\"x\"}"
        #expect(try fromHausJSONLines(text) == [1, "x"])
        #expect(try importJSONLines("1\n[2]\n") == [1, [2]])
        let empty = #expect(throws: HausError.self) { try importJSONLines("1\n\n2\n") }
        #expect(empty?.code == .jsonSyntax)
        #expect(empty?.position == SourcePosition(line: 2, column: 1))
        let bom = #expect(throws: HausError.self) { try importJSONLines("1\n\u{FEFF}2\n") }
        #expect(bom?.code == .jsonSyntax)
        let path = #expect(throws: HausError.self) {
            try fromHausJSONLines("{\"_haus\":1,\"_value\":\"a\"}\n{\"_haus\":1,\"_value\":{\"_num\":\"01\"}}\n")
        }
        #expect(path?.path == "$[1]._value._num")
        let written = #expect(throws: HausError.self) { try toHausJSONLines([1, .tag("x")]) }
        #expect(written?.path == "$[1]")
    }

    @Test func jsonLinesInChunks() throws {
        let text = Array("1\n{\"a\": [2, 3]}\r\n\"\u{E9}\"\n4".utf8)
        for size in 1...5 {
            var reader = JSONLinesReader(.import)
            var values: [HausValue] = []
            for chunk in stride(from: 0, to: text.count, by: size).map({ text[$0..<min($0 + size, text.count)] }) {
                reader.push(chunk)
                while let v = try reader.next() { values.append(v) }
            }
            reader.finish()
            while let v = try reader.next() { values.append(v) }
            #expect(values == [1, ["a": [2, 3]], "\u{E9}", 4])
        }
    }

    @Test func jsonLinesBoundLines() {
        var reader = JSONLinesReader(.import, limits: Limits(maxValueLength: 3))
        reader.push("[1]\n[1, 2]\n")
        #expect((try? reader.next()) == [1])
        let error = #expect(throws: HausError.self) { try reader.next() }
        #expect(error?.code == .valueTooLong)
        #expect(error?.position == SourcePosition(line: 2, column: 1))
    }
}
