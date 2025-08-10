const std = @import("std");
const Dom = @import("dom.zig").Dom;
const DomNodeId = @import("dom.zig").DomNodeId;
const Layout = @import("lib.zig").Layout;
const DisplayWidth = @import("lib.zig").DisplayWidth;
const measure = @import("measure.zig");
const StyleAlign = @import("style.zig").StyleAlign;
const StyleFlexDir = @import("style.zig").StyleFlexDir;
const StyleJustify = @import("style.zig").StyleJustify;
const StyleOverflow = @import("style.zig").StyleOverflow;
const StyleRow = @import("style.zig").StyleRow;
const ContiguousTree = @import("tree.zig").ContiguousTree;
const BoxSize = [2]usize;

pub const Rect = struct { x: usize, y: usize, w: usize, h: usize };

// --- Structured, call-stack-based tracing for layout debugging ---
var g_layout_trace_enabled: bool = true;
var g_trace_depth: usize = 0;
pub fn setLayoutTraceEnabled(on: bool) void {
    g_layout_trace_enabled = on;
}
fn traceIndent() []const u8 {
    const spaces = "                                                                                ";
    const n = if (g_trace_depth * 2 > spaces.len) spaces.len else g_trace_depth * 2;
    return spaces[0..n];
}
fn tracePush() void {
    if (!g_layout_trace_enabled) return;
    g_trace_depth += 1;
}
fn tracePop() void {
    if (!g_layout_trace_enabled) return;
    if (g_trace_depth > 0) g_trace_depth -= 1;
}
fn tracef(comptime fmt: []const u8, args: anytype) void {
    if (!g_layout_trace_enabled) return;
    std.log.info("{s}" ++ fmt ++ "\n", .{traceIndent()} ++ args);
}
fn tracePhase(comptime name: []const u8) void {
    if (!g_layout_trace_enabled) return;
    std.log.info("{s}[phase] {s}\n", .{ traceIndent(), name });
    g_trace_depth += 1;
}

/// Data stored in each box node (layout information)
pub const BoxData = struct {
    dom_id: DomNodeId,
    rect: Rect,
    // Scroll state for containers with overflow: scroll
    scroll_offset_y: usize = 0,
    content_size: BoxSize = .{ 0, 0 }, // Full content size (may exceed rect size for scroll containers)
};

/// Specialized tree for layout boxes
pub const BoxTree = ContiguousTree(BoxData);

/// Compatibility alias for the old BoxHeader (now includes tree metadata)
pub const BoxHeader = BoxTree.Node;

// --- Flexbox layout data structures ---
const FlexItem = struct {
    dom_id: DomNodeId,
    original_index: usize,
    intrinsic_size: BoxSize,
    flex_order: i16,
    cross_axis_alignment: ?StyleAlign,
    margin_main_axis_start: usize,
    margin_main_axis_end: usize,
    flex_grow_factor: usize,
    trailing_space: i32, // Space after this item (for justify-content)
    extra_main_size: i32, // Extra size from flex-grow distribution
};

const FlexItemMainSizeInfo = struct {
    content_extent: i32,
    total_grow_factor: usize,
};

pub fn computeInnerContentRect(container_style: StyleRow, container_rect: Rect) Rect {
    const border_width: usize = @as(usize, @intCast(container_style.border.width));
    const padding_left: usize = @as(usize, @intCast(container_style.padding.l)) + border_width;
    const padding_right: usize = @as(usize, @intCast(container_style.padding.r)) + border_width;
    const padding_top: usize = @as(usize, @intCast(container_style.padding.t)) + border_width;
    const padding_bottom: usize = @as(usize, @intCast(container_style.padding.b)) + border_width;

    var content_rect = container_rect;
    content_rect.x = container_rect.x + @min(container_rect.w, padding_left);
    content_rect.y = container_rect.y + @min(container_rect.h, padding_top);
    content_rect.w = if (container_rect.w > padding_left + padding_right) container_rect.w - (padding_left + padding_right) else 0;
    content_rect.h = if (container_rect.h > padding_top + padding_bottom) container_rect.h - (padding_top + padding_bottom) else 0;
    return content_rect;
}

