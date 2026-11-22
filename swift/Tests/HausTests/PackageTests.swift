import Foundation
import Testing

@testable import Haus

/// The package suite (test-suite/packages, spec §13.3): each case is a file
/// tree, written into a temporary directory, a schema file loaded from it
/// with packages given explicitly, and the result. See test-suite/README.md,
/// "Package suite". This binding is no implementation of the npm ecosystem
/// (it never reads `node_modules`): it runs the `core` cases and skips the
/// `npm` ones, with a count.
struct PackageSuiteTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let fields: HausRecord
        var testDescription: String { string("name") }

        func string(_ key: String) -> String {
            if case .string(let s)? = fields[key] { return s }
            return ""
        }

        /// The tags of its file entries.
        var entries: [String] {
            guard case .array(let files)? = fields["files"] else { return [] }
            return files.compactMap { if case .variant(let tag, _) = $0 { tag.name } else { nil } }
        }

        /// The packages and folders its mode gives, relative to the tree.
        var given: (packages: [String], folders: [String]) {
            guard case .variant(_, let args)? = fields["mode"] else { return ([], []) }
            return (args.first?["packages"].map(strings) ?? [], args.first?["folders"].map(strings) ?? [])
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

    /// Why this binding skips a case, or nil if it runs it.
    static func skipped(_ c: Case) -> String? {
        if c.string("ecosystem") != "core" { return "ecosystem \(c.string("ecosystem")) (no node_modules here)" }
        #if os(Windows)
            if c.string("os") == "unix" { return "Unix only" }
        #endif
        if c.entries.contains("Mode") && getuid() == 0 { return "permissions don't stop root" }
        return nil
    }

    static let core = cases.filter { skipped($0) == nil }

    @Test func everyCase() {
        #expect(Self.cases.count == 133)
        #expect(Self.cases.filter { $0.string("ecosystem") == "core" }.count == 87)
        #expect(Self.cases.filter { $0.string("ecosystem") == "npm" }.count == 46)
        let reasons = Dictionary(grouping: Self.cases.compactMap(Self.skipped), by: { $0 }).mapValues(\.count)
        print("package suite: \(Self.core.count) cases run, skipped: \(reasons)")
    }

    @Test(arguments: core)
    func run(_ c: Case) throws {
        try Self.check(c, tree: false)
    }

    /// The core cases with packages given, as a file tree given in code (a
    /// `Bundle` over the temporary directory, spec §13.3), behave as the
    /// same directories on disk. A tree follows no links: cases with links
    /// are left out.
    static let treeCases = core.filter { c in
        let (packages, folders) = c.given
        return !(packages.isEmpty && folders.isEmpty) && !c.entries.contains("Link")
    }

    @Test func treeCaseCount() {
        print("package suite as a tree: \(Self.treeCases.count) cases run")
        #expect(Self.treeCases.count > 30)
    }

    @Test(arguments: treeCases)
    func runAsTree(_ c: Case) throws {
        try Self.check(c, tree: true)
    }

    static func check(_ c: Case, tree: Bool) throws {
        let root = try TemporaryTree()
        defer { root.remove() }
        try root.write(c.fields["files"])
        let path = root.path
        let load = { @Sendable () throws(HausError) in try Self.load(path, c, tree: tree) }
        guard let outcome = Self.withTimeout(seconds: 10, load) else {
            Issue.record("timed out: the resolver blocked (a FIFO opened blocking?)")
            return
        }
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
            // Messages show paths relative to the root, never absolute ones (spec §13.3).
            for absolute in [root.path, realPath(root.path) ?? root.path] {
                #expect(!message.contains(absolute), "shows an absolute path: \(message)")
            }
        }
    }

    /// Runs `body` on a thread of its own, and gives up after `seconds`: a
    /// resolver that opens a FIFO blocking would hang (the thread is left).
    static func withTimeout(seconds: Int, _ body: @escaping @Sendable () throws(HausError) -> [String])
        -> Result<[String], HausError>?
    {
        final class Box: @unchecked Sendable {
            var result: Result<[String], HausError>?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread {
            box.result = Result(catching: body)
            done.signal()
        }.start()
        return done.wait(timeout: .now() + .seconds(seconds)) == .timedOut ? nil : box.result
    }

    /// Loads the case's root: the packages reached, as `name@version`, sorted.
    static func load(_ root: String, _ c: Case, tree: Bool) throws(HausError) -> [String] {
        let (given, folders) = c.given
        let locator =
            tree
            ? try PackageLocator.explicit(in: Bundle(path: root)!, packages: given, folders: folders)
            : try PackageLocator.explicit(
                packages: given.map { root + "/" + $0 }, folders: folders.map { root + "/" + $0 })
        let rootDir = c.fields["rootDir"] == nil ? nil : root + "/" + c.string("rootDir")
        let schema = try HausSchema(
            contentsOf: root + "/" + c.string("root"), options: .init(packages: locator, root: rootDir))
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

    /// Removes the tree, after giving the owner back the permissions `Mode`
    /// entries took (`chmod -R u+rwx`).
    func remove() {
        if let all = FileManager.default.enumerator(atPath: path) {
            chmod(path, 0o755)
            for case let name as String in all where fileType(path + "/" + name) == .typeDirectory {
                chmod(path + "/" + name, 0o755)
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ relative: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Writes a case's files (test-suite/README.md, "Package suite"): links
    /// once their targets exist, permissions last.
    func write(_ files: HausValue?) throws {
        guard case .array(let entries)? = files else { return }
        let tag = { (v: HausValue) in if case .variant(let t, _) = v { t.name } else { "" } }
        let later = ["Link", "Mode"]
        for entry in entries.filter({ !later.contains(tag($0)) }) { try create(entry) }
        for step in later { for entry in entries.filter({ tag($0) == step }) { try create(entry) } }
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
        case "Fifo":
            let fifo = URL(fileURLWithPath: path + "/" + at(0))
            try FileManager.default.createDirectory(
                at: fifo.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(mkfifo(fifo.path, 0o644) == 0, "mkfifo \(at(0))")
        case "Large":
            guard case .number(let n) = args[1], let bytes = Int(n.description) else { return }
            try file(at(0), String(repeating: " ", count: bytes))
        case "Mode":
            #expect(chmod(path + "/" + at(0), mode_t(at(1), radix: 8)!) == 0, "chmod \(at(1)) \(at(0))")
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

    /// Messages show paths relative to the build's root, `../vendor/…` for a
    /// package outside it, never absolute ones (spec §13.3).
    @Test func relativeMessages() throws {
        let root = try TemporaryTree()
        defer { root.remove() }
        try root.file("app/a.schema.haus", "import @acme/x@1 (X)\ntype Root = { x: X }")
        try root.file("vendor/x/package.haus", #"{ name: "@acme/x", version: "1.0.0" }"#)
        try root.file("vendor/x/schema.haus", "type X = { a: Strin }")
        try root.file("vendor/x/package.json", String(repeating: " ", count: SchemaFileLimits.maxFile + 1))
        let packages = try PackageLocator.explicit(packages: [root.path + "/vendor/x"])
        let error = #expect(throws: HausError.self) {
            try HausSchema(contentsOf: root.path + "/app/a.schema.haus", options: .init(packages: packages))
        }
        #expect(error?.code == .unknownType)
        try root.file("vendor/x/schema.haus", "import ./y (Y)\ntype X = Int")
        let again = #expect(throws: HausError.self) {
            try HausSchema(contentsOf: root.path + "/app/a.schema.haus", options: .init(packages: packages))
        }
        #expect(again?.code == .packagePath)
        try root.file("vendor/x/schema.haus", "type X = Int")
        try root.file("vendor/x/package.json", #"{ "version": "1.0.1" }"#)
        let version = #expect(throws: HausError.self) {
            try HausSchema(contentsOf: root.path + "/app/a.schema.haus", options: .init(packages: packages))
        }
        #expect(version?.code == .packageVersion)
        #expect(version?.message.contains("(../vendor/x)") == true, "\(version!)")
        try root.file("app/b.schema.haus", "import ./missing (M)\ntype B = M")
        let missing = #expect(throws: HausError.self) { try HausSchema(contentsOf: root.path + "/app/b.schema.haus") }
        #expect(missing?.message.contains("file not found: missing.schema.haus") == true, "\(missing!)")
        for e in [error, again, version, missing] {
            #expect(e?.description.contains(realPath(root.path)!) == false, "\(e!)")
            #expect(e?.description.contains(root.path) == false, "\(e!)")
        }
    }

    /// A relative import follows no link, even one to a file inside the root
    /// (spec §13.3, "Resolution"): the message says that the name is a link,
    /// not where it points.
    @Test func relativeImportsFollowNoLink() throws {
        let root = try TemporaryTree()
        defer { root.remove() }
        try root.file("app/a.schema.haus", "import ./lib/x (X)\ntype Root = { x: X }")
        try root.file("app/@acme/x@1.schema.haus", "type X = Int")
        try FileManager.default.createDirectory(atPath: root.path + "/app/lib", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root.path + "/app/lib/x.schema.haus", withDestinationPath: "../@acme/x@1.schema.haus")
        let error = #expect(throws: HausError.self) { try HausSchema(contentsOf: root.path + "/app/a.schema.haus") }
        #expect(error?.code == .importNotFound)
        #expect(error?.message.contains("lib/x.schema.haus is a symbolic link") == true, "\(error!)")
        #expect(error?.message.contains("@acme") == false, "\(error!)")
    }

    /// A file's id never has the form of a package's id (spec §13.3): an
    /// entry file named `@acme@1` gets `./`.
    @Test func fileIdsAreNotPackageIds() throws {
        let root = try TemporaryTree()
        defer { root.remove() }
        try root.file("app/@acme@1.schema.haus", "type Root = Int")
        let schema = try HausSchema(contentsOf: root.path + "/app/@acme@1.schema.haus")
        #expect(schema.definitions.map(\.id) == ["./@acme@1#Root"])
    }

    /// A relative root option is from the entry file's real directory, not
    /// from the current directory or the path the entry file is given by
    /// (spec §13.3, "The root").
    @Test func relativeRootOption() throws {
        let root = try TemporaryTree()
        defer { root.remove() }
        try root.file("proj/app/a.schema.haus", "import ../shared/s (S)\ntype Root = { s: S }")
        try root.file("proj/shared/s.schema.haus", "type S = Int")
        try FileManager.default.createSymbolicLink(atPath: root.path + "/current", withDestinationPath: "proj/app")
        let entry = root.path + "/current/a.schema.haus"
        for given in ["..", "../../proj"] {
            let schema = try HausSchema(contentsOf: entry, options: .init(root: given))
            #expect(schema.imported.map(\.id) == ["../shared/s#S"], "\(given)")
        }
        let narrow = #expect(throws: HausError.self) { try HausSchema(contentsOf: entry, options: .init(root: ".")) }
        #expect(narrow?.code == .importOutsideRoot)
        #expect(narrow?.position?.line == 1)
        let outside = #expect(throws: HausError.self) {
            try HausSchema(contentsOf: entry, options: .init(root: "../shared"))
        }
        #expect(outside?.code == .importOutsideRoot)
        #expect(outside?.position == nil)
    }

    /// A package tree follows no links, and its paths stay inside it (spec §13.3).
    @Test func packageTrees() throws {
        let root = try TemporaryTree()
        defer { root.remove() }
        try root.file("tree/money/package.haus", #"{ name: "@acme/money", version: "1.0.0" }"#)
        try root.file("tree/money/schema.haus", "type Money = { cents: Int }")
        try root.file("outside/geo/package.haus", #"{ name: "@acme/geo", version: "1.0.0" }"#)
        try root.file("outside/geo/schema.haus", "type LatLng = { lat: Float }")
        try FileManager.default.createSymbolicLink(
            atPath: root.path + "/tree/geo", withDestinationPath: "../outside/geo")
        try root.file("app.schema.haus", "import @acme/money@1 (Money)\ntype Root = { m: Money }")
        let tree = URL(fileURLWithPath: root.path + "/tree")
        let packages = try PackageLocator.explicit(in: tree, packages: ["money"])
        let schema = try HausSchema(contentsOf: root.path + "/app.schema.haus", options: .init(packages: packages))
        #expect(schema.packages.map(\.name) == ["@acme/money"])
        let folder = try PackageLocator.explicit(in: tree, folders: ["."])
        let found = try HausSchema(contentsOf: root.path + "/app.schema.haus", options: .init(packages: folder))
        #expect(found.packages.map(\.name) == ["@acme/money"])
        for given in ["geo", "../outside/geo", "/geo"] {
            let error = #expect(throws: HausError.self) { try PackageLocator.explicit(in: tree, packages: [given]) }
            #expect(error?.code == .packagePath, "\(given)")
        }
        let bundle = try #require(Bundle(path: root.path + "/tree"))
        #expect(throws: Never.self) { try PackageLocator.explicit(in: bundle, packages: ["money"]) }
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
