//! The C ABI (include/haus.h): values (parse, read, build, write, compare),
//! schemas (load, build with packages, decode, encode, check, JSON, typed
//! streams) and errors with their code and position.
//!
//! Ownership: every handle the library creates is freed by its own
//! function (`haus_doc_free`, `haus_schema_free`, `haus_stream_free`,
//! `haus_issues_free`), and every text buffer by `haus_free`. A
//! `haus_value` is borrowed from the `haus_doc` that holds it, a
//! `haus_type` from its `haus_schema`. There is no global state: handles
//! are independent, and every function may be called from several
//! threads at once, except that one doc being built into, or one stream,
//! is used by one thread at a time.

const std = @import("std");
const haus = @import("haus");
const Value = haus.Value;
const Diagnostic = haus.Diagnostic;
const Decoded = haus.Decoded;
const Def = haus.schema.Def;

const allocator = std.heap.smp_allocator;

pub const HAUS_OK: c_int = 0;
/// A mistake with a code of spec §17: see the `haus_error`.
pub const HAUS_ERROR: c_int = 1;
pub const HAUS_OUT_OF_MEMORY: c_int = 2;
/// A misuse of the API: a null pointer, a negative indent or width, an
/// unknown layout, a type that doesn't fit the call (no code of §17 applies).
pub const HAUS_INVALID_ARGUMENT: c_int = 3;
/// A mistake in a schema file (spec §13.3, §14), with its code and position.
pub const HAUS_SCHEMA_ERROR: c_int = 4;

pub const HAUS_NUMBER: c_int = 1;
pub const HAUS_STRING: c_int = 2;
pub const HAUS_BYTES: c_int = 3;
pub const HAUS_ARRAY: c_int = 4;
pub const HAUS_RECORD: c_int = 5;
pub const HAUS_VARIANT: c_int = 6;
/// A decoded `Secret` (spec §15): no writer takes it; its value is given
/// out by `haus_secret_reveal` only.
pub const HAUS_SECRET: c_int = 7;

pub const HAUS_PRETTY: c_int = 0;
pub const HAUS_COMPACT: c_int = 1;
pub const HAUS_MINIMISED: c_int = 2;

pub const haus_error = extern struct {
    /// The code of spec §17, NUL-terminated; empty for statuses other than
    /// HAUS_ERROR and HAUS_SCHEMA_ERROR.
    code: [32]u8,
    /// 1-based (spec §8); 0 where there is no position.
    line: u32,
    column: u32,
    message: [192]u8,
    /// The place in a value (spec §15, §16.3: `$.items[2].price`) for an
    /// error of a decoder, an encoder or a JSON reader; empty for an error
    /// in text.
    path: [256]u8,
};

pub const haus_field = extern struct {
    key: ?[*]const u8,
    key_len: usize,
    value: ?*const haus_value,
};

pub const haus_package_file = extern struct {
    name: ?[*:0]const u8,
    bytes: ?[*]const u8,
    len: usize,
};

pub const haus_package_tree = extern struct {
    shown: ?[*:0]const u8,
    files: ?[*]const haus_package_file,
    files_len: usize,
};

pub const haus_build_options = extern struct {
    packages: ?[*]const ?[*:0]const u8 = null,
    packages_len: usize = 0,
    folders: ?[*]const ?[*:0]const u8 = null,
    folders_len: usize = 0,
    trees: ?[*]const haus_package_tree = null,
    trees_len: usize = 0,
    root: ?[*:0]const u8 = null,
    skip_version_check: c_int = 0,
};

pub const haus_issue = extern struct {
    is_error: c_int,
    code: [*:0]const u8,
    path: [*]const u8,
    path_len: usize,
    message: [*]const u8,
    message_len: usize,
    line: u32,
    column: u32,
};

// Handles: opaque to C.
pub const haus_value = opaque {};
pub const haus_doc = opaque {};
pub const haus_schema = opaque {};
pub const haus_type = opaque {};
pub const haus_stream = opaque {};
pub const haus_issues = opaque {};

/// Values and the memory they live in.
const Doc = struct {
    arena: std.heap.ArenaAllocator,
    /// The top-level values: of a parsed file, or a stream's items.
    values: []const Value = &.{},

    fn create() ?*Doc {
        const d = allocator.create(Doc) catch return null;
        d.* = .{ .arena = .init(allocator) };
        return d;
    }

    fn destroy(d: *Doc) void {
        d.arena.deinit();
        allocator.destroy(d);
    }

    fn a(d: *Doc) std.mem.Allocator {
        return d.arena.allocator();
    }

    /// A new value in the doc.
    fn put(d: *Doc, v: Value) ?*const haus_value {
        const p = d.a().create(Value) catch return null;
        p.* = v;
        return @ptrCast(p);
    }
};

fn docOf(h: ?*haus_doc) ?*Doc {
    return @ptrCast(@alignCast(h));
}

fn valueOf(h: ?*const haus_value) ?*const Value {
    return @ptrCast(@alignCast(h));
}

fn defOf(h: ?*const haus_type) ?*const Def {
    return @ptrCast(@alignCast(h));
}

// ── errors ───────────────────────────────────────────────────

fn clear(err: ?*haus_error) void {
    if (err) |e| {
        e.code[0] = 0;
        e.line = 0;
        e.column = 0;
        e.message[0] = 0;
        e.path[0] = 0;
    }
}

