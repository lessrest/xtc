const std = @import("std");
const dom = @import("dom.zig");
const renderer = @import("renderer.zig");
const paint = @import("paint.zig");
const tty = @import("tty.zig");
const WrenRunner = @import("wren/runtime.zig");
const DocumentLoader = @import("pageload.zig");
const cli = @import("cli.zig");
const Trace = @import("Trace.zig").Trace;
const ansi = @import("ansi");

/// WASM live session - supports interactive fiber-based animations
pub const WasmLiveSession = struct {
    allocator: std.mem.Allocator,
    config: Config,
    live_session: ?LiveSession = null,
    components: ?Components = null,
    is_initialized: bool = false,

    pub const Config = struct {
        output: cli.OutputConfig,
        log_file: ?std.fs.File = null,
        trace: *Trace,
    };

    pub const LiveSession = @import("live_session.zig").LiveSession;

    pub fn init(allocator: std.mem.Allocator, config: Config) WasmLiveSession {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Initialize the live session with content
    pub fn initSession(self: *WasmLiveSession, input: cli.Input) !void {
        if (self.is_initialized) return;

        // Initialize components
        self.components = try initializeComponents(self.allocator);

        // Create scheduler for fiber management
        const scheduler = try self.allocator.create(@import("scheduler.zig").Scheduler);
        scheduler.* = @import("scheduler.zig").Scheduler.init(self.allocator, self.config.trace);

        self.components.?.wren_runner.script_context.scheduler = scheduler;

        // Load document
        var loader = DocumentLoader.init(
            self.allocator,
            self.components.?.document,
            self.components.?.wren_runner,
        );

        const load_result = switch (input) {
            .xml_file => |path| try loader.loadXmlFile(path),
            .xml_string => |xml| try loader.loadXmlString(xml, "inline"),
            .wren_file => |path| try loader.loadWrenFile(path),
            .wren_string => |script| try loader.loadWrenString(script, "inline"),
            .default => try loader.createDefault(),
        };

        // Print any Wren output to stderr for debugging
        if (self.components.?.wren_runner.output.items.len > 0) {
            _ = try std.io.getStdErr().write(self.components.?.wren_runner.output.items);
        }

        // Create renderer
        const render_instance = try renderer.Renderer.init(
            .{
                .allocator = self.allocator,
                .unicode = &self.components.?.unicode,
                .glyphs = &self.components.?.glyphs,
            },
            .{
                .width = self.config.output.width,
                .height = self.config.output.height,
            },
        );

        // Create live session
        self.live_session = LiveSession.init(
            self.allocator,
            self.components.?.document,
            render_instance,
            self.components.?.wren_runner,
            scheduler,
            load_result.root_id,
            self.config.trace,
        );

        self.is_initialized = true;
    }

    /// Process a single animation frame - returns true if re-render needed
    pub fn processFrame(self: *WasmLiveSession) !bool {
        if (!self.is_initialized or self.live_session == null) return false;
        return try self.live_session.?.processScheduler();
    }

    /// Render the current state
    pub fn render(self: *WasmLiveSession) !void {
        if (!self.is_initialized or self.live_session == null) return;
        try self.live_session.?.render();
    }

    /// Handle keyboard input
    pub fn handleKeypress(self: *WasmLiveSession, key: u8) !void {
        if (!self.is_initialized or self.live_session == null) return;
        try self.live_session.?.handleKeypress(key);
    }

    /// Handle viewport resize
    pub fn handleResize(self: *WasmLiveSession, width: usize, height: usize) !void {
        if (!self.is_initialized or self.live_session == null) return;
        try self.live_session.?.handleResize(width, height);
    }

    pub fn deinit(self: *WasmLiveSession) void {
        if (self.components) |*components| {
            components.deinit();
        }
        if (self.live_session) |*session| {
            session.scheduler.deinit(null);
            self.allocator.destroy(session.scheduler);
        }
    }
};

/// Component bundle for WASM rendering
const Components = struct {
    unicode: paint.UnicodeData,
    document: *dom.Dom,
    wren_runner: *WrenRunner,
    glyphs: tty.GlyphTable,

    fn deinit(self: *Components) void {
        self.unicode.deinit(self.document.alloc);
        self.wren_runner.deinit();
        self.document.deinit();
        self.glyphs.deinit();
    }
};

/// Initialize all required components
fn initializeComponents(allocator: std.mem.Allocator) !Components {
    var unicode = try paint.UnicodeData.init(allocator);
    errdefer unicode.deinit(allocator);

    var document = try dom.Dom.init(allocator);
    errdefer document.deinit();

    var wren_runner = try WrenRunner.init(allocator, document);
    errdefer wren_runner.deinit();

    var glyphs = try tty.GlyphTable.init(allocator);
    errdefer glyphs.deinit();

    return Components{
        .unicode = unicode,
        .document = document,
        .wren_runner = wren_runner,
        .glyphs = glyphs,
    };
}

// WASM exports

// Global live session instance
var global_live_session: ?WasmLiveSession = null;

// Stub main function for C runtime compatibility
export fn main() c_int {
    // Do nothing - we use exported functions instead
    return 0;
}

// Stub clock function for Wren compatibility (must return i64)
export fn clock() i64 {
    // Return a simple timestamp for WASM - this should match JavaScript Date.now()
    return @as(i64, @intFromFloat(@floor(js_performance_now() * 1_000_000)));
}

// Import JavaScript performance.now() for high-resolution timing
extern fn js_performance_now() f64;

// Export hello function
export fn xtc_hello() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("XTC WASM Live Session Ready!\n", .{}) catch return;
}

