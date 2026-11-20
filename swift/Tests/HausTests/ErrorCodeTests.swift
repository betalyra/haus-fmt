import Foundation
import Haus
import Testing

/// `Sources/Haus/ErrorCodes.swift` is generated from the catalogue,
/// spec/errors.haus (spec §17), by this test: run it with
/// `HAUS_WRITE_ERROR_CODES=1` to write the file again.
struct ErrorCodeTests {
    static let generated = repository.appendingPathComponent("swift/Sources/Haus/ErrorCodes.swift")

    /// One entry of the catalogue.
    struct Entry {
        let code: String
        let category: String
        let means: String
        let fix: String
    }

    static func entries() throws -> [Entry] {
        try parseAll(readText(repository.appendingPathComponent("spec/errors.haus"))).map { v in
            guard case .string(let code)? = v["code"], case .variant(let category, _)? = v["category"],
                case .string(let means)? = v["means"], case .string(let fix)? = v["fix"]
            else { fatalError("not an entry: \(v)") }
            return Entry(code: code, category: category, means: means, fix: fix)
        }
    }

    /// `invalid-utf8` as a Swift name: `invalidUtf8`.
    static func caseName(_ code: String) -> String {
        let parts = code.split(separator: "-")
        return parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func source(_ entries: [Entry]) -> String {
        let categories = entries.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var lines = [
            "// Generated from spec/errors.haus by Tests/HausTests/ErrorCodeTests.swift. Don't edit: edit",
            "// spec/errors.haus and run `HAUS_WRITE_ERROR_CODES=1 swift test --filter ErrorCodeTests`.",
            "// swift-format-ignore-file",
            "",
            "extension HausError {",
            "    /// An error code (spec §17): which mistake an error is. Stable, and the same in every binding.",
            "    /// Its raw value is its name, `payload-newline`; ``hint`` is the usual fix.",
            "    public enum Code: String, Sendable, CaseIterable {",
        ]
        for e in entries {
            lines += ["        /// `\(e.code)`: \(e.means)", "        case \(caseName(e.code)) = \(literal(e.code))"]
        }
        lines += [
            "    }", "", "    /// The part of the catalogue a code belongs to (spec §17).",
            "    public enum Category: Sendable, CaseIterable {",
        ]
        lines += categories.map { "        case \(lowerFirst($0))" }
        lines += [
            "    }", "}", "", "extension HausError.Code {", "    /// The part of the catalogue the code belongs to.",
            "    public var category: HausError.Category {", "        switch self {",
        ]
        for category in categories {
            let codes = entries.filter { $0.category == category }.map { "." + caseName($0.code) }
            lines.append("        case \(codes.joined(separator: ", ")): .\(lowerFirst(category))")
        }
        lines += [
            "        }", "    }", "", "    /// The catalogue's fix for the code: the hint reported with it.",
            "    public var hint: String {", "        switch self {",
        ]
        lines += entries.map { "        case .\(caseName($0.code)): \(literal($0.fix))" }
        lines += ["        }", "    }", "}"]
        return lines.joined(separator: "\n") + "\n"
    }

    @Test func generatedFromTheCatalogue() throws {
        let source = Self.source(try Self.entries())
        if ProcessInfo.processInfo.environment["HAUS_WRITE_ERROR_CODES"] == "1" {
            try source.write(to: Self.generated, atomically: true, encoding: .utf8)
        }
        #expect(source == readText(Self.generated), "run HAUS_WRITE_ERROR_CODES=1 swift test --filter ErrorCodeTests")
    }

    @Test func everyCodeIsInTheCatalogue() throws {
        #expect(try Self.entries().map(\.code) == HausError.Code.allCases.map(\.rawValue))
    }
}
