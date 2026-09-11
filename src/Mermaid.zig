//! Bounded, zero-copy Mermaid diagram parsers.

pub const max_nodes = flowchart.max_nodes;
pub const max_edges = flowchart.max_edges;
pub const max_subgraphs = flowchart.max_subgraphs;
pub const max_subgraph_depth = flowchart.max_subgraph_depth;
pub const Direction = flowchart.Direction;
pub const Shape = flowchart.Shape;
pub const EdgeStyle = flowchart.EdgeStyle;
pub const EdgeMarker = flowchart.EdgeMarker;
pub const Node = flowchart.Node;
pub const Subgraph = flowchart.Subgraph;
pub const Edge = flowchart.Edge;
pub const Flowchart = flowchart.Flowchart;
pub const parseBlock = flowchart.parseBlock;
pub const parseText = flowchart.parseText;

pub const max_participants = sequence.max_participants;
pub const max_messages = sequence.max_messages;
pub const max_notes = sequence.max_notes;
pub const max_fragments = sequence.max_fragments;
pub const max_fragment_depth = sequence.max_fragment_depth;
pub const max_activations = sequence.max_activations;
pub const max_participant_boxes = sequence.max_participant_boxes;
pub const ParticipantKind = sequence.ParticipantKind;
pub const Participant = sequence.Participant;
pub const ParticipantBox = sequence.ParticipantBox;
pub const MsgStyle = sequence.MsgStyle;
pub const MsgEndpoint = sequence.MsgEndpoint;
pub const CentralConnection = sequence.CentralConnection;
pub const Message = sequence.Message;
pub const NoteKind = sequence.NoteKind;
pub const Note = sequence.Note;
pub const FragmentOp = sequence.FragmentOp;
pub const Divider = sequence.Divider;
pub const Fragment = sequence.Fragment;
pub const Activation = sequence.Activation;
pub const Autonumber = sequence.Autonumber;
pub const Sequence = sequence.Sequence;
pub const parseSequenceBlockText = sequence.parseSequenceBlockText;
pub const parseSequenceBlock = sequence.parseSequenceBlock;

pub const Structural = structural;

pub const Parsed = union(enum) {
    flowchart: Flowchart,
    sequence: Sequence,
    structural: Structural.Diagram,
};

pub fn parseAnyBlock(cb: Document.Element.CodeBlock) ?Parsed {
    return switch (blockKind(cb) orelse return null) {
        .flowchart => .{ .flowchart = flowchart.parseBlock(cb) orelse return null },
        .sequence => .{ .sequence = sequence.parseSequenceBlock(cb) orelse return null },
        .structural => .{ .structural = structural.parseBlock(cb) orelse return null },
    };
}

const Kind = enum { flowchart, sequence, structural };

fn blockKind(cb: Document.Element.CodeBlock) ?Kind {
    const info = cb.info orelse return null;
    if (!info.isMermaid()) return null;
    var frontmatter = false;
    var lines = cb.lines();
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (mem.eql(u8, line, "---")) {
            frontmatter = !frontmatter;
            continue;
        }
        if (frontmatter or common.isComment(line) or common.isConfigDirective(line) or line[0] == '#') continue;
        var end: usize = 0;
        while (end < line.len and line[end] != ' ' and line[end] != '\t' and line[end] != ';') : (end += 1) {}
        const header = line[0..end];
        if (common.eqlIgnoreCase(header, "graph") or common.eqlIgnoreCase(header, "flowchart")) return .flowchart;
        if (common.eqlIgnoreCase(header, "sequenceDiagram")) return .sequence;
        if (common.eqlIgnoreCase(header, "classDiagram") or common.eqlIgnoreCase(header, "stateDiagram") or
            common.eqlIgnoreCase(header, "stateDiagram-v2") or common.eqlIgnoreCase(header, "erDiagram")) return .structural;
        return null;
    }
    return null;
}

const std = @import("std");
const Document = @import("Document.zig");
const common = @import("mermaid/common.zig");
const flowchart = @import("mermaid/flowchart.zig");
const sequence = @import("mermaid/sequence.zig");
const structural = @import("mermaid/structural.zig");
const mem = std.mem;

test "parseAnyBlock selects one Mermaid family" {
    const cases = [_]struct { content: []const u8, kind: std.meta.Tag(Parsed) }{
        .{ .content = "%% comment\ngraph TD\nA-->B\n", .kind = .flowchart },
        .{ .content = "---\ntitle: Call\n---\nsequenceDiagram\nA->>B: hi\n", .kind = .sequence },
        .{ .content = "%%{init: {'theme': 'dark'}}%%\nstateDiagram-v2\nA-->B\n", .kind = .structural },
    };
    for (cases) |case| {
        const parsed = parseAnyBlock(.{ .info = .{ .mermaid = "mermaid" }, .content = case.content }) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.kind, std.meta.activeTag(parsed));
    }
    try std.testing.expect(parseAnyBlock(.{ .info = .{ .mermaid = "mermaid" }, .content = "pie\ntitle Pets\n" }) == null);
}
