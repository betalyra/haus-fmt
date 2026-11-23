//! The quickstart: data checked by its schema, decoding, encoding and
//! errors. The same steps as go/examples/quickstart and
//! rust/examples/quickstart, on the same files (../../examples).
//! Run: `zig build quickstart` (from zig/); `zig build examples` runs every
//! example and checks its output.

const std = @import("std");
const haus = @import("haus");
const paths = @import("paths");
const Decoded = haus.Decoded;
const Allocator = std.mem.Allocator;

const reply =
    \\Comment { author: "me", at: Instant("2026-11-16T09:00:00Z"), text: "+1", likes: 0, replies: [] }
;

/// The record of a `Comment { … }`, which the schema checked.
fn comment(d: Decoded) Decoded {
    return d.variant.args[0];
}

fn likes(d: Decoded) !i64 {
    var n = try std.fmt.parseInt(i64, comment(d).get("likes").?.int, 10);
    for (comment(d).get("replies").?.array) |r| n += try likes(r);
    return n;
}

fn depth(d: Decoded) usize {
    var deepest: usize = 0;
    for (comment(d).get("replies").?.array) |r| deepest = @max(deepest, depth(r));
    return 1 + deepest;
}

/// An error as `$.likes: … [type-mismatch]`.
fn printError(out: *std.Io.Writer, d: *const haus.Diagnostic) !void {
    try out.print("error: {s}: {s} [{s}]\n", .{ d.path(), d.message(), d.code.name() });
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

    // The schema file, with what it imports (std/time here).
    const schema_path = try std.fs.path.join(arena, &.{ paths.examples_dir, "thread.schema.haus" });
    const build = try haus.packages.build(gpa, io, schema_path, .{});
    defer build.deinit();
    const root = build.root.get("Root").?;
    const comment_type = build.root.get("Comment").?;

    // 1. The thread, checked with its schema: Root is a Comment, whose replies are Comments.
    const text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ paths.examples_dir, "thread.haus" }), arena, .unlimited);
    const thread = try haus.decoding.decodeText(gpa, arena, root, text, .{});
    try out.print("thread by {s}: {d} levels, {d} likes\n", .{ comment(thread).get("author").?.string, depth(thread), try likes(thread) });

    // 2. Decode haus text with the schema, change it, encode it back.
    const decoded = try haus.decoding.decodeText(gpa, arena, comment_type, reply, .{});
    const fields = try arena.dupe(Decoded.Entry, comment(decoded).record);
    for (fields) |*f| if (std.mem.eql(u8, f.key, "likes")) {
        const n = try std.fmt.parseInt(i64, f.value.int, 10);
        f.value = .{ .int = try std.fmt.allocPrint(arena, "{d}", .{n + 1}) };
    };
    const liked: Decoded = .{ .variant = .{ .tag = "Comment", .args = &.{.{ .record = fields }} } };
    const encoded = try haus.decoding.encode(arena, comment_type, liked, .{});
    try out.print("{s}\n", .{try haus.stringify(arena, encoded, .{ .layout = .compact })});

    // 3. A value that doesn't match the schema is an error that says where.
    const lots = try std.mem.replaceOwned(u8, arena, reply, "likes: 0", "likes: \"lots\"");
    var d: haus.Diagnostic = .{};
    if (haus.decoding.decodeText(gpa, arena, comment_type, lots, .{ .diagnostic = &d })) |_| {
        try out.print("accepted\n", .{});
    } else |e| switch (e) {
        error.Haus => try printError(out, &d),
        else => return e,
    }
    try out.flush();
}
