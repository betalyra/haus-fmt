//! Speed of the haus Zig binding against std.json, on the corpus `bench
//! convert` exported (`bench/.out/<source>/corpus/`), the same documents
//! every other language reads. The tasks mirror Rust's and Go's:
//!
//! ```text
//! parse        std.json.parseFromSlice(std.json.Value)  vs  haus.parse / haus.parseAll (text → Value, no schema)
//! typed        haus.decoding.decodeText with the document's type (spec §15): parse and decode;
//!              the corpus: haus.parseAll + haus.decoding.decode of each
//! write        std.json.Stringify.valueAlloc(Value)     vs  haus.stringify minimised and compact, haus.stringifyAll (the corpus)
//! write typed  haus.decoding.encode + haus.stringify minimised, of the decoded value
//! ```
//!
//! each on the whole corpus as one text (`all.json`, a JSON array;
//! `all.haus`, a haus stream) and on every document on its own (the time is
//! for all of them); write typed per document only. Inputs are the wire
//! forms: minified JSON, minimised haus. Both libraries allocate with the
//! same allocator (`std.heap.smp_allocator`), each parse into an arena it
//! frees before the next.
//!
//! Before timing, every pair is checked once (as in Rust): each haus
//! document parses to a value that writes back to the same text, its pretty
//! form reads as the same value, it decodes with its type and its typed
//! write reads back and decodes, the corpus stream reads as the documents'
//! values and is what `stringifyAll` writes for them, std.json reads every
//! JSON document and the corpus array. Every output's size goes into a
//! checksum. Results: `bench/.out/<source>/speed-zig.json`.
//!
//! `gh-archive` is not measured here: its documents are public GitHub
//! events with user names in them, and the benchmark's corpora must have an
//! open licence and no personal data (bench/README.md).

const std = @import("std");
const builtin = @import("builtin");
const haus = @import("haus");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Value = haus.Value;
const Decoded = haus.Decoded;
const Def = haus.schema.Def;

/// Both libraries allocate with it.
const gpa = std.heap.smp_allocator;

/// Sources this benchmark doesn't measure, and why.
const excluded = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "gh-archive", .why = "public GitHub events with user names in them (personal data)" },
};

var io: std.Io = undefined;
var stdout: *std.Io.Writer = undefined;

fn fail(comptime fmt: []const u8, args: anytype) error{Benchmark} {
    stdout.flush() catch {};
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.Benchmark;
}

// ── settings ─────────────────────────────────────────────────

const Options = struct {
    time_ms: u64,
    warmup_ms: u64,
    quick: bool,
};

const Settings = struct {
    out: []const u8,
    sources: []const []const u8,
    options: Options,
    /// Only these tasks (by id); no results are written.
    tasks: ?[]const []const u8,
    /// Results as `speed-zig.<tag>.json`: for comparing two builds.
    tag: ?[]const u8,

    fn fromEnv(arena: Allocator, env: *const std.process.Environ.Map) !Settings {
        const bench_dir = build_options.bench_dir;
        const out = env.get("HAUS_BENCH_OUT") orelse try std.fs.path.join(arena, &.{ bench_dir, ".out" });
        const all = try manifestSources(arena, try std.fs.path.join(arena, &.{ bench_dir, "sources.haus" }));
        var sources: std.ArrayList([]const u8) = .empty;
        if (env.get("HAUS_BENCH_SOURCES")) |list| {
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |name| {
                for (excluded) |x| if (std.mem.eql(u8, x.name, name)) return fail("{s} is not measured: {s}", .{ name, x.why });
                for (all) |n| {
                    if (std.mem.eql(u8, n, name)) break;
                } else return fail("no corpus source {s} in sources.haus", .{name});
                try sources.append(arena, name);
            }
        } else for (all) |name| {
            for (excluded) |x| {
                if (std.mem.eql(u8, x.name, name)) break;
            } else try sources.append(arena, name);
        }
        const quick = if (env.get("HAUS_BENCH_QUICK")) |q| q.len > 0 and !std.mem.eql(u8, q, "0") else false;
        var options: Options = if (quick) .{ .time_ms = 300, .warmup_ms = 100, .quick = true } else .{ .time_ms = 3000, .warmup_ms = 1000, .quick = false };
        if (env.get("HAUS_BENCH_TIME_MS")) |t| options.time_ms = try std.fmt.parseInt(u64, t, 10);
        if (env.get("HAUS_BENCH_WARMUP_MS")) |t| options.warmup_ms = try std.fmt.parseInt(u64, t, 10);
        var tasks: ?[]const []const u8 = null;
        if (env.get("HAUS_BENCH_TASKS")) |list| {
            var names: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |name| try names.append(arena, name);
            tasks = names.items;
        }
        return .{ .out = out, .sources = sources.items, .options = options, .tasks = tasks, .tag = env.get("HAUS_BENCH_TAG") };
    }
};

