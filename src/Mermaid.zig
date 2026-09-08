//! Zero-copy Mermaid flowchart parser (graph/flowchart only).
//!
//! parseBlock borrows a fenced code block; every slice in the returned
//! Flowchart points into the block content. There is no allocation and no
//! failure: unknown lines are skipped, over-cap input sets degraded, and
//! non-flowchart blocks return null so callers fall back to the code card.

pub const max_nodes = 64;
pub const max_edges = 128;

pub const Direction = enum { tb, bt, lr, rl };

pub const Shape = enum {
    rect,
    rounded,
    diamond,
    circle,
    stadium,
    subroutine,
    parallelogram,
    hexagon,
};

pub const EdgeStyle = enum { solid, dotted, thick };

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape,
};

pub const Edge = struct {
    src: []const u8,
    dst: []const u8,
    label: ?[]const u8,
    style: EdgeStyle,
    arrow: bool,
};

pub const Flowchart = struct {
    direction: Direction = .tb,
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    edges: [max_edges]Edge = undefined,
    edge_count: usize = 0,
    degraded: bool = false,

    pub fn nodeList(self: *const Flowchart) []const Node {
        return self.nodes[0..self.node_count];
    }

    pub fn edgeList(self: *const Flowchart) []const Edge {
        return self.edges[0..self.edge_count];
    }
};

pub fn parseBlock(cb: Document.Element.CodeBlock) ?Flowchart {
    const info = cb.info orelse return null;
    if (!info.isMermaid()) return null;
    var parser: Parser = .{};
    var lines = cb.lines();
    while (lines.next()) |line| parser.feed(line);
    if (!parser.seen_header) return null;
    return parser.flow;
}

pub fn parseText(text: []const u8) ?Flowchart {
    var parser: Parser = .{};
    feedLines(&parser, text);
    if (!parser.seen_header) return null;
    return parser.flow;
}

fn feedLines(parser: anytype, text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        const nl = mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        parser.feed(rest[0..nl]);
        rest = if (nl < rest.len) rest[nl + 1 ..] else "";
    }
}

const Parser = struct {
    flow: Flowchart = .{},
    seen_header: bool = false,

    fn feed(self: *Parser, raw: []const u8) void {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) return;
        if (mem.startsWith(u8, line, "%%")) return;
        if (!self.seen_header) {
            self.flow.direction = parseHeader(line) orelse return;
            self.seen_header = true;
            return;
        }
        if (mem.eql(u8, line, "end")) return;
        for ([_][]const u8{ "subgraph", "style", "classDef", "class", "click", "linkStyle" }) |keyword| {
            if (isKeywordLine(line, keyword)) return;
        }
        self.feedBody(line);
    }

    fn feedBody(self: *Parser, line: []const u8) void {
        if (self.flow.degraded) return;
        var pos: usize = 0;
        var prev_id: ?[]const u8 = null;
        var pending: ?Op = null;
        while (pos <= line.len) {
            const found = findOp(line, pos);
            const end = if (found) |f| f.at else line.len;
            const node = parseNode(mem.trim(u8, line[pos..end], " \t\r")) orelse return;
            const id = self.intern(node) orelse return;
            if (pending) |op| {
                self.addEdge(prev_id.?, id, op);
                if (self.flow.degraded) return;
            }
            const f = found orelse return;
            prev_id = id;
            pending = f.op;
            pos = f.after;
        }
    }

    fn intern(self: *Parser, node: Node) ?[]const u8 {
        for (self.flow.nodes[0..self.flow.node_count]) |existing| {
            if (mem.eql(u8, existing.id, node.id)) return existing.id;
        }
        if (self.flow.node_count >= max_nodes) {
            self.flow.degraded = true;
            return null;
        }
        self.flow.nodes[self.flow.node_count] = node;
        self.flow.node_count += 1;
        return node.id;
    }

    fn addEdge(self: *Parser, src: []const u8, dst: []const u8, op: Op) void {
        if (self.flow.degraded) return;
        if (self.flow.edge_count >= max_edges) {
            self.flow.degraded = true;
            return;
        }
        self.flow.edges[self.flow.edge_count] = .{
            .src = src,
            .dst = dst,
            .label = op.label,
            .style = op.style,
            .arrow = op.arrow,
        };
        self.flow.edge_count += 1;
    }
};

fn parseHeader(line: []const u8) ?Direction {
    var word_end: usize = 0;
    while (word_end < line.len and line[word_end] != ' ' and line[word_end] != '\t') : (word_end += 1) {}
    const word = line[0..word_end];
    if (!mem.eql(u8, word, "graph") and !mem.eql(u8, word, "flowchart")) return null;
    const rest = mem.trim(u8, line[word_end..], " \t\r");
    if (rest.len == 0) return .tb;
    var end: usize = 0;
    while (end < rest.len and rest[end] != ' ' and rest[end] != '\t' and rest[end] != ';') : (end += 1) {}
    const dir = rest[0..end];
    if (eqlIgnoreCase(dir, "TD") or eqlIgnoreCase(dir, "TB")) return .tb;
    if (eqlIgnoreCase(dir, "BT")) return .bt;
    if (eqlIgnoreCase(dir, "LR")) return .lr;
    if (eqlIgnoreCase(dir, "RL")) return .rl;
    return null;
}

fn isKeywordLine(line: []const u8, keyword: []const u8) bool {
    if (!mem.startsWith(u8, line, keyword)) return false;
    if (line.len == keyword.len) return true;
    const c = line[keyword.len];
    return c == ' ' or c == '\t';
}

