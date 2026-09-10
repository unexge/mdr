//! Fenced code blocks: verbatim lines hard-wrapped at the window width,
//! rendered as a card with a filled background and the info string dimmed
//! above the content. Mermaid diagrams dispatch to mermaid.zig and
//! sequence.zig and fall back to the card when they cannot render.

const card_style: vaxis.Style = .{ .bg = Theme.panel };
const info_style: vaxis.Style = .{ .fg = Theme.muted, .bg = Theme.panel };
const max_hits_per_line = 64;
var search_query: []const u8 = "";

pub fn setSearchQuery(q: []const u8) void {
    search_query = q;
}

fn covers(line: []const u8, off: usize, len: usize) bool {
    const q = search_query.len;
    if (q == 0 or q > line.len or len == 0) return false;
    var s = if (off + 1 > q) off + 1 - q else 0;
    const last = @min(off + len - 1, line.len - q);
    while (s <= last) : (s += 1) {
        if (Search.findFirst(line[s..][0..q], search_query) != null) return true;
    }
    return false;
}

/// One walk measures (null window: no writes, no clipping, no skipping)
/// and renders, returning the row after the last content row.
pub fn layout(win: ?vaxis.Window, cb: Document.Element.CodeBlock, start_row: usize, skip: usize, width: usize) usize {
    return layoutSyntax(win, cb, start_row, skip, width, null);
}

pub fn layoutSyntax(
    win: ?vaxis.Window,
    cb: Document.Element.CodeBlock,
    start_row: usize,
    skip: usize,
    width: usize,
    highlights: ?*const Syntax.Highlights,
) usize {
    if (cb.info) |info| {
        if (info.isMermaid()) {
            if (Mermaid.parseBlock(cb)) |flow| {
                if (mermaid.layout(win, &flow, start_row, skip, width)) |after| return after;
            }
            if (Mermaid.parseSequenceBlock(cb)) |seq| {
                if (sequence.layout(win, &seq, start_row, skip, width)) |after| return after;
            }
        }
    }
    const cols = @max(width, 1);
    var row = start_row;
    var skip_rows = if (win == null) 0 else skip;

    if (cb.info) |info| {
        if (skip_rows > 0) {
            skip_rows -= 1;
        } else if (win) |w| {
            if (row < w.height) {
                fillRest(w, row, writeInfo(w, row, info.text()));
                row += 1;
            }
        } else {
            row += 1;
        }
    }

    var lines = cb.lines();
    var source_row: usize = 0;
    while (lines.next()) |line| : (source_row += 1) {
        var hit_starts: [max_hits_per_line]usize = undefined;
        var hit_seqs: [max_hits_per_line]u32 = undefined;
        var hit_count: usize = 0;
        var hit_overflow = false;
        if (search_query.len > 0 and search_query.len <= line.len) {
            var pos: usize = 0;
            while (pos + search_query.len <= line.len) {
                const rel = Search.findFirst(line[pos..], search_query) orelse break;
                const s = pos + rel;
                if (hit_count < max_hits_per_line) {
                    hit_starts[hit_count] = s;
                    hit_seqs[hit_count] = if (win != null) Search.nextSeq() else 0;
                    hit_count += 1;
                } else {
                    hit_overflow = true;
                }
                pos = s + search_query.len;
            }
        }
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
                    const bytes = g.bytes(line);
                    const off = @intFromPtr(bytes.ptr) - @intFromPtr(line.ptr);
                    w2.writeCell(@intCast(col), @intCast(row), .{
                        .char = .{ .grapheme = bytes, .width = @intCast(w) },
                        .style = lineStyle(
                            line,
                            source_row,
                            off,
                            bytes.len,
                            hit_starts[0..hit_count],
                            hit_seqs[0..hit_count],
                            hit_overflow,
                            highlights,
                        ),
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
    const line_id: u32 = if (Search.findFirst(info, search_query) != null) Search.nextSeq() else 0;
    var col: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(info);
    while (iter.next()) |g| {
        const bytes = g.bytes(info);
        const w = gwidth(bytes);
        if (w == 0) continue;
        if (col + w > win.width) return col;
        const off = @intFromPtr(bytes.ptr) - @intFromPtr(info.ptr);
        var style = info_style;
        if (line_id != 0 and covers(info, off, bytes.len)) {
            style = Search.highlight(info_style);
            if (Search.runIsFocus(line_id)) style = Search.focus(info_style);
        }
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = bytes, .width = @intCast(w) },
            .style = style,
        });
        col += w;
    }
    return col;
}

