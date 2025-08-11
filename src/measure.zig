// Provider TODOs (production):
// - Text measurement:
//   - Grapheme-aware width (double-width, combining marks), tabs
//   - Whitespace handling: normal/pre/nowrap/pre_wrap
//   - Wrapping: greedy/balanced; ellipsis per overflow rules
//   - Return border-box: content + padding + border
//
// - Intrinsic sizing:
//   - Leaves: intrinsic or style overrides (width/height, min/max)
//   - Containers: pre-measure pass: sum on main axis, max on cross; cache result
//   - Replaced elements: intrinsic size; fallbacks
//
// - Flexbox completeness:
//   - flex-grow/shrink distribution of free/deficit space with clamping to min/max
//   - flex-basis:auto vs specified; percent bases
//   - flex-wrap: multi-line layout and line breaking
//   - align-content for multi-line cross-axis distribution
//   - row_reverse/column_reverse direction
//
// - Constraints & percentages:
//   - min-width/height, max-width/height
//   - percentage resolution against parent inner size (for width/height, padding, margin)
//   - margin auto (main-axis auto-centering semantics)
//
// - Alignment details:
//   - align-items:baseline (baseline computation for text)
//   - align-self overrides (already partially supported)
//   - gap: main and cross (we have main; add cross)
//
// - Visual properties influence:
//   - display:none (skip layout/paint); visibility:hidden (layout yes, paint no)
//   - overflow:clip (establish clip rect during paint)
//   - border.style (ascii/unicode mapping), border color, alpha blending
//
// - Painting hooks:
//   - Emit background FillRect from styles (with alpha)
//   - Emit borders from border spec; corners/joints style
//   - Emit GlyphRun for text nodes (map DOM text → glyph ids)
//   - Establish clip for overflow and descendant painting
//
// - Ordering/layers:
//   - order (stable) for layout (done); z-index for paint ordering
//   - Optional overlay layers (selection/caret) composited after main
//
// - Caching & invalidation:
//   - Cache measure(props) by (node_id, constraints, style_hash, text_epoch)
//   - Invalidate on style/text change or parent constraints change
//
// - Performance ergonomics:
//   - Reuse arenas, avoid per-node allocations in hot paths
//   - Small-vec for child temp buffers; pre-size arrays
//   - Fast style lookup (we have interned rows)
//
// - Tests to add:
//   - Text wrap/ellipsis/whitespace variants
//   - flex-grow/shrink with min/max constraints
//   - flex-wrap + align-content distributions
//   - percentage sizes; margin auto centering
//   - overflow:clip clipping correctness
//   - border styles and alpha background blending

const std = @import("std");
const DisplayWidth = @import("lib.zig").DisplayWidth;
const UnicodeData = @import("paint.zig").UnicodeData;
const Dom = @import("dom.zig").Dom;
const DomNodeId = @import("dom.zig").DomNodeId;

