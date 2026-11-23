//! Schema files (spec §14, grammar.ebnf "Schema files"), the prelude and the
//! standard module std/time (spec §13): reading a schema file, resolving its
//! types and checking it, with the error codes of spec §17.
//!
//! A schema file has the comments, whitespace and quoted strings of data
//! files, so its lexical mistakes have the data codes; it is read with the
//! data parser's lexer (parser.zig) and, for an attribute's arguments, its
//! value parser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const v = @import("value.zig");
const Value = v.Value;
const errors = @import("errors.zig");
const Code = errors.Code;
const Diagnostic = errors.Diagnostic;
const Error = errors.Error;
const Parser = @import("parser.zig").Parser;
pub const time = @import("time.zig");

/// Type expressions nest at most this deep (spec §14): each parenthesized
/// type, record and variant is a level.
pub const max_type_depth = 128;

/// The prelude's built-in types (spec §13, prelude.schema.haus) other than
/// its three variants (`Bool`, `Maybe`, `Result`, which are definitions).
pub const Builtin = enum {
    String,
    Bytes,
    Int,
    Int8,
    Int16,
    Int32,
    Int64,
    UInt8,
    UInt16,
    UInt32,
    UInt64,
    Float32,
    Float64,
    Decimal,
    Any,
    Array,
    Map,
    Secret,
    Stream,

    pub fn arity(b: Builtin) usize {
        return switch (b) {
            .Array, .Map, .Secret, .Stream => 1,
            else => 0,
        };
    }
};

/// The prelude's variants, written as definitions.
pub const Prelude = enum { none, Bool, Maybe, Result };

/// The prelude's definitions (prelude.schema.haus, "Core variants").
pub const prelude_text =
    \\type Bool       = closed < False | True >
    \\type Maybe a    = closed < None | Some a >
    \\type Result e a = closed < Err e | Ok a >
;

/// The types std/time defines (spec/std/time.schema.haus).
pub const std_time_types = [_][]const u8{ "Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone" };

/// `@org/name`: npm's rules for scoped names, in lowercase (spec §13.3).
pub fn isPackageName(name: []const u8) bool {
    return Reader.validPackageName(name);
}

/// Whether `name` is a prelude type (spec §14: schemas can't redefine one).
pub fn isPreludeName(name: []const u8) bool {
    if (std.meta.stringToEnum(Builtin, name) != null) return true;
    return std.mem.eql(u8, name, "Bool") or std.mem.eql(u8, name, "Maybe") or std.mem.eql(u8, name, "Result");
}

// ── the types of a schema ────────────────────────────────────

/// What a type name refers to.
pub const Ref = union(enum) {
    unresolved,
    builtin: Builtin,
    def: *Def,
    time: time.Kind,
};

/// A type expression: what a definition's body, a field's type or a case's
/// argument is written as.
pub const Expr = struct {
    /// Byte offset in the schema file.
    at: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        /// A type name, applied to its arguments (`Array Int`, `Pair a`).
        name: Name,
        /// A parameter of the definition: its index once resolved.
        param: Param,
        paren: *Expr,
        record: *RecordType,
        variant: *VariantType,
    };

    /// The expression without the parentheses around it.
    pub fn strip(e: *const Expr) *const Expr {
        var x = e;
        while (x.kind == .paren) x = x.kind.paren;
        return x;
    }
};

pub const Name = struct {
    name: []const u8,
    args: []const *Expr,
    ref: Ref = .unresolved,
};

pub const Param = struct {
    name: []const u8,
    at: u32 = 0,
    index: u16 = 0,
};

/// The arguments of a generic definition's instance: parameter i of the
/// definition stands for `args[i]`, read in `parent`.
pub const Env = struct {
    args: []const *Expr,
    parent: ?*const Env,
};

pub const Deprecation = struct {
    message: ?[]const u8 = null,
};

pub const Member = union(enum) {
    field: FieldDecl,
    spread: Spread,
};

pub const FieldDecl = struct {
    key: []const u8,
    at: u32,
    optional: bool,
    type: *Expr,
    deprecated: ?Deprecation,
};

pub const Spread = struct {
    name: []const u8,
    at: u32,
    ref: Ref = .unresolved,
};

/// A field of a record type, spreads expanded. A field copied from another
/// definition's instance reads its type in `env`; otherwise `env` is null
/// and the type is read where the record is.
pub const Field = struct {
    key: []const u8,
    at: u32,
    optional: bool,
    type: *Expr,
    env: ?*const Env,
    copied: bool,
    deprecated: ?Deprecation,
};

pub const RecordType = struct {
    closed: bool,
    members: []Member,
    /// After the checks: the fields, spreads expanded, and an index by key.
    fields: []const Field = &.{},
    index: std.StringHashMapUnmanaged(u32) = .empty,
    expanded: Expansion = .no,
    required: u32 = 0,
};

pub const Expansion = enum { no, busy, yes };

pub const Alt = union(enum) {
    case: CaseDecl,
    spread: Spread,
};

pub const CaseDecl = struct {
    tag: []const u8,
    at: u32,
    args: []const *Expr,
    deprecated: ?Deprecation,
};

/// How a case takes its payload (spec §15, "Variants").
pub const Form = enum { none, record, positional };

pub const Case = struct {
    tag: []const u8,
    at: u32,
    args: []const *Expr,
    env: ?*const Env,
    copied: bool,
    deprecated: ?Deprecation,
    form: Form = .none,
};

pub const VariantType = struct {
    closed: bool,
    alts: []Alt,
    cases: []const Case = &.{},
    index: std.StringHashMapUnmanaged(u32) = .empty,
    expanded: Expansion = .no,
};

pub const Def = struct {
    name: []const u8,
    at: u32,
    params: []const Param,
    body: *Expr,
    deprecated: ?Deprecation,
    prelude: Prelude = .none,
    /// The body is `Stream a` (spec §14: only the whole type of a definition).
    stream: bool = false,
    head: Visit = .unvisited,
    head_result: Head = .guarded,
    /// The type's id (spec §13.3, "Identity"): `@haus-fmt/money@1#Money`
    /// for a package's type, `prelude#Bool` for the prelude's, and the
    /// schema's `module` and the name otherwise (`local#Order`). Codecs
    /// (§13.4) are selected by it.
    id: []const u8 = "",
};

pub const Visit = enum { unvisited, visiting, done };

/// Where a type's value is read when its outermost names are unfolded
/// (spec §9 item 9): inside a record, array or payload (guarded), or a
/// parameter of the definition.
pub const Head = union(enum) {
    guarded,
    param: u16,
};

pub const Warning = struct {
    code: Code,
    line: u32,
    column: u32,
    offset: u32,
};

/// A schema file, read and checked. Its types are found with `get`. It
/// doesn't change once loaded, and may be used from several threads at once
/// (spec §9 item 12).
pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    defs: []const *Def,
    /// Every name in scope: the file's definitions, its imports, the prelude.
    scope: std.StringHashMapUnmanaged(Ref) = .empty,
    warnings: []const Warning = &.{},
    prelude_defs: [3]*Def = undefined,
    /// The names the file imports.
    imported: std.StringHashMapUnmanaged(void) = .empty,
    /// What its types' ids start with (`LoadOptions.module`).
    module: []const u8 = "local",

    pub fn deinit(s: *Schema) void {
        const gpa = s.arena.child_allocator;
        s.arena.deinit();
        gpa.destroy(s);
    }

    /// A definition of the file by name.
    /// A definition of the file by name: not a prelude type, and not an
    /// imported one (a file can't re-export what it imports, §13.3).
    pub fn get(s: *const Schema, name: []const u8) ?*Def {
        if (s.imported.contains(name)) return null;
        const r = s.scope.get(name) orelse return null;
        return switch (r) {
            .def => |d| if (d.prelude == .none) d else null,
            else => null,
        };
    }
};

