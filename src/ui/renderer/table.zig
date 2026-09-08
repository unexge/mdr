//! Tables: content-weighted columns with ASCII `|` borders and a `-`
//! separator row under the header. Cell text wraps through the shared
//! text layout, honoring each column's alignment.

/// One walk measures (null window: no writes, no clipping, no skipping)
/// and renders, returning the row after the last content row.
pub fn layout(win: ?vaxis.Window, table: Document.Element.Table, start_row: usize, skip: usize, width: usize) usize {
    const ncols = table.ncols;
    if (ncols == 0 or ncols > Document.max_table_cols) return start_row;
    const cols_width: usize = if (win) |w| w.width else width;
    var widths: [Document.max_table_cols]usize = undefined;
    computeWidths(cols_width, table, widths[0..ncols]);
    var borders: [Document.max_table_cols + 1]usize = undefined;
    var cells_x: [Document.max_table_cols]usize = undefined;
    borders[0] = 0;
    for (0..ncols) |i| {
        cells_x[i] = borders[i] + 2;
        borders[i + 1] = borders[i] + widths[i] + 3;
    }

    var header_cells: [Document.max_table_cols][]const u8 = undefined;
    const header_count = Document.splitCells(table.header, &header_cells);

    if (win == null) {
        var row = start_row;
        row += rowHeight(header_cells[0..@min(header_count, ncols)], ncols, widths[0..ncols], table.refs);
        row += 1;
        var lines = Document.LineIterator{ .remaining = table.body, .chain = table.chain, .first = false };
        var buf: [Document.max_table_cols][]const u8 = undefined;
        while (lines.next()) |line| {
            const n = Document.splitCells(line, &buf);
            row += rowHeight(buf[0..@min(n, ncols)], ncols, widths[0..ncols], table.refs);
        }
        return row;
    }

    const w = win.?;
    var row = start_row;
    var skip_rows = skip;
    row = renderRow(w, header_cells[0..@min(header_count, ncols)], table, widths[0..ncols], cells_x[0..ncols], borders[0 .. ncols + 1], row, &skip_rows, .header);
    if (row >= w.height) return row;
    if (skip_rows > 0) {
        skip_rows -= 1;
    } else {
        drawSeparator(w, row, ncols, borders[0 .. ncols + 1]);
        row += 1;
    }
    var lines = Document.LineIterator{ .remaining = table.body, .chain = table.chain, .first = false };
    var buf: [Document.max_table_cols][]const u8 = undefined;
    var index: usize = 0;
    while (lines.next()) |line| {
        if (row >= w.height) break;
        const n = Document.splitCells(line, &buf);
        row = renderRow(w, buf[0..@min(n, ncols)], table, widths[0..ncols], cells_x[0..ncols], borders[0 .. ncols + 1], row, &skip_rows, if (index % 2 == 1) .striped else .body);
        index += 1;
    }
    return row;
}

const RowKind = enum { header, body, striped };

fn renderRow(w: vaxis.Window, cells: [][]const u8, table: Document.Element.Table, widths: []usize, cells_x: []usize, borders: []usize, row: usize, skip_rows: *usize, kind: RowKind) usize {
    const ncols = table.ncols;
    const aligns = table.aligns[0..ncols];
    const height = rowHeight(cells, ncols, widths, table.refs);
    if (skip_rows.* >= height) {
        skip_rows.* -= height;
        return row;
    }
    const cell_skip = skip_rows.*;
    skip_rows.* = 0;
    const visible = height - cell_skip;
    const base: vaxis.Style = switch (kind) {
        .header => .{ .bold = true },
        .body => .{},
        .striped => .{ .bg = Theme.panel },
    };
    const edge_style: vaxis.Style = switch (kind) {
        .striped => .{ .fg = Theme.muted, .bg = Theme.panel },
        else => border_style,
    };
    if (kind == .striped) {
        var s: usize = 0;
        while (s < visible and row + s < w.height) : (s += 1) fillStripe(w, row + s, borders[ncols]);
    }
    var r: usize = 0;
    while (r < visible and row + r < w.height) : (r += 1) {
        for (borders) |x| {
            if (x >= w.width) continue;
            w.writeCell(@intCast(x), @intCast(row + r), .{
                .char = .{ .grapheme = "|", .width = 1 },
                .style = edge_style,
            });
        }
    }
    for (0..ncols) |i| {
        const cell: []const u8 = if (i < cells.len) cells[i] else "";
        const inner = w.child(.{
            .x_off = @intCast(cells_x[i]),
            .y_off = @intCast(row),
            .width = @intCast(widths[i]),
            .height = w.height -| @as(u16, @intCast(row)),
        });
        _ = text.layout(inner, cell, base, 0, cell_skip, widths[i], .{}, aligns[i], table.refs);
    }
    return row + visible;
}

