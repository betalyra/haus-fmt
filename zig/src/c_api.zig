//! The C ABI (include/haus.h): parse to canonical text, hash, format, and
//! errors with their code and position. Text goes in as a pointer and a
//! length (it may hold NUL characters); text comes out in a buffer the
//! library allocates and `haus_free` releases.

const std = @import("std");
const haus = @import("haus");

const allocator = std.heap.smp_allocator;

pub const HAUS_OK: c_int = 0;
/// A mistake with a code of spec §17: see the `haus_error`.
pub const HAUS_ERROR: c_int = 1;
pub const HAUS_OUT_OF_MEMORY: c_int = 2;
/// A misuse of the API: a null pointer, a negative indent or width, an
/// unknown layout (no code of §17 applies).
pub const HAUS_INVALID_ARGUMENT: c_int = 3;
/// A mistake in the schema file (spec §14), with its code and position.
pub const HAUS_SCHEMA_ERROR: c_int = 4;

pub const haus_error = extern struct {
    /// The code of spec §17, NUL-terminated; empty for statuses other than
    /// HAUS_ERROR.
    code: [32]u8,
    /// 1-based (spec §8); 0 where there is no position (invalid UTF-8).
    line: u32,
    column: u32,
    message: [192]u8,
    /// The place in a value (spec §15, §16.3: `$.items[2].price`) for an
    /// error of a decoder or a JSON reader; empty for an error in text.
    path: [256]u8,
};

fn clear(err: ?*haus_error) void {
    if (err) |e| {
        e.code[0] = 0;
        e.line = 0;
        e.column = 0;
        e.message[0] = 0;
        e.path[0] = 0;
    }
}