// ── the corpus ───────────────────────────────────────────────

fn readFile(arena: Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| fail("{s}: {t}", .{ path, e });
}

/// The one value of a haus file.
fn readValue(arena: Allocator, path: []const u8) !Value {
    var d: haus.Diagnostic = .{};
    const parsed = haus.parse(arena, try readFile(arena, path), .{ .diagnostic = &d }) catch return fail("{s}: {f}", .{ path, d });
    return parsed.value;
}

fn field(val: Value, key: []const u8) ?Value {
    if (val != .record) return null;
    for (val.record) |f| if (std.mem.eql(u8, f.key, key)) return f.value;
    return null;
}

fn string(val: Value, key: []const u8, path: []const u8) ![]const u8 {
    const f = field(val, key) orelse return fail("{s}: no string {s}", .{ path, key });
    if (f != .string) return fail("{s}: no string {s}", .{ path, key });
    return f.string;
}

fn array(val: Value, key: []const u8, path: []const u8) ![]const Value {
    const f = field(val, key) orelse return fail("{s}: no array {s}", .{ path, key });
    if (f != .array) return fail("{s}: no array {s}", .{ path, key });
    return f.array;
}

/// The names of the corpus sources in the manifest, in its order.
fn manifestSources(arena: Allocator, path: []const u8) ![]const []const u8 {
    const m = try readValue(arena, path);
    const corpus = try array(m, "corpus", path);
    const names = try arena.alloc([]const u8, corpus.len);
    for (corpus, names) |s, *n| n.* = try string(s, "name", path);
    return names;
}

const Document = struct {
    id: []const u8,
    root: []const u8,
    /// Minimised haus (the wire form).
    haus: []const u8,
    pretty: []const u8,
    /// Minified JSON.
    json: []const u8,
};

const Corpus = struct {
    source: []const u8,
    schema: []const u8,
    documents: []const Document,
    /// Every document as one haus stream: each item followed by `,` and a line feed.
    all_haus: []const u8,
    /// Every document as one JSON array.
    all_json: []const u8,

    fn load(arena: Allocator, out: []const u8, source: []const u8) !Corpus {
        const dir = try std.fs.path.join(arena, &.{ out, source, "corpus" });
        const index_path = try std.fs.path.join(arena, &.{ dir, "index.haus" });
        std.Io.Dir.cwd().access(io, index_path, .{}) catch
            return fail("no corpus for {s} in {s}: run `pnpm --filter haus-bench convert` (from typescript/) first", .{ source, dir });
        const index = try readValue(arena, index_path);
        const entries = try array(index, "documents", index_path);
        const documents = try arena.alloc(Document, entries.len);
        for (entries, documents) |e, *d| {
            const file = try string(e, "file", index_path);
            const at = struct {
                fn f(a: Allocator, dir_: []const u8, name: []const u8, ext: []const u8) ![]const u8 {
                    return readFile(a, try std.fs.path.join(a, &.{ dir_, try std.mem.concat(a, u8, &.{ name, ext }) }));
                }
            }.f;
            d.* = .{
                .id = try string(e, "id", index_path),
                .root = try string(e, "root", index_path),
                .haus = try at(arena, dir, file, ".haus"),
                .pretty = try at(arena, dir, file, ".pretty.haus"),
                .json = try at(arena, dir, file, ".json"),
            };
        }
        return .{
            .source = try string(index, "source", index_path),
            .schema = try readFile(arena, try std.fs.path.join(arena, &.{ dir, try string(index, "schema", index_path) })),
            .documents = documents,
            .all_haus = try readFile(arena, try std.fs.path.join(arena, &.{ dir, "all.haus" })),
            .all_json = try readFile(arena, try std.fs.path.join(arena, &.{ dir, "all.json" })),
        };
    }
};

// ── the inputs, prepared and checked once ────────────────────

