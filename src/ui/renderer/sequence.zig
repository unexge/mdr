//! Unicode sequence diagram renderer: participant columns joined by
//! horizontal messages down the page. Rows derive functionally from
//! message order, so measuring and rendering can never disagree;
//! anything that does not fit returns null and the caller shows the card.

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
        for (seq.activations[0..seq.activation_count]) |*activation| {
            const participant = partIndex(seq, activation.actor) orelse continue;
            lay.spans[lay.span_count] = .{
                .p = participant,
                .r1 = lay.rowOf(activation.start),
                .r2 = lay.rowOf(activation.end),
                .depth = activation.depth,
            };
            lay.span_count += 1;
        }
        var cols: usize = 0;
        for (0..lay.count) |i| {
            lay.x[i] = cols;
            cols += lay.w[i] + 3;
        }
        var extra = [_]usize{0} ** Mermaid.max_participants;
        for (lay.spans[0..lay.span_count]) |span| extra[span.p] = @max(extra[span.p], span.depth);
        for (seq.messages[0..seq.message_count]) |*m| {
            if ((m.number == null and m.text.len == 0) or mem.eql(u8, m.src, m.dst)) continue;
            const s = partIndex(seq, m.src) orelse continue;
            const d = partIndex(seq, m.dst) orelse continue;
            var lw = cells.labelWidth(m.text);
            if (m.number) |number| lw += numberWidth(number);
            const row = lay.rowOf(m.pos);
            const scx = lay.lifelineCol(s, row);
            const dcx = lay.lifelineCol(d, row);
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
        if (seq.participant_box_count > 0) {
            for (lay.x[0..lay.count]) |*x| x.* += 1;
            cols += 2;
            for (seq.participant_boxes[0..seq.participant_box_count]) |box| {
                if (box.count == 0 or box.first + box.count > lay.count) return null;
                const last = box.first + box.count - 1;
                const box_width = lay.x[last] + lay.w[last] - (lay.x[box.first] - 1) + 1;
                if (cells.labelWidth(box.label) + 4 > box_width) return null;
            }
        }
        for (seq.messages[0..seq.message_count]) |*m| {
            if (!mem.eql(u8, m.src, m.dst)) continue;
            const s = partIndex(seq, m.src) orelse continue;
            if (s + 1 == lay.count) cols = @max(cols, lay.x[s] + lay.w[s] / 2 + 5);
        }
        for (seq.notes[0..seq.note_count]) |*n| {
            const nb = lay.noteBox(n) orelse continue;
            cols = @max(cols, nb.c2 + 1);
        }
        for (seq.messages[0..seq.message_count]) |*m| {
            if (m.number == null and m.text.len == 0) continue;
            const s = partIndex(seq, m.src) orelse continue;
            const d = partIndex(seq, m.dst) orelse continue;
            const row = lay.rowOf(m.pos);
            var end = lay.labelStart(s, d, row) + cells.labelWidth(m.text);
            if (m.number) |number| end += numberWidth(number);
            cols = @max(cols, end + 1);
        }
        if (seq.title) |title| cols = @max(cols, cells.labelWidth(title));
        if (cols > width) return null;
        lay.cols = cols;
        lay.rows = lay.headerRows() + lay.rowsBefore(seq.message_count + seq.note_count);
        if (lay.rows > max_rows) return null;
        var max_depth: usize = 0;
        for (seq.fragments[0..seq.fragment_count]) |*f| {
            max_depth = @max(max_depth, f.depth);
        }
        if (max_depth * 2 + 4 > lay.cols) return null;
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
                r += msgHeight(&msgs[mi]);
                mi += 1;
            } else {
                r += 3;
                ni += 1;
            }
        }
        for (self.seq.participants[0..self.seq.participant_count]) |participant| {
            if (participant.created_at) |created_at| {
                if (created_at <= pos) r += 3;
            }
        }
        for (self.seq.fragments[0..self.seq.fragment_count]) |*f| {
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
        return self.headerRows() + self.rowsBefore(pos);
    }

    fn rowAfter(self: *const Layout, pos: usize) usize {
        return self.headerRows() + self.rowsBefore(pos + 1);
    }

    fn titleRows(self: *const Layout) usize {
        return if (self.seq.title != null) 2 else 0;
    }

    fn headerRows(self: *const Layout) usize {
        const participant_rows: usize = if (self.seq.participant_box_count > 0) 6 else 3;
        return self.titleRows() + participant_rows;
    }

    fn participantTop(self: *const Layout) usize {
        const box_rows: usize = if (self.seq.participant_box_count > 0) 2 else 0;
        return self.titleRows() + box_rows;
    }

    fn msgHeight(m: *const Mermaid.Message) usize {
        var r: usize = if (m.number != null or m.text.len > 0) 1 else 0;
        r += if (mem.eql(u8, m.src, m.dst)) 2 else 1;
        return r;
    }

    fn activeDepth(self: *const Layout, participant: usize, row: usize) usize {
        var depth: usize = 0;
        for (self.spans[0..self.span_count]) |*span| {
            if (span.p == participant and span.r1 <= row and row < span.r2) depth = @max(depth, span.depth + 1);
        }
        return depth;
    }

    fn lifelineCol(self: *const Layout, participant: usize, row: usize) usize {
        return self.x[participant] + self.w[participant] / 2 + (self.activeDepth(participant, row) -| 1);
    }

    fn labelStart(self: *const Layout, s: usize, d: usize, row: usize) usize {
        return @min(self.lifelineCol(s, row), self.lifelineCol(d, row)) + 1;
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

    fn creationRowsAt(self: *const Layout, pos: usize) usize {
        var rows: usize = 0;
        for (self.seq.participants[0..self.seq.participant_count]) |participant| {
            if (participant.created_at == pos) rows += 3;
        }
        return rows;
    }

    fn fragTop(self: *const Layout, fi: usize) usize {
        const f = &self.seq.fragments[fi];
        var k: usize = 0;
        var rank: usize = 0;
        for (self.seq.fragments[0..self.seq.fragment_count], 0..) |*g, j| {
            if (g.start != f.start) continue;
            k += 1;
            if (g.depth < f.depth or (g.depth == f.depth and j < fi)) rank += 1;
        }
        return self.rowOf(f.start) -| k -| self.creationRowsAt(f.start) + rank;
    }

    fn fragBottom(self: *const Layout, fi: usize) usize {
        const f = &self.seq.fragments[fi];
        var k: usize = 0;
        var rank: usize = 0;
        for (self.seq.fragments[0..self.seq.fragment_count], 0..) |*g, j| {
            if (g.end != f.end or g.end <= g.start) continue;
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
        if (self.seq.title) |title| cells.putText(win, 0, 0, start_row, skip, title, self.cols, .{ .bold = true });
        self.drawParticipantBoxes(win, start_row, skip);
        for (self.seq.participants[0..self.count], 0..) |*participant, index| {
            if (participant.created_at == null) {
                self.drawParticipant(win, index, self.participantTop(), start_row, skip);
            } else if (participant.created_at) |created_at| {
                self.drawParticipant(win, index, self.rowOf(created_at) - 3, start_row, skip);
            }
        }
        for (self.seq.participants[0..self.count], 0..) |participant, index| {
            const cx = self.x[index] + self.w[index] / 2;
            var row = if (participant.created_at) |created_at| self.rowOf(created_at) else self.headerRows();
            const end = if (participant.destroyed_at) |destroyed_at| self.rowAfter(destroyed_at) else self.rows;
            while (row < end) : (row += 1) {
                const depth = self.activeDepth(index, row);
                if (depth == 0) {
                    cells.putLine(win, row, cx, start_row, skip, "│", .{});
                } else {
                    for (0..depth) |offset| cells.putRaw(win, row, cx + offset, start_row, skip, "┃", .{});
                }
            }
        }
        for (self.seq.messages[0..self.seq.message_count]) |*m| {
            self.drawMessage(win, m, start_row, skip);
        }
        for (self.seq.participants[0..self.count], 0..) |participant, index| {
            if (participant.destroyed_at) |destroyed_at| {
                cells.putRaw(win, self.rowAfter(destroyed_at) - 1, self.x[index] + self.w[index] / 2, start_row, skip, "×", .{});
            }
        }
        for (0..self.seq.fragment_count) |i| {
            self.drawFragment(win, i, start_row, skip);
        }
        for (self.seq.notes[0..self.seq.note_count]) |*n| {
            const nb = self.noteBox(n) orelse continue;
            const row = self.rowOf(n.pos);
            cells.box(win, nb.c1, row, nb.c2 - nb.c1 + 1, n.text, cells.square, start_row, skip, .{ .bg = Theme.panel });
        }
        for (self.seq.messages[0..self.seq.message_count]) |*m| {
            self.drawLabel(win, m, start_row, skip);
        }
    }

    fn drawParticipantBoxes(self: *const Layout, win: vaxis.Window, start_row: usize, skip: usize) void {
        const style: vaxis.Style = .{ .dim = true };
        const top = self.titleRows();
        const bottom = top + 5;
        for (self.seq.participant_boxes[0..self.seq.participant_box_count]) |box| {
            const last = box.first + box.count - 1;
            const x1 = self.x[box.first] - 1;
            const x2 = self.x[last] + self.w[last];
            cells.putLine(win, top, x1, start_row, skip, "┌", style);
            cells.putLine(win, top, x2, start_row, skip, "┐", style);
            cells.putLine(win, bottom, x1, start_row, skip, "└", style);
            cells.putLine(win, bottom, x2, start_row, skip, "┘", style);
            var col = x1 + 1;
            while (col < x2) : (col += 1) {
                cells.putLine(win, top, col, start_row, skip, "─", style);
                cells.putLine(win, bottom, col, start_row, skip, "─", style);
            }
            for (top + 1..bottom) |row| {
                cells.putLine(win, row, x1, start_row, skip, "│", style);
                cells.putLine(win, row, x2, start_row, skip, "│", style);
            }
            cells.putText(win, top, x1 + 2, start_row, skip, box.label, x2 - 1, style);
        }
    }

    fn drawParticipant(self: *const Layout, win: vaxis.Window, index: usize, top: usize, start_row: usize, skip: usize) void {
        const participant = &self.seq.participants[index];
        const corners = switch (participant.kind) {
            .actor, .database => cells.round,
            .participant, .boundary, .control, .entity, .collections, .queue => cells.square,
        };
        cells.box(win, self.x[index], top, self.w[index], participant.label, corners, start_row, skip, .{});
        if (participant.link) |uri| {
            cells.putTextLink(win, top + 1, self.x[index] + 2, start_row, skip, participant.label, self.x[index] + self.w[index] - 2, .{}, uri);
        }
    }

    fn drawMessage(self: *const Layout, win: vaxis.Window, m: *const Mermaid.Message, start_row: usize, skip: usize) void {
        const s = partIndex(self.seq, m.src) orelse return;
        const d = partIndex(self.seq, m.dst) orelse return;
        const base = self.rowOf(m.pos);
        const wire = base + @intFromBool(m.number != null or m.text.len > 0);
        var scx = self.lifelineCol(s, wire);
        var dcx = self.lifelineCol(d, wire);
        if (mem.eql(u8, m.src, m.dst)) {
            wireCell(m.style, win, wire, scx + 1, start_row, skip);
            wireCell(m.style, win, wire, scx + 2, start_row, skip);
            wireCell(m.style, win, wire, scx + 3, start_row, skip);
            cells.putLine(win, wire, scx + 4, start_row, skip, "┐", .{});
            wireCell(m.style, win, wire + 1, scx + 1, start_row, skip);
            wireCell(m.style, win, wire + 1, scx + 2, start_row, skip);
            wireCell(m.style, win, wire + 1, scx + 3, start_row, skip);
            cells.putLine(win, wire + 1, scx + 4, start_row, skip, "┘", .{});
            drawEndpoint(win, wire + 1, scx + 1, m.dst_endpoint, false, start_row, skip);
            drawEndpoint(win, wire, scx + 1, m.src_endpoint, true, start_row, skip);
            if (m.central == .source or m.central == .both)
                cells.putRaw(win, wire, scx, start_row, skip, "○", .{});
            if (m.central == .destination or m.central == .both)
                cells.putRaw(win, wire + 1, scx, start_row, skip, "○", .{});
            return;
        }
        const source_lifeline = scx;
        const destination_lifeline = dcx;
        const points_right = destination_lifeline > source_lifeline;
        if (m.central == .source or m.central == .both) scx = if (points_right) scx + 1 else scx - 1;
        if (m.central == .destination or m.central == .both) dcx = if (points_right) dcx - 1 else dcx + 1;
        const lo = @min(scx, dcx);
        const hi = @max(scx, dcx);
        var c = lo;
        while (c <= hi) : (c += 1) wireCell(m.style, win, wire, c, start_row, skip);
        drawEndpoint(win, wire, dcx, m.dst_endpoint, points_right, start_row, skip);
        drawEndpoint(win, wire, scx, m.src_endpoint, !points_right, start_row, skip);
        if (m.central == .source or m.central == .both)
            cells.putRaw(win, wire, source_lifeline, start_row, skip, "○", .{});
        if (m.central == .destination or m.central == .both)
            cells.putRaw(win, wire, destination_lifeline, start_row, skip, "○", .{});
    }

    fn drawLabel(self: *const Layout, win: vaxis.Window, m: *const Mermaid.Message, start_row: usize, skip: usize) void {
        if (m.number == null and m.text.len == 0) return;
        const s = partIndex(self.seq, m.src) orelse return;
        const d = partIndex(self.seq, m.dst) orelse return;
        const row = self.rowOf(m.pos);
        const c = self.labelStart(s, d, row);
        if (m.number) |number| {
            const num_width = putNumber(win, row, c, start_row, skip, number, self.cols -| 1);
            cells.putText(win, row, c + num_width, start_row, skip, m.text, self.cols -| 1, .{});
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

fn drawEndpoint(win: vaxis.Window, row: usize, col: usize, endpoint: Mermaid.MsgEndpoint, points_right: bool, start_row: usize, skip: usize) void {
    const glyph = endpointGlyph(endpoint, points_right) orelse return;
    cells.putRaw(win, row, col, start_row, skip, glyph, .{});
}

fn endpointGlyph(endpoint: Mermaid.MsgEndpoint, points_right: bool) ?[]const u8 {
    return switch (endpoint) {
        .none => null,
        .arrow => if (points_right) "►" else "◄",
        .cross => "×",
        .open => if (points_right) ">" else "<",
        .half_top => if (points_right) "↗" else "↖",
        .half_bottom => if (points_right) "↘" else "↙",
        .stick_top => if (points_right) "╲" else "╱",
        .stick_bottom => if (points_right) "╱" else "╲",
    };
}

const ActiveSpan = struct {
    p: usize,
    r1: usize,
    r2: usize,
    depth: usize,
};

fn numberWidth(value: u64) usize {
    const fraction = value % 100;
    const fraction_width: usize = if (fraction == 0) 2 else if (fraction % 10 == 0) 4 else 5;
    return digitCount(value / 100) + fraction_width;
}

fn digitCount(value: u64) usize {
    var count: usize = 1;
    var remaining = value;
    while (remaining >= 10) {
        remaining /= 10;
        count += 1;
    }
    return count;
}

fn putNumber(win: vaxis.Window, r: usize, c0: usize, start_row: usize, skip: usize, value: u64, max_c: usize) usize {
    const digits = "0123456789";
    const whole = value / 100;
    var divisor: u64 = 1;
    while (whole / divisor >= 10) divisor *= 10;
    var col = c0;
    var current = divisor;
    while (current > 0) : (current /= 10) {
        if (col + 1 > max_c or col + 1 > win.width) return col - c0;
        const digit: usize = @intCast((whole / current) % 10);
        cells.putRaw(win, r, col, start_row, skip, digits[digit .. digit + 1], .{});
        col += 1;
    }
    const fraction = value % 100;
    if (fraction > 0) {
        if (col + 2 > max_c or col + 2 > win.width) return col - c0;
        cells.putRaw(win, r, col, start_row, skip, ".", .{});
        col += 1;
        const tens: usize = @intCast(fraction / 10);
        cells.putRaw(win, r, col, start_row, skip, digits[tens .. tens + 1], .{});
        col += 1;
        if (fraction % 10 > 0) {
            if (col + 1 > max_c or col + 1 > win.width) return col - c0;
            const ones: usize = @intCast(fraction % 10);
            cells.putRaw(win, r, col, start_row, skip, digits[ones .. ones + 1], .{});
            col += 1;
        }
    }
    for ([_][]const u8{ ".", " " }) |glyph| {
        if (col + 1 > max_c or col + 1 > win.width) return col - c0;
        cells.putRaw(win, r, col, start_row, skip, glyph, .{});
        col += 1;
    }
    return col - c0;
}

fn partIndex(seq: *const Mermaid.Sequence, id: []const u8) ?usize {
    for (seq.participants[0..seq.participant_count], 0..) |*p, i| {
        if (mem.eql(u8, p.id, id)) return i;
    }
    return null;
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
const Mermaid = @import("../../Mermaid.zig");
const cells = @import("cells.zig");
const Theme = @import("../Theme.zig");
const vaxis = @import("vaxis");

test "sequence titles render above participants" {
    var seq = Mermaid.parseSequenceBlockText("sequenceDiagram\ntitle: Conversation\nA->>B: hi\n").?;
    try testing.expectEqual(@as(usize, 7), layout(null, &seq, 0, 0, 40).?);
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 7, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 0, 0, "C");
    try expectGlyph(win, 0, 2, "┌");
    try testing.expect(win.readCell(0, 0).?.style.bold);
}

test "participant links render as terminal hyperlinks" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "participant Alice\n" ++
            "link Alice: Dashboard @ https://example.com/dashboard\n" ++
            "Alice->>Bob: hi\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 5, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try testing.expectEqualStrings("https://example.com/dashboard", win.readCell(2, 1).?.link.uri);
}

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

test "participant stereotypes and boxes render" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "box Services\n" ++
            "participant A@{ \"type\": \"boundary\" }\n" ++
            "participant DB@{ \"type\": \"database\" }\n" ++
            "end\n" ++
            "A->>DB: query\n",
    ).?;
    const rows = layout(null, &seq, 0, 0, 40).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(rows), .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 2, 0, "S");
    try expectGlyph(win, 1, 2, "┌");
    try expectGlyph(win, 9, 2, "╭");
    try expectGlyph(win, 0, 5, "└");
}

