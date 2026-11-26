//! The Zig runner of the differential fuzzer (fuzz/README.md):
//!
//!   zig-runner DIR N                 parse each DIR/00000.haus …: `ok <values>` or `err LINE COLUMN CODE REASON`
//!   zig-runner --stream DIR N        the same through the stream reader, in chunks of 1, 2, 3, 5, 8, 13, 64 bytes
//!   zig-runner --canonical DIR N     `ok ["<canonical form>", …]`
//!   zig-runner --format STYLE --indent N --width N DIR N   `ok "<formatted text>"` or `err LINE COLUMN CODE REASON`
//!   zig-runner --write STYLE --indent N --width N DIR N    `ok {"values": […], "file": "…"}` or `err LINE COLUMN CODE REASON`
//!   (with `--stream` too: formatted and written with the stream option of spec §11; `"file"` stays the key)
//!   A writer's error has no place in text: `err 0 0 CODE REASON`.
//!   zig-runner --schema FILE | --schema-check FILE | --time FILE | --json MODE FILE   (fuzz_schema.zig)
//!
//! Values are printed in the suite's JSON encoding with the keys the
//! fuzzer's in-process runner uses (`num`, `bytes`, `rec`, `tag`, `args`).

const std = @import("std");
const haus = @import("haus");
const Value = haus.Value;
const Allocator = std.mem.Allocator;

const fuzz_schema = @import("fuzz_schema.zig");

const Mode = enum { parse, stream, canonical, format, write };

fn jsonString(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try out.print("\\u{x:0>4}", .{c}),
        else => try out.writeByte(c),
    };
    try out.writeByte('"');
}

fn jsonValue(out: *std.Io.Writer, val: Value) !void {
    switch (val) {
        .number => |n| {
            try out.writeAll("{\"num\":");
            try jsonString(out, n);
            try out.writeByte('}');
        },
        .string => |s| try jsonString(out, s),
        .bytes => |b| {
            try out.writeAll("{\"bytes\":\"");
            for (b) |byte| try out.print("{x:0>2}", .{byte});
            try out.writeAll("\"}");
        },
        .array => |items| {
            try out.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.writeByte(',');
                try jsonValue(out, item);
            }
            try out.writeByte(']');
        },
        .record => |fields| {
            try out.writeAll("{\"rec\":{");
            for (fields, 0..) |f, i| {
                if (i > 0) try out.writeByte(',');
                try jsonString(out, f.key);
                try out.writeByte(':');
                try jsonValue(out, f.value);
            }
            try out.writeAll("}}");
        },
        .variant => |x| {
            try out.writeAll("{\"tag\":");
            try jsonString(out, x.tag);
            if (x.args.len > 0) {
                try out.writeAll(",\"args\":[");
                for (x.args, 0..) |a, i| {
                    if (i > 0) try out.writeByte(',');
                    try jsonValue(out, a);
                }
                try out.writeByte(']');
            }
            try out.writeByte('}');
        },
    }
}

fn reason(out: *std.Io.Writer, d: *const haus.Diagnostic) !void {
    for (d.message()) |c| try out.writeByte(if (c == '\n' or c == '\r') ' ' else c);
}

fn errLine(out: *std.Io.Writer, d: *const haus.Diagnostic) !void {
    try out.print("err {d} {d} {s} ", .{ d.line, d.column, d.code.name() });
    try reason(out, d);
    try out.writeByte('\n');
}

const sizes = [_]usize{ 1, 2, 3, 5, 8, 13, 64 };

fn streamValues(arena: Allocator, gpa: Allocator, bytes: []const u8, case: usize, d: *haus.Diagnostic) ![]const Value {
    var r = try haus.StreamReader.init(gpa, .{ .diagnostic = d });
    defer r.deinit();
    var vals: std.ArrayList(Value) = .empty;
    var at: usize = 0;
    var k: usize = 0;
    while (at < bytes.len) : (k += 1) {
        const end = @min(bytes.len, at + sizes[(case + k) % sizes.len]);
        try vals.appendSlice(arena, try r.push(arena, bytes[at..end]));
        at = end;
    }
    if (try r.end(arena)) |last| try vals.append(arena, last);
    return vals.items;
}

