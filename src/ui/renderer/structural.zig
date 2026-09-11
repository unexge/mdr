//! Unicode renderer for Mermaid class, state, and entity-relationship diagrams.

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

const Size = struct {
    width: usize,
    height: usize,
};

const CellPos = struct {
    r: usize,
    c: usize,
};

const Segment = struct {
    r1: usize,
    c1: usize,
    r2: usize,
    c2: usize,
};

const LabelAt = struct {
    r: usize,
    c: usize,
    text: []const u8,
};

const Path = struct {
    segments: [3]Segment = undefined,
    segment_count: usize = 0,
    src_at: CellPos,
    dst_at: CellPos,
    src_arrow: []const u8,
    dst_arrow: []const u8,
    src_line: []const u8,
    dst_line: []const u8,
    label: ?LabelAt = null,

    fn horizontal(self: *Path, row: usize, first: usize, last: usize) void {
        if (first > last or self.segment_count >= self.segments.len) return;
        self.segments[self.segment_count] = .{ .r1 = row, .c1 = first, .r2 = row, .c2 = last };
        self.segment_count += 1;
    }

    fn vertical(self: *Path, column: usize, first: usize, last: usize) void {
        if (first > last or self.segment_count >= self.segments.len) return;
        self.segments[self.segment_count] = .{ .r1 = first, .c1 = column, .r2 = last, .c2 = column };
        self.segment_count += 1;
    }
};

pub fn layout(
    win: ?vaxis.Window,
    diagram: *const Structural.Diagram,
    start_row: usize,
    skip: usize,
    width: usize,
) ?usize {
    var computed = Layout.compute(diagram, width) orelse return null;
    if (win == null) return start_row + computed.rows;
    const target = win.?;
    computed.draw(target, start_row, skip);
    return start_row + @min(computed.rows -| skip, target.height -| start_row);
}

