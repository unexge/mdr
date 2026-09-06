//! Thematic break: a single dim rule across the window width.

const vaxis = @import("vaxis");

const style: vaxis.Style = .{ .fg = .{ .index = 8 } };
const glyph = "\u{2500}";

/// One walk measures (null window) and renders.
pub fn layout(win: ?vaxis.Window, start_row: usize, skip: usize, width: usize) usize {
    _ = width;
    const w = win orelse return start_row + 1;
    if (skip > 0 or start_row >= w.height) return start_row;
    for (0..w.width) |col| {
        w.writeCell(@intCast(col), @intCast(start_row), .{
            .char = .{ .grapheme = glyph, .width = 1 },
            .style = style,
        });
    }
    return start_row + 1;
}

const std = @import("std");

test "is one row" {
    try testing.expectEqual(@as(usize, 1), layout(null, 0, 0, 80));
}

const testing = std.testing;
