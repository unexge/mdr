//! Block-level review comments keyed by source byte range.
//!
//! Ranges stay stable across lazy parsing and resizes because they point
//! into `Document.text`, not entry indexes. Texts are owned duplicates.

const Store = @This();

list: ArrayList(Comment) = .empty,

pub const Comment = struct {
    start: usize,
    end: usize,
    text: []u8,
};

pub fn deinit(self: *Store, gpa: mem.Allocator) void {
    for (self.list.items) |*c| gpa.free(c.text);
    self.list.deinit(gpa);
    self.* = undefined;
}

pub fn count(self: *const Store) usize {
    return self.list.items.len;
}

pub fn get(self: *const Store, start: usize, end: usize) ?[]const u8 {
    for (self.list.items) |*c| {
        if (c.start == start and c.end == end) return c.text;
    }
    return null;
}

pub fn has(self: *const Store, start: usize, end: usize) bool {
    return self.get(start, end) != null;
}

/// Inserts or replaces the comment for a range; empty text deletes it.
pub fn set(self: *Store, gpa: mem.Allocator, start: usize, end: usize, text: []const u8) !void {
    for (self.list.items, 0..) |*c, i| {
        if (c.start != start or c.end != end) continue;
        if (text.len == 0) {
            gpa.free(c.text);
            _ = self.list.orderedRemove(i);
            return;
        }
        const duped = try gpa.dupe(u8, text);
        errdefer gpa.free(duped);
        gpa.free(c.text);
        c.text = duped;
        return;
    }
    if (text.len == 0) return;
    const duped = try gpa.dupe(u8, text);
    errdefer gpa.free(duped);
    try self.list.append(gpa, .{ .start = start, .end = end, .text = duped });
    mem.sort(Comment, self.list.items, {}, lessThan);
}

fn lessThan(_: void, a: Comment, b: Comment) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end < b.end;
}

/// 1-based line number for a byte offset; offsets past the end clamp.
pub fn lineOf(text: []const u8, offset: usize) usize {
    var line: usize = 1;
    const end = @min(offset, text.len);
    for (text[0..end]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

pub const RangeLines = struct {
    first: usize,
    last: usize,
};

/// 1-based inclusive line range for `[start, end)`; surrounding blank
/// whitespace is trimmed so inter-block gaps don't widen the range.
pub fn rangeLines(text: []const u8, start: usize, end: usize) RangeLines {
    var s = @min(start, text.len);
    var e = @min(end, text.len);
    while (s < e and (text[s] == '\n' or text[s] == '\r' or text[s] == ' ' or text[s] == '\t')) s += 1;
    while (e > s and (text[e - 1] == '\n' or text[e - 1] == '\r' or text[e - 1] == ' ' or text[e - 1] == '\t')) e -= 1;
    const first = lineOf(text, s);
    if (e <= s) return .{ .first = first, .last = first };
    return .{ .first = first, .last = lineOf(text, e - 1) };
}

/// Writes `Lfirst-Llast: body` with multiline bodies continued on
/// `  <line>` rows so the prefix stays parseable.
pub fn formatComment(writer: *Io.Writer, text: []const u8, start: usize, end: usize, body: []const u8) !void {
    const lines = rangeLines(text, start, end);
    if (lines.first == lines.last) {
        try writer.print("L{d}: ", .{lines.first});
    } else {
        try writer.print("L{d}-L{d}: ", .{ lines.first, lines.last });
    }
    var it = mem.splitScalar(u8, body, '\n');
    var first_line = true;
    while (it.next()) |line| {
        if (!first_line) try writer.writeAll("\n  ");
        first_line = false;
        try writer.writeAll(line);
    }
    try writer.writeAll("\n");
}

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const ArrayList = std.ArrayList;

test "line numbers count newlines" {
    const t = std.testing;
    const text = "a\nbb\nccc";
    try t.expectEqual(@as(usize, 1), lineOf(text, 0));
    try t.expectEqual(@as(usize, 1), lineOf(text, 1));
    try t.expectEqual(@as(usize, 2), lineOf(text, 2));
    try t.expectEqual(@as(usize, 3), lineOf(text, 6));
    try t.expectEqual(@as(usize, 3), lineOf(text, 100));
}

test "range lines collapse single-line blocks" {
    const t = std.testing;
    const text = "para one\n\npara two\n";
    try t.expectEqual(RangeLines{ .first = 1, .last = 1 }, rangeLines(text, 0, 8));
    try t.expectEqual(RangeLines{ .first = 3, .last = 3 }, rangeLines(text, 10, 18));
    try t.expectEqual(RangeLines{ .first = 1, .last = 3 }, rangeLines(text, 0, text.len));
}

test "range lines trim inter-block blanks" {
    const t = std.testing;
    const text = "first\n\nsecond\n\nthird";
    try t.expectEqual(RangeLines{ .first = 1, .last = 1 }, rangeLines(text, 0, 6));
    try t.expectEqual(RangeLines{ .first = 3, .last = 3 }, rangeLines(text, 6, 14));
    try t.expectEqual(RangeLines{ .first = 5, .last = 5 }, rangeLines(text, 14, text.len));
}

test "set replaces and empty deletes" {
    const t = std.testing;
    var s: Store = .{};
    defer s.deinit(t.allocator);
    try s.set(t.allocator, 0, 8, "fix");
    try t.expectEqualStrings("fix", s.get(0, 8).?);
    try s.set(t.allocator, 0, 8, "fix v2");
    try t.expectEqualStrings("fix v2", s.get(0, 8).?);
    try t.expectEqual(@as(usize, 1), s.count());
    try s.set(t.allocator, 10, 18, "other");
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expectEqualStrings("other", s.get(10, 18).?);
    try s.set(t.allocator, 0, 8, "");
    try t.expect(s.get(0, 8) == null);
    try t.expectEqual(@as(usize, 1), s.count());
}

test "set keeps source order" {
    const t = std.testing;
    var s: Store = .{};
    defer s.deinit(t.allocator);
    try s.set(t.allocator, 10, 18, "b");
    try s.set(t.allocator, 0, 8, "a");
    try t.expectEqual(@as(usize, 0), s.list.items[0].start);
    try t.expectEqual(@as(usize, 10), s.list.items[1].start);
}

test "format uses plain line prefix" {
    const t = std.testing;
    const text = "para one\n\npara two\n";
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try formatComment(&w, text, 10, 18, "fix this");
    try t.expectEqualStrings("L3: fix this\n", w.buffered());
}

test "format continues multiline bodies indented" {
    const t = std.testing;
    const text = "para one\n\npara two\n";
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try formatComment(&w, text, 0, text.len, "one\ntwo");
    try t.expectEqualStrings("L1-L3: one\n  two\n", w.buffered());
}

const testing = std.testing;
