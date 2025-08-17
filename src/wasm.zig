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

/// WASM rendering session - uses present() for efficient diff rendering
pub const WasmSession = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub const Config = struct {
        output: cli.OutputConfig,
        log_file: ?std.fs.File = null,
        trace: *Trace,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) WasmSession {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Run WASM render with present() for efficient output
    pub fn run(self: *WasmSession, input: cli.Input) !void {
        // Initialize components
        var components = try initializeComponents(self.allocator);
        defer components.deinit();

        // Load document
        var loader = DocumentLoader.init(
            self.allocator,
            components.document,
            components.wren_runner,
        );

        const load_result = switch (input) {
            .xml_file => |path| try loader.loadXmlFile(path),
            .xml_string => |xml| try loader.loadXmlString(xml, "inline"),
            .wren_file => |path| try loader.loadWrenFile(path),
            .wren_string => |script| try loader.loadWrenString(script, "inline"),
            .default => try loader.createDefault(),
        };

        // Print any Wren output to stderr for debugging
        if (components.wren_runner.output.items.len > 0) {
            _ = try std.io.getStdErr().write(components.wren_runner.output.items);
        }

        // Create renderer
        var render_instance = try renderer.Renderer.init(
            .{
                .allocator = self.allocator,
                .unicode = &components.unicode,
                .glyphs = &components.glyphs,
            },
            .{
                .width = self.config.output.width,
                .height = self.config.output.height,
            },
        );
        defer render_instance.deinit();

        // Initialize terminal for proper ANSI output
        var ansi_writer = ansi.stdout();
        try ansi_writer.initializeTerminal();

        try render_instance.render(components.document, load_result.root_id, self.config.trace);
        try render_instance.present(std.io.getStdOut().writer());
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

// Stub main function for C runtime compatibility
export fn main() c_int {
    // Do nothing - we use exported functions instead
    return 0;
}

// Stub clock function for Wren compatibility (must return i64)
export fn clock() i64 {
    // Return a simple timestamp for WASM
    return std.time.timestamp();
}

// Export hello function
export fn xtc_hello() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("XTC WASM Renderer Ready (with present)\n", .{}) catch return;
}

// Export render function that uses present() for efficient rendering
export fn xtc_render(xml_ptr: [*]const u8, xml_len: usize, width: u32, height: u32) void {
    const xml = xml_ptr[0..xml_len];
    
    // Use the WASM rendering pipeline with present()
    renderXmlWasm(xml, width, height) catch |err| {
        const stdout = std.io.getStdOut().writer();
        stdout.print("Render error: {}\n", .{err}) catch return;
    };
}

// Real XTC rendering using WASM pipeline with present()
fn renderXmlWasm(xml: []const u8, width: u32, height: u32) !void {
    // Create a disabled trace for WASM
    const stderr = std.io.getStdErr();
    var trace = @import("Trace.zig").file(stderr, .{ .enabled = false });
    
    // Create WASM session config
    const config = WasmSession.Config{
        .output = cli.OutputConfig{
            .width = width,
            .height = height,
        },
        .trace = &trace,
    };
    
    // Create session with global allocator
    var session = WasmSession.init(gpa.allocator(), config);
    
    // Run with XML string input
    const input = cli.Input{ .xml_string = xml };
    try session.run(input);
}

// Simple allocator for WASM
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

export fn wasm_alloc(size: usize) ?[*]u8 {
    const slice = gpa.allocator().alloc(u8, size) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, size: usize) void {
    const slice = ptr[0..size];
    gpa.allocator().free(slice);
}