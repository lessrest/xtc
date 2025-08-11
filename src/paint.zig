const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");
const Words = @import("Words");
const tailwind = @import("tailwind.zig");
const tty = @import("tty.zig");
const StyleRow = @import("style.zig").StyleRow;
const StyleOverflow = @import("style.zig").StyleOverflow;
const BorderStyle = @import("style.zig").BorderStyle;
const StyleJustify = @import("style.zig").StyleJustify;
const Trace = @import("Trace.zig");

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

pub const PaintBorderStyle = enum { line_light, line_double, line_heavy, line_dashed };

pub const PaintOpTag = enum { FillRect, StrokeRect, GlyphRun, FillGlyphRect };
pub const PaintOp = union(PaintOpTag) {
    FillRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8 },
    StrokeRect: struct { x: usize, y: usize, w: usize, h: usize, color: Rgba8, style: PaintBorderStyle, bg_color: ?Rgba8 = null },
    GlyphRun: struct { x: usize, y: usize, glyphs: []const tty.GlyphId, color: Rgba8 },
    FillGlyphRect: struct { x: usize, y: usize, w: usize, h: usize, glyph: tty.GlyphId, color: Rgba8 },
};

pub const UnicodeData = struct {
    graphemes: Graphemes,
    display_width: DisplayWidth,
    words: Words,

    pub fn init(allocator: std.mem.Allocator) !UnicodeData {
        var graphemes = try Graphemes.init(allocator);
        errdefer graphemes.deinit(allocator);

        var display_width = try DisplayWidth.init(allocator);
        errdefer display_width.deinit(allocator);

        var words = try Words.init(allocator);
        errdefer words.deinit(allocator);

        return .{
            .graphemes = graphemes,
            .display_width = display_width,
            .words = words,
        };
    }

    pub fn deinit(self: *UnicodeData, allocator: std.mem.Allocator) void {
        self.graphemes.deinit(allocator);
        self.display_width.deinit(allocator);
        self.words.deinit(allocator);
    }

    pub fn monospacedTextWidth(self: *const UnicodeData, text: []const u8) usize {
        return self.display_width.strWidth(text);
    }

    pub fn graphemeClusterIterator(self: *const UnicodeData, text: []const u8) @TypeOf(self.graphemes.iterator(text)) {
        return self.graphemes.iterator(text);
    }

    pub fn wordIterator(self: *const UnicodeData, text: []const u8) @TypeOf(self.words.iterator(text)) {
        return self.words.iterator(text);
    }
};

pub const PaintContext = struct {
    ops: std.ArrayList(PaintOp),
    unicode: *const UnicodeData,
    trace: Trace,

    pub fn init(allocator: std.mem.Allocator, unicode: *const UnicodeData, trace: Trace) PaintContext {
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
};

// Backward compatibility alias
pub const PaintCommandBatch = PaintContext;

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
fn emitGlyphTileFill(ctx: *PaintContext, glyphs: *tty.GlyphTable, rect: layout.Rect, row: StyleRow) !void {
    if (!(row.fill_glyph != 0 and rect.w > 0 and rect.h > 0)) return;

    const span = ctx.trace.enter();
    defer span.exit();
    span.info("Emitting glyph tile fill");

    const gid: tty.GlyphId = row.fill_glyph;
    const str = glyphs.getSlice(gid);

    const color = rgba8(row.fg.r, row.fg.g, row.fg.b, 255);
    span.data("glyph-tile-fill").put("rect", rect).put("text", str).put("color", color).end();

    try ctx.push(PaintOp{ .FillGlyphRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .glyph = gid, .color = color } });
}

/// Helper: background painting step per CSS painting order (backgrounds behind borders and content).
fn emitBackgroundFillIfAny(ctx: *PaintContext, rect: layout.Rect, row: StyleRow) !void {
    const span = ctx.trace.enter();
    defer span.exit();
    span.info("Emitting background fill");

    if (row.bg.use_default == 0 and rect.w > 0 and rect.h > 0) {
        const color = rgba8(row.bg.r, row.bg.g, row.bg.b, 255);
        span.data("fill-rect").put("rect", rect).put("color", color).end();
        span.decision("Background color specified, adding FillRect op");
        try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = color } });
    } else {
        span.decision("No background fill needed");
    }
}

