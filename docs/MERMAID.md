# Mermaid support

`mdr` renders a bounded Mermaid subset as Unicode. A Mermaid fence falls back
to the normal code card when any statement is unsupported, so a diagram is
never rendered only partially. Shape geometry and line appearance are
approximated with the Unicode forms available in a terminal.

## Flowcharts

Supported:

- `graph` and `flowchart` with `TB`, `TD`, `BT`, `LR`, and `RL`
- Plain and quoted node labels
- Rectangle, rounded, stadium, subroutine, cylinder, circle, asymmetric,
  diamond, hexagon, parallelogram, trapezoid, and double-circle nodes
- `@{ shape: ..., label: ... }` for `rect`, `rounded`, `stadium`, `subproc`,
  `subroutine`, `cyl`, `cylinder`, `circle`, `odd`, `diamond`, `diam`, `hex`,
  `hexagon`, `lean-r`, `lean-l`, `trap-b`, `trap-t`, and `dbl-circ`
- Solid, dotted, thick, invisible, circle, cross, and bidirectional links
- Link labels, chained links, and `A & B --> C & D` multi-node links
- Labeled and nested subgraphs whose direction matches the parent flowchart
- `%%` comments

Falls back:

- Subgraph direction overrides and edges targeting a subgraph ID
- Subgraph layouts whose boundaries would overlap unrelated nodes or groups
- Unlisted expanded shapes, icons, and image nodes
- Edge IDs, animation, and requested minimum link lengths
- Styles, classes, click actions, and configuration directives
- Markdown strings and semicolon-separated statements

## Sequence diagrams

Supported:

- `participant` and `actor`, including `as` aliases
- Solid and dotted plain, arrow, cross, open, and bidirectional messages
- Notes over, left of, and right of participants
- `loop`, `alt`/`else`, `opt`, `par`/`and`, `critical`/`option`, `break`, and
  `rect` fragments
- Activations and the `+`/`-` activation shorthand
- `autonumber`
- `%%` comments

Falls back:

- Participant stereotypes, participant boxes, and actor creation/destruction
- Half arrows and central connections
- Stacked activations
- Autonumber start and increment arguments
- Actor links, styling, configuration directives, and semicolon-separated
  statements

Other Mermaid diagram families, including class, state, ER, Gantt, pie, Git,
mindmap, and timeline diagrams, fall back to the code card.

A supported diagram also falls back when it exceeds the bounded parser tables,
contains a cycle the layout cannot place, or does not fit the viewport.
