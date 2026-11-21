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
/// equality and hashing.
///
/// Zig's `Value` is a plain union that code can build past any constructor,
/// so a value is checked where it is written (spec §11, "Values built in
/// code": a binding whose values can be forged checks them again, with the
/// codes a constructor uses): a number that isn't a normalized literal
/// (`invalid-number`), a string or key that isn't UTF-8 (`cannot-encode`), a
/// tag that isn't one (`invalid-tag`) and duplicate keys (`duplicate-key`)
/// are errors everywhere. Writers also apply every limit of spec §7 in
/// `limits`; the canonical form, hashing, equality and order apply only the
/// node limit, `limits.max_nodes` (spec §12).
pub const WriteOptions = struct {
    limits: Limits = .{},
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

/// Counts the values written for one top-level value, and checks what a
/// value built in code can get wrong.
pub const Checker = struct {
    options: WriteOptions,
    /// Writers check every limit of spec §7 that a value can break; the
    /// canonical form only the node limit.
    writer: bool = false,
    /// The value's index in a stream written or in `hashAll`: the node
    /// limit's place is then `$[i]`, else `$` (errors.md).
    index: ?usize = null,
    nodes: u64 = 0,

    /// Counts one value written (spec §7, "Values written"): the value
    /// itself and every element, field value and argument inside it.
    pub fn count(c: *Checker) Error!void {
        c.nodes += 1;
        if (c.nodes <= c.options.limits.max_nodes) return;
        const max = c.options.limits.max_nodes;
        if (c.options.diagnostic) |d| {
            failValue(d, .@"too-many-nodes", "the value writes more than {d} values: its parts share each other", .{max}) catch {};
            var buf: [32]u8 = undefined;
            d.setPath(if (c.index) |i| std.fmt.bufPrint(&buf, "$[{d}]", .{i}) catch "$" else "$");
        }
        return error.Haus;
    }

    /// Called for every value at nesting `depth` (the levels of spec §7 it
    /// sits in).
    pub fn visit(c: *Checker, val: Value, depth: u32) Error!void {
        try c.count();
        const diag = c.options.diagnostic;
        const limits = c.options.limits;
        switch (val) {
            .number => |n| if (!number.isNormalized(n)) {
                var buf: [64]u8 = undefined;
                return failValue(diag, .@"invalid-number", "{s} is not a normalized number literal", .{errors.quoteText(&buf, n)});
            },
            .string => |s| if (!std.unicode.utf8ValidateSlice(s)) return failValue(diag, .@"cannot-encode", "a string that isn't UTF-8", .{}),
            .variant => |x| if (!v.isTag(x.tag)) {
                var buf: [64]u8 = undefined;
                return failValue(diag, .@"invalid-tag", "{s} is not a tag", .{errors.quoteText(&buf, x.tag)});
            },
            else => {},
        }
        if (c.writer) {
            if (childDepth(val, depth) > limits.max_depth) return failValue(diag, .@"nesting-too-deep", "nesting deeper than {d} levels", .{limits.max_depth});
            switch (val) {
                .number => |n| switch (number.scan(n, 0, limits)) {
                    .err => |code| return switch (code) {
                        .@"exponent-too-large" => failValue(diag, code, "exponent larger than {d}", .{limits.max_exponent}),
                        else => failValue(diag, .@"number-too-long", "number longer than {d} characters", .{limits.max_number_length}),
                    },
                    .ok => {},
                },
                .string => |s| if (v.countCodePoints(s) > limits.max_string_length) return failValue(diag, .@"string-too-long", "string longer than {d} characters", .{limits.max_string_length}),
                .bytes => |b| if (2 * @as(u64, b.len) > limits.max_string_length) return failValue(diag, .@"string-too-long", "byte string longer than {d} characters", .{limits.max_string_length}),
                .variant => |x| if (x.tag.len > limits.max_string_length) return failValue(diag, .@"tag-too-long", "tag longer than {d} characters", .{limits.max_string_length}),
                .array, .record => {},
            }
        }
        switch (val) {
            .record => |fields| try c.checkKeys(fields),
            .variant => |x| if (x.args.len == 1 and x.args[0] == .record) try c.checkKeys(x.args[0].record),
            else => {},
        }
    }

    /// A record's keys (also a record payload's, which has no `visit` of
    /// its own): UTF-8, and within the string limit for a writer.
    fn checkKeys(c: *Checker, fields: []const Field) Error!void {
        const limits = c.options.limits;
        for (fields) |f| {
            if (!std.unicode.utf8ValidateSlice(f.key)) return failValue(c.options.diagnostic, .@"cannot-encode", "a record key that isn't UTF-8", .{});
            if (c.writer and v.countCodePoints(f.key) > limits.max_string_length) return failValue(c.options.diagnostic, .@"key-too-long", "record key longer than {d} characters", .{limits.max_string_length});
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

/// A container the canonical writer has opened: what is left to write in
/// it. A record's fields are a sorted copy, owned by the writer.
const Frame = struct {
    values: []const Value = &.{},
    fields: []const Field = &.{},
    record: bool,
    next: usize = 0,
    close: u8,
};

/// Writes the canonical form with a stack of its own rather than the call
/// stack: the canonical form has no depth limit (spec §12), so a value built
/// in code can be nested deeper than a call stack holds. Each frame is one
/// level of spec §7, so the stack's height is the depth a writer checks.
fn writeCanonical(gpa: Allocator, out: *std.ArrayList(u8), root: Value, checker: *Checker) Error!void {
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |f| if (f.record) gpa.free(f.fields);
        stack.deinit(gpa);
    }
    try openValue(gpa, out, root, checker, &stack);
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        const len = if (top.record) top.fields.len else top.values.len;
        if (top.next == len) {
            try out.append(gpa, top.close);
            if (top.record) gpa.free(top.fields);
            stack.items.len -= 1;
            continue;
        }
        if (top.next > 0) try out.append(gpa, ',');
        const child = if (top.record) blk: {
            const f = top.fields[top.next];
            try appendKey(gpa, out, f.key);
            try out.append(gpa, ':');
            break :blk f.value;
        } else top.values[top.next];
        top.next += 1;
        try openValue(gpa, out, child, checker, &stack);
    }
}

/// Writes a value, or its opening and pushes its frame.
fn openValue(gpa: Allocator, out: *std.ArrayList(u8), val: Value, checker: *Checker, stack: *std.ArrayList(Frame)) Error!void {
    try checker.visit(val, @intCast(@min(stack.items.len, std.math.maxInt(u32))));
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
            try stack.append(gpa, .{ .values = items, .record = false, .close = ']' });
        },
        .record => |fields| try openRecord(gpa, out, fields, checker, stack),
        .variant => |x| {
            try out.appendSlice(gpa, x.tag);
            if (x.args.len == 1 and x.args[0] == .record) {
                // `Tag{…}`: the record is an argument, one more value
                // written, but the payload's level, not one more.
                try checker.count();
                try openRecord(gpa, out, x.args[0].record, checker, stack);
            } else if (x.args.len > 0) {
                try out.append(gpa, '(');
                try stack.append(gpa, .{ .values = x.args, .record = false, .close = ')' });
            }
        },
    }
}