const Layout = struct {
    diagram: *const Structural.Diagram,
    widths: [Structural.max_nodes]usize,
    heights: [Structural.max_nodes]usize,
    bounds: [Structural.max_nodes]Bounds,
    group_directions: [Structural.max_groups]Structural.Direction,
    region_sizes: [Structural.max_groups][Structural.max_regions_per_group]Size,
    region_lanes: [Structural.max_groups][Structural.max_regions_per_group]usize,
    region_dividers: [Structural.max_groups][Structural.max_regions_per_group]usize,
    rows: usize,
    cols: usize,

    fn compute(diagram: *const Structural.Diagram, width: usize) ?Layout {
        if (diagram.degraded or diagram.node_count == 0) return null;
        var result: Layout = .{
            .diagram = diagram,
            .widths = [_]usize{0} ** Structural.max_nodes,
            .heights = [_]usize{0} ** Structural.max_nodes,
            .bounds = undefined,
            .group_directions = undefined,
            .region_sizes = undefined,
            .region_lanes = undefined,
            .region_dividers = undefined,
            .rows = 0,
            .cols = 0,
        };
        const content = result.measureItems(null, 0, diagram.direction) orelse return null;
        const relation_text_width = result.maxRelationTextWidth();
        const has_vertical = result.hasDirection(true);
        const has_horizontal = result.hasDirection(false);
        result.rows = content.height + 2 + @intFromBool(has_horizontal);
        result.cols = content.width + 2 + if (has_vertical)
            relation_text_width + @intFromBool(relation_text_width > 0)
        else
            0;
        if (result.rows > max_rows or result.cols > width) return null;
        result.placeItems(null, 0, diagram.direction, .{
            .x1 = 1,
            .y1 = 1,
            .x2 = content.width,
            .y2 = content.height,
        });
        for (diagram.relationList()) |*relation| _ = result.route(relation) orelse return null;
        return result;
    }

    fn measureItems(self: *Layout, parent: ?usize, region: usize, direction: Structural.Direction) ?Size {
        var count: usize = 0;
        var primary: usize = 0;
        var cross: usize = 0;
        const vertical = isVertical(direction);
        for (self.diagram.nodeList(), 0..) |_, index| {
            if (self.diagram.nodes[index].group != parent or self.diagram.nodes[index].region != region) continue;
            const size = self.measureNode(index, direction) orelse return null;
            primary += if (vertical) size.height else size.width;
            cross = @max(cross, if (vertical) size.width else size.height);
            count += 1;
        }
        if (count == 0) return null;
        primary += self.itemGap(direction) * (count - 1);
        return if (vertical)
            .{ .width = cross, .height = primary }
        else
            .{ .width = primary, .height = cross };
    }

    fn measureNode(self: *Layout, index: usize, parent_direction: Structural.Direction) ?Size {
        const node = self.diagram.nodes[index];
        const size = if (isGroupKind(node.kind)) group_size: {
            const group = self.diagram.groupForNode(index) orelse return null;
            const direction = self.diagram.groups[group].direction orelse parent_direction;
            self.group_directions[group] = direction;
            const region_count = self.diagram.groups[group].region_count;
            var content_width: usize = 0;
            var content_height: usize = region_count - 1;
            if (region_count > 1) content_height += region_count;
            for (0..region_count) |region| {
                const size = self.measureItems(group, region, direction) orelse return null;
                self.region_sizes[group][region] = size;
                content_width = @max(content_width, size.width);
                content_height += size.height;
            }
            break :group_size Size{
                .width = @max(@max(content_width + 3, cells.maxLineWidth(node.label) + 4), self.selfLabelWidth(index) + 2),
                .height = content_height + 4,
            };
        } else self.leafSize(index, node);
        self.widths[index] = size.width;
        self.heights[index] = size.height;
        return size;
    }

    fn selfLabelWidth(self: *const Layout, index: usize) usize {
        var width: usize = 0;
        for (self.diagram.relationList()) |relation| {
            if (relation.src != index or relation.dst != index or relation.label == null) continue;
            width = @max(width, cells.maxLineWidth(relation.label.?));
        }
        return width;
    }

    fn leafSize(self: *const Layout, index: usize, node: Structural.Node) Size {
        const self_label_width = self.selfLabelWidth(index);
        switch (node.kind) {
            .start, .end => return .{ .width = 1, .height = 1 },
            .fork, .join => return .{ .width = @max(self_label_width + 2, 7), .height = 1 },
            .choice => return .{ .width = @max(@max(cells.maxLineWidth(node.label) + 4, self_label_width + 2), 5), .height = 3 },
            .class, .state, .entity => {},
            .composite, .namespace, .er_group => unreachable,
        }
        var box_width = @max(@max(cells.maxLineWidth(node.label) + 4, self_label_width + 2), 5);
        var detail_rows: usize = 0;
        var detail_count: usize = 0;
        var breaks: usize = 0;
        var previous: ?Structural.DetailKind = null;
        for (self.diagram.detailList()) |detail| {
            if (detail.node != index) continue;
            box_width = @max(box_width, cells.maxLineWidth(detail.text) + 4);
            detail_rows += cells.lineCount(detail.text);
            if (previous) |kind| breaks += @intFromBool(compartment(kind) != compartment(detail.kind));
            previous = detail.kind;
            detail_count += 1;
        }
        return .{
            .width = box_width,
            .height = if (detail_count == 0) 3 else 4 + detail_rows + breaks,
        };
    }

    fn placeItems(self: *Layout, parent: ?usize, region: usize, direction: Structural.Direction, area: Bounds) void {
        const vertical = isVertical(direction);
        const forward = direction == .tb or direction == .lr;
        var primary: usize = 0;
        var count: usize = 0;
        for (self.diagram.nodeList(), 0..) |node, index| {
            if (node.group != parent or node.region != region) continue;
            primary += if (vertical) self.heights[index] else self.widths[index];
            count += 1;
        }
        primary += self.itemGap(direction) * (count - 1);
        var cursor = if (vertical)
            area.y1 + (area.height() - primary) / 2
        else
            area.x1 + (area.width() - primary) / 2;
        if (!forward) cursor += primary;
        for (self.diagram.nodeList(), 0..) |node, index| {
            if (node.group != parent or node.region != region) continue;
            const item_primary = if (vertical) self.heights[index] else self.widths[index];
            const position = if (forward) cursor else cursor - item_primary;
            const x = if (vertical) area.x1 + (area.width() - self.widths[index]) / 2 else position;
            const y = if (vertical) position else area.y1 + (area.height() - self.heights[index]) / 2;
            self.bounds[index] = .{
                .x1 = x,
                .y1 = y,
                .x2 = x + self.widths[index] - 1,
                .y2 = y + self.heights[index] - 1,
            };
            if (isGroupKind(node.kind)) {
                const group = self.diagram.groupForNode(index) orelse unreachable;
                const region_count = self.diagram.groups[group].region_count;
                const has_lanes = region_count > 1;
                var region_y = y + 2;
                for (0..region_count) |child_region| {
                    const region_size = self.region_sizes[group][child_region];
                    self.placeItems(group, child_region, self.group_directions[group], .{
                        .x1 = x + 1,
                        .y1 = region_y,
                        .x2 = x + self.widths[index] - 2,
                        .y2 = region_y + region_size.height - 1,
                    });
                    region_y += region_size.height;
                    if (has_lanes) {
                        self.region_lanes[group][child_region] = region_y;
                        region_y += 1;
                    }
                    if (child_region + 1 < region_count) {
                        self.region_dividers[group][child_region] = region_y;
                        region_y += 1;
                    }
                }
            }
            if (forward) cursor += item_primary + self.itemGap(direction) else cursor = position -| self.itemGap(direction);
        }
    }

    fn itemGap(self: *const Layout, direction: Structural.Direction) usize {
        return if (isVertical(direction)) 3 else self.horizontalGap();
    }

    fn hasDirection(self: *const Layout, vertical: bool) bool {
        if (isVertical(self.diagram.direction) == vertical) return true;
        for (self.group_directions[0..self.diagram.group_count]) |direction| {
            if (isVertical(direction) == vertical) return true;
        }
        return false;
    }

    fn maxRelationTextWidth(self: *const Layout) usize {
        var widest: usize = 0;
        for (self.diagram.relationList()) |relation| {
            if (relation.label) |label| widest = @max(widest, cells.maxLineWidth(label));
            if (relation.src_label) |label| widest = @max(widest, cells.maxLineWidth(label));
            if (relation.dst_label) |label| widest = @max(widest, cells.maxLineWidth(label));
        }
        return widest;
    }

    fn horizontalGap(self: *const Layout) usize {
        var gap: usize = 4;
        for (self.diagram.relationList()) |relation| {
            if (!self.areForwardAdjacent(relation.src, relation.dst)) continue;
            var width: usize = 4;
            if (relation.label) |label| width += cells.maxLineWidth(label);
            if (relation.src_label) |label| width += cells.maxLineWidth(label);
            if (relation.dst_label) |label| width += cells.maxLineWidth(label);
            gap = @max(gap, width);
        }
        return gap;
    }

    fn route(self: *const Layout, relation: *const Structural.Relation) ?Path {
        if (relation.src >= self.diagram.node_count or relation.dst >= self.diagram.node_count) return null;
        if (relation.src == relation.dst) return self.routeSelf(relation.src, relation.label);
        const direction = self.relationDirection(relation);
        if (!self.areForwardAdjacent(relation.src, relation.dst)) return self.routeOuter(relation, direction);
        const source = self.bounds[relation.src];
        const destination = self.bounds[relation.dst];
        const source_center = CellPos{ .r = (source.y1 + source.y2) / 2, .c = (source.x1 + source.x2) / 2 };
        const destination_center = CellPos{ .r = (destination.y1 + destination.y2) / 2, .c = (destination.x1 + destination.x2) / 2 };
        var path: Path = undefined;
        path.segment_count = 0;
        path.label = null;
        if (isVertical(direction)) {
            const down = destination_center.r > source_center.r;
            path.src_at = .{ .r = if (down) source.y2 + 1 else source.y1 - 1, .c = source_center.c };
            path.dst_at = .{ .r = if (down) destination.y1 - 1 else destination.y2 + 1, .c = destination_center.c };
            path.src_arrow = if (down) "▲" else "▼";
            path.dst_arrow = if (down) "▼" else "▲";
            path.src_line = "│";
            path.dst_line = "│";
            const middle = (path.src_at.r + path.dst_at.r) / 2;
            path.vertical(path.src_at.c, @min(path.src_at.r, middle), @max(path.src_at.r, middle));
            path.horizontal(middle, @min(path.src_at.c, path.dst_at.c), @max(path.src_at.c, path.dst_at.c));
            path.vertical(path.dst_at.c, @min(middle, path.dst_at.r), @max(middle, path.dst_at.r));
            if (relation.label) |label| path.label = .{ .r = middle, .c = @max(path.src_at.c, path.dst_at.c) + 2, .text = label };
        } else {
            const right = destination_center.c > source_center.c;
            path.src_at = .{ .r = source_center.r, .c = if (right) source.x2 + 1 else source.x1 - 1 };
            path.dst_at = .{ .r = destination_center.r, .c = if (right) destination.x1 - 1 else destination.x2 + 1 };
            path.src_arrow = if (right) "◄" else "►";
            path.dst_arrow = if (right) "►" else "◄";
            path.src_line = "─";
            path.dst_line = "─";
            const middle = (path.src_at.c + path.dst_at.c) / 2;
            path.horizontal(path.src_at.r, @min(path.src_at.c, middle), @max(path.src_at.c, middle));
            path.vertical(middle, @min(path.src_at.r, path.dst_at.r), @max(path.src_at.r, path.dst_at.r));
            path.horizontal(path.dst_at.r, @min(middle, path.dst_at.c), @max(middle, path.dst_at.c));
            if (relation.label) |label| {
                const label_width = cells.maxLineWidth(label);
                const source_is_left = path.src_at.c < path.dst_at.c;
                const left_width = endpointLabelWidth(if (source_is_left) relation.src_label else relation.dst_label);
                const right_width = endpointLabelWidth(if (source_is_left) relation.dst_label else relation.src_label);
                const first = @min(path.src_at.c, path.dst_at.c) + left_width + 2;
                const last = @max(path.src_at.c, path.dst_at.c) -| right_width -| 1;
                if (first + label_width > last) return null;
                path.label = .{ .r = path.src_at.r, .c = first + (last - first - label_width) / 2, .text = label };
            }
        }
        return path;
    }

    fn relationDirection(self: *const Layout, relation: *const Structural.Relation) Structural.Direction {
        const source = self.diagram.nodes[relation.src];
        const destination = self.diagram.nodes[relation.dst];
        const group = source.group;
        if (group != destination.group or source.region != destination.region) return self.diagram.direction;
        return if (group) |index| self.group_directions[index] else self.diagram.direction;
    }

    fn areForwardAdjacent(self: *const Layout, source: usize, destination: usize) bool {
        const source_node = self.diagram.nodes[source];
        const destination_node = self.diagram.nodes[destination];
        if (source_node.group != destination_node.group or source_node.region != destination_node.region or
            source_node.order >= destination_node.order) return false;
        for (self.diagram.nodeList(), 0..) |node, index| {
            if (index == source or index == destination or node.group != source_node.group or
                node.region != source_node.region) continue;
            if (node.order > source_node.order and node.order < destination_node.order) return false;
        }
        return true;
    }

    fn routeOuter(
        self: *const Layout,
        relation: *const Structural.Relation,
        direction: Structural.Direction,
    ) ?Path {
        const source = self.bounds[relation.src];
        const destination = self.bounds[relation.dst];
        const source_center = CellPos{ .r = (source.y1 + source.y2) / 2, .c = (source.x1 + source.x2) / 2 };
        const destination_center = CellPos{ .r = (destination.y1 + destination.y2) / 2, .c = (destination.x1 + destination.x2) / 2 };
        var path: Path = undefined;
        path.segment_count = 0;
        path.label = null;
        if (isVertical(direction)) {
            const lane = self.cols - 1;
            path.src_at = .{ .r = source_center.r, .c = source.x2 + 1 };
            path.dst_at = .{ .r = destination_center.r, .c = destination.x2 + 1 };
            path.src_arrow = "◄";
            path.dst_arrow = "◄";
            path.src_line = "─";
            path.dst_line = "─";
            path.horizontal(path.src_at.r, path.src_at.c, lane);
            path.vertical(lane, @min(path.src_at.r, path.dst_at.r), @max(path.src_at.r, path.dst_at.r));
            path.horizontal(path.dst_at.r, path.dst_at.c, lane);
            if (relation.label) |label| {
                const label_width = cells.maxLineWidth(label);
                if (label_width >= lane) return null;
                path.label = .{
                    .r = (path.src_at.r + path.dst_at.r) / 2,
                    .c = lane - label_width,
                    .text = label,
                };
            }
        } else {
            const lane = self.horizontalOuterLane(relation);
            path.src_at = .{ .r = source.y2 + 1, .c = source_center.c };
            path.dst_at = .{ .r = destination.y2 + 1, .c = destination_center.c };
            path.src_arrow = "▲";
            path.dst_arrow = "▲";
            path.src_line = "│";
            path.dst_line = "│";
            path.vertical(path.src_at.c, path.src_at.r, lane);
            path.horizontal(lane, @min(path.src_at.c, path.dst_at.c), @max(path.src_at.c, path.dst_at.c));
            path.vertical(path.dst_at.c, path.dst_at.r, lane);
            if (relation.label) |label| {
                const first = @min(path.src_at.c, path.dst_at.c);
                if (first + cells.maxLineWidth(label) > self.cols) return null;
                path.label = .{ .r = lane, .c = first, .text = label };
            }
        }
        return path;
    }

    fn horizontalOuterLane(self: *const Layout, relation: *const Structural.Relation) usize {
        const source = self.diagram.nodes[relation.src];
        const destination = self.diagram.nodes[relation.dst];
        if (source.group != destination.group or source.region != destination.region) return self.rows - 1;
        var group = source.group;
        var region = source.region;
        while (group) |index| {
            if (self.diagram.groups[index].region_count > 1) return self.region_lanes[index][region];
            const parent = self.diagram.nodes[self.diagram.groups[index].node];
            group = parent.group;
            region = parent.region;
        }
        return self.rows - 1;
    }

    fn routeSelf(self: *const Layout, node: usize, label: ?[]const u8) ?Path {
        const bounds = self.bounds[node];
        const center = CellPos{ .r = (bounds.y1 + bounds.y2) / 2, .c = (bounds.x1 + bounds.x2) / 2 };
        const source = CellPos{ .r = bounds.y2 + 1, .c = center.c };
        const destination = CellPos{ .r = center.r, .c = bounds.x2 + 1 };
        if (source.r >= self.rows or destination.c >= self.cols) return null;
        var path: Path = undefined;
        path.segment_count = 0;
        path.src_at = source;
        path.dst_at = destination;
        path.src_arrow = "▲";
        path.dst_arrow = "◄";
        path.src_line = "│";
        path.dst_line = "─";
        path.label = if (label) |text| .{ .r = source.r, .c = bounds.x1 + 1, .text = text } else null;
        path.horizontal(source.r, source.c, destination.c);
        path.vertical(destination.c, destination.r, source.r);
        return path;
    }

    fn draw(self: *const Layout, win: vaxis.Window, start_row: usize, skip: usize) void {
        for (self.diagram.groupList(), 0..) |group, index| {
            const node = self.diagram.nodes[group.node];
            drawGroupFrame(win, self.bounds[group.node], node.label, node.kind, start_row, skip);
            self.drawRegionDividers(win, index, start_row, skip);
        }
        for (self.diagram.nodeList(), 0..) |node, index| {
            if (!isGroupKind(node.kind)) self.drawNode(win, index, node, start_row, skip);
        }
        for (self.diagram.relationList()) |*relation| {
            const path = self.route(relation) orelse continue;
            for (path.segments[0..path.segment_count]) |segment| {
                drawSegment(win, segment, relation.style, start_row, skip);
            }
            drawMarker(win, path.src_at, relation.src_marker, path.src_arrow, path.src_line, start_row, skip);
            drawMarker(win, path.dst_at, relation.dst_marker, path.dst_arrow, path.dst_line, start_row, skip);
        }
        for (self.diagram.relationList()) |*relation| {
            const path = self.route(relation) orelse continue;
            if (path.label) |label| cells.putText(win, label.r, label.c, start_row, skip, label.text, self.cols, .{});
            if (relation.src_label) |label| self.drawEndpointLabel(win, path.src_at, path.src_arrow, label, start_row, skip);
            if (relation.dst_label) |label| self.drawEndpointLabel(win, path.dst_at, path.dst_arrow, label, start_row, skip);
        }
    }

    fn drawRegionDividers(
        self: *const Layout,
        win: vaxis.Window,
        group: usize,
        start_row: usize,
        skip: usize,
    ) void {
        const item = self.diagram.groups[group];
        if (item.region_count < 2) return;
        const bounds = self.bounds[item.node];
        for (0..item.region_count - 1) |region| {
            drawRegionDivider(win, bounds, self.region_dividers[group][region], start_row, skip);
        }
    }

    fn drawNode(self: *const Layout, win: vaxis.Window, index: usize, node: Structural.Node, start_row: usize, skip: usize) void {
        const bounds = self.bounds[index];
        switch (node.kind) {
            .start => {
                cells.putRaw(win, bounds.y1, bounds.x1, start_row, skip, "●", .{});
                return;
            },
            .end => {
                cells.putRaw(win, bounds.y1, bounds.x1, start_row, skip, "◉", .{});
                return;
            },
            .fork, .join => {
                for (bounds.x1..bounds.x2 + 1) |column| cells.putHeavy(win, bounds.y1, column, start_row, skip, true, .{});
                return;
            },
            .class, .state, .entity, .choice => {},
            .composite, .namespace, .er_group => return,
        }
        for (0..bounds.height()) |row| {
            for (0..bounds.width()) |column| cells.putRaw(win, bounds.y1 + row, bounds.x1 + column, start_row, skip, " ", .{});
        }
        const corners = switch (node.kind) {
            .state => cells.round,
            .choice => cells.diamond,
            .class, .entity => cells.square,
            .start, .end, .fork, .join, .composite, .namespace, .er_group => unreachable,
        };
        drawBoxFrame(win, bounds, corners, start_row, skip);
        const title_width = cells.maxLineWidth(node.label);
        const title_column = bounds.x1 + (bounds.width() - title_width) / 2;
        cells.putText(win, bounds.y1 + 1, title_column, start_row, skip, node.label, bounds.x2, .{ .bold = true });
        var row = bounds.y1 + 2;
        var seen_detail = false;
        var previous: ?Structural.DetailKind = null;
        for (self.diagram.detailList()) |detail| {
            if (detail.node != index) continue;
            if (!seen_detail or (previous != null and compartment(previous.?) != compartment(detail.kind))) {
                drawDivider(win, bounds, row, start_row, skip);
                row += 1;
            }
            var lines: cells.LineIterator = .{ .remaining = detail.text };
            while (lines.next()) |line| : (row += 1) {
                cells.putText(
                    win,
                    row,
                    bounds.x1 + 2,
                    start_row,
                    skip,
                    line,
                    bounds.x2 - 1,
                    if (detail.kind == .annotation or detail.kind == .note) .{ .dim = true } else .{},
                );
            }
            previous = detail.kind;
            seen_detail = true;
        }
    }

    fn drawEndpointLabel(
        self: *const Layout,
        win: vaxis.Window,
        endpoint: CellPos,
        arrow: []const u8,
        label: []const u8,
        start_row: usize,
        skip: usize,
    ) void {
        const label_width = cells.maxLineWidth(label);
        const column = if (mem.eql(u8, arrow, "►"))
            endpoint.c -| label_width
        else if (mem.eql(u8, arrow, "◄"))
            endpoint.c + 1
        else
            endpoint.c + 2;
        cells.putText(win, endpoint.r, column, start_row, skip, label, self.cols, .{ .dim = true });
    }
};

