//! Unicode sequence diagram renderer: participant columns joined by
//! horizontal messages down the page. Rows derive functionally from
//! message order, so measuring and rendering can never disagree;
//! anything that does not fit returns null and the caller shows the card.

const Mermaid = @import("../../Mermaid.zig");
const cells = @import("cells.zig");
const vaxis = @import("vaxis");

pub const max_rows = 200;

pub fn layout(win: ?vaxis.Window, seq: *const Mermaid.Sequence, start_row: usize, skip: usize, width: usize) ?usize {
    var lay = Layout.compute(seq, width) orelse return null;
    if (win == null) return start_row + lay.rows;
    const w = win.?;
    lay.draw(w, start_row, skip);
    return start_row + @min(lay.rows -| skip, w.height -| start_row);
}

const Layout = struct {
    seq: *const Mermaid.Sequence,
    count: usize,
    x: [Mermaid.max_participants]usize,
    w: [Mermaid.max_participants]usize,
    spans: [Mermaid.max_activations]ActiveSpan = undefined,
    span_count: usize = 0,
    rows: usize,
    cols: usize,

    fn compute(seq: *const Mermaid.Sequence, width: usize) ?Layout {
        if (seq.degraded or seq.participant_count == 0) return null;
        var lay: Layout = .{
            .seq = seq,
            .count = seq.participant_count,
            .x = [_]usize{0} ** Mermaid.max_participants,
            .w = [_]usize{0} ** Mermaid.max_participants,
            .span_count = 0,
            .rows = 0,
            .cols = 0,
        };
        for (seq.participants[0..lay.count], 0..) |*p, i| lay.w[i] = cells.labelWidth(p.label) + 4;
        var cols: usize = 0;
        for (0..lay.count) |i| {
            lay.x[i] = cols;
            cols += lay.w[i] + 3;
        }
        var extra = [_]usize{0} ** Mermaid.max_participants;
        for (seq.messages[0..seq.message_count], 0..) |*m, i| {
            if ((!seq.autonumber and m.text.len == 0) or mem.eql(u8, m.src, m.dst)) continue;
            const s = partIndex(seq, m.src) orelse continue;
            const d = partIndex(seq, m.dst) orelse continue;
            var lw = cells.labelWidth(m.text);
            if (seq.autonumber) lw += numWidth(i + 1);
            const scx = lay.x[s] + lay.w[s] / 2;
            const dcx = lay.x[d] + lay.w[d] / 2;
            const span = if (scx > dcx) scx - dcx else dcx - scx;
            const g = @min(s, d);
            extra[g] = @max(extra[g], (lw + 1) -| span);
        }
        cols = 0;
        for (0..lay.count) |i| {
            lay.x[i] = cols;
            cols += lay.w[i] + 3 + extra[i];
        }
        cols -|= 3;
        for (seq.messages[0..seq.message_count]) |*m| {
            if (!mem.eql(u8, m.src, m.dst)) continue;
            const s = partIndex(seq, m.src) orelse continue;
            if (s + 1 == lay.count) cols = @max(cols, lay.x[s] + lay.w[s] / 2 + 5);
        }
        for (seq.notes[0..seq.note_count]) |*n| {
            const nb = lay.noteBox(n) orelse continue;
            cols = @max(cols, nb.c2 + 1);
        }
        for (seq.messages[0..seq.message_count], 0..) |*m, i| {
            if (!seq.autonumber and m.text.len == 0) continue;
            const s = partIndex(seq, m.src) orelse continue;
            const d = partIndex(seq, m.dst) orelse continue;
            var end = lay.labelStart(s, d) + cells.labelWidth(m.text);
            if (seq.autonumber) end += numWidth(i + 1);
            cols = @max(cols, end + 1);
        }
        if (cols > width) return null;
        lay.cols = cols;
        lay.rows = 3 + lay.rowsBefore(seq.message_count + seq.note_count);
        if (lay.rows > max_rows) return null;
        var max_depth: usize = 0;
        for (seq.fragments[0..seq.fragment_count]) |*f| {
            if (f.op == .@"opaque") continue;
            max_depth = @max(max_depth, f.depth);
        }
        if (max_depth * 2 + 4 > lay.cols) return null;
        for (seq.activations[0..seq.activation_count]) |*a| {
            const p = partIndex(seq, a.actor) orelse continue;
            lay.spans[lay.span_count] = .{ .p = p, .r1 = lay.rowOf(a.start), .r2 = lay.rowOf(a.end) };
            lay.span_count += 1;
        }
        return lay;
    }

    fn rowsBefore(self: *const Layout, pos: usize) usize {
        var r: usize = 0;
        var mi: usize = 0;
        var ni: usize = 0;
        const msgs = self.seq.messages[0..self.seq.message_count];
        const notes = self.seq.notes[0..self.seq.note_count];
        while (true) {
            const mp = if (mi < msgs.len) msgs[mi].pos else std.math.maxInt(usize);
            const np = if (ni < notes.len) notes[ni].pos else std.math.maxInt(usize);
            if (mp >= pos and np >= pos) break;
            if (mp < np) {
                r += self.msgHeight(&msgs[mi]);
                mi += 1;
            } else {
                r += 3;
                ni += 1;
            }
        }
        for (self.seq.fragments[0..self.seq.fragment_count]) |*f| {
            if (f.op == .@"opaque") continue;
            if (f.start <= pos) r += 1;
            if (f.end > f.start and f.end <= pos) r += 1;
        }
        for (self.seq.fragments[0..self.seq.fragment_count]) |*f| {
            for (f.divs[0..f.div_count]) |*dv| {
                if (dv.pos > f.start and dv.pos <= pos) r += 1;
            }
        }
        return r;
    }

    fn rowOf(self: *const Layout, pos: usize) usize {
        return 3 + self.rowsBefore(pos);
    }

    fn msgHeight(self: *const Layout, m: *const Mermaid.Message) usize {
        var r: usize = if (self.seq.autonumber or m.text.len > 0) 1 else 0;
        r += if (mem.eql(u8, m.src, m.dst)) 2 else 1;
        return r;
    }

    fn activeAt(self: *const Layout, p: usize, r: usize) bool {
        for (self.spans[0..self.span_count]) |*span| {
            if (span.p == p and span.r1 <= r and r < span.r2) return true;
        }
        return false;
    }

    fn labelStart(self: *const Layout, s: usize, d: usize) usize {
        return @min(self.x[s] + self.w[s] / 2, self.x[d] + self.w[d] / 2) + 1;
    }

    const NoteBox = struct { c1: usize, c2: usize };

    fn noteBox(self: *const Layout, n: *const Mermaid.Note) ?NoteBox {
        const a = partIndex(self.seq, n.a) orelse return null;
        const cax = self.x[a] + self.w[a] / 2;
        const textW = cells.labelWidth(n.text);
        switch (n.kind) {
            .over => {
                if (n.b) |bid| {
                    const b = partIndex(self.seq, bid) orelse return null;
                    const cbx = self.x[b] + self.w[b] / 2;
                    const c1 = @min(cax, cbx);
                    return .{ .c1 = c1, .c2 = @max(cbx, c1 + textW + 3) };
                }
                const bw = textW + 4;
                const c1 = cax -| bw / 2;
                return .{ .c1 = c1, .c2 = c1 + bw - 1 };
            },
            .left => {
                const c2 = cax -| 1;
                return .{ .c1 = c2 -| (textW + 3), .c2 = c2 };
            },
            .right => {
                const c1 = cax + 1;
                return .{ .c1 = c1, .c2 = c1 + textW + 3 };
            },
        }
    }

    fn fragTop(self: *const Layout, fi: usize) usize {
        const f = &self.seq.fragments[fi];
        var k: usize = 0;
        var rank: usize = 0;
        for (self.seq.fragments[0..self.seq.fragment_count], 0..) |*g, j| {
            if (g.op == .@"opaque" or g.start != f.start) continue;
            k += 1;
            if (g.depth < f.depth or (g.depth == f.depth and j < fi)) rank += 1;
        }
        return self.rowOf(f.start) -| k + rank;
    }

    fn fragBottom(self: *const Layout, fi: usize) usize {
        const f = &self.seq.fragments[fi];
        var k: usize = 0;
        var rank: usize = 0;
        for (self.seq.fragments[0..self.seq.fragment_count], 0..) |*g, j| {
            if (g.op == .@"opaque" or g.end != f.end or g.end <= g.start) continue;
            k += 1;
            if (g.depth > f.depth or (g.depth == f.depth and j < fi)) rank += 1;
        }
        return self.rowOf(f.end) -| k + rank;
    }

    fn fragDiv(self: *const Layout, fi: usize, di: usize) usize {
        const f = &self.seq.fragments[fi];
        const e = f.divs[di].pos;
        var k: usize = 0;
        var rank: usize = 0;
        for (self.seq.fragments[0..self.seq.fragment_count], 0..) |*g, j| {
            for (g.divs[0..g.div_count], 0..) |*dv, k2| {
                if (dv.pos != e or dv.pos <= g.start) continue;
                k += 1;
                if (g.depth < f.depth or (g.depth == f.depth and (j < fi or (j == fi and k2 < di)))) rank += 1;
            }
        }
        return self.rowOf(e) -| k + rank;
    }

    fn draw(self: *const Layout, win: vaxis.Window, start_row: usize, skip: usize) void {
        for (0..self.count) |i| {
            cells.box(win, self.x[i], 0, self.w[i], self.seq.participants[i].label, cells.square, start_row, skip, .{});
        }
        var r: usize = 3;
        while (r < self.rows) : (r += 1) {
            for (0..self.count) |i| {
                const cx = self.x[i] + self.w[i] / 2;
                cells.putLine(win, r, cx, start_row, skip, if (self.activeAt(i, r)) "┃" else "│", .{});
            }
        }
        for (self.seq.messages[0..self.seq.message_count]) |*m| {
            self.drawMessage(win, m, start_row, skip);
        }
        for (0..self.seq.fragment_count) |i| {
            self.drawFragment(win, i, start_row, skip);
        }
        for (self.seq.notes[0..self.seq.note_count]) |*n| {
            const nb = self.noteBox(n) orelse continue;
            const row = self.rowOf(n.pos);
            cells.box(win, nb.c1, row, nb.c2 - nb.c1 + 1, n.text, cells.square, start_row, skip, .{ .bg = .{ .index = 236 } });
        }
        for (self.seq.messages[0..self.seq.message_count], 0..) |*m, i| {
            self.drawLabel(win, m, i, start_row, skip);
        }
    }

    fn drawMessage(self: *const Layout, win: vaxis.Window, m: *const Mermaid.Message, start_row: usize, skip: usize) void {
        const s = partIndex(self.seq, m.src) orelse return;
        const d = partIndex(self.seq, m.dst) orelse return;
        const scx = self.x[s] + self.w[s] / 2;
        const dcx = self.x[d] + self.w[d] / 2;
        const base = self.rowOf(m.pos);
        const wire = base + @intFromBool(self.seq.autonumber or m.text.len > 0);
        if (mem.eql(u8, m.src, m.dst)) {
            wireCell(m.style, win, wire, scx + 1, start_row, skip);
            wireCell(m.style, win, wire, scx + 2, start_row, skip);
            wireCell(m.style, win, wire, scx + 3, start_row, skip);
            cells.putLine(win, wire, scx + 4, start_row, skip, "┐", .{});
            wireCell(m.style, win, wire + 1, scx + 1, start_row, skip);
            wireCell(m.style, win, wire + 1, scx + 2, start_row, skip);
            wireCell(m.style, win, wire + 1, scx + 3, start_row, skip);
            cells.putLine(win, wire + 1, scx + 4, start_row, skip, "┘", .{});
            switch (m.kind) {
                .arrow => cells.putRaw(win, wire + 1, scx + 1, start_row, skip, "◄", .{}),
                .cross => cells.putRaw(win, wire + 1, scx + 1, start_row, skip, "×", .{}),
                .open => cells.putRaw(win, wire + 1, scx + 1, start_row, skip, "<", .{}),
                .plain => {},
            }
            return;
        }
        const lo = @min(scx, dcx);
        const hi = @max(scx, dcx);
        var c = lo;
        while (c <= hi) : (c += 1) wireCell(m.style, win, wire, c, start_row, skip);
        switch (m.kind) {
            .arrow => cells.putRaw(win, wire, dcx, start_row, skip, if (dcx > scx) "►" else "◄", .{}),
            .cross => cells.putRaw(win, wire, dcx, start_row, skip, "×", .{}),
            .open => cells.putRaw(win, wire, dcx, start_row, skip, if (dcx > scx) ">" else "<", .{}),
            .plain => {},
        }
    }

    fn drawLabel(self: *const Layout, win: vaxis.Window, m: *const Mermaid.Message, index: usize, start_row: usize, skip: usize) void {
        if (!self.seq.autonumber and m.text.len == 0) return;
        const s = partIndex(self.seq, m.src) orelse return;
        const d = partIndex(self.seq, m.dst) orelse return;
        const c = self.labelStart(s, d);
        const row = self.rowOf(m.pos);
        if (self.seq.autonumber) {
            const numW = putNumber(win, row, c, start_row, skip, index + 1, self.cols -| 1);
            cells.putText(win, row, c + numW, start_row, skip, m.text, self.cols -| 1, .{});
        } else {
            cells.putText(win, row, c, start_row, skip, m.text, self.cols -| 1, .{});
        }
    }

    fn drawFragment(self: *const Layout, win: vaxis.Window, fi: usize, start_row: usize, skip: usize) void {
        const f = &self.seq.fragments[fi];
        const inset: usize = @min(f.depth, (self.cols -| 1) / 2);
        const c1 = inset;
        const c2 = self.cols -| 1 -| inset;
        if (c2 <= c1 + 1) return;
        const dim: vaxis.Style = .{ .dim = true };
        for (f.divs[0..f.div_count], 0..) |*dv, di| {
            if (dv.pos <= f.start) continue;
            const erow = self.fragDiv(fi, di);
            cells.putLine(win, erow, c1, start_row, skip, "├", dim);
            var c3 = c1 + 1;
            while (c3 < c2) : (c3 += 1) cells.putLine(win, erow, c3, start_row, skip, "─", dim);
            cells.putLine(win, erow, c2, start_row, skip, "┤", dim);
            cells.putText(win, erow, c1 + 2, start_row, skip, "[", c2, dim);
            cells.putText(win, erow, c1 + 3, start_row, skip, dv.head, c2, dim);
            cells.putText(win, erow, c1 + 3 + dv.head.len, start_row, skip, "]", c2, dim);
            if (dv.text.len > 0) cells.putText(win, erow, c1 + 4 + dv.head.len, start_row, skip, dv.text, c2, dim);
        }
        if (f.op == .@"opaque") return;
        const top = self.fragTop(fi);
        const op = @tagName(f.op);
        cells.putLine(win, top, c1, start_row, skip, "┌", dim);
        var c = c1 + 1;
        while (c < c2) : (c += 1) cells.putLine(win, top, c, start_row, skip, "─", dim);
        cells.putLine(win, top, c2, start_row, skip, "┐", dim);
        cells.putText(win, top, c1 + 2, start_row, skip, "[", c2, dim);
        cells.putText(win, top, c1 + 3, start_row, skip, op, c2, dim);
        cells.putText(win, top, c1 + 3 + op.len, start_row, skip, "]", c2, dim);
        if (f.label.len > 0) cells.putText(win, top, c1 + 4 + op.len, start_row, skip, f.label, c2, dim);
        const bottom = if (f.end > f.start) self.fragBottom(fi) else top;
        var r = top + 1;
        while (r < bottom) : (r += 1) {
            cells.putLine(win, r, c1, start_row, skip, "│", dim);
            cells.putLine(win, r, c2, start_row, skip, "│", dim);
        }
        if (f.end > f.start) {
            cells.putLine(win, bottom, c1, start_row, skip, "└", dim);
            var c4 = c1 + 1;
            while (c4 < c2) : (c4 += 1) cells.putLine(win, bottom, c4, start_row, skip, "─", dim);
            cells.putLine(win, bottom, c2, start_row, skip, "┘", dim);
        }
    }
};

