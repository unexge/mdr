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
    source_end: usize = 0,
    media: Media.State = .idle,
    syntax: SyntaxState = .idle,
    virtual_rows: u16 = 0,
    virtual_cols: u16 = 0,
    /// Footprint rows (content plus trailing gap); zero while unmeasured,
    /// e.g. right after parsing or a width change.
    height: usize = 0,
};

const SyntaxState = union(enum) {
    idle,
    loading,
    ready: Syntax.Highlights,
    failed,

    fn deinit(self: *SyntaxState, gpa: mem.Allocator) void {
        if (self.* == .ready) self.ready.deinit(gpa);
        self.* = .idle;
    }
};

const MediaRequest = struct {
    entry_index: usize,
    path: []u8,
    max_width: u16,
    max_height: u16,
    sizing: Media.Sizing,
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

const SyntaxRequest = struct {
    entry_index: usize,
    block: Element.CodeBlock,
    cache: *Syntax.Cache,
    result: union(enum) {
        pending,
        ready: Syntax.Highlights,
        failed,
    } = .pending,

    fn deinit(self: *SyntaxRequest, gpa: mem.Allocator) void {
        if (self.result == .ready) self.result.ready.deinit(gpa);
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
image_width: usize = 0,
cell_width: usize = 0,
cell_height: usize = 0,
pending_media: ?*MediaRequest = null,
pending_syntax: ?*SyntaxRequest = null,
syntax_cache: Syntax.Cache = .{},
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
search: Search = .{},
scrollbar_visible: bool = true,
scrollbar_generation: u64 = 0,
toc_entries: ArrayList(Toc.Entry) = .empty,
toc_open: bool = false,
toc_selected: usize = 0,
toc_top: usize = 0,
toc_return: usize = 0,
toc_built: bool = false,
toc_list_h: usize = 10,

pub fn init(gpa: mem.Allocator, doc: *Document) App {
    return .{ .gpa = gpa, .doc = doc };
}

pub fn initFile(gpa: mem.Allocator, doc: *Document, file_path: []const u8) App {
    return .{ .gpa = gpa, .doc = doc, .base_dir = path.dirname(file_path) orelse "." };
}

pub fn deinit(self: *App) void {
    for (self.entries.items) |*entry| entry.syntax.deinit(self.gpa);
    self.entries.deinit(self.gpa);
    self.toc_entries.deinit(self.gpa);
    self.syntax_cache.deinit();
    self.* = undefined;
}

pub fn run(self: *App, io: Io, environ: *std.process.Environ.Map) !void {
    self.placement_mode = Kitty.placementMode(
        environ.get("TERM") orelse "",
        environ.get("TERM_PROGRAM") orelse "",
        environ.get("KITTY_WINDOW_ID") orelse "",
        environ.get("ZELLIJ") orelse "",
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
    var syntax_tasks: Io.Group = .init;
    defer {
        syntax_tasks.cancel(io);
        self.cancelPendingSyntax();
    }
    var search_tasks: Io.Group = .init;
    defer search_tasks.cancel(io);
    var scrollbar_tasks: Io.Group = .init;
    defer scrollbar_tasks.cancel(io);
    self.pokeScrollbar(io, &loop, &scrollbar_tasks);

    while (!self.quit) {
        try loop.pollEvent();
        while (try loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| {
                    try self.handleKey(io, &vx, key, &loop, &search_tasks);
                    self.pokeScrollbar(io, &loop, &scrollbar_tasks);
                },
                .winsize => |ws| {
                    try vx.resize(self.gpa, tty.writer(), ws);
                    self.pokeScrollbar(io, &loop, &scrollbar_tasks);
                },
                .media_loaded => try self.finishMedia(tty.writer()),
                .syntax_loaded => self.finishSyntax(),
                .search_tick => |generation| try self.handleSearchTick(generation),
                .scrollbar_tick => |generation| self.handleScrollbarTick(generation),
            }
            if (self.quit) break;
        }
        if (!self.quit) try self.draw(io, &vx, tty.writer(), &loop, &media_tasks, &syntax_tasks);
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    media_loaded,
    syntax_loaded,
    search_tick: u64,
    scrollbar_tick: u64,
};

fn handleKey(self: *App, io: Io, vx: *vaxis.Vaxis, key: vaxis.Key, loop: *vaxis.Loop(Event), search_tasks: *Io.Group) !void {
    if (key.matches('c', .{ .ctrl = true })) {
        self.quit = true;
        return;
    }
    if (self.search.open) {
        try self.handleSearchKey(io, key, loop, search_tasks);
        return;
    }
    if (self.toc_open) {
        try self.handleTocKey(key);
        return;
    }
    if (key.matches('q', .{})) {
        self.quit = true;
    } else if (key.matches('/', .{})) {
        self.search.activate();
    } else if (key.matches(vaxis.Key.escape, .{}) and self.search.len > 0) {
        self.search.cancel();
    } else if (key.matches('N', .{}) and self.search.len > 0) {
        try self.nextMatch(-1);
    } else if (key.matches('n', .{}) and self.search.len > 0) {
        try self.nextMatch(1);
    } else if (key.matches('G', .{}) or key.matches(vaxis.Key.end, .{})) {
        try self.ensureVisible(math.maxInt(usize));
        self.scroll = self.maxScroll();
    } else if (key.matches('l', .{ .ctrl = true })) {
        vx.queueRefresh();
    } else if (key.matches('t', .{})) {
        try self.openToc();
    } else {
        self.scrollKeys(key);
    }
}

fn handleSearchKey(self: *App, io: Io, key: vaxis.Key, loop: *vaxis.Loop(Event), search_tasks: *Io.Group) !void {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.search.cancel();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (self.search.len > 0) try self.commitSearch();
        self.search.confirm();
        return;
    }
    if (key.matches(vaxis.Key.backspace, .{ .ctrl = true }) or
        key.matches(vaxis.Key.backspace, .{ .alt = true }))
    {
        self.search.clear();
        return;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (self.search.backspace()) self.scheduleSearchCommit(io, loop, search_tasks);
        return;
    }
    if (key.matches(vaxis.Key.delete, .{})) {
        if (self.search.deleteAt()) self.scheduleSearchCommit(io, loop, search_tasks);
        return;
    }
    if (key.matches(vaxis.Key.left, .{})) {
        self.search.moveLeft();
        return;
    }
    if (key.matches(vaxis.Key.right, .{})) {
        self.search.moveRight();
        return;
    }
    if (key.matches(vaxis.Key.home, .{})) {
        self.search.cursor = 0;
        return;
    }
    if (key.matches(vaxis.Key.end, .{})) {
        self.search.cursor = self.search.len;
        return;
    }
    if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.meta) return;
    if (key.text) |text| {
        if (text.len > 0 and self.search.insert(text)) {
            self.scheduleSearchCommit(io, loop, search_tasks);
        }
        return;
    }
    if (key.codepoint >= 32 and key.codepoint < 127) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(key.codepoint), &buf) catch return;
        if (self.search.insert(buf[0..n])) self.scheduleSearchCommit(io, loop, search_tasks);
    }
}

fn scheduleSearchCommit(self: *App, io: Io, loop: *vaxis.Loop(Event), search_tasks: *Io.Group) void {
    search_tasks.concurrent(io, searchDebounce, .{ io, self.search.generation, loop }) catch {};
}

fn searchDebounce(io: Io, generation: u64, loop: *vaxis.Loop(Event)) Io.Cancelable!void {
    Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = Search.debounce_ns }, .clock = .awake } }, io) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return;
    };
    _ = loop.tryPostEvent(.{ .search_tick = generation }) catch false;
}

fn handleSearchTick(self: *App, generation: u64) !void {
    if (generation != self.search.generation) return;
    if (!self.search.open) return;
    if (self.search.len == 0) {
        self.search.no_match = false;
        return;
    }
    try self.commitSearch();
}

