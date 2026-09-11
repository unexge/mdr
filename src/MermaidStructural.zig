//! Zero-copy parsers for Mermaid class, state, and entity-relationship diagrams.

pub const max_nodes = 64;
pub const max_details = 256;
pub const max_relations = 128;

pub const Family = enum { class, state, er };
pub const Direction = enum { tb, bt, lr, rl };
pub const NodeKind = enum { class, state, entity, start, end, choice, fork, join };
pub const DetailKind = enum { annotation, attribute, operation, field, note };
pub const LineStyle = enum { solid, dotted };
pub const Marker = enum {
    none,
    arrow,
    triangle,
    diamond,
    open_diamond,
    lollipop,
    one,
    zero_one,
    one_many,
    zero_many,
};

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    kind: NodeKind,
    order: usize,
};

pub const Detail = struct {
    node: usize,
    text: []const u8,
    kind: DetailKind,
};

pub const Relation = struct {
    src: usize,
    dst: usize,
    label: ?[]const u8 = null,
    src_label: ?[]const u8 = null,
    dst_label: ?[]const u8 = null,
    style: LineStyle = .solid,
    src_marker: Marker = .none,
    dst_marker: Marker = .none,
};

pub const Diagram = struct {
    family: Family = .class,
    direction: Direction = .tb,
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    details: [max_details]Detail = undefined,
    detail_count: usize = 0,
    relations: [max_relations]Relation = undefined,
    relation_count: usize = 0,
    degraded: bool = false,

    pub fn nodeList(self: *const Diagram) []const Node {
        return self.nodes[0..self.node_count];
    }

    pub fn detailList(self: *const Diagram) []const Detail {
        return self.details[0..self.detail_count];
    }

    pub fn relationList(self: *const Diagram) []const Relation {
        return self.relations[0..self.relation_count];
    }
};

pub fn parseBlock(cb: Document.Element.CodeBlock) ?Diagram {
    const info = cb.info orelse return null;
    if (!info.isMermaid()) return null;
    var parser: Parser = .{};
    var lines = cb.lines();
    while (lines.next()) |line| parser.feed(line);
    return parser.result();
}

pub fn parseText(text: []const u8) ?Diagram {
    var parser: Parser = .{};
    var rest = text;
    while (rest.len > 0) {
        const newline = mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        parser.feed(rest[0..newline]);
        rest = if (newline < rest.len) rest[newline + 1 ..] else "";
    }
    return parser.result();
}

