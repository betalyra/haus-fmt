// Reading the files imports name (spec §13.3): a ``PackageLocator`` says
// where a package is, and the rules here say whether it may be read.
// Resolution happens when a schema is loaded, never while data is parsed,
// and never over the network (§9.2).
//
// Every file read (the entry file, the files of relative imports, a
// package's package.haus, schema.haus and package.json) is a regular file:
// it is opened by its real path, or in a real directory, without following a
// link at its last name (O_NOFOLLOW) and without blocking (O_NONBLOCK, so
// that a FIFO can't block the open), its type and identity are checked on
// the opened file (fstat: a regular file with the device and inode `lstat`
// saw), and it is read from that file, so the file checked is the file read
// (spec §13.3, "Files read").
//
// The entry file and the root are resolved to real paths once, at the start.
// A relative import follows no link: it walks down its names from the
// importing file's real directory, so it stays inside the build's root when
// its `..` names do (spec §13.3, "Resolution" and "The root"). Messages show
// paths relative to the root, never absolute ones.

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

    /// Whether the absolute path `path` is `dir` or inside it, compared by
    /// names, not as text (`/a/bc` is not inside `/a/b`).
    static func isInside(_ path: String, _ dir: String) -> Bool {
        let (p, d) = (elements(path), elements(dir))
        return p.count >= d.count && zip(p, d).allSatisfy { sameCodePoints($0, $1) }
    }
}

/// Whether `module` is a file path of the grammar (`path`, spec §13.3):
/// `./` or one or more `../`, then names separated by `/`, each starting
/// with a letter, digit, `_` or `-` and made of those and `.`. So `..` comes
/// only at the start, and a path has no `.` name, no empty name and no `/` at
/// its end.
func isFilePath(_ module: String) -> Bool {
    var rest = Substring(module)
    if rest.hasPrefix("./") {
        rest = rest.dropFirst(2)
    } else {
        guard rest.hasPrefix("../") else { return false }
        while rest.hasPrefix("../") { rest = rest.dropFirst(3) }
    }
    let names = rest.split(separator: "/", omittingEmptySubsequences: false)
    return names.allSatisfy { name in
        guard let first = name.utf8.first, isPathNameStart(first) else { return false }
        return name.utf8.allSatisfy { isPathNameStart($0) || $0 == ASCII.dot }
    }
}

/// `[A-Za-z0-9_-]`: what a name of a path starts with.
private func isPathNameStart(_ c: UInt8) -> Bool {
    isLower(c) || isUpper(c) || isDigit(c) || c == ASCII.underscore || c == ASCII.minus
}

