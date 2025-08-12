const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Allocator = std.mem.Allocator;

pub const Kind = enum { out, err };

pub const Line = struct {
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
    lines: std.ArrayList(Line),
    // Lazily built combined output cache
    combined: std.ArrayList(u8),

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

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .lines = std.ArrayList(Line).init(allocator),
            .combined = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free per-line text buffers
        for (self.lines.items) |ln| self.allocator.free(ln.text);
        self.lines.deinit();
        self.combined.deinit();
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

    /// Returns a combined view of captured output. Built lazily from lines.
    pub fn getCombinedOutput(self: *Self) []const u8 {
        if (self.combined.items.len == 0 and self.lines.items.len > 0) {
            // Merge lines in the order they were recorded; add trailing newlines
            for (self.lines.items) |ln| {
                self.combined.appendSlice(ln.text) catch @panic("OOM building combined output");
                self.combined.append('\n') catch @panic("OOM building combined output");
            }
        }
        return self.combined.items;
    }
};

fn readerThread(ctx: *CaptureContext, read_fd: posix.fd_t, kind: Kind, start_ns: i128) void {
    var buf: [4096]u8 = undefined;
    var line_buf = std.ArrayList(u8).init(ctx.allocator);
    defer line_buf.deinit();

    var have_line_start = false;
    var line_start_rel_ns: u64 = 0;

    while (true) {
        const n = posix.read(read_fd, &buf) catch {
            // Treat any read error as fatal to this reader
            return;
        };
        if (n == 0) break; // EOF

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
                    // finalize a line (no trailing newline in text)
                    const text = ctx.allocator.dupe(u8, line_buf.items) catch return;
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
                '\r' => {
                    // Ignore carriage return; treat as part of formatting
                },
                else => {
                    line_buf.append(b) catch return;
                },
            }
        }
    }

    // Flush any partial line on EOF
    if (line_buf.items.len > 0) {
        const text = ctx.allocator.dupe(u8, line_buf.items) catch return;
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

    var ctx = CaptureContext.init(allocator);
    defer ctx.deinit();

    try ctx.beginCapture();
    defer ctx.endCapture() catch unreachable;

    try std.io.getStdOut().writer().print("Hello stdout\n", .{});
    try std.io.getStdErr().writer().print("Hello stderr\n", .{});

    // End capture to ensure threads flush
    try ctx.endCapture();

    // We should have two lines, one out and one err
    try std.testing.expect(ctx.lines.items.len >= 2);
    // Combined output should include both lines
    const combined = ctx.getCombinedOutput();
    try std.testing.expect(std.mem.indexOf(u8, combined, "Hello stdout") != null);
    try std.testing.expect(std.mem.indexOf(u8, combined, "Hello stderr") != null);
}
