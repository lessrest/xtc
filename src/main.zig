const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi");
const miniflex = @import("miniflex");
const live = @import("live.zig");
const xml = @import("xml.zig");
const xmlparse = @import("xmlparse.zig");
const LiveSession = live.LiveSession;
const time = std.time;
const posix = std.posix;
const Thread = std.Thread;

test {
    _ = @import("miniflex");
    _ = @import("fiberscript/wren.zig");
    _ = @import("fiberscript/vm.zig");
    _ = @import("test/flex.test.zig");
}

pub const version = "0.5.0";

pub const panic = ansi.panic;

const log = std.log.scoped(.xtc);

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var nest: ansi.nest.TreeNest = undefined;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) void {
    logprint(level, scope, format, args) catch unreachable;
}

fn logprint(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) !void {
    try nest.dk().log(level, scope, format, args);
    try nest.writer.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // arena
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    nest = ansi.nest.stderr(arena.allocator());

    var err_buf: [512]u8 = undefined;
    var err_state = std.fs.File.stderr().writer(&err_buf);
    const stderr: *std.Io.Writer = &err_state.interface;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const program = try allocator.dupe(u8, args.next() orelse "xtc");
    defer allocator.free(program);

    var script_path: ?[]const u8 = null;
    var xml_markup: ?[]const u8 = null;
    var width: usize = 80;
    var height: ?usize = null;
    var ansi_output = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try stderr.print("{s} v{s}\n", .{ program, version });
            try stderr.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(stderr, program);
            return;
        } else if (std.mem.eql(u8, arg, "--xml")) {
            xml_markup = args.next() orelse {
                try stderr.writeAll("error: --xml requires a markup argument\n");
                try printUsage(stderr, program);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--width")) {
            const value = args.next() orelse {
                try stderr.writeAll("error: --width requires a number\n");
                try printUsage(stderr, program);
                std.process.exit(2);
            };
            width = std.fmt.parseInt(usize, value, 10) catch {
                try stderr.print("error: invalid --width value '{s}'\n", .{value});
                try printUsage(stderr, program);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--height")) {
            const value = args.next() orelse {
                try stderr.writeAll("error: --height requires a number\n");
                try printUsage(stderr, program);
                std.process.exit(2);
            };
            height = std.fmt.parseInt(usize, value, 10) catch {
                try stderr.print("error: invalid --height value '{s}'\n", .{value});
                try printUsage(stderr, program);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--ansi")) {
            ansi_output = true;
        } else if (std.mem.endsWith(u8, arg, ".wren")) {
            script_path = arg;
        } else {
            try stderr.print("error: unknown argument '{s}'\n", .{arg});
            try printUsage(stderr, program);
            std.process.exit(2);
        }
    }

    if (xml_markup) |markup| {
        return renderXmlToStdout(allocator, markup, width, height, ansi_output);
    }

    if (script_path) |path| {
        return run_script(allocator, path);
    }

    try printUsage(stderr, program);
    std.process.exit(2);
}

fn printUsage(stderr: *std.Io.Writer, program: []const u8) !void {
    try stderr.print(
        \\Usage:
        \\  {s} <file.wren>
        \\  {s} --xml '<root class="...">...</root>' [--width N] [--height N] [--ansi]
        \\
    , .{ program, program });
    try stderr.flush();
}

const Viewport = struct {
    width: usize,
    height: usize,
};

fn detectViewport(stdout_file: std.fs.File) Viewport {
    var width: usize = 80;
    var height: usize = 25;

    if (!stdout_file.isTty()) {
        return .{ .width = width, .height = height };
    }

    switch (builtin.os.tag) {
        .windows => return .{ .width = width, .height = height },
        else => {
            var winsize: posix.winsize = .{
                .row = 0,
                .col = 0,
                .xpixel = 0,
                .ypixel = 0,
            };

            const err = posix.system.ioctl(stdout_file.handle, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
            if (posix.errno(err) == .SUCCESS and winsize.col != 0 and winsize.row != 0) {
                width = @as(usize, @intCast(winsize.col));
                height = @as(usize, @intCast(winsize.row));
            }
        },
    }

    return .{ .width = width, .height = height };
}

fn renderXmlToStdout(
    allocator: std.mem.Allocator,
    markup: []const u8,
    width: usize,
    requested_height: ?usize,
    ansi_output: bool,
) !void {
    var trace = ansi.nest.silent(allocator);

    var unicode = try miniflex.UnicodeData.init(allocator);
    defer unicode.deinit(allocator);

    var glyphs = try miniflex.GlyphTable.init(allocator);
    defer glyphs.deinit();

    var painter = miniflex.Painter.init(allocator, &unicode, &trace);
    defer painter.deinit();

    var fbs = std.io.fixedBufferStream(markup);
    var xdoc = try xmlparse.parse(allocator, "<stdin>", fbs.reader());
    defer xdoc.deinit();

    var document = try xml.loadDocumentFromMarkup(allocator, &xdoc);
    defer document.deinit();

    var tree = try miniflex.layout.allocateBoxTreeFromDOM(allocator, document, 0);
    defer tree.deinit();

    const height = requested_height orelse miniflex.measure.intrinsicSize(
        document,
        &tree,
        0,
        width,
        0,
        &unicode,
    )[1];

    var layout_engine = miniflex.layout.init(allocator, &unicode, &trace);
    try layout_engine.layoutSubtree(
        &tree,
        document,
        tree.getNodeMut(0),
        .{ .x = 0, .y = 0, .w = width, .h = height },
    );

    var raster = try miniflex.Raster.init(allocator, width, height);
    defer raster.deinit(allocator);

    try painter.computePaintCommands(document, &tree, glyphs);
    try raster.rasterizeDisplayList(allocator, glyphs, &painter);

    var out_buf: [4096]u8 = undefined;
    var out_state = std.fs.File.stdout().writer(&out_buf);
    const stdout: *std.Io.Writer = &out_state.interface;
    if (ansi_output) {
        try raster.writeAsAnsiText(stdout, glyphs);
    } else {
        try raster.writeAsPlainText(stdout, glyphs);
    }
    try stdout.flush();
}

pub fn run_script(allocator: std.mem.Allocator, script_path: []const u8) !void {
    var stdout_file = std.fs.File.stdout();
    const viewport = detectViewport(stdout_file);
    log.info("using viewport {d}x{d}", .{ viewport.width, viewport.height });

    const file_path = if (std.fs.path.isAbsolute(script_path))
        try allocator.dupe(u8, script_path)
    else
        try std.fs.cwd().realpathAlloc(allocator, script_path);
    defer allocator.free(file_path);

    const file_content = try std.fs.cwd().readFileAlloc(allocator, script_path, 1024 * 1024);
    defer allocator.free(file_content);

    var session = LiveSession.init(allocator, .{
        .output = .{ .width = viewport.width, .height = viewport.height },
    });
    defer session.deinit();

    log.info("running top-level script {s}", .{file_path});
    try session.initSession(.{ .script = .{ .module = "main", .source = file_content } });

    if (!stdout_file.isTty()) {
        if (session.window) |window| {
            window.state.needs_clear = false;
            window.state.needs_tty_restore = false;
        }
    }

    if (session.context) |context| {
        log.info("{d} thunk fibers in queue", .{context.thunks.items.len});
    }

    const frame_interval_ns: u64 = 16 * time.ns_per_ms;
    var frame_count: usize = 0;

    while (true) {
        const needs_render = session.processFrame() catch |err| {
            log.err("process frame error: {}", .{err});
            if (session.engine) |engine| {
                engine.croak() catch {};
            }
            return err;
        };

        if (needs_render) {
            session.render() catch |err| {
                log.err("render error: {}", .{err});
                return err;
            };
            frame_count += 1;
        }

        const has_work = session.hasPendingWork();
        if (!has_work and !needs_render) {
            break;
        }

        if (has_work) {
            Thread.sleep(frame_interval_ns);
        }
    }

    if (session.context) |context| {
        log.info(
            "joining {d} background threads",
            .{context.background_threads.items.len},
        );
    }
    try session.joinBackgroundThreads();

    log.info("rendered {d} frames", .{frame_count});
    log.info("done", .{});
    try nest.newline();
    try nest.writer.flush();

    log.info("winding down", .{});
}
