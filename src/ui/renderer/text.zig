//! Wraps span-styled text to a width. One walk both measures (no window)
//! and renders (writes cells), so measured heights always match what is
//! drawn. Inline events drive a style stack: emphasis, strikethrough and
//! links nest up to 8 levels deep.

/// Words made of more pieces than this (many span boundaries inside one
/// word) flush early and may split mid-word.
const max_word_pieces = 16;
const max_style_depth = 8;

/// Entity decoding produces bytes that are not in the source text, and
/// cells hold grapheme slices: decoded text is copied into this frame-
/// scoped buffer, which must live until the frame has been flushed.
var frame_buf: [512]u8 = undefined;
var frame_len: usize = 0;

pub fn beginFrame() void {
    frame_len = 0;
}

fn frameCopy(bytes: []const u8) ?[]const u8 {
    if (frame_len + bytes.len > frame_buf.len) return null;
    const out = frame_buf[frame_len..][0..bytes.len];
    @memcpy(out, bytes);
    frame_len += bytes.len;
    return out;
}

pub fn measure(content: []const u8, width: usize, chain: Document.Chain) usize {
    return layout(null, content, .{}, 0, 0, width, chain);
}

pub fn render(win: vaxis.Window, content: []const u8, base: vaxis.Style, start_row: usize, skip: usize, chain: Document.Chain) usize {
    return layout(win, content, base, start_row, skip, win.width, chain);
}

pub fn layout(win: ?vaxis.Window, content: []const u8, base: vaxis.Style, start_row: usize, skip: usize, width: usize, chain: Document.Chain) usize {
    var lay: Lay = .{
        .win = win,
        .width = @max(width, 1),
        .row = start_row,
        .skip = skip,
    };
    lay.styles[0] = base;
    lay.depth = 1;

    var spans = Document.Spans.initChain(content, chain);
    while (spans.next()) |span| {
        if (lay.clipped()) break;
        switch (span) {
            .text => |t| lay.feedText(t, lay.top()),
            .code => |t| {
                lay.flushWord();
                var style = lay.top();
                style.fg = .{ .index = 6 };
                lay.feedText(t, style);
            },
            .entity => |raw| {
                lay.flushWord();
                var buf: [4]u8 = undefined;
                const decoded = Document.decodeEntity(raw, &buf) orelse raw;
                lay.putText(frameCopy(decoded) orelse raw, lay.top());
            },
            .escape => |char| {
                if (lay.piece_count == max_word_pieces) lay.flushWord();
                lay.pieces[lay.piece_count] = .{ .text = char, .style = lay.top() };
                lay.piece_count += 1;
                lay.word_width += 1;
            },
            .hard_break, .soft_break => {
                lay.flushWord();
                lay.lineBreak();
            },
            .em_open => {
                lay.flushWord();
                var style = lay.top();
                style.italic = true;
                lay.push(style);
            },
            .em_close => {
                lay.flushWord();
                lay.pop();
            },
            .strong_open => {
                lay.flushWord();
                var style = lay.top();
                style.bold = true;
                lay.push(style);
            },
            .strong_close => {
                lay.flushWord();
                lay.pop();
            },
            .strike_open => {
                lay.flushWord();
                var style = lay.top();
                style.strikethrough = true;
                lay.push(style);
            },
            .strike_close => {
                lay.flushWord();
                lay.pop();
            },
            .link => {
                lay.flushWord();
                var style = lay.top();
                style.ul_style = .single;
                style.fg = .{ .index = 4 };
                lay.push(style);
            },
            .link_close => {
                lay.flushWord();
                lay.pop();
            },
        }
    }
    lay.flushWord();
    if (lay.clipped() or lay.skip > 0) return lay.row;
    // The row counter only advances on breaks; count the drawn final line.
    return lay.row + @intFromBool(lay.col > 0);
}

fn gwidth(text: []const u8) usize {
    return vaxis.gwidth.gwidth(text, .unicode);
}

const Piece = struct {
    text: []const u8,
    style: vaxis.Style,
};