fn commitSearch(self: *App) !void {
    const q = self.search.query();
    self.search.total = Search.countMatches(self.doc.text, q);
    const found = Search.findFirst(self.doc.text, q) orelse {
        self.search.no_match = true;
        self.search.offset = null;
        self.search.index = 0;
        self.search.focus_entry = null;
        self.search.focus_local = 0;
        return;
    };
    try self.jumpToMatch(found, 0);
}

fn jumpToMatch(self: *App, offset: usize, index: usize) !void {
    self.search.no_match = false;
    self.search.offset = offset;
    self.search.index = index;
    const entry = try self.scrollToOffset(offset);
    self.search.focus_entry = entry;
    const region_start = if (entry == 0) 0 else self.entries.items[entry - 1].source_end;
    const prefix = Search.countMatches(self.doc.text[0..@min(region_start, self.doc.text.len)], self.search.query());
    self.search.focus_local = index -| prefix;
}

fn nextMatch(self: *App, dir: i8) !void {
    const q = self.search.query();
    if (q.len == 0) return;
    const cur = self.search.offset orelse {
        try self.commitSearch();
        return;
    };
    if (dir >= 0) {
        const start = cur + q.len;
        if (start < self.doc.text.len) {
            if (Search.findFirst(self.doc.text[start..], q)) |rel| {
                try self.jumpToMatch(start + rel, self.search.index + 1);
                return;
            }
        }
        if (Search.findFirst(self.doc.text, q)) |first| {
            try self.jumpToMatch(first, 0);
        }
    } else {
        if (Search.findLastBefore(self.doc.text, q, cur)) |prev| {
            try self.jumpToMatch(prev, Search.indexOf(self.doc.text, q, prev));
        } else if (Search.findLastBefore(self.doc.text, q, self.doc.text.len)) |last| {
            try self.jumpToMatch(last, Search.indexOf(self.doc.text, q, last));
        }
    }
}

fn scrollToOffset(self: *App, offset: usize) !usize {
    var row: usize = 0;
    var index: usize = 0;
    while (true) {
        if (index < self.measured) {
            if (self.entries.items[index].source_end > offset) break;
            row += self.entries.items[index].height;
            index += 1;
        } else {
            const before = self.total_height;
            try self.ensureVisible(before + 1);
            if (self.total_height == before) break;
        }
    }
    // Measure a screenful past the target (or to the end) so the clamp
    // below uses a complete total instead of the parsed prefix.
    try self.ensureVisible(row + self.viewport + 1);
    self.scroll = row -| 1;
    self.clampScroll();
    if (self.entries.items.len == 0) return 0;
    return @min(index, self.entries.items.len - 1);
}

fn handleTocKey(self: *App, key: vaxis.Key) !void {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.tocRestore();
    } else if (key.matches(vaxis.Key.enter, .{})) {
        self.tocCommit();
    } else if (key.matches('t', .{})) {
        self.tocCommit();
    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        try self.tocMove(-1);
    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        try self.tocMove(1);
    } else if (key.matches(vaxis.Key.home, .{}) or key.matches('g', .{})) {
        try self.tocGoTo(0);
    } else if (key.matches(vaxis.Key.end, .{}) or key.matches('G', .{})) {
        try self.tocGoTo(self.toc_entries.items.len -| 1);
    } else if (key.matches(vaxis.Key.page_up, .{})) {
        try self.tocMove(-@as(isize, @intCast(self.toc_list_h)));
    } else if (key.matches(vaxis.Key.page_down, .{}) or key.matches(' ', .{})) {
        try self.tocMove(@as(isize, @intCast(self.toc_list_h)));
    }
}

fn openToc(self: *App) !void {
    try self.ensureToc();
    self.toc_return = self.scroll;
    self.toc_selected = self.tocIndexAtScroll();
    self.toc_top = 0;
    self.toc_open = true;
}

fn tocCommit(self: *App) void {
    self.toc_open = false;
}

fn tocRestore(self: *App) void {
    self.scroll = self.toc_return;
    self.clampScroll();
    self.toc_open = false;
}

fn ensureToc(self: *App) !void {
    if (self.toc_built) return;
    const list = try Toc.collect(self.gpa, self.doc.text);
    self.toc_entries.deinit(self.gpa);
    self.toc_entries = list;
    self.toc_built = true;
}

fn tocMove(self: *App, step: isize) !void {
    const count = self.toc_entries.items.len;
    if (count == 0) return;
    const last: isize = @intCast(count - 1);
    const next = @max(0, @min(@as(isize, @intCast(self.toc_selected)) + step, last));
    try self.tocGoTo(@intCast(next));
}

fn tocGoTo(self: *App, index: usize) !void {
    const count = self.toc_entries.items.len;
    if (count == 0) return;
    self.toc_selected = @min(index, count - 1);
    const list_h = @max(self.toc_list_h, 1);
    if (self.toc_selected < self.toc_top) self.toc_top = self.toc_selected;
    if (self.toc_selected >= self.toc_top + list_h) self.toc_top = self.toc_selected - list_h + 1;
    _ = try self.scrollToOffset(self.toc_entries.items[self.toc_selected].offset);
}

/// Heading at or above the first visible content row, so reopening the
/// outline selects where the reader already is.
fn tocIndexAtScroll(self: *const App) usize {
    const items = self.toc_entries.items;
    if (items.len == 0) return 0;
    const probe = @min(self.scroll + 1, self.total_height -| 1);
    var skip = probe;
    var off: usize = 0;
    for (self.entries.items, 0..) |entry, i| {
        if (skip >= entry.height) {
            skip -= entry.height;
            continue;
        }
        off = if (i == 0) 0 else self.entries.items[i - 1].source_end;
        break;
    }
    var selected: usize = 0;
    for (items, 0..) |entry, i| {
        if (entry.offset > off) break;
        selected = i;
    }
    return selected;
}

fn scrollKeys(self: *App, key: vaxis.Key) void {
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        self.scroll += 1;
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        self.scroll -|= 1;
    } else if (key.matches(' ', .{}) or key.matches('f', .{}) or key.matches(vaxis.Key.page_down, .{}) or key.matches('f', .{ .ctrl = true })) {
        self.scroll += pageRows(self.viewport);
    } else if (key.matches('b', .{}) or key.matches(vaxis.Key.page_up, .{}) or key.matches('b', .{ .ctrl = true })) {
        self.scroll -|= pageRows(self.viewport);
    } else if (key.matches('d', .{ .ctrl = true })) {
        self.scroll += halfRows(self.viewport);
    } else if (key.matches('u', .{ .ctrl = true })) {
        self.scroll -|= halfRows(self.viewport);
    } else if (key.matches('g', .{}) or key.matches(vaxis.Key.home, .{})) {
        self.scroll = 0;
    }
}

fn pageRows(viewport: usize) usize {
    return if (viewport > 1) viewport - 1 else 1;
}

fn halfRows(viewport: usize) usize {
    return @max(viewport / 2, 1);
}

