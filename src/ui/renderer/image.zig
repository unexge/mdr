pub fn layout(win: ?vaxis.Window, image: Document.Element.Image, start_row: usize, skip: usize, width: usize) usize {
    const remote = Media.classify(image.source) == .remote;
    var lay: Lay = .{
        .win = win,
        .width = @max(width, 1),
        .row = start_row,
        .skip = skip,
        .link = if (remote) .{ .uri = image.source } else .{},
    };
    lay.feed(if (remote) "[remote image: " else "[image: ");
    lay.feed(image.alt);
    lay.feed("]");
    return lay.finish();
}

const Lay = struct {
    win: ?vaxis.Window,
    width: usize,
    row: usize,
    skip: usize,
    col: usize = 0,
    link: vaxis.Cell.Hyperlink,

    fn feed(self: *Lay, value: []const u8) void {
        var iter = vaxis.unicode.graphemeIterator(value);
        while (iter.next()) |g| {
            const bytes = g.bytes(value);
            const cell_width = vaxis.gwidth.gwidth(bytes, .unicode);
            if (cell_width == 0) continue;
            if (self.col + cell_width > self.width) self.lineBreak();
            if (self.skip == 0) {
                if (self.win) |win| {
                    if (self.row < win.height) {
                        win.writeCell(@intCast(self.col), @intCast(self.row), .{
                            .char = .{ .grapheme = bytes, .width = @intCast(cell_width) },
                            .style = .{ .italic = true, .dim = true },
                            .link = self.link,
                        });
                    }
                }
            }
            self.col += cell_width;
        }
    }

    fn lineBreak(self: *Lay) void {
        if (self.skip > 0) {
            self.skip -= 1;
        } else {
            self.row += 1;
        }
        self.col = 0;
    }

    fn finish(self: *Lay) usize {
        if (self.skip > 0) return self.row;
        return self.row + @intFromBool(self.col > 0);
    }
};

const vaxis = @import("vaxis");
const Document = @import("../../Document.zig");
const Media = @import("../Media.zig");
