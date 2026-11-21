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

    pub const Entry = struct { key: []const u8, value: Decoded };
    pub const Tagged = struct { tag: []const u8, args: []const Decoded = &.{} };
    pub const Time = struct { kind: time.Kind, text: []const u8 };

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
        }
    }
};

/// What a checker points out (spec §14): a hint, or the error that ends
/// the check, at its place.
pub const Issue = struct {
    kind: enum { hint, err },
    code: Code,
    path: []const u8,
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
};

const Ctx = struct {
    /// Allocates the decoded result (an arena is the usual choice).
    arena: Allocator,
    diag: ?*Diagnostic,
    hints: ?*std.ArrayList(Issue),
    /// Inside a `Secret`: no hints, and errors are rewritten at the secret.
    secret_depth: u32 = 0,

    fn fail(c: *Ctx, code: Code, path: *const Path, comptime fmt: []const u8, args: anytype) Error {
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
            .name => |n| switch (n.ref) {
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
            },
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
                const d = try c.record(target.rec, target.env, x.args[0], path);
                const args = try c.arena.alloc(Decoded, 1);
                args[0] = d;
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
    var c: Ctx = .{ .arena = arena, .diag = options.diagnostic, .hints = options.hints };
    const base = options.base orelse &Path.root;
    return c.decode(def.body, null, val, base);
}

/// Decodes `val` with a type expression read in `env` (for bindings that
/// build types of their own from a schema's).
pub fn decodeExpr(arena: Allocator, e: *const Expr, env: ?*const Env, val: Value, options: DecodeOptions) Error!Decoded {
    var c: Ctx = .{ .arena = arena, .diag = options.diagnostic, .hints = options.hints };
    return c.decode(e, env, val, options.base orelse &Path.root);
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

/// The value a decoded result is written as (spec §15, "Encoding").
pub fn toValue(arena: Allocator, d: Decoded) Allocator.Error!Value {
    return switch (d) {
        .int, .decimal => |s| .{ .number = s },
        .float64 => |x| floatValue(arena, f64, x),
        .float32 => |x| floatValue(arena, f32, x),
        .string => |s| .{ .string = s },
        .bytes => |b| .{ .bytes = b },
        .array => |items| blk: {
            const out = try arena.alloc(Value, items.len);
            for (items, 0..) |x, i| out[i] = try toValue(arena, x);
            break :blk .{ .array = out };
        },
        .map, .record => |entries| blk: {
            const out = try arena.alloc(v.Field, entries.len);
            for (entries, 0..) |e, i| out[i] = .{ .key = e.key, .value = try toValue(arena, e.value) };
            break :blk .{ .record = out };
        },
        .variant => |t| blk: {
            const out = try arena.alloc(Value, t.args.len);
            for (t.args, 0..) |x, i| out[i] = try toValue(arena, x);
            break :blk .{ .variant = .{ .tag = t.tag, .args = out } };
        },
        .unknown => |u| .{ .variant = u },
        .any => |x| x,
        .secret => |s| toValue(arena, s.*),
        .time => |t| blk: {
            const args = try arena.alloc(Value, 1);
            args[0] = .{ .string = t.text };
            break :blk .{ .variant = .{ .tag = t.kind.typeName(), .args = args } };
        },
    };
}

pub const EncodeOptions = struct {
    diagnostic: ?*Diagnostic = null,
    limits: v.Limits = .{},
};

/// Encodes a decoded result with the definition `def` (spec §15): the
/// value it is written as, checked to be one the type accepts and within
/// the limits (§9 item 8). A result the type doesn't accept (one built in
/// code) is `cannot-encode` at its place; inside a `Secret`,
/// `invalid-secret`.
pub fn encode(arena: Allocator, def: *const Def, d: Decoded, options: EncodeOptions) Error!Value {
    const val = try toValue(arena, d);
    // The limits of values built in code (§9 item 8): checked as written.
    var sink: std.ArrayList(u8) = .empty;
    canonical.appendCanonical(arena, &sink, val, .{ .limits = options.limits, .diagnostic = options.diagnostic }) catch |e| return e;
    var inner: Diagnostic = .{};
    _ = decode(arena, def, val, .{ .diagnostic = &inner }) catch |e| switch (e) {
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

// ── texts and streams ────────────────────────────────────────

pub const TextOptions = struct {
    diagnostic: ?*Diagnostic = null,
    hints: ?*std.ArrayList(Issue) = null,
    limits: v.Limits = .{},
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

    pub fn init(gpa: Allocator, def: *const Def, options: TextOptions) Error!TypedStreamReader {
        const item = streamItem(def) orelse unreachable;
        return .{
            .reader = try StreamReader.init(gpa, .{ .limits = options.limits, .diagnostic = options.diagnostic }),
            .item = item,
            .diag = options.diagnostic,
            .hints = options.hints,
        };
    }

    pub fn deinit(r: *TypedStreamReader) void {
        r.reader.deinit();
    }

    fn items(r: *TypedStreamReader, arena: Allocator, vals: []const Value) Error![]const Decoded {
        const out = try arena.alloc(Decoded, vals.len);
        for (vals, 0..) |val, i| {
            const p = Path.root.index(r.index);
            out[i] = try decodeExpr(arena, r.item, null, val, .{ .diagnostic = r.diag, .hints = r.hints, .base = &p });
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
    return decode(arena, def, parsed.value[0], .{ .diagnostic = options.diagnostic, .hints = options.hints });
}

/// Encodes what `decodeText` gave: an array of the items' values for a
/// stream, the value otherwise.
pub fn encodeText(arena: Allocator, def: *const Def, d: Decoded, options: EncodeOptions) Error!Value {
    const item = streamItem(def) orelse return encode(arena, def, d, options);
    const out = try arena.alloc(Value, d.array.len);
    for (d.array, 0..) |x, i| {
        out[i] = try toValue(arena, x);
        _ = decodeExpr(arena, item, null, out[i], .{ .diagnostic = options.diagnostic }) catch |e| switch (e) {
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
    var issues: std.ArrayList(Issue) = .empty;
    var d: Diagnostic = .{};
    _ = decodeText(gpa, arena, def, text, .{ .diagnostic = &d, .hints = &issues }) catch |e| switch (e) {
        error.Haus => try issues.append(arena, .{ .kind = .err, .code = d.code, .path = try arena.dupe(u8, d.path()) }),
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
