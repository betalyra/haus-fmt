// A schema file with its imports (spec §13.3): names looked up, generic
// types applied, and every rule of spec §14 checked. Generic types are
// applied by instantiating them (`List Int` is a type of its own), which
// ends because no type parameter passes, inside a bigger type, along a cycle
// of references back to itself (§9.10, the expansive-cycle rule); a limit on
// the number of instances is a second guard.
//
// Each file a schema reads is a unit: the root (unit 0), and the files and
// packages it imports, directly or not. Errors inside an imported file are
// reported at the import, with their place in that file.

/// The most instances of generic types one schema makes.
let maxInstances = 10_000

/// The prelude's types with parameters, and how many.
let genericTypes: [String: Int] = ["Array": 1, "Map": 1, "Maybe": 1, "Result": 2, "Secret": 1, "Stream": 1]

/// Loads a schema file and its imports: their definitions resolved into instances.
final class SchemaLoader {
    enum State { case new, busy, done }

    /// A definition: its file, and its index there.
    struct DefRef: Hashable {
        let unit: Int
        let def: Int
    }

    /// Where a file was first imported: the importing file, the import's
    /// offset there, the module as written.
    struct Origin {
        let unit: Int
        let pos: Int
        let label: String
    }

    /// One schema file: the root, or one it imports.
    final class Unit {
        let text: [UInt8]
        let file: SchemaFile
        /// Its real path; nil for a schema given as text.
        let path: String?
        /// The id of its types (spec §13.3): `@haus-fmt/money@1`, `billing/common`;
        /// "" for a schema given as text, whose types are known by their names.
        let id: String
        let origin: Origin?
        /// Its own definitions: what other files can import.
        var own: [String: Int] = [:]
        /// Every named type in scope, its own and imported ones.
        var scope: [String: DefRef] = [:]
        /// The types imported from std/time.
        var std: [String: String] = [:]

        init(text: [UInt8], file: SchemaFile, path: String?, id: String, origin: Origin?) {
            self.text = text
            self.file = file
            self.path = path
            self.id = id
            self.origin = origin
        }
    }

    /// A package a schema reaches: one per name.
    struct Reached {
        /// Its schema.haus.
        let path: String
        let package: FoundPackage
        let text: [UInt8]
    }

    let options: HausSchema.Options
    let files: SchemaFiles
    var units: [Unit] = []
    var byPath: [CodePointKey: Int] = [:]
    var reached: [String: Reached] = [:]
    /// The files being loaded, outermost first: importing one of them again is a cycle.
    var loading: [Int] = []
    /// The copies of packages whose imports have been checked.
    var copies = Set<CodePointKey>()
    /// The directory the ids of files outside packages start from: the root file's.
    var baseDir: String?

    var instances: [Instance] = []
    /// The definition of each instance.
    var definitionOf: [DefRef] = []
    var states: [State] = []
    var byKey: [String: Int] = [:]
    /// The key of each record's and variant's shape, and of each record and variant: see `key`.
    var shapes: [String: String] = [:]
    /// The key of each record and variant by its identity. The record or
    /// variant is kept with its key: once freed, its identity could be
    /// another's, which would get its key.
    var recordKeys: [ObjectIdentifier: (shape: RecordShape, key: String)] = [:]
    var variantKeys: [ObjectIdentifier: (shape: VariantShape, key: String)] = [:]
    /// The instances to evaluate, from `queueHead` on.
    var queue: [Int] = []
    var queueHead = 0
    /// The references to named types, and where they are written.
    var references: [(instance: Instance, unit: Int, pos: Int)] = []

    init(options: HausSchema.Options, files: SchemaFiles) {
        self.options = options
        self.files = files
    }

    /// The root file.
    var file: SchemaFile { units[0].file }

    /// The definition `ref` stands for.
    func definition(_ ref: DefRef) -> TypeDef { units[ref.unit].file.types[ref.def] }

    // ── errors ──────────────────────────────────────────────────