/// Computes intrinsic sizes for all flex items in the container.
/// This is the first phase of CSS flexbox layout where we determine
/// the natural size of each flex item before any flex adjustments.
fn computeIntrinsicSizesForFlexItems(
    allocator: std.mem.Allocator,
    box_tree: *BoxTree,
    dom: *const Dom,
    container_node: *const BoxTree.Node,
    content_rect: Rect,
    display_width: *DisplayWidth,
    flex_container_style: StyleRow,
) ![]FlexItem {
    tracePhase("intrinsic-sizing");
    defer tracePop();

    const flex_item_count = container_node.child_count;
    var flex_items = try allocator.alloc(FlexItem, flex_item_count);

    for (0..flex_item_count) |item_index| {
        const flex_item_box = container_node.getChildNode(box_tree, item_index);
        const item_dom_id = flex_item_box.data.dom_id;
        const item_style = dom.getNodeStyle(item_dom_id);

        // For scroll containers, give unlimited height constraint to children
        const constraint_h = if (flex_container_style.overflow_y == .scroll) 
            std.math.maxInt(usize) 
        else 
            content_rect.h;
        
        var intrinsic_size = measure.intrinsicSize(dom, item_dom_id, content_rect.w, constraint_h, display_width);
        
        // Log text sizing details for text nodes
        if (dom.getNodeKind(item_dom_id) == .text) {
            const text_slice = dom.getTextSlice(item_dom_id);
            const display_width_cols = display_width.strWidth(text_slice);
            var id_buf: [32]u8 = undefined;
            const debug_id = dom.getDebugIdOrDefault(item_dom_id, &id_buf);
            tracef("text-sizing {s}: text=\"{s}\" display_width={d} max_w={d} max_h={d} -> size=({d}x{d})", .{
                debug_id, text_slice, display_width_cols, content_rect.w, content_rect.h, intrinsic_size[0], intrinsic_size[1]
            });
        }
        
        // Override with explicit width/height if specified
        if (item_style.width != 0) intrinsic_size[0] = item_style.width;
        if (item_style.height != 0) intrinsic_size[1] = item_style.height;

        const main_axis_margin_start: usize = if (flex_container_style.flex_dir == .row)
            @as(usize, @intCast(item_style.margin.l))
        else
            @as(usize, @intCast(item_style.margin.t));
        const main_axis_margin_end: usize = if (flex_container_style.flex_dir == .row)
            @as(usize, @intCast(item_style.margin.r))
        else
            @as(usize, @intCast(item_style.margin.b));

        const natural_width = intrinsic_size[0];
        const natural_height = intrinsic_size[1];

        flex_items[item_index] = .{
            .dom_id = item_dom_id,
            .original_index = item_index,
            .intrinsic_size = intrinsic_size,
            .flex_order = item_style.order,
            .cross_axis_alignment = if (item_style.align_self == .start) flex_container_style.align_items else item_style.align_self,
            .margin_main_axis_start = main_axis_margin_start,
            .margin_main_axis_end = main_axis_margin_end,
            .flex_grow_factor = item_style.flex.flexGrowFactor,
            .trailing_space = 0, // Will be set later during space distribution
            .extra_main_size = 0, // Will be set later during flex-grow distribution
        };

        // Trace the sizing decisions
        if (g_layout_trace_enabled) {
            var id_buf: [32]u8 = undefined;
            const debug_id = dom.getDebugIdOrDefault(item_dom_id, &id_buf);
            if (item_style.width != 0 or item_style.height != 0) {
                tracef("flex-item[{d}] {s}: natural=({d}x{d}) overridden=({d}x{d}) by width_cells={d} height_cells={d}", .{
                    item_index, debug_id, natural_width, natural_height, intrinsic_size[0], intrinsic_size[1], item_style.width, item_style.height,
                });
            } else {
                tracef("flex-item[{d}] {s}: natural=({d}x{d})", .{ item_index, debug_id, intrinsic_size[0], intrinsic_size[1] });
            }
            tracef("flex-item[{d}] {s}: order={d} grow={d} align_self={?} main_margins start={d} end={d}", .{
                item_index, debug_id, item_style.order, item_style.flex.flexGrowFactor, item_style.align_self, main_axis_margin_start, main_axis_margin_end,
            });
        }
    }
    return flex_items;
}