fn copyZ(dst: []u8, src: []const u8) void {
    var n = @min(src.len, dst.len - 1);
    // Don't cut a UTF-8 sequence.
    while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

fn report(err: ?*haus_error, e: haus.Error, d: *const Diagnostic) c_int {
    switch (e) {
        error.OutOfMemory => return HAUS_OUT_OF_MEMORY,
        error.Haus => {
            if (err) |out| {
                copyZ(&out.code, d.code.name());
                out.line = d.line;
                out.column = d.column;
                copyZ(&out.message, d.message());
                copyZ(&out.path, d.path());
            }
            return HAUS_ERROR;
        },
    }
}

/// A mistake in a schema file or a build: HAUS_SCHEMA_ERROR.
fn reportSchema(err: ?*haus_error, e: haus.Error, d: *const Diagnostic) c_int {
    const status = report(err, e, d);
    return if (status == HAUS_ERROR) HAUS_SCHEMA_ERROR else status;
}

fn failWith(err: ?*haus_error, code: haus.Code, comptime fmt: []const u8, args: anytype) c_int {
    var d: Diagnostic = .{};
    d.set(code, fmt, args);
    return report(err, error.Haus, &d);
}

fn input(text: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return "";
    const t = text orelse return null;
    return t[0..len];
}

fn give(bytes: []u8, out: ?*?[*]u8, out_len: ?*usize) c_int {
    out.?.* = bytes.ptr;
    out_len.?.* = bytes.len;
    return HAUS_OK;
}

fn layoutOf(layout: c_int, indent: c_int, width: c_int) ?haus.FormatOptions {
    if (indent < 0 or width < 0) return null;
    const l: haus.Layout = switch (layout) {
        HAUS_PRETTY => .pretty,
        HAUS_COMPACT => .compact,
        HAUS_MINIMISED => .minimised,
        else => return null,
    };
    return .{ .layout = l, .indent = @intCast(indent), .width = @intCast(width) };
}

// ── text in, text out ────────────────────────────────────────

/// The canonical form (spec §12) of each value of a file, each followed by
/// a line feed.
pub export fn haus_canonical(text: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    const parsed = haus.parseAll(allocator, t, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    for (parsed.value) |v| {
        haus.canonical_form.appendCanonical(allocator, &buf, v, .{ .diagnostic = &d }) catch |e| {
            buf.deinit(allocator);
            return report(err, e, &d);
        };
        buf.append(allocator, '\n') catch {
            buf.deinit(allocator);
            return HAUS_OUT_OF_MEMORY;
        };
    }
    const owned = buf.toOwnedSlice(allocator) catch return HAUS_OUT_OF_MEMORY;
    return give(owned, out, out_len);
}

/// `hashAll` (spec §12) of a file's values: 64 lowercase hex digits and a
/// NUL into `out`.
pub export fn haus_hash_all(text: ?[*]const u8, len: usize, out: ?*[65]u8, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    const parsed = haus.parseAll(allocator, t, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    defer parsed.deinit();
    const h = haus.hashAll(allocator, parsed.value, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    @memcpy(o[0..64], &h);
    o[64] = 0;
    return HAUS_OK;
}

/// Formats a file in a layout of spec §11, keeping comments in pretty.
/// `indent` and `width` are pretty's options (2 and 80 by default, taken
/// literally: 0 is 0); a negative one is HAUS_INVALID_ARGUMENT.
pub export fn haus_format(text: ?[*]const u8, len: usize, layout: c_int, indent: c_int, width: c_int, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var options = layoutOf(layout, indent, width) orelse return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    options.write = .{ .diagnostic = &d };
    const formatted = haus.format(allocator, t, options) catch |e| return report(err, e, &d);
    return give(formatted, out, out_len);
}

/// Releases a buffer the library returned.
pub export fn haus_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| allocator.free(p[0..len]);
}

/// The version of the specification implemented, NUL-terminated.
pub export fn haus_spec_version() [*:0]const u8 {
    return haus.spec_version;
}

// ── docs: parsing ────────────────────────────────────────────

fn parseInto(doc: *Doc, text: []const u8, d: *Diagnostic) haus.Error![]Value {
    if (!std.unicode.utf8ValidateSlice(text)) {
        return haus.canonical_form.failValue(d, .@"invalid-utf8", "invalid UTF-8", .{});
    }
    var p = haus.parser.Parser.init(doc.a(), allocator, text, .{}, d);
    defer p.deinit();
    return p.parseFile();
}

/// A new, empty doc, to build values in. NULL when out of memory.
pub export fn haus_doc_new() ?*haus_doc {
    return @ptrCast(Doc.create());
}

/// Frees a doc and every value in it.
pub export fn haus_doc_free(doc: ?*haus_doc) void {
    if (docOf(doc)) |d| d.destroy();
}

/// The number of top-level values: a parsed file's, or a stream's items.
pub export fn haus_doc_count(doc: ?*const haus_doc) usize {
    const d: *const Doc = @ptrCast(@alignCast(doc orelse return 0));
    return d.values.len;
}

/// The i-th top-level value, or NULL past the end.
pub export fn haus_doc_value(doc: ?*const haus_doc, i: usize) ?*const haus_value {
    const d: *const Doc = @ptrCast(@alignCast(doc orelse return null));
    if (i >= d.values.len) return null;
    return @ptrCast(&d.values[i]);
}

/// Parses one value (spec §6: a single document; none or several is
/// `not-one-value`). On success `*out_doc` holds it and `*out` is it.
pub export fn haus_parse(text: ?[*]const u8, len: usize, out_doc: ?*?*haus_doc, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out_doc == null or out == null) return HAUS_INVALID_ARGUMENT;
    const doc = Doc.create() orelse return HAUS_OUT_OF_MEMORY;
    var d: Diagnostic = .{};
    const values = parseInto(doc, t, &d) catch |e| {
        doc.destroy();
        return report(err, e, &d);
    };
    if (values.len != 1) {
        doc.destroy();
        d.set(.@"not-one-value", "expected one value, found {s}", .{if (values.len == 0) "none" else "more than one"});
        const p = haus.parser.Parser.init(allocator, allocator, t, .{}, null);
        const at = p.position(t.len);
        d.line = at.line;
        d.column = at.column;
        return report(err, error.Haus, &d);
    }
    doc.values = values;
    out_doc.?.* = @ptrCast(doc);
    out.?.* = @ptrCast(&values[0]);
    return HAUS_OK;
}

/// Parses a file: zero or more values (spec §1, §6), read with
/// haus_doc_count and haus_doc_value.
pub export fn haus_parse_all(text: ?[*]const u8, len: usize, out_doc: ?*?*haus_doc, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out_doc == null) return HAUS_INVALID_ARGUMENT;
    const doc = Doc.create() orelse return HAUS_OUT_OF_MEMORY;
    var d: Diagnostic = .{};
    doc.values = parseInto(doc, t, &d) catch |e| {
        doc.destroy();
        return report(err, e, &d);
    };
    out_doc.?.* = @ptrCast(doc);
    return HAUS_OK;
}

// ── reading values ───────────────────────────────────────────

/// HAUS_NUMBER … HAUS_VARIANT, HAUS_SECRET; 0 for NULL.
pub export fn haus_kind(value: ?*const haus_value) c_int {
    const v = valueOf(value) orelse return 0;
    if (isSecret(v)) return HAUS_SECRET;
    return switch (v.*) {
        .number => HAUS_NUMBER,
        .string => HAUS_STRING,
        .bytes => HAUS_BYTES,
        .array => HAUS_ARRAY,
        .record => HAUS_RECORD,
        .variant => HAUS_VARIANT,
    };
}

fn slice(s: []const u8, len: ?*usize) [*]const u8 {
    if (len) |l| l.* = s.len;
    return s.ptr;
}

/// A number's normalized literal (spec §2: `255` for `0xFF`), not
/// NUL-terminated; NULL for another kind.
pub export fn haus_number(value: ?*const haus_value, len: ?*usize) ?[*]const u8 {
    const v = valueOf(value) orelse return null;
    return if (v.* == .number) slice(v.number, len) else null;
}

/// A string's UTF-8 bytes (it may hold NUL); NULL for another kind.
pub export fn haus_string(value: ?*const haus_value, len: ?*usize) ?[*]const u8 {
    const v = valueOf(value) orelse return null;
    return if (v.* == .string) slice(v.string, len) else null;
}

/// A byte string's bytes; NULL for another kind.
pub export fn haus_bytes(value: ?*const haus_value, len: ?*usize) ?[*]const u8 {
    const v = valueOf(value) orelse return null;
    return if (v.* == .bytes) slice(v.bytes, len) else null;
}

/// The number of items of an array, fields of a record or arguments of a
/// variant; 0 for other kinds.
pub export fn haus_len(value: ?*const haus_value) usize {
    const v = valueOf(value) orelse return 0;
    if (isSecret(v)) return 0;
    return switch (v.*) {
        .array => |items| items.len,
        .record => |fields| fields.len,
        .variant => |x| x.args.len,
        else => 0,
    };
}

/// The i-th item of an array; NULL past the end or for another kind.
pub export fn haus_array_get(value: ?*const haus_value, i: usize) ?*const haus_value {
    const v = valueOf(value) orelse return null;
    if (v.* != .array or i >= v.array.len) return null;
    return @ptrCast(&v.array[i]);
}

/// The key of a record's i-th field, in the order written; NULL past the end.
pub export fn haus_record_key(value: ?*const haus_value, i: usize, len: ?*usize) ?[*]const u8 {
    const v = valueOf(value) orelse return null;
    if (v.* != .record or i >= v.record.len) return null;
    return slice(v.record[i].key, len);
}

/// The value of a record's i-th field; NULL past the end.
pub export fn haus_record_value(value: ?*const haus_value, i: usize) ?*const haus_value {
    const v = valueOf(value) orelse return null;
    if (v.* != .record or i >= v.record.len) return null;
    return @ptrCast(&v.record[i].value);
}

/// The value of the field `key`; NULL when there is none.
pub export fn haus_record_get(value: ?*const haus_value, key: ?[*]const u8, key_len: usize) ?*const haus_value {
    const v = valueOf(value) orelse return null;
    const k = input(key, key_len) orelse return null;
    if (v.* != .record) return null;
    for (v.record) |*f| if (std.mem.eql(u8, f.key, k)) return @ptrCast(&f.value);
    return null;
}

/// A variant's tag; NULL for another kind.
pub export fn haus_variant_tag(value: ?*const haus_value, len: ?*usize) ?[*]const u8 {
    const v = valueOf(value) orelse return null;
    return if (v.* == .variant and !isSecret(v)) slice(v.variant.tag, len) else null;
}

/// A variant's i-th argument (`Tag { … }` has one, the record); NULL past
/// the end.
pub export fn haus_variant_arg(value: ?*const haus_value, i: usize) ?*const haus_value {
    const v = valueOf(value) orelse return null;
    if (v.* != .variant or i >= v.variant.args.len or isSecret(v)) return null;
    return @ptrCast(&v.variant.args[i]);
}

/// The value a decoded `Secret` hides (spec §15): the one explicit call
/// that gives it out. NULL for another kind.
pub export fn haus_secret_reveal(value: ?*const haus_value) ?*const haus_value {
    const v = valueOf(value) orelse return null;
    if (!isSecret(v)) return null;
    return @ptrCast(&v.variant.args[0]);
}

/// A number as an int64_t: `not-an-integer` for one spelled with a
/// fraction or exponent, `out-of-range` beyond int64_t; HAUS_INVALID_ARGUMENT
/// for another kind.
pub export fn haus_number_int64(value: ?*const haus_value, out: ?*i64, err: ?*haus_error) c_int {
    clear(err);
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    if (v.* != .number) return HAUS_INVALID_ARGUMENT;
    const lit = v.number;
    if (std.mem.indexOfAny(u8, lit, ".eE") != null) return failWith(err, .@"not-an-integer", "{s} is not an integer by its spelling", .{lit[0..@min(lit.len, 40)]});
    o.* = std.fmt.parseInt(i64, lit, 10) catch return failWith(err, .@"out-of-range", "{s} is outside the range of int64_t", .{lit[0..@min(lit.len, 40)]});
    return HAUS_OK;
}

/// A number as the nearest double: `out-of-range` beyond its range;
/// HAUS_INVALID_ARGUMENT for another kind.
pub export fn haus_number_double(value: ?*const haus_value, out: ?*f64, err: ?*haus_error) c_int {
    clear(err);
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    if (v.* != .number) return HAUS_INVALID_ARGUMENT;
    const x = std.fmt.parseFloat(f64, v.number) catch return HAUS_INVALID_ARGUMENT;
    if (std.math.isInf(x)) return failWith(err, .@"out-of-range", "{s} is too large for a double", .{v.number[0..@min(v.number.len, 40)]});
    o.* = x;
    return HAUS_OK;
}

// ── building values ──────────────────────────────────────────

/// A number from a literal in any spelling (`0xFF`, `1E+05`, `1_000`),
/// normalized as the parser does (spec §2); one that isn't a literal is
/// `invalid-number`. No limit is checked here (spec §11: writers do).
pub export fn haus_new_number(doc: ?*haus_doc, literal: ?[*]const u8, len: usize, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const d = docOf(doc) orelse return HAUS_INVALID_ARGUMENT;
    const lit = input(literal, len) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    const unlimited: haus.Limits = .{ .max_number_length = std.math.maxInt(u32), .max_exponent = std.math.maxInt(u32) };
    const ok = switch (haus.number.scan(lit, 0, unlimited)) {
        .ok => |s| s.end == lit.len,
        .err => false,
    };
    if (!ok or lit.len == 0) {
        var buf: [64]u8 = undefined;
        return failWith(err, .@"invalid-number", "{s} is not a number literal", .{haus.errors.quoteText(&buf, lit)});
    }
    var text: std.ArrayList(u8) = .empty;
    haus.number.appendNormalized(d.a(), &text, lit) catch return HAUS_OUT_OF_MEMORY;
    o.* = d.put(.{ .number = text.items }) orelse return HAUS_OUT_OF_MEMORY;
    return HAUS_OK;
}

/// A string, copied; one that isn't UTF-8 is `cannot-encode` (spec §11).
pub export fn haus_new_string(doc: ?*haus_doc, s: ?[*]const u8, len: usize, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const d = docOf(doc) orelse return HAUS_INVALID_ARGUMENT;
    const text = input(s, len) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(text)) return failWith(err, .@"cannot-encode", "the string is not UTF-8", .{});
    const copy = d.a().dupe(u8, text) catch return HAUS_OUT_OF_MEMORY;
    o.* = d.put(.{ .string = copy }) orelse return HAUS_OUT_OF_MEMORY;
    return HAUS_OK;
}

