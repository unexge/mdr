//! Unicode flowchart renderer: layered boxes joined by orthogonal edges.
//!
//! compute verifies the whole diagram before anything is drawn; diagrams
//! that do not fit or contain cycles return null and the caller falls back
//! to the code card. Adjacent layers connect directly; skip-level edges
//! travel along one spare wire row or column. Crossings merge into junctions.

const Mermaid = @import("../../Mermaid.zig");
const cells = @import("cells.zig");
const vaxis = @import("vaxis");

pub const max_rows = 200;

const Bounds = struct {
    x1: usize,
    y1: usize,
    x2: usize,
    y2: usize,

    fn width(self: Bounds) usize {
        return self.x2 - self.x1 + 1;
    }

    fn height(self: Bounds) usize {
        return self.y2 - self.y1 + 1;
    }
};

pub fn layout(win: ?vaxis.Window, flow: *const Mermaid.Flowchart, start_row: usize, skip: usize, width: usize) ?usize {
    if (flow.needsHierarchicalLayout()) {
        var hierarchy = Hierarchy.compute(flow, width) orelse return null;
        if (win == null) return start_row + hierarchy.rows;
        const w = win.?;
        hierarchy.draw(w, start_row, skip);
        return start_row + @min(hierarchy.rows -| skip, w.height -| start_row);
    }
    var grid = Grid.compute(flow, width) orelse return null;
    if (win == null) return start_row + grid.rows;
    const w = win.?;
    grid.draw(w, start_row, skip);
    return start_row + @min(grid.rows -| skip, w.height -| start_row);
}

const max_hierarchy_items = Mermaid.max_nodes + Mermaid.max_subgraphs;

const Size = struct { width: usize, height: usize };

const HierarchyItem = union(enum) {
    node: usize,
    subgraph: usize,
};

const HierarchyEndpoint = struct {
    bounds: Bounds,
    node: ?usize = null,
};

const HierarchySegment = struct {
    r1: usize,
    c1: usize,
    r2: usize,
    c2: usize,
    glyph: []const u8,
};

const HierarchyPath = struct {
    segments: [3]HierarchySegment = undefined,
    count: usize = 0,
    src_at: CellPos,
    dst_at: CellPos,
    src_arrow: []const u8,
    dst_arrow: []const u8,
    src_line: []const u8,
    dst_line: []const u8,
    label: ?LabelAt = null,

    fn add(self: *HierarchyPath, segment: HierarchySegment) void {
        if ((segment.r1 > segment.r2 and segment.c1 == segment.c2) or
            (segment.c1 > segment.c2 and segment.r1 == segment.r2)) return;
        self.segments[self.count] = segment;
        self.count += 1;
    }
};

fn hierarchyGap(flow: *const Mermaid.Flowchart) usize {
    var min_length: usize = 1;
    for (flow.edgeList()) |edge| min_length = @max(min_length, edge.min_length);
    return 3 + 2 * (min_length - 1);
}

