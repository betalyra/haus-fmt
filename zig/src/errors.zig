//! Error codes (spec §17) and the diagnostic every failing call fills in.

const std = @import("std");

/// The codes of the catalogue (spec/errors.md) that the data format reports:
/// syntax, limits and streams, plus the ones a value built in code can hit
/// when it is written. The tag name is the code: `@tagName(code)`.
pub const Code = enum {
    // Syntax
    @"invalid-utf8",
    @"version-directive",
    @"expected-value",
    @"missing-comma",
    @"payload-newline",
    @"unexpected-closer",
    @"unclosed-bracket",
    @"null-literal",
    @"boolean-literal",
    @"bare-identifier",
    @"expected-key",
    @"uppercase-key",
    @"block-string-key",
    @"missing-colon",
    @"duplicate-key",
    @"empty-payload",
    @"invalid-number",
    @"unterminated-string",
    @"string-line-break",
    @"control-character",
    @"bidi-control",
    @"invalid-escape",
    @"invalid-unicode-escape",
    @"block-string-opening",
    @"block-string-closing",
    @"block-string-indent",
    @"unterminated-block-string",
    @"unterminated-bytes",
    @"bytes-not-hex",
    @"bytes-odd-digits",
    @"lone-carriage-return",
    @"unterminated-comment",
    @"stray-slash",
    // Limits
    @"nesting-too-deep",
    @"number-too-long",
    @"exponent-too-large",
    @"string-too-long",
    @"key-too-long",
    @"tag-too-long",
    @"value-too-long",
    @"unsupported-depth",
    // Streams
    @"not-one-value",
    @"stream-truncated",
    // Values built in code
    @"invalid-tag",
    @"too-many-nodes",
    // Schema files (§14)
    @"schema-syntax",
    @"unknown-type",
    @"wrong-arity",
    @"duplicate-type",
    @"redefine-prelude",
    @"unknown-parameter",
    @"invalid-parameter",
    @"underscore-type",
    @"duplicate-field",
    @"duplicate-tag",
    @"closed-empty-variant",
    @"invalid-spread",
    @"spread-cycle",
    @"row-parameter",
    @"misplaced-stream",
    @"unguarded-recursion",
    @"growing-recursion",
    @"type-too-deep",
    @"attribute-arguments",
    @"attribute-twice",
    @"attribute-space",
    @"attribute-on-spread",
    // Imports (§13.3)
    @"unknown-module",
    @"unknown-import",
    @"duplicate-import",
    @"import-unavailable",
    @"import-not-found",
    @"import-version",
    @"import-cycle",
    @"duplicate-package",
    @"undeclared-package",
    @"package-manifest",
    @"package-version",
    @"package-path",
    @"package-name",
    @"package-crate",
    @"package-install-script",
    @"package-files",
    @"profile-vectors",
    @"package-wrapper",
    @"codec-unreachable",
    @"file-too-large",
    @"too-many-files",
    // Decoding and encoding (§15)
    @"type-mismatch",
    @"not-an-integer",
    @"out-of-range",
    @"missing-field",
    @"unknown-field",
    @"unknown-tag",
    @"wrong-payload",
    @"invalid-time",
    @"invalid-secret",
    @"codec-rejected",
    @"cannot-encode",
    @"cyclic-value",
    @"step-budget",
    // JSON (§16)
    @"json-syntax",
    @"unpaired-surrogate",
    @"haus-json-form",
    @"haus-json-version",
    @"haus-json-number",
    @"haus-json-bytes",
    @"invalid-base64",
    @"missing-member",
    @"unexpected-member",
    @"no-json-form",
    // Hints and warnings (§14)
    @"unknown-attribute",
    deprecated,
    @"unlisted-field",
    @"unlisted-tag",

    pub fn name(code: Code) []const u8 {
        return @tagName(code);
    }
};

/// Every fallible call returns one of these. `Haus` means a mistake with a
/// code: the diagnostic passed to the call says which, and where.
pub const Error = error{ Haus, OutOfMemory };

