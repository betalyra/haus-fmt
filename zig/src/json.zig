//! The JSON mappings (spec §16): JSON import (§16.1), self-describing JSON
//! (§16.2), schema-based JSON (§16.3) and JSON Lines.
//!
//! JSON is read into a tree first (I-JSON, RFC 7493: no duplicate member
//! names, no unpaired surrogates; number tokens kept as written and held to
//! the number limits of §7), then mapped. An error in the JSON text is at
//! `$` with its line and column; an error in the mapping is at its place in
//! the JSON (§16.3 "Places": member names and array indexes from the root).

const std = @import("std");
const Allocator = std.mem.Allocator;
const v = @import("value.zig");
const Value = v.Value;
const Limits = v.Limits;
const errors = @import("errors.zig");
const Code = errors.Code;
const Diagnostic = errors.Diagnostic;
const Error = errors.Error;
const number = @import("number.zig");
const canonical = @import("canonical.zig");
const schema_mod = @import("schema.zig");
const Expr = schema_mod.Expr;
const Env = schema_mod.Env;
const Def = schema_mod.Def;
const decode_mod = @import("decode.zig");
const Decoded = decode_mod.Decoded;
const Path = decode_mod.Path;
const time = @import("time.zig");

// ── the JSON tree ────────────────────────────────────────────

const TrieNode = struct {
    child: u32 = 0,
    sibling: u32 = 0,
    byte: u8 = 0,
    terminal: bool = false,
};

pub const Json = union(enum) {
    null,
    bool: bool,
    /// The number token as written.
    number: []const u8,
    string: []const u8,
    array: []const Json,
    /// Members in the order they were written; names are unique.
    object: []const Member,

    pub const Member = struct { name: []const u8, value: Json };

    pub fn get(j: Json, name: []const u8) ?Json {
        if (j != .object) return null;
        for (j.object) |m| if (std.mem.eql(u8, m.name, name)) return m.value;
        return null;
    }
};

pub const ReadOptions = struct {
    limits: Limits = .{},
    diagnostic: ?*Diagnostic = null,
};

/// What JSON text the reader accepts besides RFC 8259.
const Flavor = struct {
    /// Self-describing JSON: raw DEL, C1 and bidi controls are rejected (§16).
    strict_controls: bool,
    /// The deepest JSON nesting accepted.
    max_depth: u32,
};

