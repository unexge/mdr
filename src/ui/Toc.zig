//! Document outline: top-level headings in order with source offsets.
//!
//! Collection is a single parse pass with no measuring, so opening the
//! outline never needs the viewport to be fully laid out. Title slices
//! borrow `Document.text`; flatten them with `flatten` at render time.

pub const Entry = struct {
    /// 1 to 6.
    level: u8,
    /// Raw inline markdown of the heading.
    content: []const u8,
    /// Byte offset where the heading block starts.
    offset: usize,
    /// Structural depth: siblings share one, children add one.
    depth: u8 = 0,
    /// Index of the nearest preceding heading with a smaller level.
    parent: ?usize = null,
    /// True when no later heading shares the parent.
    last: bool = true,
};

/// Gathers every top-level heading. The probe borrows the text and leaves
/// the caller's `Document` cursor alone.
pub fn collect(gpa: mem.Allocator, text: []const u8) !ArrayList(Entry) {
    var list: ArrayList(Entry) = .empty;
    errdefer list.deinit(gpa);
    var probe = Document.init(text);
    var prev_end: usize = 0;
    var levels: [8]u8 = undefined;
    var ancestors: [8]usize = undefined;
    var depth: usize = 0;
    while (probe.next()) |elem| {
        if (elem == .header) {
            const level = elem.header.level;
            while (depth > 0 and levels[depth - 1] >= level) depth -= 1;
            try list.append(gpa, .{
                .level = level,
                .content = elem.header.content,
                .offset = prev_end,
                .depth = @intCast(depth),
                .parent = if (depth == 0) null else ancestors[depth - 1],
            });
            levels[depth] = level;
            ancestors[depth] = list.items.len - 1;
            depth += 1;
        }
        prev_end = probe.cursor;
    }
    markLast(&list);
    return list;
}

/// Walking back to front, the nearest later entry at or above each depth
/// tells whether the entry closes its sibling group.
fn markLast(list: *ArrayList(Entry)) void {
    var next_at_depth: [6]?usize = .{ null, null, null, null, null, null };
    var i = list.items.len;
    while (i > 0) {
        i -= 1;
        const d: usize = list.items[i].depth;
        var nearest: ?usize = null;
        var e: usize = 0;
        while (e <= d) : (e += 1) {
            if (next_at_depth[e]) |k| nearest = if (nearest) |n| @min(n, k) else k;
        }
        list.items[i].last = nearest == null or list.items[nearest.?].depth < d;
        next_at_depth[d] = i;
    }
}

/// Plain single-line title: formatting markers are dropped, breaks become
/// spaces, entities are decoded. Truncates to `buf.len`.
pub fn flatten(content: []const u8, refs: ?*Document.RefTable, buf: []u8) []const u8 {
    var spans = if (refs != null and mem.indexOfScalar(u8, content, '[') != null)
        Document.Spans.initChainRefs(content, .{}, refs)
    else
        Document.Spans.initChain(content, .{});
    var len: usize = 0;
    while (spans.next()) |span| {
        switch (span) {
            .text, .code, .escape => |text| push(buf, &len, text),
            .entity => |raw| {
                var decoded: [4]u8 = undefined;
                push(buf, &len, Document.decodeEntity(raw, &decoded) orelse raw);
            },
            .hard_break, .soft_break => {
                if (len > 0 and buf[len - 1] != ' ') push(buf, &len, " ");
            },
            else => {},
        }
    }
    while (len > 0 and buf[len - 1] == ' ') len -= 1;
    return buf[0..len];
}

fn push(buf: []u8, len: *usize, bytes: []const u8) void {
    const room = buf.len -| len.*;
    const n = @min(room, bytes.len);
    @memcpy(buf[len.*..][0..n], bytes[0..n]);
    len.* += n;
}

/// Frame-scoped copies of flattened titles. Cells borrow their graphemes
/// until the frame flushes, so titles flattened into a reused stack buffer
/// would all alias the last row.
var title_frame: [4096]u8 = undefined;
var title_frame_len: usize = 0;

pub fn beginFrame() void {
    title_frame_len = 0;
}

