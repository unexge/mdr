//! Fenced code blocks: verbatim lines hard-wrapped at the window width,
//! with the info string dimmed above the content. Diagram-style blocks
//! (mermaid, latex) will get their own submodules dispatched from here.

const info_style: vaxis.Style = .{ .fg = .{ .index = 8 } };

pub fn measure(cb: Document.Element.CodeBlock, width: usize) usize {
    var rows: usize = if (cb.info != null) 1 else 0;
    var lines = Document.LineIterator{ .remaining = cb.content };
    while (lines.next()) |line| rows += wrappedRows(line, width);
    return rows;
}

pub fn render(win: vaxis.Window, cb: Document.Element.CodeBlock, start_row: usize, skip: usize) usize {
    var row = start_row;
    var skip_rows = skip;

    if (cb.info) |info| {
        if (skip_rows > 0) {
            skip_rows -= 1;
        } else if (row < win.height) {
            writeInfo(win, row, info);
            row += 1;
        }
    }

    var lines = Document.LineIterator{ .remaining = cb.content };
    while (lines.next()) |line| {
        var col: usize = 0;
        var iter = vaxis.unicode.graphemeIterator(line);
        while (iter.next()) |g| {
            const w = gwidth(g.bytes(line));
            if (w == 0) continue;
            if (col + w > win.width) {
                if (skip_rows > 0) {
                    skip_rows -= 1;
                } else {
                    if (row >= win.height) return row;
                    row += 1;
                }
                col = 0;
            }
            if (skip_rows == 0 and row < win.height) {
                win.writeCell(@intCast(col), @intCast(row), .{
                    .char = .{ .grapheme = g.bytes(line), .width = @intCast(w) },
                });
            }
            col += w;
        }
        if (skip_rows > 0) {
            skip_rows -= 1;
        } else {
            if (row >= win.height) return row;
            row += 1;
        }
    }
    return row;
}

fn writeInfo(win: vaxis.Window, row: usize, info: []const u8) void {
    var col: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(info);
    while (iter.next()) |g| {
        const w = gwidth(g.bytes(info));
        if (w == 0) continue;
        if (col + w > win.width) return;
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = g.bytes(info), .width = @intCast(w) },
            .style = info_style,
        });
        col += w;
    }
}

fn gwidth(g: []const u8) usize {
    return vaxis.gwidth.gwidth(g, .unicode);
}

fn wrappedRows(line: []const u8, width: usize) usize {
    const w = @max(width, 1);
    var cols: usize = 0;
    var rows: usize = 1;
    var iter = vaxis.unicode.graphemeIterator(line);
    while (iter.next()) |g| {
        const gw = gwidth(g.bytes(line));
        if (gw == 0) continue;
        if (cols + gw > w) {
            rows += 1;
            cols = 0;
        }
        cols += gw;
    }
    return rows;
}

const std = @import("std");
const Document = @import("../../Document.zig");
const vaxis = @import("vaxis");

test "counts the info line and wrapped content lines" {
    try testing.expectEqual(@as(usize, 2), measure(.{ .info = "zig", .content = "short\n" }, 40));
    try testing.expectEqual(@as(usize, 2), measure(.{ .info = null, .content = "abcdefgh\n" }, 4));
    try testing.expectEqual(@as(usize, 3), measure(.{ .info = null, .content = "ab\n\ncd\n" }, 40));
}

const testing = std.testing;