const Hierarchy = struct {
    flow: *const Mermaid.Flowchart,
    node_widths: [Mermaid.max_nodes]usize,
    node_bounds: [Mermaid.max_nodes]Bounds,
    subgraph_sizes: [Mermaid.max_subgraphs]Size,
    subgraph_bounds: [Mermaid.max_subgraphs]Bounds,
    subgraph_directions: [Mermaid.max_subgraphs]Mermaid.Direction,
    gap: usize,
    rows: usize,
    cols: usize,

    fn compute(flow: *const Mermaid.Flowchart, width: usize) ?Hierarchy {
        if (flow.degraded or flow.node_count == 0) return null;
        var hierarchy: Hierarchy = .{
            .flow = flow,
            .node_widths = [_]usize{0} ** Mermaid.max_nodes,
            .node_bounds = undefined,
            .subgraph_sizes = undefined,
            .subgraph_bounds = undefined,
            .subgraph_directions = undefined,
            .gap = hierarchyGap(flow),
            .rows = 0,
            .cols = 0,
        };
        for (flow.nodeList(), 0..) |node, index| hierarchy.node_widths[index] = cells.labelWidth(node.label) + 4;
        const root_size = hierarchy.measureItems(null, flow.direction) orelse return null;
        hierarchy.rows = root_size.height + 2;
        hierarchy.cols = root_size.width + 2;
        if (hierarchy.rows > max_rows or hierarchy.cols > width) return null;
        hierarchy.placeItems(null, flow.direction, .{ .x1 = 1, .y1 = 1, .x2 = root_size.width, .y2 = root_size.height });
        for (flow.edgeList()) |*edge| _ = hierarchy.route(edge) orelse return null;
        return hierarchy;
    }

    fn collectItems(self: *const Hierarchy, parent: ?usize, items: *[max_hierarchy_items]HierarchyItem) usize {
        var count: usize = 0;
        for (self.flow.nodeList(), 0..) |node, index| {
            if (node.subgraph == parent) {
                items[count] = .{ .node = index };
                count += 1;
            }
        }
        for (self.flow.subgraphList(), 0..) |subgraph, index| {
            if (subgraph.parent == parent) {
                items[count] = .{ .subgraph = index };
                count += 1;
            }
        }
        var i: usize = 1;
        while (i < count) : (i += 1) {
            const item = items[i];
            const order = self.itemOrder(item);
            var j = i;
            while (j > 0 and self.itemOrder(items[j - 1]) > order) : (j -= 1) items[j] = items[j - 1];
            items[j] = item;
        }
        return count;
    }

    fn itemOrder(self: *const Hierarchy, item: HierarchyItem) usize {
        return switch (item) {
            .node => |index| self.flow.nodes[index].order,
            .subgraph => |index| self.flow.subgraphs[index].order,
        };
    }

    fn measureItems(self: *Hierarchy, parent: ?usize, direction: Mermaid.Direction) ?Size {
        var items: [max_hierarchy_items]HierarchyItem = undefined;
        const count = self.collectItems(parent, &items);
        if (count == 0) return null;
        const horizontal = direction == .lr or direction == .rl;
        var primary: usize = 0;
        var cross: usize = 0;
        for (items[0..count]) |item| {
            const size = self.measureItem(item, direction) orelse return null;
            primary += if (horizontal) size.width else size.height;
            cross = @max(cross, if (horizontal) size.height else size.width);
        }
        primary += self.gap * (count - 1);
        return if (horizontal)
            .{ .width = primary, .height = cross }
        else
            .{ .width = cross, .height = primary };
    }

    fn measureItem(self: *Hierarchy, item: HierarchyItem, parent_direction: Mermaid.Direction) ?Size {
        return switch (item) {
            .node => |index| .{ .width = self.node_widths[index], .height = 3 },
            .subgraph => |index| blk: {
                const subgraph = self.flow.subgraphs[index];
                const direction = subgraph.direction orelse parent_direction;
                self.subgraph_directions[index] = direction;
                const content = self.measureItems(index, direction) orelse return null;
                const size: Size = .{
                    .width = @max(content.width + 2, cells.labelWidth(subgraph.label) + 4),
                    .height = content.height + 3,
                };
                self.subgraph_sizes[index] = size;
                break :blk size;
            },
        };
    }

    fn itemSize(self: *const Hierarchy, item: HierarchyItem) Size {
        return switch (item) {
            .node => |index| .{ .width = self.node_widths[index], .height = 3 },
            .subgraph => |index| self.subgraph_sizes[index],
        };
    }

    fn placeItems(self: *Hierarchy, parent: ?usize, direction: Mermaid.Direction, area: Bounds) void {
        var items: [max_hierarchy_items]HierarchyItem = undefined;
        const count = self.collectItems(parent, &items);
        const horizontal = direction == .lr or direction == .rl;
        var primary: usize = 0;
        for (items[0..count]) |item| {
            const size = self.itemSize(item);
            primary += if (horizontal) size.width else size.height;
        }
        primary += self.gap * (count - 1);
        const forward = direction == .lr or direction == .tb;
        var cursor = if (horizontal)
            area.x1 + (area.width() - primary) / 2
        else
            area.y1 + (area.height() - primary) / 2;
        if (!forward) cursor += primary;
        for (items[0..count]) |item| {
            const size = self.itemSize(item);
            const item_primary = if (horizontal) size.width else size.height;
            const position = if (forward) cursor else cursor - item_primary;
            const x = if (horizontal) position else area.x1 + (area.width() - size.width) / 2;
            const y = if (horizontal) area.y1 + (area.height() - size.height) / 2 else position;
            self.placeItem(item, x, y);
            if (forward) cursor += item_primary + self.gap else cursor = position -| self.gap;
        }
    }

    fn placeItem(self: *Hierarchy, item: HierarchyItem, x: usize, y: usize) void {
        switch (item) {
            .node => |index| {
                self.node_bounds[index] = .{ .x1 = x, .y1 = y, .x2 = x + self.node_widths[index] - 1, .y2 = y + 2 };
            },
            .subgraph => |index| {
                const size = self.subgraph_sizes[index];
                self.subgraph_bounds[index] = .{ .x1 = x, .y1 = y, .x2 = x + size.width - 1, .y2 = y + size.height - 1 };
                self.placeItems(index, self.subgraph_directions[index], .{
                    .x1 = x + 1,
                    .y1 = y + 2,
                    .x2 = x + size.width - 2,
                    .y2 = y + size.height - 2,
                });
            },
        }
    }

    fn endpoint(self: *const Hierarchy, id: []const u8) ?HierarchyEndpoint {
        if (nodeIndex(self.flow, id)) |index| return .{ .bounds = self.node_bounds[index], .node = index };
        if (self.flow.subgraphIndex(id)) |index| return .{ .bounds = self.subgraph_bounds[index] };
        return null;
    }

    fn route(self: *const Hierarchy, edge: *const Mermaid.Edge) ?HierarchyPath {
        const source = self.endpoint(edge.src) orelse return null;
        const destination = self.endpoint(edge.dst) orelse return null;
        if (source.bounds.x1 == destination.bounds.x1 and source.bounds.y1 == destination.bounds.y1 and
            source.bounds.x2 == destination.bounds.x2 and source.bounds.y2 == destination.bounds.y2) return null;
        const source_center = CellPos{ .r = (source.bounds.y1 + source.bounds.y2) / 2, .c = (source.bounds.x1 + source.bounds.x2) / 2 };
        const destination_center = CellPos{ .r = (destination.bounds.y1 + destination.bounds.y2) / 2, .c = (destination.bounds.x1 + destination.bounds.x2) / 2 };
        const dx = if (source_center.c > destination_center.c) source_center.c - destination_center.c else destination_center.c - source_center.c;
        const dy = if (source_center.r > destination_center.r) source_center.r - destination_center.r else destination_center.r - source_center.r;
        var path: HierarchyPath = undefined;
        path.count = 0;
        path.label = null;
        if (dx >= dy) {
            const right = destination_center.c > source_center.c;
            const src_at = CellPos{ .r = source_center.r, .c = if (right) source.bounds.x2 + 1 else source.bounds.x1 - 1 };
            const dst_at = CellPos{ .r = destination_center.r, .c = if (right) destination.bounds.x1 - 1 else destination.bounds.x2 + 1 };
            const mid = (src_at.c + dst_at.c) / 2;
            path.src_at = src_at;
            path.dst_at = dst_at;
            path.src_arrow = if (right) "◄" else "►";
            path.dst_arrow = if (right) "►" else "◄";
            path.src_line = "─";
            path.dst_line = "─";
            path.add(.{ .r1 = src_at.r, .c1 = @min(src_at.c, mid), .r2 = src_at.r, .c2 = @max(src_at.c, mid), .glyph = "─" });
            path.add(.{ .r1 = @min(src_at.r, dst_at.r), .c1 = mid, .r2 = @max(src_at.r, dst_at.r), .c2 = mid, .glyph = "│" });
            path.add(.{ .r1 = dst_at.r, .c1 = @min(mid, dst_at.c), .r2 = dst_at.r, .c2 = @max(mid, dst_at.c), .glyph = "─" });
            if (edge.label) |label| {
                const label_width = cells.labelWidth(label);
                const start = @min(src_at.c, dst_at.c);
                const span = if (@max(src_at.c, dst_at.c) > start) @max(src_at.c, dst_at.c) - start else 0;
                if (label_width > span) return null;
                path.label = .{ .r = src_at.r, .c = start + (span - label_width) / 2, .text = label };
            }
        } else {
            const down = destination_center.r > source_center.r;
            const src_at = CellPos{ .r = if (down) source.bounds.y2 + 1 else source.bounds.y1 - 1, .c = source_center.c };
            const dst_at = CellPos{ .r = if (down) destination.bounds.y1 - 1 else destination.bounds.y2 + 1, .c = destination_center.c };
            const mid = (src_at.r + dst_at.r) / 2;
            path.src_at = src_at;
            path.dst_at = dst_at;
            path.src_arrow = if (down) "▲" else "▼";
            path.dst_arrow = if (down) "▼" else "▲";
            path.src_line = "│";
            path.dst_line = "│";
            path.add(.{ .r1 = @min(src_at.r, mid), .c1 = src_at.c, .r2 = @max(src_at.r, mid), .c2 = src_at.c, .glyph = "│" });
            path.add(.{ .r1 = mid, .c1 = @min(src_at.c, dst_at.c), .r2 = mid, .c2 = @max(src_at.c, dst_at.c), .glyph = "─" });
            path.add(.{ .r1 = @min(mid, dst_at.r), .c1 = dst_at.c, .r2 = @max(mid, dst_at.r), .c2 = dst_at.c, .glyph = "│" });
            if (edge.label) |label| {
                const label_width = cells.labelWidth(label);
                if (dst_at.c + 2 + label_width > self.cols) return null;
                path.label = .{ .r = mid, .c = dst_at.c + 2, .text = label };
            }
        }
        for (path.segments[0..path.count]) |segment| {
            for (self.flow.nodeList(), 0..) |_, index| {
                if (source.node == index or destination.node == index) continue;
                if (segmentIntersectsBounds(segment, self.node_bounds[index])) return null;
            }
        }
        return path;
    }

    fn draw(self: *const Hierarchy, win: vaxis.Window, start_row: usize, skip: usize) void {
        for (self.flow.subgraphList(), 0..) |subgraph, index| drawFrame(win, self.subgraph_bounds[index], subgraph.label, start_row, skip);
        for (self.flow.nodeList(), 0..) |*node, index| drawNodeBox(win, node, self.node_bounds[index], start_row, skip);
        for (self.flow.edgeList()) |*edge| {
            if (edge.style == .invisible) continue;
            const path = self.route(edge) orelse continue;
            for (path.segments[0..path.count]) |segment| drawHierarchySegment(win, segment, start_row, skip);
            drawMarker(win, path.src_at, edge.src_marker, path.src_arrow, path.src_line, start_row, skip);
            drawMarker(win, path.dst_at, edge.dst_marker, path.dst_arrow, path.dst_line, start_row, skip);
        }
        for (self.flow.edgeList()) |*edge| {
            if (edge.style == .invisible) continue;
            const path = self.route(edge) orelse continue;
            if (path.label) |label| cells.putText(win, label.r, label.c, start_row, skip, label.text, self.cols, .{});
        }
    }
};

