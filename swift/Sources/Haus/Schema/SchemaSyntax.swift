// The syntax tree of one schema file (spec §14, grammar.ebnf "Schema
// files"), and its parser: a recursive descent over the bytes with a
// cursor. Positions are byte offsets into the text.

/// A type expression as written. A class: the parser recurses once per level
/// of nesting, and passes references on.
final class TypeExpr {
    enum Form: Equatable {
        /// A named type applied to `args`: `Array Point`, `Int`.
        case name(String)
        /// A type parameter: `a`.
        case param(String)
        /// `{ … }` or `closed { … }`.
        case record
        /// `< … >` or `closed < … >`.
        case variant
    }

    let form: Form
    let pos: Int
    let closed: Bool
    var args: [TypeExpr] = []
    var fields: [FieldDef] = []
    var cases: [CaseDef] = []
    /// `...Name`, with how many own fields or cases come before each.
    var spreads: [SpreadDef] = []

    init(_ form: Form, pos: Int, closed: Bool = false) {
        self.form = form
        self.pos = pos
        self.closed = closed
    }

    /// The name of a named type, or nil.
    var name: String? {
        if case .name(let n) = form { return n }
        return nil
    }

    /// The type expressions directly inside: arguments, field types, payloads.
    var children: [TypeExpr] { args + fields.map(\.type) + cases.flatMap(\.payload) }

    /// Calls `body` on this expression and every one inside it, outermost first.
    func walk(_ body: (TypeExpr) -> Void) {
        body(self)
        for child in children { child.walk(body) }
    }

    /// Drops the attributes of the expression and those inside it, as if none were written.
    func dropAttributes() {
        fields = fields.map { FieldDef(key: $0.key, optional: $0.optional, type: $0.type, pos: $0.pos, attrs: []) }
        cases = cases.map { CaseDef(tag: $0.tag, payload: $0.payload, pos: $0.pos, attrs: []) }
        children.forEach { $0.dropAttributes() }
    }
}

struct FieldDef {
    let key: String
    let optional: Bool
    let type: TypeExpr
    let pos: Int
    let attrs: [Attribute]
}

struct CaseDef {
    let tag: String
    /// `Tag A B`: positional; `Tag { … }`: one record.
    let payload: [TypeExpr]
    let pos: Int
    let attrs: [Attribute]
}

struct SpreadDef {
    let name: String
    /// The own fields or cases before it.
    let at: Int
    let pos: Int
    /// Rejected: a spread has no attributes.
    let attrs: [Attribute]
}

/// `@name` or `@name(value, …)` (spec §14).
struct Attribute {
    let name: String
    let args: [HausValue]
    let pos: Int
}

struct TypeDef {
    let name: String
    let params: [String]
    let type: TypeExpr
    let pos: Int
    /// The `//` lines directly above.
    var doc = ""
    var attrs: [Attribute]
}

struct NameAt {
    let name: String
    let pos: Int
}

struct ImportDecl {
    let module: String
    let names: [NameAt]
    let pos: Int
}

struct SchemaFile {
    var imports: [ImportDecl] = []
    var types: [TypeDef] = []
    var warnings: [SchemaFailure] = []

    /// The file without attributes, as if none were written: decoding is the same (spec §15).
    func withoutAttributes() -> SchemaFile {
        var f = self
        f.types = types.map { d in
            var d = d
            d.attrs = []
            d.type.dropAttributes()
            return d
        }
        f.warnings = []
        return f
    }
}

/// A mistake at a byte offset of a schema file.
struct SchemaFailure: Error {
    let pos: Int
    let code: HausError.Code
    let message: String

    init(_ pos: Int, _ code: HausError.Code, _ message: String) {
        self.pos = pos
        self.code = code
        self.message = message
    }
}

/// The deepest nesting of type expressions the parser reads (`type-too-deep`).
let maxTypeNesting = 128

/// The keywords, which are no type parameters.
let schemaKeywords: Set<String> = ["type", "import", "closed"]

