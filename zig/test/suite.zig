//! The conformance suite (test-suite/README.md), run with `zig build suite`.
//! Each test reads its files from ../test-suite, runs every case and
//! prints how many passed; a failing case is printed and fails the test.

const std = @import("std");
const haus = @import("haus");
const build_options = @import("build_options");
const Value = haus.Value;
const Allocator = std.mem.Allocator;

var io: std.Io = undefined;
var gpa: Allocator = undefined;
var suite_dir: []const u8 = build_options.suite_dir;
var failures: usize = 0;
var stdout: *std.Io.Writer = undefined;

// ── helpers ──────────────────────────────────────────────────

fn suitePath(arena: Allocator, sub: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ suite_dir, sub });
}

fn readFile(arena: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
}

/// The names of the files in `dir` ending in `ext`, sorted, without it.
fn listFiles(arena: Allocator, dir_path: []const u8, ext: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ext)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - ext.len]));
    }
    std.sort.pdq([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return names.items;
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A record's field.
fn get(val: Value, key: []const u8) ?Value {
    if (val != .record) return null;
    for (val.record) |f| if (std.mem.eql(u8, f.key, key)) return f.value;
    return null;
}

fn canon(arena: Allocator, val: Value) ![]const u8 {
    return haus.canonical(arena, val, .{});
}

/// Reads a cases file (a stream of records) with the binding's own parser.
fn readCases(arena: Allocator, sub: []const u8) ![]const Value {
    const text = try readFile(arena, try suitePath(arena, sub));
    var d: haus.Diagnostic = .{};
    const parsed = haus.parseAll(arena, text, .{ .diagnostic = &d }) catch |e| {
        try stdout.print("{s}: {f}\n", .{ sub, d });
        return e;
    };
    return parsed.value;
}

const Tally = struct {
    name: []const u8,
    passed: usize = 0,
    failed: usize = 0,

    fn check(t: *Tally, ok: bool, comptime fmt: []const u8, args: anytype) void {
        if (ok) {
            t.passed += 1;
        } else {
            t.failed += 1;
            stdout.print("FAIL {s}: " ++ fmt ++ "\n", .{t.name} ++ args) catch {};
        }
    }

    fn report(t: *const Tally) !void {
        try stdout.print("{s}: {d} passed, {d} failed\n", .{ t.name, t.passed, t.failed });
        failures += t.failed;
    }
};

// ── self-describing JSON of the expected files (test-suite/README.md) ──

fn fromJson(arena: Allocator, j: std.json.Value) !Value {
    switch (j) {
        .string => |s| return .{ .string = s },
        .array => |items| {
            const out = try arena.alloc(Value, items.items.len);
            for (items.items, 0..) |item, i| out[i] = try fromJson(arena, item);
            return .{ .array = out };
        },
        .object => |o| {
            if (o.get("_num")) |n| return .{ .number = n.string };
            if (o.get("_bytes")) |b| {
                const out = try arena.alloc(u8, b.string.len / 2);
                _ = try std.fmt.hexToBytes(out, b.string);
                return .{ .bytes = out };
            }
            if (o.get("_rec")) |r| {
                const fields = try arena.alloc(haus.Field, r.object.count());
                var it = r.object.iterator();
                var i: usize = 0;
                while (it.next()) |e| : (i += 1) fields[i] = .{ .key = e.key_ptr.*, .value = try fromJson(arena, e.value_ptr.*) };
                return .{ .record = fields };
            }
            if (o.get("_tag")) |t| {
                var args: []const Value = &.{};
                if (o.get("_args")) |a| args = (try fromJson(arena, a)).array;
                return .{ .variant = .{ .tag = t.string, .args = args } };
            }
            return error.BadJson;
        },
        else => return error.BadJson,
    }
}

fn hexDigest(h: [64]u8) [64]u8 {
    return h;
}

// ── valid/ and invalid/ ──────────────────────────────────────

fn validSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try suitePath(arena, "valid");
    var values = Tally{ .name = "valid/*.jsonl" };
    var canonicals = Tally{ .name = "valid/*.canonical" };
    var hashes = Tally{ .name = "valid/*.hash" };
    for (try listFiles(arena, dir, ".haus")) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        const text = try readFile(arena, try std.fmt.allocPrint(arena, "{s}.haus", .{path}));
        var d: haus.Diagnostic = .{};
        const parsed = haus.parseAll(arena, text, .{ .diagnostic = &d }) catch {
            values.check(false, "{s} rejected: {f}", .{ name, d });
            continue;
        };
        const vals = parsed.value;

        // .jsonl: one envelope per value.
        const jsonl = try readFile(arena, try std.fmt.allocPrint(arena, "{s}.jsonl", .{path}));
        var expected: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, jsonl, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const j = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{ .max_value_len = std.math.maxInt(usize) });
            try expected.append(arena, try canon(arena, try fromJson(arena, j.object.get("_value").?)));
        }
        var same = expected.items.len == vals.len;
        if (same) for (vals, expected.items) |val, e| {
            if (!std.mem.eql(u8, try canon(arena, val), e)) same = false;
        };
        values.check(same, "{s}: values differ from the .jsonl", .{name});

        // .canonical: one line per value.
        const want = try readFile(arena, try std.fmt.allocPrint(arena, "{s}.canonical", .{path}));
        var got: std.ArrayList(u8) = .empty;
        for (vals) |val| {
            try got.appendSlice(arena, try canon(arena, val));
            try got.append(arena, '\n');
        }
        canonicals.check(std.mem.eql(u8, got.items, want), "{s}: canonical\n  got  {s}\n  want {s}", .{ name, got.items, want });

        // .hash: hashAll and a line break.
        const want_hash = try readFile(arena, try std.fmt.allocPrint(arena, "{s}.hash", .{path}));
        const h = try haus.hashAll(arena, vals, .{});
        hashes.check(std.mem.eql(u8, std.mem.trimEnd(u8, want_hash, "\n"), &h) and std.mem.endsWith(u8, want_hash, "\n"), "{s}: hash {s}, want {s}", .{ name, &h, want_hash });
        if (vals.len == 1) {
            const one = try haus.hash(arena, vals[0], .{});
            hashes.check(std.mem.eql(u8, &one, &h), "{s}: hash(v) != hashAll([v])", .{name});
        }
    }
    try values.report();
    try canonicals.report();
    try hashes.report();
}

