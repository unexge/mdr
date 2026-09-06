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
    media: Media.State = .idle,
    virtual_rows: u16 = 0,
    virtual_cols: u16 = 0,
    /// Footprint rows (content plus trailing gap); zero while unmeasured,
    /// e.g. right after parsing or a width change.
    height: usize = 0,
};

const MediaRequest = struct {
    entry_index: usize,
    path: []u8,
    max_width: u16,
    max_height: u16,
    result: union(enum) {
        pending,
        ready: Media.Artifact,
        failed,
    } = .pending,

    fn deinit(self: *MediaRequest, gpa: mem.Allocator) void {
        gpa.free(self.path);
        switch (self.result) {
            .ready => |*artifact| artifact.deinit(gpa),
            else => {},
        }
        self.* = undefined;
    }
};

gpa: mem.Allocator,
doc: *Document,
base_dir: []const u8 = ".",

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
cell_width: usize = 0,
cell_height: usize = 0,
pending_media: ?*MediaRequest = null,
placement_mode: Kitty.PlacementMode = .stable,
graphics_supported: bool = false,
virtual_placements: [max_images]Kitty.VirtualPlacement = undefined,
virtual_placement_count: usize = 0,
stable_placements: [max_images]Kitty.Placement = undefined,
stable_placement_count: usize = 0,
next_stable_placements: [max_images]Kitty.Placement = undefined,
next_stable_placement_count: usize = 0,
next_image_id: u32 = 1,
quit: bool = false,

pub fn init(gpa: mem.Allocator, doc: *Document) App {
    return .{ .gpa = gpa, .doc = doc };
}

pub fn initFile(gpa: mem.Allocator, doc: *Document, file_path: []const u8) App {
    return .{ .gpa = gpa, .doc = doc, .base_dir = path.dirname(file_path) orelse "." };
}

pub fn deinit(self: *App) void {
    self.entries.deinit(self.gpa);
    self.* = undefined;
}