test "created and destroyed participants render lifecycle" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "participant A\n" ++
            "create participant B as Bob\n" ++
            "A->>B: hello\n" ++
            "destroy B\n" ++
            "B--xA: bye\n",
    ).?;
    try testing.expectEqual(@as(usize, 10), layout(null, &seq, 0, 0, 40).?);
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 10, 4, "B");
    try expectGlyph(win, 11, 6, "│");
    try expectGlyph(win, 11, 9, "×");
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

test "bidirectional arrows mark both participants" {
    var seq = Mermaid.parseSequenceBlockText("sequenceDiagram\nA<<->>B: hi\n").?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 5, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 2, 4, "◄");
    try expectGlyph(win, 10, 4, "►");
}

test "half arrows render at either endpoint" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A-|\\B: forward\n" ++
            "B/|-A: reverse\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 7, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 10, 4, "↗");
    try expectGlyph(win, 10, 6, "↗");
}

test "central connections render circles beside endpoints" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A->>()B: d\n" ++
            "A()->>B: s\n" ++
            "A()->>()A: self\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 9, 4, "►");
    try expectGlyph(win, 10, 4, "○");
    try expectGlyph(win, 2, 6, "○");
    try expectGlyph(win, 10, 6, "►");
    try expectGlyph(win, 2, 8, "○");
    try expectGlyph(win, 2, 9, "○");
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
    try testing.expect(win.readCell(4, 4).?.style.bg.eql(Theme.panel));
    try testing.expect(win.readCell(8, 4).?.style.bg.eql(Theme.panel));
    try testing.expect(!win.readCell(0, 0).?.style.bg.eql(Theme.panel));
}