fn invalidSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try suitePath(arena, "invalid");
    var tally = Tally{ .name = "invalid/*.error" };
    for (try listFiles(arena, dir, ".haus")) |name| {
        const text = try readFile(arena, try std.fmt.allocPrint(arena, "{s}/{s}.haus", .{ dir, name }));
        const want = std.mem.trimEnd(u8, try readFile(arena, try std.fmt.allocPrint(arena, "{s}/{s}.error", .{ dir, name })), "\n");
        var d: haus.Diagnostic = .{};
        if (haus.parseAll(arena, text, .{ .diagnostic = &d })) |_| {
            tally.check(false, "{s}: accepted, want {s}", .{ name, want });
        } else |_| {
            tally.check(std.mem.eql(u8, d.code.name(), want), "{s}: {f}, want {s}", .{ name, d, want });
        }
    }
    try tally.report();
}

// ── positions, equality, documents ───────────────────────────

fn positionsSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tally = Tally{ .name = "positions/cases.haus" };
    for (try readCases(arena, "positions/cases.haus")) |case| {
        const text = get(case, "text").?.string;
        const code = get(case, "code").?.string;
        const line = try std.fmt.parseInt(u32, get(case, "line").?.number, 10);
        const column = try std.fmt.parseInt(u32, get(case, "column").?.number, 10);
        var d: haus.Diagnostic = .{};
        if (haus.parseAll(arena, text, .{ .diagnostic = &d })) |_| {
            tally.check(false, "{any}: accepted", .{text});
        } else |_| {
            tally.check(std.mem.eql(u8, d.code.name(), code) and d.line == line and d.column == column, "{any}: {f}, want {s} {d}:{d}", .{ text, d, code, line, column });
        }
    }
    try tally.report();
}