pub fn run(self: *App, io: Io, environ: *std.process.Environ.Map) !void {
    self.placement_mode = Kitty.placementMode(
        environ.get("TERM") orelse "",
        environ.get("TERM_PROGRAM") orelse "",
        environ.get("KITTY_WINDOW_ID") orelse "",
    );
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

    var media_tasks: Io.Group = .init;
    defer {
        media_tasks.cancel(io);
        self.cancelPendingMedia();
        self.freeImages(tty.writer());
    }

    while (!self.quit) {
        try loop.pollEvent();
        while (try loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| try self.handleKey(&vx, key),
                .winsize => |ws| try vx.resize(self.gpa, tty.writer(), ws),
                .media_loaded => try self.finishMedia(tty.writer()),
            }
            if (self.quit) break;
        }
        if (!self.quit) try self.draw(io, &vx, tty.writer(), &loop, &media_tasks);
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    media_loaded,
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

fn draw(self: *App, io: Io, vx: *vaxis.Vaxis, tty: *Io.Writer, loop: *vaxis.Loop(Event), media_tasks: *Io.Group) !void {
    if (vx.caps.kitty_graphics) {
        self.graphics_supported = true;
        if (self.placement_mode == .stable) vx.caps.kitty_graphics = false;
    }
    const win = vx.window();
    const content = win.child(.{
        .x_off = 0,
        .width = @intCast(contentWidth(win.width)),
    });
    self.syncCellSize(content);
    self.syncWidth(content.width);
    try self.prepareFrame(content.height);
    try self.startVisibleMedia(io, loop, media_tasks);

    Renderer.beginFrame();
    win.clear();
    self.virtual_placement_count = 0;
    self.next_stable_placement_count = 0;
    try self.renderViewport(content);
    if (self.placement_mode == .unicode and self.virtual_placement_count > 0) {
        try Kitty.defineVirtualPlacements(tty, self.virtual_placements[0..self.virtual_placement_count]);
    }
    try vx.render(tty);
    if (self.placement_mode == .stable) {
        try Kitty.syncPlacements(
            tty,
            self.stable_placements[0..self.stable_placement_count],
            self.next_stable_placements[0..self.next_stable_placement_count],
        );
        @memcpy(
            self.stable_placements[0..self.next_stable_placement_count],
            self.next_stable_placements[0..self.next_stable_placement_count],
        );
        self.stable_placement_count = self.next_stable_placement_count;
    }
}

/// Content fills four fifths of the window; narrower windows than this
/// (about 960px at 8px cells) use the full width instead of side margins.
const full_width_cols = 120;

fn contentWidth(full: usize) usize {
    if (full < full_width_cols) return full;
    return full * 4 / 5;
}

/// Draws the visible rows, skipping everything above `scroll` and stopping
/// at the window bottom.
fn renderViewport(self: *App, win: vaxis.Window) !void {
    var row: usize = 0;
    var skip = self.scroll;
    for (self.entries.items) |*entry| {
        if (row >= win.height) break;
        // Cached heights are footprints: content rows plus the gap after.
        if (skip >= entry.height) {
            skip -= entry.height;
            continue;
        }
        row = try self.renderEntry(win, entry, row, skip);
        skip = 0;
        row = @min(win.height, row + 1);
    }
}

fn renderEntry(self: *App, win: vaxis.Window, entry: *Entry, row: usize, skip: usize) !usize {
    switch (entry.media) {
        .ready => |image| {
            const rows = Media.rowsForSize(image.width, image.height, self.width, self.cell_width, self.cell_height);
            if (skip >= rows) return row;
            const visible_rows = rows - skip;
            const draw_rows = @min(visible_rows, win.height -| row);
            const cols = @max(1, @min(self.width, math.divCeil(usize, image.width, self.cell_width) catch self.width));
            if (self.placement_mode == .unicode) {
                if ((entry.virtual_rows != rows or entry.virtual_cols != cols) and
                    self.virtual_placement_count < self.virtual_placements.len)
                {
                    entry.virtual_rows = @intCast(rows);
                    entry.virtual_cols = @intCast(cols);
                    self.virtual_placements[self.virtual_placement_count] = .{
                        .image_id = image.id,
                        .rows = entry.virtual_rows,
                        .cols = @intCast(cols),
                    };
                    self.virtual_placement_count += 1;
                }
                Kitty.drawPlaceholder(win, image.id, row, skip, draw_rows, cols);
            } else if (self.next_stable_placement_count < self.next_stable_placements.len) {
                const source_y: u16 = @intCast(@as(usize, image.height) * skip / rows);
                self.next_stable_placements[self.next_stable_placement_count] = .{
                    .image_id = image.id,
                    .row = row,
                    .rows = @intCast(draw_rows),
                    .cols = @intCast(cols),
                    .source_y = if (skip == 0) null else source_y,
                    .source_height = if (skip == 0) null else image.height - source_y,
                };
                self.next_stable_placement_count += 1;
            }
            return row + draw_rows;
        },
        else => return Renderer.render(win, entry.elem, row, skip),
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
            entry.height = self.measureEntry(entry.*);
            self.total_height += entry.height;
            self.measured += 1;
            continue;
        }
        if (self.fully_parsed) return;
        const elem = self.doc.next() orelse {
            self.fully_parsed = true;
            return;
        };
        try self.entries.append(self.gpa, .{
            .elem = elem,
            .media = switch (elem) {
                .image => |image| Media.State.init(image.source),
                else => .idle,
            },
        });
    }
}

fn measureEntry(self: *const App, entry: Entry) usize {
    return switch (entry.media) {
        .ready => |image| Media.rowsForSize(image.width, image.height, self.width, self.cell_width, self.cell_height) + 1,
        else => Renderer.measure(entry.elem, self.width),
    };
}

fn syncCellSize(self: *App, win: vaxis.Window) void {
    const cell_width = if (win.screen.width > 0 and win.screen.width_pix > 0)
        math.divCeil(usize, win.screen.width_pix, win.screen.width) catch 8
    else
        8;
    const cell_height = if (win.screen.height > 0 and win.screen.height_pix > 0)
        math.divCeil(usize, win.screen.height_pix, win.screen.height) catch 16
    else
        16;
    if (self.cell_width == cell_width and self.cell_height == cell_height) return;
    self.cell_width = cell_width;
    self.cell_height = cell_height;
    self.invalidateMeasurementsFrom(0);
}

/// Heights are width-dependent; a width change invalidates them and they
/// are re-measured on demand from the already parsed elements.
fn syncWidth(self: *App, width: usize) void {
    if (self.width == width) return;
    self.width = width;
    self.invalidateMeasurementsFrom(0);
}

fn invalidateMeasurementsFrom(self: *App, index: usize) void {
    const start = @min(index, self.measured);
    for (self.entries.items[start..]) |*entry| entry.height = 0;
    self.measured = start;
    self.total_height = 0;
    for (self.entries.items[0..start]) |entry| self.total_height += entry.height;
}