/// Helper: border painting step. Color falls back to border_color, then fg, then white.
fn emitBorderBlock(ctx: *PaintContext, rect: layout.Rect, color: Rgba8, thickness: usize) !void {
    const span = ctx.trace.enter();
    defer span.exit();
    span.info("Emitting block border");
    span.data("border-block").put("rect", rect).put("color", color).put("thickness", thickness).end();

    if (rect.w == 0 or rect.h == 0 or thickness == 0) {
        span.decision("Zero rect or thickness, skipping border");
        return;
    }

    const t = @min(thickness, @min(rect.w, rect.h));
    _ = span.put("effective thickness", t);

    // Top band
    span.decision("Adding top border band");
    try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t, .color = color } });

    // Bottom band
    if (rect.h > t) {
        span.decision("Adding bottom border band");
        try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y + rect.h - t, .w = rect.w, .h = t, .color = color } });
    }

    // Side bands (avoid double-filling corners if height <= 2*t, harmless otherwise)
    const inner_h = if (rect.h > 2 * t) rect.h - 2 * t else 0;
    _ = span.put("inner height", inner_h);

    if (inner_h > 0) {
        span.decision("Adding left border band");
        try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x, .y = rect.y + t, .w = t, .h = inner_h, .color = color } });
        if (rect.w > t) {
            span.decision("Adding right border band");
            try ctx.push(PaintOp{ .FillRect = .{ .x = rect.x + rect.w - t, .y = rect.y + t, .w = t, .h = inner_h, .color = color } });
        }
    }
}

fn emitBorderStrokeIfAny(ctx: *PaintContext, rect: layout.Rect, row: StyleRow) !void {
    const span = ctx.trace.enter();
    defer span.exit();
    span.info("Emitting border stroke");

    if (!(row.border.width > 0 and rect.w > 0 and rect.h > 0)) {
        span.decision("No border needed");
        return;
    }
    span.data("border-stroke").put("rect", rect).put("border width", row.border.width).put("border style", @tagName(row.border.style)).end();

    const col: Rgba8 = blk: {
        if (row.border_color.use_default == 0) {
            span.decision("Using explicit border color");
            break :blk rgba8(row.border_color.r, row.border_color.g, row.border_color.b, 255);
        }
        if (row.fg.use_default == 0) {
            span.decision("Falling back to foreground color for border");
            break :blk rgba8(row.fg.r, row.fg.g, row.fg.b, 255);
        }
        span.decision("Using default white color for border");
        break :blk rgba8(255, 255, 255, 255);
    };

    const bg_for_border: ?Rgba8 = if (row.bg.use_default == 0)
        rgba8(row.bg.r, row.bg.g, row.bg.b, 255)
    else
        null;

    span.data("border-colors").put("border color", col).put("background color", bg_for_border).end();

    switch (row.border.style) {
        .block => {
            span.decision("Using block border style");
            try emitBorderBlock(ctx, rect, col, row.border.width);
        },
        .solid => {
            span.decision("Using solid line border style");
            try ctx.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_light, .bg_color = bg_for_border } });
        },
        .double => {
            span.decision("Using double line border style");
            try ctx.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_double, .bg_color = bg_for_border } });
        },
        .dashed => {
            span.decision("Using dashed line border style");
            try ctx.push(PaintOp{ .StrokeRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = col, .style = .line_dashed, .bg_color = bg_for_border } });
        },
        .none => {
            span.decision("Border style is none, no border to emit");
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
    glyphs: *tty.GlyphTable,
    text_bytes: []const u8,
    max_width_cols: usize,
    truncate_to_fit: bool,
) !struct { run: []tty.GlyphId, width_cols: usize } {
    const span = ctx.trace.enter();
    defer span.exit();
    span.info("Building glyph run from text");
    _ = span.put("text length", text_bytes.len)
        .put("max width cols", max_width_cols)
        .put("truncate to fit", truncate_to_fit);

    var glyph_ids = std.ArrayList(tty.GlyphId).init(ctx.ops.allocator);
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
            span.decision("Truncating text to fit available width");
            _ = span.put("stopped at grapheme", grapheme_count)
                .put("accumulated width", accumulated_width);
            break;
        }

        accumulated_width += grapheme_width;
        const glyph_id = try glyphs.intern(ctx.ops.allocator, grapheme_bytes);
        try glyph_ids.append(glyph_id);
    }

    _ = span.put("processed graphemes", grapheme_count)
        .put("final glyph count", glyph_ids.items.len)
        .put("accumulated width", accumulated_width);

    // Handle empty result
    if (glyph_ids.items.len == 0) {
        span.decision("Empty text result, returning empty glyph run");
        return .{ .run = &[_]tty.GlyphId{}, .width_cols = 0 };
    }

    // Allocate and copy the final glyph run
    const final_run = try ctx.ops.allocator.alloc(tty.GlyphId, glyph_ids.items.len);
    std.mem.copyForwards(tty.GlyphId, final_run, glyph_ids.items);

    // Calculate final width: use accumulated width if truncating, otherwise measure full text
    const final_width_cols: usize = if (truncate_to_fit)
        accumulated_width
    else
        ctx.unicode.monospacedTextWidth(text_bytes);

    _ = span.put("final width cols", final_width_cols);
    span.decision("Successfully built glyph run");

    return .{ .run = final_run, .width_cols = final_width_cols };
}

