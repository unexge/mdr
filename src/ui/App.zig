//! Terminal UI: a scrollable viewport over a lazily parsed Document.
//!
//! Elements are parsed and measured only when the viewport needs them, so
//! opening a huge file draws immediately and scrolling parses on demand.
//! Frames never block: each one parses at most up to the visible bottom and
//! renders only the visible rows.

const App = @This();

gpa: mem.Allocator,
doc: *Document,

/// Elements parsed so far; their slices point into `doc.text`.
elements: ArrayList(Element) = .empty,
/// Height of each element in rows at the current width, gap included.
heights: ArrayList(usize) = .empty,
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
    self.elements.deinit(self.gpa);
    self.heights.deinit(self.gpa);
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
    self.viewport = win.height;

    try self.ensureVisible(self.scroll + win.height);
    self.clampScroll();

    win.clear();
    self.renderViewport(win);
    try vx.render(tty);
}

/// Draws the visible rows, skipping everything above `scroll` and stopping
/// at the window bottom.
fn renderViewport(self: *App, win: vaxis.Window) void {
    var row: usize = 0;
    var skip = self.scroll;
    for (self.heights.items, 0..) |height, i| {
        if (row >= win.height) break;
        if (skip >= height) {
            skip -= height;
            continue;
        }
        row = Renderer.render(win, self.elements.items[i], row, skip);
        skip = 0;
    }
}

/// Parses and measures elements until the content covers `bottom` rows or
/// the document ends. Elements parsed earlier but unmeasured at the current
/// width, e.g. after a resize, are measured on demand.
fn ensureVisible(self: *App, bottom: usize) !void {
    var next = self.heights.items.len;
    while (self.total_height < bottom) {
        if (next < self.elements.items.len) {
            const height = Renderer.measure(self.elements.items[next], self.width);
            try self.heights.append(self.gpa, height);
            self.total_height += height;
            next += 1;
            continue;
        }
        if (self.fully_parsed) return;
        const elem = self.doc.next() orelse {
            self.fully_parsed = true;
            return;
        };
        try self.elements.append(self.gpa, elem);
    }
}

/// Heights are width-dependent; a width change invalidates them and they
/// are re-measured on demand from the already parsed elements.
fn syncWidth(self: *App, width: usize) void {
    if (self.width == width) return;
    self.width = width;
    self.heights.clearRetainingCapacity();
    self.total_height = 0;
}

fn clampScroll(self: *App) void {
    self.scroll = @min(self.scroll, self.maxScroll());
}

fn maxScroll(self: *App) usize {
    return self.total_height -| self.viewport;
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
    try testing.expect(app.elements.items.len < 12);
    try testing.expect(app.total_height >= 5);

    try app.ensureVisible(math.maxInt(usize));
    try testing.expect(app.fully_parsed);
    try testing.expectEqual(@as(usize, 12), app.elements.items.len);

    var sum: usize = 0;
    for (app.heights.items) |height| sum += height;
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
    const parsed = app.elements.items.len;
    const narrow = app.total_height;

    app.syncWidth(80);
    try testing.expectEqual(@as(usize, 0), app.heights.items.len);
    try testing.expectEqual(@as(usize, 0), app.total_height);

    try app.ensureVisible(math.maxInt(usize));
    try testing.expectEqual(parsed, app.elements.items.len);
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
    try testing.expect(app.heights.items.len < app.elements.items.len);

    try app.ensureVisible(math.maxInt(usize));
    try testing.expectEqual(app.elements.items.len, app.heights.items.len);
    var sum: usize = 0;
    for (app.heights.items) |height| sum += height;
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

const lazy_text = "one two three four five six seven\n\n" ** 12;

fn expectCell(win: vaxis.Window, col: usize, row: usize, expected: u8) !void {
    const cell = win.readCell(@intCast(col), @intCast(row)) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings(&[1]u8{expected}, cell.char.grapheme);
}

const testing = std.testing;