fn segmentIntersectsBounds(segment: HierarchySegment, bounds: Bounds) bool {
    if (segment.r1 == segment.r2) {
        return segment.r1 >= bounds.y1 and segment.r1 <= bounds.y2 and segment.c1 <= bounds.x2 and segment.c2 >= bounds.x1;
    }
    return segment.c1 >= bounds.x1 and segment.c1 <= bounds.x2 and segment.r1 <= bounds.y2 and segment.r2 >= bounds.y1;
}

fn drawHierarchySegment(win: vaxis.Window, segment: HierarchySegment, start_row: usize, skip: usize) void {
    if (segment.r1 == segment.r2) {
        var col = segment.c1;
        while (col <= segment.c2) : (col += 1) cells.putLine(win, segment.r1, col, start_row, skip, segment.glyph, .{});
    } else {
        var row = segment.r1;
        while (row <= segment.r2) : (row += 1) cells.putLine(win, row, segment.c1, start_row, skip, segment.glyph, .{});
    }
}

fn subgraphPadding(flow: *const Mermaid.Flowchart) usize {
    var padding: usize = 0;
    for (flow.subgraphList()) |subgraph| padding = @max(padding, subgraph.level + 1);
    return padding;
}

fn subgraphInSubgraph(flow: *const Mermaid.Flowchart, child: usize, parent: usize) bool {
    var current: ?usize = child;
    while (current) |index| {
        if (index == parent) return true;
        current = flow.subgraphs[index].parent;
    }
    return false;
}

fn boundsIntersect(a: Bounds, b: Bounds) bool {
    return a.x1 <= b.x2 and b.x1 <= a.x2 and a.y1 <= b.y2 and b.y1 <= a.y2;
}

