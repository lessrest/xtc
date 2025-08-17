const std = @import("std");
const dom = @import("dom.zig");
const renderer = @import("renderer.zig");
const clock = @import("clock.zig");
const WrenRunner = @import("wren/runtime.zig");
const Trace = @import("Trace.zig").Trace;
const event_dispatch = @import("event_dispatch.zig");
const scheduler_mod = @import("scheduler.zig");

/// Core session state - the "model" in our architecture
pub const LiveSession = struct {
    allocator: std.mem.Allocator,
    document: *dom.Dom,
    renderer: renderer.Renderer,
    wren_runner: *WrenRunner,
    scheduler: *scheduler_mod.Scheduler,
    clock_registry: *clock.ClockRegistry,
    root_id: dom.DomNodeId,
    trace: *Trace,

    pub fn init(
        allocator: std.mem.Allocator,
        document: *dom.Dom,
        render_instance: renderer.Renderer,
        wren_runner: *WrenRunner,
        clock_registry: *clock.ClockRegistry,
        scheduler: *scheduler_mod.Scheduler,
        root_id: dom.DomNodeId,
        trace: *Trace,
    ) LiveSession {
        return .{
            .allocator = allocator,
            .document = document,
            .renderer = render_instance,
            .wren_runner = wren_runner,
            .clock_registry = clock_registry,
            .root_id = root_id,
            .trace = trace,
            .scheduler = scheduler,
        };
    }

    /// Render the current document state
    pub fn render(self: *LiveSession) !void {
        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Rendering frame");

        const stdout = std.io.getStdOut().writer();
        try self.renderer.renderAndPresent(self.document, self.root_id, self.trace, stdout);
        // Resume any nextFrame fibers
        self.scheduler.onFramePresented(self.wren_runner.vm.vm);
    }

    /// Handle terminal resize
    pub fn handleResize(self: *LiveSession, width: usize, height: usize) !void {
        try self.renderer.setViewport(width, height);
        self.wren_runner.script_context.viewport_width = width;
        self.wren_runner.script_context.viewport_height = height;
        try self.render();
    }

    /// Process a clock tick - returns true if re-render needed
    pub fn processClock(self: *LiveSession) !bool {
        // Pump timers and ready fibers with a small budget
        const now_ms = std.time.milliTimestamp();
        const resumed = self.scheduler.pump(self.wren_runner.vm.vm, now_ms, 64);
        return resumed > 0;
    }

    /// Handle keyboard input
    pub fn handleKeypress(self: *LiveSession, key: u8) !void {
        // Build key string for event dispatch
        var key_buf: [16]u8 = undefined;
        const key_str = switch (key) {
            '\r', '\n' => "Enter",
            127 => "Backspace",
            '\t' => "Tab",
            27 => "Escape",
            ' ' => "Space",
            else => blk: {
                key_buf[0] = key;
                break :blk key_buf[0..1];
            },
        };

        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Handling keypress");
        
        self.trace.fields("key", .{
            .char = key,
            .string = key_str,
        });

        // Post to fiber awaiters first
        self.scheduler.postEvent(self.wren_runner.vm.vm, .{
            .type = .keypress,
            .target = 0,
            .key = key_str,
            .timestamp = std.time.milliTimestamp(),
        });
        // Then deliver to callback listeners (optional)
        event_dispatch.dispatchKeypress(self.wren_runner.vm.vm, self.document, key_str) catch |err| {
            std.log.warn("Failed to dispatch keypress event: {}", .{err});
        };

        // Re-render after input
        self.wren_runner.script_context.viewport_width = self.renderer.opts.width;
        self.wren_runner.script_context.viewport_height = self.renderer.opts.height;
        try self.render();
    }
};

