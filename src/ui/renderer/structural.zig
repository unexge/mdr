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
    vertical_flow: bool,
    rows: usize,
    cols: usize,

    fn compute(diagram: *const Structural.Diagram, width: usize) ?Layout {
        if (diagram.degraded or diagram.node_count == 0) return null;
        var result: Layout = .{
            .diagram = diagram,
            .widths = [_]usize{0} ** Structural.max_nodes,
            .heights = [_]usize{0} ** Structural.max_nodes,
            .bounds = undefined,
            .vertical_flow = diagram.direction == .tb or diagram.direction == .bt,
            .rows = 0,
            .cols = 0,
        };
        var max_node_width: usize = 0;
        var max_node_height: usize = 0;
        for (diagram.nodeList(), 0..) |node, index| {
            const size = result.nodeSize(index, node);
            result.widths[index] = size.width;
            result.heights[index] = size.height;
            max_node_width = @max(max_node_width, size.width);
            max_node_height = @max(max_node_height, size.height);
        }
        const relation_text_width = result.maxRelationTextWidth();
        if (result.vertical_flow) {
            const gap: usize = 3;
            var content_height: usize = 0;
            for (result.heights[0..diagram.node_count]) |height| content_height += height;
            content_height += gap * (diagram.node_count - 1);
            result.rows = content_height + 2;
            result.cols = max_node_width + 2 + relation_text_width + @intFromBool(relation_text_width > 0);
            if (result.rows > max_rows or result.cols > width) return null;
            var cursor: usize = if (diagram.direction == .tb) 1 else result.rows - 1;
            for (0..diagram.node_count) |index| {
                const height = result.heights[index];
                const y = if (diagram.direction == .tb) cursor else cursor - height;
                const x = 1 + (max_node_width - result.widths[index]) / 2;
                result.bounds[index] = .{
                    .x1 = x,
                    .y1 = y,
                    .x2 = x + result.widths[index] - 1,
                    .y2 = y + height - 1,
                };
                if (diagram.direction == .tb) cursor += height + gap else cursor = y -| gap;
            }
        } else {
            const gap = result.horizontalGap();
            var content_width: usize = 0;
            for (result.widths[0..diagram.node_count]) |node_width| content_width += node_width;
            content_width += gap * (diagram.node_count - 1);
            result.cols = content_width + 2;
            result.rows = max_node_height + 3;
            if (result.rows > max_rows or result.cols > width) return null;
            var cursor: usize = if (diagram.direction == .lr) 1 else result.cols - 1;
            for (0..diagram.node_count) |index| {
                const node_width = result.widths[index];
                const x = if (diagram.direction == .lr) cursor else cursor - node_width;
                const y = 1 + (max_node_height - result.heights[index]) / 2;
                result.bounds[index] = .{
                    .x1 = x,
                    .y1 = y,
                    .x2 = x + node_width - 1,
                    .y2 = y + result.heights[index] - 1,
                };
                if (diagram.direction == .lr) cursor += node_width + gap else cursor = x -| gap;
            }
        }
        for (diagram.relationList()) |*relation| _ = result.route(relation) orelse return null;
        return result;
    }

    fn nodeSize(self: *const Layout, index: usize, node: Structural.Node) struct { width: usize, height: usize } {
        var self_label_width: usize = 0;
        for (self.diagram.relationList()) |relation| {
            if (relation.src != index or relation.dst != index or relation.label == null) continue;
            self_label_width = @max(self_label_width, cells.maxLineWidth(relation.label.?));
        }
        switch (node.kind) {
            .start, .end => return .{ .width = 1, .height = 1 },
            .fork, .join => return .{ .width = @max(self_label_width + 2, 7), .height = 1 },
            .choice => return .{ .width = @max(@max(cells.maxLineWidth(node.label) + 4, self_label_width + 2), 5), .height = 3 },
            .class, .state, .entity => {},
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
        const adjacent = if (relation.src < relation.dst)
            relation.dst - relation.src == 1
        else
            false;
        if (!adjacent) return self.routeOuter(relation);
        const source = self.bounds[relation.src];
        const destination = self.bounds[relation.dst];
        const source_center = CellPos{ .r = (source.y1 + source.y2) / 2, .c = (source.x1 + source.x2) / 2 };
        const destination_center = CellPos{ .r = (destination.y1 + destination.y2) / 2, .c = (destination.x1 + destination.x2) / 2 };
        var path: Path = undefined;
        path.segment_count = 0;
        path.label = null;
        if (self.vertical_flow) {
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

    fn routeOuter(self: *const Layout, relation: *const Structural.Relation) ?Path {
        const source = self.bounds[relation.src];
        const destination = self.bounds[relation.dst];
        const source_center = CellPos{ .r = (source.y1 + source.y2) / 2, .c = (source.x1 + source.x2) / 2 };
        const destination_center = CellPos{ .r = (destination.y1 + destination.y2) / 2, .c = (destination.x1 + destination.x2) / 2 };
        var path: Path = undefined;
        path.segment_count = 0;
        path.label = null;
        if (self.vertical_flow) {
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
            const lane = self.rows - 1;
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
        for (self.diagram.nodeList(), 0..) |node, index| self.drawNode(win, index, node, start_row, skip);
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
        }
        for (0..bounds.height()) |row| {
            for (0..bounds.width()) |column| cells.putRaw(win, bounds.y1 + row, bounds.x1 + column, start_row, skip, " ", .{});
        }
        const corners = switch (node.kind) {
            .state => cells.round,
            .choice => cells.diamond,
            else => cells.square,
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
const Structural = @import("../../MermaidStructural.zig");
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