const Parser = struct {
    diagram: Diagram = .{},
    seen_header: bool = false,
    supported: bool = true,
    reading_frontmatter: bool = false,
    open_node: ?usize = null,

    fn result(self: *Parser) ?Diagram {
        if (!self.seen_header or !self.supported or self.reading_frontmatter or self.open_node != null) return null;
        return self.diagram;
    }

    fn feed(self: *Parser, raw: []const u8) void {
        if (!self.supported or self.diagram.degraded) return;
        const raw_trimmed = mem.trim(u8, raw, " \t\r");
        if (isConfigDirective(raw_trimmed)) return;
        var line = mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) return;
        if (mem.eql(u8, line, "---")) {
            self.reading_frontmatter = !self.reading_frontmatter;
            return;
        }
        if (self.reading_frontmatter) return;
        if (!self.seen_header) {
            if (eqlIgnoreCase(line, "classDiagram")) {
                self.diagram.family = .class;
            } else if (eqlIgnoreCase(line, "stateDiagram") or eqlIgnoreCase(line, "stateDiagram-v2")) {
                self.diagram.family = .state;
            } else if (eqlIgnoreCase(line, "erDiagram")) {
                self.diagram.family = .er;
            } else {
                self.supported = false;
                return;
            }
            self.seen_header = true;
            return;
        }
        if (self.open_node) |node| {
            if (mem.eql(u8, line, "}")) {
                self.open_node = null;
                return;
            }
            if (mem.indexOfScalar(u8, line, '{') != null or mem.indexOfScalar(u8, line, '}') != null) {
                self.supported = false;
                return;
            }
            self.addDetail(node, line, switch (self.diagram.family) {
                .class => if (mem.indexOfScalar(u8, line, '(') != null) .operation else if (isAnnotation(line)) .annotation else .attribute,
                .er => .field,
                .state => unreachable,
            });
            return;
        }
        line = mem.trim(u8, line, " \t");
        switch (self.diagram.family) {
            .class => self.feedClass(line),
            .state => self.feedState(line),
            .er => self.feedEr(line),
        }
    }

    fn feedClass(self: *Parser, line: []const u8) void {
        if (self.feedDirection(line) or ignoreStyle(line)) return;
        if (stripKeyword(line, "namespace") != null or stripKeyword(line, "note") != null or
            stripKeyword(line, "click") != null or stripKeyword(line, "link") != null or
            stripKeyword(line, "callback") != null)
        {
            self.supported = false;
            return;
        }
        if (stripKeyword(line, "class")) |declaration| {
            self.classDeclaration(declaration);
            return;
        }
        if (parseClassRelation(line)) |relation| {
            const source = self.intern(relation.src.id, relation.src.label, .class, false) orelse return;
            const destination = self.intern(relation.dst.id, relation.dst.label, .class, false) orelse return;
            self.addRelation(.{
                .src = source,
                .dst = destination,
                .label = relation.label,
                .src_label = relation.src_cardinality,
                .dst_label = relation.dst_cardinality,
                .style = relation.style,
                .src_marker = relation.src_marker,
                .dst_marker = relation.dst_marker,
            });
            return;
        }
        if (line[0] == '<') {
            const close = mem.indexOf(u8, line, ">>") orelse {
                self.supported = false;
                return;
            };
            if (line.len < 4 or !mem.startsWith(u8, line, "<<")) {
                self.supported = false;
                return;
            }
            const name = parseName(mem.trim(u8, line[close + 2 ..], " \t")) orelse {
                self.supported = false;
                return;
            };
            const node = self.intern(name.id, name.label, .class, true) orelse return;
            self.addDetail(node, line[0 .. close + 2], .annotation);
            return;
        }
        const colon = findOutsideQuotes(line, ':') orelse {
            self.supported = false;
            return;
        };
        const name = parseName(mem.trim(u8, line[0..colon], " \t")) orelse {
            self.supported = false;
            return;
        };
        const member = mem.trim(u8, line[colon + 1 ..], " \t");
        if (member.len == 0) {
            self.supported = false;
            return;
        }
        const node = self.intern(name.id, name.label, .class, false) orelse return;
        self.addDetail(node, member, if (mem.indexOfScalar(u8, member, '(') != null) .operation else .attribute);
    }

    fn classDeclaration(self: *Parser, raw: []const u8) void {
        var declaration = mem.trim(u8, raw, " \t");
        const opens = mem.endsWith(u8, declaration, "{");
        if (opens) declaration = mem.trim(u8, declaration[0 .. declaration.len - 1], " \t");
        const annotation_start = mem.indexOf(u8, declaration, "<<");
        const name_raw = mem.trim(u8, declaration[0 .. annotation_start orelse declaration.len], " \t");
        const name = parseName(name_raw) orelse {
            self.supported = false;
            return;
        };
        const node = self.intern(name.id, name.label, .class, true) orelse return;
        if (annotation_start) |start| {
            const annotation = mem.trim(u8, declaration[start..], " \t");
            if (!isAnnotation(annotation)) {
                self.supported = false;
                return;
            }
            self.addDetail(node, annotation, .annotation);
        }
        if (opens) self.open_node = node;
    }

    fn feedState(self: *Parser, line: []const u8) void {
        if (self.feedDirection(line) or ignoreStyle(line) or stripKeyword(line, "class") != null or metadataLine(line)) return;
        if (mem.eql(u8, line, "--") or mem.indexOfScalar(u8, line, '{') != null or mem.eql(u8, line, "}")) {
            self.supported = false;
            return;
        }
        if (parseStateTransition(line)) |transition| {
            const source = self.stateEndpoint(transition.src, true) orelse return;
            const destination = self.stateEndpoint(transition.dst, false) orelse return;
            self.addRelation(.{ .src = source, .dst = destination, .label = transition.label, .dst_marker = .arrow });
            return;
        }
        if (stripKeyword(line, "state")) |declaration| {
            self.stateDeclaration(declaration);
            return;
        }
        if (stripKeyword(line, "note")) |note| {
            const parsed = parseStateNote(note) orelse {
                self.supported = false;
                return;
            };
            const name = parseName(parsed.id) orelse {
                self.supported = false;
                return;
            };
            const node = self.intern(name.id, name.label, .state, false) orelse return;
            self.addDetail(node, parsed.text, .note);
            return;
        }
        const colon = findOutsideQuotes(line, ':');
        if (colon) |at| {
            const name = parseName(mem.trim(u8, line[0..at], " \t")) orelse {
                self.supported = false;
                return;
            };
            const label = normalizeLabel(line[at + 1 ..]);
            if (label.len == 0) {
                self.supported = false;
                return;
            }
            _ = self.intern(name.id, label, .state, true);
            return;
        }
        const name = parseName(line) orelse {
            self.supported = false;
            return;
        };
        _ = self.intern(name.id, name.label, .state, true);
    }

    fn stateDeclaration(self: *Parser, raw: []const u8) void {
        const declaration = mem.trim(u8, raw, " \t");
        if (declaration.len == 0) {
            self.supported = false;
            return;
        }
        if (declaration[0] == '"') {
            const close = closingQuote(declaration, 0) orelse {
                self.supported = false;
                return;
            };
            const after = stripKeyword(mem.trim(u8, declaration[close + 1 ..], " \t"), "as") orelse {
                self.supported = false;
                return;
            };
            const name = parseName(after) orelse {
                self.supported = false;
                return;
            };
            _ = self.intern(name.id, declaration[1..close], .state, true);
            return;
        }
        const stereotype = mem.indexOf(u8, declaration, "<<");
        const name = parseName(mem.trim(u8, declaration[0 .. stereotype orelse declaration.len], " \t")) orelse {
            self.supported = false;
            return;
        };
        var kind: NodeKind = .state;
        if (stereotype) |start| {
            const annotation = mem.trim(u8, declaration[start..], " \t");
            kind = if (eqlIgnoreCase(annotation, "<<choice>>"))
                .choice
            else if (eqlIgnoreCase(annotation, "<<fork>>"))
                .fork
            else if (eqlIgnoreCase(annotation, "<<join>>"))
                .join
            else {
                self.supported = false;
                return;
            };
        }
        _ = self.intern(name.id, name.label, kind, true);
    }

    fn stateEndpoint(self: *Parser, raw: []const u8, source: bool) ?usize {
        const endpoint = mem.trim(u8, stripClassSuffix(raw), " \t");
        if (mem.eql(u8, endpoint, "[*]")) {
            return self.intern(
                if (source) "__state:start" else "__state:end",
                "",
                if (source) .start else .end,
                true,
            );
        }
        const name = parseName(endpoint) orelse {
            self.supported = false;
            return null;
        };
        return self.intern(name.id, name.label, .state, false);
    }

    fn feedEr(self: *Parser, line: []const u8) void {
        if (self.feedDirection(line) or ignoreStyle(line) or stripKeyword(line, "class") != null) return;
        if (stripKeyword(line, "subgraph") != null or eqlIgnoreCase(line, "end")) {
            self.supported = false;
            return;
        }
        if (parseErRelation(line)) |relation| {
            const source = self.intern(relation.src.id, relation.src.label, .entity, false) orelse return;
            const destination = self.intern(relation.dst.id, relation.dst.label, .entity, false) orelse return;
            self.addRelation(.{
                .src = source,
                .dst = destination,
                .label = relation.label,
                .style = relation.style,
                .src_marker = relation.src_marker,
                .dst_marker = relation.dst_marker,
            });
            return;
        }
        var declaration = mem.trim(u8, line, " \t");
        const opens = mem.endsWith(u8, declaration, "{");
        if (opens) declaration = mem.trim(u8, declaration[0 .. declaration.len - 1], " \t");
        const name = parseName(declaration) orelse {
            self.supported = false;
            return;
        };
        const node = self.intern(name.id, name.label, .entity, true) orelse return;
        if (opens) self.open_node = node;
    }

    fn feedDirection(self: *Parser, line: []const u8) bool {
        const raw = stripKeyword(line, "direction") orelse return false;
        self.diagram.direction = parseDirection(raw) orelse {
            self.supported = false;
            return true;
        };
        return true;
    }

    fn intern(self: *Parser, id: []const u8, label: []const u8, kind: NodeKind, explicit: bool) ?usize {
        for (self.diagram.nodes[0..self.diagram.node_count], 0..) |*node, index| {
            if (!idsEqual(node.id, id)) continue;
            if (explicit) {
                node.label = label;
                node.kind = kind;
            }
            return index;
        }
        if (self.diagram.node_count >= max_nodes) {
            self.diagram.degraded = true;
            return null;
        }
        const index = self.diagram.node_count;
        self.diagram.nodes[index] = .{ .id = id, .label = label, .kind = kind, .order = index };
        self.diagram.node_count += 1;
        return index;
    }

    fn addDetail(self: *Parser, node: usize, text: []const u8, kind: DetailKind) void {
        if (text.len == 0) {
            self.supported = false;
            return;
        }
        if (self.diagram.detail_count >= max_details) {
            self.diagram.degraded = true;
            return;
        }
        self.diagram.details[self.diagram.detail_count] = .{ .node = node, .text = text, .kind = kind };
        self.diagram.detail_count += 1;
    }

    fn addRelation(self: *Parser, relation: Relation) void {
        if (self.diagram.relation_count >= max_relations) {
            self.diagram.degraded = true;
            return;
        }
        self.diagram.relations[self.diagram.relation_count] = relation;
        self.diagram.relation_count += 1;
    }
};