const Reader = struct {
    arena: Allocator,
    gpa: Allocator,
    text: []const u8,
    pos: usize = 0,
    flavor: Flavor,
    limits: Limits,
    diag: ?*Diagnostic,
    depth: u32 = 0,
    chars: std.ArrayList(u8) = .empty,
    /// The member names of the open objects, as a trie (duplicates found in
    /// linear time, §7): children are lists of siblings.
    trie: std.ArrayList(TrieNode) = .empty,
    /// The line of `text[0]` (JSON Lines: the line in the stream).
    base_line: u32 = 1,

    fn fail(r: *Reader, code: Code, at: usize, comptime fmt: []const u8, args: anytype) Error {
        if (r.diag) |d| {
            d.set(code, fmt, args);
            var line = r.base_line;
            var start: usize = 0;
            for (r.text[0..@min(at, r.text.len)], 0..) |c, i| if (c == '\n') {
                line += 1;
                start = i + 1;
            };
            d.line = line;
            d.column = @intCast(1 + v.countCodePoints(r.text[start..@min(at, r.text.len)]));
            d.offset = at;
            d.setPath("$");
        }
        return error.Haus;
    }

    fn syntax(r: *Reader, comptime what: []const u8) Error {
        if (r.pos >= r.text.len) return r.fail(.@"json-syntax", r.pos, "expected " ++ what ++ ", found the end of the text", .{});
        var buf: [16]u8 = undefined;
        return r.fail(.@"json-syntax", r.pos, "expected " ++ what ++ ", found {s}", .{errors.quoteChar(&buf, v.decode(r.text, r.pos).cp)});
    }

    fn ws(r: *Reader) void {
        while (r.pos < r.text.len) switch (r.text[r.pos]) {
            ' ', '\t', '\n', '\r' => r.pos += 1,
            else => return,
        };
    }

    fn document(r: *Reader) Error!Json {
        if (std.mem.startsWith(u8, r.text, "\xEF\xBB\xBF")) r.pos = 3;
        r.ws();
        const j = try r.value();
        r.ws();
        if (r.pos < r.text.len) return r.syntax("the end of the text after the value");
        return j;
    }

    fn enter(r: *Reader) Error!void {
        r.depth += 1;
        if (r.depth > r.flavor.max_depth) return r.fail(.@"nesting-too-deep", r.pos, "JSON nested deeper than {d} levels", .{r.flavor.max_depth});
    }

    fn value(r: *Reader) Error!Json {
        if (r.pos >= r.text.len) return r.syntax("a JSON value");
        switch (r.text[r.pos]) {
            '{' => return r.object(),
            '[' => return r.array(),
            '"' => return .{ .string = try r.string() },
            '-', '0'...'9' => return .{ .number = try r.numberToken() },
            't' => return r.literal("true", .{ .bool = true }),
            'f' => return r.literal("false", .{ .bool = false }),
            'n' => return r.literal("null", .null),
            else => return r.syntax("a JSON value"),
        }
    }

    fn literal(r: *Reader, word: []const u8, j: Json) Error!Json {
        if (!std.mem.startsWith(u8, r.text[r.pos..], word)) return r.syntax("a JSON value");
        r.pos += word.len;
        return j;
    }

    fn array(r: *Reader) Error!Json {
        try r.enter();
        r.pos += 1;
        var items: std.ArrayList(Json) = .empty;
        r.ws();
        if (r.pos < r.text.len and r.text[r.pos] == ']') {
            r.pos += 1;
            r.depth -= 1;
            return .{ .array = &.{} };
        }
        while (true) {
            r.ws();
            try items.append(r.arena, try r.value());
            r.ws();
            if (r.pos >= r.text.len) return r.syntax("',' or ']'");
            if (r.text[r.pos] == ',') {
                r.pos += 1;
                continue;
            }
            if (r.text[r.pos] == ']') break;
            return r.syntax("',' or ']'");
        }
        r.pos += 1;
        r.depth -= 1;
        return .{ .array = items.items };
    }

    /// Inserts a name into the object's trie; false if it was there.
    fn insertName(r: *Reader, root: u32, name: []const u8) Allocator.Error!bool {
        var node = root;
        for (name) |b| {
            var child = r.trie.items[node].child;
            while (child != 0 and r.trie.items[child].byte != b) child = r.trie.items[child].sibling;
            if (child == 0) {
                child = @intCast(r.trie.items.len);
                try r.trie.append(r.gpa, .{ .byte = b, .sibling = r.trie.items[node].child });
                r.trie.items[node].child = child;
            }
            node = child;
        }
        if (r.trie.items[node].terminal) return false;
        r.trie.items[node].terminal = true;
        return true;
    }

    fn object(r: *Reader) Error!Json {
        try r.enter();
        r.pos += 1;
        var members: std.ArrayList(Json.Member) = .empty;
        r.ws();
        if (r.pos < r.text.len and r.text[r.pos] == '}') {
            r.pos += 1;
            r.depth -= 1;
            return .{ .object = &.{} };
        }
        const mark = r.trie.items.len;
        defer r.trie.shrinkRetainingCapacity(mark);
        try r.trie.append(r.gpa, .{});
        const root: u32 = @intCast(mark);
        while (true) {
            r.ws();
            if (r.pos >= r.text.len or r.text[r.pos] != '"') return r.syntax("a member name");
            const name_at = r.pos;
            const name = try r.string();
            // I-JSON: no duplicate names, compared after their escapes are
            // read; found as soon as the name is read.
            if (!try r.insertName(root, name)) {
                var buf: [64]u8 = undefined;
                return r.fail(.@"duplicate-key", name_at, "duplicate member name {s}", .{errors.quoteText(&buf, name)});
            }
            r.ws();
            if (r.pos >= r.text.len or r.text[r.pos] != ':') return r.syntax("':'");
            r.pos += 1;
            r.ws();
            try members.append(r.arena, .{ .name = name, .value = try r.value() });
            r.ws();
            if (r.pos >= r.text.len) return r.syntax("',' or '}}'");
            if (r.text[r.pos] == ',') {
                r.pos += 1;
                continue;
            }
            if (r.text[r.pos] == '}') break;
            return r.syntax("',' or '}}'");
        }
        r.pos += 1;
        r.depth -= 1;
        return .{ .object = members.items };
    }

    fn hex4(r: *Reader, at: usize) ?u16 {
        if (at + 4 > r.text.len) return null;
        return std.fmt.parseInt(u16, r.text[at .. at + 4], 16) catch null;
    }

    fn string(r: *Reader) Error![]const u8 {
        const open = r.pos;
        var i = r.pos + 1;
        r.chars.clearRetainingCapacity();
        var count: usize = 0;
        while (true) {
            if (i >= r.text.len) return r.fail(.@"unterminated-string", open, "unterminated string", .{});
            const c = r.text[i];
            if (c == '"') break;
            if (c == '\\') {
                if (i + 1 >= r.text.len) return r.fail(.@"invalid-escape", i, "invalid escape: '\\' at the end of the text", .{});
                const e = r.text[i + 1];
                const simple: ?u8 = switch (e) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'b' => 8,
                    'f' => 12,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => null,
                };
                if (simple) |s| {
                    try r.chars.append(r.gpa, s);
                    i += 2;
                } else if (e == 'u') {
                    const hi = r.hex4(i + 2) orelse return r.fail(.@"invalid-unicode-escape", i, "\\u needs four hex digits", .{});
                    var cp: u21 = hi;
                    var len: usize = 6;
                    if (hi >= 0xD800 and hi <= 0xDBFF) {
                        if (i + 7 < r.text.len and r.text[i + 6] == '\\' and r.text[i + 7] == 'u') {
                            const lo = r.hex4(i + 8) orelse return r.fail(.@"invalid-unicode-escape", i + 6, "\\u needs four hex digits", .{});
                            if (lo < 0xDC00 or lo > 0xDFFF) return r.fail(.@"unpaired-surrogate", i, "a high surrogate \\u{X:0>4} without its low half", .{hi});
                            cp = 0x10000 + ((@as(u21, hi) - 0xD800) << 10) + (lo - 0xDC00);
                            len = 12;
                        } else return r.fail(.@"unpaired-surrogate", i, "a high surrogate \\u{X:0>4} without its low half", .{hi});
                    } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
                        return r.fail(.@"unpaired-surrogate", i, "a low surrogate \\u{X:0>4} without its high half", .{hi});
                    }
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                    try r.chars.appendSlice(r.gpa, buf[0..n]);
                    i += len;
                } else {
                    var buf: [16]u8 = undefined;
                    return r.fail(.@"invalid-escape", i, "invalid escape: '\\' followed by {s}", .{errors.quoteChar(&buf, v.decode(r.text, i + 1).cp)});
                }
            } else {
                const d = v.decode(r.text, i);
                if (d.cp < 0x20) return r.fail(.@"control-character", i, "raw control character U+{X:0>4} in a JSON string", .{d.cp});
                if (r.flavor.strict_controls) {
                    if (v.isControl(d.cp)) return r.fail(.@"control-character", i, "raw control character U+{X:0>4}: self-describing JSON escapes it", .{d.cp});
                    if (v.isBidi(d.cp)) return r.fail(.@"bidi-control", i, "raw bidirectional control U+{X:0>4}: self-describing JSON escapes it", .{d.cp});
                }
                try r.chars.appendSlice(r.gpa, r.text[i .. i + d.len]);
                i += d.len;
            }
            count += 1;
            if (count > r.limits.max_string_length) return r.fail(.@"string-too-long", open, "string longer than {d} characters", .{r.limits.max_string_length});
        }
        r.pos = i + 1;
        return r.arena.dupe(u8, r.chars.items);
    }

    /// A JSON number token, held to the number limits (§16 "Limits").
    fn numberToken(r: *Reader) Error![]const u8 {
        const start = r.pos;
        var i = start;
        const t = r.text;
        if (t[i] == '-') i += 1;
        if (i >= t.len or !std.ascii.isDigit(t[i])) return r.syntax("a digit");
        if (t[i] == '0') {
            i += 1;
        } else while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i < t.len and t[i] == '.') {
            i += 1;
            const f = i;
            while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
            if (i == f) {
                r.pos = i;
                return r.syntax("a digit after '.'");
            }
        }
        if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
            i += 1;
            if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
            const f = i;
            while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
            if (i == f) {
                r.pos = i;
                return r.syntax("a digit in the exponent");
            }
        }
        const token = t[start..i];
        try checkNumberLimits(token, r.limits, r, start);
        r.pos = i;
        return token;
    }
};

/// The number limits of §7 on a decimal literal as written: its length and
/// the absolute value of its exponent.
fn numberLimitCode(token: []const u8, limits: Limits) ?Code {
    if (v.countCodePoints(token) > limits.max_number_length) return .@"number-too-long";
    if (std.mem.indexOfAny(u8, token, "eE")) |e| {
        var digits = token[e + 1 ..];
        if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) digits = digits[1..];
        const trimmed = std.mem.trimStart(u8, digits, "0");
        if (trimmed.len > 9) return .@"exponent-too-large";
        const x = std.fmt.parseInt(u64, if (trimmed.len == 0) "0" else trimmed, 10) catch return .@"exponent-too-large";
        if (x > limits.max_exponent) return .@"exponent-too-large";
    }
    return null;
}

fn checkNumberLimits(token: []const u8, limits: Limits, r: *Reader, at: usize) Error!void {
    if (numberLimitCode(token, limits)) |code| return switch (code) {
        .@"number-too-long" => r.fail(code, at, "number longer than {d} characters", .{limits.max_number_length}),
        else => r.fail(code, at, "exponent larger than {d}", .{limits.max_exponent}),
    };
}

