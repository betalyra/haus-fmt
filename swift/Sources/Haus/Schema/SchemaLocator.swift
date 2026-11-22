import Foundation

/// Finds the schema packages imports name (spec §13.3): the directory of the
/// package an import names. Everything else is checked when a schema is
/// loaded: the manifest, its name and version, the `@major` of the import,
/// containment, one package per name, cycles and ids.
///
/// ```swift
/// let packages = try PackageLocator.explicit(folders: ["../extensions"])
/// let schema = try HausSchema(contentsOf: "order.schema.haus", options: .init(packages: packages))
/// ```
///
/// Packages are given explicitly: as directories on disk, or as a file tree
/// that code provides, such as a SwiftPM resource bundle
/// (`explicit(in:packages:folders:)`). They are never looked
/// for anywhere else: not in `node_modules` (only implementations of the npm
/// ecosystem look there), not in global or environment-wide places, and never
/// over the network.
public struct PackageLocator: Sendable {
    indirect enum Kind: Sendable {
        case none
        case explicit(ExplicitPackages)
        case or(Kind, Kind)
    }

    let kind: Kind

    /// Finds no packages: a schema that imports one fails with the code
    /// `import-unavailable`.
    public static let none = PackageLocator(kind: .none)

    /// Packages given explicitly (spec §13.3): each of `packages` is a
    /// package's directory; each of `folders` a directory whose
    /// subdirectories (or links to directories) with a `package.haus` are
    /// packages. Their manifests name them, whatever the directories are
    /// called, and are read and checked now. They count as declared wherever
    /// they are imported.
    ///
    /// A directory of `packages` without a manifest is `import-not-found`;
    /// a folder that can't be read is `import-not-found`, one with more than
    /// ``SchemaFileLimits/maxFolderEntries`` entries `too-many-files`. A
    /// subdirectory of a folder whose manifest is invalid is left out; an
    /// import that isn't found names it. Two packages with one name are
    /// `duplicate-package`, unless they are copies (the same `package.haus`
    /// and `schema.haus`). A `package.json` beside a manifest is read only
    /// for its version (`package-version` if it differs), and ignored if it
    /// can't be read.
    public static func explicit(packages: [String] = [], folders: [String] = []) throws(HausError) -> PackageLocator {
        var given = ExplicitPackages()
        for dir in packages { try given.addPackage(dir, tree: nil) }
        for folder in folders { try given.addFolder(folder, tree: nil) }
        return PackageLocator(kind: .explicit(given))
    }

    /// Packages given explicitly in a read-only file tree, the directory
    /// `tree`: `packages` and `folders` are paths inside it, such as
    /// `"money"` or `"schemas"` (`.` for the tree itself), with the rules of
    /// ``explicit(packages:folders:)``. A tree follows no links (spec
    /// §13.3): a package or folder given that is a link, or reached through
    /// one, is `package-path`, and a subdirectory of a folder that is a link
    /// is left out, named when an import isn't found. A path that leaves the
    /// tree (`..`, `/…`) is `package-path`.
    public static func explicit(in tree: URL, packages: [String] = [], folders: [String] = []) throws(HausError)
        -> PackageLocator
    {
        guard let base = realPath(tree.path) else {
            throw notFound("the package tree \(shown(tree.lastPathComponent)): \(systemError())")
        }
        var given = ExplicitPackages()
        for dir in packages { try given.addPackage(try inTree(base, dir), tree: base) }
        for folder in folders { try given.addFolder(try inTree(base, folder), tree: base) }
        return PackageLocator(kind: .explicit(given))
    }

    /// Packages given explicitly in a bundle's resources, such as SwiftPM's
    /// `Bundle.module`: `explicit(in:packages:folders:)` with the
    /// bundle's resource directory as the tree.
    ///
    /// ```swift
    /// let packages = try PackageLocator.explicit(in: Bundle.module, folders: ["schemas"])
    /// ```
    public static func explicit(in bundle: Bundle, packages: [String] = [], folders: [String] = []) throws(HausError)
        -> PackageLocator
    {
        try explicit(in: bundle.resourceURL ?? bundle.bundleURL, packages: packages, folders: folders)
    }