const Name = struct {
    id: []const u8,
    label: []const u8,
};

fn parseName(raw: []const u8) ?Name {
    var text = mem.trim(u8, stripClassSuffix(raw), " \t");
    if (text.len == 0) return null;
    if (text[0] == '`' or text[0] == '"') {
        const close = closingQuote(text, 0) orelse return null;
        if (mem.trim(u8, text[close + 1 ..], " \t").len != 0) return null;
        return .{ .id = text[1..close], .label = text[1..close] };
    }
    if (mem.indexOfScalar(u8, text, '[')) |open| {
        if (!mem.endsWith(u8, text, "]")) return null;
        const id = mem.trim(u8, text[0..open], " \t");
        if (!validId(id)) return null;
        const label = normalizeLabel(text[open + 1 .. text.len - 1]);
        if (label.len == 0) return null;
        return .{ .id = id, .label = label };
    }
    text = mem.trim(u8, text, " \t");
    if (!validId(text)) return null;
    return .{ .id = text, .label = text };
}

fn validId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |char| {
        if (char == ':' or char == '{' or char == '}' or char == '[' or char == ']' or
            char == '<' or char == '>' or char == '"' or char == '`' or char == ';' or
            char == ' ' or char == '\t' or char == '\r' or char == '\n') return false;
    }
    return true;
}