pub fn intrinsicSize(dom_: *const Dom, id: DomNodeId, max_w: usize, max_h: usize, unicode: *const UnicodeData) [2]usize {
    const items = dom_.headers.slice();
    const kind = items.items(.kind)[@as(usize, @intCast(id))];
    const sid = items.items(.style_id)[@as(usize, @intCast(id))];
    const row = dom_.styles.cols.items[@intCast(sid)];

    const border_w: usize = @as(usize, @intCast(row.border.width));
    // Avoid u4 overflow by widening before addition
    const pad_x: usize = @as(usize, @intCast(row.padding.l)) + @as(usize, @intCast(row.padding.r)) + border_w * 2;
    const pad_y: usize = @as(usize, @intCast(row.padding.t)) + @as(usize, @intCast(row.padding.b)) + border_w * 2;

    var w: usize = 0;
    var h: usize = 0;

    // Explicit overrides are border-box and take precedence
    if (row.width != 0) w = row.width;
    if (row.height != 0) h = row.height;

    // Calculate intrinsic size for text nodes and element containers
    if (w == 0 or h == 0) {
        if (kind == .text) {
            // Text nodes: measure based on display width and a naive wrapping model.
            const slice = dom_.getTextSlice(id);
            const text_cols: usize = unicode.monospacedTextWidth(slice);
            // Use the actual text width when max_w is 0 (unconstrained)
            const clamp_w: usize = if (max_w == 0) text_cols else @min(max_w, text_cols);

            const old_h = h;

            if (w == 0) {
                // When unconstrained (max_w == 0), use natural text width
                w = if (max_w == 0) (pad_x + text_cols) else @min(max_w, pad_x + clamp_w);
            }
            if (h == 0) {
                // Count actual newlines in the text, not just character width-based wrapping
                var lines: usize = 1;
                var it = std.unicode.Utf8Iterator{ .bytes = slice, .i = 0 };
                while (it.nextCodepoint()) |codepoint| {
                    if (codepoint == '\n') {
                        lines += 1;
                    }
                }
                // When unconstrained (max_h == 0), use natural line count
                h = if (max_h == 0) (pad_y + lines) else @min(max_h, pad_y + lines);
            }

            // Log the text measurement calculation
            var id_buf: [32]u8 = undefined;
            const debug_id = dom_.getDebugIdOrDefault(id, &id_buf);
            std.log.info("  [measure] text {s}: text_cols={d} max_w={d} max_h={d} pad=({d}x{d}) lines={d} -> ({d}x{d})", .{ debug_id, text_cols, max_w, max_h, pad_x, pad_y, if (h > 0 and old_h == 0) (h - pad_y) else 1, w, h });
        } else if (kind == .element) {
            // Element containers: calculate intrinsic size from children
            const child_count = items.items(.child_count)[@as(usize, @intCast(id))];
            if (child_count > 0) {
                var total_child_w: usize = 0;
                var max_child_w: usize = 0;
                var total_child_h: usize = 0;
                var max_child_h: usize = 0;
                
                // Measure all children to find container's intrinsic size
                var cur_child = items.items(.first_child)[@as(usize, @intCast(id))];
                while (cur_child != Dom.NullId) {
                    // Give children the available space minus our padding
                    const child_max_w = if (max_w > pad_x) (max_w - pad_x) else 0;
                    const child_max_h = if (max_h > pad_y) (max_h - pad_y) else 0;
                    const child_size = intrinsicSize(dom_, cur_child, child_max_w, child_max_h, unicode);
                    
                    // Track both sum and max for both dimensions
                    total_child_w += child_size[0];
                    max_child_w = @max(max_child_w, child_size[0]);
                    total_child_h += child_size[1];
                    max_child_h = @max(max_child_h, child_size[1]);
                    
                    // Move to next sibling
                    cur_child = items.items(.next_sibling)[@as(usize, @intCast(cur_child))];
                }
                
                // Container size depends on flex direction
                if (row.flex_dir == .row) {
                    // Horizontal layout: width is sum, height is max
                    if (w == 0) {
                        w = if (max_w == 0) (pad_x + total_child_w) else @min(max_w, pad_x + total_child_w);
                    }
                    if (h == 0) {
                        h = if (max_h == 0) (pad_y + max_child_h) else @min(max_h, pad_y + max_child_h);
                    }
                } else {
                    // Vertical layout (column): width is max, height is sum
                    if (w == 0) {
                        w = if (max_w == 0) (pad_x + max_child_w) else @min(max_w, pad_x + max_child_w);
                    }
                    if (h == 0) {
                        h = if (max_h == 0) (pad_y + total_child_h) else @min(max_h, pad_y + total_child_h);
                    }
                }
            }
        }
    }

    // Minimal border-box when no intrinsic sizing known
    if (w == 0) w = if (max_w == 0) pad_x else @min(max_w, pad_x);
    if (h == 0) h = if (max_h == 0) pad_y else @min(max_h, pad_y);

    // Replaced elements can extend this path later
    return [_]usize{ w, h };
}