fn draw(
    self: *App,
    io: Io,
    vx: *vaxis.Vaxis,
    tty: *Io.Writer,
    loop: *vaxis.Loop(Event),
    media_tasks: *Io.Group,
    syntax_tasks: *Io.Group,
) !void {
    if (vx.caps.kitty_graphics) {
        self.graphics_supported = true;
        if (self.placement_mode != .unicode) vx.caps.kitty_graphics = false;
    }
    const win = vx.window();
    const bar_rows: u16 = if (self.search.open) 1 else 0;
    const content = win.child(.{
        .x_off = 0,
        .width = @intCast(contentWidth(win.width)),
        .height = win.height -| bar_rows,
    });
    const cell_size_changed = self.syncCellSize(content);
    self.syncWidth(content.width);
    const image_width_changed = self.syncImageWidth(win.width);
    if (self.placement_mode == .remainder and (cell_size_changed or image_width_changed)) {
        self.resetReadyImages(tty);
    }
    try self.prepareFrame(content.height);
    try self.startVisibleMedia(io, loop, media_tasks);
    try self.startVisibleSyntax(io, loop, syntax_tasks);

    Renderer.beginFrame();
    Renderer.setSearchQuery(self.search.query());
    win.clear();
    self.virtual_placement_count = 0;
    self.next_stable_placement_count = 0;
    try self.renderViewport(content);
    if (bar_rows > 0) {
        self.drawScrollbar(win.child(.{ .height = win.height -| 1 }));
        self.drawSearchBar(win);
    } else {
        self.drawScrollbar(win);
    }
    self.drawSearchCount(win);
    if (self.toc_open) self.drawToc(win);
    if (self.placement_mode == .unicode and self.virtual_placement_count > 0) {
        try Kitty.defineVirtualPlacements(tty, self.virtual_placements[0..self.virtual_placement_count]);
    }
    try vx.render(tty);
    if (self.placement_mode != .unicode) {
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

/// Draws a reading-progress rail in the last column. On wide windows the
/// content leaves that column free; on narrow windows the rail overlays
/// the last text column while visible and hides after a second, so text
/// is only briefly covered.
fn drawScrollbar(self: *App, win: vaxis.Window) void {
    if (!self.scrollbar_visible) return;
    if (win.width == 0 or win.height < 2) return;
    const thumb = self.scrollbarThumb(win.height) orelse return;
    const x: u16 = win.width - 1;
    var r: usize = 0;
    while (r < win.height) : (r += 1) {
        const on_thumb = r >= thumb.y and r < thumb.y + thumb.h;
        win.writeCell(x, @intCast(r), .{
            .char = .{ .grapheme = if (on_thumb) "█" else "│", .width = 1 },
            .style = if (on_thumb) .{ .fg = Theme.accent } else .{ .fg = Theme.muted },
        });
    }
}

const ScrollbarThumb = struct {
    h: usize,
    y: usize,
};

fn scrollbarThumb(self: *const App, height: usize) ?ScrollbarThumb {
    if (height < 2) return null;
    const total_height = self.scrollbarTotalHeight();
    if (total_height <= self.viewport) return null;
    const max_scroll = total_height -| (self.viewport + 1);
    const thumb_h = @max(1, self.viewport * height / total_height);
    const thumb_y = if (max_scroll == 0) 0 else self.scroll * (height - thumb_h) / max_scroll;
    return .{ .h = thumb_h, .y = thumb_y };
}

fn pokeScrollbar(self: *App, io: Io, loop: *vaxis.Loop(Event), tasks: *Io.Group) void {
    self.markScrollbarActive();
    tasks.concurrent(io, scrollbarHide, .{ io, self.scrollbar_generation, loop }) catch {};
}

fn markScrollbarActive(self: *App) void {
    self.scrollbar_visible = true;
    self.scrollbar_generation +%= 1;
}

fn scrollbarHide(io: Io, generation: u64, loop: *vaxis.Loop(Event)) Io.Cancelable!void {
    Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = scrollbar_hide_ns }, .clock = .awake } }, io) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return;
    };
    _ = loop.tryPostEvent(.{ .scrollbar_tick = generation }) catch false;
}

fn handleScrollbarTick(self: *App, generation: u64) void {
    if (generation != self.scrollbar_generation) return;
    self.scrollbar_visible = false;
}

const scrollbar_hide_ns: u64 = 1_000_000_000;

fn drawSearchBar(self: *App, win: vaxis.Window) void {
    if (win.height == 0 or win.width == 0) return;
    const row: u16 = win.height - 1;
    var col: usize = 0;
    while (col < win.width) : (col += 1) {
        win.writeCell(@intCast(col), row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = Theme.panel },
        });
    }
    const prompt_style: vaxis.Style = .{ .fg = Theme.accent, .bg = Theme.panel, .bold = true };
    const query_style: vaxis.Style = .{ .bg = Theme.panel };
    const cursor_style: vaxis.Style = .{ .bg = Theme.panel, .reverse = true };
    win.writeCell(0, row, .{ .char = .{ .grapheme = "/", .width = 1 }, .style = prompt_style });
    col = 1;
    const q = self.search.query();
    var iter = unicode.graphemeIterator(q);
    while (iter.next()) |g| {
        const bytes = g.bytes(q);
        const w = vaxis.gwidth.gwidth(bytes, .unicode);
        if (w == 0) continue;
        if (col + w >= win.width) continue;
        win.writeCell(@intCast(col), row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(w) },
            .style = query_style,
        });
        col += w;
    }
    const cursor_col = 1 + queryCursorWidth(q[0..@min(self.search.cursor, q.len)]);
    const under: []const u8 = if (self.search.cursor < q.len) cursorGrapheme(q[self.search.cursor..]) else " ";
    const cursor_width = vaxis.gwidth.gwidth(under, .unicode);
    if (cursor_col + cursor_width < win.width) {
        win.writeCell(@intCast(cursor_col), row, .{
            .char = .{ .grapheme = under, .width = @intCast(cursor_width) },
            .style = cursor_style,
        });
    }
    if (self.search.no_match) {
        const msg = " no matches";
        var miter = unicode.graphemeIterator(msg);
        var mcol: usize = col + 1;
        while (miter.next()) |g| {
            const bytes = g.bytes(msg);
            if (mcol + 1 >= win.width) break;
            win.writeCell(@intCast(mcol), row, .{
                .char = .{ .grapheme = bytes, .width = 1 },
                .style = .{ .fg = Theme.muted, .bg = Theme.panel },
            });
            mcol += 1;
        }
    }
}

fn drawSearchCount(self: *App, win: vaxis.Window) void {
    if (self.search.len == 0) return;
    if (win.height == 0 or win.width < 10) return;
    const text = self.search.countText();
    if (text.len == 0 or text.len + 2 > win.width) return;
    var col: usize = win.width - 1 - text.len;
    var iter = unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        if (col >= win.width) break;
        win.writeCell(@intCast(col), 0, .{
            .char = .{ .grapheme = bytes, .width = 1 },
            .style = .{ .fg = Theme.gold, .bg = Theme.panel, .bold = true },
        });
        col += 1;
    }
}