fn drawSeparator(w: vaxis.Window, row: usize, ncols: usize, borders: []usize) void {
    if (row >= w.height) return;
    for (0..ncols) |i| {
        var x = borders[i];
        while (x <= borders[i + 1] and x < w.width) : (x += 1) {
            const glyph: []const u8 = if (x == borders[i] or x == borders[i + 1]) "|" else "-";
            w.writeCell(@intCast(x), @intCast(row), .{
                .char = .{ .grapheme = glyph, .width = 1 },
                .style = border_style,
            });
        }
    }
}

fn rowHeight(cells: [][]const u8, ncols: usize, widths: []usize, refs: ?*Document.RefTable) usize {
    var height: usize = 1;
    for (0..ncols) |i| {
        const cell: []const u8 = if (i < cells.len) cells[i] else "";
        if (cell.len == 0) continue;
        height = @max(height, text.measure(cell, widths[i], .{}, refs));
    }
    return height;
}

fn computeWidths(width: usize, table: Document.Element.Table, out: []usize) void {
    const ncols = table.ncols;
    if (ncols == 0) return;
    const avail = width -| (3 * ncols + 1);
    var desired: [Document.max_table_cols]usize = undefined;
    for (0..ncols) |i| desired[i] = 1;
    var buf: [Document.max_table_cols][]const u8 = undefined;
    const hn = Document.splitCells(table.header, &buf);
    for (buf[0..@min(hn, ncols)], 0..) |cell, i| desired[i] = @max(desired[i], contentWidth(cell));
    var lines = Document.LineIterator{ .remaining = table.body, .chain = table.chain, .first = false };
    while (lines.next()) |line| {
        const n = Document.splitCells(line, &buf);
        for (buf[0..@min(n, ncols)], 0..) |cell, i| desired[i] = @max(desired[i], contentWidth(cell));
    }
    const fair = avail / ncols;
    var used: usize = 0;
    for (0..ncols) |i| {
        out[i] = @min(desired[i], fair);
        used += out[i];
    }
    const leftover = avail -| used;
    const base = leftover / ncols;
    const rem = leftover % ncols;
    for (0..ncols) |i| out[i] = @max(1, out[i] + base + @intFromBool(i < rem));
}

/// Display width of a cell with markup removed, so weighting follows the
/// rendered text rather than the source bytes.
fn contentWidth(cell: []const u8) usize {
    var width: usize = 0;
    var spans = Document.Spans.init(cell);
    while (spans.next()) |span| {
        switch (span) {
            .text => |t| width += gwidth(t),
            .code => |t| width += gwidth(t),
            .entity => |raw| {
                var buf: [4]u8 = undefined;
                width += gwidth(Document.decodeEntity(raw, &buf) orelse raw);
            },
            .escape => width += 1,
            else => {},
        }
    }
    return width;
}

fn gwidth(s: []const u8) usize {
    return vaxis.gwidth.gwidth(s, .unicode);
}

const border_style: vaxis.Style = .{ .fg = Theme.muted };
const stripe_style: vaxis.Style = .{ .bg = Theme.panel };