fn isGroupKind(kind: Structural.NodeKind) bool {
    return kind == .composite or kind == .namespace or kind == .er_group;
}

fn isVertical(direction: Structural.Direction) bool {
    return direction == .tb or direction == .bt;
}

fn endpointLabelWidth(label: ?[]const u8) usize {
    return if (label) |text| cells.maxLineWidth(text) else 0;
}

fn compartment(kind: Structural.DetailKind) u8 {
    return switch (kind) {
        .annotation => 0,
        .attribute, .field => 1,
        .operation => 2,
        .note => 3,
    };
}

fn drawBoxFrame(
    win: vaxis.Window,
    bounds: Bounds,
    corners: [4][]const u8,
    start_row: usize,
    skip: usize,
) void {
    cells.putRaw(win, bounds.y1, bounds.x1, start_row, skip, corners[0], .{});
    cells.putRaw(win, bounds.y1, bounds.x2, start_row, skip, corners[1], .{});
    cells.putRaw(win, bounds.y2, bounds.x1, start_row, skip, corners[2], .{});
    cells.putRaw(win, bounds.y2, bounds.x2, start_row, skip, corners[3], .{});
    for (bounds.x1 + 1..bounds.x2) |column| {
        cells.putRaw(win, bounds.y1, column, start_row, skip, "─", .{});
        cells.putRaw(win, bounds.y2, column, start_row, skip, "─", .{});
    }
    for (bounds.y1 + 1..bounds.y2) |row| {
        cells.putRaw(win, row, bounds.x1, start_row, skip, "│", .{});
        cells.putRaw(win, row, bounds.x2, start_row, skip, "│", .{});
    }
}