fn idsEqual(a: []const u8, b: []const u8) bool {
    if (mem.eql(u8, a, b)) return true;
    const a_generic = mem.indexOfScalar(u8, a, '~') orelse a.len;
    const b_generic = mem.indexOfScalar(u8, b, '~') orelse b.len;
    return mem.eql(u8, a[0..a_generic], b[0..b_generic]);
}

fn stripClassSuffix(raw: []const u8) []const u8 {
    const suffix = mem.indexOf(u8, raw, ":::") orelse return raw;
    return mem.trim(u8, raw[0..suffix], " \t");
}

fn normalizeLabel(raw: []const u8) []const u8 {
    var label = mem.trim(u8, raw, " \t\r");
    if (label.len >= 2 and ((label[0] == '"' and label[label.len - 1] == '"') or
        (label[0] == '`' and label[label.len - 1] == '`')))
    {
        label = label[1 .. label.len - 1];
    }
    return label;
}

const ClassSide = struct {
    name: Name,
    cardinality: ?[]const u8,
};

const ParsedClassRelation = struct {
    src: Name,
    dst: Name,
    src_cardinality: ?[]const u8,
    dst_cardinality: ?[]const u8,
    label: ?[]const u8,
    style: LineStyle,
    src_marker: Marker,
    dst_marker: Marker,
};

const ClassOperator = struct {
    text: []const u8,
    style: LineStyle = .solid,
    src_marker: Marker = .none,
    dst_marker: Marker = .none,
};

