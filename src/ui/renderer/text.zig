//! Wraps span-styled text to a width. One walk both measures (no window)
//! and renders (writes cells), so measured heights always match what is
//! drawn.

/// Words made of more pieces than this (many span boundaries inside one
/// word) flush early and may split mid-word.
const max_word_pieces = 16;

pub fn measure(content: []const u8, width: usize) usize {
    return layout(null, content, .{}, 0, 0, width);
}

pub fn render(win: vaxis.Window, content: []const u8, base: vaxis.Style, start_row: usize, skip: usize) usize {
    return layout(win, content, base, start_row, skip, win.width);
}

fn layout(win: ?vaxis.Window, content: []const u8, base: vaxis.Style, start_row: usize, skip: usize, width: usize) usize {
    var lay: Lay = .{
        .win = win,
        .width = @max(width, 1),
        .row = start_row,
        .skip = skip,
    };

    var spans = Document.Spans.init(content);
    while (spans.next()) |span| {
        if (lay.clipped()) break;
        const style = spanStyle(base, span);
        const text: []const u8 = switch (span) {
            inline else => |t| t,
        };
        var i: usize = 0;
        while (i < text.len) {
            switch (text[i]) {
                ' ', '\t' => {
                    lay.flushWord();
                    if (lay.col > 0) lay.pending_space = true;
                    i += 1;
                },
                '\n' => {
                    lay.flushWord();
                    lay.lineBreak();
                    i += 1;
                },
                else => {
                    const start = i;
                    while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') i += 1;
                    if (lay.piece_count == max_word_pieces) lay.flushWord();
                    lay.pieces[lay.piece_count] = .{ .text = text[start..i], .style = style };
                    lay.piece_count += 1;
                    lay.word_width += gwidth(text[start..i]);
                },
            }
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

fn spanStyle(base: vaxis.Style, span: Document.Span) vaxis.Style {
    var style = base;
    switch (span) {
        .text => {},
        .code => style.fg = .{ .index = 6 },
        .bold => style.bold = true,
        .italic => style.italic = true,
        .bold_italic => {
            style.bold = true;
            style.italic = true;
        },
    }
    return style;
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

    /// Writes the pending whitespace and word pieces, wrapping to a fresh
    /// line first when the word does not fit on the current one.
    fn flushWord(self: *Lay) void {
        const pieces = self.pieces[0..self.piece_count];
        const word_width = self.word_width;
        self.piece_count = 0;
        self.word_width = 0;
        if (pieces.len == 0 or self.clipped()) {
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
            var iter = vaxis.unicode.graphemeIterator(piece.text);
            while (iter.next()) |g| self.put(g.bytes(piece.text), piece.style);
        }
    }
};

const std = @import("std");
const Document = @import("../../Document.zig");
const vaxis = @import("vaxis");

test "wraps words at the width" {
    try testing.expectEqual(@as(usize, 2), measure("hello world", 5));
    try testing.expectEqual(@as(usize, 1), measure("aa bb cc dd", 11));
    try testing.expectEqual(@as(usize, 0), measure("", 10));
}

test "hard wraps words longer than the width" {
    try testing.expectEqual(@as(usize, 3), measure("abcdefghij", 4));
}

test "keeps hard newlines" {
    try testing.expectEqual(@as(usize, 2), measure("a\nb", 10));
}

test "spans measure like their text" {
    try testing.expectEqual(@as(usize, 1), measure("**bold** text", 10));
    try testing.expectEqual(@as(usize, 2), measure("a *b c* d", 4));
}

const testing = std.testing;