/// Resolves flex item order by stable-sorting items according to their order property.
/// This implements the CSS flexbox order resolution phase where items are reordered
/// according to their flex order value while preserving document order for equal values.
fn resolveFlexItemOrder(flex_items: []FlexItem) void {
    tracePhase("order-resolution");
    defer tracePop();

    const item_count = flex_items.len;

    // Stable insertion sort based on flex order, preserving document order for equal values
    for (1..item_count) |current_index| {
        var insert_position = current_index;
        while (insert_position > 0) {
            const previous_item = flex_items[insert_position - 1];
            const current_item = flex_items[insert_position];

            const should_swap = previous_item.flex_order > current_item.flex_order or
                (previous_item.flex_order == current_item.flex_order and previous_item.original_index > current_item.original_index);

            if (should_swap) {
                const temp = flex_items[insert_position - 1];
                flex_items[insert_position - 1] = flex_items[insert_position];
                flex_items[insert_position] = temp;
                insert_position -= 1;
            } else {
                break;
            }
        }
    }
}

/// Resolves main axis sizes for flex items by computing natural content extent
/// and total flex-grow factor. This is part of the CSS flexbox main size resolution phase.
fn resolveFlexItemMainSizes(flex_items: []const FlexItem, flex_container_style: StyleRow) FlexItemMainSizeInfo {
    tracePhase("main-size-resolution");
    defer tracePop();

    var total_content_extent: i32 = 0;
    var total_grow_factor: usize = 0;

    for (flex_items) |flex_item| {
        const main_axis_size = if (flex_container_style.flex_dir == .row)
            flex_item.intrinsic_size[0]
        else
            flex_item.intrinsic_size[1];

        const item_total_main_size = main_axis_size + flex_item.margin_main_axis_start + flex_item.margin_main_axis_end;
        total_content_extent += @as(i32, @intCast(item_total_main_size));
        total_grow_factor += flex_item.flex_grow_factor;
    }

    return FlexItemMainSizeInfo{
        .content_extent = total_content_extent,
        .total_grow_factor = total_grow_factor,
    };
}

/// Distributes extra space among flex items based on their flex-grow factors.
/// This implements the CSS flexbox flex-grow distribution algorithm.
/// Sets the extra_main_size field directly on each flex item (no allocation needed).
fn distributeFlexGrow(
    available_space: i32,
    total_grow_factor: usize,
    flex_items: []FlexItem,
) void {
    tracePhase("flex-grow-distribution");
    defer tracePop();

    // If no space to distribute or no growing items, leave all extra sizes at 0
    if (!(available_space > 0 and total_grow_factor > 0)) {
        for (flex_items) |*flex_item| {
            flex_item.extra_main_size = 0;
        }
        return;
    }

    // Distribute proportional shares based on flex-grow factors
    var remaining_space = available_space;
    for (flex_items) |*flex_item| {
        const item_grow_factor = @as(i32, @intCast(flex_item.flex_grow_factor));
        const proportional_share = @divTrunc(available_space * item_grow_factor, @as(i32, @intCast(total_grow_factor)));
        flex_item.extra_main_size = proportional_share;
        remaining_space -= proportional_share;
    }

    // Distribute any remaining pixels one by one to items with grow factor > 0
    var distribution_index: usize = 0;
    while (remaining_space > 0) {
        if (distribution_index >= flex_items.len) {
            distribution_index = 0;
        }

        if (flex_items[distribution_index].flex_grow_factor > 0) {
            flex_items[distribution_index].extra_main_size += 1;
            remaining_space -= 1;
        }

        distribution_index += 1;
    }
}

const FlexItemPosition = struct {
    final_rect: Rect,
    main_axis_advance: usize,
};