/// A byte string, copied.
pub export fn haus_new_bytes(doc: ?*haus_doc, bytes: ?[*]const u8, len: usize, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const d = docOf(doc) orelse return HAUS_INVALID_ARGUMENT;
    const b = input(bytes, len) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    const copy = d.a().dupe(u8, b) catch return HAUS_OUT_OF_MEMORY;
    o.* = d.put(.{ .bytes = copy }) orelse return HAUS_OUT_OF_MEMORY;
    return HAUS_OK;
}

/// The values of a list given to a builder: HAUS_INVALID_ARGUMENT for a
/// NULL list or item.
fn listValues(d: *Doc, list: ?[*]const ?*const haus_value, n: usize, status: *c_int) ?[]Value {
    if (n == 0) return &.{};
    const l = list orelse {
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    };
    const out = d.a().alloc(Value, n) catch {
        status.* = HAUS_OUT_OF_MEMORY;
        return null;
    };
    for (l[0..n], out) |x, *slot| slot.* = (valueOf(x) orelse {
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    }).*;
    return out;
}

/// An array of `n` values. The values are shared, not copied: they must be
/// of this doc, or of one that outlives it.
pub export fn haus_new_array(doc: ?*haus_doc, list: ?[*]const ?*const haus_value, n: usize, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const d = docOf(doc) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    var status: c_int = HAUS_OK;
    const xs = listValues(d, list, n, &status) orelse return status;
    o.* = d.put(.{ .array = xs }) orelse return HAUS_OUT_OF_MEMORY;
    return HAUS_OK;
}

/// A record of `n` fields, in this order; keys are copied (UTF-8, or
/// `cannot-encode`), values shared; a key twice is `duplicate-key`.
pub export fn haus_new_record(doc: ?*haus_doc, fields: ?[*]const haus_field, n: usize, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const d = docOf(doc) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    if (n > 0 and fields == null) return HAUS_INVALID_ARGUMENT;
    const out_fields = d.a().alloc(haus.Field, n) catch return HAUS_OUT_OF_MEMORY;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (0..n) |i| {
        const f = fields.?[i];
        const key = input(f.key, f.key_len) orelse return HAUS_INVALID_ARGUMENT;
        const val = valueOf(f.value) orelse return HAUS_INVALID_ARGUMENT;
        if (!std.unicode.utf8ValidateSlice(key)) return failWith(err, .@"cannot-encode", "the key of field {d} is not UTF-8", .{i});
        const gop = seen.getOrPut(allocator, key) catch return HAUS_OUT_OF_MEMORY;
        if (gop.found_existing) {
            var buf: [64]u8 = undefined;
            return failWith(err, .@"duplicate-key", "the key {s} is there twice", .{haus.errors.quoteText(&buf, key)});
        }
        out_fields[i] = .{ .key = d.a().dupe(u8, key) catch return HAUS_OUT_OF_MEMORY, .value = val.* };
    }
    o.* = d.put(.{ .record = out_fields }) orelse return HAUS_OUT_OF_MEMORY;
    return HAUS_OK;
}

