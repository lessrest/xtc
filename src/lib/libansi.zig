pub usingnamespace @import("AnsiWriter.zig");
pub usingnamespace @import("TreePrinter.zig");
pub const stdio = @import("stdio.zig");
pub const nest = @import("treenest.zig");
pub const dank = @import("dank.zig");
pub const abort = @import("abort.zig");

const std = @import("std");
const ThreadContext = std.debug.ThreadContext;
const StackIterator = std.debug.StackIterator;
const getContext = std.debug.getContext;

pub const panic = struct {
    /// Prints the message to stderr without a newline and then traps.
    ///
    /// Explicit calls to `@panic` lower to calling this function.
    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();

        const stderr = std.io.getStdErr().writer();
        _ = stderr.write("\x1b[0m\x1b[?25h\x1b[?1049l\n") catch {};

        _ = stderr.writeAll(msg) catch {};

        nosuspend abort.do_abort(ra orelse @returnAddress()) catch {};
        std.posix.exit(1);
    }

    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        _ = found;
        call("sentinel mismatch", null);
    }

    pub fn unwrapError(err: anyerror) noreturn {
        _ = &err;
        call("attempt to unwrap error", null);
    }

    pub fn outOfBounds(index: usize, len: usize) noreturn {
        _ = index;
        _ = len;
        call("index out of bounds", null);
    }

    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        _ = start;
        _ = end;
        call("start index is larger than end index", null);
    }

    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        _ = accessed;
        call("access of inactive union field", null);
    }

    pub fn sliceCastLenRemainder(src_len: usize) noreturn {
        _ = src_len;
        call("slice length does not divide exactly into destination elements", null);
    }

    pub fn reachedUnreachable() noreturn {
        call("reached unreachable code", null);
    }

    pub fn unwrapNull() noreturn {
        call("attempt to use null value", null);
    }

    pub fn castToNull() noreturn {
        call("cast causes pointer to be null", null);
    }

    pub fn incorrectAlignment() noreturn {
        call("incorrect alignment", null);
    }

    pub fn invalidErrorCode() noreturn {
        call("invalid error code", null);
    }

    pub fn castTruncatedData() noreturn {
        call("integer cast truncated bits", null);
    }

    pub fn negativeToUnsigned() noreturn {
        call("attempt to cast negative value to unsigned integer", null);
    }

    pub fn integerOverflow() noreturn {
        call("integer overflow", null);
    }

    pub fn shlOverflow() noreturn {
        call("left shift overflowed bits", null);
    }

    pub fn shrOverflow() noreturn {
        call("right shift overflowed bits", null);
    }

    pub fn divideByZero() noreturn {
        call("division by zero", null);
    }

    pub fn exactDivisionRemainder() noreturn {
        call("exact division produced remainder", null);
    }

    pub fn integerPartOutOfBounds() noreturn {
        call("integer part of floating point value out of bounds", null);
    }

    pub fn corruptSwitch() noreturn {
        call("switch on corrupt value", null);
    }

    pub fn shiftRhsTooBig() noreturn {
        call("shift amount is greater than the type size", null);
    }

    pub fn invalidEnumValue() noreturn {
        call("invalid enum value", null);
    }

    pub fn forLenMismatch() noreturn {
        call("for loop over objects with non-equal lengths", null);
    }

    pub fn memcpyLenMismatch() noreturn {
        call("@memcpy arguments have non-equal lengths", null);
    }

    pub fn memcpyAlias() noreturn {
        call("@memcpy arguments alias", null);
    }

    pub fn noreturnReturned() noreturn {
        call("'noreturn' function returned", null);
    }
};

pub fn dumpFuckItAllTrace(tree: anytype, start_addr: usize) !void {
    var context: ThreadContext = undefined;
    const has_context = getContext(&context);
    const debug_info = try std.debug.getSelfDebugInfo();

    var it = (if (has_context) blk: {
        break :blk StackIterator.initWithContext(start_addr, debug_info, &context) catch null;
    } else null) orelse StackIterator.init(start_addr, null);
    defer it.deinit();

    while (it.next()) |return_address| {
        try printLastUnwindError(&it, debug_info, tree);

        // On arm64 macOS, the address of the last frame is 0x0 rather than 0x1 as on x86_64 macOS,
        // therefore, we do a check for `return_address == 0` before subtracting 1 from it to avoid
        // an overflow. We do not need to signal `StackIterator` as it will correctly detect this
        // condition on the subsequent iteration and return `null` thus terminating the loop.
        // same behaviour for x86-windows-msvc
        const address = return_address -| 1;
        try printSourceAtAddress(debug_info, tree, address);
    } else try printLastUnwindError(&it, debug_info, tree);
}