const class_operators = [_]ClassOperator{
    .{ .text = "<|--|>", .src_marker = .triangle, .dst_marker = .triangle },
    .{ .text = "<|--", .src_marker = .triangle },
    .{ .text = "--|>", .dst_marker = .triangle },
    .{ .text = "<|..", .style = .dotted, .src_marker = .triangle },
    .{ .text = "..|>", .style = .dotted, .dst_marker = .triangle },
    .{ .text = "()--", .src_marker = .lollipop },
    .{ .text = "--()", .dst_marker = .lollipop },
    .{ .text = "*--", .src_marker = .diamond },
    .{ .text = "--*", .dst_marker = .diamond },
    .{ .text = "o--", .src_marker = .open_diamond },
    .{ .text = "--o", .dst_marker = .open_diamond },
    .{ .text = "<--", .src_marker = .arrow },
    .{ .text = "-->", .dst_marker = .arrow },
    .{ .text = "<..", .style = .dotted, .src_marker = .arrow },
    .{ .text = "..>", .style = .dotted, .dst_marker = .arrow },
    .{ .text = "--" },
    .{ .text = "..", .style = .dotted },
};

fn parseClassRelation(line: []const u8) ?ParsedClassRelation {
    const found = findClassOperator(line) orelse return null;
    const left = parseClassSide(line[0..found.at], false) orelse return null;
    var right_text = line[found.at + found.op.text.len ..];
    const colon = findOutsideQuotes(right_text, ':');
    const label = if (colon) |at| normalizeLabel(right_text[at + 1 ..]) else null;
    if (label != null and label.?.len == 0) return null;
    if (colon) |at| right_text = right_text[0..at];
    const right = parseClassSide(right_text, true) orelse return null;
    return .{
        .src = left.name,
        .dst = right.name,
        .src_cardinality = left.cardinality,
        .dst_cardinality = right.cardinality,
        .label = label,
        .style = found.op.style,
        .src_marker = found.op.src_marker,
        .dst_marker = found.op.dst_marker,
    };
}

fn findClassOperator(line: []const u8) ?struct { at: usize, op: ClassOperator } {
    var quoted: u8 = 0;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        if (line[index] == '"' or line[index] == '`') {
            if (quoted == 0) quoted = line[index] else if (quoted == line[index]) quoted = 0;
            continue;
        }
        if (quoted != 0) continue;
        for (class_operators) |op| {
            if (mem.startsWith(u8, line[index..], op.text)) return .{ .at = index, .op = op };
        }
    }
    return null;
}

fn parseClassSide(raw: []const u8, cardinality_first: bool) ?ClassSide {
    var side = mem.trim(u8, raw, " \t");
    var cardinality: ?[]const u8 = null;
    if (cardinality_first and side.len > 0 and side[0] == '"') {
        const close = closingQuote(side, 0) orelse return null;
        cardinality = side[1..close];
        side = mem.trim(u8, side[close + 1 ..], " \t");
    } else if (!cardinality_first) {
        if (mem.lastIndexOfScalar(u8, side, '"')) |last| {
            var first = last;
            while (first > 0 and side[first - 1] != '"') first -= 1;
            if (first == 0) return null;
            first -= 1;
            cardinality = side[first + 1 .. last];
            side = mem.trim(u8, side[0..first], " \t");
        }
    }
    const name = parseName(side) orelse return null;
    return .{ .name = name, .cardinality = cardinality };
}

const ParsedStateTransition = struct {
    src: []const u8,
    dst: []const u8,
    label: ?[]const u8,
};

fn parseStateTransition(line: []const u8) ?ParsedStateTransition {
    const arrow = findTokenOutsideQuotes(line, "-->") orelse return null;
    const source = mem.trim(u8, line[0..arrow], " \t");
    var right = line[arrow + 3 ..];
    const colon = findOutsideQuotes(right, ':');
    const label = if (colon) |at| normalizeLabel(right[at + 1 ..]) else null;
    if (label != null and label.?.len == 0) return null;
    if (colon) |at| right = right[0..at];
    const destination = mem.trim(u8, right, " \t");
    if (source.len == 0 or destination.len == 0) return null;
    return .{ .src = source, .dst = destination, .label = label };
}

