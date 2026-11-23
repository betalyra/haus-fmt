//! The parser (grammar.ebnf, spec §1–§8): haus text to values, failing on
//! the first error with its code (spec §17) and position (spec §8).

const std = @import("std");
const Allocator = std.mem.Allocator;
const v = @import("value.zig");
const Value = v.Value;
const Field = v.Field;
const Limits = v.Limits;
const errors = @import("errors.zig");
const Code = errors.Code;
const Diagnostic = errors.Diagnostic;
const Error = errors.Error;
const number = @import("number.zig");

/// A byte range of the text.
pub const Span = struct {
    start: u32,
    end: u32,
};

/// What the formatter needs besides the values: where each value, key and
/// comment is. `nodes` has one span per value in preorder (a container
/// before its contents), `keys` one per record field in the same order.
pub const Syntax = struct {
    nodes: std.ArrayList(Span) = .empty,
    keys: std.ArrayList(Span) = .empty,
    comments: std.ArrayList(Span) = .empty,

    pub fn deinit(s: *Syntax, gpa: Allocator) void {
        s.nodes.deinit(gpa);
        s.keys.deinit(gpa);
        s.comments.deinit(gpa);
    }
};

const bom = "\xEF\xBB\xBF";

/// One node of the trie that finds duplicate keys in linear time (spec §7),
/// a radix trie: each edge is labelled with a part of a key (a slice of a
/// key the record already has), its children are a list of siblings whose
/// labels start with different bytes, so at most 256 long. Every step down
/// consumes at least one byte of the key.
const TrieNode = struct {
    label: [*]const u8 = undefined,
    label_len: u32 = 0,
    /// The label's first byte, kept here for the walk along the siblings.
    first: u8 = 0,
    child: u32 = 0,
    sibling: u32 = 0,
    terminal: bool = false,

    fn labelSlice(n: TrieNode) []const u8 {
        return n.label[0..n.label_len];
    }
};

