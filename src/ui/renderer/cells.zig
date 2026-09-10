//! Cell-level drawing shared by diagram renderers: merged line
//! junctions, overwriting markers and text, display widths.
//!
//! Cells retain grapheme slices without copying; every slice passed in
//! must outlive the frame (static text or input slices, never buffers).

const vaxis = @import("vaxis");

pub const square = [_][]const u8{ "┌", "┐", "└", "┘" };
pub const round = [_][]const u8{ "╭", "╮", "╰", "╯" };
pub const diamond = [_][]const u8{ "◇", "◇", "◇", "◇" };

pub fn box(
    win: vaxis.Window,
    x: usize,
    y: usize,
    bw: usize,
    label: []const u8,
    corners: [4][]const u8,
    start_row: usize,
    skip: usize,
    style: vaxis.Style,
) void {
    boxHeight(win, x, y, bw, 3, label, corners, start_row, skip, style);
}

pub fn boxHeight(
    win: vaxis.Window,
    x: usize,
    y: usize,
    bw: usize,
    height: usize,
    label: []const u8,
    corners: [4][]const u8,
    start_row: usize,
    skip: usize,
    style: vaxis.Style,
) void {
    var fr: usize = 0;
    while (fr < height) : (fr += 1) {
        var fc: usize = 0;
        while (fc < bw) : (fc += 1) putRaw(win, y + fr, x + fc, start_row, skip, " ", style);
    }
    putRaw(win, y, x, start_row, skip, corners[0], style);
    var c: usize = 1;
    while (c + 1 < bw) : (c += 1) putRaw(win, y, x + c, start_row, skip, "─", style);
    putRaw(win, y, x + bw - 1, start_row, skip, corners[1], style);
    for (1..height - 1) |row| {
        putRaw(win, y + row, x, start_row, skip, "│", style);
        putRaw(win, y + row, x + bw - 1, start_row, skip, "│", style);
    }
    var lines: LineIterator = .{ .remaining = label };
    var row: usize = 1;
    while (lines.next()) |line| : (row += 1) {
        if (row + 1 >= height) break;
        putText(win, y + row, x + 2, start_row, skip, line, x + bw - 2, style);
    }
    putRaw(win, y + height - 1, x, start_row, skip, corners[2], style);
    c = 1;
    while (c + 1 < bw) : (c += 1) putRaw(win, y + height - 1, x + c, start_row, skip, "─", style);
    putRaw(win, y + height - 1, x + bw - 1, start_row, skip, corners[3], style);
}

const DiagramTextIterator = struct {
    remaining: []const u8,

    fn next(self: *DiagramTextIterator) ?[]const u8 {
        if (self.remaining.len == 0) return null;
        if (self.remaining[0] == '\n') {
            self.remaining = self.remaining[1..];
            return " ";
        }
        if (self.remaining[0] == '\r') {
            self.remaining = self.remaining[1..];
            return self.next();
        }
        for ([_][]const u8{ "<br>", "<br/>", "<br />" }) |tag| {
            if (startsWithIgnoreCase(self.remaining, tag)) {
                self.remaining = self.remaining[tag.len..];
                return " ";
            }
        }
        if (self.remaining[0] == '#' or self.remaining[0] == '&') {
            if (mem.indexOfScalar(u8, self.remaining, ';')) |end| {
                const entity = self.remaining[1..end];
                const entities = [_]struct { name: []const u8, value: []const u8 }{
                    .{ .name = "9829", .value = "♥" },
                    .{ .name = "infin", .value = "∞" },
                    .{ .name = "quot", .value = "\"" },
                    .{ .name = "35", .value = "#" },
                    .{ .name = "59", .value = ";" },
                    .{ .name = "amp", .value = "&" },
                    .{ .name = "lt", .value = "<" },
                    .{ .name = "gt", .value = ">" },
                    .{ .name = "nbsp", .value = " " },
                };
                for (entities) |entry| {
                    if (!mem.eql(u8, entity, entry.name)) continue;
                    self.remaining = self.remaining[end + 1 ..];
                    return entry.value;
                }
            }
        }
        var graphemes = vaxis.unicode.graphemeIterator(self.remaining);
        const grapheme = graphemes.next() orelse return null;
        const bytes = grapheme.bytes(self.remaining);
        self.remaining = self.remaining[bytes.len..];
        return bytes;
    }
};

pub const LineIterator = struct {
    remaining: []const u8,
    done: bool = false,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.done) return null;
        var index: usize = 0;
        while (index < self.remaining.len) : (index += 1) {
            if (self.remaining[index] == '\n') {
                const line = mem.trimEnd(u8, self.remaining[0..index], "\r");
                self.remaining = self.remaining[index + 1 ..];
                return line;
            }
            for ([_][]const u8{ "<br>", "<br/>", "<br />" }) |tag| {
                if (!startsWithIgnoreCase(self.remaining[index..], tag)) continue;
                const line = self.remaining[0..index];
                self.remaining = self.remaining[index + tag.len ..];
                return line;
            }
        }
        self.done = true;
        return self.remaining;
    }
};

