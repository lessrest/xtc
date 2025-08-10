const std = @import("std");
const Dom = @import("dom.zig").Dom;
const DomNodeId = @import("dom.zig").DomNodeId;
const Layout = @import("lib.zig").Layout;
const DisplayWidth = @import("lib.zig").DisplayWidth;
const measure = @import("measure.zig");
const StyleAlign = @import("style.zig").StyleAlign;
const StyleFlexDir = @import("style.zig").StyleFlexDir;
const StyleJustify = @import("style.zig").StyleJustify;
const StyleRow = @import("style.zig").StyleRow;
const BoxSize = [2]usize;

pub const Rect = struct { x: usize, y: usize, w: usize, h: usize };

// --- Lightweight, opt-in tracing for layout debugging ---
var g_layout_trace_enabled: bool = true;
pub fn setLayoutTraceEnabled(on: bool) void {
    g_layout_trace_enabled = on;
}

fn traceIndent(depth: usize) []const u8 {
    const spaces = "                                                                                ";
    const n = if (depth * 2 > spaces.len) spaces.len else depth * 2;
    return spaces[0..n];
}

fn tracef(depth: usize, comptime fmt: []const u8, args: anytype) void {
    if (!g_layout_trace_enabled) return;
    std.log.info("{s}" ++ fmt ++ "\n", .{traceIndent(depth)} ++ args);
}

fn depthInDom(dom_: *const Dom, node_id: DomNodeId) usize {
    const items = dom_.headers.slice();
    var d: usize = 0;
    var cur: DomNodeId = node_id;
    while (true) {
        const p = items.items(.parent)[@as(usize, @intCast(cur))];
        if (p == Dom.NullId) break;
        d += 1;
        cur = p;
    }
    return d;
}

pub const BoxHeader = struct {
    dom_id: DomNodeId,
    rect: Rect,
    first_child: u32, // index into headers, or maxInt(u32) when no children
    child_count: u32,
};

pub const BoxTree = struct {
    boxes: std.ArrayList(BoxHeader),

    pub fn init(alloc: std.mem.Allocator) BoxTree {
        return .{
            .boxes = std.ArrayList(BoxHeader).init(alloc),
        };
    }

    pub fn deinit(self: *BoxTree) void {
        self.boxes.deinit();
        self.* = undefined;
    }

    pub fn children(self: *const BoxTree, idx: usize) []const BoxHeader {
        const h = self.boxes.items[idx];
        if (h.child_count == 0) return &[_]BoxHeader{};
        const start: usize = @intCast(h.first_child);
        const end: usize = start + @as(usize, @intCast(h.child_count));
        return self.boxes.items[start..end];
    }
};

// --- Helpers to structure flex-like layout logic ---
const ChildInfo = struct {
    dom_id: DomNodeId,
    orig_index: usize,
    size: BoxSize,
    order: i16,
    @"align": ?StyleAlign,
    margin_main_start: usize,
    margin_main_end: usize,
    grow: usize,
};

fn computeInnerContentRect(parent_style: StyleRow, rect_: Rect) Rect {
    const border_w: usize = @as(usize, @intCast(parent_style.border.width));
    const pad_l: usize = @as(usize, @intCast(parent_style.padding.l)) + border_w;
    const pad_r: usize = @as(usize, @intCast(parent_style.padding.r)) + border_w;
    const pad_t: usize = @as(usize, @intCast(parent_style.padding.t)) + border_w;
    const pad_b: usize = @as(usize, @intCast(parent_style.padding.b)) + border_w;
    var inner_rect = rect_;
    inner_rect.x = rect_.x + @min(rect_.w, pad_l);
    inner_rect.y = rect_.y + @min(rect_.h, pad_t);
    inner_rect.w = if (rect_.w > pad_l + pad_r) rect_.w - (pad_l + pad_r) else 0;
    inner_rect.h = if (rect_.h > pad_t + pad_b) rect_.h - (pad_t + pad_b) else 0;
    return inner_rect;
}