/// Computes the cross-axis size and position for a flex item based on its alignment.
fn computeCrossAxisAlignment(
    content_rect: Rect,
    flex_direction: StyleFlexDir,
    cross_axis_alignment: StyleAlign,
    natural_size: BoxSize,
) struct { cross_position: usize, cross_size: usize } {
    if (flex_direction == .row) {
        // Cross-axis is vertical (height)
        const available_height = content_rect.h;
        const natural_height = natural_size[1];

        switch (cross_axis_alignment) {
            .start => return .{ .cross_position = content_rect.y, .cross_size = natural_height },
            .center => {
                const constrained_height = @min(natural_height, available_height);
                const center_offset = (available_height - constrained_height) / 2;
                return .{ .cross_position = content_rect.y + center_offset, .cross_size = constrained_height };
            },
            .end => {
                const constrained_height = @min(natural_height, available_height);
                const end_offset = available_height - constrained_height;
                return .{ .cross_position = content_rect.y + end_offset, .cross_size = constrained_height };
            },
            .stretch => return .{ .cross_position = content_rect.y, .cross_size = available_height },
            .baseline => return .{ .cross_position = content_rect.y, .cross_size = natural_height },
        }
    } else {
        // Cross-axis is horizontal (width)
        const available_width = content_rect.w;
        const natural_width = natural_size[0];

        switch (cross_axis_alignment) {
            .start => return .{ .cross_position = content_rect.x, .cross_size = natural_width },
            .center => {
                const constrained_width = @min(natural_width, available_width);
                const center_offset = (available_width - constrained_width) / 2;
                return .{ .cross_position = content_rect.x + center_offset, .cross_size = constrained_width };
            },
            .end => {
                const constrained_width = @min(natural_width, available_width);
                const end_offset = available_width - constrained_width;
                return .{ .cross_position = content_rect.x + end_offset, .cross_size = constrained_width };
            },
            .stretch => return .{ .cross_position = content_rect.x, .cross_size = available_width },
            .baseline => return .{ .cross_position = content_rect.x, .cross_size = natural_width },
        }
    }
}

/// Aligns a flex item on both main and cross axes and computes its final rect.
/// This implements CSS flexbox alignment including align-items and justify-content positioning.
fn alignFlexItemOnBothAxes(
    content_rect: Rect,
    flex_container_style: StyleRow,
    main_axis_cursor: i32,
    flex_item: FlexItem,
) FlexItemPosition {
    tracePhase("cross-axis-alignment");
    defer tracePop();

    // Start with intrinsic size
    var item_width = flex_item.intrinsic_size[0];
    var item_height = flex_item.intrinsic_size[1];

    // Apply any extra space from flex-grow
    const extra_size = @max(0, flex_item.extra_main_size);
    if (flex_container_style.flex_dir == .row) {
        item_width += @as(usize, @intCast(extra_size));
    } else {
        item_height += @as(usize, @intCast(extra_size));
    }

    // Compute main axis position and cross axis alignment
    var item_x: usize = undefined;
    var item_y: usize = undefined;

    if (flex_container_style.flex_dir == .row) {
        // Main axis is horizontal
        item_x = content_rect.x + @as(usize, @intCast(main_axis_cursor)) + flex_item.margin_main_axis_start;

        const cross_alignment = flex_item.cross_axis_alignment orelse .stretch;
        const cross_result = computeCrossAxisAlignment(
            content_rect,
            flex_container_style.flex_dir,
            cross_alignment,
            [2]usize{ item_width, item_height },
        );

        item_y = cross_result.cross_position;
        item_height = cross_result.cross_size;

        tracef("row flex-item: main_pos={d} cross_align={s} -> height={d}", .{ item_x, @tagName(cross_alignment), item_height });
    } else {
        // Main axis is vertical
        item_y = content_rect.y + @as(usize, @intCast(main_axis_cursor)) + flex_item.margin_main_axis_start;

        const cross_alignment = flex_item.cross_axis_alignment orelse .stretch;
        const cross_result = computeCrossAxisAlignment(
            content_rect,
            flex_container_style.flex_dir,
            cross_alignment,
            [2]usize{ item_width, item_height },
        );

        item_x = cross_result.cross_position;
        item_width = cross_result.cross_size;

        tracef("column flex-item: main_pos={d} cross_align={s} -> width={d}", .{ item_y, @tagName(cross_alignment), item_width });
    }

    const final_rect = Rect{ .x = item_x, .y = item_y, .w = item_width, .h = item_height };
    const main_axis_advance = if (flex_container_style.flex_dir == .row) item_width else item_height;

    return FlexItemPosition{
        .final_rect = final_rect,
        .main_axis_advance = main_axis_advance,
    };
}

