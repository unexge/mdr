//! Multiline comment editor: fixed buffer with logical-line cursor.
//!
//! The buffer avoids allocation while typing; the caller dupes on save.
//! Cursor moves are UTF-8 aware at the byte level, matching `Search`.

const Editor = @This();

buf: [max_len]u8 = undefined,
len: usize = 0,
cursor: usize = 0,

pub const max_len = 1024;

pub fn clear(self: *Editor) void {
    self.len = 0;
    self.cursor = 0;
}

pub fn load(self: *Editor, content: []const u8) void {
    const n = @min(content.len, self.buf.len);
    @memcpy(self.buf[0..n], content[0..n]);
    self.len = n;
    self.cursor = n;
    while (self.cursor > 0 and !isCharStart(self.buf[self.cursor - 1]) and self.buf[self.cursor - 1] != '\n') {
        self.cursor -= 1;
    }
}

pub fn text(self: *const Editor) []const u8 {
    return self.buf[0..self.len];
}

fn allowed(byte: u8) bool {
    if (byte == '\n' or byte == '\t') return true;
    if (byte < 32 or byte == 127) return false;
    return true;
}

pub fn insert(self: *Editor, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |c| if (!allowed(c)) return false;
    if (self.len + bytes.len > self.buf.len) return false;
    mem.copyBackwards(u8, self.buf[self.cursor + bytes.len ..][0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
    @memcpy(self.buf[self.cursor..][0..bytes.len], bytes);
    self.len += bytes.len;
    self.cursor += bytes.len;
    return true;
}

pub fn insertNewline(self: *Editor) bool {
    return self.insert("\n");
}

pub fn backspace(self: *Editor) bool {
    if (self.cursor == 0) return false;
    var start = self.cursor - 1;
    while (start > 0 and isContinuation(self.buf[start])) start -= 1;
    const n = self.cursor - start;
    mem.copyForwards(u8, self.buf[start..][0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
    self.len -= n;
    self.cursor = start;
    return true;
}

pub fn deleteAt(self: *Editor) bool {
    if (self.cursor >= self.len) return false;
    var end = self.cursor + 1;
    while (end < self.len and isContinuation(self.buf[end])) end += 1;
    const n = end - self.cursor;
    mem.copyForwards(u8, self.buf[self.cursor..][0 .. self.len - end], self.buf[end..self.len]);
    self.len -= n;
    return true;
}

pub fn moveLeft(self: *Editor) void {
    if (self.cursor == 0) return;
    self.cursor -= 1;
    while (self.cursor > 0 and isContinuation(self.buf[self.cursor])) self.cursor -= 1;
}

pub fn moveRight(self: *Editor) void {
    if (self.cursor >= self.len) return;
    self.cursor += 1;
    while (self.cursor < self.len and isContinuation(self.buf[self.cursor])) self.cursor += 1;
}

pub fn lineStart(self: *const Editor, cursor: usize) usize {
    var i = cursor;
    while (i > 0 and self.buf[i - 1] != '\n') i -= 1;
    return i;
}

pub fn lineEnd(self: *const Editor, cursor: usize) usize {
    var i = cursor;
    while (i < self.len and self.buf[i] != '\n') i += 1;
    return i;
}

pub fn lineIndex(self: *const Editor, cursor: usize) usize {
    var idx: usize = 0;
    var i: usize = 0;
    while (i < cursor) : (i += 1) {
        if (self.buf[i] == '\n') idx += 1;
    }
    return idx;
}

pub fn lineCount(self: *const Editor) usize {
    if (self.len == 0) return 1;
    var n: usize = 1;
    for (self.buf[0..self.len]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

fn lineStartOf(self: *const Editor, index: usize) usize {
    var idx: usize = 0;
    var i: usize = 0;
    while (i < self.len) {
        if (idx == index) return i;
        if (self.buf[i] == '\n') idx += 1;
        i += 1;
    }
    return self.len;
}

pub fn moveUp(self: *Editor) void {
    const col = self.cursor - self.lineStart(self.cursor);
    const idx = self.lineIndex(self.cursor);
    if (idx == 0) {
        self.cursor = self.lineStart(self.cursor);
        return;
    }
    const target_start = self.lineStartOf(idx - 1);
    const target_end = self.lineEnd(target_start);
    self.cursor = @min(target_start + col, target_end);
    self.snapToCharStart();
}

pub fn moveDown(self: *Editor) void {
    const col = self.cursor - self.lineStart(self.cursor);
    const idx = self.lineIndex(self.cursor);
    if (idx + 1 >= self.lineCount()) {
        self.cursor = self.lineEnd(self.cursor);
        return;
    }
    const target_start = self.lineStartOf(idx + 1);
    const target_end = self.lineEnd(target_start);
    self.cursor = @min(target_start + col, target_end);
    self.snapToCharStart();
}

fn snapToCharStart(self: *Editor) void {
    while (self.cursor < self.len and isContinuation(self.buf[self.cursor])) self.cursor += 1;
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

fn isCharStart(b: u8) bool {
    return b & 0xC0 != 0x80;
}

const std = @import("std");
const mem = std.mem;

test "insert accepts newlines and rejects controls" {
    const t = std.testing;
    var e: Editor = .{};
    try t.expect(e.insert("hi"));
    try t.expect(e.insertNewline());
    try t.expect(e.insert("there"));
    try t.expectEqualStrings("hi\nthere", e.text());
    try t.expect(!e.insert("\x01"));
    try t.expect(!e.insert(&[_]u8{127}));
    try t.expectEqualStrings("hi\nthere", e.text());
}

test "insert respects capacity" {
    const t = std.testing;
    var e: Editor = .{};
    e.len = max_len - 1;
    e.cursor = e.len;
    try t.expect(!e.insert("ab"));
    try t.expect(e.insert("a"));
    try t.expectEqual(max_len, e.len);
}

test "backspace deletes across newline" {
    const t = std.testing;
    var e: Editor = .{};
    try t.expect(e.insert("a\nb"));
    try t.expect(e.backspace());
    try t.expectEqualStrings("a\n", e.text());
    try t.expect(e.backspace());
    try t.expectEqualStrings("a", e.text());
}

test "left right move by utf8 chars" {
    const t = std.testing;
    var e: Editor = .{};
    try t.expect(e.insert("é"));
    try t.expectEqual(@as(usize, 2), e.len);
    e.moveLeft();
    try t.expectEqual(@as(usize, 0), e.cursor);
    e.moveRight();
    try t.expectEqual(@as(usize, 2), e.cursor);
    try t.expect(e.backspace());
    try t.expectEqual(@as(usize, 0), e.len);
}

test "up and down keep column across logical lines" {
    const t = std.testing;
    var e: Editor = .{};
    try t.expect(e.insert("abcd\nefgh\nwxyz"));
    e.cursor = 2;
    e.moveDown();
    try t.expectEqual(@as(usize, 7), e.cursor);
    e.moveDown();
    try t.expectEqual(@as(usize, 12), e.cursor);
    e.moveUp();
    try t.expectEqual(@as(usize, 7), e.cursor);
    e.moveUp();
    try t.expectEqual(@as(usize, 2), e.cursor);
}

test "up at first line goes to start, down at last goes to end" {
    const t = std.testing;
    var e: Editor = .{};
    try t.expect(e.insert("ab\ncd"));
    e.cursor = 1;
    e.moveUp();
    try t.expectEqual(@as(usize, 0), e.cursor);
    e.cursor = 4;
    e.moveDown();
    try t.expectEqual(@as(usize, 5), e.cursor);
}

test "load clamps to capacity on char boundary" {
    const t = std.testing;
    var e: Editor = .{};
    var big: [max_len + 8]u8 = undefined;
    @memset(&big, 'x');
    e.load(&big);
    try t.expectEqual(max_len, e.len);
    try t.expectEqual(max_len, e.cursor);
}

const testing = std.testing;