const ParsedStateNote = struct {
    id: []const u8,
    text: []const u8,
};

fn parseStateNote(raw: []const u8) ?ParsedStateNote {
    var rest = mem.trim(u8, raw, " \t");
    if (stripKeyword(rest, "left")) |after| {
        rest = stripKeyword(after, "of") orelse return null;
    } else if (stripKeyword(rest, "right")) |after| {
        rest = stripKeyword(after, "of") orelse return null;
    } else {
        return null;
    }
    const colon = findOutsideQuotes(rest, ':') orelse return null;
    const id = mem.trim(u8, rest[0..colon], " \t");
    const text = normalizeLabel(rest[colon + 1 ..]);
    if (id.len == 0 or text.len == 0) return null;
    return .{ .id = id, .text = text };
}

const ParsedErRelation = struct {
    src: Name,
    dst: Name,
    label: ?[]const u8,
    style: LineStyle,
    src_marker: Marker,
    dst_marker: Marker,
};

fn parseErRelation(line: []const u8) ?ParsedErRelation {
    const found = findErOperator(line) orelse return null;
    const source = parseName(mem.trim(u8, line[0..found.at], " \t")) orelse return null;
    var right = line[found.at + 6 ..];
    const colon = findOutsideQuotes(right, ':') orelse return null;
    const destination = parseName(mem.trim(u8, right[0..colon], " \t")) orelse return null;
    const label = normalizeLabel(right[colon + 1 ..]);
    if (label.len == 0) return null;
    return .{
        .src = source,
        .dst = destination,
        .label = label,
        .style = found.style,
        .src_marker = found.src_marker,
        .dst_marker = found.dst_marker,
    };
}

fn findErOperator(line: []const u8) ?struct {
    at: usize,
    style: LineStyle,
    src_marker: Marker,
    dst_marker: Marker,
} {
    var quoted = false;
    var index: usize = 0;
    while (index + 6 <= line.len) : (index += 1) {
        if (line[index] == '"') {
            quoted = !quoted;
            continue;
        }
        if (quoted) continue;
        const left = erLeftMarker(line[index..][0..2]) orelse continue;
        const style: LineStyle = if (mem.eql(u8, line[index + 2 .. index + 4], "--"))
            .solid
        else if (mem.eql(u8, line[index + 2 .. index + 4], ".."))
            .dotted
        else
            continue;
        const right = erRightMarker(line[index + 4 .. index + 6]) orelse continue;
        return .{ .at = index, .style = style, .src_marker = left, .dst_marker = right };
    }
    return null;
}

fn erLeftMarker(raw: []const u8) ?Marker {
    if (mem.eql(u8, raw, "||")) return .one;
    if (mem.eql(u8, raw, "|o")) return .zero_one;
    if (mem.eql(u8, raw, "}|")) return .one_many;
    if (mem.eql(u8, raw, "}o")) return .zero_many;
    return null;
}

fn erRightMarker(raw: []const u8) ?Marker {
    if (mem.eql(u8, raw, "||")) return .one;
    if (mem.eql(u8, raw, "o|")) return .zero_one;
    if (mem.eql(u8, raw, "|{")) return .one_many;
    if (mem.eql(u8, raw, "o{")) return .zero_many;
    return null;
}

fn parseDirection(raw: []const u8) ?Direction {
    const direction = mem.trim(u8, raw, " \t");
    if (eqlIgnoreCase(direction, "TB") or eqlIgnoreCase(direction, "TD")) return .tb;
    if (eqlIgnoreCase(direction, "BT")) return .bt;
    if (eqlIgnoreCase(direction, "LR")) return .lr;
    if (eqlIgnoreCase(direction, "RL")) return .rl;
    return null;
}

fn ignoreStyle(line: []const u8) bool {
    for ([_][]const u8{ "style", "classDef", "cssClass" }) |keyword| {
        if (stripKeyword(line, keyword) != null) return true;
    }
    return false;
}

fn metadataLine(line: []const u8) bool {
    return startsWithColonDirective(line, "accTitle") or startsWithColonDirective(line, "accDescr");
}

fn startsWithColonDirective(line: []const u8, name: []const u8) bool {
    return line.len > name.len and eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':';
}

