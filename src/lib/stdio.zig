const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Allocator = std.mem.Allocator;

pub const Line = struct {
    pub const Kind = enum { out, err };
    kind: Kind,
    // Nanoseconds since capture began
    t_ns: u64,
    // Owned buffer (no trailing newline)
    text: []u8,
};

pub const CaptureContext = struct {
    const Self = @This();

    allocator: Allocator,

    // Unified, tagged lines in chronological append order
    lines: *std.ArrayList(Line),

    // Synchronization for cross-thread appends
    mutex: std.Thread.Mutex = .{},

    // Original file descriptors
    original_stdout: ?posix.fd_t = null,
    original_stderr: ?posix.fd_t = null,

    // Pipe file descriptors [read, write]
    stdout_pipe: ?[2]posix.fd_t = null,
    stderr_pipe: ?[2]posix.fd_t = null,

    // Reader threads
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,

    // Capture start timestamp (ns)
    start_ns: i128 = 0,

    pub fn init(allocator: Allocator, lines: *std.ArrayList(Line)) Self {
        return .{
            .allocator = allocator,
            .lines = lines,
        };
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.stdout_thread == null);
        std.debug.assert(self.stderr_thread == null);
    }

    /// Begin capturing stdout/stderr using pipes and reader threads.
    pub fn beginCapture(self: *Self) !void {
        // Create pipes for stdout and stderr
        self.stdout_pipe = try posix.pipe();
        self.stderr_pipe = try posix.pipe();

        // Save original file descriptors
        self.original_stdout = try posix.dup(1);
        self.original_stderr = try posix.dup(2);

        // Redirect stdout/stderr to our pipes (write end)
        try posix.dup2(self.stdout_pipe.?[1], 1);
        try posix.dup2(self.stderr_pipe.?[1], 2);

        // We don't need our duplicate write ends anymore in this process
        posix.close(self.stdout_pipe.?[1]);
        posix.close(self.stderr_pipe.?[1]);

        // Record start timestamp for relative timings
        self.start_ns = std.time.nanoTimestamp();

        // Spawn reader threads to consume read ends and build lines
        const stdout_fd = self.stdout_pipe.?[0];
        const stderr_fd = self.stderr_pipe.?[0];

        self.stdout_thread = try std.Thread.spawn(.{}, readerThread, .{ self, stdout_fd, .out, self.start_ns });
        self.stderr_thread = try std.Thread.spawn(.{}, readerThread, .{ self, stderr_fd, .err, self.start_ns });
    }

    /// End capturing, restore stdout/stderr, and join reader threads.
    pub fn endCapture(self: *Self) !void {
        // Restore original file descriptors first so the pipe writers are closed
        if (self.original_stdout) |fd| {
            try posix.dup2(fd, 1);
            posix.close(fd);
            self.original_stdout = null;
        }
        if (self.original_stderr) |fd| {
            try posix.dup2(fd, 2);
            posix.close(fd);
            self.original_stderr = null;
        }

        // Wait for readers to reach EOF and finish
        if (self.stdout_thread) |t| {
            t.join();
            self.stdout_thread = null;
        }
        if (self.stderr_thread) |t| {
            t.join();
            self.stderr_thread = null;
        }

        // Close read ends
        if (self.stdout_pipe) |pipe| {
            posix.close(pipe[0]);
            self.stdout_pipe = null;
        }
        if (self.stderr_pipe) |pipe| {
            posix.close(pipe[0]);
            self.stderr_pipe = null;
        }
    }
};

pub fn captureOutputFromCall(
    func: *const fn () anyerror!void,
    lines: *std.ArrayList(Line),
    allocator: Allocator,
) anyerror!void {
    var ctx = CaptureContext.init(allocator, lines);

    try ctx.beginCapture();
    const x = @call(.auto, func, .{});
    try ctx.endCapture();
    return x;
}