/// Parses a schema file and checks what the grammar allows but the spec
/// doesn't (§14). Spreads, names and arities need the other files and are
/// checked when the schema is resolved.
func parseSchemaFile(_ text: [UInt8]) throws(SchemaFailure) -> SchemaFile {
    if let bad = text.withUnsafeBufferPointer(firstInvalidUTF8) {
        throw SchemaFailure(bad, .invalidUtf8, "invalid UTF-8")
    }
    var p = SchemaParser(text)
    if text.starts(with: byteOrderMark) { p.pos = byteOrderMark.count }
    var file = try p.file()
    file.warnings = try checkSchemaFile(file) + deprecatedUses(file)
    file.types = file.types.map { d in
        var d = d
        d.doc = docComment(text, d.attrs.first?.pos ?? d.pos)
        return d
    }
    return file
}

struct SchemaParser {
    let s: [UInt8]
    var pos = 0
    var depth = 0

    init(_ s: [UInt8]) { self.s = s }

    func byte(_ i: Int) -> UInt8? { i < s.count ? s[i] : nil }

    func hasPrefix(_ prefix: String, at i: Int) -> Bool { s[min(i, s.count)...].starts(with: prefix.utf8) }

    func text(_ from: Int, _ to: Int) -> String { String(decoding: s[from..<to], as: UTF8.self) }

    /// The end of the word (`[A-Za-z0-9_]*`) at `i`.
    func wordEnd(_ i: Int) -> Int {
        var j = i
        while let c = byte(j), classOf(c).contains(.ident) { j += 1 }
        return j
    }

    func peekWord() -> String { text(pos, wordEnd(pos)) }

    /// What stands at `i`, for messages.
    func found(_ i: Int) -> String {
        guard i < s.count else { return "end of file" }
        let end = wordEnd(i)
        if end > i { return quoteForMessage(text(i, end)) }
        return s.withUnsafeBufferPointer { describeCharacter(at: i, in: $0) }
    }

    @inline(never)
    func expected(_ what: String) -> SchemaFailure {
        // A '/' that doesn't start a comment, where whitespace may be: as in data (§14).
        if byte(pos) == ASCII.slash {
            return SchemaFailure(pos, .straySlash, "unexpected '/' (comments are // or /* */)")
        }
        return SchemaFailure(pos, .schemaSyntax, "expected \(what), found \(found(pos))")
    }

    /// The error for a raw control or bidirectional character at `i` in a
    /// comment (spec §4), or nil.
    func rawCharacter(_ i: Int) -> SchemaFailure? {
        switch s[i] {
        case ASCII.tab, ASCII.lf: return nil
        // Inside a character: its first byte was looked at.
        case let c where isContinuation(c): return nil
        case ASCII.cr:
            return byte(i + 1) == ASCII.lf
                ? nil : SchemaFailure(i, .loneCarriageReturn, "a carriage return not followed by a line feed")
        default:
            let (character, name) = s.withUnsafeBufferPointer { b in
                (special(at: i, in: b), describeCharacter(at: i, in: b))
            }
            switch character {
            case .control, .c1:
                return SchemaFailure(i, .controlCharacter, "a raw control character, \(name), in a comment")
            case .bidi:
                return SchemaFailure(i, .bidiControl, "a raw bidirectional control character, \(name), in a comment")
            default: return nil
            }
        }
    }

    /// Skips whitespace and comments, as in data files (grammar "ws").
    mutating func ws() throws(SchemaFailure) {
        while let c = byte(pos) {
            switch c {
            case ASCII.space, ASCII.tab, ASCII.lf:
                pos += 1
            case ASCII.cr:
                guard byte(pos + 1) == ASCII.lf else {
                    throw SchemaFailure(pos, .loneCarriageReturn, "a carriage return not followed by a line feed")
                }
                pos += 2
            case ASCII.slash where byte(pos + 1) == ASCII.slash:
                pos = try lineComment(pos)
            case ASCII.slash where byte(pos + 1) == ASCII.star:
                pos = try blockComment(pos)
            default:
                return
            }
        }
    }

    func lineComment(_ start: Int) throws(SchemaFailure) -> Int {
        var i = start + 2
        while let c = byte(i), c != ASCII.lf, !(c == ASCII.cr && byte(i + 1) == ASCII.lf) {
            if c < 0x20 || c >= 0x7F, let failure = rawCharacter(i) { throw failure }
            i += 1
        }
        return i
    }

    func blockComment(_ start: Int) throws(SchemaFailure) -> Int {
        var i = start
        var depth = 0
        repeat {
            guard i < s.count else {
                throw SchemaFailure(start, .unterminatedComment, "a /* comment that is never closed")
            }
            if hasPrefix("/*", at: i) {
                depth += 1
                i += 2
            } else if hasPrefix("*/", at: i) {
                depth -= 1
                i += 2
            } else {
                if s[i] < 0x20 || s[i] >= 0x7F, let failure = rawCharacter(i) { throw failure }
                i += 1
            }
        } while depth > 0
        return i
    }

