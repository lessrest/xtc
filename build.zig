const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .cjk = false });

    // Local modules
    const xml_mod = b.createModule(.{ .root_source_file = b.path("deps/zig-xml/mod.zig") });
    const tracer_mod = b.createModule(.{ .root_source_file = b.path("deps/tracer/mod.zig") });
    xml_mod.addImport("tracer", tracer_mod);

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
    lib.root_module.addImport("xml", xml_mod);
    b.installArtifact(lib);

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
    exe.root_module.addImport("xml", xml_mod);
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("code_point", zg.module("code_point"));
    unit_tests.root_module.addImport("Graphemes", zg.module("Graphemes"));
    unit_tests.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    unit_tests.root_module.addImport("Words", zg.module("Words"));
    unit_tests.root_module.addImport("xml", xml_mod);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
