const std = @import("std");
const miniflex = @import("miniflex");
const dom = miniflex.dom;
const WindowType = miniflex.Window;
const xml = @import("xml.zig");
const xmlparse = @import("xmlparse.zig");

pub const has_threads = false;

const SessionInput = union(enum) {
    xml_string: []const u8,
    default: void,
};

const default_markup =
    \\<root class="flex flex-col items-center justify-center h-full">
    \\  <box class="text-gray-200">xtc wasm ready</box>
    \\</root>
;

pub const WasmLiveSession = struct {
    allocator: std.mem.Allocator,
    config: Config,
    document: ?*dom.Dom = null,
    window: ?*WindowType = null,
    root_id: dom.DomNodeId = 0,
    is_initialized: bool = false,
    needs_present: bool = false,

    pub const Config = struct {
        output: OutputConfig,
    };

    pub const OutputConfig = struct {
        width: usize,
        height: usize,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) WasmLiveSession {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn initSession(self: *WasmLiveSession, input: SessionInput) !void {
        if (self.is_initialized) return;

        const load_result = try loadDocumentForSession(self.allocator, input);
        self.document = load_result.document;
        self.root_id = load_result.root_id;

        const window_ptr = try self.allocator.create(WindowType);
        errdefer self.allocator.destroy(window_ptr);

        window_ptr.* = try WindowType.init(self.allocator, .{
            .width = self.config.output.width,
            .height = self.config.output.height,
        });
        self.window = window_ptr;

        self.is_initialized = true;
        self.needs_present = true;
    }

    pub fn processFrame(self: *WasmLiveSession) !bool {
        if (!self.is_initialized) return false;
        if (self.document == null or self.window == null) return false;
        return self.needs_present;
    }

    pub fn render(self: *WasmLiveSession) !void {
        if (!self.is_initialized) return;
        const document = self.document orelse return;
        const window = self.window orelse return;

        var out_buf: [4096]u8 = undefined;
        var out_state = std.fs.File.stdout().writer(&out_buf);
        const out: *std.Io.Writer = &out_state.interface;

        try window.renderAndPresent(document, self.root_id, out);
        try out.flush();
        self.needs_present = false;
    }

    pub fn handleKeypress(self: *WasmLiveSession, key: u8) void {
        _ = self;
        _ = key;
        // Keyboard input is not yet handled in the WASM shim.
    }

    pub fn handleResize(self: *WasmLiveSession, width: usize, height: usize) !void {
        if (!self.is_initialized) return;
        const window = self.window orelse return;
        const document = self.document orelse return;

        try window.setViewport(width, height);
        self.config.output.width = width;
        self.config.output.height = height;
        document.dirty = true;
        self.needs_present = true;
    }

    pub fn deinit(self: *WasmLiveSession) void {
        if (self.window) |win| {
            win.deinit();
            self.allocator.destroy(win);
            self.window = null;
        }
        if (self.document) |doc| {
            doc.deinit();
            self.document = null;
        }
        self.is_initialized = false;
        self.needs_present = false;
        self.root_id = 0;
    }
};

const LoadResult = struct {
    document: *dom.Dom,
    root_id: dom.DomNodeId,
};

fn loadDocumentForSession(allocator: std.mem.Allocator, input: SessionInput) !LoadResult {
    return switch (input) {
        .xml_string => |markup| try parseMarkup(allocator, markup, "<inline>"),
        .default => try parseMarkup(allocator, default_markup, "<default>"),
    };
}

fn parseMarkup(allocator: std.mem.Allocator, markup: []const u8, source_name: []const u8) !LoadResult {
    var stream = std.io.fixedBufferStream(markup);
    var parsed = try xmlparse.parse(allocator, source_name, stream.reader());
    defer parsed.deinit();

    var document = try xml.loadDocumentFromMarkup(allocator, &parsed);
    const root_id = determineRootNode(document);
    document.dirty = true;

    return .{ .document = document, .root_id = root_id };
}

fn determineRootNode(document: *dom.Dom) dom.DomNodeId {
    const headers = document.headers.slice();
    const contents = headers.items(.content);

    if (contents.len == 0) return 0;

    switch (contents[0]) {
        .element => |element| {
            if (element.first_child != dom.Dom.NullId) {
                return element.first_child;
            }
        },
        else => {},
    }

    var idx: usize = 1;
    while (idx < contents.len) : (idx += 1) {
        if (headers.items(.parent)[idx] == 0) {
            switch (contents[idx]) {
                .element => return @intCast(idx),
                else => {},
            }
        }
    }

    return 0;
}

// WASM exports

var global_live_session: ?WasmLiveSession = null;

export fn main() c_int {
    return 0;
}

export fn clock() i64 {
    return @as(i64, @intFromFloat(@floor(js_performance_now() * 1_000_000)));
}

extern fn js_performance_now() f64;

export fn xtc_hello() void {
    var out_buf: [256]u8 = undefined;
    var out_state = std.fs.File.stdout().writer(&out_buf);
    const out: *std.Io.Writer = &out_state.interface;
    out.print("XTC WASM Live Session Ready!\n", .{}) catch return;
    out.flush() catch {};
}

export fn xtc_init_session(xml_ptr: [*]const u8, xml_len: usize, width: u32, height: u32) c_int {
    const xml_bytes = xml_ptr[0..xml_len];

    if (global_live_session) |*session| {
        session.deinit();
    }

    global_live_session = initLiveSessionWasm(xml_bytes, width, height) catch |err| {
        var err_buf: [256]u8 = undefined;
        var err_state = std.fs.File.stderr().writer(&err_buf);
        const stderr: *std.Io.Writer = &err_state.interface;
        stderr.print("Init session error: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return -1;
    };

    return 0;
}

export fn xtc_process_frame() c_int {
    if (global_live_session) |*session| {
        const needs_render = session.processFrame() catch |err| {
            var err_buf: [256]u8 = undefined;
            var err_state = std.fs.File.stderr().writer(&err_buf);
            const stderr: *std.Io.Writer = &err_state.interface;
            stderr.print("Process frame error: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return -1;
        };
        return if (needs_render) 1 else 0;
    }
    return -1;
}

export fn xtc_render_frame() c_int {
    if (global_live_session) |*session| {
        session.render() catch |err| {
            var err_buf: [256]u8 = undefined;
            var err_state = std.fs.File.stderr().writer(&err_buf);
            const stderr: *std.Io.Writer = &err_state.interface;
            stderr.print("Render frame error: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return -1;
        };
        return 0;
    }
    return -1;
}

export fn xtc_keypress(key: u8) c_int {
    if (global_live_session) |*session| {
        session.handleKeypress(key);
        return 0;
    }
    return -1;
}

export fn xtc_resize(width: u32, height: u32) c_int {
    if (global_live_session) |*session| {
        session.handleResize(@as(usize, @intCast(width)), @as(usize, @intCast(height))) catch |err| {
            var err_buf: [256]u8 = undefined;
            var err_state = std.fs.File.stderr().writer(&err_buf);
            const stderr: *std.Io.Writer = &err_state.interface;
            stderr.print("Resize error: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return -1;
        };
        return 0;
    }
    return -1;
}

export fn xtc_cleanup() void {
    if (global_live_session) |*session| {
        session.deinit();
        global_live_session = null;
    }
}

export fn xtc_render(xml_ptr: [*]const u8, xml_len: usize, width: u32, height: u32) void {
    const xml_bytes = xml_ptr[0..xml_len];

    renderXmlWasm(xml_bytes, width, height) catch |err| {
        var outb: [256]u8 = undefined;
        var outs = std.fs.File.stdout().writer(&outb);
        const stdout: *std.Io.Writer = &outs.interface;
        stdout.print("Render error: {}\n", .{err}) catch return;
        stdout.flush() catch {};
    };
}

fn initLiveSessionWasm(markup: []const u8, width: u32, height: u32) !WasmLiveSession {
    const config = WasmLiveSession.Config{
        .output = .{
            .width = @as(usize, @intCast(width)),
            .height = @as(usize, @intCast(height)),
        },
    };

    var session = WasmLiveSession.init(global_allocator, config);
    try session.initSession(SessionInput{ .xml_string = markup });

    return session;
}

fn renderXmlWasm(markup: []const u8, width: u32, height: u32) !void {
    var session = try initLiveSessionWasm(markup, width, height);
    defer session.deinit();

    try session.render();
}

var global_allocator = std.heap.wasm_allocator;

export fn wasm_alloc(size: usize) ?[*]u8 {
    const slice = global_allocator.alloc(u8, size) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, size: usize) void {
    const slice = ptr[0..size];
    global_allocator.free(slice);
}

export fn _initialize() void {}
