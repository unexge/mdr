//! Kitty image transport with terminal-specific placement strategies.

pub const PlacementMode = enum {
    stable,
    unicode,
};

pub const VirtualPlacement = struct {
    image_id: u32,
    rows: u16,
    cols: u16,
};

pub const Placement = struct {
    image_id: u32,
    row: usize,
    rows: u16,
    cols: u16,
    source_y: ?u16 = null,
    source_height: ?u16 = null,

    fn eql(a: Placement, b: Placement) bool {
        return a.image_id == b.image_id and
            a.row == b.row and
            a.rows == b.rows and
            a.cols == b.cols and
            a.source_y == b.source_y and
            a.source_height == b.source_height;
    }
};

pub fn placementMode(term: []const u8, term_program: []const u8, kitty_window_id: []const u8) PlacementMode {
    if (kitty_window_id.len > 0 or mem.eql(u8, term, "xterm-kitty")) return .unicode;
    if (mem.eql(u8, term_program, "kitty")) return .unicode;
    return .stable;
}

pub fn transmit(tty: *Io.Writer, image_id: u32, payload: []const u8, width: u16, height: u16) !vaxis.Image {
    if (payload.len < chunk_size) {
        try tty.print(
            "\x1b_Gf=100,s={d},v={d},i={d},q=2;{s}\x1b\\",
            .{ width, height, image_id, payload },
        );
    } else {
        try tty.print(
            "\x1b_Gf=100,s={d},v={d},i={d},q=2,m=1;{s}\x1b\\",
            .{ width, height, image_id, payload[0..chunk_size] },
        );
        var offset: usize = chunk_size;
        while (offset < payload.len) : (offset += chunk_size) {
            const end = @min(offset + chunk_size, payload.len);
            try tty.print(
                "\x1b_Gm={d},q=2;{s}\x1b\\",
                .{ @intFromBool(end != payload.len), payload[offset..end] },
            );
        }
    }
    try tty.flush();
    return vaxis.Image.init(image_id, width, height);
}

pub fn defineVirtualPlacements(tty: *Io.Writer, placements: []const VirtualPlacement) !void {
    for (placements) |placement| {
        try tty.print(
            "\x1b_Ga=p,U=1,i={d},p={d},q=2,r={d},c={d}\x1b\\",
            .{
                placement.image_id,
                placement.image_id,
                placement.rows,
                placement.cols,
            },
        );
    }
    try tty.flush();
}

pub fn syncPlacements(tty: *Io.Writer, previous: []const Placement, current: []const Placement) !void {
    if (!placementsChanged(previous, current)) return;

    var removed: usize = 0;
    for (previous) |old| {
        for (current) |new| {
            if (new.image_id == old.image_id) break;
        } else removed += 1;
    }
    var changed: usize = 0;
    for (current) |new| {
        for (previous) |old| {
            if (old.image_id == new.image_id) {
                if (!old.eql(new)) changed += 1;
                break;
            }
        } else changed += 1;
    }
    const replace_all = 1 + current.len < removed + 2 * changed;

    try tty.writeAll("\x1b[?2026h");
    errdefer {
        tty.writeAll("\x1b[?2026l") catch {};
        tty.flush() catch {};
    }
    if (replace_all) {
        try tty.writeAll("\x1b_Ga=d,d=a,q=2\x1b\\");
    } else {
        for (previous) |old| {
            for (current) |new| {
                if (new.image_id == old.image_id) break;
            } else {
                try tty.print(
                    "\x1b_Ga=d,d=i,i={d},q=2\x1b\\",
                    .{old.image_id},
                );
            }
        }
    }
    for (current) |new| {
        const unchanged = for (previous) |old| {
            if (old.image_id == new.image_id) break old.eql(new);
        } else false;
        if (unchanged and !replace_all) continue;

        if (!replace_all) {
            try tty.print(
                "\x1b_Ga=d,d=i,i={d},q=2\x1b\\",
                .{new.image_id},
            );
        }
        try writePlacement(tty, new);
    }
    try tty.writeAll("\x1b[?2026l");
    try tty.flush();
}

pub fn drawPlaceholder(win: vaxis.Window, image_id: u32, row: usize, source_row: usize, rows: usize, cols: usize) void {
    const color = idColor(image_id);
    for (0..rows) |y| {
        if (source_row + y >= row_graphemes.len or row + y >= win.height) break;
        for (0..@min(cols, win.width)) |x| {
            win.writeCell(@intCast(x), @intCast(row + y), .{
                .char = .{
                    .grapheme = if (x == 0) row_graphemes[source_row + y] else placeholder,
                    .width = 1,
                },
                .style = .{ .fg = color, .ul = color },
            });
        }
    }
}

