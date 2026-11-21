//! The three layouts of spec §11: pretty, compact and minimised. Values are
//! first turned into a layout tree (`Node`), either from values alone
//! (`stringify`, `stringifyAll`: normalized spellings, no comments) or from
//! a document's source (`format.zig`: spellings as written, comments in
//! pretty); the tree is then written in a layout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const v = @import("value.zig");
const Value = v.Value;
const errors = @import("errors.zig");
const Error = errors.Error;
const canon = @import("canonical.zig");
const WriteOptions = canon.WriteOptions;
const number = @import("number.zig");

pub const Layout = enum { pretty, compact, minimised };

pub const FormatOptions = struct {
    layout: Layout = .pretty,
    /// Spaces per level (pretty only). 0 indents nothing (spec §11).
    indent: u32 = 2,
    /// The line width a positional payload must fit in to stay on one line
    /// (pretty only), counted in code points. 0 fits nothing.
    width: u32 = 80,
    /// Keep the comments of a formatted document (pretty). False drops
    /// them, which the user has to ask for (spec §11, "Comments and layouts").
    comments: bool = true,
    /// Limits and the diagnostic, for values built in code.
    write: WriteOptions = .{},
};

// ── the layout tree ──────────────────────────────────────────

/// A comment (its text, CR LF as LF) or a blank line, above an entry or at
/// the end of a container.
pub const Item = union(enum) {
    comment: []const u8,
    blank,
};

pub const Entry = struct {
    /// A record field's key (the key itself, not its spelling).
    key: ?[]const u8 = null,
    value: *const Node,
    leading: []const Item = &.{},
    /// Comments after the entry's comma, on its line.
    trailing: []const []const u8 = &.{},
};

pub const Container = struct {
    entries: []const Entry = &.{},
    /// Comments at the end, before the closing bracket.
    dangling: []const Item = &.{},

    /// Whether a comment is attached here (blank lines don't count: a
    /// payload written on one line drops them).
    pub fn hasComments(c: Container) bool {
        if (anyComment(c.dangling)) return true;
        for (c.entries) |e| if (anyComment(e.leading) or e.trailing.len > 0) return true;
        return false;
    }

    fn anyComment(items: []const Item) bool {
        for (items) |item| if (item == .comment) return true;
        return false;
    }
};

pub const Kind = union(enum) {
    /// A number or byte string, as it is written.
    atom: []const u8,
    /// `spelling`: the source text of a `"…"` string, kept where the layout
    /// writes the string in the same form.
    string: struct { value: []const u8, spelling: ?[]const u8 = null },
    array: Container,
    record: Container,
    tag: []const u8,
    /// `Tag { … }` (also for `Tag({ … })`).
    record_payload: struct { tag: []const u8, body: Container },
    /// `Tag(a, b)`.
    positional: struct { tag: []const u8, args: Container },
};

pub const Node = struct {
    kind: Kind,
    /// The width in code points of the value written on one line, when it
    /// can be (no comment, block string or non-empty container in it);
    /// null otherwise (spec §11).
    flat: ?usize,
};

fn cps(s: []const u8) usize {
    return v.countCodePoints(s);
}

/// Whether a raw string spelling needs rewriting for U+2028/U+2029 (raw in
/// the source, escaped in every layout).
fn spellingWidth(s: []const u8) usize {
    var n = cps(s);
    var i: usize = 0;
    while (i + 2 < s.len) : (i += 1) {
        if (s[i] == 0xE2 and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) n += "\\u{2028}".len - 1;
    }
    return n;
}

/// The flat width of a string written as `"…"` from its value.
fn quotedWidth(s: []const u8) usize {
    var n: usize = 2;
    var i: usize = 0;
    while (i < s.len) {
        const d = v.decode(s, i);
        n += switch (d.cp) {
            '"', '\\', '\n', '\r', '\t' => 2,
            else => if (canon.mustEscape(d.cp)) std.fmt.count("\\u{{{X}}}", .{d.cp}) else 1,
        };
        i += d.len;
    }
    return n;
}

pub fn makeNode(arena: Allocator, kind: Kind) Allocator.Error!*Node {
    const n = try arena.create(Node);
    n.* = .{ .kind = kind, .flat = flatWidth(kind) };
    return n;
}