fn equalitySuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tally = Tally{ .name = "equality/cases.haus" };
    for (try readCases(arena, "equality/cases.haus")) |case| {
        const a = get(case, "a").?;
        const b = get(case, "b").?;
        const equal = std.mem.eql(u8, get(case, "equal").?.variant.tag, "True");
        const order = try std.fmt.parseInt(i32, get(case, "order").?.number, 10);
        const ab = try haus.compare(arena, a, b, .{});
        const ba = try haus.compare(arena, b, a, .{});
        const sign = struct {
            fn of(o: std.math.Order) i32 {
                return switch (o) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                };
            }
        }.of;
        tally.check(try haus.equals(arena, a, b, .{}) == equal and try haus.equals(arena, b, a, .{}) == equal and
            sign(ab) == order and sign(ba) == -order, "{s} vs {s}", .{ try canon(arena, a), try canon(arena, b) });
    }
    try tally.report();
}

fn documentSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tally = Tally{ .name = "stream/document.cases.haus" };
    for (try readCases(arena, "stream/document.cases.haus")) |case| {
        const text = get(case, "text").?.string;
        const result = get(case, "result").?.variant;
        var d: haus.Diagnostic = .{};
        const got = haus.parse(arena, text, .{ .diagnostic = &d });
        if (std.mem.eql(u8, result.tag, "Ok")) {
            if (got) |doc| {
                tally.check(std.mem.eql(u8, try canon(arena, doc.value), try canon(arena, result.args[0])), "{any}: wrong value", .{text});
            } else |_| tally.check(false, "{any}: {f}", .{ text, d });
        } else {
            const want = result.args[0].string;
            if (got) |_| {
                tally.check(false, "{any}: accepted, want {s}", .{ text, want });
            } else |_| tally.check(std.mem.eql(u8, d.code.name(), want), "{any}: {f}, want {s}", .{ text, d, want });
        }
    }
    try tally.report();
}

/// The canonical forms of a result, or its error code: what the stream cases compare.
fn streamOutcome(arena: Allocator, text: []const u8, chunks: []const []const u8, max: u64, strict: bool) ![]const u8 {
    _ = text;
    var d: haus.Diagnostic = .{};
    var r = try haus.StreamReader.init(gpa, .{ .limits = .{ .max_value_length = max }, .strict = strict, .diagnostic = &d });
    defer r.deinit();
    var vals: std.ArrayList(Value) = .empty;
    for (chunks) |chunk| {
        const got = r.push(arena, chunk) catch return std.fmt.allocPrint(arena, "Err({s})", .{d.code.name()});
        try vals.appendSlice(arena, got);
    }
    const last = r.end(arena) catch return std.fmt.allocPrint(arena, "Err({s})", .{d.code.name()});
    if (last) |l| try vals.append(arena, l);
    return okOutcome(arena, vals.items);
}

fn okOutcome(arena: Allocator, vals: []const Value) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "Ok([");
    for (vals, 0..) |val, i| {
        if (i > 0) try s.append(arena, ',');
        try s.appendSlice(arena, try canon(arena, val));
    }
    try s.appendSlice(arena, "])");
    return s.items;
}

fn expectedOutcome(arena: Allocator, result: haus.Variant) ![]const u8 {
    if (std.mem.eql(u8, result.tag, "Ok")) return okOutcome(arena, result.args[0].array);
    return std.fmt.allocPrint(arena, "Err({s})", .{result.args[0].string});
}

