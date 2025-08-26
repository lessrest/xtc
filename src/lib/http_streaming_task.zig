const std = @import("std");
const streaming_task = @import("streaming_request_task.zig");

/// HTTP-specific payload types that can be delivered to waiting fibers
pub const HttpPayload = union(enum) {
    head: struct { status: u16 },
    data: []u8,
    end: void,
    @"error": []const u8,

    pub fn deinit(self: HttpPayload, allocator: std.mem.Allocator) void {
        switch (self) {
            .data => |chunk| allocator.free(chunk),
            .@"error" => |msg| allocator.free(msg),
            else => {},
        }
    }
};

/// Specialized StreamingRequestTask for HTTP operations
pub fn HttpStreamingTask(comptime Fiber: type) type {
    const BaseTask = streaming_task.StreamingRequestTask(HttpPayload, Fiber);

    return struct {
        const Self = @This();

        base: BaseTask,

        pub const RequestId = BaseTask.RequestId;
        pub const Delivery = BaseTask.Delivery;
        pub const Completion = BaseTask.Completion;

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .base = BaseTask.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            // Clean up HTTP payloads before base cleanup to avoid double-free
            self.base.delivery_mutex.lock();
            for (self.base.pending_deliveries.items) |delivery| {
                delivery.payload.deinit(self.base.allocator);
            }
            // Clear the deliveries so base.deinit doesn't try to process them
            self.base.pending_deliveries.clearAndFree(self.base.allocator);
            self.base.delivery_mutex.unlock();

            self.base.deinit();
        }

        /// Start a new HTTP request and spawn background worker
        pub fn openRequest(self: *Self, url: []const u8, method: []const u8) !RequestId {
            const id = try self.base.submit();

            try self.spawnHttpWorker(id, url, method);
            return id;
        }

        /// Register fiber to wait for next HTTP payload
        pub fn awaitPayload(self: *Self, request_id: RequestId, fiber: Fiber, timeout_ms: u64) !void {
            try self.base.await(request_id, fiber, timeout_ms);
        }

        /// Cancel HTTP request
        pub fn cancel(self: *Self, request_id: RequestId) void {
            self.base.cancel(request_id);
        }

        /// Process all pending HTTP events
        pub fn processEvents(self: *Self) struct {
            deliveries: []Delivery,
            completions: []Completion,
        } {
            const events = self.base.processEvents();
            return .{
                .deliveries = events.deliveries,
                .completions = events.completions,
            };
        }

        /// Check for timed out waiters
        pub fn checkTimeouts(self: *Self, allocator: std.mem.Allocator) ![]Fiber {
            return self.base.checkTimeouts(allocator);
        }

        /// Remove waiter for request
        pub fn removeWaiter(self: *Self, request_id: RequestId) ?Fiber {
            return self.base.removeWaiter(request_id);
        }

        /// Check if there are any active HTTP requests
        pub fn hasRequests(self: *Self) bool {
            return self.base.requests.count() > 0;
        }

        /// Check if there are any waiters
        pub fn hasWaiters(self: *Self) bool {
            return self.base.waiters.count() > 0;
        }

        /// Background thread helpers - thread safe
        pub fn deliverHead(self: *Self, request_id: RequestId, status: u16) void {
            self.base.deliver(request_id, .{ .head = .{ .status = status } });
        }

        pub fn deliverData(self: *Self, request_id: RequestId, chunk: []u8) void {
            self.base.deliver(request_id, .{ .data = chunk });
        }

        pub fn deliverEnd(self: *Self, request_id: RequestId) void {
            self.base.deliver(request_id, .{ .end = {} });
            self.base.complete(request_id);
        }

        pub fn deliverError(self: *Self, request_id: RequestId, message: []const u8) void {
            const owned_msg = self.base.allocator.dupe(u8, message) catch "";
            self.base.deliver(request_id, .{ .@"error" = owned_msg });
            self.base.fail(request_id, message);
        }

        /// Spawn background HTTP worker thread
        fn spawnHttpWorker(self: *Self, request_id: RequestId, url: []const u8, method: []const u8) !void {
            const url_copy = try self.base.allocator.dupe(u8, url);
            errdefer self.base.allocator.free(url_copy);
            const method_copy = try self.base.allocator.dupe(u8, method);
            errdefer self.base.allocator.free(method_copy);

            _ = try std.Thread.spawn(.{}, httpWorker, .{ self, request_id, url_copy, method_copy });
        }

        /// Background HTTP worker function
        fn httpWorker(self: *Self, request_id: RequestId, url: []const u8, method: []const u8) void {
            defer self.base.allocator.free(url);
            defer self.base.allocator.free(method);

            var client = std.http.Client{ .allocator = self.base.allocator };
            defer client.deinit();

            const uri = std.Uri.parse(url) catch |e| {
                self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "invalid url: {}", .{e}) catch "invalid url");
                return;
            };

            const http_method: std.http.Method = methodFromString(method);
            var req = std.http.Client.request(&client, http_method, uri, .{}) catch |e| {
                self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "request failed: {}", .{e}) catch "request failed");
                return;
            };
            defer req.deinit();

            req.sendBodiless() catch |e| {
                self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "send failed: {}", .{e}) catch "send failed");
                return;
            };

            var empty: [0]u8 = .{};
            var resp = req.receiveHead(&empty) catch |e| {
                self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "receive head failed: {}", .{e}) catch "receive head failed");
                return;
            };

            // Deliver head
            self.deliverHead(request_id, @intFromEnum(resp.head.status));

            // Stream body
            var buf: [4096]u8 = undefined;
            var out: std.Io.Writer = .fixed(buf[0..]);
            const reader = resp.reader(&.{});

            while (true) {
                // Check if request was cancelled
                if (!self.base.isActive(request_id)) break;

                out.end = 0;
                const n = reader.stream(&out, std.Io.Limit.limited(buf.len)) catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => {
                        self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "read failed: {}", .{e}) catch "read failed");
                        return;
                    },
                };

                if (n == 0 and out.end == 0) continue;

                // Allocate owned chunk for delivery
                const chunk = self.base.allocator.alloc(u8, out.end) catch {
                    self.deliverError(request_id, "out of memory");
                    return;
                };
                @memcpy(chunk, buf[0..out.end]);
                self.deliverData(request_id, chunk);
            }

            // Signal completion
            self.deliverEnd(request_id);
        }

        fn methodFromString(method: []const u8) std.http.Method {
            inline for (@typeInfo(std.http.Method).@"enum".fields) |f| {
                if (std.ascii.eqlIgnoreCase(method, f.name)) return @enumFromInt(f.value);
            }
            return .GET;
        }
    };
}
