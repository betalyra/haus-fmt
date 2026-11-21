//! The schema modes of the Zig fuzz runner (fuzz/README.md):
//!
//!   zig-runner --schema FILE         lines `SUITE TYPE HEX`: decode the value with the type, encode,
//!                                    `ok <canonical form>` or `err PLACE CODE REASON`
//!   zig-runner --schema-check FILE   lines `HEX` (a schema file): `ok` or `err LINE COLUMN CODE REASON`
//!   zig-runner --time FILE           lines `TYPE HEX`: `ok` or `no` (the std/time profile)
//!   zig-runner --json MODE FILE      the JSON modes (json.zig in the runner)
//!
//! The schema files are found by suite name in test-suite/schema,
//! fuzz/schema, test-suite/json and fuzz/json of the checkout the runner was
//! built from.

const std = @import("std");
const haus = @import("haus");
const build_options = @import("build_options");
const Value = haus.Value;
const Allocator = std.mem.Allocator;
const Schema = haus.schema.Schema;

pub const schema_dirs = [_][]const u8{ "test-suite/schema", "fuzz/schema", "test-suite/json", "fuzz/json" };

/// The schema files by suite name, loaded once (null when rejected).
pub const Schemas = struct {
    gpa: Allocator,
    io: std.Io,
    loaded: std.StringHashMapUnmanaged(?*Schema) = .empty,

    pub fn deinit(s: *Schemas) void {
        var it = s.loaded.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |x| x.deinit();
        }
        s.loaded.deinit(s.gpa);
    }

    pub fn get(s: *Schemas, suite: []const u8) !?*Schema {
        if (s.loaded.get(suite)) |x| return x;
        var found: ?*Schema = null;
        for (schema_dirs) |dir| {
            const path = try std.fmt.allocPrint(s.gpa, "{s}/{s}/{s}.schema.haus", .{ build_options.repo_dir, dir, suite });
            defer s.gpa.free(path);
            const text = std.Io.Dir.cwd().readFileAlloc(s.io, path, s.gpa, .unlimited) catch continue;
            defer s.gpa.free(text);
            found = haus.schema.load(s.gpa, text, .{}) catch null;
            break;
        }
        try s.loaded.put(s.gpa, try s.gpa.dupe(u8, suite), found);
        return found;
    }
};

pub fn writeReason(out: *std.Io.Writer, msg: []const u8) !void {
    for (msg) |c| try out.writeByte(if (c == '\n' or c == '\r') ' ' else c);
}

/// `err PLACE CODE REASON`.
pub fn errPlace(out: *std.Io.Writer, d: *const haus.Diagnostic) !void {
    const place = if (d.path().len > 0) d.path() else "$";
    try out.print("err {s} {s} ", .{ place, d.code.name() });
    try writeReason(out, d.message());
    try out.writeByte('\n');
}

pub fn hexDecode(arena: Allocator, hex: []const u8) ![]u8 {
    const out = try arena.alloc(u8, hex.len / 2);
    return std.fmt.hexToBytes(out, hex);
}

fn schemaCase(arena: Allocator, schemas: *Schemas, out: *std.Io.Writer, line: []const u8) !void {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const suite = parts.next().?;
    const type_name = parts.next().?;
    const text = try hexDecode(arena, parts.next() orelse "");
    const s = try schemas.get(suite) orelse return out.print("err $ - the schema file {s} is rejected\n", .{suite});
    const def = s.get(type_name) orelse return out.print("err $ - no type {s}\n", .{type_name});
    var d: haus.Diagnostic = .{};
    const parsed = haus.parseAll(arena, text, .{ .diagnostic = &d }) catch return out.print("err $ - not a single value: {s} {s}\n", .{ d.code.name(), d.message() });
    if (parsed.value.len != 1) return out.writeAll("err $ - not a single value\n");
    const decoded = haus.decoding.decode(arena, def, parsed.value[0], .{ .diagnostic = &d }) catch |e| switch (e) {
        error.Haus => return errPlace(out, &d),
        else => return e,
    };
    const encoded = haus.decoding.encode(arena, def, decoded, .{ .diagnostic = &d }) catch |e| switch (e) {
        // Encoding what was decoded must work (spec §15).
        error.Haus => return out.print("CRASH encoding failed: {s} at {s}\n", .{ d.code.name(), d.path() }),
        else => return e,
    };
    const c = try haus.canonical(arena, encoded, .{});
    try out.print("ok {s}\n", .{c});
}

fn schemaCheckCase(arena: Allocator, gpa: Allocator, out: *std.Io.Writer, line: []const u8) !void {
    const text = try hexDecode(arena, line);
    var d: haus.Diagnostic = .{};
    const s = haus.schema.load(gpa, text, .{ .diagnostic = &d }) catch |e| switch (e) {
        error.Haus => {
            try out.print("err {d} {d} {s} ", .{ d.line, d.column, d.code.name() });
            try writeReason(out, d.message());
            return out.writeByte('\n');
        },
        else => return e,
    };
    s.deinit();
    try out.writeAll("ok\n");
}

