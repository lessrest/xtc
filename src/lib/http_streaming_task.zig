const std = @import("std");
const streaming_task = @import("streaming_request_task.zig");
const Pom = @import("../pom.zig").Pom;
const TaskId = @import("../pom.zig").TaskId;
const ScopePolicy = @import("../pom.zig").ScopePolicy;

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
        pom: ?*Pom = null,  // Optional task hierarchy
        http_scope: TaskId = 0,  // HTTP request parent scope
        
        pub const RequestId = BaseTask.RequestId;
        pub const Delivery = BaseTask.Delivery;
        pub const Completion = BaseTask.Completion;
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .base = BaseTask.init(allocator) };
        }
        
        /// Initialize with optional POM integration for structured tasks
        pub fn initWithPom(allocator: std.mem.Allocator, pom: ?*Pom, parent_scope: TaskId) !Self {
            var self = Self{ .base = BaseTask.init(allocator), .pom = pom };
            
            // Create HTTP request scope under parent
            if (pom) |p| {
                std.debug.print("DEBUG: initWithPom creating scope under parent_scope={}\n", .{parent_scope});
                self.http_scope = try p.createScope(parent_scope, "http_requests", .fail_fast);
                std.debug.print("DEBUG: initWithPom created http_scope={}\n", .{self.http_scope});
            }
            
            return self;
        }
        
        pub fn deinit(self: *Self) void {
            // Cancel any active HTTP tasks before cleanup
            if (self.pom) |pom| {
                std.debug.print("DEBUG: HttpStreamingTask.deinit() - http_scope={}\n", .{self.http_scope});
                if (self.http_scope != 0) {
                    std.debug.print("DEBUG: About to call pom.cancelTask({})\n", .{self.http_scope});
                    pom.cancelTask(self.http_scope);
                }
                pom.joinAllThreads();
            }
            self.base.deinit();
        }
        
        /// Start a new HTTP request and spawn background worker
        pub fn openRequest(self: *Self, url: []const u8, method: []const u8) !RequestId {
            const id = try self.base.submit();
            
            // Create structured task scope for this specific request
            var request_task: TaskId = 0;
            if (self.pom) |pom| {
                if (self.http_scope != 0) {
                    var buf: [128]u8 = undefined;
                    const task_name = std.fmt.bufPrint(&buf, "http_{s}_{d}", .{ method, id }) catch "http_request";
                    request_task = pom.createScope(self.http_scope, task_name, .one_for_one) catch 0;
                }
            }
            
            try self.spawnHttpWorker(id, request_task, url, method);
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
        
        /// Check if there are any head waiters (compatibility)
        pub fn hasHeadWaiters(self: *Self) bool {
            return self.base.waiters.count() > 0;
        }
        
        /// Check if there are any read waiters (compatibility)
        pub fn hasReadWaiters(self: *Self) bool {
            return self.base.waiters.count() > 0;
        }
        
        /// Process supervision events if POM is available
        pub fn processSupervision(self: *Self) !void {
            if (self.pom) |pom| {
                try pom.processSupervision();
            }
        }
        
        /// Get supervision status report for debugging
        pub fn getSupervisionStatus(self: *Self, buf: []u8) []const u8 {
            if (self.pom) |_| {
                return std.fmt.bufPrint(buf, "HTTP tasks under scope {d}, total requests: {d}", 
                    .{ self.http_scope, self.base.requests.count() }) catch "status unavailable";
            }
            return std.fmt.bufPrint(buf, "No supervision (legacy mode), requests: {d}", 
                .{self.base.requests.count()}) catch "status unavailable";
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
        fn spawnHttpWorker(self: *Self, request_id: RequestId, task_id: TaskId, url: []const u8, method: []const u8) !void {
            const url_copy = try self.base.allocator.dupe(u8, url);
            errdefer self.base.allocator.free(url_copy);
            const method_copy = try self.base.allocator.dupe(u8, method);
            errdefer self.base.allocator.free(method_copy);
            
            // Spawn thread and register with POM if available
            _ = try std.Thread.spawn(.{}, httpWorker, .{ self, request_id, task_id, url_copy, method_copy });
            if (self.pom) |pom| {
                if (task_id != 0) {
                    _ = pom.spawnThread(task_id, pomThreadWrapper) catch {};
                }
            }
        }
        
        /// POM thread wrapper
        fn pomThreadWrapper(pom: *Pom, task_id: TaskId) void {
            // The actual work is handled by httpWorker - this is just for POM tracking
            _ = pom;
            _ = task_id;
        }
        
        /// Helper to update POM task state safely
        fn setPomState(self: *Self, task_id: TaskId, state: @import("../pom.zig").TaskState) void {
            if (self.pom) |pom| {
                if (task_id != 0) {
                    pom.setState(task_id, state);
                }
            }
        }
        
        /// Background HTTP worker function
        fn httpWorker(self: *Self, request_id: RequestId, task_id: TaskId, url: []const u8, method: []const u8) void {
            defer self.base.allocator.free(url);
            defer self.base.allocator.free(method);
            
            // Mark task as running in POM
            self.setPomState(task_id, .running);
            
            var client = std.http.Client{ .allocator = self.base.allocator };
            defer client.deinit();
            
            const uri = std.Uri.parse(url) catch |e| {
                self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "invalid url: {}", .{e}) catch "invalid url");
                self.setPomState(task_id, .failed);
                return;
            };
            
            const http_method: std.http.Method = methodFromString(method);
            var req = std.http.Client.request(&client, http_method, uri, .{}) catch |e| {
                self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "request failed: {}", .{e}) catch "request failed");
                self.setPomState(task_id, .failed);
                return;
            };
            defer req.deinit();
            
            req.sendBodiless() catch |e| {
                self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "send failed: {}", .{e}) catch "send failed");
                self.setPomState(task_id, .failed);
                return;
            };
            
            var empty: [0]u8 = .{};
            var resp = req.receiveHead(&empty) catch |e| {
                self.deliverError(request_id, std.fmt.allocPrint(self.base.allocator, "receive head failed: {}", .{e}) catch "receive head failed");
                self.setPomState(task_id, .failed);
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
                        self.setPomState(task_id, .failed);
                        return;
                    }
                };
                
                if (n == 0 and out.end == 0) continue;
                
                // Allocate owned chunk for delivery
                const chunk = self.base.allocator.alloc(u8, out.end) catch {
                    self.deliverError(request_id, "out of memory");
                    self.setPomState(task_id, .failed);
                    return;
                };
                @memcpy(chunk, buf[0..out.end]);
                self.deliverData(request_id, chunk);
            }
            
            // Signal completion
            self.deliverEnd(request_id);
            self.setPomState(task_id, .completed);
        }
        
        fn methodFromString(method: []const u8) std.http.Method {
            inline for (@typeInfo(std.http.Method).@"enum".fields) |f| {
                if (std.ascii.eqlIgnoreCase(method, f.name)) return @enumFromInt(f.value);
            }
            return .GET;
        }
    };
}