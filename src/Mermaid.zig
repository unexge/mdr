//! Zero-copy Mermaid flowchart and sequence diagram parsers.
//!
//! parseBlock borrows a fenced code block; every slice in the returned
//! Flowchart points into the block content. There is no allocation. Unsupported
//! syntax returns null, while over-cap input sets degraded, so callers can fall
//! back to the code card.

pub const max_nodes = 64;
pub const max_edges = 128;
pub const max_subgraphs = 16;
pub const max_subgraph_depth = 8;

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
    cylinder,
    asymmetric,
    trapezoid,
    double_circle,
};

pub const EdgeStyle = enum { solid, dotted, thick, invisible };
pub const EdgeMarker = enum { none, arrow, circle, cross };

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape,
    subgraph: ?usize = null,
    order: usize = 0,
};

pub const Subgraph = struct {
    id: []const u8,
    label: []const u8,
    parent: ?usize,
    level: usize,
    order: usize,
    direction: ?Direction = null,
};

pub const Edge = struct {
    id: ?[]const u8,
    src: []const u8,
    dst: []const u8,
    label: ?[]const u8,
    style: EdgeStyle,
    src_marker: EdgeMarker,
    dst_marker: EdgeMarker,
    min_length: usize,
};

pub const Flowchart = struct {
    direction: Direction = .tb,
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    edges: [max_edges]Edge = undefined,
    edge_count: usize = 0,
    subgraphs: [max_subgraphs]Subgraph = undefined,
    subgraph_count: usize = 0,
    degraded: bool = false,

    pub fn nodeList(self: *const Flowchart) []const Node {
        return self.nodes[0..self.node_count];
    }

    pub fn edgeList(self: *const Flowchart) []const Edge {
        return self.edges[0..self.edge_count];
    }

    pub fn subgraphList(self: *const Flowchart) []const Subgraph {
        return self.subgraphs[0..self.subgraph_count];
    }

    pub fn subgraphIndex(self: *const Flowchart, id: []const u8) ?usize {
        for (self.subgraphList(), 0..) |subgraph, index| {
            if (mem.eql(u8, subgraph.id, id)) return index;
        }
        return null;
    }

    pub fn needsHierarchicalLayout(self: *const Flowchart) bool {
        for (self.subgraphList()) |subgraph| {
            if (subgraph.direction) |direction| {
                if (direction != self.direction) return true;
            }
        }
        for (self.edgeList()) |edge| {
            if (self.subgraphIndex(edge.src) != null or self.subgraphIndex(edge.dst) != null) return true;
        }
        return false;
    }

    pub fn nodeInSubgraph(self: *const Flowchart, node: *const Node, subgraph: usize) bool {
        var current = node.subgraph;
        while (current) |index| {
            if (index == subgraph) return true;
            current = self.subgraphs[index].parent;
        }
        return false;
    }
};

pub fn parseBlock(cb: Document.Element.CodeBlock) ?Flowchart {
    const info = cb.info orelse return null;
    if (!info.isMermaid()) return null;
    var parser: Parser = .{};
    var lines = cb.lines();
    while (lines.next()) |line| parser.feed(line);
    if (!parser.seen_header or !parser.supported) return null;
    parser.finish();
    if (!parser.supported) return null;
    return parser.flow;
}