    /// Reads a word whose first byte satisfies `first`, then whitespace; nil if none is here.
    mutating func word(_ first: (UInt8) -> Bool) throws(SchemaFailure) -> String? {
        guard let c = byte(pos), first(c) else { return nil }
        let w = peekWord()
        pos += w.utf8.count
        try ws()
        return w
    }

    mutating func upper(_ what: String) throws(SchemaFailure) -> NameAt {
        let at = pos
        guard let w = try word(isUpper) else { throw expected(what) }
        return NameAt(name: w, pos: at)
    }

    /// Reads the keyword `w` if it is next.
    mutating func keyword(_ w: String) throws(SchemaFailure) -> Bool {
        guard peekWord() == w else { return false }
        pos += w.utf8.count
        try ws()
        return true
    }

    /// Reads the symbol `sym` if it is next.
    mutating func symbol(_ sym: String) throws(SchemaFailure) -> Bool {
        guard hasPrefix(sym, at: pos) else { return false }
        pos += sym.utf8.count
        try ws()
        return true
    }

    mutating func need(_ sym: String) throws(SchemaFailure) {
        guard try symbol(sym) else { throw expected("'\(sym)'") }
    }

    /// Whether a lowercase word that can be a type parameter is here.
    func atParam() -> Bool {
        guard let c = byte(pos), isLower(c) || c == ASCII.underscore else { return false }
        return !schemaKeywords.contains(peekWord())
    }

    // ── structure ───────────────────────────────────────────────

    mutating func file() throws(SchemaFailure) -> SchemaFile {
        var f = SchemaFile()
        try ws()
        while pos < s.count {
            if peekWord() == "import" {
                f.imports.append(try importDecl())
            } else {
                f.types.append(try typeDef())
            }
        }
        return f
    }

    static let moduleBytes = Set("_.-/@~".utf8)

    mutating func importDecl() throws(SchemaFailure) -> ImportDecl {
        let at = pos
        _ = try keyword("import")
        let start = pos
        let noModule = "a module (std/time, @org/name, ./file)"
        if hasPrefix("std/", at: pos) {
            pos += 4
            guard let c = byte(pos), isLower(c) || c == ASCII.underscore else { throw expected(noModule) }
            pos = wordEnd(pos)
        } else if let c = byte(pos), c == UInt8(ascii: "@") || c == ASCII.dot {
            pos += 1
            while let c = byte(pos), classOf(c).contains(.ident) || Self.moduleBytes.contains(c) { pos += 1 }
            if pos == start + 1 {
                pos = start
                throw expected(noModule)
            }
        } else {
            throw expected(noModule)
        }
        let module = text(start, pos)
        try ws()
        try need("(")
        var names: [NameAt] = []
        while let c = byte(pos), isUpper(c) {
            names.append(try upper("a type name"))
            guard try symbol(",") else { break }
        }
        try need(")")
        return ImportDecl(module: module, names: names, pos: at)
    }

    mutating func typeDef() throws(SchemaFailure) -> TypeDef {
        let attrs = try attributes()
        guard try keyword("type") else {
            throw expected(attrs.isEmpty ? "'type' or 'import'" : "'type' after the attributes")
        }
        let name = try upper("a type name")
        var params: [String] = []
        while atParam() {
            params.append(try word { _ in true }!)
        }
        try need("=")
        return TypeDef(name: name.name, params: params, type: try type(), pos: name.pos, attrs: attrs)
    }

    /// The attributes before a type, field or tag.
    mutating func attributes() throws(SchemaFailure) -> [Attribute] {
        var attrs: [Attribute] = []
        while byte(pos) == UInt8(ascii: "@") { attrs.append(try attribute()) }
        return attrs
    }

