//! Schema imports of packages and files (spec §13.3): building a schema
//! from an entry file, finding the packages it imports among those given
//! explicitly (directories, folders of packages and file trees given in
//! code), with the checks of §13.3 (the root, manifests, links, spelling,
//! versions, duplicates, cycles, limits).
//!
//! This binding belongs to no package manager's ecosystem: it never looks
//! in `node_modules` (spec §13.3, "Installed packages"), and so never reads
//! a project's `package.json` either. Packages are the ones given.
//!
//! Every file is read at most once, by its real path, and is a regular
//! file opened without following a link at its last name and without
//! blocking (`files.zig`). Every name the build looks up (the names of a
//! relative import, `package.haus`, `schema.haus`, `package.json`) is
//! matched against its directory's listing, spelled exactly. Only the
//! entry file and the `root` option are resolved to real paths (they may
//! be reached through links); a relative import follows no link anywhere
//! on its path. Messages show paths relative to the build's root, never
//! absolute ones.

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
const files = @import("files.zig");
const Read = files.Read;

pub const Options = struct {
    /// Packages given by their directory: used instead of any other one
    /// with the same name.
    packages: []const []const u8 = &.{},
    /// Packages given as file trees provided by code (spec §13.3,
    /// `packages.explicit.file-tree`), the same as `packages` otherwise.
    trees: []const Tree = &.{},
    /// Folders whose subdirectories with a `package.haus` are packages.
    folders: []const []const u8 = &.{},
    /// The build's root (spec §13.3, "The root"): a directory that contains
    /// the entry file. Relative imports stay inside it. A relative `root`
    /// is relative to the entry file's real directory (`".."` is the
    /// directory above it), whatever the working directory. Without it,
    /// the root is the directory of the entry file's real path.
    root: ?[]const u8 = null,
    /// Check a manifest's version against its `package.json` (SHOULD).
    check_versions: bool = true,
    max_manifest: usize = 64 * 1024,
    max_file: usize = 1024 * 1024,
    max_folder_entries: usize = 4096,
    max_schema_files: usize = 256,
    diagnostic: ?*Diagnostic = null,
};

/// A package given as a read-only tree of files that code provides (spec
/// §13.3, `packages.explicit.file-tree`), so that a schema package can ship
/// inside a Zig package: files embedded in the program (`@embedFile`), or
/// a directory handle, such as a build dependency's directory. The tree is
/// a package under the rules of a directory: its `package.haus` and
/// `schema.haus` (and a `package.json` beside them for the version check),
/// spelled exactly, regular files and no links, within the limits.
pub const Tree = struct {
    /// How messages name the package (`@acme/orders (embedded)`).
    shown: []const u8,
    source: Source,

    pub const File = struct { name: []const u8, bytes: []const u8 };

    pub const Source = union(enum) {
        /// The files at the package's top level, by their exact names.
        /// Such a tree can't hold links.
        files: []const File,
        /// A directory: its files are read as a package directory's are,
        /// without following links. It must have been opened with
        /// `.iterate = true`, and stays open while the build runs.
        dir: Io.Dir,
    };
};