fn printLastUnwindError(it: *StackIterator, debug_info: *std.debug.SelfInfo, tree: anytype) !void {
    _ = it;
    _ = debug_info;
    _ = tree;
}
pub fn printSourceAtAddress(debug_info: *std.debug.SelfInfo, tree: anytype, address: usize) !void {
    const module = debug_info.getModuleForAddress(address) catch |err| switch (err) {
        error.MissingDebugInfo, error.InvalidDebugInfo => return try printUnknownSource(debug_info, tree, address),
        else => return err,
    };

    const symbol_info = module.getSymbolAtAddress(debug_info.allocator, address) catch |err| switch (err) {
        error.MissingDebugInfo, error.InvalidDebugInfo => return try printUnknownSource(debug_info, tree, address),
        else => return err,
    };
    defer if (symbol_info.source_location) |sl| debug_info.allocator.free(sl.file_name);

    return printLineInfo(
        tree,
        symbol_info.source_location,
        address,
        symbol_info.name,
        symbol_info.compile_unit_name,
        module,
    );
}

fn printLineInfo(
    tree: anytype,
    source_location: ?std.debug.SourceLocation,
    address: usize,
    symbol_name: []const u8,
    compile_unit_name: []const u8,
    module: *std.debug.SelfInfo.Module,
) !void {
    _ = module; // autofix
    _ = compile_unit_name; // autofix
    _ = address; // autofix
    nosuspend {
        if (source_location) |*sl| {
            try tree.dk().stackFrame(sl.file_name, sl.line, sl.column, symbol_name);
        } else {
            try tree.dk().stackFrame("???:?:?", 0, 0, symbol_name);
        }

        // Show the matching source code line if possible
        if (source_location) |sl| {
            var f = try std.fs.cwd().openFile(sl.file_name, .{});
            defer f.close();
            const contents = try f.readToEndAlloc(tree.allocator, 1024 * 1024);
            defer tree.allocator.free(contents);
            try tree.dk().sourceBlock(contents, sl.line, sl.column, 3);
        }
    }
}

fn printUnknownSource(debug_info: *std.debug.SelfInfo, tree: anytype, address: usize) !void {
    _ = debug_info;
    _ = tree;
    _ = address;
}

