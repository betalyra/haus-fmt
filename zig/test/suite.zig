//! The conformance suite (test-suite/README.md), run with `zig build suite`.
//! Each test reads its files from ../test-suite, runs every case and
//! prints how many passed; a failing case is printed and fails the test.

const std = @import("std");
const builtin = @import("builtin");
const haus = @import("haus");
const build_options = @import("build_options");
const Value = haus.Value;
const Allocator = std.mem.Allocator;

var io: std.Io = undefined;
var environ: *std.process.Environ.Map = undefined;
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
        // `document: True`: read as a single document (`parse`), else as a file.
        const document = if (get(case, "document")) |doc| std.mem.eql(u8, doc.variant.tag, "True") else false;
        var d: haus.Diagnostic = .{};
        const accepted = if (document)
            (if (haus.parse(arena, text, .{ .diagnostic = &d })) |_| true else |_| false)
        else
            (if (haus.parseAll(arena, text, .{ .diagnostic = &d })) |_| true else |_| false);
        if (accepted) {
            tally.check(false, "{any}: accepted", .{text});
        } else {
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

// ── schemas (test-suite/schema, stream/typed, check) ─────────

/// The schema text with every attribute removed (test-suite/README.md:
/// attributes don't matter).
fn withoutAttributes(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
            i += 1;
            try out.appendSlice(arena, text[start..@min(i, text.len)]);
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            const end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            try out.appendSlice(arena, text[i..end]);
            i = end;
        } else if (c == '@') {
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
            if (i < text.len and text[i] == '(') {
                var depth: usize = 0;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '"') {
                        i += 1;
                        while (i < text.len and text[i] != '"') : (i += 1) {
                            if (text[i] == '\\') i += 1;
                        }
                    } else if (text[i] == '(' or text[i] == '[' or text[i] == '{') {
                        depth += 1;
                    } else if (text[i] == ')' or text[i] == ']' or text[i] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    }
                }
            }
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

fn loadSchema(text: []const u8, d: *haus.Diagnostic) !*haus.schema.Schema {
    return haus.schema.load(gpa, text, .{ .diagnostic = d });
}

fn schemaInvalidSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try suitePath(arena, "schema/invalid");
    var tally = Tally{ .name = "schema/invalid/*.error" };
    for (try listFiles(arena, dir, ".schema.haus")) |name| {
        const text = try readFile(arena, try std.fmt.allocPrint(arena, "{s}/{s}.schema.haus", .{ dir, name }));
        const want = std.mem.trimEnd(u8, try readFile(arena, try std.fmt.allocPrint(arena, "{s}/{s}.error", .{ dir, name })), "\n");
        var d: haus.Diagnostic = .{};
        if (loadSchema(text, &d)) |s| {
            s.deinit();
            tally.check(false, "{s}: accepted, want {s}", .{ name, want });
        } else |_| {
            tally.check(std.mem.eql(u8, d.code.name(), want), "{s}: {f}, want {s}", .{ name, d, want });
        }
    }
    try tally.report();
}

/// One case of a schema suite: `Ok { type, input, output? }` or
/// `Err { type, input, code, path }`. Returns why it failed, or null.
fn schemaCase(arena: Allocator, s: *const haus.schema.Schema, case: haus.Variant) !?[]const u8 {
    const fields = case.args[0];
    const type_name = get(fields, "type").?.string;
    const def = s.get(type_name) orelse return try std.fmt.allocPrint(arena, "no type {s}", .{type_name});
    const input = get(fields, "input").?;
    var d: haus.Diagnostic = .{};
    const decoded = haus.decoding.decode(arena, def, input, .{ .diagnostic = &d });
    if (std.mem.eql(u8, case.tag, "Ok")) {
        const got = decoded catch return try std.fmt.allocPrint(arena, "{s} {s}: rejected: {s} at {s}: {s}", .{ type_name, try canon(arena, input), d.code.name(), d.path(), d.message() });
        const encoded = haus.decoding.encode(arena, def, got, .{ .diagnostic = &d }) catch return try std.fmt.allocPrint(arena, "{s} {s}: encoding failed: {s} at {s}: {s}", .{ type_name, try canon(arena, input), d.code.name(), d.path(), d.message() });
        const want = get(fields, "output") orelse input;
        const a = try canon(arena, encoded);
        const b = try canon(arena, want);
        if (!std.mem.eql(u8, a, b)) return try std.fmt.allocPrint(arena, "{s} {s}: encoded {s}, want {s}", .{ type_name, try canon(arena, input), a, b });
        return null;
    }
    const code = get(fields, "code").?.string;
    const path = get(fields, "path").?.string;
    if (decoded) |_| return try std.fmt.allocPrint(arena, "{s} {s}: accepted, want {s} at {s}", .{ type_name, try canon(arena, input), code, path }) else |_| {}
    if (!std.mem.eql(u8, d.code.name(), code) or !std.mem.eql(u8, d.path(), path)) {
        return try std.fmt.allocPrint(arena, "{s} {s}: {s} at {s} ({s}), want {s} at {s}", .{ type_name, try canon(arena, input), d.code.name(), d.path(), d.message(), code, path });
    }
    return null;
}