/// A variant: `tag` (`[A-Z][A-Za-z0-9_]*`, or `invalid-tag`) and `n`
/// arguments, shared. `Tag { … }` is a variant with one record argument.
pub export fn haus_new_variant(doc: ?*haus_doc, tag: ?[*]const u8, tag_len: usize, args: ?[*]const ?*const haus_value, n: usize, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const d = docOf(doc) orelse return HAUS_INVALID_ARGUMENT;
    const t = input(tag, tag_len) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    if (!haus.value.isTag(t)) {
        var buf: [64]u8 = undefined;
        return failWith(err, .@"invalid-tag", "{s} is not a tag: [A-Z][A-Za-z0-9_]*", .{haus.errors.quoteText(&buf, if (std.unicode.utf8ValidateSlice(t)) t else "…")});
    }
    var status: c_int = HAUS_OK;
    const xs = listValues(d, args, n, &status) orelse return status;
    const copy = d.a().dupe(u8, t) catch return HAUS_OUT_OF_MEMORY;
    o.* = d.put(.{ .variant = .{ .tag = copy, .args = xs } }) orelse return HAUS_OUT_OF_MEMORY;
    return HAUS_OK;
}

// ── writing and comparing values ─────────────────────────────

/// One value in a layout (spec §11), without a line break after it. The
/// writer checks the limits of spec §7 (`nesting-too-deep`, …).
pub export fn haus_stringify(value: ?*const haus_value, layout: c_int, indent: c_int, width: c_int, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var options = layoutOf(layout, indent, width) orelse return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    options.write = .{ .diagnostic = &d };
    const text = haus.stringify(allocator, v.*, options) catch |e| return report(err, e, &d);
    return give(text, out, out_len);
}

/// The top-level values of a doc as a file (spec §6, §11).
pub export fn haus_stringify_doc(doc: ?*const haus_doc, layout: c_int, indent: c_int, width: c_int, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const dc: *const Doc = @ptrCast(@alignCast(doc orelse return HAUS_INVALID_ARGUMENT));
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var options = layoutOf(layout, indent, width) orelse return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    options.write = .{ .diagnostic = &d };
    const text = haus.stringifyAll(allocator, dc.values, options) catch |e| return report(err, e, &d);
    return give(text, out, out_len);
}

