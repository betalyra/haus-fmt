//! Codecs this binding ships (spec §13.4): std/time types as Zig values,
//! and the rules of the official profiles, `@haus-fmt/money/iso` and
//! `@haus-fmt/geo/wgs84` (spec §13.3, "Profiles").
//!
//! None of them is on by default: without a codec a std/time value decodes
//! to its checked text (`Decoded.time`), which keeps the value. An
//! application lists the ones it wants in a `decoding.Codecs`:
//!
//!     var codecs = try haus.decoding.Codecs.init(gpa, &.{
//!         haus.codecs.time.date.erased(),
//!         &haus.codecs.money.iso_money,
//!     });
//!     defer codecs.deinit(gpa);
//!     const d = try haus.decoding.decode(arena, def, value, .{ .codecs = &codecs });
//!     const placed = haus.codecs.time.date.get(d.get("placed").?).?; // a Date

const std = @import("std");
const Allocator = std.mem.Allocator;
const epoch = std.time.epoch;
const decoding = @import("decode.zig");
const Decoded = decoding.Decoded;
const Reason = decoding.Reason;
const CodecError = decoding.CodecError;
const Codec = decoding.Codec;
const AnyCodec = decoding.AnyCodec;
const time_profile = @import("time.zig");

// ── std/time ─────────────────────────────────────────────────