/// What went wrong: the code of spec §17, the 1-based line and column of
/// spec §8 (0 and 0 where there is no position: invalid UTF-8 in a whole
/// text, a value built in code), and a message for people. The message is
/// kept in the struct, so filling it in never allocates.
pub const Diagnostic = struct {
    code: Code = .@"expected-value",
    line: u32 = 0,
    column: u32 = 0,
    /// Byte offset of the error in the text (0 where there is no position).
    offset: usize = 0,
    message_buf: [160]u8 = undefined,
    message_len: usize = 0,
    /// The place in a value (spec §15), for an error of a decoder or a
    /// JSON reader: `$.items[2].price`. Empty for an error in text.
    path_buf: [path_capacity]u8 = undefined,
    path_len: usize = 0,

    pub const path_capacity = 4096;

    pub fn path(d: *const Diagnostic) []const u8 {
        return d.path_buf[0..d.path_len];
    }

    pub fn setPath(d: *Diagnostic, p: []const u8) void {
        const n = @min(p.len, path_capacity);
        @memcpy(d.path_buf[0..n], p[0..n]);
        d.path_len = n;
    }

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.message_buf[0..d.message_len];
    }

    /// Sets the code and message (formatted, cut to the buffer). The
    /// position is set separately.
    pub fn set(d: *Diagnostic, code: Code, comptime fmt: []const u8, args: anytype) void {
        d.code = code;
        d.path_len = 0;
        const out = std.fmt.bufPrint(&d.message_buf, fmt, args) catch blk: {
            // Too long: cut, and mark the cut.
            const cut = "…";
            const keep = d.message_buf.len - cut.len;
            var w = std.Io.Writer.fixed(d.message_buf[0..keep]);
            w.print(fmt, args) catch {};
            var n = w.end;
            // Don't cut a UTF-8 sequence in half.
            while (n > 0 and n < keep and (d.message_buf[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(d.message_buf[n .. n + cut.len], cut);
            break :blk d.message_buf[0 .. n + cut.len];
        };
        d.message_len = out.len;
    }

    /// Writes the error as `code line:column message`.
    pub fn format(d: *const Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {d}:{d} {s}", .{ @tagName(d.code), d.line, d.column, d.message() });
    }
};

/// Writes `cp` for a message, as spec §9 item 2 asks of quoted text: control
/// and bidi characters (and U+2028, U+2029) escaped, everything else as itself.
pub fn quoteChar(buf: []u8, cp: u21) []const u8 {
    if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x2066 and cp <= 0x2069) or cp == 0x2028 or cp == 0x2029 or cp == 0xFEFF)
    {
        return std.fmt.bufPrint(buf, "U+{X:0>4}", .{cp}) catch unreachable;
    }
    const n = std.unicode.utf8Encode(cp, buf[1..5]) catch unreachable;
    buf[0] = '\'';
    buf[n + 1] = '\'';
    return buf[0 .. n + 2];
}

/// Writes a token quoted from the input for a message: escaped like
/// `quoteChar` and at most 40 characters as shown, a cut marked with `…`
/// within those 40 (spec §9 item 2).
pub fn quoteText(buf: []u8, text: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var shown: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    w.writeByte('\'') catch return buf[0..0];
    while (it.nextCodepoint()) |cp| {
        var tmp: [12]u8 = undefined;
        const piece: []const u8 = if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or (cp >= 0x202A and cp <= 0x202E) or
            (cp >= 0x2066 and cp <= 0x2069) or cp == 0x2028 or cp == 0x2029)
            std.fmt.bufPrint(&tmp, "\\u{{{X}}}", .{cp}) catch unreachable
        else blk: {
            const n = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
            break :blk tmp[0..n];
        };
        const width = std.unicode.utf8CountCodepoints(piece) catch piece.len;
        // Leave room for the cut mark within the 40.
        if (shown + width > 39) {
            w.writeAll("…") catch {};
            break;
        }
        w.writeAll(piece) catch break;
        shown += width;
    }
    w.writeByte('\'') catch {};
    return w.buffered();
}

test "quoteText cuts at 40 characters" {
    var buf: [256]u8 = undefined;
    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const q = quoteText(&buf, long);
    // 39 'a', the cut mark, and the quotes.
    try std.testing.expectEqual(@as(usize, 39 + "…".len + 2), q.len);
    try std.testing.expectEqualStrings("'a\\u{1B}b'", quoteText(&buf, "a\x1bb"));
}