pub fn parseText(text: []const u8) ?Flowchart {
    var parser: Parser = .{};
    feedLines(&parser, text);
    if (!parser.seen_header or !parser.supported) return null;
    parser.finish();
    if (!parser.supported) return null;
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

fn isComment(line: []const u8) bool {
    return mem.startsWith(u8, line, "%%") and !mem.startsWith(u8, line, "%%{");
}

const Parser = struct {
    flow: Flowchart = .{},
    seen_header: bool = false,
    supported: bool = true,
    subgraph_stack: [max_subgraph_depth]usize = undefined,
    subgraph_stack_len: usize = 0,
    next_order: usize = 0,

    fn feed(self: *Parser, raw: []const u8) void {
        const trimmed = mem.trim(u8, raw, " \t\r");
        if (isComment(trimmed)) {
            self.feedStatement(trimmed);
            return;
        }
        var start: usize = 0;
        var depth: usize = 0;
        var quoted = false;
        var piped = false;
        var i: usize = 0;
        while (i <= raw.len) : (i += 1) {
            const at_end = i == raw.len;
            if (!at_end) {
                switch (raw[i]) {
                    '"' => quoted = !quoted,
                    '[', '(', '{' => if (!quoted) {
                        depth += 1;
                    },
                    ']', ')', '}' => if (!quoted) {
                        depth -|= 1;
                    },
                    '|' => if (!quoted and depth == 0) {
                        piped = !piped;
                    },
                    else => {},
                }
            }
            if (!at_end and (raw[i] != ';' or quoted or piped or depth > 0)) continue;
            self.feedStatement(raw[start..i]);
            if (!self.supported or self.flow.degraded) return;
            start = i + 1;
        }
    }

    fn feedStatement(self: *Parser, raw: []const u8) void {
        if (!self.supported or self.flow.degraded) return;
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or isComment(line)) return;
        if (!self.seen_header) {
            self.flow.direction = parseHeader(line) orelse {
                self.supported = false;
                return;
            };
            self.seen_header = true;
            return;
        }
        if (isKeywordLine(line, "subgraph")) {
            self.openSubgraph(line["subgraph".len..]);
            return;
        }
        if (isKeywordLine(line, "end")) {
            if (mem.trim(u8, line["end".len..], " \t\r").len > 0 or self.subgraph_stack_len == 0) {
                self.supported = false;
            } else {
                self.subgraph_stack_len -= 1;
            }
            return;
        }
        if (isKeywordLine(line, "direction")) {
            self.setSubgraphDirection(line["direction".len..]);
            return;
        }
        for ([_][]const u8{ "style", "classDef", "class", "linkStyle" }) |keyword| {
            if (isKeywordLine(line, keyword)) return;
        }
        if (isKeywordLine(line, "click")) {
            self.supported = false;
            return;
        }
        if (!self.feedBody(line)) self.supported = false;
    }

    fn finish(self: *Parser) void {
        if (self.flow.degraded) return;
        if (self.subgraph_stack_len > 0) {
            self.supported = false;
            return;
        }
        for (self.flow.subgraphList(), 0..) |_, index| {
            var has_node = false;
            for (self.flow.nodeList()) |*node| {
                if (self.flow.nodeInSubgraph(node, index)) {
                    has_node = true;
                    break;
                }
            }
            if (!has_node) {
                self.supported = false;
                return;
            }
        }
    }

    fn openSubgraph(self: *Parser, raw: []const u8) void {
        if (self.flow.subgraph_count >= max_subgraphs or self.subgraph_stack_len >= self.subgraph_stack.len) {
            self.flow.degraded = true;
            return;
        }
        const declaration = parseSubgraphDeclaration(raw) orelse {
            self.supported = false;
            return;
        };
        if (self.flow.subgraphIndex(declaration.id) != null) {
            self.supported = false;
            return;
        }
        var recovered_order: ?usize = null;
        var node_index: usize = 0;
        while (node_index < self.flow.node_count) : (node_index += 1) {
            const node = self.flow.nodes[node_index];
            if (!mem.eql(u8, node.id, declaration.id)) continue;
            if (node.shape != .rect or node.label.ptr != node.id.ptr or node.label.len != node.id.len) {
                self.supported = false;
                return;
            }
            recovered_order = node.order;
            var shift = node_index;
            while (shift + 1 < self.flow.node_count) : (shift += 1) self.flow.nodes[shift] = self.flow.nodes[shift + 1];
            self.flow.node_count -= 1;
            break;
        }
        const index = self.flow.subgraph_count;
        self.flow.subgraphs[index] = .{
            .id = declaration.id,
            .label = declaration.label,
            .parent = self.currentSubgraph(),
            .level = self.subgraph_stack_len,
            .order = recovered_order orelse self.next_order,
        };
        if (recovered_order == null) self.next_order += 1;
        self.flow.subgraph_count += 1;
        self.subgraph_stack[self.subgraph_stack_len] = index;
        self.subgraph_stack_len += 1;
    }

    fn setSubgraphDirection(self: *Parser, raw: []const u8) void {
        const index = self.currentSubgraph() orelse {
            self.supported = false;
            return;
        };
        self.flow.subgraphs[index].direction = parseDirection(mem.trim(u8, raw, " \t\r")) orelse {
            self.supported = false;
            return;
        };
    }

    fn currentSubgraph(self: *const Parser) ?usize {
        if (self.subgraph_stack_len == 0) return null;
        return self.subgraph_stack[self.subgraph_stack_len - 1];
    }

    fn feedBody(self: *Parser, line: []const u8) bool {
        if (self.flow.degraded) return true;
        var previous: [max_nodes][]const u8 = undefined;
        var previous_count: usize = 0;
        var pos: usize = 0;
        var pending: ?Op = null;
        while (pos <= line.len) {
            const found = findOp(line, pos);
            const end = if (found) |f| f.at else line.len;
            var current: [max_nodes][]const u8 = undefined;
            const current_count = self.parseGroup(line[pos..end], &current) orelse return false;
            if (self.flow.degraded) return true;
            if (pending) |op| {
                for (previous[0..previous_count]) |src| {
                    for (current[0..current_count]) |dst| self.addEdge(src, dst, op);
                }
                if (self.flow.degraded) return true;
            }
            const f = found orelse return true;
            @memcpy(previous[0..current_count], current[0..current_count]);
            previous_count = current_count;
            pending = f.op;
            pos = f.after;
        }
        return true;
    }

    fn parseGroup(self: *Parser, raw: []const u8, ids: *[max_nodes][]const u8) ?usize {
        var count: usize = 0;
        var start: usize = 0;
        var depth: usize = 0;
        var quoted = false;
        var i: usize = 0;
        while (i <= raw.len) : (i += 1) {
            const at_end = i == raw.len;
            if (!at_end) {
                switch (raw[i]) {
                    '"' => quoted = !quoted,
                    '[', '(', '{' => if (!quoted) {
                        depth += 1;
                    },
                    ']', ')', '}' => if (!quoted) {
                        depth -|= 1;
                    },
                    else => {},
                }
            }
            if (!at_end and (raw[i] != '&' or quoted or depth > 0)) continue;
            if (count >= ids.len) {
                self.flow.degraded = true;
                return 0;
            }
            const node = parseNode(mem.trim(u8, raw[start..i], " \t\r")) orelse return null;
            ids[count] = self.intern(node) orelse return 0;
            count += 1;
            start = i + 1;
        }
        return if (count > 0) count else null;
    }

    fn intern(self: *Parser, parsed: Node) ?[]const u8 {
        var node = parsed;
        if (self.flow.subgraphIndex(node.id) != null) return node.id;
        const current_subgraph = self.currentSubgraph();
        const explicit = node.shape != .rect or node.label.ptr != node.id.ptr or node.label.len != node.id.len;
        for (self.flow.nodes[0..self.flow.node_count]) |*existing| {
            if (!mem.eql(u8, existing.id, node.id)) continue;
            const subgraph = if (explicit and current_subgraph != null)
                current_subgraph
            else
                existing.subgraph orelse current_subgraph;
            if (explicit) {
                const order = existing.order;
                existing.* = node;
                existing.order = order;
            }
            existing.subgraph = subgraph;
            return existing.id;
        }
        if (self.flow.node_count >= max_nodes) {
            self.flow.degraded = true;
            return null;
        }
        node.subgraph = current_subgraph;
        node.order = self.next_order;
        self.next_order += 1;
        self.flow.nodes[self.flow.node_count] = node;
        self.flow.node_count += 1;
        return node.id;
    }

    fn addEdge(self: *Parser, src: []const u8, dst: []const u8, op: Op) void {
        if (self.flow.degraded) return;
        if (op.min_length >= max_nodes) {
            self.flow.degraded = true;
            return;
        }
        if (self.flow.edge_count >= max_edges) {
            self.flow.degraded = true;
            return;
        }
        if (op.id) |id| {
            for (self.flow.edgeList()) |edge| {
                if (edge.id) |existing| {
                    if (mem.eql(u8, id, existing)) {
                        self.supported = false;
                        return;
                    }
                }
            }
        }
        self.flow.edges[self.flow.edge_count] = .{
            .id = op.id,
            .src = src,
            .dst = dst,
            .label = op.label,
            .style = op.style,
            .src_marker = op.src_marker,
            .dst_marker = op.dst_marker,
            .min_length = op.min_length,
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
    const direction = parseDirection(dir) orelse return null;
    const tail = mem.trim(u8, rest[end..], " \t\r");
    if (tail.len > 0 and !mem.eql(u8, tail, ";")) return null;
    return direction;
}

fn parseDirection(raw: []const u8) ?Direction {
    if (eqlIgnoreCase(raw, "TD") or eqlIgnoreCase(raw, "TB")) return .tb;
    if (eqlIgnoreCase(raw, "BT")) return .bt;
    if (eqlIgnoreCase(raw, "LR")) return .lr;
    if (eqlIgnoreCase(raw, "RL")) return .rl;
    return null;
}

fn isKeywordLine(line: []const u8, keyword: []const u8) bool {
    if (!mem.startsWith(u8, line, keyword)) return false;
    if (line.len == keyword.len) return true;
    const c = line[keyword.len];
    return c == ' ' or c == '\t';
}

const SubgraphDeclaration = struct {
    id: []const u8,
    label: []const u8,
};

fn parseSubgraphDeclaration(raw: []const u8) ?SubgraphDeclaration {
    const declaration = mem.trim(u8, raw, " \t\r");
    if (declaration.len == 0) return null;
    var id_end: usize = 0;
    while (id_end < declaration.len and isFlowIdChar(declaration[id_end])) : (id_end += 1) {}
    if (id_end > 0) {
        const tail = mem.trim(u8, declaration[id_end..], " \t\r");
        if (tail.len >= 2 and tail[0] == '[' and tail[tail.len - 1] == ']') {
            const label = normalizeLabel(metadataValue(tail[1 .. tail.len - 1]) orelse return null);
            return .{ .id = declaration[0..id_end], .label = label };
        }
        if (tail.len > 0 and (tail[0] == '[' or tail[tail.len - 1] == ']')) return null;
    }
    const label = normalizeLabel(metadataValue(declaration) orelse return null);
    return .{ .id = label, .label = label };
}

fn stripNodeClass(seg: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i + 2 < seg.len) : (i += 1) {
        switch (seg[i]) {
            '"' => quoted = !quoted,
            '[', '(', '{' => if (!quoted) {
                depth += 1;
            },
            ']', ')', '}' => if (!quoted) {
                depth -|= 1;
            },
            else => {},
        }
        if (!quoted and depth == 0 and mem.eql(u8, seg[i .. i + 3], ":::")) {
            const class = mem.trim(u8, seg[i + 3 ..], " \t\r");
            if (class.len == 0) return null;
            for (class) |char| {
                if (!isIdChar(char) and char != '-') return null;
            }
            return mem.trim(u8, seg[0..i], " \t\r");
        }
    }
    return seg;
}

fn parseNode(raw: []const u8) ?Node {
    const seg = stripNodeClass(raw) orelse return null;
    if (seg.len == 0) return null;
    var id_len: usize = 0;
    while (id_len < seg.len and isFlowIdChar(seg[id_len])) : (id_len += 1) {}
    if (id_len == 0) return null;
    const id = seg[0..id_len];
    const rest = mem.trim(u8, seg[id_len..], " \t\r");
    if (rest.len == 0) return .{ .id = id, .label = id, .shape = .rect };
    if (mem.startsWith(u8, rest, "@{")) return parseNodeMetadata(id, rest);
    if (rest.len >= 6 and mem.startsWith(u8, rest, "(((") and mem.endsWith(u8, rest, ")))"))
        return shaped(id, rest[3 .. rest.len - 3], .double_circle);
    if (rest.len >= 4) {
        if (mem.startsWith(u8, rest, "((") and mem.endsWith(u8, rest, "))"))
            return shaped(id, rest[2 .. rest.len - 2], .circle);
        if (mem.startsWith(u8, rest, "([") and mem.endsWith(u8, rest, "])"))
            return shaped(id, rest[2 .. rest.len - 2], .stadium);
        if (mem.startsWith(u8, rest, "[[") and mem.endsWith(u8, rest, "]]"))
            return shaped(id, rest[2 .. rest.len - 2], .subroutine);
        if (mem.startsWith(u8, rest, "[(") and mem.endsWith(u8, rest, ")]"))
            return shaped(id, rest[2 .. rest.len - 2], .cylinder);
        if (mem.startsWith(u8, rest, "{{") and mem.endsWith(u8, rest, "}}"))
            return shaped(id, rest[2 .. rest.len - 2], .hexagon);
    }
    if (rest[0] == '(' and mem.endsWith(u8, rest, ")"))
        return shaped(id, rest[1 .. rest.len - 1], .rounded);
    if (rest[0] == '[' and mem.endsWith(u8, rest, "]")) {
        const inner = rest[1 .. rest.len - 1];
        if (inner.len >= 2 and (inner[0] == '/' or inner[0] == '\\') and
            (inner[inner.len - 1] == '/' or inner[inner.len - 1] == '\\'))
        {
            const shape: Shape = if (inner[0] == inner[inner.len - 1]) .parallelogram else .trapezoid;
            return shaped(id, inner[1 .. inner.len - 1], shape);
        }
        return shaped(id, inner, .rect);
    }
    if (rest[0] == '>' and mem.endsWith(u8, rest, "]"))
        return shaped(id, rest[1 .. rest.len - 1], .asymmetric);
    if (rest[0] == '{' and mem.endsWith(u8, rest, "}"))
        return shaped(id, rest[1 .. rest.len - 1], .diamond);
    return null;
}

fn parseNodeMetadata(id: []const u8, raw: []const u8) ?Node {
    if (!mem.endsWith(u8, raw, "}")) return null;
    const body = mem.trim(u8, raw[2 .. raw.len - 1], " \t\r");
    var shape: ?Shape = null;
    var label: ?[]const u8 = null;
    var start: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end and body[i] == '"') quoted = !quoted;
        if (!at_end and (body[i] != ',' or quoted)) continue;
        if (quoted) return null;
        const field = mem.trim(u8, body[start..i], " \t\r");
        const colon = mem.indexOfScalar(u8, field, ':') orelse return null;
        const key = mem.trim(u8, field[0..colon], " \t\r");
        const value = metadataValue(field[colon + 1 ..]) orelse return null;
        if (mem.eql(u8, key, "shape")) {
            shape = parseShapeName(value) orelse return null;
        } else if (mem.eql(u8, key, "label")) {
            label = value;
        } else {
            return null;
        }
        start = i + 1;
    }
    const node_shape = shape orelse return null;
    const node_label = normalizeLabel(label orelse id);
    return .{ .id = id, .label = if (node_label.len == 0) id else node_label, .shape = node_shape };
}

