const std = @import("std");
const cli = @import("cli.zig");
const live = @import("live.zig");
const one_shot = @import("one_shot.zig");
const Trace = @import("Trace.zig");

/// Main application coordinator
pub const Application = struct {
    allocator: std.mem.Allocator,
    args: cli.Args,
    log_file: ?std.fs.File = null,

    fn tracer(self: Application) Trace.Trace {
        const log_file = self.log_file orelse std.io.getStdErr();
        const trace = Trace.file(log_file, .{});
        return switch (self.args.trace) {
            .off => trace.silent(),
            .on => trace.unlimited(),
            .depth => |d| trace.limited(d),
        };
    }

    pub fn init(allocator: std.mem.Allocator) !Application {
        const args_array = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args_array);

        const args = try cli.parse(allocator, args_array);

        return Application{
            .allocator = allocator,
            .args = args,
        };
    }

    pub fn deinit(self: *Application) void {
        if (self.log_file) |*f| {
            f.close();
            self.log_file = null;
        }
        self.args.deinit(self.allocator);
    }

    /// Run the application based on parsed arguments
    pub fn run(self: *Application) !void {
        // Setup logging if requested
        if (self.args.log_path) |path| {
            self.log_file = try std.fs.cwd().createFile(path, .{
                .truncate = true,
                .read = false,
                .exclusive = false,
            });
        }

        // Handle deprecated options
        if (self.args.unicode_boxes != null) {
            std.log.warn("--[no-]unicode-boxes option is deprecated and ignored", .{});
        }

        // Route to appropriate mode
        switch (self.args.mode) {
            .live => try self.runLive(),
            .one_shot => try self.runOneShot(),
        }
    }

    fn runLive(self: *Application) !void {
        // Extract input paths if provided
        const xml_path = switch (self.args.input) {
            .xml_file => |path| path,
            .xml_string => |xml| blk: {
                // Save inline XML to temp file for live mode
                const temp_path = try self.writeTempFile("live_input.xml", xml);
                break :blk temp_path;
            },
            else => null,
        };

        const wren_path = switch (self.args.input) {
            .wren_file => |path| path,
            .wren_string => |script| blk: {
                // Save inline script to temp file for live mode
                const temp_path = try self.writeTempFile("live_input.wren", script);
                break :blk temp_path;
            },
            else => null,
        };

        var trace = self.tracer();
        trace.enter();
        defer trace.exit();
        trace.info("XTC live session");

        try live.run(self.allocator, xml_path, wren_path, &trace);
    }

    fn runOneShot(self: *Application) !void {
        var trace = self.tracer();
        trace.enter();
        defer trace.exit();
        trace.info("XTC one-shot session");

        var session = one_shot.OneShotSession.init(self.allocator, .{
            .output = self.args.output,
            .log_file = self.log_file,
            .trace = &trace,
        });

        try session.run(self.args.input);
    }

    fn writeTempFile(self: *Application, name: []const u8, content: []const u8) ![]const u8 {
        const temp_dir = std.fs.cwd();
        const path = try std.fmt.allocPrint(self.allocator, "/tmp/xtc_{s}", .{name});

        const file = try temp_dir.createFile(path, .{});
        defer file.close();

        try file.writeAll(content);
        return path;
    }
};