/// Context for DOM tree traversal - no allocation needed
const DOMTreeBuildContext = struct {
    dom: *const Dom,

    fn init(dom: *const Dom) DOMTreeBuildContext {
        return .{ .dom = dom };
    }

    /// Returns the count of element children for a DOM node
    pub fn getChildCount(self: *DOMTreeBuildContext, parent_id: DomNodeId) usize {
        const items = self.dom.headers.slice();
        const kind = items.items(.kind)[@as(usize, @intCast(parent_id))];
        if (kind != .element) return 0;

        return items.items(.child_count)[@as(usize, @intCast(parent_id))];
    }

    /// Returns the nth child of a DOM node (element children only)
    pub fn getChild(self: *DOMTreeBuildContext, parent_id: DomNodeId, index: usize) DomNodeId {
        const items = self.dom.headers.slice();
        var i: usize = 0;
        var c = items.items(.first_child)[@as(usize, @intCast(parent_id))];
        while (i < index) : (i += 1) {
            c = items.items(.next_sibling)[@as(usize, @intCast(c))];
        }
        return c;
    }

    /// Creates BoxData from a DOM node ID
    pub fn createData(self: *DOMTreeBuildContext, dom_id: DomNodeId) BoxData {
        _ = self;
        return .{
            .dom_id = dom_id,
            .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        };
    }
};

pub fn allocateBoxTreeFromDOM(alloc: std.mem.Allocator, dom: *const Dom, root: DomNodeId) !BoxTree {
    var tree = BoxTree.init(alloc);
    var context = DOMTreeBuildContext.init(dom);

    // Use the generic BFS construction
    try tree.constructBFS(DomNodeId, root, &context);

    return tree;
}

