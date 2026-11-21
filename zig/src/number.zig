//! Number literals (spec §3, grammar `number`): scanning, limits and the
//! normalized literal of spec §2.

const std = @import("std");
const Limits = @import("value.zig").Limits;
const Code = @import("errors.zig").Code;

pub const Base = enum { decimal, hex, binary };

/// A literal as written, scanned: where it ends, and what the limits need.
pub const Scanned = struct {
    end: usize,
    base: Base,
    /// Hex or binary digits, `_` not counted.
    digits: usize,
    /// The absolute value of the exponent, saturated.
    exponent: u64,
};

pub const ScanResult = union(enum) {
    ok: Scanned,
    err: Code,
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isBin(c: u8) bool {
    return c == '0' or c == '1';
}
/// What may not follow a number (grammar: `[A-Za-z0-9_.]`).
fn isNumberTail(c: u8) bool {
    return isHex(c) or (c >= 'g' and c <= 'z') or (c >= 'G' and c <= 'Z') or c == '_' or c == '.';
}

/// Digits of one class with `_` only between two of them, from `i`;
/// returns the end, or null if there is no digit at `i` or a `_` isn't
/// followed by a digit.
fn digitRun(text: []const u8, start: usize, comptime class: fn (u8) bool, count: *usize) ?usize {
    var i = start;
    if (i >= text.len or !class(text[i])) return null;
    while (i < text.len) {
        if (class(text[i])) {
            count.* += 1;
            i += 1;
        } else if (text[i] == '_') {
            if (i + 1 < text.len and class(text[i + 1])) {
                i += 1;
            } else return null;
        } else break;
    }
    return i;
}

/// Scans the literal starting at `start` (a `-` or a digit) and checks it
/// against the limits: `invalid-number`, `number-too-long` or
/// `exponent-too-large`.
pub fn scan(text: []const u8, start: usize, limits: Limits) ScanResult {
    var i = start;
    if (i < text.len and text[i] == '-') i += 1;
    if (i >= text.len) return .{ .err = .@"invalid-number" };
    var digits: usize = 0;
    var base: Base = .decimal;
    var exponent: u64 = 0;
    if (text[i] == '0' and i + 1 < text.len and text[i + 1] == 'x') {
        base = .hex;
        i = digitRun(text, i + 2, isHex, &digits) orelse return .{ .err = .@"invalid-number" };
    } else if (text[i] == '0' and i + 1 < text.len and text[i + 1] == 'b') {
        base = .binary;
        i = digitRun(text, i + 2, isBin, &digits) orelse return .{ .err = .@"invalid-number" };
    } else {
        var ignored: usize = 0;
        if (text[i] == '0') {
            i += 1;
        } else if (text[i] >= '1' and text[i] <= '9') {
            i = digitRun(text, i, isDigit, &ignored) orelse return .{ .err = .@"invalid-number" };
        } else return .{ .err = .@"invalid-number" };
        if (i < text.len and text[i] == '.') {
            i = digitRun(text, i + 1, isDigit, &ignored) orelse return .{ .err = .@"invalid-number" };
        }
        if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
            i += 1;
            if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
            const from = i;
            i = digitRun(text, i, isDigit, &ignored) orelse return .{ .err = .@"invalid-number" };
            for (text[from..i]) |c| {
                if (c == '_') continue;
                exponent = std.math.mul(u64, exponent, 10) catch std.math.maxInt(u64);
                exponent = std.math.add(u64, exponent, c - '0') catch std.math.maxInt(u64);
            }
        }
    }
    if (i < text.len and isNumberTail(text[i])) return .{ .err = .@"invalid-number" };
    if (i - start > limits.max_number_length) return .{ .err = .@"number-too-long" };
    if (base == .hex and digits > limits.maxHexDigits()) return .{ .err = .@"number-too-long" };
    if (exponent > limits.max_exponent) return .{ .err = .@"exponent-too-large" };
    return .{ .ok = .{ .end = i, .base = base, .digits = digits, .exponent = exponent } };
}

/// Appends the normalized literal (spec §2) of a valid literal: separators
/// removed, the exponent as `e` and its value (no `+`, no leading zeros, no
/// `-` on zero), hex and binary as decimal integers with their sign.
pub fn appendNormalized(gpa: std.mem.Allocator, out: *std.ArrayList(u8), literal: []const u8) !void {
    var s = literal;
    if (s.len > 0 and s[0] == '-') {
        try out.append(gpa, '-');
        s = s[1..];
    }
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'b')) {
        return appendDecimal(gpa, out, s[2..], if (s[1] == 'x') 16 else 2);
    }
    var i: usize = 0;
    while (i < s.len and s[i] != 'e' and s[i] != 'E') : (i += 1) {
        if (s[i] != '_') try out.append(gpa, s[i]);
    }
    if (i == s.len) return;
    try out.append(gpa, 'e');
    i += 1;
    var negative = false;
    if (s[i] == '+' or s[i] == '-') {
        negative = s[i] == '-';
        i += 1;
    }
    // Skip leading zeros (and separators among them).
    while (i < s.len and (s[i] == '0' or s[i] == '_')) i += 1;
    if (i == s.len) return out.append(gpa, '0');
    if (negative) try out.append(gpa, '-');
    for (s[i..]) |c| if (c != '_') try out.append(gpa, c);
}