pub const Parser = struct {
    /// Allocates the values (an arena is the usual choice).
    arena: Allocator,
    /// Allocates scratch space, freed before `deinit` returns.
    gpa: Allocator,
    text: []const u8,
    pos: usize = 0,
    /// Where the text ends for the parser: a stream reader's segment ends
    /// before the comma that follows it.
    end: usize,
    limits: Limits,
    diag: ?*Diagnostic,
    depth: u32 = 0,
    /// The line and column of `text[0]` (a stream reader's segment starts
    /// in the middle of the stream).
    base_line: u32 = 1,
    base_column: u32 = 1,
    /// Whether the last value parsed was a tag without payload (for
    /// `payload-newline`).
    bare_tag: bool = false,
    syntax: ?*Syntax = null,

    values: std.ArrayList(Value) = .empty,
    fields: std.ArrayList(Field) = .empty,
    chars: std.ArrayList(u8) = .empty,
    trie: std.ArrayList(TrieNode) = .empty,

    pub fn init(arena: Allocator, gpa: Allocator, text: []const u8, limits: Limits, diag: ?*Diagnostic) Parser {
        return .{ .arena = arena, .gpa = gpa, .text = text, .end = text.len, .limits = limits, .diag = diag };
    }

    pub fn deinit(p: *Parser) void {
        p.values.deinit(p.gpa);
        p.fields.deinit(p.gpa);
        p.chars.deinit(p.gpa);
        p.trie.deinit(p.gpa);
    }

    // ── errors and positions ─────────────────────────────────

    /// The 1-based line and column of a byte offset (spec §8): columns count
    /// code points, a byte order mark included; only LF starts a line.
    pub fn position(p: *const Parser, offset: usize) struct { line: u32, column: u32 } {
        var line = p.base_line;
        var line_start: usize = 0;
        for (p.text[0..offset], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        const cols: u32 = @intCast(v.countCodePoints(p.text[line_start..offset]));
        return .{ .line = line, .column = if (line_start == 0) p.base_column + cols else 1 + cols };
    }

    pub fn fail(p: *Parser, code: Code, offset: usize, comptime fmt: []const u8, args: anytype) Error {
        if (p.diag) |d| {
            d.set(code, fmt, args);
            const at = p.position(offset);
            d.line = at.line;
            d.column = at.column;
            d.offset = offset;
        }
        return error.Haus;
    }

    /// "found X" for a message: the character at `offset`, or end of input.
    pub fn found(p: *const Parser, offset: usize, buf: []u8) []const u8 {
        if (offset >= p.end) return "end of input";
        const d = v.decode(p.text, offset);
        return errors.quoteChar(buf, d.cp);
    }

    pub inline fn eof(p: *const Parser) bool {
        return p.pos >= p.end;
    }

    pub inline fn peek(p: *const Parser) u8 {
        return p.text[p.pos];
    }

    pub fn startsWith(p: *const Parser, at: usize, s: []const u8) bool {
        return at + s.len <= p.end and std.mem.eql(u8, p.text[at .. at + s.len], s);
    }

    // ── whitespace and comments ──────────────────────────────

    /// `ws`: spaces, tabs, line breaks and comments.
    pub fn skipWs(p: *Parser) Error!void {
        while (p.pos < p.end) {
            switch (p.text[p.pos]) {
                ' ', '\t', '\n' => p.pos += 1,
                '\r' => {
                    if (p.pos + 1 < p.end and p.text[p.pos + 1] == '\n') {
                        p.pos += 2;
                    } else return p.fail(.@"lone-carriage-return", p.pos, "carriage return without a line feed", .{});
                },
                '/' => {
                    if (p.pos + 1 < p.end and p.text[p.pos + 1] == '/') {
                        try p.lineComment();
                    } else if (p.pos + 1 < p.end and p.text[p.pos + 1] == '*') {
                        try p.blockComment();
                    } else return p.fail(.@"stray-slash", p.pos, "unexpected '/' (comments are // or /* */)", .{});
                },
                else => return,
            }
        }
    }

    fn checkCommentChar(p: *Parser, at: usize, cp: u21) Error!void {
        if (v.isBidi(cp)) return p.fail(.@"bidi-control", at, "bidirectional control U+{X:0>4} in a comment", .{cp});
        if (v.isControl(cp) and cp != '\t') return p.fail(.@"control-character", at, "raw control character U+{X:0>4} in a comment", .{cp});
    }

    fn lineComment(p: *Parser) Error!void {
        const start = p.pos;
        var i = p.pos + 2;
        while (i < p.end) {
            const c = p.text[i];
            if (c == '\n') break;
            if (c == '\r') {
                if (i + 1 < p.end and p.text[i + 1] == '\n') break;
                return p.fail(.@"lone-carriage-return", i, "carriage return without a line feed", .{});
            }
            const d = v.decode(p.text, i);
            try p.checkCommentChar(i, d.cp);
            i += d.len;
        }
        p.pos = i;
        try p.recordComment(start, i);
    }

    fn blockComment(p: *Parser) Error!void {
        const start = p.pos;
        var i = p.pos + 2;
        var nesting: usize = 1;
        while (true) {
            if (i >= p.end) return p.fail(.@"unterminated-comment", start, "unterminated block comment", .{});
            const c = p.text[i];
            if (c == '*' and i + 1 < p.end and p.text[i + 1] == '/') {
                i += 2;
                nesting -= 1;
                if (nesting == 0) break;
            } else if (c == '/' and i + 1 < p.end and p.text[i + 1] == '*') {
                i += 2;
                nesting += 1;
            } else if (c == '\n') {
                i += 1;
            } else if (c == '\r') {
                if (i + 1 < p.end and p.text[i + 1] == '\n') {
                    i += 2;
                } else return p.fail(.@"lone-carriage-return", i, "carriage return without a line feed", .{});
            } else {
                const d = v.decode(p.text, i);
                try p.checkCommentChar(i, d.cp);
                i += d.len;
            }
        }
        p.pos = i;
        try p.recordComment(start, i);
    }

    fn recordComment(p: *Parser, start: usize, end: usize) Error!void {
        if (p.syntax) |s| try s.comments.append(p.gpa, .{ .start = @intCast(start), .end = @intCast(end) });
    }

    // ── files ────────────────────────────────────────────────

    /// Skips a byte order mark and rejects a version directive (spec §10);
    /// only at the start of a file or stream.
    pub fn fileStart(p: *Parser) Error!void {
        if (p.startsWith(p.pos, bom)) p.pos += bom.len;
        if (p.startsWith(p.pos, "#haus")) {
            return p.fail(.@"version-directive", p.pos, "this file starts with a #haus version directive: it needs a newer version of haus", .{});
        }
    }

    /// A whole file (grammar `file`): zero or more values.
    pub fn parseFile(p: *Parser) Error![]Value {
        try p.fileStart();
        try p.skipWs();
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(p.arena);
        while (!p.eof()) {
            try items.append(p.arena, try p.value());
            try p.skipWs();
            if (p.eof()) break;
            if (p.peek() == ',') {
                p.pos += 1;
                try p.skipWs();
                continue;
            }
            return p.afterValue(null, 0);
        }
        return items.toOwnedSlice(p.arena);
    }

    /// The part of a stream between two top-level commas (or the start or
    /// end): whitespace and comments around at most one value. With
    /// `comma_after`, a comma follows at `end`, so a value is required.
    pub fn parseSegment(p: *Parser, first: bool, comma_after: bool) Error!?Value {
        if (first) try p.fileStart();
        try p.skipWs();
        if (p.eof()) {
            if (comma_after) return p.fail(.@"expected-value", p.end, "expected a value, found ','", .{});
            return null;
        }
        const val = try p.value();
        try p.skipWs();
        if (!p.eof()) return p.afterValue(null, 0);
        return val;
    }

    /// The error for what follows a value where `,` or the closer is
    /// expected (`closer` null at the top level; `open` is the opening
    /// bracket's offset).
    fn afterValue(p: *Parser, closer: ?u8, open: usize) Error {
        if (p.eof()) {
            return p.fail(.@"unclosed-bracket", open, "unclosed '{c}'", .{p.text[open]});
        }
        var buf: [16]u8 = undefined;
        const c = p.peek();
        const what = p.found(p.pos, &buf);
        if (p.bare_tag and (c == '(' or c == '{')) {
            return p.fail(.@"payload-newline", p.pos, "a payload must start on its tag's line: expected ',' before {s}", .{what});
        }
        if (c == ']' or c == '}' or c == ')') {
            if (closer) |want| return p.fail(.@"unexpected-closer", p.pos, "expected ',' or '{c}', found {s}", .{ want, what });
            return p.fail(.@"unexpected-closer", p.pos, "expected ',' between top-level values, found {s}", .{what});
        }
        if (closer) |want| return p.fail(.@"missing-comma", p.pos, "expected ',' or '{c}', found {s}", .{ want, what });
        return p.fail(.@"missing-comma", p.pos, "expected ',' between top-level values, found {s}", .{what});
    }

    // ── values ───────────────────────────────────────────────

    /// A value at `pos` (not at the end: callers report that).
    pub fn value(p: *Parser) Error!Value {
        var node: usize = undefined;
        if (p.syntax) |s| {
            node = s.nodes.items.len;
            try s.nodes.append(p.gpa, .{ .start = @intCast(p.pos), .end = 0 });
        }
        const start = p.pos;
        var bare = false;
        const c = p.peek();
        const result: Value = switch (c) {
            '{' => .{ .record = try p.record() },
            '[' => .{ .array = try p.array() },
            '"' => .{ .string = try p.string() },
            '-', '0'...'9' => .{ .number = try p.numberLit() },
            'A'...'Z' => blk: {
                const variant = try p.parseVariant();
                bare = p.bare_tag;
                break :blk .{ .variant = variant };
            },
            '+', '.' => {
                var buf: [16]u8 = undefined;
                return p.fail(.@"invalid-number", start, "expected a value, found {s}", .{p.found(start, &buf)});
            },
            'a'...'z', '_' => blk: {
                if (c == 'x' and p.pos + 1 < p.end and p.text[p.pos + 1] == '"') break :blk .{ .bytes = try p.bytes() };
                return p.identifierValue();
            },
            else => {
                var buf: [16]u8 = undefined;
                return p.fail(.@"expected-value", start, "expected a value, found {s}", .{p.found(start, &buf)});
            },
        };
        p.bare_tag = bare;
        if (p.syntax) |s| s.nodes.items[node].end = @intCast(p.pos);
        return result;
    }

    fn identifierValue(p: *Parser) Error {
        const start = p.pos;
        var i = p.pos;
        while (i < p.end and v.isIdentChar(p.text[i])) i += 1;
        const word = p.text[start..i];
        var buf: [64]u8 = undefined;
        const q = errors.quoteText(&buf, word);
        if (std.mem.eql(u8, word, "null")) {
            return p.fail(.@"null-literal", start, "unexpected identifier {s}: haus has no null (use the variant None)", .{q});
        }
        if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false")) {
            return p.fail(.@"boolean-literal", start, "unexpected identifier {s}: booleans are the variants True and False", .{q});
        }
        return p.fail(.@"bare-identifier", start, "unexpected identifier {s}: lowercase identifiers can only be record keys", .{q});
    }

    fn enter(p: *Parser, at: usize) Error!void {
        p.depth += 1;
        if (p.depth > p.limits.max_depth) {
            return p.fail(.@"nesting-too-deep", at, "nesting deeper than {d} levels", .{p.limits.max_depth});
        }
    }

    fn numberLit(p: *Parser) Error![]const u8 {
        const start = p.pos;
        switch (number.scan(p.text[0..p.end], start, p.limits)) {
            .err => |code| return switch (code) {
                .@"number-too-long" => p.fail(code, start, "number literal longer than the limit ({d} characters, {d} hex digits)", .{ p.limits.max_number_length, p.limits.maxHexDigits() }),
                .@"exponent-too-large" => p.fail(code, start, "exponent larger than {d}", .{p.limits.max_exponent}),
                else => p.fail(code, start, "invalid number", .{}),
            },
            .ok => |s| {
                p.pos = s.end;
                // Most literals are written normalized already (`12`, `-0.5`, `1e-9`).
                const literal = p.text[start..s.end];
                if (number.isNormalized(literal)) return p.arena.dupe(u8, literal);
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(p.arena);
                try number.appendNormalized(p.arena, &out, p.text[start..s.end]);
                return out.toOwnedSlice(p.arena);
            },
        }
    }

    fn array(p: *Parser) Error![]const Value {
        const open = p.pos;
        try p.enter(open);
        p.pos += 1;
        const base = p.values.items.len;
        defer p.values.shrinkRetainingCapacity(base);
        try p.skipWs();
        while (true) {
            if (p.eof()) return p.fail(.@"unclosed-bracket", open, "unclosed '['", .{});
            if (p.peek() == ']') break;
            const item = try p.value();
            try p.values.append(p.gpa, item);
            try p.skipWs();
            if (p.eof()) return p.fail(.@"unclosed-bracket", open, "unclosed '['", .{});
            if (p.peek() == ',') {
                p.pos += 1;
                try p.skipWs();
            } else if (p.peek() == ']') {
                break;
            } else return p.afterValue(']', open);
        }
        p.pos += 1;
        p.depth -= 1;
        p.bare_tag = false;
        return p.arena.dupe(Value, p.values.items[base..]);
    }

    fn record(p: *Parser) Error![]const Field {
        const open = p.pos;
        try p.enter(open);
        p.pos += 1;
        const base = p.fields.items.len;
        defer p.fields.shrinkRetainingCapacity(base);
        const trie_mark = p.trie.items.len;
        defer p.trie.shrinkRetainingCapacity(trie_mark);
        try p.trie.append(p.gpa, .{});
        const root: u32 = @intCast(trie_mark);
        try p.skipWs();
        while (true) {
            if (p.eof()) return p.fail(.@"unclosed-bracket", open, "unclosed '{{'", .{});
            if (p.peek() == '}') break;
            const key_start = p.pos;
            const key = try p.parseKey();
            // A duplicate is reported as soon as its key is read, before its
            // colon and value (spec §8).
            if (!try p.insertKey(root, key)) {
                var buf: [64]u8 = undefined;
                return p.fail(.@"duplicate-key", key_start, "duplicate key {s}", .{errors.quoteText(&buf, key)});
            }
            if (p.syntax) |s| try s.keys.append(p.gpa, .{ .start = @intCast(key_start), .end = @intCast(p.pos) });
            try p.skipWs();
            if (p.eof() or p.peek() != ':') {
                var buf: [64]u8 = undefined;
                var fbuf: [16]u8 = undefined;
                return p.fail(.@"missing-colon", p.pos, "expected ':' after key {s}, found {s}", .{ errors.quoteText(&buf, key), p.found(p.pos, &fbuf) });
            }
            p.pos += 1;
            try p.skipWs();
            if (p.eof()) return p.fail(.@"expected-value", p.pos, "expected a value, found end of input", .{});
            const val = try p.value();
            try p.fields.append(p.gpa, .{ .key = key, .value = val });
            try p.skipWs();
            if (p.eof()) return p.fail(.@"unclosed-bracket", open, "unclosed '{{'", .{});
            if (p.peek() == ',') {
                p.pos += 1;
                try p.skipWs();
            } else if (p.peek() == '}') {
                break;
            } else return p.afterValue('}', open);
        }
        p.pos += 1;
        p.depth -= 1;
        p.bare_tag = false;
        return p.arena.dupe(Field, p.fields.items[base..]);
    }

    /// Inserts a key into the record's trie; false if it was there. `name`
    /// must stay where it is while the record is read (the arena's copy):
    /// the trie's labels are slices of it.
    fn insertKey(p: *Parser, root: u32, name: []const u8) Error!bool {
        // At most two nodes are added.
        try p.trie.ensureUnusedCapacity(p.gpa, 2);
        const nodes = p.trie.items.ptr;
        var node = root;
        var rest = name;
        while (rest.len > 0) {
            var child = nodes[node].child;
            while (child != 0 and nodes[child].first != rest[0]) child = nodes[child].sibling;
            if (child == 0) {
                // No label starts with this byte: the rest of the key is a new leaf.
                const leaf: u32 = @intCast(p.trie.items.len);
                p.trie.appendAssumeCapacity(.{ .label = rest.ptr, .label_len = @intCast(rest.len), .first = rest[0], .sibling = nodes[node].child, .terminal = true });
                nodes[node].child = leaf;
                return true;
            }
            const label = nodes[child].labelSlice();
            const common = std.mem.indexOfDiff(u8, label, rest) orelse label.len;
            if (common < label.len) {
                // The key leaves the label after `common` bytes (at least
                // one): split the edge there, the old node below.
                const lower: u32 = @intCast(p.trie.items.len);
                var tail = nodes[child];
                tail.label += common;
                tail.label_len -= @intCast(common);
                tail.first = tail.label[0];
                tail.sibling = 0;
                p.trie.appendAssumeCapacity(tail);
                nodes[child].label_len = @intCast(common);
                nodes[child].child = lower;
                nodes[child].terminal = false;
            }
            node = child;
            rest = rest[common..];
        }
        if (nodes[node].terminal) return false;
        nodes[node].terminal = true;
        return true;
    }

    /// A record key: an identifier or a basic string.
    fn parseKey(p: *Parser) Error![]const u8 {
        const start = p.pos;
        const c = p.peek();
        if (c == '"') {
            if (p.startsWith(start, "\"\"\"")) return p.fail(.@"block-string-key", start, "a block string can't be a record key", .{});
            return p.basicString(.key);
        }
        if (v.isKeyStart(c)) {
            var i = start + 1;
            while (i < p.end and v.isIdentChar(p.text[i])) i += 1;
            if (i - start > p.limits.max_string_length) return p.fail(.@"key-too-long", start, "record key longer than {d} characters", .{p.limits.max_string_length});
            p.pos = i;
            return p.arena.dupe(u8, p.text[start..i]);
        }
        var buf: [16]u8 = undefined;
        if (v.isTagStart(c)) {
            var i = start + 1;
            while (i < p.end and v.isIdentChar(p.text[i])) i += 1;
            var kbuf: [64]u8 = undefined;
            return p.fail(.@"uppercase-key", start, "record key {s} starts with a capital letter: quote it, or start it with a lowercase letter", .{errors.quoteText(&kbuf, p.text[start..i])});
        }
        return p.fail(.@"expected-key", start, "expected a record key, found {s}", .{p.found(start, &buf)});
    }

    fn parseVariant(p: *Parser) Error!v.Variant {
        const start = p.pos;
        var i = start + 1;
        while (i < p.end and v.isIdentChar(p.text[i])) i += 1;
        if (i - start > p.limits.max_string_length) return p.fail(.@"tag-too-long", start, "tag longer than {d} characters", .{p.limits.max_string_length});
        const tag = try p.arena.dupe(u8, p.text[start..i]);
        p.pos = i;
        // Only spaces and tabs between a tag and its payload (spec §5).
        var j = i;
        while (j < p.end and (p.text[j] == ' ' or p.text[j] == '\t')) j += 1;
        if (j < p.end and p.text[j] == '(') {
            p.pos = j;
            const args = try p.payload();
            p.bare_tag = false;
            return .{ .tag = tag, .args = args };
        }
        if (j < p.end and p.text[j] == '{') {
            p.pos = j;
            var node: usize = undefined;
            if (p.syntax) |s| {
                node = s.nodes.items.len;
                try s.nodes.append(p.gpa, .{ .start = @intCast(j), .end = 0 });
            }
            const fields = try p.record();
            if (p.syntax) |s| s.nodes.items[node].end = @intCast(p.pos);
            const args = try p.arena.alloc(Value, 1);
            args[0] = .{ .record = fields };
            p.bare_tag = false;
            return .{ .tag = tag, .args = args };
        }
        p.bare_tag = true;
        return .{ .tag = tag };
    }

    pub fn payload(p: *Parser) Error![]const Value {
        const open = p.pos;
        try p.enter(open);
        p.pos += 1;
        const base = p.values.items.len;
        defer p.values.shrinkRetainingCapacity(base);
        try p.skipWs();
        if (p.eof()) return p.fail(.@"unclosed-bracket", open, "unclosed '('", .{});
        if (p.peek() == ')') return p.fail(.@"empty-payload", open, "empty payload: write the tag without parentheses", .{});
        while (true) {
            const item = try p.value();
            try p.values.append(p.gpa, item);
            try p.skipWs();
            if (p.eof()) return p.fail(.@"unclosed-bracket", open, "unclosed '('", .{});
            if (p.peek() == ',') {
                p.pos += 1;
                try p.skipWs();
                if (p.eof()) return p.fail(.@"unclosed-bracket", open, "unclosed '('", .{});
                if (p.peek() == ')') break;
            } else if (p.peek() == ')') {
                break;
            } else return p.afterValue(')', open);
        }
        p.pos += 1;
        p.depth -= 1;
        return p.arena.dupe(Value, p.values.items[base..]);
    }

    // ── strings ──────────────────────────────────────────────

    fn string(p: *Parser) Error![]const u8 {
        if (p.startsWith(p.pos, "\"\"\"")) return p.blockString();
        return p.basicString(.string);
    }

    pub const StringKind = enum { string, key };

    fn tooLong(p: *Parser, kind: StringKind, at: usize) Error {
        return switch (kind) {
            .string => p.fail(.@"string-too-long", at, "string longer than {d} characters", .{p.limits.max_string_length}),
            .key => p.fail(.@"key-too-long", at, "record key longer than {d} characters", .{p.limits.max_string_length}),
        };
    }

    /// `"…"`. The characters are checked one by one; runs of them are
    /// copied as they are, and only a string with escapes is built in
    /// `chars`.
    pub fn basicString(p: *Parser, kind: StringKind) Error![]const u8 {
        const open = p.pos;
        const max = p.limits.max_string_length;
        var count: usize = 0;
        var i = open + 1;
        // `text[run..i]` is taken as it is; once an escape is met, `chars`
        // holds what comes before `run`.
        var run = i;
        var escaped = false;
        while (true) {
            // Sixteen printable ASCII characters at a time (no quote,
            // backslash or control character), while within the limit.
            while (i + plain_chunk <= p.end and count + plain_chunk <= max and plainAscii(p.text[i..][0..plain_chunk].*)) {
                i += plain_chunk;
                count += plain_chunk;
            }
            if (i >= p.end) return p.fail(.@"unterminated-string", open, "unterminated string", .{});
            const c = p.text[i];
            if (c == '"') break;
            if (c == '\\') {
                if (!escaped) {
                    p.chars.clearRetainingCapacity();
                    escaped = true;
                }
                try p.chars.appendSlice(p.gpa, p.text[run..i]);
                i = try p.escape(i);
                run = i;
            } else if (c == '\n') {
                return p.fail(.@"string-line-break", i, "a raw line break in a string: write \\n, or use a block string", .{});
            } else if (c >= 0x20 and c < 0x7F) {
                i += 1;
            } else {
                const d = v.decode(p.text, i);
                if (v.isControl(d.cp)) return p.fail(.@"control-character", i, "raw control character U+{X:0>4} in a string: write it as an escape", .{d.cp});
                if (v.isBidi(d.cp)) return p.fail(.@"bidi-control", i, "raw bidirectional control U+{X:0>4} in a string: write it as an escape", .{d.cp});
                i += d.len;
            }
            count += 1;
            if (count > max) return p.tooLong(kind, open);
        }
        p.pos = i + 1;
        if (!escaped) return p.arena.dupe(u8, p.text[run..i]);
        try p.chars.appendSlice(p.gpa, p.text[run..i]);
        return p.arena.dupe(u8, p.chars.items);
    }

    const plain_chunk = 16;

    /// Whether every byte is printable ASCII other than `"` and `\`.
    inline fn plainAscii(chunk: @Vector(plain_chunk, u8)) bool {
        const printable = (chunk -% @as(@Vector(plain_chunk, u8), @splat(0x20))) < @as(@Vector(plain_chunk, u8), @splat(0x7F - 0x20));
        const quote = chunk == @as(@Vector(plain_chunk, u8), @splat('"'));
        const backslash = chunk == @as(@Vector(plain_chunk, u8), @splat('\\'));
        return @reduce(.And, printable) and !@reduce(.Or, quote) and !@reduce(.Or, backslash);
    }

    /// The escape at `text[at]` (a backslash), appended to `chars`;
    /// returns the offset after it.
    fn escape(p: *Parser, at: usize) Error!usize {
        if (at + 1 >= p.end) return p.fail(.@"invalid-escape", at, "invalid escape: '\\' at the end of the input", .{});
        const e = p.text[at + 1];
        const simple: ?u8 = switch (e) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => null,
        };
        if (simple) |s| {
            try p.chars.append(p.gpa, s);
            return at + 2;
        }
        if (e != 'u') {
            var buf: [16]u8 = undefined;
            return p.fail(.@"invalid-escape", at, "invalid escape: '\\' followed by {s}", .{p.found(at + 1, &buf)});
        }
        var i = at + 2;
        if (i >= p.end or p.text[i] != '{') return p.fail(.@"invalid-unicode-escape", at, "invalid unicode escape: expected \\u{{1-6 hex digits}}", .{});
        i += 1;
        var cp: u32 = 0;
        var digits: usize = 0;
        while (i < p.end and digits < 7) : (i += 1) {
            const d = std.fmt.charToDigit(p.text[i], 16) catch break;
            cp = cp * 16 + d;
            digits += 1;
        }
        if (digits == 0 or digits > 6 or i >= p.end or p.text[i] != '}') {
            return p.fail(.@"invalid-unicode-escape", at, "invalid unicode escape: expected \\u{{1-6 hex digits}}", .{});
        }
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) {
            return p.fail(.@"invalid-unicode-escape", at, "\\u{{{X}}} is not a Unicode scalar value", .{cp});
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch unreachable;
        try p.chars.appendSlice(p.gpa, buf[0..n]);
        return i + 1;
    }

    /// `"""` … `"""` (spec §4).
    fn blockString(p: *Parser) Error![]const u8 {
        const open = p.pos;
        var i = open + 3;
        while (i < p.end and (p.text[i] == ' ' or p.text[i] == '\t')) i += 1;
        if (i < p.end and p.text[i] == '\n') {
            i += 1;
        } else if (i + 1 < p.end and p.text[i] == '\r' and p.text[i + 1] == '\n') {
            i += 2;
        } else {
            var buf: [16]u8 = undefined;
            return p.fail(.@"block-string-opening", i, "the opening \"\"\" must end its line, found {s}", .{p.found(i, &buf)});
        }
        // The content lines, up to the closing line, checked character by character.
        const Line = struct { start: usize, end: usize };
        var lines: std.ArrayList(Line) = .empty;
        defer lines.deinit(p.gpa);
        var indent: []const u8 = undefined;
        while (true) {
            const line_start = i;
            var j = i;
            while (j < p.end and (p.text[j] == ' ' or p.text[j] == '\t')) j += 1;
            if (p.startsWith(j, "\"\"\"")) {
                indent = p.text[line_start..j];
                i = j + 3;
                break;
            }
            j = line_start;
            while (true) {
                if (j >= p.end) return p.fail(.@"unterminated-block-string", open, "unterminated block string", .{});
                const c = p.text[j];
                if (c == '\n') {
                    try lines.append(p.gpa, .{ .start = line_start, .end = j });
                    i = j + 1;
                    break;
                }
                if (c == '\r' and j + 1 < p.end and p.text[j + 1] == '\n') {
                    try lines.append(p.gpa, .{ .start = line_start, .end = j });
                    i = j + 2;
                    break;
                }
                if (c == '\\') {
                    // An escaped quote or backslash doesn't count toward a closing """.
                    j += 1;
                    if (j < p.end and (p.text[j] == '"' or p.text[j] == '\\')) j += 1;
                    continue;
                }
                if (c == '"' and p.startsWith(j, "\"\"\"")) return p.fail(.@"block-string-closing", j, "the closing \"\"\" must stand on a line of its own", .{});
                j += 1;
            }
        }
        // Then each line: its indent first (an error at the line's start, as
        // the other bindings place it), then its characters and escapes.
        p.chars.clearRetainingCapacity();
        for (lines.items, 0..) |line, k| {
            if (k > 0) try p.chars.append(p.gpa, '\n');
            const text = p.text[line.start..line.end];
            if (!std.mem.startsWith(u8, text, indent)) {
                var m: usize = 0;
                while (m < text.len and (text[m] == ' ' or text[m] == '\t')) m += 1;
                if (m == text.len) continue; // a short blank line is empty
                return p.fail(.@"block-string-indent", line.start, "a block string line is indented less than its closing \"\"\"", .{});
            }
            var j = line.start + indent.len;
            while (j < line.end) {
                if (p.text[j] == '\\') {
                    if (j + 1 >= line.end) return p.fail(.@"invalid-escape", j, "invalid escape: '\\' at the end of a line", .{});
                    j = try p.escape(j);
                    continue;
                }
                const d = v.decode(p.text, j);
                if (v.isControl(d.cp) and d.cp != '\t') return p.fail(.@"control-character", j, "raw control character U+{X:0>4} in a block string: write it as an escape", .{d.cp});
                if (v.isBidi(d.cp)) return p.fail(.@"bidi-control", j, "raw bidirectional control U+{X:0>4} in a block string: write it as an escape", .{d.cp});
                try p.chars.appendSlice(p.gpa, p.text[j .. j + d.len]);
                j += d.len;
            }
        }
        if (v.countCodePoints(p.chars.items) > p.limits.max_string_length) return p.tooLong(.string, open);
        p.pos = i;
        return p.arena.dupe(u8, p.chars.items);
    }

    /// `x"…"`.
    fn bytes(p: *Parser) Error![]const u8 {
        const open = p.pos;
        p.chars.clearRetainingCapacity();
        var i = open + 2;
        while (true) {
            if (i >= p.end) return p.fail(.@"unterminated-bytes", open, "unterminated byte string", .{});
            const c = p.text[i];
            if (c == '"') break;
            if (c == ' ' or c == '\t') {
                i += 1;
                continue;
            }
            const hi = std.fmt.charToDigit(c, 16) catch {
                var buf: [16]u8 = undefined;
                return p.fail(.@"bytes-not-hex", i, "{s} in a byte string (expected hex digits)", .{p.found(i, &buf)});
            };
            if (i + 1 >= p.end) return p.fail(.@"unterminated-bytes", open, "unterminated byte string", .{});
            const lo = std.fmt.charToDigit(p.text[i + 1], 16) catch {
                return p.fail(.@"bytes-odd-digits", i, "a byte needs two hex digits: this one has one", .{});
            };
            try p.chars.append(p.gpa, hi * 16 + lo);
            i += 2;
        }
        if (i - (open + 2) > p.limits.max_string_length) return p.fail(.@"string-too-long", open, "byte string longer than {d} characters", .{p.limits.max_string_length});
        p.pos = i + 1;
        return p.arena.dupe(u8, p.chars.items);
    }
};

