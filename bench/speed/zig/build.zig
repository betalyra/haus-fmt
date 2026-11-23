//! `zig build run` (ReleaseFast by default): the Zig speed benchmark, haus
//! against std.json on the corpus `bench convert` exported. Options are in
//! the environment (bench/README.md, "Speed (Zig)").

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // A benchmark measures release code: fast unless asked otherwise.
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default fast)") orelse .fast;
    const haus = b.dependency("haus", .{ .target = target, .optimize = optimize }).module("haus");

    const options = b.addOptions();
    // Where the manifest and the results are, from this checkout.
    options.addOption([]const u8, "bench_dir", b.pathResolve(&.{b.root.joinString(b.graph.arena, "../..") catch @panic("OOM")}));
    options.addOption([]const u8, "optimize", @tagName(optimize));

    const exe = b.addExecutable(.{
        .name = "haus-bench-speed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "haus", .module = haus },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.has_side_effects = true;
    b.step("run", "Run the speed benchmark (writes bench/.out/<source>/speed-zig.json)").dependOn(&run.step);
}