    /// This locator, then `next` for the packages this one doesn't find. A
    /// package given by its directory comes before `next`'s; one found in a
    /// folder doesn't: if `next` finds a package with its name and other
    /// files, the schema has two packages with one name (`duplicate-package`).
    public func or(_ next: PackageLocator) -> PackageLocator {
        PackageLocator(kind: .or(kind, next.kind))
    }
}

/// The path `relative` inside the tree `base` (a real path): names only, no
/// `..`, not absolute (`package-path` otherwise).
private func inTree(_ base: String, _ relative: String) throws(HausError) -> String {
    let names = FilePath.elements(relative).filter { $0 != "." }
    guard relative.utf8.first != ASCII.slash, !names.contains("..") else {
        throw HausError(.packagePath, "\(shown(relative)) is not a path inside the package tree")
    }
    return FilePath.join(base, names.joined(separator: "/"))
}

/// A package directory a locator found.
struct Location {
    /// It has package.haus and schema.haus.
    let dir: String
    /// The version the package manager gives the package (the version of a
    /// package.json beside it), if it gives one: the manifest's must be the
    /// same (`package-version`).
    let version: String?
    /// Found by scanning a folder: it doesn't replace a package the next
    /// locator finds.
    var scanned = false
    /// A package with the same name found by scanning a folder: its files
    /// must be the same as this one's (`duplicate-package`).
    var sameAs: String?
}

extension PackageLocator.Kind {
    /// Finds the package `name` (`@org/name`, without `@major`) for the file
    /// at `from` (its real path; nil for a schema given as text). A package
    /// that isn't there is `import-not-found`, saying where it was looked for.
    func locate(_ name: String, from: String?, files: SchemaFiles) throws(HausError) -> Location {
        switch self {
        case .none:
            throw HausError(.importUnavailable, "no package locator (only std modules and files can be imported here)")
        case .explicit(let given):
            return try given.locate(name, files: files)
        case .or(let first, let second):
            return try either(first, second, name, from: from, files: files)
        }
    }

    private func either(_ first: Self, _ second: Self, _ name: String, from: String?, files: SchemaFiles)
        throws(HausError) -> Location
    {
        let found: Location
        do throws(HausError) {
            found = try first.locate(name, from: from, files: files)
        } catch  where error.code == .importNotFound {
            let why = error.message
            do throws(HausError) {
                return try second.locate(name, from: from, files: files)
            } catch  where error.code == .importNotFound {
                throw notFound("\(why); \(error.message)")
            }
        }
        guard found.scanned else { return found }
        // A package found in a folder: the other locator's comes first, if it has the same files.
        do throws(HausError) {
            var other = try second.locate(name, from: from, files: files)
            other.sameAs = found.dir
            return other
        } catch  where error.code == .importNotFound {
            return found
        }
    }
}

/// Packages given explicitly: each by its directory, or the packages in a folder.
struct ExplicitPackages: Sendable {
    struct Given: Sendable {
        let manifest: HausManifest
        /// Its real path.
        let dir: String
        var scanned: Bool
    }

    var packages: [Given] = []
    /// The subdirectories of folders whose manifest couldn't be read: named
    /// when an import isn't found.
    var unreadable: [(dir: String, error: HausError)] = []

    /// `dir` with every link resolved; in a tree (`tree` is its real path),
    /// one without links, inside it.
    private static func resolve(_ dir: String, tree: String?, files: SchemaFiles) throws(HausError) -> String {
        guard let resolved = realPath(dir) else { throw notFound("\(files.show(dir)): \(systemError())") }
        if let tree, !(sameCodePoints(resolved, dir) && FilePath.isInside(resolved, tree)) {
            throw HausError(
                .packagePath,
                "\(files.show(dir)) is a symbolic link or reached through one; a package tree follows none")
        }
        return resolved
    }

    /// Paths in messages about what is given: from the tree, or else from the
    /// directory a package or folder given is in (`common/package.haus`).
    private static func display(_ dir: String, tree: String?) -> SchemaFiles {
        let absolute = dir.utf8.first == ASCII.slash ? dir : FilePath.join(currentDirectory(), dir)
        return SchemaFiles(root: tree ?? FilePath.dir(absolute))
    }