fn schemaSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try suitePath(arena, "schema");
    var tally = Tally{ .name = "schema/*.cases.haus" };
    var bare = Tally{ .name = "schema/*.cases.haus without attributes" };
    for (try listFiles(arena, dir, ".cases.haus")) |name| {
        const text = try readFile(arena, try std.fmt.allocPrint(arena, "{s}/{s}.schema.haus", .{ dir, name }));
        var d: haus.Diagnostic = .{};
        const s = loadSchema(text, &d) catch {
            tally.check(false, "{s}.schema.haus rejected: {f}", .{ name, d });
            continue;
        };
        defer s.deinit();
        const plain = loadSchema(try withoutAttributes(arena, text), &d) catch {
            bare.check(false, "{s}.schema.haus without attributes rejected: {f}", .{ name, d });
            continue;
        };
        defer plain.deinit();
        for (try readCases(arena, try std.fmt.allocPrint(arena, "schema/{s}.cases.haus", .{name}))) |case| {
            const why = try schemaCase(arena, s, case.variant);
            tally.check(why == null, "{s}: {s}", .{ name, why orelse "" });
            const why_bare = try schemaCase(arena, plain, case.variant);
            bare.check(why_bare == null, "{s}: {s}", .{ name, why_bare orelse "" });
        }
    }
    try tally.report();
    try bare.report();
}

fn typedSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tally = Tally{ .name = "stream/typed.cases.haus" };
    var d: haus.Diagnostic = .{};
    const s = try loadSchema(try readFile(arena, try suitePath(arena, "stream/typed.schema.haus")), &d);
    defer s.deinit();
    for (try readCases(arena, "stream/typed.cases.haus")) |case| {
        const fields = case.variant.args[0];
        const def = s.get(get(fields, "type").?.string).?;
        const text = get(fields, "text").?.string;
        const got = haus.decoding.decodeText(gpa, arena, def, text, .{ .diagnostic = &d });
        if (std.mem.eql(u8, case.variant.tag, "Ok")) {
            const decoded = got catch {
                tally.check(false, "{any}: {f} at {s}", .{ text, d, d.path() });
                continue;
            };
            const encoded = try haus.decoding.encodeText(arena, def, decoded, .{});
            tally.check(std.mem.eql(u8, try canon(arena, encoded), try canon(arena, get(fields, "output").?)), "{any}: encoded {s}", .{ text, try canon(arena, encoded) });
        } else {
            const code = get(fields, "code").?.string;
            const path = get(fields, "path").?.string;
            if (got) |_| {
                tally.check(false, "{any}: accepted, want {s}", .{ text, code });
            } else |_| tally.check(std.mem.eql(u8, d.code.name(), code) and std.mem.eql(u8, d.path(), path), "{any}: {s} at {s}, want {s} at {s}", .{ text, d.code.name(), d.path(), code, path });
        }
    }
    try tally.report();
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn checkSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var schemas = Tally{ .name = "check/cases.haus Schema" };
    var datas = Tally{ .name = "check/cases.haus Data" };
    for (try readCases(arena, "check/cases.haus")) |case| {
        const fields = case.variant.args[0];
        var d: haus.Diagnostic = .{};
        const text = get(fields, "schema").?.string;
        const tally = if (std.mem.eql(u8, case.variant.tag, "Schema")) &schemas else &datas;
        const s = loadSchema(text, &d) catch {
            tally.check(false, "{any}: rejected: {f}", .{ text, d });
            continue;
        };
        defer s.deinit();
        var got: std.ArrayList(u8) = .empty;
        var want: std.ArrayList(u8) = .empty;
        if (tally == &schemas) {
            for (s.warnings) |w| try got.print(arena, "{s} {d}:{d}; ", .{ w.code.name(), w.line, w.column });
            for (get(fields, "warnings").?.array) |w| try want.print(arena, "{s} {s}:{s}; ", .{ w.variant.args[0].string, w.variant.args[1].number, w.variant.args[2].number });
        } else {
            const def = s.get(get(fields, "type").?.string).?;
            const data = get(fields, "data").?.string;
            const report = try haus.decoding.checkReport(gpa, arena, def, data, .{});
            // Which issues, not their order (spec §14, "Every error"):
            // both lists compared sorted.
            var got_list: std.ArrayList([]const u8) = .empty;
            var want_list: std.ArrayList([]const u8) = .empty;
            for (report.issues) |i| try got_list.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}; ", .{ if (i.kind == .hint) "Hint" else "Error", i.code.name(), i.path }));
            for (get(fields, "issues").?.array) |i| try want_list.append(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}; ", .{ i.variant.tag, i.variant.args[0].string, i.variant.args[1].string }));
            for ([_]*std.ArrayList([]const u8){ &got_list, &want_list }, [_]*std.ArrayList(u8){ &got, &want }) |list, out| {
                std.mem.sort([]const u8, list.items, {}, lessString);
                for (list.items) |item| try out.appendSlice(arena, item);
            }
            // The first-error mode: at most one error, there if and only if
            // there are errors, and every issue one of the full list's.
            const first = try haus.decoding.checkReport(gpa, arena, def, data, .{ .first = true });
            var first_errors: usize = 0;
            var first_ok = !report.stopped;
            for (first.issues) |i| {
                first_errors += @intFromBool(i.kind == .err);
                const line = try std.fmt.allocPrint(arena, "{s} {s} {s}; ", .{ if (i.kind == .hint) "Hint" else "Error", i.code.name(), i.path });
                if (std.mem.indexOf(u8, got.items, line) == null) first_ok = false;
            }
            const has_errors = std.mem.indexOf(u8, got.items, "Error ") != null;
            if (first_errors != @intFromBool(has_errors)) first_ok = false;
            if (!first_ok) try got.appendSlice(arena, "(and the first-error mode differs)");
        }
        tally.check(std.mem.eql(u8, got.items, want.items), "{any}: got [{s}], want [{s}]", .{ text, got.items, want.items });
    }
    try schemas.report();
    try datas.report();
}

