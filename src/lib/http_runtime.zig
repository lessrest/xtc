const std = @import("std");

/// Lightweight HTTP runtime to encapsulate async request state.
/// Parameterized over the waiter type to avoid coupling to VM details.
pub fn Runtime(comptime Waiter: type) type {
    return struct {
        pub const RequestId = u32;

        pub const Event = union(enum) {
            head: struct { id: RequestId, status: u16 },
            data: struct { id: RequestId, chunk: []u8 },
            end: struct { id: RequestId },
            err: struct { id: RequestId, message: []const u8 },
        };

        pub const RequestState = struct {
            id: RequestId,
            pending_chunks: std.ArrayListUnmanaged([]u8) = .{},
            done: bool = false,

            pub fn deinit(self: *RequestState, allocator: std.mem.Allocator) void {
                for (self.pending_chunks.items) |chunk| allocator.free(chunk);
                self.pending_chunks.deinit(allocator);
            }
        };

        const WaiterEntry = struct { fiber: Waiter, deadline_ms: u64 };

        allocator: std.mem.Allocator,

        next_id: RequestId = 1,
        mutex: std.Thread.Mutex = .{},
        events: std.ArrayListUnmanaged(Event) = .{},
        requests: std.AutoHashMapUnmanaged(RequestId, RequestState) = .{},
        head_waiters: std.AutoHashMapUnmanaged(RequestId, WaiterEntry) = .{},
        read_waiters: std.AutoHashMapUnmanaged(RequestId, WaiterEntry) = .{},
        cancelled: std.AutoHashMapUnmanaged(RequestId, void) = .{},

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *@This()) void {
            var it = self.requests.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
            self.requests.deinit(self.allocator);

            // Free any queued event payloads
            var i: usize = 0;
            while (i < self.events.items.len) : (i += 1) {
                switch (self.events.items[i]) {
                    .data => |d| self.allocator.free(d.chunk),
                    .err => |e| self.allocator.free(@constCast(e.message)),
                    else => {},
                }
            }
            self.events.deinit(self.allocator);
            self.head_waiters.deinit(self.allocator);
            self.read_waiters.deinit(self.allocator);
            self.cancelled.deinit(self.allocator);
        }

        /// Reserve an id and record a new request state.
        pub fn newRequest(self: *@This()) !RequestId {
            const id = self.next_id;
            self.next_id +%= 1;
            try self.requests.put(self.allocator, id, .{ .id = id });
            return id;
        }

        pub fn registerHeadWaiter(self: *@This(), id: RequestId, waiter: Waiter, timeout_ms: u64, now_ns: i128) !void {
            const now_ms: u64 = @intCast(@divTrunc(@max(now_ns, @as(i128, 0)), std.time.ns_per_ms));
            const deadline_ms: u64 = now_ms + timeout_ms;
            try self.head_waiters.put(self.allocator, id, .{ .fiber = waiter, .deadline_ms = deadline_ms });
        }

        pub fn registerReadWaiter(self: *@This(), id: RequestId, waiter: Waiter, timeout_ms: u64, now_ns: i128) !void {
            const now_ms: u64 = @intCast(@divTrunc(@max(now_ns, @as(i128, 0)), std.time.ns_per_ms));
            const deadline_ms: u64 = now_ms + timeout_ms;
            try self.read_waiters.put(self.allocator, id, .{ .fiber = waiter, .deadline_ms = deadline_ms });
        }

        pub fn fetchRemoveHeadWaiter(self: *@This(), id: RequestId) ?Waiter {
            if (self.head_waiters.fetchRemove(id)) |e| {
                return e.value.fiber;
            } else {
                return null;
            }
        }

        pub fn fetchRemoveReadWaiter(self: *@This(), id: RequestId) ?Waiter {
            if (self.read_waiters.fetchRemove(id)) |e| {
                return e.value.fiber;
            } else {
                return null;
            }
        }

        pub fn getRequestPtr(self: *@This(), id: RequestId) ?*RequestState {
            return self.requests.getPtr(id);
        }

        pub fn removeRequest(self: *@This(), id: RequestId) void {
            _ = self.requests.fetchRemove(id);
        }

        pub fn markDone(self: *@This(), id: RequestId) void {
            if (self.requests.getPtr(id)) |rs| rs.done = true;
        }

        pub fn bufferChunk(self: *@This(), id: RequestId, chunk: []u8) void {
            if (self.requests.getPtr(id)) |rs| {
                rs.pending_chunks.append(self.allocator, chunk) catch {
                    self.allocator.free(chunk);
                };
            } else {
                self.allocator.free(chunk);
            }
        }

        /// Atomically obtain the current event slice and clear the queue.
        /// The returned slice is valid until more events are appended.
        pub fn popEvents(self: *@This()) []Event {
            self.mutex.lock();
            defer self.mutex.unlock();
            const n = self.events.items.len;
            const slice = self.events.items[0..n];
            self.events.items.len = 0;
            return slice;
        }

        /// Post helpers used from worker threads.
        pub fn postHead(self: *@This(), rid: RequestId, status: u16) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.events.append(self.allocator, .{ .head = .{ .id = rid, .status = status } }) catch {};
        }

        pub fn postData(self: *@This(), rid: RequestId, chunk: []u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.events.append(self.allocator, .{ .data = .{ .id = rid, .chunk = chunk } }) catch null == null) {
                self.allocator.free(chunk);
            }
        }

        pub fn postEnd(self: *@This(), rid: RequestId) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.events.append(self.allocator, .{ .end = .{ .id = rid } }) catch {};
        }

        pub fn postError(self: *@This(), rid: RequestId, message: []const u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.events.append(self.allocator, .{ .err = .{ .id = rid, .message = message } }) catch null == null) {
                if (message.len > 0) self.allocator.free(@constCast(message));
            }
        }

        pub fn cancel(self: *@This(), rid: RequestId) void {
            // Mark canceled and post error event
            _ = self.cancelled.put(self.allocator, rid, {}) catch {};
            const msg = std.fmt.allocPrint(self.allocator, "canceled", .{}) catch &.{};
            self.postError(rid, msg);
            // Also mark done to help pruning
            if (self.requests.getPtr(rid)) |rs| rs.done = true;
        }

        pub fn isCanceled(self: *@This(), rid: RequestId) bool {
            return self.cancelled.contains(rid);
        }

        /// Background worker to perform HTTP request and stream events.
        pub fn spawnRequest(self: *@This(), id: RequestId, url: []const u8, method: []const u8) !void {
            const url_copy = try self.allocator.dupe(u8, url);
            errdefer self.allocator.free(url_copy);
            const method_copy = try self.allocator.dupe(u8, method);
            errdefer self.allocator.free(method_copy);
            _ = try std.Thread.spawn(.{}, runRequest, .{ self, id, url_copy, method_copy });
        }

        fn runRequest(self: *@This(), req_id: RequestId, url: []const u8, method: []const u8) void {
            defer self.allocator.free(url);
            defer self.allocator.free(method);

            var client = std.http.Client{ .allocator = self.allocator };
            defer client.deinit();

            const uri = std.Uri.parse(url) catch |e| return self.postError(req_id, dupFmt(self.allocator, "invalid url: {s}", .{@errorName(e)}));
            const http_method: std.http.Method = methodFromString(method);
            var req = std.http.Client.request(&client, http_method, uri, .{}) catch |e| return self.postError(req_id, dupFmt(self.allocator, "request: {s}", .{@errorName(e)}));
            defer req.deinit();
            req.sendBodiless() catch |e| return self.postError(req_id, dupFmt(self.allocator, "send: {s}", .{@errorName(e)}));
            var empty: [0]u8 = .{};
            var resp = req.receiveHead(&empty) catch |e| return self.postError(req_id, dupFmt(self.allocator, "head: {s}", .{@errorName(e)}));
            self.postHead(req_id, @intFromEnum(resp.head.status));

            var buf: [4096]u8 = undefined;
            var out: std.Io.Writer = .fixed(buf[0..]);
            const reader = resp.reader(&.{});
            while (true) {
                if (self.isCanceled(req_id)) break;
                out.end = 0;
                const n = reader.stream(&out, std.Io.Limit.limited(buf.len)) catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return self.postError(req_id, dupFmt(self.allocator, "read: {s}", .{@errorName(e)})),
                };
                if (n == 0 and out.end == 0) continue;
                const chunk = self.allocator.alloc(u8, out.end) catch break;
                @memcpy(chunk, buf[0..out.end]);
                self.postData(req_id, chunk);
            }
            self.postEnd(req_id);
        }

        fn methodFromString(method: []const u8) std.http.Method {
            inline for (@typeInfo(std.http.Method).@"enum".fields) |f| {
                if (std.ascii.eqlIgnoreCase(method, f.name)) return @enumFromInt(f.value);
            }
            return .GET;
        }

        fn dupFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []u8 {
            return std.fmt.allocPrint(allocator, fmt, args) catch return &.{};
        }

        // Activity helpers
        pub fn hasRequests(self: *@This()) bool { return self.requests.count() > 0; }
        pub fn hasHeadWaiters(self: *@This()) bool { return self.head_waiters.count() > 0; }
        pub fn hasReadWaiters(self: *@This()) bool { return self.read_waiters.count() > 0; }
    };
}