pub fn copyTitle(raw: []const u8) []const u8 {
    const n = @min(raw.len, title_frame.len -| title_frame_len);
    @memcpy(title_frame[title_frame_len..][0..n], raw[0..n]);
    const out = title_frame[title_frame_len..][0..n];
    title_frame_len += n;
    return out;
}

pub const Box = struct {
    w: usize,
    h: usize,
    x: usize,
    y: usize,
    list_h: usize,
};

/// Centered modal geometry for `count` rows; clamps to the window.
pub fn boxFor(win_w: usize, win_h: usize, count: usize) Box {
    if (win_w == 0 or win_h == 0) return .{ .w = 0, .h = 0, .x = 0, .y = 0, .list_h = 0 };
    const w = @min(win_w, 52);
    const h = @min(win_h, @max(count + 4, 5));
    return .{
        .w = w,
        .h = h,
        .x = (win_w -| w) / 2,
        .y = (win_h -| h) / 2,
        .list_h = h -| 3,
    };
}

const std = @import("std");
const mem = std.mem;
const Document = @import("../Document.zig");
const ArrayList = std.ArrayList;
const testing = std.testing;

test "collects headings in order with offsets" {
    const text = "# One\n\ntext\n\n## Two\n\n```\n# not a heading\n```\n\nTitle\n=====\n";
    var list = try collect(testing.allocator, text);
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(@as(u8, 1), list.items[0].level);
    try testing.expectEqualStrings("One", list.items[0].content);
    try testing.expectEqual(@as(u8, 2), list.items[1].level);
    try testing.expectEqual(@as(u8, 1), list.items[2].level);
    try testing.expectEqualStrings("Title", list.items[2].content);
    try testing.expectEqual(@as(usize, 0), list.items[0].offset);
    try testing.expect(list.items[0].offset < list.items[1].offset);
    try testing.expect(list.items[1].offset < list.items[2].offset);
}

test "collects nothing without headings" {
    var list = try collect(testing.allocator, "just text\n\nmore text\n");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "flattens titles to plain text" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Hello world", flatten("**Hello** *world*", null, &buf));
    try testing.expectEqualStrings("click", flatten("[click](/url)", null, &buf));
    try testing.expectEqualStrings("a & b", flatten("a &amp; b", null, &buf));
    try testing.expectEqualStrings("code x", flatten("code `x`", null, &buf));
    try testing.expectEqualStrings("a b", flatten("a\nb", null, &buf));
}

test "copied titles keep their own storage" {
    beginFrame();
    const first = copyTitle("Alpha");
    const second = copyTitle("Beta");
    try testing.expectEqualStrings("Alpha", first);
    try testing.expectEqualStrings("Beta", second);
}

test "headings form a tree by level" {
    const text = "# A\n\n## B\n\n## C\n\n# D\n\n### E\n";
    var list = try collect(testing.allocator, text);
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), list.items.len);
    const depths = [_]u8{ 0, 1, 1, 0, 1 };
    const parents = [_]?usize{ null, 0, 0, null, 3 };
    const lasts = [_]bool{ false, false, true, true, true };
    for (list.items, 0..) |entry, idx| {
        try testing.expectEqual(depths[idx], entry.depth);
        try testing.expect(entry.parent == parents[idx]);
        try testing.expectEqual(lasts[idx], entry.last);
    }
}

test "modal geometry clamps to the window" {
    const big = boxFor(120, 40, 3);
    try testing.expectEqual(@as(usize, 52), big.w);
    try testing.expectEqual(@as(usize, 7), big.h);
    try testing.expectEqual(@as(usize, 4), big.list_h);
    const small = boxFor(30, 6, 20);
    try testing.expectEqual(@as(usize, 30), small.w);
    try testing.expectEqual(@as(usize, 6), small.h);
    try testing.expectEqual(@as(usize, 3), small.list_h);
    const empty = boxFor(0, 0, 3);
    try testing.expectEqual(@as(usize, 0), empty.w);
    try testing.expectEqual(@as(usize, 0), empty.list_h);
}