fn emitClockVisuals(
    ctx: *PaintContext,
    document: *const dom.Dom,
    node_id: dom.DomNodeId,
    rect: layout.Rect,
    row: StyleRow,
    glyphs: *tty.GlyphTable,
) !void {
    const span = ctx.trace.enter();
    defer span.exit();
    span.info("Emitting clock visuals");
    _ = span.put("rect", rect)
        .put("visual style", row.clock_visual);

    if (!(rect.w > 0 and rect.h > 0)) {
        span.decision("Zero rect dimensions, no clock to emit");
        return;
    }

    const cb = computeContentBox(rect, row);
    if (cb.rect.w == 0 or cb.rect.h == 0) {
        span.decision("Zero content box dimensions, no space for clock");
        return;
    }

    const color = computeTextColor(document, node_id, row);

    // Get the tick count directly from the DOM node
    const tick_count = document.getClockTick(node_id);

    switch (row.clock_visual) {
        .spinner => {
            const spinner_chars = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
            const char = spinner_chars[@mod(tick_count, spinner_chars.len)];
            const glyph_id = try glyphs.intern(ctx.ops.allocator, char);
            try ctx.push(PaintOp{ .GlyphRun = .{
                .x = cb.rect.x,
                .y = cb.rect.y,
                .glyphs = try ctx.ops.allocator.dupe(tty.GlyphId, &[_]tty.GlyphId{glyph_id}),
                .color = color,
            } });
        },
        .progress_bar => {
            // Draw a progress bar that fills based on tick count
            const progress = @as(f32, @floatFromInt(@mod(tick_count, 10))) / 10.0;
            const filled_width = @as(usize, @intFromFloat(@as(f32, @floatFromInt(cb.rect.w)) * progress));
            if (filled_width > 0) {
                try ctx.push(PaintOp{ .FillRect = .{
                    .x = cb.rect.x,
                    .y = cb.rect.y,
                    .w = filled_width,
                    .h = cb.rect.h,
                    .color = color,
                } });
            }
        },
        .pulse => {
            // Alternate between bright and dim
            const bright = @mod(tick_count, 2) == 0;
            const alpha: u8 = if (bright) 255 else 127;
            const pulse_color = (color & 0x00FFFFFF) | (@as(u32, alpha) << 24);
            try ctx.push(PaintOp{ .FillRect = .{
                .x = cb.rect.x,
                .y = cb.rect.y,
                .w = cb.rect.w,
                .h = cb.rect.h,
                .color = pulse_color,
            } });
        },
        .countdown, .text => {
            // Show tick count as text
            var buf: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{}", .{tick_count});
            // Build glyph run for the text
            var glyph_ids = std.ArrayList(tty.GlyphId).init(ctx.ops.allocator);
            defer glyph_ids.deinit();

            var it = ctx.unicode.graphemeClusterIterator(text);
            while (it.next()) |grapheme| {
                const grapheme_bytes = grapheme.bytes(text);
                const glyph_id = try glyphs.intern(ctx.ops.allocator, grapheme_bytes);
                try glyph_ids.append(glyph_id);
            }

            if (glyph_ids.items.len > 0) {
                const final_run = try ctx.ops.allocator.alloc(tty.GlyphId, glyph_ids.items.len);
                std.mem.copyForwards(tty.GlyphId, final_run, glyph_ids.items);

                try ctx.push(PaintOp{ .GlyphRun = .{
                    .x = cb.rect.x,
                    .y = cb.rect.y,
                    .glyphs = final_run,
                    .color = color,
                } });
            }
        },
        .hidden => {
            // Don't render anything
        },
    }
}

