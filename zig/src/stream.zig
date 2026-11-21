//! The stream reader (spec §6, §7): reads a stream from chunks of bytes,
//! giving each value once the comma after it has arrived, with the value
//! limit of §7 and the strict mode of §6. Whatever the chunks, it gives
//! what parsing the whole text gives (with the value limit on top).
//!
//! A light scanner follows the text as it arrives, only to find the
//! top-level commas: it knows strings, block strings, byte strings and
//! comments, and the nesting of brackets. Each part between two commas is
//! then parsed once by the parser, so the reader is linear in the input and
//! reports the parser's errors at the same places as parsing the whole text.
//! The reader belongs to one stream and one thread (spec §9 item 12).

const std = @import("std");
const Allocator = std.mem.Allocator;
const v = @import("value.zig");
const Value = v.Value;
const Limits = v.Limits;
const errors = @import("errors.zig");
const Diagnostic = errors.Diagnostic;
const Error = errors.Error;
const Parser = @import("parser.zig").Parser;

pub const StreamOptions = struct {
    limits: Limits = .{},
    /// Require a comma after the last value (spec §6): `stream-truncated`
    /// otherwise.
    strict: bool = false,
    diagnostic: ?*Diagnostic = null,
};

const State = enum {
    normal,
    slash, // a '/' outside strings and comments
    line_comment,
    block_comment,
    block_comment_star,
    block_comment_slash,
    quote1, // one '"' at the start of a string
    quote2, // two: an empty string or the start of a block string
    string,
    string_escape,
    block,
    block_escape,
    bytes,
};

