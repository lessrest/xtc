const std = @import("std");
const Dom = @import("dom.zig").Dom;
const BoxTree = @import("lib.zig").BoxTree;
const Layout = @import("lib.zig").Layout;
const StyleAlign = @import("style.zig").StyleAlign;
const StyleFlexDir = @import("style.zig").StyleFlexDir;
const StyleJustify = @import("style.zig").StyleJustify;
const StyleRow = @import("style.zig").StyleRow;
const BoxSize = @import("lib.zig").BoxSize;

pub const Rect = struct { x: usize, y: usize, w: usize, h: usize };

pub fn layoutBoxesInPlaceNode(alloc_: std.mem.Allocator, tree_: *BoxTree, dom_: *const Dom, idx_: u32, rect_: Rect, provider_: anytype) !void {
    var hdr = &tree_.headers.items[@as(usize, @intCast(idx_))];
    // Read parent style
    const items = dom_.headers.slice();
    const parent_sid = items.items(.style_id)[@as(usize, @intCast(hdr.dom_id))];
    const parent_style = dom_.styles.cols.items[@intCast(parent_sid)];

    // Compute inner content rect based on padding and border
    const border_w: usize = @as(usize, @intCast(parent_style.border.width_cells));
    const pad_l: usize = @as(usize, @intCast(parent_style.padding.l)) + border_w;
    const pad_r: usize = @as(usize, @intCast(parent_style.padding.r)) + border_w;
    const pad_t: usize = @as(usize, @intCast(parent_style.padding.t)) + border_w;
    const pad_b: usize = @as(usize, @intCast(parent_style.padding.b)) + border_w;
    var inner_rect = rect_;
    inner_rect.x = rect_.x + @min(rect_.w, pad_l);
    inner_rect.y = rect_.y + @min(rect_.h, pad_t);
    inner_rect.w = if (rect_.w > pad_l + pad_r) rect_.w - (pad_l + pad_r) else 0;
    inner_rect.h = if (rect_.h > pad_t + pad_b) rect_.h - (pad_t + pad_b) else 0;

    hdr.rect = rect_;
    if (hdr.child_count == 0) return;

    const parent_layout = provider_.props(dom_, hdr.dom_id);
    const children_slice = tree_.children(@as(usize, @intCast(idx_)));

    const n = children_slice.len;
    const ChildInfo = struct {
        orig_index: usize,
        size: BoxSize,
        order: i16,
        @"align": CrossAxisAlignment,
        margin_main_start: usize,
        margin_main_end: usize,
    };
    var children = try alloc_.alloc(ChildInfo, n);
    defer alloc_.free(children);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dom_id = children_slice[i].dom_id;
        const sid = items.items(.style_id)[@as(usize, @intCast(dom_id))];
        const srow = dom_.styles.cols.items[@intCast(sid)];
        var measured = provider_.measure(dom_, dom_id, inner_rect.w, inner_rect.h);
        if (srow.width_cells != 0) measured.width = srow.width_cells;
        if (srow.height_cells != 0) measured.height = srow.height_cells;
        const align_override = styleAlignToCross(srow.align_self);
        const margin_start: usize = if (parent_layout.direction == .row)
            @as(usize, @intCast(srow.margin.l))
        else
            @as(usize, @intCast(srow.margin.t));
        const margin_end: usize = if (parent_layout.direction == .row)
            @as(usize, @intCast(srow.margin.r))
        else
            @as(usize, @intCast(srow.margin.b));
        children[i] = .{
            .orig_index = i,
            .size = measured,
            .order = srow.order,
            // Treat reserved value _u0 as "inherit"; otherwise, use explicit align_self
            .@"align" = if (srow.align_self == ._u0) parent_layout.cross_align else align_override,
            .margin_main_start = margin_start,
            .margin_main_end = margin_end,
        };
    }

    // Stable sort by (order, orig_index)
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

    // Content extent includes margins
    // First pass: compute main sizes and totals for growth distribution
    var content_extent: i32 = 0;
    var total_grow: usize = 0;
    for (children) |cinfo| {
        const main = if (parent_layout.direction == .row) cinfo.size.width else cinfo.size.height;
        content_extent += @as(i32, @intCast(main + cinfo.margin_main_start + cinfo.margin_main_end));
        // Sum grow factors from styles
        const sid = items.items(.style_id)[@as(usize, @intCast(children_slice[cinfo.orig_index].dom_id))];
        const srow_g = dom_.styles.cols.items[@intCast(sid)];
        total_grow += srow_g.flex.grow;
    }
    const container_extent: i32 = @as(i32, @intCast(if (parent_layout.direction == .row) inner_rect.w else inner_rect.h));
    const dist = try calculateSpaces(alloc_, parent_layout.main_align, container_extent, content_extent, n);
    defer alloc_.free(dist.between_gaps);

    // Add main-axis gap from style to each between gap
    const main_gap: i32 = @as(i32, @intCast(parent_style.gaps.main));
    var gi: usize = 0;
    while (gi < dist.between_gaps.len) : (gi += 1) dist.between_gaps[gi] += main_gap;

    var cursor_main: i32 = dist.start_space;
    // If we have remaining space and grow factors, distribute proportionally
    const remaining: i32 = (@as(i32, @intCast(if (parent_layout.direction == .row) inner_rect.w else inner_rect.h))) - content_extent - dist.start_space - blk: {
        var sum_gaps: i32 = 0;
        var gi2: usize = 0;
        while (gi2 < dist.between_gaps.len) : (gi2 += 1) sum_gaps += dist.between_gaps[gi2];
        break :blk sum_gaps;
    };
    var extra_main_by_orig: []i32 = &[_]i32{};
    if (remaining > 0 and total_grow > 0) {
        extra_main_by_orig = try alloc_.alloc(i32, n);
        defer alloc_.free(extra_main_by_orig);
        var rem = remaining;
        // Proportional integer distribution
        var idxg: usize = 0;
        while (idxg < n) : (idxg += 1) {
            const sid = items.items(.style_id)[@as(usize, @intCast(children_slice[idxg].dom_id))];
            const srow_g = dom_.styles.cols.items[@intCast(sid)];
            const share = @divTrunc(remaining * @as(i32, @intCast(srow_g.flex.grow)), @as(i32, @intCast(total_grow)));
            extra_main_by_orig[idxg] = share;
            rem -= share;
        }
        // Distribute remainder one by one from left to right
        var idxr: usize = 0;
        while (rem > 0) : (rem -= 1) {
            if (idxr >= n) idxr = 0;
            if (dom_.styles.cols.items[@intCast(items.items(.style_id)[@as(usize, @intCast(children_slice[idxr].dom_id))])].flex.grow > 0) {
                extra_main_by_orig[idxr] += 1;
            }
            idxr += 1;
        }
    }
    i = 0;
    while (i < n) : (i += 1) {
        const cinfo = children[i];
        const s = cinfo.size;
        var cx: usize = inner_rect.x;
        var cy: usize = inner_rect.y;
        var cw: usize = s.width;
        var ch: usize = s.height;
        if (extra_main_by_orig.len != 0) {
            const add = extra_main_by_orig[cinfo.orig_index];
            if (parent_layout.direction == .row) cw += @as(usize, @intCast(@max(0, add))) else ch += @as(usize, @intCast(@max(0, add)));
        }
        if (parent_layout.direction == .row) {
            cx = inner_rect.x + @as(usize, @intCast(cursor_main)) + cinfo.margin_main_start;
            switch (cinfo.@"align") {
                .start => {
                    cy = inner_rect.y;
                    ch = s.height;
                },
                .center => {
                    ch = if (s.height > inner_rect.h) inner_rect.h else s.height;
                    cy = inner_rect.y + (inner_rect.h - ch) / 2;
                },
                .end => {
                    ch = if (s.height > inner_rect.h) inner_rect.h else s.height;
                    cy = inner_rect.y + (inner_rect.h - ch);
                },
                .stretch => {
                    cy = inner_rect.y;
                    ch = inner_rect.h;
                },
            }
        } else {
            cy = inner_rect.y + @as(usize, @intCast(cursor_main)) + cinfo.margin_main_start;
            switch (cinfo.@"align") {
                .start => {
                    cx = inner_rect.x;
                    cw = s.width;
                },
                .center => {
                    cw = if (s.width > inner_rect.w) inner_rect.w else s.width;
                    cx = inner_rect.x + (inner_rect.w - cw) / 2;
                },
                .end => {
                    cw = if (s.width > inner_rect.w) inner_rect.w else s.width;
                    cx = inner_rect.x + (inner_rect.w - cw);
                },
                .stretch => {
                    cx = inner_rect.x;
                    cw = inner_rect.w;
                },
            }
        }
        const child_rect: Rect = .{ .x = cx, .y = cy, .w = cw, .h = ch };
        const child_idx: u32 = @intCast(@as(usize, @intCast(hdr.first_child)) + cinfo.orig_index);
        try layoutBoxesInPlaceNode(alloc_, tree_, dom_, child_idx, child_rect, provider_);
        const advanced = if (parent_layout.direction == .row) cw else ch;
        cursor_main += @as(i32, @intCast(advanced)) + @as(i32, @intCast(cinfo.margin_main_start + cinfo.margin_main_end));
        if (i < dist.between_gaps.len) cursor_main += dist.between_gaps[i];
    }
}
pub fn layoutBoxesInPlace(alloc: std.mem.Allocator, tree: *BoxTree, dom: *const Dom, root_index: u32, root_rect: Rect, provider: anytype) !void {
    try layoutBoxesInPlaceNode(alloc, tree, dom, root_index, root_rect, provider);
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
    for (children) |c| content_extent += @as(i32, @intCast(if (layout.direction == .row) c.width else c.height));
    const container_extent: i32 = @as(i32, @intCast(if (layout.direction == .row) inner_w else inner_h));
    const dist = try calculateSpaces(allocator, layout.main_align, container_extent, content_extent, children.len);
    defer allocator.free(dist.between_gaps);

    var cursor_main: i32 = dist.start_space;
    var i: usize = 0;
    while (i < children.len) : (i += 1) {
        const c = children[i];
        var x: usize = inner_x;
        var y: usize = inner_y;
        var w: usize = c.width;
        var h: usize = c.height;
        if (layout.direction == .row) {
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
        cursor_main += @as(i32, @intCast(if (layout.direction == .row) c.width else c.height));
        if (i < dist.between_gaps.len) cursor_main += dist.between_gaps[i];
    }
    return rects;
}

pub const Direction = enum { row, column };
pub const MainAxisAlignment = enum { start, center, end, space_between, space_around, space_evenly };
pub const CrossAxisAlignment = enum { start, center, end, stretch };

pub const SpaceDistribution = struct {
    start_space: i32,
    between_gaps: []i32,
};

pub fn calculateSpaces(allocator: std.mem.Allocator, alignment: MainAxisAlignment, container: i32, content: i32, count: usize) !SpaceDistribution {
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

// --- Style -> Layout mapping helpers ---

fn styleFlexDirToDirection(dir: StyleFlexDir) Direction {
    return switch (dir) {
        .row, .row_reverse => .row,
        .column, .column_reverse => .column,
    };
}

pub fn styleAlignToCross(@"align": StyleAlign) CrossAxisAlignment {
    return switch (@"align") {
        .start => .start,
        .end => .end,
        .center => .center,
        .stretch => .stretch,
        // Map unsupported values to sensible defaults for now
        .baseline, ._u0, ._u1, ._u2 => .start,
    };
}

fn styleJustifyToMainAxis(j: StyleJustify) MainAxisAlignment {
    return switch (j) {
        .start => .start,
        .end => .end,
        .center => .center,
        .space_between => .space_between,
        .space_around => .space_around,
        .space_evenly => .space_evenly,
        ._u0, ._u1 => .start,
    };
}

pub fn layoutFromStyleRow(row: StyleRow) Layout {
    return .{
        .direction = styleFlexDirToDirection(row.flex_dir),
        .main_align = styleJustifyToMainAxis(row.justify),
        .cross_align = styleAlignToCross(row.align_items),
    };
}