const ActiveSpan = struct {
    p: usize,
    r1: usize,
    r2: usize,
};

fn putNumber(win: vaxis.Window, r: usize, c0: usize, start_row: usize, skip: usize, n: usize, max_c: usize) usize {
    const digits = "0123456789";
    var div: usize = 1;
    while (n / (div * 10) > 0) div *= 10;
    var c = c0;
    var d = div;
    while (d > 0) : (d /= 10) {
        if (c + 1 > max_c or c + 1 > win.width) break;
        cells.putRaw(win, r, c, start_row, skip, digits[(n / d) % 10 ..][0..1], .{});
        c += 1;
    }
    const suffix = ". ";
    for (0..suffix.len) |k| {
        if (c + 1 > max_c or c + 1 > win.width) break;
        cells.putRaw(win, r, c, start_row, skip, suffix[k .. k + 1], .{});
        c += 1;
    }
    return c - c0;
}

fn partIndex(seq: *const Mermaid.Sequence, id: []const u8) ?usize {
    for (seq.participants[0..seq.participant_count], 0..) |*p, i| {
        if (mem.eql(u8, p.id, id)) return i;
    }
    return null;
}

fn numWidth(n: usize) usize {
    var w: usize = 1;
    var v = n;
    while (v >= 10) {
        v /= 10;
        w += 1;
    }
    return w + 2;
}

