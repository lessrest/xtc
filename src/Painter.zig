const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const Unicode = @import("unicode.zig");
const StyleRow = @import("style.zig").StyleRow;
const StyleJustify = @import("style.zig").StyleJustify;
const ansi = @import("ansi");
const Trace = ansi.FileTrace;
const GlyphTable = @import("GlyphTable.zig");
const GlyphId = GlyphTable.GlyphId;
const paint = @import("paint.zig");
const Rgba8 = paint.Rgba8;
const rgba8 = paint.rgba8;
const PaintOp = paint.PaintOp;

pub const Painter = struct {
    allocator: std.mem.Allocator,
    ops: std.ArrayList(PaintOp),
    unicode: *const Unicode,
    trace: *Trace,

    pub fn init(
        allocator: std.mem.Allocator,
        unicode: *const Unicode,
        trace: *Trace,
    ) Painter {
        return .{
            .allocator = allocator,
            .ops = std.ArrayList(PaintOp){},
            .unicode = unicode,
            .trace = trace,
        };
    }

    pub fn deinit(self: *Painter) void {
        for (self.ops.items) |op| switch (op) {
            .GlyphRun => |gr| {
                self.allocator.free(gr.glyphs);
            },
            else => {},
        };
        self.ops.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *Painter, op: PaintOp) !void {
        try self.ops.append(self.allocator, op);
    }

    pub fn computePaintCommands(
        self: *Painter,
        document: *const dom.Dom,
        tree: *const layout.BoxTree,
        glyphs: *GlyphTable,
    ) !void {
        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Computing paint commands for display list");
        self.trace.fields("paint-start", .{
            .node_count = tree.nodeCount(),
            .initial_op_count = self.ops.items.len,
        });

        // Painting order follows CSS background, borders, then content (text). Stacking contexts are out of scope here.

        var painted_nodes: usize = 0;
        var skipped_nodes: usize = 0;

        var i: usize = 0;
        while (i < tree.nodeCount()) : (i += 1) {
            const h = tree.getNode(@as(u32, @intCast(i)));
            const row = document.getNodeStyle(h.data.dom_id);
            const node_kind = document.getNodeKind(h.data.dom_id);

            var node_id_buf: [32]u8 = undefined;
            const debug_id = document.getDebugIdOrDefault(h.data.dom_id, &node_id_buf);

            self.trace.enter();
            defer self.trace.exit();
            self.trace.info("Painting node");
            self.trace.fields("node-info", .{
                .index = i,
                .id = debug_id,
                .kind = node_kind,
                .original = h.data.rect,
            });

            // Find scroll container parent and apply scroll offset
            var paint_rect = h.data.rect;
            var is_scrolled = false;

            // Check if this node has a scroll container parent
            if (h.getParentNode(tree)) |parent_node| {
                const parent_row = document.getNodeStyle(parent_node.data.dom_id);

                if (parent_row.overflow_y == .scroll) {
                    is_scrolled = true;
                    const scroll_offset = parent_node.data.scroll_offset_y;
                    self.trace.decision("Node is in scroll container, applying scroll offset");
                    self.trace.fields("scroll-offset", .{
                        .offset = scroll_offset,
                    });

                    // Apply scroll offset: move content up by scroll amount
                    if (paint_rect.y >= scroll_offset) {
                        paint_rect.y -= scroll_offset;
                        self.trace.fields("adjusted", .{
                            .rect = paint_rect,
                        });
                    } else {
                        // Content is scrolled out of view at the top
                        self.trace.decision("Content scrolled out of view at top, skipping");
                        skipped_nodes += 1;
                        continue;
                    }

                    // Set up clipping rectangle to viewport
                    const parent_content_rect = layout.computeInnerContentRect(parent_row, parent_node.data.rect);
                    self.trace.fields("viewport", .{
                        .rect = parent_content_rect,
                    });

                    // Skip if entirely outside viewport
                    if (paint_rect.y >= parent_content_rect.y + parent_content_rect.h or
                        paint_rect.y + paint_rect.h <= parent_content_rect.y)
                    {
                        self.trace.decision("Content outside viewport bounds, skipping");
                        skipped_nodes += 1;
                        continue;
                    }
                }
            }

            if (!is_scrolled) {
                self.trace.fields("adjusted", .{
                    .rect = paint_rect,
                });
            }

            const ops_before = self.ops.items.len;

            self.trace.enter();
            defer self.trace.exit();
            self.trace.info("Emitting paint ops");

            try self.emitGlyphTileFill(glyphs, paint_rect, row);
            try self.emitBackgroundFillIfAny(paint_rect, row);
            try self.emitBorderStrokeIfAny(paint_rect, row);

            if (node_kind == .text) {
                try self.emitTextGlyphRuns(document, h.data.dom_id, paint_rect, row, glyphs);
            }

            const ops_after = self.ops.items.len;
            const ops_added = ops_after - ops_before;
            self.trace.fields("ops-added", .{
                .ops_added = ops_added,
            });

            if (ops_added > 0) {
                painted_nodes += 1;
            }
        }

        self.trace.fields("paint-end", .{
            .painted_nodes = painted_nodes,
            .skipped_nodes = skipped_nodes,
            .final_op_count = self.ops.items.len,
        });
    }

    fn emitGlyphTileFill(self: *Painter, glyphs: *GlyphTable, rect: layout.Rect, row: StyleRow) !void {
        if (!(row.fill_glyph != 0 and rect.w > 0 and rect.h > 0)) return;

        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Emitting glyph tile fill");

        const gid: GlyphId = row.fill_glyph;
        const str = glyphs.getSlice(gid);

        const color = rgba8(row.fg.r, row.fg.g, row.fg.b, 255);
        self.trace.fields("glyph-tile-fill", .{
            .rect = rect,
            .text = str,
            .color = color,
        });

        try self.push(PaintOp{ .FillGlyphRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .glyph = gid, .color = color } });
    }

    fn emitBackgroundFillIfAny(self: *Painter, rect: layout.Rect, row: StyleRow) !void {
        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Emitting background fill");

        if (row.bg.use_default == 0 and rect.w > 0 and rect.h > 0) {
            const color = rgba8(row.bg.r, row.bg.g, row.bg.b, 255);
            self.trace.fields("fill-rect", .{
                .rect = rect,
                .color = color,
            });
            self.trace.decision("Background color specified, adding FillRect op");
            try self.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = color } });
        } else {
            self.trace.decision("No background fill needed");
        }
    }

    fn emitBorderBlock(self: *Painter, rect: layout.Rect, color: Rgba8, thickness: usize) !void {
        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Emitting block border");
        self.trace.fields("border-block", .{
            .rect = rect,
            .color = color,
            .thickness = thickness,
        });

        if (rect.w == 0 or rect.h == 0 or thickness == 0) {
            self.trace.decision("Zero rect or thickness, skipping border");
            return;
        }

        const t = @min(thickness, @min(rect.w, rect.h));
        _ = self.trace.put("effective thickness", t);

        // Top band
        self.trace.decision("Adding top border band");
        try self.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t, .color = color } });

        // Bottom band
        if (rect.h > t) {
            self.trace.decision("Adding bottom border band");
            try self.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y + rect.h - t, .w = rect.w, .h = t, .color = color } });
        }

        // Side bands (avoid double-filling corners if height <= 2*t, harmless otherwise)
        const inner_h = if (rect.h > 2 * t) rect.h - 2 * t else 0;
        _ = self.trace.put("inner height", inner_h);

        if (inner_h > 0) {
            self.trace.decision("Adding left border band");
            try self.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y + t, .w = t, .h = inner_h, .color = color } });
            if (rect.w > t) {
                self.trace.decision("Adding right border band");
                try self.push(PaintOp{ .FillRect = .{ .x = rect.x + rect.w - t, .y = rect.y + t, .w = t, .h = inner_h, .color = color } });
            }
        }
    }

    fn emitBorderStrokeIfAny(self: *Painter, rect: layout.Rect, row: StyleRow) !void {
        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Emitting border stroke");

        if (!(row.border.width > 0 and rect.w > 0 and rect.h > 0)) {
            self.trace.decision("No border needed");
            return;
        }
        self.trace.fields("border-stroke", .{
            .rect = rect,
            .border_width = row.border.width,
            .border_style = @tagName(row.border.style),
        });

        const col: Rgba8 = blk: {
            if (row.border_color.use_default == 0) {
                self.trace.decision("Using explicit border color");
                break :blk rgba8(row.border_color.r, row.border_color.g, row.border_color.b, 255);
            }
            if (row.fg.use_default == 0) {
                self.trace.decision("Falling back to foreground color for border");
                break :blk rgba8(row.fg.r, row.fg.g, row.fg.b, 255);
            }
            self.trace.decision("Using default white color for border");
            break :blk rgba8(255, 255, 255, 255);
        };

        const bg_for_border: ?Rgba8 = if (row.bg.use_default == 0)
            rgba8(row.bg.r, row.bg.g, row.bg.b, 255)
        else
            null;

        self.trace.fields("border-colors", .{
            .border_color = col,
            .background_color = bg_for_border,
        });

        switch (row.border.style) {
            .block => {
                self.trace.decision("Using block border style");
                try self.emitBorderBlock(rect, col, row.border.width);
            },
            .solid => {
                self.trace.decision("Using solid line border style");
                try self.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_light, .bg_color = bg_for_border } });
            },
            .double => {
                self.trace.decision("Using double line border style");
                try self.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_double, .bg_color = bg_for_border } });
            },
            .dashed => {
                self.trace.decision("Using dashed line border style");
                try self.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_dashed, .bg_color = bg_for_border } });
            },
            .none => {
                self.trace.decision("Border style is none, no border to emit");
            },
        }
    }

    const ContentBox = struct {
        rect: layout.Rect,
        inset_left: usize,
        inset_top: usize,
    };

    fn computeContentBox(rect: layout.Rect, row: StyleRow) ContentBox {
        const border_w: usize = @as(usize, @intCast(row.border.width));
        const pad_l: usize = @as(usize, @intCast(row.padding.l));
        const pad_r: usize = @as(usize, @intCast(row.padding.r));
        const pad_t: usize = @as(usize, @intCast(row.padding.t));
        const pad_b: usize = @as(usize, @intCast(row.padding.b));
        const base_inset: usize = if (border_w > 0) 1 else 0;
        const inset_left = base_inset + pad_l;
        const inset_right = base_inset + pad_r;
        const inset_top = base_inset + pad_t;
        const inset_bottom = base_inset + pad_b;
        const content_w: usize = if (rect.w > inset_left + inset_right) rect.w - (inset_left + inset_right) else 0;
        const content_h: usize = if (rect.h > inset_top + inset_bottom) rect.h - (inset_top + inset_bottom) else 0;
        return .{
            .rect = .{ .x = rect.x, .y = rect.y, .w = content_w, .h = content_h },
            .inset_left = inset_left,
            .inset_top = inset_top,
        };
    }

    fn resolveEffectiveFgBg(dref: *const dom.Dom, node_id: dom.DomNodeId) struct { fg: ?Rgba8, bg: ?Rgba8 } {
        var items = dref.headers.slice();
        var cur: dom.DomNodeId = node_id;
        var eff_fg: ?Rgba8 = null;
        var eff_bg: ?Rgba8 = null;
        while (true) {
            const sid = items.items(.style_id)[@as(usize, @intCast(cur))];
            const row = dref.styles.cols.items[@intCast(sid)];
            if (eff_fg == null and row.fg.use_default == 0) {
                eff_fg = rgba8(row.fg.r, row.fg.g, row.fg.b, 255);
            }
            if (eff_bg == null and row.bg.use_default == 0) {
                eff_bg = rgba8(row.bg.r, row.bg.g, row.bg.b, 255);
            }
            const p = items.items(.parent)[@as(usize, @intCast(cur))];
            if (p == dom.Dom.NullId) break;
            cur = p;
        }
        return .{ .fg = eff_fg, .bg = eff_bg };
    }

    fn computeTextColor(document: *const dom.Dom, node_id: dom.DomNodeId, row: StyleRow) Rgba8 {
        const eff = resolveEffectiveFgBg(document, node_id);
        const base_fg: Rgba8 = eff.fg orelse rgba8(255, 255, 255, 255);
        const base_bg: Rgba8 = eff.bg orelse rgba8(255, 255, 255, 255);
        return if (row.text_flags.inverse == 1) base_bg else base_fg;
    }

    fn computeJustifyOffset(content_w: usize, line_w_cols: usize, justify: StyleJustify) usize {
        if (line_w_cols >= content_w) return 0;
        return switch (justify) {
            .start => 0,
            .center => (content_w - line_w_cols) / 2,
            .end => content_w - line_w_cols,
            else => 0,
        };
    }

    fn buildGlyphRun(
        self: *Painter,
        glyphs: *GlyphTable,
        text_bytes: []const u8,
        max_width_cols: usize,
        truncate_to_fit: bool,
    ) !struct { run: []GlyphId, width_cols: usize } {
        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Building glyph run from text");
        self.trace.fields("glyph-run-params", .{
            .text_length = text_bytes.len,
            .max_width_cols = max_width_cols,
            .truncate_to_fit = truncate_to_fit,
        });

        var glyph_ids = std.ArrayList(GlyphId){};
        defer glyph_ids.deinit(self.allocator);

        var grapheme_iter = self.unicode.graphemeClusterIterator(text_bytes);
        var accumulated_width: usize = 0;
        var grapheme_count: usize = 0;

        while (grapheme_iter.next()) |grapheme_cluster| {
            const grapheme_bytes = grapheme_cluster.bytes(text_bytes);
            const grapheme_width = self.unicode.monospacedTextWidth(grapheme_bytes);
            grapheme_count += 1;

            if (truncate_to_fit and accumulated_width + grapheme_width > max_width_cols) {
                self.trace.decision("Truncating text to fit available width");
                self.trace.fields("truncation-point", .{
                    .stopped_at_grapheme = grapheme_count,
                    .accumulated_width = accumulated_width,
                });
                break;
            }

            accumulated_width += grapheme_width;
            const glyph_id = try glyphs.intern(self.allocator, grapheme_bytes);
            try glyph_ids.append(self.allocator, glyph_id);
        }

        self.trace.fields("glyph-run-stats", .{
            .processed_graphemes = grapheme_count,
            .final_glyph_count = glyph_ids.items.len,
            .accumulated_width = accumulated_width,
        });

        if (glyph_ids.items.len == 0) {
            self.trace.decision("Empty text result, returning empty glyph run");
            return .{ .run = &[_]GlyphId{}, .width_cols = 0 };
        }

        const final_run = try self.allocator.alloc(GlyphId, glyph_ids.items.len);
        std.mem.copyForwards(GlyphId, final_run, glyph_ids.items);

        const final_width_cols: usize = if (truncate_to_fit)
            accumulated_width
        else
            self.unicode.monospacedTextWidth(text_bytes);

        self.trace.fields("glyph-run-final-width", .{
            .final_width_cols = final_width_cols,
        });

        return .{ .run = final_run, .width_cols = final_width_cols };
    }

    fn emitTextGlyphRuns(
        self: *Painter,
        document: *const dom.Dom,
        node_id: dom.DomNodeId,
        rect: layout.Rect,
        row: StyleRow,
        glyphs: *GlyphTable,
    ) !void {
        self.trace.enter();
        defer self.trace.exit();
        self.trace.info("Emitting text glyph runs");

        if (!(rect.w > 0 and rect.h > 0)) {
            self.trace.decision("Zero rect dimensions, no text to emit");
            return;
        }

        const slice = document.getTextSlice(node_id);
        const cb = computeContentBox(rect, row);
        const color = computeTextColor(document, node_id, row);
        self.trace.fields("text-render", .{
            .content_box = cb.rect,
            .text_color = color,
            .text_length = slice.len,
            .rect = rect,
        });

        if (cb.rect.w == 0 or cb.rect.h == 0) {
            self.trace.decision("Zero content box dimensions, no space for text");
            return;
        }

        var y_offset: usize = 0;
        var total_lines_processed: usize = 0;
        var total_glyph_runs_emitted: usize = 0;

        // First split by newlines
        var line_iter = std.mem.tokenizeScalar(u8, slice, '\n');
        while (line_iter.next()) |line| {
            if (y_offset >= cb.rect.h) {
                self.trace.decision("Reached content box height limit, stopping line processing");
                break;
            }

            total_lines_processed += 1;

            self.trace.enter();
            defer self.trace.exit();
            self.trace.info("Processing text line");
            self.trace.fields("text-line", .{
                .line_number = total_lines_processed,
                .line_length = line.len,
                .y_offset = y_offset,
            });

            // For each line, apply word wrapping if needed
            var line_start: usize = 0;
            var line_width: usize = 0;
            var last_break_bytes: ?usize = null;
            var witer = self.unicode.wordIterator(line);
            var wrapped_segments: usize = 0;

            while (witer.next()) |seg| {
                const bytes = seg.bytes(line);
                const seg_w = self.unicode.monospacedTextWidth(bytes);

                if (line_width + seg_w > cb.rect.w and line_width > 0) {
                    // Emit the current wrapped line
                    wrapped_segments += 1;
                    self.trace.fields("wrapped-segment", .{
                        .wrapped_segment = wrapped_segments,
                        .current_line_width = line_width,
                    });

                    const line_bytes_end = last_break_bytes orelse seg.offset;
                    const line_bytes = line[line_start..line_bytes_end];
                    const shaped = try self.buildGlyphRun(glyphs, line_bytes, cb.rect.w, false);

                    if (shaped.run.len > 0) {
                        const extra = computeJustifyOffset(cb.rect.w, shaped.width_cols, row.justify);
                        self.trace.fields("justify-offset", .{
                            .justify_offset = extra,
                        });

                        try self.push(PaintOp{ .GlyphRun = .{
                            .x = rect.x + cb.inset_left + extra,
                            .y = rect.y + cb.inset_top + y_offset,
                            .glyphs = shaped.run,
                            .color = color,
                        } });
                        total_glyph_runs_emitted += 1;
                    }

                    y_offset += 1;
                    if (y_offset >= cb.rect.h) {
                        self.trace.decision("Reached height limit during wrapping");
                        break;
                    }
                    line_start = seg.offset;
                    line_width = seg_w;
                    last_break_bytes = seg.offset + seg.len;
                    continue;
                }
                line_width += seg_w;
                last_break_bytes = seg.offset + seg.len;
            }

            // Emit the remainder of this line (after wrapping)
            if (line_start < line.len and y_offset < cb.rect.h) {
                self.trace.fields("final-line-segment", .{
                    .remaining_text_length = line.len - line_start,
                });

                const line_bytes = line[line_start..];
                const shaped = try self.buildGlyphRun(glyphs, line_bytes, cb.rect.w, true);

                if (shaped.run.len > 0) {
                    const extra = computeJustifyOffset(cb.rect.w, shaped.width_cols, row.justify);
                    try self.push(PaintOp{ .GlyphRun = .{
                        .x = rect.x + cb.inset_left + extra,
                        .y = rect.y + cb.inset_top + y_offset,
                        .glyphs = shaped.run,
                        .color = color,
                    } });
                    total_glyph_runs_emitted += 1;
                }
                y_offset += 1;
            }

            self.trace.fields("wrapped-segments", .{
                .wrapped_segments = wrapped_segments,
            });
        }

        self.trace.fields("text-emission-stats", .{
            .total_lines_processed = total_lines_processed,
            .total_glyph_runs_emitted = total_glyph_runs_emitted,
            .final_y_offset = y_offset,
        });
    }
};

