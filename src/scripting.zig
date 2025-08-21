const dom = @import("dom.zig");

pub const SyscallContext = struct {
    document: *dom.Dom,
};

pub fn documentSyscalls(comptime EngineType: type, comptime Context: type) type {
    return struct {
        pub fn createElement(engine: *EngineType, context: *Context, args: struct { style: []const u8 }) anyerror!dom.DomNodeId {
            _ = engine;
            return context.document.addElement(args.style);
        }

        pub fn updateText(engine: *EngineType, context: *Context, args: struct { nodeId: u32, text: []const u8 }) anyerror!void {
            _ = engine;
            try context.document.updateText(args.nodeId, args.text);
        }

        pub fn updateClass(engine: *EngineType, context: *Context, args: struct { nodeId: u32, className: []const u8 }) anyerror!void {
            _ = engine;
            try context.document.updateClass(args.nodeId, args.className);
        }

        pub fn appendChild(engine: *EngineType, context: *Context, args: struct { parentId: u32, childId: u32 }) anyerror!void {
            _ = engine;
            try context.document.appendChild(args.parentId, args.childId);
        }

        pub fn removeChild(engine: *EngineType, context: *Context, args: struct { parentId: u32, childId: u32 }) anyerror!void {
            _ = engine;
            try context.document.removeChild(args.parentId, args.childId);
        }

        pub fn requestRender(engine: *EngineType, context: *Context, args: struct {}) anyerror!void {
            _ = engine;
            _ = context;
            _ = args;
            @panic("requestRender not implemented");
        }

        pub fn clearScreen(engine: *EngineType, context: *Context, args: struct {}) anyerror!void {
            _ = engine;
            _ = context;
            _ = args;
            @panic("clearScreen not implemented");
        }

        pub fn requestAnimationFrame(engine: *EngineType, context: *Context, args: struct {}) anyerror!void {
            _ = engine;
            _ = context;
            _ = args;
            @panic("requestAnimationFrame not implemented");
        }

        pub fn setTimeout(engine: *EngineType, context: *Context, args: struct { delayMs: f64 }) anyerror!void {
            _ = engine;
            _ = context;
            _ = args;
            @panic("setTimeout not implemented");
        }

        pub fn addEventListener(engine: *EngineType, context: *Context, args: struct { eventType: []const u8 }) anyerror!void {
            _ = engine;
            _ = context;
            _ = args;
            @panic("addEventListener not implemented");
        }

        pub fn getViewportSize(engine: *EngineType, context: *Context, args: struct {}) anyerror!void {
            _ = engine;
            _ = context;
            _ = args;
            @panic("getViewportSize not implemented");
        }

        pub fn setViewportSize(engine: *EngineType, context: *Context, args: struct { width: u32, height: u32 }) anyerror!void {
            _ = engine;
            _ = context;
            _ = args;
            @panic("setViewportSize not implemented");
        }
    };
}