fn metadataValue(raw: []const u8) ?[]const u8 {
    const value = mem.trim(u8, raw, " \t\r");
    if (value.len == 0) return null;
    if (value[0] != '"') return value;
    if (value.len < 2 or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

fn parseShapeName(name: []const u8) ?Shape {
    const shapes = [_]struct { name: []const u8, shape: Shape }{
        .{ .name = "rect", .shape = .rect },
        .{ .name = "rounded", .shape = .rounded },
        .{ .name = "stadium", .shape = .stadium },
        .{ .name = "subproc", .shape = .subroutine },
        .{ .name = "subroutine", .shape = .subroutine },
        .{ .name = "cyl", .shape = .cylinder },
        .{ .name = "cylinder", .shape = .cylinder },
        .{ .name = "circle", .shape = .circle },
        .{ .name = "odd", .shape = .asymmetric },
        .{ .name = "diamond", .shape = .diamond },
        .{ .name = "diam", .shape = .diamond },
        .{ .name = "hex", .shape = .hexagon },
        .{ .name = "hexagon", .shape = .hexagon },
        .{ .name = "lean-r", .shape = .parallelogram },
        .{ .name = "lean-l", .shape = .parallelogram },
        .{ .name = "trap-b", .shape = .trapezoid },
        .{ .name = "trap-t", .shape = .trapezoid },
        .{ .name = "dbl-circ", .shape = .double_circle },
        .{ .name = "datastore", .shape = .rect },
        .{ .name = "text", .shape = .rect },
        .{ .name = "notch-rect", .shape = .rect },
        .{ .name = "lin-rect", .shape = .rect },
        .{ .name = "sm-circ", .shape = .circle },
        .{ .name = "framed-circle", .shape = .double_circle },
        .{ .name = "fork", .shape = .rect },
        .{ .name = "hourglass", .shape = .diamond },
        .{ .name = "comment", .shape = .rect },
        .{ .name = "brace-r", .shape = .rect },
        .{ .name = "braces", .shape = .rect },
        .{ .name = "bolt", .shape = .rect },
        .{ .name = "doc", .shape = .rect },
        .{ .name = "delay", .shape = .rounded },
        .{ .name = "das", .shape = .cylinder },
        .{ .name = "lin-cyl", .shape = .cylinder },
        .{ .name = "curv-trap", .shape = .trapezoid },
        .{ .name = "div-rect", .shape = .rect },
        .{ .name = "tri", .shape = .diamond },
        .{ .name = "win-pane", .shape = .rect },
        .{ .name = "f-circ", .shape = .circle },
        .{ .name = "lin-doc", .shape = .rect },
        .{ .name = "notch-pent", .shape = .hexagon },
        .{ .name = "flip-tri", .shape = .diamond },
        .{ .name = "sl-rect", .shape = .parallelogram },
        .{ .name = "docs", .shape = .rect },
        .{ .name = "processes", .shape = .rect },
        .{ .name = "procs", .shape = .rect },
        .{ .name = "flag", .shape = .rect },
        .{ .name = "bow-rect", .shape = .rect },
        .{ .name = "cross-circ", .shape = .circle },
        .{ .name = "tag-doc", .shape = .rect },
        .{ .name = "tag-rect", .shape = .rect },
        .{ .name = "proc", .shape = .rect },
        .{ .name = "process", .shape = .rect },
        .{ .name = "rectangle", .shape = .rect },
        .{ .name = "event", .shape = .rounded },
        .{ .name = "terminal", .shape = .stadium },
        .{ .name = "pill", .shape = .stadium },
        .{ .name = "fr-rect", .shape = .subroutine },
        .{ .name = "subprocess", .shape = .subroutine },
        .{ .name = "framed-rectangle", .shape = .subroutine },
        .{ .name = "db", .shape = .cylinder },
        .{ .name = "database", .shape = .cylinder },
        .{ .name = "data-store", .shape = .rect },
        .{ .name = "folder", .shape = .rect },
        .{ .name = "directory", .shape = .rect },
        .{ .name = "bucket", .shape = .cylinder },
        .{ .name = "console", .shape = .rect },
        .{ .name = "browser", .shape = .rect },
        .{ .name = "person", .shape = .rounded },
        .{ .name = "bang", .shape = .circle },
        .{ .name = "cloud", .shape = .rounded },
        .{ .name = "circ", .shape = .circle },
        .{ .name = "decision", .shape = .diamond },
        .{ .name = "question", .shape = .diamond },
        .{ .name = "prepare", .shape = .hexagon },
        .{ .name = "lean-right", .shape = .parallelogram },
        .{ .name = "in-out", .shape = .parallelogram },
        .{ .name = "lean-left", .shape = .parallelogram },
        .{ .name = "out-in", .shape = .parallelogram },
        .{ .name = "priority", .shape = .trapezoid },
        .{ .name = "trapezoid-bottom", .shape = .trapezoid },
        .{ .name = "trapezoid", .shape = .trapezoid },
        .{ .name = "manual", .shape = .trapezoid },
        .{ .name = "trapezoid-top", .shape = .trapezoid },
        .{ .name = "inv-trapezoid", .shape = .trapezoid },
        .{ .name = "double-circle", .shape = .double_circle },
        .{ .name = "card", .shape = .rect },
        .{ .name = "notched-rectangle", .shape = .rect },
        .{ .name = "lined-rectangle", .shape = .rect },
        .{ .name = "lined-process", .shape = .rect },
        .{ .name = "lin-proc", .shape = .rect },
        .{ .name = "shaded-process", .shape = .rect },
        .{ .name = "start", .shape = .circle },
        .{ .name = "small-circle", .shape = .circle },
        .{ .name = "fr-circ", .shape = .double_circle },
        .{ .name = "stop", .shape = .double_circle },
        .{ .name = "join", .shape = .rect },
        .{ .name = "collate", .shape = .diamond },
        .{ .name = "brace", .shape = .rect },
        .{ .name = "brace-l", .shape = .rect },
        .{ .name = "com-link", .shape = .rect },
        .{ .name = "lightning-bolt", .shape = .rect },
        .{ .name = "document", .shape = .rect },
        .{ .name = "half-rounded-rectangle", .shape = .rounded },
        .{ .name = "h-cyl", .shape = .cylinder },
        .{ .name = "horizontal-cylinder", .shape = .cylinder },
        .{ .name = "disk", .shape = .cylinder },
        .{ .name = "lined-cylinder", .shape = .cylinder },
        .{ .name = "curved-trapezoid", .shape = .trapezoid },
        .{ .name = "display", .shape = .trapezoid },
        .{ .name = "div-proc", .shape = .rect },
        .{ .name = "divided-rectangle", .shape = .rect },
        .{ .name = "divided-process", .shape = .rect },
        .{ .name = "extract", .shape = .diamond },
        .{ .name = "triangle", .shape = .diamond },
        .{ .name = "internal-storage", .shape = .rect },
        .{ .name = "window-pane", .shape = .rect },
        .{ .name = "junction", .shape = .circle },
        .{ .name = "filled-circle", .shape = .circle },
        .{ .name = "loop-limit", .shape = .hexagon },
        .{ .name = "notched-pentagon", .shape = .hexagon },
        .{ .name = "manual-file", .shape = .diamond },
        .{ .name = "flipped-triangle", .shape = .diamond },
        .{ .name = "manual-input", .shape = .parallelogram },
        .{ .name = "sloped-rectangle", .shape = .parallelogram },
        .{ .name = "documents", .shape = .rect },
        .{ .name = "st-doc", .shape = .rect },
        .{ .name = "stacked-document", .shape = .rect },
        .{ .name = "st-rect", .shape = .rect },
        .{ .name = "stacked-rectangle", .shape = .rect },
        .{ .name = "stored-data", .shape = .rect },
        .{ .name = "bow-tie-rectangle", .shape = .rect },
        .{ .name = "summary", .shape = .circle },
        .{ .name = "crossed-circle", .shape = .circle },
        .{ .name = "tagged-document", .shape = .rect },
        .{ .name = "tagged-rectangle", .shape = .rect },
        .{ .name = "tag-proc", .shape = .rect },
        .{ .name = "tagged-process", .shape = .rect },
        .{ .name = "paper-tape", .shape = .rect },
        .{ .name = "lined-document", .shape = .rect },
    };
    for (shapes) |entry| {
        if (mem.eql(u8, name, entry.name)) return entry.shape;
    }
    return null;
}

fn shaped(id: []const u8, raw_label: []const u8, shape: Shape) ?Node {
    const label = normalizeLabel(raw_label);
    return .{ .id = id, .label = if (label.len == 0) id else label, .shape = shape };
}

fn normalizeLabel(raw: []const u8) []const u8 {
    var label = mem.trim(u8, raw, " \t\r");
    if (label.len >= 2 and label[0] == '"' and label[label.len - 1] == '"') label = label[1 .. label.len - 1];
    if (label.len >= 2 and label[0] == '`' and label[label.len - 1] == '`') label = label[1 .. label.len - 1];
    return label;
}

fn isFlowIdChar(c: u8) bool {
    return isIdChar(c) or c == '-';
}

fn isIdChar(c: u8) bool {
    return ascii.isAlphanumeric(c) or c == '_';
}

const Op = struct {
    id: ?[]const u8 = null,
    style: EdgeStyle,
    src_marker: EdgeMarker,
    dst_marker: EdgeMarker,
    min_length: usize = 1,
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
    var quoted = false;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '"' => quoted = !quoted,
            '[', '(', '{' => if (!quoted) {
                depth += 1;
            },
            ']', ')', '}' => if (!quoted) {
                depth -|= 1;
            },
            '-', '=', '<', '~' => if (!quoted and depth == 0) {
                if (matchOp(line, i)) |found| return found;
            },
            'o', 'x' => if (!quoted and depth == 0 and (i == from or line[i - 1] == ' ' or line[i - 1] == '\t')) {
                if (matchOp(line, i)) |found| return found;
            },
            else => {},
        }
    }
    return null;
}