fn wireCell(style: Mermaid.MsgStyle, win: vaxis.Window, r: usize, c: usize, start_row: usize, skip: usize) void {
    if (style == .solid) {
        cells.putLine(win, r, c, start_row, skip, "─", .{});
    } else {
        cells.putDotted(win, r, c, start_row, skip, .{});
    }
}

const std = @import("std");
const mem = std.mem;

test "participants render boxes and lifelines" {
    var seq = Mermaid.parseSequenceBlockText("sequenceDiagram\nA->>B: hi\n").?;
    try testing.expectEqual(@as(usize, 5), layout(null, &seq, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 5, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 0, 0, "┌");
    try expectGlyph(win, 2, 1, "A");
    try expectGlyph(win, 2, 3, "│");
    try expectGlyph(win, 3, 3, "h");
    try expectGlyph(win, 10, 4, "►");
    try expectGlyph(win, 2, 4, "┼");
}

test "all eight arrows" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A->B: m0\n" ++
            "A->>B: m1\n" ++
            "A-->B: m2\n" ++
            "A-->>B: m3\n" ++
            "A-xB: m4\n" ++
            "A--xB: m5\n" ++
            "A-)B: o1\n" ++
            "A--)B: o2\n" ++
            "B->>A: bk\n" ++
            "B-)A: ob\n",
    ).?;
    try testing.expectEqual(@as(usize, 23), layout(null, &seq, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 23, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 2, 4, "┼");
    try expectGlyph(win, 10, 4, "┼");
    try expectGlyph(win, 10, 6, "►");
    try expectGlyph(win, 2, 8, "│");
    try expectGlyph(win, 3, 8, "┄");
    try expectGlyph(win, 10, 8, "│");
    try expectGlyph(win, 10, 10, "►");
    try expectGlyph(win, 5, 10, "┄");
    try expectGlyph(win, 10, 12, "×");
    try expectGlyph(win, 10, 14, "×");
    try expectGlyph(win, 10, 16, ">");
    try expectGlyph(win, 10, 18, ">");
    try expectGlyph(win, 2, 20, "◄");
    try expectGlyph(win, 3, 19, "b");
    try expectGlyph(win, 2, 22, "<");
}

