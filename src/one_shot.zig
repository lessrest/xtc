const std = @import("std");
const dom = @import("dom.zig");
const renderer = @import("renderer.zig");
const paint = @import("paint.zig");
const tty = @import("tty.zig");
const WrenRunner = @import("wren/runtime.zig");
const DocumentLoader = @import("pageload.zig");
const cli = @import("cli.zig");
const Trace = @import("Trace.zig").Trace;

/// One-shot rendering session - render once and exit
pub const OneShotSession = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub const Config = struct {
        output: cli.OutputConfig,
        log_file: ?std.fs.File = null,
        trace: *Trace,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) OneShotSession {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Run one-shot render with the given input
    pub fn run(self: *OneShotSession, input: cli.Input) !void {
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

        try render_instance.render(components.document, load_result.root_id, self.config.trace);
        try render_instance.writeFullRaster(std.io.getStdOut().writer());
    }
};

/// Component bundle for one-shot rendering
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
