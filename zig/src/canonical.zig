//! The canonical form, equality, order and hashes (spec §2, §12).

const std = @import("std");
const Allocator = std.mem.Allocator;
const v = @import("value.zig");
const Value = v.Value;
const Field = v.Field;
const Limits = v.Limits;
const errors = @import("errors.zig");
const Code = errors.Code;
const Diagnostic = errors.Diagnostic;
const Error = errors.Error;
const number = @import("number.zig");

/// Options for writing values: the canonical form, the layouts' writers,
/// equality and hashing. Values built in code are checked as they are
/// written: a number that isn't a normalized literal, a string or key that
/// isn't UTF-8, a tag that isn't one, duplicate keys and nesting deeper than
/// `limits.max_depth` are errors; so is a value that has more than
/// `max_nodes` nodes as written out (a value whose slices share one another
/// expands when written).
pub const WriteOptions = struct {
    limits: Limits = .{},
    max_nodes: u64 = 1 << 26,
    diagnostic: ?*Diagnostic = null,
};

pub fn failValue(diag: ?*Diagnostic, code: Code, comptime fmt: []const u8, args: anytype) Error {
    if (diag) |d| {
        d.set(code, fmt, args);
        d.line = 0;
        d.column = 0;
        d.offset = 0;
    }
    return error.Haus;
}

/// Counts nodes and levels while a value is written, and checks what a
/// value built in code can get wrong.
pub const Checker = struct {
    options: WriteOptions,
    nodes: u64 = 0,

    /// Called for every value at nesting `depth` (the levels of spec §7 it
    /// sits in).
    pub fn visit(c: *Checker, val: Value, depth: u32) Error!void {
        c.nodes += 1;
        if (c.nodes > c.options.max_nodes) return failValue(c.options.diagnostic, .@"too-many-nodes", "the value has more than {d} nodes as written", .{c.options.max_nodes});
        const levels: u32 = switch (val) {
            .array, .record => 1,
            .variant => |x| if (x.args.len > 0) 1 else 0,
            else => 0,
        };
        if (depth + levels > c.options.limits.max_depth) return failValue(c.options.diagnostic, .@"nesting-too-deep", "nesting deeper than {d} levels", .{c.options.limits.max_depth});
        switch (val) {
            .number => |n| if (!number.isNormalized(n)) {
                var buf: [64]u8 = undefined;
                return failValue(c.options.diagnostic, .@"invalid-number", "{s} is not a normalized number literal", .{errors.quoteText(&buf, n)});
            },
            .string => |s| if (!std.unicode.utf8ValidateSlice(s)) return failValue(c.options.diagnostic, .@"invalid-utf8", "a string that isn't UTF-8", .{}),
            .variant => |x| if (!v.isTag(x.tag)) {
                var buf: [64]u8 = undefined;
                return failValue(c.options.diagnostic, .@"invalid-tag", "{s} is not a tag", .{errors.quoteText(&buf, x.tag)});
            },
            .record => |fields| for (fields) |f| {
                if (!std.unicode.utf8ValidateSlice(f.key)) return failValue(c.options.diagnostic, .@"invalid-utf8", "a record key that isn't UTF-8", .{});
            },
            else => {},
        }
    }

    /// The level a value's children are at: a record payload `Tag { … }`
    /// is one level, as the shorter spelling (spec §7).
    pub fn childDepth(val: Value, depth: u32) u32 {
        return switch (val) {
            .array, .record => depth + 1,
            .variant => |x| if (x.args.len > 0) depth + 1 else depth,
            else => depth,
        };
    }
};

/// The fields of a record sorted by key (code points, which is the order of
/// UTF-8 bytes), into `out`; `duplicate-key` if two keys are equal.
pub fn sortedFields(gpa: Allocator, fields: []const Field, diag: ?*Diagnostic) Error![]const Field {
    const sorted = try gpa.dupe(Field, fields);
    errdefer gpa.free(sorted);
    std.sort.pdq(Field, sorted, {}, struct {
        fn less(_: void, a: Field, b: Field) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.less);
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        if (std.mem.eql(u8, sorted[i - 1].key, sorted[i].key)) {
            var buf: [64]u8 = undefined;
            return failValue(diag, .@"duplicate-key", "duplicate key {s}", .{errors.quoteText(&buf, sorted[i].key)});
        }
    }
    return sorted;
}