const Grid = struct {
    flow: *const Mermaid.Flowchart,
    vertical: bool,
    forward: bool,
    count: usize,
    rank: [Mermaid.max_nodes]usize,
    slot: [Mermaid.max_nodes]usize,
    n_layers: usize,
    n_cross: usize,
    w: [Mermaid.max_nodes]usize,
    x: [Mermaid.max_nodes]usize,
    y: [Mermaid.max_nodes]usize,
    fwd: [Mermaid.max_nodes + 1]usize,
    cpos: [Mermaid.max_nodes + 1]usize,
    cw: [Mermaid.max_nodes]usize,
    glabels: [Mermaid.max_nodes]usize,
    lrow: [Mermaid.max_edges]usize,
    lmax: [Mermaid.max_nodes]usize,
    subgraphs: [Mermaid.max_subgraphs]Bounds,
    pad: usize,
    wire: ?usize,
    rows: usize,
    cols: usize,

    fn compute(flow: *const Mermaid.Flowchart, width: usize) ?Grid {
        if (flow.degraded or flow.node_count == 0) return null;
        var grid: Grid = .{
            .flow = flow,
            .vertical = flow.direction == .tb or flow.direction == .bt,
            .forward = flow.direction == .tb or flow.direction == .lr,
            .count = flow.node_count,
            .rank = [_]usize{0} ** Mermaid.max_nodes,
            .slot = [_]usize{0} ** Mermaid.max_nodes,
            .n_layers = 0,
            .n_cross = 0,
            .w = [_]usize{0} ** Mermaid.max_nodes,
            .x = [_]usize{0} ** Mermaid.max_nodes,
            .y = [_]usize{0} ** Mermaid.max_nodes,
            .fwd = [_]usize{0} ** (Mermaid.max_nodes + 1),
            .cpos = [_]usize{0} ** (Mermaid.max_nodes + 1),
            .cw = [_]usize{0} ** Mermaid.max_nodes,
            .glabels = [_]usize{0} ** Mermaid.max_nodes,
            .lrow = [_]usize{0} ** Mermaid.max_edges,
            .lmax = [_]usize{0} ** Mermaid.max_nodes,
            .subgraphs = undefined,
            .pad = subgraphPadding(flow),
            .wire = null,
            .rows = 0,
            .cols = 0,
        };
        for (flow.nodeList(), 0..) |node, i| grid.w[i] = cells.labelWidth(node.label) + 4;
        grid.computeRanks();
        if (grid.vertical) {
            grid.layoutVertical(width) orelse return null;
        } else {
            grid.layoutHorizontal(width) orelse return null;
        }
        grid.applySubgraphPadding(width) orelse return null;
        grid.computeSubgraphBounds() orelse return null;
        if (grid.vertical) {
            for (flow.edgeList()) |*edge| {
                const s = nodeIndex(flow, edge.src) orelse continue;
                const d = nodeIndex(flow, edge.dst) orelse continue;
                if (grid.rank[d] <= grid.rank[s]) continue;
                if (grid.labelInfo(edge)) |info| {
                    grid.cols = @max(grid.cols, info.c + cells.labelWidth(info.text));
                }
            }
            if (grid.cols > width) return null;
        }
        for (flow.edgeList()) |*edge| {
            _ = grid.route(edge) orelse return null;
        }
        if (!grid.vertical) {
            grid.checkHorizontalLabels() orelse return null;
        }
        return grid;
    }

    fn computeRanks(self: *Grid) void {
        const cap = Mermaid.max_nodes - 1;
        for (0..self.count) |_| {
            for (self.flow.edgeList()) |*edge| {
                const s = nodeIndex(self.flow, edge.src) orelse continue;
                const d = nodeIndex(self.flow, edge.dst) orelse continue;
                if (s == d) continue;
                const r = @min(self.rank[s] + edge.min_length, cap);
                if (r > self.rank[d]) self.rank[d] = r;
            }
        }
        var max: usize = 0;
        for (self.rank[0..self.count]) |r| max = @max(max, r);
        self.n_layers = max + 1;
        var counts = [_]usize{0} ** Mermaid.max_nodes;
        for (0..self.count) |i| {
            self.slot[i] = counts[self.rank[i]];
            counts[self.rank[i]] += 1;
        }
        for (counts[0..self.n_layers]) |c| self.n_cross = @max(self.n_cross, c);
    }

    fn hasLongEdge(self: *const Grid) bool {
        for (self.flow.edgeList()) |*edge| {
            const s = nodeIndex(self.flow, edge.src) orelse continue;
            const d = nodeIndex(self.flow, edge.dst) orelse continue;
            if (self.rank[d] > self.rank[s] + 1) return true;
        }
        return false;
    }

    fn layoutVertical(self: *Grid, width: usize) ?void {
        for (0..self.n_cross) |c| {
            var cw: usize = 0;
            for (0..self.count) |i| {
                if (self.slot[i] == c) cw = @max(cw, self.w[i]);
            }
            self.cw[c] = cw;
        }
        const cross_gap = 3 + 2 * self.pad;
        var cols: usize = 0;
        for (0..self.n_cross) |c| {
            self.cpos[c] = cols;
            cols += self.cw[c] + cross_gap;
        }
        cols -|= cross_gap;
        for (0..self.count) |i| {
            self.x[i] = self.cpos[self.slot[i]] + (self.cw[self.slot[i]] - self.w[i]) / 2;
        }
        self.assignLabelRows();
        self.fwd[0] = 0;
        for (0..self.n_layers) |l| {
            self.fwd[l + 1] = self.fwd[l] + 3 + 2 + 2 * self.pad + self.glabels[l];
        }
        self.rows = self.fwd[self.n_layers - 1] + 3;
        if (self.rows > max_rows) return null;
        if (self.hasLongEdge()) {
            self.wire = cols;
            cols += 1;
        }
        if (cols > width) return null;
        self.cols = cols;
        for (0..self.count) |i| {
            const y = self.fwd[self.rank[i]];
            self.y[i] = if (self.forward) y else self.rows - 3 - y;
        }
    }

    fn layoutHorizontal(self: *Grid, width: usize) ?void {
        for (self.flow.edgeList()) |*edge| {
            const text = edge.label orelse continue;
            const s = nodeIndex(self.flow, edge.src) orelse continue;
            const d = nodeIndex(self.flow, edge.dst) orelse continue;
            if (self.rank[d] <= self.rank[s]) continue;
            const g = self.rank[d] - 1;
            self.lmax[g] = @max(self.lmax[g], cells.labelWidth(text));
        }
        const forward_gap = 4 + 2 * self.pad;
        self.fwd[0] = 0;
        for (0..self.n_layers) |l| {
            self.fwd[l + 1] = self.fwd[l] + self.bandWidth(l) + forward_gap + if (self.lmax[l] > 0) self.lmax[l] + 1 else 0;
        }
        const cols = self.fwd[self.n_layers] -| forward_gap;
        for (0..self.count) |i| {
            const fx = self.fwd[self.rank[i]];
            const bw = self.bandWidth(self.rank[i]);
            const bx = if (self.forward) fx else cols - (fx + bw);
            self.x[i] = bx + (bw - self.w[i]) / 2;
        }
        self.cpos[0] = 0;
        for (0..self.n_cross) |t| {
            self.cpos[t + 1] = self.cpos[t] + 3 + 2 * self.pad;
        }
        self.rows = self.cpos[self.n_cross - 1] + 3;
        if (self.hasLongEdge()) {
            self.wire = self.rows;
            self.rows += 1;
        }
        if (self.rows > max_rows) return null;
        self.cols = cols;
        if (self.cols > width) return null;
        for (0..self.count) |i| self.y[i] = self.cpos[self.slot[i]];
    }

    fn applySubgraphPadding(self: *Grid, width: usize) ?void {
        if (self.pad == 0) return;
        for (0..self.count) |i| {
            self.x[i] += self.pad;
            self.y[i] += self.pad;
        }
        for (self.fwd[0 .. self.n_layers + 1]) |*position| position.* += self.pad;
        for (self.cpos[0 .. self.n_cross + 1]) |*position| position.* += self.pad;
        if (self.wire) |*wire| wire.* += self.pad;
        self.rows += 2 * self.pad;
        self.cols += 2 * self.pad;
        if (self.rows > max_rows or self.cols > width) return null;
    }

    fn computeSubgraphBounds(self: *Grid) ?void {
        for (self.flow.subgraphList(), 0..) |_, subgraph_index| {
            var found = false;
            var x1: usize = self.cols;
            var y1: usize = self.rows;
            var x2: usize = 0;
            var y2: usize = 0;
            for (self.flow.nodeList(), 0..) |*node, node_index| {
                if (!self.flow.nodeInSubgraph(node, subgraph_index)) continue;
                found = true;
                x1 = @min(x1, self.x[node_index]);
                y1 = @min(y1, self.y[node_index]);
                x2 = @max(x2, self.x[node_index] + self.w[node_index] - 1);
                y2 = @max(y2, self.y[node_index] + 2);
            }
            if (!found) return null;
            const expansion = self.subgraphExpansion(subgraph_index);
            self.subgraphs[subgraph_index] = .{
                .x1 = x1 - expansion,
                .y1 = y1 - expansion,
                .x2 = x2 + expansion,
                .y2 = y2 + expansion,
            };
        }
        for (self.flow.subgraphList(), 0..) |_, subgraph_index| {
            const bounds = self.subgraphs[subgraph_index];
            for (self.flow.nodeList(), 0..) |*node, node_index| {
                if (self.flow.nodeInSubgraph(node, subgraph_index)) continue;
                const node_bounds: Bounds = .{
                    .x1 = self.x[node_index],
                    .y1 = self.y[node_index],
                    .x2 = self.x[node_index] + self.w[node_index] - 1,
                    .y2 = self.y[node_index] + 2,
                };
                if (boundsIntersect(bounds, node_bounds)) return null;
            }
            for (self.flow.subgraphList()[subgraph_index + 1 ..], subgraph_index + 1..) |_, other_index| {
                if (subgraphInSubgraph(self.flow, other_index, subgraph_index) or
                    subgraphInSubgraph(self.flow, subgraph_index, other_index)) continue;
                if (boundsIntersect(bounds, self.subgraphs[other_index])) return null;
            }
        }
    }

    fn subgraphExpansion(self: *const Grid, subgraph: usize) usize {
        var deepest = self.flow.subgraphs[subgraph].level;
        for (self.flow.subgraphList(), 0..) |candidate, candidate_index| {
            if (subgraphInSubgraph(self.flow, candidate_index, subgraph)) deepest = @max(deepest, candidate.level);
        }
        return deepest - self.flow.subgraphs[subgraph].level + 1;
    }

    fn bandWidth(self: *const Grid, layer: usize) usize {
        var bw: usize = 0;
        for (0..self.count) |i| {
            if (self.rank[i] == layer) bw = @max(bw, self.w[i]);
        }
        return bw;
    }

    fn assignLabelRows(self: *Grid) void {
        for (self.flow.edgeList(), 0..) |*edge, i| {
            const text = edge.label orelse continue;
            const s = nodeIndex(self.flow, edge.src) orelse continue;
            const d = nodeIndex(self.flow, edge.dst) orelse continue;
            if (self.rank[d] <= self.rank[s]) continue;
            const c = self.x[d] + self.w[d] / 2 + 2;
            const end = c + cells.labelWidth(text);
            var r: usize = 0;
            while (self.labelRowTaken(s, i, r, c, end)) r += 1;
            self.lrow[i] = r;
            self.glabels[self.rank[s]] = @max(self.glabels[self.rank[s]], r + 1);
        }
    }

    fn labelRowTaken(self: *const Grid, s: usize, upto: usize, r: usize, c: usize, end: usize) bool {
        for (self.flow.edgeList()[0..upto], 0..) |*other, j| {
            if (other.label == null or self.lrow[j] != r) continue;
            const os = nodeIndex(self.flow, other.src) orelse continue;
            if (self.rank[os] != self.rank[s]) continue;
            const od = nodeIndex(self.flow, other.dst) orelse continue;
            const oc = self.x[od] + self.w[od] / 2 + 2;
            const oend = oc + cells.labelWidth(other.label.?);
            if (c < oend and oc < end) return true;
        }
        return false;
    }

    fn route(self: *const Grid, edge: *const Mermaid.Edge) ?Walk {
        const s = nodeIndex(self.flow, edge.src) orelse return null;
        const d = nodeIndex(self.flow, edge.dst) orelse return null;
        if (self.rank[s] >= self.rank[d]) return null;
        if (self.rank[d] == self.rank[s] + 1) {
            if (self.vertical) return self.routeAdjacentV(edge, s, d) else return self.routeAdjacentH(edge, s, d);
        }
        const wire = self.wire orelse return null;
        return self.routeLong(edge, s, d, wire);
    }

    fn routeAdjacentV(self: *const Grid, edge: *const Mermaid.Edge, s: usize, d: usize) Walk {
        const cx_s = self.x[s] + self.w[s] / 2;
        const cx_d = self.x[d] + self.w[d] / 2;
        const drift = if (cx_s > cx_d) cx_s - cx_d else cx_d - cx_s;
        const straight = drift <= 2;
        var walk: Walk = .{};
        if (self.forward) {
            const fan = self.y[s] + 3;
            const span = self.y[d] - 1;
            if (straight) {
                walk.vrun(cx_s, fan, span -| 1, "│");
                walk.arrow_at = .{ .r = span, .c = cx_s };
            } else if (cx_s < cx_d) {
                walk.hrun(fan, cx_s + 1, cx_d -| 1, "─");
                walk.dot(fan, cx_s, "└");
                walk.dot(fan, cx_d, "┐");
                walk.vrun(cx_d, fan + 1, span -| 1, "│");
                walk.arrow_at = .{ .r = span, .c = cx_d };
            } else {
                walk.hrun(fan, cx_d + 1, cx_s -| 1, "─");
                walk.dot(fan, cx_s, "┘");
                walk.dot(fan, cx_d, "┌");
                walk.vrun(cx_d, fan + 1, span -| 1, "│");
                walk.arrow_at = .{ .r = span, .c = cx_d };
            }
            walk.arrow = "▼";
            walk.label = self.labelInfo(edge);
        } else {
            const fan = self.y[s] - 1;
            const span = self.y[d] + 3;
            if (straight) {
                walk.vrun(cx_s, span + 1, fan, "│");
                walk.arrow_at = .{ .r = span, .c = cx_s };
            } else if (cx_s < cx_d) {
                walk.hrun(fan, cx_s + 1, cx_d -| 1, "─");
                walk.dot(fan, cx_s, "┌");
                walk.dot(fan, cx_d, "┘");
                walk.vrun(cx_d, span + 1, fan -| 1, "│");
                walk.arrow_at = .{ .r = span, .c = cx_d };
            } else {
                walk.hrun(fan, cx_d + 1, cx_s -| 1, "─");
                walk.dot(fan, cx_s, "┐");
                walk.dot(fan, cx_d, "└");
                walk.vrun(cx_d, span + 1, fan -| 1, "│");
                walk.arrow_at = .{ .r = span, .c = cx_d };
            }
            walk.arrow = "▲";
            walk.label = self.labelInfo(edge);
        }
        return walk;
    }

    fn routeAdjacentH(self: *const Grid, edge: *const Mermaid.Edge, s: usize, d: usize) Walk {
        const mr_s = self.y[s] + 1;
        const mr_d = self.y[d] + 1;
        var walk: Walk = .{};
        if (self.forward) {
            const span = self.fwd[self.rank[s]] + self.bandWidth(self.rank[s]) + 1;
            const arrow_c = self.x[d] - 1;
            if (mr_s == mr_d) {
                walk.hrun(mr_s, self.x[s] + self.w[s], arrow_c - 1, "─");
            } else {
                walk.hrun(mr_s, self.x[s] + self.w[s], span -| 1, "─");
                walk.vrun(span, @min(mr_s, mr_d) + 1, @max(mr_s, mr_d) -| 1, "│");
                walk.dot(mr_s, span, if (mr_s < mr_d) "┐" else "┘");
                walk.hrun(mr_d, span + 1, arrow_c - 1, "─");
                walk.dot(mr_d, span, if (mr_s < mr_d) "└" else "┌");
            }
            walk.arrow_at = .{ .r = mr_d, .c = arrow_c };
            walk.arrow = "►";
        } else {
            const span = self.cols - 1 - (self.fwd[self.rank[s]] + self.bandWidth(self.rank[s]) + 1);
            const arrow_c = self.x[d] + self.w[d];
            if (mr_s == mr_d) {
                walk.hrun(mr_s, arrow_c, self.x[s] - 1, "─");
            } else {
                walk.hrun(mr_s, span + 1, self.x[s] - 1, "─");
                walk.vrun(span, @min(mr_s, mr_d) + 1, @max(mr_s, mr_d) -| 1, "│");
                walk.dot(mr_s, span, if (mr_s < mr_d) "┌" else "└");
                walk.hrun(mr_d, arrow_c, span -| 1, "─");
                walk.dot(mr_d, span, if (mr_s < mr_d) "┘" else "┐");
            }
            walk.arrow_at = .{ .r = mr_d, .c = arrow_c };
            walk.arrow = "◄";
        }
        walk.label = self.labelInfo(edge);
        return walk;
    }

    fn routeLong(self: *const Grid, edge: *const Mermaid.Edge, s: usize, d: usize, wire: usize) Walk {
        var walk: Walk = .{};
        if (self.vertical) {
            const cx_s = self.x[s] + self.w[s] / 2;
            const cx_d = self.x[d] + self.w[d] / 2;
            if (self.forward) {
                const js = self.y[s] + 3;
                const jd = self.y[d] - 1;
                walk.hrun(js, cx_s + 1, wire -| 1, "─");
                walk.dot(js, cx_s, "└");
                walk.dot(js, wire, "┐");
                walk.vrun(wire, js + 1, jd -| 1, "│");
                walk.hrun(jd, cx_d + 1, wire -| 1, "─");
                walk.dot(jd, wire, "┘");
                walk.arrow_at = .{ .r = jd, .c = cx_d };
                walk.arrow = "▼";
                walk.label = self.labelInfo(edge);
            } else {
                const js = self.y[s] - 1;
                const jd = self.y[d] + 3;
                walk.hrun(js, cx_s + 1, wire -| 1, "─");
                walk.dot(js, cx_s, "┌");
                walk.dot(js, wire, "┘");
                walk.vrun(wire, jd + 1, js -| 1, "│");
                walk.hrun(jd, cx_d + 1, wire -| 1, "─");
                walk.dot(jd, wire, "┐");
                walk.arrow_at = .{ .r = jd, .c = cx_d };
                walk.arrow = "▲";
                walk.label = self.labelInfo(edge);
            }
        } else {
            const mr_s = self.y[s] + 1;
            const mr_d = self.y[d] + 1;
            const cs = self.fwd[self.rank[s]] + self.bandWidth(self.rank[s]) + 1;
            const cd = self.fwd[self.rank[d] - 1] + self.bandWidth(self.rank[d] - 1) + 1;
            if (self.forward) {
                walk.hrun(mr_s, self.x[s] + self.w[s], cs -| 1, "─");
                walk.dot(mr_s, cs, "┐");
                walk.vrun(cs, mr_s + 1, wire -| 1, "│");
                walk.hrun(wire, cs + 1, cd -| 1, "─");
                walk.dot(wire, cs, "└");
                walk.dot(wire, cd, "┘");
                walk.vrun(cd, mr_d + 1, wire -| 1, "│");
                walk.dot(mr_d, cd, "┌");
                walk.hrun(mr_d, cd + 1, self.x[d] - 2, "─");
                walk.arrow_at = .{ .r = mr_d, .c = self.x[d] - 1 };
                walk.arrow = "►";
            } else {
                const js = self.cols - 1 - cs;
                const jd = self.cols - 1 - cd;
                walk.hrun(mr_s, js + 1, self.x[s] - 1, "─");
                walk.dot(mr_s, js, "┌");
                walk.vrun(js, mr_s + 1, wire -| 1, "│");
                walk.hrun(wire, jd + 1, js -| 1, "─");
                walk.dot(wire, js, "┘");
                walk.dot(wire, jd, "└");
                walk.vrun(jd, mr_d + 1, wire -| 1, "│");
                walk.dot(mr_d, jd, "┐");
                walk.hrun(mr_d, self.x[d] + self.w[d] + 1, jd -| 1, "─");
                walk.arrow_at = .{ .r = mr_d, .c = self.x[d] + self.w[d] };
                walk.arrow = "◄";
            }
            walk.label = self.labelInfo(edge);
        }
        return walk;
    }

    fn labelInfo(self: *const Grid, edge: *const Mermaid.Edge) ?LabelAt {
        const text = edge.label orelse return null;
        if (self.vertical) {
            const idx = edgeIndex(self.flow, edge) orelse return null;
            const s = nodeIndex(self.flow, edge.src) orelse return null;
            const d = nodeIndex(self.flow, edge.dst) orelse return null;
            const k = self.lrow[idx];
            const base = if (self.forward) self.y[s] + 4 else self.y[s] - 2;
            return .{ .r = if (self.forward) base + k else base - k, .c = self.x[d] + self.w[d] / 2 + 2, .text = text };
        }
        const d = nodeIndex(self.flow, edge.dst) orelse return null;
        const lw = cells.labelWidth(text);
        if (lw == 0) return null;
        const r = self.y[d] + 1;
        const s = nodeIndex(self.flow, edge.src) orelse return null;
        const bent = self.rank[d] > self.rank[s] + 1 or self.y[s] != self.y[d];
        if (self.forward) {
            const arrow = self.x[d] - 1;
            const rs = if (bent) self.fwd[self.rank[d] - 1] + self.bandWidth(self.rank[d] - 1) + 2 else self.x[s] + self.w[s];
            const len = if (arrow >= rs + 1) arrow - rs else 0;
            return .{ .r = r, .c = rs + (len -| lw) / 2, .text = text };
        }
        const arrow = self.x[d] + self.w[d];
        const re = if (bent) (self.cols -| 1 -| (self.fwd[self.rank[d] - 1] + self.bandWidth(self.rank[d] - 1) + 1)) -| 1 else self.x[s] -| 1;
        const len = if (re >= arrow + 1) re - arrow else 0;
        return .{ .r = r, .c = arrow + 1 + (len -| lw) / 2, .text = text };
    }

    fn edgeIndex(flow: *const Mermaid.Flowchart, edge: *const Mermaid.Edge) ?usize {
        for (flow.edgeList(), 0..) |*e, i| {
            if (e == edge) return i;
        }
        return null;
    }

    fn checkHorizontalLabels(self: *const Grid) ?void {
        var n: usize = 0;
        var rows: [Mermaid.max_edges]usize = undefined;
        var starts: [Mermaid.max_edges]usize = undefined;
        var ends: [Mermaid.max_edges]usize = undefined;
        var na: usize = 0;
        var arows: [Mermaid.max_edges]usize = undefined;
        var acols: [Mermaid.max_edges]usize = undefined;
        for (self.flow.edgeList()) |*edge| {
            const walk = self.route(edge) orelse continue;
            if (edge.style != .invisible and edge.dst_marker != .none) {
                arows[na] = walk.arrow_at.r;
                acols[na] = walk.arrow_at.c;
                na += 1;
            }
            const info = self.labelInfo(edge) orelse continue;
            rows[n] = info.r;
            starts[n] = info.c;
            ends[n] = info.c + cells.labelWidth(info.text);
            n += 1;
        }
        for (0..n) |i| {
            for (0..n) |j| {
                if (i == j or rows[i] != rows[j]) continue;
                if (starts[i] < ends[j] and starts[j] < ends[i]) return null;
            }
            for (0..na) |k| {
                if (arows[k] != rows[i]) continue;
                if (acols[k] >= starts[i] and acols[k] < ends[i]) return null;
            }
        }
    }

    fn draw(self: *const Grid, win: vaxis.Window, start_row: usize, skip: usize) void {
        for (self.flow.subgraphList(), 0..) |subgraph, index| {
            drawFrame(win, self.subgraphs[index], subgraph.label, start_row, skip);
        }
        for (self.flow.nodeList(), 0..) |*node, i| {
            drawNodeBox(win, node, .{
                .x1 = self.x[i],
                .y1 = self.y[i],
                .x2 = self.x[i] + self.w[i] - 1,
                .y2 = self.y[i] + 2,
            }, start_row, skip);
        }
        for (self.flow.edgeList()) |*edge| {
            if (edge.style == .invisible) continue;
            const path = self.route(edge) orelse continue;
            for (path.segs[0..path.n]) |*seg| {
                if (seg.r1 == seg.r2 and seg.c1 == seg.c2) {
                    cells.putLine(win, seg.r1, seg.c1, start_row, skip, seg.glyph, .{});
                } else if (seg.r1 == seg.r2) {
                    var c = seg.c1;
                    while (c <= seg.c2) : (c += 1) cells.putLine(win, seg.r1, c, start_row, skip, seg.glyph, .{});
                } else {
                    var r = seg.r1;
                    while (r <= seg.r2) : (r += 1) cells.putLine(win, r, seg.c1, start_row, skip, seg.glyph, .{});
                }
            }
            drawMarker(win, path.arrow_at, edge.dst_marker, path.arrow, self.terminalLine(), start_row, skip);
            if (edge.src_marker != .none) {
                const source = self.sourceMarkerAt(edge) orelse continue;
                drawMarker(win, source, edge.src_marker, reverseArrow(path.arrow), self.terminalLine(), start_row, skip);
            }
        }
        for (self.flow.edgeList()) |*edge| {
            if (edge.style == .invisible) continue;
            const path = self.route(edge) orelse continue;
            if (path.label) |label| cells.putText(win, label.r, label.c, start_row, skip, label.text, self.cols, .{});
        }
    }

    fn sourceMarkerAt(self: *const Grid, edge: *const Mermaid.Edge) ?CellPos {
        const source = nodeIndex(self.flow, edge.src) orelse return null;
        if (self.vertical) {
            return .{
                .r = if (self.forward) self.y[source] + 3 else self.y[source] - 1,
                .c = self.x[source] + self.w[source] / 2,
            };
        }
        return .{
            .r = self.y[source] + 1,
            .c = if (self.forward) self.x[source] + self.w[source] else self.x[source] - 1,
        };
    }

    fn terminalLine(self: *const Grid) []const u8 {
        return if (self.vertical) "│" else "─";
    }
};