fn readJson(arena: Allocator, gpa: Allocator, text: []const u8, flavor: Flavor, options: ReadOptions) Error!Json {
    if (!std.unicode.utf8ValidateSlice(text)) {
        if (options.diagnostic) |d| {
            d.set(.@"invalid-utf8", "invalid UTF-8", .{});
            d.line = 0;
            d.column = 0;
            d.setPath("$");
        }
        return error.Haus;
    }
    var r: Reader = .{ .arena = arena, .gpa = gpa, .text = text, .flavor = flavor, .limits = options.limits, .diag = options.diagnostic };
    defer r.chars.deinit(gpa);
    defer r.trie.deinit(gpa);
    return r.document();
}

/// Reads any JSON text (RFC 8259, I-JSON), nested at most `max_depth` deep.
pub fn parse(arena: Allocator, gpa: Allocator, text: []const u8, max_depth: u32, options: ReadOptions) Error!Json {
    return readJson(arena, gpa, text, .{ .strict_controls = false, .max_depth = max_depth }, options);
}

// ── mapping errors ───────────────────────────────────────────

fn failAt(diag: ?*Diagnostic, code: Code, path: *const Path, comptime fmt: []const u8, args: anytype) Error {
    if (diag) |d| {
        d.set(code, fmt, args);
        d.line = 0;
        d.column = 0;
        d.offset = 0;
        var buf: [Diagnostic.path_capacity]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var out: std.ArrayList(u8) = .empty;
        path.write(fba.allocator(), &out) catch {};
        d.setPath(out.items);
    }
    return error.Haus;
}

/// The depth of a value as values built in code count it (§7: a record
/// payload is one level), checked against the limit (§16 "Limits").
fn checkDepth(val: Value, limits: Limits, diag: ?*Diagnostic) Error!void {
    if (depthOf(val, 0, limits.max_depth) > limits.max_depth) {
        if (diag) |d| {
            d.set(.@"nesting-too-deep", "the value is nested deeper than {d} levels", .{limits.max_depth});
            d.line = 0;
            d.column = 0;
            d.setPath("$");
        }
        return error.Haus;
    }
}

fn depthOf(val: Value, depth: u32, max: u32) u32 {
    if (depth > max) return depth;
    return switch (val) {
        .array => |items| blk: {
            var m = depth + 1;
            for (items) |x| m = @max(m, depthOf(x, depth + 1, max));
            break :blk m;
        },
        .record => |fields| blk: {
            var m = depth + 1;
            for (fields) |f| m = @max(m, depthOf(f.value, depth + 1, max));
            break :blk m;
        },
        .variant => |x| blk: {
            if (x.args.len == 0) break :blk depth;
            var m = depth + 1;
            if (x.args.len == 1 and x.args[0] == .record) {
                for (x.args[0].record) |f| m = @max(m, depthOf(f.value, depth + 1, max));
            } else for (x.args) |a| {
                m = @max(m, depthOf(a, depth + 1, max));
            }
            break :blk m;
        },
        else => depth,
    };
}

fn normalized(arena: Allocator, token: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try number.appendNormalized(arena, &out, token);
    return out.items;
}

// ── JSON import (§16.1) ──────────────────────────────────────

fn importValue(arena: Allocator, j: Json) Allocator.Error!Value {
    return switch (j) {
        .null => Value.tag("None"),
        .bool => |b| Value.tag(if (b) "True" else "False"),
        .number => |n| .{ .number = try normalized(arena, n) },
        .string => |s| .{ .string = s },
        .array => |items| blk: {
            const out = try arena.alloc(Value, items.len);
            for (items, 0..) |x, i| out[i] = try importValue(arena, x);
            break :blk .{ .array = out };
        },
        .object => |members| blk: {
            const out = try arena.alloc(v.Field, members.len);
            for (members, 0..) |m, i| out[i] = .{ .key = m.name, .value = try importValue(arena, m.value) };
            break :blk .{ .record = out };
        },
    };
}

/// Reads any JSON text as a haus value (§16.1): nothing in it is special.
pub fn importJson(arena: Allocator, gpa: Allocator, text: []const u8, options: ReadOptions) Error!Value {
    const j = try readJson(arena, gpa, text, .{ .strict_controls = false, .max_depth = options.limits.max_depth }, options);
    return importValue(arena, j);
}

// ── self-describing JSON (§16.2) ─────────────────────────────

fn hausValue(arena: Allocator, j: Json, path: *const Path, options: ReadOptions) Error!Value {
    const diag = options.diagnostic;
    switch (j) {
        .string => |s| return .{ .string = s },
        .array => |items| {
            const out = try arena.alloc(Value, items.len);
            for (items, 0..) |x, i| {
                const p = path.index(i);
                out[i] = try hausValue(arena, x, &p, options);
            }
            return .{ .array = out };
        },
        .object => |members| {
            if (members.len == 1 and std.mem.eql(u8, members[0].name, "_num")) {
                const p = path.key("_num");
                const n = members[0].value;
                if (n != .string) return failAt(diag, .@"haus-json-number", &p, "_num is not a string", .{});
                if (!number.isNormalized(n.string)) {
                    var buf: [64]u8 = undefined;
                    return failAt(diag, .@"haus-json-number", &p, "{s} is not a normalized number literal", .{errors.quoteText(&buf, n.string)});
                }
                if (numberLimitCode(n.string, options.limits)) |code| return failAt(diag, code, &p, "the number is outside the limits", .{});
                return .{ .number = n.string };
            }
            if (members.len == 1 and std.mem.eql(u8, members[0].name, "_bytes")) {
                const p = path.key("_bytes");
                const b = members[0].value;
                if (b != .string or b.string.len % 2 != 0) return failAt(diag, .@"haus-json-bytes", &p, "_bytes is not two lowercase hex digits per byte", .{});
                for (b.string) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) {
                    return failAt(diag, .@"haus-json-bytes", &p, "_bytes is not two lowercase hex digits per byte", .{});
                };
                const out = try arena.alloc(u8, b.string.len / 2);
                _ = std.fmt.hexToBytes(out, b.string) catch unreachable;
                return .{ .bytes = out };
            }
            if (members.len == 1 and std.mem.eql(u8, members[0].name, "_rec")) {
                const p = path.key("_rec");
                const rec = members[0].value;
                if (rec != .object) return failAt(diag, .@"haus-json-form", &p, "_rec is not an object", .{});
                const out = try arena.alloc(v.Field, rec.object.len);
                for (rec.object, 0..) |m, i| {
                    const q = p.key(m.name);
                    out[i] = .{ .key = m.name, .value = try hausValue(arena, m.value, &q, options) };
                }
                return .{ .record = out };
            }
            const tag = j.get("_tag");
            const args = j.get("_args");
            if (tag != null and (members.len == 1 or (members.len == 2 and args != null))) {
                if (tag.? != .string or !v.isTag(tag.?.string)) return failAt(diag, .@"invalid-tag", path, "_tag is not a tag", .{});
                if (args) |a| {
                    const p = path.key("_args");
                    if (a != .array or a.array.len == 0) return failAt(diag, .@"haus-json-form", &p, "_args is not a non-empty array", .{});
                    const out = try arena.alloc(Value, a.array.len);
                    for (a.array, 0..) |x, i| {
                        const q = p.index(i);
                        out[i] = try hausValue(arena, x, &q, options);
                    }
                    return .{ .variant = .{ .tag = tag.?.string, .args = out } };
                }
                return Value.tag(tag.?.string);
            }
            return failAt(diag, .@"haus-json-form", path, "an object that is none of the forms of self-describing JSON", .{});
        },
        .number => return failAt(diag, .@"haus-json-form", path, "a bare number: write {{\"_num\": \"…\"}}", .{}),
        .bool => return failAt(diag, .@"haus-json-form", path, "true or false: write {{\"_tag\": \"True\"}}", .{}),
        .null => return failAt(diag, .@"haus-json-form", path, "null: write {{\"_tag\": \"None\"}}", .{}),
    }
}

