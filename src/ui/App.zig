//! Terminal UI: a scrollable viewport over a lazily parsed Document.
//!
//! Elements are parsed and measured only when the viewport needs them, so
//! opening a huge file draws immediately and scrolling parses on demand.
//! Frames never block: each one parses at most up to the visible bottom and
//! renders only the visible rows.

const App = @This();

/// One lazily parsed element and its height at the current width.
const Entry = struct {
    elem: Element,
    /// Footprint rows (content plus trailing gap); zero while unmeasured,
    /// e.g. right after parsing or a width change.
    height: usize = 0,
};

gpa: mem.Allocator,
doc: *Document,

/// Elements parsed so far; their slices point into `doc.text`. Heights live
/// beside their element so the pair can never fall out of sync.
entries: ArrayList(Entry) = .empty,
/// How many entries carry a valid height at the current width; heights are
/// always measured as a prefix.
measured: usize = 0,
measured_width: usize = 0,
total_height: usize = 0,
fully_parsed: bool = false,

scroll: usize = 0,
viewport: usize = 0,
width: usize = 0,
quit: bool = false,

pub fn init(gpa: mem.Allocator, doc: *Document) App {
    return .{ .gpa = gpa, .doc = doc };
}

pub fn deinit(self: *App) void {
    self.entries.deinit(self.gpa);
    self.* = undefined;
}

pub fn run(self: *App, io: Io, environ: *std.process.Environ.Map) !void {
    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, self.gpa, environ, .{});
    defer vx.deinit(self.gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();
    loop.installResizeHandler() catch {};

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    while (!self.quit) {
        switch (try loop.nextEvent()) {
            .key_press => |key| try self.handleKey(&vx, key),
            .winsize => |ws| try vx.resize(self.gpa, tty.writer(), ws),
        }
        if (!self.quit) try self.draw(&vx, tty.writer());
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

fn handleKey(self: *App, vx: *vaxis.Vaxis, key: vaxis.Key) !void {
    if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
        self.quit = true;
    } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        self.scroll += 1;
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        self.scroll -|= 1;
    } else if (key.matches(vaxis.Key.page_down, .{})) {
        self.scroll += pageRows(self.viewport);
    } else if (key.matches(vaxis.Key.page_up, .{})) {
        self.scroll -|= pageRows(self.viewport);
    } else if (key.matches('g', .{}) or key.matches(vaxis.Key.home, .{})) {
        self.scroll = 0;
    } else if (key.matches('G', .{}) or key.matches(vaxis.Key.end, .{})) {
        try self.ensureVisible(math.maxInt(usize));
        self.scroll = self.maxScroll();
    } else if (key.matches('l', .{ .ctrl = true })) {
        vx.queueRefresh();
    }
}

fn pageRows(viewport: usize) usize {
    return if (viewport > 1) viewport - 1 else 1;
}

fn draw(self: *App, vx: *vaxis.Vaxis, tty: *Io.Writer) !void {
    const win = vx.window();
    self.syncWidth(win.width);
    try self.prepareFrame(win.height);

    Renderer.beginFrame();
    win.clear();
    self.renderViewport(win);
    try vx.render(tty);
}

/// Draws the visible rows, skipping everything above `scroll` and stopping
/// at the window bottom.
fn renderViewport(self: *App, win: vaxis.Window) void {
    var row: usize = 0;
    var skip = self.scroll;
    for (self.entries.items) |entry| {
        if (row >= win.height) break;
        // Cached heights are footprints: content rows plus the gap after.
        if (skip >= entry.height) {
            skip -= entry.height;
            continue;
        }
        row = Renderer.render(win, entry.elem, row, skip);
        skip = 0;
        row = @min(win.height, row + 1);
    }
}

/// Parses and clamps so the current scroll position is renderable. One row
/// of slack is kept below the viewport (the clamp's maximum leaves it), so
/// incremental scrolling can always advance until the document ends.
fn prepareFrame(self: *App, viewport: usize) !void {
    self.viewport = viewport;
    try self.ensureVisible(self.scroll + viewport + 1);
    self.clampScroll();
}