pub fn lineCount(text: []const u8) usize {
    var count: usize = 0;
    var lines: LineIterator = .{ .remaining = text };
    while (lines.next() != null) count += 1;
    return count;
}

pub fn maxLineWidth(text: []const u8) usize {
    var width: usize = 0;
    var lines: LineIterator = .{ .remaining = text };
    while (lines.next()) |line| width = @max(width, labelWidth(line));
    return width;
}

pub fn wrappedLineCount(text: []const u8, max_width: usize) usize {
    if (max_width == 0) return lineCount(text);
    var count: usize = 0;
    var lines: LineIterator = .{ .remaining = text };
    while (lines.next()) |line| {
        var col: usize = 0;
        var graphemes: DiagramTextIterator = .{ .remaining = line };
        while (graphemes.next()) |grapheme| {
            const width = vaxis.gwidth.gwidth(grapheme, .unicode);
            if (width == 0) continue;
            if (col > 0 and col + width > max_width) {
                count += 1;
                col = 0;
            }
            col += width;
        }
        count += 1;
    }
    return count;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (text[0..prefix.len], prefix) |actual, expected| {
        if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) return false;
    }
    return true;
}

pub fn labelWidth(label: []const u8) usize {
    var width: usize = 0;
    var iter: DiagramTextIterator = .{ .remaining = label };
    while (iter.next()) |grapheme| width += vaxis.gwidth.gwidth(grapheme, .unicode);
    return width;
}

pub fn putLine(win: vaxis.Window, r: usize, c: usize, start_row: usize, skip: usize, glyph: []const u8, style: vaxis.Style) void {
    if (r < skip) return;
    const rr = start_row + (r - skip);
    if (rr >= win.height or c >= win.width) return;
    const own = maskOf(glyph) orelse {
        win.writeCell(@intCast(c), @intCast(rr), .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style });
        return;
    };
    var mask = own;
    if (win.readCell(@intCast(c), @intCast(rr))) |cell| {
        const existing = cell.char.grapheme;
        if (isTerminalGlyph(existing)) return;
        if (!isBlank(existing)) mask |= maskOf(existing) orelse 0;
    }
    const out = if (mask == own) glyph else glyphFor(mask);
    win.writeCell(@intCast(c), @intCast(rr), .{ .char = .{ .grapheme = out, .width = 1 }, .style = style });
}

pub fn putRaw(win: vaxis.Window, r: usize, c: usize, start_row: usize, skip: usize, glyph: []const u8, style: vaxis.Style) void {
    if (r < skip) return;
    const rr = start_row + (r - skip);
    if (rr >= win.height or c >= win.width) return;
    win.writeCell(@intCast(c), @intCast(rr), .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style });
}

pub fn putDotted(win: vaxis.Window, r: usize, c: usize, start_row: usize, skip: usize, style: vaxis.Style) void {
    putPattern(win, r, c, start_row, skip, "┄", style);
}

pub fn putDottedVertical(win: vaxis.Window, r: usize, c: usize, start_row: usize, skip: usize, style: vaxis.Style) void {
    putPattern(win, r, c, start_row, skip, "┊", style);
}

pub fn putHeavy(win: vaxis.Window, r: usize, c: usize, start_row: usize, skip: usize, horizontal: bool, style: vaxis.Style) void {
    if (r < skip) return;
    const rr = start_row + (r - skip);
    if (rr >= win.height or c >= win.width) return;
    if (win.readCell(@intCast(c), @intCast(rr))) |cell| {
        if (!isBlank(cell.char.grapheme)) {
            putLine(win, r, c, start_row, skip, if (horizontal) "─" else "│", style);
            return;
        }
    }
    putRaw(win, r, c, start_row, skip, if (horizontal) "━" else "┃", style);
}

fn putPattern(win: vaxis.Window, r: usize, c: usize, start_row: usize, skip: usize, glyph: []const u8, style: vaxis.Style) void {
    if (r < skip) return;
    const rr = start_row + (r - skip);
    if (rr >= win.height or c >= win.width) return;
    if (win.readCell(@intCast(c), @intCast(rr))) |cell| {
        if (!isBlank(cell.char.grapheme)) return;
    }
    win.writeCell(@intCast(c), @intCast(rr), .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style });
}