test "self messages bump east" {
    var seq = Mermaid.parseSequenceBlockText("sequenceDiagram\nA->>A: ping\n").?;
    try testing.expectEqual(@as(usize, 6), layout(null, &seq, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 6, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 6, 4, "┐");
    try expectGlyph(win, 6, 5, "┘");
    try expectGlyph(win, 3, 5, "◄");
    try expectGlyph(win, 3, 3, "p");
}

test "notes span lifelines" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "Note over A,B: span\n" ++
            "Note left of B: to the left\n" ++
            "Note right of A: to the right\n",
    ).?;
    try testing.expectEqual(@as(usize, 12), layout(null, &seq, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 12, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 2, 3, "┌");
    try expectGlyph(win, 4, 4, "s");
    try expectGlyph(win, 10, 3, "┐");
    try expectGlyph(win, 0, 6, "┌");
    try expectGlyph(win, 2, 7, "t");
    try expectGlyph(win, 3, 9, "┌");
    try testing.expect(win.readCell(4, 4).?.style.bg.eql(vaxis.Color{ .index = 236 }));
    try testing.expect(win.readCell(8, 4).?.style.bg.eql(vaxis.Color{ .index = 236 }));
    try testing.expect(!win.readCell(0, 0).?.style.bg.eql(vaxis.Color{ .index = 236 }));
}

