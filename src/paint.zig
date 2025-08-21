const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const Unicode = @import("unicode.zig");
const tailwind = @import("tailwind.zig");
const StyleRow = @import("style.zig").StyleRow;
const StyleOverflow = @import("style.zig").StyleOverflow;
const BorderStyle = @import("style.zig").BorderStyle;
const StyleJustify = @import("style.zig").StyleJustify;
const ansi = @import("ansi");
const Trace = ansi.FileTrace;
const GlyphTable = @import("GlyphTable.zig");
const GlyphId = GlyphTable.GlyphId;
const Raster = @import("Raster.zig");

// --- Paint stage: device-independent display list ---

/// RGBA color packed into a u32: 0xAABBGGRR (little-endian layout)
pub const Rgba8 = u32;

/// Create an Rgba8 color from individual components
pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Rgba8 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

/// Extract red component from Rgba8
pub fn rgba8Red(color: Rgba8) u8 {
    return @truncate(color);
}

/// Extract green component from Rgba8
pub fn rgba8Green(color: Rgba8) u8 {
    return @truncate(color >> 8);
}

/// Extract blue component from Rgba8
pub fn rgba8Blue(color: Rgba8) u8 {
    return @truncate(color >> 16);
}

/// Extract alpha component from Rgba8
pub fn rgba8Alpha(color: Rgba8) u8 {
    return @truncate(color >> 24);
}

fn mul255(x: u32, y: u32) u8 {
    // (x*y)/255 with rounding, inputs 0..255
    const prod: u32 = x * y + 127;
    return @intCast((prod + (prod >> 8)) >> 8);
}

pub fn blendOver(dst: *Rgba8, src: Rgba8) void {
    // Porter-Duff SrcOver for straight (non-premultiplied) 8-bit RGBA
    const as: u8 = rgba8Alpha(src);
    const ad: u8 = rgba8Alpha(dst.*);
    const one_minus_as: u8 = 255 - as;
    const out_a: u8 = as + mul255(ad, one_minus_as);
    if (out_a == 0) {
        dst.* = rgba8(0, 0, 0, 0);
        return;
    }
    // Premultiplied channel blend
    const dst_scale: u8 = mul255(ad, one_minus_as);
    const cp_r: u16 = @as(u16, mul255(rgba8Red(src), as)) + @as(u16, mul255(rgba8Red(dst.*), dst_scale));
    const cp_g: u16 = @as(u16, mul255(rgba8Green(src), as)) + @as(u16, mul255(rgba8Green(dst.*), dst_scale));
    const cp_b: u16 = @as(u16, mul255(rgba8Blue(src), as)) + @as(u16, mul255(rgba8Blue(dst.*), dst_scale));
    // Un-premultiply
    const oa: u16 = out_a;
    const out_r: u8 = @intCast((cp_r * 255 + oa / 2) / oa);
    const out_g: u8 = @intCast((cp_g * 255 + oa / 2) / oa);
    const out_b: u8 = @intCast((cp_b * 255 + oa / 2) / oa);
    dst.* = rgba8(out_r, out_g, out_b, out_a);
}

pub const PaintBorderStyle = enum {
    line_light,
    line_double,
    line_heavy,
    line_dashed,

    pub fn templateFor(style: PaintBorderStyle) BorderBox {
        return switch (style) {
            .line_light => .{ .grid = .{
                .{ "┌", "─", "┐" },
                .{ "│", " ", "│" },
                .{ "└", "─", "┘" },
            } },
            .line_heavy => .{ .grid = .{
                .{ "┏", "━", "┓" },
                .{ "┃", " ", "┃" },
                .{ "┗", "━", "┛" },
            } },
            .line_double => .{ .grid = .{
                .{ "╔", "═", "╗" },
                .{ "║", " ", "║" },
                .{ "╚", "═", "╝" },
            } },
            .line_dashed => .{ .grid = .{
                .{ "┌", "╌", "┐" },
                .{ "╎", " ", "╎" },
                .{ "└", "╌", "┘" },
            } },
        };
    }
};

const BorderBox = struct { grid: [3][3][]const u8 };

pub const PaintOpTag = enum { FillRect, StrokeRect, GlyphRun, FillGlyphRect };
pub const PaintOp = union(PaintOpTag) {
    FillRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8 },
    StrokeRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8, style: PaintBorderStyle, bg_color: ?Rgba8 = null },
    GlyphRun: struct { x: usize, y: usize, glyphs: []const GlyphId, color: Rgba8 },
    FillGlyphRect: struct { x: usize, y: usize, w: usize, h: usize, glyph: GlyphId, color: Rgba8 },
};

