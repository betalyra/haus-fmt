//! The same order, decoded with the schema's own types and with the app's
//! codecs (spec §13.4). The same steps as go/examples/order and
//! rust/examples/order, on the same files (../../examples/order.*).
//! Run: `zig build order` (from zig/).

const std = @import("std");
const haus = @import("haus");
const paths = @import("paths");
const Decoded = haus.Decoded;
const Allocator = std.mem.Allocator;
const Reason = haus.decoding.Reason;
const CodecError = haus.decoding.CodecError;
const Date = haus.codecs.time.Date;

// ── codecs: the application chooses Zig types for named haus types ──
//
// Each one takes the value the schema decoded, so the schema's rules always
// run, and encodes back to it, so the haus text never changes.

/// Integer cents, as payment APIs want them.
const Amount = struct {
    cents: i128,
    /// An ISO 4217 code: three letters A–Z.
    currency: [3]u8,
};

/// `Money(44.40, EUR)` ↔ `.{ .cents = 4440, .currency = "EUR" }`. More than
/// 2 decimal places, or a currency that isn't ISO-shaped (the iso profile,
/// `haus.codecs.money`), is an error.
const cents = haus.Codec(Amount).init(haus.codecs.money.money_id, struct {
    fn dec(_: Allocator, d: Decoded, reason: *Reason) CodecError!Amount {
        try haus.codecs.money.acceptsMoney(d, reason);
        const amount = d.variant.args[0].decimal;
        return .{
            .cents = centsOf(amount) orelse return reason.reject("{s} has more than 2 decimal places", .{amount}),
            .currency = d.variant.args[1].unknown.tag[0..3].*,
        };
    }
}.dec, struct {
    fn enc(arena: Allocator, a: Amount, _: *Reason) CodecError!Decoded {
        const sign = if (a.cents < 0) "-" else "";
        const abs = @abs(a.cents);
        const amount = try std.fmt.allocPrint(arena, "{s}{d}.{d:0>2}", .{ sign, abs / 100, abs % 100 });
        const args = try arena.dupe(Decoded, &.{ .{ .decimal = amount }, .{ .unknown = .{ .tag = try arena.dupe(u8, &a.currency) } } });
        return .{ .variant = .{ .tag = "Money", .args = args } };
    }
}.enc);

/// A normalized decimal literal (`44.40`, `-3`, `1.5e3`) times 100, if that
/// is a whole number that fits.
fn centsOf(literal: []const u8) ?i128 {
    var s = literal;
    const negative = s[0] == '-';
    if (negative) s = s[1..];
    const e_at = std.mem.indexOfScalar(u8, s, 'e') orelse s.len;
    const exp: i64 = if (e_at < s.len) std.fmt.parseInt(i64, s[e_at + 1 ..], 10) catch return null else 0;
    var mantissa: i128 = 0;
    var scale: i64 = 0;
    var after_point = false;
    for (s[0..e_at]) |c| {
        if (c == '.') {
            after_point = true;
            continue;
        }
        mantissa = std.math.mul(i128, mantissa, 10) catch return null;
        mantissa += c - '0';
        if (after_point) scale += 1;
    }
    // value = mantissa · 10^(exp − scale); cents = value · 100.
    var shift = exp - scale + 2;
    while (shift > 0) : (shift -= 1) mantissa = std.math.mul(i128, mantissa, 10) catch return null;
    while (shift < 0) : (shift += 1) {
        if (@rem(mantissa, 10) != 0) return null;
        mantissa = @divTrunc(mantissa, 10);
    }
    return if (negative) -mantissa else mantissa;
}

/// GeoJSON order: `LatLng(38.7223, -9.1393)` ↔ `.{ -9.1393, 38.7223 }`.
/// The swap happens here, once, on top of the wgs84 profile.
const geo_json = haus.Codec([2]f64).init(haus.codecs.geo.lat_lng_id, struct {
    fn dec(_: Allocator, d: Decoded, reason: *Reason) CodecError![2]f64 {
        try haus.codecs.geo.acceptsLatLng(d, reason);
        const p = haus.codecs.geo.point(d).?;
        return .{ p.lng, p.lat };
    }
}.dec, struct {
    fn enc(arena: Allocator, lng_lat: [2]f64, _: *Reason) CodecError!Decoded {
        const args = try arena.dupe(Decoded, &.{ .{ .float64 = lng_lat[1] }, .{ .float64 = lng_lat[0] } });
        return .{ .variant = .{ .tag = "LatLng", .args = args } };
    }
}.enc);

/// std/time types take codecs too: this binding ships one for `Date`.
const date = haus.codecs.time.date;

// ── the app's types ──

const Status = union(enum) {
    pending,
    shipped: struct { tracking: []const u8 },
    cancelled,
};

/// The app's type for the schema's Root, with the codecs' types.
const Order = struct {
    id: i64,
    customer: []const u8,
    placed: Date,
    total: Amount,
    deliver_to: [2]f64, // [lng, lat]
    status: Status,
};