fn openRecord(gpa: Allocator, out: *std.ArrayList(u8), fields: []const Field, checker: *Checker, stack: *std.ArrayList(Frame)) Error!void {
    try stack.ensureUnusedCapacity(gpa, 1);
    const sorted = try sortedFields(gpa, fields, checker.options.diagnostic);
    stack.appendAssumeCapacity(.{ .fields = sorted, .record = true, .close = '}' });
    try out.append(gpa, '{');
}

/// Appends the canonical form of a value (spec §12): only the node limit
/// applies.
pub fn appendCanonical(gpa: Allocator, out: *std.ArrayList(u8), val: Value, options: WriteOptions) Error!void {
    var checker = Checker{ .options = options };
    try writeCanonical(gpa, out, val, &checker);
}

/// Appends the canonical text of a value, checked as a writer checks it
/// (every limit of spec §7): for writers that write the value in another
/// form and check it this way first (self-describing JSON). `index` is the
/// value's place in a stream, for the node limit's `$[i]`.
pub fn appendChecked(gpa: Allocator, out: *std.ArrayList(u8), val: Value, options: WriteOptions, index: ?usize) Error!void {
    var checker = Checker{ .options = options, .writer = true, .index = index };
    try writeCanonical(gpa, out, val, &checker);
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
    return hashValues(gpa, &.{val}, options, false);
}

