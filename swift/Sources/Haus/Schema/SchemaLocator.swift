import Foundation

/// Finds the schema packages imports name (spec §13.3), for one package
/// manager: the directory of the package an import names, and whether the
/// importing file declares it. Everything else is the same for every package
/// manager and is checked when a schema is loaded: the manifest, its name
/// and version, the `@major` of the import, containment, one package per
/// name, cycles and ids.
///
/// ```swift
/// let packages = try PackageLocator.explicit(folders: ["../extensions"]).or(.nodeModules)
/// let schema = try HausSchema(contentsOf: "order.schema.haus", options: .init(packages: packages))
/// ```
///
/// Packages are never looked for anywhere else: not in global or
/// environment-wide places (`NODE_PATH`, npm's global folder), and never
/// over the network.
public struct PackageLocator: Sendable {
    indirect enum Kind: Sendable {
        case none
        case explicit(ExplicitPackages)
        case nodeModules
        case or(Kind, Kind)
    }

    let kind: Kind

    /// Finds no packages: a schema that imports one fails with the code
    /// `import-unavailable`.
    public static let none = PackageLocator(kind: .none)

    /// Finds packages in `node_modules`, by the npm rules of spec §13.3.
    ///
    /// A file imports only the packages it declares, checked before anything
    /// is looked for (`undeclared-package`): for a package's `schema.haus`,
    /// those in `dependencies`, `peerDependencies` and `optionalDependencies`
    /// of the package's own `package.json`; for other files, those and
    /// `devDependencies` of the nearest `package.json` above the file,
    /// skipping one with neither a name nor a dependency field.
    ///
    /// `@org/name` is then `D/node_modules/@org/name` for the nearest
    /// directory `D` from the importing file's real path up (a schema read
    /// from text starts at the working directory), skipping a `D` named
    /// `node_modules`, a scope directory inside one and a directory everyone
    /// may write to, such as `/tmp`. The first one that exists is the
    /// package: without a `package.haus` the import is not found.
    public static let nodeModules = PackageLocator(kind: .nodeModules)

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
    /// and `schema.haus`).
    public static func explicit(packages: [String] = [], folders: [String] = []) throws(HausError) -> PackageLocator {
        var given = ExplicitPackages()
        for dir in packages { try given.addPackage(dir) }
        for folder in folders { try given.addFolder(folder) }
        return PackageLocator(kind: .explicit(given))
    }

    /// This locator, then `next` for the packages this one doesn't find. A
    /// package given by its directory comes before `next`'s; one found in a
    /// folder doesn't: if `next` finds a package with its name and other
    /// files, the schema has two packages with one name (`duplicate-package`).
    public func or(_ next: PackageLocator) -> PackageLocator {
        PackageLocator(kind: .or(kind, next.kind))
    }
}

/// A package directory a locator found.
struct Location {
    /// It has package.haus and schema.haus.
    let dir: String
    /// The version the package manager gives the package (the version of
    /// npm's package.json), if it gives one: the manifest's must be the same
    /// (`package-version`).
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
        case .nodeModules:
            return try locateInNodeModules(name, from: from, files: files)
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
        } catch  where error.code == .importNotFound || error.code == .undeclaredPackage {
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

    mutating func addPackage(_ dir: String) throws(HausError) {
        guard let resolved = realPath(dir) else { throw notFound("\(shown(dir)): \(systemError())") }
        try add(readManifest(resolved), resolved, scanned: false)
    }

    mutating func addFolder(_ folder: String) throws(HausError) {
        let limit = SchemaFileLimits.maxFolderEntries
        guard let names = directoryEntries(folder, limit: limit + 1) else {
            throw notFound("\(shown(folder)): \(systemError())")
        }
        guard names.count <= limit else {
            throw HausError(.tooManyFiles, "\(shown(folder)): the folder of packages has more than \(limit) entries")
        }
        let dirs = names.map { FilePath.join(folder, $0) }.filter { exists(FilePath.join($0, PackageFile.manifest)) }
        for dir in dirs.sorted(by: precedes) {
            switch Self.manifest(dir) {
            case .success(let (manifest, resolved)): try add(manifest, resolved, scanned: true)
            case .failure(let error): unreadable.append((dir, error))
            }
        }
    }

    /// The manifest of the package in `dir`, and its real path.
    private static func manifest(_ dir: String) -> Result<(HausManifest, String), HausError> {
        Result { () throws(HausError) in
            guard let resolved = realPath(dir) else { throw notFound("\(shown(dir)): \(systemError())") }
            return (try readManifest(resolved), resolved)
        }
    }

    private mutating func add(_ m: HausManifest, _ dir: String, scanned: Bool) throws(HausError) {
        guard let i = packages.firstIndex(where: { $0.manifest.name == m.name }) else {
            packages.append(Given(manifest: m, dir: dir, scanned: scanned))
            return
        }
        let given = packages[i]
        guard given.dir == dir || sameFiles(given.dir, dir) else {
            throw duplicatePackage(given.manifest, given.dir, m, dir)
        }
        packages[i].scanned = given.scanned && scanned
    }

    func locate(_ name: String, files: SchemaFiles) throws(HausError) -> Location {
        guard let given = packages.first(where: { $0.manifest.name == name }) else {
            let unread = unreadable.map { "\(shown($0.dir)) (\($0.error.message))" }.joined(separator: ", ")
            let why = unreadable.isEmpty ? "" : " (packages in the folders given that could not be read: \(unread))"
            throw notFound("package \(name) is not among the packages given\(why)")
        }
        return Location(dir: given.dir, version: try npmVersion(given.dir, files: files), scanned: given.scanned)
    }
}

