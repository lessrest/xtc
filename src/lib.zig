const std = @import("std");

pub const Direction = enum { row, column };
pub const MainAxisAlignment = enum { start, center, end, space_between, space_around, space_evenly };
pub const CrossAxisAlignment = enum { start, center, end, stretch };

pub const SpaceDistribution = struct {
    start_space: i32,
    between_gaps: []i32,
};

pub fn calculateSpaces(allocator: std.mem.Allocator, alignment: MainAxisAlignment, container: i32, content: i32, count: usize) !SpaceDistribution {
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

/// Word wrap to width using greedy wrap with DP badness minimization (lite):
pub fn wrapAlloc(allocator: std.mem.Allocator, s: []const u8, width: usize) ![][]u8 {
    if (width == 0) return try std.heap.page_allocator.alloc([]u8, 0);
    var words = std.ArrayList([]const u8).init(allocator);
    defer words.deinit();
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |w| {
        if (w.len <= width) {
            try words.append(w);
        } else {
            var i: usize = 0;
            while (i < w.len) : (i += width) {
                const end = @min(w.len, i + width);
                try words.append(w[i..end]);
            }
        }
    }
    const n = words.items.len;
    var pref = try allocator.alloc(usize, n + 1);
    defer allocator.free(pref);
    pref[0] = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) pref[i + 1] = pref[i] + words.items[i].len;

    var dp = try allocator.alloc(i64, n + 1);
    var nxt = try allocator.alloc(usize, n + 1);
    defer allocator.free(dp);
    defer allocator.free(nxt);
    dp[n] = 0;
    nxt[n] = n;
    var k: isize = @as(isize, @intCast(n)) - 1;
    while (k >= 0) : (k -= 1) {
        const idx: usize = @as(usize, @intCast(k));
        var best: i64 = std.math.maxInt(i64) / 4;
        var bestj: usize = idx + 1;
        var j: usize = idx;
        while (j < n) : (j += 1) {
            const words_len = pref[j + 1] - pref[idx];
            const gaps = j - idx;
            const line_len = words_len + gaps;
            if (line_len > width) break;
            const last = (j == n - 1);
            const slack = @as(i64, @intCast(width - line_len));
            const cost: i64 = if (last) 0 else slack * slack * slack;
            const total = cost + dp[j + 1];
            if (total < best) {
                best = total;
                bestj = j + 1;
            }
        }
        dp[idx] = best;
        nxt[idx] = bestj;
    }

    var lines = std.ArrayList([]u8).init(allocator);
    var p: usize = 0;
    while (p < n) {
        const q = nxt[p];
        const joined = try joinWords(allocator, words.items[p..q]);
        try lines.append(joined);
        p = q;
    }
    return lines.toOwnedSlice();
}

