const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .musl } });
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .cjk = false });

    const ansi = b.addModule("ansi", .{
        .root_source_file = b.path("src/lib/libansi.zig"),
    });

    const wren = b.addModule("wren", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/fiberscript/vm.zig"),
    });

    wren.addImport("ansi", ansi);

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
    wren.addCMacro("abort", "zig_abort");

    const libwren = b.addLibrary(.{
        .linkage = .static,
        .name = "wren",
        .root_module = wren,
    });

    libwren.linkLibC();

    // Create WASM-specific Wren library
    const libwren_wasm = b.addStaticLibrary(.{
        .name = "wren-wasm",
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        }),
        .optimize = optimize,
        .strip = false,
    });

    libwren_wasm.addIncludePath(b.path("deps/wren/src/include"));
    libwren_wasm.addIncludePath(b.path("deps/wren/src/vm"));
    libwren_wasm.addIncludePath(b.path("deps/wren/src/optional"));
    libwren_wasm.addCSourceFiles(.{
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
            "-g",
            "-std=c99",
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
            "-O3",
        },
    });

    libwren_wasm.linkLibC();

    const xtc = b.addModule("xtc", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    xtc.addImport("ansi", ansi);

    //    xtc.addImport("code_point", zg.module("code_point"));
    xtc.addImport("Graphemes", zg.module("Graphemes"));
    xtc.addImport("DisplayWidth", zg.module("DisplayWidth"));
    xtc.addImport("Words", zg.module("Words"));

    const exe = b.addExecutable(.{
        .name = "xtc",
        .root_module = xtc,
    });

    exe.linkSystemLibrary("m");
    exe.linkLibrary(libwren);

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "xtc",
        .root_module = xtc,
    });

    exe_check.linkSystemLibrary("m");
    exe_check.linkLibrary(libwren);

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

    unit_tests.linkLibrary(libwren);

    b.installArtifact(unit_tests);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setEnvironmentVariable("TEST_VERBOSE", "true");
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);

    // WASM build target using WASI for stdout access
    const wasm_exe = b.addExecutable(.{
        .name = "xtc",
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        }),
        .optimize = .ReleaseFast,
    });

    // Disable entry and export specific functions like Wisp
    wasm_exe.entry = .disabled;
    wasm_exe.root_module.export_symbol_names = &[_][]const u8{
        "xtc_hello",
        "xtc_render",
        "xtc_init_session",
        "xtc_process_frame",
        "xtc_render_frame",
        "xtc_keypress",
        "xtc_resize",
        "xtc_cleanup",
        "wasm_alloc",
        "wasm_free",
    };

    // Link dependencies for WASI
    wasm_exe.root_module.addImport("ansi", ansi);
    wasm_exe.root_module.addImport("Graphemes", zg.module("Graphemes"));
    wasm_exe.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    wasm_exe.root_module.addImport("Words", zg.module("Words"));

    // Link WASM-specific Wren library
    wasm_exe.linkLibrary(libwren_wasm);

    const wasm_step = b.step("wasm", "Build WASM library");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

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

    web_dist_step.dependOn(&bun_build_cmd.step);

    // const install_docs = b.addInstallDirectory(.{
    //     .source_dir = exe.getEmittedDocs(),
    //     .install_dir = .prefix,
    //     .install_subdir = "doc",
    // });

    //    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    //  docs_step.dependOn(&install_docs.step);
}
