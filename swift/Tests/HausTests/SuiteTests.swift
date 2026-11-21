import Foundation
import Testing

@testable import Haus

/// The shared conformance suite (test-suite/README.md): valid files with
/// their values, canonical forms and hashes; invalid files with their error
/// codes; the format suite; the stream suite.
struct SuiteTests {
    static let validFiles = suite.appendingPathComponent("valid")
    static let invalidFiles = suite.appendingPathComponent("invalid")

    @Test(arguments: files(validFiles, ".haus"))
    func valid(_ name: String) throws {
        let file = Self.validFiles.appendingPathComponent(name)
        let values = try parseAll(bytes: read(file.appendingPathExtension("haus")))

        let expected = try onStack(kibibytes: suiteStack) {
            try readText(file.appendingPathExtension("jsonl")).split(separator: "\n").map {
                try fromSuiteJSON(JSON.parse(String($0))["_value"]!)
            }
        }
        #expect(values == expected)

        let forms = try values.map { try canonical($0) + "\n" }.joined()
        #expect(forms == readText(file.appendingPathExtension("canonical")))

        #if canImport(CryptoKit)
            let hash = readText(file.appendingPathExtension("hash")).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(try hashAll(values) == hash)
        #endif
    }

    @Test(arguments: files(invalidFiles, ".haus"))
    func invalid(_ name: String) throws {
        let file = Self.invalidFiles.appendingPathComponent(name)
        let code = readText(file.appendingPathExtension("error")).trimmingCharacters(in: .whitespacesAndNewlines)
        let error = #expect(throws: HausError.self) { try parseAll(bytes: read(file.appendingPathExtension("haus"))) }
        #expect(error?.code.rawValue == code)
        #expect((error?.position?.line ?? 0) >= 1 && (error?.position?.column ?? 0) >= 1)
    }

    @Test func suiteCodesAreInTheCatalogue() {
        for dir in [Self.invalidFiles, suite.appendingPathComponent("schema/invalid")] {
            for name in files(dir, ".error") {
                let code = readText(dir.appendingPathComponent(name + ".error")).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                #expect(HausError.Code(rawValue: code) != nil, "\(name): \(code)")
            }
        }
    }
}

/// The format suite (test-suite/format/README.md).
struct FormatSuiteTests {
    /// An input and where its expected outputs are, without the extension.
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let input: URL
        let expected: URL
        var testDescription: String { name }
    }

    static let cases: [Case] = {
        let format = suite.appendingPathComponent("format")
        let own = ["cases", "examples"].flatMap { dir in
            files(format.appendingPathComponent(dir), ".haus").map { name in
                Case(
                    name: "\(dir)/\(name)", input: format.appendingPathComponent("\(dir)/\(name).haus"),
                    expected: format.appendingPathComponent("\(dir)/\(name)"))
            }
        }
        let valid = files(SuiteTests.validFiles, ".haus").map { name in
            Case(
                name: "valid/\(name)", input: SuiteTests.validFiles.appendingPathComponent(name + ".haus"),
                expected: format.appendingPathComponent("valid/\(name)"))
        }
        return own + valid
    }()

    /// The options of a case: `NAME.options`, or the defaults.
    static func options(_ c: Case) throws -> FormatOptions {
        let file = c.expected.appendingPathExtension("options")
        guard exists(file), case .record(let r) = try parse(readText(file)) else { return FormatOptions() }
        return FormatOptions(
            indent: r["indent"].flatMap { if case .number(let n) = $0 { n.integer() } else { nil } } ?? 2,
            width: r["width"].flatMap { if case .number(let n) = $0 { n.integer() } else { nil } } ?? 80)
    }

    /// Whether two texts hold the same values.
    static func sameValues(_ a: String, _ b: String) throws -> Bool {
        try parseAll(a) == parseAll(b)
    }

    /// The text formatted as pretty with its comments removed.
    static func withoutComments(_ text: String, _ options: FormatOptions) throws -> String {
        var file = try parseFile(text, limits: Limits(), keep: true).syntax!
        func strip(_ item: Item) {
            item.leading = []
            item.trailing = []
            item.node.dangling = []
            item.node.items.forEach(strip)
        }
        file.items.forEach(strip)
        file.dangling = []
        return Printer(options).file(file)
    }

    func withoutBlankLines(_ text: String) -> String {
        text.split(separator: "\n").joined(separator: "\n")
    }

    @Test(arguments: cases)
    func format(_ c: Case) throws {
        let input = readText(c.input)
        let options = try Self.options(c)
        var outputs: [Layout: String] = [:]
        for layout in Layout.allCases {
            var o = options
            o.layout = layout
            let got = try Haus.format(input, o)
            outputs[layout] = got
            #expect(got == readText(c.expected.appendingPathExtension(layout.rawValue)), "\(layout)")
            #expect(try Haus.format(got, o) == got, "\(layout) is not idempotent")
            #expect(try Self.sameValues(got, input), "\(layout) changes the values")
        }
        var pretty = options
        pretty.layout = .pretty
        let fromMinimised = try Haus.format(outputs[.minimised]!, pretty)
        #expect(fromMinimised == (try Haus.format(outputs[.compact]!, pretty)))
        #expect(withoutBlankLines(fromMinimised) == withoutBlankLines(try Self.withoutComments(input, pretty)))
        // No pretty line ends in a space or tab outside a comment: trimming them keeps the values.
        let trimmed = outputs[.pretty]!.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }
        #expect(try Self.sameValues(trimmed.joined(separator: "\n"), input))
    }
}