const Lay = struct {
    win: ?vaxis.Window,
    width: usize,
    row: usize,
    skip: usize,
    col: usize = 0,
    pending_space: bool = false,
    pieces: [max_word_pieces]Piece = undefined,
    piece_count: usize = 0,
    word_width: usize = 0,
    styles: [max_style_depth]vaxis.Style = undefined,
    depth: usize = 0,

    fn top(self: *Lay) vaxis.Style {
        return self.styles[self.depth - 1];
    }

    fn push(self: *Lay, style: vaxis.Style) void {
        if (self.depth >= max_style_depth) return;
        self.styles[self.depth] = style;
        self.depth += 1;
    }

    fn pop(self: *Lay) void {
        if (self.depth > 1) self.depth -= 1;
    }

    fn clipped(self: *Lay) bool {
        return self.win != null and self.row >= self.win.?.height;
    }

    fn lineBreak(self: *Lay) void {
        if (self.skip > 0) {
            self.skip -= 1;
        } else {
            self.row += 1;
        }
        self.col = 0;
        self.pending_space = false;
    }

    fn put(self: *Lay, g: []const u8, style: vaxis.Style) void {
        const w = gwidth(g);
        if (w == 0) return;
        if (self.col + w > self.width) self.lineBreak();
        if (self.skip == 0 and self.win != null and self.row < self.win.?.height) {
            self.win.?.writeCell(@intCast(self.col), @intCast(self.row), .{
                .char = .{ .grapheme = g, .width = @intCast(w) },
                .style = style,
            });
        }
        self.col += w;
    }

    /// Writes graphemes directly, wrapping mid-word when needed.
    fn putText(self: *Lay, text: []const u8, style: vaxis.Style) void {
        var iter = vaxis.unicode.graphemeIterator(text);
        while (iter.next()) |g| self.put(g.bytes(text), style);
    }

    /// Accumulates one span's text into word pieces, wrapping on spaces
    /// and newlines.
    fn feedText(self: *Lay, text: []const u8, style: vaxis.Style) void {
        var i: usize = 0;
        while (i < text.len) {
            switch (text[i]) {
                ' ', '\t' => {
                    self.flushWord();
                    if (self.col > 0) self.pending_space = true;
                    i += 1;
                },
                '\n' => {
                    self.flushWord();
                    self.lineBreak();
                    i += 1;
                },
                else => {
                    const start = i;
                    while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') i += 1;
                    if (self.piece_count == max_word_pieces) self.flushWord();
                    self.pieces[self.piece_count] = .{ .text = text[start..i], .style = style };
                    self.piece_count += 1;
                    self.word_width += gwidth(text[start..i]);
                },
            }
        }
    }

    /// Writes the pending whitespace and word pieces, wrapping to a fresh
    /// line first when the word does not fit on the current one.
    fn flushWord(self: *Lay) void {
        const pieces = self.pieces[0..self.piece_count];
        const word_width = self.word_width;
        self.piece_count = 0;
        self.word_width = 0;
        // An empty flush keeps the pending space: the next span may start
        // with a word that belongs after it.
        if (pieces.len == 0) return;
        if (self.clipped()) {
            self.pending_space = false;
            return;
        }

        if (word_width >= self.width) {
            if (self.col > 0) self.lineBreak();
        } else if (self.col + @intFromBool(self.pending_space) + word_width > self.width) {
            self.lineBreak();
        }
        if (self.pending_space and self.col > 0) self.put(" ", pieces[0].style);
        self.pending_space = false;

        for (pieces) |piece| {
            self.putText(piece.text, piece.style);
        }
    }
};

const std = @import("std");
const Document = @import("../../Document.zig");
const vaxis = @import("vaxis");

test "wraps words at the width" {
    try testing.expectEqual(@as(usize, 2), measure("hello world", 5, .{}));
    try testing.expectEqual(@as(usize, 1), measure("aa bb cc dd", 11, .{}));
    try testing.expectEqual(@as(usize, 0), measure("", 10, .{}));
}

test "hard wraps words longer than the width" {
    try testing.expectEqual(@as(usize, 3), measure("abcdefghij", 4, .{}));
}

test "keeps hard newlines" {
    try testing.expectEqual(@as(usize, 2), measure("a\nb", 10, .{}));
}

test "spans measure like their text" {
    try testing.expectEqual(@as(usize, 1), measure("**bold** text", 10, .{}));
    try testing.expectEqual(@as(usize, 2), measure("a *b c* d", 4, .{}));
}

test "spaces survive span boundaries" {
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

    _ = render(win, "use `errdefer` to", .{}, 0, 0, .{});
    try testing.expectEqualStrings(" ", win.readCell(3, 0).?.char.grapheme);
    try testing.expectEqualStrings("e", win.readCell(4, 0).?.char.grapheme);
    try testing.expectEqualStrings("r", win.readCell(11, 0).?.char.grapheme);
    try testing.expectEqualStrings(" ", win.readCell(12, 0).?.char.grapheme);
    try testing.expectEqualStrings("t", win.readCell(13, 0).?.char.grapheme);
}

test "line breaks and entities occupy rows" {
    try testing.expectEqual(@as(usize, 2), measure("end  \nnext", 40, .{}));
    try testing.expectEqual(@as(usize, 1), measure("&amp;", 40, .{}));
}

const testing = std.testing;
