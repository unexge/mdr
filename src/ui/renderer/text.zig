//! Wraps span-styled text to a width. One walk both measures (no window)
//! and renders (writes cells), so measured heights always match what is
//! drawn. Inline events drive a style stack: emphasis, strikethrough and
//! links nest up to 8 levels deep.

/// Words made of more pieces than this (many span boundaries inside one
/// word) flush early and may split mid-word.
const max_word_pieces = 16;
const max_style_depth = 8;
/// Buffered cells per line when aligning center/right; wider lines fall
/// back to left alignment for the overflowed remainder.
const max_line_cells = 256;

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

pub fn measure(content: []const u8, width: usize, chain: Document.Chain, refs: ?*Document.RefTable) usize {
    return layout(null, content, .{}, 0, 0, width, chain, .left, refs);
}

pub fn render(win: vaxis.Window, content: []const u8, base: vaxis.Style, start_row: usize, skip: usize, chain: Document.Chain) usize {
    return layout(win, content, base, start_row, skip, win.width, chain, .left, null);
}

pub fn layout(win: ?vaxis.Window, content: []const u8, base: vaxis.Style, start_row: usize, skip: usize, width: usize, chain: Document.Chain, alignment: Document.Alignment, refs: ?*Document.RefTable) usize {
    var lay: Lay = .{
        .win = win,
        .width = @max(width, 1),
        .row = start_row,
        .skip = skip,
        .alignment = alignment,
    };
    lay.formats[0] = .{ .style = base };
    lay.depth = 1;

    // Definitions are scanned once, and only when brackets may need them.
    var spans = if (refs != null and mem.indexOfScalar(u8, content, '[') != null)
        Document.Spans.initChainRefs(content, chain, refs)
    else
        Document.Spans.initChain(content, chain);
    while (spans.next()) |span| {
        if (lay.clipped()) break;
        switch (span) {
            .text => |t| lay.feedText(t, lay.top()),
            .code => |t| {
                lay.flushWord();
                var format = lay.top();
                format.style.fg = Theme.code;
                format.style.bg = Theme.panel;
                lay.feedText(t, format);
            },
            .entity => |raw| {
                lay.flushWord();
                var buf: [4]u8 = undefined;
                const decoded = Document.decodeEntity(raw, &buf) orelse raw;
                lay.putText(frameCopy(decoded) orelse raw, lay.top());
            },
            .escape => |char| {
                if (lay.piece_count == max_word_pieces) lay.flushWord();
                lay.pieces[lay.piece_count] = .{ .text = char, .format = lay.top() };
                lay.piece_count += 1;
                lay.word_width += 1;
            },
            .hard_break => {
                lay.flushWord();
                lay.lineBreak();
            },
            // Soft breaks reflow: source newlines become spaces and the
            // column decides where lines end.
            .soft_break => {
                lay.flushWord();
                if (lay.col > 0) {
                    lay.pending_space = true;
                    lay.pending_space_format = lay.top();
                }
            },
            .em_open => {
                lay.flushWord();
                var format = lay.top();
                format.style.italic = true;
                lay.push(format);
            },
            .em_close => {
                lay.flushWord();
                lay.pop();
            },
            .strong_open => {
                lay.flushWord();
                var format = lay.top();
                format.style.bold = true;
                lay.push(format);
            },
            .strong_close => {
                lay.flushWord();
                lay.pop();
            },
            .strike_open => {
                lay.flushWord();
                var format = lay.top();
                format.style.strikethrough = true;
                format.style.dim = true;
                lay.push(format);
            },
            .strike_close => {
                lay.flushWord();
                lay.pop();
            },
            .link => |link| {
                lay.flushWord();
                var format = lay.top();
                format.style.ul_style = .single;
                format.style.fg = Theme.link;
                format.style.bg = Theme.panel;
                format.link.uri = link.destination;
                lay.push(format);
            },
            .link_close => {
                lay.flushWord();
                lay.pop();
            },
        }
    }
    lay.flushWord();
    lay.flushLine();
    if (lay.clipped() or lay.skip > 0) return lay.row;
    // The row counter only advances on breaks; count the drawn final line.
    return lay.row + @intFromBool(lay.col > 0);
}