fn startVisibleMedia(self: *App, io: Io, loop: *vaxis.Loop(Event), media_tasks: *Io.Group) !void {
    if (!self.graphics_supported or self.pending_media != null) return;
    var top: usize = 0;
    for (self.entries.items, 0..) |*entry, index| {
        if (entry.height == 0) break;
        const bottom = top + entry.height;
        const visible = bottom > self.scroll and top < self.scroll + self.viewport;
        top = bottom;
        if (!visible or entry.media != .idle or entry.elem != .image) continue;

        const resolved = try Media.resolveLocal(self.gpa, self.base_dir, entry.elem.image.source);
        errdefer self.gpa.free(resolved);
        const request = try self.gpa.create(MediaRequest);
        errdefer self.gpa.destroy(request);
        request.* = .{
            .entry_index = index,
            .path = resolved,
            .max_width = @intCast(@min(
                math.mul(usize, self.width, self.cell_width) catch math.maxInt(u16),
                math.maxInt(u16),
            )),
            .max_height = @intCast(@min(
                math.mul(usize, 16, self.cell_height) catch math.maxInt(u16),
                math.maxInt(u16),
            )),
        };
        self.pending_media = request;
        entry.media = .loading;
        media_tasks.concurrent(io, loadMedia, .{ io, self.gpa, request, loop }) catch {
            self.pending_media = null;
            entry.media = .failed;
            request.deinit(self.gpa);
            self.gpa.destroy(request);
        };
        return;
    }
}

fn loadMedia(io: Io, gpa: mem.Allocator, request: *MediaRequest, loop: *vaxis.Loop(Event)) Io.Cancelable!void {
    const artifact = Media.loadLocal(io, gpa, request.path, request.max_width, request.max_height) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        request.result = .failed;
        try loop.postEvent(.media_loaded);
        return;
    };
    request.result = .{ .ready = artifact };
    try loop.postEvent(.media_loaded);
}

fn finishMedia(self: *App, tty: *Io.Writer) !void {
    const request = self.pending_media orelse return;
    self.pending_media = null;
    defer {
        request.deinit(self.gpa);
        self.gpa.destroy(request);
    }
    if (request.entry_index >= self.entries.items.len) return;
    const entry = &self.entries.items[request.entry_index];
    switch (request.result) {
        .ready => |artifact| {
            self.evictImage(tty, request.entry_index);
            entry.media = .{ .ready = Kitty.transmit(
                tty,
                self.next_image_id,
                artifact.payload,
                artifact.width,
                artifact.height,
            ) catch {
                entry.media = .failed;
                return;
            } };
            self.next_image_id +%= 1;
            if (self.next_image_id == 0) self.next_image_id = 1;
        },
        .pending, .failed => entry.media = .failed,
    }
    self.invalidateMeasurementsFrom(request.entry_index);
}

fn evictImage(self: *App, tty: *Io.Writer, incoming: usize) void {
    var count: usize = 0;
    var victim: ?usize = null;
    var victim_distance: usize = 0;
    for (self.entries.items, 0..) |entry, index| {
        if (entry.media != .ready) continue;
        count += 1;
        const distance = @max(index, incoming) - @min(index, incoming);
        if (victim == null or distance > victim_distance) {
            victim = index;
            victim_distance = distance;
        }
    }
    if (count < max_images) return;
    const index = victim orelse return;
    Kitty.free(tty, self.entries.items[index].media.ready.id);
    self.entries.items[index].media = .idle;
    self.entries.items[index].virtual_rows = 0;
    self.entries.items[index].virtual_cols = 0;
    self.invalidateMeasurementsFrom(index);
}

fn cancelPendingMedia(self: *App) void {
    const request = self.pending_media orelse return;
    request.deinit(self.gpa);
    self.gpa.destroy(request);
    self.pending_media = null;
}

