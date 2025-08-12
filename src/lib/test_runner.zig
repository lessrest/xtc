const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi");
const stdio = ansi.stdio;

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?*TestCase = null;
var current_tree: ?*AnsiTreePrinter = null;

// Test hierarchy structures
const TestCase = struct {
    name: []const u8,
    friendly_name: []const u8,
    func: *const fn () anyerror!void,
    source_path: ?[]const u8,

    status: Status = .pending,
    error_value: ?anyerror = null,
    duration_ns: u64 = 0,
    output: []const stdio.Line = &.{},
    stack_trace: ?std.builtin.StackTrace = null,

    fn errorName(self: *TestCase) []const u8 {
        if (self.error_value) |err| {
            return @errorName(err);
        }
        return "?";
    }

    fn run(
        self: *TestCase,
        allocator: Allocator,
        timing: *SlowTracker,
        tree: *AnsiTreePrinter,
        verbose: bool,
        failures: *std.ArrayList(*TestCase),
    ) !void {
        timing.startTiming();
        defer _ = timing.endTiming(self.friendly_name);

        var lines = std.ArrayList(stdio.Line).init(allocator);
        defer lines.deinit();

        const DebugAllocator = @TypeOf(std.testing.allocator_instance);
        std.testing.allocator_instance = DebugAllocator.init;

        current_test = self;
        current_tree = tree;

        const nothing = stdio.captureOutputFromCall(self.func, &lines, allocator);
        if (nothing) |_| {
            self.status = .pass;
        } else |err| {
            self.status = .fail;
            self.error_value = err;
            if (@errorReturnTrace()) |trace| {
                self.stack_trace = try copyStackTrace(allocator, trace.*);
            }
            try failures.append(self);
        }

        self.duration_ns = timing.endTiming(self.friendly_name);

        self.output = try lines.toOwnedSlice();

        if (std.testing.allocator_instance.deinit() == .leak) {
            self.status = .leak;
        }

        try self.displayTestResult(tree, verbose);
    }

    fn displayTestResult(
        case: *TestCase,
        tree: *AnsiTreePrinter,
        verbose: bool,
    ) !void {
        const ms = @as(f64, @floatFromInt(case.duration_ns)) / 1_000_000.0;

        if (verbose) {
            const is_last = false; // todo

            tree.setHasMore(!is_last);
            try tree.writeVerticals();

            switch (case.status) {
                .pass => {
                    try tree.ansi.writeColoredText("✓ ", 0, 200, 0);
                },
                .fail, .leak => {
                    try tree.ansi.writeColoredText("✗ ", 255, 0, 0);
                },
                .skip => {
                    try tree.ansi.writeColoredText("⊘ ", 200, 200, 0);
                },
                .pending => unreachable,
            }

            try tree.print("{s} ({d:.2}ms)", .{ case.friendly_name, ms });

            if (case.status == .fail) {
                if (case.error_value) |err| {
                    try tree.print(" - {s}", .{@errorName(err)});
                }
            } else if (case.status == .skip) {
                try tree.ansi.writeColoredText(" [skipped] ", 200, 200, 0);
            } else if (case.status == .leak) {
                try tree.ansi.writeColoredText(" [memory leak] ", 255, 0, 0);
            }

            try tree.newline();
        } else {
            // Concise mode
            switch (case.status) {
                .pass => {
                    try tree.ansi.writeColoredText("▒", 0, 150, 0);
                },
                .fail, .leak => {
                    try tree.ansi.writeColoredText("█", 200, 0, 0);
                    //                    try tree.ansi.writeAll(" ");
                    try tree.ansi.resetStyle();
                },
                .skip => {
                    try tree.ansi.writeColoredText(" ", 200, 200, 0);
                },
                .pending => unreachable,
            }
        }
    }
};

const Status = enum { pending, pass, fail, skip, leak };