fn drawGroupFrame(
    win: vaxis.Window,
    bounds: Bounds,
    label: []const u8,
    kind: Structural.NodeKind,
    start_row: usize,
    skip: usize,
) void {
    const style: vaxis.Style = .{ .dim = true };
    const corners = if (kind == .composite) cells.round else cells.square;
    cells.putRaw(win, bounds.y1, bounds.x1, start_row, skip, corners[0], style);
    cells.putRaw(win, bounds.y1, bounds.x2, start_row, skip, corners[1], style);
    cells.putRaw(win, bounds.y2, bounds.x1, start_row, skip, corners[2], style);
    cells.putRaw(win, bounds.y2, bounds.x2, start_row, skip, corners[3], style);
    for (bounds.x1 + 1..bounds.x2) |column| {
        cells.putRaw(win, bounds.y1, column, start_row, skip, "─", style);
        cells.putRaw(win, bounds.y2, column, start_row, skip, "─", style);
    }
    for (bounds.y1 + 1..bounds.y2) |row| {
        cells.putRaw(win, row, bounds.x1, start_row, skip, "│", style);
        cells.putRaw(win, row, bounds.x2, start_row, skip, "│", style);
    }
    cells.putText(win, bounds.y1, bounds.x1 + 2, start_row, skip, label, bounds.x2 - 1, .{ .bold = true, .dim = true });
}

