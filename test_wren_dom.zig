const std = @import("std");
const wren = @import("src/wren.zig");
const Dom = @import("src/dom.zig").Dom;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a DOM instance
    var dom = Dom.init(allocator);
    defer dom.deinit();

    // Create user data struct that includes DOM reference
    const UserData = struct {
        allocator: std.mem.Allocator,
        dom: *Dom,
        output: std.ArrayList(u8),

        pub fn write(self: *@This(), text: []const u8) void {
            self.output.appendSlice(text) catch {};
        }

        pub fn onError(self: *@This(), error_type: wren.WrenErrorType, module: []const u8, line: c_int, message: []const u8) void {
            _ = self;
            std.debug.print("Wren error {}: {}:{} - {s}\n", .{ error_type, module, line, message });
        }
    };

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var user_data = try allocator.create(UserData);
    defer allocator.destroy(user_data);
    user_data.* = .{
        .allocator = allocator,
        .dom = &dom,
        .output = output,
    };

    // Create Wren VM with DOM access
    var vm = try wren.create(UserData, user_data);
    defer vm.deinit();

    // Define the DOM module in Wren
    const dom_module =
        \\foreign class DOM {
        \\    foreign static createElement(tag)
        \\}
        \\
        \\foreign class Element {
        \\    foreign setAttribute(name, value)
        \\    foreign appendChild(child)
        \\}
    ;

    // Run the DOM module first
    try vm.interpret("dom", dom_module);

    // Now run a test script that uses the DOM
    const test_script =
        \\import "dom" for DOM, Element
        \\
        \\// Create some elements
        \\var div = DOM.createElement("div")
        \\var span = DOM.createElement("span")
        \\
        \\System.print("Created elements!")
        \\System.print("div: %(div)")
        \\System.print("span: %(span)")
    ;

    try vm.interpret("main", test_script);

    // Print the output
    std.debug.print("Wren output:\n{s}\n", .{user_data.output.items});
}