/// Centered outline modal. Document cells behind stay as drawn; image
/// placements are suppressed while open so graphics cannot leak through.
fn drawToc(self: *App, win: vaxis.Window) void {
    const items = self.toc_entries.items;
    const box = Toc.boxFor(win.width, win.height, items.len);
    if (box.w < 10 or box.h < 5) return;
    Toc.beginFrame();
    self.toc_list_h = @max(box.list_h, 1);
    if (self.toc_selected < self.toc_top) self.toc_top = self.toc_selected;
    if (self.toc_selected >= self.toc_top + self.toc_list_h) {
        self.toc_top = self.toc_selected - self.toc_list_h + 1;
    }
    const frame: vaxis.Window = win.child(.{
        .x_off = @intCast(box.x),
        .y_off = @intCast(box.y),
        .width = @intCast(box.w),
        .height = @intCast(box.h),
    });
    const panel: vaxis.Style = .{ .bg = Theme.panel };
    var r: usize = 0;
    while (r < box.h) : (r += 1) {
        var c: usize = 0;
        while (c < box.w) : (c += 1) {
            frame.writeCell(@intCast(c), @intCast(r), .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = panel,
            });
        }
    }
    const border: vaxis.Style = .{ .fg = Theme.muted, .bg = Theme.panel };
    var c: usize = 1;
    while (c + 1 < box.w) : (c += 1) {
        frame.writeCell(@intCast(c), 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = border });
        frame.writeCell(@intCast(c), @intCast(box.h - 1), .{ .char = .{ .grapheme = "─", .width = 1 }, .style = border });
    }
    frame.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = border });
    frame.writeCell(@intCast(box.w - 1), 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = border });
    frame.writeCell(0, @intCast(box.h - 1), .{ .char = .{ .grapheme = "└", .width = 1 }, .style = border });
    frame.writeCell(@intCast(box.w - 1), @intCast(box.h - 1), .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = border });
    var side: usize = 1;
    while (side + 1 < box.h) : (side += 1) {
        frame.writeCell(0, @intCast(side), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border });
        frame.writeCell(@intCast(box.w - 1), @intCast(side), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = border });
    }
    _ = putTocCells(frame, 2, 0, "Contents", .{ .fg = Theme.accent, .bg = Theme.panel, .bold = true }, box.w -| 4);
    if (items.len == 0) {
        _ = putTocCells(frame, 2, 1, "(no headings)", .{ .fg = Theme.muted, .bg = Theme.panel }, box.w -| 4);
    } else {
        var title_buf: [256]u8 = undefined;
        var i: usize = 0;
        while (i < box.list_h) : (i += 1) {
            const index = self.toc_top + i;
            if (index >= items.len) break;
            const entry = items[index];
            const row = i + 1;
            const selected = index == self.toc_selected;
            const row_style: vaxis.Style = if (selected)
                .{ .fg = Theme.panel, .bg = Theme.accent, .bold = true }
            else
                .{ .bg = Theme.panel };
            const guide_style: vaxis.Style = if (selected) row_style else .{ .fg = Theme.muted, .bg = Theme.panel };
            var pad: usize = 1;
            while (pad + 1 < box.w) : (pad += 1) {
                frame.writeCell(@intCast(pad), @intCast(row), .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = row_style,
                });
            }
            var col: usize = 1;
            var chain: [6]bool = undefined;
            var chain_len: usize = 0;
            var ancestor = entry.parent;
            while (ancestor) |a| {
                chain[chain_len] = items[a].last;
                chain_len += 1;
                ancestor = items[a].parent;
            }
            while (chain_len > 0) {
                chain_len -= 1;
                col += putTocCells(frame, col, row, if (chain[chain_len]) "   " else "│  ", guide_style, 3);
            }
            col += putTocCells(frame, col, row, if (entry.last) "└── " else "├── ", guide_style, 4);
            const avail = (box.w -| 1) -| col;
            if (avail == 0) continue;
            const raw = Toc.flatten(entry.content, &self.doc.refs, &title_buf);
            const title = Toc.copyTitle(raw);
            _ = putTocCells(frame, col, row, title, row_style, avail);
        }
    }
    const footer_style: vaxis.Style = .{ .fg = Theme.muted, .bg = Theme.panel };
    var hint_max = box.w -| 4;
    if (items.len > 0) hint_max = hint_max -| 8;
    _ = putTocCells(frame, 2, box.h - 2, "Up/Down jump  Enter stay  Esc back", footer_style, hint_max);
    if (items.len > 0) {
        var count_buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ self.toc_selected + 1, items.len }) catch "";
        if (count.len + 3 < box.w) {
            _ = putTocCells(frame, box.w - 2 - count.len, box.h - 2, count, footer_style, count.len);
        }
    }
}

fn putTocCells(box: vaxis.Window, col: usize, row: usize, text: []const u8, style: vaxis.Style, max_cols: usize) usize {
    if (col >= box.width or row >= box.height) return 0;
    var c = col;
    const limit = @min(col + max_cols, box.width);
    var iter = unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const w = vaxis.gwidth.gwidth(bytes, .unicode);
        if (w == 0 or c + w > limit) break;
        box.writeCell(@intCast(c), @intCast(row), .{
            .char = .{ .grapheme = bytes, .width = @intCast(w) },
            .style = style,
        });
        c += w;
    }
    return c - col;
}

fn queryCursorWidth(before: []const u8) usize {
    var w: usize = 0;
    var iter = unicode.graphemeIterator(before);
    while (iter.next()) |g| w += vaxis.gwidth.gwidth(g.bytes(before), .unicode);
    return w;
}

fn cursorGrapheme(rest: []const u8) []const u8 {
    var iter = unicode.graphemeIterator(rest);
    if (iter.next()) |g| return g.bytes(rest);
    return " ";
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
    for (self.entries.items, 0..) |*entry, i| {
        if (row >= win.height) break;
        // Cached heights are footprints: content rows plus the gap after.
        if (skip >= entry.height) {
            skip -= entry.height;
            continue;
        }
        Search.setEntryFocus(self.search.focus_entry == i, self.search.focus_local);
        row = try self.renderEntry(win, entry, row, skip);
        skip = 0;
        row = @min(win.height, row + 1);
    }
}

fn renderEntry(self: *App, win: vaxis.Window, entry: *Entry, row: usize, skip: usize) !usize {
    switch (entry.media) {
        .ready => |image| {
            const cols = self.imageCols(image);
            const rows = self.imageRows(image, cols);
            if (skip >= rows) return row;
            const visible_rows = rows - skip;
            const draw_rows = @min(visible_rows, win.height -| row);
            // Behind the outline modal images keep their rows but emit no
            // placements, so no graphics show through the panel.
            if (self.toc_open) return row + draw_rows;
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
                const source_y: u16 = if (self.placement_mode == .remainder)
                    sourcePixelRow(image.height, skip, self.cell_height)
                else
                    @intCast(@as(usize, image.height) * skip / rows);
                const source_bottom: u16 = if (self.placement_mode == .remainder)
                    image.height
                else
                    @intCast(math.divCeil(
                        usize,
                        @as(usize, image.height) * (skip + draw_rows),
                        rows,
                    ) catch image.height);
                const clipped = skip > 0 or
                    (self.placement_mode != .remainder and draw_rows < visible_rows);
                self.next_stable_placements[self.next_stable_placement_count] = .{
                    .image_id = image.id,
                    .row = row,
                    .rows = @intCast(if (self.placement_mode == .remainder) visible_rows else draw_rows),
                    .cols = @intCast(cols),
                    .source = if (clipped) .{
                        .y = source_y,
                        .width = image.width,
                        .height = @max(1, source_bottom - source_y),
                    } else null,
                };
                self.next_stable_placement_count += 1;
            }
            return row + draw_rows;
        },
        else => return switch (entry.syntax) {
            .ready => |*highlights| Renderer.renderHighlighted(win, entry.elem, row, skip, highlights),
            else => Renderer.render(win, entry.elem, row, skip),
        },
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
            .source_end = self.doc.cursor,
            .media = switch (elem) {
                .image => |image| Media.State.init(image.source),
                else => .idle,
            },
        });
    }
}

fn measureEntry(self: *const App, entry: Entry) usize {
    return switch (entry.media) {
        .ready => |image| self.imageRows(image, self.imageCols(image)) + 1,
        else => Renderer.measure(entry.elem, self.width),
    };
}

fn imageCols(self: *const App, image: vaxis.Image) usize {
    if (self.placement_mode == .remainder) {
        return @max(1, @min(self.width, math.divCeil(usize, image.width, self.cell_width) catch 1));
    }
    return @max(1, @min(self.image_width, self.width));
}

fn imageRows(self: *const App, image: vaxis.Image, cols: usize) usize {
    if (self.placement_mode == .remainder) {
        return @max(1, math.divCeil(usize, image.height, self.cell_height) catch 1);
    }
    const rows = Media.rowsForSize(image.width, image.height, cols, self.cell_width, self.cell_height);
    return if (self.placement_mode == .unicode) @min(rows, Kitty.max_placeholder_rows) else rows;
}

