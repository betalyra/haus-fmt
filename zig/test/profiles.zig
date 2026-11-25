//! The official profiles' test vectors (../extensions/*/profiles/*.vectors.haus,
//! spec §13.3 "Profiles") against this binding's codecs (`haus.codecs`):
//! each `Accept` decodes with the codecs and encodes back to its `output`
//! (or its `value`), and each `Reject` is valid for the schema and
//! `codec-rejected` with the codecs. Run by `zig build test`.

const std = @import("std");
const haus = @import("haus");
const build_options = @import("build_options");
const Value = haus.Value;
const Allocator = std.mem.Allocator;

fn field(val: Value, key: []const u8) ?[]const u8 {
    for (val.variant.args[0].record) |f| if (std.mem.eql(u8, f.key, key)) return f.value.string;
    return null;
}

/// A looser codec than any profile's: every value its type's schema
/// accepts, kept as a host value of its own (its canonical text).
const accept_all = haus.Codec([]const u8).init("(set per type)", struct {
    fn dec(arena: Allocator, d: haus.Decoded, _: *haus.decoding.Reason) haus.decoding.CodecError![]const u8 {
        const v = haus.decoding.toValue(arena, d, null) catch return error.OutOfMemory;
        return haus.canonical(arena, v, .{}) catch error.OutOfMemory;
    }
}.dec, struct {
    fn enc(arena: Allocator, text: []const u8, _: *haus.decoding.Reason) haus.decoding.CodecError!haus.Decoded {
        const v = (haus.parse(arena, text, .{}) catch return error.OutOfMemory).value;
        return .{ .any = v };
    }
}.enc);

/// Whether decoding `text` with `codecs` is `codec-rejected`.
fn rejected(arena: Allocator, def: *const haus.schema.Def, text: []const u8, codecs: *const haus.Codecs, d: *haus.Diagnostic) bool {
    _ = haus.decoding.decodeText(arena, arena, def, text, .{ .codecs = codecs, .diagnostic = d }) catch return d.code == .@"codec-rejected";
    return false;
}

fn looserList(vec: Value) ?[]const Value {
    for (vec.variant.args[0].record) |f| if (std.mem.eql(u8, f.key, "looser")) return f.value.array;
    return null;
}

const Package = struct { dir: []const u8, profile: []const u8, codecs: []const *const haus.AnyCodec };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .initStreaming(.stdout(), io, &buf);
    const out = &stdout_writer.interface;
    var failures: usize = 0;

    const packages = [_]Package{
        .{ .dir = "money", .profile = "iso", .codecs = &haus.codecs.money.iso },
        .{ .dir = "geo", .profile = "wgs84", .codecs = &haus.codecs.geo.wgs84 },
    };
    for (packages) |p| {
        const dir = try std.fs.path.join(arena, &.{ build_options.extensions_dir, p.dir });
        const cwd = std.Io.Dir.cwd();
        const manifest = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, "package.haus" }), arena, .unlimited);
        const m = (try haus.parse(arena, manifest, .{})).value;
        var name: []const u8 = "";
        var version: []const u8 = "";
        for (m.record) |f| {
            if (std.mem.eql(u8, f.key, "name")) name = f.value.string;
            if (std.mem.eql(u8, f.key, "version")) version = f.value.string;
        }
        const module = try std.fmt.allocPrint(arena, "{s}@{s}", .{ name, version[0..std.mem.indexOfScalar(u8, version, '.').?] });
        const schema_text = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, "schema.haus" }), arena, .unlimited);
        const s = try haus.schema.load(arena, schema_text, .{ .module = module });
        var codecs = try haus.Codecs.init(arena, p.codecs);

        const vectors_path = try std.fmt.allocPrint(arena, "{s}/profiles/{s}.vectors.haus", .{ dir, p.profile });
        const vectors = (try haus.parseAll(arena, try cwd.readFileAlloc(io, vectors_path, arena, .unlimited), .{})).value;
        var passed: usize = 0;
        for (vectors, 0..) |vec, i| {
            const kind = vec.variant.tag;
            const def = s.get(field(vec, "type").?).?;
            const text = field(vec, "value").?;
            var d: haus.Diagnostic = .{};
            const ok = blk: {
                if (std.mem.eql(u8, kind, "Accept")) {
                    const decoded = haus.decoding.decodeText(arena, arena, def, text, .{ .codecs = &codecs, .diagnostic = &d }) catch break :blk false;
                    const val = haus.decoding.encode(arena, def, decoded, .{ .codecs = &codecs, .diagnostic = &d }) catch break :blk false;
                    const written = try haus.stringify(arena, val, .{ .layout = .compact });
                    const want = field(vec, "output") orelse text;
                    break :blk std.mem.eql(u8, std.mem.trimEnd(u8, written, "\n"), want);
                }
                // Valid for the shape, rejected by the rule.
                _ = haus.decoding.decodeText(arena, arena, def, text, .{ .diagnostic = &d }) catch break :blk false;
                if (!rejected(arena, def, text, &codecs, &d)) break :blk false;
                // `looser: ["T", …]`: again with, for each T, a codec that
                // accepts every value of T's schema (a host type of its
                // own); the codec for `type` still rejects the value.
                const looser = looserList(vec) orelse break :blk true;
                var list: std.ArrayList(*const haus.AnyCodec) = .empty;
                var ids: std.ArrayList([]const u8) = .empty;
                for (looser) |type_name| try ids.append(arena, try std.fmt.allocPrint(arena, "{s}#{s}", .{ module, type_name.string }));
                for (p.codecs) |c| {
                    for (ids.items) |id| {
                        if (std.mem.eql(u8, c.id, id)) break;
                    } else try list.append(arena, c);
                }
                for (ids.items) |id| {
                    const c = try arena.create(haus.AnyCodec);
                    c.* = accept_all.any;
                    c.id = id;
                    try list.append(arena, c);
                }
                var with_looser = try haus.Codecs.init(arena, list.items);
                break :blk rejected(arena, def, text, &with_looser, &d);
            };
            if (ok) passed += 1 else {
                failures += 1;
                try out.print("FAIL {s} #{d}: {s} {s} ({s}: {s})\n", .{ vectors_path, i, kind, text, d.code.name(), d.message() });
            }
        }
        try out.print("{s}/profiles/{s}.vectors.haus: {d} passed, {d} failed\n", .{ p.dir, p.profile, passed, vectors.len - passed });
    }
    try out.flush();
    if (failures > 0) std.process.exit(1);
}