test "loop fragments box messages" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "loop Every minute\n" ++
            "A->>B: ping\n" ++
            "end\n",
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

test "critical fragments render option dividers" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "critical Connect\n" ++
            "A->>B: try\n" ++
            "option Timeout\n" ++
            "A->>B: retry\n" ++
            "end\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 3, 3, "c");
    try expectGlyph(win, 3, 6, "o");
    try expectGlyph(win, 0, 9, "└");
}

test "lifecycle renders inside par over fragments" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "par_over work\n" ++
            "create actor D\n" ++
            "A->>D: create\n" ++
            "and finish\n" ++
            "destroy D\n" ++
            "D--xA: destroy\n" ++
            "end\n",
    ).?;
    const rows = layout(null, &seq, 0, 0, 40).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(rows), .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 0, 3, "┌");
    try expectGlyph(win, 2, 5, "D");
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

test "stacked activations widen lifelines" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "activate A\n" ++
            "activate A\n" ++
            "A->>B: nested\n" ++
            "deactivate A\n" ++
            "A->>B: outer\n" ++
            "deactivate A\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 7, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 2, 3, "┃");
    try expectGlyph(win, 3, 3, "┃");
    try expectGlyph(win, 4, 3, "n");
    try expectGlyph(win, 2, 5, "┃");
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

test "configured autonumber prefixes" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "autonumber 2.5 0.25\n" ++
            "A->>B: first\n" ++
            "A->>B: second\n" ++
            "A->>B: third\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 9, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 3, 3, "2");
    try expectGlyph(win, 5, 3, "5");
    try expectGlyph(win, 6, 5, "5");
    try expectGlyph(win, 3, 7, "3");
}

test "autonumber can start and stop" {
    var seq = Mermaid.parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "autonumber 5\n" ++
            "A->>B: first\n" ++
            "autonumber off\n" ++
            "A->>B: second\n",
    ).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 7, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 3, 3, "5");
    try expectGlyph(win, 3, 5, "s");
}

test "sequence text normalizes line breaks and entities" {
    var seq = Mermaid.parseSequenceBlockText("sequenceDiagram\nA->>B: hi<br/>there #9829; #infin; &amp;\n").?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 5, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &seq, 0, 0, 40).?;
    try expectGlyph(win, 5, 3, " ");
    try expectGlyph(win, 6, 3, "t");
    try expectGlyph(win, 12, 3, "♥");
    try expectGlyph(win, 14, 3, "∞");
    try expectGlyph(win, 16, 3, "&");
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