fn syncCellSize(self: *App, win: vaxis.Window) bool {
    const cell_width = if (win.screen.width > 0 and win.screen.width_pix > 0)
        math.divCeil(usize, win.screen.width_pix, win.screen.width) catch 8
    else
        8;
    const cell_height = if (win.screen.height > 0 and win.screen.height_pix > 0)
        math.divCeil(usize, win.screen.height_pix, win.screen.height) catch 16
    else
        16;
    if (self.cell_width == cell_width and self.cell_height == cell_height) return false;
    self.cell_width = cell_width;
    self.cell_height = cell_height;
    self.invalidateMeasurementsFrom(0);
    return true;
}

/// Heights are width-dependent; a width change invalidates them and they
/// are re-measured on demand from the already parsed elements.
fn syncWidth(self: *App, width: usize) void {
    if (self.width == width) return;
    self.width = width;
    self.invalidateMeasurementsFrom(0);
}

fn syncImageWidth(self: *App, screen_width: usize) bool {
    const image_width = imageWidthForScreen(screen_width, self.width);
    if (self.image_width == image_width) return false;
    self.image_width = image_width;
    self.invalidateMeasurementsFrom(0);
    return true;
}

fn imageWidthForScreen(screen_width: usize, content_width: usize) usize {
    return @max(1, @min(content_width, screen_width * 4 / 5));
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
            .max_width = self.imagePixelWidth(),
            .max_height = math.maxInt(u16),
            .sizing = if (self.placement_mode == .remainder) .width else .fit,
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
    const artifact = Media.loadLocal(io, gpa, request.path, request.max_width, request.max_height, request.sizing) catch |err| {
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
    if (self.placement_mode == .remainder and request.max_width != self.imagePixelWidth()) {
        entry.media = .idle;
        self.invalidateMeasurementsFrom(request.entry_index);
        return;
    }
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

fn startVisibleSyntax(self: *App, io: Io, loop: *vaxis.Loop(Event), tasks: *Io.Group) !void {
    if (self.pending_syntax != null) return;
    const cache = &self.syntax_cache;
    var top: usize = 0;
    for (self.entries.items, 0..) |*entry, index| {
        if (entry.height == 0) break;
        const bottom = top + entry.height;
        const visible = bottom > self.scroll and top < self.scroll + self.viewport;
        top = bottom;
        if (!visible or entry.syntax != .idle) continue;
        const block = switch (entry.elem) {
            .code_block => |block| block,
            else => continue,
        };
        if (block.info == null or block.info.?.isMermaid() or block.content.len > Syntax.max_source_bytes) {
            entry.syntax = .failed;
            continue;
        }

        const request = try self.gpa.create(SyntaxRequest);
        errdefer self.gpa.destroy(request);
        request.* = .{
            .entry_index = index,
            .block = block,
            .cache = cache,
        };
        self.pending_syntax = request;
        entry.syntax = .loading;
        tasks.concurrent(io, loadSyntax, .{ io, self.gpa, request, loop }) catch {
            self.pending_syntax = null;
            entry.syntax = .failed;
            request.deinit(self.gpa);
            self.gpa.destroy(request);
        };
        return;
    }
}

fn loadSyntax(
    io: Io,
    gpa: mem.Allocator,
    request: *SyntaxRequest,
    loop: *vaxis.Loop(Event),
) Io.Cancelable!void {
    _ = io;
    const highlights = Syntax.load(gpa, request.cache, request.block) catch {
        request.result = .failed;
        try loop.postEvent(.syntax_loaded);
        return;
    };
    request.result = .{ .ready = highlights };
    try loop.postEvent(.syntax_loaded);
}

fn finishSyntax(self: *App) void {
    const request = self.pending_syntax orelse return;
    self.pending_syntax = null;
    defer {
        request.deinit(self.gpa);
        self.gpa.destroy(request);
    }
    if (request.entry_index >= self.entries.items.len) return;
    const entry = &self.entries.items[request.entry_index];
    switch (request.result) {
        .ready => |highlights| {
            entry.syntax = .{ .ready = highlights };
            request.result = .pending;
        },
        .pending, .failed => entry.syntax = .failed,
    }
}

fn cancelPendingSyntax(self: *App) void {
    const request = self.pending_syntax orelse return;
    request.deinit(self.gpa);
    self.gpa.destroy(request);
    self.pending_syntax = null;
}

fn imagePixelWidth(self: *const App) u16 {
    return @intCast(@min(
        math.mul(usize, self.image_width, self.cell_width) catch math.maxInt(u16),
        math.maxInt(u16),
    ));
}

fn sourcePixelRow(image_height: u16, row: usize, cell_height: usize) u16 {
    return @intCast(@min(
        image_height,
        math.mul(usize, row, cell_height) catch math.maxInt(usize),
    ));
}

fn resetReadyImages(self: *App, tty: *Io.Writer) void {
    var first = self.entries.items.len;
    for (self.entries.items, 0..) |*entry, index| {
        if (entry.media != .ready) continue;
        Kitty.free(tty, entry.media.ready.id);
        entry.media = .idle;
        entry.virtual_rows = 0;
        entry.virtual_cols = 0;
        first = @min(first, index);
    }
    if (first < self.entries.items.len) self.invalidateMeasurementsFrom(first);
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

/// Estimates unparsed rows from source progress so the scrollbar does not
/// treat the lazily measured prefix as the whole document.
fn scrollbarTotalHeight(self: *const App) usize {
    if (self.total_height == 0 or self.measured == 0) return self.total_height;
    if (self.fully_parsed and self.measured == self.entries.items.len) return self.total_height;
    const source_end = self.entries.items[self.measured - 1].source_end;
    if (source_end == 0) return self.total_height;
    const scaled = math.mul(usize, self.total_height, self.doc.text.len) catch return math.maxInt(usize);
    return @max(
        self.total_height,
        math.divCeil(usize, scaled, source_end) catch self.total_height,
    );
}

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const path = std.fs.path;
const vaxis = @import("vaxis");
const Document = @import("../Document.zig");
const Renderer = @import("Renderer.zig");
const Search = @import("Search.zig");
const Syntax = @import("Syntax.zig");
const Theme = @import("Theme.zig");
const Media = @import("Media.zig");
const Kitty = @import("Kitty.zig");
const Toc = @import("Toc.zig");
const unicode = vaxis.unicode;
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

test "scroll key bindings" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.viewport = 11;

    app.scrollKeys(.{ .codepoint = 'j' });
    try testing.expectEqual(@as(usize, 1), app.scroll);
    app.scrollKeys(.{ .codepoint = 'k' });
    try testing.expectEqual(@as(usize, 0), app.scroll);
    app.scrollKeys(.{ .codepoint = 'k' });
    try testing.expectEqual(@as(usize, 0), app.scroll);

    app.scrollKeys(.{ .codepoint = ' ' });
    try testing.expectEqual(@as(usize, 10), app.scroll);
    app.scrollKeys(.{ .codepoint = 'g' });
    try testing.expectEqual(@as(usize, 0), app.scroll);

    app.scrollKeys(.{ .codepoint = 'f' });
    try testing.expectEqual(@as(usize, 10), app.scroll);
    app.scrollKeys(.{ .codepoint = 'b' });
    try testing.expectEqual(@as(usize, 0), app.scroll);

    app.scrollKeys(.{ .codepoint = 'f', .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 10), app.scroll);
    app.scrollKeys(.{ .codepoint = 'b', .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 0), app.scroll);

    app.scrollKeys(.{ .codepoint = 'd', .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 5), app.scroll);
    app.scrollKeys(.{ .codepoint = 'd', .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 10), app.scroll);
    app.scrollKeys(.{ .codepoint = 'u', .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 5), app.scroll);

    app.scrollKeys(.{ .codepoint = 'x' });
    try testing.expectEqual(@as(usize, 5), app.scroll);
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
    app.image_width = 24;
    app.cell_width = 10;
    app.cell_height = 20;
    app.placement_mode = .unicode;

    var entry: Entry = .{
        .elem = .{ .image = .{ .alt = "diagram", .source = "diagram.png", .title = null } },
        .media = .{ .ready = vaxis.Image.init(1, 800, 400) },
    };
    try testing.expectEqual(@as(usize, 7), app.measureEntry(entry));

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
    try testing.expectEqual(@as(usize, 6), app.renderEntry(win, &entry, 0, 0));
    try testing.expectEqual(@as(usize, 1), app.virtual_placement_count);
    try testing.expectEqual(@as(u32, 1), app.virtual_placements[0].image_id);
    try testing.expectEqual(@as(u16, 24), app.virtual_placements[0].cols);
    try testing.expectEqualStrings("\u{10eeee}\u{0305}", win.readCell(0, 0).?.char.grapheme);

    app.virtual_placement_count = 0;
    try testing.expectEqual(@as(usize, 2), app.renderEntry(win, &entry, 0, 4));
    try testing.expectEqual(@as(usize, 0), app.virtual_placement_count);
    try testing.expectEqualStrings("\u{10eeee}\u{0312}", win.readCell(0, 0).?.char.grapheme);

    win.clear();
    app.placement_mode = .stable;
    _ = try app.renderEntry(win, &entry, 0, 0);
    try testing.expectEqual(@as(usize, 1), app.next_stable_placement_count);
    try testing.expectEqual(@as(u32, 1), app.next_stable_placements[0].image_id);
    try testing.expectEqualStrings(" ", win.readCell(0, 0).?.char.grapheme);

    app.next_stable_placement_count = 0;
    _ = try app.renderEntry(win, &entry, 10, 0);
    try testing.expectEqual(@as(u16, 2), app.next_stable_placements[0].rows);
    try testing.expectEqual(
        Kitty.Placement.SourceRect{ .y = 0, .width = 800, .height = 134 },
        app.next_stable_placements[0].source.?,
    );

    app.next_stable_placement_count = 0;
    _ = try app.renderEntry(win, &entry, 0, 4);
    try testing.expectEqual(
        Kitty.Placement.SourceRect{ .y = 266, .width = 800, .height = 134 },
        app.next_stable_placements[0].source.?,
    );

    app.next_stable_placement_count = 0;
    app.placement_mode = .remainder;
    var remainder_entry: Entry = .{
        .elem = entry.elem,
        .media = .{ .ready = vaxis.Image.init(2, 240, 120) },
    };
    _ = try app.renderEntry(win, &remainder_entry, 10, 0);
    try testing.expectEqual(@as(u16, 6), app.next_stable_placements[0].rows);
    try testing.expectEqual(@as(?Kitty.Placement.SourceRect, null), app.next_stable_placements[0].source);

    app.next_stable_placement_count = 0;
    _ = try app.renderEntry(win, &remainder_entry, 0, 4);
    try testing.expectEqual(@as(u16, 2), app.next_stable_placements[0].rows);
    try testing.expectEqual(@as(u16, 24), app.next_stable_placements[0].cols);
    try testing.expectEqual(
        Kitty.Placement.SourceRect{ .y = 80, .width = 240, .height = 40 },
        app.next_stable_placements[0].source.?,
    );
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

test "scrollbar estimates full height before layout is complete" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = contentWidth(130);
    try app.prepareFrame(10);
    try testing.expect(!app.fully_parsed);

    var complete_doc = Document.init(lazy_text);
    var complete_app = App.init(testing.allocator, &complete_doc);
    defer complete_app.deinit();
    complete_app.width = app.width;
    complete_app.viewport = app.viewport;
    try complete_app.ensureVisible(math.maxInt(usize));
    const expected_thumb_h = @max(1, app.viewport * 10 / complete_app.total_height);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 130, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 130,
        .height = 10,
        .screen = &screen,
    };

    app.drawScrollbar(win);
    var thumb_h: usize = 0;
    for (0..win.height) |row| {
        const cell = win.readCell(129, @intCast(row)) orelse return error.TestUnexpectedCell;
        if (mem.eql(u8, "█", cell.char.grapheme)) thumb_h += 1;
    }
    try testing.expectEqual(expected_thumb_h, thumb_h);

    const resized_width = contentWidth(120);
    var resized_doc = Document.init(lazy_text);
    var resized_app = App.init(testing.allocator, &resized_doc);
    defer resized_app.deinit();
    resized_app.width = resized_width;
    resized_app.viewport = app.viewport;
    try resized_app.ensureVisible(math.maxInt(usize));
    const resized_thumb_h = @max(1, app.viewport * 10 / resized_app.total_height);

    complete_app.syncWidth(resized_width);
    try complete_app.prepareFrame(10);
    try testing.expect(complete_app.measured < complete_app.entries.items.len);

    win.clear();
    complete_app.drawScrollbar(win);
    thumb_h = 0;
    for (0..win.height) |row| {
        const cell = win.readCell(129, @intCast(row)) orelse return error.TestUnexpectedCell;
        if (mem.eql(u8, "█", cell.char.grapheme)) thumb_h += 1;
    }
    try testing.expectEqual(resized_thumb_h, thumb_h);
}

test "scrollbar tracks scroll position" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 20;
    try app.ensureVisible(math.maxInt(usize));
    app.viewport = 3;
    app.clampScroll();
    try testing.expect(app.total_height > app.viewport);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 130, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 130,
        .height = 10,
        .screen = &screen,
    };

    app.scroll = 0;
    app.drawScrollbar(win);
    try testing.expectEqualStrings("█", win.readCell(129, 0).?.char.grapheme);
    try testing.expectEqualStrings("│", win.readCell(129, 9).?.char.grapheme);

    win.clear();
    app.scroll = app.maxScroll();
    app.drawScrollbar(win);
    try testing.expectEqualStrings("│", win.readCell(129, 0).?.char.grapheme);
    try testing.expectEqualStrings("█", win.readCell(129, 9).?.char.grapheme);
}