pub const PaintContext = struct {
    ops: std.ArrayList(PaintOp),
    unicode: *const Unicode,
    trace: *Trace,

    pub fn init(
        allocator: std.mem.Allocator,
        unicode: *const Unicode,
        trace: *Trace,
    ) PaintContext {
        return .{
            .ops = std.ArrayList(PaintOp).init(allocator),
            .unicode = unicode,
            .trace = trace,
        };
    }

    pub fn deinit(self: *PaintContext) void {
        self.ops.deinit();
        self.* = undefined;
    }

    pub fn push(self: *PaintContext, op: PaintOp) !void {
        try self.ops.append(op);
    }

    pub fn computePaintCommands(
        ctx: *PaintContext,
        document: *const dom.Dom,
        tree: *const layout.BoxTree,
        glyphs: *GlyphTable,
    ) !void {
        ctx.trace.enter();
        defer ctx.trace.exit();
        ctx.trace.info("Computing paint commands for display list");
        ctx.trace.fields("paint-start", .{
            .node_count = tree.nodeCount(),
            .initial_op_count = ctx.ops.items.len,
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

            ctx.trace.enter();
            defer ctx.trace.exit();
            ctx.trace.info("Painting node");
            ctx.trace.fields("node-info", .{
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
                    ctx.trace.decision("Node is in scroll container, applying scroll offset");
                    ctx.trace.fields("scroll-offset", .{
                        .offset = scroll_offset,
                    });

                    // Apply scroll offset: move content up by scroll amount
                    if (paint_rect.y >= scroll_offset) {
                        paint_rect.y -= scroll_offset;
                        ctx.trace.fields("adjusted", .{
                            .rect = paint_rect,
                        });
                    } else {
                        // Content is scrolled out of view at the top
                        ctx.trace.decision("Content scrolled out of view at top, skipping");
                        skipped_nodes += 1;
                        continue;
                    }

                    // Set up clipping rectangle to viewport
                    const parent_content_rect = layout.computeInnerContentRect(parent_row, parent_node.data.rect);
                    ctx.trace.fields("viewport", .{
                        .rect = parent_content_rect,
                    });

                    // Skip if entirely outside viewport
                    if (paint_rect.y >= parent_content_rect.y + parent_content_rect.h or
                        paint_rect.y + paint_rect.h <= parent_content_rect.y)
                    {
                        ctx.trace.decision("Content outside viewport bounds, skipping");
                        skipped_nodes += 1;
                        continue;
                    }
                }
            }

            if (!is_scrolled) {
                ctx.trace.fields("adjusted", .{
                    .rect = paint_rect,
                });
            }

            const ops_before = ctx.ops.items.len;

            ctx.trace.enter();
            defer ctx.trace.exit();
            ctx.trace.info("Emitting paint ops");

            try emitGlyphTileFill(ctx, glyphs, paint_rect, row);
            try emitBackgroundFillIfAny(ctx, paint_rect, row);
            try emitBorderStrokeIfAny(ctx, paint_rect, row);

            if (node_kind == .text) {
                try emitTextGlyphRuns(ctx, document, h.data.dom_id, paint_rect, row, glyphs);
            }

            const ops_after = ctx.ops.items.len;
            const ops_added = ops_after - ops_before;
            ctx.trace.fields("ops-added", .{
                .ops_added = ops_added,
            });

            if (ops_added > 0) {
                painted_nodes += 1;
            }
        }

        ctx.trace.fields("paint-end", .{
            .painted_nodes = painted_nodes,
            .skipped_nodes = skipped_nodes,
            .final_op_count = ctx.ops.items.len,
        });
    }
};

// No global rendering toggles here; the TTY backend chooses glyphs and fallbacks.
/// Resolve effective foreground/background color along DOM ancestry, per CSS color inheritance.
/// Nearest ancestor with an explicit value wins; returns null when no explicit color was found.
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

/// Helper: emit a uniform glyph tile fill across the box rect (testing/demo aid).
fn emitGlyphTileFill(ctx: *PaintContext, glyphs: *GlyphTable, rect: layout.Rect, row: StyleRow) !void {
    if (!(row.fill_glyph != 0 and rect.w > 0 and rect.h > 0)) return;

    ctx.trace.enter();
    defer ctx.trace.exit();
    ctx.trace.info("Emitting glyph tile fill");

    const gid: GlyphId = row.fill_glyph;
    const str = glyphs.getSlice(gid);

    const color = rgba8(row.fg.r, row.fg.g, row.fg.b, 255);
    ctx.trace.fields("glyph-tile-fill", .{
        .rect = rect,
        .text = str,
        .color = color,
    });

    try ctx.push(PaintOp{ .FillGlyphRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .glyph = gid, .color = color } });
}