    /// A mistake at offset `pos` of file `u`, as an error of the root file:
    /// a mistake inside an imported file is reported at the import, with its
    /// place in that file.
    @inline(never)
    func fail(_ u: Int, _ pos: Int, _ code: HausError.Code, _ message: String) -> HausError {
        var (u, pos, message) = (u, pos, message)
        while true {
            let unit = units[u]
            let at = position(pos, in: unit.text)
            guard let origin = unit.origin else { return HausError(code, message, position: at) }
            (u, pos, message) = (origin.unit, origin.pos, "\(origin.label) (\(at.line):\(at.column)): \(message)")
        }
    }

    func position(_ pos: Int, in text: [UInt8]) -> SourcePosition {
        text.withUnsafeBufferPointer { sourcePosition(of: pos, in: $0) }
    }

    // ── loading ─────────────────────────────────────────────────

    /// Loads the root file, at `path` (a real path; nil for a schema given
    /// as text), with its imports, and resolves every definition.
    func run(_ text: [UInt8], path: String?) throws(HausError) {
        var package: FoundPackage?
        if let path {
            package = try packageOfFile(path, files: files)
            baseDir = FilePath.dir(path)
        }
        if let package, let path {
            reached[package.manifest.name] = Reached(path: path, package: package, text: text)
        }
        let id = package?.manifest.id ?? path.map(appID) ?? ""
        try load(text, path: path, id: id, origin: nil)
        try evaluateAll()
    }

    /// The id of a file outside packages (spec §13.3): its path from the
    /// root file's directory, without the extension (`billing/common`).
    func appID(_ path: String) -> String {
        let relative = baseDir.map { FilePath.relative(from: $0, to: path) } ?? path
        return relative.hasSuffix(PackageFile.schemaExtension)
            ? String(relative.dropLast(PackageFile.schemaExtension.count)) : relative
    }

    /// Parses a file, loads its imports and puts its types in scope.
    @discardableResult
    func load(_ text: [UInt8], path: String?, id: String, origin: Origin?) throws(HausError) -> Int {
        let parsed: SchemaFile
        do throws(SchemaFailure) {
            parsed = try parseSchemaFile(text)
        } catch {
            let at = position(error.pos, in: text)
            guard let origin else { throw HausError(error.code, error.message, position: at) }
            throw fail(
                origin.unit, origin.pos, error.code, "\(origin.label) (\(at.line):\(at.column)): \(error.message)")
        }
        let u = units.count
        if let path { byPath[CodePointKey(string: path)] = u }
        let file = options.withoutAttributes ? parsed.withoutAttributes() : parsed
        units.append(Unit(text: text, file: file, path: path, id: id, origin: origin))
        loading.append(u)
        defer { loading.removeLast() }
        try imports(u)
        try ownTypes(u)
        return u
    }

    func imports(_ u: Int) throws(HausError) {
        for imp in units[u].file.imports {
            if imp.module.hasPrefix("std/") {
                try standardImport(u, imp)
                continue
            }
            let isModule =
                imp.module.hasPrefix("@") && imp.module.contains("/") || imp.module.hasPrefix("./")
                || imp.module.hasPrefix("../")
            guard isModule else {
                throw fail(
                    u, imp.pos, .unknownModule,
                    "unknown module \(quoteForMessage(imp.module)): import std/…, a package @org/name or a file ./name")
            }
            let dep = try importFrom(u, pos: imp.pos, module: imp.module, label: imp.module, from: units[u].path)
            for n in imp.names {
                guard let d = units[dep].own[n.name] else {
                    let has = units[dep].file.types.map(\.name)
                    let list = has.isEmpty ? "" : " (it has \(has.joined(separator: ", ")))"
                    throw fail(u, n.pos, .unknownImport, "\(quoteForMessage(imp.module)) has no type \(n.name)\(list)")
                }
                try bring(u, n, def: DefRef(unit: dep, def: d))
            }
        }
    }