fn drawFrame(win: vaxis.Window, bounds: Bounds, label: []const u8, start_row: usize, skip: usize) void {
    const style: vaxis.Style = .{ .dim = true };
    cells.putLine(win, bounds.y1, bounds.x1, start_row, skip, "┌", style);
    cells.putLine(win, bounds.y1, bounds.x2, start_row, skip, "┐", style);
    cells.putLine(win, bounds.y2, bounds.x1, start_row, skip, "└", style);
    cells.putLine(win, bounds.y2, bounds.x2, start_row, skip, "┘", style);
    var col = bounds.x1 + 1;
    while (col < bounds.x2) : (col += 1) {
        cells.putLine(win, bounds.y1, col, start_row, skip, "─", style);
        cells.putLine(win, bounds.y2, col, start_row, skip, "─", style);
    }
    var row = bounds.y1 + 1;
    while (row < bounds.y2) : (row += 1) {
        cells.putLine(win, row, bounds.x1, start_row, skip, "│", style);
        cells.putLine(win, row, bounds.x2, start_row, skip, "│", style);
    }
    cells.putText(win, bounds.y1, bounds.x1 + 2, start_row, skip, label, bounds.x2 - 1, style);
}

fn drawNodeBox(win: vaxis.Window, node: *const Mermaid.Node, bounds: Bounds, start_row: usize, skip: usize) void {
    const corners = switch (node.shape) {
        .rounded, .stadium, .circle, .cylinder, .double_circle => cells.round,
        .diamond => cells.diamond,
        else => cells.square,
    };
    cells.box(win, bounds.x1, bounds.y1, bounds.width(), node.label, corners, start_row, skip, .{});
}