fn collectChildrenInfo(
    alloc_: std.mem.Allocator,
    tree_: *BoxTree,
    dom_: *const Dom,
    idx_: u32,
    inner_rect: Rect,
    dw_: *DisplayWidth,
    parent_layout: StyleRow,
) ![]ChildInfo {
    const items = dom_.headers.slice();
    const children_slice = tree_.children(@as(usize, @intCast(idx_)));
    const n = children_slice.len;
    var result = try alloc_.alloc(ChildInfo, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dom_id = children_slice[i].dom_id;
        const sid = items.items(.style_id)[@as(usize, @intCast(dom_id))];
        const style = dom_.styles.cols.items[@intCast(sid)];

        var measured = measure.intrinsicSize(dom_, dom_id, inner_rect.w, inner_rect.h, dw_);
        if (style.width != 0) measured[0] = style.width;
        if (style.height != 0) measured[1] = style.height;

        const margin_start: usize = if (parent_layout.flex_dir == .row)
            @as(usize, @intCast(style.margin.l))
        else
            @as(usize, @intCast(style.margin.t));
        const margin_end: usize = if (parent_layout.flex_dir == .row)
            @as(usize, @intCast(style.margin.r))
        else
            @as(usize, @intCast(style.margin.b));
        const before_w = measured[0];
        const before_h = measured[1];
        result[i] = .{
            .dom_id = dom_id,
            .orig_index = i,
            .size = measured,
            .order = style.order,
            .@"align" = if (style.align_self == .start) parent_layout.align_items else style.align_self,
            .margin_main_start = margin_start,
            .margin_main_end = margin_end,
            .grow = style.flex.flexGrowFactor,
        };
        // Trace reasons for measured size
        if (g_layout_trace_enabled) {
            const depth = depthInDom(dom_, @intCast(tree_.boxes.items[@as(usize, @intCast(idx_))].dom_id)) + 1;
            if (style.width != 0 or style.height != 0) {
                tracef(depth, "child[{d}] dom={d}: intrinsic=({d}x{d}) overridden to=({d}x{d}) by width_cells={d} height_cells={d}", .{
                    i, dom_id, before_w, before_h, measured[0], measured[1], style.width, style.height,
                });
            } else {
                tracef(depth, "child[{d}] dom={d}: intrinsic measured=({d}x{d})", .{ i, dom_id, measured[0], measured[1] });
            }
            tracef(depth, "child[{d}]: order={d} grow={d} align_self={?} margins(main) start={d} end={d}", .{
                i, style.order, style.flex.flexGrowFactor, style.align_self, margin_start, margin_end,
            });
        }
    }
    return result;
}

fn stableSortChildrenByOrderInPlace(children: []ChildInfo) void {
    const n = children.len;
    var j: usize = 0;
    while (j < n) : (j += 1) {
        var k: usize = j;
        while (k > 0) : (k -= 1) {
            const a = children[k - 1];
            const bb = children[k];
            if (a.order > bb.order or (a.order == bb.order and a.orig_index > bb.orig_index)) {
                const tmp = children[k - 1];
                children[k - 1] = children[k];
                children[k] = tmp;
            } else break;
        }
    }
}

fn computeContentExtentAndTotalGrow(children: []const ChildInfo, parent_layout: StyleRow) struct { content_extent: i32, total_grow: usize } {
    var content_extent: i32 = 0;
    var total_grow: usize = 0;
    for (children) |cinfo| {
        const main = if (parent_layout.flex_dir == .row) cinfo.size[0] else cinfo.size[1];
        content_extent += @as(i32, @intCast(main + cinfo.margin_main_start + cinfo.margin_main_end));
        total_grow += cinfo.grow;
    }
    return .{ .content_extent = content_extent, .total_grow = total_grow };
}