fn parseNode(seg: []const u8) ?Node {
    if (seg.len == 0) return null;
    var id_len: usize = 0;
    while (id_len < seg.len and isIdChar(seg[id_len])) : (id_len += 1) {}
    if (id_len == 0) return null;
    const id = seg[0..id_len];
    const rest = mem.trim(u8, seg[id_len..], " \t\r");
    if (rest.len == 0) return .{ .id = id, .label = id, .shape = .rect };
    if (rest.len >= 4) {
        if (mem.startsWith(u8, rest, "((") and mem.endsWith(u8, rest, "))"))
            return shaped(id, rest[2 .. rest.len - 2], .circle);
        if (mem.startsWith(u8, rest, "([") and mem.endsWith(u8, rest, "])"))
            return shaped(id, rest[2 .. rest.len - 2], .stadium);
        if (mem.startsWith(u8, rest, "[[") and mem.endsWith(u8, rest, "]]"))
            return shaped(id, rest[2 .. rest.len - 2], .subroutine);
        if (mem.startsWith(u8, rest, "{{") and mem.endsWith(u8, rest, "}}"))
            return shaped(id, rest[2 .. rest.len - 2], .hexagon);
    }
    if (rest[0] == '(' and mem.endsWith(u8, rest, ")"))
        return shaped(id, rest[1 .. rest.len - 1], .rounded);
    if (rest[0] == '[' and mem.endsWith(u8, rest, "]")) {
        const inner = rest[1 .. rest.len - 1];
        if (inner.len >= 2 and (inner[0] == '/' or inner[0] == '\\') and
            (inner[inner.len - 1] == '/' or inner[inner.len - 1] == '\\'))
            return shaped(id, inner[1 .. inner.len - 1], .parallelogram);
        return shaped(id, inner, .rect);
    }
    if (rest[0] == '{' and mem.endsWith(u8, rest, "}"))
        return shaped(id, rest[1 .. rest.len - 1], .diamond);
    return null;
}

fn shaped(id: []const u8, raw_label: []const u8, shape: Shape) Node {
    const label = mem.trim(u8, raw_label, " \t\r");
    return .{ .id = id, .label = if (label.len == 0) id else label, .shape = shape };
}

fn isIdChar(c: u8) bool {
    return ascii.isAlphanumeric(c) or c == '_';
}

const Op = struct {
    style: EdgeStyle,
    arrow: bool,
    label: ?[]const u8,
};

const FoundOp = struct {
    at: usize,
    after: usize,
    op: Op,
};

fn findOp(line: []const u8, from: usize) ?FoundOp {
    var i = from;
    var depth: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '[', '(', '{' => depth += 1,
            ']', ')', '}' => depth -|= 1,
            '-', '=' => if (depth == 0) {
                if (matchOp(line, i)) |found| return found;
            },
            else => {},
        }
    }
    return null;
}

fn matchOp(line: []const u8, i: usize) ?FoundOp {
    const rest = line[i..];
    if (matchToken(rest)) |t| return opAt(line, i, t.len, t.style, t.arrow);
    if (rest.len <= 2) return null;
    if (line[i] == '-') {
        if (rest[1] == '-' and rest[2] == '|') return opAt(line, i, 2, .solid, true);
        if (rest[1] == '-' or rest[1] == '.') return spacedOp(line, i);
    } else if (rest[1] == '=') {
        return spacedOp(line, i);
    }
    return null;
}

const Token = struct {
    len: usize,
    style: EdgeStyle,
    arrow: bool,
};

fn matchToken(rest: []const u8) ?Token {
    if (mem.startsWith(u8, rest, "-.->")) return .{ .len = 4, .style = .dotted, .arrow = true };
    if (mem.startsWith(u8, rest, "-->")) return .{ .len = 3, .style = .solid, .arrow = true };
    if (mem.startsWith(u8, rest, "---")) return .{ .len = 3, .style = .solid, .arrow = false };
    if (mem.startsWith(u8, rest, "-.-")) return .{ .len = 3, .style = .dotted, .arrow = false };
    if (mem.startsWith(u8, rest, "==>")) return .{ .len = 3, .style = .thick, .arrow = true };
    if (mem.startsWith(u8, rest, "===")) return .{ .len = 3, .style = .thick, .arrow = false };
    return null;
}

fn spacedOp(line: []const u8, at: usize) ?FoundOp {
    var j = at + 2;
    while (j < line.len) : (j += 1) {
        if (line[j] != '-' and line[j] != '=') continue;
        const rest = line[j..];
        if (matchToken(rest)) |t| return spacedAt(line, at, j, t.len, t.style, t.arrow);
        if (line[j] == '-' and rest.len > 1 and rest[1] == '>' and line[j - 1] == '.')
            return spacedAt(line, at, j - 1, 3, .dotted, true);
    }
    return null;
}

fn spacedAt(line: []const u8, at: usize, close: usize, len: usize, style: EdgeStyle, arrow: bool) FoundOp {
    const raw = mem.trim(u8, line[at + 2 .. close], " \t\r");
    var found = opAt(line, close, len, style, arrow);
    found.at = at;
    if (found.op.label == null and raw.len > 0) found.op.label = raw;
    return found;
}

