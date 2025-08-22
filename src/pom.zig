const std = @import("std");

/// Process Object Model (POM) - Structured task scopes
/// Like Trio nurseries or Erlang supervision trees

pub const TaskId = u32;

/// Task scope policy - how to handle child failures
pub const ScopePolicy = enum {
    fail_fast,      // If any child fails, cancel all siblings (Trio-style)
    one_for_one,    // Restart failed child, keep siblings (Erlang-style)
    one_for_all,    // If any child fails, restart all children
    ignore,         // Let children fail independently
};

/// Task state
pub const TaskState = enum {
    created,
    running,
    completed,
    failed,
    cancelled,
};

/// Task scope - manages a group of related concurrent work
pub const TaskHeader = struct {
    // Hierarchy (structured scopes)
    parent: TaskId,
    first_child: TaskId,
    next_sibling: TaskId,
    
    // Task identity  
    name_offset: u32,
    name_len: u16,
    
    // Scope management
    state: TaskState,
    policy: ScopePolicy,
    thread_handle: ?std.Thread,     // Background thread doing the work
    child_count: u16,               // Number of active children
    failed_children: u16,           // How many children have failed
    
    created_at: i64,
    updated_at: i64,
};

pub const Pom = struct {
    pub const NullId: TaskId = 0;  // Use 0 as null instead of maxInt to avoid overflow
    
    alloc: std.mem.Allocator,
    tasks: std.AutoHashMap(TaskId, TaskHeader),
    name_arena: std.ArrayList(u8),
    root_id: TaskId = NullId,
    next_id: TaskId = 1,  // Start task IDs from 1
    
    // Supervision tree management
    active_threads: std.ArrayList(std.Thread),
    failed_tasks: std.ArrayList(TaskId),         // Tasks that need supervision action
    completion_queue: std.ArrayList(TaskId),     // Tasks that completed successfully
    
    pub fn init(alloc: std.mem.Allocator) !*Pom {
        const pom = try alloc.create(Pom);
        pom.* = .{
            .alloc = alloc,
            .tasks = std.AutoHashMap(TaskId, TaskHeader).init(alloc),
            .name_arena = .{},
            .active_threads = .{},
            .failed_tasks = .{},
            .completion_queue = .{},
            .root_id = NullId,
            .next_id = 1,
        };
        return pom;
    }
    
    pub fn deinit(self: *Pom) void {
        // Join all active threads before cleanup
        self.joinAllThreads();
        
        self.tasks.deinit();
        self.name_arena.deinit(self.alloc);
        self.active_threads.deinit(self.alloc);
        self.failed_tasks.deinit(self.alloc);
        self.completion_queue.deinit(self.alloc);
        self.alloc.destroy(self);
    }
    
    /// Create a task scope (like Trio nursery or Erlang supervisor)  
    pub fn createScope(self: *Pom, parent: TaskId, name: []const u8, policy: ScopePolicy) !TaskId {
        const id = self.next_id;
        self.next_id += 1;
        const now = std.time.nanoTimestamp();
        
        // Store name in arena
        const name_offset: u32 = @intCast(self.name_arena.items.len);
        try self.name_arena.appendSlice(self.alloc, name);
        
        const header = TaskHeader{
            .parent = parent,
            .first_child = NullId,
            .next_sibling = NullId,
            .name_offset = name_offset,
            .name_len = @intCast(name.len),
            .state = .created,
            .policy = policy,
            .thread_handle = null,
            .child_count = 0,
            .failed_children = 0,
            .created_at = @intCast(now),
            .updated_at = @intCast(now),
        };
        
        try self.tasks.put(id, header);
        
        // Link to parent scope
        if (parent != NullId) {
            self.linkChild(parent, id);
            // Increment parent's child count
            if (self.tasks.getPtr(parent)) |parent_header| {
                parent_header.child_count += 1;
            }
        } else {
            self.root_id = id; // Root supervisor
        }
        
        return id;
    }
    
    
    /// Link child to parent (like DOM appendChild)
    fn linkChild(self: *Pom, parent_id: TaskId, child_id: TaskId) void {
        var parent = self.tasks.getPtr(parent_id) orelse return;
        
        if (parent.first_child == NullId) {
            // First child
            parent.first_child = child_id;
        } else {
            // Find last sibling and append  
            var last_sibling = parent.first_child;
            while (last_sibling != NullId) {
                if (self.tasks.getPtr(last_sibling)) |sibling_header| {
                    if (sibling_header.next_sibling == NullId) break;
                    last_sibling = sibling_header.next_sibling;
                } else break;
            }
            
            if (self.tasks.getPtr(last_sibling)) |last| {
                last.next_sibling = child_id;
            }
        }
    }
    
    /// Get task name (like DOM textContent)
    pub fn getName(self: *Pom, id: TaskId) []const u8 {
        const header = self.tasks.get(id) orelse return "";
        const start = header.name_offset;
        const end = start + header.name_len;
        return self.name_arena.items[start..end];
    }
    
    /// Spawn a background thread for a task (like DOM event handling)
    pub fn spawnThread(self: *Pom, task_id: TaskId, thread_fn: fn(*Pom, TaskId) void) !void {
        if (!self.tasks.contains(task_id)) return error.InvalidTaskId;
        
        // Start the thread
        const thread = try std.Thread.spawn(.{}, thread_fn, .{ self, task_id });
        try self.active_threads.append(self.alloc, thread);
        
        // Update task state
        if (self.tasks.getPtr(task_id)) |header| {
            header.thread_handle = thread;
            header.state = .running;
            header.updated_at = @intCast(std.time.nanoTimestamp());
        }
    }
    
    /// Notify that a child task failed (Erlang-style supervision)
    pub fn childFailed(self: *Pom, child_id: TaskId, error_info: []const u8) !void {
        const child = self.tasks.get(child_id) orelse return;
        if (child.parent == NullId) return; // No supervisor
        
        // Update child state
        self.setState(child_id, .failed);
        
        // Notify parent supervisor
        if (self.tasks.getPtr(child.parent)) |parent| {
            parent.failed_children += 1;
        }
        
        // Add to failed tasks queue for supervision action
        try self.failed_tasks.append(self.alloc, child_id);
        
        _ = error_info; // TODO: store error info
    }
    
    /// Update task state (like DOM property changes)
    pub fn setState(self: *Pom, task_id: TaskId, new_state: TaskState) void {
        if (self.tasks.getPtr(task_id)) |header| {
            header.state = new_state;
            header.updated_at = @intCast(std.time.nanoTimestamp());
        }
    }
    
    /// Get task state
    pub fn getState(self: *Pom, task_id: TaskId) TaskState {
        const header = self.tasks.get(task_id) orelse return .failed;
        return header.state;
    }
    
    /// Join all threads (like DOM cleanup)
    pub fn joinAllThreads(self: *Pom) void {
        for (self.active_threads.items) |thread| {
            thread.join();
        }
        self.active_threads.clearAndFree(self.alloc);
    }
    
    /// Cancel task and all children (like DOM removeChild)
    pub fn cancelTask(self: *Pom, task_id: TaskId) void {
        var visited = std.AutoHashMap(TaskId, void).init(self.alloc);
        defer visited.deinit();
        self.cancelTaskImpl(task_id, &visited);
    }
    
    /// Internal implementation with cycle detection
    fn cancelTaskImpl(self: *Pom, task_id: TaskId, visited: *std.AutoHashMap(TaskId, void)) void {
        // Detect cycles in task hierarchy - this should NEVER happen
        std.debug.assert(!visited.contains(task_id)); // ASSERT NO LOOP
        visited.put(task_id, {}) catch return;
        
        const header = self.tasks.get(task_id) orelse return;
        
        // Cancel children first
        var child = header.first_child;
        while (child != NullId) {
            self.cancelTaskImpl(child, visited);
            // Get next sibling before recursing (in case child gets modified)
            if (self.tasks.get(child)) |child_header| {
                child = child_header.next_sibling;
            } else break;
        }
        
        // Cancel this task
        self.setState(task_id, .cancelled);
        
        // TODO: Actually cancel thread/fiber if needed
    }
    
    /// Walk tree depth-first (like DOM traversal)  
    pub fn walk(self: *Pom, root: TaskId, visitor: fn(TaskId, TaskHeader) void) void {
        const header = self.tasks.get(root) orelse return;
        visitor(root, header);
        
        // Visit children
        var child = header.first_child;
        while (child != NullId) {
            self.walk(child, visitor);
            if (self.tasks.get(child)) |child_header| {
                child = child_header.next_sibling;
            } else break;
        }
    }
    
    /// Process supervision actions (like Erlang supervisor behavior)
    pub fn processSupervision(self: *Pom) !void {
        // Process failed tasks according to their parent's supervision policy
        var i: usize = 0;
        while (i < self.failed_tasks.items.len) {
            const failed_task = self.failed_tasks.items[i];
            const task = self.tasks.get(failed_task) orelse continue;
            
            if (task.parent != NullId) {
                const supervisor = self.tasks.get(task.parent) orelse continue;
                
                switch (supervisor.policy) {
                    .fail_fast => {
                        // Cancel all siblings (Trio-style)
                        self.cancelAllChildren(task.parent);
                    },
                    .one_for_one => {
                        // Just restart this failed task
                        try self.restartTask(failed_task);
                    },
                    .one_for_all => {
                        // Restart all children 
                        try self.restartAllChildren(task.parent);
                    },
                    .ignore => {
                        // Do nothing, let it stay failed
                    },
                }
            }
            
            i += 1;
        }
        
        // Clear processed failures
        self.failed_tasks.clearRetainingCapacity();
    }
    
    fn cancelAllChildren(self: *Pom, supervisor_id: TaskId) void {
        const supervisor = self.tasks.get(supervisor_id) orelse return;
        var child = supervisor.first_child;
        
        while (child != NullId) {
            self.setState(child, .cancelled);
            // TODO: Actually cancel the thread/work
            if (self.tasks.get(child)) |child_header| {
                child = child_header.next_sibling;
            } else break;
        }
    }
    
    fn restartTask(self: *Pom, task_id: TaskId) !void {
        // Reset task state to created (ready for restart)
        self.setState(task_id, .created);
        // TODO: Actually restart the work
    }
    
    fn restartAllChildren(self: *Pom, supervisor_id: TaskId) !void {
        self.cancelAllChildren(supervisor_id);
        
        const supervisor = self.tasks.get(supervisor_id) orelse return;
        var child = supervisor.first_child;
        
        while (child != NullId) {
            try self.restartTask(child);
            if (self.tasks.get(child)) |child_header| {
                child = child_header.next_sibling;
            } else break;
        }
    }
};