/// `hashAll(values)`: the SHA-256 of the canonical forms joined by `,`
/// (spec §12). `hashAll(&.{v})` is `hash(v)`; no values hash as the empty
/// text. The node limit applies to each value on its own, at `$[i]`.
pub fn hashAll(gpa: Allocator, values: []const Value, options: WriteOptions) Error![64]u8 {
    return hashValues(gpa, values, options, true);
}

fn hashValues(gpa: Allocator, values: []const Value, options: WriteOptions, indexed: bool) Error![64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (values, 0..) |val, i| {
        out.clearRetainingCapacity();
        if (i > 0) try out.append(gpa, ',');
        var checker = Checker{ .options = options, .index = if (indexed) i else null };
        try writeCanonical(gpa, &out, val, &checker);
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
    try std.testing.expectEqual(Code.@"cannot-encode", d.code);
    const dup = [_]Field{ .{ .key = "a", .value = .{ .number = "1" } }, .{ .key = "a", .value = .{ .number = "2" } } };
    try std.testing.expectError(error.Haus, canonical(gpa, .{ .record = &dup }, .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"duplicate-key", d.code);
}

test "the canonical form has only the node limit" {
    const gpa = std.testing.allocator;
    // A value whose arrays share their element: 2^k+1 − 1 values written.
    var levels: [20]Value = undefined;
    levels[0] = .{ .number = "1" };
    var pairs: [19][2]Value = undefined;
    for (1..20) |i| {
        pairs[i - 1] = .{ levels[i - 1], levels[i - 1] };
        levels[i] = .{ .array = &pairs[i - 1] };
    }
    var d: Diagnostic = .{};
    const small: Limits = .{ .max_nodes = 1000 };
    try std.testing.expectError(error.Haus, canonical(gpa, levels[19], .{ .limits = small, .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"too-many-nodes", d.code);
    try std.testing.expectEqualStrings("$", d.path());
    try std.testing.expectError(error.Haus, hashAll(gpa, &.{ levels[1], levels[19] }, .{ .limits = small, .diagnostic = &d }));
    try std.testing.expectEqualStrings("$[1]", d.path());
    try std.testing.expectError(error.Haus, compare(gpa, levels[1], levels[19], .{ .limits = small, .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"too-many-nodes", d.code);
    // 2^10 − 1 values: within the limit, whatever its depth.
    const c = try canonical(gpa, levels[9], .{ .limits = .{ .max_nodes = 1023, .max_depth = 1 } });
    defer gpa.free(c);
    // No length limit either.
    const long = try canonical(gpa, .{ .number = "1e99999" }, .{});
    defer gpa.free(long);
    try std.testing.expectEqualStrings("1e99999", long);
}

test "the canonical form of a value deeper than a call stack" {
    const gpa = std.testing.allocator;
    const n = 200_000;
    const chain = try gpa.alloc(Value, n);
    defer gpa.free(chain);
    chain[0] = .{ .number = "0" };
    for (1..n) |i| chain[i] = .{ .array = chain[i - 1 .. i] };
    const c = try canonical(gpa, chain[n - 1], .{});
    defer gpa.free(c);
    try std.testing.expectEqual(@as(usize, 2 * (n - 1) + 1), c.len);
}

test "hashAll of nothing is the hash of the empty text" {
    const h = try hashAll(std.testing.allocator, &.{}, .{});
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &h);
}