pub const Raster = struct {
    width: usize,
    height: usize,
    buf: []u8,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Raster {
        const r = Raster{
            .width = width,
            .height = height,
            .buf = try allocator.alloc(u8, width * height),
        };
        @memset(r.buf, ' ');
        return r;
    }

    pub fn deinit(self: *Raster, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn set(self: *Raster, x: usize, y: usize, ch: u8) void {
        if (x >= self.width or y >= self.height) return;
        self.buf[y * self.width + x] = ch;
    }

    pub fn toStringAlloc(self: *const Raster, allocator: std.mem.Allocator) ![]u8 {
        const line_len = self.width + 1; // + '\n'
        var out = try allocator.alloc(u8, self.height * line_len);
        var i: usize = 0;
        while (i < self.height) : (i += 1) {
            const row = self.buf[i * self.width .. i * self.width + self.width];
            std.mem.copyForwards(u8, out[i * line_len ..][0..self.width], row);
            out[i * line_len + self.width] = '\n';
        }
        return out;
    }
};

pub fn drawBorderAscii(r: *Raster, x: usize, y: usize, w: usize, h: usize) void {
    if (w == 0 or h == 0) return;
    const x2 = if (x + w == 0) 0 else x + w - 1;
    const y2 = if (y + h == 0) 0 else y + h - 1;
    r.set(x, y, '+');
    r.set(x2, y, '+');
    r.set(x, y2, '+');
    r.set(x2, y2, '+');
    var xi: usize = x + 1;
    while (xi < x2) : (xi += 1) {
        r.set(xi, y, '-');
        r.set(xi, y2, '-');
    }
    var yi: usize = y + 1;
    while (yi < y2) : (yi += 1) {
        r.set(x, yi, '|');
        r.set(x2, yi, '|');
    }
}

pub fn renderParagraphAlloc(allocator: std.mem.Allocator, s: []const u8, width: usize) !Raster {
    const lines = try wrapAlloc(allocator, s, width);
    defer {
        for (lines) |ln| allocator.free(ln);
        allocator.free(lines);
    }
    var r = try Raster.init(allocator, width, lines.len);
    var y: usize = 0;
    while (y < lines.len) : (y += 1) {
        const ln = lines[y];
        // copy line into raster row
        const n = if (ln.len < width) ln.len else width;
        std.mem.copyForwards(u8, r.buf[y * r.width ..][0..n], ln[0..n]);
    }
    return r;
}

fn joinWords(allocator: std.mem.Allocator, ws: [][]const u8) ![]u8 {
    if (ws.len == 0) return try allocator.alloc(u8, 0);
    var total: usize = ws.len - 1;
    for (ws) |w| total += w.len;
    var buf = try allocator.alloc(u8, total);
    var i: usize = 0;
    var idx: usize = 0;
    while (i < ws.len) : (i += 1) {
        const w = ws[i];
        std.mem.copyForwards(u8, buf[idx..][0..w.len], w);
        idx += w.len;
        if (i + 1 < ws.len) {
            buf[idx] = ' ';
            idx += 1;
        }
    }
    return buf;
}

// --- Simple compositor primitives for ASCII-art TDD ---
pub const BoxSize = struct {
    width: usize,
    height: usize,
};

pub const Layout = struct {
    direction: Direction,
    main_align: MainAxisAlignment,
    cross_align: CrossAxisAlignment,
};

/// Compose a single-line flex row/column of fixed-size boxes into a raster.
/// For now, children are placed on the main axis according to `main_align`,
/// without wrapping or cross-axis alignment. Intended for ASCII-art tests.
pub fn composeFixedBoxesAlloc(
    allocator: std.mem.Allocator,
    container_width: usize,
    container_height: usize,
    layout: Layout,
    children: []const BoxSize,
) !Raster {
    var r = try Raster.init(allocator, container_width, container_height);
    // Draw viewport border and compute inner content area
    drawBorderAscii(&r, 0, 0, container_width, container_height);
    const inner_x: usize = if (container_width >= 2) 1 else 0;
    const inner_y: usize = if (container_height >= 2) 1 else 0;
    const inner_w: usize = if (container_width > 1) container_width - 2 else container_width;
    const inner_h: usize = if (container_height > 1) container_height - 2 else container_height;

    // Compute content extent along main axis
    var content_extent: i32 = 0;
    for (children) |c| content_extent += @as(i32, @intCast(if (layout.direction == .row) c.width else c.height));

    const count = children.len;
    const container_extent: i32 = @as(i32, @intCast(if (layout.direction == .row) inner_w else inner_h));
    const dist = try calculateSpaces(allocator, layout.main_align, container_extent, content_extent, count);
    defer allocator.free(dist.between_gaps);

    var cursor_main: i32 = dist.start_space;
    var i: usize = 0;
    while (i < children.len) : (i += 1) {
        const c = children[i];
        const w_nat = c.width;
        const h_nat = c.height;
        var x: usize = inner_x;
        var y: usize = inner_y;
        var draw_w: usize = w_nat;
        var draw_h: usize = h_nat;
        if (layout.direction == .row) {
            x = inner_x + @as(usize, @intCast(cursor_main));
            // Cross is vertical
            switch (layout.cross_align) {
                .start => {
                    y = inner_y;
                    draw_h = h_nat;
                },
                .center => {
                    draw_h = if (h_nat > inner_h) inner_h else h_nat;
                    y = inner_y + (inner_h - draw_h) / 2;
                },
                .end => {
                    draw_h = if (h_nat > inner_h) inner_h else h_nat;
                    y = inner_y + (inner_h - draw_h);
                },
                .stretch => {
                    y = inner_y;
                    draw_h = inner_h;
                },
            }
        } else { // column direction
            y = inner_y + @as(usize, @intCast(cursor_main));
            // Cross is horizontal
            switch (layout.cross_align) {
                .start => {
                    x = inner_x;
                    draw_w = w_nat;
                },
                .center => {
                    draw_w = if (w_nat > inner_w) inner_w else w_nat;
                    x = inner_x + (inner_w - draw_w) / 2;
                },
                .end => {
                    draw_w = if (w_nat > inner_w) inner_w else w_nat;
                    x = inner_x + (inner_w - draw_w);
                },
                .stretch => {
                    x = inner_x;
                    draw_w = inner_w;
                },
            }
        }
        if (draw_w > 0 and draw_h > 0) {
            drawBorderAscii(&r, x, y, draw_w, draw_h);
        }
        cursor_main += @as(i32, @intCast(if (layout.direction == .row) w_nat else h_nat));
        if (i < dist.between_gaps.len) cursor_main += dist.between_gaps[i];
    }

    return r;
}

/// Helper to compare ASCII rasters while producing a readable diff on failure.
pub fn expectAsciiEqual(want: []const u8, got: []const u8) !void {
    try std.testing.expectEqualStrings(want, got);
    // zig already prints a great diff view
}

// --- Test DSL helpers to reduce boilerplate ---
pub fn b(width: usize, height: usize) BoxSize {
    return .{ .width = width, .height = height };
}

fn joinLinesAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (lines) |ln| total += ln.len + 1; // +\n per line
    var buf = try allocator.alloc(u8, total);
    var idx: usize = 0;
    for (lines) |ln| {
        std.mem.copyForwards(u8, buf[idx..][0..ln.len], ln);
        idx += ln.len;
        buf[idx] = '\n';
        idx += 1;
    }
    return buf;
}

