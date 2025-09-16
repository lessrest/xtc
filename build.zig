const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .cjk = false });

    const ansi = b.addModule("ansi", .{
        .root_source_file = b.path("src/lib/libansi.zig"),
    });

    const pretty = b.addModule("pretty", .{
        .root_source_file = b.path("src/lib/pretty.zig"),
    });

    const miniflex = b.addModule("miniflex", .{
        .root_source_file = b.path("src/miniflex/miniflex.zig"),
        .target = target,
        .optimize = optimize,
    });

    miniflex.addImport("ansi", ansi);
    miniflex.addImport("Graphemes", zg.module("Graphemes"));
    miniflex.addImport("DisplayWidth", zg.module("DisplayWidth"));
    miniflex.addImport("Words", zg.module("Words"));

    const xtc = b.addModule("xtc", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    xtc.addImport("ansi", ansi);
    xtc.addImport("pretty", pretty);
    xtc.addImport("miniflex", miniflex);

    xtc.addIncludePath(b.path("deps/wren/src/include"));
    xtc.addIncludePath(b.path("deps/wren/src/vm"));
    xtc.addIncludePath(b.path("deps/wren/src/optional"));
    xtc.addCSourceFiles(.{
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
        .flags = &.{
            "-std=c99",
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
            "-Wno-implicit",
            "-g",
            "-DDEBUG",
        },
    });
    xtc.addCMacro("abort", "zig_abort");

    // const stub = b.createModule(.{
    //     .root_source_file = b.path("src/stub.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });

    xtc.addImport("Graphemes", zg.module("Graphemes"));
    xtc.addImport("DisplayWidth", zg.module("DisplayWidth"));
    xtc.addImport("Words", zg.module("Words"));

    const exe = b.addExecutable(.{
        .name = "xtc",
        .root_module = xtc,
        //        .use_lld = true,
        //        .use_llvm = true,
    });

    exe.linkSystemLibrary("m");
    //    exe.linkLibrary(libwren);

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "xtc",
        .root_module = xtc,
    });

    exe_check.linkSystemLibrary("m");
    // exe_check.linkLibrary(libwren);

    const check_step = b.step("check", "Check the xtc executable");
    check_step.dependOn(&exe_check.step);

    const unit_tests = b.addTest(.{
        .name = "xtc-test-suite",
        .root_module = xtc,

        .test_runner = .{
            .path = b.path("src/lib/test_runner.zig"),
            .mode = .simple,
        },
    });

    const miniflextest = b.addTest(.{
        .name = "miniflex-test-suite",
        .root_module = miniflex,
        .test_runner = .{
            .path = b.path("src/lib/test_runner.zig"),
            .mode = .simple,
        },
    });

    // unit_tests.linkLibrary(libwren);

    b.installArtifact(unit_tests);
    b.installArtifact(miniflextest);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_miniflex_tests = b.addRunArtifact(miniflextest);
    run_unit_tests.setEnvironmentVariable("TEST_VERBOSE", "true");
    run_miniflex_tests.setEnvironmentVariable("TEST_VERBOSE", "true");

    var teststep = b.step("test", "Run unit tests");
    teststep.dependOn(&run_unit_tests.step);
    teststep.dependOn(&run_miniflex_tests.step);

    // // WASM build target using WASI for stdout access
    const wasm_initial_pages: u32 = 260;
    const wasm_memory_bytes: u64 = @as(u64, wasm_initial_pages) * std.wasm.page_size;
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .ofmt = .wasm,
        .abi = .musl,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }),
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    wasm_mod.single_threaded = false;

    const wasm_exe = b.addExecutable(.{ .name = "xtc", .root_module = wasm_mod });
    wasm_exe.rdynamic = true;
    wasm_exe.wasi_exec_model = .reactor;
    wasm_exe.import_memory = true;
    wasm_exe.shared_memory = true;
    wasm_exe.initial_memory = wasm_memory_bytes;
    wasm_exe.max_memory = wasm_memory_bytes * 32;

    wasm_exe.root_module.export_symbol_names = &[_][]const u8{
        "xtc_init_session",
        "xtc_process_frame",
        "xtc_render_frame",
        "xtc_keypress",
        "xtc_resize",
        "xtc_cleanup",
        "wasm_alloc",
        "wasm_free",
    };

    wasm_mod.addImport("miniflex", miniflex);
    wasm_mod.addImport("ansi", ansi);

    wasm_mod.addIncludePath(b.path("deps/wren/src/include"));
    wasm_mod.addIncludePath(b.path("deps/wren/src/vm"));
    wasm_mod.addIncludePath(b.path("deps/wren/src/optional"));
    wasm_mod.addCSourceFiles(.{
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
        .flags = &.{
            "-std=c99",
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
            "-Wno-implicit",
            "-g",
            "-DDEBUG",
        },
    });

    const wasm_step = b.step("wasm", "Build WASM library");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

    // Standalone WASM CLI executable (not a reactor)
    const wasm_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_cli.zig"),
        .target = wasm_target,
        //        .optimize = .ReleaseFast,
    });

    const wasm_cli_exe = b.addExecutable(.{
        .name = "xtc-cli",
        .root_module = wasm_cli_mod,
    });

    // Link dependencies
    wasm_cli_mod.addImport("miniflex", miniflex);

    const install_wasm_cli = b.addInstallArtifact(wasm_cli_exe, .{});

    const wasm_cli_step = b.step("wasm-cli", "Build standalone WASM CLI executable");
    wasm_cli_step.dependOn(&install_wasm_cli.step);

    // Web distribution build using Bun
    const web_dist_step = b.step("web-dist", "Build web distribution with Bun");

    // Install the WASI WASM binary
    const install_wasm_wasi = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "web-dist" } },
    });

    // Use Bun build script
    const bun_build_cmd = b.addSystemCommand(&.{ "bun", "run", "./build.js" });

    // Dependencies: build after WASM is ready
    bun_build_cmd.step.dependOn(&install_wasm_wasi.step);
    try bun_build_cmd.step.addDirectoryWatchInputFromPath(.initCwd("web"));

    web_dist_step.dependOn(&bun_build_cmd.step);

    // const install_docs = b.addInstallDirectory(.{
    //     .source_dir = exe.getEmittedDocs(),
    //     .install_dir = .prefix,
    //     .install_subdir = "doc",
    // });

    //    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    //  docs_step.dependOn(&install_docs.step);
}