fn flatWidth(kind: Kind) ?usize {
    return switch (kind) {
        .atom => |a| cps(a),
        .string => |s| if (std.mem.indexOfScalar(u8, s.value, '\n') != null) null else if (s.spelling) |sp| spellingWidth(sp) else quotedWidth(s.value),
        .array, .record => |c| if (c.entries.len == 0 and c.dangling.len == 0) 2 else null,
        .tag => |t| t.len,
        .record_payload => |r| if (r.body.entries.len == 0 and r.body.dangling.len == 0) r.tag.len + 3 else null,
        .positional => |p| blk: {
            if (p.args.hasComments()) break :blk null;
            var w: usize = p.tag.len + 2 + 2 * (p.args.entries.len - 1);
            for (p.args.entries) |e| w += e.value.flat orelse break :blk null;
            break :blk w;
        },
    };
}

// ── from values ──────────────────────────────────────────────

const FromValues = struct {
    arena: Allocator,
    gpa: Allocator,
    checker: canon.Checker,

    fn node(b: *FromValues, val: Value, depth: u32) Error!*Node {
        try b.checker.visit(val, depth);
        const inner = canon.Checker.childDepth(val, depth);
        const kind: Kind = switch (val) {
            .number => |n| blk: {
                if (number.integerDigits(n)) |digits| {
                    if (digits + @intFromBool(n[0] == '-') > b.checker.options.limits.max_number_length) {
                        return canon.failValue(b.checker.options.diagnostic, .@"number-too-long", "an integer of {d} digits is longer than the number limit ({d} characters)", .{ digits, b.checker.options.limits.max_number_length });
                    }
                }
                break :blk .{ .atom = n };
            },
            .string => |s| .{ .string = .{ .value = s } },
            .bytes => |bytes| blk: {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(b.arena, "x\"");
                try canon.appendHex(b.arena, &out, bytes);
                try out.append(b.arena, '"');
                break :blk .{ .atom = out.items };
            },
            .array => |items| .{ .array = .{ .entries = try b.entries(items, inner) } },
            .record => |fields| .{ .record = try b.record(fields, inner) },
            .variant => |x| blk: {
                if (x.args.len == 0) break :blk .{ .tag = x.tag };
                if (x.args.len == 1 and x.args[0] == .record) {
                    b.checker.nodes += 1;
                    break :blk .{ .record_payload = .{ .tag = x.tag, .body = try b.record(x.args[0].record, inner) } };
                }
                break :blk .{ .positional = .{ .tag = x.tag, .args = .{ .entries = try b.entries(x.args, inner) } } };
            },
        };
        return makeNode(b.arena, kind);
    }

    fn entries(b: *FromValues, items: []const Value, depth: u32) Error![]const Entry {
        const out = try b.arena.alloc(Entry, items.len);
        for (items, 0..) |item, i| out[i] = .{ .value = try b.node(item, depth) };
        return out;
    }

    fn record(b: *FromValues, fields: []const v.Field, depth: u32) Error!Container {
        for (fields) |f| {
            if (!std.unicode.utf8ValidateSlice(f.key)) return canon.failValue(b.checker.options.diagnostic, .@"invalid-utf8", "a record key that isn't UTF-8", .{});
        }
        // Duplicate keys: checked on a sorted copy.
        b.gpa.free(try canon.sortedFields(b.gpa, fields, b.checker.options.diagnostic));
        const out = try b.arena.alloc(Entry, fields.len);
        for (fields, 0..) |f, i| out[i] = .{ .key = f.key, .value = try b.node(f.value, depth) };
        return .{ .entries = out };
    }
};

// ── writing ──────────────────────────────────────────────────

