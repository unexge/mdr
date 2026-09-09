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

pub fn layout(win: ?vaxis.Window, flow: *const Mermaid.Flowchart, start_row: usize, skip: usize, width: usize) ?usize {
    var grid = Grid.compute(flow, width) orelse return null;
    if (win == null) return start_row + grid.rows;
    const w = win.?;
    grid.draw(w, start_row, skip);
    return start_row + @min(grid.rows -| skip, w.height -| start_row);
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
        const cap = self.count -| 1;
        for (0..self.count) |_| {
            for (self.flow.edgeList()) |*edge| {
                const s = nodeIndex(self.flow, edge.src) orelse continue;
                const d = nodeIndex(self.flow, edge.dst) orelse continue;
                if (s == d) continue;
                const r = @min(self.rank[s] + 1, cap);
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
        var cols: usize = 0;
        for (0..self.n_cross) |c| {
            self.cpos[c] = cols;
            cols += self.cw[c] + 3;
        }
        cols -|= 3;
        for (0..self.count) |i| {
            self.x[i] = self.cpos[self.slot[i]] + (self.cw[self.slot[i]] - self.w[i]) / 2;
        }
        self.assignLabelRows();
        self.fwd[0] = 0;
        for (0..self.n_layers) |l| {
            self.fwd[l + 1] = self.fwd[l] + 3 + 2 + self.glabels[l];
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
        self.fwd[0] = 0;
        for (0..self.n_layers) |l| {
            self.fwd[l + 1] = self.fwd[l] + self.bandWidth(l) + 4 + if (self.lmax[l] > 0) self.lmax[l] + 1 else 0;
        }
        const cols = self.fwd[self.n_layers] -| 4;
        for (0..self.count) |i| {
            const fx = self.fwd[self.rank[i]];
            const bw = self.bandWidth(self.rank[i]);
            const bx = if (self.forward) fx else cols - (fx + bw);
            self.x[i] = bx + (bw - self.w[i]) / 2;
        }
        self.cpos[0] = 0;
        for (0..self.n_cross) |t| {
            self.cpos[t + 1] = self.cpos[t] + 3;
        }
        self.rows = self.cpos[self.n_cross];
        if (self.hasLongEdge()) {
            self.wire = self.rows;
            self.rows += 1;
        }
        if (self.rows > max_rows) return null;
        self.cols = cols;
        if (self.cols > width) return null;
        for (0..self.count) |i| self.y[i] = self.cpos[self.slot[i]];
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
        for (self.flow.nodeList(), 0..) |*node, i| {
            drawBox(win, node, self.x[i], self.y[i], self.w[i], start_row, skip);
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

    fn drawBox(win: vaxis.Window, node: *const Mermaid.Node, x: usize, y: usize, bw: usize, start_row: usize, skip: usize) void {
        const corners = switch (node.shape) {
            .rounded, .stadium, .circle, .cylinder, .double_circle => cells.round,
            .diamond => cells.diamond,
            else => cells.square,
        };
        cells.box(win, x, y, bw, node.label, corners, start_row, skip, .{});
    }
};

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

fn expectGlyph(win: vaxis.Window, col: u16, row: u16, expected: []const u8) !void {
    const cell = win.readCell(col, row) orelse return error.TestUnexpectedCell;
    try testing.expectEqualStrings(expected, cell.char.grapheme);
}

const testing = std.testing;
