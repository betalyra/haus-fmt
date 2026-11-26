//! The formatter (spec §11): a document's text in a layout, keeping its
//! spellings, and in pretty its comments and blank lines. Comments are
//! attached to the entries around them as §11 says:
//!
//! - after an entry on its line (before or after its comma): after the
//!   entry's comma, until one of them spans lines;
//! - any other comment between two entries: above the next entry, or at the
//!   end of the container after the last one;
//! - between a key and its value: above the entry, after its own comments;
//! - inside the parentheses of `Tag({ … })` but outside the braces: inside
//!   the braces of `Tag { … }`; one on the `}`'s line after it stays after
//!   the last entry when the `}` is on that entry's line.
//!
//! Blank lines between entries and comments are kept (at most one), except
//! right after an opening bracket and right before a closing one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const v = @import("value.zig");
const Value = v.Value;
const errors = @import("errors.zig");
const Error = errors.Error;
const parser = @import("parser.zig");
const Span = parser.Span;
const w = @import("write.zig");
const Node = w.Node;
const Entry = w.Entry;
const Item = w.Item;
const Container = w.Container;

const Builder = struct {
    arena: Allocator,
    text: []const u8,
    nodes: []const Span,
    keys: []const Span,
    comments: []const Span,
    ni: usize = 0,
    ki: usize = 0,

    /// The comments that start in [a, b).
    fn commentsIn(b: *const Builder, a: usize, end: usize) []const Span {
        var lo: usize = 0;
        var hi: usize = b.comments.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (b.comments[mid].start < a) lo = mid + 1 else hi = mid;
        }
        var e = lo;
        while (e < b.comments.len and b.comments[e].start < end) e += 1;
        return b.comments[lo..e];
    }

    fn commentText(b: *const Builder, c: Span) Allocator.Error![]const u8 {
        const raw = b.text[c.start..c.end];
        if (std.mem.indexOfScalar(u8, raw, '\r') == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        for (raw) |ch| if (ch != '\r') try out.append(b.arena, ch);
        return out.items;
    }

    fn hasLineBreak(b: *const Builder, a: usize, end: usize) bool {
        return std.mem.indexOfScalar(u8, b.text[a..end], '\n') != null;
    }

    /// Whether [a, end) holds an empty line: a line with only spaces and
    /// tabs between two line breaks (the line `a` is on has something
    /// before `a`).
    fn hasBlankLine(b: *const Builder, a: usize, end: usize) bool {
        var blank = false;
        for (b.text[a..end]) |ch| switch (ch) {
            '\n' => {
                if (blank) return true;
                blank = true;
            },
            ' ', '\t', '\r' => {},
            else => blank = false,
        };
        return false;
    }

    fn lineOf(b: *const Builder, at: usize) usize {
        return std.mem.count(u8, b.text[0..at], "\n");
    }

    const Gap = struct {
        trailing: std.ArrayList([]const u8) = .empty,
        rest: std.ArrayList(Item) = .empty,
    };

    /// The comments and blank lines in [a, end), after a value (with
    /// `after_value`, those on its line first become trailing comments).
    fn gap(b: *const Builder, a: usize, end: usize, after_value: bool) Allocator.Error!Gap {
        var g: Gap = .{};
        var pos = a;
        var trailing = after_value;
        for (b.commentsIn(a, end)) |c| {
            if (trailing and !b.hasLineBreak(pos, c.start)) {
                try g.trailing.append(b.arena, try b.commentText(c));
                pos = c.end;
                if (b.hasLineBreak(c.start, c.end)) trailing = false;
                continue;
            }
            trailing = false;
            if (b.hasBlankLine(pos, c.start)) try g.rest.append(b.arena, .blank);
            try g.rest.append(b.arena, .{ .comment = try b.commentText(c) });
            pos = c.end;
        }
        if (b.hasBlankLine(pos, end)) try g.rest.append(b.arena, .blank);
        return g;
    }

    fn dropFirstBlank(list: *std.ArrayList(Item)) void {
        if (list.items.len > 0 and list.items[0] == .blank) _ = list.orderedRemove(0);
    }
    fn dropLastBlank(list: *std.ArrayList(Item)) void {
        if (list.items.len > 0 and list.items[list.items.len - 1] == .blank) _ = list.pop();
    }

    fn nextSpan(b: *Builder) Span {
        const s = b.nodes[b.ni];
        b.ni += 1;
        return s;
    }

    /// The items of a container: values (and keys for a record) between
    /// `open` (just after the opening bracket) and `close` (the closing
    /// bracket's offset). `paren_close`: for `Tag({ … })`, the `)`.
    fn container(b: *Builder, values: []const Value, keys: ?[]const v.Field, open: usize, close: usize, paren_close: ?usize) Error!Container {
        const n = values.len;
        const entries = try b.arena.alloc(Entry, n);
        var pos = open;
        var leading: std.ArrayList(Item) = .empty;
        for (0..n) |i| {
            var key_span: ?Span = null;
            if (keys != null) {
                key_span = b.keys[b.ki];
                b.ki += 1;
            }
            const start = if (key_span) |k| k.start else b.nodes[b.ni].start;
            const g = try b.gap(pos, start, i > 0);
            if (i > 0) {
                entries[i - 1].trailing = g.trailing.items;
            }
            leading = g.rest;
            if (key_span) |k| {
                // Comments between the key and the value move above the
                // entry, each after the blank line it had before it.
                var at = k.end;
                for (b.commentsIn(k.end, b.nodes[b.ni].start)) |c| {
                    const last_blank = leading.items.len > 0 and leading.items[leading.items.len - 1] == .blank;
                    if (!last_blank and b.hasBlankLine(at, c.start)) try leading.append(b.arena, .blank);
                    try leading.append(b.arena, .{ .comment = try b.commentText(c) });
                    at = c.end;
                }
            }
            // No blank line right after the opening bracket.
            if (i == 0) dropFirstBlank(&leading);
            const value_end = b.nodes[b.ni].end;
            const node = try b.build(values[i]);
            entries[i] = .{ .key = if (keys) |fs| fs[i].key else null, .value = node, .leading = leading.items };
            pos = value_end;
        }
        var g = try b.gap(pos, close, n > 0);
        if (n > 0) entries[n - 1].trailing = g.trailing.items;
        if (n == 0) dropFirstBlank(&g.rest);
        var dangling = g.rest;
        if (paren_close) |pc| {
            // After the `}` of `Tag({ … })`, inside the parentheses.
            var after = try b.gap(close + 1, pc, true);
            if (after.trailing.items.len > 0) {
                const same_line = n > 0 and b.lineOf(close) == b.lineOf(pos);
                if (same_line) {
                    var t: std.ArrayList([]const u8) = .empty;
                    try t.appendSlice(b.arena, entries[n - 1].trailing);
                    try t.appendSlice(b.arena, after.trailing.items);
                    entries[n - 1].trailing = t.items;
                } else {
                    // A blank line before the `}` stays before them.
                    for (after.trailing.items) |c| try dangling.append(b.arena, .{ .comment = c });
                }
            }
            if (n == 0 and dangling.items.len == 0) dropFirstBlank(&after.rest);
            for (after.rest.items) |item| {
                // At most one blank line in a row.
                if (item == .blank and dangling.items.len > 0 and dangling.items[dangling.items.len - 1] == .blank) continue;
                try dangling.append(b.arena, item);
            }
        }
        dropLastBlank(&dangling);
        return .{ .entries = entries, .dangling = dangling.items };
    }

    fn build(b: *Builder, val: Value) Error!*const Node {
        const span = b.nextSpan();
        const src = b.text[span.start..span.end];
        const kind: w.Kind = switch (val) {
            .number, .bytes => .{ .atom = src },
            .string => |s| .{ .string = .{ .value = s, .spelling = if (std.mem.startsWith(u8, src, "\"\"\"")) null else src } },
            .array => |items| .{ .array = try b.container(items, null, span.start + 1, span.end - 1, null) },
            .record => |fields| .{ .record = try b.record(fields, span.start + 1, null) },
            .variant => |x| blk: {
                if (x.args.len == 0) break :blk .{ .tag = x.tag };
                var j = span.start + x.tag.len;
                while (b.text[j] == ' ' or b.text[j] == '\t') j += 1;
                const paren = b.text[j] == '(';
                if (x.args.len == 1 and x.args[0] == .record) {
                    if (!paren) {
                        const rspan = b.nextSpan();
                        break :blk .{ .record_payload = .{ .tag = x.tag, .body = try b.record(x.args[0].record, rspan.start + 1, null) } };
                    }
                    // `Tag({ … })`: the record's own span is the next node.
                    const rspan = b.nextSpan();
                    const body = try b.recordIn(x.args[0].record, j + 1, rspan.end - 1, span.end - 1);
                    break :blk .{ .record_payload = .{ .tag = x.tag, .body = body } };
                }
                break :blk .{ .positional = .{ .tag = x.tag, .args = try b.container(x.args, null, j + 1, span.end - 1, null) } };
            },
        };
        return w.makeNode(b.arena, kind);
    }

    fn record(b: *Builder, fields: []const v.Field, open: usize, paren_close: ?usize) Error!Container {
        // The record's closing brace is at the end of its span: found from
        // the last node consumed, so take it from the span just read.
        const span = b.nodes[b.ni - 1];
        return b.recordIn(fields, open, span.end - 1, paren_close);
    }

    fn recordIn(b: *Builder, fields: []const v.Field, open: usize, close: usize, paren_close: ?usize) Error!Container {
        const values = try b.arena.alloc(Value, fields.len);
        for (fields, 0..) |f, i| values[i] = f.value;
        return b.container(values, fields, open, close, paren_close);
    }
};

/// Formats a document's text in a layout (spec §11): spellings as written,
/// and in pretty its comments and blank lines.
pub fn format(gpa: Allocator, text: []const u8, options: w.FormatOptions) Error![]u8 {
    var doc = try root.parseDocument(gpa, text, .{ .limits = options.write.limits, .diagnostic = options.write.diagnostic });
    defer doc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var b = Builder{
        .arena = arena_state.allocator(),
        .text = text,
        .nodes = doc.syntax.nodes.items,
        .keys = doc.syntax.keys.items,
        .comments = if (options.comments) doc.syntax.comments.items else &.{},
    };
    const top = try b.container(doc.values, null, 0, text.len, null);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var writer = w.Writer{ .gpa = gpa, .out = &out, .indent = options.indent, .width = options.width };
    try writer.file(top, options.layout, options.stream);
    return out.toOwnedSlice(gpa);
}
