const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .cjk = false });

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

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("code_point", zg.module("code_point"));
    unit_tests.root_module.addImport("Graphemes", zg.module("Graphemes"));
    unit_tests.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    unit_tests.root_module.addImport("Words", zg.module("Words"));
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