pub fn dumpConciseStackTrace(tree: anytype, stack_trace: std.builtin.StackTrace) !void {
    const dbg = try std.debug.getSelfDebugInfo();
    const allocator = tree.allocator;

    // Get current working directory for path stripping
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);
    var shown_frames: usize = 0;
    const max_frames = 50;

    var previous_dirname: ?[]const u8 = null;

    var context_lines: u32 = 3;

    while (frames_left != 0 and shown_frames < max_frames) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        const address = return_address -| 1;

        const module = try dbg.getModuleForAddress(address);
        const si = try module.getSymbolAtAddress(dbg.allocator, address);
        defer if (si.source_location) |sl| dbg.allocator.free(sl.file_name);

        //        if (!std.mem.startsWith(u8, si.name, "test.")) continue;

        const Color = nest.Color;
        if (si.source_location) |sl| {
            const func_name = if (std.mem.lastIndexOf(u8, si.name, ".")) |idx|
                si.name[idx + 1 ..]
            else if (std.mem.indexOf(u8, si.name, "__anon")) |idx|
                si.name[0..idx]
            else
                si.name;

            const abs_path = std.fs.realpathAlloc(allocator, sl.file_name) catch sl.file_name;

            const dirname = std.fs.path.dirname(abs_path) orelse ".";
            const basename = std.fs.path.basename(abs_path);

            if (std.mem.indexOf(u8, abs_path, "test_runner.zig")) |_| {
                break;
            }

            // if (previous_dirname) |prev| {
            //     if (!std.mem.eql(u8, prev, dirname)) {
            //     }
            // }

            try tree.newline();

            previous_dirname = dirname;

            const filetypes = enum { zig, c, other };
            const ext = std.fs.path.extension(basename);
            const filetype = if (std.mem.eql(u8, ext, ".zig")) filetypes.zig else if (std.mem.eql(u8, ext, ".c")) filetypes.c else filetypes.other;

            if (std.mem.indexOf(u8, dirname, "/zig-0.14.1/") != null and
                std.mem.indexOf(u8, dirname, "/lib/") != null)
            {
                if (std.mem.indexOf(u8, dirname, "/lib/")) |lib_idx| {
                    const after_lib = dirname[lib_idx + 5 ..];
                    try tree.dk().compose(&.{
                        nest.colored(func_name, Color.rgb(207, 199, 164)).onColor(Color.rgb(69, 67, 96)).justifyRight(tree.allocator, 30),
                        nest.dim(" ").onColor(Color.rgb(69, 67, 96)),
                        nest.dim("  "),
                        nest.colored("<zig>", Color.rgb(243, 216, 12)),
                        nest.dim("/"),
                        nest.colored(after_lib, Color.rgb(211, 221, 230)),
                        nest.dim("/"),
                        nest.colored(basename, switch (filetype) {
                            .zig => Color.rgb(232, 230, 185),
                            .c => Color.rgb(233, 175, 183),
                            .other => Color.rgb(201, 212, 222),
                        }),
                        nest.dim(":"),
                        tree.dk().integerPart(sl.line),
                        nest.dim(":"),
                        tree.dk().integerPart(sl.column),
                    }).joined("");
                } else {
                    return error.InvalidDebugInfo;
                }
            } else {
                if (std.mem.startsWith(u8, abs_path, cwd)) {
                    try tree.dk().compose(&.{
                        nest.colored(func_name, Color.rgb(208, 248, 245)).onColor(Color.rgb(69, 67, 96)).bold().justifyRight(tree.allocator, 30),
                        nest.dim(" ").onColor(Color.rgb(69, 67, 96)),
                        nest.dim("  "),
                        nest.colored(dirname[cwd.len + 1 ..], Color.rgb(211, 221, 230)),
                        nest.dim("/"),
                        nest.colored(basename, switch (filetype) {
                            .zig => Color.rgb(232, 230, 185),
                            .c => Color.rgb(233, 175, 183),
                            .other => Color.rgb(201, 212, 222),
                        }).bold(),
                        nest.dim(":"),
                        tree.dk().integerPart(sl.line),
                        nest.dim(":"),
                        tree.dk().integerPart(sl.column),
                    }).joined("");
                } else {
                    try tree.dk().compose(&.{
                        nest.colored(func_name, Color.rgb(195, 195, 195)).onColor(Color.rgb(69, 67, 96)).justifyRight(tree.allocator, 30),
                        nest.dim(" ").onColor(Color.rgb(69, 67, 96)),
                        nest.dim("  "),
                        nest.colored(dirname[cwd.len + 1 ..], Color.rgb(211, 221, 230)),
                        nest.dim("/"),
                        nest.colored(basename, switch (filetype) {
                            .zig => Color.rgb(232, 230, 185),
                            .c => Color.rgb(233, 175, 183),
                            .other => Color.rgb(201, 212, 222),
                        }).bold(),
                        nest.dim(":"),
                        tree.dk().integerPart(sl.line),
                        nest.dim(":"),
                        tree.dk().integerPart(sl.column),
                    }).joined("");
                }
            }

            var f = try std.fs.cwd().openFile(sl.file_name, .{});
            defer f.close();
            const contents = try f.readToEndAlloc(tree.allocator, 1024 * 1024);
            defer tree.allocator.free(contents);
            try tree.dk().sourceBlock(contents, sl.line, sl.column, context_lines);
            if (context_lines > 0) context_lines -= 1;

            shown_frames += 1;
        } else {
            try tree.dk().spaces(6);
            try tree.dk().stackFrame(si.name, 0, 0, "???");
        }
    }
    try tree.dk().separator(72);
}
