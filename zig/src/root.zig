//! haus for Zig: a clean-room binding of the haus data format
//! (spec/README.md §1–§12, §17), written from the specification and the
//! conformance suite only.
//!
//! Every function that allocates takes an allocator. Failing calls return
//! `error.Haus` and fill in the `Diagnostic` passed in their options with the
//! error code of spec §17, its line and column (spec §8) and a message.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const value = @import("value.zig");
pub const errors = @import("errors.zig");
pub const number = @import("number.zig");
pub const parser = @import("parser.zig");
pub const canonical_form = @import("canonical.zig");
pub const stream = @import("stream.zig");
pub const write = @import("write.zig");
pub const format_source = @import("format.zig");
pub const time = @import("time.zig");
pub const schema = @import("schema.zig");
pub const decoding = @import("decode.zig");
pub const json = @import("json.zig");
pub const packages = @import("packages.zig");

pub const Value = value.Value;
pub const Field = value.Field;
pub const Variant = value.Variant;
pub const Limits = value.Limits;
pub const Code = errors.Code;
pub const Diagnostic = errors.Diagnostic;
pub const Error = errors.Error;
pub const WriteOptions = canonical_form.WriteOptions;
pub const StreamReader = stream.StreamReader;
pub const Layout = write.Layout;
pub const FormatOptions = write.FormatOptions;

pub const canonical = canonical_form.canonical;
pub const hash = canonical_form.hash;
pub const hashAll = canonical_form.hashAll;
pub const equals = canonical_form.equals;
pub const compare = canonical_form.compare;
pub const stringify = write.stringify;
pub const stringifyAll = write.stringifyAll;
pub const format = format_source.format;

/// The version of the specification this binding implements.
pub const spec_version = "0.1";

pub const ParseOptions = struct {
    limits: Limits = .{},
    diagnostic: ?*errors.Diagnostic = null,
};

/// The result of a parse: the values and the arena that holds them.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

/// Rejects a depth limit above what this binding supports (spec §7).
pub fn checkLimits(limits: Limits, diag: ?*Diagnostic) Error!void {
    if (limits.max_depth > Limits.supported_depth) {
        return canonical_form.failValue(diag, .@"unsupported-depth", "a depth limit of {d} is above the {d} levels this binding supports", .{ limits.max_depth, Limits.supported_depth });
    }
}

fn invalidUtf8(diag: ?*Diagnostic) Error {
    // The position is left out (0, 0): spec §17 lets a decoder say where,
    // and the reference model doesn't.
    return canonical_form.failValue(diag, .@"invalid-utf8", "invalid UTF-8", .{});
}

/// Parses a file: zero or more values separated by commas (spec §1, §6).
pub fn parseAll(gpa: Allocator, text: []const u8, options: ParseOptions) Error!Parsed([]const Value) {
    try checkLimits(options.limits, options.diagnostic);
    if (!std.unicode.utf8ValidateSlice(text)) return invalidUtf8(options.diagnostic);
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var p = parser.Parser.init(arena.allocator(), gpa, text, options.limits, options.diagnostic);
    defer p.deinit();
    const values = try p.parseFile();
    return .{ .arena = arena, .value = values };
}

/// Parses a single document: exactly one value, a comma after it allowed;
/// none or several is `not-one-value` (spec §6).
pub fn parse(gpa: Allocator, text: []const u8, options: ParseOptions) Error!Parsed(Value) {
    const all = try parseAll(gpa, text, options);
    if (all.value.len != 1) {
        defer all.deinit();
        if (options.diagnostic) |d| {
            d.set(.@"not-one-value", "expected one value, found {s}", .{if (all.value.len == 0) "none" else "more than one"});
            var p = parser.Parser.init(gpa, gpa, text, options.limits, null);
            const at = p.position(text.len);
            d.line = at.line;
            d.column = at.column;
            d.offset = text.len;
        }
        return error.Haus;
    }
    return .{ .arena = all.arena, .value = all.value[0] };
}

/// A parsed file with what the formatter needs: where each value, key and
/// comment is in `text`.
pub const Document = struct {
    arena: *std.heap.ArenaAllocator,
    text: []const u8,
    values: []const Value,
    syntax: parser.Syntax,

    pub fn deinit(self: *Document) void {
        const gpa = self.arena.child_allocator;
        self.syntax.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

/// Parses a file keeping the positions of its values, keys and comments.
pub fn parseDocument(gpa: Allocator, text: []const u8, options: ParseOptions) Error!Document {
    try checkLimits(options.limits, options.diagnostic);
    if (!std.unicode.utf8ValidateSlice(text)) return invalidUtf8(options.diagnostic);
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var syntax: parser.Syntax = .{};
    errdefer syntax.deinit(gpa);
    var p = parser.Parser.init(arena.allocator(), gpa, text, options.limits, options.diagnostic);
    defer p.deinit();
    p.syntax = &syntax;
    const values = try p.parseFile();
    return .{ .arena = arena, .text = text, .values = values, .syntax = syntax };
}

test {
    std.testing.refAllDecls(@This());
    _ = value;
    _ = errors;
    _ = number;
    _ = parser;
    _ = canonical_form;
    _ = stream;
    _ = write;
    _ = format_source;
    _ = time;
    _ = schema;
    _ = decoding;
    _ = json;
    _ = packages;
}

test "parse and canonical" {
    const gpa = std.testing.allocator;
    const parsed = try parseAll(gpa, "Order { total: 19.90, id: 0xFF, \"x-y\": 1e+5, p: Point(1, 2) },", .{});
    defer parsed.deinit();
    const c = try canonical(gpa, parsed.value[0], .{});
    defer gpa.free(c);
    try std.testing.expectEqualStrings("Order{id:255,p:Point(1,2),total:19.90,\"x-y\":1e5}", c);
}

test "errors carry code and position" {
    const gpa = std.testing.allocator;
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Haus, parseAll(gpa, "{ \"\u{1F600}\": 1, \"\u{1F600}\": 2 }", .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"duplicate-key", d.code);
    try std.testing.expectEqual(@as(u32, 1), d.line);
    try std.testing.expectEqual(@as(u32, 11), d.column);
}