/// std/time types as Zig values. Each codec takes the value the std/time
/// profile already checked, so decoding never fails for a valid value,
/// except where a codec says it rejects what its host type can't hold.
/// Encoding checks the value with the profile (`cannot-encode`).
///
/// What each host type drops, as spec §13.4 asks to say:
///
/// | Codec | std/time type | Host type | Drops |
/// |---|---|---|---|
/// | `date` | `Date` | `Date` | nothing |
/// | `year_month` | `YearMonth` | `YearMonth` | nothing |
/// | `time_of_day` | `Time` | `TimeOfDay` | trailing zeros of a fraction (`.250` is written `.25`) |
/// | `date_time` | `DateTime` | `DateTime` | the same |
/// | `instant` | `Instant` | `Instant` (with its offset) | the same, and `+00:00` is written `Z` |
/// | `instant_timestamp` | `Instant` | `std.Io.Timestamp` (UTC) | also the offset: it is written `Z` |
/// | `duration` | `Duration` | `std.Io.Duration` | how the time is split (`PT90M` is written `PT1H30M`); rejects years, months, weeks and days |
///
/// Where something is dropped, encoding writes a value that means the same
/// time but isn't equal (spec §2), with another canonical form and hash.
pub const time = struct {
    pub const Month = epoch.Month;

    pub const Weekday = enum(u3) {
        monday,
        tuesday,
        wednesday,
        thursday,
        friday,
        saturday,
        sunday,

        pub fn name(w: Weekday) []const u8 {
            return switch (w) {
                .monday => "Monday",
                .tuesday => "Tuesday",
                .wednesday => "Wednesday",
                .thursday => "Thursday",
                .friday => "Friday",
                .saturday => "Saturday",
                .sunday => "Sunday",
            };
        }
    };

    /// A day of the proleptic Gregorian calendar, years 0000–9999.
    pub const Date = struct {
        year: u16,
        month: Month,
        day: u5,

        /// Days since 1970-01-01 (negative before it).
        pub fn epochDay(d: Date) i64 {
            // Howard Hinnant's days_from_civil.
            const m: i64 = @backingInt(d.month);
            const y: i64 = @as(i64, d.year) - @intFromBool(m <= 2);
            const era = @divFloor(y, 400);
            const yoe = y - era * 400;
            const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d.day - 1;
            const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
            return era * 146097 + doe - 719468;
        }

        pub fn fromEpochDay(n: i64) Date {
            const z = n + 719468;
            const era = @divFloor(z, 146097);
            const doe = z - era * 146097;
            const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
            const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
            const mp = @divFloor(5 * doy + 2, 153);
            const day = doy - @divFloor(153 * mp + 2, 5) + 1;
            const month = if (mp < 10) mp + 3 else mp - 9;
            const year = yoe + era * 400 + @intFromBool(month <= 2);
            return .{ .year = @intCast(year), .month = @fromBackingInt(@as(u4, @intCast(month))), .day = @intCast(day) };
        }

        pub fn weekday(d: Date) Weekday {
            // 1970-01-01 was a Thursday.
            return @fromBackingInt(@as(u3, @intCast(@mod(d.epochDay() + 3, 7))));
        }

        fn valid(d: Date) bool {
            return d.year <= 9999 and d.day >= 1 and d.day <= epoch.getDaysInMonth(d.year, d.month);
        }
    };

    pub const YearMonth = struct { year: u16, month: Month };

    /// A time of day: no leap seconds, and a fraction in nanoseconds.
    pub const TimeOfDay = struct {
        hour: u5,
        minute: u6,
        second: u6,
        nanosecond: u30 = 0,

        fn valid(t: TimeOfDay) bool {
            return t.hour < 24 and t.minute < 60 and t.second < 60 and t.nanosecond < 1_000_000_000;
        }

        fn nanosOfDay(t: TimeOfDay) i64 {
            return ((@as(i64, t.hour) * 60 + t.minute) * 60 + t.second) * std.time.ns_per_s + t.nanosecond;
        }
    };

    pub const DateTime = struct { date: Date, time: TimeOfDay };

    /// An instant with the offset it was written with, in minutes east of UTC.
    pub const Instant = struct {
        date_time: DateTime,
        offset_minutes: i16 = 0,

        /// The point on the timeline: nanoseconds since 1970-01-01T00:00:00Z.
        pub fn timestamp(i: Instant) std.Io.Timestamp {
            const local: i128 = @as(i128, i.date_time.date.epochDay()) * std.time.ns_per_day + i.date_time.time.nanosOfDay();
            return .{ .nanoseconds = @intCast(local - @as(i128, i.offset_minutes) * std.time.ns_per_min) };
        }

        /// The instant at `ts`, written with the offset `offset_minutes`.
        pub fn fromTimestamp(ts: std.Io.Timestamp, offset_minutes: i16) Instant {
            const local: i128 = @as(i128, ts.nanoseconds) + @as(i128, offset_minutes) * std.time.ns_per_min;
            const day = @divFloor(local, std.time.ns_per_day);
            const ns: i64 = @intCast(local - day * std.time.ns_per_day);
            const day_i64 = std.math.cast(i64, day) orelse std.math.maxInt(i64) / 2;
            const s = @divFloor(ns, std.time.ns_per_s);
            return .{
                .date_time = .{
                    .date = if (day_i64 >= -719528 and day_i64 <= 2932896) Date.fromEpochDay(day_i64) else .{ .year = 10000, .month = .jan, .day = 1 },
                    .time = .{
                        .hour = @intCast(@divFloor(s, 3600)),
                        .minute = @intCast(@mod(@divFloor(s, 60), 60)),
                        .second = @intCast(@mod(s, 60)),
                        .nanosecond = @intCast(@mod(ns, std.time.ns_per_s)),
                    },
                },
                .offset_minutes = offset_minutes,
            };
        }
    };

    // ── reading the checked text ──

    fn num(s: []const u8) u32 {
        var n: u32 = 0;
        for (s) |c| n = n * 10 + (c - '0');
        return n;
    }

    fn readDate(s: []const u8) Date {
        return .{ .year = @intCast(num(s[0..4])), .month = @fromBackingInt(@as(u4, @intCast(num(s[5..7])))), .day = @intCast(num(s[8..10])) };
    }

    /// `hh:mm:ss[.f]` at the start of `s`; returns the time and its length.
    fn readTime(s: []const u8) struct { TimeOfDay, usize } {
        var t: TimeOfDay = .{ .hour = @intCast(num(s[0..2])), .minute = @intCast(num(s[3..5])), .second = @intCast(num(s[6..8])) };
        var i: usize = 8;
        if (i < s.len and s[i] == '.') {
            i += 1;
            var ns: u32 = 0;
            var digits: u32 = 0;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
                ns = ns * 10 + (s[i] - '0');
                digits += 1;
            }
            while (digits < 9) : (digits += 1) ns *= 10;
            t.nanosecond = @intCast(ns);
        }
        return .{ t, i };
    }

    fn readDateTime(s: []const u8) struct { DateTime, usize } {
        const t, const n = readTime(s[11..]);
        return .{ .{ .date = readDate(s), .time = t }, 11 + n };
    }

    fn readInstant(s: []const u8) Instant {
        const dt, const n = readDateTime(s);
        const off = s[n..];
        if (off[0] == 'Z') return .{ .date_time = dt };
        const minutes: i16 = @intCast(num(off[1..3]) * 60 + num(off[4..6]));
        return .{ .date_time = dt, .offset_minutes = if (off[0] == '-') -minutes else minutes };
    }

    fn textOf(d: Decoded, kind: time_profile.Kind) []const u8 {
        // The schema decoded it, as this kind.
        std.debug.assert(d == .time and d.time.kind == kind);
        return d.time.text;
    }

    // ── writing ──

    fn writeDate(w: *std.Io.Writer, d: Date) !void {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, @backingInt(d.month), d.day });
    }

    fn writeTime(w: *std.Io.Writer, t: TimeOfDay) !void {
        try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
        if (t.nanosecond != 0) {
            var buf: [9]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{t.nanosecond}) catch unreachable;
            var n: usize = 9;
            while (buf[n - 1] == '0') n -= 1;
            try w.print(".{s}", .{buf[0..n]});
        }
    }

    fn writeOffset(w: *std.Io.Writer, minutes: i16) !void {
        if (minutes == 0) return w.writeByte('Z');
        const m: u16 = @abs(minutes);
        try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (minutes < 0) '-' else '+'), m / 60, m % 60 });
    }

    /// The `Decoded.time` for `text`, checked with the profile.
    fn checked(arena: Allocator, kind: time_profile.Kind, text: []const u8, reason: *Reason) CodecError!Decoded {
        if (!time_profile.check(kind, text)) return reason.reject("{s} is not a valid {s}", .{ text, @tagName(kind) });
        return .{ .time = .{ .kind = kind, .text = try arena.dupe(u8, text) } };
    }

    fn written(arena: Allocator, kind: time_profile.Kind, x: anytype, comptime write: anytype, reason: *Reason) CodecError!Decoded {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        write(&w, x) catch return reason.reject("the value can't be written as a {s}", .{@tagName(kind)});
        return checked(arena, kind, w.buffered(), reason);
    }

    // ── the codecs ──

    pub const date = Codec(Date).init("std/time#Date", struct {
        fn dec(_: Allocator, d: Decoded, _: *Reason) CodecError!Date {
            return readDate(textOf(d, .Date));
        }
    }.dec, struct {
        fn enc(arena: Allocator, x: Date, reason: *Reason) CodecError!Decoded {
            if (!x.valid()) return reason.reject("{d}-{d}-{d} is not a day of the years 0000–9999", .{ x.year, @backingInt(x.month), x.day });
            return written(arena, .Date, x, writeDate, reason);
        }
    }.enc);

    pub const year_month = Codec(YearMonth).init("std/time#YearMonth", struct {
        fn dec(_: Allocator, d: Decoded, _: *Reason) CodecError!YearMonth {
            const s = textOf(d, .YearMonth);
            return .{ .year = @intCast(num(s[0..4])), .month = @fromBackingInt(@as(u4, @intCast(num(s[5..7])))) };
        }
    }.dec, struct {
        fn write(w: *std.Io.Writer, x: YearMonth) !void {
            try w.print("{d:0>4}-{d:0>2}", .{ x.year, @backingInt(x.month) });
        }
        fn enc(arena: Allocator, x: YearMonth, reason: *Reason) CodecError!Decoded {
            if (x.year > 9999) return reason.reject("the year {d} is outside 0000–9999", .{x.year});
            return written(arena, .YearMonth, x, write, reason);
        }
    }.enc);

    pub const time_of_day = Codec(TimeOfDay).init("std/time#Time", struct {
        fn dec(_: Allocator, d: Decoded, _: *Reason) CodecError!TimeOfDay {
            return readTime(textOf(d, .Time))[0];
        }
    }.dec, struct {
        fn enc(arena: Allocator, x: TimeOfDay, reason: *Reason) CodecError!Decoded {
            if (!x.valid()) return reason.reject("not a time of day", .{});
            return written(arena, .Time, x, writeTime, reason);
        }
    }.enc);

    pub const date_time = Codec(DateTime).init("std/time#DateTime", struct {
        fn dec(_: Allocator, d: Decoded, _: *Reason) CodecError!DateTime {
            return readDateTime(textOf(d, .DateTime))[0];
        }
    }.dec, struct {
        fn write(w: *std.Io.Writer, x: DateTime) !void {
            try writeDate(w, x.date);
            try w.writeByte('T');
            try writeTime(w, x.time);
        }
        fn enc(arena: Allocator, x: DateTime, reason: *Reason) CodecError!Decoded {
            if (!x.date.valid() or !x.time.valid()) return reason.reject("not a date and time of the years 0000–9999", .{});
            return written(arena, .DateTime, x, write, reason);
        }
    }.enc);

    fn writeInstant(w: *std.Io.Writer, x: Instant) !void {
        try writeDate(w, x.date_time.date);
        try w.writeByte('T');
        try writeTime(w, x.date_time.time);
        try writeOffset(w, x.offset_minutes);
    }

    fn validInstant(x: Instant, reason: *Reason) error{Rejected}!void {
        if (!x.date_time.date.valid() or !x.date_time.time.valid()) return reason.reject("not a date and time of the years 0000–9999", .{});
        if (@abs(x.offset_minutes) >= 24 * 60) return reason.reject("the offset {d} minutes is outside ±23:59", .{x.offset_minutes});
    }

    pub const instant = Codec(Instant).init("std/time#Instant", struct {
        fn dec(_: Allocator, d: Decoded, _: *Reason) CodecError!Instant {
            return readInstant(textOf(d, .Instant));
        }
    }.dec, struct {
        fn enc(arena: Allocator, x: Instant, reason: *Reason) CodecError!Decoded {
            try validInstant(x, reason);
            return written(arena, .Instant, x, writeInstant, reason);
        }
    }.enc);

    /// Keeps the instant only, as UTC nanoseconds: the offset it was
    /// written with is dropped, and it is written back with `Z`.
    pub const instant_timestamp = Codec(std.Io.Timestamp).init("std/time#Instant", struct {
        fn dec(_: Allocator, d: Decoded, _: *Reason) CodecError!std.Io.Timestamp {
            return readInstant(textOf(d, .Instant)).timestamp();
        }
    }.dec, struct {
        fn enc(arena: Allocator, x: std.Io.Timestamp, reason: *Reason) CodecError!Decoded {
            const i = Instant.fromTimestamp(x, 0);
            if (i.date_time.date.year > 9999) return reason.reject("the instant is outside the years 0000–9999", .{});
            return written(arena, .Instant, i, writeInstant, reason);
        }
    }.enc);

    /// Durations of hours, minutes and seconds only, as nanoseconds. A
    /// duration with years, months, weeks or days has no fixed length: it
    /// is rejected (`codec-rejected`).
    pub const duration = Codec(std.Io.Duration).init("std/time#Duration", struct {
        fn dec(_: Allocator, d: Decoded, reason: *Reason) CodecError!std.Io.Duration {
            const s = textOf(d, .Duration);
            var i: usize = 0;
            const negative = s[0] == '-';
            if (negative) i += 1;
            i += 1; // P
            if (i >= s.len or s[i] != 'T') return reason.reject("{s} has years, months, weeks or days, which have no fixed length", .{s});
            i += 1;
            var total: i128 = 0;
            while (i < s.len) {
                var n: i128 = 0;
                while (std.ascii.isDigit(s[i])) : (i += 1) n = n * 10 + (s[i] - '0');
                var frac: i128 = 0;
                if (s[i] == '.') {
                    i += 1;
                    var digits: u32 = 0;
                    while (std.ascii.isDigit(s[i])) : (i += 1) {
                        frac = frac * 10 + (s[i] - '0');
                        digits += 1;
                    }
                    while (digits < 9) : (digits += 1) frac *= 10;
                }
                const unit: i128 = switch (s[i]) {
                    'H' => std.time.ns_per_hour,
                    'M' => std.time.ns_per_min,
                    else => std.time.ns_per_s,
                };
                total += n * unit + frac;
                i += 1;
            }
            return .{ .nanoseconds = @intCast(if (negative) -total else total) };
        }
    }.dec, struct {
        fn write(w: *std.Io.Writer, x: std.Io.Duration) !void {
            const ns: u128 = @abs(@as(i128, x.nanoseconds));
            if (ns == 0) return w.writeAll("PT0S");
            if (x.nanoseconds < 0) try w.writeByte('-');
            try w.writeAll("PT");
            const secs = ns / std.time.ns_per_s;
            const h = secs / 3600;
            const m = secs / 60 % 60;
            const sec = secs % 60;
            const f = ns % std.time.ns_per_s;
            if (h > 0) try w.print("{d}H", .{h});
            if (m > 0) try w.print("{d}M", .{m});
            if (sec > 0 or f > 0) {
                try w.print("{d}", .{sec});
                if (f > 0) {
                    var buf: [9]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{f}) catch unreachable;
                    var n: usize = 9;
                    while (buf[n - 1] == '0') n -= 1;
                    try w.print(".{s}", .{buf[0..n]});
                }
                try w.writeByte('S');
            }
        }
        fn enc(arena: Allocator, x: std.Io.Duration, reason: *Reason) CodecError!Decoded {
            const secs = @abs(@as(i128, x.nanoseconds)) / std.time.ns_per_s;
            if (secs >= 1 << 53) return reason.reject("the duration is 2^53 seconds or longer", .{});
            return written(arena, .Duration, x, write, reason);
        }
    }.enc);

    /// Every std/time codec above with a host type that keeps the instant
    /// and its offset (not `instant_timestamp` or `duration`).
    pub const all = [_]*const AnyCodec{ date.erased(), year_month.erased(), time_of_day.erased(), date_time.erased(), instant.erased() };
};