fn envelope(arena: Allocator, j: Json, path: *const Path, options: ReadOptions) Error!Value {
    const diag = options.diagnostic;
    if (j != .object or j.object.len != 2) return failAt(diag, .@"haus-json-form", path, "not an envelope {{\"_haus\": 1, \"_value\": …}}", .{});
    const version = j.get("_haus") orelse return failAt(diag, .@"haus-json-form", path, "not an envelope {{\"_haus\": 1, \"_value\": …}}", .{});
    const val = j.get("_value") orelse return failAt(diag, .@"haus-json-form", path, "not an envelope {{\"_haus\": 1, \"_value\": …}}", .{});
    if (version != .number or !std.mem.eql(u8, version.number, "1")) {
        const p = path.key("_haus");
        return failAt(diag, .@"haus-json-version", &p, "_haus is not 1, the only version of the form", .{});
    }
    const p = path.key("_value");
    const out = try hausValue(arena, val, &p, options);
    try checkDepth(out, options.limits, diag);
    return out;
}

fn hausFlavor(limits: Limits) Flavor {
    return .{ .strict_controls = true, .max_depth = 4 * limits.max_depth + 2 };
}

/// Reads self-describing JSON (§16.2): an envelope around one value.
pub fn fromHausJson(arena: Allocator, gpa: Allocator, text: []const u8, options: ReadOptions) Error!Value {
    const j = try readJson(arena, gpa, text, hausFlavor(options.limits), options);
    return envelope(arena, j, &Path.root, options);
}

/// Reads JSON Lines of self-describing JSON (§16 "Streams"): one envelope
/// per line. An error's place starts with the line's index (`$[3]`).
pub fn fromHausJsonLines(arena: Allocator, gpa: Allocator, text: []const u8, options: ReadOptions) Error![]const Value {
    var out: std.ArrayList(Value) = .empty;
    var rest = text;
    if (std.mem.startsWith(u8, rest, "\xEF\xBB\xBF")) rest = rest[3..];
    var index: usize = 0;
    var line_no: u32 = 1;
    while (rest.len > 0) : (index += 1) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        var line = if (nl) |k| rest[0..k] else rest;
        rest = if (nl) |k| rest[k + 1 ..] else rest[rest.len..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const p = Path.root.index(index);
        if (std.mem.trim(u8, line, " \t").len == 0) {
            if (options.diagnostic) |d| {
                d.set(.@"json-syntax", "line {d} is empty: no JSON text", .{line_no});
                d.line = line_no;
                d.column = 1;
                d.setPath("$");
            }
            return error.Haus;
        }
        if (std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) {
            if (options.diagnostic) |d| {
                d.set(.@"json-syntax", "a byte order mark at the start of line {d}", .{line_no});
                d.line = line_no;
                d.column = 1;
                d.setPath("$");
            }
            return error.Haus;
        }
        if (!std.unicode.utf8ValidateSlice(line)) {
            if (options.diagnostic) |d| {
                d.set(.@"invalid-utf8", "invalid UTF-8", .{});
                d.line = 0;
                d.column = 0;
                d.setPath("$");
            }
            return error.Haus;
        }
        var r: Reader = .{ .arena = arena, .gpa = gpa, .text = line, .flavor = hausFlavor(options.limits), .limits = options.limits, .diag = options.diagnostic, .base_line = line_no };
        defer r.chars.deinit(gpa);
        defer r.trie.deinit(gpa);
        const j = r.document() catch |e| {
            if (options.diagnostic) |d| {
                var buf: [32]u8 = undefined;
                d.setPath(std.fmt.bufPrint(&buf, "$[{d}]", .{index}) catch "$");
            }
            return e;
        };
        try out.append(arena, try envelope(arena, j, &p, options));
        line_no += 1;
    }
    return out.items;
}

/// Appends `s` as a JSON string, escaping what §16 asks writers to escape.
pub fn appendString(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        const d = v.decode(s, i);
        switch (d.cp) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => if (v.isControl(d.cp) or v.isBidi(d.cp) or d.cp == 0x2028 or d.cp == 0x2029) {
                try out.print(gpa, "\\u{x:0>4}", .{d.cp});
            } else try out.appendSlice(gpa, s[i .. i + d.len]),
        }
        i += d.len;
    }
    try out.append(gpa, '"');
}

/// The self-describing form of a value, without the envelope.
pub fn appendHausValue(gpa: Allocator, out: *std.ArrayList(u8), val: Value) Allocator.Error!void {
    switch (val) {
        .string => |s| try appendString(gpa, out, s),
        .number => |n| {
            try out.appendSlice(gpa, "{\"_num\":");
            try appendString(gpa, out, n);
            try out.append(gpa, '}');
        },
        .bytes => |b| {
            try out.appendSlice(gpa, "{\"_bytes\":\"");
            for (b) |byte| try out.print(gpa, "{x:0>2}", .{byte});
            try out.appendSlice(gpa, "\"}");
        },
        .array => |items| {
            try out.append(gpa, '[');
            for (items, 0..) |x, i| {
                if (i > 0) try out.append(gpa, ',');
                try appendHausValue(gpa, out, x);
            }
            try out.append(gpa, ']');
        },
        .record => |fields| {
            try out.appendSlice(gpa, "{\"_rec\":{");
            for (fields, 0..) |f, i| {
                if (i > 0) try out.append(gpa, ',');
                try appendString(gpa, out, f.key);
                try out.append(gpa, ':');
                try appendHausValue(gpa, out, f.value);
            }
            try out.appendSlice(gpa, "}}");
        },
        .variant => |x| {
            try out.appendSlice(gpa, "{\"_tag\":");
            try appendString(gpa, out, x.tag);
            if (x.args.len > 0) {
                try out.appendSlice(gpa, ",\"_args\":[");
                for (x.args, 0..) |a, i| {
                    if (i > 0) try out.append(gpa, ',');
                    try appendHausValue(gpa, out, a);
                }
                try out.append(gpa, ']');
            }
            try out.append(gpa, '}');
        },
    }
}