fn drawMarker(win: vaxis.Window, pos: CellPos, marker: Mermaid.EdgeMarker, arrow: []const u8, line: []const u8, start_row: usize, skip: usize) void {
    switch (marker) {
        .none => cells.putLine(win, pos.r, pos.c, start_row, skip, line, .{}),
        .arrow => cells.putRaw(win, pos.r, pos.c, start_row, skip, arrow, .{}),
        .circle => cells.putRaw(win, pos.r, pos.c, start_row, skip, "○", .{}),
        .cross => cells.putRaw(win, pos.r, pos.c, start_row, skip, "×", .{}),
    }
}

fn reverseArrow(arrow: []const u8) []const u8 {
    if (mem.eql(u8, arrow, "▼")) return "▲";
    if (mem.eql(u8, arrow, "▲")) return "▼";
    if (mem.eql(u8, arrow, "►")) return "◄";
    return "►";
}

const Seg = struct {
    r1: usize,
    c1: usize,
    r2: usize,
    c2: usize,
    glyph: []const u8,
};

const CellPos = struct {
    r: usize,
    c: usize,
};

const Walk = struct {
    segs: [10]Seg = undefined,
    n: usize = 0,
    arrow_at: CellPos = .{ .r = 0, .c = 0 },
    arrow: []const u8 = "▼",
    label: ?LabelAt = null,

    fn hrun(self: *Walk, r: usize, c1: usize, c2: usize, glyph: []const u8) void {
        if (c1 > c2 or self.n >= self.segs.len) return;
        self.segs[self.n] = .{ .r1 = r, .c1 = c1, .r2 = r, .c2 = c2, .glyph = glyph };
        self.n += 1;
    }

    fn vrun(self: *Walk, c: usize, r1: usize, r2: usize, glyph: []const u8) void {
        if (r1 > r2 or self.n >= self.segs.len) return;
        self.segs[self.n] = .{ .r1 = r1, .c1 = c, .r2 = r2, .c2 = c, .glyph = glyph };
        self.n += 1;
    }

    fn dot(self: *Walk, r: usize, c: usize, glyph: []const u8) void {
        self.hrun(r, c, c, glyph);
    }
};

