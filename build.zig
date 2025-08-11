const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .cjk = false });

    // Local modules
    const lib = b.addStaticLibrary(.{
        .name = "zig-xtc",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.root_module.addImport("code_point", zg.module("code_point"));
    lib.root_module.addImport("Graphemes", zg.module("Graphemes"));
    lib.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    lib.root_module.addImport("Words", zg.module("Words"));
    b.installArtifact(lib);

    // Build Wren VM library
    const wren = b.addStaticLibrary(.{
        .name = "wren",
        .target = target,
        .optimize = optimize,
    });
    wren.addIncludePath(b.path("deps/wren/src/include"));
    wren.addIncludePath(b.path("deps/wren/src/vm"));
    wren.addIncludePath(b.path("deps/wren/src/optional"));
    wren.addCSourceFiles(.{
        .files = &.{
            // Core VM files
            "deps/wren/src/vm/wren_compiler.c",
            "deps/wren/src/vm/wren_core.c",
            "deps/wren/src/vm/wren_debug.c",
            "deps/wren/src/vm/wren_primitive.c",
            "deps/wren/src/vm/wren_utils.c",
            "deps/wren/src/vm/wren_value.c",
            "deps/wren/src/vm/wren_vm.c",
            // Optional modules
            "deps/wren/src/optional/wren_opt_meta.c",
            "deps/wren/src/optional/wren_opt_random.c",
        },
        .flags = &.{
            "-std=c99",
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
        },
    });
    // math is required
    wren.linkSystemLibrary("m");
    b.installArtifact(wren);

    // CLI executable: xtc
    const exe = b.addExecutable(.{
        .name = "xtc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("code_point", zg.module("code_point"));
    exe.root_module.addImport("Graphemes", zg.module("Graphemes"));
    exe.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    exe.root_module.addImport("Words", zg.module("Words"));
    exe.addIncludePath(b.path("deps/wren/src/include"));
    exe.linkLibrary(wren);

    const pretty = b.dependency("pretty", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("pretty", pretty.module("pretty"));
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    unit_tests.root_module.addImport("pretty", pretty.module("pretty"));
    unit_tests.root_module.addImport("code_point", zg.module("code_point"));
    unit_tests.root_module.addImport("Graphemes", zg.module("Graphemes"));
    unit_tests.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    unit_tests.root_module.addImport("Words", zg.module("Words"));
    unit_tests.addIncludePath(b.path("deps/wren/src/include"));
    unit_tests.linkLibrary(wren);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Trace formatter is now a library module used by main
}
