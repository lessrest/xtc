// measure.zig - Intrinsic Size Calculation for Terminal UI Elements
//
// This module computes the natural size of DOM nodes before layout runs.
// It answers: "How big would this element like to be if unconstrained?"
//
// The intrinsic size is used as input to the flexbox layout algorithm,
// which then distributes available space among children.

const std = @import("std");
const DisplayWidth = @import("DisplayWidth");
const UnicodeData = @import("./unicode.zig");
const Dom = @import("./dom.zig").Dom;
const DomNodeId = @import("./dom.zig").DomNodeId;
const StyleRow = @import("./style.zig").StyleRow;
const BoxTree = @import("./layout.zig").BoxTree;
const text_layout = @import("./text_layout.zig");

// ============================================================================
// Core Concepts
// ============================================================================
//
// 1. INTRINSIC SIZE: The natural dimensions an element would have based on
//    its content, before any layout constraints are applied.
//
// 2. BOX MODEL: Terminal elements follow the CSS box model:
//    - Content: The actual text or child elements
//    - Padding: Space between content and border
//    - Border: The element's border (if any)
//    - Total size = content + padding + border (we use border-box sizing)
//
// 3. MEASUREMENT FLOW:
//    - Text nodes: Measure character width and line count
//    - Element nodes: Recursively measure children, then aggregate
//    - Special nodes (clock): Use minimal size (just padding+border)

// ============================================================================
// Box Model Helpers
// ============================================================================

const BoxSpacing = struct {
    // Horizontal spacing: left padding + right padding + 2 * border width
    horizontal: usize,
    // Vertical spacing: top padding + bottom padding + 2 * border width
    vertical: usize,
};

/// Calculate the total spacing (padding + border) for an element.
/// This is the space between the element's outer edge and its content area.
fn calculateBoxSpacing(style: StyleRow) BoxSpacing {
    const border_width = @as(usize, @intCast(style.border.width));

    return .{
        .horizontal = @as(usize, @intCast(style.padding.l)) +
            @as(usize, @intCast(style.padding.r)) +
            border_width * 2,
        .vertical = @as(usize, @intCast(style.padding.t)) +
            @as(usize, @intCast(style.padding.b)) +
            border_width * 2,
    };
}

/// Apply maximum constraints to dimensions, handling the special case of 0
/// meaning "unconstrained" in our system.
fn applyMaxConstraints(width: usize, height: usize, max_w: usize, max_h: usize) [2]usize {
    return .{
        if (max_w == 0) width else @min(max_w, width),
        if (max_h == 0) height else @min(max_h, height),
    };
}

// ============================================================================
// Text Measurement
// ============================================================================

/// Measure the intrinsic size of a text node.
/// Text nodes have natural dimensions based on their character content.
fn measureTextNode(
    dom: *const Dom,
    box_tree: *const BoxTree,
    node_index: BoxTree.NodeIndex,
    max_w: usize,
    max_h: usize,
    unicode: *const UnicodeData,
) [2]usize {
    const node = box_tree.getNode(node_index);
    const spacing = calculateBoxSpacing(node.data.style);
    const text = dom.getTextSlice(node.data.dom_id);

    const content_max_w = if (max_w > spacing.horizontal) max_w - spacing.horizontal else 0;
    const explicit_content_w = if (node.data.style.width > spacing.horizontal)
        @as(usize, @intCast(node.data.style.width)) - spacing.horizontal
    else
        0;
    const wrap_width = if (node.data.style.width != 0)
        explicit_content_w
    else
        content_max_w;

    var text_width: usize = 0;
    var line_count: usize = 0;
    var wrapped_lines = text_layout.WrappedLineIterator.init(unicode, text, wrap_width);
    while (wrapped_lines.next()) |line| {
        line_count += 1;
        text_width = @max(text_width, line.width_cols);
    }

    if (line_count == 0) line_count = 1;

    const content_width = if (node.data.style.width != 0)
        explicit_content_w
    else if (content_max_w == 0)
        text_width
    else
        @min(content_max_w, text_width);

    // Add spacing to get final dimensions
    const final_width = spacing.horizontal + content_width;
    const final_height = spacing.vertical + line_count;

    return applyMaxConstraints(final_width, final_height, max_w, max_h);
}

// ============================================================================
// Element Container Measurement
// ============================================================================

/// Aggregate child dimensions based on flex direction.
/// This determines how child sizes combine to form the parent's intrinsic size.
const ChildAggregator = struct {
    // Running totals for main axis (items placed end-to-end)
    total_main: usize = 0,
    // Maximum size on cross axis (items aligned side-by-side)
    max_cross: usize = 0,

    /// Add a child's dimensions to the aggregation
    fn addChild(self: *ChildAggregator, width: usize, height: usize, is_row: bool) void {
        if (is_row) {
            // Row layout: children placed horizontally
            self.total_main += width; // Sum widths
            self.max_cross = @max(self.max_cross, height); // Max height
        } else {
            // Column layout: children placed vertically
            self.total_main += height; // Sum heights
            self.max_cross = @max(self.max_cross, width); // Max width
        }
    }

    /// Get final dimensions based on flex direction
    fn getDimensions(self: ChildAggregator, is_row: bool) [2]usize {
        if (is_row) {
            return .{ self.total_main, self.max_cross };
        } else {
            return .{ self.max_cross, self.total_main };
        }
    }
};