fn opAt(line: []const u8, at: usize, len: usize, style: EdgeStyle, arrow: bool) FoundOp {
    var after = at + len;
    var label: ?[]const u8 = null;
    if (after < line.len and line[after] == '|') {
        if (mem.indexOfScalarPos(u8, line, after + 1, '|')) |close| {
            label = mem.trim(u8, line[after + 1 .. close], " \t\r");
            after = close + 1;
        }
    }
    return .{ .at = at, .after = after, .op = .{ .style = style, .arrow = arrow, .label = label } };
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (ascii.toLower(x) != ascii.toLower(y)) return false;
    }
    return true;
}

pub const max_participants = 32;
pub const max_messages = 128;
pub const max_notes = 32;
pub const max_fragments = 16;
pub const max_fragment_depth = 8;
pub const max_activations = 64;

pub const Participant = struct {
    id: []const u8,
    label: []const u8,
};

pub const MsgStyle = enum { solid, dotted };
pub const MsgKind = enum { plain, arrow, cross, open };

pub const Message = struct {
    src: []const u8,
    dst: []const u8,
    style: MsgStyle,
    kind: MsgKind,
    text: []const u8,
    pos: usize,
};

pub const NoteKind = enum { over, left, right };

pub const Note = struct {
    kind: NoteKind,
    a: []const u8,
    b: ?[]const u8,
    text: []const u8,
    pos: usize,
};

pub const FragmentOp = enum { loop, alt, opt, par, @"opaque" };

pub const Divider = struct {
    pos: usize,
    head: []const u8,
    text: []const u8,
};

pub const Fragment = struct {
    op: FragmentOp,
    label: []const u8,
    start: usize,
    end: usize,
    divs: [8]Divider = undefined,
    div_count: usize = 0,
    depth: usize,
};

pub const Activation = struct {
    actor: []const u8,
    start: usize,
    end: usize,
};

pub const Sequence = struct {
    participants: [max_participants]Participant = undefined,
    participant_count: usize = 0,
    messages: [max_messages]Message = undefined,
    message_count: usize = 0,
    notes: [max_notes]Note = undefined,
    note_count: usize = 0,
    fragments: [max_fragments]Fragment = undefined,
    fragment_count: usize = 0,
    activations: [max_activations]Activation = undefined,
    activation_count: usize = 0,
    autonumber: bool = false,
    degraded: bool = false,
};

pub fn parseSequenceBlockText(text: []const u8) ?Sequence {
    var parser: SeqParser = .{};
    feedLines(&parser, text);
    if (!parser.seen_header) return null;
    parser.finish();
    return parser.seq;
}

pub fn parseSequenceBlock(cb: Document.Element.CodeBlock) ?Sequence {
    const info = cb.info orelse return null;
    if (!info.isMermaid()) return null;
    var parser: SeqParser = .{};
    var lines = cb.lines();
    while (lines.next()) |line| parser.feed(line);
    if (!parser.seen_header) return null;
    parser.finish();
    return parser.seq;
}

