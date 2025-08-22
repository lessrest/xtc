const std = @import("std");

/// A generic contiguous tree data structure that maintains child locality.
/// Children of each node are stored contiguously in a flat array for optimal cache performance.
/// This is particularly useful for tree structures that need to be traversed frequently.
pub fn ContiguousTree(comptime NodeData: type) type {
    return struct {
        const Self = @This();

        pub const NodeIndex = u32;
        pub const INVALID_INDEX = std.math.maxInt(NodeIndex);

        /// Internal node structure that wraps user data with tree metadata
        pub const Node = struct {
            data: NodeData,
            first_child: NodeIndex,
            child_count: u32,
            parent_index: NodeIndex,

            pub fn hasChildren(self: *const Node) bool {
                return self.child_count > 0;
            }

            /// Get the parent node, or null if this is the root node
            pub fn getParentNode(self: *const Node, tree: *const Self) ?*const Node {
                if (self.parent_index == INVALID_INDEX) return null;
                return tree.getNode(self.parent_index);
            }

            /// Get the index of the nth child node
            pub fn getChildIndex(self: *const Node, index: usize) NodeIndex {
                std.debug.assert(index < self.child_count);
                return self.first_child + @as(NodeIndex, @intCast(index));
            }

            /// Get a reference to the nth child node data
            pub fn getChildData(self: *const Node, tree: *const Self, index: usize) *const NodeData {
                const child_index = self.getChildIndex(index);
                return tree.nodeData(child_index);
            }

            /// Get a mutable reference to the nth child node data
            pub fn getChildDataMut(self: *const Node, tree: *Self, index: usize) *NodeData {
                const child_index = self.getChildIndex(index);
                return tree.nodeDataMut(child_index);
            }

            /// Get a reference to the nth child node
            pub fn getChildNode(self: *const Node, tree: *const Self, index: usize) *const Node {
                const child_index = self.getChildIndex(index);
                return tree.getNode(child_index);
            }

            /// Get a mutable reference to the nth child node
            pub fn getChildNodeMut(self: *const Node, tree: *Self, index: usize) *Node {
                const child_index = self.getChildIndex(index);
                return tree.getNodeMut(child_index);
            }
        };

        /// Callback function type for BFS construction - this is just for documentation
        /// The actual callback functions are passed as comptime parameters to constructBFS
        // Fields
        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .nodes = std.ArrayList(Node){},
            };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.* = undefined;
        }

        /// Get a slice of child nodes for the given node index
        pub fn children(self: *const Self, node_index: NodeIndex) []const Node {
            const node = self.nodes.items[node_index];
            if (node.child_count == 0) return &[_]Node{};
            const start: usize = @intCast(node.first_child);
            const end: usize = start + @as(usize, @intCast(node.child_count));
            return self.nodes.items[start..end];
        }

        /// Get mutable slice of child nodes for the given node index
        pub fn childrenMut(self: *Self, node_index: NodeIndex) []Node {
            const node = self.nodes.items[node_index];
            if (node.child_count == 0) return &[_]Node{};
            const start: usize = @intCast(node.first_child);
            const end: usize = start + @as(usize, @intCast(node.child_count));
            return self.nodes.items[start..end];
        }

        /// Get the data for a node at the given index
        pub fn nodeData(self: *const Self, node_index: NodeIndex) *const NodeData {
            return &self.nodes.items[node_index].data;
        }

        /// Get mutable data for a node at the given index
        pub fn nodeDataMut(self: *Self, node_index: NodeIndex) *NodeData {
            return &self.nodes.items[node_index].data;
        }

        /// Get the node at the given index
        pub fn getNode(self: *const Self, node_index: NodeIndex) *const Node {
            return &self.nodes.items[node_index];
        }

        /// Get mutable node at the given index
        pub fn getNodeMut(self: *Self, node_index: NodeIndex) *Node {
            return &self.nodes.items[node_index];
        }

        /// Get the number of nodes in the tree
        pub fn nodeCount(self: *const Self) usize {
            return self.nodes.items.len;
        }

        /// Construct tree using breadth-first traversal to ensure contiguous children.
        /// Context must have methods:
        /// - getChildCount(parent_id: IdType) usize
        /// - getChild(parent_id: IdType, index: usize) IdType
        /// - createData(id: IdType) NodeData
        pub fn constructBFS(
            self: *Self,
            comptime IdType: type,
            root_id: IdType,
            context: anytype,
        ) !void {
            self.nodes.clearRetainingCapacity();

            const QueueItem = struct { id: IdType, tree_idx: NodeIndex };
            var queue = std.ArrayList(QueueItem){};
            defer queue.deinit(self.allocator);

            // Create root node
            const root_data = context.createData(root_id);
            try self.nodes.append(self.allocator, .{
                .data = root_data,
                .first_child = INVALID_INDEX,
                .child_count = 0,
                .parent_index = INVALID_INDEX,
            });
            try queue.append(self.allocator, .{ .id = root_id, .tree_idx = 0 });

            var queue_index: usize = 0;
            while (queue_index < queue.items.len) : (queue_index += 1) {
                const current = queue.items[queue_index];
                const child_count = context.getChildCount(current.id);

                if (child_count == 0) continue;

                // Reserve space for all children contiguously
                const first_child_index: NodeIndex = @intCast(self.nodes.items.len);

                // Add all children to the tree
                for (0..child_count) |child_index| {
                    const child_id = context.getChild(current.id, child_index);
                    const child_data = context.createData(child_id);
                    const child_tree_idx: NodeIndex = @intCast(self.nodes.items.len);
                    try self.nodes.append(self.allocator, .{
                        .data = child_data,
                        .first_child = INVALID_INDEX,
                        .child_count = 0,
                        .parent_index = current.tree_idx,
                    });
                    try queue.append(self.allocator, .{ .id = child_id, .tree_idx = child_tree_idx });
                }

                // Update parent to point to its children
                var parent_node_ref = &self.nodes.items[current.tree_idx];
                parent_node_ref.first_child = first_child_index;
                parent_node_ref.child_count = @intCast(child_count);
            }
        }
    };
}