// ── JSON (test-suite/json) ───────────────────────────────────

/// JSON compared as data: member order and whitespace don't matter,
/// numbers compare by their text.
fn jsonEqual(a: haus.json.Json, b: haus.json.Json) bool {
    switch (a) {
        .null => return b == .null,
        .bool => |x| return b == .bool and b.bool == x,
        .number => |x| return b == .number and std.mem.eql(u8, x, b.number),
        .string => |x| return b == .string and std.mem.eql(u8, x, b.string),
        .array => |xs| {
            if (b != .array or b.array.len != xs.len) return false;
            for (xs, b.array) |x, y| if (!jsonEqual(x, y)) return false;
            return true;
        },
        .object => |ms| {
            if (b != .object or b.object.len != ms.len) return false;
            for (ms) |m| {
                const other = b.get(m.name) orelse return false;
                if (!jsonEqual(m.value, other)) return false;
            }
            return true;
        },
    }
}

fn sameJson(arena: Allocator, a: []const u8, b: []const u8) bool {
    const ja = haus.json.parse(arena, gpa, a, 100000, .{}) catch return false;
    const jb = haus.json.parse(arena, gpa, b, 100000, .{}) catch return false;
    return jsonEqual(ja, jb);
}

/// The outcome of a reader that fails with a diagnostic: null, or why the
/// error isn't the expected one.
fn errMismatch(arena: Allocator, d: *const haus.Diagnostic, fields: Value) !?[]const u8 {
    const code = get(fields, "code").?.string;
    if (!std.mem.eql(u8, d.code.name(), code)) return try std.fmt.allocPrint(arena, "{s} at {s} ({s}), want {s}", .{ d.code.name(), d.path(), d.message(), code });
    if (get(fields, "path")) |p| if (!std.mem.eql(u8, d.path(), p.string)) {
        return try std.fmt.allocPrint(arena, "{s} at {s}, want {s} at {s}", .{ d.code.name(), d.path(), code, p.string });
    };
    return null;
}