fn freeImages(self: *App, tty: *Io.Writer) void {
    for (self.entries.items) |*entry| {
        if (entry.media == .ready) Kitty.free(tty, entry.media.ready.id);
        entry.media = .idle;
    }
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
const path = std.fs.path;
const vaxis = @import("vaxis");
const Document = @import("../Document.zig");
const Renderer = @import("Renderer.zig");
const Media = @import("Media.zig");
const Kitty = @import("Kitty.zig");
const Element = Document.Element;
const ArrayList = std.ArrayList;
const max_images = 8;

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

test "ready image entry measures from its raster dimensions" {
    var doc = Document.init("");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 40;
    app.cell_width = 10;
    app.cell_height = 20;
    app.placement_mode = .unicode;

    var entry: Entry = .{
        .elem = .{ .image = .{ .alt = "diagram", .source = "diagram.png", .title = null } },
        .media = .{ .ready = vaxis.Image.init(1, 800, 400) },
    };
    try testing.expectEqual(@as(usize, 11), app.measureEntry(entry));

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 12, .cols = 40, .x_pixel = 400, .y_pixel = 240 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 12,
        .screen = &screen,
    };
    try testing.expectEqual(@as(usize, 10), app.renderEntry(win, &entry, 0, 0));
    try testing.expectEqual(@as(usize, 1), app.virtual_placement_count);
    try testing.expectEqual(@as(u32, 1), app.virtual_placements[0].image_id);
    try testing.expectEqualStrings("\u{10eeee}\u{0305}", win.readCell(0, 0).?.char.grapheme);

    app.virtual_placement_count = 0;
    try testing.expectEqual(@as(usize, 6), app.renderEntry(win, &entry, 0, 4));
    try testing.expectEqual(@as(usize, 0), app.virtual_placement_count);
    try testing.expectEqualStrings("\u{10eeee}\u{0312}", win.readCell(0, 0).?.char.grapheme);

    win.clear();
    app.placement_mode = .stable;
    _ = try app.renderEntry(win, &entry, 0, 0);
    try testing.expectEqual(@as(usize, 1), app.next_stable_placement_count);
    try testing.expectEqual(@as(u32, 1), app.next_stable_placements[0].image_id);
    try testing.expectEqualStrings(" ", win.readCell(0, 0).?.char.grapheme);
}

test "unavailable image states render a placeholder" {
    var doc = Document.init("");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 40;

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 1,
        .screen = &screen,
    };
    const states = [_]Media.State{ .loading, .unsupported, .failed };
    for (states) |state| {
        var entry: Entry = .{
            .elem = .{ .image = .{ .alt = "diagram", .source = "diagram.png", .title = null } },
            .media = state,
        };
        _ = try app.renderEntry(win, &entry, 0, 0);
        try testing.expectEqualStrings("[", win.readCell(0, 0).?.char.grapheme);
        win.clear();
    }
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

    try app.renderViewport(win);
    try expectCell(win, 0, 0, 'f');
    try expectCell(win, 0, 2, 's');

    win.clear();
    app.scroll = 1;
    try app.renderViewport(win);
    try expectCell(win, 0, 0, ' ');
    try expectCell(win, 0, 1, 's');

    win.clear();
    app.scroll = 2;
    try app.renderViewport(win);
    try expectCell(win, 0, 0, 's');
    try expectCell(win, 0, 2, 't');
}

test "content fills four fifths of the window" {
    try testing.expectEqual(@as(usize, 100), contentWidth(100));
    try testing.expectEqual(@as(usize, 20), contentWidth(20));
    try testing.expectEqual(@as(usize, 1), contentWidth(1));
    try testing.expectEqual(@as(usize, 0), contentWidth(0));
    try testing.expectEqual(@as(usize, 119), contentWidth(119));
    try testing.expectEqual(@as(usize, 96), contentWidth(120));
    try testing.expectEqual(@as(usize, 160), contentWidth(200));
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
    try app.renderViewport(win);
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

    try app.renderViewport(win);
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

    try app.renderViewport(win);
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

    try app.renderViewport(win);
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

    try app.renderViewport(win);
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

    try app.renderViewport(win);
    const bar = win.readCell(0, 0) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings("\u{2502}", bar.char.grapheme);
    try expectCell(win, 2, 0, '|');
    try expectCell(win, 4, 0, 'h');
    try expectCell(win, 3, 1, '-');
    try expectCell(win, 4, 2, 'y');
    try expectCell(win, 0, 3, ' ');
}

test "reference links resolve and definitions are stripped" {
    var doc = Document.init("[click][here]\n\n[here]: /url\n");
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

    try app.renderViewport(win);
    const link = win.readCell(0, 0) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings("c", link.char.grapheme);
    try testing.expect(link.style.ul_style == .single);
    try expectCell(win, 4, 0, 'k');
    try expectCell(win, 0, 1, ' ');
    try expectCell(win, 0, 2, ' ');
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
        try app.renderViewport(win);

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