/// Helper: background painting step per CSS painting order (backgrounds behind borders and content).
fn emitBackgroundFillIfAny(ctx: *PaintContext, rect: layout.Rect, row: StyleRow) !void {
    ctx.trace.enter();
    defer ctx.trace.exit();
    ctx.trace.info("Emitting background fill");

    if (row.bg.use_default == 0 and rect.w > 0 and rect.h > 0) {
        const color = rgba8(row.bg.r, row.bg.g, row.bg.b, 255);
        ctx.trace.fields("fill-rect", .{
            .rect = rect,
            .color = color,
        });
        ctx.trace.decision("Background color specified, adding FillRect op");
        try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = color } });
    } else {
        ctx.trace.decision("No background fill needed");
    }
}

/// Helper: border painting step. Color falls back to border_color, then fg, then white.
fn emitBorderBlock(ctx: *PaintContext, rect: layout.Rect, color: Rgba8, thickness: usize) !void {
    ctx.trace.enter();
    defer ctx.trace.exit();
    ctx.trace.info("Emitting block border");
    ctx.trace.fields("border-block", .{
        .rect = rect,
        .color = color,
        .thickness = thickness,
    });

    if (rect.w == 0 or rect.h == 0 or thickness == 0) {
        ctx.trace.decision("Zero rect or thickness, skipping border");
        return;
    }

    const t = @min(thickness, @min(rect.w, rect.h));
    _ = ctx.trace.put("effective thickness", t);

    // Top band
    ctx.trace.decision("Adding top border band");
    try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t, .color = color } });

    // Bottom band
    if (rect.h > t) {
        ctx.trace.decision("Adding bottom border band");
        try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y + rect.h - t, .w = rect.w, .h = t, .color = color } });
    }

    // Side bands (avoid double-filling corners if height <= 2*t, harmless otherwise)
    const inner_h = if (rect.h > 2 * t) rect.h - 2 * t else 0;
    _ = ctx.trace.put("inner height", inner_h);

    if (inner_h > 0) {
        ctx.trace.decision("Adding left border band");
        try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y + t, .w = t, .h = inner_h, .color = color } });
        if (rect.w > t) {
            ctx.trace.decision("Adding right border band");
            try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x + rect.w - t, .y = rect.y + t, .w = t, .h = inner_h, .color = color } });
        }
    }
}

fn emitBorderStrokeIfAny(ctx: *PaintContext, rect: layout.Rect, row: StyleRow) !void {
    ctx.trace.enter();
    defer ctx.trace.exit();
    ctx.trace.info("Emitting border stroke");

    if (!(row.border.width > 0 and rect.w > 0 and rect.h > 0)) {
        ctx.trace.decision("No border needed");
        return;
    }
    ctx.trace.fields("border-stroke", .{
        .rect = rect,
        .border_width = row.border.width,
        .border_style = @tagName(row.border.style),
    });

    const col: Rgba8 = blk: {
        if (row.border_color.use_default == 0) {
            ctx.trace.decision("Using explicit border color");
            break :blk rgba8(row.border_color.r, row.border_color.g, row.border_color.b, 255);
        }
        if (row.fg.use_default == 0) {
            ctx.trace.decision("Falling back to foreground color for border");
            break :blk rgba8(row.fg.r, row.fg.g, row.fg.b, 255);
        }
        ctx.trace.decision("Using default white color for border");
        break :blk rgba8(255, 255, 255, 255);
    };

    const bg_for_border: ?Rgba8 = if (row.bg.use_default == 0)
        rgba8(row.bg.r, row.bg.g, row.bg.b, 255)
    else
        null;

    ctx.trace.fields("border-colors", .{
        .border_color = col,
        .background_color = bg_for_border,
    });

    switch (row.border.style) {
        .block => {
            ctx.trace.decision("Using block border style");
            try emitBorderBlock(ctx, rect, col, row.border.width);
        },
        .solid => {
            ctx.trace.decision("Using solid line border style");
            try ctx.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_light, .bg_color = bg_for_border } });
        },
        .double => {
            ctx.trace.decision("Using double line border style");
            try ctx.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_double, .bg_color = bg_for_border } });
        },
        .dashed => {
            ctx.trace.decision("Using dashed line border style");
            try ctx.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_dashed, .bg_color = bg_for_border } });
        },
        .none => {
            ctx.trace.decision("Border style is none, no border to emit");
        },
    }
}