const SeqParser = struct {
    seq: Sequence = .{},
    seen_header: bool = false,
    pos: usize = 0,
    stack: [max_fragment_depth]usize = undefined,
    stack_len: usize = 0,
    active_from: [max_participants]?usize = [_]?usize{null} ** max_participants,

    fn feed(self: *SeqParser, raw: []const u8) void {
        if (self.seq.degraded) return;
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or mem.startsWith(u8, line, "%%")) return;
        if (!self.seen_header) {
            if (mem.eql(u8, line, "sequenceDiagram")) self.seen_header = true;
            return;
        }
        if (parseParticipantLine(line)) |p| {
            self.addParticipant(p.id, p.label, p.explicit);
            return;
        }
        if (parseNoteLine(line)) |n| {
            self.addNote(n.kind, n.a, n.b, n.text);
            return;
        }
        if (self.feedControl(line)) return;
        if (parseMessageLine(line)) |m| {
            self.addMessage(m);
            return;
        }
    }

    fn finish(self: *SeqParser) void {
        while (self.stack_len > 0) {
            self.stack_len -= 1;
            self.seq.fragments[self.stack[self.stack_len]].end = self.pos;
        }
        for (self.active_from[0..self.seq.participant_count], 0..) |from, i| {
            const start = from orelse continue;
            if (self.seq.activation_count >= max_activations) {
                self.seq.degraded = true;
                return;
            }
            self.seq.activations[self.seq.activation_count] = .{
                .actor = self.seq.participants[i].id,
                .start = start,
                .end = self.pos,
            };
            self.seq.activation_count += 1;
        }
    }

    fn intern(self: *SeqParser, id: []const u8) ?usize {
        for (self.seq.participants[0..self.seq.participant_count], 0..) |*p, i| {
            if (mem.eql(u8, p.id, id)) return i;
        }
        if (self.seq.participant_count >= max_participants) {
            self.seq.degraded = true;
            return null;
        }
        self.seq.participants[self.seq.participant_count] = .{ .id = id, .label = id };
        self.seq.participant_count += 1;
        return self.seq.participant_count - 1;
    }

    fn addParticipant(self: *SeqParser, id: []const u8, label: []const u8, explicit: bool) void {
        for (self.seq.participants[0..self.seq.participant_count]) |*p| {
            if (mem.eql(u8, p.id, id)) {
                if (explicit) p.label = label;
                return;
            }
        }
        if (self.seq.participant_count >= max_participants) {
            self.seq.degraded = true;
            return;
        }
        self.seq.participants[self.seq.participant_count] = .{ .id = id, .label = label };
        self.seq.participant_count += 1;
    }

    fn addNote(self: *SeqParser, kind: NoteKind, a: []const u8, b: ?[]const u8, text: []const u8) void {
        _ = self.intern(a) orelse return;
        if (b) |other| _ = self.intern(other) orelse return;
        if (self.seq.note_count >= max_notes) {
            self.seq.degraded = true;
            return;
        }
        self.seq.notes[self.seq.note_count] = .{ .kind = kind, .a = a, .b = b, .text = text, .pos = self.pos };
        self.seq.note_count += 1;
        self.pos += 1;
    }

    fn addMessage(self: *SeqParser, m: ParsedMessage) void {
        const s = self.intern(m.src) orelse return;
        const d = self.intern(m.dst) orelse return;
        if (self.seq.message_count >= max_messages) {
            self.seq.degraded = true;
            return;
        }
        self.seq.messages[self.seq.message_count] = .{
            .src = m.src,
            .dst = m.dst,
            .style = m.style,
            .kind = m.kind,
            .text = m.text,
            .pos = self.pos,
        };
        self.seq.message_count += 1;
        self.pos += 1;
        if (m.plus) self.startActivation(d, self.pos - 1);
        if (m.minus) self.endActivation(s, self.pos);
    }

    fn startActivation(self: *SeqParser, idx: usize, at: usize) void {
        if (self.active_from[idx] != null) return;
        self.active_from[idx] = at;
    }

    fn endActivation(self: *SeqParser, idx: usize, at: usize) void {
        const start = self.active_from[idx] orelse return;
        if (self.seq.activation_count >= max_activations) {
            self.seq.degraded = true;
            return;
        }
        self.seq.activations[self.seq.activation_count] = .{
            .actor = self.seq.participants[idx].id,
            .start = start,
            .end = at,
        };
        self.seq.activation_count += 1;
        self.active_from[idx] = null;
    }

    fn feedControl(self: *SeqParser, line: []const u8) bool {
        if (stripKeyword(line, "autonumber") != null) {
            self.seq.autonumber = true;
            return true;
        }
        if (prefixId(line, "activate")) |id| {
            if (self.intern(id)) |idx| self.startActivation(idx, self.pos);
            return true;
        }
        if (prefixId(line, "deactivate")) |id| {
            if (self.intern(id)) |idx| self.endActivation(idx, self.pos);
            return true;
        }
        const blocks = [_]struct { kw: []const u8, op: FragmentOp }{
            .{ .kw = "loop", .op = .loop },
            .{ .kw = "alt", .op = .alt },
            .{ .kw = "opt", .op = .opt },
            .{ .kw = "par", .op = .par },
        };
        for (blocks) |b| {
            if (stripKeyword(line, b.kw)) |label| {
                self.push(b.op, label);
                return true;
            }
        }
        for ([_][]const u8{ "rect", "critical", "break", "box" }) |kw| {
            if (stripKeyword(line, kw)) |label| {
                self.push(.@"opaque", label);
                return true;
            }
        }
        if (stripKeyword(line, "and")) |label| {
            self.div("and", label);
            return true;
        }
        if (stripKeyword(line, "else")) |label| {
            self.div("else", label);
            return true;
        }
        if (stripKeyword(line, "end") != null) {
            self.close();
            return true;
        }
        return false;
    }

    fn push(self: *SeqParser, op: FragmentOp, label: []const u8) void {
        if (self.stack_len >= max_fragment_depth or self.seq.fragment_count >= max_fragments) {
            self.seq.degraded = true;
            return;
        }
        const idx = self.seq.fragment_count;
        self.seq.fragments[idx] = .{
            .op = op,
            .label = label,
            .start = self.pos,
            .end = self.pos,
            .depth = self.stack_len,
        };
        self.seq.fragment_count += 1;
        self.stack[self.stack_len] = idx;
        self.stack_len += 1;
    }

    fn close(self: *SeqParser) void {
        if (self.stack_len == 0) return;
        self.stack_len -= 1;
        self.seq.fragments[self.stack[self.stack_len]].end = self.pos;
    }

    fn div(self: *SeqParser, head: []const u8, label: []const u8) void {
        if (self.stack_len == 0) return;
        const frag = &self.seq.fragments[self.stack[self.stack_len - 1]];
        if (frag.div_count >= frag.divs.len) return;
        frag.divs[frag.div_count] = .{ .pos = self.pos, .head = head, .text = label };
        frag.div_count += 1;
    }
};

fn boundary(s: []const u8, n: usize) bool {
    return s.len == n or s[n] == ' ' or s[n] == '\t';
}

fn stripKeyword(s: []const u8, kw: []const u8) ?[]const u8 {
    if (!mem.startsWith(u8, s, kw) or !boundary(s, kw.len)) return null;
    return mem.trim(u8, s[kw.len..], " \t");
}

fn prefixId(s: []const u8, kw: []const u8) ?[]const u8 {
    const rest = stripKeyword(s, kw) orelse return null;
    var i: usize = 0;
    while (i < rest.len and isIdChar(rest[i])) : (i += 1) {}
    if (i == 0 or i != rest.len) return null;
    return rest[0..i];
}

fn parseId(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    for (s) |c| if (!isIdChar(c)) return null;
    return s;
}

const ParsedParticipant = struct {
    id: []const u8,
    label: []const u8,
    explicit: bool,
};