/// Paints the stripe wash behind a body row up to the table's right edge;
/// borders and cell text draw over it afterwards.
fn fillStripe(w: vaxis.Window, row: usize, edge: usize) void {
    var x: usize = 0;
    while (x <= edge and x < w.width) : (x += 1) {
        w.writeCell(@intCast(x), @intCast(row), .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = stripe_style,
        });
    }
}

const std = @import("std");
const Document = @import("../../Document.zig");
const vaxis = @import("vaxis");
const text = @import("text.zig");
const Theme = @import("../Theme.zig");

test "counts header, separator and body rows" {
    const table: Document.Element.Table = .{
        .ncols = 2,
        .aligns = [_]Document.Alignment{.left} ** Document.max_table_cols,
        .header = "a | b",
        .body = "c | d\ne | f",
    };
    try testing.expectEqual(@as(usize, 4), layout(null, table, 0, 0, 20));
}

test "long cells wrap and grow the row" {
    const table: Document.Element.Table = .{
        .ncols = 2,
        .aligns = [_]Document.Alignment{.left} ** Document.max_table_cols,
        .header = "abcdefgh | b",
        .body = "",
    };
    try testing.expectEqual(@as(usize, 3), layout(null, table, 0, 0, 15));
}

test "renders borders and cell text" {
    const table: Document.Element.Table = .{
        .ncols = 2,
        .aligns = [_]Document.Alignment{.left} ** Document.max_table_cols,
        .header = "a | b",
        .body = "c | d",
    };
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 3, .cols = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 12,
        .height = 3,
        .screen = &screen,
    };
    const end = layout(win, table, 0, 0, win.width);
    try testing.expectEqual(@as(usize, 3), end);
    try testing.expectEqualStrings("|", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("a", win.readCell(2, 0).?.char.grapheme);
    try testing.expectEqualStrings("-", win.readCell(1, 1).?.char.grapheme);
    try testing.expectEqualStrings("c", win.readCell(2, 2).?.char.grapheme);
}

test "weights columns by content" {
    const table: Document.Element.Table = .{
        .ncols = 2,
        .aligns = [_]Document.Alignment{.left} ** Document.max_table_cols,
        .header = "name | age",
        .body = "Alice | 30",
    };
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 3, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 3,
        .screen = &screen,
    };
    const end = layout(win, table, 0, 0, win.width);
    try testing.expectEqual(@as(usize, 3), end);
    try testing.expectEqualStrings("A", win.readCell(2, 2).?.char.grapheme);
    try testing.expectEqualStrings("3", win.readCell(13, 2).?.char.grapheme);
}

test "weighting ignores markup" {
    const table: Document.Element.Table = .{
        .ncols = 2,
        .aligns = [_]Document.Alignment{.left} ** Document.max_table_cols,
        .header = "*ab* | cdef",
        .body = "",
    };
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 2, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 2,
        .screen = &screen,
    };
    _ = layout(win, table, 0, 0, win.width);
    try testing.expectEqualStrings("c", win.readCell(11, 0).?.char.grapheme);
}

test "renders column alignment" {
    var right_aligns = [_]Document.Alignment{.left} ** Document.max_table_cols;
    right_aligns[0] = .right;
    const right: Document.Element.Table = .{
        .ncols = 1,
        .aligns = right_aligns,
        .header = "b",
        .body = "",
    };
    var center_aligns = [_]Document.Alignment{.left} ** Document.max_table_cols;
    center_aligns[0] = .center;
    const center: Document.Element.Table = .{
        .ncols = 1,
        .aligns = center_aligns,
        .header = "b",
        .body = "",
    };
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 4, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 10,
        .height = 4,
        .screen = &screen,
    };
    _ = layout(win, right, 0, 0, win.width);
    try testing.expectEqualStrings("|", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("b", win.readCell(7, 0).?.char.grapheme);
    _ = layout(win, center, 2, 0, win.width);
    try testing.expectEqualStrings("b", win.readCell(4, 2).?.char.grapheme);
}

const testing = std.testing;
