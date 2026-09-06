//! Renders Document elements into a vaxis Window. Block kinds live in
//! `renderer/` submodules; future block renderers (mermaid, latex) slot in
//! there and dispatch from here. Containers (lists, block quotes) recurse
//! through `layoutBlocks`, bounded by depth so that deeply nested input
//! cannot exhaust the stack.
//!
//! Measuring and rendering are the same walk: a null window counts rows
//! without writing, clipping or skipping, so the two can never disagree.
//! Layout functions return content rows; the one blank row that separates
//! a block from the next is added by `measure` (its footprint) and by the
//! loops that place blocks. The `gap` flag decides whether container
//! children are separated (tight list items are not).

const max_container_depth = 24;

/// Resets per-frame scratch state; call before rendering a frame and flush
/// the frame within it.
pub fn beginFrame() void {
    text.beginFrame();
}

/// Rows used by a block at `width`, including its trailing gap.
pub fn measure(elem: Document.Element, width: usize) usize {
    return layoutDepth(null, elem, 0, 0, 0, width) + 1;
}

/// Renders the block starting at `row`, skipping its first `skip` rows.
/// Returns the row after the last content row.
pub fn render(win: vaxis.Window, elem: Document.Element, row: usize, skip: usize) usize {
    return layoutDepth(win, elem, row, skip, 0, win.width);
}

/// Lays out a container's children; when `gap` is set, one blank row
/// separates the children. In measure mode (`win` null) `start_row` must be
/// zero and the return is content rows; when rendering, `start_row` is the
/// drawing origin and the return is the row after the last content row.
pub fn layoutBlocks(win: ?vaxis.Window, blocks: Document.Blocks, start_row: usize, skip: usize, depth: usize, width: usize, gap: bool) usize {
    if (depth >= max_container_depth) return start_row;
    var it = blocks;
    var row = start_row;
    var skip_rows = if (win == null) 0 else skip;
    var first = true;
    while (it.next()) |elem| {
        if (win == null) {
            if (!first and gap) row += 1;
            first = false;
            // Measure mode: start_row stays zero so the return is a count.
            row += layoutDepth(null, elem, 0, 0, depth, width);
            continue;
        }
        const w = win.?;
        const content = layoutDepth(null, elem, 0, 0, depth, width);
        const extent = if (gap) content + 1 else content;
        if (skip_rows >= extent) {
            skip_rows -= extent;
            first = false;
            continue;
        }
        if (!first and gap) row = @min(w.height, row + 1);
        first = false;
        if (row >= w.height) break;
        row = layoutDepth(win, elem, row, skip_rows, depth, width);
        skip_rows = 0;
    }
    return row;
}

fn layoutDepth(win: ?vaxis.Window, elem: Document.Element, row: usize, skip: usize, depth: usize, width: usize) usize {
    return switch (elem) {
        .header => |h| text.layout(win, h.content, headerStyle(h.level), row, skip, width, h.chain, .left, h.refs),
        .paragraph => |p| text.layout(win, p.content, .{}, row, skip, width, p.chain, .left, p.refs),
        .code_block => |cb| code_block.layout(win, cb, row, skip, width),
        .thematic_break => thematic_break.layout(win, row, skip, width),
        .list => |l| list.layout(win, l, row, skip, depth, width),
        .block_quote => |q| block_quote.layout(win, q.blocks, row, skip, depth, width),
        .table => |t| table.layout(win, t, row, skip, width),
    };
}

fn headerStyle(level: u8) vaxis.Style {
    if (level == 1) return .{ .bold = true, .ul_style = .single };
    return .{ .bold = level <= 2 };
}

const std = @import("std");
const Document = @import("../Document.zig");
const vaxis = @import("vaxis");
const text = @import("renderer/text.zig");
const code_block = @import("renderer/code_block.zig");
const thematic_break = @import("renderer/thematic_break.zig");
const list = @import("renderer/list.zig");
const block_quote = @import("renderer/block_quote.zig");
const table = @import("renderer/table.zig");

test "block footprints include the trailing gap" {
    try testing.expectEqual(@as(usize, 2), measure(.{ .thematic_break = .{} }, 10));
    try testing.expectEqual(@as(usize, 2), measure(.{ .paragraph = .{ .content = "hi" } }, 10));
    try testing.expectEqual(@as(usize, 3), measure(.{ .header = .{ .level = 3, .content = "a\nb" } }, 10));
}

test "list and quote footprints" {
    const doc = Document.init("- one\n- two\n");
    var blocks: Document.Blocks = .{ .text = doc.text, .cursor = 0, .end = doc.text.len };
    const list_elem = blocks.next().?.list;
    // Two one-line items, adjacent in a tight list, plus the list's gap.
    try testing.expectEqual(@as(usize, 3), measure(.{ .list = list_elem }, 20));

    const quote_doc = Document.init("> a\n> b\n");
    var quote_blocks: Document.Blocks = .{ .text = quote_doc.text, .cursor = 0, .end = quote_doc.text.len };
    const quote = quote_blocks.next().?.block_quote;
    // Two content rows inset by the quote bar, plus the quote's gap.
    try testing.expectEqual(@as(usize, 3), measure(.{ .block_quote = quote }, 20));
}

const testing = std.testing;