fn schemaJsonCase(arena: Allocator, s: *const haus.schema.Schema, case: haus.Variant) !?[]const u8 {
    const fields = case.args[0];
    const type_name = get(fields, "type").?.string;
    const def = s.get(type_name) orelse return try std.fmt.allocPrint(arena, "no type {s}", .{type_name});
    const json_text = get(fields, "json").?.string;
    var d: haus.Diagnostic = .{};
    if (std.mem.eql(u8, case.tag, "Ok")) {
        const input = get(fields, "input").?;
        const decoded = haus.decoding.decode(arena, def, input, .{ .diagnostic = &d }) catch return try std.fmt.allocPrint(arena, "{s}: input rejected: {f}", .{ type_name, d });
        const written = haus.json.toJson(arena, def, decoded, .{ .diagnostic = &d }) catch return try std.fmt.allocPrint(arena, "{s}: writing failed: {f}", .{ type_name, d });
        if (!sameJson(arena, written, json_text)) return try std.fmt.allocPrint(arena, "{s}: wrote {s}, want {s}", .{ type_name, written, json_text });
    }
    if (std.mem.eql(u8, case.tag, "Err")) {
        if (haus.json.fromJson(arena, gpa, def, json_text, .{ .diagnostic = &d })) |_| {
            return try std.fmt.allocPrint(arena, "{s} {s}: accepted, want {s}", .{ type_name, json_text, get(fields, "code").?.string });
        } else |_| {}
        if (try errMismatch(arena, &d, fields)) |why| return try std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ type_name, json_text, why });
        return null;
    }
    const read = haus.json.fromJson(arena, gpa, def, json_text, .{ .diagnostic = &d }) catch return try std.fmt.allocPrint(arena, "{s} {s}: rejected: {f} at {s}", .{ type_name, json_text, d, d.path() });
    const encoded = haus.decoding.encode(arena, def, read, .{ .diagnostic = &d }) catch return try std.fmt.allocPrint(arena, "{s} {s}: encoding failed: {f}", .{ type_name, json_text, d });
    const want = get(fields, "output") orelse get(fields, "input").?;
    const a = try canon(arena, encoded);
    const b = try canon(arena, want);
    if (!std.mem.eql(u8, a, b)) return try std.fmt.allocPrint(arena, "{s} {s}: read {s}, want {s}", .{ type_name, json_text, a, b });
    return null;
}

fn hausJsonCase(arena: Allocator, case: haus.Variant) !?[]const u8 {
    const fields = case.args[0];
    const json_text = get(fields, "json").?.string;
    var d: haus.Diagnostic = .{};
    if (std.mem.eql(u8, case.tag, "Ok")) {
        const input = get(fields, "input").?;
        const written = try haus.json.toHausJson(arena, input, .{});
        if (!sameJson(arena, written, json_text)) return try std.fmt.allocPrint(arena, "wrote {s}, want {s}", .{ written, json_text });
        const read = haus.json.fromHausJson(arena, gpa, json_text, .{ .diagnostic = &d }) catch return try std.fmt.allocPrint(arena, "{s}: rejected: {f}", .{ json_text, d });
        if (!std.mem.eql(u8, try canon(arena, read), try canon(arena, input))) return try std.fmt.allocPrint(arena, "{s}: read {s}", .{ json_text, try canon(arena, read) });
        return null;
    }
    if (haus.json.fromHausJson(arena, gpa, json_text, .{ .diagnostic = &d })) |_| {
        return try std.fmt.allocPrint(arena, "{s}: accepted, want {s}", .{ json_text, get(fields, "code").?.string });
    } else |_| {}
    if (try errMismatch(arena, &d, fields)) |why| return try std.fmt.allocPrint(arena, "{s}: {s}", .{ json_text, why });
    return null;
}

fn importCase(arena: Allocator, case: haus.Variant) !?[]const u8 {
    const fields = case.args[0];
    const json_text = get(fields, "json").?.string;
    var d: haus.Diagnostic = .{};
    const got = haus.json.importJson(arena, gpa, json_text, .{ .diagnostic = &d });
    if (std.mem.eql(u8, case.tag, "Read")) {
        const val = got catch return try std.fmt.allocPrint(arena, "{s}: rejected: {f}", .{ json_text, d });
        const a = try canon(arena, val);
        const b = try canon(arena, get(fields, "output").?);
        if (!std.mem.eql(u8, a, b)) return try std.fmt.allocPrint(arena, "{s}: read {s}, want {s}", .{ json_text, a, b });
        return null;
    }
    if (got) |_| return try std.fmt.allocPrint(arena, "{s}: accepted", .{json_text}) else |_| {}
    if (try errMismatch(arena, &d, fields)) |why| return try std.fmt.allocPrint(arena, "{s}: {s}", .{ json_text, why });
    return null;
}