// ── node_modules ────────────────────────────────────────────────

/// The dependency fields of a package.json: all four count for a project's
/// files, the first three for a package's schema.haus.
let dependencyFields = ["dependencies", "peerDependencies", "optionalDependencies", "devDependencies"]

func locateInNodeModules(_ name: String, from: String?, files: SchemaFiles) throws(HausError) -> Location {
    let start = from.map(FilePath.dir) ?? FileManager.default.currentDirectoryPath
    try checkDeclared(name, from: from, dir: start, files: files)
    let candidates = ancestors(of: start).lazy.filter(isSearched).map { FilePath.join($0, "node_modules", name) }
    guard let installed = candidates.first(where: exists) else {
        throw notFound("package \(name) is not installed (no node_modules/\(name) in \(shown(start)) or above)")
    }
    guard exists(FilePath.join(installed, PackageFile.manifest)) else {
        throw notFound(
            "\(shown(installed)) is not a schema package: it has no \(PackageFile.manifest) (the nearest node_modules/\(name) is the package)"
        )
    }
    guard let dir = realPath(installed) else { throw notFound("\(shown(installed)): \(systemError())") }
    return Location(dir: dir, version: try npmVersion(dir, files: files))
}

/// Whether `node_modules` is looked for in `dir` (spec §13.3).
func isSearched(_ dir: String) -> Bool {
    let base = FilePath.base(dir)
    let scope = base.hasPrefix("@") && FilePath.base(FilePath.dir(dir)) == "node_modules"
    return base != "node_modules" && !scope && !isWorldWritable(dir)
}

/// Checks that the file at `from` (in `dir`) declares `name`
/// (`undeclared-package` if not).
func checkDeclared(_ name: String, from: String?, dir: String, files: SchemaFiles) throws(HausError) {
    let file = from.map(shown) ?? "the schema"
    let declaring: (path: String, doc: PackageJSON, fields: ArraySlice<String>)
    if let from, FilePath.base(from) == PackageFile.schema, exists(FilePath.join(dir, PackageFile.manifest)) {
        let path = FilePath.join(dir, "package.json")
        guard let doc = try files.packageJSON(path, .packageJSON) else {
            throw HausError(
                .undeclaredPackage,
                "the package in \(shown(dir)) has no package.json, so it declares no packages: \(name) isn't declared")
        }
        declaring = (path, doc, dependencyFields.prefix(3))
    } else {
        guard let (path, doc) = try project(above: dir, files: files) else {
            throw HausError(
                .undeclaredPackage,
                "no package.json above \(file) declares \(name): list it in the dependencies of a package.json, or give the package explicitly"
            )
        }
        declaring = (path, doc, dependencyFields[...])
    }
    guard declaring.fields.contains(where: { declaring.doc.dependencies[$0]?.contains(name) ?? false }) else {
        throw HausError(
            .undeclaredPackage,
            "\(file) doesn't declare \(name): \(shown(declaring.path)) doesn't list it in \(declaring.fields.joined(separator: ", "))"
        )
    }
}

/// The nearest package.json above `dir` that has a name or a dependency
/// field: the project's. One that isn't valid JSON, or isn't a regular file
/// (a directory, a broken link), is the project's too, and declares nothing:
/// the search stops there.
func project(above dir: String, files: SchemaFiles) throws(HausError) -> (path: String, doc: PackageJSON)? {
    for d in ancestors(of: dir) {
        let path = FilePath.join(d, "package.json")
        guard exists(path) else { continue }
        guard let doc = try files.packageJSON(path, .projectJSON) else { return (path, PackageJSON.unreadable) }
        if !doc.isValid || doc.members.contains("name") || dependencyFields.contains(where: doc.members.contains) {
            return (path, doc)
        }
    }
    return nil
}

/// The version of the package.json in the package directory `dir`, if it
/// has one that is a string.
func npmVersion(_ dir: String, files: SchemaFiles) throws(HausError) -> String? {
    try files.packageJSON(FilePath.join(dir, "package.json"), .packageJSON)?.version
}