    mutating func addPackage(_ dir: String, tree: String?) throws(HausError) {
        let resolved = try Self.resolve(dir, tree: tree, files: Self.display(dir, tree: tree))
        let files = Self.display(resolved, tree: tree)
        try add(files.manifest(resolved).manifest, resolved, scanned: false, files: files)
    }

    /// Adds the packages in `folder`. A subdirectory whose manifest can't be
    /// read, or whose package.json gives another version, is skipped, and
    /// named when an import isn't found by the last name of the folder's real
    /// path and its own (`schemas/broken`), however the folder was given
    /// (spec §13.3).
    mutating func addFolder(_ folder: String, tree: String?) throws(HausError) {
        let limit = SchemaFileLimits.maxFolderEntries
        let real = try Self.resolve(folder, tree: tree, files: Self.display(folder, tree: tree))
        let files = Self.display(real, tree: tree)
        guard let names = directoryEntries(real, limit: limit + 1) else {
            throw notFound("\(files.show(folder)): \(systemError())")
        }
        guard names.count <= limit else {
            throw HausError(
                .tooManyFiles, "\(files.show(folder)): the folder of packages has more than \(limit) entries")
        }
        let entries = names.filter { files.hasManifest(FilePath.join(real, $0)) }
        for name in entries.sorted(by: precedes) {
            switch Self.manifest(FilePath.join(real, name), tree: tree, files: files) {
            case .success(let (manifest, resolved)): try add(manifest, resolved, scanned: true, files: files)
            case .failure(let error): unreadable.append((FilePath.join(FilePath.base(real), name), error))
            }
        }
    }

    /// The manifest of the package in `dir`, and its real path; a
    /// package.json beside it with another version is `package-version`.
    private static func manifest(_ dir: String, tree: String?, files: SchemaFiles)
        -> Result<(HausManifest, String), HausError>
    {
        Result { () throws(HausError) in
            let resolved = try resolve(dir, tree: tree, files: files)
            let manifest = try files.manifest(resolved).manifest
            if let version = lenientVersion(resolved, files: files), version != manifest.version {
                throw HausError(
                    .packageVersion,
                    "the package.haus of \(manifest.name) says version \(quoteFromFile(manifest.version)), "
                        + "the package.json next to it \(quoteFromFile(version))")
            }
            return (manifest, resolved)
        }
    }

    private mutating func add(_ m: HausManifest, _ dir: String, scanned: Bool, files: SchemaFiles) throws(HausError) {
        guard let i = packages.firstIndex(where: { $0.manifest.name == m.name }) else {
            packages.append(Given(manifest: m, dir: dir, scanned: scanned))
            return
        }
        let given = packages[i]
        guard given.dir == dir || sameFiles(given.dir, dir, files: files) else {
            throw files.duplicatePackage(given.manifest, given.dir, m, dir)
        }
        packages[i].scanned = given.scanned && scanned
    }

    func locate(_ name: String, files: SchemaFiles) throws(HausError) -> Location {
        guard let given = packages.first(where: { $0.manifest.name == name }) else {
            let unread = unreadable.map { "\(shown($0.dir)) (\($0.error.message))" }.joined(separator: ", ")
            let why = unreadable.isEmpty ? "" : " (packages in the folders given that could not be read: \(unread))"
            throw notFound("package \(name) is not among the packages given\(why)")
        }
        return Location(dir: given.dir, version: lenientVersion(given.dir, files: files), scanned: given.scanned)
    }
}

/// The version of the package.json beside the manifest of a package given
/// explicitly (`dir` is its real path), if it gives one. Such a package.json
/// only gives a version: one that can't be read (a link, not a regular file,
/// too large, not JSON) is ignored, and is no error (spec §13.3, "Package
/// versions").
func lenientVersion(_ dir: String, files: SchemaFiles) -> String? {
    (try? files.packageJSON(FilePath.join(dir, "package.json")))??.version
}
