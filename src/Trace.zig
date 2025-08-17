const std = @import("std");
const nest = @import("ansi").nest;

pub const Options = struct {
    enabled: bool = false,
    max_depth: ?usize = null,
};

// Simple adapter that uses TreeNest for tracing
pub const Trace = nest.TreeNest(std.fs.File.Writer);

// For backwards compatibility - create a Trace from a file
pub fn file(output_file: std.fs.File, options: Options) Trace {
    const allocator = std.heap.page_allocator;
    var trace = nest.treeNest(allocator, output_file.writer());
    trace.setEnabled(options.enabled);
    if (options.max_depth) |max| {
        trace.setMaxDepth(max);
    }
    return trace;
}

// Expose the generic tracer for custom writers if needed
pub const GenericTracer = nest.TreeNest;