fn drawRegionDivider(win: vaxis.Window, bounds: Bounds, row: usize, start_row: usize, skip: usize) void {
    const style: vaxis.Style = .{ .dim = true };
    cells.putRaw(win, row, bounds.x1, start_row, skip, "├", style);
    cells.putRaw(win, row, bounds.x2, start_row, skip, "┤", style);
    for (bounds.x1 + 1..bounds.x2) |column| cells.putDotted(win, row, column, start_row, skip, style);
}

fn drawDivider(win: vaxis.Window, bounds: Bounds, row: usize, start_row: usize, skip: usize) void {
    cells.putRaw(win, row, bounds.x1, start_row, skip, "├", .{});
    cells.putRaw(win, row, bounds.x2, start_row, skip, "┤", .{});
    for (bounds.x1 + 1..bounds.x2) |column| cells.putRaw(win, row, column, start_row, skip, "─", .{});
}

fn drawSegment(
    win: vaxis.Window,
    segment: Segment,
    style: Structural.LineStyle,
    start_row: usize,
    skip: usize,
) void {
    const horizontal = segment.r1 == segment.r2;
    var row = segment.r1;
    var column = segment.c1;
    while (true) {
        if (style == .solid) {
            cells.putLine(win, row, column, start_row, skip, if (horizontal) "─" else "│", .{});
        } else if (horizontal) {
            cells.putDotted(win, row, column, start_row, skip, .{});
        } else {
            cells.putDottedVertical(win, row, column, start_row, skip, .{});
        }
        if (row == segment.r2 and column == segment.c2) break;
        if (horizontal) column += 1 else row += 1;
    }
}