const Inputs = struct {
    corpus: Corpus,
    /// Each document's type.
    defs: []const *const Def,
    /// Each haus document, parsed.
    values: []const Value,
    /// Each haus document, decoded with its type.
    decoded: []const Decoded,
    /// Each JSON document, and the corpus array, parsed by std.json.
    json_values: []const std.json.Value,
    json_all: std.json.Value,
    /// Bytes of the compact texts.
    compact_bytes: u64,
    /// Bytes of the typed writes.
    typed_bytes: u64,

    fn prepare(arena: Allocator, corpus: Corpus) !Inputs {
        if (corpus.documents.len == 0) return fail("{s}: no documents: run convert first", .{corpus.source});
        var d: haus.Diagnostic = .{};
        const schema = haus.schema.load(arena, corpus.schema, .{ .diagnostic = &d }) catch return fail("{s} schema: {f}", .{ corpus.source, d });
        const n = corpus.documents.len;
        const defs = try arena.alloc(*const Def, n);
        const values = try arena.alloc(Value, n);
        const decoded = try arena.alloc(Decoded, n);
        const json_values = try arena.alloc(std.json.Value, n);
        var compact_bytes: u64 = 0;
        var typed_bytes: u64 = 0;
        for (corpus.documents, 0..) |doc, i| {
            defs[i] = schema.get(doc.root) orelse return fail("{s}: no type {s} in the schema", .{ doc.id, doc.root });
            values[i] = (haus.parse(arena, doc.haus, .{ .diagnostic = &d }) catch return fail("{s}: {f}", .{ doc.id, d })).value;
            decoded[i] = haus.decoding.decode(arena, defs[i], values[i], .{ .diagnostic = &d }) catch return fail("{s}: decode as {s}: {f}", .{ doc.id, doc.root, d });
            json_values[i] = (std.json.parseFromSliceLeaky(std.json.Value, arena, doc.json, .{}) catch |e| return fail("{s}: std.json: {t}", .{ doc.id, e }));
            compact_bytes += (try haus.stringify(arena, values[i], .{ .layout = .compact })).len;
            typed_bytes += (try typedWrite(arena, defs[i], decoded[i])).len;
        }
        const json_all = std.json.parseFromSliceLeaky(std.json.Value, arena, corpus.all_json, .{}) catch |e| return fail("all.json: std.json: {t}", .{e});
        return .{
            .corpus = corpus,
            .defs = defs,
            .values = values,
            .decoded = decoded,
            .json_values = json_values,
            .json_all = json_all,
            .compact_bytes = compact_bytes,
            .typed_bytes = typed_bytes,
        };
    }

    /// The checks before timing; the number of documents std.json's
    /// `Value` writes back as another document (numbers as i64 or f64;
    /// haus's equality: exact numbers, member order aside).
    fn check(i: *const Inputs, arena: Allocator) !u64 {
        var d: haus.Diagnostic = .{};
        var json_not_stable: u64 = 0;
        for (i.corpus.documents, i.values, i.defs, i.decoded, i.json_values) |doc, val, def, dec, j| {
            const written = try haus.stringify(arena, val, .{ .layout = .minimised });
            if (!std.mem.eql(u8, written, doc.haus)) return fail("{s}: haus parse → stringify minimised is not the same text", .{doc.id});
            const pretty = (haus.parse(arena, doc.pretty, .{ .diagnostic = &d }) catch return fail("{s} (pretty): {f}", .{ doc.id, d })).value;
            if (!try haus.equals(arena, pretty, val, .{})) return fail("{s}: the pretty text reads as another value", .{doc.id});
            const typed = try typedWrite(arena, def, dec);
            const back = (haus.parse(arena, typed, .{ .diagnostic = &d }) catch return fail("{s} (typed write): {f}", .{ doc.id, d })).value;
            _ = haus.decoding.decode(arena, def, back, .{ .diagnostic = &d }) catch return fail("{s}: the typed write doesn't decode: {f}", .{ doc.id, d });
            const json_back = try std.json.Stringify.valueAlloc(arena, j, .{});
            const same = struct {
                fn f(a: Allocator, text: []const u8, id: []const u8) !Value {
                    var dd: haus.Diagnostic = .{};
                    return haus.json.importJson(a, a, text, .{ .diagnostic = &dd }) catch fail("{s}: {f}", .{ id, dd });
                }
            }.f;
            if (!try haus.equals(arena, try same(arena, json_back, doc.id), try same(arena, doc.json, doc.id), .{})) json_not_stable += 1;
        }
        const stream = (haus.parseAll(arena, i.corpus.all_haus, .{ .diagnostic = &d }) catch return fail("all.haus: {f}", .{d})).value;
        if (stream.len != i.values.len) return fail("all.haus has {d} values, not {d}", .{ stream.len, i.values.len });
        for (stream, i.values) |a, b| if (!try haus.equals(arena, a, b, .{})) return fail("the haus corpus stream reads as other values", .{});
        if (!std.mem.eql(u8, try haus.stringifyAll(arena, i.values, .{ .layout = .minimised }), i.corpus.all_haus)) {
            return fail("the haus corpus stream isn't what stringifyAll writes for the documents", .{});
        }
        if (i.json_all != .array or i.json_all.array.items.len != i.values.len) return fail("the JSON corpus array has the wrong length", .{});
        return json_not_stable;
    }
};