/// Terminal management - handles raw mode and alternate screen
pub const Terminal = struct {
    raw_mode: ?RawMode = null,
    original_termios: ?std.posix.termios = null,

    pub fn init() Terminal {
        return .{};
    }

    pub fn enterLiveMode(self: *Terminal) !void {
        // Save original terminal state and enter raw mode
        self.raw_mode = try RawMode.enable(std.posix.STDIN_FILENO);

        // Enter alternate screen and hide cursor
        var ansi_writer = @import("ansi").stdout();
        try ansi_writer.initializeTerminal();
    }

    pub fn exitLiveMode(self: *Terminal) void {
        // Restore terminal state
        var ansi_writer = @import("ansi").stdout();
        ansi_writer.restoreTerminal() catch {};

        if (self.raw_mode) |*raw| {
            raw.disable() catch {};
        }
    }

    pub fn getSize(self: *const Terminal) [2]usize {
        _ = self;
        var ws: std.posix.winsize = .{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
        const result = std.posix.system.ioctl(std.io.getStdOut().handle, std.posix.T.IOCGWINSZ, &ws);

        if (result >= 0 and ws.col > 0 and ws.row > 0) {
            return .{ ws.col, ws.row };
        }
        return .{ 80, 24 }; // Fallback
    }
};

/// Input stream processor
pub const InputReader = struct {
    stdin: std.fs.File,

    pub fn init() InputReader {
        return .{ .stdin = std.io.getStdIn() };
    }

    /// Read next input byte with timeout (returns null on timeout)
    pub fn readByteTimeout(self: *InputReader, timeout_ms: i32) !?u8 {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const poll_result = try std.posix.poll(&fds, timeout_ms);
        if (poll_result > 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
            var buf: [1]u8 = undefined;
            const n = try self.stdin.read(&buf);
            if (n > 0) return buf[0];
        }
        return null;
    }
};

/// Event loop configuration
pub const EventLoopConfig = struct {
    clock_interval_ms: i32 = 50, // How often to check clocks
    exit_key: u8 = 'q', // Key to exit the loop
};

/// Main event loop - coordinates all the pieces
pub const EventLoop = struct {
    session: *LiveSession,
    terminal: *const Terminal,
    input: InputReader,
    config: EventLoopConfig,

    pub fn init(session: *LiveSession, terminal: *const Terminal, config: EventLoopConfig) EventLoop {
        return .{
            .session = session,
            .terminal = terminal,
            .input = InputReader.init(),
            .config = config,
        };
    }

    pub fn run(self: *EventLoop) !void {
        var last_size = self.terminal.getSize();

        while (true) {
            // Check for resize
            const current_size = self.terminal.getSize();
            if (current_size[0] != last_size[0] or current_size[1] != last_size[1]) {
                try self.session.handleResize(current_size[0], current_size[1]);
                last_size = current_size;
            }

            // Process clocks
            if (try self.session.processClock()) {
                try self.session.render();
            }

            // Read input with timeout
            if (try self.input.readByteTimeout(self.config.clock_interval_ms)) |byte| {
                // Check for exit
                if (byte == self.config.exit_key or byte == self.config.exit_key & 0x1F) {
                    return;
                }

                // Handle the keypress
                try self.session.handleKeypress(byte);
            }
        }
    }
};

// RawMode implementation (moved from live.zig)
const RawMode = struct {
    orig_termios: std.posix.termios,
    fd: std.posix.fd_t,

    pub fn enable(fd: std.posix.fd_t) !RawMode {
        const orig = try std.posix.tcgetattr(fd);
        var raw = orig;

        // Input modes: no break, no CR to NL, no parity check, no strip char, no start/stop output control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output modes: disable post processing
        raw.oflag.OPOST = false;

        // Control modes: set 8 bit chars
        raw.cflag.CSIZE = .CS8;

        // Local modes: no echo, no canonical mode, no extended functions, no signal chars
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Control chars: set return condition to 1 byte, no timeout
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(fd, .FLUSH, raw);

        return RawMode{
            .orig_termios = orig,
            .fd = fd,
        };
    }

    pub fn disable(self: *RawMode) !void {
        try std.posix.tcsetattr(self.fd, .FLUSH, self.orig_termios);
    }
};