fn linesCase(arena: Allocator, case: haus.Variant) !?[]const u8 {
    const fields = case.args[0];
    const json_text = get(fields, "json").?.string;
    var d: haus.Diagnostic = .{};
    const got = haus.json.fromHausJsonLines(arena, gpa, json_text, .{ .diagnostic = &d });
    if (std.mem.eql(u8, case.tag, "Ok")) {
        const vals = got catch return try std.fmt.allocPrint(arena, "{any}: rejected: {f}", .{ json_text, d });
        const a = try canon(arena, .{ .array = vals });
        const b = try canon(arena, get(fields, "output").?);
        if (!std.mem.eql(u8, a, b)) return try std.fmt.allocPrint(arena, "{any}: read {s}, want {s}", .{ json_text, a, b });
        return null;
    }
    if (got) |_| return try std.fmt.allocPrint(arena, "{any}: accepted", .{json_text}) else |_| {}
    if (try errMismatch(arena, &d, fields)) |why| return try std.fmt.allocPrint(arena, "{any}: {s}", .{ json_text, why });
    return null;
}

fn jsonSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: haus.Diagnostic = .{};
    {
        var tally = Tally{ .name = "json/schema-based.cases.haus" };
        const s = try loadSchema(try readFile(arena, try suitePath(arena, "json/schema-based.schema.haus")), &d);
        defer s.deinit();
        for (try readCases(arena, "json/schema-based.cases.haus")) |case| {
            const why = try schemaJsonCase(arena, s, case.variant);
            tally.check(why == null, "{s}", .{why orelse ""});
        }
        try tally.report();
    }
    {
        var tally = Tally{ .name = "json/self-describing.cases.haus" };
        for (try readCases(arena, "json/self-describing.cases.haus")) |case| {
            const why = try hausJsonCase(arena, case.variant);
            tally.check(why == null, "{s}", .{why orelse ""});
        }
        try tally.report();
    }
    {
        // Every valid/NAME.jsonl: one envelope per value of the file.
        var tally = Tally{ .name = "json: valid/*.jsonl as self-describing JSON" };
        const dir = try suitePath(arena, "valid");
        for (try listFiles(arena, dir, ".haus")) |name| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
            const vals = (try haus.parseAll(arena, try readFile(arena, try std.fmt.allocPrint(arena, "{s}.haus", .{path})), .{})).value;
            const jsonl = try readFile(arena, try std.fmt.allocPrint(arena, "{s}.jsonl", .{path}));
            var lines = std.mem.splitScalar(u8, jsonl, '\n');
            var i: usize = 0;
            while (lines.next()) |line| : (i += 1) {
                if (line.len == 0) break;
                const read = haus.json.fromHausJson(arena, gpa, line, .{ .diagnostic = &d }) catch {
                    tally.check(false, "{s}[{d}]: rejected: {f}", .{ name, i, d });
                    continue;
                };
                const same = i < vals.len and std.mem.eql(u8, try canon(arena, read), try canon(arena, vals[i]));
                const written = try haus.json.toHausJson(arena, vals[i], .{});
                tally.check(same and sameJson(arena, written, line), "{s}[{d}]: differs", .{ name, i });
            }
        }
        try tally.report();
    }
    {
        var tally = Tally{ .name = "json/import.cases.haus" };
        for (try readCases(arena, "json/import.cases.haus")) |case| {
            const why = try importCase(arena, case.variant);
            tally.check(why == null, "{s}", .{why orelse ""});
        }
        try tally.report();
    }
    {
        var tally = Tally{ .name = "json/lines.cases.haus" };
        for (try readCases(arena, "json/lines.cases.haus")) |case| {
            const why = try linesCase(arena, case.variant);
            tally.check(why == null, "{s}", .{why orelse ""});
        }
        try tally.report();
    }
}

// ── packages (test-suite/packages) ───────────────────────────

/// A JSON value of a `package.json` from a case's haus value: a list of
/// names is an object from the names to "*".
fn packageJsonValue(arena: Allocator, out: *std.ArrayList(u8), val: Value) !void {
    switch (val) {
        .string => |s| try haus.json.appendString(arena, out, s),
        .number => |n| try out.appendSlice(arena, n),
        .array => |names| {
            try out.append(arena, '{');
            for (names, 0..) |n, i| {
                if (i > 0) try out.append(arena, ',');
                try haus.json.appendString(arena, out, n.string);
                try out.appendSlice(arena, ":\"*\"");
            }
            try out.append(arena, '}');
        },
        else => try haus.json.appendHausValue(arena, out, val),
    }
}

fn writeCaseFile(dir: std.Io.Dir, sub: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub, .data = bytes });
}

const is_windows = builtin.os.tag == .windows;

