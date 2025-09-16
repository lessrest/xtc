const std = @import("std");
const Self = @import("vm.zig");
const Context = @import("context.zig").Context;
const Fiber = Self.FiberID;
const FiberID = Self.FiberID;
const miniflex = @import("miniflex");
const dom = miniflex.dom;
const root_mod = @import("root");
const syscalls = @import("syscalls.zig");
const has_threads = if (@hasDecl(root_mod, "has_threads")) root_mod.has_threads else true;
const Pending = syscalls.Pending;

const log = std.log.scoped(.platform);

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
    if (has_threads) {
        const readableStream = context.fiber_readers.at(args.id);

        try context.addBackgroundThread(
            try std.Thread.spawn(
                .{},
                slowlyDrainStreamThread,
                .{readableStream},
            ),
        );
    } else {
        return error.ThreadsUnavailable;
    }
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

pub fn getViewportWidth(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!u32 {
    _ = engine;
    _ = fiber;
    _ = args;
    return @as(u32, @intCast(context.viewport_width));
}

pub fn getViewportHeight(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!u32 {
    _ = engine;
    _ = fiber;
    _ = args;
    return @as(u32, @intCast(context.viewport_height));
}

pub fn waitForNextFrame(engine: *Self, context: *Context, fiber: Fiber, args: struct {}) anyerror!Pending {
    _ = engine;
    _ = args;
    try context.queueFrameFiber(fiber);
    return Pending{};
}

fn slowlyDrainStreamThread(source: *@import("context.zig").FiberReader) void {
    if (has_threads) {
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
}
