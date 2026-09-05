//! Thematic break: a single dim rule across the window width.

const style: vaxis.Style = .{ .fg = .{ .index = 8 } };
const glyph = "\u{2500}";

pub fn measure() usize {
    return 1;
}

pub fn render(win: vaxis.Window, start_row: usize, skip: usize) usize {
    if (skip > 0 or start_row >= win.height) return start_row;
    for (0..win.width) |col| {
        win.writeCell(@intCast(col), @intCast(start_row), .{
            .char = .{ .grapheme = glyph, .width = 1 },
            .style = style,
        });
    }
    return start_row + 1;
}

const std = @import("std");
const vaxis = @import("vaxis");

test "is one row" {
    try testing.expectEqual(@as(usize, 1), measure());
}

const testing = std.testing;