fn isAnnotation(line: []const u8) bool {
    return line.len >= 4 and mem.startsWith(u8, line, "<<") and mem.endsWith(u8, line, ">>");
}

fn stripKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (line.len < keyword.len or !eqlIgnoreCase(line[0..keyword.len], keyword)) return null;
    if (line.len > keyword.len and line[keyword.len] != ' ' and line[keyword.len] != '\t') return null;
    return mem.trim(u8, line[keyword.len..], " \t");
}

fn stripComment(line: []const u8) []const u8 {
    var quoted: u8 = 0;
    var index: usize = 0;
    while (index + 1 < line.len) : (index += 1) {
        if (line[index] == '"' or line[index] == '`') {
            if (quoted == 0) quoted = line[index] else if (quoted == line[index]) quoted = 0;
            continue;
        }
        if (quoted == 0 and line[index] == '%' and line[index + 1] == '%') return line[0..index];
    }
    return line;
}

fn isConfigDirective(line: []const u8) bool {
    return mem.startsWith(u8, line, "%%{") and mem.endsWith(u8, line, "}%%");
}

fn findTokenOutsideQuotes(line: []const u8, token: []const u8) ?usize {
    var quoted: u8 = 0;
    var index: usize = 0;
    while (index + token.len <= line.len) : (index += 1) {
        const char = line[index];
        if (char == '"' or char == '`') {
            if (quoted == 0) quoted = char else if (quoted == char) quoted = 0;
        } else if (quoted == 0 and mem.startsWith(u8, line[index..], token)) {
            return index;
        }
    }
    return null;
}

fn findOutsideQuotes(line: []const u8, needle: u8) ?usize {
    var quoted: u8 = 0;
    for (line, 0..) |char, index| {
        if (char == '"' or char == '`') {
            if (quoted == 0) quoted = char else if (quoted == char) quoted = 0;
        } else if (quoted == 0 and char == needle) {
            return index;
        }
    }
    return null;
}