pub fn free(tty: *Io.Writer, image_id: u32) void {
    tty.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id}) catch return;
    tty.flush() catch {};
}

const chunk_size = 4096;
const placeholder = "\u{10eeee}";
const row_graphemes = [_][]const u8{
    placeholder ++ "\u{0305}",
    placeholder ++ "\u{030d}",
    placeholder ++ "\u{030e}",
    placeholder ++ "\u{0310}",
    placeholder ++ "\u{0312}",
    placeholder ++ "\u{033d}",
    placeholder ++ "\u{033e}",
    placeholder ++ "\u{033f}",
    placeholder ++ "\u{0346}",
    placeholder ++ "\u{034a}",
    placeholder ++ "\u{034b}",
    placeholder ++ "\u{034c}",
    placeholder ++ "\u{0350}",
    placeholder ++ "\u{0351}",
    placeholder ++ "\u{0352}",
    placeholder ++ "\u{0357}",
};

fn idColor(image_id: u32) vaxis.Color {
    return .rgbFromUint(@truncate(image_id));
}

fn writePlacement(tty: *Io.Writer, placement: Placement) !void {
    try tty.print(
        "\x1b[{d};1H\x1b_Ga=p,i={d},p={d},q=2",
        .{ placement.row + 1, placement.image_id, placement.image_id },
    );
    if (placement.source_y) |y| try tty.print(",y={d}", .{y});
    if (placement.source_height) |height| try tty.print(",h={d}", .{height});
    try tty.print(",r={d},c={d},C=1\x1b\\", .{ placement.rows, placement.cols });
}

fn placementsChanged(previous: []const Placement, current: []const Placement) bool {
    for (previous) |old| {
        for (current) |new| {
            if (new.image_id == old.image_id) break;
        } else return true;
    }
    for (current) |new| {
        for (previous) |old| {
            if (old.image_id == new.image_id) {
                if (!old.eql(new)) return true;
                break;
            }
        } else return true;
    }
    return false;
}

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

test "image commands suppress terminal acknowledgements" {
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    _ = try transmit(&writer, 7, "eA==", 10, 20);
    try defineVirtualPlacements(&writer, &.{
        .{
            .image_id = 7,
            .rows = 2,
            .cols = 3,
        },
        .{
            .image_id = 8,
            .rows = 4,
            .cols = 5,
        },
    });
    free(&writer, 7);

    try testing.expectEqualStrings(
        "\x1b_Gf=100,s=10,v=20,i=7,q=2;eA==\x1b\\" ++
            "\x1b_Ga=p,U=1,i=7,p=7,q=2,r=2,c=3\x1b\\" ++
            "\x1b_Ga=p,U=1,i=8,p=8,q=2,r=4,c=5\x1b\\" ++
            "\x1b_Ga=d,d=I,i=7,q=2\x1b\\",
        writer.buffered(),
    );
    try expectQuietGraphicsCommands(writer.buffered());
}

test "selects Unicode placeholders only for Kitty" {
    try testing.expectEqual(PlacementMode.unicode, placementMode("xterm-kitty", "", ""));
    try testing.expectEqual(PlacementMode.unicode, placementMode("xterm-256color", "", "1"));
    try testing.expectEqual(PlacementMode.stable, placementMode("xterm-ghostty", "ghostty", ""));
}

test "stable placements update only when their layout changes" {
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    const first: Placement = .{ .image_id = 3, .row = 4, .rows = 2, .cols = 5 };

    try syncPlacements(&writer, &.{}, &.{first});
    const after_first = writer.buffered().len;
    try syncPlacements(&writer, &.{first}, &.{first});
    try testing.expectEqual(after_first, writer.buffered().len);

    const moved: Placement = .{
        .image_id = 3,
        .row = 2,
        .rows = 1,
        .cols = 5,
        .source_y = 20,
        .source_height = 40,
    };
    try syncPlacements(&writer, &.{first}, &.{moved});
    try syncPlacements(&writer, &.{moved}, &.{});

    try testing.expectEqualStrings(
        "\x1b[?2026h" ++
            "\x1b_Ga=d,d=i,i=3,q=2\x1b\\" ++
            "\x1b[5;1H\x1b_Ga=p,i=3,p=3,q=2,r=2,c=5,C=1\x1b\\" ++
            "\x1b[?2026l" ++
            "\x1b[?2026h" ++
            "\x1b_Ga=d,d=i,i=3,q=2\x1b\\" ++
            "\x1b[3;1H\x1b_Ga=p,i=3,p=3,q=2,y=20,h=40,r=1,c=5,C=1\x1b\\" ++
            "\x1b[?2026l" ++
            "\x1b[?2026h" ++
            "\x1b_Ga=d,d=i,i=3,q=2\x1b\\" ++
            "\x1b[?2026l",
        writer.buffered(),
    );
    try expectQuietGraphicsCommands(writer.buffered());
}