test "loop fragments box messages" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "loop Every minute\n" ++
            "A->>B: ping\n",
    ).?;
    try testing.expectEqual(@as(usize, 7), layout(null, &seq, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 7, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 0, 3, "┌");
    try expectGlyph(win, 2, 3, "[");
    try expectGlyph(win, 3, 3, "l");
    try expectGlyph(win, 7, 3, "]");
    try expectGlyph(win, 8, 3, "E");
    try expectGlyph(win, 0, 4, "│");
    try expectGlyph(win, 0, 6, "└");
    try expectGlyph(win, 12, 6, "┘");
    try testing.expect(win.readCell(2, 3).?.style.dim);
    try testing.expect(win.readCell(0, 3).?.style.dim);
    try testing.expect(!win.readCell(0, 0).?.style.dim);
}

test "nested fragments inset" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "loop outer\n" ++
            "loop inner\n" ++
            "A->>B: ping\n" ++
            "end\n" ++
            "end\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 12, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 0, 3, "┌");
    try expectGlyph(win, 1, 4, "┌");
    try expectGlyph(win, 11, 7, "┘");
    try expectGlyph(win, 12, 8, "┘");
    try testing.expect(win.readCell(1, 4).?.style.dim);
}

test "alt else dividers" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "alt ok\n" ++
            "A->>B: yes\n" ++
            "else bad\n" ++
            "A->>B: no\n" ++
            "end\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 0, 3, "┌");
    try expectGlyph(win, 0, 6, "├");
    try expectGlyph(win, 2, 6, "[");
    try expectGlyph(win, 3, 6, "e");
    try expectGlyph(win, 0, 9, "└");
    try testing.expect(win.readCell(2, 6).?.style.dim);
    try testing.expect(win.readCell(0, 6).?.style.dim);
}

