const std = @import("std");
const lib = @import("lib.zig");
const Graphemes = @import("Graphemes");
const live = @import("live.zig");
const FormatTrace = @import("FormatTrace.zig");
const tty = @import("tty.zig");
const WrenRunner = @import("wren/runtime.zig");
const dom = @import("dom.zig");
const xmlparse = @import("xmlparse.zig");
const wren_xml = @import("wren/xml.zig");
const ticket = @import("ticket.zig");

// Global logging options using std.log
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = myLogFn,
};

pub var g_log_file: ?std.fs.File = null; // set at runtime by --log
fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const ts = std.time.timestamp();
    const prefix = "[" ++ comptime level.asText() ++ "](" ++ @tagName(scope) ++ ") ";
    if (g_log_file) |*f| {
        var bw = std.io.bufferedWriter(f.writer());
        const w = bw.writer();
        w.print(format ++ "\n", args) catch unreachable;
        bw.flush() catch {};
        return;
    }
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    _ = stderr.print("{d} " ++ prefix ++ format ++ "\n", .{ts} ++ args) catch {};
}

// Ensure panics leave the terminal in a readable state when running in raw + alt screen.
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    // Best-effort: reset attributes, show cursor, and exit alt screen buffer.
    // We cannot restore cooked termios here without the saved state, but this greatly improves readability.
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write("\x1b[0m\x1b[?25h\x1b[?1049l\n") catch {};
    // Print panic and stack trace similarly to std.debug.defaultPanic.
    _ = stderr.write("panic: ") catch {};
    _ = stderr.print("{s}\n", .{msg}) catch {};
    if (error_return_trace) |t| std.debug.dumpStackTrace(t.*);
    std.debug.dumpCurrentStackTrace(return_address);
    std.posix.abort();
}