/// Measure the intrinsic size of an element based on its children.
/// Elements aggregate their children's sizes according to flex direction.
fn measureElementNode(
    dom: *const Dom,
    box_tree: *BoxTree,
    node_index: BoxTree.NodeIndex,
    max_w: usize,
    max_h: usize,
    unicode: *const UnicodeData,
) [2]usize {
    const node = box_tree.getNode(node_index);
    const spacing = calculateBoxSpacing(node.data.style);

    // Handle empty elements (no children)
    if (node.child_count == 0) {
        // Empty element: just padding and border
        return applyMaxConstraints(spacing.horizontal, spacing.vertical, max_w, max_h);
    }

    // Measure all children and aggregate their sizes
    var aggregator = ChildAggregator{};
    const is_row = (node.data.style.flex_dir == .row);

    // Calculate available space for children (parent max minus spacing)
    const child_max_w = if (max_w > spacing.horizontal) (max_w - spacing.horizontal) else 0;
    const child_max_h = if (max_h > spacing.vertical) (max_h - spacing.vertical) else 0;

    // Iterate through children using efficient contiguous access
    const child_nodes = box_tree.children(node_index);
    for (child_nodes, 0..) |_, child_idx| {
        const child_node_index = node.getChildIndex(child_idx);
        // Recursively measure each child (will use cache if available)
        const child_size = intrinsicSize(dom, box_tree, child_node_index, child_max_w, child_max_h, unicode);
        aggregator.addChild(child_size[0], child_size[1], is_row);
    }

    // Get aggregated dimensions and add spacing
    const content_dims = aggregator.getDimensions(is_row);
    const final_width = spacing.horizontal + content_dims[0];
    const final_height = spacing.vertical + content_dims[1];

    return applyMaxConstraints(final_width, final_height, max_w, max_h);
}

// ============================================================================
// Main Entry Point
// ============================================================================

/// Calculate the intrinsic size of any DOM node.
/// This is the main entry point called by the layout engine.
///
/// The algorithm:
/// 1. Check for cached intrinsic size (return immediately if valid)
/// 2. Check for explicit width/height overrides in styles (these win)
/// 3. Otherwise, calculate based on node type:
///    - Text: Measure character width and line count
///    - Element: Recursively measure children and aggregate
///    - Special (clock): Use minimal size
/// 4. Cache the result and return
/// 5. Apply maximum constraints if provided
pub fn intrinsicSize(
    dom: *const Dom,
    box_tree: *BoxTree,
    node_index: BoxTree.NodeIndex,
    max_w: usize,
    max_h: usize,
    unicode: *const UnicodeData,
) [2]usize {
    const node = box_tree.getNodeMut(node_index);

    // Step 1: Check cache first
    if (node.data.intrinsic_size) |cached_size| {
        // Cache hit - return cached value
        return cached_size;
    }

    const node_id = node.data.dom_id;
    const style = node.data.style;
    const content = dom.getNodeContent(node_id);

    // Step 2: Check for explicit size overrides
    // These are treated as border-box dimensions and take precedence
    var width: usize = 0;
    var height: usize = 0;

    if (style.width != 0) width = style.width;
    if (style.height != 0) height = style.height;

    // If both dimensions are explicitly set, we're done
    if (width != 0 and height != 0) {
        return applyMaxConstraints(width, height, max_w, max_h);
    }

    // Step 3: Calculate intrinsic size based on content type
    const size = switch (content) {
        .text => measureTextNode(dom, box_tree, node_index, max_w, max_h, unicode),
        .element => measureElementNode(dom, box_tree, node_index, max_w, max_h, unicode),
    };

    // Step 4: Cache the computed size
    node.data.intrinsic_size = size;

    return size;
}

// ============================================================================
// Future Improvements (TODOs)
// ============================================================================
//
// Text Measurement Enhancements:
// - [ ] Tab character handling (configurable tab width)
// - [ ] Whitespace modes (normal, pre, nowrap, pre-wrap)
// - [ ] Text wrapping with line breaking
// - [ ] Ellipsis for overflow text
// - [ ] Baseline calculation for vertical alignment
//
// Layout Features:
// - [ ] flex-grow and flex-shrink distribution
// - [ ] flex-basis (auto vs specified)
// - [ ] flex-wrap for multi-line layouts
// - [ ] align-content for wrapped lines
// - [ ] Reverse directions (row-reverse, column-reverse)
//
// Constraints:
// - [ ] min-width, min-height enforcement
// - [ ] max-width, max-height clamping
// - [ ] Percentage resolution against parent
// - [ ] margin: auto for centering
//
// Performance:
// - [ ] Cache measurements by (node_id, constraints, style_hash)
// - [ ] Invalidation tracking for style/text changes
// - [ ] Pre-allocated buffers for child iteration
//
// Visual Properties:
// - [ ] display: none (skip measurement entirely)
// - [ ] visibility: hidden (measure but don't paint)
// - [ ] overflow clipping bounds calculation