/// Parses and measures elements until the content covers `bottom` rows or
/// the document ends. Elements parsed earlier but unmeasured at the current
/// width, e.g. after a resize, are measured on demand.
fn ensureVisible(self: *App, bottom: usize) !void {
    while (self.total_height < bottom) {
        if (self.measured < self.entries.items.len) {
            const entry = &self.entries.items[self.measured];
            entry.height = Renderer.measure(entry.elem, self.width);
            self.total_height += entry.height;
            self.measured += 1;
            continue;
        }
        if (self.fully_parsed) return;
        const elem = self.doc.next() orelse {
            self.fully_parsed = true;
            return;
        };
        try self.entries.append(self.gpa, .{ .elem = elem });
    }
}

/// Heights are width-dependent; a width change invalidates them and they
/// are re-measured on demand from the already parsed elements.
fn syncWidth(self: *App, width: usize) void {
    if (self.width == width) return;
    self.width = width;
    for (self.entries.items) |*entry| entry.height = 0;
    self.measured = 0;
    self.total_height = 0;
}

fn clampScroll(self: *App) void {
    self.scroll = @min(self.scroll, self.maxScroll());
}

fn maxScroll(self: *App) usize {
    // The trailing gap row of the last element is never worth showing.
    return self.total_height -| (self.viewport + 1);
}

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const vaxis = @import("vaxis");
const Document = @import("../Document.zig");
const Renderer = @import("Renderer.zig");
const Element = Document.Element;
const ArrayList = std.ArrayList;

test "parses only what the viewport needs" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 20;
    try app.ensureVisible(5);
    try testing.expect(app.entries.items.len < 12);
    try testing.expect(app.total_height >= 5);

    try app.ensureVisible(math.maxInt(usize));
    try testing.expect(app.fully_parsed);
    try testing.expectEqual(@as(usize, 12), app.entries.items.len);

    var sum: usize = 0;
    for (app.entries.items) |entry| sum += entry.height;
    try testing.expectEqual(app.total_height, sum);
}

test "scroll clamps to the parsed content" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 20;
    app.viewport = 3;
    try app.ensureVisible(math.maxInt(usize));

    app.scroll = 10_000;
    app.clampScroll();
    try testing.expectEqual(app.maxScroll(), app.scroll);
    try testing.expect(app.scroll < app.total_height);
}

test "width change re-measures without re-parsing" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 15;
    try app.ensureVisible(math.maxInt(usize));
    const parsed = app.entries.items.len;
    const narrow = app.total_height;

    app.syncWidth(80);
    try testing.expectEqual(@as(usize, 0), app.measured);
    try testing.expectEqual(@as(usize, 0), app.total_height);

    try app.ensureVisible(math.maxInt(usize));
    try testing.expectEqual(parsed, app.entries.items.len);
    try testing.expect(app.total_height < narrow);
}

test "resize measures on demand after the document is fully parsed" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 15;
    try app.ensureVisible(math.maxInt(usize));

    app.syncWidth(60);
    try app.ensureVisible(4);
    try testing.expect(app.measured < app.entries.items.len);

    try app.ensureVisible(math.maxInt(usize));
    try testing.expectEqual(app.entries.items.len, app.measured);
    var sum: usize = 0;
    for (app.entries.items) |entry| sum += entry.height;
    try testing.expectEqual(app.total_height, sum);
}

test "scrolling shifts content up" {
    var doc = Document.init("first\n\nsecond\n\nthird");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 20;
    try app.ensureVisible(math.maxInt(usize));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 3, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 3,
        .screen = &screen,
    };

    app.renderViewport(win);
    try expectCell(win, 0, 0, 'f');
    try expectCell(win, 0, 2, 's');

    win.clear();
    app.scroll = 1;
    app.renderViewport(win);
    try expectCell(win, 0, 0, ' ');
    try expectCell(win, 0, 1, 's');

    win.clear();
    app.scroll = 2;
    app.renderViewport(win);
    try expectCell(win, 0, 0, 's');
    try expectCell(win, 0, 2, 't');
}

test "scrolling reaches the last line of a long document" {
    var doc = Document.init("alpha\n\nbeta\n\ngamma\n\ndelta");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 2, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 2,
        .screen = &screen,
    };

    app.scroll = app.maxScroll();
    app.renderViewport(win);
    try expectCell(win, 0, 1, 'd');
}

