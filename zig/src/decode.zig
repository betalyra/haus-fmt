//! Decoding with a schema (spec §15): which values each type accepts, the
//! decoded result, the error codes and the places (`$.items[2].price`), and
//! encoding a decoded result back to a value.

const std = @import("std");
const Allocator = std.mem.Allocator;
const v = @import("value.zig");
const Value = v.Value;
const errors = @import("errors.zig");
const Code = errors.Code;
const Diagnostic = errors.Diagnostic;
const Error = errors.Error;
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const Expr = schema_mod.Expr;
const Env = schema_mod.Env;
const Def = schema_mod.Def;
const RecordType = schema_mod.RecordType;
const VariantType = schema_mod.VariantType;
const time = @import("time.zig");
const canonical = @import("canonical.zig");
const number = @import("number.zig");
const StreamReader = @import("stream.zig").StreamReader;

/// A decoded value: what a type accepts, as this binding keeps it. Every
/// result encodes back to a value the type accepts (`encode`); the only
/// differences to the decoded value are those spec §15 allows (fields an
/// open record ignores, the spelling of a float, `-0` as an integer).
pub const Decoded = union(enum) {
    /// `Int`, `Int8` … `UInt64`: the decimal integer, `-0` as `0`.
    int: []const u8,
    float64: f64,
    float32: f32,
    /// `Decimal`: the normalized literal, scale and exponent kept.
    decimal: []const u8,
    string: []const u8,
    bytes: []const u8,
    array: []const Decoded,
    /// `Map v`: the entries, in the order they were written.
    map: []const Entry,
    /// A record type: the fields it lists that are present. A missing
    /// optional field is missing here too (spec §1).
    record: []const Entry,
    /// A tag the variant lists, with its decoded arguments (a record case
    /// has one argument, the record).
    variant: Tagged,
    /// A tag an open variant doesn't list: the tag and its arguments as
    /// parsed, untrusted (spec §15, "Unknown values").
    unknown: v.Variant,
    /// `Any`: the value as parsed.
    any: Value,
    /// `Secret a`: hidden when printed (`<redacted>`); `reveal` gives it out.
    secret: *const Decoded,
    /// A std/time value: its type and the checked text, as written.
    time: Time,
    /// A value of the host type a codec chose for its type (spec §13.4):
    /// `Codec(T).get` gives it out, `Codec(T).wrap` makes one to encode.
    host: Host,

    pub const Entry = struct { key: []const u8, value: Decoded };
    pub const Tagged = struct { tag: []const u8, args: []const Decoded = &.{} };
    pub const Time = struct { kind: time.Kind, text: []const u8 };
    pub const Host = struct { codec: *const AnyCodec, ptr: *const anyopaque };

    /// The field `key` of a record or map, if it is present.
    pub fn get(d: Decoded, key: []const u8) ?Decoded {
        const entries = switch (d) {
            .record, .map => |e| e,
            else => return null,
        };
        for (entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    /// The value a `Secret` hides, given out only by this explicit call.
    pub fn reveal(d: Decoded) Decoded {
        return switch (d) {
            .secret => |s| s.*,
            else => d,
        };
    }

    /// Prints the decoded value for people, a `Secret` as `<redacted>`
    /// (spec §15, "Secrets").
    pub fn format(d: Decoded, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (d) {
            .secret => try w.writeAll("<redacted>"),
            .int, .decimal => |s| try w.writeAll(s),
            .float64 => |f| try w.print("{d}", .{f}),
            .float32 => |f| try w.print("{d}", .{f}),
            .string => |s| try w.print("\"{f}\"", .{std.zig.fmtString(s)}),
            .bytes => |b| try w.print("x\"{x}\"", .{b}),
            .array => |items| {
                try w.writeByte('[');
                for (items, 0..) |x, i| {
                    if (i > 0) try w.writeAll(", ");
                    try x.format(w);
                }
                try w.writeByte(']');
            },
            .map, .record => |entries| {
                try w.writeByte('{');
                for (entries, 0..) |e, i| {
                    try w.writeAll(if (i > 0) ", " else " ");
                    try w.print("\"{f}\": ", .{std.zig.fmtString(e.key)});
                    try e.value.format(w);
                }
                try w.writeAll(if (entries.len > 0) " }" else "}");
            },
            .variant => |t| {
                try w.writeAll(t.tag);
                if (t.args.len > 0) {
                    try w.writeByte('(');
                    for (t.args, 0..) |x, i| {
                        if (i > 0) try w.writeAll(", ");
                        try x.format(w);
                    }
                    try w.writeByte(')');
                }
            },
            .unknown => |u| try w.print("<unknown {s}>", .{u.tag}),
            .any => try w.writeAll("<any>"),
            .time => |t| try w.print("{s}(\"{s}\")", .{ t.kind.typeName(), t.text }),
            .host => |h| try w.print("<{s}>", .{h.codec.id}),
        }
    }
};

// ── codecs (spec §13.4) ──────────────────────────────────────

/// Why a codec rejected a value: a message for people, kept in the struct.
pub const Reason = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn message(r: *const Reason) []const u8 {
        return r.buf[0..r.len];
    }

    /// Sets the message and returns `error.Rejected`, for
    /// `return reason.reject("{s} is not …", .{x});`.
    pub fn reject(r: *Reason, comptime fmt: []const u8, args: anytype) error{Rejected} {
        const out = std.fmt.bufPrint(&r.buf, fmt, args) catch blk: {
            const cut = "…";
            var w = std.Io.Writer.fixed(r.buf[0 .. r.buf.len - cut.len]);
            w.print(fmt, args) catch {};
            var n = w.end;
            while (n > 0 and (r.buf[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(r.buf[n .. n + cut.len], cut);
            break :blk r.buf[0 .. n + cut.len];
        };
        r.len = out.len;
        return error.Rejected;
    }
};

/// What a codec's functions return: a value, or a rejection (with its
/// `Reason`), or no memory.
pub const CodecError = error{ Rejected, OutOfMemory };

/// A codec with its host type erased, as `Codecs` keeps it (spec §13.4).
/// Make one with `Codec(T).init` (a host type of its own) or `rule` (the
/// default host type, with a rule added).
pub const AnyCodec = struct {
    /// The id of the type it is for (`@haus-fmt/money@1#Money`,
    /// `std/time#Date`): a named type without arguments (§13.3, "Identity").
    id: []const u8,
    /// `@typeName` of the host type (`Decoded` for a rule).
    host_type: []const u8,
    /// Takes what the schema decoded (inner codecs already applied) and
    /// gives the host value (a `.host`), or the value itself for a rule.
    decode: *const fn (arena: Allocator, d: Decoded, reason: *Reason) CodecError!Decoded,
    /// The other way: from what `decode` gave (or a value of the type's
    /// default host type) to the value the schema encodes.
    encode: *const fn (arena: Allocator, d: Decoded, reason: *Reason) CodecError!Decoded,
};

/// A codec whose host type is `T` (spec §13.4): `decode` maps what the
/// schema decoded to a `T`, or rejects it; `encode` maps a `T` back to the
/// type's decoded value, so that decoding it again gives the same `T`.
/// It never changes what a value means. A codec for a type that holds
/// other codecs' types receives their host values (inner codecs run first).
///
///     const date = haus.decoding.Codec(Date).init("std/time#Date", decodeDate, encodeDate);
///     var codecs = try haus.decoding.Codecs.init(gpa, &.{date.erased()});
pub fn Codec(comptime T: type) type {
    return struct {
        any: AnyCodec,

        const Self = @This();
        pub const Host = T;

        pub fn init(
            id: []const u8,
            comptime decodeFn: fn (arena: Allocator, d: Decoded, reason: *Reason) CodecError!T,
            comptime encodeFn: fn (arena: Allocator, x: T, reason: *Reason) CodecError!Decoded,
        ) Self {
            const W = struct {
                fn dec(arena: Allocator, d: Decoded, reason: *Reason) CodecError!Decoded {
                    const p = try arena.create(T);
                    p.* = try decodeFn(arena, d, reason);
                    return .{ .host = .{ .codec = undefined, .ptr = p } };
                }
                fn enc(arena: Allocator, d: Decoded, reason: *Reason) CodecError!Decoded {
                    return switch (d) {
                        .host => |h| encodeFn(arena, @as(*const T, @ptrCast(@alignCast(h.ptr))).*, reason),
                        // A value of the default host type: the rule only.
                        else => blk: {
                            _ = try decodeFn(arena, d, reason);
                            break :blk d;
                        },
                    };
                }
            };
            return .{ .any = .{ .id = id, .host_type = @typeName(T), .decode = W.dec, .encode = W.enc } };
        }

        /// The codec as `Codecs` takes it. `self` must outlive the decoded
        /// values (a global constant, typically).
        pub fn erased(self: *const Self) *const AnyCodec {
            return &self.any;
        }

        /// The host value in `d`, if it is one of this codec's.
        pub fn get(self: *const Self, d: Decoded) ?T {
            if (d != .host) return null;
            const c = d.host.codec;
            if (!std.mem.eql(u8, c.id, self.any.id) or !std.mem.eql(u8, c.host_type, self.any.host_type)) return null;
            return @as(*const T, @ptrCast(@alignCast(d.host.ptr))).*;
        }

        /// A host value to encode, where the schema has this codec's type.
        pub fn wrap(self: *const Self, arena: Allocator, x: T) Allocator.Error!Decoded {
            const p = try arena.create(T);
            p.* = x;
            return .{ .host = .{ .codec = &self.any, .ptr = p } };
        }
    };
}

/// A codec that keeps the type's default host type and adds a rule (a
/// profile, spec §13.3): `check` rejects what the rule doesn't accept,
/// when decoding and when encoding.
pub fn rule(id: []const u8, comptime accepts: fn (d: Decoded, reason: *Reason) error{Rejected}!void) AnyCodec {
    const W = struct {
        fn run(_: Allocator, d: Decoded, reason: *Reason) CodecError!Decoded {
            try accepts(d, reason);
            return d;
        }
    };
    return .{ .id = id, .host_type = @typeName(Decoded), .decode = W.run, .encode = W.run };
}

/// The codecs of an application, by type id (spec §13.4): one per id.
pub const Codecs = struct {
    map: std.StringHashMapUnmanaged(*const AnyCodec) = .empty,

    pub const InitError = error{ OutOfMemory, DuplicateCodec };

    /// Two codecs for one id are `error.DuplicateCodec`.
    pub fn init(gpa: Allocator, list: []const *const AnyCodec) InitError!Codecs {
        var c: Codecs = .{};
        errdefer c.map.deinit(gpa);
        for (list) |x| {
            const gop = try c.map.getOrPut(gpa, x.id);
            if (gop.found_existing) return error.DuplicateCodec;
            gop.value_ptr.* = x;
        }
        return c;
    }

    pub fn deinit(c: *Codecs, gpa: Allocator) void {
        c.map.deinit(gpa);
    }

    pub fn get(c: *const Codecs, id: []const u8) ?*const AnyCodec {
        return c.map.get(id);
    }
};

/// What a checker points out (spec §14): a hint, or the error that ends
/// the check, at its place.
pub const Issue = struct {
    kind: enum { hint, err },
    code: Code,
    path: []const u8,
    /// For the error: its message, and its line and column when it is an
    /// error in the text (0 otherwise). Hints have none.
    message: []const u8 = "",
    line: u32 = 0,
    column: u32 = 0,
};

// ── places ───────────────────────────────────────────────────

/// A place in the decoded value (spec §15): one step per level.
pub const Path = struct {
    parent: ?*const Path,
    step: Step,

    pub const Step = union(enum) {
        root,
        key: []const u8,
        index: usize,
    };

    pub const root: Path = .{ .parent = null, .step = .root };

    pub fn key(p: *const Path, k: []const u8) Path {
        return .{ .parent = p, .step = .{ .key = k } };
    }

    pub fn index(p: *const Path, i: usize) Path {
        return .{ .parent = p, .step = .{ .index = i } };
    }

    /// `$.items[2].price`, `$.m["pt-BR"]` (a key as a canonical string
    /// unless it is an identifier).
    pub fn write(p: *const Path, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
        if (p.parent) |q| try q.write(gpa, out);
        switch (p.step) {
            .root => try out.append(gpa, '$'),
            .index => |i| try out.print(gpa, "[{d}]", .{i}),
            .key => |k| {
                if (v.isBareKey(k)) {
                    try out.append(gpa, '.');
                    try out.appendSlice(gpa, k);
                } else {
                    try out.append(gpa, '[');
                    try canonical.appendQuoted(gpa, out, k);
                    try out.append(gpa, ']');
                }
            },
        }
    }

    pub fn toOwned(p: *const Path, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try p.write(gpa, &out);
        return out.toOwnedSlice(gpa);
    }
};

// ── decoding ─────────────────────────────────────────────────

pub const DecodeOptions = struct {
    diagnostic: ?*Diagnostic = null,
    /// When given, the hints a checker reports (spec §14: `unlisted-field`,
    /// `unlisted-tag`, `deprecated`) are added to it.
    hints: ?*std.ArrayList(Issue) = null,
    /// The path the decoded value is at (for the items of a stream).
    base: ?*const Path = null,
    /// The depth limit (spec §7, §9 item 8): a value nested deeper, such
    /// as one built in code, is `nesting-too-deep` at its path before it
    /// is decoded, since the decoder recurses once per level.
    limits: v.Limits = .{},
    /// The application's codecs (spec §13.4): each runs, after the schema,
    /// wherever its type occurs.
    codecs: ?*const Codecs = null,
};

/// Whether `val` is nested deeper than `max` levels, as values built in
/// code count them (spec §7: a record payload is one level). It looks at
/// most `max + 1` levels down, so its own recursion is bounded.
fn deeperThan(val: Value, max: u32) bool {
    if (max == 0) return switch (val) {
        .array, .record => true,
        .variant => |x| x.args.len > 0,
        else => false,
    };
    return switch (val) {
        .array => |items| for (items) |x| {
            if (deeperThan(x, max - 1)) break true;
        } else false,
        .record => |fields| for (fields) |f| {
            if (deeperThan(f.value, max - 1)) break true;
        } else false,
        .variant => |x| blk: {
            if (x.args.len == 1 and x.args[0] == .record) {
                for (x.args[0].record) |f| if (deeperThan(f.value, max - 1)) break :blk true;
                break :blk false;
            }
            for (x.args) |a| if (deeperThan(a, max - 1)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn checkDepth(c: *Ctx, val: Value, limits: v.Limits, path: *const Path) Error!void {
    if (limits.max_depth > v.Limits.supported_depth) {
        return c.fail(.@"unsupported-depth", path, "a depth limit of {d} is above the {d} levels this binding supports", .{ limits.max_depth, v.Limits.supported_depth });
    }
    if (deeperThan(val, limits.max_depth)) {
        return c.fail(.@"nesting-too-deep", path, "the value is nested deeper than {d} levels", .{limits.max_depth});
    }
}

const Ctx = struct {
    /// Allocates the decoded result (an arena is the usual choice).
    arena: Allocator,
    diag: ?*Diagnostic,
    hints: ?*std.ArrayList(Issue),
    /// Inside a `Secret`: no hints, and errors are rewritten at the secret.
    secret_depth: u32 = 0,
    codecs: ?*const Codecs = null,

    /// A named type without arguments, decoded and then given to its
    /// codec, if the application has one (spec §13.4).
    noinline fn named(c: *Ctx, ref: schema_mod.Ref, val: Value, path: *const Path) Error!Decoded {
        // Nothing inlined here: this is a step of the recursion.
        const id, const d = switch (ref) {
            .builtin => |b| .{ schema_mod.builtinId(b), try @call(.never_inline, Ctx.builtin, .{ c, b, &.{}, null, val, path }) },
            .time => |k| .{ schema_mod.timeId(k), try @call(.never_inline, Ctx.timeValue, .{ c, k, val, path }) },
            .def => |def| .{ def.id, try @call(.never_inline, Ctx.decode, .{ c, def.body, null, val, path }) },
            .unresolved => unreachable,
        };
        const cs = c.codecs orelse return d;
        const codec = cs.get(id) orelse return d;
        return c.applyCodec(codec, d, path);
    }

    /// Runs the codec for the type `id`, if the application has one, on
    /// what the schema decoded (spec §13.4): a rejection is
    /// `codec-rejected` at the type's place.
    fn withCodec(c: *Ctx, id: []const u8, d: Decoded, path: *const Path) Error!Decoded {
        const cs = c.codecs orelse return d;
        const codec = cs.get(id) orelse return d;
        return c.applyCodec(codec, d, path);
    }

    noinline fn applyCodec(c: *Ctx, codec: *const AnyCodec, d: Decoded, path: *const Path) Error!Decoded {
        var reason: Reason = .{};
        var out = codec.decode(c.arena, d, &reason) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Rejected => return c.fail(.@"codec-rejected", path, "{s} rejects the value: {s}", .{ codec.id, reason.message() }),
        };
        if (out == .host) out.host.codec = codec;
        return out;
    }

    /// Never inlined: its buffer would grow the frames of the recursive
    /// decoder (spec §7, the stack needed at the supported depth).
    noinline fn fail(c: *Ctx, code: Code, path: *const Path, comptime fmt: []const u8, args: anytype) Error {
        if (c.diag) |d| {
            d.set(code, fmt, args);
            d.line = 0;
            d.column = 0;
            d.offset = 0;
            var buf: [Diagnostic.path_capacity]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const a = fba.allocator();
            var out: std.ArrayList(u8) = .empty;
            path.write(a, &out) catch {};
            d.setPath(out.items);
        }
        return error.Haus;
    }

    fn hint(c: *Ctx, code: Code, path: *const Path) Error!void {
        if (c.secret_depth > 0) return;
        const list = c.hints orelse return;
        try list.append(c.arena, .{ .kind = .hint, .code = code, .path = try path.toOwned(c.arena) });
    }

    fn kindName(val: Value) []const u8 {
        return switch (val) {
            .number => "a number",
            .string => "a string",
            .bytes => "bytes",
            .array => "an array",
            .record => "a record",
            .variant => "a variant",
        };
    }

    fn mismatch(c: *Ctx, path: *const Path, comptime expected: []const u8, val: Value) Error {
        return c.fail(.@"type-mismatch", path, "expected " ++ expected ++ ", found {s}", .{kindName(val)});
    }

    fn decode(c: *Ctx, e: *const Expr, env: ?*const Env, val: Value, path: *const Path) Error!Decoded {
        switch (e.kind) {
            .paren => |inner| return c.decode(inner, env, val, path),
            .param => |p| {
                const en = env.?;
                return c.decode(en.args[p.index], en.parent, val, path);
            },
            .record => |rec| return c.record(rec, env, val, path),
            .variant => |vt| return c.variant(vt, env, val, path),
            .name => |n| {
                // With codecs, a step of its own (it keeps the frame of
                // this recursive function as small as without, spec §7).
                if (c.codecs != null and n.args.len == 0) return c.named(n.ref, val, path);
                switch (n.ref) {
                    .builtin => |b| return c.builtin(b, n.args, env, val, path),
                    .time => |k| return c.timeValue(k, val, path),
                    .def => |d| {
                        const inner_env: ?*const Env = if (n.args.len > 0) blk: {
                            const en = try c.arena.create(Env);
                            en.* = .{ .args = n.args, .parent = env };
                            break :blk en;
                        } else null;
                        return c.decode(d.body, inner_env, val, path);
                    },
                    .unresolved => unreachable,
                }
            },
        }
    }

    /// The codecs of the named types a record case's payload is written
    /// with (`Shipped Address`, `type Address = Base`), applied from the
    /// inside out: the payload is a decoded value of its own here, so a
    /// codec reaches it (never `codec-unreachable`, spec §13.4).
    noinline fn payloadCodecs(c: *Ctx, e0: *const Expr, env0: ?*const Env, slot: *Decoded, path: *const Path) Error!void {
        var ids: std.ArrayList([]const u8) = .empty;
        var e = e0;
        var env = env0;
        while (true) switch (e.kind) {
            .paren => |inner| e = inner,
            .param => |p| {
                const en = env.?;
                e = en.args[p.index];
                env = en.parent;
            },
            .name => |n| {
                const d = n.ref.def;
                if (n.args.len > 0) {
                    const en = try c.arena.create(Env);
                    en.* = .{ .args = n.args, .parent = env };
                    env = en;
                } else {
                    try ids.append(c.arena, d.id);
                    env = null;
                }
                e = d.body;
            },
            else => break,
        };
        var i = ids.items.len;
        while (i > 0) {
            i -= 1;
            slot.* = try c.withCodec(ids.items[i], slot.*, path);
        }
    }

    fn builtin(c: *Ctx, b: schema_mod.Builtin, args: []const *Expr, env: ?*const Env, val: Value, path: *const Path) Error!Decoded {
        switch (b) {
            .String => return if (val == .string) .{ .string = val.string } else c.mismatch(path, "a string", val),
            .Bytes => return if (val == .bytes) .{ .bytes = val.bytes } else c.mismatch(path, "bytes", val),
            .Any => return .{ .any = val },
            .Int, .Int8, .Int16, .Int32, .Int64, .UInt8, .UInt16, .UInt32, .UInt64 => return c.integer(b, val, path),
            .Float64 => return c.float(f64, val, path),
            .Float32 => return c.float(f32, val, path),
            .Decimal => return if (val == .number) .{ .decimal = val.number } else c.mismatch(path, "a number", val),
            .Array => {
                if (val != .array) return c.mismatch(path, "an array", val);
                const out = try c.arena.alloc(Decoded, val.array.len);
                for (val.array, 0..) |item, i| {
                    const p = path.index(i);
                    out[i] = try c.decode(args[0], env, item, &p);
                }
                return .{ .array = out };
            },
            .Map => {
                if (val != .record) return c.mismatch(path, "a record (a Map)", val);
                const out = try c.arena.alloc(Decoded.Entry, val.record.len);
                for (val.record, 0..) |f, i| {
                    const p = path.key(f.key);
                    out[i] = .{ .key = f.key, .value = try c.decode(args[0], env, f.value, &p) };
                }
                return .{ .map = out };
            },
            .Secret => {
                c.secret_depth += 1;
                defer c.secret_depth -= 1;
                const inner = c.decode(args[0], env, val, path) catch |err| switch (err) {
                    error.Haus => return c.fail(.@"invalid-secret", path, "the value of this Secret is not valid for its type (the value is not shown)", .{}),
                    else => return err,
                };
                const box = try c.arena.create(Decoded);
                box.* = inner;
                return .{ .secret = box };
            },
            .Stream => return c.fail(.@"type-mismatch", path, "a Stream describes a whole file, not one value", .{}),
        }
    }

    fn integer(c: *Ctx, b: schema_mod.Builtin, val: Value, path: *const Path) Error!Decoded {
        if (val != .number) return c.mismatch(path, "an integer", val);
        const lit = val.number;
        if (std.mem.indexOfAny(u8, lit, ".eE") != null) {
            var buf: [64]u8 = undefined;
            return c.fail(.@"not-an-integer", path, "expected an integer, found {s} (not a whole number by its spelling)", .{errors.quoteText(&buf, lit)});
        }
        const text = if (std.mem.eql(u8, lit, "-0")) "0" else lit;
        const range: ?struct { min: i128, max: i128 } = switch (b) {
            .Int => null,
            .Int8 => .{ .min = -(1 << 7), .max = (1 << 7) - 1 },
            .Int16 => .{ .min = -(1 << 15), .max = (1 << 15) - 1 },
            .Int32 => .{ .min = -(1 << 31), .max = (1 << 31) - 1 },
            .Int64 => .{ .min = -(1 << 63), .max = (1 << 63) - 1 },
            .UInt8 => .{ .min = 0, .max = (1 << 8) - 1 },
            .UInt16 => .{ .min = 0, .max = (1 << 16) - 1 },
            .UInt32 => .{ .min = 0, .max = (1 << 32) - 1 },
            .UInt64 => .{ .min = 0, .max = (1 << 64) - 1 },
            else => unreachable,
        };
        if (range) |r| {
            const digits = if (text[0] == '-') text.len - 1 else text.len;
            const n: ?i128 = if (digits > 30) null else std.fmt.parseInt(i128, text, 10) catch null;
            if (n == null or n.? < r.min or n.? > r.max) {
                var buf: [64]u8 = undefined;
                return c.fail(.@"out-of-range", path, "{s} is outside the range of {s} ({d} to {d})", .{ errors.quoteText(&buf, text), @tagName(b), r.min, r.max });
            }
        }
        return .{ .int = text };
    }

    fn float(c: *Ctx, comptime F: type, val: Value, path: *const Path) Error!Decoded {
        switch (val) {
            .number => |lit| {
                const x = std.fmt.parseFloat(F, lit) catch return c.fail(.@"type-mismatch", path, "not a number", .{});
                if (std.math.isInf(x)) {
                    var buf: [64]u8 = undefined;
                    return c.fail(.@"out-of-range", path, "{s} is too large for {s}", .{ errors.quoteText(&buf, lit), if (F == f64) "Float64" else "Float32" });
                }
                return if (F == f64) .{ .float64 = x } else .{ .float32 = x };
            },
            .variant => |x| {
                if (x.args.len == 0) {
                    const special: ?F = if (std.mem.eql(u8, x.tag, "NaN")) std.math.nan(F) else if (std.mem.eql(u8, x.tag, "Infinity")) std.math.inf(F) else if (std.mem.eql(u8, x.tag, "NegInfinity")) -std.math.inf(F) else null;
                    if (special) |s| return if (F == f64) .{ .float64 = s } else .{ .float32 = s };
                }
                return c.mismatch(path, "a number, NaN, Infinity or NegInfinity", val);
            },
            else => return c.mismatch(path, "a number", val),
        }
    }

    fn timeValue(c: *Ctx, k: time.Kind, val: Value, path: *const Path) Error!Decoded {
        const name = k.typeName();
        if (val != .variant or !std.mem.eql(u8, val.variant.tag, name) or val.variant.args.len != 1 or val.variant.args[0] != .string) {
            return c.fail(.@"type-mismatch", path, "expected {s}(\"…\"), the tag {s} around one string", .{ name, name });
        }
        const text = val.variant.args[0].string;
        if (!time.check(k, text)) {
            const p = path.index(0);
            return c.fail(.@"invalid-time", &p, "not a valid {s} of the std/time profile", .{name});
        }
        return .{ .time = .{ .kind = k, .text = text } };
    }

    fn record(c: *Ctx, rec: *const RecordType, env: ?*const Env, val: Value, path: *const Path) Error!Decoded {
        if (val != .record) return c.mismatch(path, "a record", val);
        const data = val.record;
        // Which listed fields are present.
        const present = try c.arena.alloc(i32, rec.fields.len);
        @memset(present, -1);
        for (data, 0..) |f, i| {
            if (rec.index.get(f.key)) |k| present[k] = @intCast(i);
        }
        for (rec.fields, 0..) |f, k| {
            if (!f.optional and present[k] < 0) {
                var buf: [64]u8 = undefined;
                return c.fail(.@"missing-field", path, "missing field {s}", .{errors.quoteText(&buf, f.key)});
            }
        }
        var out: std.ArrayList(Decoded.Entry) = .empty;
        try out.ensureTotalCapacity(c.arena, rec.fields.len);
        for (data) |f| {
            const p = path.key(f.key);
            if (rec.index.get(f.key)) |k| {
                const field = rec.fields[k];
                if (field.deprecated != null) try c.hint(.deprecated, &p);
                const d = try c.decode(field.type, field.env orelse env, f.value, &p);
                out.appendAssumeCapacity(.{ .key = f.key, .value = d });
            } else if (rec.closed) {
                return c.fail(.@"unknown-field", &p, "not a field of this closed record", .{});
            } else {
                try c.hint(.@"unlisted-field", &p);
            }
        }
        return .{ .record = out.items };
    }

    fn variant(c: *Ctx, vt: *const VariantType, env: ?*const Env, val: Value, path: *const Path) Error!Decoded {
        if (val != .variant) return c.mismatch(path, "a variant", val);
        const x = val.variant;
        const k = vt.index.get(x.tag) orelse {
            if (vt.closed) {
                var buf: [64]u8 = undefined;
                return c.fail(.@"unknown-tag", path, "{s} is not a tag of this closed variant", .{errors.quoteText(&buf, x.tag)});
            }
            try c.hint(.@"unlisted-tag", path);
            return .{ .unknown = x };
        };
        const case = vt.cases[k];
        if (case.deprecated != null) try c.hint(.deprecated, path);
        const case_env = case.env orelse env;
        switch (case.form) {
            .none => {
                if (x.args.len != 0) return c.fail(.@"wrong-payload", path, "{s} takes no payload", .{case.tag});
                return .{ .variant = .{ .tag = x.tag } };
            },
            .record => {
                if (x.args.len != 1 or x.args[0] != .record) return c.fail(.@"wrong-payload", path, "{s} takes one record", .{case.tag});
                const target = unfoldRecord(c.arena, case.args[0], case_env) catch return error.OutOfMemory;
                const args = try c.arena.alloc(Decoded, 1);
                args[0] = try c.record(target.rec, target.env, x.args[0], path);
                if (c.codecs != null) try c.payloadCodecs(case.args[0], case_env, &args[0], path);
                return .{ .variant = .{ .tag = x.tag, .args = args } };
            },
            .positional => {
                if (x.args.len != case.args.len) return c.fail(.@"wrong-payload", path, "{s} takes {d} arguments", .{ case.tag, case.args.len });
                const args = try c.arena.alloc(Decoded, x.args.len);
                for (x.args, 0..) |a, i| {
                    const p = path.index(i);
                    args[i] = try c.decode(case.args[i], case_env, a, &p);
                }
                return .{ .variant = .{ .tag = x.tag, .args = args } };
            },
        }
    }
};

/// The record type a record case's argument is, with the arguments its
/// names were applied to.
pub fn unfoldRecord(arena: Allocator, e0: *const Expr, env0: ?*const Env) Allocator.Error!struct { rec: *const RecordType, env: ?*const Env } {
    var e = e0;
    var env = env0;
    while (true) {
        switch (e.kind) {
            .paren => |inner| e = inner,
            .record => |rec| return .{ .rec = rec, .env = env },
            .name => |n| {
                const d = n.ref.def;
                if (n.args.len > 0) {
                    const en = try arena.create(Env);
                    en.* = .{ .args = n.args, .parent = env };
                    env = en;
                } else env = null;
                e = d.body;
            },
            .param => |p| {
                const en = env.?;
                e = en.args[p.index];
                env = en.parent;
            },
            .variant => unreachable,
        }
    }
}

/// Decodes `val` with the definition `def` of its schema (spec §15).
/// `def` must have no parameters. The result is allocated with `arena`.
pub fn decode(arena: Allocator, def: *const Def, val: Value, options: DecodeOptions) Error!Decoded {
    var c: Ctx = .{ .arena = arena, .diag = options.diagnostic, .hints = options.hints, .codecs = options.codecs };
    const base = options.base orelse &Path.root;
    try checkDepth(&c, val, options.limits, base);
    const d = try c.decode(def.body, null, val, base);
    // The definition's own codec (§13.4), as where its name is used.
    return if (def.params.len == 0 and !def.stream) c.withCodec(def.id, d, base) else d;
}

/// Decodes `val` with a type expression read in `env` (for bindings that
/// build types of their own from a schema's).
pub fn decodeExpr(arena: Allocator, e: *const Expr, env: ?*const Env, val: Value, options: DecodeOptions) Error!Decoded {
    var c: Ctx = .{ .arena = arena, .diag = options.diagnostic, .hints = options.hints, .codecs = options.codecs };
    const base = options.base orelse &Path.root;
    try checkDepth(&c, val, options.limits, base);
    return c.decode(e, env, val, base);
}

// ── encoding ─────────────────────────────────────────────────

/// Writes a float in the one spelling of spec §15: the fewest digits that
/// read back to the same float of its type, laid out as JavaScript's
/// `Number.prototype.toString` without `+` in the exponent.
pub fn formatFloat(comptime F: type, x: F, buf: []u8) []const u8 {
    std.debug.assert(!std.math.isNan(x) and !std.math.isInf(x));
    var tmp: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&tmp, "{e}", .{x}) catch unreachable;
    var i: usize = 0;
    var w = std.Io.Writer.fixed(buf);
    if (sci[0] == '-') {
        w.writeByte('-') catch unreachable;
        i = 1;
    }
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    var digits_buf: [40]u8 = undefined;
    var k: usize = 0;
    for (sci[i..e_at]) |ch| {
        if (ch != '.') {
            digits_buf[k] = ch;
            k += 1;
        }
    }
    // Trailing zeros are not digits of the shortest form.
    while (k > 1 and digits_buf[k - 1] == '0') k -= 1;
    const digits = digits_buf[0..k];
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable;
    const n: i32 = exp + 1;
    const ki: i32 = @intCast(k);
    if (ki <= n and n <= 21) {
        w.writeAll(digits) catch unreachable;
        for (0..@intCast(n - ki)) |_| w.writeByte('0') catch unreachable;
    } else if (0 < n and n <= 21) {
        const nn: usize = @intCast(n);
        w.writeAll(digits[0..nn]) catch unreachable;
        w.writeByte('.') catch unreachable;
        w.writeAll(digits[nn..]) catch unreachable;
    } else if (-6 < n and n <= 0) {
        w.writeAll("0.") catch unreachable;
        for (0..@intCast(-n)) |_| w.writeByte('0') catch unreachable;
        w.writeAll(digits) catch unreachable;
    } else {
        w.writeByte(digits[0]) catch unreachable;
        if (k > 1) {
            w.writeByte('.') catch unreachable;
            w.writeAll(digits[1..]) catch unreachable;
        }
        w.print("e{d}", .{n - 1}) catch unreachable;
    }
    return w.buffered();
}

fn floatValue(arena: Allocator, comptime F: type, x: F) Allocator.Error!Value {
    if (std.math.isNan(x)) return Value.tag("NaN");
    if (std.math.isInf(x)) return Value.tag(if (x > 0) "Infinity" else "NegInfinity");
    var buf: [64]u8 = undefined;
    return .{ .number = try arena.dupe(u8, formatFloat(F, x, &buf)) };
}

/// The value a decoded result is written as (spec §15, "Encoding"). A
/// host value of a codec is encoded by its codec first; one it rejects is
/// `error.Haus` (`encode` says why and where).
pub fn toValue(arena: Allocator, d: Decoded) Error!Value {
    return valueAt(arena, d, null, &Path.root);
}

/// What a codec gives back for a host value (spec §13.4), its own inner
/// host values left in; a rejection is `cannot-encode` at `path`.
noinline fn encodeHost(arena: Allocator, h: Decoded.Host, diag: ?*Diagnostic, path: *const Path) Error!Decoded {
    var reason: Reason = .{};
    return h.codec.encode(arena, .{ .host = h }, &reason) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => {
            var c: Ctx = .{ .arena = arena, .diag = diag, .hints = null };
            return c.fail(.@"cannot-encode", path, "{s} can't encode the value: {s}", .{ h.codec.id, reason.message() });
        },
    };
}

fn valueAt(arena: Allocator, d: Decoded, diag: ?*Diagnostic, path: *const Path) Error!Value {
    return switch (d) {
        .int, .decimal => |s| .{ .number = s },
        .float64 => |x| floatValue(arena, f64, x),
        .float32 => |x| floatValue(arena, f32, x),
        .string => |s| .{ .string = s },
        .bytes => |b| .{ .bytes = b },
        .array => |items| blk: {
            const out = try arena.alloc(Value, items.len);
            for (items, 0..) |x, i| {
                const p = path.index(i);
                out[i] = try valueAt(arena, x, diag, &p);
            }
            break :blk .{ .array = out };
        },
        .map, .record => |entries| blk: {
            const out = try arena.alloc(v.Field, entries.len);
            for (entries, 0..) |e, i| {
                const p = path.key(e.key);
                out[i] = .{ .key = e.key, .value = try valueAt(arena, e.value, diag, &p) };
            }
            break :blk .{ .record = out };
        },
        .variant => |t| blk: {
            const out = try arena.alloc(Value, t.args.len);
            for (t.args, 0..) |x, i| {
                // A record payload is at the variant's place (§15).
                const p = path.index(i);
                out[i] = try valueAt(arena, x, diag, if (t.args.len == 1 and x == .record) path else &p);
            }
            break :blk .{ .variant = .{ .tag = t.tag, .args = out } };
        },
        .unknown => |u| .{ .variant = u },
        .any => |x| x,
        .secret => |s| valueAt(arena, s.*, diag, path),
        .time => |t| blk: {
            const args = try arena.alloc(Value, 1);
            args[0] = .{ .string = t.text };
            break :blk .{ .variant = .{ .tag = t.kind.typeName(), .args = args } };
        },
        .host => |h| valueAt(arena, try encodeHost(arena, h, diag, path), diag, path),
    };
}

/// `d` with every host value encoded by its codec (spec §13.4): what the
/// type's default host types would have decoded.
pub fn lower(arena: Allocator, d: Decoded, diag: ?*Diagnostic) Error!Decoded {
    return lowerAt(arena, d, diag, &Path.root);
}

fn lowerAt(arena: Allocator, d: Decoded, diag: ?*Diagnostic, path: *const Path) Error!Decoded {
    return switch (d) {
        .array => |items| blk: {
            const out = try arena.alloc(Decoded, items.len);
            for (items, 0..) |x, i| {
                const p = path.index(i);
                out[i] = try lowerAt(arena, x, diag, &p);
            }
            break :blk .{ .array = out };
        },
        .map, .record => |entries| blk: {
            const out = try arena.alloc(Decoded.Entry, entries.len);
            for (entries, 0..) |e, i| {
                const p = path.key(e.key);
                out[i] = .{ .key = e.key, .value = try lowerAt(arena, e.value, diag, &p) };
            }
            break :blk if (d == .map) .{ .map = out } else .{ .record = out };
        },
        .variant => |t| blk: {
            const out = try arena.alloc(Decoded, t.args.len);
            for (t.args, 0..) |x, i| {
                const p = path.index(i);
                out[i] = try lowerAt(arena, x, diag, if (t.args.len == 1 and x == .record) path else &p);
            }
            break :blk .{ .variant = .{ .tag = t.tag, .args = out } };
        },
        .secret => |s| blk: {
            const box = try arena.create(Decoded);
            box.* = try lowerAt(arena, s.*, diag, path);
            break :blk .{ .secret = box };
        },
        .host => |h| lowerAt(arena, try encodeHost(arena, h, diag, path), diag, path),
        else => d,
    };
}

pub const EncodeOptions = struct {
    diagnostic: ?*Diagnostic = null,
    limits: v.Limits = .{},
    /// The codecs to check the encoded value with (spec §13.4): pass the
    /// ones it was decoded with, so their rules run when encoding too.
    /// Host values are encoded by their own codec in any case.
    codecs: ?*const Codecs = null,
};

/// Encodes a decoded result with the definition `def` (spec §15): the
/// value it is written as, checked to be one the type accepts and within
/// the limits (§9 item 8). A result the type doesn't accept (one built in
/// code) is `cannot-encode` at its place; inside a `Secret`,
/// `invalid-secret`.
pub fn encode(arena: Allocator, def: *const Def, d: Decoded, options: EncodeOptions) Error!Value {
    const val = try valueAt(arena, d, options.diagnostic, &Path.root);
    // The limits of values built in code (§9 item 8): checked as written.
    var sink: std.ArrayList(u8) = .empty;
    try canonical.appendChecked(arena, &sink, val, .{ .limits = options.limits, .diagnostic = options.diagnostic }, null);
    var inner: Diagnostic = .{};
    _ = decode(arena, def, val, .{ .diagnostic = &inner, .limits = options.limits, .codecs = options.codecs }) catch |e| switch (e) {
        error.Haus => {
            if (options.diagnostic) |dg| {
                if (inner.code == .@"invalid-secret") {
                    dg.set(.@"invalid-secret", "the value of this Secret can't be written for its type (the value is not shown)", .{});
                } else {
                    dg.set(.@"cannot-encode", "the value can't be written with this type: {s}", .{inner.message()});
                }
                dg.setPath(inner.path());
            }
            return error.Haus;
        },
        else => return e,
    };
    return val;
}

/// Runs the codecs of `options` on a result decoded without them, such as
/// `json.fromJson`'s: the result `decode` would have given with them.
pub fn applyCodecs(arena: Allocator, def: *const Def, d: Decoded, options: DecodeOptions) Error!Decoded {
    return decode(arena, def, try valueAt(arena, d, options.diagnostic, &Path.root), options);
}

// ── texts and streams ────────────────────────────────────────

pub const TextOptions = struct {
    diagnostic: ?*Diagnostic = null,
    hints: ?*std.ArrayList(Issue) = null,
    limits: v.Limits = .{},
    codecs: ?*const Codecs = null,
};

/// The item type of a `Stream a` definition, or null for another type.
pub fn streamItem(def: *const Def) ?*const Expr {
    if (!def.stream) return null;
    return def.body.strip().kind.name.args[0];
}

/// Reads a stream with a `Stream a` type (spec §15, "Streams"): each
/// top-level value is decoded as an `a` as it arrives, and an error's place
/// starts with the item's index (`$[3].price`).
pub const TypedStreamReader = struct {
    reader: StreamReader,
    item: *const Expr,
    index: usize = 0,
    diag: ?*Diagnostic,
    hints: ?*std.ArrayList(Issue),
    limits: v.Limits,
    codecs: ?*const Codecs,

    /// `def` must be a `Stream a` (`streamItem(def) != null`).
    pub fn init(gpa: Allocator, def: *const Def, options: TextOptions) Error!TypedStreamReader {
        const item = streamItem(def) orelse unreachable;
        return .{
            .reader = try StreamReader.init(gpa, .{ .limits = options.limits, .diagnostic = options.diagnostic }),
            .item = item,
            .diag = options.diagnostic,
            .hints = options.hints,
            .limits = options.limits,
            .codecs = options.codecs,
        };
    }

    pub fn deinit(r: *TypedStreamReader) void {
        r.reader.deinit();
    }

    fn items(r: *TypedStreamReader, arena: Allocator, vals: []const Value) Error![]const Decoded {
        const out = try arena.alloc(Decoded, vals.len);
        for (vals, 0..) |val, i| {
            const p = Path.root.index(r.index);
            out[i] = try decodeExpr(arena, r.item, null, val, .{ .diagnostic = r.diag, .hints = r.hints, .base = &p, .limits = r.limits, .codecs = r.codecs });
            r.index += 1;
        }
        return out;
    }

    /// The next chunk of bytes; returns the items it completed.
    pub fn push(r: *TypedStreamReader, arena: Allocator, chunk: []const u8) Error![]const Decoded {
        return r.items(arena, try r.reader.push(arena, chunk));
    }

    /// The end of the stream; returns the last item, if any.
    pub fn end(r: *TypedStreamReader, arena: Allocator) Error!?Decoded {
        const last = try r.reader.end(arena) orelse return null;
        const out = try r.items(arena, &.{last});
        return out[0];
    }
};

/// Decodes a text with a definition: for a `Stream a`, every top-level
/// value (the result is an array of the items); for any other type, the
/// one value of a single document (`not-one-value` at `$` otherwise).
pub fn decodeText(gpa: Allocator, arena: Allocator, def: *const Def, text: []const u8, options: TextOptions) Error!Decoded {
    if (def.stream) {
        var r = try TypedStreamReader.init(gpa, def, options);
        defer r.deinit();
        var out: std.ArrayList(Decoded) = .empty;
        try out.appendSlice(arena, try r.push(arena, text));
        if (try r.end(arena)) |last| try out.append(arena, last);
        return .{ .array = out.items };
    }
    const root = @import("root.zig");
    const parsed = try root.parseAll(arena, text, .{ .limits = options.limits, .diagnostic = options.diagnostic });
    if (parsed.value.len != 1) {
        if (options.diagnostic) |d| {
            d.set(.@"not-one-value", "expected one value, found {s}", .{if (parsed.value.len == 0) "none" else "more than one"});
            d.line = 0;
            d.column = 0;
            d.setPath("$");
        }
        return error.Haus;
    }
    return decode(arena, def, parsed.value[0], .{ .diagnostic = options.diagnostic, .hints = options.hints, .limits = options.limits, .codecs = options.codecs });
}

/// Encodes what `decodeText` gave: an array of the items' values for a
/// stream, the value otherwise.
pub fn encodeText(arena: Allocator, def: *const Def, d: Decoded, options: EncodeOptions) Error!Value {
    const item = streamItem(def) orelse return encode(arena, def, d, options);
    const out = try arena.alloc(Value, d.array.len);
    for (d.array, 0..) |x, i| {
        const p = Path.root.index(i);
        out[i] = try valueAt(arena, x, options.diagnostic, &p);
        _ = decodeExpr(arena, item, null, out[i], .{ .diagnostic = options.diagnostic, .limits = options.limits, .codecs = options.codecs, .base = &p }) catch |e| switch (e) {
            error.Haus => {
                if (options.diagnostic) |dg| dg.code = .@"cannot-encode";
                return e;
            },
            else => return e,
        };
    }
    return .{ .array = out };
}

/// Checks a text against a definition as a tool does (spec §14): the
/// hints, and the error that ends the check, in the order of their places.
pub fn check(gpa: Allocator, arena: Allocator, def: *const Def, text: []const u8) Error![]const Issue {
    return checkWith(gpa, arena, def, text, .{});
}

pub const CheckOptions = struct {
    limits: v.Limits = .{},
    /// Codecs whose rules the check applies too (`codec-rejected`).
    codecs: ?*const Codecs = null,
};

/// `check` with limits and codecs.
pub fn checkWith(gpa: Allocator, arena: Allocator, def: *const Def, text: []const u8, options: CheckOptions) Error![]const Issue {
    var issues: std.ArrayList(Issue) = .empty;
    var d: Diagnostic = .{};
    _ = decodeText(gpa, arena, def, text, .{ .diagnostic = &d, .hints = &issues, .limits = options.limits, .codecs = options.codecs }) catch |e| switch (e) {
        error.Haus => try issues.append(arena, .{ .kind = .err, .code = d.code, .path = try arena.dupe(u8, d.path()), .message = try arena.dupe(u8, d.message()), .line = d.line, .column = d.column }),
        else => return e,
    };
    return issues.items;
}

test "float spelling" {
    var buf: [64]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("0.1", formatFloat(f64, 0.1, &buf));
    try t.expectEqualStrings("100", formatFloat(f64, 100, &buf));
    try t.expectEqualStrings("1.5e-7", formatFloat(f64, 1.5e-7, &buf));
    try t.expectEqualStrings("0.000001", formatFloat(f64, 0.000001, &buf));
    try t.expectEqualStrings("1e21", formatFloat(f64, 1e21, &buf));
    try t.expectEqualStrings("100000000000000000000", formatFloat(f64, 1e20, &buf));
    try t.expectEqualStrings("-0", formatFloat(f64, -0.0, &buf));
    try t.expectEqualStrings("5e-324", formatFloat(f64, 5e-324, &buf));
    try t.expectEqualStrings("2097152.2", formatFloat(f32, 2097152.25, &buf));
    try t.expectEqualStrings("0.1", formatFloat(f32, 0.1, &buf));
    try t.expectEqualStrings("3.4028235e38", formatFloat(f32, 3.4028235e38, &buf));
}
