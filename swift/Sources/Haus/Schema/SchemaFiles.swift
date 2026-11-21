// Reading the files imports name (spec §13.3), the same for every package
// manager: a ``PackageLocator`` says where a package is, and the rules here
// say whether it may be read. Resolution happens when a schema is loaded,
// never while data is parsed, and never over the network (§9.2).
//
// A package's package.haus, schema.haus and package.json are opened without
// following links (O_NOFOLLOW, and O_NONBLOCK so that a FIFO can't block the
// open); their type and size are checked on the opened file, and they are
// read from it, so the file checked is the file read.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The limits of spec §13.3.
public enum SchemaFileLimits {
    /// The largest schema file and `package.json`, in bytes (1 MiB).
    public static let maxFile = 1 << 20
    /// The most entries a folder of packages may have.
    public static let maxFolderEntries = 4096
    /// The most schema files one schema reads, the root included.
    public static let maxFiles = 256
}

// ── paths ───────────────────────────────────────────────────────

/// Paths with `/`, cleaned lexically as Go's `path/filepath` does.
enum FilePath {
    /// The path with `.` and `..` resolved lexically and repeated slashes removed.
    static func clean(_ path: String) -> String {
        let rooted = path.utf8.first == ASCII.slash
        var parts: [String] = []
        for part in Self.elements(path) where part != "." {
            if part != ".." {
                parts.append(part)
            } else if let last = parts.last, last != ".." {
                parts.removeLast()
            } else if !rooted {
                parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        return rooted ? "/" + joined : joined.isEmpty ? "." : joined
    }

    static func join(_ parts: String...) -> String { clean(parts.filter { !$0.isEmpty }.joined(separator: "/")) }

    /// The names between the slashes of a path.
    static func elements(_ path: String) -> [String] {
        path.utf8.split(separator: ASCII.slash).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The directory of a path: all but its last element.
    static func dir(_ path: String) -> String {
        guard let slash = path.utf8.lastIndex(of: ASCII.slash) else { return "." }
        return clean(String(path[...slash]))
    }

    /// The last element of a path.
    static func base(_ path: String) -> String {
        elements(path).last ?? (path.isEmpty ? "." : "/")
    }

    /// The path of `target` from `base`, both absolute and clean.
    static func relative(from base: String, to target: String) -> String {
        let (from, to) = (elements(base), elements(target))
        let common = zip(from, to).prefix { sameCodePoints($0, $1) }.count
        let parts = Array(repeating: "..", count: from.count - common) + to[common...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}

/// The absolute path with every link resolved; nil if there is nothing there.
func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The type of what is at `path`, without following a link; nil if nothing is.
func fileType(_ path: String) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
}

/// Whether something is at `path`, without following a link.
func exists(_ path: String) -> Bool { fileType(path) != nil }

/// The names in a directory, at most `limit` of them; nil if it can't be read.
func directoryEntries(_ path: String, limit: Int = .max) -> [String]? {
    guard let dir = opendir(path) else { return nil }
    defer { closedir(dir) }
    var names: [String] = []
    while names.count < limit, let entry = readdir(dir) {
        let name = withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                String(cString: $0)
            }
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names
}

/// Whether everyone may write to `dir`, such as `/tmp`: a `node_modules`
/// there is never used (spec §13.3).
func isWorldWritable(_ dir: String) -> Bool {
    let permissions = (try? FileManager.default.attributesOfItem(atPath: dir))?[.posixPermissions] as? NSNumber
    return (permissions?.intValue ?? 0) & 0o002 != 0
}

/// The text of the last system error.
func systemError() -> String { String(cString: strerror(errno)) }

// ── reading files ───────────────────────────────────────────────

/// Which file is read, and so how.
enum FileKind {
    /// A package's package.haus: never through a link, at most 64 KiB.
    case manifest
    /// A package's schema.haus: never through a link.
    case packageSchema
    /// A package's package.json: never through a link.
    case packageJSON
    /// A schema file outside packages, read at its real path.
    case schema
    /// The package.json of a project (not a package's).
    case projectJSON

    var followsLinks: Bool { self == .schema || self == .projectJSON }

    var limit: Int { self == .manifest ? HausManifest.maxSize : SchemaFileLimits.maxFile }
}

/// What opening a file gave.
enum Opened {
    case bytes([UInt8])
    case missing
    /// A symbolic link, a directory, a FIFO, …: not read.
    case notRegular
    case tooLarge(Int)
    case failed(String)

    /// The file as another use, with its own limit, sees it.
    func within(_ kind: FileKind) -> Opened {
        if case .bytes(let b) = self, b.count > kind.limit { return .tooLarge(b.count) }
        return self
    }
}

/// Opens the file at `path`, following a link or not, and reads it: a
/// regular file of at most `limit` bytes, checked on the opened file.
func readFile(_ path: String, follow: Bool, limit: Int) -> Opened {
    let fd = open(path, O_RDONLY | O_NONBLOCK | (follow ? 0 : O_NOFOLLOW))
    guard fd >= 0 else {
        let (code, why) = (errno, systemError())
        if let type = fileType(path), type != .typeRegular { return .notRegular }
        return code == ENOENT ? .missing : .failed(why)
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { return .failed(systemError()) }
    guard info.st_mode & S_IFMT == S_IFREG else { return .notRegular }
    guard Int(info.st_size) <= limit else { return .tooLarge(Int(info.st_size)) }
    // Up to one byte more than the limit, to see a file that grew since fstat.
    var out: [UInt8] = []
    out.reserveCapacity(Int(info.st_size) + 1)
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while out.count <= limit {
        let n = chunk.withUnsafeMutableBytes { readBytes(fd, $0.baseAddress!, $0.count) }
        guard n >= 0 else { return .failed(systemError()) }
        if n == 0 { break }
        out += chunk[..<n]
    }
    return out.count > limit ? .tooLarge(out.count) : .bytes(out)
}

/// read(2).
private func readBytes(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
    #elseif canImport(Glibc)
        Glibc.read(fd, buffer, count)
    #else
        Musl.read(fd, buffer, count)
    #endif
}

/// A package.json as far as resolution reads it: nil members for one that
/// isn't valid JSON, which declares nothing and gives no version.
struct PackageJSON {
    /// The names of its members, if it is an object.
    let members: Set<String>
    /// Its `version`, if it is a string.
    let version: String?
    /// The names each dependency field lists.
    let dependencies: [String: Set<String>]
    let isValid: Bool

    /// A package.json that can't be read (not a regular file): it declares nothing.
    static let unreadable = PackageJSON([])

    init(_ bytes: [UInt8]) {
        let valid = bytes.withUnsafeBufferPointer(firstInvalidUTF8) == nil
        let doc = valid ? try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) : nil
        let object = doc as? [String: Any] ?? [:]
        isValid = doc != nil
        members = Set(object.keys)
        version = object["version"] as? String
        dependencies = object.compactMapValues { ($0 as? [String: Any]).map { Set($0.keys) } }
    }
}

/// The files one schema reads, each once (spec §13.3), by real path: a file
/// needed in two roles (a package.json that is a link to a schema file) is
/// read once, and every use sees the same bytes. Each use keeps its own
/// checks: a package's files are never read through a link, and each kind of
/// file has its own size limit.
final class SchemaFiles {
    private var opened: [String: Opened] = [:]
    private var json: [String: PackageJSON] = [:]

    /// Reads the file at `path` as `kind` says, and returns the path it is cached by.
    func read(_ path: String, _ kind: FileKind) -> (key: String, opened: Opened) {
        if !kind.followsLinks {
            switch fileType(path) {
            case .typeSymbolicLink?: return (path, .notRegular)
            case nil: return (path, .missing)
            default: break
            }
        }
        let key = realPath(path) ?? path
        if let known = opened[key] { return (key, known.within(kind)) }
        let read = readFile(path, follow: kind.followsLinks, limit: max(SchemaFileLimits.maxFile, HausManifest.maxSize))
        opened[key] = read
        return (key, read.within(kind))
    }

    /// The package.json at `path` (`kind` says whose); nil if there is none
    /// (or, for a project's, it isn't a regular file).
    func packageJSON(_ path: String, _ kind: FileKind) throws(HausError) -> PackageJSON? {
        let (key, opened) = read(path, kind)
        switch opened {
        case .missing: return nil
        case .notRegular:
            if kind == .projectJSON { return nil }
            throw HausError(.packagePath, "\(shown(path)) is a symbolic link or not a regular file; it is not read")
        case .tooLarge(let size): throw tooLargeError(path, size)
        case .failed(let why): throw notFound("\(shown(path)): \(why)")
        case .bytes(let bytes):
            if let known = json[key] { return known }
            let doc = PackageJSON(bytes)
            json[key] = doc
            return doc
        }
    }

    /// Reads and checks the manifest of the package in `dir` (a real path).
    func manifest(_ dir: String) throws(HausError) -> (manifest: HausManifest, text: [UInt8]) {
        try manifestOf(dir, read(FilePath.join(dir, PackageFile.manifest), .manifest).opened)
    }

    /// Reads a schema file: a package's schema.haus, or a file outside
    /// packages at its real path. `missing` says why a missing one is missing.
    func schemaText(_ path: String, _ kind: FileKind, missing: () -> String) throws(HausError) -> [UInt8] {
        switch read(path, kind).opened {
        case .bytes(let text): return text
        case .missing: throw notFound(missing())
        case .notRegular where kind == .packageSchema:
            throw HausError(.packagePath, "\(shown(path)) is a symbolic link or not a regular file; it is not read")
        case .notRegular: throw notFound("\(shown(path)) is not a regular file")
        case .tooLarge(let size): throw tooLargeError(path, size)
        case .failed(let why): throw notFound("\(shown(path)): \(why)")
        }
    }
}

/// Checks the manifest at `dir/package.haus`, opened.
func manifestOf(_ dir: String, _ opened: Opened) throws(HausError) -> (manifest: HausManifest, text: [UInt8]) {
    let path = FilePath.join(dir, PackageFile.manifest)
    let invalid = { (why: String) in HausError(.packageManifest, "\(shown(path)): \(why)") }
    switch opened {
    case .missing: throw notFound("\(shown(dir)) is not a schema package: it has no \(PackageFile.manifest)")
    case .notRegular:
        throw HausError(
            .packagePath, "the manifest \(shown(path)) is a symbolic link or not a regular file; it is not read")
    case .tooLarge(let size): throw invalid("the manifest has \(size) bytes, more than 64 KiB")
    case .failed(let why): throw HausError(.importNotFound, "\(shown(path)): \(why)")
    case .bytes(let text):
        guard text.withUnsafeBufferPointer(firstInvalidUTF8) == nil else { throw invalid("the manifest is not UTF-8") }
        switch HausManifest.parse(text) {
        case .success(let m): return (m, text)
        case .failure(let why): throw invalid(why.message)
        }
    }
}

/// Reads the manifest of the package in `dir`, on its own.
func readManifest(_ dir: String) throws(HausError) -> HausManifest {
    let path = FilePath.join(dir, PackageFile.manifest)
    return try manifestOf(dir, readFile(path, follow: false, limit: HausManifest.maxSize)).manifest
}

// ── sources ─────────────────────────────────────────────────────

/// A package, with its manifest checked.
struct FoundPackage {
    let manifest: HausManifest
    /// Its directory, a real path.
    let dir: String
    /// Copies of a package have the same.
    let manifestText: [UInt8]
}

/// A schema file an import names, read.
struct SchemaSource {
    /// Its real path: two imports reach the same file when it is the same.
    let path: String
    let text: [UInt8]
    /// For a package's schema.haus.
    let package: FoundPackage?
}

/// Finds the package `name` for the file at `from` (a real path; nil for a
/// schema given as text) with `locator` and checks it: the manifest
/// (`package-manifest`) and its name (`import-not-found`), its version
/// (`package-version`), its files (`package-path`, `file-too-large`), and that
/// a package found in a folder that the package manager has too is the same
/// (`duplicate-package`).
func openPackage(
    for name: String, from: String?, with locator: PackageLocator, files: SchemaFiles
) throws(HausError) -> SchemaSource {
    let location = try locator.kind.locate(name, from: from, files: files)
    let source = try openPackage(location.dir, name: name, version: location.version, files: files)
    guard let other = location.sameAs else { return source }
    let copy = try openPackage(other, name: name, version: nil, files: files)
    let (a, b) = (source.package!, copy.package!)
    if a.dir != b.dir && (a.manifestText != b.manifestText || source.text != copy.text) {
        throw duplicatePackage(a.manifest, a.dir, b.manifest, b.dir)
    }
    return source
}

/// Reads the package in `dir`, which must be called `name`, with the
/// version its package manager gives it, if it gives one.
func openPackage(_ dir: String, name: String, version: String?, files: SchemaFiles) throws(HausError)
    -> SchemaSource
{
    guard let resolved = realPath(dir) else { throw notFound("\(shown(dir)): \(systemError())") }
    let (m, text) = try files.manifest(resolved)
    guard m.name == name else {
        let at = shown(FilePath.join(resolved, PackageFile.manifest))
        throw notFound("\(at) names the package \(quoteFromFile(m.name)), not \(name)")
    }
    if let given = version, given != m.version {
        let other =
            isSemanticVersion(given)
            ? "its package manager \(quoteFromFile(given))"
            : "and the version its package manager gives isn't a semantic version"
        throw HausError(
            .packageVersion,
            "the package.haus of \(name) says version \(quoteFromFile(m.version)), \(other) (\(shown(resolved)))")
    }
    let path = FilePath.join(resolved, PackageFile.schema)
    let schema = try files.schemaText(path, .packageSchema) {
        "\(name) has no \(PackageFile.schema) next to its manifest (\(shown(resolved)))"
    }
    return SchemaSource(path: path, text: schema, package: FoundPackage(manifest: m, dir: resolved, manifestText: text))
}

/// Reads the file `module` (`./common`, `../shared/money`) imports, next to
/// the file at `from` (a real path; nil for a schema given as text, which
/// imports no files). A package imports no files, and a file outside a
/// package no file inside one (`package-path`). Each name in the path is
/// spelled as its directory lists it, and the file's real path ends in
/// `.schema.haus` (`import-not-found`, the file not read).
func openRelative(_ module: String, from: String?, files: SchemaFiles) throws(HausError) -> SchemaSource {
    guard let from else {
        throw HausError(.importUnavailable, "a schema read from text imports no files (load it from its file)")
    }
    if let package = packageDir(of: from) {
        let name = (try? files.manifest(package).manifest.name) ?? shown(package)
        throw HausError(.packagePath, "the schema of \(name) can't import files, only packages by name")
    }
    let dir = FilePath.dir(from)
    let relative = module + PackageFile.schemaExtension
    let path = FilePath.join(dir, relative)
    if let name = misspelled(dir, relative) {
        throw notFound(
            "file not found: \(shown(path)) (no \(quoteFromFile(name)) in its directory: names are spelled as the directory lists them)"
        )
    }
    let resolved = realPath(path)
    if let into = resolved.flatMap(packageDir(of:)) ?? packageDir(of: path) {
        throw HausError(
            .packagePath, "the file is in the package directory \(shown(into)): import the package by its name")
    }
    guard let resolved else { throw notFound("file not found: \(shown(path))") }
    guard FilePath.base(resolved).hasSuffix(PackageFile.schemaExtension) else {
        throw notFound(
            "\(shown(path)) is not a schema file: its real path \(shown(resolved)) doesn't end in \(PackageFile.schemaExtension); it is not read"
        )
    }
    let text = try files.schemaText(resolved, .schema) { "file not found: \(shown(path))" }
    return SchemaSource(path: resolved, text: text, package: nil)
}

/// The first name in `relative` (from `dir`) that its directory doesn't
/// list byte for byte: on file systems that ignore case or Unicode
/// normalization, `./Billing/common` finds `billing/common.schema.haus`.
func misspelled(_ dir: String, _ relative: String) -> String? {
    var at = dir
    for part in FilePath.elements(relative) {
        switch part {
        case ".": continue
        case "..":
            at = FilePath.join(at, "..")
            continue
        default: break
        }
        // A directory that can't be listed: the file isn't found later.
        guard let entries = directoryEntries(at) else { return nil }
        guard entries.contains(where: { sameCodePoints($0, part) }) else { return part }
        at = FilePath.join(at, part)
    }
    return nil
}

/// Reads the root schema file at `path`: its real path and text. A
/// package's schema.haus is read as one (never through a link).
func rootSource(_ path: String, files: SchemaFiles) throws(HausError) -> (path: String, text: [UInt8]) {
    guard let resolved = realPath(path) else { throw HausError(.importNotFound, "\(shown(path)): \(systemError())") }
    let kind: FileKind = isPackageSchema(resolved) ? .packageSchema : .schema
    return (resolved, try files.schemaText(resolved, kind) { "file not found: \(shown(path))" })
}

/// Whether the file at `path` is a package's schema.haus: next to a package.haus.
func isPackageSchema(_ path: String) -> Bool {
    FilePath.base(path) == PackageFile.schema && exists(FilePath.join(FilePath.dir(path), PackageFile.manifest))
}

/// The package whose schema.haus is the file at `path` (a real path), if it
/// is one, with its manifest checked.
func packageOfFile(_ path: String, files: SchemaFiles) throws(HausError) -> FoundPackage? {
    guard isPackageSchema(path) else { return nil }
    let dir = FilePath.dir(path)
    let (m, text) = try files.manifest(dir)
    return FoundPackage(manifest: m, dir: dir, manifestText: text)
}

/// The package directory a file is in: the nearest directory above it with a
/// manifest, or nil.
func packageDir(of path: String) -> String? {
    ancestors(of: FilePath.dir(path)).first { exists(FilePath.join($0, PackageFile.manifest)) }
}

/// `dir` and the directories above it, nearest first.
func ancestors(of dir: String) -> some Sequence<String> {
    sequence(first: dir) { d in
        let parent = FilePath.dir(d)
        return parent == d ? nil : parent
    }
}

/// Whether the packages in `a` and `b` are copies of one package: their
/// manifests and schema files are the same, byte for byte, and regular files
/// (spec §13.3).
func sameFiles(_ a: String, _ b: String) -> Bool {
    func files(_ dir: String) -> (manifest: [UInt8], schema: [UInt8])? {
        let m = readFile(FilePath.join(dir, PackageFile.manifest), follow: false, limit: HausManifest.maxSize)
        let s = readFile(FilePath.join(dir, PackageFile.schema), follow: false, limit: SchemaFileLimits.maxFile)
        guard case .bytes(let manifest) = m, case .bytes(let schema) = s else { return nil }
        return (manifest, schema)
    }
    guard let x = files(a), let y = files(b) else { return false }
    return x.manifest == y.manifest && x.schema == y.schema
}

// ── errors ──────────────────────────────────────────────────────

func notFound(_ message: String) -> HausError { HausError(.importNotFound, message) }

func tooLargeError(_ path: String, _ size: Int) -> HausError {
    HausError(.fileTooLarge, "\(shown(path)) has \(size) bytes, more than 1 MiB; it is not read")
}

/// `duplicate-package`: two packages with one name.
func duplicatePackage(_ a: HausManifest, _ aDir: String, _ b: HausManifest, _ bDir: String) -> HausError {
    let copies =
        a.version == b.version ? " (two copies of \(quoteFromFile(a.version)) whose files or imports differ)" : ""
    return HausError(
        .duplicatePackage,
        "two packages are called \(quoteFromFile(a.name)): \(quoteFromFile(a.version)) in \(shown(aDir)) and \(quoteFromFile(b.version)) in \(shown(bDir))\(copies)"
    )
}