fn lineStyle(
    line: []const u8,
    row: usize,
    off: usize,
    len: usize,
    starts: []const usize,
    seqs: []const u32,
    overflow: bool,
    highlights: ?*const Syntax.Highlights,
) vaxis.Style {
    for (starts, seqs) |s, q| {
        if (s < off + len and off < s + search_query.len) {
            if (Search.runIsFocus(q)) return Search.focus(card_style);
            return Search.highlight(card_style);
        }
    }
    if (overflow and covers(line, off, len)) return Search.highlight(card_style);
    if (highlights) |syntax_highlights| {
        if (syntax_highlights.kindAt(row, off, len)) |kind| return syntaxStyle(kind);
    }
    return card_style;
}

fn syntaxStyle(kind: Syntax.Kind) vaxis.Style {
    return .{
        .fg = switch (kind) {
            .comment => Theme.muted,
            .string => Theme.success,
            .constant => Theme.gold,
            .keyword => Theme.violet,
            .function => Theme.code,
            .type => Theme.accent,
        },
        .bg = Theme.panel,
    };
}

fn gwidth(g: []const u8) usize {
    return vaxis.gwidth.gwidth(g, .unicode);
}

const std = @import("std");
const Document = @import("../../Document.zig");
const Mermaid = @import("../../Mermaid.zig");
const Search = @import("../Search.zig");
const Syntax = @import("../Syntax.zig");
const mermaid = @import("mermaid.zig");
const sequence = @import("sequence.zig");
const Theme = @import("../Theme.zig");
const vaxis = @import("vaxis");

test "mermaid flowcharts render as diagrams" {
    const diagram: Document.Element.CodeBlock = .{ .info = .{ .mermaid = "mermaid" }, .content = "graph TD\nA-->B\n" };
    try testing.expectEqual(@as(usize, 8), layout(null, diagram, 0, 0, 40));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 8, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 8,
        .screen = &screen,
    };
    _ = layout(win, diagram, 0, 0, 40);
    try testing.expectEqualStrings("┌", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("▼", win.readCell(2, 4).?.char.grapheme);
}

test "multiline mermaid source renders as a diagram" {
    const diagram: Document.Element.CodeBlock = .{
        .info = .{ .mermaid = "mermaid" },
        .content = "flowchart TD\nA[\"one\ntwo\"]-->B\n",
    };
    try testing.expectEqual(@as(usize, 9), layout(null, diagram, 0, 0, 40));
}

test "unsupported mermaid syntax falls back to the card" {
    const diagram: Document.Element.CodeBlock = .{
        .info = .{ .mermaid = "mermaid" },
        .content = "graph TD\nA-->B\nclick A callback\nB-->C\nC-->D\n",
    };
    try testing.expectEqual(@as(usize, 6), layout(null, diagram, 0, 0, 40));

    const sequence_diagram: Document.Element.CodeBlock = .{
        .info = .{ .mermaid = "mermaid" },
        .content = "sequenceDiagram\nA->>B: before\nbox Group\nparticipant C\nend\n",
    };
    try testing.expectEqual(@as(usize, 6), layout(null, sequence_diagram, 0, 0, 40));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 6, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 6,
        .screen = &screen,
    };
    _ = layout(win, diagram, 0, 0, 40);
    try testing.expect(win.readCell(0, 1).?.style.bg.eql(Theme.panel));
}