/// Finds the modules a schema imports: packages and files (spec §13.3).
/// Without one, only std/time can be imported (`import-unavailable`).
pub const Resolver = struct {
    context: *anyopaque,
    /// Resolves `module` (as written: `@org/name`, `@org/name@1`, `./x`)
    /// imported by the file `from` (null for the root) to a loaded schema,
    /// or fails with a diagnostic.
    resolve: *const fn (context: *anyopaque, from: ?*const Schema, module: Module, diag: ?*Diagnostic) Error!*const Schema,
};

pub const Module = union(enum) {
    std: []const u8,
    package: struct { name: []const u8, major: ?[]const u8, text: []const u8 },
    file: []const u8,
};

pub const LoadOptions = struct {
    diagnostic: ?*Diagnostic = null,
    resolver: ?Resolver = null,
    /// What the ids of the file's types start with (spec §13.3,
    /// "Identity"): `@org/name@N` for a package's `schema.haus` (set by
    /// `packages.build`), and for a file outside a package an id of this
    /// binding's choosing: `local` for a schema loaded from text, and
    /// `./` and the file's path from the build's root for a file of a
    /// build. A file's id must not have the form of a package's (§13.3):
    /// give `@org/name@N` only for a package's own `schema.haus`.
    module: []const u8 = "local",
};

/// The id of a type of the module `module` (spec §13.3, "Identity").
pub fn typeId(arena: Allocator, module: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}#{s}", .{ module, name });
}

/// The ids of the prelude's and std/time's types, which take no arguments
/// (`prelude#Decimal`, `std/time#Instant`).
pub fn builtinId(b: Builtin) []const u8 {
    return switch (b) {
        inline else => |x| "prelude#" ++ @tagName(x),
    };
}

pub fn timeId(k: time.Kind) []const u8 {
    return switch (k) {
        inline else => |x| "std/time#" ++ @tagName(x),
    };
}

const Import = struct {
    module: Module,
    at: u32,
    module_at: u32,
    names: []const struct { name: []const u8, at: u32 },
};

// ── reading ──────────────────────────────────────────────────

