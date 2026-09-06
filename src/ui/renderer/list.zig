//! Lists: markers, ordered numbering and task checkboxes. Item content
//! renders into a child window inset by the marker width; tight lists keep
//! items adjacent, loose lists separate them with a blank row.

const Document = @import("../../Document.zig");
const Renderer = @import("../Renderer.zig");
const vaxis = @import("vaxis");

const marker_style: vaxis.Style = .{ .fg = .{ .index = 8 } };
const task_open_style: vaxis.Style = .{ .fg = .{ .index = 8 } };
const task_done_style: vaxis.Style = .{ .fg = .{ .index = 2 } };

/// One walk measures (null window: no writes, no clipping, no skipping)
/// and renders, returning the row after the last content row.
pub fn layout(win: ?vaxis.Window, list: Document.Element.List, start_row: usize, skip: usize, depth: usize, width: usize) usize {
    var items = list.items;
    var row = start_row;
    var skip_rows = if (win == null) 0 else skip;
    var first = true;
    var index: u32 = 0;
    while (items.next()) |item| {
        const inset = contentX(item);
        const gap = !list.tight;
        const content = Renderer.layoutBlocks(null, item.blocks, 0, 0, depth + 1, width -| inset, gap);
        const item_rows = @max(content, 1);
        const separator: usize = if (!first and gap) 1 else 0;
        const total = item_rows + separator;

        if (win == null) {
            row += total;
            first = false;
            index += 1;
            continue;
        }
        const w = win.?;
        if (skip_rows >= total) {
            skip_rows -= total;
            first = false;
            index += 1;
            continue;
        }
        if (!first and gap) row = @min(w.height, row + 1);
        first = false;
        if (row >= w.height) break;
        if (skip_rows == 0) drawMarker(w, row, item, inset);
        const inner = w.child(.{
            .x_off = @intCast(inset),
            .y_off = @intCast(row),
            .width = w.width -| @as(u16, @intCast(inset)),
            .height = w.height -| @as(u16, @intCast(row)),
        });
        row += @max(Renderer.layoutBlocks(inner, item.blocks, 0, skip_rows, depth + 1, innerWidth(w.width, inset), gap), 1);
        skip_rows = 0;
        index += 1;
    }
    return row;
}

/// The marker's source text plus one space of padding.
fn contentX(item: Document.ListItem) usize {
    return (if (item.task != null) item.task_glyph.len else item.marker.len) + 1;
}

fn innerWidth(width: usize, inset: usize) usize {
    return width -| inset;
}

fn drawMarker(win: vaxis.Window, row: usize, item: Document.ListItem, inset: usize) void {
    // Cells hold grapheme slices, so the marker text must outlive this
    // call: the parser's slices point into the document text.
    if (row >= win.height or inset == 0) return;
    const marker = if (item.task != null) item.task_glyph else item.marker;
    const style = if (item.task) |done| (if (done) task_done_style else task_open_style) else marker_style;
    var col: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(marker);
    while (iter.next()) |g| {
        if (col >= inset or col >= win.width) break;
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = g.bytes(marker), .width = 1 },
            .style = style,
        });
        col += 1;
    }
}

const std = @import("std");

test "marker width" {
    const doc = Document.init("- a\n2. b\n- [x] c\n");
    var blocks: Document.Blocks = .{ .text = doc.text, .cursor = 0, .end = doc.text.len };

    var list_elem = blocks.next().?.list;
    var item = list_elem.items.next().?;
    try testing.expectEqual(@as(usize, 2), contentX(item));

    list_elem = blocks.next().?.list;
    item = list_elem.items.next().?;
    try testing.expectEqual(@as(usize, 3), contentX(item));

    list_elem = blocks.next().?.list;
    item = list_elem.items.next().?;
    try testing.expectEqual(@as(usize, 4), contentX(item));
}

const testing = std.testing;