const LabelAt = struct {
    r: usize,
    c: usize,
    text: []const u8,
};

fn nodeIndex(flow: *const Mermaid.Flowchart, id: []const u8) ?usize {
    for (flow.nodeList(), 0..) |*node, i| {
        if (mem.eql(u8, node.id, id)) return i;
    }
    return null;
}

const std = @import("std");
const mem = std.mem;

test "chain renders boxes joined by arrows" {
    var flow = Mermaid.parseText("graph TD\nA-->B-->C\n").?;
    const rows = layout(null, &flow, 0, 0, 40).?;
    try testing.expectEqual(@as(usize, 13), rows);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 13, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    try testing.expectEqual(@as(usize, 13), layout(win, &flow, 0, 0, 40).?);
    try expectGlyph(win, 0, 0, "┌");
    try expectGlyph(win, 4, 0, "┐");
    try expectGlyph(win, 2, 1, "A");
    try expectGlyph(win, 2, 3, "│");
    try expectGlyph(win, 2, 4, "▼");
    try expectGlyph(win, 2, 8, "│");
    try expectGlyph(win, 2, 9, "▼");
    try expectGlyph(win, 0, 10, "┌");
}

test "branch lays out siblings side by side" {
    var flow = Mermaid.parseText("graph TD\nA-->B\nA-->C\n").?;
    try testing.expectEqual(@as(usize, 8), layout(null, &flow, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 8, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 0, 5, "┌");
    try expectGlyph(win, 8, 5, "┌");
    try expectGlyph(win, 2, 4, "▼");
    try expectGlyph(win, 10, 4, "▼");
    try expectGlyph(win, 2, 3, "├");
    try expectGlyph(win, 10, 3, "┐");
}

test "subgraphs render labeled boundaries" {
    var flow = Mermaid.parseText(
        "flowchart LR\n" ++
            "subgraph group [Group]\n" ++
            "A-->B\n" ++
            "subgraph inner [Inner]\n" ++
            "C-->D\n" ++
            "end\n" ++
            "B-->C\n" ++
            "end\n" ++
            "D-->E\n",
    ).?;
    const rows = layout(null, &flow, 0, 0, 80).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(rows), .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 80).?;

    var found_group = false;
    var found_inner = false;
    var found_border = false;
    for (0..win.height) |row| {
        for (0..win.width) |col| {
            const cell = win.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (!cell.style.dim) continue;
            if (mem.eql(u8, cell.char.grapheme, "G")) found_group = true;
            if (mem.eql(u8, cell.char.grapheme, "I")) found_inner = true;
            if (mem.eql(u8, cell.char.grapheme, "┌")) found_border = true;
        }
    }
    try testing.expect(found_group and found_inner and found_border);
}

test "hierarchical subgraph directions and group edges render" {
    var flow = Mermaid.parseText(
        "flowchart LR\n" ++
            "one-->two\n" ++
            "subgraph one [One]\n" ++
            "direction TB\n" ++
            "A-->B\n" ++
            "end\n" ++
            "subgraph two [Two]\n" ++
            "direction RL\n" ++
            "C-->D\n" ++
            "end\n",
    ).?;
    const rows = layout(null, &flow, 0, 0, 80).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(rows), .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 80).?;
    const a = findGlyph(win, "A").?;
    const b = findGlyph(win, "B").?;
    const c = findGlyph(win, "C").?;
    const d = findGlyph(win, "D").?;
    try testing.expect(a.c == b.c and a.r < b.r);
    try testing.expect(c.r == d.r and c.c > d.c);
}

test "interleaved subgraph members fall back" {
    var flow = Mermaid.parseText(
        "flowchart TD\n" ++
            "subgraph group\n" ++
            "A\n" ++
            "C\n" ++
            "end\n" ++
            "B\n" ++
            "A-->B-->C\n",
    ).?;
    try testing.expect(layout(null, &flow, 0, 0, 80) == null);
}

test "left to right flows horizontally" {
    var flow = Mermaid.parseText("flowchart LR\nA-->B\n").?;
    try testing.expectEqual(@as(usize, 3), layout(null, &flow, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 3, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 9, 0, "┌");
    try expectGlyph(win, 8, 1, "►");
    try expectGlyph(win, 2, 1, "A");
}

test "flowchart endpoint markers render" {
    var flow = Mermaid.parseText("flowchart LR\nA<-->B\n").?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 3, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 5, 1, "◄");
    try expectGlyph(win, 8, 1, "►");

    win.clear();
    flow = Mermaid.parseText("flowchart LR\nA--oB\n").?;
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 8, 1, "○");

    win.clear();
    flow = Mermaid.parseText("flowchart LR\nA--xB\n").?;
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 8, 1, "×");

    win.clear();
    flow = Mermaid.parseText("flowchart LR\nA---B\n").?;
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 8, 1, "─");

    win.clear();
    flow = Mermaid.parseText("flowchart LR\nA~~~B\n").?;
    _ = layout(win, &flow, 0, 0, 40).?;
    try testing.expect(!mem.eql(u8, win.readCell(6, 1).?.char.grapheme, "─"));
}