const Reader = struct {
    p: Parser,
    arena: Allocator,
    level: u32 = 0,
    defs: std.ArrayList(*Def) = .empty,
    imports: std.ArrayList(Import) = .empty,
    warnings: *std.ArrayList(Warning),

    fn fail(r: *Reader, code: Code, at: usize, comptime fmt: []const u8, args: anytype) Error {
        return r.p.fail(code, at, fmt, args);
    }

    /// The word (identifier characters) at `at`.
    fn wordAt(r: *const Reader, at: usize) []const u8 {
        var i = at;
        while (i < r.p.end and v.isIdentChar(r.p.text[i])) i += 1;
        return r.p.text[at..i];
    }

    /// What is at `at`, for a message: a word, a character or the end.
    fn found(r: *const Reader, at: usize, buf: []u8) []const u8 {
        const w = r.wordAt(at);
        if (w.len > 0) return errors.quoteText(buf, w);
        return r.p.found(at, buf);
    }

    fn syntax(r: *Reader, comptime what: []const u8) Error {
        var buf: [64]u8 = undefined;
        return r.fail(.@"schema-syntax", r.p.pos, "expected " ++ what ++ ", found {s}", .{r.found(r.p.pos, &buf)});
    }

    fn ws(r: *Reader) Error!void {
        try r.p.skipWs();
    }

    fn eof(r: *const Reader) bool {
        return r.p.pos >= r.p.end;
    }

    fn peek(r: *const Reader) u8 {
        return r.p.text[r.p.pos];
    }

    fn here(r: *const Reader) u32 {
        return @intCast(r.p.pos);
    }

    fn newExpr(r: *Reader, offset: u32, kind: Expr.Kind) Error!*Expr {
        const e = try r.arena.create(Expr);
        e.* = .{ .at = offset, .kind = kind };
        return e;
    }

    // ── file ─────────────────────────────────────────────────

    fn file(r: *Reader) Error!void {
        if (r.p.startsWith(r.p.pos, "\xEF\xBB\xBF")) r.p.pos += 3;
        try r.ws();
        while (!r.eof()) {
            const w = r.wordAt(r.p.pos);
            if (r.peek() == '@') {
                const attrs = try r.attributes(.definition);
                if (!std.mem.eql(u8, r.wordAt(r.p.pos), "type")) {
                    return r.syntax("a type definition after the attribute (attributes go before a type, a field or a tag)");
                }
                try r.typedef(attrs);
            } else if (std.mem.eql(u8, w, "type")) {
                try r.typedef(null);
            } else if (std.mem.eql(u8, w, "import")) {
                try r.import();
            } else return r.syntax("'type' or 'import'");
            try r.ws();
        }
    }

    // ── attributes ───────────────────────────────────────────

    const Place = enum { definition, member };

    const Attrs = struct {
        deprecated: ?Deprecation = null,
        first: u32,
    };

    /// `@name` or `@name(values)`, any number of them, each followed by
    /// whitespace. Returns null when there is none.
    fn attributes(r: *Reader, _: Place) Error!?Attrs {
        if (r.eof() or r.peek() != '@') return null;
        var attrs: Attrs = .{ .first = r.here() };
        while (!r.eof() and r.peek() == '@') {
            const start = r.p.pos;
            r.p.pos += 1;
            if (r.eof() or !v.isKeyStart(r.peek())) return r.syntax("an attribute name after '@'");
            const name = r.wordAt(r.p.pos);
            r.p.pos += name.len;
            var args: ?[]const Value = null;
            if (!r.eof() and r.peek() == '(') {
                // `@foo()`: empty parentheses are no arguments (spec §14).
                const open = r.p.pos;
                r.p.pos += 1;
                try r.ws();
                if (!r.eof() and r.peek() == ')') {
                    return r.fail(.@"attribute-arguments", open, "empty parentheses after @{s}: write it without them", .{name});
                }
                r.p.pos = open;
                r.p.depth = 0;
                args = try r.p.payload();
            } else {
                const save = r.p.pos;
                try r.ws();
                if (!r.eof() and r.peek() == '(') {
                    return r.fail(.@"attribute-space", r.p.pos, "a space between @{s} and its '(': write the parenthesis right after the name", .{name});
                }
                r.p.pos = save;
            }
            if (std.mem.eql(u8, name, "deprecated")) {
                if (attrs.deprecated != null) return r.fail(.@"attribute-twice", start, "@deprecated twice", .{});
                var dep: Deprecation = .{};
                if (args) |a| {
                    if (a.len != 1 or a[0] != .string) {
                        return r.fail(.@"attribute-arguments", start, "@deprecated takes nothing or one string", .{});
                    }
                    dep.message = a[0].string;
                }
                attrs.deprecated = dep;
            } else {
                // An attribute this version doesn't define: accepted, with a warning (spec §14).
                try r.warn(.@"unknown-attribute", start);
            }
            try r.ws();
        }
        return attrs;
    }

    fn warn(r: *Reader, code: Code, offset: usize) Error!void {
        const pos = r.p.position(offset);
        try r.warnings.append(r.arena, .{ .code = code, .line = pos.line, .column = pos.column, .offset = @intCast(offset) });
    }

    // ── imports ──────────────────────────────────────────────

    fn isSegmentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_';
    }

    fn validSegment(s: []const u8) bool {
        if (s.len == 0) return false;
        const c = s[0];
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))) return false;
        for (s) |x| if (!isSegmentChar(x)) return false;
        return !std.mem.eql(u8, s, "node_modules");
    }

    /// `@org/name`: npm's rules for scoped names, in lowercase (spec §13.3).
    pub fn validPackageName(name: []const u8) bool {
        if (name.len < 4 or name.len > 214 or name[0] != '@') return false;
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return false;
        return validSegment(name[1..slash]) and validSegment(name[slash + 1 ..]);
    }

    /// A file path of an import (grammar.ebnf, `path`): `./` or one or
    /// more `../`, then names `[A-Za-z0-9_-][A-Za-z0-9_.-]*` separated by
    /// `/`. So no `.` or `..` name after the start, no empty name and no
    /// `/` at the end.
    pub fn validPath(path: []const u8) bool {
        var rest = path;
        if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else {
            while (std.mem.startsWith(u8, rest, "../")) rest = rest[3..];
            if (rest.len == path.len) return false;
        }
        var names = std.mem.splitScalar(u8, rest, '/');
        while (names.next()) |name| {
            if (name.len == 0) return false;
            const c = name[0];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
            for (name) |x| if (!(std.ascii.isAlphanumeric(x) or x == '_' or x == '-' or x == '.')) return false;
        }
        return true;
    }

    pub fn validMajor(s: []const u8) bool {
        if (s.len == 0) return false;
        if (s[0] == '0') return s.len == 1;
        for (s) |c| if (c < '0' or c > '9') return false;
        return true;
    }

    fn import(r: *Reader) Error!void {
        const start = r.here();
        r.p.pos += "import".len;
        try r.ws();
        const module_at = r.here();
        var buf: [64]u8 = undefined;
        const module: Module = blk: {
            if (r.p.startsWith(r.p.pos, "std/")) {
                const name = if (r.p.pos + 4 < r.p.end and v.isKeyStart(r.p.text[r.p.pos + 4])) r.wordAt(r.p.pos + 4) else "";
                if (name.len == 0) return r.fail(.@"schema-syntax", module_at, "expected a module like std/time, @org/name or ./file, found 'std'", .{});
                r.p.pos += 4 + name.len;
                break :blk .{ .std = name };
            }
            if (!r.eof() and r.peek() == '@') {
                var i = r.p.pos + 1;
                // The package and its version: everything up to whitespace or '('.
                while (i < r.p.end and r.p.text[i] != ' ' and r.p.text[i] != '\t' and r.p.text[i] != '\n' and r.p.text[i] != '\r' and r.p.text[i] != '(') i += 1;
                const token = r.p.text[r.p.pos..i];
                r.p.pos = i;
                const name, const major: ?[]const u8 = if (std.mem.indexOfScalarPos(u8, token, 1, '@')) |k| .{ token[0..k], token[k + 1 ..] } else .{ token, null };
                if (!validPackageName(name)) {
                    return r.fail(.@"unknown-module", module_at, "unknown module {s}: a package is @org/name, in lowercase letters, digits, -, . and _ (not node_modules)", .{errors.quoteText(&buf, token)});
                }
                if (major) |m| if (!validMajor(m)) {
                    return r.fail(.@"import-version", module_at, "{s}: expected a major version after '@', like @acme/x@1", .{errors.quoteText(&buf, token)});
                };
                break :blk .{ .package = .{ .name = name, .major = major, .text = token } };
            }
            if (!r.eof() and r.peek() == '.') {
                var i = r.p.pos;
                while (i < r.p.end and (v.isIdentChar(r.p.text[i]) or r.p.text[i] == '.' or r.p.text[i] == '/' or r.p.text[i] == '-')) i += 1;
                const path = r.p.text[r.p.pos..i];
                r.p.pos = i;
                if (!std.mem.startsWith(u8, path, "./") and !std.mem.startsWith(u8, path, "../")) {
                    return r.fail(.@"unknown-module", module_at, "unknown module {s}: import std/…, a package @org/name or a file ./name", .{errors.quoteText(&buf, path)});
                }
                if (!validPath(path)) {
                    return r.fail(.@"schema-syntax", module_at, "{s} is not a path: '..' only at its start, then names that start with a letter, digit, _ or -, and no '/' at its end", .{errors.quoteText(&buf, path)});
                }
                break :blk .{ .file = path };
            }
            return r.syntax("a module like std/time, @org/name or ./file");
        };
        try r.ws();
        if (r.eof() or r.peek() != '(') return r.syntax("'(' and the types to import");
        r.p.pos += 1;
        try r.ws();
        var names: std.ArrayList(@typeInfo(@FieldType(Import, "names")).pointer.child) = .empty;
        while (true) {
            if (r.eof()) return r.syntax("a type name or ')'");
            if (r.peek() == ')') break;
            if (!v.isTagStart(r.peek())) return r.syntax("a type name");
            const n = r.wordAt(r.p.pos);
            try names.append(r.arena, .{ .name = n, .at = r.here() });
            r.p.pos += n.len;
            try r.ws();
            if (r.eof()) return r.syntax("',' or ')'");
            if (r.peek() == ',') {
                r.p.pos += 1;
                try r.ws();
                continue;
            }
            if (r.peek() == ')') break;
            return r.syntax("',' or ')'");
        }
        r.p.pos += 1;
        try r.imports.append(r.arena, .{ .module = module, .at = start, .module_at = module_at, .names = names.items });
    }

    // ── definitions ──────────────────────────────────────────

    fn typedef(r: *Reader, attrs: ?Attrs) Error!void {
        const start = if (attrs) |a| a.first else r.here();
        _ = start;
        r.p.pos += "type".len;
        try r.ws();
        if (r.eof() or !v.isTagStart(r.peek())) return r.syntax("a type name");
        const name_at = r.here();
        const name = r.wordAt(r.p.pos);
        r.p.pos += name.len;
        var params: std.ArrayList(Param) = .empty;
        while (true) {
            const save = r.p.pos;
            try r.ws();
            if (r.eof() or !v.isKeyStart(r.peek())) {
                r.p.pos = save;
                break;
            }
            const w = r.wordAt(r.p.pos);
            if (isKeyword(w)) {
                r.p.pos = save;
                break;
            }
            try params.append(r.arena, .{ .name = w, .at = r.here() });
            r.p.pos += w.len;
        }
        try r.ws();
        if (r.eof() or r.peek() != '=') return r.syntax("'='");
        r.p.pos += 1;
        try r.ws();
        if (r.eof()) return r.syntax("a type");
        r.level = 0;
        const body = try r.typeExpr();
        const def = try r.arena.create(Def);
        def.* = .{
            .name = name,
            .at = name_at,
            .params = params.items,
            .body = body,
            .deprecated = if (attrs) |a| a.deprecated else null,
        };
        try r.defs.append(r.arena, def);
    }

    fn isKeyword(w: []const u8) bool {
        return std.mem.eql(u8, w, "type") or std.mem.eql(u8, w, "import") or std.mem.eql(u8, w, "closed");
    }

    /// Whether an atom starts at the position (for the arguments of an
    /// application or a case).
    fn atomStarts(r: *const Reader) bool {
        if (r.eof()) return false;
        const c = r.peek();
        if (c == '(' or c == '{' or c == '<' or v.isTagStart(c)) return true;
        if (v.isKeyStart(c)) {
            const w = r.wordAt(r.p.pos);
            return !std.mem.eql(u8, w, "type") and !std.mem.eql(u8, w, "import");
        }
        return false;
    }

    /// `type`: a name applied to atoms, or an atom.
    fn typeExpr(r: *Reader) Error!*Expr {
        if (!r.eof() and v.isTagStart(r.peek())) {
            const start = r.here();
            const name = r.wordAt(r.p.pos);
            r.p.pos += name.len;
            var args: std.ArrayList(*Expr) = .empty;
            try r.atoms(&args);
            return r.newExpr(start, .{ .name = .{ .name = name, .args = args.items } });
        }
        return r.atom();
    }

    /// `(ws atom)*`: the atoms that follow, stopping (and leaving the
    /// whitespace) before anything else.
    fn atoms(r: *Reader, list: *std.ArrayList(*Expr)) Error!void {
        while (true) {
            const save = r.p.pos;
            try r.ws();
            if (!r.atomStarts()) {
                r.p.pos = save;
                return;
            }
            try list.append(r.arena, try r.atom());
        }
    }

    fn enter(r: *Reader) Error!void {
        r.level += 1;
        if (r.level > max_type_depth) return r.fail(.@"type-too-deep", r.p.pos, "type expressions nested deeper than {d} levels", .{max_type_depth});
    }

    fn atom(r: *Reader) Error!*Expr {
        if (r.eof()) return r.syntax("a type");
        const start = r.here();
        const c = r.peek();
        switch (c) {
            '(' => {
                try r.enter();
                r.p.pos += 1;
                try r.ws();
                if (r.eof()) return r.syntax("a type");
                const inner = try r.typeExpr();
                try r.ws();
                if (r.eof() or r.peek() != ')') return r.syntax("')'");
                r.p.pos += 1;
                r.level -= 1;
                return r.newExpr(start, .{ .paren = inner });
            },
            '{' => return r.record(false, start),
            '<' => return r.variant(false, start),
            else => {},
        }
        if (v.isTagStart(c)) {
            const name = r.wordAt(r.p.pos);
            r.p.pos += name.len;
            return r.newExpr(start, .{ .name = .{ .name = name, .args = &.{} } });
        }
        if (v.isKeyStart(c)) {
            const w = r.wordAt(r.p.pos);
            if (std.mem.eql(u8, w, "closed")) {
                r.p.pos += w.len;
                try r.ws();
                if (!r.eof() and r.peek() == '{') return r.record(true, start);
                if (!r.eof() and r.peek() == '<') return r.variant(true, start);
                return r.syntax("'{{' or '<' after closed");
            }
            if (std.mem.eql(u8, w, "_")) {
                return r.fail(.@"underscore-type", start, "'_' is not a type: write < > for a variant with any tags, Any for any value, or a type parameter", .{});
            }
            if (std.mem.eql(u8, w, "type") or std.mem.eql(u8, w, "import")) return r.syntax("a type");
            r.p.pos += w.len;
            return r.newExpr(start, .{ .param = .{ .name = w } });
        }
        return r.syntax("a type");
    }

    fn spread(r: *Reader, attrs: ?Attrs) Error!Spread {
        if (attrs) |a| return r.fail(.@"attribute-on-spread", a.first, "an attribute on a spread: the fields and tags it copies keep their own attributes", .{});
        const start = r.here();
        r.p.pos += 3;
        if (!r.eof() and v.isTagStart(r.peek())) {
            const name = r.wordAt(r.p.pos);
            const name_at = r.here();
            r.p.pos += name.len;
            return .{ .name = name, .at = name_at };
        }
        if (!r.eof() and v.isKeyStart(r.peek())) {
            return r.fail(.@"row-parameter", start, "row parameters (...r) aren't supported; spread a named type instead: ...UserEvent", .{});
        }
        return r.syntax("a type name after '...'");
    }

    fn record(r: *Reader, closed: bool, start: u32) Error!*Expr {
        try r.enter();
        r.p.pos += 1;
        try r.ws();
        var members: std.ArrayList(Member) = .empty;
        while (true) {
            if (r.eof()) return r.syntax("a field name, ...Name or '}}'");
            if (r.peek() == '}') break;
            const attrs = try r.attributes(.member);
            if (r.p.startsWith(r.p.pos, "...")) {
                try members.append(r.arena, .{ .spread = try r.spread(attrs) });
            } else {
                if (r.eof()) return r.syntax("a field name, ...Name or '}}'");
                const key_at = r.here();
                const key: []const u8 = if (r.peek() == '"')
                    try r.p.basicString(.key)
                else if (v.isKeyStart(r.peek())) blk: {
                    const w = r.wordAt(r.p.pos);
                    r.p.pos += w.len;
                    break :blk w;
                } else return r.syntax("a field name, ...Name or '}}'");
                try r.ws();
                var optional = false;
                if (!r.eof() and r.peek() == '?') {
                    optional = true;
                    r.p.pos += 1;
                    try r.ws();
                }
                if (r.eof() or r.peek() != ':') return r.syntax("':' after the field name");
                r.p.pos += 1;
                try r.ws();
                if (r.eof()) return r.syntax("a type");
                const t = try r.typeExpr();
                try members.append(r.arena, .{ .field = .{
                    .key = key,
                    .at = key_at,
                    .optional = optional,
                    .type = t,
                    .deprecated = if (attrs) |a| a.deprecated else null,
                } });
            }
            try r.ws();
            if (r.eof()) return r.syntax("',' or '}}'");
            if (r.peek() == ',') {
                r.p.pos += 1;
                try r.ws();
                continue;
            }
            if (r.peek() == '}') break;
            return r.syntax("',' or '}}'");
        }
        r.p.pos += 1;
        r.level -= 1;
        const rec = try r.arena.create(RecordType);
        rec.* = .{ .closed = closed, .members = members.items };
        return r.newExpr(start, .{ .record = rec });
    }

    fn variant(r: *Reader, closed: bool, start: u32) Error!*Expr {
        try r.enter();
        r.p.pos += 1;
        try r.ws();
        if (!r.eof() and r.peek() == '|') {
            r.p.pos += 1;
            try r.ws();
        }
        var alts: std.ArrayList(Alt) = .empty;
        if (r.eof() or r.peek() != '>') {
            while (true) {
                const attrs = try r.attributes(.member);
                if (r.p.startsWith(r.p.pos, "...")) {
                    try alts.append(r.arena, .{ .spread = try r.spread(attrs) });
                } else {
                    if (r.eof() or !v.isTagStart(r.peek())) return r.syntax("a tag, ...Name or '>'");
                    const tag_at = r.here();
                    const tag = r.wordAt(r.p.pos);
                    r.p.pos += tag.len;
                    var args: std.ArrayList(*Expr) = .empty;
                    try r.atoms(&args);
                    try alts.append(r.arena, .{ .case = .{
                        .tag = tag,
                        .at = tag_at,
                        .args = args.items,
                        .deprecated = if (attrs) |a| a.deprecated else null,
                    } });
                }
                try r.ws();
                if (r.eof()) return r.syntax("'|' or '>'");
                if (r.peek() == '|') {
                    r.p.pos += 1;
                    try r.ws();
                    continue;
                }
                if (r.peek() == '>') break;
                return r.syntax("'|' or '>'");
            }
        }
        r.p.pos += 1;
        r.level -= 1;
        const vt = try r.arena.create(VariantType);
        vt.* = .{ .closed = closed, .alts = alts.items };
        return r.newExpr(start, .{ .variant = vt });
    }
};