fn computeExtraMainByOrig(
    alloc_: std.mem.Allocator,
    remaining: i32,
    total_grow: usize,
    children: []const ChildInfo,
) ![]i32 {
    const n = children.len;
    if (!(remaining > 0 and total_grow > 0)) return &[_]i32{};
    var extra = try alloc_.alloc(i32, n);
    var i: usize = 0;
    while (i < n) : (i += 1) extra[i] = 0;
    var rem = remaining;
    var idxg: usize = 0;
    while (idxg < n) : (idxg += 1) {
        const grow = @as(i32, @intCast(children[idxg].grow));
        const share = @divTrunc(remaining * grow, @as(i32, @intCast(total_grow)));
        extra[idxg] = share;
        rem -= share;
    }
    var idxr: usize = 0;
    while (rem > 0) : (rem -= 1) {
        if (idxr >= n) idxr = 0;
        if (children[idxr].grow > 0) extra[idxr] += 1;
        idxr += 1;
    }
    return extra;
}

fn positionChildRect(
    inner_rect: Rect,
    parent_layout: StyleRow,
    cursor_main: i32,
    cinfo: ChildInfo,
    extra_main_by_orig: []const i32,
    depth: usize,
) struct { rect: Rect, advanced: usize } {
    var cx: usize = inner_rect.x;
    var cy: usize = inner_rect.y;
    var cw: usize = cinfo.size[0];
    var ch: usize = cinfo.size[1];
    if (extra_main_by_orig.len != 0) {
        const add = extra_main_by_orig[cinfo.orig_index];
        if (parent_layout.flex_dir == .row) cw += @as(usize, @intCast(@max(0, add))) else ch += @as(usize, @intCast(@max(0, add)));
    }
    if (parent_layout.flex_dir == .row) {
        cx = inner_rect.x + @as(usize, @intCast(cursor_main)) + cinfo.margin_main_start;
        switch (cinfo.@"align" orelse .stretch) {
            .start => {
                cy = inner_rect.y;
                ch = cinfo.size[1];
                tracef(depth, "cross-align start: top of inner {d} with natural height {d}", .{ inner_rect.h, ch });
            },
            .center => {
                ch = if (cinfo.size[1] > inner_rect.h) inner_rect.h else cinfo.size[1];
                cy = inner_rect.y + (inner_rect.h - ch) / 2;
                tracef(depth, "cross-align center: vertical center, height clamped to {d}", .{ch});
            },
            .end => {
                ch = if (cinfo.size[1] > inner_rect.h) inner_rect.h else cinfo.size[1];
                cy = inner_rect.y + (inner_rect.h - ch);
                tracef(depth, "cross-align end: bottom align, height {d}", .{ch});
            },
            .stretch => {
                cy = inner_rect.y;
                ch = inner_rect.h;
                tracef(depth, "cross-align stretch: fill cross-axis to {d}", .{ch});
            },
            .baseline => {
                cy = inner_rect.y;
                ch = cinfo.size[1];
                tracef(depth, "cross-align baseline: fallback to natural height {d}", .{ch});
            },
        }
    } else {
        cy = inner_rect.y + @as(usize, @intCast(cursor_main)) + cinfo.margin_main_start;
        switch (cinfo.@"align" orelse .stretch) {
            .start => {
                cx = inner_rect.x;
                cw = cinfo.size[0];
                tracef(depth, "cross-align start: left align with natural width {d}", .{cw});
            },
            .center => {
                cw = if (cinfo.size[0] > inner_rect.w) inner_rect.w else cinfo.size[0];
                cx = inner_rect.x + (inner_rect.w - cw) / 2;
                tracef(depth, "cross-align center: horizontal center, width clamped to {d}", .{cw});
            },
            .end => {
                cw = if (cinfo.size[0] > inner_rect.w) inner_rect.w else cinfo.size[0];
                cx = inner_rect.x + (inner_rect.w - cw);
                tracef(depth, "cross-align end: right align, width {d}", .{cw});
            },
            .stretch => {
                cx = inner_rect.x;
                cw = inner_rect.w;
                tracef(depth, "cross-align stretch: fill cross-axis to {d}", .{cw});
            },
            .baseline => {
                cx = inner_rect.x;
                cw = cinfo.size[0];
                tracef(depth, "cross-align baseline: fallback to natural width {d}", .{cw});
            },
        }
    }
    const rect = Rect{ .x = cx, .y = cy, .w = cw, .h = ch };
    const advanced = if (parent_layout.flex_dir == .row) cw else ch;
    return .{ .rect = rect, .advanced = advanced };
}

