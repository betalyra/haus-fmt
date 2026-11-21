/// A schema file (`.schema.haus`, spec §14) with its imports (§13.3), its
/// names resolved and every rule of spec §14 and §13.3 checked. Its types
/// decode and encode values (spec §15) and convert them to and from
/// schema-based JSON (§16.3). A schema is immutable and safe to share
/// between tasks.
///
/// ```swift
/// let schema = try HausSchema(parsing: """
///     import std/time (Date)
///     type Order = { id: Int, placed: Date, total: Decimal }
///     """)
/// let order = try schema.type("Order")
/// let decoded = try order.decode(parse(#"{ id: 0x10, placed: Date("2026-11-13"), total: 19.90 }"#))
/// try order.toJSON(decoded) // {"id":"16","placed":"2026-11-13","total":"19.90"}
/// ```
///
/// ``init(contentsOf:options:)`` reads a schema file, its relative imports
/// next to it, and the packages it imports found by ``Options/packages``:
///
/// ```swift
/// let packages = try PackageLocator.explicit(folders: ["extensions"])
/// let schema = try HausSchema(contentsOf: "order.schema.haus", options: .init(packages: packages))
/// ```
public struct HausSchema: Sendable {
    /// How to read a schema.
    public struct Options: Sendable {
        /// Leaves out every attribute, as if none were written: decoding is
        /// the same (spec §15). For tests of that.
        public var withoutAttributes: Bool
        /// Finds the packages imports name (spec §13.3). ``PackageLocator/none``
        /// finds none: a schema that imports one fails with the code
        /// `import-unavailable`.
        public var packages: PackageLocator

        public init(withoutAttributes: Bool = false, packages: PackageLocator = .none) {
            self.withoutAttributes = withoutAttributes
            self.packages = packages
        }
    }

    /// A type definition of the schema file, its own or imported.
    public struct Definition: Sendable {
        /// Its name in the file (imported types keep their names).
        public let name: String
        /// Its id (spec §13.3): `@haus-fmt/money@1#Money`, `billing/common#Address`
        /// for a file outside packages (its path from the root file's
        /// directory), or its name for a schema read from text.
        public let id: String
        /// Its type parameters.
        public let params: [String]
        /// The `//` comment lines just above it.
        public let doc: String
        /// The message of its `@deprecated` ("" without one), or nil if it isn't deprecated.
        public let deprecated: String?
        let template: Instance
    }

    /// A schema package the schema reaches, directly or through other packages.
    public struct Package: Sendable, Hashable {
        /// `@haus-fmt/money`.
        public let name: String
        /// The version of its manifest: `1.2.0`.
        public let version: String
        /// Its directory, a real path.
        public let directory: String
    }

    /// The file's own definitions, in source order.
    public let definitions: [Definition]
    /// The types the file imports from packages and files (not std/time), by
    /// the name they have in it.
    public let imported: [Definition]
    /// Every schema package the schema reaches, by name.
    public let packages: [Package]
    /// What to point out in the file (not in the files it imports), in source
    /// order: attributes this version doesn't define (`unknown-attribute`),
    /// uses of deprecated types (`deprecated`), and record cases with no
    /// schema-based JSON form (`no-json-form`, spec §16.3).
    public let warnings: [HausError]

    /// Reads a schema from text. Errors have the position in the text. It
    /// imports std/time and packages found by ``Options/packages``; a
    /// relative import fails with `import-unavailable`, as text has no place
    /// among files.
    public init(parsing text: String, options: Options = Options()) throws(HausError) {
        try self.init(text: Array(text.utf8), path: nil, options: options, files: SchemaFiles())
    }

    /// Reads a schema from UTF-8; invalid UTF-8 fails with `invalid-utf8`.
    public init(bytes: some Collection<UInt8>, options: Options = Options()) throws(HausError) {
        try self.init(text: Array(bytes), path: nil, options: options, files: SchemaFiles())
    }

    /// Reads the schema file at `path`, its relative imports next to it, and
    /// the packages it imports found by ``Options/packages`` (spec §13.3).
    /// Each file is read once, by its real path; a package's files are never
    /// read through a link. Errors in an imported file are reported at the
    /// import, with their place in that file.
    public init(contentsOf path: String, options: Options = Options()) throws(HausError) {
        let files = SchemaFiles()
        let root = try rootSource(path, files: files)
        try self.init(text: root.text, path: root.path, options: options, files: files)
    }