/// Helper: compute text content box (padding + 1-cell inset if border present) and emit wrapped glyph runs.
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
    ctx: *PaintContext,
    glyphs: *GlyphTable,
    text_bytes: []const u8,
    max_width_cols: usize,
    truncate_to_fit: bool,
) !struct { run: []GlyphId, width_cols: usize } {
    ctx.trace.enter();
    defer ctx.trace.exit();
    ctx.trace.info("Building glyph run from text");
    ctx.trace.fields("glyph-run-params", .{
        .text_length = text_bytes.len,
        .max_width_cols = max_width_cols,
        .truncate_to_fit = truncate_to_fit,
    });

    var glyph_ids = std.ArrayList(GlyphId).init(ctx.ops.allocator);
    defer glyph_ids.deinit();

    var grapheme_iter = ctx.unicode.graphemeClusterIterator(text_bytes);
    var accumulated_width: usize = 0;
    var grapheme_count: usize = 0;

    // Process each grapheme cluster in the text
    while (grapheme_iter.next()) |grapheme_cluster| {
        const grapheme_bytes = grapheme_cluster.bytes(text_bytes);
        const grapheme_width = ctx.unicode.monospacedTextWidth(grapheme_bytes);
        grapheme_count += 1;

        // Check if adding this grapheme would exceed the available width
        if (truncate_to_fit and accumulated_width + grapheme_width > max_width_cols) {
            ctx.trace.decision("Truncating text to fit available width");
            ctx.trace.fields("truncation-point", .{
                .stopped_at_grapheme = grapheme_count,
                .accumulated_width = accumulated_width,
            });
            break;
        }

        accumulated_width += grapheme_width;
        const glyph_id = try glyphs.intern(ctx.ops.allocator, grapheme_bytes);
        try glyph_ids.append(glyph_id);
    }

    ctx.trace.fields("glyph-run-stats", .{
        .processed_graphemes = grapheme_count,
        .final_glyph_count = glyph_ids.items.len,
        .accumulated_width = accumulated_width,
    });

    // Handle empty result
    if (glyph_ids.items.len == 0) {
        ctx.trace.decision("Empty text result, returning empty glyph run");
        return .{ .run = &[_]GlyphId{}, .width_cols = 0 };
    }

    // Allocate and copy the final glyph run
    const final_run = try ctx.ops.allocator.alloc(GlyphId, glyph_ids.items.len);
    std.mem.copyForwards(GlyphId, final_run, glyph_ids.items);

    // Calculate final width: use accumulated width if truncating, otherwise measure full text
    const final_width_cols: usize = if (truncate_to_fit)
        accumulated_width
    else
        ctx.unicode.monospacedTextWidth(text_bytes);

    ctx.trace.fields("glyph-run-final-width", .{
        .final_width_cols = final_width_cols,
    });

    return .{ .run = final_run, .width_cols = final_width_cols };
}