fn gwidth(text: []const u8) usize {
    return vaxis.gwidth.gwidth(text, .unicode);
}

const Piece = struct {
    text: []const u8,
    format: Format,
};

const Format = struct {
    style: vaxis.Style,
    link: vaxis.Cell.Hyperlink = .{},
};

const LineCell = struct {
    text: []const u8,
    format: Format,
    width: usize,
};

const Lay = struct {
    win: ?vaxis.Window,
    width: usize,
    row: usize,
    skip: usize,
    alignment: Document.Alignment = .left,
    col: usize = 0,
    pending_space: bool = false,
    pending_space_format: Format = .{ .style = .{} },
    pieces: [max_word_pieces]Piece = undefined,
    piece_count: usize = 0,
    word_width: usize = 0,
    line: [max_line_cells]LineCell = undefined,
    line_count: usize = 0,
    line_width: usize = 0,
    line_plain: bool = false,
    formats: [max_style_depth]Format = undefined,
    depth: usize = 0,

    fn top(self: *Lay) Format {
        return self.formats[self.depth - 1];
    }

    fn push(self: *Lay, format: Format) void {
        if (self.depth >= max_style_depth) return;
        self.formats[self.depth] = format;
        self.depth += 1;
    }

    fn pop(self: *Lay) void {
        if (self.depth > 1) self.depth -= 1;
    }

    fn clipped(self: *Lay) bool {
        return self.win != null and self.row >= self.win.?.height;
    }

    fn lineBreak(self: *Lay) void {
        self.flushLine();
        if (self.skip > 0) {
            self.skip -= 1;
        } else {
            self.row += 1;
        }
        self.col = 0;
        self.pending_space = false;
    }

    /// Writes the buffered line at its aligned offset; skipped, empty and
    /// left-aligned lines need no work. Row and column accounting already
    /// happened in `put`, so measuring never depends on this.
    fn flushLine(self: *Lay) void {
        defer {
            self.line_count = 0;
            self.line_width = 0;
            self.line_plain = false;
        }
        if (self.line_plain or self.skip > 0 or self.alignment == .left) return;
        const win = self.win orelse return;
        if (self.row >= win.height or self.line_count == 0) return;
        var x: usize = switch (self.alignment) {
            .left => 0,
            .center => (self.width -| self.line_width) / 2,
            .right => self.width -| self.line_width,
        };
        for (self.line[0..self.line_count]) |c| {
            win.writeCell(@intCast(x), @intCast(self.row), .{
                .char = .{ .grapheme = c.text, .width = @intCast(c.width) },
                .style = c.format.style,
                .link = c.format.link,
            });
            x += c.width;
        }
    }

    /// Overflow fallback: lines wider than the buffer flush left-aligned
    /// and the rest of the line writes straight through.
    fn flushLineLeft(self: *Lay) void {
        if (self.win) |win| {
            if (self.row < win.height) {
                var x: usize = 0;
                for (self.line[0..self.line_count]) |c| {
                    win.writeCell(@intCast(x), @intCast(self.row), .{
                        .char = .{ .grapheme = c.text, .width = @intCast(c.width) },
                        .style = c.format.style,
                        .link = c.format.link,
                    });
                    x += c.width;
                }
            }
        }
        self.line_count = 0;
        self.line_width = 0;
        self.line_plain = true;
    }

    fn put(self: *Lay, g: []const u8, format: Format) void {
        const w = gwidth(g);
        if (w == 0) return;
        if (self.col + w > self.width) self.lineBreak();
        if (self.skip == 0) self.write(g, format, w);
        self.col += w;
    }

    fn write(self: *Lay, g: []const u8, format: Format, w: usize) void {
        const win = self.win orelse return;
        if (self.alignment == .left or self.line_plain) {
            if (self.row < win.height) {
                win.writeCell(@intCast(self.col), @intCast(self.row), .{
                    .char = .{ .grapheme = g, .width = @intCast(w) },
                    .style = format.style,
                    .link = format.link,
                });
            }
            return;
        }
        if (self.line_count >= max_line_cells) self.flushLineLeft();
        if (self.line_plain) {
            if (self.row < win.height) {
                win.writeCell(@intCast(self.col), @intCast(self.row), .{
                    .char = .{ .grapheme = g, .width = @intCast(w) },
                    .style = format.style,
                    .link = format.link,
                });
            }
            return;
        }
        self.line[self.line_count] = .{ .text = g, .format = format, .width = w };
        self.line_count += 1;
        self.line_width += w;
    }

    /// Writes graphemes directly, wrapping mid-word when needed.
    fn putText(self: *Lay, text: []const u8, format: Format) void {
        var iter = vaxis.unicode.graphemeIterator(text);
        while (iter.next()) |g| self.put(g.bytes(text), format);
    }

    /// Accumulates one span's text into word pieces, wrapping on spaces
    /// and newlines.
    fn feedText(self: *Lay, text: []const u8, format: Format) void {
        var i: usize = 0;
        while (i < text.len) {
            switch (text[i]) {
                ' ', '\t' => {
                    self.flushWord();
                    if (self.col > 0) {
                        self.pending_space = true;
                        self.pending_space_format = format;
                    }
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
                    self.pieces[self.piece_count] = .{ .text = text[start..i], .format = format };
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
        if (self.pending_space and self.col > 0) self.put(" ", self.pending_space_format);
        self.pending_space = false;

        for (pieces) |piece| {
            self.putText(piece.text, piece.format);
        }
    }
};

const std = @import("std");
const mem = std.mem;
const Document = @import("../../Document.zig");
const Theme = @import("../Theme.zig");
const vaxis = @import("vaxis");

test "wraps words at the width" {
    try testing.expectEqual(@as(usize, 2), measure("hello world", 5, .{}, null));
    try testing.expectEqual(@as(usize, 1), measure("aa bb cc dd", 11, .{}, null));
    try testing.expectEqual(@as(usize, 0), measure("", 10, .{}, null));
}

test "hard wraps words longer than the width" {
    try testing.expectEqual(@as(usize, 3), measure("abcdefghij", 4, .{}, null));
}

test "soft breaks reflow, hard breaks keep lines" {
    try testing.expectEqual(@as(usize, 1), measure("a\nb", 10, .{}, null));
    try testing.expectEqual(@as(usize, 1), measure("aa bb\ncc dd", 11, .{}, null));
    try testing.expectEqual(@as(usize, 2), measure("a  \nb", 10, .{}, null));
}

test "spans measure like their text" {
    try testing.expectEqual(@as(usize, 1), measure("**bold** text", 10, .{}, null));
    try testing.expectEqual(@as(usize, 2), measure("a *b c* d", 4, .{}, null));
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
    try testing.expectEqual(@as(usize, 2), measure("end  \nnext", 40, .{}, null));
    try testing.expectEqual(@as(usize, 1), measure("&amp;", 40, .{}, null));
}

test "measures with reference links resolved" {
    var doc = Document.init("[click][here] and more text here\n\n[here]: /url\n");
    const p = doc.next().?.paragraph;
    try testing.expectEqual(layout(null, p.content, .{}, 0, 0, 20, p.chain, .left, p.refs), measure(p.content, 20, p.chain, p.refs));
    try testing.expectEqual(@as(usize, 1), measure("[click][here]", 6, .{}, p.refs));
    try testing.expectEqual(@as(usize, 3), measure("[click][here]", 6, .{}, null));
}

test "renders center and right alignment" {
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 4, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 10,
        .height = 4,
        .screen = &screen,
    };

    _ = layout(win, "ab", .{}, 0, 0, 10, .{}, .center, null);
    try testing.expectEqualStrings("a", win.readCell(4, 0).?.char.grapheme);
    _ = layout(win, "ab", .{}, 1, 0, 10, .{}, .right, null);
    try testing.expectEqualStrings("a", win.readCell(8, 1).?.char.grapheme);
    _ = layout(win, "aa bb cc", .{}, 2, 0, 5, .{}, .center, null);
    try testing.expectEqualStrings("c", win.readCell(1, 3).?.char.grapheme);
}

const testing = std.testing;
