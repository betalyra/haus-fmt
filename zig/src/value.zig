//! The data model (spec §1) and the limits (spec §7).

const std = @import("std");

/// A haus value. Slices point into memory owned by whoever built the value:
/// the arena of a `Parsed` for parsed values, the caller for values built in
/// code.
pub const Value = union(enum) {
    /// The normalized literal (spec §2): `255` for `0xFF`, `1e5` for `1E+05`,
    /// `19.90` as written.
    number: []const u8,
    /// UTF-8, any Unicode scalar values (NUL included).
    string: []const u8,
    bytes: []const u8,
    array: []const Value,
    /// Fields in the order they were written; keys are unique.
    record: []const Field,
    variant: Variant,

    pub const Kind = std.meta.Tag(Value);

    pub fn tag(name: []const u8) Value {
        return .{ .variant = .{ .tag = name } };
    }
};

pub const Field = struct {
    key: []const u8,
    value: Value,
};

/// `Tag`, `Tag(a, b)` or `Tag { … }`: `Tag { … }` and `Tag({ … })` are the
/// same value, a variant with one record argument (spec §2).
pub const Variant = struct {
    tag: []const u8,
    args: []const Value = &.{},
};

/// The limits of spec §7. The defaults are the spec's; every one can be set.
/// The hex-digit limit is derived from `max_number_length` (spec §7).
pub const Limits = struct {
    max_depth: u32 = 256,
    max_number_length: u32 = 1000,
    max_exponent: u32 = 6144,
    /// Characters (code points) in a string's value, a record key, a tag, or
    /// between the quotes of a byte string.
    max_string_length: u32 = 16 * 1024 * 1024,
    /// Characters in one top-level value of a stream (stream readers only).
    max_value_length: u64 = 64 * 1024 * 1024,

    /// The deepest nesting this binding supports (spec §7): the parser,
    /// writers and formatter recurse, one call per level.
    pub const supported_depth: u32 = 4096;

    /// The largest h with 16^h ≤ 10^(n−1): every integer of h hex digits has
    /// a decimal form of at most n characters, sign included (spec §7).
    pub fn maxHexDigits(l: Limits) u32 {
        const n = l.max_number_length;
        if (n <= 1) return 0;
        // h·log10(16) ≤ n−1. log10(16) is irrational, so equality never
        // holds for h > 0; f64 is exact enough for any u32 n.
        const h: u64 = @intFromFloat(@floor(@as(f64, @floatFromInt(n - 1)) / std.math.log10(16.0)));
        return @intCast(h);
    }
};

test "the derived hex limit" {
    try std.testing.expectEqual(@as(u32, 829), (Limits{}).maxHexDigits());
    try std.testing.expectEqual(@as(u32, 0), (Limits{ .max_number_length = 1 }).maxHexDigits());
    try std.testing.expectEqual(@as(u32, 1), (Limits{ .max_number_length = 3 }).maxHexDigits());
}

// ── characters ───────────────────────────────────────────────

/// C0, DEL and C1 (spec §4).
pub fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7F and cp <= 0x9F);
}

/// The bidirectional controls of spec §4.
pub fn isBidi(cp: u21) bool {
    return (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069);
}

pub fn isTagStart(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}
pub fn isKeyStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c == '_';
}
pub fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// A bare key: `[a-z_][A-Za-z0-9_]*`.
pub fn isBareKey(s: []const u8) bool {
    if (s.len == 0 or !isKeyStart(s[0])) return false;
    for (s[1..]) |c| if (!isIdentChar(c)) return false;
    return true;
}

/// A tag: `[A-Z][A-Za-z0-9_]*`.
pub fn isTag(s: []const u8) bool {
    if (s.len == 0 or !isTagStart(s[0])) return false;
    for (s[1..]) |c| if (!isIdentChar(c)) return false;
    return true;
}

/// The code point starting at `s[i]` and its length, for valid UTF-8.
pub fn decode(s: []const u8, i: usize) struct { cp: u21, len: u3 } {
    const c = s[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    if (c < 0xE0) return .{ .cp = (@as(u21, c & 0x1F) << 6) | (s[i + 1] & 0x3F), .len = 2 };
    if (c < 0xF0) return .{ .cp = (@as(u21, c & 0x0F) << 12) | (@as(u21, s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F), .len = 3 };
    return .{ .cp = (@as(u21, c & 0x07) << 18) | (@as(u21, s[i + 1] & 0x3F) << 12) | (@as(u21, s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F), .len = 4 };
}

/// The number of code points in valid UTF-8.
pub fn countCodePoints(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if ((c & 0xC0) != 0x80) n += 1;
    }
    return n;
}
