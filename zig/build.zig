const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The Zig module, for packages that depend on this one:
    // `b.dependency("haus", .{}).module("haus")`.
    const haus = b.addModule("haus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The C ABI (include/haus.h): libhaus, its header and a pkg-config
    // file. Static by default (`-Dlinkage=dynamic` for the shared library).
    // Dependents link `dep.artifact("haus")`.
    const linkage = b.option(std.builtin.LinkMode, "linkage", "libhaus: static (default) or dynamic") orelse .static;
    const c_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        // Position-independent, so that a C program built as PIE (the
        // default of most Linux compilers) can link the static library.
        .pic = true,
        .imports = &.{.{ .name = "haus", .module = haus }},
    });
    const c_lib = b.addLibrary(.{
        .name = "haus",
        .root_module = c_module,
        .linkage = linkage,
        .version = if (linkage == .dynamic) .{ .major = 0, .minor = 1, .patch = 0 } else null,
    });
    // A C toolchain other than Zig's can link the static library without
    // Zig's runtime.
    c_lib.bundle_compiler_rt = true;
    c_lib.installHeader(b.path("include/haus.h"), "haus.h");
    b.installArtifact(c_lib);
    const pc = b.addWriteFiles().add("haus.pc",
        \\prefix=${pcfiledir}/../..
        \\libdir=${prefix}/lib
        \\includedir=${prefix}/include
        \\
        \\Name: haus
        \\Description: The haus data format: parser, writers, canonical form, schemas (C ABI of the Zig binding)
        \\URL: https://haus-fmt.org
        \\Version: 0.1.0
        \\Libs: -L${libdir} -lhaus
        \\Cflags: -I${includedir}
        \\
    );
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, "pkgconfig/haus.pc").step);

    // Everything below needs the rest of the repository (the suites, the
    // shared examples, the official packages): not when used as a package.
    if (b.dep_prefix.len != 0) return;

    // Where the examples and tests find the shared files.
    const paths = b.addOptions();
    paths.addOptionPathUntracked("examples_dir", b.path("../examples"));
    paths.addOptionPathUntracked("extensions_dir", b.path("../extensions"));
    const paths_module = paths.createModule();

    // `zig build test`: the unit tests, the C ABI's tests (in Zig and in
    // C), the profiles' vectors and the conformance suite.
    const test_step = b.step("test", "Run the unit tests, the C ABI's tests, the profiles' vectors and the conformance suite");
    const unit = b.addTest(.{ .root_module = haus });
    test_step.dependOn(&b.addRunArtifact(unit).step);
    const c_tests = b.addTest(.{ .root_module = c_module });
    test_step.dependOn(&b.addRunArtifact(c_tests).step);

    const c_test = b.addExecutable(.{
        .name = "c-api-test",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_test.root_module.addCSourceFile(.{ .file = b.path("test/c_api_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    c_test.root_module.addIncludePath(b.path("include"));
    // The C test and the C example link libhaus statically, whatever is installed.
    const static_lib = if (linkage == .static) c_lib else b.addLibrary(.{ .name = "haus-static", .root_module = c_module, .linkage = .static });
    c_test.root_module.linkLibrary(static_lib);
    const run_c_test = b.addRunArtifact(c_test);
    run_c_test.addDirectoryArg(b.path("../extensions"));
    run_c_test.addDirectoryArg(b.path("../examples"));
    run_c_test.addDirectoryArg(b.path("test"));
    run_c_test.has_side_effects = true;
    test_step.dependOn(&run_c_test.step);

    const profiles = b.addExecutable(.{
        .name = "haus-profiles",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/profiles.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "haus", .module = haus },
                .{ .name = "build_options", .module = paths_module },
            },
        }),
    });
    const run_profiles = b.addRunArtifact(profiles);
    run_profiles.has_side_effects = true;
    test_step.dependOn(&run_profiles.step);

    // `zig build suite`: the conformance suite (../test-suite).
    const suite_options = b.addOptions();
    suite_options.addOptionPathDirectory("suite_dir", b.path("../test-suite"));
    const suite_module = b.createModule(.{
        .root_source_file = b.path("test/suite.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "haus", .module = haus },
            .{ .name = "build_options", .module = suite_options.createModule() },
        },
    });
    const suite = b.addExecutable(.{ .name = "haus-suite", .root_module = suite_module });
    const run_suite = b.addRunArtifact(suite);
    run_suite.has_side_effects = true;
    const suite_step = b.step("suite", "Run the conformance suite (../test-suite)");
    suite_step.dependOn(&run_suite.step);
    test_step.dependOn(&run_suite.step);

    // `zig build examples`: every example, its output checked. `zig build
    // quickstart`, `order` and `quickstart-c` run one.
    const examples_step = b.step("examples", "Run the examples and check their output");
    const quickstart_out = @embedFile("examples/quickstart.out");
    inline for (.{
        .{ "quickstart", "examples/quickstart.zig", quickstart_out },
        .{ "order", "examples/order.zig", @embedFile("examples/order.out") },
    }) |ex| {
        const exe = b.addExecutable(.{
            .name = ex[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "haus", .module = haus },
                    .{ .name = "paths", .module = paths_module },
                },
            }),
        });
        b.step(ex[0], "Run examples/" ++ ex[0] ++ ".zig").dependOn(&b.addRunArtifact(exe).step);
        const checked = b.addRunArtifact(exe);
        checked.expectStdOutEqual(ex[2]);
        examples_step.dependOn(&checked.step);
    }
    const c_example = b.addExecutable(.{
        .name = "quickstart-c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_example.root_module.addCSourceFile(.{ .file = b.path("examples/c/quickstart.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    c_example.root_module.addIncludePath(b.path("include"));
    c_example.root_module.linkLibrary(static_lib);
    const run_c_example = b.addRunArtifact(c_example);
    run_c_example.addDirectoryArg(b.path("../examples"));
    b.step("quickstart-c", "Run examples/c/quickstart.c").dependOn(&run_c_example.step);
    const checked_c = b.addRunArtifact(c_example);
    checked_c.addDirectoryArg(b.path("../examples"));
    // The same output as the Zig quickstart. On Windows, C's stdout is in
    // text mode and ends lines with \r\n.
    checked_c.expectStdOutEqual(if (target.result.os.tag == .windows)
        std.mem.replaceOwned(u8, b.graph.arena, quickstart_out, "\n", "\r\n") catch @panic("OOM")
    else
        quickstart_out);
    examples_step.dependOn(&checked_c.step);

    // The runner of the differential fuzzer (../fuzz). It finds the schema
    // files of the schema and JSON fuzzers in the checkout it is built from.
    const runner_options = b.addOptions();
    runner_options.addOption([]const u8, "repo_dir", b.pathResolve(&.{b.root.joinString(b.graph.arena, "..") catch @panic("OOM")}));
    const runner = b.addExecutable(.{
        .name = "zig-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "haus", .module = haus },
                .{ .name = "build_options", .module = runner_options.createModule() },
            },
        }),
    });
    const install_runner = b.addInstallArtifact(runner, .{});
    const runner_step = b.step("fuzz-runner", "Build the fuzz runner (zig-out/bin/zig-runner)");
    runner_step.dependOn(&install_runner.step);
}