/// Writes a value as self-describing JSON (§16.2), in its envelope. The
/// value is checked as written (values built in code, §11).
pub fn toHausJson(gpa: Allocator, val: Value, options: canonical.WriteOptions) Error![]u8 {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(gpa);
    try canonical.appendCanonical(gpa, &sink, val, options);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"_haus\":1,\"_value\":");
    try appendHausValue(gpa, &out, val);
    try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
}

// ── schema-based JSON (§16.3) ────────────────────────────────

/// A type with its arguments: an expression and where its parameters stand.
const Typed = struct { e: *const Expr, env: ?*const Env };

/// The type without parentheses and names, and without `Secret` when
/// `secret` is set: what decides the JSON form.
fn unfold(arena: Allocator, t0: Typed, through_secret: bool) Allocator.Error!Typed {
    var t = t0;
    var steps: usize = 0;
    while (steps < 1 << 16) : (steps += 1) {
        switch (t.e.kind) {
            .paren => |inner| t.e = inner,
            .param => |p| {
                const en = t.env.?;
                t = .{ .e = en.args[p.index], .env = en.parent };
            },
            .name => |n| switch (n.ref) {
                .def => |d| {
                    if (d.prelude != .none) return t;
                    t = .{ .e = d.body, .env = try pushEnv(arena, n.args, t.env) };
                },
                .builtin => |b| {
                    if (b == .Secret and through_secret) {
                        t.e = n.args[0];
                    } else return t;
                },
                else => return t,
            },
            else => return t,
        }
    }
    return t;
}

fn pushEnv(arena: Allocator, args: []const *Expr, parent: ?*const Env) Allocator.Error!?*const Env {
    if (args.len == 0) return null;
    const en = try arena.create(Env);
    en.* = .{ .args = args, .parent = parent };
    return en;
}

fn preludeOf(t: Typed) schema_mod.Prelude {
    if (t.e.kind != .name) return .none;
    return switch (t.e.kind.name.ref) {
        .def => |d| d.prelude,
        else => .none,
    };
}

/// Whether a `Maybe` written at `m` reaches itself through `Maybe`,
/// `Secret` and names only (§16.3: then it always uses the tagged form).
fn reachesItself(arena: Allocator, m: Typed) Allocator.Error!bool {
    var t: Typed = .{ .e = m.e.kind.name.args[0], .env = m.env };
    var steps: usize = 0;
    while (steps < 4096) : (steps += 1) {
        t = try unfold(arena, t, true);
        if (preludeOf(t) != .Maybe) return false;
        if (t.e == m.e) return true;
        t = .{ .e = t.e.kind.name.args[0], .env = t.env };
    }
    return false;
}

/// Whether a type's JSON can be `null` (§16.3): a `Maybe` that uses `null`,
/// directly or through names and `Secret`.
fn nullable(arena: Allocator, t0: Typed) Allocator.Error!bool {
    const t = try unfold(arena, t0, true);
    if (preludeOf(t) != .Maybe) return false;
    return usesNull(arena, t);
}

/// Whether the prelude `Maybe` at `m` writes `None` as `null`.
fn usesNull(arena: Allocator, m: Typed) Allocator.Error!bool {
    if (try reachesItself(arena, m)) return false;
    return !(try nullable(arena, .{ .e = m.e.kind.name.args[0], .env = m.env }));
}

/// A closed variant whose tags all have no payload (`Bool` aside): written
/// as a string.
fn isEnum(vt: *const schema_mod.VariantType) bool {
    if (!vt.closed) return false;
    for (vt.cases) |c| if (c.form != .none) return false;
    return true;
}

