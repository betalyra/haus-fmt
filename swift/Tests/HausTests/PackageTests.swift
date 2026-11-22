import Foundation
import Testing

@testable import Haus

/// The package suite (test-suite/packages, spec §13.3): each case is a file
/// tree, written into a temporary directory, a schema file loaded from it
/// with packages found in `node_modules` (Npm) or given explicitly
/// (Explicit), and the result. See test-suite/README.md, "Package suite".
struct PackageSuiteTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let fields: HausRecord
        var testDescription: String { string("name") }

        func string(_ key: String) -> String {
            if case .string(let s)? = fields[key] { return s }
            return ""
        }
    }

    static let cases: [Case] = {
        let values = (try? parseAll(bytes: read(suite.appendingPathComponent("packages/cases.haus")))) ?? []
        return values.map { v in
            guard case .variant("Case", let args) = v, case .record(let r) = args.first else {
                fatalError("every entry is Case { … }: \(v)")
            }
            return Case(fields: r)
        }
    }()

    @Test func everyCase() {
        #expect(Self.cases.count == 99)
    }

    @Test(arguments: cases)
    func run(_ c: Case) throws {
        let root = try TemporaryTree()
        defer { root.remove() }
        try root.write(c.fields["files"])
        let outcome = Result { () throws(HausError) in try Self.load(root.path, c) }
        guard case .variant(let tag, let args) = c.fields["expect"], case .record(let want) = args.first else {
            Issue.record("a case without expect")
            return
        }
        switch (tag, outcome) {
        case ("Ok", .success(let reached)):
            #expect(reached == strings(want["packages"]))
        case ("Ok", .failure(let error)):
            Issue.record("failed: \(error)")
        case (_, .success(let reached)):
            Issue.record("loaded (reaching \(reached)), expected \(String(describing: want["code"]))")
        case (_, .failure(let error)):
            let message = error.description.replacingOccurrences(of: "\\", with: "/")
            #expect(.string(error.code.rawValue) == want["code"], "\(message)")
            for m in strings(want["mentions"]) { #expect(message.contains(m), "doesn't mention \(m): \(message)") }
            for h in strings(want["hides"]) { #expect(!message.contains(h), "shows \(h): \(message)") }
        }
    }

    /// Loads the case's root in its mode: the packages reached, as `name@version`, sorted.
    static func load(_ root: String, _ c: Case) throws(HausError) -> [String] {
        guard case .variant(let mode, let args) = c.fields["mode"] else { fatalError("a case without mode") }
        let given = args.first?["packages"].map(strings) ?? []
        let folders = args.first?["folders"].map(strings) ?? []
        let explicit = try PackageLocator.explicit(
            packages: given.map { root + "/" + $0 }, folders: folders.map { root + "/" + $0 })
        let locator = mode == "Npm" ? explicit.or(.nodeModules) : explicit
        let schema = try HausSchema(contentsOf: root + "/" + c.string("root"), options: .init(packages: locator))
        return schema.packages.map { "\($0.name)@\($0.version)" }.sorted()
    }
}

/// The strings of an array value.
func strings(_ v: HausValue?) -> [String] {
    guard case .array(let items)? = v else { return [] }
    return items.compactMap { if case .string(let s) = $0 { s } else { nil } }
}

/// A directory of its own under the temporary directory, removed by `remove`.
struct TemporaryTree {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("haus-packages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.path
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }

    func file(_ relative: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Writes a case's files (test-suite/README.md, "Package suite"): links
    /// last, once their targets exist.
    func write(_ files: HausValue?) throws {
        guard case .array(let entries)? = files else { return }
        let isLink = { (v: HausValue) in if case .variant("Link", _) = v { true } else { false } }
        for entry in entries.filter({ !isLink($0) }) + entries.filter(isLink) { try create(entry) }
    }

    func create(_ entry: HausValue) throws {
        guard case .variant(let tag, let args) = entry else { return }
        let at = { (i: Int) in if case .string(let s) = args[i] { s } else { "" } }
        switch tag {
        case "File":
            try file(at(0), at(1))
        case "Package":
            try file(at(0) + "/package.haus", "{ name: \(jsonString(at(1))), version: \(jsonString(at(2))) }")
            try file(at(0) + "/schema.haus", at(3))
        case "Npm":
            guard case .record(let r) = args[1] else { return }
            let members = r.fields.compactMap { key, value -> String? in
                switch value {
                case .string(let s): "\(jsonString(key)):\(jsonString(s))"
                case .array:
                    "\(jsonString(key)):{" + strings(value).map { "\(jsonString($0)):\"*\"" }.joined(separator: ",")
                        + "}"
                default: nil
                }
            }
            try file(at(0) + "/package.json", "{" + members.joined(separator: ",") + "}")
        case "Link":
            let link = URL(fileURLWithPath: path + "/" + at(0))
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: at(1))
        default:
            Issue.record("unknown file entry \(tag)")
        }
    }
}

/// Loading the examples' schemas from their files.
struct SchemaFileTests {
    static let examples = repository.appendingPathComponent("examples").path

    @Test func orderWithExplicitPackages() throws {
        let packages = try PackageLocator.explicit(folders: [repository.appendingPathComponent("extensions").path])
        let schema = try HausSchema(
            contentsOf: Self.examples + "/order.schema.haus", options: .init(packages: packages))
        #expect(schema.packages.map(\.name) == ["@haus-fmt/geo", "@haus-fmt/money"])
        #expect(schema.imported.map(\.name) == ["LatLng", "Money"])
        #expect(schema.imported.first { $0.name == "Money" }?.id == "@haus-fmt/money@1#Money")
        #expect(schema.definitions.first { $0.name == "Root" }?.id == "order#Root")
        let order = try schema.type("Root")
        let value = try parse(
            #"""
            { id: 7, customer: UserId("u-1"), placed: Date("2026-11-13"), total: Money(19.90, EUR),
              deliverTo: LatLng(52.52, 13.405), status: Shipped { tracking: "DE-4711" } }
            """#)
        #expect(try order.decode(value) == value)
        let money = HausValue.tag("Money", .number(try HausNumber("1.5")), .tag("EUR"))
        #expect(try schema.type("Money").decode(money) == money)
    }

    @Test func orderWithoutPackages() {
        let error = #expect(throws: HausError.self) { try HausSchema(contentsOf: Self.examples + "/order.schema.haus") }
        #expect(error?.code == .importUnavailable)
        #expect(error?.position?.line == 4)
    }

    @Test func thread() throws {
        let schema = try HausSchema(contentsOf: Self.examples + "/thread.schema.haus")
        #expect(!schema.definitions.isEmpty)
        #expect(schema.packages.isEmpty)
    }

    @Test func missingFile() {
        let error = #expect(throws: HausError.self) { try HausSchema(contentsOf: Self.examples + "/nope.schema.haus") }
        #expect(error?.code == .importNotFound)
    }

    /// Errors inside an imported file are reported at the import, with their place in that file.
    @Test func errorsInImportedFiles() throws {
        let root = try TemporaryTree()
        defer { root.remove() }
        try root.file("app.schema.haus", "// app\nimport ./common (Address)\ntype Root = { home: Address }")
        try root.file("common.schema.haus", "type Address = { city: Strin }")
        let error = #expect(throws: HausError.self) { try HausSchema(contentsOf: root.path + "/app.schema.haus") }
        #expect(error?.code == .unknownType)
        #expect(error?.position == SourcePosition(line: 2, column: 1))
        #expect(error?.message.hasPrefix("./common (1:24): ") == true)
        try root.file("common.schema.haus", "type Address = { city: String }")
        let schema = try HausSchema(contentsOf: root.path + "/app.schema.haus")
        #expect(schema.imported.map(\.id) == ["common#Address"])
        #expect(try schema.type("Root").decode(["home": ["city": "Graz"]]) == ["home": ["city": "Graz"]])
        let text = #expect(throws: HausError.self) {
            try HausSchema(parsing: "import ./common (Address)\ntype Root = { home: Address }")
        }
        #expect(text?.code == .importUnavailable)
    }

    @Test func manifests() throws {
        let m = try HausManifest(parsing: #"{ name: "@haus-fmt/money", version: "1.2.0", other: 1 }"#.utf8)
        #expect(m.id == "@haus-fmt/money@1")
        for bad in [
            #"{ name: "@Acme/x", version: "1.0.0" }"#, #"{ name: "@acme/x", version: "1.0" }"#,
            #"{ name: "@acme/x", version: "01.0.0" }"#, #"[1]"#, #"{ name: "@acme/node_modules", version: "1.0.0" }"#,
        ] {
            #expect(#expect(throws: HausError.self) { try HausManifest(parsing: bad.utf8) }?.code == .packageManifest)
        }
        #expect(quoteFromFile("a\u{202E}b") == #"a\u{202E}b"#)
        #expect(quoteFromFile(String(repeating: "x", count: 50)) == String(repeating: "x", count: 39) + "…")
        // Escaped first, then cut within 40 as shown, never inside an escape (spec §9).
        #expect(quoteFromFile(String(repeating: "x", count: 40)) == String(repeating: "x", count: 40))
        let escapes = String(repeating: "\u{1B}", count: 10)
        #expect(quoteFromFile(escapes) == String(repeating: #"\u{1B}"#, count: 6) + "…")
        #expect(quoteForMessage(escapes) == "\"" + String(repeating: #"\u{1B}"#, count: 6) + "…\"")
        #expect(quoteForMessage("x" + escapes) == "\"x" + String(repeating: #"\u{1B}"#, count: 6) + "…\"")
        #expect(
            quoteForMessage(String(repeating: "\"", count: 20)) == "\"" + String(repeating: #"\""#, count: 20) + "\"")
        #expect(
            quoteForMessage(String(repeating: "\"", count: 21)) == "\"" + String(repeating: #"\""#, count: 19) + "…\"")
        #expect(isSemanticVersion("1.0.0-rc.1+build.5") && !isSemanticVersion("1.0.0-01"))
    }
}