/// Appends the decimal form of the digits (`_` allowed) in `base`.
fn appendDecimal(gpa: std.mem.Allocator, out: *std.ArrayList(u8), digits: []const u8, base: u32) !void {
    // Little-endian limbs of 10^9.
    var limbs: std.ArrayList(u32) = .empty;
    defer limbs.deinit(gpa);
    for (digits) |c| {
        if (c == '_') continue;
        const d: u64 = std.fmt.charToDigit(c, 16) catch unreachable;
        var carry: u64 = d;
        for (limbs.items) |*limb| {
            const x = @as(u64, limb.*) * base + carry;
            limb.* = @intCast(x % 1_000_000_000);
            carry = x / 1_000_000_000;
        }
        if (carry > 0) try limbs.append(gpa, @intCast(carry));
    }
    if (limbs.items.len == 0) return out.append(gpa, '0');
    var buf: [9]u8 = undefined;
    var k = limbs.items.len;
    const top = std.fmt.bufPrint(&buf, "{d}", .{limbs.items[k - 1]}) catch unreachable;
    try out.appendSlice(gpa, top);
    k -= 1;
    while (k > 0) {
        k -= 1;
        const part = std.fmt.bufPrint(&buf, "{d:0>9}", .{limbs.items[k]}) catch unreachable;
        try out.appendSlice(gpa, part);
    }
}

/// Whether `s` is a normalized literal (spec §2): what parsing gives, and
/// what writers accept as a number built in code.
pub fn isNormalized(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    if (i >= s.len) return false;
    if (s[i] == '0') {
        i += 1;
    } else if (s[i] >= '1' and s[i] <= '9') {
        while (i < s.len and isDigit(s[i])) i += 1;
    } else return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const from = i;
        while (i < s.len and isDigit(s[i])) i += 1;
        if (i == from) return false;
    }
    if (i < s.len and s[i] == 'e') {
        i += 1;
        if (i < s.len and s[i] == '-') {
            i += 1;
            if (i >= s.len or s[i] < '1' or s[i] > '9') return false;
        } else if (i < s.len and s[i] == '0') {
            return i + 1 == s.len;
        }
        if (i >= s.len or s[i] < '1' or s[i] > '9') return false;
        while (i < s.len and isDigit(s[i])) i += 1;
    }
    return i == s.len;
}

/// For a normalized literal: the length of its integer part's digits when
/// it is an integer (no fraction, no exponent), else null.
pub fn integerDigits(s: []const u8) ?usize {
    const body = if (s.len > 0 and s[0] == '-') s[1..] else s;
    for (body) |c| if (!isDigit(c)) return null;
    return body.len;
}

fn testNormalize(literal: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendNormalized(gpa, &out, literal);
    try std.testing.expectEqualStrings(expected, out.items);
    try std.testing.expect(isNormalized(out.items));
}

test "normalized literals" {
    try testNormalize("1_000", "1000");
    try testNormalize("0xFF", "255");
    try testNormalize("-0x0", "-0");
    try testNormalize("0b1010_1010", "170");
    try testNormalize("1E+05", "1e5");
    try testNormalize("1e-0", "1e0");
    try testNormalize("-0e-0", "-0e0");
    try testNormalize("1_000.000_1e1_0", "1000.0001e10");
    try testNormalize("19.90", "19.90");
    try testNormalize("0x1_0000_0000_0000_0000", "18446744073709551616");
    try std.testing.expect(!isNormalized("1e+5"));
    try std.testing.expect(!isNormalized("01"));
    try std.testing.expect(!isNormalized("1e05"));
    try std.testing.expect(!isNormalized("1e-0"));
}

test "scan" {
    const l = Limits{};
    try std.testing.expectEqual(Code.@"invalid-number", scan("007", 0, l).err);
    try std.testing.expectEqual(Code.@"invalid-number", scan("1.", 0, l).err);
    try std.testing.expectEqual(Code.@"invalid-number", scan("0X1", 0, l).err);
    try std.testing.expectEqual(Code.@"invalid-number", scan("1_", 0, l).err);
    try std.testing.expectEqual(Code.@"invalid-number", scan("-", 0, l).err);
    try std.testing.expectEqual(Code.@"exponent-too-large", scan("1e6145", 0, l).err);
    try std.testing.expectEqual(@as(usize, 6), scan("1e6144,", 0, l).ok.end);
    try std.testing.expectEqual(@as(usize, 1), scan("1-2", 0, l).ok.end);
}
