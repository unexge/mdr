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

const flowchart = @import("mermaid/flowchart.zig");
const sequence = @import("mermaid/sequence.zig");
const structural = @import("mermaid/structural.zig");