// ── checking ─────────────────────────────────────────────────

const Checker = struct {
    arena: Allocator,
    gpa: Allocator,
    schema: *Schema,
    p: *Parser,
    warnings: *std.ArrayList(Warning),

    fn fail(c: *Checker, code: Code, at: usize, comptime fmt: []const u8, args: anytype) Error {
        return c.p.fail(code, at, fmt, args);
    }

    fn warn(c: *Checker, code: Code, offset: usize) Error!void {
        const pos = c.p.position(offset);
        try c.warnings.append(c.arena, .{ .code = code, .line = pos.line, .column = pos.column, .offset = @intCast(offset) });
    }

    // ── names ────────────────────────────────────────────────

    fn lookup(c: *Checker, name: []const u8) ?Ref {
        if (c.schema.scope.get(name)) |r| return r;
        if (std.meta.stringToEnum(Builtin, name)) |b| return .{ .builtin = b };
        return null;
    }

    fn resolveDef(c: *Checker, def: *Def) Error!void {
        // Parameters: each once, none starting with `_` (spec §14).
        for (def.params, 0..) |p, i| {
            if (p.name[0] == '_') return c.fail(.@"invalid-parameter", p.at, "type parameter {s} starts with '_'", .{p.name});
            for (def.params[0..i]) |q| if (std.mem.eql(u8, p.name, q.name)) {
                return c.fail(.@"invalid-parameter", p.at, "type parameter {s} declared twice", .{p.name});
            };
        }
        try c.resolve(def, def.body, true);
    }

    fn resolve(c: *Checker, def: *Def, e: *Expr, whole: bool) Error!void {
        switch (e.kind) {
            .paren => |inner| try c.resolve(def, inner, whole),
            .param => |*p| {
                for (def.params, 0..) |q, i| if (std.mem.eql(u8, p.name, q.name)) {
                    p.index = @intCast(i);
                    return;
                };
                var buf: [64]u8 = undefined;
                return c.fail(.@"unknown-parameter", e.at, "unknown type parameter {s}", .{errors.quoteText(&buf, p.name)});
            },
            .name => |*n| {
                var buf: [64]u8 = undefined;
                const ref = c.lookup(n.name) orelse return c.fail(.@"unknown-type", e.at, "unknown type {s}", .{errors.quoteText(&buf, n.name)});
                n.ref = ref;
                const want: usize = switch (ref) {
                    .builtin => |b| b.arity(),
                    .def => |d| d.params.len,
                    .time => 0,
                    .unresolved => unreachable,
                };
                if (n.args.len != want) {
                    return c.fail(.@"wrong-arity", e.at, "{s} needs {d} argument{s}, got {d}", .{ n.name, want, if (want == 1) "" else "s", n.args.len });
                }
                switch (ref) {
                    .builtin => |b| if (b == .Stream and !whole) {
                        return c.fail(.@"misplaced-stream", e.at, "Stream is only the whole type of a definition: use Array inside types", .{});
                    },
                    .def => |d| {
                        if (d.stream) return c.fail(.@"misplaced-stream", e.at, "{s} is a Stream, which is a whole file: it can't be used inside a type", .{d.name});
                        if (d.deprecated != null) try c.warn(.deprecated, e.at);
                    },
                    else => {},
                }
                for (n.args) |a| try c.resolve(def, a, false);
            },
            .record => |rec| {
                for (rec.members) |*m| switch (m.*) {
                    .field => |f| try c.resolve(def, f.type, false),
                    .spread => |*s| try c.resolveSpread(s),
                };
            },
            .variant => |vt| {
                if (vt.closed and vt.alts.len == 0) return c.fail(.@"closed-empty-variant", e.at, "closed < > accepts nothing: list its tags, or write < >", .{});
                for (vt.alts) |*a| switch (a.*) {
                    .case => |cd| for (cd.args) |x| try c.resolve(def, x, false),
                    .spread => |*s| try c.resolveSpread(s),
                };
            },
        }
    }

    fn resolveSpread(c: *Checker, s: *Spread) Error!void {
        var buf: [64]u8 = undefined;
        const ref = c.lookup(s.name) orelse return c.fail(.@"unknown-type", s.at, "unknown type {s}", .{errors.quoteText(&buf, s.name)});
        s.ref = ref;
        switch (ref) {
            .def => |d| {
                if (d.prelude != .none) return c.fail(.@"invalid-spread", s.at, "{s} is a prelude type, which can't be spread", .{s.name});
                if (d.params.len > 0) return c.fail(.@"invalid-spread", s.at, "{s} has parameters: only a named type without parameters can be spread", .{s.name});
                if (d.stream) return c.fail(.@"invalid-spread", s.at, "{s} is a Stream, which can't be spread", .{s.name});
                if (d.deprecated != null) try c.warn(.deprecated, s.at);
            },
            else => return c.fail(.@"invalid-spread", s.at, "{s} is not a named record or variant of this schema, so it can't be spread", .{s.name}),
        }
    }

    // ── spreads ──────────────────────────────────────────────

    /// The definitions a definition spreads, anywhere in its body: the
    /// spread's definition and every definition its name unfolds to (a
    /// spread of an alias copies the aliased type).
    fn spreadsOf(e: *const Expr, out: *std.ArrayList(*Def), gpa: Allocator, limit: usize) Allocator.Error!void {
        switch (e.kind) {
            .paren => |inner| try spreadsOf(inner, out, gpa, limit),
            .param => {},
            .name => |n| for (n.args) |a| try spreadsOf(a, out, gpa, limit),
            .record => |rec| for (rec.members) |m| switch (m) {
                .field => |f| try spreadsOf(f.type, out, gpa, limit),
                .spread => |s| try aliasChain(s.ref.def, out, gpa, limit),
            },
            .variant => |vt| for (vt.alts) |a| switch (a) {
                .case => |cd| for (cd.args) |x| try spreadsOf(x, out, gpa, limit),
                .spread => |s| try aliasChain(s.ref.def, out, gpa, limit),
            },
        }
    }

    fn aliasChain(d0: *Def, out: *std.ArrayList(*Def), gpa: Allocator, limit: usize) Allocator.Error!void {
        var d = d0;
        var steps: usize = 0;
        while (steps <= limit) : (steps += 1) {
            try out.append(gpa, d);
            const body = d.body.strip();
            if (body.kind != .name or body.kind.name.ref != .def) return;
            d = body.kind.name.ref.def;
            if (d.prelude != .none) return;
        }
    }

    /// `spread-cycle`: a definition that spreads itself, directly or not,
    /// however deep the spreads are written (spec §14).
    fn checkSpreadCycles(c: *Checker) Error!void {
        const defs = c.schema.defs;
        var state = try c.gpa.alloc(u8, defs.len);
        defer c.gpa.free(state);
        @memset(state, 0);
        var index: std.AutoHashMapUnmanaged(*Def, usize) = .empty;
        defer index.deinit(c.gpa);
        for (defs, 0..) |d, i| try index.put(c.gpa, d, i);
        var edges = try c.gpa.alloc(std.ArrayList(*Def), defs.len);
        defer {
            for (edges) |*l| l.deinit(c.gpa);
            c.gpa.free(edges);
        }
        for (defs, 0..) |d, i| {
            edges[i] = .empty;
            try spreadsOf(d.body, &edges[i], c.gpa, defs.len);
        }
        // Iterative DFS: 0 new, 1 on the stack, 2 done.
        const Frame = struct { node: usize, next: usize };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(c.gpa);
        for (0..defs.len) |root| {
            if (state[root] != 0) continue;
            state[root] = 1;
            try stack.append(c.gpa, .{ .node = root, .next = 0 });
            while (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top.next >= edges[top.node].items.len) {
                    state[top.node] = 2;
                    _ = stack.pop();
                    continue;
                }
                const target = edges[top.node].items[top.next];
                top.next += 1;
                const t = index.get(target) orelse continue;
                if (state[t] == 1) {
                    return c.fail(.@"spread-cycle", defs[t].at, "{s} spreads itself, directly or through other types", .{defs[t].name});
                }
                if (state[t] == 0) {
                    state[t] = 1;
                    try stack.append(c.gpa, .{ .node = t, .next = 0 });
                }
            }
        }
    }

    /// The record or variant a spread's definition is, its names unfolded.
    fn spreadTarget(c: *Checker, def: *Def) Error!struct { e: *Expr, env: ?*const Env } {
        var e: *Expr = def.body;
        var env: ?*const Env = null;
        var steps: usize = 0;
        while (true) : (steps += 1) {
            if (steps > c.schema.defs.len + 64) return .{ .e = e, .env = env };
            switch (e.kind) {
                .paren => |inner| e = inner,
                .param => |p| {
                    const en = env orelse return .{ .e = e, .env = env };
                    e = en.args[p.index];
                    env = en.parent;
                },
                .name => |n| switch (n.ref) {
                    .def => |d| {
                        if (d.prelude != .none or d.stream) return .{ .e = e, .env = env };
                        if (n.args.len > 0) {
                            const en = try c.arena.create(Env);
                            en.* = .{ .args = n.args, .parent = env };
                            env = en;
                        } else env = null;
                        e = d.body;
                    },
                    else => return .{ .e = e, .env = env },
                },
                .record, .variant => return .{ .e = e, .env = env },
            }
        }
    }

    fn expandRecord(c: *Checker, rec: *RecordType) Error!void {
        if (rec.expanded == .yes) return;
        rec.expanded = .busy;
        var fields: std.ArrayList(Field) = .empty;
        for (rec.members) |m| switch (m) {
            .field => |f| try fields.append(c.arena, .{
                .key = f.key,
                .at = f.at,
                .optional = f.optional,
                .type = f.type,
                .env = null,
                .copied = false,
                .deprecated = f.deprecated,
            }),
            .spread => |s| {
                const d = s.ref.def;
                const target = try c.spreadTarget(d);
                if (target.e.kind != .record) {
                    return c.fail(.@"invalid-spread", s.at, "{s} is not a record, so it can't be spread here", .{s.name});
                }
                const inner = target.e.kind.record;
                if (inner.expanded == .busy) return c.fail(.@"spread-cycle", s.at, "{s} spreads itself", .{s.name});
                try c.expandRecord(inner);
                for (inner.fields) |f| {
                    var copy = f;
                    if (!f.copied) copy.env = target.env;
                    copy.copied = true;
                    copy.at = s.at;
                    try fields.append(c.arena, copy);
                }
            },
        };
        rec.fields = fields.items;
        rec.index = .empty;
        var required: u32 = 0;
        for (rec.fields, 0..) |f, i| {
            const gop = try rec.index.getOrPut(c.arena, f.key);
            if (gop.found_existing) {
                var buf: [64]u8 = undefined;
                return c.fail(.@"duplicate-field", f.at, "field {s} listed twice", .{errors.quoteText(&buf, f.key)});
            }
            gop.value_ptr.* = @intCast(i);
            if (!f.optional) required += 1;
        }
        rec.required = required;
        rec.expanded = .yes;
    }

    fn expandVariant(c: *Checker, vt: *VariantType) Error!void {
        if (vt.expanded == .yes) return;
        vt.expanded = .busy;
        var cases: std.ArrayList(Case) = .empty;
        for (vt.alts) |a| switch (a) {
            .case => |cd| try cases.append(c.arena, .{
                .tag = cd.tag,
                .at = cd.at,
                .args = cd.args,
                .env = null,
                .copied = false,
                .deprecated = cd.deprecated,
            }),
            .spread => |s| {
                const d = s.ref.def;
                const target = try c.spreadTarget(d);
                if (target.e.kind != .variant) {
                    return c.fail(.@"invalid-spread", s.at, "{s} is not a variant, so it can't be spread here", .{s.name});
                }
                const inner = target.e.kind.variant;
                if (inner.expanded == .busy) return c.fail(.@"spread-cycle", s.at, "{s} spreads itself", .{s.name});
                try c.expandVariant(inner);
                for (inner.cases) |cs| {
                    var copy = cs;
                    if (!cs.copied) copy.env = target.env;
                    copy.copied = true;
                    copy.at = s.at;
                    try cases.append(c.arena, copy);
                }
            },
        };
        vt.cases = cases.items;
        vt.index = .empty;
        for (vt.cases, 0..) |cs, i| {
            const gop = try vt.index.getOrPut(c.arena, cs.tag);
            if (gop.found_existing) return c.fail(.@"duplicate-tag", cs.at, "tag {s} listed twice", .{cs.tag});
            gop.value_ptr.* = @intCast(i);
        }
        vt.expanded = .yes;
    }

    fn expandAll(c: *Checker, e: *Expr) Error!void {
        switch (e.kind) {
            .paren => |inner| try c.expandAll(inner),
            .param => {},
            .name => |n| for (n.args) |a| try c.expandAll(a),
            .record => |rec| {
                try c.expandRecord(rec);
                for (rec.members) |m| switch (m) {
                    .field => |f| try c.expandAll(f.type),
                    .spread => {},
                };
            },
            .variant => |vt| {
                try c.expandVariant(vt);
                for (vt.alts) |a| switch (a) {
                    .case => |cd| for (cd.args) |x| try c.expandAll(x),
                    .spread => {},
                };
            },
        }
    }

    // ── record cases ─────────────────────────────────────────

    /// Whether a case's one argument is a record type, written in place or
    /// by name (spec §15): a parameter, `Secret R`, `Map v` or `Maybe R`
    /// is not.
    pub fn isRecordType(e0: *const Expr, limit: usize) bool {
        var e = e0;
        var steps: usize = 0;
        while (steps <= limit) : (steps += 1) {
            switch (e.kind) {
                .paren => |inner| e = inner,
                .record => return true,
                .name => |n| switch (n.ref) {
                    .def => |d| {
                        if (d.prelude != .none or d.stream) return false;
                        e = d.body;
                    },
                    else => return false,
                },
                else => return false,
            }
        }
        return false;
    }

    fn classifyCases(c: *Checker, e: *Expr) void {
        switch (e.kind) {
            .paren => |inner| c.classifyCases(inner),
            .param => {},
            .name => |n| for (n.args) |a| c.classifyCases(a),
            .record => |rec| for (rec.members) |m| switch (m) {
                .field => |f| c.classifyCases(f.type),
                .spread => {},
            },
            .variant => |vt| {
                for (vt.cases) |*cs| {
                    const mut: *Case = @constCast(cs);
                    mut.form = if (cs.args.len == 0) .none else if (cs.args.len == 1 and isRecordType(cs.args[0], c.schema.defs.len + 1)) .record else .positional;
                }
                for (vt.alts) |a| switch (a) {
                    .case => |cd| for (cd.args) |x| c.classifyCases(x),
                    .spread => {},
                };
            },
        }
    }

    // ── recursion ────────────────────────────────────────────

    /// `unguarded-recursion` (spec §9 item 9, §14): the head of every
    /// definition, its outermost names unfolded, must not reach the
    /// definition itself before a record, array or payload. `Secret` and
    /// names are no step.
    fn defHead(c: *Checker, d: *Def) Error!Head {
        switch (d.head) {
            .done => return d.head_result,
            .visiting => return c.fail(.@"unguarded-recursion", d.at, "{s} refers to itself without a record field, array element or variant payload in between", .{d.name}),
            .unvisited => {},
        }
        d.head = .visiting;
        const h = try c.exprHead(d.body);
        d.head = .done;
        d.head_result = h;
        return h;
    }

    fn exprHead(c: *Checker, e: *const Expr) Error!Head {
        switch (e.kind) {
            .paren => |inner| return c.exprHead(inner),
            .param => |p| return .{ .param = p.index },
            .record, .variant => return .guarded,
            .name => |n| switch (n.ref) {
                .builtin => |b| return if (b == .Secret) c.exprHead(n.args[0]) else .guarded,
                .time => return .guarded,
                .def => |d| {
                    if (d.prelude != .none) return .guarded;
                    const h = try c.defHead(d);
                    return switch (h) {
                        .guarded => .guarded,
                        .param => |i| c.exprHead(n.args[i]),
                    };
                },
                .unresolved => unreachable,
            },
        }
    }

    /// Whether parameter `p` occurs in `e`.
    fn occurs(e: *const Expr, p: u16) bool {
        switch (e.kind) {
            .paren => |inner| return occurs(inner, p),
            .param => |q| return q.index == p,
            .name => |n| {
                for (n.args) |a| if (occurs(a, p)) return true;
                return false;
            },
            .record => |rec| {
                for (rec.members) |m| switch (m) {
                    .field => |f| if (occurs(f.type, p)) return true,
                    .spread => {},
                };
                return false;
            },
            .variant => |vt| {
                for (vt.alts) |a| switch (a) {
                    .case => |cd| for (cd.args) |x| {
                        if (occurs(x, p)) return true;
                    },
                    .spread => {},
                };
                return false;
            },
        }
    }

    const Edge = struct { to: u32, expanding: bool };

    fn paramEdges(c: *Checker, e: *const Expr, owner: *const Def, base: []const u32, index: *const std.AutoHashMapUnmanaged(*Def, usize), out: []std.ArrayList(Edge)) Error!void {
        switch (e.kind) {
            .paren => |inner| try c.paramEdges(inner, owner, base, index, out),
            .param => {},
            .name => |n| {
                if (n.ref == .def and n.ref.def.prelude == .none) {
                    const target = index.get(n.ref.def).?;
                    for (n.args, 0..) |arg, i| {
                        for (owner.params, 0..) |_, a| {
                            if (!occurs(arg, @intCast(a))) continue;
                            const s = arg.strip();
                            const same = s.kind == .param and s.kind.param.index == a;
                            const from = base[index.get(@constCast(owner)).?] + @as(u32, @intCast(a));
                            try out[from].append(c.gpa, .{ .to = base[target] + @as(u32, @intCast(i)), .expanding = !same });
                        }
                    }
                }
                for (n.args) |a| try c.paramEdges(a, owner, base, index, out);
            },
            .record => |rec| for (rec.members) |m| switch (m) {
                .field => |f| try c.paramEdges(f.type, owner, base, index, out),
                .spread => {},
            },
            .variant => |vt| for (vt.alts) |a| switch (a) {
                .case => |cd| for (cd.args) |x| try c.paramEdges(x, owner, base, index, out),
                .spread => {},
            },
        }
    }

    /// `growing-recursion` (spec §9 item 10): an expanding edge of the
    /// parameter graph on a cycle.
    fn checkGrowing(c: *Checker) Error!void {
        const defs = c.schema.defs;
        var index: std.AutoHashMapUnmanaged(*Def, usize) = .empty;
        defer index.deinit(c.gpa);
        const base = try c.gpa.alloc(u32, defs.len);
        defer c.gpa.free(base);
        var n: u32 = 0;
        for (defs, 0..) |d, i| {
            try index.put(c.gpa, d, i);
            base[i] = n;
            n += @intCast(d.params.len);
        }
        if (n == 0) return;
        const out = try c.gpa.alloc(std.ArrayList(Edge), n);
        defer {
            for (out) |*l| l.deinit(c.gpa);
            c.gpa.free(out);
        }
        for (out) |*l| l.* = .empty;
        for (defs) |d| if (d.params.len > 0) try c.paramEdges(d.body, d, base, &index, out);
        // Tarjan's strongly connected components, iteratively.
        const comp = try c.gpa.alloc(u32, n);
        defer c.gpa.free(comp);
        try sccs(c.gpa, out, comp);
        for (out, 0..) |edges, from| for (edges.items) |edge| {
            if (edge.expanding and comp[from] == comp[edge.to]) {
                // The definition the edge starts in: the last with a node at or before it.
                var owner: usize = 0;
                for (defs, 0..) |d, i| {
                    if (d.params.len > 0 and base[i] <= from) owner = i;
                }
                const d = defs[owner];
                return c.fail(.@"growing-recursion", d.at, "{s}'s instances grow without bound: a parameter passes, inside a bigger type, along a cycle back to itself", .{d.name});
            }
        };
    }

    fn sccs(gpa: Allocator, out: []const std.ArrayList(Edge), comp: []u32) Allocator.Error!void {
        const n = out.len;
        const undef = std.math.maxInt(u32);
        const idx = try gpa.alloc(u32, n);
        defer gpa.free(idx);
        const low = try gpa.alloc(u32, n);
        defer gpa.free(low);
        const on = try gpa.alloc(bool, n);
        defer gpa.free(on);
        @memset(idx, undef);
        @memset(on, false);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        const Frame = struct { node: u32, next: usize };
        var calls: std.ArrayList(Frame) = .empty;
        defer calls.deinit(gpa);
        var counter: u32 = 0;
        var comps: u32 = 0;
        for (0..n) |root| {
            if (idx[root] != undef) continue;
            try calls.append(gpa, .{ .node = @intCast(root), .next = 0 });
            idx[root] = counter;
            low[root] = counter;
            counter += 1;
            try stack.append(gpa, @intCast(root));
            on[root] = true;
            while (calls.items.len > 0) {
                const f = &calls.items[calls.items.len - 1];
                const u = f.node;
                if (f.next < out[u].items.len) {
                    const w = out[u].items[f.next].to;
                    f.next += 1;
                    if (idx[w] == undef) {
                        idx[w] = counter;
                        low[w] = counter;
                        counter += 1;
                        try stack.append(gpa, w);
                        on[w] = true;
                        try calls.append(gpa, .{ .node = w, .next = 0 });
                    } else if (on[w]) {
                        low[u] = @min(low[u], idx[w]);
                    }
                    continue;
                }
                if (low[u] == idx[u]) {
                    while (true) {
                        const w = stack.pop().?;
                        on[w] = false;
                        comp[w] = comps;
                        if (w == u) break;
                    }
                    comps += 1;
                }
                _ = calls.pop();
                if (calls.items.len > 0) {
                    const parent = calls.items[calls.items.len - 1].node;
                    low[parent] = @min(low[parent], low[u]);
                }
            }
        }
    }

    // ── warnings ─────────────────────────────────────────────

    /// `no-json-form` (spec §16.3): a record case with a field named
    /// `_tag` or `_args`, once per case where it is written.
    fn jsonFormWarnings(c: *Checker, e: *const Expr) Error!void {
        switch (e.kind) {
            .paren => |inner| try c.jsonFormWarnings(inner),
            .param => {},
            .name => |n| for (n.args) |a| try c.jsonFormWarnings(a),
            .record => |rec| for (rec.members) |m| switch (m) {
                .field => |f| try c.jsonFormWarnings(f.type),
                .spread => {},
            },
            .variant => |vt| {
                for (vt.cases) |cs| {
                    if (cs.copied or cs.form != .record) continue;
                    if (recordOf(cs.args[0])) |rec| {
                        if (rec.index.contains("_tag") or rec.index.contains("_args")) try c.warn(.@"no-json-form", cs.at);
                    }
                }
                for (vt.alts) |a| switch (a) {
                    .case => |cd| for (cd.args) |x| try c.jsonFormWarnings(x),
                    .spread => {},
                };
            },
        }
    }
};