pub fn allocateBoxTreeFromDOM(alloc: std.mem.Allocator, dom: *const Dom, root: DomNodeId) !BoxTree {
    var tree = BoxTree.init(alloc);
    // Breadth-first construction so each node's immediate children are contiguous
    const items = dom.headers.slice();

    const Pair = struct { dom_id: DomNodeId, tree_idx: u32 };
    var queue = std.ArrayList(Pair).init(alloc);
    defer queue.deinit();

    // Append root header
    try tree.boxes.append(.{ .dom_id = root, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .first_child = std.math.maxInt(u32), .child_count = 0 });
    try queue.append(.{ .dom_id = root, .tree_idx = 0 });

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const cur = queue.items[qi];
        const kind = items.items(.kind)[@as(usize, @intCast(cur.dom_id))];
        if (kind != .element) continue;

        const dom_child_count = items.items(.child_count)[@as(usize, @intCast(cur.dom_id))];
        if (dom_child_count == 0) continue;

        const first_child_index: u32 = @intCast(tree.boxes.items.len);
        var i: usize = 0;
        var c = items.items(.first_child)[@as(usize, @intCast(cur.dom_id))];
        while (i < dom_child_count) : (i += 1) {
            const child_tree_idx: u32 = @intCast(tree.boxes.items.len);
            try tree.boxes.append(.{ .dom_id = c, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .first_child = std.math.maxInt(u32), .child_count = 0 });
            try queue.append(.{ .dom_id = c, .tree_idx = child_tree_idx });
            c = items.items(.next_sibling)[@as(usize, @intCast(c))];
        }
        var hdr_ptr = &tree.boxes.items[@as(usize, @intCast(cur.tree_idx))];
        hdr_ptr.first_child = first_child_index;
        hdr_ptr.child_count = @intCast(dom_child_count);
    }

    return tree;
}

