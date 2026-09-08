# mdr

A Markdown reader for the terminal, written in Zig. Parses lazily so huge
files open instantly, and renders through [libvaxis](https://github.com/rockorager/libvaxis).

## Build and run

Requires Zig 0.16 or newer.

```sh
zig build            # produces zig-out/bin/mdr
zig build test       # unit tests
zig fmt .            # format before committing

mdr <file.md>
```

## Keys

| Keys | Action |
|---|---|
| `j` / `k`, arrows | Scroll one line |
| `Space` / `f`, `Ctrl-f` / `Ctrl-b` | Page down / up |
| `Ctrl-d` / `Ctrl-u` | Half page down / up |
| `g` / `G`, Home / End | Top / bottom |
| `Ctrl-l` | Redraw |
| `q`, `Ctrl-c` | Quit |

## Features

- CommonMark plus GFM strikethrough, task lists, tables, and reference links
- Fenced code blocks as cards; local images via Kitty graphics
- Mermaid `graph`/`flowchart` and `sequenceDiagram` rendered as unicode
  diagrams (anything unrenderable falls back to the code card)

## Testing

`zig build test` runs unit tests, property-style randomized rendering
checks, and fuzz corpora. `zig build bombadil` drives the TUI through a
pseudo-terminal with randomized input (see `bombadil/`).