test "opaque fragments draw nothing" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "rect one\n" ++
            "A->>B: inside\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 5), layout(null, &seq, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 5, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 0, 3, " ");
    try expectGlyph(win, 10, 4, "►");
    try expectGlyph(win, 2, 4, "┼");
}

test "activations widen lifelines" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "activate A\n" ++
            "A->>B: hi\n" ++
            "deactivate A\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 5, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 2, 3, "┃");
    try expectGlyph(win, 2, 4, "─");
    try expectGlyph(win, 10, 3, "│");
}

test "autonumber prefixes" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "autonumber\n" ++
            "A->>B: first\n" ++
            "A->>B: second\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 7, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 3, 3, "1");
    try expectGlyph(win, 3, 5, "2");
    try expectGlyph(win, 6, 3, "f");
}

test "long labels extend the diagram" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "Alice->>John: Hello John, how are you?\n" ++
            "John-->>Alice: Great!\n",
    ).?;
    try testing.expectEqual(@as(usize, 7), layout(null, &seq, 0, 0, 80).?);
    try testing.expect(layout(null, &seq, 0, 0, 20) == null);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 7, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 80).?;
    try expectGlyph(win, 5, 3, "H");
    try expectGlyph(win, 28, 3, "?");
    try expectGlyph(win, 5, 5, "G");
    try expectGlyph(win, 25, 0, "┌");
    try expectGlyph(win, 29, 4, "►");
    try expectGlyph(win, 20, 4, "─");
    try expectGlyph(win, 4, 6, "◄");
}

test "par and dividers" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "par one\n" ++
            "A->>B: x\n" ++
            "and two\n" ++
            "A->>B: y\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 10), layout(null, &seq, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 0, 3, "┌");
    try expectGlyph(win, 2, 3, "[");
    try expectGlyph(win, 3, 3, "p");
    try expectGlyph(win, 0, 6, "├");
    try expectGlyph(win, 2, 6, "[");
    try expectGlyph(win, 3, 6, "a");
    try expectGlyph(win, 0, 9, "└");
    try expectGlyph(win, 10, 5, "►");
    try expectGlyph(win, 10, 8, "►");
    try testing.expect(win.readCell(2, 3).?.style.dim);
}

test "unrenderable sequences fall back" {
    var empty = Mermaid.parseSequenceBlockText("sequenceDiagram\n").?;
    try testing.expect(layout(null, &empty, 0, 0, 40) == null);

    var degraded = Mermaid.parseSequenceBlockText("sequenceDiagram\n" ++ ("A->>B: x\n" ** 200)).?;
    try testing.expect(layout(null, &degraded, 0, 0, 40) == null);

    var tiny = Mermaid.parseSequenceBlockText("sequenceDiagram\nA->>B: x\n").?;
    try testing.expect(layout(null, &tiny, 0, 0, 4) == null);
}

test "skips shift content up" {
    var seq = Mermaid.parseSequenceBlockText("sequenceDiagram\nA->>B: hi\n").?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 5, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    try testing.expectEqual(@as(usize, 3), layout(win, &seq, 0, 2, 40).?);
    try expectGlyph(win, 0, 0, "└");
    try expectGlyph(win, 2, 1, "│");
    try expectGlyph(win, 3, 1, "h");
}

fn window(screen: *vaxis.Screen) vaxis.Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = screen,
    };
}

fn expectGlyph(win: vaxis.Window, col: u16, row: u16, expected: []const u8) !void {
    const cell = win.readCell(col, row) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings(expected, cell.char.grapheme);
}

const testing = std.testing;