/// The typed write: the decoded value encoded with its type (checked
/// against it), written minimised.
fn typedWrite(arena: Allocator, def: *const Def, d: Decoded) ![]const u8 {
    const val = try haus.decoding.encode(arena, def, d, .{});
    return haus.stringify(arena, val, .{ .layout = .minimised });
}

// ── the tasks ────────────────────────────────────────────────

const Group = enum { parse, typed, write };
const Input = enum {
    corpus,
    per_doc,
    fn name(x: Input) []const u8 {
        return if (x == .corpus) "corpus" else "per doc";
    }
};
const Format = enum { json, haus };

const Task = struct {
    id: []const u8,
    group: Group,
    input: Input,
    format: Format,
    impl: []const u8,
    bytes: u64,
    /// The library calls; returns a size, which goes into the checksum.
    run: *const fn (*const Inputs) anyerror!usize,
};

const runs = struct {
    fn parseCorpusJson(i: *const Inputs) !usize {
        const p = try std.json.parseFromSlice(std.json.Value, gpa, i.corpus.all_json, .{});
        defer p.deinit();
        return p.value.array.items.len;
    }
    fn parseCorpusHaus(i: *const Inputs) !usize {
        const p = try haus.parseAll(gpa, i.corpus.all_haus, .{});
        defer p.deinit();
        return p.value.len;
    }
    fn parseDocJson(i: *const Inputs) !usize {
        var n: usize = 0;
        for (i.corpus.documents) |d| {
            const p = try std.json.parseFromSlice(std.json.Value, gpa, d.json, .{});
            defer p.deinit();
            n += @intFromBool(p.value != .null);
        }
        return n;
    }
    fn parseDocHaus(i: *const Inputs) !usize {
        var n: usize = 0;
        for (i.corpus.documents) |d| {
            const p = try haus.parse(gpa, d.haus, .{});
            defer p.deinit();
            n += @intFromBool(p.value != .array);
        }
        return n;
    }
    fn typedCorpusHaus(i: *const Inputs) !usize {
        const p = try haus.parseAll(gpa, i.corpus.all_haus, .{});
        defer p.deinit();
        const arena = p.arena.allocator();
        var n: usize = 0;
        for (p.value, i.defs) |val, def| {
            const d = try haus.decoding.decode(arena, def, val, .{});
            n += @intFromBool(d != .any);
        }
        return n;
    }
    fn typedDocHaus(i: *const Inputs) !usize {
        var n: usize = 0;
        for (i.corpus.documents, i.defs) |doc, def| {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const d = try haus.decoding.decodeText(gpa, arena_state.allocator(), def, doc.haus, .{});
            n += @intFromBool(d != .any);
        }
        return n;
    }
    fn writeCorpusJson(i: *const Inputs) !usize {
        const text = try std.json.Stringify.valueAlloc(gpa, i.json_all, .{});
        defer gpa.free(text);
        return text.len;
    }
    fn writeCorpusHaus(i: *const Inputs) !usize {
        const text = try haus.stringifyAll(gpa, i.values, .{ .layout = .minimised });
        defer gpa.free(text);
        return text.len;
    }
    fn writeDocJson(i: *const Inputs) !usize {
        var n: usize = 0;
        for (i.json_values) |j| {
            const text = try std.json.Stringify.valueAlloc(gpa, j, .{});
            defer gpa.free(text);
            n += text.len;
        }
        return n;
    }
    fn writeDoc(i: *const Inputs, comptime layout: haus.Layout) !usize {
        var n: usize = 0;
        for (i.values) |val| {
            const text = try haus.stringify(gpa, val, .{ .layout = layout });
            defer gpa.free(text);
            n += text.len;
        }
        return n;
    }
    fn writeDocMinimised(i: *const Inputs) !usize {
        return writeDoc(i, .minimised);
    }
    fn writeDocCompact(i: *const Inputs) !usize {
        return writeDoc(i, .compact);
    }
    fn writeDocTyped(i: *const Inputs) !usize {
        var n: usize = 0;
        for (i.defs, i.decoded) |def, d| {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            n += (try typedWrite(arena_state.allocator(), def, d)).len;
        }
        return n;
    }
};

