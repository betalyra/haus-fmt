//! Schema imports of packages and files (spec §13.3): building a schema
//! from a root file, finding the packages it imports among those given
//! explicitly and, with `npm`, in `node_modules` by the npm rules, with the
//! checks of §13.3 (manifests, links, declarations, versions, duplicates,
//! cycles, limits).
//!
//! Every file is read at most once, by its real path. A package's
//! `package.haus`, `schema.haus` and `package.json` are opened without
//! following links and checked on the opened file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const errors = @import("errors.zig");
const Code = errors.Code;
const Diagnostic = errors.Diagnostic;
const Error = errors.Error;
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const Module = schema_mod.Module;
const json = @import("json.zig");

pub const Options = struct {
    /// Packages given by their directory: used instead of any other one
    /// with the same name.
    packages: []const []const u8 = &.{},
    /// Folders whose subdirectories with a `package.haus` are packages.
    folders: []const []const u8 = &.{},
    /// Also look in `node_modules`, by the npm rules (spec §13.3).
    npm: bool = false,
    /// Check a manifest's version against its `package.json` (SHOULD).
    check_versions: bool = true,
    max_manifest: usize = 64 * 1024,
    max_file: usize = 1024 * 1024,
    max_folder_entries: usize = 4096,
    max_schema_files: usize = 256,
    diagnostic: ?*Diagnostic = null,
};

const Package = struct {
    /// The real path of its directory.
    dir: []const u8,
    /// How it was given, for messages (`schemas/broken`).
    shown: []const u8,
    name: []const u8,
    version: []const u8,
    manifest: []const u8,
    schema_text: ?[]const u8 = null,
    /// The declarations of its own `package.json` (npm).
    declared: ?std.StringHashMapUnmanaged(void) = null,
    explicit: bool = false,
    schema: ?*Schema = null,
};

const FileState = struct {
    schema: ?*Schema = null,
    loading: bool = true,
};

/// The importing file, for the resolver.
const Importer = struct {
    build: *Build,
    real: []const u8,
    package: ?*Package,
};