    /// `import std/time (…)`.
    func standardImport(_ u: Int, _ imp: ImportDecl) throws(HausError) {
        switch imp.module.dropFirst(4) {
        case "time": break
        case "money":
            let names = imp.names.map(\.name).joined(separator: ", ")
            throw fail(
                u, imp.pos, .unknownModule,
                "std/money is no longer a standard module; it is the package @haus-fmt/money: import @haus-fmt/money (\(names))"
            )
        default:
            throw fail(
                u, imp.pos, .unknownModule, "unknown standard module \(quoteForMessage(imp.module)) (there is std/time)"
            )
        }
        for n in imp.names {
            guard timeTypes.contains(n.name) else {
                throw fail(
                    u, n.pos, .unknownImport,
                    "std/time has no type \(n.name) (it has \(timeTypes.joined(separator: ", ")))")
            }
            try bring(u, n, std: n.name)
        }
    }

    /// Puts an imported name in scope, once.
    func bring(_ u: Int, _ n: NameAt, def: DefRef? = nil, std: String? = nil) throws(HausError) {
        let unit = units[u]
        guard unit.scope[n.name] == nil && unit.std[n.name] == nil else {
            throw fail(u, n.pos, .duplicateImport, "\(n.name) is imported twice")
        }
        if let def { unit.scope[n.name] = def }
        if let std { unit.std[n.name] = std }
    }

    /// `@org/name@2`: the package, and the major version wanted.
    func splitMajor(_ module: String) -> (name: String, major: String?) {
        let b = Array(module.utf8)
        let at = UInt8(ascii: "@")
        guard b.first == at, let i = b.lastIndex(of: at), i > 1, i < b.count - 1, b[(i + 1)...].allSatisfy(isDigit)
        else { return (module, nil) }
        return (String(decoding: b[..<i], as: UTF8.self), String(decoding: b[(i + 1)...], as: UTF8.self))
    }

    /// Loads the file `module` names for the file at `from`; errors are
    /// reported at offset `pos` of file `u`, for the import `label`.
    func importFrom(_ u: Int, pos: Int, module: String, label: String, from: String?) throws(HausError) -> Int {
        let at = { (code: HausError.Code, message: String) in self.fail(u, pos, code, message) }
        let (name, wanted) = splitMajor(module)
        let found: SchemaSource
        do throws(HausError) {
            found =
                name.hasPrefix("@")
                ? try openPackage(for: name, from: from, with: options.packages, files: files)
                : try openRelative(name, from: from, files: files)
        } catch {
            throw at(error.code, "can't import \(label): \(error.message)")
        }
        if let wanted, let p = found.package, p.manifest.major != wanted {
            throw at(
                .importVersion,
                "\(label) wants major version \(wanted), but version \(quoteFromFile(p.manifest.version)) was found")
        }
        // One package per name (spec §13.3): copies with the same files, whose
        // imports reach the same packages, are one.
        var path = found.path
        var copyPath: String?
        if let p = found.package, let old = reached[p.manifest.name], !sameCodePoints(old.path, found.path) {
            guard old.package.manifestText == p.manifestText && old.text == found.text else {
                let e = duplicatePackage(old.package.manifest, old.package.dir, p.manifest, p.dir)
                throw at(e.code, "can't import \(label): \(e.message)")
            }
            (copyPath, path) = (found.path, old.path)
        }
        if loading.contains(where: { units[$0].path.map { sameCodePoints($0, path) } ?? false }) {
            throw at(.importCycle, "import cycle: \(label) imports this file again")
        }
        if let cached = byPath[CodePointKey(string: path)] {
            if let copyPath { try copyImports(u, pos: pos, label: label, original: cached, copyPath: copyPath) }
            return cached
        }
        guard units.count + copies.count < SchemaFileLimits.maxFiles else {
            throw at(.tooManyFiles, "more than \(SchemaFileLimits.maxFiles) schema files are imported")
        }
        let origin = Origin(unit: u, pos: pos, label: label)
        guard let p = found.package else { return try load(found.text, path: path, id: appID(path), origin: origin) }
        reached[p.manifest.name] = Reached(path: path, package: p, text: found.text)
        return try load(found.text, path: path, id: p.manifest.id, origin: origin)
    }

