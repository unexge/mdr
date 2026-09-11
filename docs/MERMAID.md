# Mermaid support

`mdr` renders a bounded Mermaid subset as Unicode. A Mermaid fence falls back
to the normal code card when any statement is unsupported, so a diagram is
never rendered only partially. Shape geometry and line appearance use the
closest Unicode forms available in a terminal.

## Flowcharts

Supported:

- `graph` and `flowchart` with `TB`, `TD`, `BT`, `LR`, and `RL`
- Plain and quoted node labels
- Rectangle, rounded, stadium, subroutine, cylinder, circle, asymmetric,
  diamond, hexagon, parallelogram, trapezoid, and double-circle nodes
- Built-in non-media `@{ shape: ..., label: ... }` shapes mapped to the
  nearest terminal geometry
- Visually distinct solid, dotted, thick, invisible, circle, cross, and
  bidirectional links
- Link labels, edge IDs, requested minimum lengths, chained links, and
  `A & B --> C & D` multi-node links
- Labeled and nested subgraphs with local directions and edges to subgraph IDs
- Cycles, backward edges, and self-links using outer or local routes
- Multiline Markdown node labels, class assignments, style declarations, and
  semicolon-separated statements; terminal rendering uses the active theme
- `%%` comments

Falls back:

- Icons and image nodes
- Edge animation, click actions, and configuration directives

## Sequence diagrams

Supported:

- `participant` and `actor`, including `as` aliases, IDs containing spaces,
  hyphens, or equals signs, and all participant stereotypes
- Participant `box` groups wherever Mermaid permits them, with named and RGB
  colors applied to terminal borders
- Actor and participant creation and destruction, including inside fragments
- Solid and dotted plain, arrow, cross, open, bidirectional, and half-arrow
  messages
- Source, destination, and dual `()` central connections, including self-messages
- Notes over, left of, and right of participants
- `loop`, `alt`/`else`, `opt`, `par`/`par_over`/`and`, `critical`/`option`,
  `break`, and `rect` fragments
- Stacked activations and the `+`/`-` activation shorthand
- `autonumber`, optional start and increment values, and `autonumber off`
- Case-insensitive keywords and semicolon-separated statements
- Titles, accessibility metadata, frontmatter, and configuration directives
- Actor links as terminal hyperlinks; properties and details render as notes
- Multiline participant, note, message, and title labels
- Common Mermaid and HTML entities decoded
- `%%` and `#` comments

Falls back:

- Participant boxes containing non-participant lines
- Actor creation or destruction without an immediately matching message
- Browser-only popup menus, CSS styling, and JavaScript callbacks

## Class diagrams

Supported:

- `classDiagram` declarations, labels, escaped names, annotations, and generic names
- Attributes and operations declared with `:` or multiline `{ ... }` bodies
- Solid and dotted inheritance, realization, composition, aggregation,
  association, dependency, two-way inheritance, and lollipop relationships
- Relationship labels and endpoint cardinalities
- `TB`, `TD`, `BT`, `LR`, and `RL` directions
- `style`, `classDef`, and `cssClass` declarations accepted using the active terminal theme
- `%%` comments, frontmatter, and configuration directives

Falls back:

- Namespaces, notes, interactions, callbacks, and links
- Inline member bodies and semicolon-separated statements

## State diagrams

Supported:

- `stateDiagram` and `stateDiagram-v2`
- Plain states, quoted descriptions with aliases, and `id: description` declarations
- Labeled transitions, including cycles, backward transitions, and self-transitions
- Start and end states plus choice, fork, and join states
- Single-line notes attached to the left or right of a state
- `TB`, `TD`, `BT`, `LR`, and `RL` directions
- Style and class assignments accepted using the active terminal theme
- `%%` comments, frontmatter, configuration, and accessibility directives

Falls back:

- Composite states, concurrency regions, and multiline notes

## Entity-relationship diagrams

Supported:

- `erDiagram` entities, quoted names, aliases, and multiline attribute bodies
- Attribute types, keys, and comments rendered verbatim
- Symbolic crow's-foot cardinalities with identifying and non-identifying links
- Relationship labels and `TB`, `TD`, `BT`, `LR`, and `RL` directions
- Style and class assignments accepted using the active terminal theme
- `%%` comments, frontmatter, and configuration directives

Falls back:

- Textual relationship aliases such as `one or more`
- ER subgraphs

Other Mermaid diagram families, including Gantt, pie, Git, mindmap, timeline,
quadrant, requirement, block, and architecture diagrams, fall back to the code card.

A supported flowchart falls back above 64 nodes, 128 edges, 16 subgraphs, or
8 nested subgraphs. A supported sequence falls back above 32 participants,
128 messages, 32 notes, 16 fragments, 8 nested fragments, 64 activations, or
16 participant boxes. Class, state, and ER diagrams fall back above 64 nodes,
256 detail lines, or 128 relationships. All diagrams fall back when they exceed
200 terminal rows, a route cannot be placed, or the result does not fit the viewport.
