// What the grammar of schema files allows but the spec doesn't (§14):
// checked on one file, before its names are looked up.

/// The prelude's types and their number of parameters (spec §13). A schema
/// can't redefine them.
let preludeTypes: [String: Int] = [
    "Bool": 0, "Maybe": 1, "Result": 2, "String": 0, "Bytes": 0, "Array": 1, "Map": 1,
    "Int": 0, "Int8": 0, "Int16": 0, "Int32": 0, "Int64": 0,
    "UInt8": 0, "UInt16": 0, "UInt32": 0, "UInt64": 0,
    "Float32": 0, "Float64": 0, "Decimal": 0, "Any": 0, "Secret": 1, "Stream": 1,
]

/// The types of std/time (spec §13.2), the only standard module.
public let timeTypes = ["Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone"]

/// The attributes this version defines (spec §14).
let definedAttributes: Set<String> = ["deprecated"]

/// Checks a parsed file, and returns its warnings: attributes this version
/// doesn't define.
func checkSchemaFile(_ f: SchemaFile) throws(SchemaFailure) -> [SchemaFailure] {
    var names = Set<String>()
    for d in f.types {
        guard names.insert(d.name).inserted else {
            throw SchemaFailure(d.pos, .duplicateType, "\(d.name) is defined twice")
        }
    }
    if let d = f.types.first(where: { preludeTypes[$0.name] != nil }) {
        throw SchemaFailure(d.pos, .redefinePrelude, "\(d.name) is a prelude type and can't be redefined")
    }
    if let imp = f.imports.first(where: { $0.names.isEmpty }) {
        let m = quoteForMessage(imp.module)
        throw SchemaFailure(imp.pos, .unknownImport, "import \(m) names no type: import \(imp.module) (Name, …)")
    }
    for imp in f.imports {
        if let why = importVersionError(imp.module) { throw SchemaFailure(imp.pos, .importVersion, why) }
    }
    if let imp = f.imports.first(where: { $0.module.hasPrefix("@") && !isPackageName(packageOf($0.module)) }) {
        throw SchemaFailure(
            imp.pos, .unknownModule,
            "unknown module \(quoteForMessage(imp.module)): a package is @org/name, in lowercase letters, digits, -, . and _ (not node_modules)"
        )
    }
    for d in f.types { try checkParameters(d) }
    for d in f.types { try checkTypeExpr(d.type) }
    var warnings: [SchemaFailure] = []
    for attrs in allAttributes(f) { warnings += try checkAttributes(attrs) }
    return warnings
}

func checkParameters(_ d: TypeDef) throws(SchemaFailure) {
    var seen = Set<String>()
    for p in d.params {
        if p.hasPrefix("_") {
            throw SchemaFailure(
                d.pos, .invalidParameter, "\(p) can't be a parameter name: a parameter starts with a lowercase letter")
        }
        guard seen.insert(p).inserted else {
            throw SchemaFailure(d.pos, .invalidParameter, "parameter \(p) appears twice")
        }
    }
}

func checkTypeExpr(_ t: TypeExpr) throws(SchemaFailure) {
    if let s = t.spreads.first(where: { !isUpper($0.name.utf8.first!) }) {
        throw SchemaFailure(
            s.pos, .rowParameter,
            "row parameters (...\(s.name)) aren't supported; spread a named type instead: ...UserEvent")
    }
    if let s = t.spreads.first(where: { !$0.attrs.isEmpty }) {
        throw SchemaFailure(
            s.attrs[0].pos, .attributeOnSpread,
            "a spread can't have attributes; the fields or tags of \(s.name) keep their own")
    }
    switch t.form {
    case .param("_"):
        throw SchemaFailure(
            t.pos, .underscoreType,
            "types are open by default, so there is no _: write < > for any tag, or use a type parameter")
    case .record:
        var seen = Set<CodePointKey>()
        for f in t.fields where !seen.insert(CodePointKey(string: f.key)).inserted {
            throw SchemaFailure(f.pos, .duplicateField, "duplicate field \(quoteKey(f.key))")
        }
    case .variant:
        if t.closed && t.cases.isEmpty && t.spreads.isEmpty {
            throw SchemaFailure(t.pos, .closedEmptyVariant, "a closed variant needs at least one tag")
        }
        var seen = Set<String>()
        for c in t.cases where !seen.insert(c.tag).inserted {
            throw SchemaFailure(c.pos, .duplicateTag, "duplicate tag \(c.tag)")
        }
    case .name, .param:
        break
    }
    for child in t.children { try checkTypeExpr(child) }
}

/// Every list of attributes in the file: of its types, fields and tags.
func allAttributes(_ file: SchemaFile) -> [[Attribute]] {
    var out: [[Attribute]] = []
    for d in file.types {
        out.append(d.attrs)
        d.type.walk { t in
            out += t.fields.map(\.attrs)
            out += t.cases.map(\.attrs)
        }
    }
    return out
}

