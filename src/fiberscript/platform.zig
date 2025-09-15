const std = @import("std");
const Self = @import("vm.zig");
const Context = @import("context.zig").Context;
const Fiber = Self.FiberID;
const FiberID = Self.FiberID;
const miniflex = @import("miniflex");
const dom = miniflex.dom;

const log = std.log.scoped(.platform);

const documentSyscalls = struct {
    pub fn start(
        engine: *Self,
        context: *Context,
        fiber: Fiber,
        args: struct { subfiber: FiberID },
    ) anyerror!void {
        _ = engine; // autofix
        log.info("{s} wants to start {s}", .{ fiber.ticket, args.subfiber.ticket });
        try context.thunks.append(context.allocator, args.subfiber);
    }

    pub fn readableStreamFromFiber(
        engine: *Self,
        context: *Context,
        fiber: Fiber,
        args: struct { size: u32, subfiber: FiberID },
    ) anyerror!u32 {
        _ = fiber; // autofix
        _ = engine;

        return try context.readableStreamFromFiber(args.subfiber, args.size);
    }

    pub fn slowlyDrainStream(
        engine: *Self,
        context: *Context,
        fiber: Fiber,
        args: struct { id: u32 },
    ) anyerror!void {
        _ = engine; // autofix
        _ = fiber; // autofix
        const readableStream = context.fiber_readers.at(args.id);

        try context.addBackgroundThread(
            try std.Thread.spawn(
                .{},
                slowlyDrainStreamThread,
                .{readableStream},
            ),
        );
    }

    pub fn print(engine: *Self, context: *Context, fiber: Fiber, args: struct { message: []const u8 }) anyerror!void {
        _ = engine; // autofix
        _ = fiber;
        _ = context;
        std.debug.print("{s}", .{args.message});
    }

    pub fn createElement(engine: *Self, context: *Context, fiber: Fiber, args: struct { style: []const u8 }) anyerror!dom.DomNodeId {
        _ = engine;
        _ = fiber;
        return context.document.addElement(args.style);
    }

    pub fn createText(engine: *Self, context: *Context, fiber: Fiber, args: struct { text: []const u8 }) anyerror!dom.DomNodeId {
        _ = fiber;
        _ = engine;
        return context.document.addText(args.text);
    }

    pub fn updateText(engine: *Self, context: *Context, fiber: Fiber, args: struct { nodeId: u32, text: []const u8 }) anyerror!void {
        _ = fiber;
        _ = engine;
        try context.document.updateText(args.nodeId, args.text);
    }

    pub fn updateClass(engine: *Self, context: *Context, fiber: Fiber, args: struct { nodeId: u32, className: []const u8 }) anyerror!void {
        _ = fiber;
        _ = engine;
        try context.document.updateClass(args.nodeId, args.className);
    }

    pub fn appendChild(engine: *Self, context: *Context, fiber: Fiber, args: struct { parentId: u32, childId: u32 }) anyerror!void {
        _ = fiber;
        _ = engine;
        try context.document.appendChild(args.parentId, args.childId);
    }

    pub fn removeChild(engine: *Self, context: *Context, fiber: Fiber, args: struct { parentId: u32, childId: u32 }) anyerror!void {
        _ = fiber;
        _ = engine;
        try context.document.removeChild(args.parentId, args.childId);
    }

    // pub fn openWindow(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
    //     _ = fiber;
    //     _ = engine;
    //     _ = args;
    //     if (context.window == null) {
    //         const w = try context.document.alloc.create(WindowMod.Window);
    //         w.* = try WindowMod.Window.init(context.document.alloc, .{
    //             .width = context.viewport_width,
    //             .height = context.viewport_height,
    //         });
    //         context.window = w;
    //     }
    //     var out_buf: [2048]u8 = undefined;
    //     var out_state = std.fs.File.stdout().writer(&out_buf);
    //     const out: *std.Io.Writer = &out_state.interface;
    //     try context.window.?.renderAndPresent(context.document, 0, out);
    //     try out.flush();
    // }

    // pub fn printElement(engine: *Self, context: *Context, fiber: Fiber, args: struct { nodeId: u32 }) anyerror!void {
    //     _ = fiber;
    //     _ = engine;
    //     if (context.window == null) {
    //         const w = try context.document.alloc.create(WindowMod.Window);
    //         w.* = try WindowMod.Window.init(context.document.alloc, .{
    //             .width = context.viewport_width,
    //             .height = context.viewport_height,
    //         });
    //         context.window = w;
    //     }
    //     const w = context.window.?;
    //     w.state.back.clear();
    //     var box_tree = try layout.allocateBoxTreeFromDOM(context.document.alloc, context.document, 0);
    //     defer box_tree.deinit();
    //     var layout_engine = layout.init(context.document.alloc, w.unicode, w.trace);
    //     try layout_engine.layoutSubtree(&box_tree, context.document, box_tree.getNodeMut(0), .{
    //         .x = 0,
    //         .y = 0,
    //         .w = w.opts.width,
    //         .h = w.opts.height,
    //     });
    //     var painter = Painter.init(context.document.alloc, w.unicode, w.trace);
    //     defer painter.deinit();
    //     try painter.computePaintCommands(context.document, &box_tree, w.glyphs);
    //     try w.state.back.rasterizeDisplayList(context.document.alloc, w.glyphs, &painter);

    //     var rect = layout.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    //     var found = false;
    //     for (box_tree.nodes.items) |node| {
    //         if (node.data.dom_id == args.nodeId) {
    //             rect = node.data.rect;
    //             found = true;
    //             break;
    //         }
    //     }
    //     if (!found) return;

    //     var out_buf2: [2048]u8 = undefined;
    //     var out_state2 = std.fs.File.stdout().writer(&out_buf2);
    //     const out2: *std.Io.Writer = &out_state2.interface;
    //     try w.state.back.writeSubRectAsPlainText(out2, w.glyphs, rect.x, rect.y, rect.w, rect.h);
    //     try out2.flush();
    // }

    // pub fn requestRender(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
    //     _ = fiber;
    //     _ = engine;
    //     _ = args;
    //     if (context.window) |w| {
    //         var out_buf3: [2048]u8 = undefined;
    //         var out_state3 = std.fs.File.stdout().writer(&out_buf3);
    //         const out3: *std.Io.Writer = &out_state3.interface;
    //         try w.renderAndPresent(context.document, 0, out3);
    //         try out3.flush();
    //     }
    // }

    // pub fn clearScreen(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!void {
    //     _ = fiber;
    //     _ = engine;
    //     _ = context;
    //     _ = args;
    //     @panic("clearScreen not implemented");
    // }

    // pub fn requestAnimationFrame(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!Pending {
    //     _ = engine;
    //     _ = args;
    //     try context.frame_fibers.append(context.allocator, fiber);
    //     return syscalls.Pending{};
    // }

    // pub fn sleep(engine: *Self, context: *Context, fiber: Fiber, args: struct { seconds: f64 }) anyerror!Pending {
    //     _ = engine;
    //     const now_ms = std.time.milliTimestamp();
    //     const delay_ms = @as(i64, @intFromFloat(args.seconds * 1000.0));
    //     const deadline: u64 = @intCast(now_ms + delay_ms);
    //     try context.sleep_timers.append(context.allocator, .{ .fiber = fiber, .deadline_ms = deadline });
    //     return syscalls.Pending{};
    // }

};

// Export the syscalls so they can be used by the Syscaller
pub const start = documentSyscalls.start;
pub const readableStreamFromFiber = documentSyscalls.readableStreamFromFiber;
pub const slowlyDrainStream = documentSyscalls.slowlyDrainStream;
pub const print = documentSyscalls.print;
pub const createElement = documentSyscalls.createElement;
pub const createText = documentSyscalls.createText;
pub const updateText = documentSyscalls.updateText;
pub const updateClass = documentSyscalls.updateClass;
pub const appendChild = documentSyscalls.appendChild;
pub const removeChild = documentSyscalls.removeChild;

fn slowlyDrainStreamThread(source: *@import("context.zig").FiberReader) void {
    var stdout = std.fs.File.stdout().writer(&.{});
    while (true) {
        std.Thread.sleep(std.time.ns_per_ms * 250);
        const n = source.reader.stream(&stdout.interface, .limited(3)) catch {
            break;
        };
        _ = n; // autofix
        stdout.interface.flush() catch {};
    }
}