pub fn layoutBoxesInPlaceNode(alloc_: std.mem.Allocator, tree_: *BoxTree, dom_: *const Dom, idx_: u32, rect_: Rect, dw_: *DisplayWidth) !void {
    var hdr = &tree_.boxes.items[@as(usize, @intCast(idx_))];
    const items = dom_.headers.slice();
    const parent_sid = items.items(.style_id)[@as(usize, @intCast(hdr.dom_id))];
    const parent_style = dom_.styles.cols.items[@intCast(parent_sid)];

    const inner_rect = computeInnerContentRect(parent_style, rect_);
    hdr.rect = rect_;
    if (hdr.child_count == 0) return;

    const parent_layout = parent_style;
    const depth = depthInDom(dom_, hdr.dom_id);
    tracef(depth, "layout node dom={d} rect=({d},{d} {d}x{d}) inner=({d},{d} {d}x{d}) dir={s} justify={s} align_items={s}", .{
        hdr.dom_id,
        rect_.x,
        rect_.y,
        rect_.w,
        rect_.h,
        inner_rect.x,
        inner_rect.y,
        inner_rect.w,
        inner_rect.h,
        if (parent_layout.flex_dir == .row) "row" else "col",
        @tagName(parent_layout.justify),
        @tagName(parent_layout.align_items),
    });
    const children = try collectChildrenInfo(alloc_, tree_, dom_, idx_, inner_rect, dw_, parent_layout);
    defer alloc_.free(children);
    const n = children.len;

    stableSortChildrenByOrderInPlace(children);

    const totals = computeContentExtentAndTotalGrow(children, parent_layout);
    const container_extent: i32 = @as(i32, @intCast(if (parent_layout.flex_dir == .row) inner_rect.w else inner_rect.h));
    tracef(depth, "content_extent={d} container_extent={d} gaps.main={d}", .{ totals.content_extent, container_extent, parent_style.gaps.main });
    // Step 1: flex-grow distribution on remaining space
    const remaining_initial: i32 = container_extent - totals.content_extent;
    const extra_main_by_orig = try computeExtraMainByOrig(alloc_, remaining_initial, totals.total_grow, children);
    defer if (extra_main_by_orig.len != 0) alloc_.free(extra_main_by_orig);
    var added: i32 = 0;
    if (extra_main_by_orig.len != 0) {
        var t: usize = 0;
        while (t < extra_main_by_orig.len) : (t += 1) added += @max(0, extra_main_by_orig[t]);
    }
    const content_after_grow: i32 = totals.content_extent + added;
    tracef(depth, "grow: remaining={d} total_grow={d} added={d} content_after_grow={d}", .{ remaining_initial, totals.total_grow, added, content_after_grow });
    // Step 2: justify-content spacing on the (now grown) content extent
    const dist = try calculateSpaces(alloc_, parent_layout.justify, container_extent, content_after_grow, n);
    defer alloc_.free(dist.between_gaps);

    const main_gap: i32 = @as(i32, @intCast(parent_style.gaps.main));
    var gi: usize = 0;
    while (gi < dist.between_gaps.len) : (gi += 1) dist.between_gaps[gi] += main_gap;

    var cursor_main: i32 = dist.start_space;
    tracef(depth, "justify: start_space={d} between_gaps={d}", .{ dist.start_space, @as(i32, @intCast(dist.between_gaps.len)) });

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cinfo = children[i];
        const pos = positionChildRect(inner_rect, parent_layout, cursor_main, cinfo, extra_main_by_orig, depth + 1);
        const child_idx: u32 = @intCast(@as(usize, @intCast(hdr.first_child)) + cinfo.orig_index);
        tracef(depth + 1, "position child[{d}] dom={d}: order={d} grow_add={d} -> rect=({d},{d} {d}x{d}) advance={d}", .{
            i,            cinfo.dom_id, cinfo.order, if (extra_main_by_orig.len != 0) @max(0, extra_main_by_orig[cinfo.orig_index]) else 0,
            pos.rect.x,   pos.rect.y,   pos.rect.w,  pos.rect.h,
            pos.advanced,
        });
        try layoutBoxesInPlaceNode(alloc_, tree_, dom_, child_idx, pos.rect, dw_);
        cursor_main += @as(i32, @intCast(pos.advanced)) + @as(i32, @intCast(cinfo.margin_main_start + cinfo.margin_main_end));
        if (i < dist.between_gaps.len) cursor_main += dist.between_gaps[i];
    }
}
pub fn layoutBoxesInPlace(alloc: std.mem.Allocator, tree: *BoxTree, dom: *const Dom, root_index: u32, root_rect: Rect, dw: *DisplayWidth) !void {
    try layoutBoxesInPlaceNode(alloc, tree, dom, root_index, root_rect, dw);
}
pub fn layoutFixedBoxesAlloc(
    allocator: std.mem.Allocator,
    inner_x: usize,
    inner_y: usize,
    inner_w: usize,
    inner_h: usize,
    layout: Layout,
    children: []const BoxSize,
) ![]Rect {
    var rects = try allocator.alloc(Rect, children.len);
    var content_extent: i32 = 0;
    for (children) |c| content_extent += @as(i32, @intCast(if (layout.flex_dir == .row) c.width else c.height));
    const container_extent: i32 = @as(i32, @intCast(if (layout.flex_dir == .row) inner_w else inner_h));
    const dist = try calculateSpaces(allocator, layout.align_items, container_extent, content_extent, children.len);
    defer allocator.free(dist.between_gaps);

    var cursor_main: i32 = dist.start_space;
    var i: usize = 0;
    while (i < children.len) : (i += 1) {
        const c = children[i];
        var x: usize = inner_x;
        var y: usize = inner_y;
        var w: usize = c.width;
        var h: usize = c.height;
        if (layout.flex_dir == .row) {
            x = inner_x + @as(usize, @intCast(cursor_main));
            switch (layout.cross_align) {
                .start => {
                    y = inner_y;
                    h = c.height;
                },
                .center => {
                    h = if (c.height > inner_h) inner_h else c.height;
                    y = inner_y + (inner_h - h) / 2;
                },
                .end => {
                    h = if (c.height > inner_h) inner_h else c.height;
                    y = inner_y + (inner_h - h);
                },
                .stretch => {
                    y = inner_y;
                    h = inner_h;
                },
            }
        } else {
            y = inner_y + @as(usize, @intCast(cursor_main));
            switch (layout.cross_align) {
                .start => {
                    x = inner_x;
                    w = c.width;
                },
                .center => {
                    w = if (c.width > inner_w) inner_w else c.width;
                    x = inner_x + (inner_w - w) / 2;
                },
                .end => {
                    w = if (c.width > inner_w) inner_w else c.width;
                    x = inner_x + (inner_w - w);
                },
                .stretch => {
                    x = inner_x;
                    w = inner_w;
                },
            }
        }
        rects[i] = .{ .x = x, .y = y, .w = w, .h = h };
        cursor_main += @as(i32, @intCast(if (layout.flex_dir == .row) c.width else c.height));
        if (i < dist.between_gaps.len) cursor_main += dist.between_gaps[i];
    }
    return rects;
}