pub const StreamReader = struct {
    gpa: Allocator,
    options: StreamOptions,
    buf: std.ArrayList(u8) = .empty,
    /// Where the current part (after the last top-level comma) starts.
    seg_start: usize = 0,
    /// How far the bytes are checked as UTF-8 and scanned.
    scanned: usize = 0,
    /// The line and column of `buf[seg_start]`.
    line: u32 = 1,
    column: u32 = 1,
    /// No top-level comma yet: the part is at the start of the stream.
    first: bool = true,
    /// Characters (code points) of the current part, a byte order mark at
    /// the start not counted.
    chars: u64 = 0,
    /// Characters seen since the start of the stream (for the byte order mark).
    seen: u64 = 0,
    state: State = .normal,
    depth: usize = 0,
    comment_depth: usize = 0,
    quotes: u2 = 0,
    /// The previous character outside strings and comments was an `x` that
    /// starts a word (so `"` opens a byte string).
    x_word: bool = false,
    ident: bool = false,
    failed: bool = false,

    pub fn init(gpa: Allocator, options: StreamOptions) Error!StreamReader {
        try @import("root.zig").checkLimits(options.limits, options.diagnostic);
        return .{ .gpa = gpa, .options = options };
    }

    pub fn deinit(r: *StreamReader) void {
        r.buf.deinit(r.gpa);
    }

    fn fail(r: *StreamReader, code: errors.Code, at: usize, comptime fmt: []const u8, args: anytype) Error {
        r.failed = true;
        if (r.options.diagnostic) |d| {
            d.set(code, fmt, args);
            if (code == .@"invalid-utf8") {
                d.line = 0;
                d.column = 0;
                d.offset = 0;
            } else {
                const p = r.parserFor(r.gpa, r.buf.items.len);
                const pos = p.position(at - r.seg_start);
                d.line = pos.line;
                d.column = pos.column;
                d.offset = at;
            }
        }
        return error.Haus;
    }

    fn parserFor(r: *StreamReader, arena: Allocator, until: usize) Parser {
        var p = Parser.init(arena, r.gpa, r.buf.items[r.seg_start..until], r.options.limits, r.options.diagnostic);
        p.base_line = r.line;
        p.base_column = r.column;
        return p;
    }

    /// Reads the next chunk; returns the values it completed, allocated
    /// with `arena`.
    pub fn push(r: *StreamReader, arena: Allocator, chunk: []const u8) Error![]const Value {
        if (r.failed) return error.Haus;
        // Drop the parts already read.
        if (r.seg_start > 0) {
            const rest = r.buf.items.len - r.seg_start;
            std.mem.copyForwards(u8, r.buf.items[0..rest], r.buf.items[r.seg_start..]);
            r.buf.shrinkRetainingCapacity(rest);
            r.scanned -= r.seg_start;
            r.seg_start = 0;
        }
        try r.buf.appendSlice(r.gpa, chunk);
        var out: std.ArrayList(Value) = .empty;
        errdefer out.deinit(arena);
        while (r.scanned < r.buf.items.len) {
            const at = r.scanned;
            const len = std.unicode.utf8ByteSequenceLength(r.buf.items[at]) catch return r.fail(.@"invalid-utf8", at, "invalid UTF-8", .{});
            if (at + len > r.buf.items.len) {
                // An incomplete sequence: wait for the rest, unless it is already wrong.
                if (!prefixValid(r.buf.items[at..])) return r.fail(.@"invalid-utf8", at, "invalid UTF-8", .{});
                break;
            }
            const cp = std.unicode.utf8Decode(r.buf.items[at .. at + len]) catch return r.fail(.@"invalid-utf8", at, "invalid UTF-8", .{});
            r.scanned += len;
            if (r.seen == 0 and r.first and cp == 0xFEFF) {
                r.seen += 1;
                continue;
            }
            r.seen += 1;
            if (r.scan(cp)) {
                // A top-level comma: the part before it holds one value.
                if (try r.part(arena, at, true)) |val| try out.append(arena, val);
                r.advance(at + 1);
                continue;
            }
            r.chars += 1;
            if (r.chars > r.options.limits.max_value_length) {
                return r.fail(.@"value-too-long", at, "a value longer than {d} characters", .{r.options.limits.max_value_length});
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// Ends the stream: returns the last value, if there is one after the
    /// last comma.
    pub fn end(r: *StreamReader, arena: Allocator) Error!?Value {
        if (r.failed) return error.Haus;
        if (r.scanned < r.buf.items.len) return r.fail(.@"invalid-utf8", r.scanned, "invalid UTF-8: the stream ends inside a character", .{});
        const last = try r.part(arena, r.buf.items.len, false);
        if (last != null and r.options.strict) {
            return r.fail(.@"stream-truncated", r.buf.items.len, "the stream ends without a comma after its last value: it may be cut off", .{});
        }
        r.failed = true; // nothing more to read
        return last;
    }

    /// Parses the current part, up to `end`.
    fn part(r: *StreamReader, arena: Allocator, end_at: usize, comma_after: bool) Error!?Value {
        var p = r.parserFor(arena, end_at);
        defer p.deinit();
        return p.parseSegment(r.first, comma_after) catch |e| {
            r.failed = true;
            return e;
        };
    }

    /// Starts the next part at `next` (after a comma).
    fn advance(r: *StreamReader, next: usize) void {
        for (r.buf.items[r.seg_start..next]) |c| {
            if (c == '\n') {
                r.line += 1;
                r.column = 1;
            } else if ((c & 0xC0) != 0x80) {
                r.column += 1;
            }
        }
        r.seg_start = next;
        r.first = false;
        r.chars = 0;
    }

    /// Follows one character; true for a top-level comma.
    fn scan(r: *StreamReader, cp: u21) bool {
        switch (r.state) {
            .normal => return r.normal(cp),
            .slash => {
                if (cp == '/') {
                    r.state = .line_comment;
                } else if (cp == '*') {
                    r.state = .block_comment;
                    r.comment_depth = 1;
                } else {
                    r.state = .normal;
                    return r.normal(cp);
                }
            },
            .line_comment => if (cp == '\n') {
                r.state = .normal;
            },
            .block_comment => {
                if (cp == '*') r.state = .block_comment_star else if (cp == '/') r.state = .block_comment_slash;
            },
            .block_comment_star => {
                if (cp == '/') {
                    r.comment_depth -= 1;
                    r.state = if (r.comment_depth == 0) .normal else .block_comment;
                } else if (cp != '*') {
                    r.state = if (cp == '/') .block_comment_slash else .block_comment;
                }
            },
            .block_comment_slash => {
                if (cp == '*') {
                    r.comment_depth += 1;
                    r.state = .block_comment;
                } else if (cp != '/') {
                    r.state = .block_comment;
                }
            },
            .quote1 => {
                if (cp == '"') {
                    r.state = .quote2;
                } else {
                    r.state = .string;
                    _ = r.scan(cp);
                }
            },
            .quote2 => {
                if (cp == '"') {
                    r.state = .block;
                    r.quotes = 0;
                } else {
                    // The empty string "".
                    r.state = .normal;
                    return r.normal(cp);
                }
            },
            .string => {
                if (cp == '\\') r.state = .string_escape else if (cp == '"') r.state = .normal;
            },
            .string_escape => r.state = .string,
            .block => {
                if (cp == '\\') {
                    r.state = .block_escape;
                    r.quotes = 0;
                } else if (cp == '"') {
                    r.quotes += 1;
                    if (r.quotes == 3) {
                        r.state = .normal;
                        r.quotes = 0;
                    }
                } else r.quotes = 0;
            },
            .block_escape => r.state = .block,
            .bytes => if (cp == '"') {
                r.state = .normal;
            },
        }
        return false;
    }

    fn normal(r: *StreamReader, cp: u21) bool {
        const was_x = r.x_word;
        const was_ident = r.ident;
        r.x_word = false;
        r.ident = cp < 0x80 and v.isIdentChar(@intCast(cp));
        if (cp == 'x' and !was_ident) r.x_word = true;
        switch (cp) {
            ',' => return r.depth == 0,
            '{', '[', '(' => r.depth += 1,
            '}', ']', ')' => r.depth -|= 1,
            '/' => r.state = .slash,
            '"' => r.state = if (was_x) .bytes else .quote1,
            else => {},
        }
        return false;
    }
};

/// Whether the bytes could start a valid UTF-8 sequence (more to come).
fn prefixValid(s: []const u8) bool {
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return false;
    var buf: [4]u8 = undefined;
    @memcpy(buf[0..s.len], s);
    // Complete it with the smallest continuation bytes that could follow,
    // then check: overlong forms and surrogates show in the first two bytes.
    var i = s.len;
    while (i < len) : (i += 1) buf[i] = 0x80;
    if (s.len >= 2) {
        _ = std.unicode.utf8Decode(buf[0..len]) catch {
            // 0x80 might be too small for E0/F0 or too large for ED/F4:
            // try the largest continuation byte as well.
            i = s.len;
            while (i < len) : (i += 1) buf[i] = 0xBF;
            _ = std.unicode.utf8Decode(buf[0..len]) catch return false;
            return true;
        };
        return true;
    }
    return true;
}

fn readAll(gpa: Allocator, arena: Allocator, text: []const u8, size: usize, options: StreamOptions) Error![]const Value {
    var r = try StreamReader.init(gpa, options);
    defer r.deinit();
    var out: std.ArrayList(Value) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        const n = @min(size, text.len - at);
        try out.appendSlice(arena, try r.push(arena, text[at .. at + n]));
        at += n;
    }
    if (try r.end(arena)) |last| try out.append(arena, last);
    return out.items;
}

test "chunks don't matter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "\u{FEFF}{ a: \"x,y\" }, /* , */ [1, 2], \"\"\"\n  a,\"\"\n  \"\"\", x\"00 ff\", Tag(1, 2), \"\", // c, d\n3,";
    for ([_]usize{ 1, 2, 3, 5, 64 }) |size| {
        const vals = try readAll(std.testing.allocator, arena, text, size, .{});
        try std.testing.expectEqual(@as(usize, 7), vals.len);
    }
}

test "errors at the same place as parsing the whole text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Haus, readAll(std.testing.allocator, arena, "1,\n [1 2]", 1, .{ .diagnostic = &d }));
    try std.testing.expectEqual(errors.Code.@"missing-comma", d.code);
    try std.testing.expectEqual(@as(u32, 2), d.line);
    try std.testing.expectEqual(@as(u32, 5), d.column);
    try std.testing.expectError(error.Haus, readAll(std.testing.allocator, arena, "1, 2", 2, .{ .strict = true, .diagnostic = &d }));
    try std.testing.expectEqual(errors.Code.@"stream-truncated", d.code);
}