/// The record type a record case's argument is (its names unfolded).
pub fn recordOf(e0: *const Expr) ?*RecordType {
    var e = e0;
    var steps: usize = 0;
    while (steps < 1 << 16) : (steps += 1) {
        switch (e.kind) {
            .paren => |inner| e = inner,
            .record => |rec| return rec,
            .name => |n| switch (n.ref) {
                .def => |d| e = d.body,
                else => return null,
            },
            else => return null,
        }
    }
    return null;
}

fn lessWarning(_: void, a: Warning, b: Warning) bool {
    return a.offset < b.offset;
}

/// Reads and checks a schema file. Fails with the error code of spec §17
/// and its position (spec §8) in the diagnostic.
pub fn load(gpa: Allocator, text: []const u8, options: LoadOptions) Error!*Schema {
    if (!std.unicode.utf8ValidateSlice(text)) {
        if (options.diagnostic) |d| {
            d.set(.@"invalid-utf8", "invalid UTF-8", .{});
            d.line = 0;
            d.column = 0;
            d.offset = 0;
        }
        return error.Haus;
    }
    const s = try gpa.create(Schema);
    s.* = .{ .arena = .init(gpa), .text = text, .defs = &.{} };
    errdefer s.deinit();
    const arena = s.arena.allocator();
    var warnings: std.ArrayList(Warning) = .empty;

    // The prelude's variants, as definitions of their own.
    {
        var pr: Reader = .{ .p = Parser.init(arena, gpa, prelude_text, .{}, null), .arena = arena, .warnings = &warnings };
        defer pr.p.deinit();
        pr.file() catch unreachable;
        const kinds = [_]Prelude{ .Bool, .Maybe, .Result };
        for (pr.defs.items, 0..) |d, i| {
            d.prelude = kinds[i];
            d.id = try typeId(arena, "prelude", d.name);
            s.prelude_defs[i] = d;
            try s.scope.put(arena, d.name, .{ .def = d });
        }
        var pc: Checker = .{ .arena = arena, .gpa = gpa, .schema = s, .p = &pr.p, .warnings = &warnings };
        for (pr.defs.items) |d| pc.resolveDef(d) catch unreachable;
        for (pr.defs.items) |d| pc.expandAll(d.body) catch unreachable;
        for (pr.defs.items) |d| pc.classifyCases(d.body);
    }

    const text_copy = try arena.dupe(u8, text);
    s.text = text_copy;
    var r: Reader = .{ .p = Parser.init(arena, gpa, text_copy, .{}, options.diagnostic), .arena = arena, .warnings = &warnings };
    defer r.p.deinit();
    try r.file();

    var c: Checker = .{ .arena = arena, .gpa = gpa, .schema = s, .p = &r.p, .warnings = &warnings };

    // Imports (spec §13.3).
    const imported = &s.imported;
    for (r.imports.items) |imp| {
        var buf: [64]u8 = undefined;
        if (imp.names.len == 0) return c.fail(.@"unknown-import", imp.at, "an import names at least one type", .{});
        switch (imp.module) {
            .std => |name| {
                if (!std.mem.eql(u8, name, "time")) {
                    if (std.mem.eql(u8, name, "money")) {
                        return c.fail(.@"unknown-module", imp.module_at, "unknown module std/money: money is the package @haus-fmt/money now (import @haus-fmt/money (Money))", .{});
                    }
                    return c.fail(.@"unknown-module", imp.module_at, "unknown module std/{s}: the standard modules are std/time", .{errors.quoteText(&buf, name)});
                }
                for (imp.names) |n| {
                    const kind = time.Kind.fromName(n.name) orelse return c.fail(.@"unknown-import", n.at, "std/time has no type {s} (it has Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone)", .{errors.quoteText(&buf, n.name)});
                    if ((try imported.fetchPut(arena, n.name, {})) != null) return c.fail(.@"duplicate-import", n.at, "{s} imported twice", .{n.name});
                    try s.scope.put(arena, n.name, .{ .time = kind });
                }
            },
            .package, .file => {
                const resolver = options.resolver orelse return c.fail(.@"import-unavailable", imp.module_at, "can't import {s}: no module resolver (only std modules are found here)", .{errors.quoteText(&buf, switch (imp.module) {
                    .package => |p| p.text,
                    .file => |f| f,
                    else => unreachable,
                })});
                const module = try resolver.resolve(resolver.context, s, imp.module, options.diagnostic);
                for (imp.names) |n| {
                    const d = module.get(n.name) orelse return c.fail(.@"unknown-import", n.at, "the module has no type {s}", .{errors.quoteText(&buf, n.name)});
                    if ((try imported.fetchPut(arena, n.name, {})) != null) return c.fail(.@"duplicate-import", n.at, "{s} imported twice", .{n.name});
                    try s.scope.put(arena, n.name, .{ .def = d });
                }
            },
        }
    }

    // Definitions: unique, not the prelude's. Their ids (§13.3).
    const module = try arena.dupe(u8, options.module);
    s.module = module;
    for (r.defs.items) |d| {
        if (isPreludeName(d.name)) return c.fail(.@"redefine-prelude", d.at, "{s} is a prelude type: give your type another name", .{d.name});
        const gop = try s.scope.getOrPut(arena, d.name);
        if (gop.found_existing) {
            return c.fail(.@"duplicate-type", d.at, "{s} is {s}", .{ d.name, if (imported.contains(d.name)) "imported, and also defined" else "defined twice" });
        }
        gop.value_ptr.* = .{ .def = d };
        d.id = try typeId(arena, module, d.name);
        const body = d.body.strip();
        d.stream = body.kind == .name and std.mem.eql(u8, body.kind.name.name, "Stream");
    }
    s.defs = r.defs.items;

    for (s.defs) |d| try c.resolveDef(d);
    try c.checkSpreadCycles();
    for (s.defs) |d| try c.expandAll(d.body);
    for (s.defs) |d| _ = try c.defHead(d);
    for (s.defs) |d| c.classifyCases(d.body);
    try c.checkGrowing();
    for (s.defs) |d| try c.jsonFormWarnings(d.body);

    std.sort.insertion(Warning, warnings.items, {}, lessWarning);
    s.warnings = warnings.items;
    return s;
}

test "prelude names" {
    try std.testing.expect(isPreludeName("Any"));
    try std.testing.expect(isPreludeName("Maybe"));
    try std.testing.expect(!isPreludeName("Date"));
}

test "load a schema" {
    const gpa = std.testing.allocator;
    const s = try load(gpa, "type A = { x: Int, y?: Maybe (Array String) }\ntype L a = < Nil | Cons a (L a) >", .{});
    defer s.deinit();
    try std.testing.expect(s.get("A") != null);
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Haus, load(gpa, "type A = B\ntype B = A", .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"unguarded-recursion", d.code);
    try std.testing.expectError(error.Haus, load(gpa, "type L a = < X (L (Array a)) | E >", .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"growing-recursion", d.code);
}