test "scrollbar hides after a second without input" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 20;
    try app.ensureVisible(math.maxInt(usize));
    app.viewport = 3;

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 130, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 130,
        .height = 10,
        .screen = &screen,
    };

    app.drawScrollbar(win);
    try testing.expectEqualStrings("█", win.readCell(129, 0).?.char.grapheme);

    app.markScrollbarActive();
    app.handleScrollbarTick(app.scrollbar_generation - 1);
    try testing.expect(app.scrollbar_visible);

    app.handleScrollbarTick(app.scrollbar_generation);
    try testing.expect(!app.scrollbar_visible);
    win.clear();
    app.drawScrollbar(win);
    for (0..10) |row| {
        const cell = win.readCell(129, @intCast(row)).?;
        try testing.expect(!mem.eql(u8, "█", cell.char.grapheme));
        try testing.expect(!mem.eql(u8, "│", cell.char.grapheme));
    }

    app.markScrollbarActive();
    try testing.expect(app.scrollbar_visible);
}

test "scrollbar shows on narrow windows" {
    var doc = Document.init(lazy_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();

    app.width = 40;
    try app.ensureVisible(math.maxInt(usize));
    app.viewport = 3;
    try testing.expect(app.total_height > app.viewport);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 10,
        .screen = &screen,
    };

    app.scroll = 0;
    app.drawScrollbar(win);
    try testing.expectEqualStrings("█", win.readCell(39, 0).?.char.grapheme);
    try testing.expectEqualStrings("│", win.readCell(39, 9).?.char.grapheme);

    win.clear();
    app.scroll = app.maxScroll();
    app.drawScrollbar(win);
    try testing.expectEqualStrings("│", win.readCell(39, 0).?.char.grapheme);
    try testing.expectEqualStrings("█", win.readCell(39, 9).?.char.grapheme);
}