fn appendBase64(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Allocator.Error!void {
    const enc = std.base64.standard.Encoder;
    const start = out.items.len;
    try out.resize(gpa, start + enc.calcSize(bytes.len));
    _ = enc.encode(out.items[start..], bytes);
}

const Writer = struct {
    arena: Allocator,
    gpa: Allocator,
    out: *std.ArrayList(u8),
    diag: ?*Diagnostic,

    fn put(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.out.appendSlice(w.gpa, s);
    }

    fn write(w: *Writer, t0: Typed, d: Decoded, path: *const Path) Error!void {
        const t = try unfold(w.arena, t0, false);
        switch (t.e.kind) {
            .record => |rec| return w.record(rec, t.env, d.record, path),
            .variant => |vt| return w.variant(vt, t.env, d, path),
            .name => |n| switch (n.ref) {
                .time => return appendString(w.gpa, w.out, d.time.text),
                .builtin => |b| return w.builtin(b, n.args, t.env, d, path),
                .def => |def| switch (def.prelude) {
                    .Bool => return w.put(if (std.mem.eql(u8, d.variant.tag, "True")) "true" else "false"),
                    .Maybe => {
                        if (try usesNull(w.arena, t)) {
                            if (std.mem.eql(u8, d.variant.tag, "None")) return w.put("null");
                            return w.write(.{ .e = n.args[0], .env = t.env }, d.variant.args[0], path);
                        }
                        return w.variant(def.body.kind.variant, try pushEnv(w.arena, n.args, t.env), d, path);
                    },
                    .Result => return w.variant(def.body.kind.variant, try pushEnv(w.arena, n.args, t.env), d, path),
                    .none => unreachable,
                },
                .unresolved => unreachable,
            },
            else => unreachable,
        }
    }

    fn builtin(w: *Writer, b: schema_mod.Builtin, args: []const *Expr, env: ?*const Env, d: Decoded, path: *const Path) Error!void {
        switch (b) {
            .String => try appendString(w.gpa, w.out, d.string),
            .Bytes => {
                try w.put("\"");
                try appendBase64(w.gpa, w.out, d.bytes);
                try w.put("\"");
            },
            .Int8, .Int16, .Int32, .UInt8, .UInt16, .UInt32 => try w.put(d.int),
            .Int, .Int64, .UInt64 => try appendString(w.gpa, w.out, d.int),
            .Float64, .Float32 => {
                const x: f64 = if (b == .Float64) d.float64 else d.float32;
                if (std.math.isNan(x)) return w.put("\"NaN\"");
                if (std.math.isInf(x)) return w.put(if (x > 0) "\"Infinity\"" else "\"-Infinity\"");
                var buf: [64]u8 = undefined;
                try w.put(if (b == .Float64) decode_mod.formatFloat(f64, d.float64, &buf) else decode_mod.formatFloat(f32, d.float32, &buf));
            },
            .Decimal => try appendString(w.gpa, w.out, d.decimal),
            .Any => try appendHausValue(w.gpa, w.out, d.any),
            .Secret => try w.write(.{ .e = args[0], .env = env }, d.secret.*, path),
            .Array => {
                try w.put("[");
                for (d.array, 0..) |x, i| {
                    if (i > 0) try w.put(",");
                    const p = path.index(i);
                    try w.write(.{ .e = args[0], .env = env }, x, &p);
                }
                try w.put("]");
            },
            .Map => {
                try w.put("{");
                for (d.map, 0..) |e, i| {
                    if (i > 0) try w.put(",");
                    try appendString(w.gpa, w.out, e.key);
                    try w.put(":");
                    const p = path.key(e.key);
                    try w.write(.{ .e = args[0], .env = env }, e.value, &p);
                }
                try w.put("}");
            },
            .Stream => unreachable,
        }
    }

    fn fields(w: *Writer, rec: *const schema_mod.RecordType, env: ?*const Env, entries: []const Decoded.Entry, path: *const Path, first: bool) Error!void {
        var sep = !first;
        for (entries) |e| {
            const field = rec.fields[rec.index.get(e.key).?];
            if (sep) try w.put(",");
            sep = true;
            try appendString(w.gpa, w.out, e.key);
            try w.put(":");
            const p = path.key(e.key);
            try w.write(.{ .e = field.type, .env = field.env orelse env }, e.value, &p);
        }
    }

    fn record(w: *Writer, rec: *const schema_mod.RecordType, env: ?*const Env, entries: []const Decoded.Entry, path: *const Path) Error!void {
        try w.put("{");
        try w.fields(rec, env, entries, path, true);
        try w.put("}");
    }

    fn variant(w: *Writer, vt: *const schema_mod.VariantType, env: ?*const Env, d: Decoded, path: *const Path) Error!void {
        if (d == .unknown) {
            try w.put("{\"_tag\":");
            try appendString(w.gpa, w.out, d.unknown.tag);
            if (d.unknown.args.len > 0) {
                try w.put(",\"_args\":[");
                for (d.unknown.args, 0..) |a, i| {
                    if (i > 0) try w.put(",");
                    try appendHausValue(w.gpa, w.out, a);
                }
                try w.put("]");
            }
            return w.put("}");
        }
        const t = d.variant;
        if (isEnum(vt)) return appendString(w.gpa, w.out, t.tag);
        const case = vt.cases[vt.index.get(t.tag).?];
        const case_env = case.env orelse env;
        switch (case.form) {
            .none => {
                try w.put("{\"_tag\":");
                try appendString(w.gpa, w.out, t.tag);
                try w.put("}");
            },
            .record => {
                const target = try decode_mod.unfoldRecord(w.arena, case.args[0], case_env);
                if (target.rec.index.contains("_tag") or target.rec.index.contains("_args")) {
                    return failAt(w.diag, .@"no-json-form", path, "{s} has a field named _tag or _args: it has no schema-based JSON form", .{t.tag});
                }
                try w.put("{\"_tag\":");
                try appendString(w.gpa, w.out, t.tag);
                try w.fields(target.rec, target.env, t.args[0].record, path, false);
                try w.put("}");
            },
            .positional => {
                try w.put("{\"_tag\":");
                try appendString(w.gpa, w.out, t.tag);
                if (case.args.len == 1) {
                    try w.put(",\"value\":");
                    const p = path.key("value");
                    try w.write(.{ .e = case.args[0], .env = case_env }, t.args[0], &p);
                } else {
                    try w.put(",\"values\":[");
                    const vp = path.key("values");
                    for (t.args, 0..) |a, i| {
                        if (i > 0) try w.put(",");
                        const p = vp.index(i);
                        try w.write(.{ .e = case.args[i], .env = case_env }, a, &p);
                    }
                    try w.put("]");
                }
                try w.put("}");
            },
        }
    }
};

pub const WriteJsonOptions = struct {
    diagnostic: ?*Diagnostic = null,
};

/// Writes a decoded value of `def` as schema-based JSON (§16.3).
pub fn toJson(gpa: Allocator, def: *const Def, d: Decoded, options: WriteJsonOptions) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: Writer = .{ .arena = arena_state.allocator(), .gpa = gpa, .out = &out, .diag = options.diagnostic };
    try w.write(.{ .e = def.body, .env = null }, d, &Path.root);
    return out.toOwnedSlice(gpa);
}

// ── reading schema-based JSON ────────────────────────────────