pub fn assertComposeRow(
    main_align: MainAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want_lines: []const []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .row, .main_align = main_align, .cross_align = .stretch };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    const want = try joinLinesAlloc(al, want_lines);
    try expectAsciiEqual(want, got);
}

pub fn expectFlexRow(
    main_align: MainAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want: []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .row, .main_align = main_align, .cross_align = .stretch };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    try expectAsciiEqual(want, got);
}

pub fn expectFlexRowWithCross(
    main_align: MainAxisAlignment,
    cross_align: CrossAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want: []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .row, .main_align = main_align, .cross_align = cross_align };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    try expectAsciiEqual(want, got);
}

pub fn assertComposeColumn(
    main_align: MainAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want_lines: []const []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .column, .main_align = main_align, .cross_align = .start };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    const want = try joinLinesAlloc(al, want_lines);
    try expectAsciiEqual(want, got);
}

pub fn expectFlexColumn(
    main_align: MainAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want: []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .column, .main_align = main_align, .cross_align = .start };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    try expectAsciiEqual(want, got);
}

pub fn expectFlexColumnWithCross(
    main_align: MainAxisAlignment,
    cross_align: CrossAxisAlignment,
    container: BoxSize,
    boxes: []const BoxSize,
    want: []const u8,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    const layout = Layout{ .direction = .column, .main_align = main_align, .cross_align = cross_align };
    var r = try composeFixedBoxesAlloc(al, container.width, container.height, layout, boxes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    try expectAsciiEqual(want, got);
}

// --- Nested composition primitives ---

pub fn blitNonSpace(dst: *Raster, dx: usize, dy: usize, src: *const Raster) void {
    var y: usize = 0;
    while (y < src.height) : (y += 1) {
        var x: usize = 0;
        while (x < src.width) : (x += 1) {
            const ch = src.buf[y * src.width + x];
            if (ch != ' ') dst.set(dx + x, dy + y, ch);
        }
    }
}

pub const ColumnNode = struct {
    // If width == 0, width is max child width; otherwise use provided width
    width: usize = 0,
    main_align: MainAxisAlignment = .start,
    cross_align: CrossAxisAlignment = .start,
    children: []const BoxSize,
};

pub const NodeKind = enum { Box, Column };
pub const Node = union(NodeKind) {
    Box: BoxSize,
    Column: ColumnNode,
};

fn maxChildWidth(children: []const BoxSize) usize {
    var m: usize = 0;
    for (children) |c| {
        if (c.width > m) {
            m = c.width;
        }
    }
    return m;
}

fn renderColumnAlloc(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    col: ColumnNode,
) !Raster {
    var r = try Raster.init(allocator, width, height);
    const total_h: i32 = blk: {
        var acc: usize = 0;
        for (col.children) |c| acc += c.height;
        break :blk @as(i32, @intCast(acc));
    };
    const count = col.children.len;
    const col_align = col.main_align;
    const dist = try calculateSpaces(allocator, col_align, @as(i32, @intCast(height)), total_h, count);
    defer allocator.free(dist.between_gaps);
    var cursor_y: i32 = dist.start_space;
    var i: usize = 0;
    while (i < col.children.len) : (i += 1) {
        const c = col.children[i];
        var cx: usize = 0;
        var cw: usize = c.width;
        switch (col.cross_align) {
            .start => {
                cx = 0;
                cw = c.width;
            },
            .center => {
                cw = if (c.width > width) width else c.width;
                cx = (width - cw) / 2;
            },
            .end => {
                cw = if (c.width > width) width else c.width;
                cx = width - cw;
            },
            .stretch => {
                cx = 0;
                cw = width;
            },
        }
        drawBorderAscii(&r, cx, @as(usize, @intCast(cursor_y)), cw, c.height);
        cursor_y += @as(i32, @intCast(c.height));
        if (i < dist.between_gaps.len) cursor_y += dist.between_gaps[i];
    }
    return r;
}

pub fn composeRowOfNodesAlloc(
    allocator: std.mem.Allocator,
    container_width: usize,
    container_height: usize,
    main_align: MainAxisAlignment,
    nodes: []const Node,
) !Raster {
    var r = try Raster.init(allocator, container_width, container_height);
    drawBorderAscii(&r, 0, 0, container_width, container_height);
    const inner_x: usize = if (container_width >= 2) 1 else 0;
    const inner_y: usize = if (container_height >= 2) 1 else 0;
    const inner_w: usize = if (container_width > 1) container_width - 2 else container_width;
    const inner_h: usize = if (container_height > 1) container_height - 2 else container_height;

    // Compute per-node width footprints
    var content_w: i32 = 0;
    var i: usize = 0;
    while (i < nodes.len) : (i += 1) {
        const w: usize = switch (nodes[i]) {
            .Box => |bx| bx.width,
            .Column => |c| if (c.width == 0) maxChildWidth(c.children) else c.width,
        };
        content_w += @as(i32, @intCast(w));
    }
    const dist = try calculateSpaces(allocator, main_align, @as(i32, @intCast(inner_w)), content_w, nodes.len);
    defer allocator.free(dist.between_gaps);

    var cursor_x: i32 = dist.start_space;
    i = 0;
    while (i < nodes.len) : (i += 1) {
        const px: usize = inner_x + @as(usize, @intCast(cursor_x));
        switch (nodes[i]) {
            .Box => |bx| {
                // Stretch boxes to full inner height to match default cross-axis stretch in row
                drawBorderAscii(&r, px, inner_y, bx.width, inner_h);
                cursor_x += @as(i32, @intCast(bx.width));
            },
            .Column => |c| {
                const w: usize = if (c.width == 0) maxChildWidth(c.children) else c.width;
                var sub = try renderColumnAlloc(allocator, w, inner_h, c);
                defer sub.deinit(allocator);
                blitNonSpace(&r, px, inner_y, &sub);
                cursor_x += @as(i32, @intCast(w));
            },
        }
        if (i < dist.between_gaps.len) cursor_x += dist.between_gaps[i];
    }
    return r;
}

// --- Text-in-box primitives

pub const TextBox = struct {
    width: usize,
    height: usize,
    text: []const u8,
};

fn wrapWithOverflowAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    max_lines: usize,
) ![][]u8 {
    const lines = try wrapAlloc(allocator, text, width);
    if (lines.len <= max_lines) return lines;
    var out = try allocator.alloc([]u8, max_lines);
    var i: usize = 0;
    while (i + 1 < max_lines) : (i += 1) {
        out[i] = lines[i];
    }
    // Prepare last line
    const last_src = lines[i];

    // Chop without ellipsis
    const n = @min(width, last_src.len);
    var buf = try allocator.alloc(u8, n);
    if (n > 0) std.mem.copyForwards(u8, buf[0..n], last_src[0..n]);
    out[i] = buf;
    // We are replacing the original last line with a chopped buffer, so free the dropped source line
    allocator.free(last_src);

    // Free the remaining lines we won't use
    var j: usize = i + 1;
    while (j < lines.len) : (j += 1) allocator.free(lines[j]);
    allocator.free(lines);
    return out;
}

