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
        return try FormatOptions(
            indent: r["indent"].flatMap { if case .number(let n) = $0 { n.integer() } else { nil } } ?? 2,
            width: r["width"].flatMap { if case .number(let n) = $0 { n.integer() } else { nil } } ?? 80,
            stream: streamOption(r["stream"]))
    }

    /// `stream: True` or `False`; not given, the default (false).
    static func streamOption(_ v: HausValue?) -> Bool {
        switch v {
        case nil: false
        case .variant("True", [])?: true
        case .variant("False", [])?: false
        default: fatalError("not a stream option: \(v!)")
        }
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

    /// A case of options.cases.haus: the pretty layout's `indent` and `width`, and `stream`.
    struct OptionsCase: CustomTestStringConvertible, Sendable {
        let input: String
        /// The options given; nil: not given, the default applies.
        let indent: Int?
        let width: Int?
        let stream: Bool
        /// The pretty result, or nil for `Rejected`.
        let result: String?
        var testDescription: String {
            "\(input.debugDescription) indent \(indent.map(String.init) ?? "-") width \(width.map(String.init) ?? "-")"
                + (stream ? " stream" : "")
        }
    }

    static let optionsCases: [OptionsCase] = {
        let values = try! parseAll(readText(suite.appendingPathComponent("format/options.cases.haus")))
        return values.map { v in
            guard case .string(let input)? = v["input"], case .variant(let tag, let args)? = v["result"] else {
                fatalError("not a case: \(v)")
            }
            func int(_ key: String) -> Int? {
                guard let n = v[key] else { return nil }
                guard case .number(let n) = n, let i = n.integer() else { fatalError("not an option: \(v)") }
                return i
            }
            let result: String? =
                switch (tag, args.first) {
                case ("Ok", .string(let text)?): text
                case ("Rejected", nil): nil
                default: fatalError("not a result: \(v)")
                }
            return OptionsCase(
                input: input, indent: int("indent"), width: int("width"), stream: streamOption(v["stream"]),
                result: result)
        }
    }()

    @Test func hasOptionsCases() {
        #expect(!Self.optionsCases.isEmpty)
    }

    /// The options of the pretty layout themselves (format/README.md): 0 is 0,
    /// and a negative number is rejected (`FormatOptions` throws). The inputs
    /// have no comments, so `stringifyAll` writes the same text.
    @Test(arguments: optionsCases)
    func options(_ c: OptionsCase) async throws {
        let (input, indent, width) = (c.input, c.indent ?? 2, c.width ?? 80)
        guard c.result == nil else {
            let options = try FormatOptions(indent: indent, width: width, stream: c.stream)
            #expect(try Haus.format(input, options) == c.result)
            #expect(try stringifyAll(parseAll(input), options) == c.result)
            return
        }
        #expect(throws: FormatOptionsError.self) { try FormatOptions(indent: indent, width: width) }
        // Rejected: in a process of its own, so that a formatter that traps on
        // the options fails this case and not the whole run. Exit code 0:
        // rejected (thrown); 2: formatted anyway; a signal: it trapped.
        await #expect(processExitsWith: .success) {
            [input = input as String, indent = indent as Int, width = width as Int] in
            do {
                _ = try Haus.format(input, FormatOptions(indent: indent, width: width))
                exit(2)
            } catch {
                exit(0)
            }
        }
    }
}

/// The stream suite (test-suite/README.md, "Stream suite"): each case whole,
/// one character at a time, and split in two at every byte; the cases with
/// `whole` parsed whole; single documents (document.cases.haus). Typed
/// streams are `TypedStreamSuiteTests`, in SchemaTests.swift.
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
        /// `whole`: the values of parsing the whole text, which doesn't apply the value limit.
        let whole: [HausValue]?
        /// `line` and `column`: where the error is, for every split, when the case gives them.
        let place: [Int]?
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
            let whole: [HausValue]? =
                switch v["whole"] {
                case nil: nil
                case .variant("Ok", let args)? where args.count == 1:
                    if case .array(let values) = args[0] { values } else { fatalError("not a whole: \(v)") }
                default: fatalError("not a whole: \(v)")
                }
            let place: [Int]? =
                switch (v["line"], v["column"]) {
                case (nil, nil): nil
                case (.number(let line)?, .number(let column)?): [line.integer()!, column.integer()!]
                default: fatalError("not a place: \(v)")
                }
            return Case(
                text: text, maxValueLength: max.integer()!, strict: v["strict"] == .tag("True"), result: result,
                whole: whole, place: place)
        }
    }()

    /// Reads the pieces as one stream: the values, or the error's code and place.
    static func read(_ c: Case, _ pieces: [[UInt8]]) -> (Outcome, place: [Int]?) {
        var reader = StreamReader(limits: Limits(maxValueLength: c.maxValueLength), strict: c.strict)
        var values: [HausValue] = []
        do {
            for piece in pieces {
                reader.push(piece)
                while let v = try reader.next() { values.append(v) }
            }
            reader.finish()
            while let v = try reader.next() { values.append(v) }
            return (.values(values), nil)
        } catch {
            return (.error(error.code), error.position.map { [$0.line, $0.column] })
        }
    }

    @Test func count() {
        #expect(Self.cases.count == 32)
        #expect(Self.cases.contains { $0.place != nil })
    }

    @Test(arguments: cases)
    func stream(_ c: Case) {
        let bytes = Array(c.text.utf8)
        var splits: [[[UInt8]]] = [[bytes], c.text.unicodeScalars.map { Array(String($0).utf8) }]
        splits += (0...bytes.count).map { [Array(bytes[..<$0]), Array(bytes[$0...])] }
        for pieces in splits {
            let (got, place) = Self.read(c, pieces)
            #expect(got == c.result, "\(pieces)")
            if let want = c.place {
                #expect(place == want, "\(pieces)")
            }
        }
    }

    @Test func hasWholeCases() {
        #expect(Self.cases.contains { $0.whole != nil })
    }

    /// `whole`: parsing the whole text (as `parseAll`, default limits) doesn't
    /// apply the value limit (spec §7).
    @Test(arguments: cases.filter { $0.whole != nil })
    func parsedWhole(_ c: Case) throws {
        #expect(try parseAll(c.text) == c.whole)
    }

    /// A case of document.cases.haus: a text, and what `parse` gives for it.
    struct Document: CustomTestStringConvertible, Sendable {
        let text: String
        let result: Outcome
        var testDescription: String { text.debugDescription }
    }

    static let documents: [Document] = {
        let values = try! parseAll(readText(suite.appendingPathComponent("stream/document.cases.haus")))
        return values.map { v in
            guard case .string(let text)? = v["text"], case .variant(let tag, let args)? = v["result"] else {
                fatalError("not a case: \(v)")
            }
            let result: Outcome =
                switch (tag, args.first) {
                case ("Ok", let value?): .values([value])
                case ("Err", .string(let code)?): .error(HausError.Code(rawValue: code)!)
                default: fatalError("not a result: \(v)")
                }
            return Document(text: text, result: result)
        }
    }()

    @Test func hasDocuments() {
        #expect(!Self.documents.isEmpty)
    }

    /// Single documents (spec §6, as `parse`): one value, with or without a
    /// comma after it; none, or two or more, is `not-one-value`.
    @Test(arguments: documents)
    func document(_ d: Document) {
        let got: Outcome
        do {
            got = .values([try parse(d.text)])
        } catch {
            got = .error(error.code)
        }
        #expect(got == d.result)
    }
}