    /// `@name` or `@name(value, …)`, whose arguments are haus values read by
    /// the data parser.
    mutating func attribute() throws(SchemaFailure) -> Attribute {
        let at = pos
        pos += 1
        guard let c = byte(pos), isLower(c) || c == ASCII.underscore else {
            throw expected("an attribute name after '@': @deprecated")
        }
        let name = peekWord()
        pos += name.utf8.count
        if byte(pos) == ASCII.openParen {
            let open = pos
            guard let end = closingParen(s, open) else { throw unclosedArguments(open, name) }
            let values = try attributeValues(open + 1, end, name)
            if values.isEmpty {
                throw SchemaFailure(open, .attributeArguments, "empty parentheses: write @\(name) without them")
            }
            pos = end + 1
            try ws()
            return Attribute(name: name, args: values, pos: at)
        }
        try ws()
        if byte(pos) == ASCII.openParen {
            throw SchemaFailure(pos, .attributeSpace, "expected '(' right after the attribute's name, without a space")
        }
        return Attribute(name: name, args: [], pos: at)
    }

    /// The values of the text from `from` to `to`, read as data within the
    /// file: a byte order mark is a mistake and `#haus` no version directive.
    func attributeValues(_ from: Int, _ to: Int, _ name: String) throws(SchemaFailure) -> [HausValue] {
        do {
            return try parseValues(Array(s[from..<to]))
        } catch {
            throw dataError(error, from, "in the arguments of @\(name)")
        }
    }

    /// The error of attribute arguments whose `(` at `open` has no `)`: what
    /// reading them value by value finds first, as for any arguments.
    func unclosedArguments(_ open: Int, _ name: String) -> SchemaFailure {
        let values: [HausValue]
        do {
            values = try attributeValues(open + 1, s.count, name)
        } catch {
            return error
        }
        let inner = s[(open + 1)...]
        let trimmed = inner.reversed().drop { [ASCII.space, ASCII.tab, ASCII.cr, ASCII.lf].contains($0) }
        if values.isEmpty || trimmed.first == ASCII.comma {
            return SchemaFailure(open, .unclosedBracket, "unclosed '(' of an attribute")
        }
        return SchemaFailure(s.count, .missingComma, "expected ',' or ')' in the attribute's arguments")
    }

    /// An error of the data parser, in text that starts at `base`, at its place in the file.
    func dataError(_ e: HausError, _ base: Int, _ place: String) -> SchemaFailure {
        let at = e.position.map { offset(from: base, line: $0.line, column: $0.column) } ?? base
        return SchemaFailure(at, e.code, "\(place): \(e.message)")
    }

    /// The byte offset of a 1-based line and column (in code points) of the text that starts at `base`.
    func offset(from base: Int, line: Int, column: Int) -> Int {
        var i = base
        var l = 1
        while l < line && i < s.count {
            if s[i] == ASCII.lf { l += 1 }
            i += 1
        }
        for _ in 1..<max(column, 1) where i < s.count {
            i += 1
            while i < s.count && isContinuation(s[i]) { i += 1 }
        }
        return i
    }

    // ── types ───────────────────────────────────────────────────
    //
    // Type expressions nest, and their functions recurse once per level.
    // A debug build gives a function a stack slot for every temporary, so
    // these functions hold little more than their calls; what they read is
    // in functions of their own.

    /// Starts a nested type expression at `at`.
    @inline(never)
    mutating func enter(_ at: Int) throws(SchemaFailure) {
        depth += 1
        if depth > maxTypeNesting {
            throw SchemaFailure(at, .typeTooDeep, "types nested deeper than \(maxTypeNesting) levels")
        }
    }

    /// `Name atom+ | atom`. Only parentheses, records and variants count as
    /// a level of nesting, as in every binding.
    mutating func type() throws(SchemaFailure) -> TypeExpr {
        let named = byte(pos).map(isUpper) ?? false
        guard let t = try atom() else { throw expected("a type") }
        if named {
            while let a = try atom() { t.args.append(a) }
        }
        return t
    }

    /// What starts an atom.
    enum AtomStart {
        /// A name or a parameter, read.
        case leaf(TypeExpr)
        case parens
        case record(closed: Bool)
        case variant(closed: Bool)
    }

    /// An atom, or nil if none starts here.
    mutating func atom() throws(SchemaFailure) -> TypeExpr? {
        switch try atomStart() {
        case .leaf(let t)?: t
        case .parens?: try parenthesized()
        case .record(let closed)?: try record(closed: closed)
        case .variant(let closed)?: try variant(closed: closed)
        case nil: nil
        }
    }

