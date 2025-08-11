const std = @import("std");
const dom = @import("dom.zig");
const DomNodeId = dom.DomNodeId;
const events = @import("events.zig");

pub const ClockEvent = struct {
    node_id: DomNodeId,
    tick_count: u64,
    timestamp_ms: i64,
};

/// Thread-safe queue for clock events
pub const ClockEventQueue = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    events: std.ArrayList(ClockEvent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ClockEventQueue {
        return .{
            .mutex = .{},
            .cond = .{},
            .events = std.ArrayList(ClockEvent).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClockEventQueue) void {
        self.events.deinit();
    }

    pub fn push(self: *ClockEventQueue, event: ClockEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.events.append(event);
        self.cond.signal();
    }

    pub fn popAll(self: *ClockEventQueue, out: *std.ArrayList(ClockEvent)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        out.clearRetainingCapacity();
        try out.appendSlice(self.events.items);
        self.events.clearRetainingCapacity();
    }

    pub fn waitForEvent(self: *ClockEventQueue, timeout_ms: ?u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.events.items.len > 0) return true;
        
        if (timeout_ms) |ms| {
            const timeout_ns = ms * 1_000_000;
            _ = self.cond.timedWait(&self.mutex, timeout_ns) catch return false;
        } else {
            self.cond.wait(&self.mutex);
        }
        
        return self.events.items.len > 0;
    }
};

/// A clock that runs in its own thread and generates tick events
pub const Clock = struct {
    node_id: DomNodeId,
    interval_ms: u64,
    thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    tick_count: std.atomic.Value(u64),
    event_queue: *ClockEventQueue,
    visual_state: VisualState,
    
    pub const VisualState = struct {
        style: ClockStyle,
        last_update: i64,
    };
    
    pub const ClockStyle = enum {
        hidden,
        progress_bar,
        spinner,
        pulse,
        countdown,
        text,
    };

    pub fn init(node_id: DomNodeId, interval_ms: u64, event_queue: *ClockEventQueue) Clock {
        return .{
            .node_id = node_id,
            .interval_ms = interval_ms,
            .thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .tick_count = std.atomic.Value(u64).init(0),
            .event_queue = event_queue,
            .visual_state = .{
                .style = .hidden,
                .last_update = 0,
            },
        };
    }

    pub fn start(self: *Clock) !void {
        if (self.thread != null) return; // Already running
        
        self.should_stop.store(false, .monotonic);
        self.thread = try std.Thread.spawn(.{}, threadFn, .{self});
    }

    pub fn stop(self: *Clock) void {
        self.should_stop.store(true, .monotonic);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn threadFn(self: *Clock) void {
        const check_interval_ms: u64 = 10; // Check every 10ms for stop signal
        const check_interval_ns = check_interval_ms * 1_000_000;
        
        var elapsed_ms: u64 = 0;
        
        while (!self.should_stop.load(.acquire)) {
            // Sleep in small increments to check for stop signal
            std.time.sleep(check_interval_ns);
            elapsed_ms += check_interval_ms;
            
            if (self.should_stop.load(.acquire)) break;
            
            // Check if it's time to tick
            if (elapsed_ms >= self.interval_ms) {
                elapsed_ms = 0;
                
                const tick = self.tick_count.fetchAdd(1, .monotonic) + 1;
                const event = ClockEvent{
                    .node_id = self.node_id,
                    .tick_count = tick,
                    .timestamp_ms = std.time.milliTimestamp(),
                };
                
                self.event_queue.push(event) catch {
                    // Handle error - maybe log it
                    continue;
                };
            }
        }
    }

    pub fn setStyle(self: *Clock, style: ClockStyle) void {
        self.visual_state.style = style;
    }

    pub fn getTickCount(self: *Clock) u64 {
        return self.tick_count.load(.acquire);
    }
};

/// Registry to manage all active clocks in the system
pub const ClockRegistry = struct {
    clocks: std.AutoHashMap(DomNodeId, *Clock),
    event_queue: ClockEventQueue,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ClockRegistry {
        return .{
            .clocks = std.AutoHashMap(DomNodeId, *Clock).init(allocator),
            .event_queue = ClockEventQueue.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClockRegistry) void {
        var it = self.clocks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.stop();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.clocks.deinit();
        self.event_queue.deinit();
    }

    pub fn createClock(self: *ClockRegistry, node_id: DomNodeId, interval_ms: u64) !*Clock {
        const clock = try self.allocator.create(Clock);
        clock.* = Clock.init(node_id, interval_ms, &self.event_queue);
        try self.clocks.put(node_id, clock);
        return clock;
    }

    pub fn removeClock(self: *ClockRegistry, node_id: DomNodeId) void {
        if (self.clocks.fetchRemove(node_id)) |entry| {
            entry.value.stop();
            self.allocator.destroy(entry.value);
        }
    }

    pub fn getClock(self: *ClockRegistry, node_id: DomNodeId) ?*Clock {
        return self.clocks.get(node_id);
    }

    pub fn processEvents(self: *ClockRegistry, temp_allocator: std.mem.Allocator) ![]ClockEvent {
        var event_list = std.ArrayList(ClockEvent).init(temp_allocator);
        try self.event_queue.popAll(&event_list);
        return event_list.toOwnedSlice();
    }

    pub fn waitForEvents(self: *ClockRegistry, timeout_ms: ?u64) bool {
        return self.event_queue.waitForEvent(timeout_ms);
    }
};