/// Checks the attributes of one type, field or tag: defined ones take the
/// right arguments and are written once. Unknown ones are accepted, with a
/// warning (spec §14).
func checkAttributes(_ attrs: [Attribute]) throws(SchemaFailure) -> [SchemaFailure] {
    var warnings: [SchemaFailure] = []
    for (i, a) in attrs.enumerated() {
        guard definedAttributes.contains(a.name) else {
            warnings.append(
                SchemaFailure(a.pos, .unknownAttribute, "unknown attribute @\(a.name): this version of haus ignores it")
            )
            continue
        }
        if attrs[..<i].contains(where: { $0.name == a.name }) {
            throw SchemaFailure(a.pos, .attributeTwice, "@\(a.name) is written twice here")
        }
        if a.name == "deprecated" && deprecation(attrs) == nil {
            throw SchemaFailure(
                a.pos, .attributeArguments,
                #"@deprecated takes at most one argument, a string: @deprecated("use email")"#)
        }
    }
    return warnings
}

/// The message of the first `@deprecated` among `attrs` ("" without one),
/// or nil if it has other arguments than one string or none.
func deprecation(_ attrs: [Attribute]) -> String? {
    guard let a = attrs.first(where: { $0.name == "deprecated" }) else { return "" }
    switch a.args.count {
    case 0: return ""
    case 1:
        if case .string(let why) = a.args[0] { return why }
        return nil
    default: return nil
    }
}

/// Whether `attrs` mark something deprecated.
func isDeprecated(_ attrs: [Attribute]) -> Bool { attrs.contains { $0.name == "deprecated" } }

/// `@deprecated`, with its message, if `attrs` have one.
func deprecated(_ attrs: [Attribute]) -> Deprecation? {
    isDeprecated(attrs) ? Deprecation(why: deprecation(attrs) ?? "") : nil
}

/// Warnings about uses of the file's deprecated types outside deprecated
/// types, once where each is written (spec §14), spreads included.
func deprecatedUses(_ f: SchemaFile) -> [SchemaFailure] {
    let deprecatedTypes = Dictionary(
        f.types.filter { isDeprecated($0.attrs) }.map { ($0.name, deprecation($0.attrs) ?? "") },
        uniquingKeysWith: { a, _ in a })
    guard !deprecatedTypes.isEmpty else { return [] }
    var out: [SchemaFailure] = []
    func use(_ name: String, _ pos: Int) {
        guard let why = deprecatedTypes[name] else { return }
        out.append(
            SchemaFailure(pos, .deprecated, why.isEmpty ? "\(name) is deprecated" : "\(name) is deprecated: \(why)"))
    }
    for d in f.types where deprecatedTypes[d.name] == nil {
        d.type.walk { t in
            if let name = t.name { use(name, t.pos) }
            for s in t.spreads { use(s.name, s.pos) }
        }
    }
    return out
}

/// Why the version of a package import (`@org/name@1.1`) isn't a major
/// version, `@N` without leading zeros (spec §13.3), or nil.
func importVersionError(_ module: String) -> String? {
    guard module.hasPrefix("@"), let at = module.dropFirst().firstIndex(of: "@") else { return nil }
    let name = String(module[..<at])
    let version = module[module.index(after: at)...]
    let digits = version.prefix { $0.isASCII && $0.isNumber }
    let rest = version.dropFirst(digits.count)
    let trimmed = digits.drop { $0 == "0" }
    let major = trimmed.isEmpty ? "0" : String(trimmed)
    let shown = "\(quoteForMessage(name))@\(quoteForMessage(String(version)))"
    if digits.isEmpty || rest.first.map({ $0 != "." }) ?? false {
        return "\(shown): expected a major version after '@', like \(name)@1"
    }
    if !rest.isEmpty { return "\(shown): an import names only the major version (\(name)@\(major))" }
    if digits.count != major.count { return "\(shown): a major version has no leading zeros (\(name)@\(major))" }
    return nil
}

/// The package a package import names, without its `@major`.
func packageOf(_ module: String) -> String {
    guard let at = module.dropFirst().firstIndex(of: "@") else { return module }
    return String(module[..<at])
}

/// Whether `name` is a package name: `@org/name`, each part lowercase
/// letters, digits, `-`, `.` and `_`, starting with a letter or digit, not
/// `node_modules`, at most 214 characters (spec §13.3).
func isPackageName(_ name: String) -> Bool {
    func segment(_ s: Substring) -> Bool {
        guard let first = s.utf8.first, s != "node_modules", isLower(first) || isDigit(first) else { return false }
        return s.utf8.allSatisfy {
            isLower($0) || isDigit($0) || $0 == ASCII.minus || $0 == ASCII.dot || $0 == ASCII.underscore
        }
    }
    guard name.hasPrefix("@"), name.utf8.count <= 214 else { return false }
    let parts = name.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    return parts.count == 2 && segment(parts[0]) && segment(parts[1])
}

/// The message for an unknown type, with how to import it if it is a
/// well-known one.
func unknownTypeMessage(_ name: String) -> String {
    switch name {
    case "Money", "Currency":
        "unknown type \(name) (import it with: import @haus-fmt/money (\(name)), and install @haus-fmt/money with your package manager)"
    case "LatLng", "BBox":
        "unknown type \(name) (import it with: import @haus-fmt/geo (\(name)), and install @haus-fmt/geo with your package manager)"
    case "Uuid":
        "unknown type \(name) (import it with: import @haus-fmt/uuid (\(name)), and install @haus-fmt/uuid with your package manager)"
    case _ where timeTypes.contains(name):
        "unknown type \(name) (import it with: import std/time (\(name)))"
    default:
        "unknown type \(quoteForMessage(name))"
    }
}

/// A key as data writes it, for messages: bare if it can be, else quoted.
func quoteKey(_ key: String) -> String {
    if isIdentifier(key) { return key }
    var quoted: [UInt8] = []
    appendQuoted(key, to: &quoted)
    return quoteForMessage(String(decoding: quoted, as: UTF8.self))
}