fn runCase(arena: Allocator, gpa: Allocator, out: *std.Io.Writer, mode: Mode, bytes: []const u8, case: usize, options: haus.FormatOptions) !void {
    var d: haus.Diagnostic = .{};
    switch (mode) {
        .parse, .stream, .canonical => {
            const vals: []const Value = if (mode == .stream)
                streamValues(arena, gpa, bytes, case, &d) catch |e| switch (e) {
                    error.Haus => return errLine(out, &d),
                    else => return e,
                }
            else if (haus.parseAll(arena, bytes, .{ .diagnostic = &d })) |p| p.value else |e| switch (e) {
                error.Haus => return errLine(out, &d),
                else => return e,
            };
            try out.writeAll("ok [");
            for (vals, 0..) |val, i| {
                if (i > 0) try out.writeByte(',');
                if (mode == .canonical) {
                    const c = haus.canonical(arena, val, .{ .diagnostic = &d }) catch |e| switch (e) {
                        error.Haus => return errLine(out, &d),
                        else => return e,
                    };
                    try jsonString(out, c);
                } else try jsonValue(out, val);
            }
            try out.writeAll("]\n");
        },
        .format => {
            var o = options;
            o.write.diagnostic = &d;
            const text = haus.format(arena, bytes, o) catch |e| switch (e) {
                error.Haus => return errLine(out, &d),
                else => return e,
            };
            try out.writeAll("ok ");
            try jsonString(out, text);
            try out.writeByte('\n');
        },
        .write => {
            var o = options;
            o.write.diagnostic = &d;
            const vals = if (haus.parseAll(arena, bytes, .{ .diagnostic = &d })) |p| p.value else |e| switch (e) {
                error.Haus => return errLine(out, &d),
                else => return e,
            };
            var line: std.Io.Writer.Allocating = .init(arena);
            const lw = &line.writer;
            try lw.writeAll("ok {\"values\":[");
            for (vals, 0..) |val, i| {
                if (i > 0) try lw.writeByte(',');
                // A writer's error has no place in text: `0 0`.
                const text = haus.stringify(arena, val, o) catch |e| switch (e) {
                    error.Haus => return errLine(out, &d),
                    else => return e,
                };
                try jsonString(lw, text);
            }
            // `"file"` is `stringifyAll`; with `--stream`, with the stream
            // option (spec §11): a comma after every value, a single one too.
            try lw.writeAll("],\"file\":");
            const file = haus.stringifyAll(arena, vals, o) catch |e| switch (e) {
                error.Haus => return errLine(out, &d),
                else => return e,
            };
            try jsonString(lw, file);
            try lw.writeAll("}\n");
            try out.writeAll(line.written());
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3) {
        if (std.meta.stringToEnum(fuzz_schema.FileMode, if (args[1].len > 2) args[1][2..] else "")) |m| {
            if (std.mem.startsWith(u8, args[1], "--")) return fuzz_schema.run(io, gpa, m, args[2]);
        }
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "--json")) return fuzz_schema.runJson(io, gpa, args[2], args[3]);
    var mode: Mode = .parse;
    var options: haus.FormatOptions = .{};
    var stream = false;
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--stream")) {
            stream = true;
        } else if (std.mem.eql(u8, a, "--canonical")) {
            mode = .canonical;
        } else if (std.mem.eql(u8, a, "--format") or std.mem.eql(u8, a, "--write")) {
            mode = if (std.mem.eql(u8, a, "--format")) .format else .write;
            i += 1;
            options.layout = std.meta.stringToEnum(haus.Layout, args[i]) orelse return error.UnknownLayout;
        } else if (std.mem.eql(u8, a, "--indent")) {
            i += 1;
            options.indent = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--width")) {
            i += 1;
            options.width = try std.fmt.parseInt(u32, args[i], 10);
        } else try positional.append(init.arena.allocator(), a);
    }
    // `--stream` alone reads through the stream reader; with `--format` or
    // `--write` it is the formatter's and the writer's stream option.
    if (stream) switch (mode) {
        .format, .write => options.stream = true,
        .parse => mode = .stream,
        else => {},
    };
    if (positional.items.len != 2) {
        std.debug.print("usage: zig-runner [--stream] [--canonical | --format STYLE | --write STYLE] [--indent N] [--width N] DIR N\n", .{});
        std.process.exit(2);
    }
    const dir_path = positional.items[0];
    const n = try std.fmt.parseInt(usize, positional.items[1], 10);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var buf: [1 << 16]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;
    for (0..n) |case| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var name: [16]u8 = undefined;
        const file = try std.fmt.bufPrint(&name, "{d:0>5}.haus", .{case});
        const bytes = try dir.readFileAlloc(io, file, arena, .unlimited);
        try runCase(arena, gpa, out, mode, bytes, case, options);
    }
    try out.flush();
}