fn formatTraceLog(allocator: std.mem.Allocator, log_path: []const u8) !void {
    var file = std.fs.cwd().openFile(log_path, .{ .mode = .read_only }) catch |err| {
        std.log.warn("Could not open log file {s}: {}", .{ log_path, err });
        return;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        std.log.warn("Could not stat log file {s}: {}", .{ log_path, err });
        return;
    };
    const size: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    _ = try file.readAll(bytes);

    const formatted = FormatTrace.formatLogXml(allocator, bytes) catch |err| {
        std.log.warn("Trace format failed: {}", .{err});
        return;
    };
    defer allocator.free(formatted);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(formatted);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const args = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, args);

    var log_path: ?[]const u8 = "xtc.log";
    var xml_input: ?[]const u8 = null;
    var wren_script: ?[]const u8 = null;
    var out_width: usize = 80;
    var out_height: usize = 24;
    var unicode_boxes: ?bool = null; // tri-state: null => default
    var debug_mode: bool = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--log")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing path after --log\n", .{});
                std.process.exit(2);
            }
            log_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--xml")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing string after --xml\n", .{});
                std.process.exit(2);
            }
            xml_input = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--width")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing number after --width\n", .{});
                std.process.exit(2);
            }
            out_width = std.fmt.parseUnsigned(usize, args[i + 1], 10) catch {
                try std.io.getStdErr().writer().print("invalid --width value: {s}\n", .{args[i + 1]});
                std.process.exit(2);
                unreachable;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--height")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing number after --height\n", .{});
                std.process.exit(2);
            }
            out_height = std.fmt.parseUnsigned(usize, args[i + 1], 10) catch {
                try std.io.getStdErr().writer().print("invalid --height value: {s}\n", .{args[i + 1]});
                std.process.exit(2);
                unreachable;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--unicode-boxes")) {
            unicode_boxes = true;
        } else if (std.mem.eql(u8, a, "--no-unicode-boxes")) {
            unicode_boxes = false;
        } else if (std.mem.eql(u8, a, "--debug")) {
            debug_mode = true;
        } else if (std.mem.eql(u8, a, "--wren")) {
            if (i + 1 >= args.len) {
                try std.io.getStdErr().writer().print("missing file/script after --wren\n", .{});
                std.process.exit(2);
            }
            wren_script = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--live")) {
            // Flag is handled later, just skip it here
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std.io.getStdOut().writer().print(
                "usage: xtc [--live] [--log <file>] [--xml <string>] [--wren <file|script>] [--width N] [--height N] [--[no-]unicode-boxes] [--debug]\n" ++
                    "  --live: Run in live mode with alternate screen buffer (use with --xml)\n",
                .{},
            );
            return;
        } else {
            try std.io.getStdErr().writer().print("unknown argument: {s}\n", .{a});
            std.process.exit(2);
        }
    }

    // Initialize optional log file for std.log override
    var opened: ?std.fs.File = null;
    if (log_path) |lp| {
        // Always create/truncate the log file to start fresh
        opened = std.fs.cwd().createFile(lp, .{ .truncate = true, .read = false, .exclusive = false }) catch null;
        if (opened) |f| {
            g_log_file = f;
            std.log.info("logging to {s}", .{lp});
        }
    }
    defer {
        if (opened) |f| f.close();
        // Avoid writing to a closed file from logFn during formatting
        g_log_file = null;

        // Format trace log if debug mode is enabled
        if (debug_mode and log_path != null) {
            formatTraceLog(al, log_path.?) catch |err| {
                // Print diagnostics to stderr and fall back to raw span dump
                const stderr = std.io.getStdErr().writer();
                _ = stderr.print("[trace] format failed: {}\n", .{err}) catch {};
                // Best-effort raw dump of XML span region
                if (std.fs.cwd().readFileAlloc(al, log_path.?, 16 * 1024 * 1024)) |raw_bytes| {
                    defer al.free(raw_bytes);
                    if (std.mem.indexOf(u8, raw_bytes, "<span>")) |start_idx| {
                        _ = stderr.writeAll(raw_bytes[start_idx..]) catch {};
                    }
                } else |_| {}
            };
        }
    }

    // Apply unicode boxes preference if specified (applies to both modes)
    if (unicode_boxes) |on| tty.setUseUnicodeBoxes(on);

    // Check for --live flag to determine mode
    var is_live_mode = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--live")) {
            is_live_mode = true;
            break;
        }
    }

    // If not explicitly live mode, check if we have xml or wren for one-shot mode
    if (!is_live_mode) {
        if (xml_input) |xml| {
            // Check if it's a file path or XML content
            const xml_content = if (std.fs.cwd().readFileAlloc(al, xml, 1024 * 1024)) |content|
                content
            else |_|
                xml; // If file read fails, treat it as inline XML

            // Parse XML and use Wren integration (handles both with and without scripts)
            var reader = std.io.fixedBufferStream(xml_content);
            var xml_doc = try xmlparse.parse(al, "inline", reader.reader());
            defer xml_doc.deinit();

            var document = dom.Dom.init(al);
            // Note: WrenRunner.deinit() will handle document.deinit()

            var runner = try WrenRunner.init(al, &document);
            defer runner.deinit();

            // Build DOM and execute scripts (if any)
            try wren_xml.buildDomIntoAndRunScripts(WrenRunner.ScriptContext, al, &xml_doc, &runner.vm, &document);

            // Print any Wren output to stderr for debugging
            const wren_output = runner.output.items;
            if (wren_output.len > 0) {
                _ = try std.io.getStdErr().write(wren_output);
            }

            // Render the resulting DOM
            try lib.renderDocumentToWriter(al, &document, std.io.getStdOut().writer(), out_width, out_height);
            return;
        }

        if (wren_script) |script_input| {
            // Check if it's a file path or inline script
            const script_content = if (std.fs.cwd().readFileAlloc(al, script_input, 1024 * 1024)) |content| content else |_| script_input;
            defer if (script_content.ptr != script_input.ptr) al.free(script_content);

            var document = dom.Dom.init(al);
            var runner = try WrenRunner.init(al, &document);
            defer runner.deinit();

            const script_id = ticket.from(script_content) catch @panic("Failed to generate script ID");

            runner.vm.interpret(&script_id, script_content) catch |err| {
                try std.io.getStdErr().writer().print("Wren script error: {}\n", .{err});
                std.process.exit(1);
            };

            // Print output to stdout
            const output = runner.output.items;
            if (output.len > 0) {
                _ = try std.io.getStdOut().write(output);
            }

            try lib.renderDocumentToWriter(
                al,
                runner.document,
                std.io.getStdOut().writer(),
                out_width,
                out_height,
            );

            return;
        }
    }

    // Live mode (default if no xml/wren, or if --live is specified)
    try live.run(al, xml_input, wren_script);
}