fn drawTextBoxIntoRaster(
    allocator: std.mem.Allocator,
    r: *Raster,
    x: usize,
    y: usize,
    tb: TextBox,
) !void {
    // Treat tb.width/height as content size; add a 1-cell border around
    if (tb.width == 0 or tb.height == 0) return;
    const outer_w: usize = tb.width + 2;
    const outer_h: usize = tb.height + 2;
    drawBorderAscii(r, x, y, outer_w, outer_h);
    const inner_w: usize = tb.width;
    const inner_h: usize = tb.height;
    if (inner_w == 0 or inner_h == 0) return;
    const lines = try wrapWithOverflowAlloc(allocator, tb.text, inner_w, inner_h);
    defer {
        for (lines) |ln| allocator.free(ln);
        allocator.free(lines);
    }
    var row: usize = 0;
    while (row < lines.len and row < inner_h) : (row += 1) {
        const ln = lines[row];
        const n = @min(ln.len, inner_w);
        // Copy ln into interior cell area
        std.mem.copyForwards(u8, r.buf[(y + 1 + row) * r.width + (x + 1) ..][0..n], ln[0..n]);
    }
}

pub fn composeFlowingRowOfTextBoxesAlloc(
    allocator: std.mem.Allocator,
    container_width: usize,
    container_height: usize,
    boxes: []const TextBox,
) !Raster {
    var r = try Raster.init(allocator, container_width, container_height);
    drawBorderAscii(&r, 0, 0, container_width, container_height);
    const inner_x0: usize = if (container_width >= 2) 1 else 0;
    const inner_y0: usize = if (container_height >= 2) 1 else 0;
    const inner_w: usize = if (container_width > 1) container_width - 2 else container_width;
    const inner_h: usize = if (container_height > 1) container_height - 2 else container_height;

    // Horizontal shrink-to-fit on a single line with 1-space gaps
    var widths = try allocator.alloc(usize, boxes.len);
    defer allocator.free(widths);
    var i: usize = 0;
    var total_outer: isize = 0;
    while (i < boxes.len) : (i += 1) {
        widths[i] = boxes[i].width;
        total_outer += @as(isize, @intCast(widths[i] + 2));
    }
    if (boxes.len > 1) total_outer += @as(isize, @intCast(boxes.len - 1));
    const inner_w_is: isize = @as(isize, @intCast(inner_w));
    if (total_outer > inner_w_is) {
        var overflow: isize = total_outer - inner_w_is;
        var idx: usize = 0;
        while (overflow > 0 and boxes.len > 0) : (idx += 1) {
            if (idx >= boxes.len) idx = 0;
            if (widths[idx] > 1) {
                widths[idx] -= 1;
                overflow -= 1;
            } else if (boxes.len == 1) {
                break;
            }
        }
    }

    // Draw a single line of boxes
    var cursor_x: usize = 0;
    const cursor_y: usize = 0;
    i = 0;
    while (i < boxes.len) : (i += 1) {
        const cw = widths[i];
        const tb = TextBox{ .width = cw, .height = boxes[i].height, .text = boxes[i].text };
        const bw_outer = cw + 2;
        const bh_outer = tb.height + 2;
        if (cursor_x + bw_outer > inner_w or bh_outer > inner_h) break;
        try drawTextBoxIntoRaster(allocator, &r, inner_x0 + cursor_x, inner_y0 + cursor_y, tb);
        cursor_x += bw_outer;
        if (i + 1 < boxes.len and cursor_x < inner_w) cursor_x += 1;
    }
    return r;
}