const TestGroup = struct {
    name: []const u8,
    path: []const u8,
    tests: std.ArrayList(TestCase),
    setup_funcs: std.ArrayList(*const fn () anyerror!void),
    teardown_funcs: std.ArrayList(*const fn () anyerror!void),

    fn init(allocator: Allocator, path: []const u8) TestGroup {
        return .{
            .name = std.fs.path.basename(path),
            .path = path,
            .tests = std.ArrayList(TestCase).init(allocator),
            .setup_funcs = std.ArrayList(*const fn () anyerror!void).init(allocator),
            .teardown_funcs = std.ArrayList(*const fn () anyerror!void).init(allocator),
        };
    }

    fn deinit(self: *TestGroup) void {
        self.tests.deinit();
        self.setup_funcs.deinit();
        self.teardown_funcs.deinit();
    }

    fn addTest(self: *TestGroup, test_case: TestCase) !void {
        try self.tests.append(test_case);
    }

    fn addSetup(self: *TestGroup, func: *const fn () anyerror!void) !void {
        try self.setup_funcs.append(func);
    }

    fn addTeardown(self: *TestGroup, func: *const fn () anyerror!void) !void {
        try self.teardown_funcs.append(func);
    }

    fn run(
        group: *TestGroup,
        allocator: Allocator,
        timing: *SlowTracker,
        filter: ?[]const u8,
        fail_first: bool,
        tree: *AnsiTreePrinter,
        verbose: bool,
        failures: *std.ArrayList(*TestCase),
    ) !void {
        // Skip empty groups
        if (group.tests.items.len == 0) return;

        // Apply filter if needed
        var has_matching_tests = false;
        if (filter) |f| {
            for (group.tests.items) |case| {
                if (!isUnnamed(case.name) and std.mem.indexOf(u8, case.name, f) != null) {
                    has_matching_tests = true;
                    break;
                }
            }
            if (!has_matching_tests) return;
        } else {
            has_matching_tests = true;
        }

        try tree.enter();
        defer tree.exit();
        try group.header(tree, verbose);

        for (group.setup_funcs.items) |setup_func| {
            setup_func() catch |err| {
                try tree.println("setup failed: {s}", .{@errorName(err)});
                return err;
            };
        }

        for (group.tests.items) |*case| {
            if (filter) |f| {
                if (!isUnnamed(case.name) and std.mem.indexOf(u8, case.name, f) == null) {
                    continue;
                }
            }

            try case.run(allocator, timing, tree, verbose, failures);

            if (fail_first and case.status == .fail) {
                break;
            }
        }

        if (!verbose) {
            try tree.ansi.writeColoredText("\n", 100, 100, 100);
        }

        // Run teardown functions
        for (group.teardown_funcs.items) |teardown_func| {
            teardown_func() catch |err| {
                try tree.println("teardown failed: {s}", .{@errorName(err)});
                return err;
            };
        }
    }

    fn header(self: *TestGroup, tree: *AnsiTreePrinter, verbose: bool) !void {
        if (verbose) {
            try tree.writePrefix(false);
            try tree.ansi.setBold();
            try tree.ansi.setForegroundRgb(150, 150, 255);
            try tree.println("{s}", .{self.path});
        } else {
            const path = std.mem.trimLeft(u8, self.path, "src/");

            const padding = 24 - path.len;
            for (0..padding) |_| {
                try tree.ansi.writeAll(" ");
            }

            const location = std.fs.path.dirname(path) orelse "";
            try tree.ansi.writeColoredText(location, 150, 150, 150);

            const name = std.fs.path.basename(path);
            const nameWithoutExtension = std.mem.trimRight(u8, name, ".zig");
            if (location.len > 0) {
                try tree.ansi.writeColoredText("/", 150, 150, 160);
            }
            try tree.ansi.writeBoldColored(nameWithoutExtension, 150, 150, 170);
            //            try tree.ansi.writeColoredText(".zig", 150, 150, 150);
            try tree.ansi.writeColoredText(" ", 100, 100, 100);
        }
    }
};