    /// Resolves the imports of a copy of a package (its schema.haus at
    /// `copyPath`), identical to the package loaded as `original`, from the
    /// copy's place: they must reach the same packages (spec §13.3).
    func copyImports(_ u: Int, pos: Int, label: String, original: Int, copyPath: String) throws(HausError) {
        guard copies.insert(CodePointKey(string: copyPath)).inserted else { return }
        guard units.count + copies.count <= SchemaFileLimits.maxFiles else {
            throw fail(u, pos, .tooManyFiles, "more than \(SchemaFileLimits.maxFiles) schema files are imported")
        }
        let dir = shown(FilePath.dir(copyPath))
        for imp in units[original].file.imports where imp.module.hasPrefix("@") {
            let label = "\(label) (its copy in \(dir) imports \(imp.module))"
            _ = try importFrom(u, pos: pos, module: imp.module, label: label, from: copyPath)
        }
    }

    /// Puts the file's own definitions in scope, unless a name is also
    /// imported, and checks that generic ones can't grow without bound
    /// (§9.10). Cycles are within one file: imports have none.
    func ownTypes(_ u: Int) throws(HausError) {
        let unit = units[u]
        for (d, def) in unit.file.types.enumerated() {
            if unit.scope[def.name] != nil || unit.std[def.name] != nil {
                throw fail(u, def.pos, .duplicateType, "type \(def.name) is already imported")
            }
            unit.own[def.name] = d
        }
        for (d, def) in unit.file.types.enumerated() { unit.scope[def.name] = DefRef(unit: u, def: d) }
        if let f = GrowthGraph(unit.file.types, own: unit.own).firstGrowing() {
            throw fail(u, f.pos, f.code, f.message)
        }
    }

    // ── evaluation ──────────────────────────────────────────────

    /// Evaluates every definition of every file (templates for generic
    /// ones), so that all errors surface, then checks references to streams
    /// and that every cycle of definitions consumes input (§9.9).
    func evaluateAll() throws(HausError) {
        for (u, unit) in units.enumerated() {
            for (d, def) in unit.file.types.enumerated() {
                let params = def.params.map { SchemaNode(.param($0)) }
                _ = try instance(DefRef(unit: u, def: d), args: params, at: u, pos: def.pos)
                while queueHead < queue.count {
                    queueHead += 1
                    try evaluateInstance(queue[queueHead - 1])
                }
            }
        }
        if let r = references.first(where: { $0.instance.stream }) {
            throw fail(
                r.unit, r.pos, .misplacedStream,
                "\(r.instance.name) is a Stream; a stream can only be the whole file, not part of a type")
        }
        // §9.9: every cycle passes through a record, array or variant (Secret is no step).
        for inst in instances {
            var seen = Set<ObjectIdentifier>()
            var t = inst.body
            while true {
                if case .secret(let e) = t.kind {
                    t = e
                } else if case .ref(let next) = t.kind {
                    guard seen.insert(ObjectIdentifier(next)).inserted else {
                        let ref = definitionOf[inst.index]
                        throw fail(
                            ref.unit, definition(ref).pos, .unguardedRecursion,
                            "type \(inst.name) refers to itself without a record, array or variant in between")
                    }
                    t = next.body
                } else {
                    break
                }
            }
        }
        for inst in instances {
            var t = inst.body
            while case .ref(let next) = t.kind { t = next.body }
            inst.resolved = t
        }
        markJSONNull(instances)
    }

    /// The key of the template instance of definition `d` of the root file.
    func templateKey(_ d: Int) -> String { templateKey(DefRef(unit: 0, def: d)) }

    /// The key of a definition's template instance.
    func templateKey(_ ref: DefRef) -> String {
        let params = definition(ref).params
        let key = "\(ref.unit):\(ref.def)"
        return params.isEmpty ? key : key + "(" + params.map { "'" + $0 }.joined(separator: ",") + ")"
    }

    /// The id of a definition (spec §13.3): `@haus-fmt/money@1#Money`;
    /// its name for a schema given as text.
    func id(_ ref: DefRef) -> String {
        let name = definition(ref).name
        let id = units[ref.unit].id
        return id.isEmpty ? name : id + "#" + name
    }