fn emitTextGlyphRuns(
    ctx: *PaintContext,
    document: *const dom.Dom,
    node_id: dom.DomNodeId,
    rect: layout.Rect,
    row: StyleRow,
    glyphs: *GlyphTable,
) !void {
    ctx.trace.enter();
    defer ctx.trace.exit();
    ctx.trace.info("Emitting text glyph runs");

    if (!(rect.w > 0 and rect.h > 0)) {
        ctx.trace.decision("Zero rect dimensions, no text to emit");
        return;
    }

    const slice = document.getTextSlice(node_id);
    const cb = computeContentBox(rect, row);
    const color = computeTextColor(document, node_id, row);
    ctx.trace.fields("text-render", .{
        .content_box = cb.rect,
        .text_color = color,
        .text_length = slice.len,
        .rect = rect,
    });

    if (cb.rect.w == 0 or cb.rect.h == 0) {
        ctx.trace.decision("Zero content box dimensions, no space for text");
        return;
    }

    var y_offset: usize = 0;
    var total_lines_processed: usize = 0;
    var total_glyph_runs_emitted: usize = 0;

    // First split by newlines
    var line_iter = std.mem.tokenizeScalar(u8, slice, '\n');
    while (line_iter.next()) |line| {
        if (y_offset >= cb.rect.h) {
            ctx.trace.decision("Reached content box height limit, stopping line processing");
            break;
        }

        total_lines_processed += 1;

        ctx.trace.enter();
        defer ctx.trace.exit();
        ctx.trace.info("Processing text line");
        ctx.trace.fields("text-line", .{
            .line_number = total_lines_processed,
            .line_length = line.len,
            .y_offset = y_offset,
        });

        // For each line, apply word wrapping if needed
        var line_start: usize = 0;
        var line_width: usize = 0;
        var last_break_bytes: ?usize = null;
        var witer = ctx.unicode.wordIterator(line);
        var wrapped_segments: usize = 0;

        while (witer.next()) |seg| {
            const bytes = seg.bytes(line);
            const seg_w = ctx.unicode.monospacedTextWidth(bytes);

            if (line_width + seg_w > cb.rect.w and line_width > 0) {
                // Emit the current wrapped line
                wrapped_segments += 1;
                ctx.trace.fields("wrapped-segment", .{
                    .wrapped_segment = wrapped_segments,
                    .current_line_width = line_width,
                });

                const line_bytes_end = last_break_bytes orelse seg.offset;
                const line_bytes = line[line_start..line_bytes_end];
                const shaped = try buildGlyphRun(ctx, glyphs, line_bytes, cb.rect.w, false);

                if (shaped.run.len > 0) {
                    const extra = computeJustifyOffset(cb.rect.w, shaped.width_cols, row.justify);
                    ctx.trace.fields("justify-offset", .{
                        .justify_offset = extra,
                    });

                    try ctx.push(PaintOp{ .GlyphRun = .{
                        .x = rect.x + cb.inset_left + extra,
                        .y = rect.y + cb.inset_top + y_offset,
                        .glyphs = shaped.run,
                        .color = color,
                    } });
                    total_glyph_runs_emitted += 1;
                }

                y_offset += 1;
                if (y_offset >= cb.rect.h) {
                    ctx.trace.decision("Reached height limit during wrapping");
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
            ctx.trace.fields("final-line-segment", .{
                .remaining_text_length = line.len - line_start,
            });

            const line_bytes = line[line_start..];
            const shaped = try buildGlyphRun(ctx, glyphs, line_bytes, cb.rect.w, true);

            if (shaped.run.len > 0) {
                const extra = computeJustifyOffset(cb.rect.w, shaped.width_cols, row.justify);
                try ctx.push(PaintOp{ .GlyphRun = .{
                    .x = rect.x + cb.inset_left + extra,
                    .y = rect.y + cb.inset_top + y_offset,
                    .glyphs = shaped.run,
                    .color = color,
                } });
                total_glyph_runs_emitted += 1;
            }
            y_offset += 1;
        }

        ctx.trace.fields("wrapped-segments", .{
            .wrapped_segments = wrapped_segments,
        });
    }

    ctx.trace.fields("text-emission-stats", .{
        .total_lines_processed = total_lines_processed,
        .total_glyph_runs_emitted = total_glyph_runs_emitted,
        .final_y_offset = y_offset,
    });
}

test "source-over alpha blending mixes foreground and background colors correctly" {
    var dst = rgba8(0, 0, 255, 255);
    const src = rgba8(255, 0, 0, 128);
    blendOver(&dst, src);
    // Expect purple-ish, full alpha
    try std.testing.expect(rgba8Red(dst) > 120 and rgba8Red(dst) < 140);
    try std.testing.expect(rgba8Blue(dst) > 120 and rgba8Blue(dst) < 140);
    try std.testing.expectEqual(@as(u8, 255), rgba8Alpha(dst));
}

test "stroke rect command renders unicode box-drawing characters to the raster" {
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
    var ctx = PaintContext.init(al, &unicode, &trace);
    defer ctx.deinit();

    try ctx.push(PaintOp{
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

    try r.rasterizeDisplayList(al, glyphs, &ctx);
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
    var ctx = PaintContext.init(al, &unicode, &trace);
    defer ctx.deinit();
    try ctx.computePaintCommands(d, &tree, glyphs);

    var found = false;
    var got: Rgba8 = undefined;
    for (ctx.ops.items) |op| switch (op) {
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