fn emitTextGlyphRuns(
    ctx: *PaintContext,
    document: *const dom.Dom,
    node_id: dom.DomNodeId,
    rect: layout.Rect,
    row: StyleRow,
    glyphs: *tty.GlyphTable,
) !void {
    const span = ctx.trace.enter();
    defer span.exit();
    span.info("Emitting text glyph runs");
    _ = span.put("rect", rect);

    if (!(rect.w > 0 and rect.h > 0)) {
        span.decision("Zero rect dimensions, no text to emit");
        return;
    }

    const slice = document.getTextSlice(node_id);
    _ = span.put("text length", slice.len);

    const cb = computeContentBox(rect, row);
    const color = computeTextColor(document, node_id, row);
    span.data("text-render").put("content box", cb.rect).put("text color", color).end();

    if (cb.rect.w == 0 or cb.rect.h == 0) {
        span.decision("Zero content box dimensions, no space for text");
        return;
    }

    var y_offset: usize = 0;
    var total_lines_processed: usize = 0;
    var total_glyph_runs_emitted: usize = 0;

    // First split by newlines
    var line_iter = std.mem.tokenizeScalar(u8, slice, '\n');
    while (line_iter.next()) |line| {
        if (y_offset >= cb.rect.h) {
            span.decision("Reached content box height limit, stopping line processing");
            break;
        }

        total_lines_processed += 1;

        const line_span = ctx.trace.enter();
        defer line_span.exit();
        line_span.info("Processing text line");
        _ = line_span.put("line number", total_lines_processed)
            .put("line length", line.len)
            .put("y offset", y_offset);

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
                line_span.decision("Line width exceeded, emitting wrapped segment");
                _ = line_span.put("wrapped segment", wrapped_segments)
                    .put("current line width", line_width);

                const line_bytes_end = last_break_bytes orelse seg.offset;
                const line_bytes = line[line_start..line_bytes_end];
                const shaped = try buildGlyphRun(ctx, glyphs, line_bytes, cb.rect.w, false);

                if (shaped.run.len > 0) {
                    const extra = computeJustifyOffset(cb.rect.w, shaped.width_cols, row.justify);
                    _ = line_span.put("justify offset", extra);

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
                    line_span.decision("Reached height limit during wrapping");
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
            line_span.decision("Emitting final line segment");
            _ = line_span.put("remaining text length", line.len - line_start);

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

        _ = line_span.put("wrapped segments", wrapped_segments);
    }

    _ = span.put("total lines processed", total_lines_processed)
        .put("total glyph runs emitted", total_glyph_runs_emitted)
        .put("final y offset", y_offset);
}

pub fn computePaintCommands(
    ctx: *PaintContext,
    document: *const dom.Dom,
    tree: *const layout.BoxTree,
    glyphs: *tty.GlyphTable,
) !void {
    const span = ctx.trace.enter();
    defer span.exit();
    span.info("Computing paint commands for display list");
    _ = span.put("node count", tree.nodeCount())
        .put("initial op count", ctx.ops.items.len);

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

        const node_span = ctx.trace.enter();
        defer node_span.exit();
        node_span.info("Painting node");
        _ = node_span.put("index", i)
            .put("id", debug_id)
            .put("kind", node_kind)
            .put("original", h.data.rect);

        // Find scroll container parent and apply scroll offset
        var paint_rect = h.data.rect;
        var is_scrolled = false;

        // Check if this node has a scroll container parent
        if (h.getParentNode(tree)) |parent_node| {
            const parent_row = document.getNodeStyle(parent_node.data.dom_id);

            if (parent_row.overflow_y == .scroll) {
                is_scrolled = true;
                const scroll_offset = parent_node.data.scroll_offset_y;
                node_span.decision("Node is in scroll container, applying scroll offset");
                _ = node_span.put("offset", scroll_offset);

                // Apply scroll offset: move content up by scroll amount
                if (paint_rect.y >= scroll_offset) {
                    paint_rect.y -= scroll_offset;
                    _ = node_span.put("adjusted", paint_rect);
                } else {
                    // Content is scrolled out of view at the top
                    node_span.decision("Content scrolled out of view at top, skipping");
                    skipped_nodes += 1;
                    continue;
                }

                // Set up clipping rectangle to viewport
                const parent_content_rect = layout.computeInnerContentRect(parent_row, parent_node.data.rect);
                _ = node_span.put("viewport", parent_content_rect);

                // Skip if entirely outside viewport
                if (paint_rect.y >= parent_content_rect.y + parent_content_rect.h or
                    paint_rect.y + paint_rect.h <= parent_content_rect.y)
                {
                    node_span.decision("Content outside viewport bounds, skipping");
                    skipped_nodes += 1;
                    continue;
                }
            }
        }

        if (!is_scrolled) {
            _ = node_span.put("adjusted", paint_rect);
        }

        const ops_before = ctx.ops.items.len;

        try emitGlyphTileFill(ctx, glyphs, paint_rect, row);
        try emitBackgroundFillIfAny(ctx, paint_rect, row);
        try emitBorderStrokeIfAny(ctx, paint_rect, row);

        if (node_kind == .text) {
            try emitTextGlyphRuns(ctx, document, h.data.dom_id, paint_rect, row, glyphs);
        } else if (node_kind == .clock) {
            try emitClockVisuals(ctx, document, h.data.dom_id, paint_rect, row, glyphs);
        }

        const ops_after = ctx.ops.items.len;
        const ops_added = ops_after - ops_before;
        _ = node_span.put("ops added", ops_added);

        if (ops_added > 0) {
            painted_nodes += 1;
        }
    }

    _ = span.put("painted nodes", painted_nodes)
        .put("skipped nodes", skipped_nodes)
        .put("final op count", ctx.ops.items.len);
}