// ── @haus-fmt/money/iso ──────────────────────────────────────

/// The profile `@haus-fmt/money/iso` (extensions/money/profiles/iso.md):
/// a currency is three letters A–Z with no payload, and a `Money` is
/// accepted when its currency is. The host types stay the default ones.
pub const money = struct {
    pub const money_id = "@haus-fmt/money@1#Money";
    pub const currency_id = "@haus-fmt/money@1#Currency";

    /// The rule for a `Currency`, as decoded (an unknown tag of `< >`).
    pub fn acceptsCurrency(d: Decoded, reason: *Reason) error{Rejected}!void {
        const tag, const args = switch (d) {
            .unknown => |u| .{ u.tag, u.args.len },
            .variant => |t| .{ t.tag, t.args.len },
            // A host value of an application's own Currency codec: it
            // checked the value itself.
            else => return,
        };
        if (args != 0) return reason.reject("{s} has a payload: a currency is a bare tag", .{tag});
        if (tag.len != 3) return reason.reject("{s} is not a currency: three letters A–Z (ISO 4217)", .{tag});
        for (tag) |c| if (c < 'A' or c > 'Z') return reason.reject("{s} is not a currency: three letters A–Z (ISO 4217)", .{tag});
    }

    /// The rule for a `Money`: its currency is accepted.
    pub fn acceptsMoney(d: Decoded, reason: *Reason) error{Rejected}!void {
        if (d != .variant) return;
        return acceptsCurrency(d.variant.args[1], reason);
    }

    pub const iso_money: AnyCodec = decoding.rule(money_id, acceptsMoney);
    pub const iso_currency: AnyCodec = decoding.rule(currency_id, acceptsCurrency);
    /// Both codecs of the profile.
    pub const iso = [_]*const AnyCodec{ &iso_money, &iso_currency };
};

