const std = @import("std");

/// StreamingRequestTask provides a clean abstraction for managing background work
/// that delivers sequential payloads to waiting fibers.
///
/// The pattern: Fiber makes request → Background task produces stream of payloads → 
/// Fiber receives payloads one by one via suspension/resumption.
pub fn StreamingRequestTask(comptime Payload: type, comptime Fiber: type) type {
    return struct {
        const Self = @This();
        
        pub const RequestId = u32;
        
        /// Represents the current state of a streaming request
        pub const RequestState = struct {
            id: RequestId,
            completed: bool = false,
            failed: bool = false,
            error_message: ?[]const u8 = null,
            
            pub fn deinit(self: *RequestState, allocator: std.mem.Allocator) void {
                if (self.error_message) |msg| {
                    allocator.free(msg);
                }
            }
        };
        
        /// A fiber waiting for the next payload on a request
        const Waiter = struct {
            fiber: Fiber,
            timeout_deadline_ms: u64,
        };
        
        /// Delivered payload with metadata
        pub const Delivery = struct {
            request_id: RequestId,
            payload: Payload,
        };
        
        /// Completion notification
        pub const Completion = struct {
            request_id: RequestId,
            success: bool,
            error_message: ?[]const u8 = null,
        };
        
        allocator: std.mem.Allocator,
        next_request_id: RequestId = 1,
        
        // Core state
        requests: std.AutoHashMapUnmanaged(RequestId, RequestState) = .{},
        waiters: std.AutoHashMapUnmanaged(RequestId, Waiter) = .{},
        
        // Thread-safe queues for background → main thread communication
        delivery_mutex: std.Thread.Mutex = .{},
        pending_deliveries: std.ArrayListUnmanaged(Delivery) = .{},
        pending_completions: std.ArrayListUnmanaged(Completion) = .{},
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        
        pub fn deinit(self: *Self) void {
            // Clean up request states
            var req_it = self.requests.iterator();
            while (req_it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.requests.deinit(self.allocator);
            self.waiters.deinit(self.allocator);
            
            // Clean up queued deliveries/completions
            self.delivery_mutex.lock();
            defer self.delivery_mutex.unlock();
            
            for (self.pending_deliveries.items) |delivery| {
                // Let payload clean itself up if it has a deinit
                _ = delivery;
            }
            self.pending_deliveries.deinit(self.allocator);
            
            for (self.pending_completions.items) |completion| {
                if (completion.error_message) |msg| {
                    self.allocator.free(msg);
                }
            }
            self.pending_completions.deinit(self.allocator);
        }
        
        /// Start a new streaming request. Returns the request ID.
        pub fn submit(self: *Self) !RequestId {
            const id = self.next_request_id;
            self.next_request_id +%= 1;
            
            try self.requests.put(self.allocator, id, .{ .id = id });
            return id;
        }
        
        /// Register a fiber to wait for the next payload on this request.
        /// Only one fiber can wait per request at a time.
        pub fn await(self: *Self, request_id: RequestId, fiber: Fiber, timeout_ms: u64) !void {
            const now_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
            const deadline_ms = now_ms + timeout_ms;
            
            try self.waiters.put(self.allocator, request_id, .{
                .fiber = fiber,
                .timeout_deadline_ms = deadline_ms,
            });
        }
        
        /// Remove the waiter for this request and return it if present.
        pub fn removeWaiter(self: *Self, request_id: RequestId) ?Fiber {
            if (self.waiters.fetchRemove(request_id)) |entry| {
                return entry.value.fiber;
            }
            return null;
        }
        
        /// Cancel a request, removing all state and notifying waiter.
        pub fn cancel(self: *Self, request_id: RequestId) void {
            // Remove from active requests
            if (self.requests.fetchRemove(request_id)) |entry| {
                var state = entry.value;
                state.deinit(self.allocator);
            }
            
            // Remove any waiting fiber
            _ = self.removeWaiter(request_id);
            
            // Post cancellation error
            self.postCompletion(request_id, false, "cancelled");
        }
        
        /// Check if a request exists and is still active.
        pub fn isActive(self: *Self, request_id: RequestId) bool {
            if (self.requests.get(request_id)) |state| {
                return !state.completed and !state.failed;
            }
            return false;
        }
        
        /// Background threads call this to deliver payloads.
        /// Thread-safe.
        pub fn deliver(self: *Self, request_id: RequestId, payload: Payload) void {
            self.delivery_mutex.lock();
            defer self.delivery_mutex.unlock();
            
            _ = self.pending_deliveries.append(self.allocator, .{
                .request_id = request_id,
                .payload = payload,
            }) catch {}; // Drop on allocation failure
        }
        
        /// Background threads call this to signal completion.
        /// Thread-safe.
        pub fn complete(self: *Self, request_id: RequestId) void {
            self.postCompletion(request_id, true, null);
        }
        
        /// Background threads call this to signal failure.
        /// Thread-safe. Error message will be owned by the task.
        pub fn fail(self: *Self, request_id: RequestId, error_message: []const u8) void {
            const owned_msg = self.allocator.dupe(u8, error_message) catch "";
            self.postCompletion(request_id, false, owned_msg);
        }
        
        fn postCompletion(self: *Self, request_id: RequestId, success: bool, error_message: ?[]const u8) void {
            self.delivery_mutex.lock();
            defer self.delivery_mutex.unlock();
            
            _ = self.pending_completions.append(self.allocator, .{
                .request_id = request_id,
                .success = success,
                .error_message = error_message,
            }) catch {}; // Drop on allocation failure
        }
        
        /// Process all pending deliveries and completions.
        /// Returns slices that are valid until next call to this method.
        /// Main thread should call this regularly.
        pub fn processEvents(self: *Self) struct {
            deliveries: []Delivery,
            completions: []Completion,
        } {
            self.delivery_mutex.lock();
            defer self.delivery_mutex.unlock();
            
            const deliveries = self.pending_deliveries.items;
            const completions = self.pending_completions.items;
            
            // Clear the queues but keep capacity
            self.pending_deliveries.items.len = 0;
            self.pending_completions.items.len = 0;
            
            return .{
                .deliveries = deliveries,
                .completions = completions,
            };
        }
        
        /// Check for timed out waiters. Returns slice of fibers that timed out.
        /// Caller should resume these fibers with timeout/error.
        pub fn checkTimeouts(self: *Self, allocator: std.mem.Allocator) ![]Fiber {
            const now_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
            var timed_out: std.ArrayList(Fiber) = .{};
            
            var waiter_it = self.waiters.iterator();
            var to_remove: std.ArrayList(RequestId) = .{};
            defer to_remove.deinit(allocator);
            
            while (waiter_it.next()) |entry| {
                if (now_ms >= entry.value_ptr.timeout_deadline_ms) {
                    try timed_out.append(allocator, entry.value_ptr.fiber);
                    try to_remove.append(allocator, entry.key_ptr.*);
                }
            }
            
            // Remove timed out waiters
            for (to_remove.items) |request_id| {
                _ = self.waiters.remove(request_id);
            }
            
            return timed_out.toOwnedSlice(allocator);
        }
    };
}