fn parseParticipantLine(line: []const u8) ?ParsedParticipant {
    const rest = if (stripKeyword(line, "participant")) |r| r else if (stripKeyword(line, "actor")) |r| r else return null;
    var i: usize = 0;
    while (i < rest.len and isIdChar(rest[i])) : (i += 1) {}
    if (i == 0) return null;
    const id = rest[0..i];
    const after = mem.trim(u8, rest[i..], " \t");
    if (after.len == 0) return .{ .id = id, .label = id, .explicit = false };
    if (!mem.startsWith(u8, after, "as")) return null;
    const tail = after[2..];
    if (tail.len > 0 and tail[0] != ' ' and tail[0] != '\t') return null;
    const label = mem.trim(u8, tail, " \t");
    if (label.len == 0) return .{ .id = id, .label = id, .explicit = false };
    return .{ .id = id, .label = label, .explicit = true };
}

const ParsedNote = struct {
    kind: NoteKind,
    a: []const u8,
    b: ?[]const u8,
    text: []const u8,
};

fn parseNoteLine(line: []const u8) ?ParsedNote {
    const rest = stripKeyword(line, "Note") orelse return null;
    if (stripKeyword(rest, "over")) |after| {
        const ci = mem.indexOfScalar(u8, after, ':') orelse return null;
        const actors = mem.trim(u8, after[0..ci], " \t");
        const text = mem.trim(u8, after[ci + 1 ..], " \t");
        if (mem.indexOfScalar(u8, actors, ',')) |comma| {
            const a = parseId(mem.trim(u8, actors[0..comma], " \t")) orelse return null;
            const b = parseId(mem.trim(u8, actors[comma + 1 ..], " \t")) orelse return null;
            return .{ .kind = .over, .a = a, .b = b, .text = text };
        }
        return .{ .kind = .over, .a = parseId(actors) orelse return null, .b = null, .text = text };
    }
    for ([_]struct { kw: []const u8, kind: NoteKind }{ .{ .kw = "left", .kind = .left }, .{ .kw = "right", .kind = .right } }) |side| {
        const after_side = stripKeyword(rest, side.kw) orelse continue;
        const after_of = stripKeyword(after_side, "of") orelse return null;
        const ci = mem.indexOfScalar(u8, after_of, ':') orelse return null;
        const actor = parseId(mem.trim(u8, after_of[0..ci], " \t")) orelse return null;
        return .{ .kind = side.kind, .a = actor, .b = null, .text = mem.trim(u8, after_of[ci + 1 ..], " \t") };
    }
    return null;
}

const ParsedMessage = struct {
    src: []const u8,
    dst: []const u8,
    style: MsgStyle,
    kind: MsgKind,
    text: []const u8,
    plus: bool,
    minus: bool,
};

const MsgToken = struct {
    style: MsgStyle,
    kind: MsgKind,
    len: usize,
};

fn parseMessageLine(line: []const u8) ?ParsedMessage {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '-') continue;
        const rest = line[i..];
        // Longest match first: ->> precedes ->, -->> precedes -->.
        const arrow: MsgToken = if (mem.startsWith(u8, rest, "-->>"))
            .{ .style = .dotted, .kind = .arrow, .len = 4 }
        else if (mem.startsWith(u8, rest, "->>"))
            .{ .style = .solid, .kind = .arrow, .len = 3 }
        else if (mem.startsWith(u8, rest, "-->"))
            .{ .style = .dotted, .kind = .plain, .len = 3 }
        else if (mem.startsWith(u8, rest, "->"))
            .{ .style = .solid, .kind = .plain, .len = 2 }
        else if (mem.startsWith(u8, rest, "--x"))
            .{ .style = .dotted, .kind = .cross, .len = 3 }
        else if (mem.startsWith(u8, rest, "-x"))
            .{ .style = .solid, .kind = .cross, .len = 2 }
        else if (mem.startsWith(u8, rest, "--)"))
            .{ .style = .dotted, .kind = .open, .len = 3 }
        else if (mem.startsWith(u8, rest, "-)"))
            .{ .style = .solid, .kind = .open, .len = 2 }
        else
            continue;
        const src = parseId(mem.trim(u8, line[0..i], " \t")) orelse return null;
        var j = i + arrow.len;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        var plus = false;
        var minus = false;
        if (j < line.len and (line[j] == '+' or line[j] == '-')) {
            if (line[j] == '+') plus = true else minus = true;
            j += 1;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        }
        var k = j;
        while (k < line.len and isIdChar(line[k])) : (k += 1) {}
        if (k == j) return null;
        const dst = line[j..k];
        const after = mem.trim(u8, line[k..], " \t");
        var text: []const u8 = "";
        if (after.len > 0) {
            if (after[0] != ':') return null;
            text = mem.trim(u8, after[1..], " \t");
        }
        return .{
            .src = src,
            .dst = dst,
            .style = arrow.style,
            .kind = arrow.kind,
            .text = text,
            .plus = plus,
            .minus = minus,
        };
    }
    return null;
}

const std = @import("std");
const Document = @import("Document.zig");
const mem = std.mem;
const ascii = std.ascii;

test "header directions and rejection" {
    try testing.expect(parseText("graph TD\nA-->B\n").?.direction == .tb);
    try testing.expect(parseText("flowchart LR\n").?.direction == .lr);
    try testing.expect(parseText("graph\n").?.direction == .tb);
    try testing.expect(parseText("graph BT\n").?.direction == .bt);
    try testing.expect(parseText("graph RL\n").?.direction == .rl);
    try testing.expect(parseText("graph td\n").?.direction == .tb);
    try testing.expect(parseText("sequenceDiagram\nA->B\n") == null);
    try testing.expect(parseText("just text\n") == null);
    try testing.expect(parseText("") == null);
}