/// Makes `sub` (in `dir`) a FIFO, as `mkfifo` does (Unix only).
fn makeFifo(dir: std.Io.Dir, sub: []const u8) !void {
    if (is_windows) return error.Unsupported;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    if (sub.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..sub.len], sub);
    buf[sub.len] = 0;
    const z: [*:0]const u8 = buf[0..sub.len :0];
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        if (linux.errno(linux.mknodat(dir.handle, z, linux.S.IFIFO | 0o644, 0)) != .SUCCESS) return error.MkfifoFailed;
    } else {
        const c = struct {
            extern "c" fn mkfifoat(fd: std.c.fd_t, path: [*:0]const u8, mode: std.c.mode_t) c_int;
        };
        if (c.mkfifoat(dir.handle, z, 0o644) != 0) return error.MkfifoFailed;
    }
}

/// Whether the tests run as root, whom permissions don't stop.
fn runningAsRoot() bool {
    if (is_windows) return false;
    if (builtin.os.tag == .linux) return std.os.linux.geteuid() == 0;
    return std.c.geteuid() == 0;
}

fn setMode(dir: std.Io.Dir, sub: []const u8, mode: u32) !void {
    if (is_windows) return error.Unsupported;
    try dir.setFilePermissions(io, sub, @fromBackingInt(@intCast(mode)), .{});
}

/// Writes the file tree of a case into `case_dir`. Returns the paths
/// whose permissions a `Mode` entry changed.
fn writeTree(arena: Allocator, case_dir: []const u8, case: Value) ![]const []const u8 {
    try std.Io.Dir.cwd().createDirPath(io, case_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, case_dir, .{});
    defer dir.close(io);
    var links: std.ArrayList(haus.Variant) = .empty;
    var modes: std.ArrayList(haus.Variant) = .empty;
    for (get(case, "files").?.array) |f| {
        const x = f.variant;
        if (std.mem.eql(u8, x.tag, "Fifo")) {
            if (std.fs.path.dirname(x.args[0].string)) |parent| try dir.createDirPath(io, parent);
            try makeFifo(dir, x.args[0].string);
        } else if (std.mem.eql(u8, x.tag, "Large")) {
            const n = try std.fmt.parseInt(usize, x.args[1].number, 10);
            const spaces = try arena.alloc(u8, n);
            @memset(spaces, ' ');
            try writeCaseFile(dir, x.args[0].string, spaces);
        } else if (std.mem.eql(u8, x.tag, "Mode")) {
            try modes.append(arena, x);
        } else if (std.mem.eql(u8, x.tag, "File")) {
            try writeCaseFile(dir, x.args[0].string, x.args[1].string);
        } else if (std.mem.eql(u8, x.tag, "Package")) {
            var manifest: std.ArrayList(u8) = .empty;
            try manifest.appendSlice(arena, "{ name: ");
            try haus.canonical_form.appendQuoted(arena, &manifest, x.args[1].string);
            try manifest.appendSlice(arena, ", version: ");
            try haus.canonical_form.appendQuoted(arena, &manifest, x.args[2].string);
            try manifest.appendSlice(arena, " }");
            try writeCaseFile(dir, try std.fmt.allocPrint(arena, "{s}/package.haus", .{x.args[0].string}), manifest.items);
            try writeCaseFile(dir, try std.fmt.allocPrint(arena, "{s}/schema.haus", .{x.args[0].string}), x.args[3].string);
        } else if (std.mem.eql(u8, x.tag, "Npm")) {
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '{');
            for (x.args[1].record, 0..) |field, i| {
                if (i > 0) try out.append(arena, ',');
                try haus.json.appendString(arena, &out, field.key);
                try out.append(arena, ':');
                try packageJsonValue(arena, &out, field.value);
            }
            try out.append(arena, '}');
            try writeCaseFile(dir, try std.fmt.allocPrint(arena, "{s}/package.json", .{x.args[0].string}), out.items);
        } else if (std.mem.eql(u8, x.tag, "Link")) {
            try links.append(arena, x);
        } else return error.UnknownFileEntry;
    }
    // The links last, in order, once what they point to is there: Windows
    // needs to know whether a link is to a directory when it is made.
    for (links.items) |x| {
        const path = x.args[0].string;
        const parent = std.fs.path.dirname(path);
        if (parent) |p| try dir.createDirPath(io, p);
        const target = try std.fs.path.join(arena, &.{ parent orelse ".", x.args[1].string });
        const is_directory = if (dir.statFile(io, target, .{})) |st| st.kind == .directory else |_| false;
        try dir.symLink(io, x.args[1].string, path, .{ .is_directory = is_directory });
    }
    // The permissions last, once the whole tree is written.
    var changed: std.ArrayList([]const u8) = .empty;
    for (modes.items) |x| {
        try setMode(dir, x.args[0].string, try std.fmt.parseInt(u32, x.args[1].string, 8));
        try changed.append(arena, x.args[0].string);
    }
    return changed.items;
}