pub fn computeFlexLayout(
    allocator: std.mem.Allocator,
    box_tree: *BoxTree,
    dom: *const Dom,
    container_node: *BoxTree.Node,
    container_rect: Rect,
    display_width: *DisplayWidth,
) !void {
    tracePhase("flexbox-layout");
    defer tracePop();

    var container_header = container_node;
    const flex_container_style = dom.getNodeStyle(container_header.data.dom_id);

    // Compute the inner content area after padding and border
    const content_rect = computeInnerContentRect(flex_container_style, container_rect);
    container_header.data.rect = container_rect;
    if (container_header.child_count == 0) return;

    var container_id_buf: [32]u8 = undefined;
    const container_debug_id = dom.getDebugIdOrDefault(container_header.data.dom_id, &container_id_buf);
    tracef("flexbox-container {s} rect=({d},{d} {d}x{d}) content=({d},{d} {d}x{d}) dir={s} justify={s} align_items={s}", .{
        container_debug_id,
        container_rect.x,
        container_rect.y,
        container_rect.w,
        container_rect.h,
        content_rect.x,
        content_rect.y,
        content_rect.w,
        content_rect.h,
        if (flex_container_style.flex_dir == .row) "row" else "col",
        @tagName(flex_container_style.justify),
        @tagName(flex_container_style.align_items),
    });

    // Phase 1: Compute intrinsic sizes for all flex items
    const flex_items = try computeIntrinsicSizesForFlexItems(
        allocator,
        box_tree,
        dom,
        container_header,
        content_rect,
        display_width,
        flex_container_style,
    );
    defer allocator.free(flex_items);
    const flex_item_count = flex_items.len;

    // Phase 2: Resolve flex item order (stable sort by order property)
    resolveFlexItemOrder(flex_items);

    // Phase 3: Resolve main axis sizes and compute flex-grow distribution
    const main_size_info = resolveFlexItemMainSizes(flex_items, flex_container_style);
    const container_main_size: i32 = @as(i32, @intCast(if (flex_container_style.flex_dir == .row) content_rect.w else content_rect.h));
    tracef("total_content_extent={d} container_main_size={d} main_gap={d}", .{
        main_size_info.content_extent,
        container_main_size,
        flex_container_style.gaps.main,
    });

    const available_space_for_growth: i32 = container_main_size - main_size_info.content_extent;
    distributeFlexGrow(
        available_space_for_growth,
        main_size_info.total_grow_factor,
        flex_items,
    );

    var total_distributed_space: i32 = 0;
    for (flex_items) |flex_item| {
        total_distributed_space += @max(0, flex_item.extra_main_size);
    }
    const content_extent_after_grow: i32 = main_size_info.content_extent + total_distributed_space;
    tracef("flex-grow: available={d} total_grow_factor={d} distributed={d} final_extent={d}", .{
        available_space_for_growth,
        main_size_info.total_grow_factor,
        total_distributed_space,
        content_extent_after_grow,
    });

    // Phase 4: Distribute remaining space according to justify-content
    const available_space_for_justify = container_main_size - content_extent_after_grow;
    const spacing = computeJustifyContentSpacing(
        flex_container_style.justify,
        available_space_for_justify,
        flex_item_count,
    );

    // Apply spacing directly to flex items (no separate allocation needed)
    const main_axis_gap: i32 = @as(i32, @intCast(flex_container_style.gaps.main));
    applyJustifyContentSpacing(flex_items, spacing, main_axis_gap);

    var main_axis_cursor: i32 = spacing.start_space;
    tracef("justify-content: start_space={d} between_space={d} remaining_pixels={d}", .{
        spacing.start_space,
        spacing.between_space,
        spacing.remaining_pixels,
    });

    // Phase 5: Position each flex item and recursively layout subtrees
    for (flex_items, 0..) |flex_item, item_index| {
        // Phase 5a: Align item on both axes and compute final rect
        const item_position = alignFlexItemOnBothAxes(
            content_rect,
            flex_container_style,
            main_axis_cursor,
            flex_item,
        );
        const item_box_node = container_header.getChildNodeMut(box_tree, flex_item.original_index);

        var item_id_buf: [32]u8 = undefined;
        const item_debug_id = dom.getDebugIdOrDefault(flex_item.dom_id, &item_id_buf);
        tracef("flex-item[{d}] {s}: order={d} extra_size={d} -> rect=({d},{d} {d}x{d}) advance={d}", .{
            item_index,
            item_debug_id,
            flex_item.flex_order,
            @max(0, flex_item.extra_main_size),
            item_position.final_rect.x,
            item_position.final_rect.y,
            item_position.final_rect.w,
            item_position.final_rect.h,
            item_position.main_axis_advance,
        });

        // Phase 5b: Recursively layout the flex item's subtree
        try computeFlexLayout(
            allocator,
            box_tree,
            dom,
            item_box_node,
            item_position.final_rect,
            display_width,
        );

        // Advance cursor for next item
        main_axis_cursor += @as(i32, @intCast(item_position.main_axis_advance)) + @as(i32, @intCast(flex_item.margin_main_axis_start + flex_item.margin_main_axis_end));
        main_axis_cursor += flex_item.trailing_space;
    }
    
    // For scroll containers, track the actual content size and handle auto-scroll
    if (flex_container_style.overflow_y == .scroll) {
        // Calculate the total content height used by all flex items
        const content_height: usize = @as(usize, @intCast(@max(0, main_axis_cursor - spacing.start_space)));
        
        // Store the content size for paint phase clipping
        container_header.data.content_size = .{ content_rect.w, content_height };
        
        // Auto-scroll to bottom: set scroll offset to show the bottom of content
        const viewport_height = content_rect.h;
        if (content_height > viewport_height) {
            container_header.data.scroll_offset_y = content_height - viewport_height;
        } else {
            container_header.data.scroll_offset_y = 0;
        }
        
        if (g_layout_trace_enabled) {
            var scroll_id_buf: [32]u8 = undefined;
            const scroll_debug_id = dom.getDebugIdOrDefault(container_header.data.dom_id, &scroll_id_buf);
            tracef("scroll-container {s}: content_size=({d}x{d}) viewport=({d}x{d}) scroll_y={d}", .{
                scroll_debug_id,
                content_rect.w,
                content_height,
                content_rect.w,
                viewport_height,
                container_header.data.scroll_offset_y,
            });
        }
    }
}

