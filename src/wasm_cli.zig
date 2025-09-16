const std = @import("std");
const wasm = @import("wasm.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simple test layout
    const markup =
        \\<root>
        \\  <box class="flex flex-col gap-2 p-2 bg-blue-900">
        \\    <box class="text-cyan-400 bold text-center">XTC WASM Rendering</box>
        \\    <box class="flex gap-2">
        \\      <box class="flex-1 p-1 bg-green-800 text-green-300">✓ Working</box>
        \\      <box class="flex-1 p-1 bg-yellow-800 text-yellow-300">✢ Fast</box>
        \\    </box>
        \\    <box class="text-gray-400 text-center">Running on WASM</box>
        \\  </box>
        \\</root>
    ;

    // Use WasmLiveSession from wasm.zig
    var session = wasm.WasmLiveSession.init(allocator, .{
        .output = .{ .width = 40, .height = 8 },
    });
    defer if (session.document) |doc| doc.deinit();
    defer if (session.window) |win| win.deinit();

    try session.initSession(.{ .script = .{ .module = "main", .source = markup } });
    _ = try session.processFrame();

    if (session.window) |window| {
        // Avoid alternate screen for CLI demo.
        window.state.needs_clear = false;
        window.state.needs_tty_restore = false;
    }

    try session.render();
}