test "alpha: simple SrcOver blend" {
    var dst = rgba8(0, 0, 255, 255);
    const src = rgba8(255, 0, 0, 128);
    blendOver(&dst, src);
    // Expect purple-ish, full alpha
    try std.testing.expect(rgba8Red(dst) > 120 and rgba8Red(dst) < 140);
    try std.testing.expect(rgba8Blue(dst) > 120 and rgba8Blue(dst) < 140);
    try std.testing.expectEqual(@as(u8, 255), rgba8Alpha(dst));
}

test "paint: stroke rect via display list (ascii)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const al = gpa.allocator();
    var r = try tty.Raster.init(al, 10, 6);
    defer r.deinit(al);
    var glyphs = try tty.GlyphTable.init(al);
    defer glyphs.deinit();
    var unicode = try UnicodeData.init(al);
    defer unicode.deinit(al);
    const trace = Trace.init(false); // Disable tracing for tests
    var ctx = PaintContext.init(al, &unicode, trace);
    defer ctx.deinit();
    try ctx.push(PaintOp{ .StrokeRect = .{ .x = 2, .y = 1, .w = 6, .h = 4, .color = rgba8(255, 255, 255, 255), .style = .line_light, .bg_color = rgba8(0, 0, 0, 255) } });
    // Force ASCII fallback for this test
    tty.setUseUnicodeBoxes(false);
    defer tty.setUseUnicodeBoxes(true);
    try tty.rasterizeDisplayList(&r, al, &glyphs, &ctx);
    const got = try r.toStringAlloc(al, &glyphs);
    defer al.free(got);
    const want =
        "          \n" ++
        "  +----+  \n" ++
        "  |    |  \n" ++
        "  |    |  \n" ++
        "  +----+  \n" ++
        "          \n";
    try std.testing.expectEqualStrings(want, got);
}

test "text color inheritance: parent element color applies to child text glyph run" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const al = arena.allocator();

    var d = dom.Dom.init(al);
    defer d.deinit();
    const root = try d.addElement("text-blue-200");
    const txt = try d.addText("A");
    d.appendChild(root, txt);

    var tree = try layout.allocateBoxTreeFromDOM(al, &d, root);
    defer tree.deinit();

    // Perform layout so text node gets a non-zero rect
    var unicode = try UnicodeData.init(al);
    defer unicode.deinit(al);
    const trace = Trace.init(false); // Disable tracing for tests
    var layout_engine = @import("layout.zig").init(al, &unicode, trace);
    try layout_engine.computeFlexLayout(
        &tree,
        &d,
        tree.getNodeMut(0),
        .{ .x = 0, .y = 0, .w = 10, .h = 3 },
    );

    var glyphs = try tty.GlyphTable.init(al);
    defer glyphs.deinit();
    var ctx = PaintContext.init(al, &unicode, trace);
    defer ctx.deinit();
    try computePaintCommands(&ctx, &d, &tree, &glyphs);

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
