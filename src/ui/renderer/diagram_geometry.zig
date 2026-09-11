pub const Bounds = struct {
    x1: usize,
    y1: usize,
    x2: usize,
    y2: usize,

    pub fn width(self: Bounds) usize {
        return self.x2 - self.x1 + 1;
    }

    pub fn height(self: Bounds) usize {
        return self.y2 - self.y1 + 1;
    }
};

pub const Size = struct {
    width: usize,
    height: usize,
};

pub const CellPos = struct {
    r: usize,
    c: usize,
};

pub const Segment = struct {
    r1: usize,
    c1: usize,
    r2: usize,
    c2: usize,
    glyph: []const u8,
};

pub const LabelAt = struct {
    r: usize,
    c: usize,
    text: []const u8,
};

pub const Path = struct {
    segments: [3]Segment = undefined,
    segment_count: usize = 0,
    src_at: CellPos,
    dst_at: CellPos,
    src_arrow: []const u8,
    dst_arrow: []const u8,
    src_line: []const u8,
    dst_line: []const u8,
    label: ?LabelAt = null,

    pub fn add(self: *Path, segment: Segment) void {
        if (self.segment_count >= self.segments.len) return;
        if ((segment.r1 > segment.r2 and segment.c1 == segment.c2) or
            (segment.c1 > segment.c2 and segment.r1 == segment.r2)) return;
        self.segments[self.segment_count] = segment;
        self.segment_count += 1;
    }

    pub fn horizontal(self: *Path, row: usize, first: usize, last: usize) void {
        self.add(.{ .r1 = row, .c1 = first, .r2 = row, .c2 = last, .glyph = "─" });
    }

    pub fn vertical(self: *Path, column: usize, first: usize, last: usize) void {
        self.add(.{ .r1 = first, .c1 = column, .r2 = last, .c2 = column, .glyph = "│" });
    }
};

pub const Stroke = enum { solid, dotted, heavy, hidden };

pub fn selfPath(bounds: Bounds, label: ?[]const u8, rows: usize, cols: usize) ?Path {
    const center = CellPos{ .r = (bounds.y1 + bounds.y2) / 2, .c = (bounds.x1 + bounds.x2) / 2 };
    const source = CellPos{ .r = bounds.y2 + 1, .c = center.c };
    const destination = CellPos{ .r = center.r, .c = bounds.x2 + 1 };
    if (source.r >= rows or destination.c >= cols) return null;
    var path: Path = undefined;
    path.segment_count = 0;
    path.src_at = source;
    path.dst_at = destination;
    path.src_arrow = "▲";
    path.dst_arrow = "◄";
    path.src_line = "│";
    path.dst_line = "─";
    path.label = if (label) |text| .{ .r = source.r, .c = bounds.x1 + 1, .text = text } else null;
    path.horizontal(source.r, source.c, destination.c);
    path.vertical(destination.c, destination.r, source.r);
    return path;
}

pub fn drawFrame(
    win: vaxis.Window,
    bounds: Bounds,
    corners: [4][]const u8,
    style: vaxis.Style,
    merge: bool,
    start_row: usize,
    skip: usize,
) void {
    putFrameCell(win, bounds.y1, bounds.x1, corners[0], style, merge, start_row, skip);
    putFrameCell(win, bounds.y1, bounds.x2, corners[1], style, merge, start_row, skip);
    putFrameCell(win, bounds.y2, bounds.x1, corners[2], style, merge, start_row, skip);
    putFrameCell(win, bounds.y2, bounds.x2, corners[3], style, merge, start_row, skip);
    for (bounds.x1 + 1..bounds.x2) |column| {
        putFrameCell(win, bounds.y1, column, "─", style, merge, start_row, skip);
        putFrameCell(win, bounds.y2, column, "─", style, merge, start_row, skip);
    }
    for (bounds.y1 + 1..bounds.y2) |row| {
        putFrameCell(win, row, bounds.x1, "│", style, merge, start_row, skip);
        putFrameCell(win, row, bounds.x2, "│", style, merge, start_row, skip);
    }
}

fn putFrameCell(
    win: vaxis.Window,
    row: usize,
    column: usize,
    glyph: []const u8,
    style: vaxis.Style,
    merge: bool,
    start_row: usize,
    skip: usize,
) void {
    if (merge)
        cells.putLine(win, row, column, start_row, skip, glyph, style)
    else
        cells.putRaw(win, row, column, start_row, skip, glyph, style);
}

pub fn drawSegment(
    win: vaxis.Window,
    segment: Segment,
    stroke: Stroke,
    start_row: usize,
    skip: usize,
) void {
    if (stroke == .hidden) return;
    const horizontal = segment.r1 == segment.r2;
    const straight = (horizontal and mem.eql(u8, segment.glyph, "─")) or
        (!horizontal and mem.eql(u8, segment.glyph, "│"));
    var row = segment.r1;
    var column = segment.c1;
    while (true) {
        if (!straight or stroke == .solid) {
            cells.putLine(win, row, column, start_row, skip, segment.glyph, .{});
        } else if (stroke == .dotted) {
            if (horizontal)
                cells.putDotted(win, row, column, start_row, skip, .{})
            else
                cells.putDottedVertical(win, row, column, start_row, skip, .{});
        } else {
            cells.putHeavy(win, row, column, start_row, skip, horizontal, .{});
        }
        if (row == segment.r2 and column == segment.c2) break;
        if (horizontal) column += 1 else row += 1;
    }
}

pub fn reverseArrow(arrow: []const u8) []const u8 {
    if (mem.eql(u8, arrow, "▼")) return "▲";
    if (mem.eql(u8, arrow, "▲")) return "▼";
    if (mem.eql(u8, arrow, "►")) return "◄";
    return "►";
}

const std = @import("std");
const mem = std.mem;
const cells = @import("cells.zig");
const vaxis = @import("vaxis");