fn drawMarker(
    win: vaxis.Window,
    position: CellPos,
    marker: Structural.Marker,
    arrow: []const u8,
    line: []const u8,
    start_row: usize,
    skip: usize,
) void {
    if (marker == .none) {
        cells.putLine(win, position.r, position.c, start_row, skip, line, .{});
        return;
    }
    const glyph = switch (marker) {
        .none => unreachable,
        .arrow => arrow,
        .triangle => "△",
        .diamond => "◆",
        .open_diamond => "◇",
        .lollipop => "○",
        .one => "1",
        .zero_one => "?",
        .one_many => "+",
        .zero_many => "*",
    };
    cells.putRaw(win, position.r, position.c, start_row, skip, glyph, .{});
}

const std = @import("std");
const mem = std.mem;
const Structural = @import("../../mermaid/structural.zig");
const cells = @import("cells.zig");
const vaxis = @import("vaxis");

test "class diagrams render member compartments and inheritance" {
    var diagram = Structural.parseText(
        "classDiagram\n" ++
            "class Animal {\n" ++
            "+String name\n" ++
            "+speak()\n" ++
            "}\n" ++
            "Animal \"1\" <|-- \"*\" Duck : inherits\n",
    ).?;
    const rows = layout(null, &diagram, 0, 0, 60).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(rows), .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &diagram, 0, 0, 60).?;
    try testing.expect(findGlyph(win, "△") != null);
    try testing.expect(findGlyph(win, "1") != null);
    try testing.expect(findGlyph(win, "*") != null);
    try testing.expect(findGlyph(win, "├") != null);
    try testing.expect(findGlyph(win, "s") != null);
}