test "node shapes and labels" {
    const flow = parseText(
        "graph TD\n" ++
            "A[rect]\n" ++
            "B(round)\n" ++
            "C{choice}\n" ++
            "D((circle))\n" ++
            "E[[sub]]\n" ++
            "F[/para/]\n" ++
            "G{{hex}}\n" ++
            "H([stad])\n" ++
            "I\n",
    ).?;
    const nodes = flow.nodeList();
    try testing.expectEqual(@as(usize, 9), nodes.len);
    try testing.expectEqualStrings("rect", nodes[0].label);
    try testing.expect(nodes[0].shape == .rect);
    try testing.expect(nodes[1].shape == .rounded);
    try testing.expect(nodes[2].shape == .diamond);
    try testing.expect(nodes[3].shape == .circle);
    try testing.expect(nodes[4].shape == .subroutine);
    try testing.expect(nodes[5].shape == .parallelogram);
    try testing.expect(nodes[6].shape == .hexagon);
    try testing.expect(nodes[7].shape == .stadium);
    try testing.expectEqualStrings("I", nodes[8].label);
}

test "first node definition wins" {
    const flow = parseText("graph TD\nA[first]\nA[second]\n").?;
    try testing.expectEqual(@as(usize, 1), flow.node_count);
    try testing.expectEqualStrings("first", flow.nodeList()[0].label);
}

test "edges carry style and labels across chains" {
    const flow = parseText(
        "graph TD\n" ++
            "A-->B\n" ++
            "B---C\n" ++
            "C-.->D\n" ++
            "D==>E\n" ++
            "A-->|take|F-->|leave|G\n",
    ).?;
    const edges = flow.edgeList();
    try testing.expectEqual(@as(usize, 6), edges.len);
    try testing.expect(edges[0].style == .solid and edges[0].arrow);
    try testing.expect(edges[1].style == .solid and !edges[1].arrow);
    try testing.expect(edges[2].style == .dotted and edges[2].arrow);
    try testing.expect(edges[3].style == .thick and edges[3].arrow);
    try testing.expectEqualStrings("take", edges[4].label.?);
    try testing.expectEqualStrings("leave", edges[5].label.?);
    try testing.expectEqualStrings("A", edges[4].src);
    try testing.expectEqualStrings("F", edges[4].dst);
}

test "spaced edge labels" {
    const flow = parseText(
        "graph TD\n" ++
            "A -- Link text --> B\n" ++
            "B -- plain --- C\n" ++
            "C -. dotted .-> D\n" ++
            "D == thick ==> E\n" ++
            "A -- one --> B -- two --> C\n",
    ).?;
    const edges = flow.edgeList();
    try testing.expectEqual(@as(usize, 6), edges.len);
    try testing.expectEqualStrings("Link text", edges[0].label.?);
    try testing.expect(edges[0].style == .solid and edges[0].arrow);
    try testing.expectEqualStrings("plain", edges[1].label.?);
    try testing.expect(edges[1].style == .solid and !edges[1].arrow);
    try testing.expectEqualStrings("dotted", edges[2].label.?);
    try testing.expect(edges[2].style == .dotted and edges[2].arrow);
    try testing.expectEqualStrings("thick", edges[3].label.?);
    try testing.expect(edges[3].style == .thick and edges[3].arrow);
    try testing.expectEqualStrings("one", edges[4].label.?);
    try testing.expectEqualStrings("two", edges[5].label.?);
}

test "spaces around arrows" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A ->> B: one\n" ++
            "A->> B: two\n" ++
            "A ->>B: three\n" ++
            "A --x B: four\n" ++
            "A->>+ B: five\n",
    ).?;
    try testing.expectEqual(@as(usize, 5), seq.message_count);
    try testing.expectEqualStrings("one", seq.messages[0].text);
    try testing.expectEqualStrings("two", seq.messages[1].text);
    try testing.expectEqualStrings("three", seq.messages[2].text);
    try testing.expect(seq.messages[3].kind == .cross);
    try testing.expectEqual(@as(usize, 1), seq.activation_count);
    try testing.expectEqualStrings("B", seq.activations[0].actor);
}

test "dots and dashes survive inside spaced labels" {
    const flow = parseText(
        "graph TD\n" ++
            "A -- v1.2 --> B\n" ++
            "B -- a-b --> C\n",
    ).?;
    const edges = flow.edgeList();
    try testing.expectEqual(@as(usize, 2), edges.len);
    try testing.expectEqualStrings("v1.2", edges[0].label.?);
    try testing.expectEqualStrings("a-b", edges[1].label.?);
}

test "dashes inside labels never split" {
    const flow = parseText(
        "graph TD\n" ++
            "A[x -- y] --> B\n" ++
            "C[p --> q] --> D\n",
    ).?;
    try testing.expectEqual(@as(usize, 4), flow.node_count);
    try testing.expectEqualStrings("x -- y", flow.nodeList()[0].label);
    try testing.expectEqualStrings("p --> q", flow.nodeList()[2].label);
    try testing.expectEqual(@as(usize, 2), flow.edge_count);
}

