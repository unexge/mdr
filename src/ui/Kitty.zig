//! Kitty image transport with terminal-specific placement strategies.

pub const PlacementMode = enum {
    remainder,
    stable,
    unicode,
};

pub const VirtualPlacement = struct {
    image_id: u32,
    rows: u16,
    cols: u16,
};

pub const max_placeholder_rows = row_diacritics.len;

pub const Placement = struct {
    pub const SourceRect = struct {
        y: u16,
        width: u16,
        height: u16,
    };

    image_id: u32,
    row: usize,
    rows: u16,
    cols: u16,
    source: ?SourceRect = null,

    fn eql(a: Placement, b: Placement) bool {
        return a.image_id == b.image_id and
            a.row == b.row and
            a.rows == b.rows and
            a.cols == b.cols and
            meta.eql(a.source, b.source);
    }
};

pub fn placementMode(term: []const u8, term_program: []const u8, kitty_window_id: []const u8, zellij: []const u8) PlacementMode {
    if (zellij.len > 0) return .remainder;
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
        const row_grapheme = &row_graphemes[source_row + y];
        for (0..@min(cols, win.width)) |x| {
            win.writeCell(@intCast(x), @intCast(row + y), .{
                .char = .{
                    .grapheme = if (x == 0) row_grapheme.bytes[0..row_grapheme.len] else placeholder,
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
const RowGrapheme = struct {
    bytes: [8]u8,
    len: u4,
};
const row_diacritics = [_]u21{
    0x0305,  0x030d,  0x030e,  0x0310,  0x0312,  0x033d,  0x033e,  0x033f,  0x0346,  0x034a,  0x034b,  0x034c,
    0x0350,  0x0351,  0x0352,  0x0357,  0x035b,  0x0363,  0x0364,  0x0365,  0x0366,  0x0367,  0x0368,  0x0369,
    0x036a,  0x036b,  0x036c,  0x036d,  0x036e,  0x036f,  0x0483,  0x0484,  0x0485,  0x0486,  0x0487,  0x0592,
    0x0593,  0x0594,  0x0595,  0x0597,  0x0598,  0x0599,  0x059c,  0x059d,  0x059e,  0x059f,  0x05a0,  0x05a1,
    0x05a8,  0x05a9,  0x05ab,  0x05ac,  0x05af,  0x05c4,  0x0610,  0x0611,  0x0612,  0x0613,  0x0614,  0x0615,
    0x0616,  0x0617,  0x0657,  0x0658,  0x0659,  0x065a,  0x065b,  0x065d,  0x065e,  0x06d6,  0x06d7,  0x06d8,
    0x06d9,  0x06da,  0x06db,  0x06dc,  0x06df,  0x06e0,  0x06e1,  0x06e2,  0x06e4,  0x06e7,  0x06e8,  0x06eb,
    0x06ec,  0x0730,  0x0732,  0x0733,  0x0735,  0x0736,  0x073a,  0x073d,  0x073f,  0x0740,  0x0741,  0x0743,
    0x0745,  0x0747,  0x0749,  0x074a,  0x07eb,  0x07ec,  0x07ed,  0x07ee,  0x07ef,  0x07f0,  0x07f1,  0x07f3,
    0x0816,  0x0817,  0x0818,  0x0819,  0x081b,  0x081c,  0x081d,  0x081e,  0x081f,  0x0820,  0x0821,  0x0822,
    0x0823,  0x0825,  0x0826,  0x0827,  0x0829,  0x082a,  0x082b,  0x082c,  0x082d,  0x0951,  0x0953,  0x0954,
    0x0f82,  0x0f83,  0x0f86,  0x0f87,  0x135d,  0x135e,  0x135f,  0x17dd,  0x193a,  0x1a17,  0x1a75,  0x1a76,
    0x1a77,  0x1a78,  0x1a79,  0x1a7a,  0x1a7b,  0x1a7c,  0x1b6b,  0x1b6d,  0x1b6e,  0x1b6f,  0x1b70,  0x1b71,
    0x1b72,  0x1b73,  0x1cd0,  0x1cd1,  0x1cd2,  0x1cda,  0x1cdb,  0x1ce0,  0x1dc0,  0x1dc1,  0x1dc3,  0x1dc4,
    0x1dc5,  0x1dc6,  0x1dc7,  0x1dc8,  0x1dc9,  0x1dcb,  0x1dcc,  0x1dd1,  0x1dd2,  0x1dd3,  0x1dd4,  0x1dd5,
    0x1dd6,  0x1dd7,  0x1dd8,  0x1dd9,  0x1dda,  0x1ddb,  0x1ddc,  0x1ddd,  0x1dde,  0x1ddf,  0x1de0,  0x1de1,
    0x1de2,  0x1de3,  0x1de4,  0x1de5,  0x1de6,  0x1dfe,  0x20d0,  0x20d1,  0x20d4,  0x20d5,  0x20d6,  0x20d7,
    0x20db,  0x20dc,  0x20e1,  0x20e7,  0x20e9,  0x20f0,  0x2cef,  0x2cf0,  0x2cf1,  0x2de0,  0x2de1,  0x2de2,
    0x2de3,  0x2de4,  0x2de5,  0x2de6,  0x2de7,  0x2de8,  0x2de9,  0x2dea,  0x2deb,  0x2dec,  0x2ded,  0x2dee,
    0x2def,  0x2df0,  0x2df1,  0x2df2,  0x2df3,  0x2df4,  0x2df5,  0x2df6,  0x2df7,  0x2df8,  0x2df9,  0x2dfa,
    0x2dfb,  0x2dfc,  0x2dfd,  0x2dfe,  0x2dff,  0xa66f,  0xa67c,  0xa67d,  0xa6f0,  0xa6f1,  0xa8e0,  0xa8e1,
    0xa8e2,  0xa8e3,  0xa8e4,  0xa8e5,  0xa8e6,  0xa8e7,  0xa8e8,  0xa8e9,  0xa8ea,  0xa8eb,  0xa8ec,  0xa8ed,
    0xa8ee,  0xa8ef,  0xa8f0,  0xa8f1,  0xaab0,  0xaab2,  0xaab3,  0xaab7,  0xaab8,  0xaabe,  0xaabf,  0xaac1,
    0xfe20,  0xfe21,  0xfe22,  0xfe23,  0xfe24,  0xfe25,  0xfe26,  0x10a0f, 0x10a38, 0x1d185, 0x1d186, 0x1d187,
    0x1d188, 0x1d189, 0x1d1aa, 0x1d1ab, 0x1d1ac, 0x1d1ad, 0x1d242, 0x1d243, 0x1d244,
};
const row_graphemes = makeRowGraphemes();

fn makeRowGraphemes() [row_diacritics.len]RowGrapheme {
    @setEvalBranchQuota(10_000);
    var result: [row_diacritics.len]RowGrapheme = undefined;
    for (row_diacritics, &result) |diacritic, *grapheme| {
        @memcpy(grapheme.bytes[0..placeholder.len], placeholder);
        const diacritic_len = unicode.utf8Encode(diacritic, grapheme.bytes[placeholder.len..]) catch unreachable;
        grapheme.len = @intCast(placeholder.len + diacritic_len);
    }
    return result;
}

fn idColor(image_id: u32) vaxis.Color {
    return .rgbFromUint(@truncate(image_id));
}

fn writePlacement(tty: *Io.Writer, placement: Placement) !void {
    try tty.print(
        "\x1b[{d};1H\x1b_Ga=p,i={d},p={d},q=2",
        .{ placement.row + 1, placement.image_id, placement.image_id },
    );
    if (placement.source) |source| {
        try tty.print(
            ",x=0,y={d},w={d},h={d}",
            .{ source.y, source.width, source.height },
        );
    }
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
const meta = std.meta;
const unicode = std.unicode;
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

test "selects placement strategy from terminal capabilities" {
    try testing.expectEqual(PlacementMode.unicode, placementMode("xterm-kitty", "", "", ""));
    try testing.expectEqual(PlacementMode.unicode, placementMode("xterm-256color", "", "1", ""));
    try testing.expectEqual(PlacementMode.stable, placementMode("xterm-ghostty", "ghostty", "", ""));
    try testing.expectEqual(PlacementMode.remainder, placementMode("xterm-256color", "ghostty", "", "0"));
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
        .source = .{ .y = 20, .width = 100, .height = 40 },
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
            "\x1b[3;1H\x1b_Ga=p,i=3,p=3,q=2,x=0,y=20,w=100,h=40,r=1,c=5,C=1\x1b\\" ++
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

    drawPlaceholder(win, 42, 0, 16, 2, 3);

    try testing.expectEqualStrings(placeholder ++ "\u{035b}", win.readCell(0, 0).?.char.grapheme);
    try testing.expectEqualStrings(placeholder, win.readCell(1, 0).?.char.grapheme);
    try testing.expectEqual(vaxis.Color.rgbFromUint(42), win.readCell(2, 1).?.style.fg);
}

const mem = std.mem;
const testing = std.testing;