// Initialize a live session
export fn xtc_init_session(xml_ptr: [*]const u8, xml_len: usize, width: u32, height: u32) c_int {
    const xml = xml_ptr[0..xml_len];

    // Clean up any existing session
    if (global_live_session) |*session| {
        session.deinit();
    }

    // Create new live session
    global_live_session = initLiveSessionWasm(xml, width, height) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Init session error: {}\n", .{err}) catch {};
        return -1;
    };

    return 0; // Success
}

// Process one animation frame - returns 1 if re-render needed, 0 if not, -1 on error
export fn xtc_process_frame() c_int {
    if (global_live_session) |*session| {
        const needs_render = session.processFrame() catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Process frame error: {}\n", .{err}) catch {};
            return -1;
        };
        return if (needs_render) 1 else 0;
    }
    return -1; // No session
}

// Render current state
export fn xtc_render_frame() c_int {
    if (global_live_session) |*session| {
        session.render() catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Render frame error: {}\n", .{err}) catch {};
            return -1;
        };
        return 0; // Success
    }
    return -1; // No session
}

// Handle keypress
export fn xtc_keypress(key: u8) c_int {
    if (global_live_session) |*session| {
        session.handleKeypress(key) catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Keypress error: {}\n", .{err}) catch {};
            return -1;
        };
        return 0; // Success
    }
    return -1; // No session
}

// Handle viewport resize
export fn xtc_resize(width: u32, height: u32) c_int {
    if (global_live_session) |*session| {
        session.handleResize(width, height) catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Resize error: {}\n", .{err}) catch {};
            return -1;
        };
        return 0; // Success
    }
    return -1; // No session
}

// Clean up session
export fn xtc_cleanup() void {
    if (global_live_session) |*session| {
        session.deinit();
        global_live_session = null;
    }
}

// Legacy one-shot render function for compatibility
export fn xtc_render(xml_ptr: [*]const u8, xml_len: usize, width: u32, height: u32) void {
    const xml = xml_ptr[0..xml_len];

    // Use the WASM rendering pipeline with present()
    renderXmlWasm(xml, width, height) catch |err| {
        const stdout = std.io.getStdOut().writer();
        stdout.print("Render error: {}\n", .{err}) catch return;
    };
}

// Initialize a live session for interactive WASM use
fn initLiveSessionWasm(xml: []const u8, width: u32, height: u32) !WasmLiveSession {
    // Create a disabled trace for WASM
    const stderr = std.io.getStdErr();
    var trace = @import("Trace.zig").file(stderr, .{ .enabled = false });

    // Create WASM session config
    const config = WasmLiveSession.Config{
        .output = cli.OutputConfig{
            .width = width,
            .height = height,
        },
        .trace = &trace,
    };

    // Create session with global allocator
    var session = WasmLiveSession.init(global_allocator, config);

    // Initialize with XML string input
    const input = cli.Input{ .xml_string = xml };
    try session.initSession(input);

    return session;
}

// Real XTC rendering using WASM pipeline with present() (legacy compatibility)
fn renderXmlWasm(xml: []const u8, width: u32, height: u32) !void {
    // For legacy compatibility, create a temporary live session
    var session = try initLiveSessionWasm(xml, width, height);
    defer session.deinit();

    // Just render once
    try session.render();
}

// Simple allocator for WASM
var global_allocator = std.heap.wasm_allocator;

export fn wasm_alloc(size: usize) ?[*]u8 {
    const slice = global_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, size: usize) void {
    const slice = ptr[0..size];
    global_allocator.free(slice);
}
