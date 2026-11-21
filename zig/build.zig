const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const haus = b.addModule("haus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build test`: the unit tests, the C ABI's tests and the conformance suite.
    const test_step = b.step("test", "Run the unit tests and the conformance suite");
    const unit = b.addTest(.{ .root_module = haus });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // The C ABI (include/haus.h): a static library, and its tests.
    const c_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "haus", .module = haus }},
    });
    const c_lib = b.addLibrary(.{ .name = "haus", .root_module = c_module, .linkage = .static });
    c_lib.installHeader(b.path("include/haus.h"), "haus.h");
    b.installArtifact(c_lib);
    const c_tests = b.addTest(.{ .root_module = c_module });
    test_step.dependOn(&b.addRunArtifact(c_tests).step);

    // `zig build suite`: the conformance suite (../test-suite).
    const options = b.addOptions();
    options.addOptionPathDirectory("suite_dir", b.path("../test-suite"));
    const suite_module = b.createModule(.{
        .root_source_file = b.path("test/suite.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "haus", .module = haus },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    const suite = b.addExecutable(.{ .name = "haus-suite", .root_module = suite_module });
    const run_suite = b.addRunArtifact(suite);
    run_suite.has_side_effects = true;
    const suite_step = b.step("suite", "Run the conformance suite (../test-suite)");
    suite_step.dependOn(&run_suite.step);
    test_step.dependOn(&run_suite.step);

    // The runner of the differential fuzzer (../fuzz).
    const runner = b.addExecutable(.{
        .name = "zig-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "haus", .module = haus }},
        }),
    });
    const install_runner = b.addInstallArtifact(runner, .{});
    const runner_step = b.step("fuzz-runner", "Build the fuzz runner (zig-out/bin/zig-runner)");
    runner_step.dependOn(&install_runner.step);
}