test "stable placements batch viewport-wide changes" {
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    const previous = [_]Placement{
        .{ .image_id = 1, .row = 2, .rows = 2, .cols = 5 },
        .{ .image_id = 2, .row = 6, .rows = 2, .cols = 5 },
    };
    const current = [_]Placement{
        .{ .image_id = 1, .row = 1, .rows = 2, .cols = 5 },
        .{ .image_id = 2, .row = 5, .rows = 2, .cols = 5 },
    };

    try syncPlacements(&writer, &previous, &current);

    try testing.expectEqualStrings(
        "\x1b[?2026h" ++
            "\x1b_Ga=d,d=a,q=2\x1b\\" ++
            "\x1b[2;1H\x1b_Ga=p,i=1,p=1,q=2,r=2,c=5,C=1\x1b\\" ++
            "\x1b[6;1H\x1b_Ga=p,i=2,p=2,q=2,r=2,c=5,C=1\x1b\\" ++
            "\x1b[?2026l",
        writer.buffered(),
    );
}

test "fuzz Kitty command framing" {
    try testing.fuzz({}, fuzzCommands, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00",
        "\xff\x0f\x00\x00\x00\x00\x00\x00",
        "\x00\x10\x00\x00\x00\x00\x00\x00",
        "\x01\x10\x00\x00\x00\x00\x00\x00",
    } });
}

fn fuzzCommands(_: void, smith: *testing.Smith) anyerror!void {
    var payload_buffer: [chunk_size * 4 + 1]u8 = undefined;
    const payload_len = smith.valueRangeAtMost(u16, 0, @intCast(payload_buffer.len));
    const payload = payload_buffer[0..payload_len];
    smith.bytes(payload);
    for (payload) |*byte| {
        byte.* = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"[byte.* % 64];
    }

    var output_buffer: [payload_buffer.len + 1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&output_buffer);
    _ = try transmit(&writer, 1, payload, 640, 480);
    try defineVirtualPlacements(&writer, &.{
        .{ .image_id = 1, .rows = 1, .cols = 1 },
        .{ .image_id = 2, .rows = 3, .cols = 4 },
    });
    try syncPlacements(&writer, &.{}, &.{
        .{ .image_id = 1, .row = 0, .rows = 1, .cols = 1 },
        .{ .image_id = 2, .row = 2, .rows = 3, .cols = 4 },
    });
    free(&writer, 1);
    try expectQuietGraphicsCommands(writer.buffered());
}

fn expectQuietGraphicsCommands(output: []const u8) !void {
    var remaining = output;
    var count: usize = 0;
    while (mem.indexOf(u8, remaining, "\x1b_G")) |start| {
        const command = remaining[start .. (mem.indexOfPos(u8, remaining, start, "\x1b\\") orelse
            return error.UnterminatedGraphicsCommand) + 2];
        try testing.expect(mem.indexOf(u8, command, "q=2") != null);
        remaining = remaining[start + command.len ..];
        count += 1;
    }
    try testing.expect(count > 0);
}

test "image placeholders are ordinary screen cells" {
    var screen = try vaxis.Screen.init(testing.allocator, .{
        .rows = 2,
        .cols = 3,
        .x_pixel = 30,
        .y_pixel = 40,
    });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 3,
        .height = 2,
        .screen = &screen,
    };

    drawPlaceholder(win, 42, 0, 1, 2, 3);

    try testing.expectEqualStrings(placeholder ++ "\u{030d}", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings(placeholder, win.readCell(1, 0).?.char.grapheme);
    try testing.expectEqual(vaxis.Color.rgbFromUint(42), win.readCell(2, 1).?.style.fg);
}

const mem = std.mem;
const testing = std.testing;
