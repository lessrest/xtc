const std = @import("std");
const c = @import("wren.zig");

/// Error reporting and collection for Wren virtual machine.
///
/// This module handles compilation errors, runtime errors, and stack trace
/// collection from Wren, providing structured error information to the host.
pub const ErrorHandler = struct {
    buffer: std.heap.FixedBufferAllocator,
    current_error: ErrorReport,

    pub const Options = struct {
        buffer_size: usize = 1024 * 32,
    };

    pub const ErrorReport = union(enum) {
        none: struct {},
        compilation_error: struct {
            error_message: []const u8,
            module_name: []const u8,
            source_line: usize,
        },
        runtime_error: struct {
            message: []const u8,
            stack_trace: std.ArrayListUnmanaged(StackTraceLine),
        },
    };

    pub const StackTraceLine = struct {
        symbol_name: []const u8,
        module_name: []const u8,
        source_line: usize,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !ErrorHandler {
        return ErrorHandler{
            .buffer = std.heap.FixedBufferAllocator.init(
                try allocator.alloc(u8, options.buffer_size),
            ),
            .current_error = .{ .none = .{} },
        };
    }

    pub fn deinit(self: *ErrorHandler, allocator: std.mem.Allocator) void {
        self.clearError();
        allocator.free(self.buffer.buffer);
    }

    /// C callback function for Wren's error reporting.
    ///
    /// Handles different types of errors:
    /// - Compilation errors: syntax and resolution errors
    /// - Runtime errors: execution-time errors with stack traces
    /// - Stack trace entries: individual frames in the call stack
    pub fn errorFn(
        self: *ErrorHandler,
        error_type: c.ErrorType,
        module_ptr: ?[*:0]const u8,
        line: c_int,
        message_ptr: ?[*:0]const u8,
    ) callconv(.c) void {
        const allocator = self.buffer.allocator();

        const message = if (message_ptr) |m| std.mem.span(m) else "";
        const module = if (module_ptr) |m| std.mem.span(m) else "";

        switch (self.current_error) {
            .runtime_error => |*runtime_error| {
                switch (error_type) {
                    .stack_trace => {
                        runtime_error.stack_trace.append(allocator, .{
                            .symbol_name = allocator.dupe(u8, message) catch {
                                std.debug.panic("failed to dupe symbol name", .{});
                            },
                            .module_name = allocator.dupe(u8, module) catch {
                                std.debug.panic("failed to dupe module name", .{});
                            },
                            .source_line = @intCast(line),
                        }) catch {
                            std.debug.panic("failed to append stack trace line", .{});
                        };
                    },
                    else => std.debug.panic("{any} during runtime error", .{error_type}),
                }
            },
            else => {
                switch (error_type) {
                    .compile => {
                        self.current_error = .{
                            .compilation_error = .{
                                .error_message = allocator.dupe(u8, message) catch {
                                    std.debug.panic("failed to dupe error message", .{});
                                },
                                .module_name = allocator.dupe(u8, module) catch {
                                    std.debug.panic("failed to dupe module name", .{});
                                },
                                .source_line = @intCast(line),
                            },
                        };
                    },
                    .runtime => {
                        self.current_error = .{
                            .runtime_error = .{
                                .message = allocator.dupe(u8, message) catch {
                                    std.debug.panic("failed to dupe message", .{});
                                },
                                .stack_trace = std.ArrayListUnmanaged(StackTraceLine){},
                            },
                        };
                    },
                    .stack_trace => std.debug.panic("stack trace without error", .{}),
                }
            },
        }
    }

    /// Returns the current error and clears it.
    pub fn takeError(self: *ErrorHandler) ErrorReport {
        const error_report = self.current_error;
        self.current_error = .{ .none = .{} };
        return error_report;
    }

    /// Returns an error if there is a current error.
    /// If there is no error, does nothing.
    pub fn checkError(self: *ErrorHandler) error{ CompilationError, RuntimeError }!void {
        switch (self.current_error) {
            .compilation_error => return error.CompilationError,
            .runtime_error => return error.RuntimeError,
            else => {},
        }
    }

    /// Clears the current error without returning it.
    pub fn clearError(self: *ErrorHandler) void {
        // Free any allocated memory in the current error
        const allocator = self.buffer.allocator();
        switch (self.current_error) {
            .runtime_error => |*runtime_error| {
                for (runtime_error.stack_trace.items) |trace_line| {
                    allocator.free(trace_line.symbol_name);
                    allocator.free(trace_line.module_name);
                }
                runtime_error.stack_trace.deinit(allocator);
            },
            .compilation_error => |comp_error| {
                allocator.free(comp_error.error_message);
                allocator.free(comp_error.module_name);
            },
            .none => {},
        }
        self.current_error = .{ .none = .{} };
    }

    /// Prints the current error to stderr and converts it to a Zig error.
    pub fn croak(self: *ErrorHandler) error{ CompilationError, RuntimeError }!void {
        const error_report = self.takeError();
        switch (error_report) {
            .none => {},
            .compilation_error => |comp_error| {
                std.debug.print("compilation error: {s}\n", .{comp_error.error_message});
                return error.CompilationError;
            },
            .runtime_error => |runtime_error| {
                std.debug.print("runtime error: {s}\n", .{runtime_error.message});
                for (runtime_error.stack_trace.items) |line| {
                    std.debug.print("  {s} in {s}:{d}\n", .{
                        line.symbol_name,
                        line.module_name,
                        line.source_line,
                    });
                }
                return error.RuntimeError;
            },
        }
    }
};