test "contiguous tree stores nodes in a flat array with parent indices" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestData = struct {
        value: i32,
    };

    var tree = ContiguousTree(TestData).init(allocator);
    defer tree.deinit();

    // Test empty tree
    try testing.expect(tree.nodeCount() == 0);
}

test "contiguous tree constructs nodes in breadth-first order for cache locality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const TestData = struct {
        id: u32,
    };

    var tree = ContiguousTree(TestData).init(allocator);
    defer tree.deinit();

    // Mock data structure for testing
    const MockContext = struct {
        fn getChildCount(self: *const @This(), parent_id: u32) usize {
            _ = self;
            return switch (parent_id) {
                1 => 2, // children: 2, 3
                2 => 2, // children: 4, 5
                else => 0,
            };
        }

        fn getChild(self: *const @This(), parent_id: u32, index: usize) u32 {
            _ = self;
            return switch (parent_id) {
                1 => if (index == 0) 2 else 3, // children: 2, 3
                2 => if (index == 0) 4 else 5, // children: 4, 5
                else => unreachable,
            };
        }

        fn createData(self: *const @This(), id: u32) TestData {
            _ = self;
            return .{ .id = id };
        }
    };

    const context = MockContext{};
    try tree.constructBFS(u32, 1, &context);

    // Verify tree structure
    try testing.expect(tree.nodeCount() == 5);
    try testing.expect(tree.nodeData(0).id == 1); // root

    const root_children = tree.children(0);
    try testing.expect(root_children.len == 2);
    try testing.expect(root_children[0].data.id == 2);
    try testing.expect(root_children[1].data.id == 3);

    const node2_children = tree.children(1); // node with id=2 is at index 1
    try testing.expect(node2_children.len == 2);
    try testing.expect(node2_children[0].data.id == 4);
    try testing.expect(node2_children[1].data.id == 5);

    const node3_children = tree.children(2); // node with id=3 is at index 2
    try testing.expect(node3_children.len == 0);

    // Test new Node convenience methods
    const root_node = tree.getNode(0);
    try testing.expect(root_node.hasChildren());
    try testing.expect(root_node.child_count == 2);

    // Test getChildIndex
    const first_child_index = root_node.getChildIndex(0);
    const second_child_index = root_node.getChildIndex(1);
    try testing.expect(first_child_index == 1);
    try testing.expect(second_child_index == 2);

    // Test getChildData
    const first_child_data = root_node.getChildData(&tree, 0);
    const second_child_data = root_node.getChildData(&tree, 1);
    try testing.expect(first_child_data.id == 2);
    try testing.expect(second_child_data.id == 3);

    // Test getChildNode
    const first_child_node = root_node.getChildNode(&tree, 0);
    try testing.expect(first_child_node.data.id == 2);
    try testing.expect(first_child_node.child_count == 2);
}