const TestSuite = struct {
    allocator: Allocator,
    groups: std.ArrayList(TestGroup),
    env: Env,
    slowest: SlowTracker,
    failures: std.ArrayList(*TestCase),

    // Statistics
    pass_count: usize = 0,
    fail_count: usize = 0,
    skip_count: usize = 0,
    leak_count: usize = 0,

    fn init(allocator: Allocator) !TestSuite {
        return .{
            .allocator = allocator,
            .groups = std.ArrayList(TestGroup).init(allocator),
            .env = Env.init(allocator),
            .slowest = SlowTracker.init(allocator, 5),
            .failures = std.ArrayList(*TestCase).init(allocator),
        };
    }

    fn deinit(self: *TestSuite) void {
        for (self.groups.items) |*group| {
            group.deinit();
        }
        self.groups.deinit();
        self.env.deinit(self.allocator);
        self.slowest.deinit();
        self.failures.deinit();
    }

    fn buildFromTestFunctions(self: *TestSuite) !void {
        const dbg_info: ?*std.debug.SelfInfo = std.debug.getSelfDebugInfo() catch null;
        var group_map = std.StringHashMap(*TestGroup).init(self.allocator);
        defer group_map.deinit();

        // First pass: organize tests into groups by source file
        for (builtin.test_functions) |t| {
            const source_path = if (dbg_info) |di|
                getFunctionFilePath(di, self.allocator, t.func)
            else
                null;

            const path = source_path orelse "unknown";

            // Get or create group for this path
            var group = if (group_map.get(path)) |g|
                g
            else blk: {
                const new_group = TestGroup.init(self.allocator, path);
                try self.groups.append(new_group);
                const group_ptr = &self.groups.items[self.groups.items.len - 1];
                try group_map.put(path, group_ptr);
                break :blk group_ptr;
            };

            // Categorize the test function
            if (isSetup(t)) {
                try group.addSetup(t.func);
            } else if (isTeardown(t)) {
                try group.addTeardown(t.func);
            } else {
                const friendly_name = extractFriendlyName(t.name);
                const test_case = TestCase{
                    .name = t.name,
                    .friendly_name = friendly_name,
                    .func = t.func,
                    .source_path = source_path,
                };
                try group.addTest(test_case);
            }
        }

        try self.sortGroups();
    }

    fn sortGroups(self: *TestSuite) !void {
        std.sort.insertion(TestGroup, self.groups.items, {}, struct {
            fn compare(context: void, a: TestGroup, b: TestGroup) bool {
                _ = context;
                return a.path.len < b.path.len;
            }
        }.compare);
    }

    fn run(self: *TestSuite) !void {
        const ansi_writer = ansi.stdout();
        var tree_printer = AnsiTreePrinter.init(self.allocator, ansi_writer);

        // Run all groups
        for (self.groups.items) |*group| {
            try group.run(
                self.allocator,
                &self.slowest,
                self.env.filter,
                self.env.fail_first,
                &tree_printer,
                self.env.verbose,
                &self.failures,
            );

            if (self.env.fail_first and self.fail_count > 0) {
                break;
            }
        }

        if (self.env.verbose) {
            try tree_printer.newline();
        }

        try self.displayResults(&tree_printer);
    }

    fn displayResults(self: *TestSuite, tree: *AnsiTreePrinter) !void {
        // Display failures
        if (self.failures.items.len > 0) {
            for (self.failures.items) |failure| {
                if (self.env.verbose) {
                    try tree.println("✗ {s}: {s}", .{ failure.friendly_name, failure.errorName() });
                    try tree.enter();
                    defer tree.exit();
                    if (failure.stack_trace) |trace| {
                        dumpAllStackFrames(trace);
                    }
                    if (failure.output.len > 0) {
                        try tree.enter();
                        defer tree.exit();

                        for (failure.output, 0..) |line, i| {
                            const has_more = i < failure.output.len - 1;
                            try tree.writePrefix(has_more);
                            if (line.kind == .out) {
                                try tree.writeWrappedText(line.text, 60);
                            } else {
                                try tree.writeWrappedText(line.text, 60);
                            }
                        }
                    }
                } else {
                    if (failure.stack_trace) |trace| {
                        try emitMatcherFailureLine(tree, failure.friendly_name, failure.errorName(), trace);
                        try dumpConciseStackTrace(tree, trace, failure.friendly_name);
                    }
                }
            }
            try tree.newline();
        }

        // Display summary
        const total_tests = self.pass_count + self.fail_count;
        try tree.println("{d} of {d} test{s} passed", .{ self.pass_count, total_tests, if (total_tests != 1) "s" else "" });

        if (self.skip_count > 0) {
            try tree.println("{d} test{s} skipped", .{ self.skip_count, if (self.skip_count != 1) "s" else "" });
        }

        if (self.leak_count > 0) {
            try tree.println("{d} test{s} leaked", .{ self.leak_count, if (self.leak_count != 1) "s" else "" });
        }

        if (self.env.verbose) {
            try tree.newline();
            try self.slowest.display(tree);
        }

        try tree.newline();
    }
};