    /// What starts an atom here, after the keyword `closed`; nil if no atom does.
    @inline(never)
    mutating func atomStart() throws(SchemaFailure) -> AtomStart? {
        guard let c = byte(pos) else { return nil }
        let at = pos
        switch c {
        case ASCII.openParen: return .parens
        case ASCII.openBrace: return .record(closed: false)
        case UInt8(ascii: "<"): return .variant(closed: false)
        case _ where isUpper(c):
            let name = try upper("a type name")
            return .leaf(TypeExpr(.name(name.name), pos: name.pos))
        case _ where isLower(c) || c == ASCII.underscore:
            let w = peekWord()
            if w == "closed" {
                _ = try keyword("closed")
                switch byte(pos) {
                case ASCII.openBrace: return .record(closed: true)
                case UInt8(ascii: "<"): return .variant(closed: true)
                default: throw expected("'{' or '<' after closed")
                }
            }
            if schemaKeywords.contains(w) { return nil }
            pos += w.utf8.count
            try ws()
            return .leaf(TypeExpr(.param(w), pos: at))
        default:
            return nil
        }
    }

    /// `( type )`.
    mutating func parenthesized() throws(SchemaFailure) -> TypeExpr {
        try enter(pos)
        _ = try symbol("(")
        let t = try type()
        try need(")")
        depth -= 1
        return t
    }

    /// `...Name` (a lowercase name is read too, for the checks to reject).
    @inline(never)
    mutating func spread(at: Int, _ attrs: [Attribute]) throws(SchemaFailure) -> SpreadDef {
        pos += 3
        try ws()
        let start = pos
        guard let c = byte(pos), isUpper(c) || isLower(c) || c == ASCII.underscore else {
            throw expected("a type name after '...': ...UserEvent")
        }
        let name = peekWord()
        pos += name.utf8.count
        try ws()
        return SpreadDef(name: name, at: at, pos: start, attrs: attrs)
    }

    mutating func record(closed: Bool) throws(SchemaFailure) -> TypeExpr {
        let t = TypeExpr(.record, pos: pos, closed: closed)
        try enter(pos)
        try need("{")
        if try !symbol("}") {
            repeat { try recordEntry(t) } while try another(",", closer: "}", trailing: true)
        }
        depth -= 1
        return t
    }

    /// Whether another entry comes: after `sep`, unless `closer` follows it
    /// (with `trailing`); otherwise `closer` must come.
    @inline(never)
    mutating func another(_ sep: String, closer: String, trailing: Bool) throws(SchemaFailure) -> Bool {
        if try symbol(sep) {
            guard trailing else { return true }
            return try !symbol(closer)
        }
        try need(closer)
        return false
    }

    /// A field or spread of the record `t`, with its attributes.
    mutating func recordEntry(_ t: TypeExpr) throws(SchemaFailure) {
        let attrs = try attributes()
        if hasPrefix("...", at: pos) {
            t.spreads.append(try spread(at: t.fields.count, attrs))
            return
        }
        let (key, at, optional) = try fieldName(attrs)
        t.fields.append(FieldDef(key: key, optional: optional, type: try type(), pos: at, attrs: attrs))
    }

    /// A field's key, where it is, and whether it is optional, up to its `:`.
    @inline(never)
    mutating func fieldName(_ attrs: [Attribute]) throws(SchemaFailure) -> (String, Int, Bool) {
        let at = pos
        let key: String
        switch byte(pos) {
        case let c? where isLower(c) || c == ASCII.underscore:
            key = peekWord()
            pos += key.utf8.count
            try ws()
        case ASCII.quote:
            key = try quotedKey()
        default:
            throw expected(attrs.isEmpty ? "a field name" : "a field after the attributes")
        }
        let optional = try symbol("?")
        try need(":")
        return (key, at, optional)
    }

    mutating func variant(closed: Bool) throws(SchemaFailure) -> TypeExpr {
        let t = TypeExpr(.variant, pos: pos, closed: closed)
        try enter(pos)
        try need("<")
        _ = try symbol("|")
        if try !symbol(">") {
            repeat { try variantEntry(t) } while try another("|", closer: ">", trailing: false)
        }
        depth -= 1
        return t
    }

