# mdr

A Markdown reader for the terminal written in Zig using [libvaxis](https://github.com/rockorager/libvaxis) under the hood.

## Demo

https://github.com/user-attachments/assets/4d136ba2-6375-4b1f-ade3-998bba08fc7f

This demo runs `mdr` in a [Zellij floating pane](https://zellij.dev/features/#floating-panes) with the following Nushell function:

```nu
def md [file: path] {
    zellij run --close-on-exit --floating -- mdr $file
}
```

## Install

On x86_64 Linux:

```sh
curl -fLO https://github.com/unexge/mdr/releases/latest/download/mdr-x86_64-linux.tar.gz
tar -xzf mdr-x86_64-linux.tar.gz
sudo install mdr-x86_64-linux/mdr /usr/local/bin/mdr
rm -rf mdr-x86_64-linux.tar.gz mdr-x86_64-linux
```

For other platforms, download the matching archive from the [latest release](https://github.com/unexge/mdr/releases/latest).

## Features

- Headings, styled text, inline code, links, dividers, nested lists, tasks, quotes, and aligned tables
- Syntax-highlighted code blocks for Bash, C/C++, Go, JSON, JavaScript/JSX, Python, Rust, TypeScript/TSX, and Zig
- Local images in supported terminals, plus clickable placeholders for remote images
- Mermaid flowcharts, sequence, class, state, and entity-relationship diagrams; unsupported diagrams remain code ([support matrix](docs/MERMAID.md))
- Vim-style scrolling and an auto-hiding scrollbar
- Search with highlighted matches and next and previous controls
- Table of contents for quick jumps between headings
- Adapts to the terminal size and renders content as needed; images and syntax highlighting load in the background

## Keys

| Keys                                         | Action                                               |
| -------------------------------------------- | ---------------------------------------------------- |
| `j` / `k`, arrows                            | Scroll one line                                      |
| `Space` / `f`, `Ctrl-f` / `Ctrl-b`           | Page down / up                                       |
| `Ctrl-d` / `Ctrl-u`                          | Half page down / up                                  |
| `g` / `G`, Home / End                        | Top / bottom                                         |
| `/` then type                                | Search, jumps to the first match after a short delay |
| `Enter` / `Esc` in search                    | Keep highlight and close / clear search              |
| `n` / `N`                                    | Next / previous match (`1/3` counter top right)      |
| `t`                                          | Table of contents, `Up` / `Down` jump between headings |
| `Enter` / `Esc` in table of contents         | Stay at heading / return to previous position          |
| `Ctrl-Backspace` / `Alt-Backspace` in search | Clear the query                                      |
| `Ctrl-l`                                     | Redraw                                               |
| `q`, `Ctrl-c`                                | Quit                                                 |

## Build and run

Requires Zig 0.17.0-dev.27+0dd99c37c.

```sh
zig build            # produces zig-out/bin/mdr
zig build test       # unit tests
zig build benchmark-mermaid -Doptimize=ReleaseFast
zig fmt .            # format before committing

mdr <file.md>
<cmd> | mdr        # read from stdin
mdr -              # read from stdin
```

## Testing

`zig build test` runs unit tests and fuzz corpora. `zig build bombadil`
drives the TUI through a pseudo-terminal with randomized input (see
`bombadil/`).