const JustifyContentSpacing = struct {
    start_space: i32,
    between_space: i32, // Space between each pair of items
    remaining_pixels: i32, // Extra pixels to distribute
};

/// Computes justify-content spacing parameters without allocating arrays.
/// Returns the base spacing values that can be applied directly to flex items.
fn computeJustifyContentSpacing(
    justify_content: StyleJustify,
    available_space: i32,
    item_count: usize,
) JustifyContentSpacing {
    if (item_count == 0) {
        return JustifyContentSpacing{
            .start_space = 0,
            .between_space = 0,
            .remaining_pixels = 0,
        };
    }

    return switch (justify_content) {
        .start => JustifyContentSpacing{
            .start_space = 0,
            .between_space = 0,
            .remaining_pixels = 0,
        },
        .end => JustifyContentSpacing{
            .start_space = available_space,
            .between_space = 0,
            .remaining_pixels = 0,
        },
        .center => JustifyContentSpacing{
            .start_space = @divTrunc(available_space, 2),
            .between_space = 0,
            .remaining_pixels = 0,
        },
        .space_between => if (item_count > 1) blk: {
            const gap_count = item_count - 1;
            const base_between_space = @divTrunc(available_space, @as(i32, @intCast(gap_count)));
            const remaining = available_space - base_between_space * @as(i32, @intCast(gap_count));
            break :blk JustifyContentSpacing{
                .start_space = 0,
                .between_space = base_between_space,
                .remaining_pixels = remaining,
            };
        } else JustifyContentSpacing{
            .start_space = 0,
            .between_space = 0,
            .remaining_pixels = 0,
        },
        .space_around => blk: {
            const total_half_slots: i32 = @as(i32, @intCast(2 * item_count));
            const half_slot_size: i32 = @divTrunc(available_space, total_half_slots);
            const remaining = available_space - half_slot_size * total_half_slots;
            break :blk JustifyContentSpacing{
                .start_space = half_slot_size,
                .between_space = half_slot_size * 2,
                .remaining_pixels = remaining,
            };
        },
        .space_evenly => blk: {
            const total_slots = item_count + 1;
            const base_slot_size = @divTrunc(available_space, @as(i32, @intCast(total_slots)));
            const remaining = available_space - base_slot_size * @as(i32, @intCast(total_slots));
            break :blk JustifyContentSpacing{
                .start_space = base_slot_size,
                .between_space = base_slot_size,
                .remaining_pixels = remaining,
            };
        },
    };
}

/// Applies justify-content spacing to flex items by setting their trailing_space.
/// This eliminates the need for a separate allocation for between_gaps.
fn applyJustifyContentSpacing(
    flex_items: []FlexItem,
    spacing: JustifyContentSpacing,
    main_axis_gap: i32,
) void {
    if (flex_items.len == 0) return;

    // Add main axis gap to between space
    const total_between_space = spacing.between_space + main_axis_gap;

    // Distribute remaining pixels evenly among items that should have spacing
    var remaining_pixels = spacing.remaining_pixels;

    for (flex_items, 0..) |*flex_item, item_index| {
        // All items except the last get trailing space
        if (item_index < flex_items.len - 1) {
            var item_trailing_space = total_between_space;

            // Distribute extra pixels fairly
            if (remaining_pixels > 0) {
                item_trailing_space += 1;
                remaining_pixels -= 1;
            }

            flex_item.trailing_space = item_trailing_space;
        } else {
            // Last item gets no trailing space
            flex_item.trailing_space = 0;
        }
    }
}
