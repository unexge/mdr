//! Zero-copy parsers for Mermaid class, state, and entity-relationship diagrams.

pub const max_nodes = 64;
pub const max_details = 256;
pub const max_relations = 128;
pub const max_groups = 16;
pub const max_group_depth = 8;
pub const max_regions_per_group = 8;

pub const Family = enum { class, state, er };
pub const Direction = common.Direction;
pub const NodeKind = enum { class, state, entity, start, end, choice, fork, join, composite, namespace, er_group };
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
    group: ?usize = null,
    region: usize = 0,
};

pub const Group = struct {
    node: usize,
    direction: ?Direction = null,
    region_count: usize = 1,
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
    groups: [max_groups]Group = undefined,
    group_count: usize = 0,
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

    pub fn groupList(self: *const Diagram) []const Group {
        return self.groups[0..self.group_count];
    }

    pub fn groupForNode(self: *const Diagram, node: usize) ?usize {
        for (self.groupList(), 0..) |group, index| {
            if (group.node == node) return index;
        }
        return null;
    }
};

pub fn parseBlock(cb: Document.Element.CodeBlock) ?Diagram {
    const info = cb.info orelse return null;
    if (!info.isMermaid()) return null;
    var parser: Parser = .{};
    var lines = cb.lines();
    while (lines.next()) |line| {
        parser.feed(line);
        if (!parser.supported or parser.diagram.degraded) break;
    }
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
    group_stack: [max_group_depth]usize = undefined,
    group_stack_len: usize = 0,
    declared: [max_nodes]bool = [_]bool{false} ** max_nodes,

    fn result(self: *Parser) ?Diagram {
        if (!self.seen_header or !self.supported or self.reading_frontmatter or
            self.open_node != null or self.group_stack_len != 0) return null;
        for (self.diagram.groupList(), 0..) |item, group| {
            for (0..item.region_count) |region| {
                var has_child = false;
                for (self.diagram.nodeList()) |node| {
                    if (node.group == group and node.region == region) {
                        has_child = true;
                        break;
                    }
                }
                if (!has_child) return null;
            }
        }
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
        if (mem.eql(u8, line, "}")) {
            self.closeGroup();
            return;
        }
        if (stripKeyword(line, "namespace")) |declaration| {
            self.namespaceDeclaration(declaration);
            return;
        }
        if (stripKeyword(line, "note") != null or stripKeyword(line, "click") != null or
            stripKeyword(line, "link") != null or stripKeyword(line, "callback") != null)
        {
            self.supported = false;
            return;
        }
        if (stripKeyword(line, "class")) |declaration| {
            self.classDeclaration(declaration);
            return;
        }
        if (parseClassRelation(line)) |relation| {
            const source = self.resolveClass(relation.src.id, relation.src.label, false) orelse return;
            const destination = self.resolveClass(relation.dst.id, relation.dst.label, false) orelse return;
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
            const node = self.resolveClass(name.id, name.label, true) orelse return;
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
        const node = self.resolveClass(name.id, name.label, false) orelse return;
        self.addDetail(node, member, if (mem.indexOfScalar(u8, member, '(') != null) .operation else .attribute);
    }

    fn namespaceDeclaration(self: *Parser, raw: []const u8) void {
        var declaration = mem.trim(u8, raw, " \t");
        if (!mem.endsWith(u8, declaration, "{")) {
            self.supported = false;
            return;
        }
        declaration = mem.trim(u8, declaration[0 .. declaration.len - 1], " \t");
        const name = parseName(declaration) orelse {
            self.supported = false;
            return;
        };
        if (mem.indexOfScalar(u8, name.id, '.') != null) {
            self.supported = false;
            return;
        }
        self.openGroup(name.id, name.label, .namespace, true);
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
        const node = self.resolveClass(name.id, name.label, true) orelse return;
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
        if (mem.eql(u8, line, "}")) {
            self.closeGroup();
            return;
        }
        if (mem.eql(u8, line, "--")) {
            self.startRegion();
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
        if (mem.indexOfScalar(u8, line, '{') != null) {
            self.supported = false;
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
            const node = self.resolveState(name.id, name.label, .state, false) orelse return;
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
            _ = self.resolveState(name.id, label, .state, true);
            return;
        }
        const name = parseName(line) orelse {
            self.supported = false;
            return;
        };
        _ = self.resolveState(name.id, name.label, .state, true);
    }

    fn stateDeclaration(self: *Parser, raw: []const u8) void {
        var declaration = mem.trim(u8, raw, " \t");
        const opens = mem.endsWith(u8, declaration, "{");
        if (opens) declaration = mem.trim(u8, declaration[0 .. declaration.len - 1], " \t");
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
            if (opens) {
                self.openGroup(name.id, declaration[1..close], .composite, true);
            } else {
                _ = self.resolveState(name.id, declaration[1..close], .state, true);
            }
            return;
        }
        const stereotype = mem.indexOf(u8, declaration, "<<");
        const name = parseName(mem.trim(u8, declaration[0 .. stereotype orelse declaration.len], " \t")) orelse {
            self.supported = false;
            return;
        };
        if (opens) {
            if (stereotype != null) {
                self.supported = false;
                return;
            }
            self.openGroup(name.id, name.label, .composite, !mem.eql(u8, name.id, name.label));
            return;
        }
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
        _ = self.resolveState(name.id, name.label, kind, true);
    }

    fn stateEndpoint(self: *Parser, raw: []const u8, source: bool) ?usize {
        const endpoint = mem.trim(u8, stripClassSuffix(raw), " \t");
        if (mem.eql(u8, endpoint, "[*]")) {
            return self.resolveState(
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
        return self.resolveState(name.id, name.label, .state, false);
    }

    fn feedEr(self: *Parser, line: []const u8) void {
        if (self.feedDirection(line) or ignoreStyle(line) or stripKeyword(line, "class") != null) return;
        if (stripKeyword(line, "subgraph")) |declaration| {
            const name = parseName(declaration) orelse {
                self.supported = false;
                return;
            };
            self.openGroup(name.id, name.label, .er_group, true);
            return;
        }
        if (eqlIgnoreCase(line, "end")) {
            self.closeGroup();
            return;
        }
        if (parseErRelation(line)) |relation| {
            const source = self.resolveErEndpoint(relation.src.id, relation.src.label) orelse return;
            const destination = self.resolveErEndpoint(relation.dst.id, relation.dst.label) orelse return;
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
        const node = self.declareErEntity(name.id, name.label) orelse return;
        if (opens) self.open_node = node;
    }

    fn feedDirection(self: *Parser, line: []const u8) bool {
        const raw = stripKeyword(line, "direction") orelse return false;
        const direction = parseDirection(raw) orelse {
            self.supported = false;
            return true;
        };
        if ((self.diagram.family == .state or self.diagram.family == .er) and self.currentGroup() != null) {
            self.diagram.groups[self.currentGroup().?].direction = direction;
        } else {
            self.diagram.direction = direction;
        }
        return true;
    }

    fn openGroup(
        self: *Parser,
        id: []const u8,
        label: []const u8,
        kind: NodeKind,
        label_explicit: bool,
    ) void {
        if (self.diagram.group_count >= max_groups or self.group_stack_len >= self.group_stack.len) {
            self.diagram.degraded = true;
            return;
        }
        const node = switch (kind) {
            .namespace => self.declareNamespace(id, label),
            .composite => self.declareComposite(id, label, label_explicit),
            .er_group => self.declareErGroup(id, label),
            else => unreachable,
        } orelse return;
        if (self.diagram.groupForNode(node) != null) {
            self.supported = false;
            return;
        }
        self.diagram.nodes[node].kind = kind;
        const group = self.diagram.group_count;
        self.diagram.groups[group] = .{ .node = node };
        self.diagram.group_count += 1;
        self.group_stack[self.group_stack_len] = group;
        self.group_stack_len += 1;
    }

    fn closeGroup(self: *Parser) void {
        if (self.group_stack_len == 0) {
            self.supported = false;
        } else {
            self.group_stack_len -= 1;
        }
    }

    fn startRegion(self: *Parser) void {
        const group = self.currentGroup() orelse {
            self.supported = false;
            return;
        };
        if (self.diagram.groups[group].region_count >= max_regions_per_group) {
            self.diagram.degraded = true;
            return;
        }
        self.diagram.groups[group].region_count += 1;
    }

    fn currentGroup(self: *const Parser) ?usize {
        if (self.group_stack_len == 0) return null;
        return self.group_stack[self.group_stack_len - 1];
    }

    fn currentRegion(self: *const Parser) usize {
        const group = self.currentGroup() orelse return 0;
        return self.diagram.groups[group].region_count - 1;
    }

    fn resolveClass(self: *Parser, id: []const u8, label: []const u8, explicit: bool) ?usize {
        const group = self.currentGroup();
        const region = self.currentRegion();
        for (self.diagram.nodes[0..self.diagram.node_count], 0..) |*node, index| {
            if (node.kind == .namespace or !idsEqual(node.id, id)) continue;
            if (explicit) {
                node.label = label;
                node.kind = .class;
                node.group = group;
                node.region = region;
            }
            return index;
        }
        return self.appendNode(id, label, .class, group, region, false);
    }

    fn declareNamespace(self: *Parser, id: []const u8, label: []const u8) ?usize {
        const group = self.currentGroup();
        for (self.diagram.nodes[0..self.diagram.node_count], 0..) |node, index| {
            if (node.kind == .namespace and node.group == group and idsEqual(node.id, id)) return index;
        }
        return self.appendNode(id, label, .namespace, group, self.currentRegion(), false);
    }

    fn resolveState(self: *Parser, id: []const u8, label: []const u8, kind: NodeKind, explicit: bool) ?usize {
        const group = self.currentGroup();
        const region = self.currentRegion();
        for (self.diagram.nodes[0..self.diagram.node_count], 0..) |*node, index| {
            if (!idsEqual(node.id, id) or node.group != group) continue;
            if (node.region != region) {
                if (kind != .start and kind != .end) self.supported = false;
                if (!self.supported) return null;
                continue;
            }
            if (explicit) {
                node.label = label;
                if (node.kind != .composite) node.kind = kind;
            }
            return index;
        }
        return self.appendNode(id, label, kind, group, region, false);
    }

    fn declareComposite(self: *Parser, id: []const u8, label: []const u8, label_explicit: bool) ?usize {
        return self.resolveState(id, label, .composite, label_explicit);
    }

    fn resolveErEndpoint(self: *Parser, id: []const u8, label: []const u8) ?usize {
        for (self.diagram.nodes[0..self.diagram.node_count], 0..) |node, index| {
            if ((node.kind == .entity or node.kind == .er_group) and idsEqual(node.id, id)) return index;
        }
        return self.appendNode(id, label, .entity, self.currentGroup(), self.currentRegion(), false);
    }

    fn declareErEntity(self: *Parser, id: []const u8, label: []const u8) ?usize {
        const group = self.currentGroup();
        const region = self.currentRegion();
        for (self.diagram.nodes[0..self.diagram.node_count], 0..) |*node, index| {
            if (!idsEqual(node.id, id)) continue;
            if (node.kind == .er_group) {
                self.supported = false;
                return null;
            }
            if (node.kind != .entity) continue;
            node.label = label;
            node.group = group;
            node.region = region;
            self.declared[index] = true;
            return index;
        }
        return self.appendNode(id, label, .entity, group, region, true);
    }

    fn declareErGroup(self: *Parser, id: []const u8, label: []const u8) ?usize {
        const group = self.currentGroup();
        const region = self.currentRegion();
        for (self.diagram.nodes[0..self.diagram.node_count], 0..) |*node, index| {
            if (!idsEqual(node.id, id)) continue;
            if (node.kind == .er_group) return index;
            if (node.kind != .entity) continue;
            if (self.declared[index]) {
                self.supported = false;
                return null;
            }
            node.label = label;
            node.kind = .er_group;
            node.group = group;
            node.region = region;
            self.declared[index] = true;
            return index;
        }
        return self.appendNode(id, label, .er_group, group, region, true);
    }

    fn appendNode(
        self: *Parser,
        id: []const u8,
        label: []const u8,
        kind: NodeKind,
        group: ?usize,
        region: usize,
        declared: bool,
    ) ?usize {
        if (self.diagram.node_count >= max_nodes) {
            self.diagram.degraded = true;
            return null;
        }
        const index = self.diagram.node_count;
        self.diagram.nodes[index] = .{
            .id = id,
            .label = label,
            .kind = kind,
            .order = index,
            .group = group,
            .region = region,
        };
        self.declared[index] = declared;
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
        if (self.diagram.family == .state) {
            const source = self.diagram.nodes[relation.src];
            const destination = self.diagram.nodes[relation.dst];
            if (source.group != destination.group or source.region != destination.region) {
                self.supported = false;
                return;
            }
        }
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

const common = @import("common.zig");
const parseDirection = common.parseDirection;
const stripKeyword = common.stripKeyword;
const isConfigDirective = common.isConfigDirective;
const eqlIgnoreCase = common.eqlIgnoreCase;

const std = @import("std");
const Document = @import("../Document.zig");
const mem = std.mem;

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

test "class diagrams parse nested labeled namespaces" {
    const diagram = parseText(
        "classDiagram\n" ++
            "Animal <|-- Duck\n" ++
            "namespace Models[\"Domain Models\"] {\n" ++
            "class Animal {\n" ++
            "+String name\n" ++
            "}\n" ++
            "namespace Water {\n" ++
            "class Duck {\n" ++
            "+swim()\n" ++
            "}\n" ++
            "}\n" ++
            "}\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), diagram.group_count);
    try testing.expectEqual(@as(usize, 4), diagram.node_count);
    try testing.expectEqual(@as(usize, 2), diagram.detail_count);
    try testing.expectEqualStrings("Domain Models", diagram.nodes[diagram.groups[0].node].label);
    try testing.expectEqual(@as(?usize, 0), diagram.nodes[0].group);
    try testing.expectEqual(@as(?usize, 1), diagram.nodes[1].group);
    try testing.expect(diagram.nodes[diagram.groups[0].node].group == null);
    try testing.expectEqual(@as(?usize, 0), diagram.nodes[diagram.groups[1].node].group);
    try testing.expectEqual(@as(usize, 0), diagram.relations[0].src);
    try testing.expectEqual(@as(usize, 1), diagram.relations[0].dst);
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

test "state diagrams parse nested composite states" {
    const diagram = parseText(
        "stateDiagram-v2\n" ++
            "[*] --> First\n" ++
            "First: Outer state\n" ++
            "state First {\n" ++
            "direction LR\n" ++
            "[*] --> Second\n" ++
            "state \"Inner state\" as Second {\n" ++
            "[*] --> Idle\n" ++
            "Idle --> [*]\n" ++
            "}\n" ++
            "Second --> [*]\n" ++
            "}\n" ++
            "First: Renamed outer\n" ++
            "First --> [*]\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), diagram.group_count);
    try testing.expectEqual(@as(usize, 9), diagram.node_count);
    try testing.expectEqual(@as(usize, 6), diagram.relation_count);
    try testing.expectEqualStrings("Renamed outer", diagram.nodes[diagram.groups[0].node].label);
    try testing.expectEqualStrings("Inner state", diagram.nodes[diagram.groups[1].node].label);
    try testing.expect(diagram.nodes[diagram.groups[0].node].group == null);
    try testing.expectEqual(@as(?usize, 0), diagram.nodes[diagram.groups[1].node].group);
    try testing.expectEqual(@as(?Direction, .lr), diagram.groups[0].direction);
    try testing.expect(diagram.groups[1].direction == null);
    try testing.expectEqual(diagram.groups[0].node, diagram.relations[0].dst);
    try testing.expectEqual(diagram.groups[1].node, diagram.relations[1].dst);
    try testing.expect(diagram.relations[0].src != diagram.relations[1].src);
}

test "state diagrams parse concurrent composite regions" {
    const diagram = parseText(
        "stateDiagram-v2\n" ++
            "state Active {\n" ++
            "direction LR\n" ++
            "[*] --> NumLockOff\n" ++
            "NumLockOff --> NumLockOn\n" ++
            "NumLockOn --> NumLockOff\n" ++
            "--\n" ++
            "[*] --> CapsLockOff\n" ++
            "state CapsLockOn {\n" ++
            "[*] --> Lit\n" ++
            "Lit --> [*]\n" ++
            "}\n" ++
            "CapsLockOff --> CapsLockOn\n" ++
            "}\n",
    ).?;
    try testing.expectEqual(@as(usize, 2), diagram.group_count);
    try testing.expectEqual(@as(usize, 10), diagram.node_count);
    try testing.expectEqual(@as(usize, 7), diagram.relation_count);
    try testing.expectEqual(@as(usize, 2), diagram.groups[0].region_count);
    try testing.expectEqual(@as(usize, 1), diagram.groups[1].region_count);
    try testing.expectEqual(@as(usize, 0), diagram.nodes[1].region);
    try testing.expectEqual(@as(usize, 1), diagram.nodes[4].region);
    try testing.expect(diagram.relations[0].src != diagram.relations[3].src);
    try testing.expectEqual(@as(?usize, 0), diagram.nodes[diagram.groups[1].node].group);
    try testing.expectEqual(@as(usize, 1), diagram.nodes[diagram.groups[1].node].region);
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

test "er diagrams parse nested subgraphs and group relationships" {
    const diagram = parseText(
        "erDiagram\n" ++
            "direction LR\n" ++
            "sales ||--|| support : collaborates\n" ++
            "subgraph sales [Sales Domain]\n" ++
            "direction TB\n" ++
            "CUSTOMER ||--o{ ORDER : places\n" ++
            "subgraph fulfillment\n" ++
            "SHIPMENT ||--|{ ITEM : contains\n" ++
            "end\n" ++
            "end\n" ++
            "subgraph support\n" ++
            "AGENT\n" ++
            "end\n" ++
            "support ||--o{ ITEM : handles\n",
    ).?;
    try testing.expectEqual(@as(usize, 3), diagram.group_count);
    try testing.expectEqual(@as(usize, 8), diagram.node_count);
    try testing.expectEqual(@as(usize, 4), diagram.relation_count);
    try testing.expect(diagram.nodes[diagram.groups[0].node].kind == .er_group);
    try testing.expectEqualStrings("Sales Domain", diagram.nodes[diagram.groups[0].node].label);
    try testing.expectEqual(@as(?usize, 0), diagram.nodes[diagram.groups[1].node].group);
    try testing.expect(diagram.nodes[diagram.groups[2].node].group == null);
    try testing.expectEqual(@as(?Direction, .tb), diagram.groups[0].direction);
    try testing.expectEqual(diagram.groups[0].node, diagram.relations[0].src);
    try testing.expectEqual(diagram.groups[2].node, diagram.relations[0].dst);
    try testing.expectEqual(diagram.groups[2].node, diagram.relations[3].src);
    try testing.expectEqual(@as(?usize, 1), diagram.nodes[diagram.relations[3].dst].group);
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
    try testing.expect(parseText("classDiagram\nnamespace Company.Engineering {\nclass A\n}\n") == null);
    try testing.expect(parseText("stateDiagram-v2\nstate Parent {\n") == null);
    try testing.expect(parseText("stateDiagram-v2\n--\nA\n") == null);
    try testing.expect(parseText("stateDiagram-v2\nstate Parent {\nA\n--\n}\n") == null);
    try testing.expect(parseText("stateDiagram-v2\nstate Parent {\nA\n--\nA --> B\n}\n") == null);
    try testing.expect(parseText("erDiagram\nCUSTOMER {\nstring id\n") == null);
    try testing.expect(parseText("erDiagram\nsales\nsubgraph sales\nCUSTOMER\nend\n") == null);
    try testing.expect(parseText("erDiagram\nsubgraph sales\nCUSTOMER\n") == null);
}

const testing = std.testing;