    /// A case or spread of the variant `t`, with its attributes.
    mutating func variantEntry(_ t: TypeExpr) throws(SchemaFailure) {
        let attrs = try attributes()
        if hasPrefix("...", at: pos) {
            t.spreads.append(try spread(at: t.cases.count, attrs))
            return
        }
        guard let c = byte(pos), isUpper(c) else {
            throw expected(attrs.isEmpty ? "a tag" : "a tag after the attributes")
        }
        let tag = try upper("a tag")
        var payload: [TypeExpr] = []
        while let a = try atom() { payload.append(a) }
        t.cases.append(CaseDef(tag: tag.name, payload: payload, pos: tag.pos, attrs: attrs))
    }

    /// A `"…"` key: the data grammar's basic string.
    mutating func quotedKey() throws(SchemaFailure) -> String {
        let start = pos
        // `"""` is the key "" and a '"' that no rule takes: the grammar has no block strings.
        if hasPrefix(#"""""#, at: start) {
            pos = start + 2
            return ""
        }
        var i = start + 1
        while let c = byte(i), c != ASCII.quote, c != ASCII.lf {
            i += c == ASCII.backslash ? 2 : 1
        }
        // The string up to its closing '"', or to the line break or end where
        // it stops, which the data parser reports as in data.
        let value: HausValue
        do {
            value = try parse(bytes: s[start..<min(i + 1, s.count)])
        } catch {
            throw dataError(error, start, "in a field name")
        }
        pos = i + 1
        try ws()
        guard case .string(let key) = value else { return "" }
        return key
    }
}

/// Parses the arguments of an attribute: values within the file, where a
/// byte order mark is a mistake and `#haus` no version directive.
func parseValues(_ text: [UInt8]) throws(HausError) -> [HausValue] {
    try text.withUnsafeBufferPointer { (b) throws(HausError) in
        var p = Parser(b, limits: Limits(), keep: false)
        p.fileStart = false
        return try p.file().values
    }
}

/// The offset of the `)` that matches the `(` at `s[i]`, skipping strings,
/// comments and nested brackets, or nil.
func closingParen(_ s: [UInt8], _ i: Int) -> Int? {
    func at(_ k: Int, _ prefix: String) -> Bool { s[min(k, s.count)...].starts(with: prefix.utf8) }
    var i = i
    var depth = 0
    while i < s.count {
        let c = s[i]
        switch c {
        case ASCII.openParen, ASCII.openBracket, ASCII.openBrace:
            depth += 1
            i += 1
        case ASCII.closeParen, ASCII.closeBracket, ASCII.closeBrace:
            depth -= 1
            if depth == 0 { return c == ASCII.closeParen ? i : nil }
            if depth < 0 { return nil }
            i += 1
        case ASCII.quote where at(i, #"""""#):
            var j = i + 3
            while j < s.count && !at(j, #"""""#) { j += s[j] == ASCII.backslash ? 2 : 1 }
            guard j < s.count else { return nil }
            i = j + 3
        case ASCII.quote:
            var j = i + 1
            while j < s.count && s[j] != ASCII.quote && s[j] != ASCII.lf { j += s[j] == ASCII.backslash ? 2 : 1 }
            i = j + 1
        case ASCII.slash where at(i, "//"):
            guard let lf = s[i...].firstIndex(of: ASCII.lf) else { return nil }
            i = lf
        case ASCII.slash where at(i, "/*"):
            var nested = 0
            repeat {
                guard i < s.count else { return nil }
                if at(i, "/*") {
                    nested += 1
                    i += 2
                } else if at(i, "*/") {
                    nested -= 1
                    i += 2
                } else {
                    i += 1
                }
            } while nested > 0
        default:
            i += 1
        }
    }
    return nil
}

/// The `//` lines directly above the line of `pos`.
func docComment(_ s: [UInt8], _ pos: Int) -> String {
    guard let lineStart = s[..<pos].lastIndex(of: ASCII.lf) else { return "" }
    let lines = s[..<lineStart].split(separator: ASCII.lf, omittingEmptySubsequences: false).reversed()
        .map(trimmingBlanks)
        .prefix { $0.starts(with: "//".utf8) }
        .map { line in
            let text = line.dropFirst(2)
            return text.first == ASCII.space ? text.dropFirst() : text
        }
    return lines.reversed().map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
}

/// The bytes without spaces, tabs and carriage returns at either end.
func trimmingBlanks(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
    let blank = { (c: UInt8) in c == ASCII.space || c == ASCII.tab || c == ASCII.cr }
    guard let first = line.firstIndex(where: { !blank($0) }), let last = line.lastIndex(where: { !blank($0) }) else {
        return []
    }
    return line[first...last]
}