fn streamSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tally = Tally{ .name = "stream/limits.cases.haus" };
    var splits: usize = 0;
    for (try readCases(arena, "stream/limits.cases.haus")) |case| {
        const text = get(case, "text").?.string;
        const max = try std.fmt.parseInt(u64, get(case, "maxValueLength").?.number, 10);
        const strict = if (get(case, "strict")) |s| std.mem.eql(u8, s.variant.tag, "True") else false;
        const want = try expectedOutcome(arena, get(case, "result").?.variant);
        // Whole, one byte at a time, one character at a time, and split at every position.
        var ways: std.ArrayList([]const []const u8) = .empty;
        try ways.append(arena, &.{text});
        var bytes: std.ArrayList([]const u8) = .empty;
        for (0..text.len) |i| try bytes.append(arena, text[i .. i + 1]);
        try ways.append(arena, bytes.items);
        var chars: std.ArrayList([]const u8) = .empty;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepointSlice()) |c| try chars.append(arena, c);
        try ways.append(arena, chars.items);
        for (0..text.len + 1) |cut| try ways.append(arena, try arena.dupe([]const u8, &.{ text[0..cut], text[cut..] }));
        var all = true;
        for (ways.items) |chunks| {
            const got = try streamOutcome(arena, text, chunks, max, strict);
            if (!std.mem.eql(u8, got, want)) {
                all = false;
                try stdout.print("  {any} in {d} chunks: {s}, want {s}\n", .{ text, chunks.len, got, want });
                break;
            }
            splits += 1;
        }
        tally.check(all, "{any}", .{text});
        if (get(case, "whole")) |whole| {
            var d: haus.Diagnostic = .{};
            const got = if (haus.parseAll(arena, text, .{ .diagnostic = &d })) |p| try okOutcome(arena, p.value) else |_| try std.fmt.allocPrint(arena, "Err({s})", .{d.code.name()});
            const want_whole = try expectedOutcome(arena, whole.variant);
            tally.check(std.mem.eql(u8, got, want_whole), "{any} parsed whole: {s}, want {s}", .{ text, got, want_whole });
        }
    }
    try stdout.print("  ({d} chunkings run)\n", .{splits});
    try tally.report();
}

// ── format/ ──────────────────────────────────────────────────

fn valuesOf(arena: Allocator, text: []const u8) !?[]const u8 {
    const parsed = haus.parseAll(arena, text, .{}) catch return null;
    var s: std.ArrayList(u8) = .empty;
    for (parsed.value) |val| {
        try s.appendSlice(arena, try canon(arena, val));
        try s.append(arena, '\n');
    }
    return s.items;
}

fn withoutBlankLines(arena: Allocator, text: []const u8) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try s.appendSlice(arena, line);
        try s.append(arena, '\n');
    }
    return s.items;
}

fn trimLines(arena: Allocator, text: []const u8) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try s.append(arena, '\n');
        first = false;
        try s.appendSlice(arena, std.mem.trimEnd(u8, line, " \t"));
    }
    return s.items;
}