/// The tasks, in the other languages' order. Bytes are those of the text
/// read or written, as there.
fn taskList(i: *const Inputs) [12]Task {
    var json_bytes: u64 = 0;
    var haus_bytes: u64 = 0;
    for (i.corpus.documents) |d| {
        json_bytes += d.json.len;
        haus_bytes += d.haus.len;
    }
    const all_json = i.corpus.all_json.len;
    const all_haus = i.corpus.all_haus.len;
    const json_parse = "std.json.parseFromSlice (Value)";
    const json_write = "std.json.Stringify.valueAlloc";
    return .{
        .{ .id = "parse-corpus-json", .group = .parse, .input = .corpus, .format = .json, .impl = json_parse, .bytes = all_json, .run = runs.parseCorpusJson },
        .{ .id = "parse-corpus-haus", .group = .parse, .input = .corpus, .format = .haus, .impl = "haus.parseAll", .bytes = all_haus, .run = runs.parseCorpusHaus },
        .{ .id = "parse-doc-json", .group = .parse, .input = .per_doc, .format = .json, .impl = json_parse, .bytes = json_bytes, .run = runs.parseDocJson },
        .{ .id = "parse-doc-haus", .group = .parse, .input = .per_doc, .format = .haus, .impl = "haus.parse", .bytes = haus_bytes, .run = runs.parseDocHaus },
        .{ .id = "typed-corpus-haus", .group = .typed, .input = .corpus, .format = .haus, .impl = "haus.parseAll + decoding.decode", .bytes = all_haus, .run = runs.typedCorpusHaus },
        .{ .id = "typed-doc-haus", .group = .typed, .input = .per_doc, .format = .haus, .impl = "decoding.decodeText (parse + decode)", .bytes = haus_bytes, .run = runs.typedDocHaus },
        .{ .id = "write-corpus-json", .group = .write, .input = .corpus, .format = .json, .impl = json_write, .bytes = all_json, .run = runs.writeCorpusJson },
        .{ .id = "write-corpus-haus", .group = .write, .input = .corpus, .format = .haus, .impl = "haus.stringifyAll minimised (stream)", .bytes = all_haus, .run = runs.writeCorpusHaus },
        .{ .id = "write-doc-json", .group = .write, .input = .per_doc, .format = .json, .impl = json_write, .bytes = json_bytes, .run = runs.writeDocJson },
        .{ .id = "write-doc-haus-minimised", .group = .write, .input = .per_doc, .format = .haus, .impl = "haus.stringify minimised", .bytes = haus_bytes, .run = runs.writeDocMinimised },
        .{ .id = "write-doc-haus-compact", .group = .write, .input = .per_doc, .format = .haus, .impl = "haus.stringify compact", .bytes = i.compact_bytes, .run = runs.writeDocCompact },
        .{ .id = "write-doc-haus-typed", .group = .write, .input = .per_doc, .format = .haus, .impl = "decoding.encode + haus.stringify minimised (typed)", .bytes = i.typed_bytes, .run = runs.writeDocTyped },
    };
}

// ── timing ───────────────────────────────────────────────────

const Row = struct {
    group: Group,
    input: []const u8,
    format: Format,
    impl: []const u8,
    bytes: u64,
    docs: u64,
    hz: f64,
    mean_ms: f64,
    p75_ms: f64,
    p99_ms: f64,
    samples: u64,
    mb_s: f64,
    us_per_doc: f64,
};

fn now() i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

/// The `q` quantile of sorted values, interpolated between the nearest ranks.
fn quantile(sorted: []const f64, q: f64) f64 {
    const pos = q * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi: usize = @intFromFloat(@ceil(pos));
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - @as(f64, @floatFromInt(lo)));
}