test "nested class namespaces render labeled frames" {
    var diagram = Structural.parseText(
        "classDiagram\n" ++
            "direction LR\n" ++
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
    const computed = Layout.compute(&diagram, 80).?;
    const outer = computed.bounds[diagram.groups[0].node];
    const inner = computed.bounds[diagram.groups[1].node];
    try testing.expect(outer.x1 < inner.x1 and inner.x2 < outer.x2);
    try testing.expect(outer.y1 < inner.y1 and inner.y2 < outer.y2);
    try testing.expect(computed.bounds[0].x1 < inner.x1);
    try testing.expect(inner.x1 < computed.bounds[1].x1 and computed.bounds[1].x2 < inner.x2);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(computed.rows), .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &diagram, 0, 0, 80).?;
    try testing.expectEqualStrings("┌", win.readCell(@intCast(outer.x1), @intCast(outer.y1)).?.char.grapheme);
    try testing.expect(win.readCell(@intCast(outer.x1), @intCast(outer.y1)).?.style.dim);
    try testing.expect(findGlyph(win, "△") != null);
    try testing.expect(findGlyph(win, "├") != null);
}

test "state diagrams render terminal states choices and backward transitions" {
    var diagram = Structural.parseText(
        "stateDiagram-v2\n" ++
            "[*] --> Ready\n" ++
            "state Choice <<choice>>\n" ++
            "Ready --> Choice\n" ++
            "Choice --> Ready : retry\n" ++
            "Choice --> [*]\n",
    ).?;
    const rows = layout(null, &diagram, 0, 0, 60).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(rows), .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &diagram, 0, 0, 60).?;
    try testing.expect(findGlyph(win, "●") != null);
    try testing.expect(findGlyph(win, "◉") != null);
    try testing.expect(findGlyph(win, "◇") != null);
    try testing.expect(findGlyph(win, "◄") != null);
}

test "nested composite states render framed local layouts" {
    var diagram = Structural.parseText(
        "stateDiagram-v2\n" ++
            "[*] --> First\n" ++
            "First: Outer state\n" ++
            "state First {\n" ++
            "direction LR\n" ++
            "[*] --> Second\n" ++
            "state Second {\n" ++
            "[*] --> Idle\n" ++
            "Idle --> Idle : wait\n" ++
            "Idle --> [*]\n" ++
            "}\n" ++
            "Second --> Second : retry nested composite\n" ++
            "Second --> [*]\n" ++
            "}\n" ++
            "First --> [*]\n",
    ).?;
    const computed = Layout.compute(&diagram, 80).?;
    const outer = computed.bounds[diagram.groups[0].node];
    const inner = computed.bounds[diagram.groups[1].node];
    try testing.expect(outer.x1 < inner.x1 and inner.x2 < outer.x2);
    try testing.expect(outer.y1 < inner.y1 and inner.y2 < outer.y2);
    try testing.expect(inner.width() >= cells.maxLineWidth("retry nested composite") + 2);
    try testing.expect((computed.bounds[2].y1 + computed.bounds[2].y2) / 2 ==
        (computed.bounds[3].y1 + computed.bounds[3].y2) / 2);
    try testing.expect(computed.bounds[2].x1 < computed.bounds[3].x1);
    try testing.expect((computed.bounds[4].y1 + computed.bounds[4].y2) / 2 ==
        (computed.bounds[5].y1 + computed.bounds[5].y2) / 2);
    try testing.expect(computed.bounds[4].x1 < computed.bounds[5].x1);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(computed.rows), .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &diagram, 0, 0, 80).?;
    try testing.expect(win.readCell(@intCast(outer.x1), @intCast(outer.y1)).?.style.dim);
    try testing.expectEqualStrings("╯", win.readCell(@intCast(inner.x2), @intCast(inner.y2)).?.char.grapheme);
    try testing.expect(findGlyph(win, "●") != null);
    try testing.expect(findGlyph(win, "◉") != null);
}