fn matchOp(line: []const u8, i: usize) ?FoundOp {
    const rest = line[i..];
    var found: ?FoundOp = if (matchToken(rest)) |token|
        opAt(line, i, token)
    else if (rest.len <= 2)
        null
    else if (line[i] == '-')
        if (rest[1] == '-' and rest[2] == '|')
            opAt(line, i, .{ .len = 2, .style = .solid, .dst_marker = .arrow })
        else if (rest[1] == '-' or rest[1] == '.')
            spacedOp(line, i)
        else
            null
    else if (line[i] == '=' and rest[1] == '=')
        spacedOp(line, i)
    else
        null;
    if (found) |*operator| attachEdgeId(line, i, operator);
    return found;
}

fn attachEdgeId(line: []const u8, operator_at: usize, found: *FoundOp) void {
    if (operator_at == 0 or line[operator_at - 1] != '@') return;
    const end = operator_at - 1;
    var start = end;
    while (start > 0 and isFlowIdChar(line[start - 1])) start -= 1;
    if (start == end or (start > 0 and line[start - 1] != ' ' and line[start - 1] != '\t')) return;
    found.at = start;
    found.op.id = line[start..end];
}

const Token = struct {
    len: usize,
    style: EdgeStyle,
    src_marker: EdgeMarker = .none,
    dst_marker: EdgeMarker = .none,
    min_length: usize = 1,
};

fn matchToken(rest: []const u8) ?Token {
    if (mem.startsWith(u8, rest, "<-->")) return .{ .len = 4, .style = .solid, .src_marker = .arrow, .dst_marker = .arrow };
    if (mem.startsWith(u8, rest, "o--o")) return .{ .len = 4, .style = .solid, .src_marker = .circle, .dst_marker = .circle };
    if (mem.startsWith(u8, rest, "x--x")) return .{ .len = 4, .style = .solid, .src_marker = .cross, .dst_marker = .cross };
    if (rest.len == 0) return null;
    return switch (rest[0]) {
        '-' => matchDashToken(rest),
        '=' => matchThickToken(rest),
        '~' => matchInvisibleToken(rest),
        else => null,
    };
}

fn matchDashToken(rest: []const u8) ?Token {
    if (rest.len > 2 and rest[1] == '.') {
        var dots: usize = 1;
        while (1 + dots < rest.len and rest[1 + dots] == '.') dots += 1;
        const close = 1 + dots;
        if (close >= rest.len or rest[close] != '-') return null;
        const arrow = close + 1 < rest.len and rest[close + 1] == '>';
        return .{
            .len = close + 1 + @intFromBool(arrow),
            .style = .dotted,
            .dst_marker = if (arrow) .arrow else .none,
            .min_length = dots,
        };
    }
    var count: usize = 0;
    while (count < rest.len and rest[count] == '-') count += 1;
    if (count >= 2 and count < rest.len and rest[count] == '>')
        return .{ .len = count + 1, .style = .solid, .dst_marker = .arrow, .min_length = count - 1 };
    if (count >= 2 and count < rest.len and (rest[count] == 'o' or rest[count] == 'x'))
        return .{
            .len = count + 1,
            .style = .solid,
            .dst_marker = if (rest[count] == 'o') .circle else .cross,
            .min_length = count - 1,
        };
    if (count >= 3) return .{ .len = count, .style = .solid, .min_length = count - 2 };
    return null;
}

fn matchThickToken(rest: []const u8) ?Token {
    var count: usize = 0;
    while (count < rest.len and rest[count] == '=') count += 1;
    if (count >= 2 and count < rest.len and rest[count] == '>')
        return .{ .len = count + 1, .style = .thick, .dst_marker = .arrow, .min_length = count - 1 };
    if (count >= 3) return .{ .len = count, .style = .thick, .min_length = count - 2 };
    return null;
}

fn matchInvisibleToken(rest: []const u8) ?Token {
    var count: usize = 0;
    while (count < rest.len and rest[count] == '~') count += 1;
    if (count < 3) return null;
    return .{ .len = count, .style = .invisible, .min_length = count - 2 };
}

fn spacedOp(line: []const u8, at: usize) ?FoundOp {
    var j = at + 2;
    while (j < line.len) : (j += 1) {
        if (line[j] != '-' and line[j] != '=') continue;
        const rest = line[j..];
        if (matchToken(rest)) |token| return spacedAt(line, at, j, token);
        if (line[j] == '-' and rest.len > 1 and rest[1] == '>' and line[j - 1] == '.') {
            if (mem.trim(u8, line[at + 2 .. j - 1], " \t\r").len == 0) return null;
            return spacedAt(line, at, j - 1, .{ .len = 3, .style = .dotted, .dst_marker = .arrow });
        }
    }
    return null;
}

fn spacedAt(line: []const u8, at: usize, close: usize, token: Token) FoundOp {
    const raw = normalizeLabel(line[at + 2 .. close]);
    var found = opAt(line, close, token);
    found.at = at;
    if (found.op.label == null and raw.len > 0) found.op.label = raw;
    return found;
}