// ── @haus-fmt/geo/wgs84 ──────────────────────────────────────

/// The profile `@haus-fmt/geo/wgs84` (extensions/geo/profiles/wgs84.md):
/// latitudes in −90…90 and longitudes in −180…180 (no NaN or infinity),
/// and a box's south-west corner not north of its north-east one. The
/// host types stay the default ones (two `f64`).
pub const geo = struct {
    pub const lat_lng_id = "@haus-fmt/geo@1#LatLng";
    pub const bbox_id = "@haus-fmt/geo@1#BBox";

    pub const Point = struct { lat: f64, lng: f64 };

    /// The latitude and longitude of a decoded `LatLng`.
    pub fn point(d: Decoded) ?Point {
        if (d != .variant or d.variant.args.len != 2) return null;
        return .{ .lat = d.variant.args[0].float64, .lng = d.variant.args[1].float64 };
    }

    pub fn acceptsLatLng(d: Decoded, reason: *Reason) error{Rejected}!void {
        const p = point(d) orelse return;
        if (!(p.lat >= -90 and p.lat <= 90)) return reason.reject("the latitude {d} is outside −90…90", .{p.lat});
        if (!(p.lng >= -180 and p.lng <= 180)) return reason.reject("the longitude {d} is outside −180…180", .{p.lng});
    }

    pub fn acceptsBBox(d: Decoded, reason: *Reason) error{Rejected}!void {
        if (d != .variant or d.variant.args.len != 2) return;
        const sw = d.variant.args[0];
        const ne = d.variant.args[1];
        try acceptsLatLng(sw, reason);
        try acceptsLatLng(ne, reason);
        const a = point(sw) orelse return;
        const b = point(ne) orelse return;
        if (a.lat > b.lat) return reason.reject("the south-west corner ({d}) is north of the north-east one ({d})", .{ a.lat, b.lat });
    }

    pub const wgs84_lat_lng: AnyCodec = decoding.rule(lat_lng_id, acceptsLatLng);
    pub const wgs84_bbox: AnyCodec = decoding.rule(bbox_id, acceptsBBox);
    /// Both codecs of the profile.
    pub const wgs84 = [_]*const AnyCodec{ &wgs84_lat_lng, &wgs84_bbox };
};