/// The stream suite (test-suite/README.md, "Stream suite"): each case whole,
/// one character at a time, and split in two at every byte.
struct StreamSuiteTests {
    /// The values read, or the code of the error.
    enum Outcome: Equatable, Sendable {
        case values([HausValue])
        case error(HausError.Code)
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let text: String
        let maxValueLength: Int
        let strict: Bool
        let result: Outcome
        var testDescription: String { "\(text.debugDescription) max \(maxValueLength)\(strict ? " strict" : "")" }
    }

    static let cases: [Case] = {
        let values = try! parseAll(readText(suite.appendingPathComponent("stream/limits.cases.haus")))
        return values.map { v in
            guard case .string(let text)? = v["text"], case .number(let max)? = v["maxValueLength"],
                case .variant(let tag, let args)? = v["result"]
            else { fatalError("not a case: \(v)") }
            let result: Outcome =
                switch (tag, args.first) {
                case ("Ok", .array(let values)?): .values(values)
                case ("Err", .string(let code)?): .error(HausError.Code(rawValue: code)!)
                default: fatalError("not a result: \(v)")
                }
            return Case(text: text, maxValueLength: max.integer()!, strict: v["strict"] == .tag("True"), result: result)
        }
    }()

    /// Reads the pieces as one stream: the values, or the error's code.
    static func read(_ c: Case, _ pieces: [[UInt8]]) -> Outcome {
        var reader = StreamReader(limits: Limits(maxValueLength: c.maxValueLength), strict: c.strict)
        var values: [HausValue] = []
        do {
            for piece in pieces {
                reader.push(piece)
                while let v = try reader.next() { values.append(v) }
            }
            reader.finish()
            while let v = try reader.next() { values.append(v) }
            return .values(values)
        } catch {
            return .error(error.code)
        }
    }

    @Test func count() {
        #expect(Self.cases.count == 24)
    }

    @Test(arguments: cases)
    func stream(_ c: Case) {
        let bytes = Array(c.text.utf8)
        var splits: [[[UInt8]]] = [[bytes], c.text.unicodeScalars.map { Array(String($0).utf8) }]
        splits += (0...bytes.count).map { [Array(bytes[..<$0]), Array(bytes[$0...])] }
        for pieces in splits {
            #expect(Self.read(c, pieces) == c.result, "\(pieces)")
        }
    }
}