/// Whether a character is written as an escape in every string (spec §11,
/// §12): control characters, bidi controls, U+2028 and U+2029.
pub fn mustEscape(cp: u21) bool {
    return v.isControl(cp) or v.isBidi(cp) or cp == 0x2028 or cp == 0x2029;
}

/// Appends a string as `"…"` with the minimal escapes of spec §12 (the
/// same in every layout, spec §11).
pub fn appendQuoted(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        const d = v.decode(s, i);
        try appendEscaped(gpa, out, d.cp, s[i .. i + d.len]);
        i += d.len;
    }
    try out.append(gpa, '"');
}

/// One character of a `"…"` string, escaped where it must be.
pub fn appendEscaped(gpa: Allocator, out: *std.ArrayList(u8), cp: u21, raw: []const u8) Allocator.Error!void {
    switch (cp) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => if (mustEscape(cp)) try appendUnicodeEscape(gpa, out, cp) else try out.appendSlice(gpa, raw),
    }
}

pub fn appendUnicodeEscape(gpa: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var buf: [12]u8 = undefined;
    try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "\\u{{{X}}}", .{cp}) catch unreachable);
}

/// A key: bare if it is an identifier, else a string.
pub fn appendKey(gpa: Allocator, out: *std.ArrayList(u8), key: []const u8) Allocator.Error!void {
    if (v.isBareKey(key)) return out.appendSlice(gpa, key);
    return appendQuoted(gpa, out, key);
}

pub fn appendHex(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8) Allocator.Error!void {
    const digits = "0123456789abcdef";
    for (bytes) |b| {
        try out.append(gpa, digits[b >> 4]);
        try out.append(gpa, digits[b & 15]);
    }
}

fn writeCanonical(gpa: Allocator, out: *std.ArrayList(u8), val: Value, checker: *Checker, depth: u32) Error!void {
    try checker.visit(val, depth);
    const inner = Checker.childDepth(val, depth);
    switch (val) {
        .number => |n| try out.appendSlice(gpa, n),
        .string => |s| try appendQuoted(gpa, out, s),
        .bytes => |b| {
            try out.appendSlice(gpa, "x\"");
            try appendHex(gpa, out, b);
            try out.append(gpa, '"');
        },
        .array => |items| {
            try out.append(gpa, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.append(gpa, ',');
                try writeCanonical(gpa, out, item, checker, inner);
            }
            try out.append(gpa, ']');
        },
        .record => |fields| try writeRecord(gpa, out, fields, checker, inner),
        .variant => |x| {
            try out.appendSlice(gpa, x.tag);
            if (x.args.len == 1 and x.args[0] == .record) {
                // `Tag{…}`: the record is the payload's level, not one more.
                checker.nodes += 1;
                try writeRecord(gpa, out, x.args[0].record, checker, inner);
            } else if (x.args.len > 0) {
                try out.append(gpa, '(');
                for (x.args, 0..) |arg, i| {
                    if (i > 0) try out.append(gpa, ',');
                    try writeCanonical(gpa, out, arg, checker, inner);
                }
                try out.append(gpa, ')');
            }
        },
    }
}

fn writeRecord(gpa: Allocator, out: *std.ArrayList(u8), fields: []const Field, checker: *Checker, inner: u32) Error!void {
    for (fields) |f| {
        if (!std.unicode.utf8ValidateSlice(f.key)) return failValue(checker.options.diagnostic, .@"invalid-utf8", "a record key that isn't UTF-8", .{});
    }
    const sorted = try sortedFields(gpa, fields, checker.options.diagnostic);
    defer gpa.free(sorted);
    try out.append(gpa, '{');
    for (sorted, 0..) |f, i| {
        if (i > 0) try out.append(gpa, ',');
        try appendKey(gpa, out, f.key);
        try out.append(gpa, ':');
        try writeCanonical(gpa, out, f.value, checker, inner);
    }
    try out.append(gpa, '}');
}