/// A schema built from a root file and what it imports.
pub const Build = struct {
    gpa: Allocator,
    io: Io,
    arena_state: std.heap.ArenaAllocator,
    options: Options,
    root: *Schema = undefined,
    files: std.StringHashMapUnmanaged(*FileState) = .empty,
    schema_files: usize = 0,
    /// Packages by the real path of their directory.
    by_dir: std.StringHashMapUnmanaged(*Package) = .empty,
    /// The first package of each name that was used.
    by_name: std.StringHashMapUnmanaged(*Package) = .empty,
    explicit: std.StringHashMapUnmanaged(*Package) = .empty,
    folder: std.StringHashMapUnmanaged(*Package) = .empty,
    /// Folder subdirectories whose manifest can't be read: named when an
    /// import isn't found.
    skipped: std.ArrayList([]const u8) = .empty,
    schemas: std.ArrayList(*Schema) = .empty,

    fn arena(b: *Build) Allocator {
        return b.arena_state.allocator();
    }

    pub fn deinit(b: *Build) void {
        for (b.schemas.items) |s| s.deinit();
        b.schemas.deinit(b.gpa);
        const gpa = b.gpa;
        b.arena_state.deinit();
        gpa.destroy(b);
    }

    /// Every package the schema reaches, as `name@version`, sorted.
    pub fn packageList(b: *Build, out_arena: Allocator) Allocator.Error![]const []const u8 {
        var set: std.StringArrayHashMapUnmanaged(void) = .empty;
        var it = b.by_dir.valueIterator();
        while (it.next()) |p| if (p.*.schema != null) {
            try set.put(out_arena, try std.fmt.allocPrint(out_arena, "{s}@{s}", .{ p.*.name, p.*.version }), {});
        };
        const list = try out_arena.dupe([]const u8, set.keys());
        std.sort.pdq([]const u8, list, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        return list;
    }

    fn fail(b: *Build, code: Code, comptime fmt: []const u8, args: anytype) Error {
        if (b.options.diagnostic) |d| {
            d.set(code, fmt, args);
            d.line = 0;
            d.column = 0;
            d.offset = 0;
        }
        return error.Haus;
    }

    fn quote(b: *Build, text: []const u8) []const u8 {
        const buf = b.arena().alloc(u8, 256) catch return "…";
        return errors.quoteText(buf, text);
    }

    /// A path with `\` written as `/`, for messages.
    fn shownPath(b: *Build, p: []const u8) []const u8 {
        const out = b.arena().dupe(u8, p) catch return p;
        for (out) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        return out;
    }

    // ── files ────────────────────────────────────────────────

    fn realPath(b: *Build, path: []const u8) ?[]const u8 {
        const r = Io.Dir.cwd().realPathFileAlloc(b.io, path, b.arena()) catch return null;
        return r;
    }

    fn kindOf(b: *Build, path: []const u8, follow: bool) ?Io.File.Kind {
        const st = Io.Dir.cwd().statFile(b.io, path, .{ .follow_symlinks = follow }) catch return null;
        return st.kind;
    }

    const Read = union(enum) { missing, link, not_regular, too_large, bytes: []const u8 };

    /// Reads a file of a package: a regular file, not a link (checked on
    /// the opened file), at most `limit` bytes.
    fn readPackageFile(b: *Build, path: []const u8, limit: usize) Read {
        const kind = b.kindOf(path, false) orelse return .missing;
        if (kind == .sym_link) return .link;
        if (kind != .file) return .not_regular;
        const file = Io.Dir.cwd().openFile(b.io, path, .{ .follow_symlinks = false, .allow_directory = false }) catch return .not_regular;
        defer file.close(b.io);
        const st = file.stat(b.io) catch return .not_regular;
        if (st.kind != .file) return .not_regular;
        if (st.size > limit) return .too_large;
        const buf = b.arena().alloc(u8, @intCast(st.size)) catch return .too_large;
        const n = file.readPositionalAll(b.io, buf, 0) catch return .not_regular;
        return .{ .bytes = buf[0..n] };
    }

    /// Reads an application's file (links followed), at most `limit` bytes.
    fn readAppFile(b: *Build, path: []const u8, limit: usize) Read {
        const file = Io.Dir.cwd().openFile(b.io, path, .{ .allow_directory = false }) catch return .missing;
        defer file.close(b.io);
        const st = file.stat(b.io) catch return .not_regular;
        if (st.kind != .file) return .not_regular;
        if (st.size > limit) return .too_large;
        const buf = b.arena().alloc(u8, @intCast(st.size)) catch return .too_large;
        const n = file.readPositionalAll(b.io, buf, 0) catch return .not_regular;
        return .{ .bytes = buf[0..n] };
    }

    /// The directory of a package that a real path is in: the nearest
    /// directory above it with a `package.haus`.
    fn packageDirOf(b: *Build, real: []const u8) ?[]const u8 {
        var dir = std.fs.path.dirname(real);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const manifest = std.fs.path.join(b.arena(), &.{ d, "package.haus" }) catch return null;
            if (b.kindOf(manifest, false) != null) return d;
        }
        return null;
    }

    // ── schema files ─────────────────────────────────────────

    fn loadFile(b: *Build, real: []const u8, package: ?*Package, text: []const u8) Error!*Schema {
        if (b.files.get(real)) |st| {
            if (st.loading) return b.fail(.@"import-cycle", "import cycle: {s} imports itself, directly or not", .{b.quote(std.fs.path.basename(real))});
            return st.schema.?;
        }
        b.schema_files += 1;
        if (b.schema_files > b.options.max_schema_files) return b.fail(.@"too-many-files", "the schema imports more than {d} schema files", .{b.options.max_schema_files});
        const st = try b.arena().create(FileState);
        st.* = .{};
        try b.files.put(b.arena(), real, st);
        const importer = try b.arena().create(Importer);
        importer.* = .{ .build = b, .real = real, .package = package };
        const s = try schema_mod.load(b.gpa, text, .{
            .diagnostic = b.options.diagnostic,
            .resolver = .{ .context = importer, .resolve = resolve },
        });
        b.schemas.append(b.gpa, s) catch |e| {
            s.deinit();
            return e;
        };
        st.schema = s;
        st.loading = false;
        return s;
    }

    fn resolve(context: *anyopaque, _: ?*const Schema, module: Module, _: ?*Diagnostic) Error!*const Schema {
        const imp: *Importer = @ptrCast(@alignCast(context));
        const b = imp.build;
        return switch (module) {
            .file => |rel| b.resolveFile(imp, rel),
            .package => |p| b.resolvePackage(imp, p.name, p.major),
            .std => unreachable,
        };
    }

    /// `import ./x`: the file `x.schema.haus` next to the importing file,
    /// each name spelled as its directory lists it.
    fn resolveFile(b: *Build, imp: *Importer, rel: []const u8) Error!*const Schema {
        if (imp.package) |p| {
            return b.fail(.@"package-path", "the package {s} imports a file ({s}): a package imports other packages by name", .{ b.quote(p.name), b.quote(rel) });
        }
        var dir: []const u8 = std.fs.path.dirname(imp.real) orelse "/";
        var parts = std.mem.splitScalar(u8, rel, '/');
        var names: std.ArrayList([]const u8) = .empty;
        while (parts.next()) |part| try names.append(b.arena(), part);
        for (names.items, 0..) |part, i| {
            const last = i + 1 == names.items.len;
            if (part.len == 0 or std.mem.eql(u8, part, ".")) {
                if (last) return b.fail(.@"import-not-found", "can't import {s}: no such file", .{b.quote(rel)});
                continue;
            }
            if (std.mem.eql(u8, part, "..")) {
                if (last) return b.fail(.@"import-not-found", "can't import {s}: no such file", .{b.quote(rel)});
                dir = std.fs.path.dirname(dir) orelse dir;
                continue;
            }
            const name = if (last) try std.fmt.allocPrint(b.arena(), "{s}.schema.haus", .{part}) else part;
            if (!b.listed(dir, name)) return b.fail(.@"import-not-found", "can't import {s}: no file spelled so", .{b.quote(rel)});
            dir = try std.fs.path.join(b.arena(), &.{ dir, name });
        }
        const real = b.realPath(dir) orelse return b.fail(.@"import-not-found", "can't import {s}: no such file", .{b.quote(rel)});
        if (b.packageDirOf(real) != null) {
            return b.fail(.@"package-path", "{s} is in a package's directory: import the package by name", .{b.quote(rel)});
        }
        if (!std.mem.endsWith(u8, real, ".schema.haus")) {
            return b.fail(.@"import-not-found", "can't import {s}: it is not a schema file", .{b.quote(rel)});
        }
        const text = switch (b.readAppFile(real, b.options.max_file)) {
            .bytes => |t| t,
            .too_large => return b.fail(.@"file-too-large", "{s} is larger than {d} bytes", .{ b.quote(rel), b.options.max_file }),
            else => return b.fail(.@"import-not-found", "can't import {s}: no such file", .{b.quote(rel)}),
        };
        return b.loadFile(real, null, text);
    }

    /// Whether `dir` lists an entry spelled exactly `name`.
    fn listed(b: *Build, dir: []const u8, name: []const u8) bool {
        var d = Io.Dir.cwd().openDir(b.io, dir, .{ .iterate = true }) catch return false;
        defer d.close(b.io);
        var it = d.iterate();
        while (it.next(b.io) catch return false) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return true;
        }
        return false;
    }

    // ── packages ─────────────────────────────────────────────

    fn resolvePackage(b: *Build, imp: *Importer, name: []const u8, major: ?[]const u8) Error!*const Schema {
        if (b.options.npm and !b.explicit.contains(name) and !b.folder.contains(name)) {
            if (!try b.declares(imp, name)) {
                if (imp.package) |p| return b.fail(.@"undeclared-package", "the package {s} imports {s}, which its package.json doesn't declare", .{ b.quote(p.name), b.quote(name) });
                return b.fail(.@"undeclared-package", "{s} is imported but not declared in the project's package.json", .{b.quote(name)});
            }
        }
        const p = try b.findPackage(imp, name);
        if (major) |m| {
            const have = p.version[0 .. std.mem.indexOfScalar(u8, p.version, '.') orelse p.version.len];
            if (!std.mem.eql(u8, have, m)) return b.fail(.@"import-version", "{s}@{s} is imported, and {s} is installed", .{ b.quote(name), m, p.version });
        }
        try b.register(p);
        if (p.schema) |s| return s;
        const schema_path = try std.fs.path.join(b.arena(), &.{ p.dir, "schema.haus" });
        const text = switch (b.readPackageFile(schema_path, b.options.max_file)) {
            .bytes => |t| t,
            .too_large => return b.fail(.@"file-too-large", "the schema.haus of {s} is larger than {d} bytes", .{ b.quote(name), b.options.max_file }),
            .missing => return b.fail(.@"import-not-found", "the package {s} has no schema.haus", .{b.quote(name)}),
            .link, .not_regular => return b.fail(.@"package-path", "the schema.haus of {s} is a link or not a regular file: it is not read", .{b.quote(name)}),
        };
        p.schema_text = text;
        try b.checkIdentical(p);
        const s = try b.loadFile(schema_path, p, text);
        p.schema = s;
        return s;
    }

    /// The package an import of `name` means.
    fn findPackage(b: *Build, imp: *Importer, name: []const u8) Error!*Package {
        if (b.explicit.get(name)) |p| return p;
        if (b.options.npm) {
            if (try b.npmLookup(imp, name)) |p| {
                if (b.folder.get(name)) |f| try b.sameOrDuplicate(p, f);
                return p;
            }
        }
        if (b.folder.get(name)) |p| return p;
        if (b.skipped.items.len > 0) {
            var list: std.ArrayList(u8) = .empty;
            for (b.skipped.items, 0..) |s, i| {
                if (i > 0) try list.appendSlice(b.arena(), ", ");
                try list.appendSlice(b.arena(), b.quote(s));
            }
            return b.fail(.@"import-not-found", "{s} is not installed (manifests that can't be read: {s})", .{ b.quote(name), list.items });
        }
        return b.fail(.@"import-not-found", "{s} is not installed", .{b.quote(name)});
    }

    /// Two packages with one name: one package if their manifests and
    /// schemas are byte for byte the same, else `duplicate-package`.
    fn sameOrDuplicate(b: *Build, a: *Package, c: *Package) Error!void {
        if (a == c or std.mem.eql(u8, a.dir, c.dir)) return;
        if (std.mem.eql(u8, a.manifest, c.manifest)) {
            const ta = try b.schemaText(a);
            const tc = try b.schemaText(c);
            if (ta != null and tc != null and std.mem.eql(u8, ta.?, tc.?)) return;
        }
        return b.fail(.@"duplicate-package", "two packages named {s}: {s} and {s}", .{ b.quote(a.name), b.quote(a.version), b.quote(c.version) });
    }

    fn schemaText(b: *Build, p: *Package) Error!?[]const u8 {
        if (p.schema_text) |t| return t;
        const path = try std.fs.path.join(b.arena(), &.{ p.dir, "schema.haus" });
        return switch (b.readPackageFile(path, b.options.max_file)) {
            .bytes => |t| blk: {
                p.schema_text = t;
                break :blk t;
            },
            else => null,
        };
    }

    fn register(b: *Build, p: *Package) Error!void {
        const gop = try b.by_name.getOrPut(b.arena(), p.name);
        if (!gop.found_existing) gop.value_ptr.* = p;
    }

    fn checkIdentical(b: *Build, p: *Package) Error!void {
        const first = b.by_name.get(p.name) orelse return;
        try b.sameOrDuplicate(first, p);
    }

    /// Reads the package in `dir` (a real path); `shown` for messages.
    fn openPackage(b: *Build, dir: []const u8, shown: []const u8) Error!*Package {
        if (b.by_dir.get(dir)) |p| return p;
        const manifest_path = try std.fs.path.join(b.arena(), &.{ dir, "package.haus" });
        const manifest = switch (b.readPackageFile(manifest_path, b.options.max_manifest)) {
            .bytes => |t| t,
            .too_large => return b.fail(.@"package-manifest", "the package.haus of {s} is larger than {d} bytes", .{ b.quote(shown), b.options.max_manifest }),
            .missing => return b.fail(.@"import-not-found", "{s} has no package.haus", .{b.quote(shown)}),
            .link, .not_regular => return b.fail(.@"package-path", "the package.haus of {s} is a link or not a regular file: it is not read", .{b.quote(shown)}),
        };
        const nv = parseManifest(b.arena(), manifest) orelse return b.fail(.@"package-manifest", "the package.haus of {s} is not a valid manifest {{ name: \"@org/name\", version: \"1.2.0\" }}", .{b.quote(shown)});
        const p = try b.arena().create(Package);
        p.* = .{ .dir = dir, .shown = shown, .name = nv.name, .version = nv.version, .manifest = manifest };
        if (b.options.npm) try b.readOwnPackageJson(p);
        try b.by_dir.put(b.arena(), dir, p);
        return p;
    }

    /// A package's own `package.json` (npm): its declarations, and the
    /// version check (`package-version`).
    fn readOwnPackageJson(b: *Build, p: *Package) Error!void {
        const path = try std.fs.path.join(b.arena(), &.{ p.dir, "package.json" });
        const bytes = switch (b.readPackageFile(path, b.options.max_file)) {
            .bytes => |t| t,
            .missing => return,
            .too_large => return b.fail(.@"file-too-large", "the package.json of {s} is larger than {d} bytes", .{ b.quote(p.name), b.options.max_file }),
            .link, .not_regular => return b.fail(.@"package-path", "the package.json of {s} is a link or not a regular file: it is not read", .{b.quote(p.name)}),
        };
        const j = json.parse(b.arena(), b.gpa, bytes, 512, .{}) catch {
            p.declared = .empty;
            return;
        };
        p.declared = try declarations(b.arena(), j, false);
        if (b.options.check_versions) if (j.get("version")) |ver| if (ver == .string) {
            if (!std.mem.eql(u8, ver.string, p.version)) {
                if (validSemver(ver.string)) return b.fail(.@"package-version", "the package.haus of {s} says {s}, its package.json {s}", .{ b.quote(p.name), b.quote(p.version), b.quote(ver.string) });
                return b.fail(.@"package-version", "the package.haus of {s} says {s}, its package.json another version that isn't a valid version", .{ b.quote(p.name), b.quote(p.version) });
            }
        };
    }

    /// Whether the importing file declares the package (npm, spec §13.3).
    fn declares(b: *Build, imp: *Importer, name: []const u8) Error!bool {
        if (imp.package) |p| {
            const d = p.declared orelse return false;
            return d.contains(name);
        }
        var dir = std.fs.path.dirname(imp.real);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const path = try std.fs.path.join(b.arena(), &.{ d, "package.json" });
            const kind = b.kindOf(path, true) orelse {
                // A broken link declares nothing and ends the search.
                if (b.kindOf(path, false) != null) return false;
                continue;
            };
            if (kind != .file) return false;
            const bytes = switch (b.readAppFile(path, b.options.max_file)) {
                .bytes => |t| t,
                .too_large => return b.fail(.@"file-too-large", "{s} is larger than {d} bytes", .{ b.quote(path), b.options.max_file }),
                else => return false,
            };
            const j = json.parse(b.arena(), b.gpa, bytes, 512, .{}) catch return false;
            if (j != .object) continue;
            const fields = [_][]const u8{ "name", "dependencies", "peerDependencies", "optionalDependencies", "devDependencies" };
            const project = for (fields) |f| {
                if (j.get(f) != null) break true;
            } else false;
            if (!project) continue;
            const decl = try declarations(b.arena(), j, true);
            return decl.contains(name);
        }
        return false;
    }

    /// `D/node_modules/@org/name` for each directory `D` from the importing
    /// file's up (spec §13.3, npm): the first that exists is the package.
    fn npmLookup(b: *Build, imp: *Importer, name: []const u8) Error!?*Package {
        var dir = std.fs.path.dirname(imp.real);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const base = std.fs.path.basename(d);
            if (std.mem.eql(u8, base, "node_modules")) continue;
            if (base.len > 0 and base[0] == '@') {
                if (std.fs.path.dirname(d)) |parent| if (std.mem.eql(u8, std.fs.path.basename(parent), "node_modules")) continue;
            }
            const candidate = try std.fs.path.join(b.arena(), &.{ d, "node_modules", name });
            if (b.kindOf(candidate, true) == null) continue;
            const real = b.realPath(candidate) orelse continue;
            const manifest = try std.fs.path.join(b.arena(), &.{ real, "package.haus" });
            if (b.kindOf(manifest, false) == null) return b.fail(.@"import-not-found", "{s} in node_modules is not a schema package (no package.haus)", .{b.quote(name)});
            const p = try b.openPackage(real, candidate);
            if (!std.mem.eql(u8, p.name, name)) return b.fail(.@"import-not-found", "node_modules/{s} holds the package {s}", .{ b.quote(name), b.quote(p.name) });
            return p;
        }
        return null;
    }

    fn addExplicit(b: *Build, path: []const u8) Error!void {
        const real = b.realPath(path) orelse return b.fail(.@"import-not-found", "the package {s} doesn't exist", .{b.quote(b.shownPath(path))});
        const p = try b.openPackage(real, b.shownPath(path));
        p.explicit = true;
        const gop = try b.explicit.getOrPut(b.arena(), p.name);
        if (gop.found_existing) {
            try b.sameOrDuplicate(gop.value_ptr.*, p);
        } else gop.value_ptr.* = p;
    }

    fn addFolder(b: *Build, path: []const u8) Error!void {
        var d = Io.Dir.cwd().openDir(b.io, path, .{ .iterate = true }) catch return b.fail(.@"import-not-found", "the folder {s} doesn't exist", .{b.quote(b.shownPath(path))});
        defer d.close(b.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(b.io) catch return b.fail(.@"import-not-found", "the folder {s} can't be read", .{b.quote(b.shownPath(path))})) |entry| {
            if (names.items.len >= b.options.max_folder_entries) return b.fail(.@"too-many-files", "the folder {s} has more than {d} entries", .{ b.quote(b.shownPath(path)), b.options.max_folder_entries });
            try names.append(b.arena(), try b.arena().dupe(u8, entry.name));
        }
        std.sort.pdq([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        for (names.items) |n| {
            const sub = try std.fs.path.join(b.arena(), &.{ path, n });
            if (b.kindOf(sub, true) != .directory) continue;
            const manifest = try std.fs.path.join(b.arena(), &.{ sub, "package.haus" });
            if (b.kindOf(manifest, false) == null) continue;
            const real = b.realPath(sub) orelse continue;
            // Named by the folder's last name and the subdirectory's (`schemas/broken`).
            const shown = b.shownPath(try std.fs.path.join(b.arena(), &.{ std.fs.path.basename(path), n }));
            // A subdirectory whose manifest can't be read is skipped, not rejected.
            var inner: Diagnostic = .{};
            const saved = b.options.diagnostic;
            b.options.diagnostic = &inner;
            const p = b.openPackage(real, shown) catch |e| switch (e) {
                error.Haus => {
                    b.options.diagnostic = saved;
                    try b.skipped.append(b.arena(), shown);
                    continue;
                },
                else => return e,
            };
            b.options.diagnostic = saved;
            const gop = try b.folder.getOrPut(b.arena(), p.name);
            if (gop.found_existing) {
                try b.sameOrDuplicate(gop.value_ptr.*, p);
            } else gop.value_ptr.* = p;
        }
    }
};

/// The declared packages of a `package.json`: the member names of
/// `dependencies`, `peerDependencies`, `optionalDependencies` and, for a
/// project's file, `devDependencies`. A field that isn't an object
/// declares nothing.
fn declarations(arena: Allocator, j: json.Json, dev: bool) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    if (j != .object) return set;
    const fields = [_][]const u8{ "dependencies", "peerDependencies", "optionalDependencies", "devDependencies" };
    for (fields) |f| {
        if (!dev and std.mem.eql(u8, f, "devDependencies")) continue;
        const deps = j.get(f) orelse continue;
        if (deps != .object) continue;
        for (deps.object) |m| try set.put(arena, m.name, {});
    }
    return set;
}