fn copyZ(dst: []u8, src: []const u8) void {
    var n = @min(src.len, dst.len - 1);
    // Don't cut a UTF-8 sequence.
    while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

fn report(err: ?*haus_error, e: haus.Error, d: *const haus.Diagnostic) c_int {
    switch (e) {
        error.OutOfMemory => return HAUS_OUT_OF_MEMORY,
        error.Haus => {
            if (err) |out| {
                copyZ(&out.code, d.code.name());
                out.line = d.line;
                out.column = d.column;
                copyZ(&out.message, d.message());
                copyZ(&out.path, d.path());
            }
            return HAUS_ERROR;
        },
    }
}

fn input(text: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return "";
    const t = text orelse return null;
    return t[0..len];
}

fn give(bytes: []u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    out.?.* = bytes.ptr;
    out_len.?.* = bytes.len;
    return HAUS_OK;
}

/// The canonical form (spec §12) of each value of a file, each followed by
/// a line feed.
pub export fn haus_canonical(text: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var d: haus.Diagnostic = .{};
    const parsed = haus.parseAll(allocator, t, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    for (parsed.value) |v| {
        haus.canonical_form.appendCanonical(allocator, &buf, v, .{ .diagnostic = &d }) catch |e| {
            buf.deinit(allocator);
            return report(err, e, &d);
        };
        buf.append(allocator, '\n') catch {
            buf.deinit(allocator);
            return HAUS_OUT_OF_MEMORY;
        };
    }
    const owned = buf.toOwnedSlice(allocator) catch return HAUS_OUT_OF_MEMORY;
    return give(owned, out, out_len);
}

/// `hashAll` (spec §12) of a file's values: 64 lowercase hex digits and a
/// NUL into `out`.
pub export fn haus_hash_all(text: ?[*]const u8, len: usize, out: ?*[65]u8, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    var d: haus.Diagnostic = .{};
    const parsed = haus.parseAll(allocator, t, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    defer parsed.deinit();
    const h = haus.hashAll(allocator, parsed.value, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    @memcpy(o[0..64], &h);
    o[64] = 0;
    return HAUS_OK;
}

pub const HAUS_PRETTY: c_int = 0;
pub const HAUS_COMPACT: c_int = 1;
pub const HAUS_MINIMISED: c_int = 2;

/// Formats a file in a layout of spec §11, keeping comments in pretty.
/// `indent` and `width` are pretty's options (2 and 80 by default, taken
/// literally: 0 is 0); a negative one is HAUS_INVALID_ARGUMENT.
pub export fn haus_format(text: ?[*]const u8, len: usize, layout: c_int, indent: c_int, width: c_int, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null or indent < 0 or width < 0) return HAUS_INVALID_ARGUMENT;
    const l: haus.Layout = switch (layout) {
        HAUS_PRETTY => .pretty,
        HAUS_COMPACT => .compact,
        HAUS_MINIMISED => .minimised,
        else => return HAUS_INVALID_ARGUMENT,
    };
    var d: haus.Diagnostic = .{};
    const formatted = haus.format(allocator, t, .{
        .layout = l,
        .indent = @intCast(indent),
        .width = @intCast(width),
        .write = .{ .diagnostic = &d },
    }) catch |e| return report(err, e, &d);
    return give(formatted, out, out_len);
}

/// Releases a buffer the library returned.
pub export fn haus_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| allocator.free(p[0..len]);
}

/// The version of the specification implemented, NUL-terminated.
pub export fn haus_spec_version() [*:0]const u8 {
    return haus.spec_version;
}

// ── schemas (spec §14–§16) ───────────────────────────────────

/// A schema file and one of its types, for the calls below.
const Typed = struct {
    schema: *haus.schema.Schema,
    def: *const haus.schema.Def,

    fn deinit(t: Typed) void {
        t.schema.deinit();
    }
};

fn loadType(schema: ?[*]const u8, schema_len: usize, type_name: ?[*:0]const u8, err: ?*haus_error, status: *c_int) ?Typed {
    const s = input(schema, schema_len) orelse {
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    };
    const name = std.mem.span(type_name orelse {
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    });
    var d: haus.Diagnostic = .{};
    const loaded = haus.schema.load(allocator, s, .{ .diagnostic = &d }) catch |e| {
        status.* = if (report(err, e, &d) == HAUS_ERROR) HAUS_SCHEMA_ERROR else HAUS_OUT_OF_MEMORY;
        return null;
    };
    const def = loaded.get(name) orelse {
        loaded.deinit();
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    };
    if (def.params.len > 0) {
        loaded.deinit();
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    }
    return .{ .schema = loaded, .def = def };
}

/// Checks a haus text against the type `type_name` of a schema file (spec
/// §14, §15): every value for a `Stream` type, exactly one otherwise. A
/// mistake in the schema file is HAUS_SCHEMA_ERROR; one in the text or the
/// value is HAUS_ERROR, with the value's place in `path`.
pub export fn haus_check(schema: ?[*]const u8, schema_len: usize, type_name: ?[*:0]const u8, text: ?[*]const u8, len: usize, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    var status: c_int = HAUS_OK;
    const typed = loadType(schema, schema_len, type_name, err, &status) orelse return status;
    defer typed.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var d: haus.Diagnostic = .{};
    _ = haus.decoding.decodeText(allocator, arena_state.allocator(), typed.def, t, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return HAUS_OK;
}

/// Decodes a haus text with a type of a schema file and writes it as
/// schema-based JSON (spec §16.3).
pub export fn haus_to_json(schema: ?[*]const u8, schema_len: usize, type_name: ?[*:0]const u8, text: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var status: c_int = HAUS_OK;
    const typed = loadType(schema, schema_len, type_name, err, &status) orelse return status;
    defer typed.deinit();
    if (typed.def.stream) return HAUS_INVALID_ARGUMENT;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var d: haus.Diagnostic = .{};
    const decoded = haus.decoding.decodeText(allocator, arena_state.allocator(), typed.def, t, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    const json = haus.json.toJson(allocator, typed.def, decoded, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return give(json, out, out_len);
}

/// Reads schema-based JSON (spec §16.3) with a type of a schema file and
/// writes the value it encodes to in canonical form (spec §12).
pub export fn haus_from_json(schema: ?[*]const u8, schema_len: usize, type_name: ?[*:0]const u8, json: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const j = input(json, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var status: c_int = HAUS_OK;
    const typed = loadType(schema, schema_len, type_name, err, &status) orelse return status;
    defer typed.deinit();
    if (typed.def.stream) return HAUS_INVALID_ARGUMENT;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: haus.Diagnostic = .{};
    const decoded = haus.json.fromJson(arena, allocator, typed.def, j, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    const val = haus.decoding.encode(arena, typed.def, decoded, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    const c = haus.canonical(allocator, val, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return give(c, out, out_len);
}

// ── tests, through the C ABI ─────────────────────────────────

fn callCanonical(text: []const u8, err: *haus_error) !?[]u8 {
    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    const status = haus_canonical(text.ptr, text.len, &out, &out_len, err);
    if (status != HAUS_OK) return null;
    return out.?[0..out_len];
}

test "canonical through the C ABI" {
    var err: haus_error = undefined;
    const got = (try callCanonical("Order { total: 19.90, id: 0xFF },\n\"a\\u{0}b\",", &err)).?;
    defer haus_free(got.ptr, got.len);
    try std.testing.expectEqualStrings("Order{id:255,total:19.90}\n\"a\\u{0}b\"\n", got);
}

test "errors through the C ABI" {
    var err: haus_error = undefined;
    try std.testing.expect(try callCanonical("[1,\n 2 3]", &err) == null);
    try std.testing.expectEqualStrings("missing-comma", std.mem.sliceTo(&err.code, 0));
    try std.testing.expectEqual(@as(u32, 2), err.line);
    try std.testing.expectEqual(@as(u32, 4), err.column);
    try std.testing.expect(std.mem.sliceTo(&err.message, 0).len > 0);
    // Invalid UTF-8 has no position.
    try std.testing.expect(try callCanonical("\"\xff\"", &err) == null);
    try std.testing.expectEqualStrings("invalid-utf8", std.mem.sliceTo(&err.code, 0));
    try std.testing.expectEqual(@as(u32, 0), err.line);
}

test "hash through the C ABI" {
    var err: haus_error = undefined;
    var out: [65]u8 = undefined;
    try std.testing.expectEqual(HAUS_OK, haus_hash_all("", 0, &out, &err));
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", std.mem.sliceTo(&out, 0));
    const a = "1, \"a\", Order { id: 0xFF },";
    const b = "1,\"a\",Order{id:255}";
    var out_b: [65]u8 = undefined;
    try std.testing.expectEqual(HAUS_OK, haus_hash_all(a, a.len, &out, &err));
    try std.testing.expectEqual(HAUS_OK, haus_hash_all(b, b.len, &out_b, &err));
    try std.testing.expectEqualStrings(&out, &out_b);
}

test "format through the C ABI" {
    var err: haus_error = undefined;
    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    const text = "{ a: Point(1, 2) } // c";
    try std.testing.expectEqual(HAUS_OK, haus_format(text, text.len, HAUS_PRETTY, 4, 0, &out, &out_len, &err));
    defer haus_free(out, out_len);
    try std.testing.expectEqualStrings("{\n    a: Point(\n        1,\n        2,\n    ),\n} // c\n", out.?[0..out_len]);
    try std.testing.expectEqual(HAUS_INVALID_ARGUMENT, haus_format(text, text.len, HAUS_PRETTY, -1, 80, &out, &out_len, &err));
    try std.testing.expectEqual(HAUS_INVALID_ARGUMENT, haus_format(text, text.len, 7, 2, 80, &out, &out_len, &err));
    var min: ?[*]u8 = null;
    try std.testing.expectEqual(HAUS_OK, haus_format(text, text.len, HAUS_MINIMISED, 0, 0, &min, &out_len, &err));
    defer haus_free(min, out_len);
    try std.testing.expectEqualStrings("{a:Point(1,2)}\n", min.?[0..out_len]);
}

test "schemas through the C ABI" {
    var err: haus_error = undefined;
    const schema = "type Order = { id: Int, lines: Array Line }\ntype Line = { qty: UInt8 }\ntype Log = Stream Line";
    const ok = "{ id: 1, lines: [{ qty: 2 }] }";
    try std.testing.expectEqual(HAUS_OK, haus_check(schema, schema.len, "Order", ok, ok.len, &err));
    const bad = "{ id: 1, lines: [{ qty: 300 }] }";
    try std.testing.expectEqual(HAUS_ERROR, haus_check(schema, schema.len, "Order", bad, bad.len, &err));
    try std.testing.expectEqualStrings("out-of-range", std.mem.sliceTo(&err.code, 0));
    try std.testing.expectEqualStrings("$.lines[0].qty", std.mem.sliceTo(&err.path, 0));
    const log = "{ qty: 1 },\n{ qty: \"x\" },";
    try std.testing.expectEqual(HAUS_ERROR, haus_check(schema, schema.len, "Log", log, log.len, &err));
    try std.testing.expectEqualStrings("$[1].qty", std.mem.sliceTo(&err.path, 0));
    const broken = "type A = B";
    try std.testing.expectEqual(HAUS_SCHEMA_ERROR, haus_check(broken, broken.len, "A", ok, ok.len, &err));
    try std.testing.expectEqualStrings("unknown-type", std.mem.sliceTo(&err.code, 0));
    try std.testing.expectEqual(HAUS_INVALID_ARGUMENT, haus_check(schema, schema.len, "Nope", ok, ok.len, &err));

    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    try std.testing.expectEqual(HAUS_OK, haus_to_json(schema, schema.len, "Order", ok, ok.len, &out, &out_len, &err));
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"lines\":[{\"qty\":2}]}", out.?[0..out_len]);
    var back: ?[*]u8 = null;
    var back_len: usize = 0;
    try std.testing.expectEqual(HAUS_OK, haus_from_json(schema, schema.len, "Order", out.?, out_len, &back, &back_len, &err));
    haus_free(out, out_len);
    defer haus_free(back, back_len);
    try std.testing.expectEqualStrings("{id:1,lines:[{qty:2}]}", back.?[0..back_len]);
}