    /// The instance of definition `ref` with `args`, created if new. It is
    /// used at offset `pos` of file `at`, for errors.
    func instance(_ ref: DefRef, args: [SchemaNode], at: Int, pos: Int) throws(HausError) -> Instance {
        let key = "\(ref.unit):\(ref.def)" + (args.isEmpty ? "" : "(" + args.map(key).joined(separator: ",") + ")")
        if let id = byKey[key] { return instances[id] }
        guard instances.count < maxInstances else {
            throw fail(
                at, pos, .growingRecursion,
                "more than \(maxInstances) type instances: a generic type grows without bound"
            )
        }
        let inst = Instance(name: definition(ref).name, id: id(ref), args: args, index: instances.count)
        instances.append(inst)
        definitionOf.append(ref)
        states.append(.new)
        byKey[key] = inst.index
        queue.append(inst.index)
        return inst
    }

    /// A text that tells types apart, for instances. It never holds the
    /// whole of an argument, which can grow exponentially with legitimate
    /// nesting (`P a a` inside `P a a` …): an instance is keyed by its
    /// number, a record or variant by the number of its shape, so a key is
    /// as long as one type expression. Each record and variant is keyed once.
    func key(_ t: SchemaNode) -> String {
        switch t.kind {
        case .builtin(let b): b.rawValue
        case .time(let name): name
        case .param(let name): "'" + name
        case .array(let e): "Array(" + key(e) + ")"
        case .map(let e): "Map(" + key(e) + ")"
        case .maybe(let e): "Maybe(" + key(e) + ")"
        case .secret(let e): "Secret(" + key(e) + ")"
        case .ref(let inst): "#\(inst.index)"
        case .record(let r): recordKey(r)
        case .variant(let v): variantKey(v)
        }
    }

    /// The number of a shape, as a key.
    func shapeKey(_ shape: String) -> String {
        if let k = shapes[shape] { return k }
        let k = "~\(shapes.count)"
        shapes[shape] = k
        return k
    }

    func recordKey(_ r: RecordShape) -> String {
        if let k = recordKeys[ObjectIdentifier(r)]?.key { return k }
        let fields = r.fields.map { f in
            var quoted: [UInt8] = []
            appendQuoted(f.key, to: &quoted)
            return String(decoding: quoted, as: UTF8.self) + (f.optional ? "?" : "") + ":" + key(f.type)
        }
        let k = shapeKey("{" + (r.closed ? "|" : "") + fields.joined(separator: ",") + "}")
        recordKeys[ObjectIdentifier(r)] = (r, k)
        return k
    }

    func variantKey(_ v: VariantShape) -> String {
        if let k = variantKeys[ObjectIdentifier(v)]?.key { return k }
        let cases = v.cases.map { c in
            switch c.payload {
            case .none: c.tag
            case .record(let r): c.tag + recordKey(r)
            // Not the key of one positional argument: X R and X a with R for a differ.
            case .named(let t): c.tag + "{" + key(t) + "}"
            case .positional(let items): c.tag + "(" + items.map(key).joined(separator: ",") + ")"
            }
        }
        let k = shapeKey("<" + cases.joined(separator: "|") + (v.open ? "|_" : "") + ">")
        variantKeys[ObjectIdentifier(v)] = (v, k)
        return k
    }

    /// Evaluates the body of an instance, now if it isn't yet (a spread needs it).
    func evaluateInstance(_ id: Int) throws(HausError) {
        let ref = definitionOf[id]
        let def = definition(ref)
        switch states[id] {
        case .done: return
        case .busy:
            throw fail(
                ref.unit, def.pos, .spreadCycle, "type \(def.name) spreads itself (directly or through another type)")
        case .new: break
        }
        states[id] = .busy
        let inst = instances[id]
        let env = Dictionary(zip(def.params, inst.args), uniquingKeysWith: { a, _ in a })
        if def.type.name == "Stream" {
            guard def.type.args.count == 1 else {
                throw fail(
                    ref.unit, def.type.pos, .wrongArity, "Stream takes 1 argument(s), found \(def.type.args.count)")
            }
            inst.body = try eval(ref.unit, def.type.args[0], env)
            inst.stream = true
        } else {
            inst.body = try eval(ref.unit, def.type, env)
        }
        states[id] = .done
    }