/// Appends the canonical form of a value (spec §12).
pub fn appendCanonical(gpa: Allocator, out: *std.ArrayList(u8), val: Value, options: WriteOptions) Error!void {
    var checker = Checker{ .options = options };
    try writeCanonical(gpa, out, val, &checker, 0);
}

/// The canonical form of a value (spec §12). The caller owns the result.
pub fn canonical(gpa: Allocator, val: Value, options: WriteOptions) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendCanonical(gpa, &out, val, options);
    return out.toOwnedSlice(gpa);
}

/// `hash(value)`: the SHA-256 of the canonical form as 64 lowercase hex
/// digits (spec §12).
pub fn hash(gpa: Allocator, val: Value, options: WriteOptions) Error![64]u8 {
    return hashAll(gpa, &.{val}, options);
}

/// `hashAll(values)`: the SHA-256 of the canonical forms joined by `,`
/// (spec §12). `hashAll(&.{v})` is `hash(v)`; no values hash as the empty text.
pub fn hashAll(gpa: Allocator, values: []const Value, options: WriteOptions) Error![64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (values, 0..) |val, i| {
        out.clearRetainingCapacity();
        if (i > 0) try out.append(gpa, ',');
        try appendCanonical(gpa, &out, val, options);
        h.update(out.items);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// `equals(a, b)`: equality of spec §2.
pub fn equals(gpa: Allocator, a: Value, b: Value, options: WriteOptions) Error!bool {
    return try compare(gpa, a, b, options) == .eq;
}

/// `compare(a, b)`: the order of the canonical forms' bytes, shorter first
/// when one is a prefix of the other (spec §12).
pub fn compare(gpa: Allocator, a: Value, b: Value, options: WriteOptions) Error!std.math.Order {
    const ca = try canonical(gpa, a, options);
    defer gpa.free(ca);
    const cb = try canonical(gpa, b, options);
    defer gpa.free(cb);
    return std.mem.order(u8, ca, cb);
}

test "canonical form of the spec's example" {
    const gpa = std.testing.allocator;
    const fields = [_]Field{
        .{ .key = "total", .value = .{ .number = "19.90" } },
        .{ .key = "id", .value = .{ .number = "255" } },
        .{ .key = "x-y", .value = .{ .number = "1e5" } },
        .{ .key = "p", .value = .{ .variant = .{ .tag = "Point", .args = &.{ .{ .number = "1" }, .{ .number = "2" } } } } },
    };
    const order = Value{ .variant = .{ .tag = "Order", .args = &.{.{ .record = &fields }} } };
    const c = try canonical(gpa, order, .{});
    defer gpa.free(c);
    try std.testing.expectEqualStrings("Order{id:255,p:Point(1,2),total:19.90,\"x-y\":1e5}", c);
}

test "values built in code are checked" {
    const gpa = std.testing.allocator;
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Haus, canonical(gpa, .{ .number = "0xFF" }, .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"invalid-number", d.code);
    try std.testing.expectError(error.Haus, canonical(gpa, Value.tag("lower"), .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"invalid-tag", d.code);
    try std.testing.expectError(error.Haus, canonical(gpa, .{ .string = "\xff" }, .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"invalid-utf8", d.code);
    const dup = [_]Field{ .{ .key = "a", .value = .{ .number = "1" } }, .{ .key = "a", .value = .{ .number = "2" } } };
    try std.testing.expectError(error.Haus, canonical(gpa, .{ .record = &dup }, .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"duplicate-key", d.code);
}

test "hashAll of nothing is the hash of the empty text" {
    const h = try hashAll(std.testing.allocator, &.{}, .{});
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &h);
}