const JsonReader = struct {
    arena: Allocator,
    diag: ?*Diagnostic,
    options: ReadOptions,
    secret_depth: u32 = 0,

    fn fail(r: *JsonReader, code: Code, path: *const Path, comptime fmt: []const u8, args: anytype) Error {
        return failAt(r.diag, code, path, fmt, args);
    }

    fn kindName(j: Json) []const u8 {
        return switch (j) {
            .null => "null",
            .bool => "true or false",
            .number => "a number",
            .string => "a string",
            .array => "an array",
            .object => "an object",
        };
    }

    fn mismatch(r: *JsonReader, path: *const Path, comptime expected: []const u8, j: Json) Error {
        return r.fail(.@"type-mismatch", path, "expected " ++ expected ++ ", found {s}", .{kindName(j)});
    }

    fn read(r: *JsonReader, t0: Typed, j: Json, path: *const Path) Error!Decoded {
        const t = try unfold(r.arena, t0, false);
        switch (t.e.kind) {
            .record => |rec| {
                if (j != .object) return r.mismatch(path, "an object", j);
                return .{ .record = try r.recordFields(rec, t.env, j.object, path, null) };
            },
            .variant => |vt| return r.variant(vt, t.env, j, path),
            .name => |n| switch (n.ref) {
                .time => |k| {
                    if (j != .string) return r.mismatch(path, "a string", j);
                    if (!time.check(k, j.string)) return r.fail(.@"invalid-time", path, "not a valid {s} of the std/time profile", .{k.typeName()});
                    return .{ .time = .{ .kind = k, .text = j.string } };
                },
                .builtin => |b| return r.builtin(b, n.args, t.env, j, path),
                .def => |def| switch (def.prelude) {
                    .Bool => {
                        if (j != .bool) return r.mismatch(path, "true or false", j);
                        return .{ .variant = .{ .tag = if (j.bool) "True" else "False" } };
                    },
                    .Maybe => {
                        if (try usesNull(r.arena, t)) {
                            if (j == .null) return .{ .variant = .{ .tag = "None" } };
                            const inner = try r.read(.{ .e = n.args[0], .env = t.env }, j, path);
                            const args = try r.arena.alloc(Decoded, 1);
                            args[0] = inner;
                            return .{ .variant = .{ .tag = "Some", .args = args } };
                        }
                        return r.variant(def.body.kind.variant, try pushEnv(r.arena, n.args, t.env), j, path);
                    },
                    .Result => return r.variant(def.body.kind.variant, try pushEnv(r.arena, n.args, t.env), j, path),
                    .none => unreachable,
                },
                .unresolved => unreachable,
            },
            else => unreachable,
        }
    }

    fn bigInteger(r: *JsonReader, b: schema_mod.Builtin, j: Json, path: *const Path) Error!Decoded {
        if (j != .string) return r.mismatch(path, "a string holding an integer", j);
        const s = j.string;
        var buf: [64]u8 = undefined;
        // -?(0|[1-9][0-9]*)
        const body = if (s.len > 0 and s[0] == '-') s[1..] else s;
        const whole = body.len > 0 and (std.mem.eql(u8, body, "0") or (body[0] >= '1' and body[0] <= '9')) and for (body) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true;
        if (!whole) {
            if (isJsonNumber(s)) return r.fail(.@"not-an-integer", path, "{s} is not a whole number", .{errors.quoteText(&buf, s)});
            return r.fail(.@"invalid-number", path, "{s} is not an integer", .{errors.quoteText(&buf, s)});
        }
        const text = if (std.mem.eql(u8, s, "-0")) "0" else s;
        if (b == .Int) {
            if (v.countCodePoints(text) > r.options.limits.max_number_length) return r.fail(.@"number-too-long", path, "integer longer than {d} characters", .{r.options.limits.max_number_length});
            return .{ .int = text };
        }
        const val: Value = .{ .number = text };
        return decode_mod.decodeExpr(r.arena, builtinExpr(b), null, val, .{ .diagnostic = r.diag, .base = path });
    }

    fn builtin(r: *JsonReader, b: schema_mod.Builtin, args: []const *Expr, env: ?*const Env, j: Json, path: *const Path) Error!Decoded {
        var buf: [64]u8 = undefined;
        switch (b) {
            .String => return if (j == .string) .{ .string = j.string } else r.mismatch(path, "a string", j),
            .Bytes => {
                if (j != .string) return r.mismatch(path, "a base64 string", j);
                return .{ .bytes = decodeBase64(r.arena, j.string) orelse return r.fail(.@"invalid-base64", path, "not canonical base64 with padding", .{}) };
            },
            .Int8, .Int16, .Int32, .UInt8, .UInt16, .UInt32 => {
                if (j != .number) return r.mismatch(path, "a number", j);
                return decode_mod.decodeExpr(r.arena, builtinExpr(b), null, .{ .number = try normalized(r.arena, j.number) }, .{ .diagnostic = r.diag, .base = path });
            },
            .Int, .Int64, .UInt64 => return r.bigInteger(b, j, path),
            .Float64, .Float32 => {
                if (j == .string) {
                    const s = j.string;
                    const x: ?f64 = if (std.mem.eql(u8, s, "NaN")) std.math.nan(f64) else if (std.mem.eql(u8, s, "Infinity")) std.math.inf(f64) else if (std.mem.eql(u8, s, "-Infinity")) -std.math.inf(f64) else null;
                    if (x) |f| return if (b == .Float64) .{ .float64 = f } else .{ .float32 = @floatCast(f) };
                    return r.fail(.@"type-mismatch", path, "expected a number, \"NaN\", \"Infinity\" or \"-Infinity\", found {s}", .{errors.quoteText(&buf, s)});
                }
                if (j != .number) return r.mismatch(path, "a number", j);
                return decode_mod.decodeExpr(r.arena, builtinExpr(b), null, .{ .number = try normalized(r.arena, j.number) }, .{ .diagnostic = r.diag, .base = path });
            },
            .Decimal => {
                if (j != .string) return r.mismatch(path, "a string holding a number", j);
                if (!isJsonNumber(j.string)) return r.fail(.@"invalid-number", path, "{s} is not a JSON number literal", .{errors.quoteText(&buf, j.string)});
                if (numberLimitCode(j.string, r.options.limits)) |code| return r.fail(code, path, "the number is outside the limits", .{});
                return .{ .decimal = try normalized(r.arena, j.string) };
            },
            .Any => return .{ .any = try hausValue(r.arena, j, path, r.options) },
            .Secret => {
                r.secret_depth += 1;
                defer r.secret_depth -= 1;
                const inner = r.read(.{ .e = args[0], .env = env }, j, path) catch |e| switch (e) {
                    error.Haus => return r.fail(.@"invalid-secret", path, "the value of this Secret is not valid for its type (the value is not shown)", .{}),
                    else => return e,
                };
                const box = try r.arena.create(Decoded);
                box.* = inner;
                return .{ .secret = box };
            },
            .Array => {
                if (j != .array) return r.mismatch(path, "an array", j);
                const out = try r.arena.alloc(Decoded, j.array.len);
                for (j.array, 0..) |x, i| {
                    const p = path.index(i);
                    out[i] = try r.read(.{ .e = args[0], .env = env }, x, &p);
                }
                return .{ .array = out };
            },
            .Map => {
                if (j != .object) return r.mismatch(path, "an object", j);
                const out = try r.arena.alloc(Decoded.Entry, j.object.len);
                for (j.object, 0..) |m, i| {
                    const p = path.key(m.name);
                    out[i] = .{ .key = m.name, .value = try r.read(.{ .e = args[0], .env = env }, m.value, &p) };
                }
                return .{ .map = out };
            },
            .Stream => return r.fail(.@"type-mismatch", path, "a Stream describes a whole file", .{}),
        }
    }

    /// The fields of a record from an object's members; `skip` is a member
    /// that isn't a field (`_tag` beside a record case's fields).
    fn recordFields(r: *JsonReader, rec: *const schema_mod.RecordType, env: ?*const Env, members: []const Json.Member, path: *const Path, skip: ?[]const u8) Error![]const Decoded.Entry {
        const present = try r.arena.alloc(bool, rec.fields.len);
        @memset(present, false);
        for (members) |m| {
            if (rec.index.get(m.name)) |k| present[k] = true;
        }
        for (rec.fields, 0..) |f, k| {
            if (!f.optional and !present[k]) {
                var buf: [64]u8 = undefined;
                return r.fail(.@"missing-field", path, "missing field {s}", .{errors.quoteText(&buf, f.key)});
            }
        }
        var out: std.ArrayList(Decoded.Entry) = .empty;
        for (members) |m| {
            if (skip) |s| if (std.mem.eql(u8, m.name, s)) continue;
            const p = path.key(m.name);
            if (rec.index.get(m.name)) |k| {
                const field = rec.fields[k];
                try out.append(r.arena, .{ .key = m.name, .value = try r.read(.{ .e = field.type, .env = field.env orelse env }, m.value, &p) });
            } else if (rec.closed) {
                return r.fail(.@"unknown-field", &p, "not a field of this closed record", .{});
            }
        }
        return out.items;
    }

    fn variant(r: *JsonReader, vt: *const schema_mod.VariantType, env: ?*const Env, j: Json, path: *const Path) Error!Decoded {
        var buf: [64]u8 = undefined;
        if (isEnum(vt)) {
            if (j != .string) return r.mismatch(path, "a string (a tag)", j);
            if (!v.isTag(j.string)) return r.fail(.@"invalid-tag", path, "{s} is not a tag", .{errors.quoteText(&buf, j.string)});
            if (vt.index.get(j.string) == null) return r.fail(.@"unknown-tag", path, "{s} is not a tag of this closed variant", .{errors.quoteText(&buf, j.string)});
            return .{ .variant = .{ .tag = j.string } };
        }
        if (j != .object) return r.mismatch(path, "an object with \"_tag\"", j);
        const tag_json = j.get("_tag") orelse return r.fail(.@"missing-member", path, "missing member \"_tag\"", .{});
        if (tag_json != .string or !v.isTag(tag_json.string)) return r.fail(.@"invalid-tag", path, "\"_tag\" is not a tag", .{});
        const tag = tag_json.string;
        const k = vt.index.get(tag) orelse {
            if (vt.closed) return r.fail(.@"unknown-tag", path, "{s} is not a tag of this closed variant", .{errors.quoteText(&buf, tag)});
            return r.unknown(j, tag, path);
        };
        const case = vt.cases[k];
        const case_env = case.env orelse env;
        switch (case.form) {
            .none => {
                for (j.object) |m| if (!std.mem.eql(u8, m.name, "_tag")) {
                    const p = path.key(m.name);
                    return r.fail(.@"unexpected-member", &p, "{s} takes no payload", .{tag});
                };
                return .{ .variant = .{ .tag = tag } };
            },
            .record => {
                const target = try decode_mod.unfoldRecord(r.arena, case.args[0], case_env);
                if (target.rec.index.contains("_tag") or target.rec.index.contains("_args")) {
                    return r.fail(.@"no-json-form", path, "{s} has a field named _tag or _args: it has no schema-based JSON form", .{tag});
                }
                const entries = try r.recordFields(target.rec, target.env, j.object, path, "_tag");
                const args = try r.arena.alloc(Decoded, 1);
                args[0] = .{ .record = entries };
                return .{ .variant = .{ .tag = tag, .args = args } };
            },
            .positional => {
                const name = if (case.args.len == 1) "value" else "values";
                const payload = j.get(name) orelse return r.fail(.@"missing-member", path, "missing member \"{s}\"", .{name});
                for (j.object) |m| if (!std.mem.eql(u8, m.name, "_tag") and !std.mem.eql(u8, m.name, name)) {
                    const p = path.key(m.name);
                    return r.fail(.@"unexpected-member", &p, "unexpected member beside \"_tag\" and \"{s}\"", .{name});
                };
                const args = try r.arena.alloc(Decoded, case.args.len);
                const pp = path.key(name);
                if (case.args.len == 1) {
                    args[0] = try r.read(.{ .e = case.args[0], .env = case_env }, payload, &pp);
                } else {
                    if (payload != .array or payload.array.len != case.args.len) return r.fail(.@"wrong-payload", path, "{s} takes {d} values", .{ tag, case.args.len });
                    for (payload.array, 0..) |x, i| {
                        const p = pp.index(i);
                        args[i] = try r.read(.{ .e = case.args[i], .env = case_env }, x, &p);
                    }
                }
                return .{ .variant = .{ .tag = tag, .args = args } };
            },
        }
    }

    /// A tag an open variant doesn't list (§16.3): bare, with `_args`, or
    /// with other members read as a record payload by the import.
    fn unknown(r: *JsonReader, j: Json, tag: []const u8, path: *const Path) Error!Decoded {
        const members = j.object;
        if (members.len == 1) return .{ .unknown = .{ .tag = tag } };
        if (members.len == 2) if (j.get("_args")) |a| {
            const p = path.key("_args");
            if (a != .array or a.array.len == 0) return r.fail(.@"haus-json-form", &p, "\"_args\" is not a non-empty array", .{});
            const out = try r.arena.alloc(Value, a.array.len);
            for (a.array, 0..) |x, i| {
                const q = p.index(i);
                out[i] = try hausValue(r.arena, x, &q, r.options);
            }
            return .{ .unknown = .{ .tag = tag, .args = out } };
        };
        const fields = try r.arena.alloc(v.Field, members.len - 1);
        var i: usize = 0;
        for (members) |m| {
            if (std.mem.eql(u8, m.name, "_tag")) continue;
            fields[i] = .{ .key = m.name, .value = try importValue(r.arena, m.value) };
            i += 1;
        }
        const args = try r.arena.alloc(Value, 1);
        args[0] = .{ .record = fields };
        return .{ .unknown = .{ .tag = tag, .args = args } };
    }
};