test "comments and non-graph lines are skipped" {
    const flow = parseText(
        "%% a comment\n" ++
            "graph TD\n" ++
            "subgraph inner\n" ++
            "A-->B\n" ++
            "style A fill:red\n" ++
            "classDef x fill:blue\n" ++
            "class A x\n" ++
            "click A href\n" ++
            "not a node !!!\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), flow.node_count);
    try testing.expectEqual(@as(usize, 1), flow.edge_count);
    try testing.expect(!flow.degraded);
}

test "over-cap diagrams degrade" {
    const many_edges = parseText("graph TD\n" ++ ("A-->B\n" ** 200)).?;
    try testing.expect(many_edges.degraded);

    var buf: [8192]u8 = undefined;
    @memcpy(buf[0..9], "graph TD\n");
    var pos: usize = 9;
    for (1..66) |k| {
        @memset(buf[pos..][0..k], 'a');
        pos += k;
        buf[pos] = '\n';
        pos += 1;
    }
    const many_nodes = parseText(buf[0..pos]).?;
    try testing.expect(many_nodes.degraded);
}

test "slices point into the input" {
    const text = "graph TD\nA[hello]-->B\n";
    const flow = parseText(text).?;
    const node = flow.nodeList()[0];
    try testing.expectEqualStrings("hello", node.label);
    try testing.expect(within(text, node.id));
    try testing.expect(within(text, node.label));
    try testing.expect(within(text, flow.edgeList()[0].src));
}

test "parseBlock dispatches on info and strips containers" {
    var doc = Document.init("> ```mermaid\n> graph TD\n> A-->B\n> ```\n");
    var quote = doc.next().?.block_quote.blocks;
    const cb = quote.next().?.code_block;
    const flow = parseBlock(cb).?;
    try testing.expectEqual(@as(usize, 2), flow.node_count);
    try testing.expectEqual(@as(usize, 1), flow.edge_count);

    var zig_doc = Document.init("```zig\ngraph TD\nA-->B\n```\n");
    try testing.expect(parseBlock(zig_doc.next().?.code_block) == null);

    var seq_doc = Document.init("```mermaid\nsequenceDiagram\nA->B\n```\n");
    try testing.expect(parseBlock(seq_doc.next().?.code_block) == null);
}

test "sequence participants" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "participant A as Alice\n" ++
            "B->>A: hi\n" ++
            "participant B as Bob\n" ++
            "actor C as Carol\n" ++
            "participant A\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.participant_count);
    try testing.expectEqualStrings("Alice", seq.participants[0].label);
    try testing.expectEqualStrings("Bob", seq.participants[1].label);
    try testing.expectEqualStrings("Carol", seq.participants[2].label);
    try testing.expect(!seq.degraded);
}

test "sequence arrows" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A->B: plain\n" ++
            "A-->B: dotted\n" ++
            "A->>B: arrow\n" ++
            "A-->>B: dotted arrow\n" ++
            "A-xB: lost\n" ++
            "A--xB: dotted lost\n" ++
            "A-)B: open\n" ++
            "A--)B: dotted open\n" ++
            "A->>B\n",
    ).?;
    const messages = seq.messages[0..seq.message_count];
    try testing.expectEqual(@as(usize, 9), messages.len);
    try testing.expect(messages[0].style == .solid and messages[0].kind == .plain);
    try testing.expect(messages[1].style == .dotted and messages[1].kind == .plain);
    try testing.expect(messages[2].style == .solid and messages[2].kind == .arrow);
    try testing.expect(messages[3].style == .dotted and messages[3].kind == .arrow);
    try testing.expect(messages[4].style == .solid and messages[4].kind == .cross);
    try testing.expect(messages[5].style == .dotted and messages[5].kind == .cross);
    try testing.expectEqualStrings("open", messages[6].text);
    try testing.expect(messages[6].style == .solid and messages[6].kind == .open);
    try testing.expect(messages[7].style == .dotted and messages[7].kind == .open);
    try testing.expectEqualStrings("", messages[8].text);
    try testing.expectEqual(@as(usize, 0), messages[0].pos);
    try testing.expectEqual(@as(usize, 8), messages[8].pos);
}

test "sequence message text splits on first colon" {
    const seq = parseSequenceBlockText("sequenceDiagram\nA->>B: see http://x\n").?;
    try testing.expectEqualStrings("see http://x", seq.messages[0].text);
}

test "sequence notes" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "Note over A,B: span\n" ++
            "Note over A: single\n" ++
            "Note left of A: to the left\n" ++
            "Note right of B: to the right\n",
    ).?;
    try testing.expectEqual(@as(usize, 4), seq.note_count);
    try testing.expect(seq.notes[0].kind == .over);
    try testing.expectEqualStrings("B", seq.notes[0].b.?);
    try testing.expect(seq.notes[1].b == null);
    try testing.expect(seq.notes[2].kind == .left);
    try testing.expect(seq.notes[3].kind == .right);
    try testing.expectEqualStrings("to the right", seq.notes[3].text);
    try testing.expectEqual(@as(usize, 2), seq.participant_count);
}

test "sequence fragments" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "loop Every minute\n" ++
            "A->>B: ping\n" ++
            "alt ok\n" ++
            "B->>A: pong\n" ++
            "else bad\n" ++
            "B->>A: silence\n" ++
            "end\n" ++
            "opt maybe\n" ++
            "A->>B: again\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.fragment_count);
    try testing.expect(seq.fragments[0].op == .loop);
    try testing.expectEqualStrings("Every minute", seq.fragments[0].label);
    try testing.expectEqual(@as(usize, 0), seq.fragments[0].start);
    try testing.expectEqual(@as(usize, 4), seq.fragments[0].end);
    try testing.expectEqual(@as(usize, 0), seq.fragments[0].depth);
    try testing.expect(seq.fragments[1].op == .alt);
    try testing.expectEqual(@as(usize, 1), seq.fragments[1].start);
    try testing.expectEqual(@as(usize, 1), seq.fragments[1].div_count);
    try testing.expectEqual(@as(usize, 2), seq.fragments[1].divs[0].pos);
    try testing.expectEqualStrings("else", seq.fragments[1].divs[0].head);
    try testing.expectEqualStrings("bad", seq.fragments[1].divs[0].text);
    try testing.expectEqual(@as(usize, 3), seq.fragments[1].end);
    try testing.expectEqual(@as(usize, 1), seq.fragments[1].depth);
    try testing.expect(seq.fragments[2].op == .opt);
    try testing.expectEqual(@as(usize, 3), seq.fragments[2].start);
    try testing.expectEqual(@as(usize, 4), seq.fragments[2].end);
}

