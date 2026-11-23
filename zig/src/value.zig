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
    /// Values written for one value built in code (spec §7, "Values
    /// written"): writers, the canonical form and hashing count each value
    /// as often as it is written, so a value whose parts share each other
    /// can't expand without bound.
    max_nodes: u64 = 64 * 1024 * 1024,

    /// The deepest nesting this binding supports (spec §7): the parser,
    /// writers, formatter, decoder and JSON readers recurse, one call per
    /// level. At 256, every one of them runs on a thread with a 512 KiB
    /// stack in the release modes (tested in root.zig); a Debug build
    /// needs about 2 MiB there (its frames are larger). 512 overflowed the
    /// decoder on 512 KiB in ReleaseSafe, 4096 the parser.
    pub const supported_depth: u32 = 256;

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
    return ident_chars[c];
}

/// `[A-Za-z0-9_]`, by byte.
const ident_chars: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for (0..256) |c| t[c] = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    break :blk t;
};

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

/// Whether `s` is UTF-8 (RFC 3629: no overlong forms, no surrogates,
/// nothing above U+10FFFF), as `std.unicode.utf8ValidateSlice`. Runs of
/// ASCII are skipped eight bytes at a time, also after the first character
/// that isn't ASCII.
pub fn validUtf8(s: []const u8) bool {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i < s.len) {
        while (i + 16 <= s.len and @reduce(.Max, @as(V, s[i..][0..16].*)) < 0x80) i += 16;
        while (i + 8 <= s.len and std.mem.readInt(u64, s[i..][0..8], .little) & 0x8080_8080_8080_8080 == 0) i += 8;
        while (i < s.len and s[i] < 0x80) i += 1;
        if (i == s.len) return true;
        i += utf8Sequence(s, i) orelse return false;
    }
    return true;
}

/// The length of the UTF-8 sequence of a non-ASCII character at `s[i]`, or
/// null if there is none there.
fn utf8Sequence(s: []const u8, i: usize) ?usize {
    const c = s[i];
    const len: usize = if (c < 0xC2) return null else if (c < 0xE0) 2 else if (c < 0xF0) 3 else if (c < 0xF5) 4 else return null;
    if (i + len > s.len) return null;
    for (s[i + 1 .. i + len]) |b| if (b & 0xC0 != 0x80) return null;
    const b1 = s[i + 1];
    switch (c) {
        0xE0 => if (b1 < 0xA0) return null, // overlong
        0xED => if (b1 > 0x9F) return null, // a surrogate
        0xF0 => if (b1 < 0x90) return null, // overlong
        0xF4 => if (b1 > 0x8F) return null, // above U+10FFFF
        else => {},
    }
    return len;
}

test "validUtf8 agrees with the standard library" {
    const cases = [_][]const u8{
        "",                 "plain ascii text, longer than eight bytes", "caf\xc3\xa9 and more ascii after it",
        "\xc3",             "\xc0\x80",                                  "\xe0\x80\x80",
        "\xe0\xa0\x80",     "\xed\x9f\xbf",                              "\xed\xa0\x80",
        "\xef\xbf\xbf",     "\xf0\x8f\xbf\xbf",                          "\xf0\x90\x80\x80",
        "\xf4\x8f\xbf\xbf", "\xf4\x90\x80\x80",                          "\xf5\x80\x80\x80",
        "\x80",             "abcdefgh\xff",                              "abcdefg\xe2\x80\xa8xyz",
        "\xe2\x80",         "\xf0\x9f\x98\x80\xf0\x9f\x98",
    };
    for (cases) |s| try std.testing.expectEqual(std.unicode.utf8ValidateSlice(s), validUtf8(s));
    // Every one- and two-byte input.
    var buf: [2]u8 = undefined;
    for (0..256) |a| {
        buf[0] = @intCast(a);
        try std.testing.expectEqual(std.unicode.utf8ValidateSlice(buf[0..1]), validUtf8(buf[0..1]));
        for (0..256) |b| {
            buf[1] = @intCast(b);
            try std.testing.expectEqual(std.unicode.utf8ValidateSlice(&buf), validUtf8(&buf));
        }
    }
    // Every three-byte input starting with a lead byte of three or four.
    var buf3: [3]u8 = undefined;
    for (0xE0..0x100) |a| for (0x70..0xC0) |b| for (0x70..0xC0) |c| {
        buf3 = .{ @intCast(a), @intCast(b), @intCast(c) };
        try std.testing.expectEqual(std.unicode.utf8ValidateSlice(&buf3), validUtf8(&buf3));
    };
}

/// The number of code points in valid UTF-8.
pub fn countCodePoints(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if ((c & 0xC0) != 0x80) n += 1;
    }
    return n;
}