test "left to right branch bends inside the gap" {
    var flow = Mermaid.parseText("flowchart LR\nA-->B\nA-->C\n").?;
    try testing.expectEqual(@as(usize, 6), layout(null, &flow, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 6, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 6, 1, "┬");
    try expectGlyph(win, 6, 2, "│");
    try expectGlyph(win, 6, 4, "└");
    try expectGlyph(win, 8, 4, "►");
}

test "right to left mirrors horizontally" {
    var flow = Mermaid.parseText("graph RL\nA-->B\nA-->C\n").?;
    try testing.expectEqual(@as(usize, 6), layout(null, &flow, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 6, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 5, 1, "◄");
    try expectGlyph(win, 8, 1, "─");
    try expectGlyph(win, 7, 1, "┬");
    try expectGlyph(win, 7, 4, "┘");
    try expectGlyph(win, 5, 4, "◄");
    try expectGlyph(win, 9, 0, "┌");
    try expectGlyph(win, 0, 3, "┌");
}

test "wide band mates stay intact" {
    var flow = Mermaid.parseText("flowchart LR\nA-->W[wide box here]\nA-->N[x]\n").?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 6, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 9, 0, "┌");
    try expectGlyph(win, 25, 0, "┐");
    try expectGlyph(win, 14, 4, "►");
    try expectGlyph(win, 6, 2, "│");
}

test "left to right labels sit on the edge" {
    var flow = Mermaid.parseText(
        "graph LR\n" ++
            "A[Square Rect] -- Link text --> B((Circle))\n" ++
            "A --> C(Round Rect)\n" ++
            "B --> D{Rhombus}\n" ++
            "C --> D\n",
    ).?;
    try testing.expectEqual(@as(usize, 6), layout(null, &flow, 0, 0, 80).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 6, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 80).?;
    try expectGlyph(win, 18, 1, "L");
    try expectGlyph(win, 26, 1, "t");
    try expectGlyph(win, 30, 1, "►");
    try expectGlyph(win, 16, 1, "┬");
    try expectGlyph(win, 44, 1, "┬");
    try expectGlyph(win, 46, 1, "►");
    try expectGlyph(win, 28, 4, "►");
    try expectGlyph(win, 31, 0, "╭");
    try expectGlyph(win, 47, 0, "◇");
}

test "crowded horizontal labels fall back" {
    var flow = Mermaid.parseText("flowchart LR\nA-->|xx|C\nB-->|yy|C\n").?;
    try testing.expect(layout(null, &flow, 0, 0, 80) == null);
}

test "left to right skip edges use the wire row" {
    var flow = Mermaid.parseText("flowchart LR\nA-->B\nB-->C\nA-->C\n").?;
    try testing.expectEqual(@as(usize, 4), layout(null, &flow, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 4, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 6, 2, "│");
    try expectGlyph(win, 10, 3, "─");
    try expectGlyph(win, 17, 1, "►");
}

test "minimum link lengths add layers" {
    var flow = Mermaid.parseText("graph TD\nA---->B\n").?;
    try testing.expectEqual(@as(usize, 18), layout(null, &flow, 0, 0, 40).?);
}

test "bottom up points arrows upward" {
    var flow = Mermaid.parseText("graph BT\nA-->B\n").?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 8, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 2, 3, "▲");
    try expectGlyph(win, 0, 0, "┌");
    try expectGlyph(win, 2, 1, "B");
    try expectGlyph(win, 0, 5, "┌");
    try expectGlyph(win, 2, 6, "A");
}

test "edge labels take their own row" {
    var flow = Mermaid.parseText("graph TD\nA-->|yes|B\n").?;
    try testing.expectEqual(@as(usize, 9), layout(null, &flow, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 9, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 4, 4, "y");
    try expectGlyph(win, 2, 5, "▼");
}

test "skip-level edges route along the wire" {
    var flow = Mermaid.parseText("graph TD\nA-->B\nB-->C\nA-->C\n").?;
    try testing.expectEqual(@as(usize, 13), layout(null, &flow, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 13, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 5, 6, "│");
    try expectGlyph(win, 2, 9, "▼");
    try expectGlyph(win, 2, 3, "├");
    try expectGlyph(win, 5, 3, "┐");
}

test "centering drift routes straight" {
    var flow = Mermaid.parseText(
        "flowchart TD\n" ++
            "A[Christmas] -->|Get money| B(Go shopping)\n" ++
            "B --> C{Let me think}\n" ++
            "C -->|One| D[Laptop]\n" ++
            "C -->|Two| E[iPhone]\n" ++
            "C -->|Three| F[Car]\n",
    ).?;
    try testing.expectEqual(@as(usize, 20), layout(null, &flow, 0, 0, 60).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 20, .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 60).?;
    try expectGlyph(win, 7, 9, "│");
    try expectGlyph(win, 7, 10, "▼");
    try expectGlyph(win, 9, 4, "G");
    try expectGlyph(win, 0, 11, "◇");
    try expectGlyph(win, 10, 15, "O");
    try expectGlyph(win, 26, 15, "T");
    try expectGlyph(win, 37, 15, "T");
    try expectGlyph(win, 8, 14, "├");
    try expectGlyph(win, 24, 14, "┬");
    try expectGlyph(win, 8, 16, "▼");
    try expectGlyph(win, 24, 16, "▼");
    try expectGlyph(win, 35, 16, "▼");
}

test "overlapping labels stack on separate rows" {
    var flow = Mermaid.parseText("graph TD\nA-->|long label one|B\nA-->|long label two|C\n").?;
    try testing.expectEqual(@as(usize, 10), layout(null, &flow, 0, 0, 40).?);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 10, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &flow, 0, 0, 40).?;
    try expectGlyph(win, 4, 4, "l");
    try expectGlyph(win, 12, 5, "l");
    try expectGlyph(win, 2, 6, "▼");
    try expectGlyph(win, 10, 6, "▼");
}

test "unrenderable diagrams fall back" {
    var cyclic = Mermaid.parseText("graph TD\nA-->B\nB-->A\n").?;
    try testing.expect(layout(null, &cyclic, 0, 0, 40) == null);

    var self_edge = Mermaid.parseText("graph TD\nA-->A\n").?;
    try testing.expect(layout(null, &self_edge, 0, 0, 40) == null);

    var empty = Mermaid.parseText("graph TD\n").?;
    try testing.expect(layout(null, &empty, 0, 0, 40) == null);

    var degraded = Mermaid.parseText("graph TD\n" ++ ("A-->B\n" ** 200)).?;
    try testing.expect(layout(null, &degraded, 0, 0, 40) == null);

    var chain = Mermaid.parseText("graph TD\nA-->B-->C\n").?;
    try testing.expect(layout(null, &chain, 0, 0, 4) == null);
}

test "skips shift content up" {
    var flow = Mermaid.parseText("graph TD\nA-->B-->C\n").?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = 13, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    try testing.expectEqual(@as(usize, 8), layout(win, &flow, 0, 5, 40).?);
    try expectGlyph(win, 0, 0, "┌");
    try expectGlyph(win, 2, 1, "B");
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

fn findGlyph(win: vaxis.Window, glyph: []const u8) ?CellPos {
    for (0..win.height) |row| {
        for (0..win.width) |col| {
            const cell = win.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (mem.eql(u8, cell.char.grapheme, glyph)) return .{ .r = row, .c = col };
        }
    }
    return null;
}

fn expectGlyph(win: vaxis.Window, col: u16, row: u16, expected: []const u8) !void {
    const cell = win.readCell(col, row) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings(expected, cell.char.grapheme);
}

const testing = std.testing;
