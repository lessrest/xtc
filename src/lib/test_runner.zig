const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi");
const stdio = ansi.stdio;
const treenest = ansi.nest;
const dank = ansi.dank;

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?*TestCase = null;

const Tree = treenest.TreeNest(std.fs.File.Writer);
const Dank = dank.Dank(std.fs.File.Writer);

var current_tree: *Tree = undefined;

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
        tree: *Tree,
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

        // const nothing = stdio.captureOutputFromCall(self.func, &lines, allocator);
        // if (nothing) |_| {
        //     self.status = .pass;
        // } else |err| {
        //     self.status = .fail;
        //     self.error_value = err;
        //     if (@errorReturnTrace()) |trace| {
        //         self.stack_trace = try copyStackTrace(allocator, trace.*);
        //     }
        //     try failures.append(self);
        // }

        if (self.func()) |_| {
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

        try self.displayTestResult(allocator, tree, verbose);
    }

    fn displayTestResult(
        case: *TestCase,
        allocator: Allocator,
        tree: *Tree,
        verbose: bool,
    ) !void {
        _ = allocator; // autofix
        const ms = @as(f64, @floatFromInt(case.duration_ns)) / 1_000_000.0;
        var dk = tree.dk();

        if (verbose) {
            switch (case.status) {
                .pass => try dk.testPass(case.friendly_name, ms),
                .fail => {
                    const err_name = if (case.error_value) |err| @errorName(err) else "unknown";
                    try dk.testFail(case.friendly_name, err_name, ms);
                },
                .skip => try dk.testSkip(case.friendly_name),
                .leak => try dk.testFail(case.friendly_name, "memory leak", ms),
                .pending => try dk.testPending(case.friendly_name),
            }
        } else {
            // Concise mode
            try dk.testCompact(case.status == .pass);
        }
    }
};

