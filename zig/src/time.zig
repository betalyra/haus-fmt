//! The std/time profile (spec/std/time.md): which strings each type of
//! `std/time` accepts. A schema binding checks exactly these rules (spec
//! §13.1); the parser doesn't.

const std = @import("std");

/// The types of `std/time` (spec/std/time.schema.haus).
pub const Kind = enum {
    Date,
    Time,
    DateTime,
    Instant,
    ZonedDateTime,
    Duration,
    YearMonth,
    TimeZone,

    pub fn fromName(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }

    pub fn typeName(k: Kind) []const u8 {
        return @tagName(k);
    }
};

/// Whether the profile accepts `s` for the type `kind`.
pub fn check(kind: Kind, s: []const u8) bool {
    var r: Reader = .{ .s = s };
    const ok = switch (kind) {
        .Date => r.date(),
        .Time => r.time(),
        .DateTime => r.dateTime(),
        .Instant => r.dateTime() and r.offset(),
        .ZonedDateTime => r.dateTime() and r.offset() and r.bracketZone(),
        .Duration => r.duration(),
        .YearMonth => r.yearMonth(),
        .TimeZone => r.zone(r.s.len),
    };
    return ok and r.i == s.len;
}

const Reader = struct {
    s: []const u8,
    i: usize = 0,

    fn eat(r: *Reader, c: u8) bool {
        if (r.i < r.s.len and r.s[r.i] == c) {
            r.i += 1;
            return true;
        }
        return false;
    }

    /// Exactly `n` ASCII digits, as a number.
    fn digits(r: *Reader, n: usize) ?u32 {
        if (r.i + n > r.s.len) return null;
        var x: u32 = 0;
        for (r.s[r.i .. r.i + n]) |c| {
            if (c < '0' or c > '9') return null;
            x = x * 10 + (c - '0');
        }
        r.i += n;
        return x;
    }

    fn yearMonthParts(r: *Reader) ?struct { year: u32, month: u32 } {
        const year = r.digits(4) orelse return null;
        if (!r.eat('-')) return null;
        const month = r.digits(2) orelse return null;
        if (month < 1 or month > 12) return null;
        return .{ .year = year, .month = month };
    }

    fn yearMonth(r: *Reader) bool {
        return r.yearMonthParts() != null;
    }

    fn date(r: *Reader) bool {
        const ym = r.yearMonthParts() orelse return false;
        if (!r.eat('-')) return false;
        const day = r.digits(2) orelse return false;
        return day >= 1 and day <= daysIn(ym.year, ym.month);
    }

    /// `hh:mm:ss` and an optional fraction of 1–9 digits.
    fn time(r: *Reader) bool {
        const h = r.digits(2) orelse return false;
        if (!r.eat(':')) return false;
        const m = r.digits(2) orelse return false;
        if (!r.eat(':')) return false;
        const sec = r.digits(2) orelse return false;
        if (h > 23 or m > 59 or sec > 59) return false;
        if (r.eat('.')) {
            const start = r.i;
            while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
            const n = r.i - start;
            if (n < 1 or n > 9) return false;
        }
        return true;
    }

    fn dateTime(r: *Reader) bool {
        return r.date() and r.eat('T') and r.time();
    }

    /// `±hh:mm` up to `±23:59`, not `-00:00`.
    fn numericOffset(r: *Reader) bool {
        if (r.i >= r.s.len) return false;
        const sign = r.s[r.i];
        if (sign != '+' and sign != '-') return false;
        r.i += 1;
        const h = r.digits(2) orelse return false;
        if (!r.eat(':')) return false;
        const m = r.digits(2) orelse return false;
        if (h > 23 or m > 59) return false;
        if (sign == '-' and h == 0 and m == 0) return false;
        return true;
    }

    /// `Z` or a numeric offset.
    fn offset(r: *Reader) bool {
        if (r.eat('Z')) return true;
        return r.numericOffset();
    }

    /// `[zone]` at the end: exactly one.
    fn bracketZone(r: *Reader) bool {
        if (!r.eat('[')) return false;
        const close = std.mem.indexOfScalarPos(u8, r.s, r.i, ']') orelse return false;
        if (!r.zone(close)) return false;
        return r.eat(']');
    }

    /// A zone name or an offset, from `i` up to `end`.
    fn zone(r: *Reader, end: usize) bool {
        const z = r.s[r.i..end];
        if (z.len > 0 and (z[0] == '+' or z[0] == '-')) {
            var sub: Reader = .{ .s = z };
            if (!sub.numericOffset() or sub.i != z.len) return false;
            r.i = end;
            return true;
        }
        if (z.len == 0 or z.len > 255) return false;
        // `Z` and `z` are the offset letter, not a zone name.
        if (std.mem.eql(u8, z, "Z") or std.mem.eql(u8, z, "z")) return false;
        if (!std.ascii.isAlphabetic(z[0])) return false;
        var parts = std.mem.splitScalar(u8, z, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
            for (part) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '+' or c == '-')) return false;
            }
        }
        r.i = end;
        return true;
    }

    /// A component's number: digits without leading zeros, saturated.
    fn count(r: *Reader) ?struct { value: u128, zero: bool } {
        const start = r.i;
        while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
        const ds = r.s[start..r.i];
        if (ds.len == 0) return null;
        if (ds.len > 1 and ds[0] == '0') return null;
        var x: u128 = 0;
        for (ds) |c| {
            x = std.math.mul(u128, x, 10) catch std.math.maxInt(u128);
            x = std.math.add(u128, x, c - '0') catch std.math.maxInt(u128);
        }
        return .{ .value = x, .zero = x == 0 };
    }

    fn duration(r: *Reader) bool {
        const negative = r.eat('-');
        if (!r.eat('P')) return false;
        const two32: u128 = 1 << 32;
        const two53: u128 = 1 << 53;
        var components: usize = 0;
        var zero_component = false;
        var seconds_total: u128 = 0;
        var only_zero_seconds = false;
        // Date part: Y, M, W, D in this order, each at most once.
        const date_units = "YMWD";
        var next_unit: usize = 0;
        while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') {
            const n = r.count() orelse return false;
            if (r.i >= r.s.len) return false;
            const unit = std.mem.indexOfScalarPos(u8, date_units, next_unit, r.s[r.i]) orelse return false;
            r.i += 1;
            next_unit = unit + 1;
            components += 1;
            if (n.zero) zero_component = true;
            switch (date_units[unit]) {
                'Y', 'M', 'W' => if (n.value >= two32) return false,
                'D' => seconds_total = sat(seconds_total, satMul(n.value, 86400)),
                else => unreachable,
            }
        }
        if (r.eat('T')) {
            const time_units = "HMS";
            var next_time: usize = 0;
            var any = false;
            while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') {
                const n = r.count() orelse return false;
                var fraction_zero = true;
                var has_fraction = false;
                if (r.eat('.')) {
                    has_fraction = true;
                    const start = r.i;
                    while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
                    const f = r.s[start..r.i];
                    if (f.len < 1 or f.len > 9) return false;
                    for (f) |c| if (c != '0') {
                        fraction_zero = false;
                    };
                }
                if (r.i >= r.s.len) return false;
                const unit = std.mem.indexOfScalarPos(u8, time_units, next_time, r.s[r.i]) orelse return false;
                // A fraction only on seconds.
                if (has_fraction and time_units[unit] != 'S') return false;
                r.i += 1;
                next_time = unit + 1;
                components += 1;
                any = true;
                const is_zero = n.zero and fraction_zero;
                if (is_zero) zero_component = true;
                if (is_zero and time_units[unit] == 'S' and components == 1) only_zero_seconds = true;
                const factor: u128 = switch (time_units[unit]) {
                    'H' => 3600,
                    'M' => 60,
                    'S' => 1,
                    else => unreachable,
                };
                seconds_total = sat(seconds_total, satMul(n.value, factor));
            }
            if (!any) return false;
        }
        if (components == 0) return false;
        if (seconds_total >= two53) return false;
        if (zero_component) {
            // The zero duration is `PT0S` (a fraction of zeros allowed), alone and unsigned.
            if (!(components == 1 and only_zero_seconds) or negative) return false;
        }
        return true;
    }
};