/// Gives the owner back their permissions on what `writeTree` changed
/// (`chmod u+rwx`), so that the tree left in place can be removed.
fn restoreModes(case_dir: []const u8, changed: []const []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, case_dir, .{}) catch return;
    defer dir.close(io);
    for (changed) |sub| setMode(dir, sub, 0o755) catch {};
}

/// Runs a case on its tree in `case_dir`: null if it passed, else why
/// not. With `as_trees`, each package given by its directory is given as
/// a file tree (a directory handle) instead (spec §13.3,
/// `packages.explicit.file-tree`); null is returned as `skipped` when the
/// case has none that can be opened.
fn runCase(arena: Allocator, case_dir: []const u8, case: Value, as_trees: bool) !?[]const u8 {
    var options: haus.packages.Options = .{};
    const mode = get(case, "mode").?.variant;
    var packages: std.ArrayList([]const u8) = .empty;
    var trees: std.ArrayList(haus.packages.Tree) = .empty;
    var opened: std.ArrayList(std.Io.Dir) = .empty;
    defer for (opened.items) |d| d.close(io);
    var folders: std.ArrayList([]const u8) = .empty;
    if (mode.args.len > 0) {
        if (get(mode.args[0], "packages")) |ps| for (ps.array) |p| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ case_dir, p.string });
            if (as_trees) {
                const d = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return skipped;
                try opened.append(arena, d);
                try trees.append(arena, .{ .shown = p.string, .source = .{ .dir = d } });
            } else try packages.append(arena, path);
        };
        if (get(mode.args[0], "folders")) |fs| for (fs.array) |p| try folders.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ case_dir, p.string }));
    }
    if (as_trees and trees.items.len == 0) return skipped;
    options.packages = packages.items;
    options.trees = trees.items;
    options.folders = folders.items;
    if (get(case, "rootDir")) |r| options.root = try std.fmt.allocPrint(arena, "{s}/{s}", .{ case_dir, r.string });
    var d: haus.Diagnostic = .{};
    options.diagnostic = &d;
    const root = try std.fmt.allocPrint(arena, "{s}/{s}", .{ case_dir, get(case, "root").?.string });
    const expect = get(case, "expect").?.variant;
    const got = haus.packages.build(gpa, io, root, options);
    if (std.mem.eql(u8, expect.tag, "Ok")) {
        const b = got catch return try std.fmt.allocPrint(arena, "rejected: {f}", .{d});
        defer b.deinit();
        const list = try b.packageList(arena);
        var have: std.ArrayList(u8) = .empty;
        for (list) |p| try have.print(arena, "{s} ", .{p});
        var want: std.ArrayList(u8) = .empty;
        for (get(expect.args[0], "packages").?.array) |p| try want.print(arena, "{s} ", .{p.string});
        if (!std.mem.eql(u8, have.items, want.items)) return try std.fmt.allocPrint(arena, "packages [{s}], want [{s}]", .{ have.items, want.items });
        return null;
    }
    const code = get(expect.args[0], "code").?.string;
    if (got) |b| {
        b.deinit();
        return try std.fmt.allocPrint(arena, "accepted, want {s}", .{code});
    } else |_| {}
    if (!std.mem.eql(u8, d.code.name(), code)) return try std.fmt.allocPrint(arena, "{f}, want {s}", .{ d, code });
    // Paths in `mentions` use `/`: every `\` of the message is read as one.
    const message = try arena.dupe(u8, d.message());
    std.mem.replaceScalar(u8, message, '\\', '/');
    if (get(expect.args[0], "mentions")) |ms| for (ms.array) |m| {
        if (std.mem.indexOf(u8, message, m.string) == null) return try std.fmt.allocPrint(arena, "{f}: doesn't mention {s}", .{ d, m.string });
    };
    if (get(expect.args[0], "hides")) |hs| for (hs.array) |h| {
        if (std.mem.indexOf(u8, message, h.string) != null) return try std.fmt.allocPrint(arena, "{f}: shows {s}", .{ d, h.string });
    };
    return null;
}

/// What `runCase` gives for a case that doesn't apply.
const skipped: []const u8 = "(skipped)";

fn isSkipped(why: ?[]const u8) bool {
    return if (why) |w| w.ptr == skipped.ptr else false;
}

/// A case run on a thread of its own, so that a resolver that blocks (on
/// a FIFO) fails the case after a timeout instead of hanging the suite.
const Job = struct {
    arena_state: std.heap.ArenaAllocator,
    case_dir: []const u8,
    case: Value,
    why: ?[]const u8 = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(job: *Job) void {
        const a = job.arena_state.allocator();
        job.why = runCase(a, job.case_dir, job.case, false) catch |e| blk: {
            const why: []const u8 = std.fmt.allocPrint(a, "adapter error {s}", .{@errorName(e)}) catch "adapter error";
            break :blk why;
        };
        job.done.store(true, .release);
    }
};

