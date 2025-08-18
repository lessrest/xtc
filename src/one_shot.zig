const std = @import("std");
const dom = @import("dom.zig");
const renderer = @import("renderer.zig");
const paint = @import("paint.zig");
const tty = @import("tty.zig");
const WrenRunner = @import("wren/runtime.zig");
const DocumentLoader = @import("pageload.zig");
const cli = @import("cli.zig");
const Trace = @import("Trace.zig").Trace;
const Scheduler = @import("scheduler.zig").Scheduler;

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
        var components = try initializeComponents(self.allocator, self.config.trace);
        defer components.deinit();

        // Connect scheduler to Wren runtime
        components.wren_runner.script_context.scheduler = &components.scheduler;

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

        // Create renderer
        var render_instance = try renderer.Renderer.init(
            .{
                .allocator = self.allocator,
                .unicode = &components.unicode,
                .glyphs = components.glyphs,
            },
            .{
                .width = self.config.output.width,
                .height = self.config.output.height,
            },
        );
        defer render_instance.deinit();

        try render_instance.renderAndPresent(
            components.document,
            load_result.root_id,
            self.config.trace,
            std.io.getStdOut().writer(),
        );

        // Run scheduler until all fibers complete
        var iterations: usize = 0;
        while (components.scheduler.hasPendingWork()) {
            const now = std.time.milliTimestamp();
            const resumed = try components.scheduler.pump(components.wren_runner.vm.vm, now, 10);
            iterations += 1;

            // Print any Wren output to stderr for debugging
            if (components.wren_runner.output.items.len > 0) {
                _ = try std.io.getStdErr().write(components.wren_runner.output.items);
                components.wren_runner.output.clearRetainingCapacity();
            }

            if (resumed > 0) {
                try render_instance.renderAndPresent(
                    components.document,
                    load_result.root_id,
                    self.config.trace,
                    std.io.getStdOut().writer(),
                );
            }

            // Small delay to avoid busy waiting and allow timers to expire
            std.time.sleep(1_000_000); // 1ms
        }

        var ansi = @import("ansi").stdout();
        try ansi.restoreTerminal();
    }
};

/// Component bundle for one-shot rendering
const Components = struct {
    unicode: paint.UnicodeData,
    document: *dom.Dom,
    wren_runner: *WrenRunner,
    glyphs: *tty.GlyphTable,
    scheduler: Scheduler,

    fn deinit(self: *Components) void {
        self.unicode.deinit(self.document.alloc);
        self.scheduler.deinit(self.wren_runner.vm.vm);
        self.wren_runner.deinit();
        self.document.deinit();
        self.glyphs.deinit();
    }
};

/// Initialize all required components
fn initializeComponents(allocator: std.mem.Allocator, trace: *Trace) !Components {
    var unicode = try paint.UnicodeData.init(allocator);
    errdefer unicode.deinit(allocator);

    var document = try dom.Dom.init(allocator);
    errdefer document.deinit();

    var wren_runner = try WrenRunner.init(allocator, document);
    errdefer wren_runner.deinit();

    var glyphs = try tty.GlyphTable.init(allocator);
    errdefer glyphs.deinit();

    var scheduler = Scheduler.init(allocator, trace);
    errdefer scheduler.deinit(wren_runner.vm.vm);

    return Components{
        .unicode = unicode,
        .document = document,
        .wren_runner = wren_runner,
        .glyphs = glyphs,
        .scheduler = scheduler,
    };
}