// ── tests: the codec contract (spec §13.4) ───────────────────

const testing = std.testing;
const schema = @import("schema.zig");
const canonical = @import("canonical.zig");
const errors = @import("errors.zig");
const parseOne = @import("root.zig").parse;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    s: *schema.Schema,

    fn init(text: []const u8, module: []const u8) !Fixture {
        return .{ .arena_state = .init(testing.allocator), .s = try schema.load(testing.allocator, text, .{ .module = module }) };
    }

    fn deinit(f: *Fixture) void {
        f.s.deinit();
        f.arena_state.deinit();
    }

    fn decode(f: *Fixture, ty: []const u8, text: []const u8, cs: ?*const decoding.Codecs, d: *errors.Diagnostic) !Decoded {
        const a = f.arena_state.allocator();
        return decoding.decodeText(a, a, f.s.get(ty).?, text, .{ .codecs = cs, .diagnostic = d });
    }

    /// The canonical text `d` encodes to.
    fn encode(f: *Fixture, ty: []const u8, d: Decoded, cs: ?*const decoding.Codecs, diag: *errors.Diagnostic) ![]const u8 {
        const a = f.arena_state.allocator();
        const v = try decoding.encode(a, f.s.get(ty).?, d, .{ .codecs = cs, .diagnostic = diag });
        return canonical.canonical(a, v, .{});
    }
};

