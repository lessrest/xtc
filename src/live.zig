const std = @import("std");
const dom = @import("dom.zig");
const renderer = @import("renderer.zig");
const paint = @import("paint.zig");
const tty = @import("tty.zig");
const clock = @import("clock.zig");
const WrenRunner = @import("wren/runtime.zig");
const Trace = @import("Trace.zig").Trace;
const LiveSession = @import("live_session.zig").LiveSession;
const Terminal = @import("live_session.zig").Terminal;
const EventLoop = @import("live_session.zig").EventLoop;
const EventLoopConfig = @import("live_session.zig").EventLoopConfig;
const document_loader = @import("document_loader.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const DocumentLoader = document_loader.DocumentLoader;
const LoadResult = document_loader.LoadResult;

/// Entry point for live mode - much cleaner!
pub fn run(
    allocator: std.mem.Allocator,
    xml_path: ?[]const u8,
    wren_path: ?[]const u8,
    trace: *Trace,
) !void {
    // 1. Setup tracing
    const session_trace = trace;

    // 2. Initialize terminal for live mode
    var terminal = Terminal.init();
    try terminal.enterLiveMode();
    defer terminal.exitLiveMode();

    // 3. Initialize core components
    var components = try initializeComponents(allocator);
    defer components.deinit();

    // 4. Load document content
    var loader = DocumentLoader.init(allocator, components.document, components.wren_runner);
    const load_result = try loadContent(&loader, xml_path, wren_path);

    // 5. Configure viewport
    const initial_size = terminal.getSize();
    components.wren_runner.script_context.viewport_width = initial_size[0];
    components.wren_runner.script_context.viewport_height = initial_size[1];

    // 6. Create renderer
    var render_instance = try renderer.Renderer.init(
        .{
            .allocator = allocator,
            .unicode = &components.unicode,
            .glyphs = &components.glyphs,
        },
        .{
            .width = initial_size[0],
            .height = initial_size[1],
        },
    );
    defer render_instance.deinit();

    // 7. Create session
    var session = LiveSession.init(
        allocator,
        components.document,
        render_instance,
        components.wren_runner,
        &components.clock_registry,
        &components.scheduler,
        load_result.root_id,
        session_trace,
    );

    // 8. Initial render
    try session.render();

    // 9. Start clock nodes if document has them
    try startClockNodes(&session);

    // 10. Run event loop
    var event_loop = EventLoop.init(&session, &terminal, .{
        .clock_interval_ms = 50,
        .exit_key = 'q',
    });
    try event_loop.run();
}

/// Component bundle - groups related initializations
const Components = struct {
    unicode: paint.UnicodeData,
    document: *dom.Dom,
    clock_registry: clock.ClockRegistry,
    wren_runner: *WrenRunner,
    glyphs: tty.GlyphTable,
    scheduler: Scheduler,

    fn deinit(self: *Components) void {
        self.unicode.deinit(self.document.alloc);
        self.clock_registry.deinit();
        self.wren_runner.deinit();
        self.glyphs.deinit();
        self.document.deinit();
        self.document.alloc.destroy(self.document);
        self.scheduler.deinit(self.wren_runner.vm.vm);
    }
};

/// Initialize all core components
fn initializeComponents(allocator: std.mem.Allocator) !Components {
    var unicode = try paint.UnicodeData.init(allocator);
    errdefer unicode.deinit(allocator);

    var document = try dom.Dom.init(allocator);
    errdefer document.deinit();

    var clock_registry = clock.ClockRegistry.init(allocator);
    errdefer clock_registry.deinit();

    var wren_runner = try WrenRunner.init(allocator, document);
    errdefer wren_runner.deinit();

    var glyphs = try tty.GlyphTable.init(allocator);
    errdefer glyphs.deinit();

    var scheduler = Scheduler.init(allocator);
    errdefer scheduler.deinit(wren_runner.vm.vm);

    return Components{
        .unicode = unicode,
        .document = document,
        .clock_registry = clock_registry,
        .wren_runner = wren_runner,
        .glyphs = glyphs,
        .scheduler = scheduler,
    };
}

/// Load content from the specified source
fn loadContent(
    loader: *DocumentLoader,
    xml_path: ?[]const u8,
    wren_path: ?[]const u8,
) !LoadResult {
    if (xml_path) |path| {
        return try loader.loadXmlFile(path);
    } else if (wren_path) |path| {
        return try loader.loadWrenFile(path);
    } else {
        return try loader.createDefault();
    }
}

/// Start clock threads for any clock nodes in the DOM
fn startClockNodes(session: *LiveSession) !void {
    const headers = session.document.headers.slice();
    const kinds = headers.items(.kind);
    const style_ids = headers.items(.style_id);

    for (kinds, 0..) |kind, i| {
        if (kind == .clock) {
            const node_id: dom.DomNodeId = @intCast(i);
            const style = session.document.styles.cols.items[style_ids[i]];

            if (style.clock_interval_ms > 0) {
                const clock_node = try session.clock_registry.createClock(node_id, style.clock_interval_ms);
                try clock_node.start();
                session.trace.data("clock started").put("node", node_id).put("interval ms", style.clock_interval_ms).end();
            }
        }
    }
}