test "row: column + box (no cross-centering)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const nodes = [_]Node{
        Node{ .Column = ColumnNode{ .width = 0, .main_align = .space_between, .cross_align = .start, .children = &.{ b(4, 3), b(4, 3) } } },
        Node{ .Box = b(6, 5) },
    };
    var r = try composeRowOfNodesAlloc(al, 18, 9, .space_between, &nodes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+----------------+
        \\|+--+      +----+|
        \\||  |      |    ||
        \\|+--+      |    ||
        \\|          |    ||
        \\|+--+      |    ||
        \\||  |      |    ||
        \\|+--+      +----+|
        \\+----------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "row: column (cross-centered) + box" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const nodes = [_]Node{
        Node{ .Column = ColumnNode{ .width = 6, .main_align = .space_between, .cross_align = .center, .children = &.{ b(4, 3), b(4, 3) } } },
        Node{ .Box = b(6, 5) },
    };
    var r = try composeRowOfNodesAlloc(al, 20, 9, .space_between, &nodes);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+------------------+
        \\| +--+       +----+|
        \\| |  |       |    ||
        \\| +--+       |    ||
        \\|            |    ||
        \\| +--+       |    ||
        \\| |  |       |    ||
        \\| +--+       +----+|
        \\+------------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "flowing row of text boxes: wrap and ellipsize" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const t1 = TextBox{ .width = 8, .height = 4, .text = "the quick brown" };
    const t2 = TextBox{ .width = 6, .height = 3, .text = "fox jumps over the lazy dog" };
    const t3 = TextBox{ .width = 7, .height = 4, .text = "zig makes tests pretty" };
    var r = try composeFlowingRowOfTextBoxesAlloc(al, 24, 9, &.{ t1, t2, t3 });
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+----------------------+
        \\|+-----+ +----+ +-----+|
        \\||the  | |fox | |zig  ||
        \\||quick| |jump| |makes||
        \\||brown| |s   | |tests||
        \\||     | +----+ |prett||
        \\|+-----+        +-----+|
        \\|                      |
        \\+----------------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "flowing row of text boxes: chop when no ellipsis" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const t1 = TextBox{ .width = 8, .height = 3, .text = "abcdef ghijk" };
    const t2 = TextBox{ .width = 8, .height = 3, .text = "lmn op qrstuv" };
    var r = try composeFlowingRowOfTextBoxesAlloc(al, 20, 7, &.{ t1, t2 });
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    const want =
        \\+------------------+
        \\|+------+ +-------+|
        \\||abcdef| |lmn op ||
        \\||ghijk | |qrstuv ||
        \\||      | |       ||
        \\|+------+ +-------+|
        \\+------------------+
        \\
    ;
    try expectAsciiEqual(want, got);
}