    private init(text: [UInt8], path: String?, options: Options, files: SchemaFiles) throws(HausError) {
        let loader = SchemaLoader(options: options, files: files)
        try loader.run(text, path: path)
        let root = loader.units[0]
        let definition = { (name: String, ref: SchemaLoader.DefRef) in
            let def = loader.definition(ref)
            return Definition(
                name: name, id: loader.id(ref), params: def.params, doc: def.doc,
                deprecated: isDeprecated(def.attrs) ? deprecation(def.attrs) ?? "" : nil,
                template: loader.instances[loader.byKey[loader.templateKey(ref)]!])
        }
        definitions = root.file.types.indices.map { definition(root.file.types[$0].name, .init(unit: 0, def: $0)) }
        imported = root.scope.filter { $0.value.unit != 0 }.sorted { precedes($0.key, $1.key) }.map(definition)
        packages = loader.reached.values.map {
            Package(name: $0.package.manifest.name, version: $0.package.manifest.version, directory: $0.package.dir)
        }.sorted { precedes($0.name, $1.name) }
        warnings = (root.file.warnings + loader.noJSONForms()).sorted { $0.pos < $1.pos }.map {
            loader.fail(0, $0.pos, $0.code, $0.message)
        }
    }

    /// The definition called `name`, its own or imported, which must have no
    /// parameters: `unknown-type` if there is none, `wrong-arity` if it has
    /// parameters.
    public func type(_ name: String) throws(HausError) -> SchemaType {
        guard let d = (definitions + imported).first(where: { $0.name == name }) else {
            throw HausError(.unknownType, "the schema has no type \(quoteForMessage(name))")
        }
        guard d.params.isEmpty else {
            throw HausError(.wrongArity, "\(name) needs arguments, so it can't describe a whole file")
        }
        return SchemaType(node: SchemaNode(.ref(d.template)), name: name, isStream: d.template.stream)
    }

    /// Decodes `value` with the type called `name`. See ``SchemaType/decode(_:limits:)``.
    public func decode(_ name: String, _ value: HausValue) throws(HausError) -> HausValue {
        try type(name).decode(value)
    }
}

/// A named type of a ``HausSchema``, without parameters: what a whole value
/// (or, for a `Stream` definition, each value of a stream) is decoded with.
public struct SchemaType: Sendable {
    /// The resolved type: a reference to the definition's instance.
    let node: SchemaNode
    /// Its name in the schema.
    public let name: String
    /// Whether it is a `Stream` definition, `type Events = Stream Event`: it
    /// describes a file, each of whose values ``decode(_:limits:)`` decodes
    /// as an `Event`.
    public let isStream: Bool

    /// Decodes `value` with the type and returns the value an encoder writes
    /// back (spec §15): integers in decimal (`-0` as `0`), floats in their one
    /// spelling, the fields an open record doesn't list left out, and
    /// everything else as it was. An error has the code and the path of the
    /// failing value (`$.items[2].price`); an error inside a `Secret` is
    /// `invalid-secret`, at the secret. For a `Stream` definition, `value`
    /// is one value of the stream.
    public func decode(_ value: HausValue, limits: Limits = Limits()) throws(HausError) -> HausValue {
        try run(value, limits: limits, encoding: false, path: [])
    }

    /// Decodes value `index` of a stream: an error's path starts with the
    /// index, `$[3].total` (spec §15, "Streams").
    public func decode(_ value: HausValue, index: Int, limits: Limits = Limits()) throws(HausError) -> HausValue {
        try run(value, limits: limits, encoding: false, path: [.index(index)])
    }

    /// Checks a value built in code against the type and returns the value
    /// to write (spec §15): what ``decode(_:limits:)`` gives for it, with the
    /// numbers also checked against the number limits.
    public func encode(_ value: HausValue, limits: Limits = Limits()) throws(HausError) -> HausValue {
        try run(value, limits: limits, encoding: true, path: [])
    }

    /// Decodes the values of a file: each one on its own with the type a
    /// `Stream` definition holds (an error's path starts with the value's
    /// index: `$[3].total`); any other type expects exactly one value
    /// (`not-one-value`, at the path `$`).
    public func decodeAll(_ values: [HausValue], limits: Limits = Limits()) throws(HausError) -> [HausValue] {
        guard isStream else { return [try decode(one(values), limits: limits)] }
        var out: [HausValue] = []
        out.reserveCapacity(values.count)
        for (i, v) in values.enumerated() { out.append(try decode(v, index: i, limits: limits)) }
        return out
    }

    /// The one value of a file read with this type (spec §6): none, or two or
    /// more, is `not-one-value`, at the path `$`.
    func one(_ values: [HausValue]) throws(HausError) -> HausValue {
        guard values.count == 1 else {
            throw HausError(
                .notOneValue, "\(name) is not a Stream: expected one value, found \(values.count)", path: "$")
        }
        return values[0]
    }

    func run(_ value: HausValue, limits: Limits, encoding: Bool, path: [PathStep]) throws(HausError) -> HausValue {
        var walker = SchemaWalker(limits: try limits.checked(), encoding: encoding, path: path)
        return try walker.value(value, node) ?? value
    }
}
