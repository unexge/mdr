//! Renders Document elements into a vaxis Window. Block kinds live in
//! `renderer/` submodules; future block renderers (mermaid, latex) slot in
//! there and dispatch from here.

/// Rows used by a block at `width`, including the one-row gap after it.
pub fn measure(elem: Document.Element, width: usize) usize {
    const rows = switch (elem) {
        .header => |h| text.measure(h.content, width),
        .paragraph => |p| text.measure(p.content, width),
        .code_block => |cb| code_block.measure(cb, width),
        .thematic_break => thematic_break.measure(),
    };
    return rows + 1;
}

/// Renders the block starting at `row`, skipping its first `skip` rows.
/// Returns the row after the block's trailing gap.
pub fn render(win: vaxis.Window, elem: Document.Element, row: usize, skip: usize) usize {
    const drawn = switch (elem) {
        .header => |h| text.render(win, h.content, headerStyle(h.level), row, skip),
        .paragraph => |p| text.render(win, p.content, .{}, row, skip),
        .code_block => |cb| code_block.render(win, cb, row, skip),
        .thematic_break => thematic_break.render(win, row, skip),
    };
    return @min(win.height, drawn + 1);
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

test "block heights include the trailing gap" {
    try testing.expectEqual(@as(usize, 2), measure(.{ .thematic_break = .{} }, 10));
    try testing.expectEqual(@as(usize, 2), measure(.{ .paragraph = .{ .content = "hi" } }, 10));
    try testing.expectEqual(@as(usize, 3), measure(.{ .header = .{ .level = 3, .content = "a\nb" } }, 10));
}

const testing = std.testing;