/// Times a task: warm-up for `warmup_ms`, then samples of equal batches
/// (a batch long enough for `time_ms` over all samples). The mean is the
/// total time over the total calls; p75 and p99 are over the samples.
fn measure(arena: Allocator, t: Task, i: *const Inputs, options: Options) !Row {
    const sample_count: usize = if (options.quick) 10 else 30;
    var calls: u64 = 0;
    const warm_start = now();
    const warm_end = warm_start + @as(i96, options.warmup_ms) * std.time.ns_per_ms;
    while (calls == 0 or now() < warm_end) : (calls += 1) std.mem.doNotOptimizeAway(try t.run(i));
    const per_call: f64 = @as(f64, @floatFromInt(now() - warm_start)) / @as(f64, @floatFromInt(calls));
    const budget: f64 = @as(f64, @floatFromInt(options.time_ms * std.time.ns_per_ms)) / @as(f64, @floatFromInt(sample_count));
    const batch: u64 = @max(1, @as(u64, @intFromFloat(@round(budget / per_call))));
    const per_ms = try arena.alloc(f64, sample_count);
    var total_ns: f64 = 0;
    for (per_ms) |*s| {
        const start = now();
        for (0..batch) |_| std.mem.doNotOptimizeAway(try t.run(i));
        const ns: f64 = @floatFromInt(now() - start);
        total_ns += ns;
        s.* = ns / @as(f64, @floatFromInt(batch)) / 1e6;
    }
    std.sort.pdq(f64, per_ms, {}, std.sort.asc(f64));
    const mean_ms = total_ns / @as(f64, @floatFromInt(batch * sample_count)) / 1e6;
    const docs: u64 = i.corpus.documents.len;
    return .{
        .group = t.group,
        .input = t.input.name(),
        .format = t.format,
        .impl = t.impl,
        .bytes = t.bytes,
        .docs = docs,
        .hz = 1000.0 / mean_ms,
        .mean_ms = mean_ms,
        .p75_ms = quantile(per_ms, 0.75),
        .p99_ms = quantile(per_ms, 0.99),
        .samples = sample_count,
        .mb_s = @as(f64, @floatFromInt(t.bytes)) / 1e6 / (mean_ms / 1000.0),
        .us_per_doc = mean_ms * 1000.0 / @as(f64, @floatFromInt(docs)),
    };
}

// ── the machine ──────────────────────────────────────────────

const Machine = struct {
    cpu: []const u8,
    cores: u64,
    memory_gb: u64,
    os: []const u8,
    runtime: []const u8,
    gc: bool = false,

    fn sysctl(arena: Allocator, name: [*:0]const u8) ?[]u8 {
        if (builtin.os.tag != .macos) return null;
        var len: usize = 0;
        if (std.c.sysctlbyname(name, null, &len, null, 0) != 0) return null;
        const buf = arena.alloc(u8, len) catch return null;
        if (std.c.sysctlbyname(name, buf.ptr, &len, null, 0) != 0) return null;
        return buf[0..len];
    }

    fn procField(arena: Allocator, path: []const u8, key: []const u8) ?[]const u8 {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, key)) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }

    fn detect(arena: Allocator) !Machine {
        const cpu: []const u8 = if (sysctl(arena, "machdep.cpu.brand_string")) |b|
            std.mem.sliceTo(b, 0)
        else
            procField(arena, "/proc/cpuinfo", "model name") orelse "unknown";
        const memory: u64 = if (sysctl(arena, "hw.memsize")) |b|
            (if (b.len == 8) std.mem.readInt(u64, b[0..8], builtin.cpu.arch.endian()) else 0)
        else if (procField(arena, "/proc/meminfo", "MemTotal")) |kb|
            (std.fmt.parseInt(u64, std.mem.trim(u8, std.mem.trimEnd(u8, kb, "kB"), " "), 10) catch 0) * 1024
        else
            0;
        // Node's names, so every language's results read the same.
        const platform = switch (builtin.os.tag) {
            .macos => "darwin",
            else => @tagName(builtin.os.tag),
        };
        const arch = switch (builtin.cpu.arch) {
            .aarch64 => "arm64",
            .x86_64 => "x64",
            else => @tagName(builtin.cpu.arch),
        };
        const uts = std.posix.uname();
        return .{
            .cpu = cpu,
            .cores = std.Thread.getCpuCount() catch 1,
            .memory_gb = @intFromFloat(@round(@as(f64, @floatFromInt(memory)) / (1 << 30))),
            .os = try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ platform, std.mem.sliceTo(&uts.release, 0), arch }),
            .runtime = try std.fmt.allocPrint(arena, "zig {s} ({s})", .{ builtin.zig_version_string, build_options.optimize }),
        };
    }
};