test "images occupy four fifths of the screen" {
    try testing.expectEqual(@as(usize, 80), imageWidthForScreen(100, 100));
    try testing.expectEqual(@as(usize, 160), imageWidthForScreen(200, 160));
    try testing.expectEqual(@as(usize, 40), imageWidthForScreen(100, 40));
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
    try expectCell(win, 0, 0, '*');
    try expectCell(win, 2, 0, 'o');
    try expectCell(win, 0, 1, '*');
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
    const check = win.readCell(1, 2) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings("✔", check.char.grapheme);
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

test "search commit jumps to the first match" {
    var doc = Document.init("first\n\nsecond\n\nthird");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.scroll = 0;
    app.search.open = true;
    try testing.expect(app.search.insert("third"));
    try app.commitSearch();
    try testing.expect(!app.search.no_match);
    try testing.expect(app.scroll > 0);
}

test "search with no match keeps scroll and flags" {
    var doc = Document.init("first\n\nsecond\n\nthird");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.scroll = 0;
    app.search.open = true;
    try testing.expect(app.search.insert("zzz"));
    try app.commitSearch();
    try testing.expect(app.search.no_match);
    try testing.expectEqual(@as(usize, 0), app.scroll);
}

test "stale search tick is ignored" {
    var doc = Document.init("first\n\nsecond\n\nthird");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.search.open = true;
    try testing.expect(app.search.insert("third"));
    const stale = app.search.generation;
    try testing.expect(app.search.insert("x"));
    try app.handleSearchTick(stale);
    try testing.expectEqual(@as(usize, 0), app.scroll);
    try testing.expect(!app.search.no_match);
    try app.handleSearchTick(app.search.generation);
    try testing.expect(app.search.no_match);
}

test "escape clears search, enter confirms and keeps highlight" {
    var doc = Document.init("first\n\nsecond");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.search.open = true;
    try testing.expect(app.search.insert("second"));
    const io: Io = undefined;
    var loop: vaxis.Loop(Event) = undefined;
    var tasks: Io.Group = .init;
    try app.handleSearchKey(io, .{ .codepoint = vaxis.Key.enter }, &loop, &tasks);
    try testing.expect(!app.search.open);
    try testing.expectEqualStrings("second", app.search.query());
    try testing.expect(app.scroll > 0);
    app.search.open = true;
    try app.handleSearchKey(io, .{ .codepoint = vaxis.Key.escape }, &loop, &tasks);
    try testing.expect(!app.search.open);
    try testing.expectEqual(@as(usize, 0), app.search.len);
}

test "n and N cycle matches with wrap" {
    var doc = Document.init("aa\n\naa\n\naa");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.search.open = true;
    try testing.expect(app.search.insert("aa"));
    try app.commitSearch();
    try testing.expectEqual(@as(usize, 3), app.search.total);
    try testing.expectEqual(@as(usize, 0), app.search.index);
    try testing.expectEqual(@as(?usize, 0), app.search.offset);
    try testing.expectEqualStrings("1/3", app.search.countText());

    try app.nextMatch(1);
    try testing.expectEqual(@as(?usize, 4), app.search.offset);
    try testing.expectEqual(@as(usize, 1), app.search.index);
    try testing.expect(app.scroll > 0);
    try app.nextMatch(1);
    try testing.expectEqual(@as(?usize, 8), app.search.offset);
    try testing.expectEqualStrings("3/3", app.search.countText());
    try app.nextMatch(1);
    try testing.expectEqual(@as(?usize, 0), app.search.offset);
    try testing.expectEqual(@as(usize, 0), app.search.index);
    try app.nextMatch(-1);
    try testing.expectEqual(@as(?usize, 8), app.search.offset);
    try testing.expectEqual(@as(usize, 2), app.search.index);
    try app.nextMatch(-1);
    try testing.expectEqual(@as(?usize, 4), app.search.offset);
    try testing.expectEqualStrings("2/3", app.search.countText());
}

test "ctrl+backspace clears the query" {
    var doc = Document.init("first\n\nsecond");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    try app.ensureVisible(math.maxInt(usize));
    app.search.open = true;
    try testing.expect(app.search.insert("second"));
    try app.commitSearch();
    try testing.expectEqual(@as(usize, 1), app.search.total);
    const io: Io = undefined;
    var loop: vaxis.Loop(Event) = undefined;
    var tasks: Io.Group = .init;
    try app.handleSearchKey(io, .{ .codepoint = vaxis.Key.backspace, .mods = .{ .ctrl = true } }, &loop, &tasks);
    try testing.expectEqual(@as(usize, 0), app.search.len);
    try testing.expectEqual(@as(usize, 0), app.search.total);
    try testing.expectEqual(@as(?usize, null), app.search.offset);
    try testing.expect(!app.search.no_match);
}

test "navigation keys work after confirming" {
    var doc = Document.init("aa\n\naa");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.search.open = true;
    try testing.expect(app.search.insert("aa"));
    try app.commitSearch();
    app.search.confirm();
    const io: Io = undefined;
    var vx: vaxis.Vaxis = undefined;
    var loop: vaxis.Loop(Event) = undefined;
    var tasks: Io.Group = .init;
    try app.handleKey(io, &vx, .{ .codepoint = 'n' }, &loop, &tasks);
    try testing.expectEqual(@as(usize, 1), app.search.index);
    try app.handleKey(io, &vx, .{ .codepoint = 'N' }, &loop, &tasks);
    try testing.expectEqual(@as(usize, 0), app.search.index);
    try testing.expectEqualStrings("aa", app.search.query());
    try app.handleKey(io, &vx, .{ .codepoint = vaxis.Key.escape }, &loop, &tasks);
    try testing.expectEqual(@as(usize, 0), app.search.len);
    try app.handleKey(io, &vx, .{ .codepoint = 'n' }, &loop, &tasks);
    try testing.expectEqual(@as(usize, 0), app.search.total);
}

test "search cursor does not draw a wide grapheme at the right edge" {
    var doc = Document.init("");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    try testing.expect(app.search.insert("aaaaaaaaaaaaaaaaaa😀"));
    app.search.moveLeft();

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 1, .cols = 21, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 21,
        .height = 1,
        .screen = &screen,
    };
    app.drawSearchBar(win);

    try expectCell(win, 18, 0, 'a');
    try expectCell(win, 19, 0, ' ');
    try expectCell(win, 20, 0, ' ');
}

test "counter overlay shows index and total" {
    var doc = Document.init("aa\n\naa\n\naa");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.search.open = true;
    try testing.expect(app.search.insert("aa"));
    try app.commitSearch();
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
    app.drawSearchCount(win);
    try expectCell(win, 16, 0, '1');
    try expectCell(win, 17, 0, '/');
    try expectCell(win, 18, 0, '3');
    try testing.expect(win.readCell(16, 0).?.style.fg.eql(Theme.gold));
}

test "viewport marks the jumped-to match" {
    var doc = Document.init("first\n\nsecond\n\nthird");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.search.open = true;
    try testing.expect(app.search.insert("second"));
    try app.commitSearch();
    Renderer.beginFrame();
    Renderer.setSearchQuery(app.search.query());
    defer Renderer.setSearchQuery("");
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
    try app.renderViewport(win);
    try expectCell(win, 0, 1, 's');
    try testing.expect(win.readCell(0, 1).?.style.bg.eql(Theme.accent));
}