// Helper functions
fn extractFriendlyName(full_name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, full_name, '.');
    while (it.next()) |value| {
        if (std.mem.eql(u8, value, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else full_name;
        }
    }
    return full_name;
}

fn isUnnamed(name: []const u8) bool {
    const marker = ".test_";
    const index = std.mem.indexOf(u8, name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var suite = try TestSuite.init(allocator);
    defer suite.deinit();

    // Build test hierarchy from builtin test functions
    try suite.buildFromTestFunctions();

    // Run the test suite
    try suite.run();

    // Exit with appropriate code
    std.posix.exit(if (suite.fail_count == 0) 0 else 1);
}

const AnsiTreePrinter = ansi.TreePrinter(ansi.StdoutAnsiWriter);

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
            slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                return ns;
            }
        }

        _ = slowest.removeMin();
        slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker, tree: *AnsiTreePrinter) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        try tree.println("Slowest {d} test{s}:", .{ count, if (count != 1) "s" else "" });
        while (slowest.removeMinOrNull()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            try tree.println("  {d:.2}ms\t{s}", .{ ms, info.name });
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
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{
                BORDER,
                ct.friendly_name,
                BORDER,
            });
            if (@errorReturnTrace()) |trace| {
                dumpAllStackFrames(trace.*);
                emitMatcherFailureLine(
                    current_tree.?,
                    ct.friendly_name,
                    "panic",
                    trace.*,
                ) catch {};
            }
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

const FailureInfo = struct {
    test_name: []const u8,
    error_name: []const u8,
    trace: ?std.builtin.StackTrace,
    file_path: ?[]const u8,
    output: std.ArrayList(stdio.Line),
};

fn getFunctionFilePath(dbg: *std.debug.SelfInfo, allocator: std.mem.Allocator, func: anytype) ?[]const u8 {
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

fn copyStackTrace(allocator: Allocator, trace: std.builtin.StackTrace) !std.builtin.StackTrace {
    var copy = trace;
    const addresses = try allocator.alloc(usize, trace.instruction_addresses.len);
    @memcpy(addresses, trace.instruction_addresses);
    copy.instruction_addresses = addresses;
    return copy;
}

fn dumpAllStackFrames(stack_trace: std.builtin.StackTrace) void {
    const stderr = std.io.getStdErr().writer();
    if (std.debug.getSelfDebugInfo() catch null) |dbg| {
        const tty_config = std.io.tty.detectConfig(std.io.getStdErr());
        std.debug.writeStackTrace(stack_trace, stderr, dbg, tty_config) catch {};
    }
}

fn dumpConciseStackTrace(tree: *AnsiTreePrinter, stack_trace: std.builtin.StackTrace, test_name: []const u8) !void {
    _ = test_name; // autofix
    const dbg = std.debug.getSelfDebugInfo() catch return;

    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);
    var shown_frames: usize = 0;
    const max_frames = 50;

    while (frames_left != 0 and shown_frames < max_frames) : ({
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
            try tree.print("  {s}:{d}:{d}: ", .{ sl.file_name, sl.line, sl.column });

            if (std.mem.lastIndexOf(u8, si.name, ".")) |idx| {
                const func_name = si.name[idx + 1 ..];
                try tree.print("{s}\n", .{func_name});
            } else {
                try tree.print("{s}\n", .{si.name});
            }
            shown_frames += 1;
        }
    }
}

fn emitMatcherFailureLine(
    tree: *AnsiTreePrinter,
    test_name: []const u8,
    error_name: []const u8,
    stack_trace: std.builtin.StackTrace,
) !void {
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
                try tree.writeVerticals();
                try tree.print(
                    "{s}:{d}:{d}: test \"{s}\": {s}\n",
                    .{ sl.file_name, sl.line, sl.column, test_name, error_name },
                );
                try tree.writeVerticals();
                try printSourceLineOnly(tree.ansi.writer, sl);
                try tree.newline();
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
