const std = @import("std");

/// Parsed command-line arguments
pub const Args = struct {
    // Execution mode
    mode: Mode,
    
    // Input source
    input: Input,
    
    // Output configuration
    output: OutputConfig,
    
    // Debug/logging
    log_path: ?[]const u8 = "xtc.log",
    debug_mode: bool = false,
    
    // Deprecated options
    unicode_boxes: ?bool = null,
};

pub const Mode = enum {
    one_shot,  // Render once and exit
    live,      // Interactive mode
};

pub const Input = union(enum) {
    xml_file: []const u8,
    xml_string: []const u8,
    wren_file: []const u8,
    wren_string: []const u8,
    default: void,
};

pub const OutputConfig = struct {
    width: usize = 80,
    height: usize = 24,
};

/// Parse command-line arguments into structured form
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Args {
    var result = Args{
        .mode = .one_shot,  // Default to one-shot
        .input = .{ .default = {} },
        .output = .{},
    };
    
    var i: usize = 1;  // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        
        if (std.mem.eql(u8, arg, "--live")) {
            result.mode = .live;
        } else if (std.mem.eql(u8, arg, "--log")) {
            result.log_path = try expectValue(arg, args, &i);
        } else if (std.mem.eql(u8, arg, "--xml")) {
            const value = try expectValue(arg, args, &i);
            result.input = try parseXmlInput(allocator, value);
        } else if (std.mem.eql(u8, arg, "--wren")) {
            const value = try expectValue(arg, args, &i);
            result.input = try parseWrenInput(allocator, value);
        } else if (std.mem.eql(u8, arg, "--width")) {
            const value = try expectValue(arg, args, &i);
            result.output.width = try parseNumber(usize, value, arg);
        } else if (std.mem.eql(u8, arg, "--height")) {
            const value = try expectValue(arg, args, &i);
            result.output.height = try parseNumber(usize, value, arg);
        } else if (std.mem.eql(u8, arg, "--unicode-boxes")) {
            result.unicode_boxes = true;
        } else if (std.mem.eql(u8, arg, "--no-unicode-boxes")) {
            result.unicode_boxes = false;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            result.debug_mode = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else {
            try std.io.getStdErr().writer().print("Unknown argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    
    // Auto-detect live mode if no input provided
    if (result.input == .default and result.mode == .one_shot) {
        result.mode = .live;
    }
    
    return result;
}

fn expectValue(flag: []const u8, args: []const []const u8, index: *usize) ![]const u8 {
    if (index.* + 1 >= args.len) {
        try std.io.getStdErr().writer().print("Missing value after {s}\n", .{flag});
        std.process.exit(2);
    }
    index.* += 1;
    return args[index.*];
}

fn parseNumber(comptime T: type, value: []const u8, flag: []const u8) !T {
    return std.fmt.parseUnsigned(T, value, 10) catch {
        try std.io.getStdErr().writer().print("Invalid {s} value: {s}\n", .{ flag, value });
        std.process.exit(2);
    };
}

fn parseXmlInput(allocator: std.mem.Allocator, value: []const u8) !Input {
    // Check if it's a file or inline XML
    if (std.fs.cwd().readFileAlloc(allocator, value, 1024 * 1024)) |content| {
        _ = content;  // We'll read it again when needed
        return .{ .xml_file = value };
    } else |_| {
        // Treat as inline XML
        return .{ .xml_string = value };
    }
}

fn parseWrenInput(allocator: std.mem.Allocator, value: []const u8) !Input {
    // Check if it's a file or inline script
    if (std.fs.cwd().readFileAlloc(allocator, value, 1024 * 1024)) |content| {
        allocator.free(content);  // Just checking existence
        return .{ .wren_file = value };
    } else |_| {
        // Treat as inline script
        return .{ .wren_string = value };
    }
}

fn printHelp() void {
    const help_text =
        \\Usage: xtc [OPTIONS]
        \\
        \\Terminal UI compositor with Tailwind-style layout
        \\
        \\Options:
        \\  --live                Run in interactive mode (default if no input)
        \\  --xml <file|string>   Load XML content (file path or inline)
        \\  --wren <file|script>  Load Wren script (file path or inline)
        \\  --width <N>           Output width (default: 80)
        \\  --height <N>          Output height (default: 24)
        \\  --log <file>          Log file path (default: xtc.log)
        \\  --debug               Enable debug mode with trace formatting
        \\  -h, --help           Show this help message
        \\
        \\Examples:
        \\  xtc --live --xml layout.xml
        \\  xtc --xml '<root class="flex"><text>Hello</text></root>' --width 40
        \\  xtc --wren script.wren
        \\
    ;
    _ = std.io.getStdOut().writer().writeAll(help_text) catch {};
}