test "std/time codecs: decode, encode, decode is decode" {
    var f = try Fixture.init(
        \\import std/time (Date, Time, DateTime, Instant, YearMonth, Duration)
        \\type T = { d: Date, t: Time, dt: DateTime, i: Instant, ym: YearMonth, du: Duration }
    , "local");
    defer f.deinit();
    var cs = try decoding.Codecs.init(testing.allocator, &(time.all ++ [_]*const AnyCodec{time.duration.erased()}));
    defer cs.deinit(testing.allocator);
    var diag: errors.Diagnostic = .{};
    const text =
        \\{ d: Date("2026-11-09"), t: Time("14:30:00.250"), dt: DateTime("0000-02-29T23:59:59.000000001"),
        \\  i: Instant("2026-11-09T14:30:00-01:30"), ym: YearMonth("9999-12"), du: Duration("-PT90M") }
    ;
    const d = try f.decode("T", text, &cs, &diag);
    const date = time.date.get(d.get("d").?).?;
    try testing.expectEqual(@as(u16, 2026), date.year);
    try testing.expectEqual(time.Month.nov, date.month);
    try testing.expectEqualStrings("Monday", date.weekday().name());
    try testing.expectEqual(@as(u30, 250_000_000), time.time_of_day.get(d.get("t").?).?.nanosecond);
    const inst = time.instant.get(d.get("i").?).?;
    try testing.expectEqual(@as(i16, -90), inst.offset_minutes);
    // 2026-11-09T16:00:00Z.
    try testing.expectEqual(@as(i96, 1_794_240_000) * std.time.ns_per_s, inst.timestamp().nanoseconds);
    try testing.expectEqual(@as(i96, -90 * std.time.ns_per_min), time.duration.get(d.get("du").?).?.nanoseconds);
    // The host types drop the fraction's zeros and the split of a duration.
    const once = try f.encode("T", d, &cs, &diag);
    try testing.expectEqualStrings(
        \\{d:Date("2026-11-09"),dt:DateTime("0000-02-29T23:59:59.000000001"),du:Duration("-PT1H30M"),i:Instant("2026-11-09T14:30:00-01:30"),t:Time("14:30:00.25"),ym:YearMonth("9999-12")}
    , once);
    // Decoding what was encoded gives the same host values again.
    const again = try f.decode("T", once, &cs, &diag);
    try testing.expectEqual(date, time.date.get(again.get("d").?).?);
    try testing.expectEqual(inst, time.instant.get(again.get("i").?).?);
    try testing.expectEqualStrings(once, try f.encode("T", again, &cs, &diag));
    // Without codecs the default host type keeps the value as written.
    const plain = try f.decode("T", text, null, &diag);
    try testing.expectEqualStrings("14:30:00.250", plain.get("t").?.time.text);
    try testing.expect(time.date.get(plain.get("d").?) == null);
}