test "code blocks render the info line above the content" {
    var doc = Document.init("```zig\nhi there\n```");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 20;
    try app.ensureVisible(math.maxInt(usize));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 3, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 20,
        .height = 3,
        .screen = &screen,
    };

    app.renderViewport(win);
    try expectCell(win, 0, 0, 'z');
    try expectCell(win, 2, 0, 'g');
    try expectCell(win, 0, 1, 'h');
    try expectCell(win, 7, 1, 'e');
    try expectCell(win, 0, 2, ' ');
}

test "lists render markers and item content" {
    var doc = Document.init("- one\n- two\n");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 10;
    try app.ensureVisible(math.maxInt(usize));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 10,
        .height = 3,
        .screen = &screen,
    };

    app.renderViewport(win);
    try expectCell(win, 0, 0, '-');
    try expectCell(win, 2, 0, 'o');
    try expectCell(win, 0, 1, '-');
    try expectCell(win, 2, 1, 't');
    try expectCell(win, 0, 2, ' ');
}

test "ordered and task markers" {
    var doc = Document.init("3. x\n\n- [x] done\n");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 12;
    try app.ensureVisible(math.maxInt(usize));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 3, .cols = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 12,
        .height = 3,
        .screen = &screen,
    };

    app.renderViewport(win);
    try expectCell(win, 0, 0, '3');
    try expectCell(win, 1, 0, '.');
    try expectCell(win, 3, 0, 'x');
    // The loose gap after the list, then the task checkbox.
    try expectCell(win, 0, 2, '[');
    try expectCell(win, 1, 2, 'x');
}

test "block quotes render the bar and inset content" {
    var doc = Document.init("> hi\n");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 10;
    try app.ensureVisible(math.maxInt(usize));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 2, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 10,
        .height = 2,
        .screen = &screen,
    };

    app.renderViewport(win);
    const bar = win.readCell(0, 0) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings("\u{2502}", bar.char.grapheme);
    try expectCell(win, 2, 0, 'h');
    try expectCell(win, 3, 0, 'i');
    try expectCell(win, 0, 1, ' ');
}

test "tables render inside block quotes" {
    var doc = Document.init("> | hi |\n> |---|\n> | yo |\n");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 12;
    try app.ensureVisible(math.maxInt(usize));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 4, .cols = 12, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 12,
        .height = 4,
        .screen = &screen,
    };

    app.renderViewport(win);
    const bar = win.readCell(0, 0) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings("\u{2502}", bar.char.grapheme);
    try expectCell(win, 2, 0, '|');
    try expectCell(win, 4, 0, 'h');
    try expectCell(win, 3, 1, '-');
    try expectCell(win, 4, 2, 'y');
    try expectCell(win, 0, 3, ' ');
}