fn opAt(line: []const u8, at: usize, token: Token) FoundOp {
    var after = at + token.len;
    var label: ?[]const u8 = null;
    if (after < line.len and line[after] == '|') {
        if (mem.indexOfScalarPos(u8, line, after + 1, '|')) |close| {
            label = normalizeLabel(line[after + 1 .. close]);
            after = close + 1;
        }
    }
    return .{
        .at = at,
        .after = after,
        .op = .{
            .style = token.style,
            .src_marker = token.src_marker,
            .dst_marker = token.dst_marker,
            .min_length = token.min_length,
            .label = label,
        },
    };
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
pub const max_participant_boxes = 16;

pub const ParticipantKind = enum {
    participant,
    actor,
    boundary,
    control,
    entity,
    database,
    collections,
    queue,
};

pub const Participant = struct {
    id: []const u8,
    label: []const u8,
    kind: ParticipantKind = .participant,
    created_at: ?usize = null,
    destroyed_at: ?usize = null,
};

pub const ParticipantBox = struct {
    label: []const u8,
    first: usize,
    count: usize,
};

pub const MsgStyle = enum { solid, dotted };
pub const MsgEndpoint = enum { none, arrow, cross, open, half_top, half_bottom, stick_top, stick_bottom };
pub const CentralConnection = enum { none, source, destination, both };

pub const Message = struct {
    src: []const u8,
    dst: []const u8,
    style: MsgStyle,
    src_endpoint: MsgEndpoint,
    dst_endpoint: MsgEndpoint,
    central: CentralConnection,
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

pub const FragmentOp = enum { loop, alt, opt, par, critical, @"break", rect };

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
    depth: usize,
};

pub const Autonumber = struct {
    start: u32,
    increment: u32,
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
    participant_boxes: [max_participant_boxes]ParticipantBox = undefined,
    participant_box_count: usize = 0,
    autonumber: ?Autonumber = null,
    degraded: bool = false,
};

pub fn parseSequenceBlockText(text: []const u8) ?Sequence {
    var parser: SeqParser = .{};
    feedLines(&parser, text);
    if (!parser.seen_header or !parser.supported) return null;
    parser.finish();
    if (!parser.supported) return null;
    return parser.seq;
}

pub fn parseSequenceBlock(cb: Document.Element.CodeBlock) ?Sequence {
    const info = cb.info orelse return null;
    if (!info.isMermaid()) return null;
    var parser: SeqParser = .{};
    var lines = cb.lines();
    while (lines.next()) |line| parser.feed(line);
    if (!parser.seen_header or !parser.supported) return null;
    parser.finish();
    if (!parser.supported) return null;
    return parser.seq;
}

const PendingActivation = struct {
    participant: usize,
    start: usize,
    depth: usize,
};

const PendingLifecycle = union(enum) {
    create: usize,
    destroy: usize,
};

const SeqParser = struct {
    seq: Sequence = .{},
    seen_header: bool = false,
    supported: bool = true,
    pos: usize = 0,
    stack: [max_fragment_depth]usize = undefined,
    stack_len: usize = 0,
    pending_activations: [max_activations]PendingActivation = undefined,
    pending_activation_count: usize = 0,
    open_participant_box: ?usize = null,
    pending_lifecycle: ?PendingLifecycle = null,

    fn feed(self: *SeqParser, raw: []const u8) void {
        if (self.seq.degraded or !self.supported) return;
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or isComment(line)) return;
        if (!self.seen_header) {
            if (!mem.eql(u8, line, "sequenceDiagram")) {
                self.supported = false;
                return;
            }
            self.seen_header = true;
            return;
        }
        if (mem.indexOfScalar(u8, line, ';') != null) {
            self.supported = false;
            return;
        }
        if (self.pending_lifecycle != null) {
            const message = parseMessageLine(line) orelse {
                self.supported = false;
                return;
            };
            self.addMessage(message);
            return;
        }
        if (self.open_participant_box != null) {
            if (parseParticipantLine(line)) |participant| {
                const before = self.seq.participant_count;
                _ = self.addParticipant(participant) orelse return;
                if (self.seq.participant_count == before) self.supported = false;
            } else if (stripKeyword(line, "end")) |tail| {
                if (tail.len > 0) self.supported = false else self.closeParticipantBox();
            } else {
                self.supported = false;
            }
            return;
        }
        if (self.feedLifecycle(line)) return;
        if (parseParticipantLine(line)) |participant| {
            _ = self.addParticipant(participant);
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
        self.supported = false;
    }

    fn finish(self: *SeqParser) void {
        if (self.seq.degraded) return;
        if (self.pending_lifecycle != null or self.open_participant_box != null or self.stack_len > 0) {
            self.supported = false;
            return;
        }
        for (self.pending_activations[0..self.pending_activation_count]) |pending| {
            self.appendActivation(pending, self.pos);
            if (self.seq.degraded) return;
        }
        self.pending_activation_count = 0;
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

    fn addParticipant(self: *SeqParser, parsed: ParsedParticipant) ?usize {
        for (self.seq.participants[0..self.seq.participant_count], 0..) |*participant, index| {
            if (!mem.eql(u8, participant.id, parsed.id)) continue;
            if (parsed.label_explicit) participant.label = parsed.label;
            if (parsed.kind_explicit) participant.kind = parsed.kind;
            return index;
        }
        if (self.seq.participant_count >= max_participants) {
            self.seq.degraded = true;
            return null;
        }
        const index = self.seq.participant_count;
        self.seq.participants[index] = .{ .id = parsed.id, .label = parsed.label, .kind = parsed.kind };
        self.seq.participant_count += 1;
        return index;
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
        if (m.central != .none and mem.eql(u8, m.src, m.dst)) {
            self.supported = false;
            return;
        }
        const s = self.intern(m.src) orelse return;
        const d = self.intern(m.dst) orelse return;
        if (self.seq.participants[s].destroyed_at != null or self.seq.participants[d].destroyed_at != null) {
            self.supported = false;
            return;
        }
        if (self.pending_lifecycle) |pending| {
            switch (pending) {
                .create => |participant| if (d != participant) {
                    self.supported = false;
                    return;
                },
                .destroy => |participant| if (s != participant and d != participant) {
                    self.supported = false;
                    return;
                },
            }
        }
        if (self.seq.message_count >= max_messages) {
            self.seq.degraded = true;
            return;
        }
        self.seq.messages[self.seq.message_count] = .{
            .src = m.src,
            .dst = m.dst,
            .style = m.style,
            .src_endpoint = m.src_endpoint,
            .dst_endpoint = m.dst_endpoint,
            .central = m.central,
            .text = m.text,
            .pos = self.pos,
        };
        self.seq.message_count += 1;
        if (self.pending_lifecycle) |pending| {
            switch (pending) {
                .create => |participant| self.seq.participants[participant].created_at = self.pos,
                .destroy => |participant| {
                    self.seq.participants[participant].destroyed_at = self.pos;
                    self.endAllActivations(participant, self.pos + 1);
                },
            }
            self.pending_lifecycle = null;
        }
        self.pos += 1;
        if (m.plus) self.startActivation(d, self.pos - 1);
        if (m.minus) self.endActivation(s, self.pos);
    }

    fn feedLifecycle(self: *SeqParser, line: []const u8) bool {
        if (stripKeyword(line, "create")) |declaration| {
            if (self.stack_len > 0) {
                self.supported = false;
                return true;
            }
            const participant = parseParticipantLine(declaration) orelse {
                self.supported = false;
                return true;
            };
            if (self.findParticipant(participant.id) != null) {
                self.supported = false;
                return true;
            }
            const index = self.addParticipant(participant) orelse return true;
            self.pending_lifecycle = .{ .create = index };
            return true;
        }
        if (stripKeyword(line, "destroy")) |raw_id| {
            if (self.stack_len > 0) {
                self.supported = false;
                return true;
            }
            const id = parseId(raw_id) orelse {
                self.supported = false;
                return true;
            };
            const index = self.findParticipant(id) orelse {
                self.supported = false;
                return true;
            };
            if (self.seq.participants[index].destroyed_at != null) {
                self.supported = false;
                return true;
            }
            self.pending_lifecycle = .{ .destroy = index };
            return true;
        }
        return false;
    }

    fn findParticipant(self: *const SeqParser, id: []const u8) ?usize {
        for (self.seq.participants[0..self.seq.participant_count], 0..) |participant, index| {
            if (mem.eql(u8, participant.id, id)) return index;
        }
        return null;
    }

    fn startParticipantBox(self: *SeqParser, descriptor: []const u8) void {
        if (self.seq.participant_box_count >= max_participant_boxes) {
            self.seq.degraded = true;
            return;
        }
        if (self.pos > 0 or self.stack_len > 0) {
            self.supported = false;
            return;
        }
        const label = participantBoxLabel(descriptor) orelse {
            self.supported = false;
            return;
        };
        const index = self.seq.participant_box_count;
        self.seq.participant_boxes[index] = .{
            .label = label,
            .first = self.seq.participant_count,
            .count = 0,
        };
        self.seq.participant_box_count += 1;
        self.open_participant_box = index;
    }

    fn closeParticipantBox(self: *SeqParser) void {
        const index = self.open_participant_box orelse return;
        const box = &self.seq.participant_boxes[index];
        box.count = self.seq.participant_count - box.first;
        if (box.count == 0) self.supported = false;
        self.open_participant_box = null;
    }

    fn startActivation(self: *SeqParser, idx: usize, at: usize) void {
        if (self.seq.activation_count + self.pending_activation_count >= max_activations) {
            self.seq.degraded = true;
            return;
        }
        var depth: usize = 0;
        for (self.pending_activations[0..self.pending_activation_count]) |pending| {
            if (pending.participant == idx) depth += 1;
        }
        self.pending_activations[self.pending_activation_count] = .{
            .participant = idx,
            .start = at,
            .depth = depth,
        };
        self.pending_activation_count += 1;
    }

    fn endActivation(self: *SeqParser, idx: usize, at: usize) void {
        const index = self.pendingActivationIndex(idx) orelse {
            self.supported = false;
            return;
        };
        self.closeActivation(index, at);
    }

    fn endAllActivations(self: *SeqParser, participant: usize, at: usize) void {
        while (self.pendingActivationIndex(participant)) |index| self.closeActivation(index, at);
    }

    fn pendingActivationIndex(self: *const SeqParser, participant: usize) ?usize {
        var i = self.pending_activation_count;
        while (i > 0) {
            i -= 1;
            if (self.pending_activations[i].participant == participant) return i;
        }
        return null;
    }

    fn closeActivation(self: *SeqParser, index: usize, at: usize) void {
        self.appendActivation(self.pending_activations[index], at);
        var shift = index;
        while (shift + 1 < self.pending_activation_count) : (shift += 1) {
            self.pending_activations[shift] = self.pending_activations[shift + 1];
        }
        self.pending_activation_count -= 1;
    }

    fn appendActivation(self: *SeqParser, pending: PendingActivation, end: usize) void {
        if (self.seq.activation_count >= max_activations) {
            self.seq.degraded = true;
            return;
        }
        self.seq.activations[self.seq.activation_count] = .{
            .actor = self.seq.participants[pending.participant].id,
            .start = pending.start,
            .end = end,
            .depth = pending.depth,
        };
        self.seq.activation_count += 1;
    }

    fn feedControl(self: *SeqParser, line: []const u8) bool {
        if (stripKeyword(line, "autonumber")) |options| {
            self.seq.autonumber = parseAutonumber(options) orelse {
                self.supported = false;
                return true;
            };
            return true;
        }
        if (stripKeyword(line, "activate")) |raw_id| {
            const id = parseId(raw_id) orelse {
                self.supported = false;
                return true;
            };
            if (self.intern(id)) |idx| self.startActivation(idx, self.pos);
            return true;
        }
        if (stripKeyword(line, "deactivate")) |raw_id| {
            const id = parseId(raw_id) orelse {
                self.supported = false;
                return true;
            };
            if (self.intern(id)) |idx| self.endActivation(idx, self.pos);
            return true;
        }
        const blocks = [_]struct { kw: []const u8, op: FragmentOp }{
            .{ .kw = "loop", .op = .loop },
            .{ .kw = "alt", .op = .alt },
            .{ .kw = "opt", .op = .opt },
            .{ .kw = "par", .op = .par },
            .{ .kw = "critical", .op = .critical },
            .{ .kw = "break", .op = .@"break" },
            .{ .kw = "rect", .op = .rect },
        };
        for (blocks) |b| {
            if (stripKeyword(line, b.kw)) |label| {
                self.push(b.op, label);
                return true;
            }
        }
        if (stripKeyword(line, "box")) |label| {
            self.startParticipantBox(label);
            return true;
        }
        if (stripKeyword(line, "and")) |label| {
            if (!self.topIs(.par)) self.supported = false else self.div("and", label);
            return true;
        }
        if (stripKeyword(line, "else")) |label| {
            if (!self.topIs(.alt)) self.supported = false else self.div("else", label);
            return true;
        }
        if (stripKeyword(line, "option")) |label| {
            if (!self.topIs(.critical)) self.supported = false else self.div("option", label);
            return true;
        }
        if (stripKeyword(line, "end")) |tail| {
            if (tail.len > 0 or self.stack_len == 0) self.supported = false else self.close();
            return true;
        }
        return false;
    }

    fn topIs(self: *const SeqParser, op: FragmentOp) bool {
        if (self.stack_len == 0) return false;
        return self.seq.fragments[self.stack[self.stack_len - 1]].op == op;
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
        const frag = &self.seq.fragments[self.stack[self.stack_len - 1]];
        if (frag.div_count >= frag.divs.len) {
            self.seq.degraded = true;
            return;
        }
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

fn parseAutonumber(raw: []const u8) ?Autonumber {
    const options = mem.trim(u8, raw, " \t");
    if (options.len == 0) return .{ .start = 100, .increment = 100 };
    var tokens = mem.tokenizeAny(u8, options, " \t");
    const start = parseHundredths(tokens.next() orelse return null) orelse return null;
    const increment = parseHundredths(tokens.next() orelse return null) orelse return null;
    if (tokens.next() != null) return null;
    return .{ .start = start, .increment = increment };
}

fn parseHundredths(raw: []const u8) ?u32 {
    if (raw.len == 0) return null;
    const dot = mem.indexOfScalar(u8, raw, '.');
    const whole_text = if (dot) |index| raw[0..index] else raw;
    const fraction_text = if (dot) |index| raw[index + 1 ..] else "";
    if (whole_text.len == 0 and fraction_text.len == 0) return null;
    if (fraction_text.len > 2 or mem.indexOfScalar(u8, fraction_text, '.') != null) return null;

    var whole: u32 = 0;
    for (whole_text) |digit| {
        if (!ascii.isDigit(digit)) return null;
        const value: u32 = digit - '0';
        if (whole > (std.math.maxInt(u32) - value) / 10) return null;
        whole = whole * 10 + value;
    }
    var fraction: u32 = 0;
    for (fraction_text) |digit| {
        if (!ascii.isDigit(digit)) return null;
        fraction = fraction * 10 + digit - '0';
    }
    if (fraction_text.len == 1) fraction *= 10;
    if (whole > (std.math.maxInt(u32) - fraction) / 100) return null;
    return whole * 100 + fraction;
}

fn parseId(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    for (s) |c| if (!isIdChar(c)) return null;
    return s;
}

const ParsedParticipant = struct {
    id: []const u8,
    label: []const u8,
    label_explicit: bool,
    kind: ParticipantKind,
    kind_explicit: bool,
};

const ParticipantMetadata = struct {
    alias: ?[]const u8 = null,
    kind: ?ParticipantKind = null,
};

fn parseParticipantLine(line: []const u8) ?ParsedParticipant {
    const parsed_keyword: struct { rest: []const u8, kind: ParticipantKind } = if (stripKeyword(line, "participant")) |rest|
        .{ .rest = rest, .kind = ParticipantKind.participant }
    else if (stripKeyword(line, "actor")) |rest|
        .{ .rest = rest, .kind = ParticipantKind.actor }
    else
        return null;
    var i: usize = 0;
    while (i < parsed_keyword.rest.len and isIdChar(parsed_keyword.rest[i])) : (i += 1) {}
    if (i == 0) return null;
    const id = parsed_keyword.rest[0..i];
    var after = mem.trim(u8, parsed_keyword.rest[i..], " \t");
    var label = id;
    var label_explicit = false;
    var kind = parsed_keyword.kind;
    var kind_explicit = kind == .actor;
    if (mem.startsWith(u8, after, "@{")) {
        const close = mem.indexOfScalar(u8, after, '}') orelse return null;
        const metadata = parseParticipantMetadata(after[2..close]) orelse return null;
        if (metadata.alias) |alias| {
            label = alias;
            label_explicit = true;
        }
        if (metadata.kind) |participant_kind| {
            kind = participant_kind;
            kind_explicit = true;
        }
        after = mem.trim(u8, after[close + 1 ..], " \t");
    }
    if (after.len > 0) {
        const external_alias = stripKeyword(after, "as") orelse return null;
        if (external_alias.len == 0) return null;
        label = external_alias;
        label_explicit = true;
    }
    return .{
        .id = id,
        .label = label,
        .label_explicit = label_explicit,
        .kind = kind,
        .kind_explicit = kind_explicit,
    };
}

fn parseParticipantMetadata(body: []const u8) ?ParticipantMetadata {
    var metadata: ParticipantMetadata = .{};
    var start: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end and body[i] == '"') quoted = !quoted;
        if (!at_end and (body[i] != ',' or quoted)) continue;
        if (quoted) return null;
        const field = mem.trim(u8, body[start..i], " \t");
        const colon = mem.indexOfScalar(u8, field, ':') orelse return null;
        const key = metadataValue(field[0..colon]) orelse return null;
        const value = metadataValue(field[colon + 1 ..]) orelse return null;
        if (mem.eql(u8, key, "alias")) {
            if (value.len == 0) return null;
            metadata.alias = value;
        } else if (mem.eql(u8, key, "type")) {
            metadata.kind = parseParticipantKind(value) orelse return null;
        } else {
            return null;
        }
        start = i + 1;
    }
    return metadata;
}

fn participantBoxLabel(raw: []const u8) ?[]const u8 {
    const descriptor = mem.trim(u8, raw, " \t");
    if (descriptor.len == 0) return null;
    for ([_][]const u8{ "rgb(", "rgba(", "hsl(", "hsla(" }) |prefix| {
        if (!mem.startsWith(u8, descriptor, prefix)) continue;
        const close = mem.indexOfScalar(u8, descriptor, ')') orelse return null;
        return mem.trim(u8, descriptor[close + 1 ..], " \t");
    }
    var word_end: usize = 0;
    while (word_end < descriptor.len and descriptor[word_end] != ' ' and descriptor[word_end] != '\t') : (word_end += 1) {}
    const color = descriptor[0..word_end];
    for ([_][]const u8{
        "transparent", "black", "silver", "gray",   "white", "maroon", "red",  "purple", "fuchsia",
        "green",       "lime",  "olive",  "yellow", "navy",  "blue",   "teal", "aqua",   "orange",
    }) |name| {
        if (eqlIgnoreCase(color, name)) return mem.trim(u8, descriptor[word_end..], " \t");
    }
    return descriptor;
}

fn parseParticipantKind(value: []const u8) ?ParticipantKind {
    inline for (std.meta.fields(ParticipantKind)) |field| {
        if (mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
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
    src_endpoint: MsgEndpoint,
    dst_endpoint: MsgEndpoint,
    central: CentralConnection,
    text: []const u8,
    plus: bool,
    minus: bool,
};

const MsgToken = struct {
    style: MsgStyle,
    len: usize,
    src_endpoint: MsgEndpoint = .none,
    dst_endpoint: MsgEndpoint = .none,
};

fn matchMsgToken(rest: []const u8) ?MsgToken {
    if (mem.startsWith(u8, rest, "<<-->>")) return .{ .style = .dotted, .len = 6, .src_endpoint = .arrow, .dst_endpoint = .arrow };
    if (mem.startsWith(u8, rest, "<<->>")) return .{ .style = .solid, .len = 5, .src_endpoint = .arrow, .dst_endpoint = .arrow };

    if (mem.startsWith(u8, rest, "--|\\")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .half_top };
    if (mem.startsWith(u8, rest, "--|/")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .half_bottom };
    if (mem.startsWith(u8, rest, "--\\\\")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .stick_top };
    if (mem.startsWith(u8, rest, "--//")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .stick_bottom };
    if (mem.startsWith(u8, rest, "/|--")) return .{ .style = .dotted, .len = 4, .src_endpoint = .half_top };
    if (mem.startsWith(u8, rest, "\\|--")) return .{ .style = .dotted, .len = 4, .src_endpoint = .half_bottom };
    if (mem.startsWith(u8, rest, "//--")) return .{ .style = .dotted, .len = 4, .src_endpoint = .stick_top };
    if (mem.startsWith(u8, rest, "\\\\--")) return .{ .style = .dotted, .len = 4, .src_endpoint = .stick_bottom };

    if (mem.startsWith(u8, rest, "-|\\")) return .{ .style = .solid, .len = 3, .dst_endpoint = .half_top };
    if (mem.startsWith(u8, rest, "-|/")) return .{ .style = .solid, .len = 3, .dst_endpoint = .half_bottom };
    if (mem.startsWith(u8, rest, "-\\\\")) return .{ .style = .solid, .len = 3, .dst_endpoint = .stick_top };
    if (mem.startsWith(u8, rest, "-//")) return .{ .style = .solid, .len = 3, .dst_endpoint = .stick_bottom };
    if (mem.startsWith(u8, rest, "/|-")) return .{ .style = .solid, .len = 3, .src_endpoint = .half_top };
    if (mem.startsWith(u8, rest, "\\|-")) return .{ .style = .solid, .len = 3, .src_endpoint = .half_bottom };
    if (mem.startsWith(u8, rest, "//-")) return .{ .style = .solid, .len = 3, .src_endpoint = .stick_top };
    if (mem.startsWith(u8, rest, "\\\\-")) return .{ .style = .solid, .len = 3, .src_endpoint = .stick_bottom };

    if (mem.startsWith(u8, rest, "-->>")) return .{ .style = .dotted, .len = 4, .dst_endpoint = .arrow };
    if (mem.startsWith(u8, rest, "->>")) return .{ .style = .solid, .len = 3, .dst_endpoint = .arrow };
    if (mem.startsWith(u8, rest, "-->")) return .{ .style = .dotted, .len = 3 };
    if (mem.startsWith(u8, rest, "->")) return .{ .style = .solid, .len = 2 };
    if (mem.startsWith(u8, rest, "--x")) return .{ .style = .dotted, .len = 3, .dst_endpoint = .cross };
    if (mem.startsWith(u8, rest, "-x")) return .{ .style = .solid, .len = 2, .dst_endpoint = .cross };
    if (mem.startsWith(u8, rest, "--)")) return .{ .style = .dotted, .len = 3, .dst_endpoint = .open };
    if (mem.startsWith(u8, rest, "-)")) return .{ .style = .solid, .len = 2, .dst_endpoint = .open };
    return null;
}

fn parseMessageLine(line: []const u8) ?ParsedMessage {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const arrow = matchMsgToken(line[i..]) orelse continue;
        var raw_src = mem.trim(u8, line[0..i], " \t");
        var source_central = false;
        if (mem.endsWith(u8, raw_src, "()")) {
            source_central = true;
            raw_src = mem.trim(u8, raw_src[0 .. raw_src.len - 2], " \t");
        }
        const src = parseId(raw_src) orelse return null;
        var j = i + arrow.len;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        var destination_central = false;
        if (mem.startsWith(u8, line[j..], "()")) {
            destination_central = true;
            j += 2;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        }
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
        const central: CentralConnection = if (source_central and destination_central)
            .both
        else if (source_central)
            .source
        else if (destination_central)
            .destination
        else
            .none;
        return .{
            .src = src,
            .dst = dst,
            .style = arrow.style,
            .src_endpoint = arrow.src_endpoint,
            .dst_endpoint = arrow.dst_endpoint,
            .central = central,
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

test "additional classic node shapes and quoted labels" {
    const flow = parseText(
        "graph TD\n" ++
            "A[(Database)]\n" ++
            "B>Odd]\n" ++
            "C[/Trapezoid\\]\n" ++
            "D(((Stop)))\n" ++
            "E[\"Quoted label\"]\n",
    ).?;
    const nodes = flow.nodeList();
    try testing.expectEqual(@as(usize, 5), nodes.len);
    try testing.expect(nodes[0].shape == .cylinder);
    try testing.expectEqualStrings("Database", nodes[0].label);
    try testing.expect(nodes[1].shape == .asymmetric);
    try testing.expect(nodes[2].shape == .trapezoid);
    try testing.expect(nodes[3].shape == .double_circle);
    try testing.expectEqualStrings("Stop", nodes[3].label);
    try testing.expectEqualStrings("Quoted label", nodes[4].label);
}

test "node shape metadata" {
    const flow = parseText(
        "graph TD\n" ++
            "A@{ shape: cyl, label: \"Database\" }\n" ++
            "B@{ label: \"Decision, now\", shape: diamond }\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), flow.node_count);
    try testing.expect(flow.nodes[0].shape == .cylinder);
    try testing.expectEqualStrings("Database", flow.nodes[0].label);
    try testing.expect(flow.nodes[1].shape == .diamond);
    try testing.expectEqualStrings("Decision, now", flow.nodes[1].label);
    try testing.expect(parseText("graph TD\nA@{ shape: unknown }\n") == null);
}

test "last explicit node definition wins" {
    const flow = parseText("graph TD\nA[first]\nA\nA[second]\n").?;
    try testing.expectEqual(@as(usize, 1), flow.node_count);
    try testing.expectEqualStrings("second", flow.nodeList()[0].label);
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
    try testing.expect(edges[0].style == .solid and edges[0].dst_marker == .arrow);
    try testing.expect(edges[1].style == .solid and edges[1].dst_marker == .none);
    try testing.expect(edges[2].style == .dotted and edges[2].dst_marker == .arrow);
    try testing.expect(edges[3].style == .thick and edges[3].dst_marker == .arrow);
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
    try testing.expect(edges[0].style == .solid and edges[0].dst_marker == .arrow);
    try testing.expectEqualStrings("plain", edges[1].label.?);
    try testing.expect(edges[1].style == .solid and edges[1].dst_marker == .none);
    try testing.expectEqualStrings("dotted", edges[2].label.?);
    try testing.expect(edges[2].style == .dotted and edges[2].dst_marker == .arrow);
    try testing.expectEqualStrings("thick", edges[3].label.?);
    try testing.expect(edges[3].style == .thick and edges[3].dst_marker == .arrow);
    try testing.expectEqualStrings("one", edges[4].label.?);
    try testing.expectEqualStrings("two", edges[5].label.?);
}

test "multi-node links expand into edges" {
    const flow = parseText(
        "graph TD\n" ++
            "A & B --> C & D\n" ++
            "C --> E & F --> G\n",
    ).?;
    try testing.expectEqual(@as(usize, 7), flow.node_count);
    try testing.expectEqual(@as(usize, 8), flow.edge_count);
    try testing.expectEqualStrings("A", flow.edges[0].src);
    try testing.expectEqualStrings("C", flow.edges[0].dst);
    try testing.expectEqualStrings("D", flow.edges[1].dst);
    try testing.expectEqualStrings("B", flow.edges[2].src);
    try testing.expectEqualStrings("E", flow.edges[6].src);
    try testing.expectEqualStrings("G", flow.edges[7].dst);
}

test "flowchart endpoint markers and invisible links" {
    const flow = parseText(
        "graph LR\n" ++
            "A--oB\n" ++
            "B--xC\n" ++
            "C<-->D\n" ++
            "D o--o E\n" ++
            "E x--x F\n" ++
            "F~~~G\n",
    ).?;
    const edges = flow.edgeList();
    try testing.expectEqual(@as(usize, 6), edges.len);
    try testing.expect(edges[0].dst_marker == .circle);
    try testing.expect(edges[1].dst_marker == .cross);
    try testing.expect(edges[2].src_marker == .arrow and edges[2].dst_marker == .arrow);
    try testing.expect(edges[3].src_marker == .circle and edges[3].dst_marker == .circle);
    try testing.expect(edges[4].src_marker == .cross and edges[4].dst_marker == .cross);
    try testing.expect(edges[5].style == .invisible);

    const suffix = parseText("graph LR\nfoo--oB\nA---oC\n").?;
    try testing.expectEqualStrings("foo", suffix.edges[0].src);
    try testing.expect(suffix.edges[0].src_marker == .none);
    try testing.expect(suffix.edges[0].dst_marker == .circle);
    try testing.expectEqualStrings("A", suffix.edges[1].src);
    try testing.expectEqualStrings("C", suffix.edges[1].dst);
    try testing.expect(suffix.edges[1].dst_marker == .circle);
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
    try testing.expect(seq.messages[3].dst_endpoint == .cross);
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

test "nested flowchart subgraphs" {
    const flow = parseText(
        "graph LR\n" ++
            "subgraph outer [Outer group]\n" ++
            "A-->B\n" ++
            "subgraph inner [\"Inner group\"]\n" ++
            "direction LR\n" ++
            "C-->D\n" ++
            "end\n" ++
            "B-->C\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), flow.subgraph_count);
    try testing.expectEqualStrings("outer", flow.subgraphs[0].id);
    try testing.expectEqualStrings("Outer group", flow.subgraphs[0].label);
    try testing.expect(flow.subgraphs[0].parent == null);
    try testing.expectEqual(@as(?usize, 0), flow.subgraphs[1].parent);
    try testing.expectEqualStrings("Inner group", flow.subgraphs[1].label);
    try testing.expectEqual(@as(?usize, 0), flow.nodes[0].subgraph);
    try testing.expectEqual(@as(?usize, 0), flow.nodes[1].subgraph);
    try testing.expectEqual(@as(?usize, 1), flow.nodes[2].subgraph);
    try testing.expectEqual(@as(?usize, 1), flow.nodes[3].subgraph);
}

test "hierarchical subgraph syntax" {
    const flow = parseText(
        "graph LR\n" ++
            "one-->two\n" ++
            "subgraph one [One]\n" ++
            "direction TB\n" ++
            "A-->B\n" ++
            "end\n" ++
            "subgraph two [Two]\n" ++
            "C-->D\n" ++
            "end\n",
    ).?;
    try testing.expect(flow.needsHierarchicalLayout());
    try testing.expectEqual(@as(usize, 4), flow.node_count);
    try testing.expectEqualStrings("one", flow.edges[0].src);
    try testing.expectEqualStrings("two", flow.edges[0].dst);
}

test "unsupported subgraph semantics are rejected" {
    for ([_][]const u8{
        "graph LR\nsubgraph empty\nend\n",
        "graph LR\nsubgraph open\nA-->B\n",
        "graph LR\nsubgraph bad [label] trailing\nA\nend\n",
    }) |text| {
        try testing.expect(parseText(text) == null);
    }
}

test "flowchart syntax extensions" {
    const flow = parseText(
        "flowchart LR; " ++
            "node-a@{ shape: doc, label: \"Document\" } edge-1@---> node-b[\"`**Done**`\"]:::done; " ++
            "classDef done fill:red; class node-b done; linkStyle 0 stroke:blue; " ++
            "node-b-->|x;y|node-c; node-c-..->node-d\n",
    ).?;
    try testing.expectEqual(@as(usize, 4), flow.node_count);
    try testing.expectEqualStrings("Document", flow.nodes[0].label);
    try testing.expectEqualStrings("**Done**", flow.nodes[1].label);
    try testing.expectEqualStrings("edge-1", flow.edges[0].id.?);
    try testing.expectEqual(@as(usize, 2), flow.edges[0].min_length);
    try testing.expectEqualStrings("x;y", flow.edges[1].label.?);
    try testing.expect(flow.edges[2].style == .dotted);
    try testing.expectEqual(@as(usize, 2), flow.edges[2].min_length);
}

test "flowchart comments are skipped" {
    const flow = parseText("%% a comment; not syntax\ngraph TD\nA-->B\n").?;
    try testing.expectEqual(@as(usize, 2), flow.node_count);
    try testing.expectEqual(@as(usize, 1), flow.edge_count);
}

test "unsupported flowchart statements are rejected" {
    for ([_][]const u8{
        "graph TD\nA-->B\nnot a node !!!\n",
        "graph TD\nA-->B\nclick A callback\n",
        "graph TD\nA edge@-->B\nC edge@-->D\n",
        "%%{init: {'theme': 'dark'}}%%\ngraph TD\nA-->B\n",
    }) |text| {
        try testing.expect(parseText(text) == null);
    }
}

test "over-cap diagrams degrade" {
    const many_edges = parseText("graph TD\n" ++ ("A-->B\n" ** 200)).?;
    try testing.expect(many_edges.degraded);

    const many_group = parseText("graph TD\n" ++ ("A & " ** 64) ++ "A\n").?;
    try testing.expect(many_group.degraded);

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

test "sequence participant stereotypes and aliases" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "participant API@{ \"type\": \"boundary\", \"alias\": \"Internal API\" } as Public API\n" ++
            "actor DB@{ \"type\": \"database\" } as Database\n" ++
            "participant Q@{ \"type\": \"queue\" }\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.participant_count);
    try testing.expect(seq.participants[0].kind == .boundary);
    try testing.expectEqualStrings("Public API", seq.participants[0].label);
    try testing.expect(seq.participants[1].kind == .database);
    try testing.expectEqualStrings("Database", seq.participants[1].label);
    try testing.expect(seq.participants[2].kind == .queue);
}

test "sequence participant boxes" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "box Purple Services\n" ++
            "participant A\n" ++
            "actor B as Bob\n" ++
            "end\n" ++
            "box rgb(10, 20, 30)\n" ++
            "participant C\n" ++
            "end\n" ++
            "A->>C: hello\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.participant_box_count);
    try testing.expectEqualStrings("Services", seq.participant_boxes[0].label);
    try testing.expectEqual(@as(usize, 0), seq.participant_boxes[0].first);
    try testing.expectEqual(@as(usize, 2), seq.participant_boxes[0].count);
    try testing.expectEqualStrings("", seq.participant_boxes[1].label);
    try testing.expectEqual(@as(usize, 2), seq.participant_boxes[1].first);
    try testing.expectEqual(@as(usize, 1), seq.participant_boxes[1].count);
}

test "sequence actor creation and destruction" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "participant A\n" ++
            "create participant B as Bob\n" ++
            "A->>B: hello\n" ++
            "activate B\n" ++
            "destroy B\n" ++
            "B--xA: bye\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.participant_count);
    try testing.expect(seq.participants[0].created_at == null);
    try testing.expectEqual(@as(?usize, 0), seq.participants[1].created_at);
    try testing.expectEqual(@as(?usize, 1), seq.participants[1].destroyed_at);
    try testing.expectEqual(@as(usize, 1), seq.activation_count);
    try testing.expectEqual(@as(usize, 2), seq.activations[0].end);
}

test "unsupported sequence participant state is rejected" {
    for ([_][]const u8{
        "sequenceDiagram\ncreate participant B\nA->>C: wrong\n",
        "sequenceDiagram\ndestroy Missing\nA->>B: wrong\n",
        "sequenceDiagram\nbox Empty\nend\n",
        "sequenceDiagram\nbox Group\nparticipant A\nA->>B: inside\nend\n",
        "sequenceDiagram\nloop x\ncreate participant B\nA->>B: inside\nend\n",
        "sequenceDiagram\nparticipant A\nparticipant B\ndestroy B\nA->>B: bye\nB->>A: after\n",
        "sequenceDiagram\nparticipant A@{ \"type\": \"unknown\" }\n",
    }) |text| {
        try testing.expect(parseSequenceBlockText(text) == null);
    }
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
    try testing.expect(messages[0].style == .solid and messages[0].dst_endpoint == .none);
    try testing.expect(messages[1].style == .dotted and messages[1].dst_endpoint == .none);
    try testing.expect(messages[2].style == .solid and messages[2].dst_endpoint == .arrow);
    try testing.expect(messages[3].style == .dotted and messages[3].dst_endpoint == .arrow);
    try testing.expect(messages[4].style == .solid and messages[4].dst_endpoint == .cross);
    try testing.expect(messages[5].style == .dotted and messages[5].dst_endpoint == .cross);
    try testing.expectEqualStrings("open", messages[6].text);
    try testing.expect(messages[6].style == .solid and messages[6].dst_endpoint == .open);
    try testing.expect(messages[7].style == .dotted and messages[7].dst_endpoint == .open);
    try testing.expectEqualStrings("", messages[8].text);
    try testing.expectEqual(@as(usize, 0), messages[0].pos);
    try testing.expectEqual(@as(usize, 8), messages[8].pos);
}

test "sequence bidirectional arrows" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A<<->>B: solid\n" ++
            "B<<-->>A: dotted\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.message_count);
    try testing.expect(seq.messages[0].src_endpoint == .arrow and seq.messages[0].dst_endpoint == .arrow);
    try testing.expect(seq.messages[0].style == .solid);
    try testing.expect(seq.messages[1].src_endpoint == .arrow and seq.messages[1].dst_endpoint == .arrow);
    try testing.expect(seq.messages[1].style == .dotted);
}

test "sequence half arrows" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A-|\\B\n" ++
            "A-|/B\n" ++
            "A-\\\\B\n" ++
            "A-//B\n" ++
            "A--|\\B\n" ++
            "A--|/B\n" ++
            "A--\\\\B\n" ++
            "A--//B\n" ++
            "B/|-A\n" ++
            "B\\|-A\n" ++
            "B//-A\n" ++
            "B\\\\-A\n" ++
            "B/|--A\n" ++
            "B\\|--A\n" ++
            "B//--A\n" ++
            "B\\\\--A\n",
    ).?;
    try testing.expectEqual(@as(usize, 16), seq.message_count);
    const endpoints = [_]MsgEndpoint{ .half_top, .half_bottom, .stick_top, .stick_bottom };
    for (0..8) |index| {
        const style: MsgStyle = if (index < 4) .solid else .dotted;
        try testing.expect(seq.messages[index].dst_endpoint == endpoints[index % endpoints.len]);
        try testing.expect(seq.messages[index].style == style);
    }
    for (8..16) |index| {
        const style: MsgStyle = if (index < 12) .solid else .dotted;
        try testing.expect(seq.messages[index].src_endpoint == endpoints[index % endpoints.len]);
        try testing.expect(seq.messages[index].style == style);
    }
}

test "sequence central connections" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "A->>()B: destination\n" ++
            "A()->>B: source\n" ++
            "A()->>()B: both\n" ++
            "A()<<-->>()B: bidirectional\n",
    ).?;
    try testing.expect(seq.messages[0].central == .destination);
    try testing.expect(seq.messages[1].central == .source);
    try testing.expect(seq.messages[2].central == .both);
    try testing.expect(seq.messages[3].central == .both);
    try testing.expect(seq.messages[3].src_endpoint == .arrow and seq.messages[3].dst_endpoint == .arrow);
    try testing.expect(parseSequenceBlockText("sequenceDiagram\nA()->>()A: self\n") == null);
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
            "A->>B: again\n" ++
            "end\n" ++
            "end\n",
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

test "critical break and rect sequence fragments" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "critical Connect\n" ++
            "A->>B: try\n" ++
            "option Timeout\n" ++
            "A->>B: retry\n" ++
            "end\n" ++
            "break Failed\n" ++
            "A->>B: stop\n" ++
            "end\n" ++
            "rect rgb(10, 20, 30)\n" ++
            "B->>A: done\n" ++
            "end\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), seq.fragment_count);
    try testing.expect(seq.fragments[0].op == .critical);
    try testing.expectEqual(@as(usize, 1), seq.fragments[0].div_count);
    try testing.expectEqualStrings("option", seq.fragments[0].divs[0].head);
    try testing.expect(seq.fragments[1].op == .@"break");
    try testing.expect(seq.fragments[2].op == .rect);
}

test "unsupported sequence statements are rejected" {
    for ([_][]const u8{
        "sequenceDiagram\nA->>B: before\nbox Group\nparticipant C\nend\n",
        "sequenceDiagram\nA->>B: before\nnot sequence syntax\n",
        "sequenceDiagram\nloop forever\nA->>B: again\n",
        "sequenceDiagram\nA->>B: one; B->>A: two\n",
        "%%{init: {'theme': 'dark'}}%%\nsequenceDiagram\nA->>B: before\n",
    }) |text| {
        try testing.expect(parseSequenceBlockText(text) == null);
    }
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

test "stacked sequence activations" {
    const seq = parseSequenceBlockText(
        "sequenceDiagram\n" ++
            "activate A\n" ++
            "activate A\n" ++
            "A->>B: nested\n" ++
            "deactivate A\n" ++
            "A->>B: outer\n" ++
            "deactivate A\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), seq.activation_count);
    try testing.expectEqual(@as(usize, 1), seq.activations[0].depth);
    try testing.expectEqual(@as(usize, 0), seq.activations[0].start);
    try testing.expectEqual(@as(usize, 1), seq.activations[0].end);
    try testing.expectEqual(@as(usize, 0), seq.activations[1].depth);
    try testing.expectEqual(@as(usize, 2), seq.activations[1].end);
}

test "sequence autonumber configuration" {
    const seq = parseSequenceBlockText("sequenceDiagram\nautonumber\nA->>B: x\n").?;
    try testing.expectEqual(@as(u32, 100), seq.autonumber.?.start);
    try testing.expectEqual(@as(u32, 100), seq.autonumber.?.increment);

    const configured = parseSequenceBlockText("sequenceDiagram\nautonumber 2.5 0.25\nA->>B: x\n").?;
    try testing.expectEqual(@as(u32, 250), configured.autonumber.?.start);
    try testing.expectEqual(@as(u32, 25), configured.autonumber.?.increment);

    const plain = parseSequenceBlockText("sequenceDiagram\nA->>B: x\n").?;
    try testing.expect(plain.autonumber == null);
    for ([_][]const u8{
        "sequenceDiagram\nautonumber 1\nA->>B: x\n",
        "sequenceDiagram\nautonumber 1.001 1\nA->>B: x\n",
        "sequenceDiagram\nautonumber x 1\nA->>B: x\n",
    }) |text| {
        try testing.expect(parseSequenceBlockText(text) == null);
    }
}

test "sequence over-cap degrades" {
    const many = parseSequenceBlockText("sequenceDiagram\n" ++ ("A->>B: x\n" ** 200)).?;
    try testing.expect(many.degraded);
    const activations = parseSequenceBlockText("sequenceDiagram\n" ++ ("activate A\n" ** 65)).?;
    try testing.expect(activations.degraded);
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
    try testing.expect(seq.messages[0].dst_endpoint == .arrow);
    try testing.expect(seq.messages[2].dst_endpoint == .cross);
    try testing.expect(seq.messages[3].dst_endpoint == .cross);
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
