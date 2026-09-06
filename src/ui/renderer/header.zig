//! Headers: dim `#` markers showing the level, with bold text inset past
//! them. Wrapping accounts for the inset, like list item content.

/// One walk measures (null window: no writes, no clipping, no skipping)
/// and renders, returning the row after the last content row.
pub fn layout(win: ?vaxis.Window, header: Document.Element.Header, start_row: usize, skip: usize, width: usize) usize {
    const inset: usize = @as(usize, header.level) + 1;
    const inner_width = width -| inset;
    if (win == null) {
        return text.layout(null, header.content, style, 0, 0, inner_width, header.chain, .left, header.refs);
    }
    const w = win.?;
    if (skip == 0) drawMarker(w, start_row, header.level);
    const inner = w.child(.{
        .x_off = @intCast(inset),
        .y_off = @intCast(start_row),
        .width = w.width -| @as(u16, @intCast(inset)),
        .height = w.height -| @as(u16, @intCast(start_row)),
    });
    return start_row + text.layout(inner, header.content, style, 0, skip, innerWidth(w.width, inset), header.chain, .left, header.refs);
}

fn innerWidth(width: usize, inset: usize) usize {
    return width -| inset;
}

fn drawMarker(win: vaxis.Window, row: usize, level: u8) void {
    if (row >= win.height) return;
    var col: usize = 0;
    while (col < level and col < win.width) : (col += 1) {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = "#", .width = 1 },
            .style = marker_style,
        });
    }
}

const style: vaxis.Style = .{ .bold = true };
const marker_style: vaxis.Style = .{ .fg = .{ .index = 8 } };

const std = @import("std");
const Document = @import("../../Document.zig");
const vaxis = @import("vaxis");
const text = @import("text.zig");

test "wraps within the inset width" {
    const header: Document.Element.Header = .{ .level = 1, .content = "abcdefghij" };
    try testing.expectEqual(@as(usize, 3), layout(null, header, 0, 0, 6));
}

test "renders level markers and inset text" {
    const header: Document.Element.Header = .{ .level = 2, .content = "Hi" };
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 1,
        .screen = &screen,
    };
    const end = layout(win, header, 0, 0, win.width);
    try testing.expectEqual(@as(usize, 1), end);
    try testing.expectEqualStrings("#", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("#", win.readCell(1, 0).?.char.grapheme);
    try testing.expectEqualStrings("H", win.readCell(3, 0).?.char.grapheme);
}

const testing = std.testing;