pub const SpaceDistribution = struct {
    start_space: i32,
    between_gaps: []i32,
};

pub fn calculateSpaces(allocator: std.mem.Allocator, alignment: StyleJustify, container: i32, content: i32, count: usize) !SpaceDistribution {
    @setEvalBranchQuota(5000);
    const remaining = @max(0, container - content);
    var dist = SpaceDistribution{
        .start_space = 0,
        .between_gaps = try allocator.alloc(i32, if (count == 0) 0 else if (count == 1) 0 else count - 1),
    };
    for (dist.between_gaps) |*g| g.* = 0;

    switch (alignment) {
        .start => dist.start_space = 0,
        .end => dist.start_space = remaining,
        .center => dist.start_space = @divTrunc(remaining, 2),
        .space_between => if (count > 1) {
            const gaps = count - 1;
            const base = @divTrunc(remaining, @as(i32, @intCast(gaps)));
            var rem = remaining - base * @as(i32, @intCast(gaps));
            dist.start_space = 0;
            var i: usize = 0;
            while (i < gaps) : (i += 1) {
                var add: i32 = base;
                if (rem > 0) {
                    add += 1;
                    rem -= 1;
                }
                dist.between_gaps[i] = add;
            }
        } else {},
        .space_around => if (count > 0) {
            // Model space-around as 2*count half-slots: start (1), end (1), and two halves per between gap.
            // Each half-slot gets base_half = remaining / (2*count). The spaces between items are 2*base_half,
            // and the leading/trailing spaces are base_half. Distribute any remainder starting from start.
            const half_slots: i32 = @as(i32, @intCast(2 * count));
            const base_half: i32 = @divTrunc(remaining, half_slots);
            var rem: i32 = remaining - base_half * half_slots;
            dist.start_space = base_half;
            var i: usize = 0;
            while (i < dist.between_gaps.len) : (i += 1) {
                dist.between_gaps[i] = base_half * 2;
            }
            // Distribute remainder: start first, then each between gap from left to right, then repeat if needed.
            var idx: usize = 0;
            while (rem > 0) {
                if (idx == 0) {
                    dist.start_space += 1;
                } else {
                    const gap_index = idx - 1;
                    if (gap_index < dist.between_gaps.len) {
                        dist.between_gaps[gap_index] += 1;
                    } else {
                        // wrap around to start again
                        idx = 0;
                        continue;
                    }
                }
                idx += 1;
                if (idx > dist.between_gaps.len) idx = 0; // cycle through start + gaps
                rem -= 1;
            }
        } else {},
        .space_evenly => if (count > 0) {
            const slots = count + 1; // start + gaps + end
            const base = @divTrunc(remaining, @as(i32, @intCast(slots)));
            var rem = remaining - base * @as(i32, @intCast(slots));
            dist.start_space = base;
            var i: usize = 0;
            while (i < dist.between_gaps.len) : (i += 1) {
                var add: i32 = base;
                if (rem > 0) {
                    add += 1;
                    rem -= 1;
                }
                dist.between_gaps[i] = add;
            }
        } else {},
    }
    return dist;
}
