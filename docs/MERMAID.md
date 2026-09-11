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

Other Mermaid diagram families, including class, state, ER, Gantt, pie, Git,
mindmap, and timeline diagrams, fall back to the code card.

A supported diagram also falls back when it exceeds the bounded parser tables,
a route cannot be placed, or the result does not fit the viewport.