test "n moves focus within one block" {
    var doc = Document.init("aa aa");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 2;
    try app.ensureVisible(math.maxInt(usize));
    app.search.open = true;
    try testing.expect(app.search.insert("aa"));
    try app.commitSearch();
    try testing.expectEqual(@as(usize, 2), app.search.total);
    try testing.expectEqual(@as(usize, 0), app.search.focus_local);
    try app.nextMatch(1);
    try testing.expectEqual(@as(?usize, 3), app.search.offset);
    try testing.expectEqual(@as(usize, 1), app.search.index);
    try testing.expectEqual(@as(usize, 0), app.search.focus_entry.?);
    try testing.expectEqual(@as(usize, 1), app.search.focus_local);
    Renderer.beginFrame();
    Renderer.setSearchQuery(app.search.query());
    defer Renderer.setSearchQuery("");
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
    try app.renderViewport(win);
    try testing.expect(win.readCell(0, 0).?.style.bg.eql(Theme.gold));
    try testing.expect(win.readCell(3, 0).?.style.bg.eql(Theme.accent));
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

const toc_text = "# Alpha\n\nfill one two three\n\n## Beta\n\nfill four five six\n\n### Gamma\n\nfill seven eight\n";

test "toc scans all headings without laying out the viewport" {
    var doc = Document.init(toc_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 30;

    try app.openToc();
    try testing.expect(app.toc_open);
    try testing.expectEqual(@as(usize, 3), app.toc_entries.items.len);
    try testing.expectEqual(@as(usize, 0), app.entries.items.len);
    try testing.expectEqual(@as(u8, 1), app.toc_entries.items[0].level);
    try testing.expectEqual(@as(u8, 2), app.toc_entries.items[1].level);
    try testing.expectEqual(@as(u8, 3), app.toc_entries.items[2].level);
}

test "toc arrows jump, enter stays, escape restores" {
    var doc = Document.init(toc_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 30;
    app.viewport = 4;
    try app.ensureVisible(math.maxInt(usize));

    try app.openToc();
    try testing.expectEqual(@as(usize, 0), app.toc_selected);
    try app.tocMove(1);
    try testing.expectEqual(@as(usize, 1), app.toc_selected);
    const at_beta = app.scroll;
    try testing.expect(at_beta > 0);
    try app.tocMove(1);
    try testing.expect(app.scroll > at_beta);

    try app.handleTocKey(.{ .codepoint = vaxis.Key.enter });
    try testing.expect(!app.toc_open);
    const at_gamma = app.scroll;
    try testing.expect(at_gamma > at_beta);

    try app.openToc();
    try testing.expectEqual(@as(usize, 2), app.toc_selected);
    try app.tocMove(-2);
    try testing.expectEqual(@as(usize, 0), app.toc_selected);
    try app.handleTocKey(.{ .codepoint = vaxis.Key.escape });
    try testing.expect(!app.toc_open);
    try testing.expectEqual(at_gamma, app.scroll);
}

test "t toggles the outline, escape restores the scroll" {
    var doc = Document.init(toc_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 30;
    app.viewport = 4;
    try app.ensureVisible(math.maxInt(usize));
    const io: Io = undefined;
    var vx: vaxis.Vaxis = undefined;
    var loop: vaxis.Loop(Event) = undefined;
    var tasks: Io.Group = .init;

    try app.handleKey(io, &vx, .{ .codepoint = 't' }, &loop, &tasks);
    try testing.expect(app.toc_open);
    try app.handleTocKey(.{ .codepoint = vaxis.Key.down });
    try testing.expect(app.scroll > 0);
    try app.handleKey(io, &vx, .{ .codepoint = 't' }, &loop, &tasks);
    try testing.expect(!app.toc_open);
    const stayed = app.scroll;
    try testing.expect(stayed > 0);

    try app.handleKey(io, &vx, .{ .codepoint = 't' }, &loop, &tasks);
    try app.handleTocKey(.{ .codepoint = vaxis.Key.down });
    try app.handleTocKey(.{ .codepoint = vaxis.Key.escape });
    try testing.expect(!app.toc_open);
    try testing.expectEqual(stayed, app.scroll);
}

test "toc jump from a partial parse lands on the section" {
    var doc = Document.init(toc_text);
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 30;
    app.viewport = 4;
    try app.ensureVisible(5);
    try testing.expect(!app.fully_parsed);
    try app.openToc();

    try app.tocGoTo(1);
    try testing.expectEqual(@as(usize, 4), app.scroll);

    try app.tocGoTo(2);
    try testing.expect(app.fully_parsed);
    try testing.expectEqual(app.maxScroll(), app.scroll);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 4, .cols = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 30,
        .height = 4,
        .screen = &screen,
    };
    try app.renderViewport(win);
    try expectCell(win, 2, 1, 'G');
}

test "toc modal lists headings with hierarchy" {
    var doc = Document.init("# A\n\n## B\n\n## C\n\n# D\n");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 40;
    try app.openToc();

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 20, .cols = 50, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 50,
        .height = 20,
        .screen = &screen,
    };
    app.drawToc(win);
    try expectCell(win, 2, 6, 'C');
    try testing.expectEqualStrings("├", win.readCell(1, 7).?.char.grapheme);
    try testing.expectEqualStrings("─", win.readCell(2, 7).?.char.grapheme);
    try expectCell(win, 5, 7, 'A');
    try testing.expect(win.readCell(5, 7).?.style.bg.eql(Theme.accent));
    try testing.expectEqualStrings("│", win.readCell(1, 8).?.char.grapheme);
    try testing.expectEqualStrings("├", win.readCell(4, 8).?.char.grapheme);
    try expectCell(win, 8, 8, 'B');
    try testing.expectEqualStrings("│", win.readCell(1, 9).?.char.grapheme);
    try testing.expectEqualStrings("└", win.readCell(4, 9).?.char.grapheme);
    try expectCell(win, 8, 9, 'C');
    try testing.expectEqualStrings("└", win.readCell(1, 10).?.char.grapheme);
    try expectCell(win, 5, 10, 'D');
    try expectCell(win, 2, 12, 'U');
}

test "toc with no headings opens and closes cleanly" {
    var doc = Document.init("just text\n");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 20;
    app.viewport = 4;
    try app.openToc();
    try testing.expect(app.toc_open);
    try testing.expectEqual(@as(usize, 0), app.toc_entries.items.len);
    try app.tocMove(1);
    try testing.expectEqual(@as(usize, 0), app.scroll);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 30,
        .height = 10,
        .screen = &screen,
    };
    app.drawToc(win);
    try expectCell(win, 3, 3, 'n');
    try app.handleTocKey(.{ .codepoint = vaxis.Key.escape });
    try testing.expect(!app.toc_open);
}

test "toc modal suppresses image placements" {
    var doc = Document.init("");
    var app = App.init(testing.allocator, &doc);
    defer app.deinit();
    app.width = 40;
    app.image_width = 24;
    app.cell_width = 10;
    app.cell_height = 20;
    app.placement_mode = .stable;

    var entry: Entry = .{
        .elem = .{ .image = .{ .alt = "diagram", .source = "diagram.png", .title = null } },
        .media = .{ .ready = vaxis.Image.init(1, 800, 400) },
    };
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
    const drawn = try app.renderEntry(win, &entry, 0, 0);
    try testing.expectEqual(@as(usize, 1), app.next_stable_placement_count);
    try testing.expect(drawn > 0);

    app.next_stable_placement_count = 0;
    app.toc_open = true;
    const hidden = try app.renderEntry(win, &entry, 0, 0);
    try testing.expectEqual(drawn, hidden);
    try testing.expectEqual(@as(usize, 0), app.next_stable_placement_count);

    app.placement_mode = .unicode;
    _ = try app.renderEntry(win, &entry, 0, 0);
    try testing.expectEqual(@as(usize, 0), app.virtual_placement_count);

    app.toc_open = false;
    _ = try app.renderEntry(win, &entry, 0, 0);
    try testing.expectEqual(@as(usize, 1), app.virtual_placement_count);
}