fn runWithTimeout(arena: Allocator, case_dir: []const u8, case: Value, seconds: i64) !?[]const u8 {
    // Not freed if the case hangs: the thread may still use it.
    const job = try std.heap.page_allocator.create(Job);
    job.* = .{ .arena_state = .init(std.heap.page_allocator), .case_dir = case_dir, .case = case };
    const thread = try std.Thread.spawn(.{}, Job.run, .{job});
    var waited: i64 = 0;
    while (!job.done.load(.acquire)) : (waited += 10) {
        if (waited >= seconds * 1000) {
            thread.detach();
            return try std.fmt.allocPrint(arena, "timed out after {d} s (the build blocks)", .{seconds});
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    thread.join();
    defer {
        job.arena_state.deinit();
        std.heap.page_allocator.destroy(job);
    }
    return if (job.why) |w| try arena.dupe(u8, w) else null;
}

fn hasEntry(case: Value, tag: []const u8) bool {
    for (get(case, "files").?.array) |f| if (std.mem.eql(u8, f.variant.tag, tag)) return true;
    return false;
}

fn packagesSuite() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tally = Tally{ .name = "packages/cases.haus" };
    var as_trees = Tally{ .name = "packages/cases.haus, packages given as file trees" };
    var other_ecosystem: usize = 0;
    var other_os: usize = 0;
    var as_root: usize = 0;
    // A fresh directory for the trees (left in place: nothing is deleted).
    const tmp = environ.get("TMPDIR") orelse environ.get("TEMP") orelse environ.get("TMP") orelse "/tmp";
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const base = try std.fmt.allocPrint(arena, "{s}/haus-zig-packages-{d}", .{ std.mem.trimEnd(u8, tmp, "/\\"), now });
    const cases = try readCases(arena, "packages/cases.haus");
    for (cases, 0..) |case, i| {
        const fields = case.variant.args[0];
        const name = get(fields, "name").?.string;
        // Only the core rules: this binding belongs to no package
        // manager's ecosystem, and never reads node_modules.
        if (!std.mem.eql(u8, get(fields, "ecosystem").?.string, "core")) {
            other_ecosystem += 1;
            continue;
        }
        if (get(fields, "os")) |os| if (std.mem.eql(u8, os.string, "unix") and is_windows) {
            other_os += 1;
            continue;
        };
        if (hasEntry(fields, "Mode") and runningAsRoot()) {
            as_root += 1;
            continue;
        }
        const case_dir = try std.fmt.allocPrint(arena, "{s}/{d}", .{ base, i });
        const changed = writeTree(arena, case_dir, fields) catch |e| {
            tally.check(false, "{s}: adapter error {s}", .{ name, @errorName(e) });
            continue;
        };
        defer restoreModes(case_dir, changed);
        const why = if (hasEntry(fields, "Fifo"))
            try runWithTimeout(arena, case_dir, fields, 5)
        else
            runCase(arena, case_dir, fields, false) catch |e| try std.fmt.allocPrint(arena, "adapter error {s}", .{@errorName(e)});
        tally.check(why == null, "{s}: {s}", .{ name, why orelse "" });
        // The same case with its packages given as file trees.
        if (hasEntry(fields, "Fifo")) continue;
        const why_tree = runCase(arena, case_dir, fields, true) catch |e| try std.fmt.allocPrint(arena, "adapter error {s}", .{@errorName(e)});
        if (!isSkipped(why_tree)) as_trees.check(why_tree == null, "{s}: {s}", .{ name, why_tree orelse "" });
    }
    try stdout.print("  ({d} cases of other ecosystems (npm, cargo), {d} Unix-only cases on Windows, {d} permission cases as root: skipped)\n", .{ other_ecosystem, other_os, as_root });
    try tally.report();
    try as_trees.report();
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    gpa = init.gpa;
    environ = init.environ_map;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) suite_dir = args[1];
    var buf: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    stdout = &w.interface;
    const suites = .{ validSuite, invalidSuite, positionsSuite, equalitySuite, documentSuite, streamSuite, formatSuite, schemaInvalidSuite, schemaSuite, typedSuite, checkSuite, jsonSuite, packagesSuite };
    inline for (suites) |run| try run();
    try stdout.print("{s}\n", .{if (failures == 0) "conformance suite: all passed" else "conformance suite: FAILED"});
    try stdout.flush();
    if (failures > 0) std.process.exit(1);
}