test "concurrent state regions render independent layouts and dividers" {
    var diagram = Structural.parseText(
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
            "Lit --> Dark\n" ++
            "Dark --> Lit\n" ++
            "Lit --> [*]\n" ++
            "}\n" ++
            "CapsLockOff --> CapsLockOn\n" ++
            "}\n",
    ).?;
    const computed = Layout.compute(&diagram, 100).?;
    const active = computed.bounds[diagram.groups[0].node];
    const nested = computed.bounds[diagram.groups[1].node];
    try testing.expect(computed.bounds[1].y1 < computed.bounds[4].y1);
    try testing.expect(computed.bounds[1].x1 < computed.bounds[2].x1);
    try testing.expect(computed.bounds[4].x1 < computed.bounds[5].x1);
    try testing.expect(active.x1 < nested.x1 and nested.x2 < active.x2);
    const lane = computed.region_lanes[0][0];
    const divider = computed.region_dividers[0][0];
    try testing.expectEqual(lane + 1, divider);
    const backward = computed.route(&diagram.relations[2]).?;
    var uses_lane = false;
    for (backward.segments[0..backward.segment_count]) |segment| {
        if (segment.r1 == lane and segment.r2 == lane) uses_lane = true;
    }
    try testing.expect(uses_lane);
    const nested_backward = computed.route(&diagram.relations[6]).?;
    var uses_parent_lane = false;
    for (nested_backward.segments[0..nested_backward.segment_count]) |segment| {
        if (segment.r1 == computed.region_lanes[0][1] and segment.r2 == computed.region_lanes[0][1]) {
            uses_parent_lane = true;
        }
    }
    try testing.expect(uses_parent_lane);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(computed.rows), .cols = 100, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &diagram, 0, 0, 100).?;
    try testing.expectEqualStrings("├", win.readCell(@intCast(active.x1), @intCast(divider)).?.char.grapheme);
    try testing.expectEqualStrings("┄", win.readCell(@intCast(active.x1 + 1), @intCast(divider)).?.char.grapheme);
    try testing.expect(win.readCell(@intCast(active.x1), @intCast(divider)).?.style.dim);
}

test "horizontal choice self-transition labels fit" {
    var diagram = Structural.parseText(
        "stateDiagram-v2\n" ++
            "direction LR\n" ++
            "state Choice <<choice>>\n" ++
            "Choice --> Choice : reconsidering\n",
    ).?;
    const rows = layout(null, &diagram, 0, 0, 40).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(rows), .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &diagram, 0, 0, 40).?;
    try testing.expect(findGlyph(win, "g") != null);
}

test "er diagrams render fields and crow foot markers" {
    var diagram = Structural.parseText(
        "erDiagram\n" ++
            "CUSTOMER ||..o{ ORDER : places\n" ++
            "CUSTOMER {\n" ++
            "string id PK\n" ++
            "}\n",
    ).?;
    const rows = layout(null, &diagram, 0, 0, 60).?;
    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(rows), .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &diagram, 0, 0, 60).?;
    try testing.expect(findGlyph(win, "1") != null);
    try testing.expect(findGlyph(win, "*") != null);
    try testing.expect(findGlyph(win, "┄") != null or findGlyph(win, "┊") != null);
}

test "nested er subgraphs render group relationships and local directions" {
    var diagram = Structural.parseText(
        "erDiagram\n" ++
            "direction LR\n" ++
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
            "sales ||--|| support : collaborates\n" ++
            "support ||--o{ ITEM : handles\n",
    ).?;
    const computed = Layout.compute(&diagram, 120).?;
    const sales = computed.bounds[diagram.groups[0].node];
    const fulfillment = computed.bounds[diagram.groups[1].node];
    const support = computed.bounds[diagram.groups[2].node];
    try testing.expect(sales.x1 < fulfillment.x1 and fulfillment.x2 < sales.x2);
    try testing.expect(sales.y1 < fulfillment.y1 and fulfillment.y2 < sales.y2);
    try testing.expect(sales.x1 < support.x1);
    try testing.expect(computed.bounds[1].y1 < computed.bounds[2].y1);
    try testing.expect(computed.bounds[4].y1 < computed.bounds[5].y1);

    var screen = try vaxis.Screen.init(testing.allocator, .{ .rows = @intCast(computed.rows), .cols = 120, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(testing.allocator);
    const win = window(&screen);
    _ = layout(win, &diagram, 0, 0, 120).?;
    try testing.expectEqualStrings("┌", win.readCell(@intCast(sales.x1), @intCast(sales.y1)).?.char.grapheme);
    try testing.expect(win.readCell(@intCast(sales.x1), @intCast(sales.y1)).?.style.dim);
    try testing.expect(findGlyph(win, "1") != null);
    try testing.expect(findGlyph(win, "*") != null);
}

test "structural diagrams fall back when empty or wider than the viewport" {
    var empty = Structural.parseText("classDiagram\n").?;
    try testing.expect(layout(null, &empty, 0, 0, 40) == null);
    var wide = Structural.parseText("classDiagram\nclass VeryLongClassName\n").?;
    try testing.expect(layout(null, &wide, 0, 0, 8) == null);
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
        for (0..win.width) |column| {
            const cell = win.readCell(@intCast(column), @intCast(row)) orelse continue;
            if (mem.eql(u8, cell.char.grapheme, glyph)) return .{ .r = row, .c = column };
        }
    }
    return null;
}

const testing = std.testing;
