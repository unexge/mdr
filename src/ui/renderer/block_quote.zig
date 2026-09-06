//! Block quotes: content rendered into a child window inset by two columns
//! with a dim bar marking the quoted rows.

const Document = @import("../../Document.zig");
const Renderer = @import("../Renderer.zig");
const vaxis = @import("vaxis");

const inset = 2;
const bar = "\u{2502}";
const bar_style: vaxis.Style = .{ .fg = .{ .index = 8 } };

/// One walk measures (null window: no writes, no clipping, no skipping)
/// and renders, returning the row after the last content row.
pub fn layout(win: ?vaxis.Window, blocks: Document.Blocks, start_row: usize, skip: usize, depth: usize, width: usize) usize {
    const inner_width = width -| inset;
    if (win) |w| {
        const inner = w.child(.{
            .x_off = inset,
            .y_off = @intCast(start_row),
            .width = w.width -| inset,
            .height = w.height -| @as(u16, @intCast(start_row)),
        });
        const used = Renderer.layoutBlocks(inner, blocks, 0, skip, depth + 1, inner_width, true);
        var r = start_row;
        while (r < start_row + used and r < w.height) : (r += 1) {
            w.writeCell(0, @intCast(r), .{
                .char = .{ .grapheme = bar, .width = 1 },
                .style = bar_style,
            });
        }
        return start_row + used;
    }
    return start_row + Renderer.layoutBlocks(null, blocks, 0, 0, depth + 1, inner_width, true);
}

const std = @import("std");