test "duplicate keys, whatever their common prefixes" {
    const root = @import("root.zig");
    const gpa = std.testing.allocator;
    const fine = [_][]const u8{
        "{ abc: 1, ab: 2, a: 3, abd: 4, b: 5, \"\": 6, abcd: 7, x: { ab: 1, abc: 2 }, abce: 8 }",
        "{ \"key\\u{20}\": 1, key: 2, \"k\": 3, ke: 4 }",
    };
    for (fine) |text| {
        const parsed = try root.parse(gpa, text, .{});
        parsed.deinit();
    }
    const dups = [_][]const u8{ "{ abc: 1, ab: 2, abc: 3 }", "{ ab: 1, abc: 2, ab: 3 }", "{ a: 1, b: 2, \"a\": 3 }", "{ \"\": 1, \"\": 2 }", "{ abcd: 1, abce: 2, abc: 3, abcd: 4 }" };
    for (dups) |text| {
        var d: Diagnostic = .{};
        try std.testing.expectError(error.Haus, root.parse(gpa, text, .{ .diagnostic = &d }));
        try std.testing.expectEqual(Code.@"duplicate-key", d.code);
    }
}

test "strings: runs, escapes and the length limit" {
    const root = @import("root.zig");
    const gpa = std.testing.allocator;
    const parsed = try root.parse(gpa, "[\"0123456789abcdef0123456789\\n\\u{e9}xyz\", \"caf\u{e9} 0123456789abcdef\", \"\\\"\"]", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("0123456789abcdef0123456789\n\u{e9}xyz", parsed.value.array[0].string);
    try std.testing.expectEqualStrings("caf\u{e9} 0123456789abcdef", parsed.value.array[1].string);
    try std.testing.expectEqualStrings("\"", parsed.value.array[2].string);
    // The limit counts characters exactly, also across runs of sixteen.
    const text = "\"0123456789abcdef0123456789abcdef\"";
    for ([_]u32{ 31, 32, 33 }) |max| {
        var d: Diagnostic = .{};
        const result = root.parse(gpa, text, .{ .limits = .{ .max_string_length = max }, .diagnostic = &d });
        if (max < 32) {
            try std.testing.expectError(error.Haus, result);
            try std.testing.expectEqual(Code.@"string-too-long", d.code);
        } else (try result).deinit();
    }
    // A control character after a run is found where it is.
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Haus, root.parse(gpa, "\"0123456789abcdef01\x01\"", .{ .diagnostic = &d }));
    try std.testing.expectEqual(Code.@"control-character", d.code);
    try std.testing.expectEqual(@as(u32, 20), d.column);
}
