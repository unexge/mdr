//! Fenced code blocks: verbatim lines hard-wrapped at the window width,
//! rendered as a card with a filled background and the info string dimmed
//! above the content. Diagram-style blocks (mermaid, latex) will get their
//! own submodules dispatched from here.

const Document = @import("../../Document.zig");
const vaxis = @import("vaxis");

const card_style: vaxis.Style = .{ .bg = .{ .index = 236 } };
const info_style: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 236 } };

/// One walk measures (null window: no writes, no clipping, no skipping)
/// and renders, returning the row after the last content row.
pub fn layout(win: ?vaxis.Window, cb: Document.Element.CodeBlock, start_row: usize, skip: usize, width: usize) usize {
    const cols = @max(width, 1);
    var row = start_row;
    var skip_rows = if (win == null) 0 else skip;

    if (cb.info) |info| {
        if (skip_rows > 0) {
            skip_rows -= 1;
        } else if (win) |w| {
            if (row < w.height) {
                fillRest(w, row, writeInfo(w, row, info));
                row += 1;
            }
        } else {
            row += 1;
        }
    }

    var lines = cb.lines();
    while (lines.next()) |line| {
        var col: usize = 0;
        var iter = vaxis.unicode.graphemeIterator(line);
        while (iter.next()) |g| {
            const w = gwidth(g.bytes(line));
            if (w == 0) continue;
            if (col + w > cols) {
                if (skip_rows > 0) {
                    skip_rows -= 1;
                } else if (win) |w2| {
                    if (row >= w2.height) return row;
                    fillRest(w2, row, col);
                    row += 1;
                } else {
                    row += 1;
                }
                col = 0;
            }
            if (win) |w2| {
                if (skip_rows == 0 and row < w2.height) {
                    w2.writeCell(@intCast(col), @intCast(row), .{
                        .char = .{ .grapheme = g.bytes(line), .width = @intCast(w) },
                        .style = card_style,
                    });
                }
            }
            col += w;
        }
        if (skip_rows > 0) {
            skip_rows -= 1;
        } else if (win) |w2| {
            if (row >= w2.height) return row;
            fillRest(w2, row, col);
            row += 1;
        } else {
            row += 1;
        }
    }
    return row;
}

/// Fills the rest of a card row with the background; blank cells would
/// otherwise show through to the terminal background.
fn fillRest(w: vaxis.Window, row: usize, from: usize) void {
    var col = from;
    while (col < w.width) : (col += 1) {
        w.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = card_style,
        });
    }
}

fn writeInfo(win: vaxis.Window, row: usize, info: []const u8) usize {
    var col: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(info);
    while (iter.next()) |g| {
        const w = gwidth(g.bytes(info));
        if (w == 0) continue;
        if (col + w > win.width) return col;
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = g.bytes(info), .width = @intCast(w) },
            .style = info_style,
        });
        col += w;
    }
    return col;
}

fn gwidth(g: []const u8) usize {
    return vaxis.gwidth.gwidth(g, .unicode);
}

const std = @import("std");

test "counts the info line and wrapped content lines" {
    try testing.expectEqual(@as(usize, 2), layout(null, .{ .info = "zig", .content = "short\n" }, 0, 0, 40));
    try testing.expectEqual(@as(usize, 2), layout(null, .{ .info = null, .content = "abcdefgh\n" }, 0, 0, 4));
    try testing.expectEqual(@as(usize, 3), layout(null, .{ .info = null, .content = "ab\n\ncd\n" }, 0, 0, 40));
}

test "fills the card background past the text" {
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 10,
        .height = 1,
        .screen = &screen,
    };
    _ = layout(win, .{ .info = null, .content = "hi\n" }, 0, 0, win.width);
    try testing.expectEqualStrings("h", win.readCell(0, 0).?.char.grapheme);
    try testing.expect(win.readCell(9, 0).?.style.bg.eql(vaxis.Color{ .index = 236 }));
}

const testing = std.testing;