test "Date arithmetic over the whole range" {
    var day: i64 = (time.Date{ .year = 0, .month = .jan, .day = 1 }).epochDay();
    try testing.expectEqual(@as(i64, -719528), day);
    try testing.expectEqual(@as(i64, 0), (time.Date{ .year = 1970, .month = .jan, .day = 1 }).epochDay());
    const last = (time.Date{ .year = 9999, .month = .dec, .day = 31 }).epochDay();
    while (day <= last) : (day += 997) {
        const d = time.Date.fromEpochDay(day);
        try testing.expectEqual(day, d.epochDay());
        try testing.expect(d.valid());
    }
    try testing.expectEqual(time.Weekday.thursday, (time.Date{ .year = 1970, .month = .jan, .day = 1 }).weekday());
}

test "a lossy codec is explicit: an Instant as a timestamp is written in UTC" {
    var f = try Fixture.init("import std/time (Instant)\ntype T = Instant", "local");
    defer f.deinit();
    var cs = try decoding.Codecs.init(testing.allocator, &.{time.instant_timestamp.erased()});
    defer cs.deinit(testing.allocator);
    var diag: errors.Diagnostic = .{};
    const d = try f.decode("T", "Instant(\"2026-11-09T14:30:00.5+01:00\")", &cs, &diag);
    const ts = time.instant_timestamp.get(d).?;
    // The same instant, another value (§13.4, "keeps less").
    try testing.expectEqualStrings("Instant(\"2026-11-09T13:30:00.5Z\")", try f.encode("T", d, &cs, &diag));
    // A timestamp outside the years 0000–9999 can't be written.
    const a = f.arena_state.allocator();
    const far = try time.instant_timestamp.wrap(a, .{ .nanoseconds = ts.nanoseconds * 1000 });
    try testing.expectError(error.Haus, f.encode("T", far, &cs, &diag));
    try testing.expectEqual(errors.Code.@"cannot-encode", diag.code);
    try testing.expectEqualStrings("$", diag.path());
}

test "a codec that rejects what its host type can't hold" {
    var f = try Fixture.init("import std/time (Duration)\ntype T = { a: Duration }", "local");
    defer f.deinit();
    var cs = try decoding.Codecs.init(testing.allocator, &.{time.duration.erased()});
    defer cs.deinit(testing.allocator);
    var diag: errors.Diagnostic = .{};
    try testing.expectError(error.Haus, f.decode("T", "{ a: Duration(\"P1DT1H\") }", &cs, &diag));
    try testing.expectEqual(errors.Code.@"codec-rejected", diag.code);
    try testing.expectEqualStrings("$.a", diag.path());
    try testing.expect(std.mem.startsWith(u8, diag.message(), "std/time#Duration rejects the value: "));
    // Without the codec it is a valid Duration.
    _ = try f.decode("T", "{ a: Duration(\"P1DT1H\") }", null, &diag);
    // A value the schema rejects never reaches the codec.
    try testing.expectError(error.Haus, f.decode("T", "{ a: Duration(\"P\") }", &cs, &diag));
    try testing.expectEqual(errors.Code.@"invalid-time", diag.code);
}

/// A Currency as a Zig enum: an application's own codec for a package's type.
const Iso = enum { EUR, USD, CHF };
const currency_enum = Codec(Iso).init(money.currency_id, struct {
    fn dec(_: Allocator, d: Decoded, reason: *Reason) CodecError!Iso {
        try money.acceptsCurrency(d, reason);
        return std.meta.stringToEnum(Iso, d.unknown.tag) orelse reason.reject("{s} is not a currency this shop takes", .{d.unknown.tag});
    }
}.dec, struct {
    fn enc(_: Allocator, x: Iso, _: *Reason) CodecError!Decoded {
        return .{ .unknown = .{ .tag = @tagName(x) } };
    }
}.enc);

const money_schema =
    \\type Money = closed < Money Decimal Currency >
    \\type Currency = < >
;

test "codecs run from the inside out, the first rejection at its own place" {
    var f = try Fixture.init(money_schema, "@haus-fmt/money@1");
    defer f.deinit();
    var cs = try decoding.Codecs.init(testing.allocator, &.{ currency_enum.erased(), &money.iso_money });
    defer cs.deinit(testing.allocator);
    var diag: errors.Diagnostic = .{};
    const d = try f.decode("Money", "Money(19.90, CHF)", &cs, &diag);
    // The Money rule saw the Currency's host value.
    try testing.expectEqual(Iso.CHF, currency_enum.get(d.variant.args[1]).?);
    try testing.expectEqualStrings("Money(19.90,CHF)", try f.encode("Money", d, &cs, &diag));
    // The inner codec rejects first, at its place.
    try testing.expectError(error.Haus, f.decode("Money", "Money(1, GBP)", &cs, &diag));
    try testing.expectEqual(errors.Code.@"codec-rejected", diag.code);
    try testing.expectEqualStrings("$[1]", diag.path());
    try testing.expect(std.mem.startsWith(u8, diag.message(), "@haus-fmt/money@1#Currency rejects the value"));
    // The same file read as another package: its ids differ, no codec applies.
    var other = try Fixture.init(money_schema, "@acme/money@1");
    defer other.deinit();
    _ = try other.decode("Money", "Money(1, GBP)", &cs, &diag);
}

