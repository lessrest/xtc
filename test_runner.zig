const std = @import("std");
const builtin = @import("builtin");
const stdio = @import("src/stdio.zig");
const ansi = @import("ansi");

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main() !void {
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    const allocator = fba.allocator();

    const env = Env.init(allocator);
    defer env.deinit(allocator);

    var slowest = SlowTracker.init(allocator, 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    const printer = Printer.init();
    printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    // Create a single TreePrinter for verbose mode
    const TreePrinter = ansi.TreePrinter(ansi.AnsiWriter(std.fs.File.Writer));
    var ansi_writer = ansi.AnsiWriter(std.fs.File.Writer).init(std.io.getStdErr().writer());
    var tree_printer = if (env.verbose) TreePrinter.init(allocator, ansi_writer) else undefined;
    defer if (env.verbose) tree_printer.deinit();

    // Store failures for concise mode
    var failures = std.ArrayList(FailureInfo).init(allocator);
    defer failures.deinit();

    // Debug info used to print module/file headings and stack traces
    const dbg_info: ?*std.debug.SelfInfo = std.debug.getSelfDebugInfo() catch null;

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            t.func() catch |err| {
                printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    var last_heading_path: ?[]const u8 = null;
    var module_test_count: usize = 0;
    var module_fail_count: usize = 0;

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(t);
        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
                continue;
            }
        }

        const friendly_name = blk: {
            const name = t.name;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test")) {
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
            }
            break :blk name;
        };

        // Print a heading when switching test module/file based on the function's source path
        if (dbg_info) |di| {
            if (getFunctionFilePath(di, allocator, t.func)) |path| {
                if (last_heading_path) |lh| {
                    if (!std.mem.eql(u8, lh, path)) {
                        // Finish previous module display in concise mode
                        if (!env.verbose and module_test_count > 0) {
                            printer.fmt("\n", .{});
                        }
                        module_test_count = 0;
                        module_fail_count = 0;
                        last_heading_path = path;
                        if (env.verbose) {
                            // Exit current module in tree if needed
                            if (tree_printer.indent_level > 0) {
                                tree_printer.exit();
                            }
                            // Enter new module
                            try tree_printer.enter();
                            try tree_printer.writePrefix(false);
                            try ansi_writer.setBold();
                            try ansi_writer.setForegroundRgb(150, 150, 255); // Light blue for module names
                            try ansi_writer.writeAll(path);
                            try ansi_writer.resetStyle();
                            printer.fmt("\n", .{});
                        } else {
                            printer.fmt("{s} ", .{path});
                        }
                    }
                } else {
                    last_heading_path = path;
                    if (env.verbose) {
                        // Enter first module
                        try tree_printer.enter();
                        try tree_printer.writePrefix(false);
                        try ansi_writer.setBold();
                        try ansi_writer.setForegroundRgb(150, 150, 255); // Light blue for module names
                        try ansi_writer.writeAll(path);
                        try ansi_writer.resetStyle();
                        printer.fmt("\n", .{});
                    } else {
                        printer.fmt("{s} ", .{path});
                    }
                }
            }
        }

        current_test = friendly_name;
        std.testing.allocator_instance = .{};

        // Capture stdout/stderr using stdio module
        var capture = stdio.CaptureContext.init(allocator);
        defer capture.deinit();

        capture.beginCapture() catch {};
        const result = t.func();
        capture.endCapture() catch {};

        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name);
        module_test_count += 1;

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            // Always store for later display
            try failures.append(.{
                .test_name = try allocator.dupe(u8, friendly_name),
                .error_name = try allocator.dupe(u8, "Memory Leak"),
                .trace = null,
                .file_path = if (last_heading_path) |p| try allocator.dupe(u8, p) else null,
                .output = try allocator.dupe(u8, capture.getCombinedOutput()),
            });
        }

        if (result) |_| {
            pass += 1;
            if (env.verbose) {
                const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                // Enter test level
                try tree_printer.enter();
                const is_last_test = (env.filter != null) or (fail > 0 and env.fail_first);
                tree_printer.setHasMore(!is_last_test);
                try tree_printer.writePrefix(is_last_test);
                try ansi_writer.setForegroundRgb(0, 200, 0); // Green for pass
                try ansi_writer.writeAll("✓ ");
                try ansi_writer.resetStyle();
                try ansi_writer.print("{s} ({d:.2}ms)", .{ friendly_name, ms });
                // if (capture.getCombinedOutput().len > 0) {
                //     try ansi_writer.writeAll("\n");
                //     try tree_printer.writeVerticals();
                //     try ansi_writer.setForegroundRgb(128, 128, 128); // Gray for output
                //     try tree_printer.writeWrappedText(capture.getCombinedOutput(), 70);
                //     try ansi_writer.resetStyle();
                // }
                printer.fmt("\n", .{});
                tree_printer.exit();
            } else {
                printer.fmt(".", .{});
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
                if (env.verbose) {
                    const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                    // Enter test level
                    try tree_printer.enter();
                    const is_last_test = (env.filter != null) or (fail > 0 and env.fail_first);
                    tree_printer.setHasMore(!is_last_test);
                    try tree_printer.writePrefix(is_last_test);
                    try ansi_writer.setForegroundRgb(200, 200, 0); // Yellow for skip
                    try ansi_writer.writeAll("⊘ ");
                    try ansi_writer.resetStyle();
                    try ansi_writer.print("{s} ({d:.2}ms) [skipped]", .{ friendly_name, ms });
                    // if (capture.getCombinedOutput().len > 0) {
                    //     try ansi_writer.writeAll("\n");
                    //     try tree_printer.writeVerticals();
                    //     try ansi_writer.setForegroundRgb(128, 128, 128); // Gray for output
                    //     try tree_printer.writeWrappedText(capture.getCombinedOutput(), 70);
                    //     try ansi_writer.resetStyle();
                    // }
                    printer.fmt("\n", .{});
                    tree_printer.exit();
                } else {
                    printer.fmt(".", .{});
                }
            },
            else => {
                status = .fail;
                fail += 1;
                module_fail_count += 1;

                // Always store failure for later display
                try failures.append(.{
                    .test_name = try allocator.dupe(u8, friendly_name),
                    .error_name = try allocator.dupe(u8, @errorName(err)),
                    .trace = if (@errorReturnTrace()) |trace| try copyStackTrace(allocator, trace.*) else null,
                    .file_path = if (last_heading_path) |p| try allocator.dupe(u8, p) else null,
                    .output = try allocator.dupe(u8, capture.getCombinedOutput()),
                });

                if (env.verbose) {
                    const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                    // Enter test level
                    try tree_printer.enter();
                    const is_last_test = env.fail_first;
                    tree_printer.setHasMore(!is_last_test);
                    try tree_printer.writePrefix(is_last_test);
                    try ansi_writer.setForegroundRgb(255, 0, 0); // Red for fail
                    try ansi_writer.writeAll("✗ ");
                    try ansi_writer.resetStyle();
                    try ansi_writer.print("{s} ({d:.2}ms) - {s}", .{ friendly_name, ms, @errorName(err) });
                    // if (capture.getCombinedOutput().len > 0) {
                    //     try ansi_writer.writeAll("\n");
                    //     try tree_printer.writeVerticals();
                    //     try ansi_writer.setForegroundRgb(255, 100, 100); // Light red for error output
                    //     try tree_printer.writeWrappedText(capture.getCombinedOutput(), 70);
                    //     try ansi_writer.resetStyle();
                    // }
                    printer.fmt("\n", .{});
                    tree_printer.exit();
                } else {
                    printer.fmt("!", .{});
                }

                if (env.fail_first) {
                    break;
                }
            },
        }
    }

    // Finish last module display
    if (!env.verbose and module_test_count > 0) {
        printer.fmt("\n", .{});
    } else if (env.verbose and tree_printer.indent_level > 0) {
        // Exit last module in tree
        tree_printer.exit();
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            t.func() catch |err| {
                printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    // Display failures for both modes
    if (failures.items.len > 0) {
        printer.fmt("\n", .{});

        // Group failures by test
        var current_failure_test: ?[]const u8 = null;
        for (failures.items) |failure| {
            const show_test_header = if (current_failure_test) |cft|
                !std.mem.eql(u8, cft, failure.test_name)
            else
                true;

            if (show_test_header) {
                current_failure_test = failure.test_name;
                if (env.verbose) {
                    printer.fmt("{s}\n", .{BORDER});
                    printer.status(.fail, "FAILED: {s} - {s}\n", .{ failure.test_name, failure.error_name });
                    printer.fmt("{s}\n", .{BORDER});
                } else {
                    printer.status(.fail, "\n✗ {s} - {s}\n", .{ failure.test_name, failure.error_name });
                }
            }

            if (env.verbose) {
                if (failure.trace) |trace| {
                    dumpAllStackFrames(trace);
                }
                if (failure.output.len > 0) {
                    printer.fmt("\nCaptured output:\n{s}\n", .{failure.output});
                }
            } else {
                if (failure.trace) |trace| {
                    dumpConciseStackTrace(trace, failure.test_name);
                }
            }
        }
        printer.fmt("\n", .{});
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    if (env.verbose) {
        printer.fmt("\n", .{});
        try slowest.display(printer);
    }
    printer.fmt("\n", .{});
    std.posix.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    out: std.fs.File.Writer,

    fn init() Printer {
        return .{
            .out = std.io.getStdErr().writer(),
        };
    }

    fn fmt(self: Printer, comptime format: []const u8, args: anytype) void {
        std.fmt.format(self.out, format, args) catch unreachable;
    }

    fn status(self: Printer, s: Status, comptime format: []const u8, args: anytype) void {
        const color = switch (s) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            else => "",
        };
        const out = self.out;
        out.writeAll(color) catch @panic("writeAll failed?!");
        std.fmt.format(out, format, args) catch @panic("std.fmt.format failed?!");
        self.fmt("\x1b[0m", .{});
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    timer: std.time.Timer,

    fn init(allocator: Allocator, count: u32) SlowTracker {
        const timer = std.time.Timer.start() catch @panic("failed to start timer");
        var slowest = SlowestQueue.init(allocator, {});
        slowest.ensureTotalCapacity(count) catch @panic("OOM");
        return .{
            .max = count,
            .timer = timer,
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: SlowTracker) void {
        self.slowest.deinit();
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer.reset();
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
        var timer = self.timer;
        const ns = timer.lap();

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.removeMin();
        slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker, printer: Printer) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.removeMinOrNull()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    fn init(allocator: Allocator) Env {
        return .{
            .verbose = readEnvBool(allocator, "TEST_VERBOSE", false),
            .fail_first = readEnvBool(allocator, "TEST_FAIL_FIRST", false),
            .filter = readEnv(allocator, "TEST_FILTER"),
        };
    }

    fn deinit(self: Env, allocator: Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    fn readEnv(allocator: Allocator, key: []const u8) ?[]const u8 {
        const v = std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return null;
            }
            std.log.warn("failed to get env var {s} due to err {}", .{ key, err });
            return null;
        };
        return v;
    }

    fn readEnvBool(allocator: Allocator, key: []const u8, deflt: bool) bool {
        const value = readEnv(allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
            if (@errorReturnTrace()) |trace| {
                dumpAllStackFrames(trace.*);
                emitMatcherFailureLine(ct, "panic", trace.*);
            }
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn dumpTestStackTrace(stack_trace: std.builtin.StackTrace) void {
    // Inspired by std.debug.writeStackTrace but simplified and filtered for test frames.
    var stderr = std.io.getStdErr().writer();
    const tty_config = std.io.tty.detectConfig(std.io.getStdErr());
    var dbg = std.debug.getSelfDebugInfo() catch return;

    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);
    while (frames_left != 0) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        const address = return_address -| 1;

        const module = dbg.getModuleForAddress(address) catch {
            // ignore unknown frames
            continue;
        };
        const si = module.getSymbolAtAddress(dbg.allocator, address) catch {
            // ignore frames without symbols
            continue;
        };
        defer if (si.source_location) |sl| dbg.allocator.free(sl.file_name);

        // Only include frames for actual test functions: symbol names start with "test." in Zig tests
        if (!std.mem.startsWith(u8, si.name, "test.")) continue;

        // Emit matcher-friendly single line similar to std: file:line:col: 0xADDR in test.xxx (test)
        if (si.source_location) |sl| {
            tty_config.setColor(stderr, .bold) catch {};
            stderr.print("{s}:{d}:{d}", .{ sl.file_name, sl.line, sl.column }) catch {};
            tty_config.setColor(stderr, .reset) catch {};
        } else {
            stderr.writeAll("???:?:?") catch {};
        }
        stderr.writeAll(": ") catch {};
        tty_config.setColor(stderr, .dim) catch {};
        stderr.print("0x{x} in {s} ({s})\n", .{ address, si.name, si.compile_unit_name }) catch {};
        tty_config.setColor(stderr, .reset) catch {};
    }
}

fn dumpAllStackFrames(stack_trace: std.builtin.StackTrace) void {
    const stderr = std.io.getStdErr().writer();
    if (std.debug.getSelfDebugInfo() catch null) |dbg| {
        const tty_config = std.io.tty.detectConfig(std.io.getStdErr());
        std.debug.writeStackTrace(stack_trace, stderr, dbg, tty_config) catch {};
    }
}

fn emitMatcherFailureLine(test_name: []const u8, error_name: []const u8, stack_trace: std.builtin.StackTrace) void {
    const stderr = std.io.getStdErr().writer();
    if (std.debug.getSelfDebugInfo() catch null) |dbg| {
        var frame_index: usize = 0;
        var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);
        while (frames_left != 0) : ({
            frames_left -= 1;
            frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
        }) {
            const return_address = stack_trace.instruction_addresses[frame_index];
            const address = return_address -| 1;
            const module = dbg.getModuleForAddress(address) catch continue;
            const si = module.getSymbolAtAddress(dbg.allocator, address) catch continue;
            defer if (si.source_location) |sl| dbg.allocator.free(sl.file_name);
            if (!std.mem.startsWith(u8, si.name, "test.")) continue;
            if (si.source_location) |sl| {
                // Print matcher-friendly one-liner with source line content.
                // Format: [xtc-test] file:line:col: test "name" - ErrorName: <source line>
                stderr.print("[xtc-test] {s}:{d}:{d}: test \"{s}\" - {s}: ", .{ sl.file_name, sl.line, sl.column, test_name, error_name }) catch {};
                printSourceLineOnly(stderr, sl) catch {};
                stderr.writeByte('\n') catch {};
            }
            break;
        }
    }
}

fn printSourceLineOnly(writer: anytype, sl: std.debug.SourceLocation) !void {
    var f = try std.fs.cwd().openFile(sl.file_name, .{});
    defer f.close();
    var buf: [4096]u8 = undefined;
    var amt_read = try f.read(buf[0..]);
    var current_line_start: usize = 0;
    var next_line: usize = 1;
    while (next_line != sl.line) {
        const slice = buf[current_line_start..amt_read];
        if (std.mem.indexOfScalar(u8, slice, '\n')) |pos| {
            next_line += 1;
            if (pos == slice.len - 1) {
                amt_read = try f.read(buf[0..]);
                current_line_start = 0;
            } else current_line_start += pos + 1;
        } else if (amt_read < buf.len) {
            return error.EndOfFile;
        } else {
            amt_read = try f.read(buf[0..]);
            current_line_start = 0;
        }
    }
    const slice = buf[current_line_start..amt_read];
    if (std.mem.indexOfScalar(u8, slice, '\n')) |pos| {
        const line = slice[0..pos];
        std.mem.replaceScalar(u8, line, '\t', ' ');
        try writer.writeAll(line);
    } else {
        const line = slice;
        std.mem.replaceScalar(u8, line, '\t', ' ');
        try writer.writeAll(line);
    }
}

fn getFunctionFilePath(dbg: *std.debug.SelfInfo, allocator: std.mem.Allocator, func: anytype) ?[]const u8 {
    // Best-effort: get symbol/source for the function pointer. Use address - 1 for consistency.
    const addr: usize = @intFromPtr(func);
    const module = dbg.getModuleForAddress(addr) catch return null;
    const si = module.getSymbolAtAddress(dbg.allocator, addr) catch return null;
    if (si.source_location) |sl| {
        const dir = std.fs.cwd().realpathAlloc(allocator, ".") catch return null;
        const relative_path = std.fs.path.relative(allocator, dir, sl.file_name) catch return null;
        return relative_path;
    }
    return null;
}

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}

const FailureInfo = struct {
    test_name: []const u8,
    error_name: []const u8,
    trace: ?std.builtin.StackTrace,
    file_path: ?[]const u8,
    output: []const u8,
};

fn copyStackTrace(allocator: Allocator, trace: std.builtin.StackTrace) !std.builtin.StackTrace {
    var copy = trace;
    const addresses = try allocator.alloc(usize, trace.instruction_addresses.len);
    @memcpy(addresses, trace.instruction_addresses);
    copy.instruction_addresses = addresses;
    return copy;
}

fn dumpConciseStackTrace(stack_trace: std.builtin.StackTrace, test_name: []const u8) void {
    _ = test_name;
    const stderr = std.io.getStdErr().writer();
    const dbg = std.debug.getSelfDebugInfo() catch return;

    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);
    var shown_frames: usize = 0;
    const max_frames = 5; // Limit frames in concise mode

    while (frames_left != 0 and shown_frames < max_frames) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        const address = return_address -| 1;

        const module = dbg.getModuleForAddress(address) catch continue;
        const si = module.getSymbolAtAddress(dbg.allocator, address) catch continue;
        defer if (si.source_location) |sl| dbg.allocator.free(sl.file_name);

        // Skip non-test frames and internal testing framework
        if (!std.mem.startsWith(u8, si.name, "test.")) continue;

        if (si.source_location) |sl| {
            // Concise format: file:line:col: function_name
            stderr.print("  {s}:{d}:{d}: ", .{ sl.file_name, sl.line, sl.column }) catch {};

            // Extract just the function name part
            if (std.mem.lastIndexOf(u8, si.name, ".")) |idx| {
                const func_name = si.name[idx + 1 ..];
                stderr.print("{s}\n", .{func_name}) catch {};
            } else {
                stderr.print("{s}\n", .{si.name}) catch {};
            }
            shown_frames += 1;
        }
    }
}