fn sat(a: u128, b: u128) u128 {
    return std.math.add(u128, a, b) catch std.math.maxInt(u128);
}

fn satMul(a: u128, b: u128) u128 {
    return std.math.mul(u128, a, b) catch std.math.maxInt(u128);
}

fn isLeap(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn daysIn(year: u32, month: u32) u32 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

test "std/time profile" {
    const t = std.testing;
    try t.expect(check(.Date, "2024-02-29"));
    try t.expect(check(.Date, "0000-02-29"));
    try t.expect(!check(.Date, "1900-02-29"));
    try t.expect(check(.Time, "12:00:00.123456789"));
    try t.expect(!check(.Time, "12:00:00.1234567890"));
    try t.expect(check(.Instant, "2026-11-09T14:30:00-23:59"));
    try t.expect(!check(.Instant, "2026-11-09T13:30:00-00:00"));
    try t.expect(check(.ZonedDateTime, "2026-11-09T14:30:00Z[Etc/GMT+1]"));
    try t.expect(!check(.ZonedDateTime, "2026-11-09T14:30:00Z[Z]"));
    try t.expect(check(.TimeZone, "Zulu"));
    try t.expect(!check(.TimeZone, "Z"));
    try t.expect(!check(.TimeZone, "z"));
    try t.expect(check(.TimeZone, "zulu"));
    try t.expect(check(.Duration, "PT0S"));
    try t.expect(check(.Duration, "PT0.0S"));
    try t.expect(!check(.Duration, "-PT0.0S"));
    try t.expect(!check(.Duration, "P1DT0.0S"));
    try t.expect(check(.Duration, "P1Y2M3W4DT5H6M7.5S"));
    try t.expect(check(.Duration, "PT9007199254740991.999999999S"));
    try t.expect(!check(.Duration, "PT9007199254740992S"));
    try t.expect(check(.Duration, "P104249991374D"));
    try t.expect(!check(.Duration, "P104249991375D"));
    try t.expect(!check(.Duration, "P4294967296Y"));
    try t.expect(!check(.Duration, "PT1.5H"));
    try t.expect(!check(.Duration, "P1DT"));
}