/// Decodes with the schema and the codecs, which check their rules (errors
/// have the place of the value), and then takes the codecs' host values.
fn decodeOrder(arena: Allocator, def: *const haus.schema.Def, text: []const u8, codecs: *const haus.Codecs, d: *haus.Diagnostic) !Order {
    const r = try haus.decoding.decodeText(arena, arena, def, text, .{ .codecs = codecs, .diagnostic = d });
    const s = r.get("status").?.variant;
    return .{
        .id = try std.fmt.parseInt(i64, r.get("id").?.int, 10),
        .customer = r.get("customer").?.variant.args[0].string,
        .placed = date.get(r.get("placed").?).?,
        .total = cents.get(r.get("total").?).?,
        .deliver_to = geo_json.get(r.get("deliverTo").?).?,
        .status = if (std.mem.eql(u8, s.tag, "Pending"))
            .pending
        else if (std.mem.eql(u8, s.tag, "Cancelled"))
            .cancelled
        else
            .{ .shipped = .{ .tracking = s.args[0].get("tracking").?.string } },
    };
}

/// Encodes an Order with the same codecs.
fn encodeOrder(arena: Allocator, def: *const haus.schema.Def, o: Order, codecs: *const haus.Codecs) !haus.Value {
    const status: Decoded = switch (o.status) {
        .pending => .{ .variant = .{ .tag = "Pending" } },
        .cancelled => .{ .variant = .{ .tag = "Cancelled" } },
        .shipped => |s| .{ .variant = .{ .tag = "Shipped", .args = try arena.dupe(Decoded, &.{.{ .record = try arena.dupe(Decoded.Entry, &.{.{ .key = "tracking", .value = .{ .string = s.tracking } }}) }}) } },
    };
    const fields = try arena.dupe(Decoded.Entry, &.{
        .{ .key = "id", .value = .{ .int = try std.fmt.allocPrint(arena, "{d}", .{o.id}) } },
        .{ .key = "customer", .value = .{ .variant = .{ .tag = "UserId", .args = try arena.dupe(Decoded, &.{.{ .string = o.customer }}) } } },
        .{ .key = "placed", .value = try date.wrap(arena, o.placed) },
        .{ .key = "total", .value = try cents.wrap(arena, o.total) },
        .{ .key = "deliverTo", .value = try geo_json.wrap(arena, o.deliver_to) },
        .{ .key = "status", .value = status },
    });
    return haus.decoding.encode(arena, def, .{ .record = fields }, .{ .codecs = codecs });
}

fn float(buf: []u8, x: f64) []const u8 {
    return haus.decoding.formatFloat(f64, x, buf);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [1024]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;

    // The packages the schema imports, @haus-fmt/money and @haus-fmt/geo,
    // given by the folder of their directories (a Zig package that embeds
    // a schema package gives it as a `packages.Tree` instead).
    const build = try haus.packages.build(gpa, io, try std.fs.path.join(arena, &.{ paths.examples_dir, "order.schema.haus" }), .{
        .folders = &.{paths.extensions_dir},
    });
    defer build.deinit();
    const root = build.root.get("Root").?;
    const order = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ paths.examples_dir, "order.haus" }), arena, .unlimited);

    var codecs = try haus.Codecs.init(gpa, &.{ cents.erased(), geo_json.erased(), date.erased() });
    defer codecs.deinit(gpa);

    // Without codecs: Money is Money(Decimal, Currency), the Decimal as its exact text.
    const plain = try haus.decoding.decodeText(gpa, arena, root, order, .{});
    const total = plain.get("total").?.variant;
    try out.print("plain:  {s} pays {s} {s}\n", .{ plain.get("customer").?.variant.args[0].string, total.args[0].decimal, total.args[1].unknown.tag });

    // With codecs: the fields have the codecs' types.
    var d: haus.Diagnostic = .{};
    const typed = try decodeOrder(arena, root, order, &codecs, &d);
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    try out.print("typed:  {s} pays {d} cents, deliver to [lng, lat] [{s}, {s}]\n", .{ typed.customer, typed.total.cents, float(&b1, typed.deliver_to[0]), float(&b2, typed.deliver_to[1]) });
    try out.print("placed: {d:0>4}-{d:0>2}-{d:0>2}, a {s}\n", .{ typed.placed.year, @backingInt(typed.placed.month), typed.placed.day, typed.placed.weekday().name() });

    // Variants are a tagged union: switch on it.
    switch (typed.status) {
        .shipped => |s| try out.print("status: shipped, tracking {s}\n", .{s.tracking}),
        .pending, .cancelled => try out.print("status: not on its way\n", .{}),
    }

    // Encoding with the same codecs gives back the same haus text.
    const encoded = try encodeOrder(arena, root, typed, &codecs);
    try out.print("{s}\n", .{try haus.stringify(arena, encoded, .{ .layout = .compact })});

    // Codecs add rules on top of the schema's: Eur is a valid tag, but not ISO-shaped.
    const eur = try std.mem.replaceOwned(u8, arena, order, "EUR", "Eur");
    if (haus.decoding.decodeText(gpa, arena, root, eur, .{})) |_| {
        try out.print("Eur without codecs: accepted\n", .{});
    } else |_| {}
    if (decodeOrder(arena, root, eur, &codecs, &d)) |_| {} else |_| {
        try out.print("Eur with codecs: {s}: {s} [{s}]\n", .{ d.path(), d.message(), d.code.name() });
    }
    const precise = try std.mem.replaceOwned(u8, arena, order, "44.40", "44.405");
    if (decodeOrder(arena, root, precise, &codecs, &d)) |_| {} else |_| {
        try out.print("44.405 with codecs: {s}: {s} [{s}]\n", .{ d.path(), d.message(), d.code.name() });
    }
    try out.flush();
}