pub const Writer = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    indent: u32,
    width: u32,

    fn put(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.out.appendSlice(w.gpa, s);
    }
    fn byte(w: *Writer, c: u8) Allocator.Error!void {
        try w.out.append(w.gpa, c);
    }
    fn pad(w: *Writer, level: usize) Allocator.Error!void {
        try w.out.appendNTimes(w.gpa, ' ', level * w.indent);
    }

    /// A string's `"…"` form: its spelling (raw U+2028 and U+2029 escaped),
    /// or written from its value.
    fn quoted(w: *Writer, value: []const u8, spelling: ?[]const u8) Allocator.Error!void {
        const sp = spelling orelse return canon.appendQuoted(w.gpa, w.out, value);
        var i: usize = 0;
        while (i < sp.len) {
            if (i + 2 < sp.len and sp[i] == 0xE2 and sp[i + 1] == 0x80 and (sp[i + 2] == 0xA8 or sp[i + 2] == 0xA9)) {
                try w.put(if (sp[i + 2] == 0xA8) "\\u{2028}" else "\\u{2029}");
                i += 3;
            } else {
                try w.byte(sp[i]);
                i += 1;
            }
        }
    }

    fn key(w: *Writer, k: []const u8) Allocator.Error!void {
        try canon.appendKey(w.gpa, w.out, k);
    }

    // ── compact and minimised ──

    pub fn flat(w: *Writer, n: *const Node, minimised: bool) Allocator.Error!void {
        const comma = if (minimised) "," else ", ";
        switch (n.kind) {
            .atom => |a| try w.put(a),
            .string => |s| try w.quoted(s.value, s.spelling),
            .array => |c| {
                try w.byte('[');
                for (c.entries, 0..) |e, i| {
                    if (i > 0) try w.put(comma);
                    try w.flat(e.value, minimised);
                }
                try w.byte(']');
            },
            .record => |c| try w.flatRecord(c, minimised),
            .tag => |t| try w.put(t),
            .record_payload => |r| {
                try w.put(r.tag);
                if (!minimised) try w.byte(' ');
                try w.flatRecord(r.body, minimised);
            },
            .positional => |p| {
                try w.put(p.tag);
                try w.byte('(');
                for (p.args.entries, 0..) |e, i| {
                    if (i > 0) try w.put(comma);
                    try w.flat(e.value, minimised);
                }
                try w.byte(')');
            },
        }
    }

    fn flatRecord(w: *Writer, c: Container, minimised: bool) Allocator.Error!void {
        if (c.entries.len == 0) return w.put("{}");
        try w.put(if (minimised) "{" else "{ ");
        for (c.entries, 0..) |e, i| {
            if (i > 0) try w.put(if (minimised) "," else ", ");
            try w.key(e.key.?);
            try w.put(if (minimised) ":" else ": ");
            try w.flat(e.value, minimised);
        }
        try w.put(if (minimised) "}" else " }");
    }

    // ── pretty ──

    fn comment(w: *Writer, text: []const u8) Allocator.Error!void {
        try w.put(text);
    }

    fn items(w: *Writer, list: []const Item, level: usize) Allocator.Error!void {
        for (list) |item| switch (item) {
            .blank => try w.byte('\n'),
            .comment => |c| {
                try w.pad(level);
                try w.comment(c);
                try w.byte('\n');
            },
        };
    }

    /// An entry on its own line(s) at `level`; returns whether its value
    /// took more than one line.
    pub fn entry(w: *Writer, e: Entry, level: usize, comma: bool) Allocator.Error!bool {
        try w.items(e.leading, level);
        try w.pad(level);
        var col = level * w.indent;
        if (e.key) |k| {
            const before = w.out.items.len;
            try w.key(k);
            col += cps(w.out.items[before..]) + 2;
            try w.put(": ");
        }
        const start = w.out.items.len;
        try w.pretty(e.value, level, col, comma);
        const multi = std.mem.indexOfScalar(u8, w.out.items[start..], '\n') != null;
        if (comma) try w.byte(',');
        for (e.trailing) |t| {
            try w.byte(' ');
            try w.comment(t);
        }
        try w.byte('\n');
        return multi;
    }

    fn block(w: *Writer, c: Container, level: usize, open: u8, close: u8) Allocator.Error!void {
        if (c.entries.len == 0 and c.dangling.len == 0) {
            try w.byte(open);
            return w.byte(close);
        }
        try w.byte(open);
        try w.byte('\n');
        for (c.entries) |e| _ = try w.entry(e, level + 1, true);
        try w.items(c.dangling, level + 1);
        try w.pad(level);
        try w.byte(close);
    }

    /// A value at `level` (its entry's), starting at column `col`, with a
    /// comma after it if `comma`.
    pub fn pretty(w: *Writer, n: *const Node, level: usize, col: usize, comma: bool) Allocator.Error!void {
        switch (n.kind) {
            .atom => |a| try w.put(a),
            .string => |s| {
                if (std.mem.indexOfScalar(u8, s.value, '\n') != null) return w.blockString(s.value, level + 1);
                try w.quoted(s.value, s.spelling);
            },
            .array => |c| try w.block(c, level, '[', ']'),
            .record => |c| try w.block(c, level, '{', '}'),
            .tag => |t| try w.put(t),
            .record_payload => |r| {
                try w.put(r.tag);
                try w.byte(' ');
                try w.block(r.body, level, '{', '}');
            },
            .positional => |p| {
                if (n.flat) |f| {
                    if (col + f + @intFromBool(comma) <= w.width) return w.flat(n, false);
                }
                try w.put(p.tag);
                try w.block(p.args, level, '(', ')');
            },
        }
    }

    /// A block string (spec §4, §11), its lines at `level`.
    fn blockString(w: *Writer, value: []const u8, level: usize) Allocator.Error!void {
        try w.put("\"\"\"\n");
        var lines = std.mem.splitScalar(u8, value, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try w.pad(level);
                try w.blockLine(line);
            }
            try w.byte('\n');
        }
        try w.pad(level);
        try w.put("\"\"\"");
    }

    fn blockLine(w: *Writer, line: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < line.len) {
            const d = v.decode(line, i);
            const last = i + d.len == line.len;
            switch (d.cp) {
                '\\' => try w.put("\\\\"),
                '\r' => try w.put("\\r"),
                '"' => {
                    // A quote followed by two more is escaped.
                    if (i + 2 < line.len and line[i + 1] == '"' and line[i + 2] == '"') try w.put("\\\"") else try w.byte('"');
                },
                ' ' => try w.put(if (last) "\\u{20}" else " "),
                '\t' => try w.put(if (last) "\\t" else "\t"),
                else => if (canon.mustEscape(d.cp)) try canon.appendUnicodeEscape(w.gpa, w.out, d.cp) else try w.put(line[i .. i + d.len]),
            }
            i += d.len;
        }
    }

    /// A whole file (spec §6, §11): its items, and the comments at its end.
    pub fn file(w: *Writer, top: Container, layout: Layout) Allocator.Error!void {
        const many = top.entries.len > 1;
        switch (layout) {
            .compact, .minimised => for (top.entries) |e| {
                try w.flat(e.value, layout == .minimised);
                if (many) try w.byte(',');
                try w.byte('\n');
            },
            .pretty => {
                var after_multi = false;
                for (top.entries) |e| {
                    if (after_multi and !(e.leading.len > 0 and e.leading[0] == .blank)) try w.byte('\n');
                    after_multi = try w.entry(e, 0, many);
                }
                try w.items(top.dangling, 0);
            },
        }
    }
};

