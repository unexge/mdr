//! Incremental search state: fixed query buffer, debounced commit,
//! ASCII case-insensitive matching and highlight styles.

const Search = @This();

open: bool = false,
len: usize = 0,
buf: [max_query]u8 = undefined,
cursor: usize = 0,
generation: u64 = 0,
no_match: bool = false,
/// Non-overlapping matches of the current query in document order.
total: usize = 0,
index: usize = 0,
offset: ?usize = null,
focus_entry: ?usize = null,
focus_local: usize = 0,
count_buf: [48]u8 = undefined,
count_len: usize = 0,

pub const max_query = 128;
pub const debounce_ns: i96 = 100_000_000;

pub fn query(self: *const Search) []const u8 {
    return self.buf[0..self.len];
}

pub fn activate(self: *Search) void {
    self.open = true;
    self.cursor = self.len;
    self.no_match = false;
}

pub fn cancel(self: *Search) void {
    self.open = false;
    self.len = 0;
    self.cursor = 0;
    self.no_match = false;
    self.total = 0;
    self.index = 0;
    self.offset = null;
    self.focus_entry = null;
    self.focus_local = 0;
}

pub fn confirm(self: *Search) void {
    self.open = false;
    self.no_match = false;
}

pub fn clear(self: *Search) void {
    self.len = 0;
    self.cursor = 0;
    self.generation +%= 1;
    self.no_match = false;
    self.total = 0;
    self.index = 0;
    self.offset = null;
    self.focus_entry = null;
    self.focus_local = 0;
}

fn invalidate(self: *Search) void {
    self.generation +%= 1;
    self.no_match = false;
    self.total = 0;
    self.index = 0;
    self.offset = null;
    self.focus_entry = null;
    self.focus_local = 0;
}

