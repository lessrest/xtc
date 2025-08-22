const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 'magic' module
    const magic = b.createModule(.{
        .root_source_file = b.path("src/magic_numbers.zig"),
        .target = target,
        .optimize = optimize,
    });

    // shared zstd embed helper
    const zstdembed = b.createModule(.{
        .root_source_file = b.path("src/lib/zstd_embed.zig"),
        .target = target,
        .optimize = optimize,
    });

    //| Options

    // Display width
    const cjk = b.option(bool, "cjk", "Ambiguous code points are wide (display width: 2)") orelse false;
    const dwp_options = b.addOptions();
    dwp_options.addOption(bool, "cjk", cjk);

    // Visible Controls
    const c0_width = b.option(
        i4,
        "c0_width",
        "C0 controls have this width (default: 0, <BS> <Del> default -1)",
    );
    dwp_options.addOption(?i4, "c0_width", c0_width);
    const c1_width = b.option(
        i4,
        "c1_width",
        "C1 controls have this width (default: 0)",
    );
    dwp_options.addOption(?i4, "c1_width", c1_width);

    //| Offset size
    const fat_offset = b.option(bool, "fat_offset", "Offsets in iterators and data structures will be u64") orelse false;
    const size_config = b.addOptions();
    size_config.addOption(bool, "fat_offset", fat_offset);

    //| Code generation

    // Grapheme break
    const gbp_gen_exe = b.addExecutable(.{
        .name = "gbp",
        .root_source_file = b.path("codegen/gbp.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_gbp_gen_exe = b.addRunArtifact(gbp_gen_exe);
    const gbp_gen_out = run_gbp_gen_exe.addOutputFileArg("gbp.bin");

    const wbp_gen_exe = b.addExecutable(.{
        .name = "wbp",
        .root_source_file = b.path("codegen/wbp.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_wbp_gen_exe = b.addRunArtifact(wbp_gen_exe);
    const wbp_gen_out = run_wbp_gen_exe.addOutputFileArg("wbp.bin");

    const dwp_gen_exe = b.addExecutable(.{
        .name = "dwp",
        .root_source_file = b.path("codegen/dwp.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    dwp_gen_exe.root_module.addOptions("options", dwp_options);
    const run_dwp_gen_exe = b.addRunArtifact(dwp_gen_exe);
    const dwp_gen_out = run_dwp_gen_exe.addOutputFileArg("dwp.bin");

    // Normalization properties
    const canon_gen_exe = b.addExecutable(.{
        .name = "canon",
        .root_source_file = b.path("codegen/canon.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_canon_gen_exe = b.addRunArtifact(canon_gen_exe);
    const canon_gen_out = run_canon_gen_exe.addOutputFileArg("canon.bin");

    const compat_gen_exe = b.addExecutable(.{
        .name = "compat",
        .root_source_file = b.path("codegen/compat.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_compat_gen_exe = b.addRunArtifact(compat_gen_exe);
    const compat_gen_out = run_compat_gen_exe.addOutputFileArg("compat.bin");

    const hangul_gen_exe = b.addExecutable(.{
        .name = "hangul",
        .root_source_file = b.path("codegen/hangul.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_hangul_gen_exe = b.addRunArtifact(hangul_gen_exe);
    const hangul_gen_out = run_hangul_gen_exe.addOutputFileArg("hangul.bin");

    const normp_gen_exe = b.addExecutable(.{
        .name = "normp",
        .root_source_file = b.path("codegen/normp.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_normp_gen_exe = b.addRunArtifact(normp_gen_exe);
    const normp_gen_out = run_normp_gen_exe.addOutputFileArg("normp.bin");

    const ccc_gen_exe = b.addExecutable(.{
        .name = "ccc",
        .root_source_file = b.path("codegen/ccc.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_ccc_gen_exe = b.addRunArtifact(ccc_gen_exe);
    const ccc_gen_out = run_ccc_gen_exe.addOutputFileArg("ccc.bin");

    const gencat_gen_exe = b.addExecutable(.{
        .name = "gencat",
        .root_source_file = b.path("codegen/gencat.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_gencat_gen_exe = b.addRunArtifact(gencat_gen_exe);
    const gencat_gen_out = run_gencat_gen_exe.addOutputFileArg("gencat.bin");

    const fold_gen_exe = b.addExecutable(.{
        .name = "fold",
        .root_source_file = b.path("codegen/fold.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_fold_gen_exe = b.addRunArtifact(fold_gen_exe);
    const fold_gen_out = run_fold_gen_exe.addOutputFileArg("fold.bin");

    // Numeric types
    const num_gen_exe = b.addExecutable(.{
        .name = "numeric",
        .root_source_file = b.path("codegen/numeric.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_num_gen_exe = b.addRunArtifact(num_gen_exe);
    const num_gen_out = run_num_gen_exe.addOutputFileArg("numeric.bin");

    // Letter case properties
    const case_prop_gen_exe = b.addExecutable(.{
        .name = "case_prop",
        .root_source_file = b.path("codegen/case_prop.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_case_prop_gen_exe = b.addRunArtifact(case_prop_gen_exe);
    const case_prop_gen_out = run_case_prop_gen_exe.addOutputFileArg("case_prop.bin");

    // Uppercase mappings
    const upper_gen_exe = b.addExecutable(.{
        .name = "upper",
        .root_source_file = b.path("codegen/upper.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_upper_gen_exe = b.addRunArtifact(upper_gen_exe);
    const upper_gen_out = run_upper_gen_exe.addOutputFileArg("upper.bin");

    // Lowercase mappings
    const lower_gen_exe = b.addExecutable(.{
        .name = "lower",
        .root_source_file = b.path("codegen/lower.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_lower_gen_exe = b.addRunArtifact(lower_gen_exe);
    const lower_gen_out = run_lower_gen_exe.addOutputFileArg("lower.bin");

    const scripts_gen_exe = b.addExecutable(.{
        .name = "scripts",
        .root_source_file = b.path("codegen/scripts.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_scripts_gen_exe = b.addRunArtifact(scripts_gen_exe);
    const scripts_gen_out = run_scripts_gen_exe.addOutputFileArg("scripts.bin");

    const core_gen_exe = b.addExecutable(.{
        .name = "core",
        .root_source_file = b.path("codegen/core_props.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_core_gen_exe = b.addRunArtifact(core_gen_exe);
    const core_gen_out = run_core_gen_exe.addOutputFileArg("core_props.bin");

    const props_gen_exe = b.addExecutable(.{
        .name = "props",
        .root_source_file = b.path("codegen/props.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_props_gen_exe = b.addRunArtifact(props_gen_exe);
    const props_gen_out = run_props_gen_exe.addOutputFileArg("props.bin");

    // Zstd-compress generated data as an optional pack step
    const pack_zstd = b.step("pack-zstd", "Compress generated tables with zstd");

    const zstd_gbp = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_gbp.addArg("-o");
    const gbp_zst = zstd_gbp.addOutputFileArg("gbp.bin.zst");
    zstd_gbp.addFileArg(gbp_gen_out);
    pack_zstd.dependOn(&zstd_gbp.step);

    const zstd_wbp = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_wbp.addArg("-o");
    const wbp_zst = zstd_wbp.addOutputFileArg("wbp.bin.zst");
    zstd_wbp.addFileArg(wbp_gen_out);
    pack_zstd.dependOn(&zstd_wbp.step);

    const zstd_dwp = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_dwp.addArg("-o");
    const dwp_zst = zstd_dwp.addOutputFileArg("dwp.bin.zst");
    zstd_dwp.addFileArg(dwp_gen_out);
    pack_zstd.dependOn(&zstd_dwp.step);

    const zstd_canon = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_canon.addArg("-o");
    const canon_zst = zstd_canon.addOutputFileArg("canon.bin.zst");
    zstd_canon.addFileArg(canon_gen_out);
    pack_zstd.dependOn(&zstd_canon.step);

    const zstd_compat = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_compat.addArg("-o");
    const compat_zst = zstd_compat.addOutputFileArg("compat.bin.zst");
    zstd_compat.addFileArg(compat_gen_out);
    pack_zstd.dependOn(&zstd_compat.step);

    const zstd_hangul = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_hangul.addArg("-o");
    const hangul_zst = zstd_hangul.addOutputFileArg("hangul.bin.zst");
    zstd_hangul.addFileArg(hangul_gen_out);
    pack_zstd.dependOn(&zstd_hangul.step);

    const zstd_normp = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_normp.addArg("-o");
    const normp_zst = zstd_normp.addOutputFileArg("normp.bin.zst");
    zstd_normp.addFileArg(normp_gen_out);
    pack_zstd.dependOn(&zstd_normp.step);

    const zstd_ccc = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_ccc.addArg("-o");
    const ccc_zst = zstd_ccc.addOutputFileArg("ccc.bin.zst");
    zstd_ccc.addFileArg(ccc_gen_out);
    pack_zstd.dependOn(&zstd_ccc.step);

    const zstd_gencat = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_gencat.addArg("-o");
    const gencat_zst = zstd_gencat.addOutputFileArg("gencat.bin.zst");
    zstd_gencat.addFileArg(gencat_gen_out);
    pack_zstd.dependOn(&zstd_gencat.step);

    const zstd_fold = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_fold.addArg("-o");
    const fold_zst = zstd_fold.addOutputFileArg("fold.bin.zst");
    zstd_fold.addFileArg(fold_gen_out);
    pack_zstd.dependOn(&zstd_fold.step);

    const zstd_numeric = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_numeric.addArg("-o");
    const numeric_zst = zstd_numeric.addOutputFileArg("numeric.bin.zst");
    zstd_numeric.addFileArg(num_gen_out);
    pack_zstd.dependOn(&zstd_numeric.step);

    const zstd_case_prop = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_case_prop.addArg("-o");
    const case_prop_zst = zstd_case_prop.addOutputFileArg("case_prop.bin.zst");
    zstd_case_prop.addFileArg(case_prop_gen_out);
    pack_zstd.dependOn(&zstd_case_prop.step);

    const zstd_upper = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_upper.addArg("-o");
    const upper_zst = zstd_upper.addOutputFileArg("upper.bin.zst");
    zstd_upper.addFileArg(upper_gen_out);
    pack_zstd.dependOn(&zstd_upper.step);

    const zstd_lower = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_lower.addArg("-o");
    const lower_zst = zstd_lower.addOutputFileArg("lower.bin.zst");
    zstd_lower.addFileArg(lower_gen_out);
    pack_zstd.dependOn(&zstd_lower.step);

    const zstd_scripts = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_scripts.addArg("-o");
    const scripts_zst = zstd_scripts.addOutputFileArg("scripts.bin.zst");
    zstd_scripts.addFileArg(scripts_gen_out);
    pack_zstd.dependOn(&zstd_scripts.step);

    const zstd_core = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_core.addArg("-o");
    const core_props_zst = zstd_core.addOutputFileArg("core_props.bin.zst");
    zstd_core.addFileArg(core_gen_out);
    pack_zstd.dependOn(&zstd_core.step);

    const zstd_props = b.addSystemCommand(&.{ "zstd", "-q", "-f", "-19" });
    zstd_props.addArg("-o");
    const props_zst = zstd_props.addOutputFileArg("props.bin.zst");
    zstd_props.addFileArg(props_gen_out);
    pack_zstd.dependOn(&zstd_props.step);

    // Modules we provide

    // Code points
    const code_point = b.addModule("code_point", .{
        .root_source_file = b.path("src/code_point.zig"),
        .target = target,
        .optimize = optimize,
    });
    code_point.addOptions("config", size_config);

    const code_point_t = b.addTest(.{
        .name = "code_point",
        .root_module = code_point,
        .target = target,
        .optimize = optimize,
    });
    const code_point_tr = b.addRunArtifact(code_point_t);

    // Graphemes
    const graphemes = b.addModule("Graphemes", .{
        .root_source_file = b.path("src/Graphemes.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphemes.addAnonymousImport("gbp", .{ .root_source_file = gbp_zst });
    graphemes.addImport("code_point", code_point);
    graphemes.addOptions("config", size_config);
    graphemes.addImport("zstdembed", zstdembed);

    const grapheme_t = b.addTest(.{
        .name = "Graphemes",
        .root_module = graphemes,
        .target = target,
        .optimize = optimize,
    });
    const grapheme_tr = b.addRunArtifact(grapheme_t);

    // Word Breaking
    const words = b.addModule("Words", .{
        .root_source_file = b.path("src/Words.zig"),
        .target = target,
        .optimize = optimize,
    });
    words.addAnonymousImport("wbp", .{ .root_source_file = wbp_zst });
    words.addImport("code_point", code_point);
    words.addImport("zstdembed", zstdembed);

    const words_t = b.addTest(.{
        .name = "WordBreak",
        .root_module = words,
        .target = target,
        .optimize = optimize,
    });
    const words_tr = b.addRunArtifact(words_t);

    // ASCII utilities
    const ascii = b.addModule("ascii", .{
        .root_source_file = b.path("src/ascii.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ascii_t = b.addTest(.{
        .name = "ascii",
        .root_module = ascii,
        .target = target,
        .optimize = optimize,
    });
    const ascii_tr = b.addRunArtifact(ascii_t);

    // Fixed pitch font display width
    const display_width = b.addModule("DisplayWidth", .{
        .root_source_file = b.path("src/DisplayWidth.zig"),
        .target = target,
        .optimize = optimize,
    });
    display_width.addAnonymousImport("dwp", .{ .root_source_file = dwp_zst });
    display_width.addImport("ascii", ascii);
    display_width.addImport("code_point", code_point);
    display_width.addImport("Graphemes", graphemes);
    display_width.addOptions("options", dwp_options); // For testing
    display_width.addImport("zstdembed", zstdembed);

    const display_width_t = b.addTest(.{
        .name = "display_width",
        .root_module = display_width,
        .target = target,
        .optimize = optimize,
    });
    const display_width_tr = b.addRunArtifact(display_width_t);

    // Normalization
    const ccc_data = b.createModule(.{
        .root_source_file = b.path("src/CombiningData.zig"),
        .target = target,
        .optimize = optimize,
    });
    ccc_data.addAnonymousImport("ccc", .{ .root_source_file = ccc_zst });
    ccc_data.addImport("zstdembed", zstdembed);

    const ccc_data_t = b.addTest(.{
        .name = "ccc_data",
        .root_module = ccc_data,
        .target = target,
        .optimize = optimize,
    });
    const ccc_data_tr = b.addRunArtifact(ccc_data_t);

    const canon_data = b.createModule(.{
        .root_source_file = b.path("src/CanonData.zig"),
        .target = target,
        .optimize = optimize,
    });
    canon_data.addAnonymousImport("canon", .{ .root_source_file = canon_zst });
    canon_data.addImport("magic", magic);
    canon_data.addImport("zstdembed", zstdembed);

    const canon_data_t = b.addTest(.{
        .name = "canon_data",
        .root_module = canon_data,
        .target = target,
        .optimize = optimize,
    });
    const canon_data_tr = b.addRunArtifact(canon_data_t);

    const compat_data = b.createModule(.{
        .root_source_file = b.path("src/CompatData.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_data.addAnonymousImport("compat", .{ .root_source_file = compat_zst });
    compat_data.addImport("magic", magic);
    compat_data.addImport("zstdembed", zstdembed);

    const compat_data_t = b.addTest(.{
        .name = "compat_data",
        .root_module = compat_data,
        .target = target,
        .optimize = optimize,
    });
    const compat_data_tr = b.addRunArtifact(compat_data_t);

    const hangul_data = b.createModule(.{
        .root_source_file = b.path("src/HangulData.zig"),
        .target = target,
        .optimize = optimize,
    });
    hangul_data.addAnonymousImport("hangul", .{ .root_source_file = hangul_zst });
    hangul_data.addImport("zstdembed", zstdembed);

    const hangul_data_t = b.addTest(.{
        .name = "hangul_data",
        .root_module = hangul_data,
        .target = target,
        .optimize = optimize,
    });
    const hangul_data_tr = b.addRunArtifact(hangul_data_t);

    const normp_data = b.createModule(.{
        .root_source_file = b.path("src/NormPropsData.zig"),
        .target = target,
        .optimize = optimize,
    });
    normp_data.addAnonymousImport("normp", .{ .root_source_file = normp_zst });
    normp_data.addImport("zstdembed", zstdembed);

    const normp_data_t = b.addTest(.{
        .name = "normp_data",
        .root_module = normp_data,
        .target = target,
        .optimize = optimize,
    });
    const normp_data_tr = b.addRunArtifact(normp_data_t);

    const norm = b.addModule("Normalize", .{
        .root_source_file = b.path("src/Normalize.zig"),
        .target = target,
        .optimize = optimize,
    });
    norm.addImport("ascii", ascii);
    norm.addImport("code_point", code_point);
    norm.addImport("CanonData", canon_data);
    norm.addImport("CombiningData", ccc_data);
    norm.addImport("CompatData", compat_data);
    norm.addImport("HangulData", hangul_data);
    norm.addImport("NormPropsData", normp_data);

    const norm_t = b.addTest(.{
        .name = "norm",
        .root_module = norm,
        .target = target,
        .optimize = optimize,
    });
    const norm_tr = b.addRunArtifact(norm_t);

    // General Category
    const gencat = b.addModule("GeneralCategories", .{
        .root_source_file = b.path("src/GeneralCategories.zig"),
        .target = target,
        .optimize = optimize,
    });
    gencat.addAnonymousImport("gencat", .{ .root_source_file = gencat_zst });
    gencat.addImport("zstdembed", zstdembed);

    const gencat_t = b.addTest(.{
        .name = "gencat",
        .root_module = gencat,
        .target = target,
        .optimize = optimize,
    });
    const gencat_tr = b.addRunArtifact(gencat_t);

    // Case folding
    const case_fold = b.addModule("CaseFolding", .{
        .root_source_file = b.path("src/CaseFolding.zig"),
        .target = target,
        .optimize = optimize,
    });
    case_fold.addAnonymousImport("fold", .{ .root_source_file = fold_zst });
    case_fold.addImport("ascii", ascii);
    case_fold.addImport("Normalize", norm);
    case_fold.addImport("zstdembed", zstdembed);

    const case_fold_t = b.addTest(.{
        .name = "case_fold",
        .root_module = case_fold,
        .target = target,
        .optimize = optimize,
    });
    const case_fold_tr = b.addRunArtifact(case_fold_t);

    // Letter case
    const letter_case = b.addModule("LetterCasing", .{
        .root_source_file = b.path("src/LetterCasing.zig"),
        .target = target,
        .optimize = optimize,
    });
    letter_case.addImport("code_point", code_point);
    letter_case.addAnonymousImport("case_prop", .{ .root_source_file = case_prop_zst });
    letter_case.addAnonymousImport("upper", .{ .root_source_file = upper_zst });
    letter_case.addAnonymousImport("lower", .{ .root_source_file = lower_zst });
    letter_case.addImport("zstdembed", zstdembed);

    const letter_case_t = b.addTest(.{
        .name = "lettercase",
        .root_module = letter_case,
        .target = target,
        .optimize = optimize,
    });
    const letter_case_tr = b.addRunArtifact(letter_case_t);

    // Scripts
    const scripts = b.addModule("Scripts", .{
        .root_source_file = b.path("src/Scripts.zig"),
        .target = target,
        .optimize = optimize,
    });
    scripts.addAnonymousImport("scripts", .{ .root_source_file = scripts_zst });
    scripts.addImport("zstdembed", zstdembed);

    const scripts_t = b.addTest(.{
        .name = "scripts",
        .root_module = scripts,
        .target = target,
        .optimize = optimize,
    });
    const scripts_tr = b.addRunArtifact(scripts_t);

    // Properties
    const properties = b.addModule("Properties", .{
        .root_source_file = b.path("src/Properties.zig"),
        .target = target,
        .optimize = optimize,
    });
    properties.addAnonymousImport("core_props", .{ .root_source_file = core_props_zst });
    properties.addAnonymousImport("props", .{ .root_source_file = props_zst });
    properties.addAnonymousImport("numeric", .{ .root_source_file = numeric_zst });
    properties.addImport("zstdembed", zstdembed);

    const properties_t = b.addTest(.{
        .name = "properties",
        .root_module = properties,
        .target = target,
        .optimize = optimize,
    });
    const properties_tr = b.addRunArtifact(properties_t);

    // Unicode Tests
    const unicode_tests = b.addTest(.{
        .root_source_file = b.path("src/unicode_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unicode_tests.root_module.addImport("Graphemes", graphemes);
    unicode_tests.root_module.addImport("Normalize", norm);
    unicode_tests.root_module.addImport("Words", words);

    const run_unicode_tests = b.addRunArtifact(unicode_tests);

    const test_step = b.step("test", "Run all module tests");
    test_step.dependOn(&run_unicode_tests.step);
    test_step.dependOn(&code_point_tr.step);
    test_step.dependOn(&display_width_tr.step);
    test_step.dependOn(&grapheme_tr.step);
    test_step.dependOn(&words_tr.step);
    test_step.dependOn(&ascii_tr.step);
    test_step.dependOn(&ccc_data_tr.step);
    test_step.dependOn(&canon_data_tr.step);
    test_step.dependOn(&compat_data_tr.step);
    test_step.dependOn(&hangul_data_tr.step);
    test_step.dependOn(&normp_data_tr.step);
    test_step.dependOn(&norm_tr.step);
    test_step.dependOn(&gencat_tr.step);
    test_step.dependOn(&case_fold_tr.step);
    test_step.dependOn(&letter_case_tr.step);
    test_step.dependOn(&scripts_tr.step);
    test_step.dependOn(&properties_tr.step);
}
