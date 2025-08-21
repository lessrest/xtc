const std = @import("std");
const ansi = @import("ansi");

const vm = @import("fiberscript/vm.zig");

const Engine = vm.Engine(.{});

pub const version = "0.5.0";

pub const panic = ansi.panic;

comptime {
    _ = @import("test/flex.test.zig");
    _ = @import("fiberscript/vm.zig");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var stderr = std.io.getStdErr().writer();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const program = try allocator.dupe(u8, args.next() orelse "xtc");
    defer allocator.free(program);

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try stderr.print("{s} v{s}\n", .{ program, version });
            return;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stderr.print("Usage: {s} <file>\n", .{program});
            return;
        }

        if (std.mem.endsWith(u8, arg, ".wren")) {
            return run_script(allocator, arg);
        }
    }

    try stderr.print("Usage: {s} <file>\n", .{program});
    return error.Usage;
}

fn run_script(allocator: std.mem.Allocator, name: []const u8) !void {
    var stderr = std.io.getStdErr().writer();

    const file = try std.fs.cwd().openFile(name, .{});
    defer file.close();

    const script = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(script);

    const engine = try Engine.init(allocator, .{});
    defer engine.deinit();

    try engine.runTopLevel(name, script); // TODO: croak...
    try engine.trampoline(engine.vm);

    std.debug.print("trampoline done\n", .{});
    const output = try engine.takeOutput(allocator);
    defer allocator.free(output);
    try stderr.print("{s}", .{output});
}