pub fn insert(self: *Search, text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < 32 or c == 127) return false;
    if (self.len + text.len > max_query) return false;
    mem.copyBackwards(u8, self.buf[self.cursor + text.len ..][0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
    @memcpy(self.buf[self.cursor..][0..text.len], text);
    self.len += text.len;
    self.cursor += text.len;
    self.invalidate();
    return true;
}

pub fn backspace(self: *Search) bool {
    if (self.cursor == 0) return false;
    var start = self.cursor - 1;
    while (start > 0 and self.buf[start] & 0xC0 == 0x80) start -= 1;
    const n = self.cursor - start;
    mem.copyForwards(u8, self.buf[start..][0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
    self.len -= n;
    self.cursor = start;
    self.invalidate();
    return true;
}

pub fn deleteAt(self: *Search) bool {
    if (self.cursor >= self.len) return false;
    var end = self.cursor + 1;
    while (end < self.len and self.buf[end] & 0xC0 == 0x80) end += 1;
    const n = end - self.cursor;
    mem.copyForwards(u8, self.buf[self.cursor..][0 .. self.len - end], self.buf[end..self.len]);
    self.len -= n;
    self.invalidate();
    return true;
}

pub fn moveLeft(self: *Search) void {
    if (self.cursor == 0) return;
    self.cursor -= 1;
    while (self.cursor > 0 and self.buf[self.cursor] & 0xC0 == 0x80) self.cursor -= 1;
}

pub fn moveRight(self: *Search) void {
    if (self.cursor >= self.len) return;
    self.cursor += 1;
    while (self.cursor < self.len and self.buf[self.cursor] & 0xC0 == 0x80) self.cursor += 1;
}

/// "3/12" for the counter overlay; stable storage on the struct since
/// cells only borrow the slice until the frame flushes.
pub fn countText(self: *Search) []const u8 {
    const shown = if (self.total == 0) 0 else self.index + 1;
    const slice = std.fmt.bufPrint(self.count_buf[0..], "{d}/{d}", .{ shown, self.total }) catch &.{};
    self.count_len = slice.len;
    return self.count_buf[0..self.count_len];
}

pub fn findFirst(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (lower(haystack[i + j]) != lower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}

pub fn countMatches(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        const rel = findFirst(haystack[pos..], needle) orelse break;
        n += 1;
        pos += rel + needle.len;
    }
    return n;
}

/// Last non-overlapping match starting before `before`.
pub fn findLastBefore(haystack: []const u8, needle: []const u8, before: usize) ?usize {
    if (needle.len == 0) return null;
    var last: ?usize = null;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        const rel = findFirst(haystack[pos..], needle) orelse break;
        const s = pos + rel;
        if (s >= before) break;
        last = s;
        pos = s + needle.len;
    }
    return last;
}

/// How many non-overlapping matches start before `offset`.
pub fn indexOf(haystack: []const u8, needle: []const u8, offset: usize) usize {
    if (needle.len == 0) return 0;
    var idx: usize = 0;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        const rel = findFirst(haystack[pos..], needle) orelse break;
        const s = pos + rel;
        if (s >= offset) break;
        idx += 1;
        pos = s + needle.len;
    }
    return idx;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn highlight(base: vaxis.Style) vaxis.Style {
    var out = base;
    out.bg = Theme.gold;
    out.fg = Theme.panel;
    return out;
}

pub fn focus(base: vaxis.Style) vaxis.Style {
    var out = highlight(base);
    out.bg = Theme.accent;
    out.bold = true;
    return out;
}

var seq_dispenser: u32 = 0;
var entry_active: bool = false;
var entry_last_id: u32 = 0;
var entry_run_count: usize = 0;
var entry_target: usize = 0;

pub fn beginFrame() void {
    seq_dispenser = 0;
    entry_active = false;
    entry_last_id = 0;
    entry_run_count = 0;
}

pub fn nextSeq() u32 {
    seq_dispenser +%= 1;
    if (seq_dispenser == 0) seq_dispenser = 1;
    return seq_dispenser;
}

/// Scopes focus resolution to one entry render; renderers call this around
/// each entry so nested layouts share the scope.
pub fn setEntryFocus(active: bool, local: usize) void {
    entry_active = active;
    entry_last_id = 0;
    entry_run_count = 0;
    entry_target = local;
}

/// True for every cell of the target run. Runs are counted as their first
/// cell is written, so skipped rows never shift the ordinals.
pub fn runIsFocus(id: u32) bool {
    if (!entry_active or id == 0) return false;
    if (id != entry_last_id) {
        entry_last_id = id;
        entry_run_count += 1;
    }
    return entry_run_count - 1 == entry_target;
}

const mem = std.mem;
const std = @import("std");
const vaxis = @import("vaxis");
const Theme = @import("Theme.zig");

test "insert and backspace edit utf8 by chars" {
    var s: Search = .{};
    try testing.expect(s.insert("hi"));
    try testing.expectEqualStrings("hi", s.query());
    try testing.expectEqual(@as(usize, 2), s.cursor);
    try testing.expect(s.backspace());
    try testing.expectEqualStrings("h", s.query());

    var u: Search = .{};
    try testing.expect(u.insert("é"));
    try testing.expectEqual(@as(usize, 2), u.len);
    try testing.expectEqual(@as(usize, 2), u.cursor);
    u.moveLeft();
    try testing.expectEqual(@as(usize, 0), u.cursor);
    u.moveRight();
    try testing.expectEqual(@as(usize, 2), u.cursor);
    try testing.expect(u.backspace());
    try testing.expectEqual(@as(usize, 0), u.len);
}

test "insert respects capacity and cursor" {
    var s: Search = .{};
    s.len = max_query - 1;
    s.cursor = s.len;
    try testing.expect(!s.insert("ab"));
    try testing.expect(s.insert("a"));
    try testing.expectEqual(max_query, s.len);

    var m: Search = .{};
    try testing.expect(m.insert("ac"));
    m.moveLeft();
    try testing.expect(m.insert("b"));
    try testing.expectEqualStrings("abc", m.query());
    try testing.expect(m.deleteAt());
    try testing.expectEqualStrings("ab", m.query());
}

test "insert rejects control characters" {
    var s: Search = .{};
    try testing.expect(!s.insert("\x08"));
    try testing.expect(!s.insert("a\x01b"));
    try testing.expect(!s.insert(&[_]u8{127}));
    try testing.expectEqual(@as(usize, 0), s.len);
    try testing.expect(s.insert("ok"));
    try testing.expectEqualStrings("ok", s.query());
}

test "edits invalidate navigation state" {
    var s: Search = .{};
    try testing.expect(s.insert("hi"));
    s.total = 3;
    s.index = 1;
    s.offset = 10;
    try testing.expect(s.backspace());
    try testing.expectEqual(@as(?usize, null), s.offset);
    try testing.expectEqual(@as(usize, 0), s.total);
    s.total = 3;
    s.offset = 10;
    s.clear();
    try testing.expectEqual(@as(usize, 0), s.len);
    try testing.expectEqual(@as(?usize, null), s.offset);
}

test "findFirst is ascii case-insensitive" {
    try testing.expectEqual(@as(?usize, 0), findFirst("Hello world", "hello"));
    try testing.expectEqual(@as(?usize, 6), findFirst("Hello WORLD", "world"));
    try testing.expectEqual(@as(?usize, null), findFirst("abc", "d"));
    try testing.expectEqual(@as(?usize, null), findFirst("abc", ""));
    try testing.expectEqual(@as(?usize, 1), findFirst("aÉb", "É"));
}

test "match counting and neighbours" {
    try testing.expectEqual(@as(usize, 3), countMatches("aa aa aa", "aa"));
    try testing.expectEqual(@as(usize, 1), countMatches("aaa", "aa"));
    try testing.expectEqual(@as(usize, 0), countMatches("abc", ""));
    try testing.expectEqual(@as(?usize, 6), findLastBefore("aa aa aa", "aa", 7));
    try testing.expectEqual(@as(?usize, 3), findLastBefore("aa aa aa", "aa", 6));
    try testing.expectEqual(@as(?usize, null), findLastBefore("aa aa aa", "aa", 0));
    try testing.expectEqual(@as(usize, 0), indexOf("aa aa aa", "aa", 0));
    try testing.expectEqual(@as(usize, 1), indexOf("aa aa aa", "aa", 3));
    try testing.expectEqual(@as(usize, 2), indexOf("aa aa aa", "aa", 6));
}

test "counter text" {
    var s: Search = .{};
    s.total = 12;
    s.index = 2;
    try testing.expectEqualStrings("3/12", s.countText());
    s.total = 0;
    try testing.expectEqualStrings("0/0", s.countText());
}

test "entry focus tracks written runs" {
    beginFrame();
    setEntryFocus(true, 1);
    try testing.expect(!runIsFocus(5));
    try testing.expect(runIsFocus(6));
    try testing.expect(runIsFocus(6));
    try testing.expect(!runIsFocus(7));
    setEntryFocus(false, 0);
    try testing.expect(!runIsFocus(8));
    beginFrame();
    setEntryFocus(true, 0);
    try testing.expect(runIsFocus(8));
}

test "highlight keeps emphasis and swaps colors" {
    const base: vaxis.Style = .{ .bold = true, .italic = true };
    const hl = highlight(base);
    try testing.expect(hl.bold);
    try testing.expect(hl.italic);
    try testing.expect(hl.bg.eql(Theme.gold));
    try testing.expect(hl.fg.eql(Theme.panel));
    const fc = focus(base);
    try testing.expect(fc.bg.eql(Theme.accent));
    try testing.expect(fc.bold);
}

const testing = std.testing;
