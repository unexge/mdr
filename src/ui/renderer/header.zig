//! Headers use progressively lighter accent bars, with a rule below H1.
//! Wrapping accounts for the accent inset, like list item content.

/// One walk measures (null window: no writes, no clipping, no skipping)
/// and renders, returning the row after the last content row.
pub fn layout(win: ?vaxis.Window, header: Document.Element.Header, start_row: usize, skip: usize, width: usize) usize {
    const inset: usize = 2;
    const inner_width = width -| inset;
    const title_rows = text.layout(null, header.content, style, 0, 0, inner_width, header.chain, .left, header.refs);
    const has_rule = header.level == 1;
    if (win == null) {
        return title_rows + @intFromBool(has_rule);
    }
    const w = win.?;
    if (skip < title_rows) {
        if (skip == 0) drawAccent(w, start_row, header.level);
        const inner = w.child(.{
            .x_off = @intCast(inset),
            .y_off = @intCast(start_row),
            .width = w.width -| @as(u16, @intCast(inset)),
            .height = w.height -| @as(u16, @intCast(start_row)),
        });
        const end = start_row + text.layout(inner, header.content, style, 0, skip, innerWidth(w.width, inset), header.chain, .left, header.refs);
        if (!has_rule or end >= w.height) return end;
        drawRule(w, end);
        return end + 1;
    }
    if (has_rule and skip == title_rows) {
        drawRule(w, start_row);
        return @min(@as(usize, w.height), start_row + 1);
    }
    return start_row;
}

fn innerWidth(width: usize, inset: usize) usize {
    return width -| inset;
}

fn drawAccent(win: vaxis.Window, row: usize, level: u8) void {
    if (row >= win.height or win.width == 0) return;
    win.writeCell(0, @intCast(row), .{
        .char = .{ .grapheme = accent(level), .width = 1 },
        .style = accent_style,
    });
}

fn drawRule(win: vaxis.Window, row: usize) void {
    if (row >= win.height) return;
    var col: u16 = 0;
    while (col < win.width) : (col += 1) {
        win.writeCell(col, @intCast(row), .{
            .char = .{ .grapheme = "━", .width = 1 },
            .style = accent_style,
        });
    }
}

fn accent(level: u8) []const u8 {
    return switch (level) {
        1 => "▌",
        2 => "▍",
        3 => "▎",
        4 => "▏",
        5 => "╎",
        else => "┊",
    };
}

const style: vaxis.Style = .{ .bold = true };
const accent_style: vaxis.Style = .{};

const std = @import("std");
const Document = @import("../../Document.zig");
const vaxis = @import("vaxis");
const text = @import("text.zig");

test "wraps within the inset width" {
    const header: Document.Element.Header = .{ .level = 1, .content = "abcdefghij" };
    try testing.expectEqual(@as(usize, 4), layout(null, header, 0, 0, 6));
}

test "renders bold default-color heading text and level accent" {
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
    try testing.expectEqualStrings("▍", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqual(vaxis.Style{}, win.readCell(0, 0).?.style);
    try testing.expectEqualStrings("H", win.readCell(2, 0).?.char.grapheme);
    try testing.expectEqual(vaxis.Style{ .bold = true }, win.readCell(2, 0).?.style);
}

test "renders a rule below a level one heading" {
    const header: Document.Element.Header = .{ .level = 1, .content = "Title" };
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 2, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 8,
        .height = 2,
        .screen = &screen,
    };
    const end = layout(win, header, 0, 0, win.width);
    try testing.expectEqual(@as(usize, 2), end);
    try testing.expectEqualStrings("▌", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("━", win.readCell(0, 1).?.char.grapheme);
    try testing.expectEqualStrings("━", win.readCell(7, 1).?.char.grapheme);

    const scrolled_end = layout(win, header, 0, 1, win.width);
    try testing.expectEqual(@as(usize, 1), scrolled_end);
    try testing.expectEqualStrings("━", win.readCell(0, 0).?.char.grapheme);
}

test "renders progressively lighter accents for deeper headings" {
    const expected = [_][]const u8{ "▌", "▍", "▎", "▏", "╎", "┊" };
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 7, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 8,
        .height = 7,
        .screen = &screen,
    };
    var row: usize = 0;
    for (expected, 1..) |bar, level| {
        const header: Document.Element.Header = .{ .level = @intCast(level), .content = "Title" };
        const start = row;
        row = layout(win, header, row, 0, win.width);
        try testing.expectEqualStrings(bar, win.readCell(0, @intCast(start)).?.char.grapheme);
    }
    try testing.expectEqual(@as(usize, 7), row);
}

const testing = std.testing;