const Package = struct {
    /// The real path of its directory; for a tree, a name of its own.
    dir: []const u8,
    /// The tree its files come from, if it was given as one.
    tree: ?*const Tree = null,
    /// How it was given, for messages (`schemas/broken`).
    shown: []const u8,
    name: []const u8,
    version: []const u8,
    manifest: []const u8,
    schema_text: ?[]const u8 = null,
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

const Names = std.StringHashMapUnmanaged(void);

/// A schema built from an entry file and what it imports.
pub const Build = struct {
    gpa: Allocator,
    io: Io,
    arena_state: std.heap.ArenaAllocator,
    options: Options,
    root: *Schema = undefined,
    /// The real path of the build's root directory.
    root_dir: []const u8 = "",
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
    /// What each directory lists (null: it can't be listed), read once.
    listings: std.StringHashMapUnmanaged(?Names) = .empty,
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

    /// A path for messages: relative to the build's root (`../vendor/x`
    /// for one outside it), never absolute (spec §13.3, "The root"). A
    /// relative path given that doesn't exist is shown as given.
    fn display(b: *Build, path: []const u8) []const u8 {
        const abs = b.realPath(path) orelse (if (std.fs.path.isAbsolute(path)) path else return b.shownPath(path));
        return b.displayReal(abs);
    }

    /// `display` of a path that is real already: nothing is looked at.
    fn displayReal(b: *Build, abs: []const u8) []const u8 {
        const rel = std.fs.path.relativeAlloc(b.arena(), b.root_dir, null, b.root_dir, abs) catch return b.shownPath(std.fs.path.basename(abs));
        return b.shownPath(if (rel.len == 0) "." else rel);
    }

    // ── files ────────────────────────────────────────────────

    fn realPath(b: *Build, path: []const u8) ?[]const u8 {
        const r = Io.Dir.cwd().realPathFileAlloc(b.io, path, b.arena()) catch return null;
        return r;
    }

    fn isDirectory(b: *Build, path: []const u8) bool {
        const st = Io.Dir.cwd().statFile(b.io, path, .{}) catch return false;
        return st.kind == .directory;
    }

    /// What the directory `dir` lists, read once; null if it can't be
    /// listed.
    fn listing(b: *Build, dir: []const u8) Error!?Names {
        const gop = try b.listings.getOrPut(b.arena(), dir);
        if (!gop.found_existing) {
            gop.key_ptr.* = try b.arena().dupe(u8, dir);
            gop.value_ptr.* = try files.list(b.io, b.arena(), Io.Dir.cwd(), dir);
        }
        return gop.value_ptr.*;
    }

    /// Whether the directory `dir` lists an entry spelled exactly `name`.
    /// A directory that can't be listed lists nothing (spec §13.3,
    /// "Spelling").
    fn listed(b: *Build, dir: []const u8, name: []const u8) Error!bool {
        const names = try b.listing(dir) orelse return false;
        return names.contains(name);
    }

    /// Reads the file `name` of the real directory `dir`: listed with that
    /// spelling, a regular file, not a link.
    fn readIn(b: *Build, dir: []const u8, name: []const u8, limit: usize) Error!Read {
        if (!try b.listed(dir, name)) return .missing;
        const path = try std.fs.path.join(b.arena(), &.{ dir, name });
        return files.readRegular(b.io, b.arena(), Io.Dir.cwd(), path, limit);
    }

    /// Reads a file of a package (`package.haus`, `schema.haus`,
    /// `package.json`), from its directory or its tree.
    fn readPackageFile(b: *Build, p: *const Package, name: []const u8, limit: usize) Error!Read {
        const tree = p.tree orelse return b.readIn(p.dir, name, limit);
        return b.readTreeFile(tree, name, limit);
    }

    fn readTreeFile(b: *Build, tree: *const Tree, name: []const u8, limit: usize) Error!Read {
        switch (tree.source) {
            .files => |list| {
                for (list) |f| if (std.mem.eql(u8, f.name, name)) {
                    if (f.bytes.len > limit) return .too_large;
                    return .{ .bytes = f.bytes };
                };
                return .missing;
            },
            .dir => |dir| {
                const names = try files.list(b.io, b.arena(), dir, ".") orelse return .missing;
                if (!names.contains(name)) return .missing;
                return files.readRegular(b.io, b.arena(), dir, name, limit);
            },
        }
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
            .package => |p| b.resolvePackage(p.name, p.major),
            .std => unreachable,
        };
    }

    /// `import ./x`: the file `x.schema.haus` next to the importing file,
    /// inside the build's root (spec §13.3, "Resolution" and "The root").
    /// The path is a valid `path` of the grammar (the schema reader checked
    /// it): `..` names only at its start, then names. The checks come in
    /// the order of `packages.relative.check-order`: `..` names above the
    /// root, the walk down the names, a target in a package's directory,
    /// then opening the file.
    fn resolveFile(b: *Build, imp: *Importer, rel: []const u8) Error!*const Schema {
        // Only a package's own `schema.haus` imports no files.
        if (imp.package) |p| {
            return b.fail(.@"package-path", "the package {s} imports a file ({s}): a package imports other packages by name", .{ b.quote(p.name), b.quote(rel) });
        }
        const from = b.quote(b.displayReal(imp.real));
        // The `..` names first, on the importing file's real directory
        // alone (it has no links): one that goes above the root looks at
        // nothing.
        var dir: []const u8 = std.fs.path.dirname(imp.real) orelse imp.real;
        var rest = rel;
        if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else while (std.mem.startsWith(u8, rest, "../")) {
            rest = rest[3..];
            dir = std.fs.path.dirname(dir) orelse dir;
        }
        if (!within(b.root_dir, dir)) {
            return b.fail(.@"import-outside-root", "{s} imports {s}, which goes above the build's root", .{ from, b.quote(rel) });
        }
        // The walk down the names: each listed by its directory with that
        // spelling, none a link (not followed: nothing behind one is looked
        // at), each but the last a directory. The path reached is real, and
        // inside the root.
        var names = std.mem.splitScalar(u8, rest, '/');
        while (names.next()) |part| {
            const last = names.peek() == null;
            const name = if (last) try std.fmt.allocPrint(b.arena(), "{s}.schema.haus", .{part}) else part;
            if (!try b.listed(dir, name)) return b.fail(.@"import-not-found", "{s} imports {s}, which isn't found (no file spelled so)", .{ from, b.quote(rel) });
            const path = try std.fs.path.join(b.arena(), &.{ dir, name });
            const kind = files.kindAt(b.io, Io.Dir.cwd(), path) orelse return b.fail(.@"import-not-found", "{s} imports {s}, which isn't found", .{ from, b.quote(rel) });
            switch (kind) {
                .link => return b.fail(.@"import-not-found", "{s} imports {s}, in which {s} is a symbolic link; a relative import follows no link, and nothing behind it is read", .{ from, b.quote(rel), b.quote(name) }),
                .directory => {},
                .file, .other => if (!last) return b.fail(.@"import-not-found", "{s} imports {s}, which isn't found ({s} is not a directory)", .{ from, b.quote(rel), b.quote(name) }),
            }
            dir = path;
        }
        const real = dir;
        try b.checkOutsidePackages(real, from, rel);
        // The path has no links: its last name is opened, not followed.
        const text = switch (try files.readRegular(b.io, b.arena(), Io.Dir.cwd(), real, b.options.max_file)) {
            .bytes => |t| t,
            .too_large => return b.fail(.@"file-too-large", "{s} imports {s}, which is larger than {d} bytes; it is not read", .{ from, b.quote(rel), b.options.max_file }),
            else => return b.fail(.@"import-not-found", "{s} imports {s}, which is not a regular file; it is not read", .{ from, b.quote(rel) }),
        };
        return b.loadFile(real, null, text);
    }

    /// A relative import doesn't reach into a package's directory (spec
    /// §13.3, "Imports"): the directories from the target's up to the
    /// build's root, the root included, nearest first, each a package's
    /// when it lists `package.haus`. One that can't be listed can't show
    /// whether it is a package's: the import fails (it fails closed).
    fn checkOutsidePackages(b: *Build, target: []const u8, from: []const u8, rel: []const u8) Error!void {
        var dir = std.fs.path.dirname(target);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            if (!within(b.root_dir, d)) return;
            const names = try b.listing(d) orelse return b.fail(.@"import-not-found", "{s} imports {s}, and whether {s} is a package's directory can't be checked (it can't be listed); it is not read", .{ from, b.quote(rel), b.quote(b.displayReal(d)) });
            if (names.contains("package.haus")) return b.fail(.@"package-path", "{s} imports {s}, a file in the package directory {s}: import the package by name", .{ from, b.quote(rel), b.quote(b.displayReal(d)) });
        }
    }

    // ── packages ─────────────────────────────────────────────

    fn resolvePackage(b: *Build, name: []const u8, major: ?[]const u8) Error!*const Schema {
        const p = try b.findPackage(name);
        if (major) |m| {
            const have = p.version[0 .. std.mem.indexOfScalar(u8, p.version, '.') orelse p.version.len];
            if (!std.mem.eql(u8, have, m)) return b.fail(.@"import-version", "{s}@{s} is imported, and {s} is given", .{ b.quote(name), m, p.version });
        }
        try b.register(p);
        if (p.schema) |s| return s;
        const text = switch (try b.readPackageFile(p, "schema.haus", b.options.max_file)) {
            .bytes => |t| t,
            .too_large => return b.fail(.@"file-too-large", "the schema.haus of {s} is larger than {d} bytes", .{ b.quote(name), b.options.max_file }),
            .missing => return b.fail(.@"import-not-found", "the package {s} has no schema.haus", .{b.quote(name)}),
            .link, .not_regular => return b.fail(.@"package-path", "the schema.haus of {s} is a link or not a regular file: it is not read", .{b.quote(name)}),
        };
        p.schema_text = text;
        try b.checkIdentical(p);
        const s = try b.loadFile(try std.fs.path.join(b.arena(), &.{ p.dir, "schema.haus" }), p, text);
        p.schema = s;
        return s;
    }

    /// The package an import of `name` means: one given by its directory
    /// (or as a tree), else one found in a folder given.
    fn findPackage(b: *Build, name: []const u8) Error!*Package {
        if (b.explicit.get(name)) |p| return p;
        if (b.folder.get(name)) |p| return p;
        if (b.skipped.items.len > 0) {
            var list: std.ArrayList(u8) = .empty;
            for (b.skipped.items, 0..) |s, i| {
                if (i > 0) try list.appendSlice(b.arena(), ", ");
                try list.appendSlice(b.arena(), b.quote(s));
            }
            return b.fail(.@"import-not-found", "{s} is not given (manifests that can't be read: {s})", .{ b.quote(name), list.items });
        }
        return b.fail(.@"import-not-found", "{s} is not given", .{b.quote(name)});
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
        return switch (try b.readPackageFile(p, "schema.haus", b.options.max_file)) {
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

    /// Reads the package in `dir` (a real path, or a tree's own name with
    /// `tree`); `shown` for messages.
    fn openPackage(b: *Build, dir: []const u8, tree: ?*const Tree, shown: []const u8) Error!*Package {
        if (b.by_dir.get(dir)) |p| return p;
        const p = try b.arena().create(Package);
        p.* = .{ .dir = dir, .tree = tree, .shown = shown, .name = "", .version = "", .manifest = "" };
        const manifest = switch (try b.readPackageFile(p, "package.haus", b.options.max_manifest)) {
            .bytes => |t| t,
            .too_large => return b.fail(.@"package-manifest", "the package.haus of {s} is larger than {d} bytes", .{ b.quote(shown), b.options.max_manifest }),
            .missing => return b.fail(.@"import-not-found", "{s} has no package.haus", .{b.quote(shown)}),
            .link, .not_regular => return b.fail(.@"package-path", "the package.haus of {s} is a link or not a regular file: it is not read", .{b.quote(shown)}),
        };
        const nv = parseManifest(b.arena(), manifest) orelse return b.fail(.@"package-manifest", "the package.haus of {s} is not a valid manifest {{ name: \"@org/name\", version: \"1.2.0\" }}", .{b.quote(shown)});
        p.name = nv.name;
        p.version = nv.version;
        p.manifest = manifest;
        if (b.options.check_versions) try b.checkVersionBeside(p);
        try b.by_dir.put(b.arena(), dir, p);
        return p;
    }

    /// The version of a `package.json` beside the manifest, read leniently
    /// (spec §13.3, "Package versions"): one that can't be read (a link,
    /// not a regular file, too large, not JSON) is ignored; one whose
    /// `version` is a string other than the manifest's is `package-version`.
    fn checkVersionBeside(b: *Build, p: *Package) Error!void {
        const bytes = switch (try b.readPackageFile(p, "package.json", b.options.max_file)) {
            .bytes => |t| t,
            else => return,
        };
        const j = json.parse(b.arena(), b.gpa, bytes, 512, .{}) catch return;
        if (j.get("version")) |ver| if (ver == .string) {
            if (!std.mem.eql(u8, ver.string, p.version)) {
                if (validSemver(ver.string)) return b.fail(.@"package-version", "the package.haus of {s} says {s}, its package.json {s}", .{ b.quote(p.name), b.quote(p.version), b.quote(ver.string) });
                return b.fail(.@"package-version", "the package.haus of {s} says {s}, its package.json another version that isn't a valid version", .{ b.quote(p.name), b.quote(p.version) });
            }
        };
    }

    fn addExplicit(b: *Build, p: *Package) Error!void {
        p.explicit = true;
        const gop = try b.explicit.getOrPut(b.arena(), p.name);
        if (gop.found_existing) {
            try b.sameOrDuplicate(gop.value_ptr.*, p);
        } else gop.value_ptr.* = p;
    }

    fn addDirectory(b: *Build, path: []const u8) Error!void {
        const real = b.realPath(path) orelse return b.fail(.@"import-not-found", "the package {s} doesn't exist", .{b.quote(b.display(path))});
        try b.addExplicit(try b.openPackage(real, null, b.display(real)));
    }

    fn addTree(b: *Build, tree: *const Tree, index: usize) Error!void {
        // A name no real path has: a tree is a package of its own.
        const id = try std.fmt.allocPrint(b.arena(), "<tree {d}>", .{index});
        try b.addExplicit(try b.openPackage(id, tree, tree.shown));
    }

    fn addFolder(b: *Build, path: []const u8) Error!void {
        const real_folder = b.realPath(path) orelse return b.fail(.@"import-not-found", "the folder {s} doesn't exist", .{b.quote(b.display(path))});
        var d = Io.Dir.cwd().openDir(b.io, real_folder, .{ .iterate = true }) catch return b.fail(.@"import-not-found", "the folder {s} can't be read", .{b.quote(b.display(path))});
        defer d.close(b.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(b.io) catch return b.fail(.@"import-not-found", "the folder {s} can't be read", .{b.quote(b.display(path))})) |entry| {
            if (names.items.len >= b.options.max_folder_entries) return b.fail(.@"too-many-files", "the folder {s} has more than {d} entries", .{ b.quote(b.display(path)), b.options.max_folder_entries });
            try names.append(b.arena(), try b.arena().dupe(u8, entry.name));
        }
        std.sort.pdq([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        // Named by the folder's last name and the subdirectory's
        // (`schemas/broken`), however the folder was given (`.`,
        // `schemas/`, a link): the last name of its real path.
        const folder_name = std.fs.path.basename(real_folder);
        for (names.items) |n| {
            const real = b.realPath(try std.fs.path.join(b.arena(), &.{ real_folder, n })) orelse continue;
            if (!b.isDirectory(real) or !try b.listed(real, "package.haus")) continue;
            const shown = b.shownPath(try std.fs.path.join(b.arena(), &.{ folder_name, n }));
            // A subdirectory whose manifest can't be read is skipped, not rejected.
            var inner: Diagnostic = .{};
            const saved = b.options.diagnostic;
            b.options.diagnostic = &inner;
            const p = b.openPackage(real, null, shown) catch |e| switch (e) {
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

    /// The `root` option as a path to resolve: a relative one is relative
    /// to the entry file's real directory, whatever the working directory
    /// (spec §13.3, "The root"). Without an entry file, as given.
    fn rootOption(b: *Build, real_entry: ?[]const u8) Error!?[]const u8 {
        const option = b.options.root orelse return null;
        if (std.fs.path.isAbsolute(option)) return option;
        const entry = real_entry orelse return option;
        const dir = std.fs.path.dirname(entry) orelse entry;
        return try std.fs.path.join(b.arena(), &.{ dir, option });
    }

    /// The build's root (spec §13.3, "The root"), for the entry file whose
    /// real path is `real`: the `root` option's real path `real_root`, a
    /// directory that contains it, or the directory of `real`.
    fn checkRoot(b: *Build, real: []const u8, real_root: ?[]const u8) Error![]const u8 {
        const default = std.fs.path.dirname(real) orelse real;
        const option = b.options.root orelse return default;
        b.root_dir = default; // for the messages below
        const r = real_root orelse return b.fail(.@"import-not-found", "the root {s} given doesn't exist", .{b.quote(b.display(option))});
        if (!b.isDirectory(r) or !within(r, real)) {
            return b.fail(.@"import-outside-root", "the schema file {s} is not inside the root {s} given", .{ b.quote(std.fs.path.basename(real)), b.quote(b.displayReal(r)) });
        }
        return r;
    }
};

/// Whether the real path `path` is the directory `root` or inside it.
fn within(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (root.len > 0 and std.fs.path.isSep(root[root.len - 1])) return true;
    return std.fs.path.isSep(path[root.len]);
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

/// Builds the schema of the entry file `entry` (a schema file) with its
/// imports.
pub fn build(gpa: Allocator, io: Io, entry: []const u8, options: Options) Error!*Build {
    const b = try gpa.create(Build);
    b.* = .{ .gpa = gpa, .io = io, .arena_state = .init(gpa), .options = options };
    errdefer b.deinit();
    // The entry file and the root option are resolved to real paths once,
    // here (they may be reached through links); nothing a relative import
    // names is. The root, for the messages about the packages given: the
    // checks come once those are read.
    const real_entry = b.realPath(entry);
    const real_root = if (try b.rootOption(real_entry)) |r| b.realPath(r) else null;
    b.root_dir = blk: {
        if (real_root) |r| break :blk r;
        if (real_entry) |r| break :blk std.fs.path.dirname(r) orelse r;
        break :blk b.realPath(".") orelse "";
    };
    for (options.packages) |p| try b.addDirectory(p);
    for (options.trees, 0..) |*t, i| try b.addTree(t, i);
    for (options.folders) |f| try b.addFolder(f);
    const real = real_entry orelse return b.fail(.@"import-not-found", "the schema file {s} doesn't exist", .{b.quote(b.display(entry))});
    const text = switch (try files.readRegular(io, b.arena(), Io.Dir.cwd(), real, options.max_file)) {
        .bytes => |t| t,
        .too_large => return b.fail(.@"file-too-large", "the schema file {s} is larger than {d} bytes", .{ b.quote(std.fs.path.basename(real)), options.max_file }),
        else => return b.fail(.@"import-not-found", "the schema file {s} is not a regular file", .{b.quote(std.fs.path.basename(real))}),
    };
    b.root_dir = try b.checkRoot(real, real_root);
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

test "a root contains itself and what is below it" {
    try std.testing.expect(within("/a/b", "/a/b"));
    try std.testing.expect(within("/a/b", "/a/b/c.schema.haus"));
    try std.testing.expect(!within("/a/b", "/a/bc/x"));
    try std.testing.expect(!within("/a/b", "/a"));
    try std.testing.expect(within("/", "/a"));
}

test "a package given as embedded files" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.close(io);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "app.schema.haus", .data = "import @acme/orders@1 (Order)\ntype Root = { order: Order }" });
    const entry = try tmp.dir.realPathFileAlloc(io, "app.schema.haus", testing.allocator);
    defer testing.allocator.free(entry);
    const tree: Tree = .{ .shown = "@acme/orders (embedded)", .source = .{ .files = &.{
        .{ .name = "package.haus", .bytes = "{ name: \"@acme/orders\", version: \"1.2.0\" }" },
        .{ .name = "schema.haus", .bytes = "type Order = { id: Int }" },
    } } };
    const b = try build(testing.allocator, io, entry, .{ .trees = &.{tree} });
    defer b.deinit();
    const list = try b.packageList(b.arena());
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("@acme/orders@1.2.0", list[0]);

    // Names are exact: `Schema.haus` is not `schema.haus`.
    const wrong: Tree = .{ .shown = "@acme/orders (embedded)", .source = .{ .files = &.{
        .{ .name = "package.haus", .bytes = "{ name: \"@acme/orders\", version: \"1.2.0\" }" },
        .{ .name = "Schema.haus", .bytes = "type Order = { id: Int }" },
    } } };
    var d: Diagnostic = .{};
    try testing.expectError(error.Haus, build(testing.allocator, io, entry, .{ .trees = &.{wrong}, .diagnostic = &d }));
    try testing.expectEqual(Code.@"import-not-found", d.code);

    // The version beside the manifest is checked, as in a directory.
    const versioned: Tree = .{ .shown = "@acme/orders (embedded)", .source = .{ .files = &.{
        .{ .name = "package.haus", .bytes = "{ name: \"@acme/orders\", version: \"1.2.0\" }" },
        .{ .name = "schema.haus", .bytes = "type Order = { id: Int }" },
        .{ .name = "package.json", .bytes = "{ \"version\": \"1.3.0\" }" },
    } } };
    try testing.expectError(error.Haus, build(testing.allocator, io, entry, .{ .trees = &.{versioned}, .diagnostic = &d }));
    try testing.expectEqual(Code.@"package-version", d.code);
}

test "messages show paths relative to the root" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.close(io);
    }
    try tmp.dir.createDirPath(io, "proj/app");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/app/a.schema.haus", .data = "import ./missing (X)\ntype Root = { x: X }" });
    const entry = try tmp.dir.realPathFileAlloc(io, "proj/app/a.schema.haus", testing.allocator);
    defer testing.allocator.free(entry);
    const root = try tmp.dir.realPathFileAlloc(io, "proj", testing.allocator);
    defer testing.allocator.free(root);
    var d: Diagnostic = .{};
    try testing.expectError(error.Haus, build(testing.allocator, io, entry, .{ .root = root, .diagnostic = &d }));
    try testing.expectEqual(Code.@"import-not-found", d.code);
    try testing.expect(std.mem.indexOf(u8, d.message(), "'app/a.schema.haus'") != null);
    try testing.expect(std.mem.indexOf(u8, d.message(), root) == null);
}

test "a relative root is relative to the entry file's real directory" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.close(io);
    }
    try tmp.dir.createDirPath(io, "proj/app");
    try tmp.dir.createDirPath(io, "proj/shared");
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/app/a.schema.haus", .data = "import ../shared/x (X)\ntype Root = { x: X }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/shared/x.schema.haus", .data = "type X = Int" });
    const entry = try tmp.dir.realPathFileAlloc(io, "proj/app/a.schema.haus", testing.allocator);
    defer testing.allocator.free(entry);
    // Not the working directory's `..`.
    const b = try build(testing.allocator, io, entry, .{ .root = ".." });
    b.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(error.Haus, build(testing.allocator, io, entry, .{ .root = ".", .diagnostic = &d }));
    try testing.expectEqual(Code.@"import-outside-root", d.code);
}

test "a relative import follows no link" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.close(io);
    }
    try tmp.dir.createDirPath(io, "app/real");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/real/x.schema.haus", .data = "type X = Int" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/a.schema.haus", .data = "import ./real/x (X)\ntype Root = { x: X }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/b.schema.haus", .data = "import ./via/x (X)\ntype Root = { x: X }" });
    tmp.dir.symLink(io, "real", "app/via", .{ .is_directory = true }) catch return error.SkipZigTest;
    const a = try tmp.dir.realPathFileAlloc(io, "app/a.schema.haus", testing.allocator);
    defer testing.allocator.free(a);
    const ok = try build(testing.allocator, io, a, .{});
    ok.deinit();
    const entry = try tmp.dir.realPathFileAlloc(io, "app/b.schema.haus", testing.allocator);
    defer testing.allocator.free(entry);
    var d: Diagnostic = .{};
    try testing.expectError(error.Haus, build(testing.allocator, io, entry, .{ .diagnostic = &d }));
    try testing.expectEqual(Code.@"import-not-found", d.code);
    try testing.expect(std.mem.indexOf(u8, d.message(), "'via' is a symbolic link") != null);
    try testing.expect(std.mem.indexOf(u8, d.message(), "real") == null);
}