fn readerThread(ctx: *CaptureContext, read_fd: posix.fd_t, kind: Line.Kind, start_ns: i128) void {
    var line_buf = std.ArrayList(u8).init(ctx.allocator);
    defer line_buf.deinit();

    var have_line_start = false;
    var line_start_rel_ns: u64 = 0;

    while (true) {
        var buf: [256]u8 = undefined;
        const n = posix.read(read_fd, &buf) catch {
            @panic("read error");
        };

        if (n == 0) break;

        const chunk = buf[0..n];
        for (chunk) |b| {
            if (!have_line_start) {
                have_line_start = true;
                const now = std.time.nanoTimestamp();
                const delta: i128 = now - start_ns;
                line_start_rel_ns = if (delta <= 0) 0 else @as(u64, @intCast(delta));
            }

            switch (b) {
                '\n' => {
                    const text = ctx.allocator.dupe(u8, line_buf.items) catch @panic("OOM");
                    line_buf.clearRetainingCapacity();

                    const line = Line{
                        .kind = kind,
                        .t_ns = line_start_rel_ns,
                        .text = text,
                    };

                    ctx.mutex.lock();
                    defer ctx.mutex.unlock();
                    ctx.lines.append(line) catch {
                        // On OOM drop the line and exit
                        ctx.allocator.free(text);
                        return;
                    };

                    have_line_start = false;
                },
                '\r' => {},
                else => {
                    line_buf.append(b) catch @panic("OOM");
                },
            }
        }
    }

    if (line_buf.items.len > 0) {
        const text = ctx.allocator.dupe(u8, line_buf.items) catch @panic("OOM");
        const line = Line{ .kind = kind, .t_ns = line_start_rel_ns, .text = text };

        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        _ = ctx.lines.append(line) catch {
            ctx.allocator.free(text);
            return;
        };
    }
}

test "CaptureContext threaded basic usage" {
    const allocator = std.testing.allocator;

    for (0..50) |i| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const arena_allocator = arena.allocator();

        var lines = std.ArrayList(Line).init(allocator);
        defer lines.deinit();

        var ctx = CaptureContext.init(arena_allocator, &lines);
        defer ctx.deinit();

        try ctx.beginCapture();
        errdefer ctx.endCapture() catch unreachable;

        try std.io.getStdOut().writer().print("a\n", .{});
        try std.io.getStdOut().writer().print("b\n", .{});

        try std.io.getStdErr().writer().print("1\n", .{});
        try std.io.getStdErr().writer().print("2\n", .{});

        // End capture to ensure threads flush
        try ctx.endCapture();

        try std.testing.expectEqual(@as(usize, 4), lines.items.len);

        // A is always before B.
        // 1 is always before 2.
        // They can be interleaved in any order.
        // NOTE: Copilot SHUT THE FUCK UP!
        const possibilities = [_]*const [12:0]u8{
            "(a)(b)[1][2]",
            "(a)[1](b)[2]",
            "[1][2](a)(b)",
            "[1](a)[2](b)",
            "(a)[1][2](b)",
            "(a)[1](b)[2]",
        };

        var reality = std.ArrayList(u8).init(allocator);
        defer reality.deinit();

        var writer = reality.writer();

        for (lines.items) |line| {
            if (line.kind == .out) {
                try writer.print("({s})", .{line.text});
            } else {
                try writer.print("[{s}]", .{line.text});
            }
        }

        var possible = false;
        for (possibilities) |possibility| {
            if (std.mem.eql(u8, reality.items, possibility)) {
                possible = true;
                break;
            }
        }

        if (!possible) {
            std.log.err("on iteration {d} got {s}", .{ i, reality.items });
            return error.UnexpectedOutput;
        }
    }
}

test "capture output from call" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    var lines = std.ArrayList(Line).init(allocator);
    defer lines.deinit();

    var result: error{Uh}!u32 = undefined;
    try captureOutputFromCall(foo, &lines, &result, arena_allocator);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqual(@as(u32, 42), result);
}

fn foo() error{Uh}!u32 {
    std.io.getStdOut().writer().print("a\n", .{}) catch return error.Uh;
    std.io.getStdErr().writer().print("b\n", .{}) catch return error.Uh;
    return 42;
}