test "sequence stray and opaque blocks" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "end\n" ++
            "rect one\n" ++
            "A->>B: inside\n" ++
            "end\n" ++
            "A->>B: outside\n",
    ).?;
    try testing.expectEqual(@as(usize, 1), seq.fragment_count);
    try testing.expect(seq.fragments[0].op == .@"opaque");
    try testing.expectEqual(@as(usize, 0), seq.fragments[0].start);
    try testing.expectEqual(@as(usize, 1), seq.fragments[0].end);
    try testing.expectEqual(@as(usize, 2), seq.message_count);
}

test "par blocks are real fragments" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "par one\n" ++
            "A->>B: inside\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 1), seq.fragment_count);
    try testing.expect(seq.fragments[0].op == .par);
    try testing.expectEqualStrings("one", seq.fragments[0].label);
    try testing.expectEqual(@as(usize, 0), seq.fragments[0].start);
    try testing.expectEqual(@as(usize, 1), seq.fragments[0].end);
}

test "sequence activations" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "activate A\n" ++
            "A->>+B: hello\n" ++
            "B-->>-A: hi\n" ++
            "deactivate A\n" ++
            "A->>B: later\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.activation_count);
    try testing.expectEqualStrings("B", seq.activations[0].actor);
    try testing.expectEqual(@as(usize, 0), seq.activations[0].start);
    try testing.expectEqual(@as(usize, 2), seq.activations[0].end);
    try testing.expectEqualStrings("A", seq.activations[1].actor);
    try testing.expectEqual(@as(usize, 0), seq.activations[1].start);
    try testing.expectEqual(@as(usize, 2), seq.activations[1].end);
    try testing.expect(!seq.degraded);
}

test "sequence autonumber flag" {
    const seq = parseSequenceBlockText("sequenceDiagram\nautonumber\nA->>B: x\n").?;
    try testing.expect(seq.autonumber);
    const plain = parseSequenceBlockText("sequenceDiagram\nA->>B: x\n").?;
    try testing.expect(!plain.autonumber);
}

test "sequence over-cap degrades" {
    const many = parseSequenceBlockText("sequenceDiagram\n" ++ ("A->>B: x\n" ** 200)).?;
    try testing.expect(many.degraded);
    var deep: [512]u8 = undefined;
    @memcpy(deep[0..16], "sequenceDiagram\n");
    var pos: usize = 16;
    for (0..12) |_| {
        @memcpy(deep[pos..][0..7], "loop x\n");
        pos += 7;
    }
    const nested = parseSequenceBlockText(deep[0..pos]).?;
    try testing.expect(nested.degraded);
}

test "sequence rejects non-sequences" {
    try testing.expect(parseSequenceBlockText("graph TD\nA-->B\n") == null);
    try testing.expect(parseSequenceBlockText("just text\n") == null);
    try testing.expect(parseSequenceBlockText("") == null);
    var doc = Document.init("```mermaid\nsequenceDiagram\nA->>B: x\n```\n");
    const seq = parseSequenceBlock(doc.next().?.code_block).?;
    try testing.expectEqual(@as(usize, 1), seq.message_count);
    var zig = Document.init("```zig\nsequenceDiagram\n```\n");
    try testing.expect(parseSequenceBlock(zig.next().?.code_block) == null);
}

test "six message conversation" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "    Alice ->> Bob: Hello Bob, how are you?\n" ++
            "    Bob-->>John: How about you John?\n" ++
            "    Bob--x Alice: I am good thanks!\n" ++
            "    Bob-x John: I am good thanks!\n" ++
            "    Bob-->Alice: Checking with John...\n" ++
            "    Alice->John: Yes... John, how are you?\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.participant_count);
    try testing.expectEqualStrings("Alice", seq.participants[0].id);
    try testing.expectEqualStrings("Bob", seq.participants[1].id);
    try testing.expectEqualStrings("John", seq.participants[2].id);
    try testing.expectEqual(@as(usize, 6), seq.message_count);
    try testing.expect(seq.messages[0].kind == .arrow);
    try testing.expect(seq.messages[2].kind == .cross);
    try testing.expect(seq.messages[3].kind == .cross);
    try testing.expectEqualStrings("Yes... John, how are you?", seq.messages[5].text);
}

test "sequence slices point into the input" {
    const text = "sequenceDiagram\nA->>B: hello\n";
    const seq = parseSequenceBlockText(text).?;
    try testing.expect(within(text, seq.messages[0].text));
    try testing.expect(within(text, seq.messages[0].src));
}

fn within(text: []const u8, slice: []const u8) bool {
    const start = @intFromPtr(text.ptr);
    const end = start + text.len;
    const s = @intFromPtr(slice.ptr);
    return s >= start and s + slice.len <= end;
}

const testing = std.testing;