const NameVersion = struct { name: []const u8, version: []const u8 };

/// A manifest: one record with a valid `name` and `version`, other fields
/// ignored.
fn parseManifest(arena: Allocator, text: []const u8) ?NameVersion {
    const root = @import("root.zig");
    const parsed = root.parse(arena, text, .{}) catch return null;
    const val = parsed.value;
    if (val != .record) return null;
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    for (val.record) |f| {
        if (std.mem.eql(u8, f.key, "name")) name = if (f.value == .string) f.value.string else return null;
        if (std.mem.eql(u8, f.key, "version")) version = if (f.value == .string) f.value.string else return null;
    }
    const n = name orelse return null;
    const ver = version orelse return null;
    if (!schema_mod.isPackageName(n) or !validSemver(ver)) return null;
    return .{ .name = n, .version = ver };
}

fn validNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len > 1 and s[0] == '0') return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn validIdentifiers(s: []const u8, numeric_rule: bool) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        var all_digits = true;
        for (part) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
            if (c < '0' or c > '9') all_digits = false;
        }
        if (numeric_rule and all_digits and part.len > 1 and part[0] == '0') return false;
    }
    return true;
}

/// A semantic version (semver.org 2.0.0): `MAJOR.MINOR.PATCH`, an optional
/// pre-release and build metadata, ASCII only.
pub fn validSemver(v: []const u8) bool {
    var rest = v;
    var build_meta: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '+')) |k| {
        build_meta = rest[k + 1 ..];
        rest = rest[0..k];
    }
    var pre: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '-')) |k| {
        pre = rest[k + 1 ..];
        rest = rest[0..k];
    }
    var parts = std.mem.splitScalar(u8, rest, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (!validNumeric(part)) return false;
    }
    if (count != 3) return false;
    if (pre) |p| if (!validIdentifiers(p, true)) return false;
    if (build_meta) |bm| if (!validIdentifiers(bm, false)) return false;
    return true;
}