// --- Tests ---

test "stroke rect command renders unicode box-drawing characters to the raster" {
    const Raster = @import("Raster.zig");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();

    var r = try Raster.init(al, 10, 6);
    defer r.deinit(al);
    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    var unicode = try Unicode.init(al);
    defer unicode.deinit(al);

    var trace = ansi.silentTrace(al);
    var painter = Painter.init(al, &unicode, &trace);
    defer painter.deinit();

    try painter.push(PaintOp{
        .StrokeRect = .{
            .x = 2,
            .y = 1,
            .w = 6,
            .h = 4,
            .color = rgba8(255, 255, 255, 255),
            .style = .line_light,
            .bg_color = rgba8(0, 0, 0, 255),
        },
    });

    try r.rasterizeDisplayList(al, glyphs, &painter);
    const got = try r.plainTextDump(al, glyphs);
    defer al.free(got);

    const want =
        "          \n" ++
        "  ┌────┐  \n" ++
        "  │    │  \n" ++
        "  │    │  \n" ++
        "  └────┘  \n" ++
        "          \n";
    try std.testing.expectEqualStrings(want, got);
}

test "text nodes inherit foreground color from their parent element's style" {
    const tailwind = @import("tailwind.zig");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var d = try dom.Dom.init(al);
    defer d.deinit();
    const root = try d.addElement("text-blue-200");
    const txt = try d.addText("A");
    try d.appendChild(root, txt);

    var tree = try layout.allocateBoxTreeFromDOM(al, d, root);
    defer tree.deinit();

    // Perform layout so text node gets a non-zero rect
    var unicode = try Unicode.init(al);
    defer unicode.deinit(al);
    var trace = ansi.silentTrace(al);
    var layout_engine = @import("layout.zig").init(al, &unicode, &trace);
    try layout_engine.layoutSubtree(
        &tree,
        d,
        tree.getNodeMut(0),
        .{ .x = 0, .y = 0, .w = 10, .h = 3 },
    );

    var glyphs = try GlyphTable.init(al);
    defer glyphs.deinit();
    var painter = Painter.init(al, &unicode, &trace);
    defer painter.deinit();
    try painter.computePaintCommands(d, &tree, glyphs);

    var found = false;
    var got: Rgba8 = undefined;
    for (painter.ops.items) |op| switch (op) {
        .GlyphRun => |gr| {
            got = gr.color;
            found = true;
            break;
        },
        else => {},
    };
    try std.testing.expect(found);

    const sr = tailwind.parseUtilityClassList("text-blue-200");
    const rgb = tailwind.get_fg_rgb(sr) orelse return error.TestExpectedFg;
    const want: Rgba8 = rgba8(rgb[0], rgb[1], rgb[2], 255);
    try std.testing.expectEqual(want, got);
}
