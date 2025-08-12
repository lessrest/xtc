const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .cjk = false });

    const ansi = b.addModule("ansi", .{
        .root_source_file = b.path("src/lib/libansi.zig"),
    });

    const wren = b.addModule("wren", .{
        .target = target,
        .optimize = optimize,
    });

    wren.addIncludePath(b.path("deps/wren/src/include"));
    wren.addIncludePath(b.path("deps/wren/src/vm"));
    wren.addIncludePath(b.path("deps/wren/src/optional"));
    wren.addCSourceFiles(.{
        .files = &.{
            "deps/wren/src/vm/wren_compiler.c",
            "deps/wren/src/vm/wren_core.c",
            "deps/wren/src/vm/wren_debug.c",
            "deps/wren/src/vm/wren_primitive.c",
            "deps/wren/src/vm/wren_utils.c",
            "deps/wren/src/vm/wren_value.c",
            "deps/wren/src/vm/wren_vm.c",
            "deps/wren/src/optional/wren_opt_meta.c",
            "deps/wren/src/optional/wren_opt_random.c",
        },
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Wno-unused-parameter" },
    });

    const libwren = b.addStaticLibrary(.{
        .name = "wren",
        .root_module = wren,
    });

    const xtc = b.addModule("xtc", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const pretty = b.dependency("pretty", .{ .target = target, .optimize = optimize });

    xtc.addImport("ansi", ansi);

    xtc.addImport("code_point", zg.module("code_point"));
    xtc.addImport("Graphemes", zg.module("Graphemes"));
    xtc.addImport("DisplayWidth", zg.module("DisplayWidth"));
    xtc.addImport("Words", zg.module("Words"));

    xtc.addImport("pretty", pretty.module("pretty"));

    const exe = b.addExecutable(.{
        .name = "xtc",
        .root_module = xtc,
        .optimize = optimize,
    });

    exe.linkSystemLibrary("m");
    exe.linkLibrary(libwren);

    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .name = "xtc-test-suite",
        .root_module = xtc,
        .optimize = .Debug,
        .test_runner = .{
            .path = b.path("src/lib/test_runner.zig"),
            .mode = .simple,
        },
    });

    unit_tests.linkLibrary(libwren);

    b.installArtifact(unit_tests);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc",
    });

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
