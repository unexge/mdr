//! Thematic break: a centered ornament.

const style: vaxis.Style = .{ .fg = Theme.muted };
const glyphs = "* * *";

/// One walk measures (null window) and renders.
pub fn layout(win: ?vaxis.Window, start_row: usize, skip: usize, width: usize) usize {
    _ = width;
    const w = win orelse return start_row + 1;
    if (skip > 0 or start_row >= w.height) return start_row;
    const start = (w.width -| glyphs.len) / 2;
    for (0..glyphs.len) |i| {
        const col = start + i;
        if (col >= w.width) break;
        w.writeCell(@intCast(col), @intCast(start_row), .{
            .char = .{ .grapheme = glyphs[i..][0..1], .width = 1 },
            .style = style,
        });
    }
    return start_row + 1;
}

const std = @import("std");
const Theme = @import("../Theme.zig");
const vaxis = @import("vaxis");

test "is one row" {
    try testing.expectEqual(@as(usize, 1), layout(null, 0, 0, 80));
}

const testing = std.testing;