pub fn putText(win: vaxis.Window, r: usize, c0: usize, start_row: usize, skip: usize, text: []const u8, max_c: usize, style: vaxis.Style) void {
    if (r < skip) return;
    const rr = start_row + (r - skip);
    if (rr >= win.height) return;
    var c = c0;
    var iter: DiagramTextIterator = .{ .remaining = text };
    while (iter.next()) |bytes| {
        const gw = vaxis.gwidth.gwidth(bytes, .unicode);
        if (gw == 0) continue;
        if (c + gw > max_c or c + gw > win.width) break;
        win.writeCell(@intCast(c), @intCast(rr), .{ .char = .{ .grapheme = bytes, .width = @intCast(gw) }, .style = style });
        c += gw;
    }
}

pub fn putWrappedText(
    win: vaxis.Window,
    r: usize,
    c0: usize,
    start_row: usize,
    skip: usize,
    text: []const u8,
    max_width: usize,
    max_c: usize,
    style: vaxis.Style,
) void {
    var row = r;
    var lines: LineIterator = .{ .remaining = text };
    while (lines.next()) |line| : (row += 1) {
        var col: usize = 0;
        var graphemes: DiagramTextIterator = .{ .remaining = line };
        while (graphemes.next()) |bytes| {
            const width = vaxis.gwidth.gwidth(bytes, .unicode);
            if (width == 0) continue;
            if (col > 0 and col + width > max_width) {
                row += 1;
                col = 0;
            }
            if (row >= skip) {
                const visible_row = start_row + (row - skip);
                if (visible_row >= win.height or c0 + col + width > max_c or c0 + col + width > win.width) break;
                win.writeCell(@intCast(c0 + col), @intCast(visible_row), .{
                    .char = .{ .grapheme = bytes, .width = @intCast(width) },
                    .style = style,
                });
            }
            col += width;
        }
    }
}

pub fn putTextLink(win: vaxis.Window, r: usize, c0: usize, start_row: usize, skip: usize, text: []const u8, max_c: usize, style: vaxis.Style, uri: []const u8) void {
    if (r < skip) return;
    const rr = start_row + (r - skip);
    if (rr >= win.height) return;
    var col = c0;
    var iter: DiagramTextIterator = .{ .remaining = text };
    while (iter.next()) |bytes| {
        const width = vaxis.gwidth.gwidth(bytes, .unicode);
        if (width == 0) continue;
        if (col + width > max_c or col + width > win.width) break;
        win.writeCell(@intCast(col), @intCast(rr), .{
            .char = .{ .grapheme = bytes, .width = @intCast(width) },
            .style = style,
            .link = .{ .uri = uri },
        });
        col += width;
    }
}

fn isBlank(grapheme: []const u8) bool {
    return grapheme.len == 0 or (grapheme.len == 1 and grapheme[0] == ' ');
}

fn isTerminalGlyph(grapheme: []const u8) bool {
    for ([_][]const u8{ "▼", "▲", "►", "◄", "↗", "↖", "↘", "↙", "╲", "╱", "○", "×", ">", "<" }) |glyph| {
        if (mem.eql(u8, grapheme, glyph)) return true;
    }
    return false;
}

fn maskOf(grapheme: []const u8) ?u4 {
    if (grapheme.len == 1) return if (grapheme[0] == ' ') 0 else null;
    if (mem.eql(u8, grapheme, "─")) return 0b0011;
    if (mem.eql(u8, grapheme, "│")) return 0b1100;
    if (mem.eql(u8, grapheme, "┌") or mem.eql(u8, grapheme, "╭")) return 0b0110;
    if (mem.eql(u8, grapheme, "┐") or mem.eql(u8, grapheme, "╮")) return 0b0101;
    if (mem.eql(u8, grapheme, "└") or mem.eql(u8, grapheme, "╰")) return 0b1010;
    if (mem.eql(u8, grapheme, "┘") or mem.eql(u8, grapheme, "╯")) return 0b1001;
    if (mem.eql(u8, grapheme, "├")) return 0b1110;
    if (mem.eql(u8, grapheme, "┤")) return 0b1101;
    if (mem.eql(u8, grapheme, "┬")) return 0b0111;
    if (mem.eql(u8, grapheme, "┴")) return 0b1011;
    if (mem.eql(u8, grapheme, "┼")) return 0b1111;
    return null;
}

fn glyphFor(mask: u4) []const u8 {
    return switch (mask) {
        0b0011, 0b0010, 0b0001 => "─",
        0b1100, 0b1000, 0b0100 => "│",
        0b0110 => "┌",
        0b0101 => "┐",
        0b1010 => "└",
        0b1001 => "┘",
        0b1110 => "├",
        0b1101 => "┤",
        0b0111 => "┬",
        0b1011 => "┴",
        else => "┼",
    };
}

const std = @import("std");
const mem = std.mem;