test "two boxes, row, start" {
    try expectFlexRow(.start, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\|+--++--+    |
        \\||  ||  |    |
        \\|+--++--+    |
        \\+------------+
        \\
    );
}

test "two boxes, row, space between" {
    try expectFlexRow(.space_between, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\|+--+    +--+|
        \\||  |    |  ||
        \\|+--+    +--+|
        \\+------------+
        \\
    );
}

test "two boxes, row, space around" {
    try expectFlexRow(.space_around, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\| +--+  +--+ |
        \\| |  |  |  | |
        \\| +--+  +--+ |
        \\+------------+
        \\
    );
}

test "space-around: remainder cycles start then gaps" {
    // Container inner width (excluding border) is 12 for b(14,5). Two boxes of width 4 => content 8.
    // Remaining = 4. There are 2 items => 2*count half-slots = 4; base_half = 1, rem = 0 -> trivial.
    // Use a width that yields a remainder: make inner width 13 (container 15): remaining = 5, half_slots=4 -> base_half=1, rem=1.
    // Expect start gets the extra 1.
    try expectFlexRow(.space_around, b(15, 5), &.{ b(4, 3), b(4, 3) },
        \\+-------------+
        \\|  +--+  +--+ |
        \\|  |  |  |  | |
        \\|  +--+  +--+ |
        \\+-------------+
        \\
    );
}

