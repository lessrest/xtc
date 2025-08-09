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

    // Build Trealla C library (minimal: no FFI, SSL, threads, readline)
    const trealla = b.addStaticLibrary(.{
        .name = "trealla",
        .target = target,
        .optimize = optimize,
    });
    trealla.addIncludePath(b.path("deps/trealla/src"));
    trealla.addIncludePath(b.path("deps/trealla/src/isocline/include"));
    trealla.addCSourceFiles(.{
        .files = &.{
            // core src
            "deps/trealla/src/base64.c",
            "deps/trealla/src/bif_atts.c",
            "deps/trealla/src/bif_bboard.c",
            "deps/trealla/src/bif_control.c",
            "deps/trealla/src/bif_csv.c",
            "deps/trealla/src/bif_database.c",
            // exclude bif_ffi.c when NOFFI
            "deps/trealla/src/bif_format.c",
            "deps/trealla/src/bif_functions.c",
            "deps/trealla/src/bif_maps.c",
            "deps/trealla/src/bif_os.c",
            "deps/trealla/src/bif_posix.c",
            "deps/trealla/src/bif_predicates.c",
            "deps/trealla/src/bif_sort.c",
            "deps/trealla/src/bif_sregex.c",
            "deps/trealla/src/bif_streams.c",
            "deps/trealla/src/bif_tasks.c",
            // exclude threads when NOTHREADS
            "deps/trealla/src/compile.c",
            "deps/trealla/src/heap.c",
            "deps/trealla/src/history.c",
            // NOTE: exclude deps/trealla/src/library.c (we provide g_libs in shim)
            "deps/trealla/src/list.c",
            "deps/trealla/src/module.c",
            "deps/trealla/src/network.c",
            "deps/trealla/src/parser.c",
            "deps/trealla/src/print.c",
            "deps/trealla/src/prolog.c",
            "deps/trealla/src/query.c",
            "deps/trealla/src/skiplist.c",
            "deps/trealla/src/terms.c",
            "deps/trealla/src/toplevel.c",
            "deps/trealla/src/unify.c",
            "deps/trealla/src/utf8.c",
            "deps/trealla/src/version.c",
            // imath and sre
            "deps/trealla/src/imath/imath.c",
            "deps/trealla/src/imath/imrat.c",
            "deps/trealla/src/sre/re.c",
            // bundled isocline (tiny line editor)
            "deps/trealla/src/isocline/src/isocline.c",
            // minimal embedded library shim
            "deps/trealla/shim/g_libs_empty.c",
        },
        .flags = &.{
            "-std=c99",
            "-D_GNU_SOURCE",
            // feature toggles for minimal build
            "-DNOFFI=1",
            "-DNOSSL=1",
            "-DNOTHREADS=1",
            // use bundled isocline, avoid readline/editline deps
            "-DUSE_ISOCLINE=1",
            // common warnings similar to upstream
            "-Wall",
            "-Wextra",
            "-Wno-unused-but-set-variable",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
        },
    });
    // math is required
    trealla.linkSystemLibrary("m");
    b.installArtifact(trealla);

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
    exe.linkLibrary(trealla);

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
    unit_tests.root_module.addImport("xml", xml_mod);
    unit_tests.linkLibrary(trealla);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