fn copyStackTrace(allocator: Allocator, trace: std.builtin.StackTrace) !std.builtin.StackTrace {
    return std.builtin.StackTrace{
        .index = trace.index,
        .instruction_addresses = try allocator.dupe(usize, trace.instruction_addresses),
    };
}

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
        tree: *Tree,
        verbose: bool,
        failures: *std.ArrayList(*TestCase),
    ) !void {
        current_tree = tree;

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

        try group.header(allocator, tree, verbose);

        for (group.setup_funcs.items) |setup_func| {
            setup_func() catch |err| {
                try tree.dk().errorMsg(try std.fmt.allocPrint(allocator, "setup failed: {s}", .{@errorName(err)}));
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

        try tree.newline();

        // Run teardown functions
        for (group.teardown_funcs.items) |teardown_func| {
            teardown_func() catch |err| {
                try tree.dk().errorMsg(try std.fmt.allocPrint(allocator, "teardown failed: {s}", .{@errorName(err)}));
                return err;
            };
        }
    }

    fn header(self: *TestGroup, allocator: Allocator, tree: *Tree, verbose: bool) !void {
        _ = allocator; // autofix
        const path = std.mem.trimLeft(u8, self.path, "src/");
        if (verbose) {
            try tree.line(self.path);
        } else {
            const padding = 24 - @min(24, path.len);
            for (0..padding) |_| {
                try tree.raw(" ");
            }

            const location = std.fs.path.dirname(path) orelse "";
            if (location.len > 0) {
                try tree.styled(location, .{ .fg = treenest.Color.gray });
                try tree.styled("/", .{ .fg = treenest.Color.rgb(150, 150, 160) });
            }

            const name = std.fs.path.basename(path);
            const nameWithoutExtension = std.mem.trimRight(u8, name, ".zig");
            try tree.styled(nameWithoutExtension, .{ .fg = treenest.Color.rgb(150, 150, 170) });
            try tree.raw(" ");
        }
    }
};

fn getFunctionFilePath(
    dbg_info: *std.debug.SelfInfo,
    allocator: Allocator,
    func: std.builtin.TestFn,
) !?[]const u8 {
    const module = try dbg_info.getModuleForAddress(@intFromPtr(func.func));
    const symbol_info = try module.getSymbolAtAddress(allocator, @intFromPtr(func.func));

    return symbol_info.source_location.?.file_name;
}

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
                try getFunctionFilePath(di, self.allocator, t)
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
                return a.tests.items.len < b.tests.items.len;
            }
        }.compare);
    }

    fn run(self: *TestSuite) !void {
        const stdout = std.io.getStdOut().writer();
        var tree = treenest.treeNest(self.allocator, stdout);
        defer tree.deinit();

        // Run all groups
        for (self.groups.items) |*group| {
            try group.run(
                self.allocator,
                &self.slowest,
                self.env.filter,
                self.env.fail_first,
                &tree,
                self.env.verbose,
                &self.failures,
            );

            if (self.env.fail_first and self.fail_count > 0) {
                break;
            }
        }

        for (self.groups.items) |*group| {
            for (group.tests.items) |*case| {
                switch (case.status) {
                    .pass => self.pass_count += 1,
                    .fail => self.fail_count += 1,
                    .skip => self.skip_count += 1,
                    .leak => self.leak_count += 1,
                    .pending => {},
                }
            }
        }

        try self.displayResults(&tree);
    }

    fn displayResults(self: *TestSuite, tree: *Tree) !void {
        var dk = tree.dk();

        // Display failures
        if (self.failures.items.len > 0) {
            for (self.failures.items) |failure| {
                if (self.env.verbose) {
                    try dk.errorMsg(try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ failure.friendly_name, failure.errorName() }));

                    if (failure.stack_trace) |trace| {
                        try ansi.dumpConciseStackTrace(tree, trace);
                    }
                    if (failure.output.len > 0) {
                        for (failure.output) |line| {
                            try dk.subprocessOutput(line.text, line.kind == .err);
                        }
                    }
                } else {
                    if (failure.stack_trace) |trace| {
                        try tree.newline();
                        try ansi.dumpConciseStackTrace(tree, trace);
                        //                        try emitMatcherFailureLine(tree, failure.friendly_name, failure.errorName(), trace);
                        if (failure.output.len > 0) {
                            for (failure.output) |line| {
                                try dk.subprocessOutput(line.text, line.kind == .err);
                            }
                        }
                    }
                }
            }
        }

        // Display summary
        const total_tests = self.pass_count + self.fail_count;

        try tree.line(try std.fmt.allocPrint(self.allocator, "{d} of {d} test{s} passed", .{
            self.pass_count,
            total_tests,
            if (total_tests != 1) "s" else "",
        }));

        if (self.skip_count > 0) {
            try tree.line(try std.fmt.allocPrint(self.allocator, "{d} test{s} skipped", .{ self.skip_count, if (self.skip_count != 1) "s" else "" }));
        }

        if (self.leak_count > 0) {
            try tree.line(try std.fmt.allocPrint(self.allocator, "{d} test{s} leaked", .{ self.leak_count, if (self.leak_count != 1) "s" else "" }));
        }

        // if (self.env.verbose) {
        //     try self.slowest.display(tree);
        // }
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
    var ok = true;
    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var suite = try TestSuite.init(arena_allocator);
        defer suite.deinit();

        // Build test hierarchy from builtin test functions
        try suite.buildFromTestFunctions();

        // Run the test suite
        try suite.run();
        ok = suite.fail_count == 0;
    }

    // Exit with appropriate code
    std.posix.exit(if (ok) 0 else 1);
}

pub const panic = ansi.panic;

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

    fn display(self: *SlowTracker, tree: anytype) !void {
        var slowest = self.slowest;
        try tree.dk().section("slowest tests");
        defer tree.end();

        while (slowest.removeMinOrNull()) |info| {
            try tree.dk().timing(info.name, info.ns);
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

const FailureInfo = struct {
    test_name: []const u8,
    error_name: []const u8,
    trace: ?std.builtin.StackTrace,
    file_path: ?[]const u8,
    output: std.ArrayList(stdio.Line),
};