test "sequence diagrams render lifelines" {
    const diagram: Document.Element.CodeBlock = .{ .info = .{ .mermaid = "mermaid" }, .content = "sequenceDiagram\nA->>B: hi\n" };
    try testing.expectEqual(@as(usize, 5), layout(null, diagram, 0, 0, 40));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 5, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 5,
        .screen = &screen,
    };
    _ = layout(win, diagram, 0, 0, 40);
    try testing.expectEqualStrings("┌", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings("│", win.readCell(2, 3).?.char.grapheme);
    try testing.expectEqualStrings("►", win.readCell(10, 4).?.char.grapheme);
}

test "counts the info line and wrapped content lines" {
    try testing.expectEqual(@as(usize, 2), layout(null, .{ .info = .{ .other = "zig" }, .content = "short\n" }, 0, 0, 40));
    try testing.expectEqual(@as(usize, 2), layout(null, .{ .info = null, .content = "abcdefgh\n" }, 0, 0, 4));
    try testing.expectEqual(@as(usize, 3), layout(null, .{ .info = null, .content = "ab\n\ncd\n" }, 0, 0, 40));
}

test "syntax colors code cells" {
    var spans = [_]Syntax.Span{
        .{
            .row = 0,
            .start_col = 0,
            .end_col = 3,
            .kind = .keyword,
            .priority = 100,
            .pattern_index = 0,
        },
    };
    const highlights: Syntax.Highlights = .{ .spans = &spans };
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
    _ = layoutSyntax(win, .{ .info = null, .content = "pub value\n" }, 0, 0, win.width, &highlights);

    try testing.expect(win.readCell(0, 0).?.style.fg.eql(Theme.violet));
    try testing.expect(win.readCell(4, 0).?.style.fg.eql(.default));
}

test "search styling overrides syntax colors" {
    Search.beginFrame();
    Search.setEntryFocus(false, 0);
    setSearchQuery("pub");
    defer setSearchQuery("");
    var spans = [_]Syntax.Span{
        .{
            .row = 0,
            .start_col = 0,
            .end_col = 3,
            .kind = .keyword,
            .priority = 100,
            .pattern_index = 0,
        },
    };
    const highlights: Syntax.Highlights = .{ .spans = &spans };
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
    _ = layoutSyntax(win, .{ .info = null, .content = "pub value\n" }, 0, 0, win.width, &highlights);

    try testing.expect(win.readCell(0, 0).?.style.bg.eql(Theme.gold));
}

test "search highlights code matches" {
    Search.beginFrame();
    Search.setEntryFocus(true, 0);
    setSearchQuery("hi");
    defer setSearchQuery("");
    try testing.expectEqual(@as(usize, 1), layout(null, .{ .info = null, .content = "hi there\n" }, 0, 0, 40));
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
    _ = layout(win, .{ .info = null, .content = "hi there\n" }, 0, 0, win.width);
    try testing.expect(win.readCell(0, 0).?.style.bg.eql(Theme.accent));
    try testing.expect(win.readCell(1, 0).?.style.bg.eql(Theme.accent));
    try testing.expect(win.readCell(3, 0).?.style.bg.eql(Theme.panel));
}

test "only the targeted code match takes focus" {
    Search.beginFrame();
    Search.setEntryFocus(true, 1);
    setSearchQuery("ab");
    defer setSearchQuery("");
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
    _ = layout(win, .{ .info = null, .content = "ab ab\n" }, 0, 0, win.width);
    try testing.expect(win.readCell(0, 0).?.style.bg.eql(Theme.gold));
    try testing.expect(win.readCell(3, 0).?.style.bg.eql(Theme.accent));
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
    try testing.expect(win.readCell(9, 0).?.style.bg.eql(Theme.panel));
}

const testing = std.testing;