/// One value in a layout (spec §11), without a line break after it.
pub fn stringify(gpa: Allocator, val: Value, options: FormatOptions) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var b = FromValues{ .arena = arena_state.allocator(), .gpa = gpa, .checker = .{ .options = options.write } };
    const n = try b.node(val, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w = Writer{ .gpa = gpa, .out = &out, .indent = options.indent, .width = options.width };
    switch (options.layout) {
        .pretty => try w.pretty(n, 0, 0, false),
        .compact => try w.flat(n, false),
        .minimised => try w.flat(n, true),
    }
    return out.toOwnedSlice(gpa);
}

/// Values as a file (spec §6, §11): one value alone, more each followed by
/// a comma; a line break at the end unless there are none.
pub fn stringifyAll(gpa: Allocator, values: []const Value, options: FormatOptions) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var b = FromValues{ .arena = arena, .gpa = gpa, .checker = .{ .options = options.write } };
    const entries = try arena.alloc(Entry, values.len);
    for (values, 0..) |val, i| entries[i] = .{ .value = try b.node(val, 0) };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w = Writer{ .gpa = gpa, .out = &out, .indent = options.indent, .width = options.width };
    try w.file(.{ .entries = entries }, options.layout);
    return out.toOwnedSlice(gpa);
}

test "stringify" {
    const gpa = std.testing.allocator;
    const fields = [_]v.Field{
        .{ .key = "name", .value = .{ .string = "a\nb" } },
        .{ .key = "x-y", .value = .{ .variant = .{ .tag = "Point", .args = &.{ .{ .number = "1" }, .{ .number = "2" } } } } },
    };
    const val = Value{ .variant = .{ .tag = "P", .args = &.{.{ .record = &fields }} } };
    const pretty = try stringify(gpa, val, .{});
    defer gpa.free(pretty);
    try std.testing.expectEqualStrings("P {\n  name: \"\"\"\n    a\n    b\n    \"\"\",\n  \"x-y\": Point(1, 2),\n}", pretty);
    const compact = try stringify(gpa, val, .{ .layout = .compact });
    defer gpa.free(compact);
    try std.testing.expectEqualStrings("P { name: \"a\\nb\", \"x-y\": Point(1, 2) }", compact);
    const min = try stringify(gpa, val, .{ .layout = .minimised });
    defer gpa.free(min);
    try std.testing.expectEqualStrings("P{name:\"a\\nb\",\"x-y\":Point(1,2)}", min);
}
