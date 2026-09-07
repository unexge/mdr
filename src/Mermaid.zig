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
    var rest = text;
    while (rest.len > 0) {
        const nl = mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        parser.feed(rest[0..nl]);
        rest = if (nl < rest.len) rest[nl + 1 ..] else "";
    }
    if (!parser.seen_header) return null;
    return parser.flow;
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

fn within(text: []const u8, slice: []const u8) bool {
    const start = @intFromPtr(text.ptr);
    const end = start + text.len;
    const s = @intFromPtr(slice.ptr);
    return s >= start and s + slice.len <= end;
}

const testing = std.testing;