fn timeCase(arena: Allocator, out: *std.Io.Writer, line: []const u8) !void {
    var parts = std.mem.splitScalar(u8, line, ' ');
    const kind = haus.time.Kind.fromName(parts.next().?);
    const text = try hexDecode(arena, parts.next() orelse "");
    const ok = if (kind) |k| std.unicode.utf8ValidateSlice(text) and haus.time.check(k, text) else false;
    try out.writeAll(if (ok) "ok\n" else "no\n");
}

pub const FileMode = enum { schema, @"schema-check", time };

/// Runs a mode that reads a file of lines.
pub fn run(io: std.Io, gpa: Allocator, mode: FileMode, path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(data);
    var buf: [1 << 16]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;
    var schemas: Schemas = .{ .gpa = gpa, .io = io };
    defer schemas.deinit();
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        switch (mode) {
            .schema => try schemaCase(arena, &schemas, out, line),
            .@"schema-check" => try schemaCheckCase(arena, gpa, out, line),
            .time => try timeCase(arena, out, line),
        }
    }
    try out.flush();
}

pub const JsonMode = enum { write, read, @"haus-json-write", @"haus-json-read", import };

fn jsonErr(out: *std.Io.Writer, d: *const haus.Diagnostic) !void {
    return errPlace(out, d);
}

fn jsonCase(arena: Allocator, gpa: Allocator, schemas: *Schemas, out: *std.Io.Writer, mode: JsonMode, line: []const u8) !void {
    var d: haus.Diagnostic = .{};
    var text: []const u8 = undefined;
    var def: ?*const haus.schema.Def = null;
    if (mode == .write or mode == .read) {
        var parts = std.mem.splitScalar(u8, line, ' ');
        const suite = parts.next().?;
        const type_name = parts.next().?;
        text = try hexDecode(arena, parts.next() orelse "");
        const s = try schemas.get(suite) orelse return out.print("err $ - the schema file {s} is rejected\n", .{suite});
        def = s.get(type_name) orelse return out.print("err $ - no type {s}\n", .{type_name});
    } else text = try hexDecode(arena, line);
    switch (mode) {
        .write, .@"haus-json-write" => {
            const parsed = haus.parseAll(arena, text, .{ .diagnostic = &d }) catch return out.writeAll("err $ - not a single value\n");
            if (parsed.value.len != 1) return out.writeAll("err $ - not a single value\n");
            const json_text = if (mode == .write) blk: {
                const decoded = haus.decoding.decode(arena, def.?, parsed.value[0], .{ .diagnostic = &d }) catch |e| switch (e) {
                    error.Haus => return jsonErr(out, &d),
                    else => return e,
                };
                break :blk haus.json.toJson(arena, def.?, decoded, .{ .diagnostic = &d });
            } else haus.json.toHausJson(arena, parsed.value[0], .{ .diagnostic = &d });
            const j = json_text catch |e| switch (e) {
                error.Haus => return jsonErr(out, &d),
                else => return e,
            };
            try out.print("ok {s}\n", .{j});
        },
        .read => {
            const decoded = haus.json.fromJson(arena, gpa, def.?, text, .{ .diagnostic = &d }) catch |e| switch (e) {
                error.Haus => return jsonErr(out, &d),
                else => return e,
            };
            const encoded = haus.decoding.encode(arena, def.?, decoded, .{ .diagnostic = &d }) catch |e| switch (e) {
                error.Haus => return out.print("CRASH encoding what was read failed: {s} at {s}\n", .{ d.code.name(), d.path() }),
                else => return e,
            };
            try out.print("ok {s}\n", .{try haus.canonical(arena, encoded, .{})});
        },
        .@"haus-json-read", .import => {
            const val = (if (mode == .import) haus.json.importJson(arena, gpa, text, .{ .diagnostic = &d }) else haus.json.fromHausJson(arena, gpa, text, .{ .diagnostic = &d })) catch |e| switch (e) {
                error.Haus => return jsonErr(out, &d),
                else => return e,
            };
            try out.print("ok {s}\n", .{try haus.canonical(arena, val, .{})});
        },
    }
}

/// The JSON modes: `zig-runner --json MODE FILE`.
pub fn runJson(io: std.Io, gpa: Allocator, mode_name: []const u8, path: []const u8) !void {
    const mode = std.meta.stringToEnum(JsonMode, mode_name) orelse return error.UnknownMode;
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(data);
    var buf: [1 << 16]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;
    var schemas: Schemas = .{ .gpa = gpa, .io = io };
    defer schemas.deinit();
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        try jsonCase(arena_state.allocator(), gpa, &schemas, out, mode, line);
    }
    try out.flush();
}