// Rendering fuzz: arbitrary inputs are parsed, scrolled incrementally with
// random resizes, and rendered. Asserts three properties that broke before:
// no panics, measure/render agreement, and that incremental scrolling
// converges to the true bottom of the document.
fn fuzzRender(_: void, smith: *testing.Smith) !void {
    // Token streams produce nested containers constantly, so the layout
    // properties below are exercised on real structure, not just raw bytes.
    var input_buf: [4096]u8 = undefined;
    var input_len: usize = 0;
    while (!smith.eos() and input_len < input_buf.len) {
        switch (smith.value(enum { token, raw, token_repeat })) {
            .token => {
                const token = Document.fuzz_tokens[smith.index(Document.fuzz_tokens.len)];
                if (token.len > input_buf.len - input_len) break;
                @memcpy(input_buf[input_len..][0..token.len], token);
                input_len += token.len;
            },
            .raw => {
                const n = smith.valueRangeAtMost(u16, 1, 96);
                const take = @min(@as(usize, n), input_buf.len - input_len);
                smith.bytes(input_buf[input_len..][0..take]);
                input_len += take;
            },
            .token_repeat => {
                const token = Document.fuzz_tokens[smith.index(Document.fuzz_tokens.len)];
                const repeats = smith.valueRangeAtMost(u8, 2, 8);
                for (0..repeats) |_| {
                    if (token.len > input_buf.len - input_len) break;
                    @memcpy(input_buf[input_len..][0..token.len], token);
                    input_len += token.len;
                }
            },
        }
    }

    var doc = Document.init(input_buf[0..input_len]);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    var width: usize = smith.valueRangeAtMost(u16, 8, 100);
    const viewport: usize = smith.valueRangeAtMost(u16, 2, 12);

    var frame: usize = 0;
    while (frame < 48) : (frame += 1) {
        app.scroll += 1;
        app.syncWidth(width);
        try app.prepareFrame(viewport);

        // Measure/render agreement: rendering an element with any skip
        // advances exactly its footprint minus the skipped rows.
        if (app.entries.items.len > 0 and smith.value(enum { no, check }) == .check) {
            const i = smith.index(app.entries.items.len);
            const entry = app.entries.items[i];
            if (entry.height > 0) {
                const skip = smith.valueRangeAtMost(u16, 0, @intCast(entry.height - 1));
                var screen = try vaxis.Screen.init(testing.allocator, .{
                    .rows = @intCast(entry.height + 1),
                    .cols = @intCast(width),
                    .x_pixel = 0,
                    .y_pixel = 0,
                });
                defer screen.deinit(testing.allocator);
                const win: vaxis.Window = .{
                    .x_off = 0,
                    .y_off = 0,
                    .parent_x_off = 0,
                    .parent_y_off = 0,
                    .width = @intCast(width),
                    .height = @intCast(entry.height + 1),
                    .screen = &screen,
                };
                const drawn = Renderer.render(win, entry.elem, 0, skip);
                try testing.expectEqual(entry.height - 1 - skip, drawn);
            }
        }

        var screen = try vaxis.Screen.init(testing.allocator, .{
            .rows = @intCast(viewport),
            .cols = @intCast(width),
            .x_pixel = 0,
            .y_pixel = 0,
        });
        defer screen.deinit(testing.allocator);
        const win: vaxis.Window = .{
            .x_off = 0,
            .y_off = 0,
            .parent_x_off = 0,
            .parent_y_off = 0,
            .width = @intCast(width),
            .height = @intCast(viewport),
            .screen = &screen,
        };
        app.renderViewport(win);

        width = smith.valueRangeAtMost(u16, 8, 100);
    }

    // Incremental scrolling must converge to the true bottom.
    try app.ensureVisible(math.maxInt(usize));
    app.clampScroll();
    try testing.expectEqual(app.maxScroll(), app.scroll);
    for (app.entries.items) |entry| {
        try testing.expect(entry.height >= 1);
    }
    try testing.expectEqual(app.entries.items.len, app.measured);
}

test "fuzz rendering safety" {
    try testing.fuzz({}, fuzzRender, .{ .corpus = &Document.fuzz_corpus });
}

// Deterministic randomized runs in every `zig build test`: random byte
// streams drive `fuzzRender` through Smith's decode mode.
test "randomized rendering" {
    var prng = std.Random.DefaultPrng.init(0x6d64720f);
    const rand = prng.random();
    for (0..256) |_| {
        var stream: [512]u8 = undefined;
        rand.bytes(&stream);
        const len = rand.uintAtMost(usize, stream.len);
        var smith: testing.Smith = .{ .in = stream[0..len] };
        try fuzzRender({}, &smith);
    }
}

const lazy_text = "one two three four five six seven\n\n" ** 12;

fn expectCell(win: vaxis.Window, col: usize, row: usize, expected: u8) !void {
    const cell = win.readCell(@intCast(col), @intCast(row)) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings(&[1]u8{expected}, cell.char.grapheme);
}

const testing = std.testing;

test "container measures match render" {
    const text =
        "## UI\n" ++
        "- Make sure to keep UI always responsive and don't do any blocking work on the main thread\n" ++
        "- Do things lazily and try avoiding allocating memory dynamically\n" ++
        "  - For example don't try to parse a huge file at once, just process visible parts\n";

    var doc = Document.init(text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 50;
    try app.ensureVisible(math.maxInt(usize));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 40, .cols = 50, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 50,
        .height = 40,
        .screen = &screen,
    };

    for (app.entries.items) |entry| {
        const drawn = Renderer.render(win, entry.elem, 0, 0);
        try testing.expectEqual(entry.height - 1, drawn);
    }
}