/// The absolute path with every link resolved; nil if there is nothing there.
func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The real path of the current directory.
func currentDirectory() -> String {
    let cwd = FileManager.default.currentDirectoryPath
    return realPath(cwd) ?? cwd
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

/// The text of the last system error.
func systemError() -> String { String(cString: strerror(errno)) }

// ── reading files ───────────────────────────────────────────────

/// Which file is read, and so its limit.
enum FileKind {
    /// A package's package.haus: at most 64 KiB.
    case manifest
    /// A package's schema.haus.
    case packageSchema
    /// A package's package.json.
    case packageJSON
    /// A schema file outside packages, read at its real path.
    case schema

    var limit: Int { self == .manifest ? HausManifest.maxSize : SchemaFileLimits.maxFile }

    /// Whether its name is one the build looks up itself (`package.haus`,
    /// `schema.haus`, `package.json`), which must be spelled as its
    /// directory lists it (spec §13.3, "Spelling").
    var isFixedName: Bool { self != .schema }
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

/// Opens the file at `path` without following a link at its last name and
/// without blocking, and reads it: a regular file of at most `limit` bytes,
/// checked on the opened file to be the regular file `lstat` saw (the same
/// device and inode), so that a file swapped between the two is not read.
func readFile(_ path: String, limit: Int) -> Opened {
    var seen = stat()
    guard lstat(path, &seen) == 0 else {
        let code = errno
        return code == ENOENT || code == ENOTDIR ? .missing : .failed(systemError())
    }
    guard seen.st_mode & S_IFMT == S_IFREG else { return .notRegular }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY)
    guard fd >= 0 else {
        let code = errno
        // Swapped for a link since lstat.
        if code == ELOOP { return .notRegular }
        return code == ENOENT || code == ENOTDIR ? .missing : .failed(systemError())
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { return .failed(systemError()) }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_dev == seen.st_dev, info.st_ino == seen.st_ino else {
        return .notRegular
    }
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

/// A package.json as far as resolution reads it: beside a package's
/// manifest, only for its version.
struct PackageJSON {
    /// Its `version`, if it is a string.
    let version: String?

    init(_ bytes: [UInt8]) {
        let valid = bytes.withUnsafeBufferPointer(firstInvalidUTF8) == nil
        let doc = valid ? try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) : nil
        version = (doc as? [String: Any])?["version"] as? String
    }
}

/// The files one schema reads, each once (spec §13.3), and the build's root:
/// a file needed in two roles is read once, and every use sees the same
/// bytes; each kind of file has its own size limit.
final class SchemaFiles {
    /// The build's root directory, a real path (spec §13.3, "The root"):
    /// relative imports stay inside it, and messages show paths from it.
    let root: String
    private var opened: [String: Opened] = [:]
    private var json: [String: PackageJSON] = [:]
    private var listings: [String: [String]?] = [:]

    /// Files read for a build whose root is `root` (a real path); the
    /// current directory for a schema read from text, or for packages given
    /// before any build.
    init(root: String = currentDirectory()) {
        self.root = root
    }

    /// A path for a message: relative to the root (`../vendor/x` for a
    /// package outside it), with its control and bidirectional characters
    /// escaped (spec §9.2, §13.3).
    func show(_ path: String) -> String {
        shown(path.utf8.first == ASCII.slash ? FilePath.relative(from: root, to: path) : path)
    }

    /// The names in the directory `dir`; nil if it can't be listed.
    func listing(_ dir: String) -> [String]? {
        if let known = listings[dir] { return known }
        let names = directoryEntries(dir)
        listings[dir] = names
        return names
    }

    /// Whether the directory `dir` lists `name`, spelled so, code point for
    /// code point; false if it can't be listed.
    func lists(_ dir: String, _ name: String) -> Bool {
        listing(dir)?.contains { sameCodePoints($0, name) } ?? false
    }

    /// Whether `dir` has a package.haus: one its listing spells so. A
    /// directory that can't be listed (only entered) has one if something
    /// is there, so that it never passes for a directory outside packages.
    func hasManifest(_ dir: String) -> Bool {
        guard listing(dir) != nil else { return exists(FilePath.join(dir, PackageFile.manifest)) }
        return lists(dir, PackageFile.manifest)
    }

    /// Reads the file at `path` (a real path, or a name in a real directory)
    /// as `kind` says, and returns the path it is cached by.
    func read(_ path: String, _ kind: FileKind) -> Opened {
        if kind.isFixedName && !lists(FilePath.dir(path), FilePath.base(path)) { return .missing }
        if let known = opened[path] { return known.within(kind) }
        let read = readFile(path, limit: max(SchemaFileLimits.maxFile, HausManifest.maxSize))
        opened[path] = read
        return read.within(kind)
    }

    /// The package.json beside a package's manifest at `path`; nil if there
    /// is none. One that can't be read throws.
    func packageJSON(_ path: String) throws(HausError) -> PackageJSON? {
        switch read(path, .packageJSON) {
        case .missing: return nil
        case .notRegular:
            throw HausError(.packagePath, "\(show(path)) is a symbolic link or not a regular file; it is not read")
        case .tooLarge(let size): throw tooLargeError(path, size)
        case .failed(let why): throw notFound("\(show(path)): \(why)")
        case .bytes(let bytes):
            if let known = json[path] { return known }
            let doc = PackageJSON(bytes)
            json[path] = doc
            return doc
        }
    }

    /// Reads and checks the manifest of the package in `dir` (a real path).
    func manifest(_ dir: String) throws(HausError) -> (manifest: HausManifest, text: [UInt8]) {
        let path = FilePath.join(dir, PackageFile.manifest)
        let invalid = { (why: String) in HausError(.packageManifest, "\(self.show(path)): \(why)") }
        switch read(path, .manifest) {
        case .missing: throw notFound("\(show(dir)) is not a schema package: it has no \(PackageFile.manifest)")
        case .notRegular:
            throw HausError(
                .packagePath, "the manifest \(show(path)) is a symbolic link or not a regular file; it is not read")
        case .tooLarge(let size): throw invalid("the manifest has \(size) bytes, more than 64 KiB")
        case .failed(let why): throw HausError(.importNotFound, "\(show(path)): \(why)")
        case .bytes(let text):
            guard text.withUnsafeBufferPointer(firstInvalidUTF8) == nil else {
                throw invalid("the manifest is not UTF-8")
            }
            switch HausManifest.parse(text) {
            case .success(let m): return (m, text)
            case .failure(let why): throw invalid(why.message)
            }
        }
    }

    /// Reads a schema file: a package's schema.haus, or a file outside
    /// packages at its real path. `missing` says why a missing one is missing.
    func schemaText(_ path: String, _ kind: FileKind, missing: () -> String) throws(HausError) -> [UInt8] {
        switch read(path, kind) {
        case .bytes(let text): return text
        case .missing: throw notFound(missing())
        case .notRegular where kind == .packageSchema:
            throw HausError(.packagePath, "\(show(path)) is a symbolic link or not a regular file; it is not read")
        case .notRegular: throw notFound("\(show(path)) is not a regular file; it is not read")
        case .tooLarge(let size): throw tooLargeError(path, size)
        case .failed(let why): throw notFound("\(show(path)): \(why)")
        }
    }

    func tooLargeError(_ path: String, _ size: Int) -> HausError {
        HausError(.fileTooLarge, "\(show(path)) has \(size) bytes, more than 1 MiB; it is not read")
    }

    /// `duplicate-package`: two packages with one name.
    func duplicatePackage(_ a: HausManifest, _ aDir: String, _ b: HausManifest, _ bDir: String) -> HausError {
        let copies =
            a.version == b.version ? " (two copies of \(quoteFromFile(a.version)) whose files or imports differ)" : ""
        return HausError(
            .duplicatePackage,
            "two packages are called \(quoteFromFile(a.name)): \(quoteFromFile(a.version)) in \(show(aDir)) and \(quoteFromFile(b.version)) in \(show(bDir))\(copies)"
        )
    }
}

// ── the root ────────────────────────────────────────────────────

/// The root of a build that starts from the file whose real path is `entry`
/// (spec §13.3, "The root"): the directory `root` names (a relative one from
/// the entry file's real directory), resolved to its real path once, which
/// must contain the entry file (`import-outside-root`, at no place), or else
/// the entry file's directory.
func buildRoot(entry: String, option root: String?) throws(HausError) -> String {
    guard let root else { return FilePath.dir(entry) }
    let given = root.utf8.first == ASCII.slash ? root : FilePath.join(FilePath.dir(entry), root)
    guard let real = realPath(given), fileType(real) == .typeDirectory, FilePath.isInside(entry, real) else {
        throw HausError(
            .importOutsideRoot,
            "the root option is not a directory that contains the schema file the build starts from")
    }
    return real
}

/// Reads the entry file, whose real path is `path`: a package's schema.haus
/// is read as one.
func entryText(_ path: String, files: SchemaFiles) throws(HausError) -> [UInt8] {
    let kind: FileKind = isPackageSchema(path, files: files) ? .packageSchema : .schema
    return try files.schemaText(path, kind) { "file not found: \(files.show(path))" }
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
/// a package found in a folder that another locator has too is the same
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
        throw files.duplicatePackage(a.manifest, a.dir, b.manifest, b.dir)
    }
    return source
}

/// Reads the package in `dir`, which must be called `name`, with the
/// version its package manager gives it, if it gives one.
func openPackage(_ dir: String, name: String, version: String?, files: SchemaFiles) throws(HausError)
    -> SchemaSource
{
    guard let resolved = realPath(dir) else { throw notFound("\(files.show(dir)): \(systemError())") }
    let (m, text) = try files.manifest(resolved)
    guard m.name == name else {
        let at = files.show(FilePath.join(resolved, PackageFile.manifest))
        throw notFound("\(at) names the package \(quoteFromFile(m.name)), not \(name)")
    }
    if let given = version, given != m.version {
        let other =
            isSemanticVersion(given)
            ? "its package manager \(quoteFromFile(given))"
            : "and the version its package manager gives isn't a semantic version"
        throw HausError(
            .packageVersion,
            "the package.haus of \(name) says version \(quoteFromFile(m.version)), \(other) (\(files.show(resolved)))")
    }
    let path = FilePath.join(resolved, PackageFile.schema)
    let schema = try files.schemaText(path, .packageSchema) {
        "\(name) has no \(PackageFile.schema) next to its manifest (\(files.show(resolved)))"
    }
    return SchemaSource(path: path, text: schema, package: FoundPackage(manifest: m, dir: resolved, manifestText: text))
}

/// Reads the file `module` (`./common`, `../shared/money`, a path of the
/// grammar) imports, next to the file at `from` (a real path; nil for a
/// schema given as text, which imports no files). A package (`fromPackage`)
/// imports no files (`package-path`). The other checks come in the order of
/// spec §13.3 ("Resolution"), the first that fails giving the error: the
/// `..` names stay inside the root, checked on the text before anything is
/// looked at (`import-outside-root`); the walk down the names, each listed
/// with that spelling and none a symbolic link (`import-not-found`); a
/// target outside a package's directory (`package-path`); then the file,
/// regular and within its limit.
func openRelative(_ module: String, from: String?, fromPackage: Bool, files: SchemaFiles) throws(HausError)
    -> SchemaSource
{
    guard let from else {
        throw HausError(.importUnavailable, "a schema read from text imports no files (load it from its file)")
    }
    if fromPackage {
        let name = (try? files.manifest(FilePath.dir(from)).manifest.name) ?? files.show(FilePath.dir(from))
        throw HausError(.packagePath, "the schema of \(name) can't import files, only packages by name")
    }
    let dir = FilePath.dir(from)
    // `..` only at the start (grammar `path`), and no link is followed: going
    // up from the real directory of the importing file means the same on the
    // text and on the file system.
    let names = FilePath.elements(module + PackageFile.schemaExtension)
    let ups = names.prefix { $0 == ".." }.count
    let top = (0..<ups).reduce(dir) { d, _ in FilePath.dir(d) }
    guard ups <= FilePath.elements(dir).count, FilePath.isInside(top, files.root) else {
        throw HausError(
            .importOutsideRoot,
            "\(module) goes above the build's root (the directory of the schema file it starts from, or its root option)"
        )
    }
    let path = try walkNames(names.drop { $0 == "." || $0 == ".." }, from: top, files: files)
    try checkOutsidePackages(path, files: files)
    let text = try files.schemaText(path, .schema) { "file not found: \(files.show(path))" }
    return SchemaSource(path: path, text: text, package: nil)
}

/// The walk down the names of a relative import (spec §13.3, "Resolution")
/// from the real directory `dir`: each name must be an entry its directory
/// lists with that exact spelling, also on file systems that ignore case or
/// Unicode normalization, and not a symbolic link (seen without following
/// it); each name but the last a directory. A directory that can't be listed
/// can't show how a name is spelled. Nothing behind a link is looked at, and
/// a message about one doesn't say where it points. The path reached has no
/// links; what its last name is (a regular file or not) is checked when it is
/// opened.
func walkNames(_ names: some Collection<String>, from dir: String, files: SchemaFiles) throws(HausError) -> String {
    // The file the import names, for messages.
    let target = files.show(FilePath.join(dir, names.joined(separator: "/")))
    var at = dir
    for (i, name) in names.enumerated() {
        let path = FilePath.join(at, name)
        guard files.listing(at) != nil else {
            throw notFound(
                "file not found: \(target) (\(files.show(at)) can't be listed, so how \(quoteFromFile(name)) is spelled can't be checked)"
            )
        }
        guard files.lists(at, name) else {
            throw notFound(
                "file not found: \(target) (no \(quoteFromFile(name)) in its directory: names are spelled as the directory lists them)"
            )
        }
        switch fileType(path) {
        case .typeSymbolicLink?:
            throw notFound(
                "\(files.show(path)) is a symbolic link: a relative import follows no link, and nothing behind it is read"
            )
        case .typeDirectory?: break
        default:
            guard i == names.count - 1 else {
                throw notFound("file not found: \(target) (\(files.show(path)) is not a directory)")
            }
        }
        at = path
    }
    return at
}

/// Checks that the file at `path` (reached by a relative import, inside the
/// root) is in no package's directory (spec §13.3, "Imports"): the
/// directories from its own up to the root, the root included, each a
/// package's when it lists `package.haus` (`package-path`). One that can't be
/// listed can't show whether it is a package's: the import fails
/// (`import-not-found`), and never passes as one outside a package.
func checkOutsidePackages(_ path: String, files: SchemaFiles) throws(HausError) {
    for dir in ancestors(of: FilePath.dir(path)).prefix(while: { FilePath.isInside($0, files.root) }) {
        guard let names = files.listing(dir) else {
            throw notFound(
                "whether \(files.show(dir)) is a package's directory can't be checked (it can't be listed); \(files.show(path)) is not read"
            )
        }
        if names.contains(where: { sameCodePoints($0, PackageFile.manifest) }) {
            throw HausError(
                .packagePath,
                "the file is in the package directory \(files.show(dir)): import the package by its name")
        }
    }
}

/// Whether the file at `path` is a package's schema.haus: next to a package.haus.
func isPackageSchema(_ path: String, files: SchemaFiles) -> Bool {
    FilePath.base(path) == PackageFile.schema && files.hasManifest(FilePath.dir(path))
}

/// The package whose schema.haus is the file at `path` (a real path), if it
/// is one, with its manifest checked.
func packageOfFile(_ path: String, files: SchemaFiles) throws(HausError) -> FoundPackage? {
    guard isPackageSchema(path, files: files) else { return nil }
    let dir = FilePath.dir(path)
    let (m, text) = try files.manifest(dir)
    return FoundPackage(manifest: m, dir: dir, manifestText: text)
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
func sameFiles(_ a: String, _ b: String, files: SchemaFiles) -> Bool {
    func read(_ dir: String) -> (manifest: [UInt8], schema: [UInt8])? {
        let m = files.read(FilePath.join(dir, PackageFile.manifest), .manifest)
        let s = files.read(FilePath.join(dir, PackageFile.schema), .packageSchema)
        guard case .bytes(let manifest) = m, case .bytes(let schema) = s else { return nil }
        return (manifest, schema)
    }
    guard let x = read(a), let y = read(b) else { return false }
    return x.manifest == y.manifest && x.schema == y.schema
}

// ── errors ──────────────────────────────────────────────────────

func notFound(_ message: String) -> HausError { HausError(.importNotFound, message) }