/// A JSON number literal (RFC 8259), as `Decimal` strings hold.
fn isJsonNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
    if (s[i] == '0') {
        i += 1;
    } else while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const f = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == f) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const f = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == f) return false;
    }
    return i == s.len;
}

/// Canonical base64 with padding (RFC 4648 §4): no whitespace, no URL
/// alphabet, zero pad bits.
fn decodeBase64(arena: Allocator, s: []const u8) ?[]const u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return null;
    const out = arena.alloc(u8, n) catch return null;
    dec.decode(out, s) catch return null;
    // Canonical: encoding gives the same text back (zero pad bits).
    var check_buf: std.ArrayList(u8) = .empty;
    appendBase64(arena, &check_buf, out) catch return null;
    if (!std.mem.eql(u8, check_buf.items, s)) return null;
    return out;
}

/// A type expression for a built-in type without arguments.
fn builtinExpr(b: schema_mod.Builtin) *const Expr {
    const table = comptime blk: {
        var t: [@backingInt(schema_mod.Builtin.Stream) + 1]Expr = undefined;
        for (&t, 0..) |*e, i| e.* = .{ .at = 0, .kind = .{ .name = .{ .name = @tagName(@as(schema_mod.Builtin, @fromBackingInt(@intCast(i)))), .args = &.{}, .ref = .{ .builtin = @fromBackingInt(@intCast(i)) } } } };
        break :blk t;
    };
    return &table[@backingInt(b)];
}

/// Reads schema-based JSON with `def` (§16.3): the decoded value, as
/// decoding the haus value would give it.
pub fn fromJson(arena: Allocator, gpa: Allocator, def: *const Def, text: []const u8, options: ReadOptions) Error!Decoded {
    const j = try readJson(arena, gpa, text, .{ .strict_controls = false, .max_depth = 4 * options.limits.max_depth + 1 }, options);
    var r: JsonReader = .{ .arena = arena, .diag = options.diagnostic, .options = options };
    const d = try r.read(.{ .e = def.body, .env = null }, j, &Path.root);
    // The limits apply to the value the result encodes to (§16 "Limits").
    try checkDepth(try decode_mod.toValue(arena, d), options.limits, options.diagnostic);
    return d;
}

test "base64 is canonical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualSlices(u8, &.{ 0x0b, 0x34 }, decodeBase64(a, "CzQ=").?);
    try std.testing.expect(decodeBase64(a, "CzR=") == null);
    try std.testing.expect(decodeBase64(a, "CzQ") == null);
    try std.testing.expect(decodeBase64(a, "Cz Q=") == null);
    try std.testing.expect(decodeBase64(a, "-_8=") == null);
}