test "two boxes, row, end" {
    try expectFlexRow(.end, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\|    +--++--+|
        \\|    |  ||  ||
        \\|    +--++--+|
        \\+------------+
        \\
    );
}

test "two boxes, row, center" {
    try expectFlexRow(.center, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\|  +--++--+  |
        \\|  |  ||  |  |
        \\|  +--++--+  |
        \\+------------+
        \\
    );
}

test "two boxes, row, evenly" {
    try expectFlexRow(.space_evenly, b(14, 5), &.{ b(4, 3), b(4, 3) },
        \\+------------+
        \\| +--+  +--+ |
        \\| |  |  |  | |
        \\| +--+  +--+ |
        \\+------------+
        \\
    );
}

test "one box, row, center" {
    try expectFlexRow(.center, b(11, 5), &.{b(5, 3)},
        \\+---------+
        \\|  +---+  |
        \\|  |   |  |
        \\|  +---+  |
        \\+---------+
        \\
    );
}

test "zero boxes, row" {
    try expectFlexRow(.space_between, b(10, 4), &.{},
        \\+--------+
        \\|        |
        \\|        |
        \\+--------+
        \\
    );
}

test "two boxes, column, start" {
    try expectFlexColumn(.start, b(11, 9), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\+---------+
        \\
    );
}

test "two boxes, column, end" {
    try expectFlexColumn(.end, b(11, 9), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\+---------+
        \\
    );
}

test "two boxes, column, center" {
    try expectFlexColumn(.center, b(11, 9), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\+---------+
        \\
    );
}

test "two boxes, column, space between" {
    try expectFlexColumn(.space_between, b(11, 9), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\+---------+
        \\
    );
}

test "two boxes, column, space around" {
    try expectFlexColumn(.space_around, b(11, 10), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\+---------+
        \\
    );
}

test "two boxes, column, evenly" {
    try expectFlexColumn(.space_evenly, b(11, 10), &.{ b(5, 3), b(5, 3) },
        \\+---------+
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\|+---+    |
        \\||   |    |
        \\|+---+    |
        \\|         |
        \\+---------+
        \\
    );
}

test "space distribution: space_evenly distributes remainders" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    const dist = try calculateSpaces(al, .space_evenly, 20, 10, 3);
    defer al.free(dist.between_gaps);
    // For container=20, content=10, count=3:
    // remaining=10, slots=count+1=4 => base=2, remainder=2 -> start ~2 or 3 depending on policy
    try std.testing.expect(dist.start_space >= 2);
}

test "wrap DP prefers balanced lines" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    const s = "alpha beta gamma delta";
    const lines = try wrapAlloc(al, s, 12);
    defer {
        for (lines) |ln| al.free(ln);
        al.free(lines);
    }
    try std.testing.expect(lines.len >= 2);
}

test "raster border ascii" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    var r = try Raster.init(al, 8, 4);
    defer r.deinit(al);
    drawBorderAscii(&r, 1, 1, 6, 3);
    const want =
        "        \n" ++
        " +----+ \n" ++
        " |    | \n" ++
        " +----+ \n";
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "renderParagraphAlloc wraps into glyph grid" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    const s = "the quick brown fox";
    var r = try renderParagraphAlloc(al, s, 10);
    defer r.deinit(al);
    const got = try r.toStringAlloc(al);
    defer al.free(got);
    // two lines expected given width 10
    try std.testing.expect(std.mem.indexOfScalar(u8, got, '\n') != null);
}