/// Builds the schema of `root_path` (a schema file) with its imports.
pub fn build(gpa: Allocator, io: Io, root_path: []const u8, options: Options) Error!*Build {
    const b = try gpa.create(Build);
    b.* = .{ .gpa = gpa, .io = io, .arena_state = .init(gpa), .options = options };
    errdefer b.deinit();
    for (options.packages) |p| try b.addExplicit(p);
    for (options.folders) |f| try b.addFolder(f);
    const real = b.realPath(root_path) orelse return b.fail(.@"import-not-found", "the schema file {s} doesn't exist", .{b.quote(b.shownPath(root_path))});
    const text = switch (b.readAppFile(real, options.max_file)) {
        .bytes => |t| t,
        .too_large => return b.fail(.@"file-too-large", "{s} is larger than {d} bytes", .{ b.quote(b.shownPath(root_path)), options.max_file }),
        else => return b.fail(.@"import-not-found", "the schema file {s} can't be read", .{b.quote(b.shownPath(root_path))}),
    };
    b.root = try b.loadFile(real, null, text);
    return b;
}

test "semantic versions" {
    try std.testing.expect(validSemver("1.0.0"));
    try std.testing.expect(validSemver("0.3.0-rc.1+build.7"));
    try std.testing.expect(!validSemver("1.0"));
    try std.testing.expect(!validSemver("v1.0.0"));
    try std.testing.expect(!validSemver("01.0.0"));
    try std.testing.expect(!validSemver("1.0.0\n"));
}