fn closingQuote(line: []const u8, start: usize) ?usize {
    const quote = line[start];
    var index = start + 1;
    while (index < line.len) : (index += 1) {
        if (line[index] == quote and line[index - 1] != '\\') return index;
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |actual, expected| {
        if (ascii.toLower(actual) != ascii.toLower(expected)) return false;
    }
    return true;
}

const std = @import("std");
const Document = @import("Document.zig");
const mem = std.mem;
const ascii = std.ascii;

test "class diagrams preserve members relationships and cardinalities" {
    const diagram = parseText(
        "classDiagram\n" ++
            "direction LR\n" ++
            "class Animal {\n" ++
            "  <<abstract>>\n" ++
            "  +String name\n" ++
            "  +speak() void\n" ++
            "}\n" ++
            "class Duck[Water Duck]\n" ++
            "Animal \"1\" <|-- \"*\" Duck : implements\n",
    ).?;
    try testing.expect(diagram.family == .class);
    try testing.expect(diagram.direction == .lr);
    try testing.expectEqual(@as(usize, 2), diagram.node_count);
    try testing.expectEqualStrings("Water Duck", diagram.nodes[1].label);
    try testing.expectEqual(@as(usize, 3), diagram.detail_count);
    try testing.expect(diagram.details[2].kind == .operation);
    try testing.expect(diagram.relations[0].src_marker == .triangle);
    try testing.expectEqualStrings("1", diagram.relations[0].src_label.?);
    try testing.expectEqualStrings("*", diagram.relations[0].dst_label.?);
    try testing.expectEqualStrings("implements", diagram.relations[0].label.?);
}

test "class relationship forms map endpoint markers" {
    const cases = [_]struct {
        text: []const u8,
        style: LineStyle = .solid,
        source: Marker = .none,
        destination: Marker = .none,
    }{
        .{ .text = "classDiagram\nA <|-- B\n", .source = .triangle },
        .{ .text = "classDiagram\nA --|> B\n", .destination = .triangle },
        .{ .text = "classDiagram\nA *-- B\n", .source = .diamond },
        .{ .text = "classDiagram\nA o-- B\n", .source = .open_diamond },
        .{ .text = "classDiagram\nA --> B\n", .destination = .arrow },
        .{ .text = "classDiagram\nA ..> B\n", .style = .dotted, .destination = .arrow },
        .{ .text = "classDiagram\nA <|.. B\n", .style = .dotted, .source = .triangle },
        .{ .text = "classDiagram\nA ()-- B\n", .source = .lollipop },
    };
    for (cases) |case| {
        const diagram = parseText(case.text).?;
        try testing.expectEqual(@as(usize, 1), diagram.relation_count);
        try testing.expect(diagram.relations[0].style == case.style);
        try testing.expect(diagram.relations[0].src_marker == case.source);
        try testing.expect(diagram.relations[0].dst_marker == case.destination);
    }
}

test "quoted state descriptions do not parse as transitions" {
    const diagram = parseText("stateDiagram-v2\nstate \"A --> B\" as Between\n").?;
    try testing.expectEqual(@as(usize, 1), diagram.node_count);
    try testing.expectEqualStrings("A --> B", diagram.nodes[0].label);
    try testing.expectEqual(@as(usize, 0), diagram.relation_count);
}

test "state diagrams preserve special states choices notes and cycles" {
    const diagram = parseText(
        "stateDiagram-v2\n" ++
            "state \"Waiting for input\" as Waiting\n" ++
            "state Decision <<choice>>\n" ++
            "[*] --> Waiting\n" ++
            "Waiting --> Decision : submit\n" ++
            "Decision --> Waiting : retry\n" ++
            "Decision --> [*]\n" ++
            "note right of Waiting : user action\n",
    ).?;
    try testing.expect(diagram.family == .state);
    try testing.expectEqual(@as(usize, 4), diagram.node_count);
    try testing.expectEqualStrings("Waiting for input", diagram.nodes[0].label);
    try testing.expect(diagram.nodes[1].kind == .choice);
    try testing.expect(diagram.nodes[2].kind == .start);
    try testing.expect(diagram.nodes[3].kind == .end);
    try testing.expectEqual(@as(usize, 4), diagram.relation_count);
    try testing.expect(diagram.details[0].kind == .note);
}

test "er diagrams preserve attributes and crow foot cardinalities" {
    const diagram = parseText(
        "erDiagram\n" ++
            "CUSTOMER ||--o{ ORDER : places\n" ++
            "CUSTOMER {\n" ++
            "  string id PK\n" ++
            "  string name\n" ++
            "}\n" ++
            "ORDER[Purchase] {\n" ++
            "  int total\n" ++
            "}\n",
    ).?;
    try testing.expect(diagram.family == .er);
    try testing.expectEqual(@as(usize, 2), diagram.node_count);
    try testing.expectEqualStrings("Purchase", diagram.nodes[1].label);
    try testing.expectEqual(@as(usize, 3), diagram.detail_count);
    try testing.expect(diagram.relations[0].src_marker == .one);
    try testing.expect(diagram.relations[0].dst_marker == .zero_many);
    try testing.expectEqualStrings("places", diagram.relations[0].label.?);
}

test "er cardinality forms map endpoint markers" {
    const diagram = parseText(
        "erDiagram\n" ++
            "A |o--o| B : maybe\n" ++
            "B }|..|{ C : children\n" ++
            "C }o--o{ D : peers\n",
    ).?;
    try testing.expect(diagram.relations[0].src_marker == .zero_one);
    try testing.expect(diagram.relations[0].dst_marker == .zero_one);
    try testing.expect(diagram.relations[1].src_marker == .one_many);
    try testing.expect(diagram.relations[1].dst_marker == .one_many);
    try testing.expect(diagram.relations[1].style == .dotted);
    try testing.expect(diagram.relations[2].src_marker == .zero_many);
    try testing.expect(diagram.relations[2].dst_marker == .zero_many);
}

test "structural parser rejects unsupported blocks and unclosed bodies" {
    try testing.expect(parseText("pie\ntitle Pets\n") == null);
    try testing.expect(parseText("classDiagram\nnamespace Models {\n") == null);
    try testing.expect(parseText("stateDiagram-v2\nstate Parent {\n") == null);
    try testing.expect(parseText("erDiagram\nCUSTOMER {\nstring id\n") == null);
}

const testing = std.testing;