// ── results ──────────────────────────────────────────────────

/// `speed-zig.json`: the shape every language writes (`SpeedOut` in
/// bench/size/src/results.ts), so `bench report` puts them side by side.
const SpeedOut = struct {
    lang: []const u8 = "zig",
    harness: []const u8,
    machine: Machine,
    options: Options,
    documents: []const []const u8,
    jsonNotStable: u64,
    rows: []const Row,
    checksum: u64,
};

fn printRow(r: Row) !void {
    var buf: [128]u8 = undefined;
    const task = try std.fmt.bufPrint(&buf, "{t} | {s} | {s}", .{ r.group, r.input, r.impl });
    try stdout.print("{s:<64} {d:>8.1} MB/s {d:>9.2} µs/doc  p99 {d:.3} ms  ({d} samples)\n", .{ task, r.mb_s, r.us_per_doc, r.p99_ms, r.samples });
    try stdout.flush();
}

fn benchSource(arena: Allocator, settings: Settings, machine: Machine, source: []const u8) !void {
    const inputs = try Inputs.prepare(arena, try Corpus.load(arena, settings.out, source));
    const json_not_stable = try inputs.check(arena);
    const all = taskList(&inputs);
    var checksum: u64 = 0;
    for (all) |t| checksum += try t.run(&inputs);

    try stdout.print("\n{s}: {s}, {s}{s}\n", .{ source, machine.cpu, machine.runtime, if (settings.options.quick) " (quick)" else "" });
    var rows: std.ArrayList(Row) = .empty;
    for (all) |t| {
        if (settings.tasks) |only| {
            for (only) |id| {
                if (std.mem.eql(u8, id, t.id)) break;
            } else continue;
        }
        const row = try measure(arena, t, &inputs, settings.options);
        try printRow(row);
        try rows.append(arena, row);
    }
    if (settings.tasks != null) {
        try stdout.print("{s}: only some tasks (HAUS_BENCH_TASKS): no results written\n", .{source});
        return;
    }
    const ids = try arena.alloc([]const u8, inputs.corpus.documents.len);
    for (inputs.corpus.documents, ids) |d, *id| id.* = d.id;
    const out: SpeedOut = .{
        .harness = "own timer (std.Io awake clock): warm-up, then equal batches",
        .machine = machine,
        .options = settings.options,
        .documents = ids,
        .jsonNotStable = json_not_stable,
        .rows = rows.items,
        .checksum = checksum,
    };
    const name = if (settings.tag) |tag| try std.fmt.allocPrint(arena, "speed-zig.{s}.json", .{tag}) else "speed-zig.json";
    const path = try std.fs.path.join(arena, &.{ settings.out, source, name });
    const text = try std.json.Stringify.valueAlloc(arena, out, .{ .whitespace = .indent_2 });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |e| return fail("{s}: {t}", .{ path, e });
    try stdout.print("std.json wrote {d} documents back as another document; wrote {s}\n", .{ json_not_stable, path });
    try stdout.flush();
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    var buf: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    stdout = &w.interface;
    const arena = init.arena.allocator();
    const settings = Settings.fromEnv(arena, init.environ_map) catch |e| switch (e) {
        error.Benchmark => std.process.exit(1),
        else => return e,
    };
    const machine = try Machine.detect(arena);
    for (excluded) |x| try stdout.print("{s}: not measured ({s})\n", .{ x.name, x.why });
    for (settings.sources) |source| {
        // Each source's inputs in an arena of their own.
        var source_arena: std.heap.ArenaAllocator = .init(gpa);
        defer source_arena.deinit();
        benchSource(source_arena.allocator(), settings, machine, source) catch |e| switch (e) {
            error.Benchmark => std.process.exit(1),
            else => {
                stdout.flush() catch {};
                std.debug.print("error: {s}: {t}\n", .{ source, e });
                std.process.exit(1);
            },
        };
    }
}