/// A value's canonical form (spec §12), without a line break.
pub export fn haus_value_canonical(value: ?*const haus_value, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    const text = haus.canonical(allocator, v.*, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return give(text, out, out_len);
}

/// A value's hash (spec §12): 64 lowercase hex digits and a NUL.
pub export fn haus_value_hash(value: ?*const haus_value, out: ?*[65]u8, err: ?*haus_error) c_int {
    clear(err);
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    const h = haus.hash(allocator, v.*, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    @memcpy(o[0..64], &h);
    o[64] = 0;
    return HAUS_OK;
}

/// Whether two values are equal (spec §2): `*out` is 1 or 0.
pub export fn haus_value_equals(a: ?*const haus_value, b: ?*const haus_value, out: ?*c_int, err: ?*haus_error) c_int {
    clear(err);
    const x = valueOf(a) orelse return HAUS_INVALID_ARGUMENT;
    const y = valueOf(b) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    o.* = @intFromBool(haus.equals(allocator, x.*, y.*, .{ .diagnostic = &d }) catch |e| return report(err, e, &d));
    return HAUS_OK;
}

/// The order of two values (spec §12, by their canonical bytes): `*out`
/// is -1, 0 or 1.
pub export fn haus_value_compare(a: ?*const haus_value, b: ?*const haus_value, out: ?*c_int, err: ?*haus_error) c_int {
    clear(err);
    const x = valueOf(a) orelse return HAUS_INVALID_ARGUMENT;
    const y = valueOf(b) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    o.* = switch (haus.compare(allocator, x.*, y.*, .{ .diagnostic = &d }) catch |e| return report(err, e, &d)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return HAUS_OK;
}

// ── JSON without a schema (spec §16.1, §16.2) ────────────────

fn newDocWith(out_doc: ?*?*haus_doc, out: ?*?*const haus_value, comptime f: anytype, args: anytype, err: ?*haus_error) c_int {
    if (out_doc == null or out == null) return HAUS_INVALID_ARGUMENT;
    const doc = Doc.create() orelse return HAUS_OUT_OF_MEMORY;
    var d: Diagnostic = .{};
    const v = @call(.auto, f, .{ doc, &d } ++ args) catch |e| {
        doc.destroy();
        return report(err, e, &d);
    };
    const p = doc.put(v) orelse {
        doc.destroy();
        return HAUS_OUT_OF_MEMORY;
    };
    out_doc.?.* = @ptrCast(doc);
    out.?.* = p;
    return HAUS_OK;
}

fn importJson(doc: *Doc, d: *Diagnostic, text: []const u8) haus.Error!Value {
    return haus.json.importJson(doc.a(), allocator, text, .{ .diagnostic = d });
}

fn fromHausJson(doc: *Doc, d: *Diagnostic, text: []const u8) haus.Error!Value {
    return haus.json.fromHausJson(doc.a(), allocator, text, .{ .diagnostic = d });
}

/// Imports plain JSON as a haus value (spec §16.1).
pub export fn haus_import_json(json: ?[*]const u8, len: usize, out_doc: ?*?*haus_doc, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const j = input(json, len) orelse return HAUS_INVALID_ARGUMENT;
    return newDocWith(out_doc, out, importJson, .{j}, err);
}

/// Reads self-describing JSON (spec §16.2).
pub export fn haus_from_haus_json(json: ?[*]const u8, len: usize, out_doc: ?*?*haus_doc, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const j = input(json, len) orelse return HAUS_INVALID_ARGUMENT;
    return newDocWith(out_doc, out, fromHausJson, .{j}, err);
}

/// Writes a value as self-describing JSON (spec §16.2).
pub export fn haus_to_haus_json(value: ?*const haus_value, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var d: Diagnostic = .{};
    const text = haus.json.toHausJson(allocator, v.*, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return give(text, out, out_len);
}

// ── schemas ──────────────────────────────────────────────────

const SchemaHandle = struct {
    schema: *haus.schema.Schema,
    build: ?*haus.packages.Build = null,
    arena: std.heap.ArenaAllocator,

    fn destroy(h: *SchemaHandle) void {
        if (h.build) |b| b.deinit() else h.schema.deinit();
        h.arena.deinit();
        allocator.destroy(h);
    }
};

fn schemaOf(h: ?*const haus_schema) ?*const SchemaHandle {
    return @ptrCast(@alignCast(h));
}

/// Loads a schema file from text (spec §14). It can import std/time only
/// (`import-unavailable` otherwise: use haus_schema_build for packages and
/// files). Its types' ids start with `local#`.
pub export fn haus_schema_load(text: ?[*]const u8, len: usize, out: ?*?*haus_schema, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    const h = allocator.create(SchemaHandle) catch return HAUS_OUT_OF_MEMORY;
    var d: Diagnostic = .{};
    const s = haus.schema.load(allocator, t, .{ .diagnostic = &d }) catch |e| {
        allocator.destroy(h);
        return reportSchema(err, e, &d);
    };
    h.* = .{ .schema = s, .arena = .init(allocator) };
    o.* = @ptrCast(h);
    return HAUS_OK;
}

fn span(p: ?[*:0]const u8) ?[]const u8 {
    return if (p) |x| std.mem.span(x) else null;
}

fn paths(arena: std.mem.Allocator, list: ?[*]const ?[*:0]const u8, n: usize) ?[]const []const u8 {
    if (n == 0) return &.{};
    const l = list orelse return null;
    const out = arena.alloc([]const u8, n) catch return null;
    for (l[0..n], out) |p, *slot| slot.* = arena.dupe(u8, span(p) orelse return null) catch return null;
    return out;
}

/// Builds the schema of the schema file at `entry` (a path) with what it
/// imports (spec §13.3): packages given by directory, by folder, or as
/// trees of files in memory, the build's root, the version check. `options`
/// may be NULL. A mistake is HAUS_SCHEMA_ERROR, with paths relative to the
/// root in its message.
pub export fn haus_schema_build(entry: ?[*:0]const u8, options: ?*const haus_build_options, out: ?*?*haus_schema, err: ?*haus_error) c_int {
    clear(err);
    const e = span(entry) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    const opts: haus_build_options = if (options) |p| p.* else .{};
    const h = allocator.create(SchemaHandle) catch return HAUS_OUT_OF_MEMORY;
    h.* = .{ .schema = undefined, .arena = .init(allocator) };
    const a = h.arena.allocator();
    const fail_arg = struct {
        fn f(x: *SchemaHandle) c_int {
            x.arena.deinit();
            allocator.destroy(x);
            return HAUS_INVALID_ARGUMENT;
        }
    }.f;
    const packages = paths(a, opts.packages, opts.packages_len) orelse return fail_arg(h);
    const folders = paths(a, opts.folders, opts.folders_len) orelse return fail_arg(h);
    // Trees are copied: the build keeps them.
    const trees = a.alloc(haus.packages.Tree, opts.trees_len) catch return fail_arg(h);
    if (opts.trees_len > 0 and opts.trees == null) return fail_arg(h);
    for (trees, 0..) |*t, i| {
        const src = opts.trees.?[i];
        if (src.files_len > 0 and src.files == null) return fail_arg(h);
        const fs = a.alloc(haus.packages.Tree.File, src.files_len) catch return fail_arg(h);
        for (fs, 0..) |*f, k| {
            const file = src.files.?[k];
            const bytes = input(file.bytes, file.len) orelse return fail_arg(h);
            f.* = .{ .name = a.dupe(u8, span(file.name) orelse return fail_arg(h)) catch return fail_arg(h), .bytes = a.dupe(u8, bytes) catch return fail_arg(h) };
        }
        t.* = .{ .shown = a.dupe(u8, span(src.shown) orelse "tree") catch return fail_arg(h), .source = .{ .files = fs } };
    }
    const root = if (span(opts.root)) |r| (a.dupe(u8, r) catch return fail_arg(h)) else null;
    // A single-threaded Io of the call's own: files are read only here.
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    var d: Diagnostic = .{};
    const b = haus.packages.build(allocator, threaded.io(), e, .{
        .packages = packages,
        .folders = folders,
        .trees = trees,
        .root = root,
        .check_versions = opts.skip_version_check == 0,
        .diagnostic = &d,
    }) catch |x| {
        h.arena.deinit();
        allocator.destroy(h);
        return reportSchema(err, x, &d);
    };
    h.build = b;
    h.schema = b.root;
    o.* = @ptrCast(h);
    return HAUS_OK;
}

/// Frees a schema; its types go with it.
pub export fn haus_schema_free(schema: ?*haus_schema) void {
    const h: *SchemaHandle = @ptrCast(@alignCast(schema orelse return));
    h.destroy();
}

/// The number of warnings about the schema file (spec §14:
/// `unknown-attribute`, `deprecated`, `no-json-form`).
pub export fn haus_schema_warning_count(schema: ?*const haus_schema) usize {
    const h = schemaOf(schema) orelse return 0;
    return h.schema.warnings.len;
}

/// The i-th warning: its code, line and column in `out` (no message, no path).
pub export fn haus_schema_warning(schema: ?*const haus_schema, i: usize, out: ?*haus_error) c_int {
    clear(out);
    const h = schemaOf(schema) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    if (i >= h.schema.warnings.len) return HAUS_INVALID_ARGUMENT;
    const w = h.schema.warnings[i];
    copyZ(&o.code, w.code.name());
    o.line = w.line;
    o.column = w.column;
    return HAUS_OK;
}

/// A type the schema file defines (not a prelude or imported one) and that
/// takes no parameters; NULL otherwise. Borrowed from the schema.
pub export fn haus_schema_type(schema: ?*const haus_schema, name: ?[*:0]const u8) ?*const haus_type {
    const h = schemaOf(schema) orelse return null;
    const def = h.schema.get(span(name) orelse return null) orelse return null;
    if (def.params.len > 0) return null;
    return @ptrCast(def);
}

/// A type's id (spec §13.3, "Identity"), not NUL-terminated.
pub export fn haus_type_id(t: ?*const haus_type, len: ?*usize) ?[*]const u8 {
    const def = defOf(t) orelse return null;
    return slice(def.id, len);
}

/// Whether a type is a `Stream a` (spec §14): 1 or 0.
pub export fn haus_type_is_stream(t: ?*const haus_type) c_int {
    const def = defOf(t) orelse return 0;
    return @intFromBool(def.stream);
}

/// The value a decoded result is, in a new doc.
/// The tag that marks a decoded `Secret` (spec §15, "Secrets"): not a tag
/// (`invalid-tag` for every writer, so it is never written by mistake),
/// told apart by its address. `haus_secret_reveal` gives out the value.
const secret_tag: []const u8 = "<redacted>";

fn isSecret(v: *const Value) bool {
    return v.* == .variant and v.variant.tag.ptr == secret_tag.ptr;
}

/// A decoded result as values, each `Secret` as a secret handle.
fn cValue(arena: std.mem.Allocator, d: Decoded) haus.Error!Value {
    return switch (d) {
        .secret => |s| .{ .variant = .{ .tag = secret_tag, .args = try arena.dupe(Value, &.{try cValue(arena, s.*)}) } },
        .array => |xs| blk: {
            const out = try arena.alloc(Value, xs.len);
            for (xs, out) |x, *slot| slot.* = try cValue(arena, x);
            break :blk .{ .array = out };
        },
        .map, .record => |entries| blk: {
            const out = try arena.alloc(haus.Field, entries.len);
            for (entries, out) |e, *slot| slot.* = .{ .key = e.key, .value = try cValue(arena, e.value) };
            break :blk .{ .record = out };
        },
        .variant => |t| blk: {
            const out = try arena.alloc(Value, t.args.len);
            for (t.args, out) |x, *slot| slot.* = try cValue(arena, x);
            break :blk .{ .variant = .{ .tag = t.tag, .args = out } };
        },
        else => haus.decoding.toValue(arena, d),
    };
}

fn decodedDoc(doc: *Doc, decoded: Decoded, out_doc: ?*?*haus_doc, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    var d: Diagnostic = .{};
    const v = cValue(doc.a(), decoded) catch |e| {
        doc.destroy();
        return report(err, e, &d);
    };
    const p = doc.put(v) orelse {
        doc.destroy();
        return HAUS_OUT_OF_MEMORY;
    };
    out_doc.?.* = @ptrCast(doc);
    out.?.* = p;
    return HAUS_OK;
}

/// Decodes a value with a type (spec §15): the result is the value the
/// type accepts, as its decoding has it (fields an open record doesn't
/// list left out, floats in the one spelling of §15, `-0` as `0` for an
/// integer, a `Secret` as a HAUS_SECRET value). The result may share parts with
/// `value`: free its doc after this one. A `Stream` type is
/// HAUS_INVALID_ARGUMENT (use haus_decode_text or a typed stream).
pub export fn haus_decode(t: ?*const haus_type, value: ?*const haus_value, out_doc: ?*?*haus_doc, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const def = defOf(t) orelse return HAUS_INVALID_ARGUMENT;
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    if (out_doc == null or out == null or def.stream) return HAUS_INVALID_ARGUMENT;
    const doc = Doc.create() orelse return HAUS_OUT_OF_MEMORY;
    var d: Diagnostic = .{};
    const decoded = haus.decoding.decode(doc.a(), def, v.*, .{ .diagnostic = &d }) catch |e| {
        doc.destroy();
        return report(err, e, &d);
    };
    return decodedDoc(doc, decoded, out_doc, out, err);
}

/// Decodes a haus text with a type: one value (`not-one-value` at `$`
/// otherwise), or every value of a `Stream` type, as an array of the items
/// (errors at `$[i]`).
pub export fn haus_decode_text(t: ?*const haus_type, text: ?[*]const u8, len: usize, out_doc: ?*?*haus_doc, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const def = defOf(t) orelse return HAUS_INVALID_ARGUMENT;
    const s = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out_doc == null or out == null) return HAUS_INVALID_ARGUMENT;
    const doc = Doc.create() orelse return HAUS_OUT_OF_MEMORY;
    var d: Diagnostic = .{};
    const decoded = haus.decoding.decodeText(allocator, doc.a(), def, s, .{ .diagnostic = &d }) catch |e| {
        doc.destroy();
        return report(err, e, &d);
    };
    return decodedDoc(doc, decoded, out_doc, out, err);
}

/// Encodes a value built in code with a type (spec §15): the value the
/// type accepts, checked against it and against the limits; one the type
/// doesn't accept is `cannot-encode` at its place (`invalid-secret` inside
/// a `Secret`). It is written as decoding has it (haus_decode).
pub export fn haus_encode(t: ?*const haus_type, value: ?*const haus_value, out_doc: ?*?*haus_doc, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const def = defOf(t) orelse return HAUS_INVALID_ARGUMENT;
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    if (out_doc == null or out == null or def.stream) return HAUS_INVALID_ARGUMENT;
    const doc = Doc.create() orelse return HAUS_OUT_OF_MEMORY;
    var d: Diagnostic = .{};
    // A value the type accepts decodes; what it decodes to is written.
    const decoded = haus.decoding.decode(doc.a(), def, v.*, .{ .diagnostic = &d }) catch |e| {
        doc.destroy();
        if (e == error.Haus and d.code != .@"invalid-secret" and d.code != .@"nesting-too-deep" and d.code != .@"unsupported-depth") {
            const path = d.path();
            var inner: Diagnostic = .{};
            inner.set(.@"cannot-encode", "the value can't be written with this type: {s}", .{d.message()});
            inner.setPath(path);
            return report(err, error.Haus, &inner);
        }
        return report(err, e, &d);
    };
    const encoded = haus.decoding.encode(doc.a(), def, decoded, .{ .diagnostic = &d }) catch |e| {
        doc.destroy();
        return report(err, e, &d);
    };
    const p = doc.put(encoded) orelse {
        doc.destroy();
        return HAUS_OUT_OF_MEMORY;
    };
    out_doc.?.* = @ptrCast(doc);
    out.?.* = p;
    return HAUS_OK;
}

comptime {
    // HAUS_CHECK_MAX_ERRORS in include/haus.h.
    std.debug.assert(haus.decoding.CheckOptions.default_max_errors == 200);
}

const Issues = struct {
    arena: std.heap.ArenaAllocator,
    list: []const haus.decoding.Issue,
    stopped: bool,
};

/// Checks a text against a type as a tool does (spec §14): the hints
/// (`unlisted-field`, `unlisted-tag`, `deprecated`) and every error
/// (spec §14, "Every error"), in `*out`, in the order of their places in
/// the text. At most `HAUS_CHECK_MAX_ERRORS` errors per value
/// (`haus_issues_stopped`). HAUS_OK when the check ran, whatever it found.
pub export fn haus_check_text(t: ?*const haus_type, text: ?[*]const u8, len: usize, out: ?*?*haus_issues, err: ?*haus_error) c_int {
    return checkText(t, text, len, out, err, false);
}

/// `haus_check_text` that stops at the first error: the hints found
/// before it, and that error.
pub export fn haus_check_text_first(t: ?*const haus_type, text: ?[*]const u8, len: usize, out: ?*?*haus_issues, err: ?*haus_error) c_int {
    return checkText(t, text, len, out, err, true);
}

fn checkText(t: ?*const haus_type, text: ?[*]const u8, len: usize, out: ?*?*haus_issues, err: ?*haus_error, first: bool) c_int {
    clear(err);
    const def = defOf(t) orelse return HAUS_INVALID_ARGUMENT;
    const s = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    const h = allocator.create(Issues) catch return HAUS_OUT_OF_MEMORY;
    h.* = .{ .arena = .init(allocator), .list = &.{}, .stopped = false };
    const found = haus.decoding.checkReport(allocator, h.arena.allocator(), def, s, .{ .first = first }) catch {
        h.arena.deinit();
        allocator.destroy(h);
        return HAUS_OUT_OF_MEMORY;
    };
    h.list = found.issues;
    h.stopped = found.stopped;
    o.* = @ptrCast(h);
    return HAUS_OK;
}

pub export fn haus_issues_count(issues: ?*const haus_issues) usize {
    const h: *const Issues = @ptrCast(@alignCast(issues orelse return 0));
    return h.list.len;
}

/// 1 when the check stopped at `HAUS_CHECK_MAX_ERRORS` errors in one
/// value: the rest of the text was not checked. 0 otherwise.
pub export fn haus_issues_stopped(issues: ?*const haus_issues) c_int {
    const h: *const Issues = @ptrCast(@alignCast(issues orelse return 0));
    return @intFromBool(h.stopped);
}

/// The i-th issue; its strings are borrowed from `issues`.
pub export fn haus_issues_get(issues: ?*const haus_issues, i: usize, out: ?*haus_issue) c_int {
    const h: *const Issues = @ptrCast(@alignCast(issues orelse return HAUS_INVALID_ARGUMENT));
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    if (i >= h.list.len) return HAUS_INVALID_ARGUMENT;
    const x = h.list[i];
    o.* = .{
        .is_error = @intFromBool(x.kind == .err),
        .code = @tagName(x.code),
        .path = x.path.ptr,
        .path_len = x.path.len,
        .message = x.message.ptr,
        .message_len = x.message.len,
        .line = x.line,
        .column = x.column,
    };
    return HAUS_OK;
}

pub export fn haus_issues_free(issues: ?*haus_issues) void {
    const h: *Issues = @ptrCast(@alignCast(issues orelse return));
    h.arena.deinit();
    allocator.destroy(h);
}

/// Decodes a value with a type and writes its schema-based JSON (spec §16.3).
pub export fn haus_type_to_json(t: ?*const haus_type, value: ?*const haus_value, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const def = defOf(t) orelse return HAUS_INVALID_ARGUMENT;
    const v = valueOf(value) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null or def.stream) return HAUS_INVALID_ARGUMENT;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var d: Diagnostic = .{};
    const decoded = haus.decoding.decode(arena_state.allocator(), def, v.*, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    const json = haus.json.toJson(allocator, def, decoded, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return give(json, out, out_len);
}

/// Reads schema-based JSON (spec §16.3) with a type: the value it encodes
/// to, in a new doc.
pub export fn haus_type_from_json(t: ?*const haus_type, json: ?[*]const u8, len: usize, out_doc: ?*?*haus_doc, out: ?*?*const haus_value, err: ?*haus_error) c_int {
    clear(err);
    const def = defOf(t) orelse return HAUS_INVALID_ARGUMENT;
    const j = input(json, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out_doc == null or out == null or def.stream) return HAUS_INVALID_ARGUMENT;
    const doc = Doc.create() orelse return HAUS_OUT_OF_MEMORY;
    var d: Diagnostic = .{};
    const decoded = haus.json.fromJson(doc.a(), allocator, def, j, .{ .diagnostic = &d }) catch |e| {
        doc.destroy();
        return report(err, e, &d);
    };
    return decodedDoc(doc, decoded, out_doc, out, err);
}

// ── streams ──────────────────────────────────────────────────

const Stream = struct {
    reader: union(enum) {
        plain: haus.StreamReader,
        typed: haus.decoding.TypedStreamReader,
    },
    diag: Diagnostic = .{},
    done: bool = false,

    fn destroy(s: *Stream) void {
        switch (s.reader) {
            inline else => |*r| r.deinit(),
        }
        allocator.destroy(s);
    }
};

/// A stream reader (spec §6, §7): bytes in, values out once their comma
/// arrives. `strict` (1) requires a comma after the last value
/// (`stream-truncated` otherwise).
pub export fn haus_stream_new(strict: c_int, out: ?*?*haus_stream) c_int {
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    const s = allocator.create(Stream) catch return HAUS_OUT_OF_MEMORY;
    s.* = .{ .reader = .{ .plain = undefined } };
    s.reader.plain = haus.StreamReader.init(allocator, .{ .strict = strict != 0, .diagnostic = &s.diag }) catch {
        allocator.destroy(s);
        return HAUS_OUT_OF_MEMORY;
    };
    o.* = @ptrCast(s);
    return HAUS_OK;
}

/// A typed stream reader for a `Stream a` type (spec §15, "Streams"): each
/// value is decoded as an `a` as it arrives (errors at `$[i]`). Another
/// type is HAUS_INVALID_ARGUMENT.
pub export fn haus_typed_stream_new(t: ?*const haus_type, out: ?*?*haus_stream) c_int {
    const def = defOf(t) orelse return HAUS_INVALID_ARGUMENT;
    const o = out orelse return HAUS_INVALID_ARGUMENT;
    if (!def.stream) return HAUS_INVALID_ARGUMENT;
    const s = allocator.create(Stream) catch return HAUS_OUT_OF_MEMORY;
    s.* = .{ .reader = .{ .typed = undefined } };
    s.reader.typed = haus.decoding.TypedStreamReader.init(allocator, def, .{ .diagnostic = &s.diag }) catch {
        allocator.destroy(s);
        return HAUS_OUT_OF_MEMORY;
    };
    o.* = @ptrCast(s);
    return HAUS_OK;
}

fn streamOf(h: ?*haus_stream) ?*Stream {
    return @ptrCast(@alignCast(h));
}

fn streamValues(doc: *Doc, decoded: []const Decoded) haus.Error![]Value {
    const out = try doc.a().alloc(Value, decoded.len);
    for (decoded, out) |x, *slot| slot.* = try cValue(doc.a(), x);
    return out;
}

fn streamStep(s: *Stream, chunk: ?[]const u8, out_doc: ?*?*haus_doc, err: ?*haus_error) c_int {
    if (s.done) return HAUS_INVALID_ARGUMENT;
    const doc = Doc.create() orelse return HAUS_OUT_OF_MEMORY;
    const a = doc.a();
    const values: haus.Error![]const Value = switch (s.reader) {
        .plain => |*r| if (chunk) |c| r.push(a, c) else if (r.end(a)) |last| (if (last) |l| a.dupe(Value, &.{l}) else &.{}) else |e| e,
        .typed => |*r| blk: {
            if (chunk) |c| {
                const items_ = r.push(a, c) catch |e| break :blk e;
                break :blk streamValues(doc, items_);
            }
            const last = r.end(a) catch |e| break :blk e;
            break :blk if (last) |l| streamValues(doc, &.{l}) else &.{};
        },
    };
    doc.values = values catch |e| {
        doc.destroy();
        s.done = true;
        return report(err, e, &s.diag);
    };
    if (chunk == null) s.done = true;
    out_doc.?.* = @ptrCast(doc);
    return HAUS_OK;
}

/// Reads the next chunk of bytes: `*out_doc` is a new doc whose top-level
/// values are the values (or items) the chunk completed, maybe none. After
/// an error, or after haus_stream_end, the stream takes nothing more
/// (HAUS_INVALID_ARGUMENT).
pub export fn haus_stream_push(stream: ?*haus_stream, chunk: ?[*]const u8, len: usize, out_doc: ?*?*haus_doc, err: ?*haus_error) c_int {
    clear(err);
    const s = streamOf(stream) orelse return HAUS_INVALID_ARGUMENT;
    const c = input(chunk, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out_doc == null) return HAUS_INVALID_ARGUMENT;
    return streamStep(s, c, out_doc, err);
}

/// The end of the stream: `*out_doc` holds the last value, if any.
pub export fn haus_stream_end(stream: ?*haus_stream, out_doc: ?*?*haus_doc, err: ?*haus_error) c_int {
    clear(err);
    const s = streamOf(stream) orelse return HAUS_INVALID_ARGUMENT;
    if (out_doc == null) return HAUS_INVALID_ARGUMENT;
    return streamStep(s, null, out_doc, err);
}

pub export fn haus_stream_free(stream: ?*haus_stream) void {
    if (streamOf(stream)) |s| s.destroy();
}

// ── one-call schema functions (a schema file's text and a type name) ──

/// A schema file and one of its types, for the calls below.
const Typed = struct {
    schema: *haus.schema.Schema,
    def: *const Def,

    fn deinit(t: Typed) void {
        t.schema.deinit();
    }
};

fn loadType(schema: ?[*]const u8, schema_len: usize, type_name: ?[*:0]const u8, err: ?*haus_error, status: *c_int) ?Typed {
    const s = input(schema, schema_len) orelse {
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    };
    const name = span(type_name) orelse {
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    };
    var d: Diagnostic = .{};
    const loaded = haus.schema.load(allocator, s, .{ .diagnostic = &d }) catch |e| {
        status.* = reportSchema(err, e, &d);
        return null;
    };
    const def = loaded.get(name) orelse {
        loaded.deinit();
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    };
    if (def.params.len > 0) {
        loaded.deinit();
        status.* = HAUS_INVALID_ARGUMENT;
        return null;
    }
    return .{ .schema = loaded, .def = def };
}

/// Checks a haus text against the type `type_name` of a schema file (spec
/// §14, §15): every value for a `Stream` type, exactly one otherwise. A
/// mistake in the schema file is HAUS_SCHEMA_ERROR; one in the text or the
/// value is HAUS_ERROR, with the value's place in `path`.
pub export fn haus_check(schema: ?[*]const u8, schema_len: usize, type_name: ?[*:0]const u8, text: ?[*]const u8, len: usize, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    var status: c_int = HAUS_OK;
    const typed = loadType(schema, schema_len, type_name, err, &status) orelse return status;
    defer typed.deinit();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var d: Diagnostic = .{};
    _ = haus.decoding.decodeText(allocator, arena_state.allocator(), typed.def, t, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return HAUS_OK;
}

/// Decodes a haus text with a type of a schema file and writes it as
/// schema-based JSON (spec §16.3).
pub export fn haus_to_json(schema: ?[*]const u8, schema_len: usize, type_name: ?[*:0]const u8, text: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const t = input(text, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var status: c_int = HAUS_OK;
    const typed = loadType(schema, schema_len, type_name, err, &status) orelse return status;
    defer typed.deinit();
    if (typed.def.stream) return HAUS_INVALID_ARGUMENT;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var d: Diagnostic = .{};
    const decoded = haus.decoding.decodeText(allocator, arena_state.allocator(), typed.def, t, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    const json = haus.json.toJson(allocator, typed.def, decoded, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return give(json, out, out_len);
}

/// Reads schema-based JSON (spec §16.3) with a type of a schema file and
/// writes the value it encodes to in canonical form (spec §12).
pub export fn haus_from_json(schema: ?[*]const u8, schema_len: usize, type_name: ?[*:0]const u8, json: ?[*]const u8, len: usize, out: ?*?[*]u8, out_len: ?*usize, err: ?*haus_error) c_int {
    clear(err);
    const j = input(json, len) orelse return HAUS_INVALID_ARGUMENT;
    if (out == null or out_len == null) return HAUS_INVALID_ARGUMENT;
    var status: c_int = HAUS_OK;
    const typed = loadType(schema, schema_len, type_name, err, &status) orelse return status;
    defer typed.deinit();
    if (typed.def.stream) return HAUS_INVALID_ARGUMENT;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: Diagnostic = .{};
    const decoded = haus.json.fromJson(arena, allocator, typed.def, j, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    const val = haus.decoding.encode(arena, typed.def, decoded, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    const c = haus.canonical(allocator, val, .{ .diagnostic = &d }) catch |e| return report(err, e, &d);
    return give(c, out, out_len);
}

// ── tests, through the C ABI (more in test/c_api_test.c) ─────

fn callCanonical(text: []const u8, err: *haus_error) !?[]u8 {
    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    const status = haus_canonical(text.ptr, text.len, &out, &out_len, err);
    if (status != HAUS_OK) return null;
    return out.?[0..out_len];
}

test "canonical through the C ABI" {
    var err: haus_error = undefined;
    const got = (try callCanonical("Order { total: 19.90, id: 0xFF },\n\"a\\u{0}b\",", &err)).?;
    defer haus_free(got.ptr, got.len);
    try std.testing.expectEqualStrings("Order{id:255,total:19.90}\n\"a\\u{0}b\"\n", got);
}

test "errors through the C ABI" {
    var err: haus_error = undefined;
    try std.testing.expect(try callCanonical("[1,\n 2 3]", &err) == null);
    try std.testing.expectEqualStrings("missing-comma", std.mem.sliceTo(&err.code, 0));
    try std.testing.expectEqual(@as(u32, 2), err.line);
    try std.testing.expectEqual(@as(u32, 4), err.column);
    try std.testing.expect(std.mem.sliceTo(&err.message, 0).len > 0);
    // Invalid UTF-8 has no position.
    try std.testing.expect(try callCanonical("\"\xff\"", &err) == null);
    try std.testing.expectEqualStrings("invalid-utf8", std.mem.sliceTo(&err.code, 0));
    try std.testing.expectEqual(@as(u32, 0), err.line);
}

test "hash through the C ABI" {
    var err: haus_error = undefined;
    var out: [65]u8 = undefined;
    try std.testing.expectEqual(HAUS_OK, haus_hash_all("", 0, &out, &err));
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", std.mem.sliceTo(&out, 0));
    const a = "1, \"a\", Order { id: 0xFF },";
    const b = "1,\"a\",Order{id:255}";
    var out_b: [65]u8 = undefined;
    try std.testing.expectEqual(HAUS_OK, haus_hash_all(a, a.len, &out, &err));
    try std.testing.expectEqual(HAUS_OK, haus_hash_all(b, b.len, &out_b, &err));
    try std.testing.expectEqualStrings(&out, &out_b);
}

test "format through the C ABI" {
    var err: haus_error = undefined;
    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    const text = "{ a: Point(1, 2) } // c";
    try std.testing.expectEqual(HAUS_OK, haus_format(text, text.len, HAUS_PRETTY, 4, 0, &out, &out_len, &err));
    defer haus_free(out, out_len);
    try std.testing.expectEqualStrings("{\n    a: Point(\n        1,\n        2,\n    ),\n} // c\n", out.?[0..out_len]);
    try std.testing.expectEqual(HAUS_INVALID_ARGUMENT, haus_format(text, text.len, HAUS_PRETTY, -1, 80, &out, &out_len, &err));
    try std.testing.expectEqual(HAUS_INVALID_ARGUMENT, haus_format(text, text.len, 7, 2, 80, &out, &out_len, &err));
    var min: ?[*]u8 = null;
    try std.testing.expectEqual(HAUS_OK, haus_format(text, text.len, HAUS_MINIMISED, 0, 0, &min, &out_len, &err));
    defer haus_free(min, out_len);
    try std.testing.expectEqualStrings("{a:Point(1,2)}\n", min.?[0..out_len]);
}

test "schemas through the C ABI" {
    var err: haus_error = undefined;
    const schema = "type Order = { id: Int, lines: Array Line }\ntype Line = { qty: UInt8 }\ntype Log = Stream Line";
    const ok = "{ id: 1, lines: [{ qty: 2 }] }";
    try std.testing.expectEqual(HAUS_OK, haus_check(schema, schema.len, "Order", ok, ok.len, &err));
    const bad = "{ id: 1, lines: [{ qty: 300 }] }";
    try std.testing.expectEqual(HAUS_ERROR, haus_check(schema, schema.len, "Order", bad, bad.len, &err));
    try std.testing.expectEqualStrings("out-of-range", std.mem.sliceTo(&err.code, 0));
    try std.testing.expectEqualStrings("$.lines[0].qty", std.mem.sliceTo(&err.path, 0));
    const log = "{ qty: 1 },\n{ qty: \"x\" },";
    try std.testing.expectEqual(HAUS_ERROR, haus_check(schema, schema.len, "Log", log, log.len, &err));
    try std.testing.expectEqualStrings("$[1].qty", std.mem.sliceTo(&err.path, 0));
    const broken = "type A = B";
    try std.testing.expectEqual(HAUS_SCHEMA_ERROR, haus_check(broken, broken.len, "A", ok, ok.len, &err));
    try std.testing.expectEqualStrings("unknown-type", std.mem.sliceTo(&err.code, 0));
    try std.testing.expectEqual(HAUS_INVALID_ARGUMENT, haus_check(schema, schema.len, "Nope", ok, ok.len, &err));

    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    try std.testing.expectEqual(HAUS_OK, haus_to_json(schema, schema.len, "Order", ok, ok.len, &out, &out_len, &err));
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"lines\":[{\"qty\":2}]}", out.?[0..out_len]);
    var back: ?[*]u8 = null;
    var back_len: usize = 0;
    try std.testing.expectEqual(HAUS_OK, haus_from_json(schema, schema.len, "Order", out.?, out_len, &back, &back_len, &err));
    haus_free(out, out_len);
    defer haus_free(back, back_len);
    try std.testing.expectEqualStrings("{id:1,lines:[{qty:2}]}", back.?[0..back_len]);
}

test "a value read through handles" {
    var err: haus_error = undefined;
    var doc: ?*haus_doc = null;
    var v: ?*const haus_value = null;
    const text = "Order { id: 0xFF, tags: [\"a\"] }";
    try std.testing.expectEqual(HAUS_OK, haus_parse(text, text.len, &doc, &v, &err));
    defer haus_doc_free(doc);
    try std.testing.expectEqual(HAUS_VARIANT, haus_kind(v));
    const rec = haus_variant_arg(v, 0);
    var len: usize = 0;
    const id = haus_number(haus_record_get(rec, "id", 2), &len).?;
    try std.testing.expectEqualStrings("255", id[0..len]);
    try std.testing.expect(haus_record_get(rec, "nope", 4) == null);
}