    /// Whether `t`, written in file `u`, is a record (spec §15), decided
    /// where it is written: names are followed through their definitions,
    /// with their arguments as written, and a type parameter of the
    /// definition it is written in is not a record, whatever its argument is.
    func isRecord(_ u: Int, _ t: TypeExpr) -> Bool {
        final class Bindings {
            let names: [String: (type: TypeExpr, unit: Int, env: Bindings?)]
            init(_ names: [String: (type: TypeExpr, unit: Int, env: Bindings?)]) { self.names = names }
        }
        var (u, t) = (u, t)
        var env: Bindings?
        for _ in 0..<maxInstances {
            switch t.form {
            case .record: return true
            case .variant: return false
            case .param(let name):
                guard let bound = env?.names[name] else { return false }
                (t, u, env) = bound
            case .name(let name):
                guard genericTypes[name] == nil, let at = units[u].scope[name] else { return false }
                let def = definition(at)
                let bound = zip(def.params, t.args).map { ($0, (type: $1, unit: u, env: env)) }
                (t, u, env) = (def.type, at.unit, Bindings(Dictionary(bound, uniquingKeysWith: { a, _ in a })))
            }
        }
        return false
    }

    /// The record or variant `...Name`, written in file `u`, copies.
    func spread(_ u: Int, _ s: SpreadDef, record wantRecord: Bool) throws(HausError) -> SchemaNode {
        let want = wantRecord ? "record" : "variant"
        let notOne = fail(u, s.pos, .invalidSpread, "\(s.name) is not a \(want), so it can't be spread here")
        guard let at = units[u].scope[s.name] else {
            if units[u].std[s.name] != nil || preludeTypes[s.name] != nil { throw notOne }
            throw fail(u, s.pos, .unknownType, unknownTypeMessage(s.name))
        }
        let params = definition(at).params
        guard params.isEmpty else {
            throw fail(
                u, s.pos, .invalidSpread,
                "\(s.name) has parameters (\(([s.name] + params).joined(separator: " "))); only a type without parameters can be spread"
            )
        }
        var inst = try instance(at, args: [], at: u, pos: s.pos)
        var seen = Set<ObjectIdentifier>()
        while true {
            try evaluateInstance(inst.index)
            if inst.stream { throw fail(u, s.pos, .invalidSpread, "\(s.name) is a Stream and can't be spread") }
            switch inst.body.kind {
            case .ref(let next) where seen.insert(ObjectIdentifier(next)).inserted:
                inst = next
            case .record where wantRecord, .variant where !wantRecord:
                return inst.body
            default:
                throw notOne
            }
        }
    }

    /// Evaluates a type expression of file `u`, with the parameters in `env`.
    func eval(_ u: Int, _ t: TypeExpr, _ env: [String: SchemaNode]) throws(HausError) -> SchemaNode {
        switch t.form {
        case .param(let name):
            guard let a = env[name] else { throw fail(u, t.pos, .unknownParameter, "unknown type parameter \(name)") }
            return a
        case .record: return SchemaNode(.record(try record(u, t, env)))
        case .variant: return try variant(u, t, env)
        case .name(let name): return try named(u, name, t, env)
        }
    }

    /// The own entries of a record or variant with the entries of its
    /// spreads in their places, each with where it is written.
    func withSpreads<Entry>(
        _ own: [(Entry, Int)], _ spreads: [SpreadDef], _ copied: (SpreadDef) throws(HausError) -> [Entry]
    ) throws(HausError) -> [(Entry, Int)] {
        var out: [(Entry, Int)] = []
        for i in 0...own.count {
            for sp in spreads where sp.at == i {
                out += try copied(sp).map { ($0, sp.pos) }
            }
            if i < own.count { out.append(own[i]) }
        }
        return out
    }

