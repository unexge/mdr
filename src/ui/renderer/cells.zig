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
    var fr: usize = 0;
    while (fr < 3) : (fr += 1) {
        var fc: usize = 0;
        while (fc < bw) : (fc += 1) putRaw(win, y + fr, x + fc, start_row, skip, " ", style);
    }
    putRaw(win, y, x, start_row, skip, corners[0], style);
    var c: usize = 1;
    while (c + 1 < bw) : (c += 1) putRaw(win, y, x + c, start_row, skip, "─", style);
    putRaw(win, y, x + bw - 1, start_row, skip, corners[1], style);
    putRaw(win, y + 1, x, start_row, skip, "│", style);
    putText(win, y + 1, x + 2, start_row, skip, label, x + bw - 2, style);
    putRaw(win, y + 1, x + bw - 1, start_row, skip, "│", style);
    putRaw(win, y + 2, x, start_row, skip, corners[2], style);
    c = 1;
    while (c + 1 < bw) : (c += 1) putRaw(win, y + 2, x + c, start_row, skip, "─", style);
    putRaw(win, y + 2, x + bw - 1, start_row, skip, corners[3], style);
}

pub fn labelWidth(label: []const u8) usize {
    var width: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(label);
    while (iter.next()) |g| width += vaxis.gwidth.gwidth(g.bytes(label), .unicode);
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
    if (r < skip) return;
    const rr = start_row + (r - skip);
    if (rr >= win.height or c >= win.width) return;
    if (win.readCell(@intCast(c), @intCast(rr))) |cell| {
        if (!isBlank(cell.char.grapheme)) return;
    }
    win.writeCell(@intCast(c), @intCast(rr), .{ .char = .{ .grapheme = "┄", .width = 1 }, .style = style });
}

pub fn putText(win: vaxis.Window, r: usize, c0: usize, start_row: usize, skip: usize, text: []const u8, max_c: usize, style: vaxis.Style) void {
    if (r < skip) return;
    const rr = start_row + (r - skip);
    if (rr >= win.height) return;
    var c = c0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const gw = vaxis.gwidth.gwidth(bytes, .unicode);
        if (gw == 0) continue;
        if (c + gw > max_c or c + gw > win.width) break;
        win.writeCell(@intCast(c), @intCast(rr), .{ .char = .{ .grapheme = bytes, .width = @intCast(gw) }, .style = style });
        c += gw;
    }
}

fn isBlank(grapheme: []const u8) bool {
    return grapheme.len == 0 or (grapheme.len == 1 and grapheme[0] == ' ');
}

fn isTerminalGlyph(grapheme: []const u8) bool {
    for ([_][]const u8{ "▼", "▲", "►", "◄", "○", "×", ">", "<" }) |glyph| {
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