/// One input of the format suite, with its expected files next to it.
fn formatCase(arena: Allocator, tally: *Tally, input_path: []const u8, expected_base: []const u8, name: []const u8) !void {
    const text = try readFile(arena, input_path);
    var opts: haus.FormatOptions = .{};
    const options_path = try std.fmt.allocPrint(arena, "{s}.options", .{expected_base});
    if (fileExists(options_path)) {
        const o = (try haus.parse(arena, try readFile(arena, options_path), .{})).value;
        if (get(o, "indent")) |i| opts.indent = try std.fmt.parseInt(u32, i.number, 10);
        if (get(o, "width")) |wd| opts.width = try std.fmt.parseInt(u32, wd.number, 10);
    }
    const values = (try valuesOf(arena, text)).?;
    var outputs: [3][]const u8 = undefined;
    for ([_]haus.Layout{ .pretty, .compact, .minimised }, 0..) |layout, k| {
        var o = opts;
        o.layout = layout;
        var d: haus.Diagnostic = .{};
        o.write.diagnostic = &d;
        const got = haus.format(arena, text, o) catch {
            tally.check(false, "{s} {t}: rejected: {f}", .{ name, layout, d });
            return;
        };
        outputs[k] = got;
        const want = try readFile(arena, try std.fmt.allocPrint(arena, "{s}.{t}", .{ expected_base, layout }));
        tally.check(std.mem.eql(u8, got, want), "{s} {t}:\n--- got\n{s}--- want\n{s}---", .{ name, layout, got, want });
        // Idempotent, and the same values.
        const again = try haus.format(arena, got, o);
        tally.check(std.mem.eql(u8, again, got), "{s} {t}: not idempotent:\n{s}", .{ name, layout, again });
        const vals = try valuesOf(arena, got);
        tally.check(vals != null and std.mem.eql(u8, vals.?, values), "{s} {t}: other values", .{ name, layout });
    }
    // Minimised as pretty: the pretty file without its comments and blank lines.
    var o = opts;
    o.layout = .pretty;
    const from_min = try haus.format(arena, outputs[2], o);
    // "The pretty file without its comments" read as the input formatted
    // in pretty with its comments dropped: removing them from the pretty
    // text isn't the same where they broke a container (spec §11; finding).
    var bare_opts = o;
    bare_opts.comments = false;
    const bare = try haus.format(arena, text, bare_opts);
    tally.check(std.mem.eql(u8, try withoutBlankLines(arena, from_min), try withoutBlankLines(arena, bare)), "{s}: pretty(minimised) is not pretty without comments:\n{s}", .{ name, from_min });
    // Trimming trailing blanks keeps the values.
    const trimmed = try valuesOf(arena, try trimLines(arena, outputs[0]));
    tally.check(trimmed != null and std.mem.eql(u8, trimmed.?, values), "{s}: trimming trailing blanks changes the values", .{name});
}

fn formatSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "cases", "examples", "valid" }) |kind| {
        var tally = Tally{ .name = try std.fmt.allocPrint(arena, "format/{s}", .{kind}) };
        const expected_dir = try suitePath(arena, try std.fmt.allocPrint(arena, "format/{s}", .{kind}));
        const input_dir = if (std.mem.eql(u8, kind, "valid")) try suitePath(arena, "valid") else expected_dir;
        for (try listFiles(arena, input_dir, ".haus")) |name| {
            try formatCase(
                arena,
                &tally,
                try std.fmt.allocPrint(arena, "{s}/{s}.haus", .{ input_dir, name }),
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ expected_dir, name }),
                name,
            );
        }
        try tally.report();
    }
    // The pretty layout's options.
    var tally = Tally{ .name = "format/options.cases.haus" };
    for (try readCases(arena, "format/options.cases.haus")) |case| {
        const input = get(case, "input").?.string;
        var o: haus.FormatOptions = .{};
        var rejected = false;
        if (get(case, "indent")) |i| {
            if (i.number[0] == '-') rejected = true else o.indent = try std.fmt.parseInt(u32, i.number, 10);
        }
        if (get(case, "width")) |wd| {
            if (wd.number[0] == '-') rejected = true else o.width = try std.fmt.parseInt(u32, wd.number, 10);
        }
        const result = get(case, "result").?;
        if (result == .variant and std.mem.eql(u8, result.variant.tag, "Rejected")) {
            // The option types can't hold a negative number: rejected by the types.
            tally.check(rejected, "{any}: expected Rejected", .{input});
            continue;
        }
        const want = result.variant.args[0].string;
        const got = try haus.format(arena, input, o);
        tally.check(!rejected and std.mem.eql(u8, got, want), "{any}: got {any}, want {any}", .{ input, got, want });
    }
    try tally.report();
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) suite_dir = args[1];
    var buf: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), io, &buf);
    stdout = &w.interface;
    const suites = .{ validSuite, invalidSuite, positionsSuite, equalitySuite, documentSuite, streamSuite, formatSuite };
    inline for (suites) |run| try run();
    try stdout.print("{s}\n", .{if (failures == 0) "conformance suite: all passed" else "conformance suite: FAILED"});
    try stdout.flush();
    if (failures > 0) std.process.exit(1);
}