test "a rule is checked when encoding too" {
    var f = try Fixture.init(money_schema, "@haus-fmt/money@1");
    defer f.deinit();
    var cs = try decoding.Codecs.init(testing.allocator, &money.iso);
    defer cs.deinit(testing.allocator);
    var diag: errors.Diagnostic = .{};
    const d = try f.decode("Money", "Money(19.90, EUR)", &cs, &diag);
    try testing.expectEqualStrings("Money(19.90,EUR)", try f.encode("Money", d, &cs, &diag));
    const bad: Decoded = .{ .variant = .{ .tag = "Money", .args = &.{ .{ .decimal = "1" }, .{ .unknown = .{ .tag = "Eur" } } } } };
    try testing.expectError(error.Haus, f.encode("Money", bad, &cs, &diag));
    try testing.expectEqual(errors.Code.@"cannot-encode", diag.code);
    // A host value whose codec rejects it is not written either.
    const a = f.arena_state.allocator();
    var date_f = try Fixture.init("import std/time (Date)\ntype T = Array Date", "local");
    defer date_f.deinit();
    const feb30 = try time.date.wrap(a, .{ .year = 2026, .month = .feb, .day = 30 });
    try testing.expectError(error.Haus, date_f.encode("T", .{ .array = &.{feb30} }, null, &diag));
    try testing.expectEqual(errors.Code.@"cannot-encode", diag.code);
    try testing.expectEqualStrings("$[0]", diag.path());
}

test "codecs on record payloads, inside secrets, and one per id" {
    var f = try Fixture.init(
        \\type Base = { lat: Float64, lng: Float64 }
        \\type Shape = < At Base | Hidden (Secret LatLng) >
        \\type LatLng = closed < LatLng Float64 Float64 >
    , "@haus-fmt/geo@1");
    defer f.deinit();
    const base_codec = Codec(geo.Point).init("@haus-fmt/geo@1#Base", struct {
        fn dec(_: Allocator, d: Decoded, _: *Reason) CodecError!geo.Point {
            return .{ .lat = d.get("lat").?.float64, .lng = d.get("lng").?.float64 };
        }
    }.dec, struct {
        fn enc(arena: Allocator, p: geo.Point, _: *Reason) CodecError!Decoded {
            const e = try arena.dupe(Decoded.Entry, &.{ .{ .key = "lat", .value = .{ .float64 = p.lat } }, .{ .key = "lng", .value = .{ .float64 = p.lng } } });
            return .{ .record = e };
        }
    }.enc);
    var cs = try decoding.Codecs.init(testing.allocator, &.{ base_codec.erased(), &geo.wgs84_lat_lng });
    defer cs.deinit(testing.allocator);
    var diag: errors.Diagnostic = .{};
    const d = try f.decode("Shape", "At { lat: 1.5, lng: 2 }", &cs, &diag);
    try testing.expectEqual(geo.Point{ .lat = 1.5, .lng = 2 }, base_codec.get(d.variant.args[0]).?);
    try testing.expectEqualStrings("At{lat:1.5,lng:2}", try f.encode("Shape", d, &cs, &diag));
    // An error inside a Secret is at the secret (§15).
    try testing.expectError(error.Haus, f.decode("Shape", "Hidden(LatLng(91, 0))", &cs, &diag));
    try testing.expectEqual(errors.Code.@"invalid-secret", diag.code);
    try testing.expectEqualStrings("$[0]", diag.path());
    try testing.expectError(error.DuplicateCodec, decoding.Codecs.init(testing.allocator, &.{ &geo.wgs84_lat_lng, &geo.wgs84_lat_lng }));
}

test "the type ids" {
    var f = try Fixture.init("type A = Int", "local");
    defer f.deinit();
    try testing.expectEqualStrings("local#A", f.s.get("A").?.id);
    try testing.expectEqualStrings("prelude#Decimal", schema.builtinId(.Decimal));
    try testing.expectEqualStrings("std/time#ZonedDateTime", schema.timeId(.ZonedDateTime));
}