    func variant(_ u: Int, _ t: TypeExpr, _ env: [String: SchemaNode]) throws(HausError) -> SchemaNode {
        var own: [(CaseType, Int)] = []
        for c in t.cases {
            own.append((CaseType(tag: c.tag, payload: try payload(u, c, env), deprecated: deprecated(c.attrs)), c.pos))
        }
        let all = try withSpreads(own, t.spreads) { (sp) throws(HausError) -> [CaseType] in
            guard case .variant(let v) = try spread(u, sp, record: false).kind else { return [] }
            return v.cases
        }
        var seen = Set<String>()
        for (c, pos) in all where !seen.insert(c.tag).inserted {
            throw fail(u, pos, .duplicateTag, "duplicate tag \(c.tag)")
        }
        return SchemaNode(.variant(VariantShape(open: !t.closed, cases: all.map(\.0))))
    }

    /// What a case of a variant takes.
    func payload(_ u: Int, _ c: CaseDef, _ env: [String: SchemaNode]) throws(HausError) -> Payload {
        if c.payload.isEmpty { return .none }
        if c.payload.count == 1 && c.payload[0].form == .record { return .record(try record(u, c.payload[0], env)) }
        var items: [SchemaNode] = []
        for p in c.payload { items.append(try eval(u, p, env)) }
        // A record case by name, if it is a record where it is written.
        if c.payload.count == 1 && c.payload[0].name != nil && isRecord(u, c.payload[0]) { return .named(items[0]) }
        return .positional(items)
    }

    func record(_ u: Int, _ t: TypeExpr, _ env: [String: SchemaNode]) throws(HausError) -> RecordShape {
        var own: [(FieldType, Int)] = []
        for f in t.fields {
            let field = FieldType(
                key: f.key, optional: f.optional, type: try eval(u, f.type, env), deprecated: deprecated(f.attrs))
            own.append((field, f.pos))
        }
        let all = try withSpreads(own, t.spreads) { (sp) throws(HausError) -> [FieldType] in
            guard case .record(let r) = try spread(u, sp, record: true).kind else { return [] }
            return r.fields
        }
        var seen = Set<CodePointKey>()
        for (f, pos) in all where !seen.insert(CodePointKey(string: f.key)).inserted {
            throw fail(u, pos, .duplicateField, "duplicate field \(quoteKey(f.key))")
        }
        return RecordShape(closed: t.closed, fields: all.map(\.0))
    }

    func named(_ u: Int, _ name: String, _ t: TypeExpr, _ env: [String: SchemaNode]) throws(HausError) -> SchemaNode {
        func arity(_ n: Int) throws(HausError) {
            guard t.args.count != n else { return }
            throw fail(u, t.pos, .wrongArity, "\(name) takes \(n) argument(s), found \(t.args.count)")
        }
        func args() throws(HausError) -> [SchemaNode] {
            var out: [SchemaNode] = []
            for a in t.args { out.append(try eval(u, a, env)) }
            return out
        }
        if let n = genericTypes[name] {
            // Arity first, then where it is: `{ e: Stream }` is wrong-arity.
            try arity(n)
            if name == "Stream" {
                throw fail(u, t.pos, .misplacedStream, "Stream is only allowed as the whole type of a definition")
            }
            let a = try args()
            switch name {
            case "Array": return SchemaNode(.array(a[0]))
            case "Map": return SchemaNode(.map(a[0]))
            case "Maybe": return SchemaNode(.maybe(a[0]))
            case "Secret": return SchemaNode(.secret(a[0]))
            default:
                return SchemaNode(
                    .variant(
                        VariantShape(
                            open: false,
                            cases: [
                                CaseType(tag: "Err", payload: .positional([a[0]]), deprecated: nil),
                                CaseType(tag: "Ok", payload: .positional([a[1]]), deprecated: nil),
                            ])))
            }
        }
        if let at = units[u].scope[name] {
            try arity(definition(at).params.count)
            let inst = try instance(at, args: try args(), at: u, pos: t.pos)
            references.append((inst, u, t.pos))
            return SchemaNode(.ref(inst))
        }
        if let time = units[u].std[name] {
            try arity(0)
            return SchemaNode(.time(time))
        }
        if let b = Builtin(rawValue: name) {
            try arity(0)
            return SchemaNode(.builtin(b))
        }
        throw fail(u, t.pos, .unknownType, unknownTypeMessage(name))
    }
}
