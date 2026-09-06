//! Zero-copy, lazily parsed Markdown (CommonMark flavored, plus GFM
//! strikethrough, task lists and reference links).
//!
//! `Document` returns one block-level `Element` per `next` call; every slice
//! it hands out points into the input text. Containers carry iterators:
//! `List.items` yields `ListItem`s, and lists, items and block quotes expose
//! a `Blocks` iterator over their children. Inline formatting is an event
//! stream: `Spans` yields open/close markers around nested emphasis,
//! strikethrough and links, plus code spans, entities, escapes and line
//! breaks. Text spans are single lines; soft breaks are events.
//! `parse` reads a `std.Io.Reader` into a single buffer, the only allocation
//! in the library; `init` borrows text already in memory. Markdown has no
//! syntax errors, so parsing cannot fail.
//!
//! Not supported yet: indented code blocks, HTML and inline or reference
//! images. Standalone direct images are block elements. Container nesting
//! deeper than 8 levels degrades to plain text.

const Document = @This();

/// The full input text. Every returned slice points into this buffer.
text: []const u8,
cursor: usize = 0,
/// Set by `parse`, freed by `deinit`.
owned: ?[]u8 = null,
gpa: ?mem.Allocator = null,
/// Reference definitions, scanned once on first use.
refs: RefTable = .{},

/// Reads the entire stream into one buffer; the reader is not retained.
/// Wrap the reader in `limited()` first to bound memory for untrusted input.
pub fn parse(reader: *Io.Reader, gpa: mem.Allocator) ParseError!Document {
    const owned = try reader.allocRemaining(gpa, .unlimited);
    return .{ .text = owned, .owned = owned, .gpa = gpa, .refs = .{ .text = owned } };
}

pub const ParseError = Io.Reader.LimitedAllocError;

/// Borrows `text`; it must stay valid and unmodified while iterating.
pub fn init(text: []const u8) Document {
    return .{ .text = text, .refs = .{ .text = text } };
}

/// Frees the `parse` buffer; a no-op for `init` documents.
pub fn deinit(self: *Document) void {
    if (self.owned) |buf| self.gpa.?.free(buf);
    self.* = undefined;
}

/// Returns the next block-level element, or null at the end.
pub fn next(self: *Document) ?Element {
    self.refs.text = self.text;
    var blocks: Blocks = .{
        .text = self.text,
        .cursor = self.cursor,
        .end = self.text.len,
        .refs = &self.refs,
    };
    const elem = blocks.next() orelse return null;
    self.cursor = blocks.cursor;
    return elem;
}

/// One block-level element; all payloads are slices into `Document.text`.
pub const Element = union(enum) {
    header: Header,
    paragraph: Paragraph,
    image: Image,
    code_block: CodeBlock,
    thematic_break: ThematicBreak,
    list: List,
    block_quote: BlockQuote,
    table: Table,

    pub const Header = struct {
        /// 1 to 6.
        level: u8,
        content: []const u8,
        /// Container prefixes to strip per line (setext headers only).
        chain: Chain = .{},
        /// Reference definitions for `[text][label]` links.
        refs: ?*RefTable = null,

        pub fn spans(self: Header) Spans {
            return .initChain(self.content, self.chain);
        }
    };

    pub const Paragraph = struct {
        /// Raw text of the block. Inside containers this still carries the
        /// container prefixes of continuation lines; `lines` and `spans`
        /// strip them.
        content: []const u8,
        chain: Chain = .{},
        /// Reference definitions for `[text][label]` links.
        refs: ?*RefTable = null,

        pub fn lines(self: Paragraph) LineIterator {
            return .{ .remaining = self.content, .chain = self.chain };
        }

        pub fn spans(self: Paragraph) Spans {
            return .initChain(self.content, self.chain);
        }
    };

    pub const Image = struct {
        alt: []const u8,
        source: []const u8,
        title: ?[]const u8,
    };

    pub const CodeBlock = struct {
        info: ?[]const u8,
        /// Raw text between the fences, including container prefixes; use
        /// `lines` for the stripped, verbatim lines.
        content: []const u8,
        chain: Chain = .{},

        pub fn lines(self: CodeBlock) LineIterator {
            return .{ .remaining = self.content, .chain = self.chain, .first = false };
        }
    };

    pub const ThematicBreak = struct {};

    pub const List = struct {
        /// True for `1.` / `1)`, false for `-` / `*` / `+`.
        ordered: bool,
        /// First number of an ordered list.
        start: u32,
        /// No blank lines between or inside items.
        tight: bool,
        items: Items,

        pub const Items = struct {
            text: []const u8,
            /// Container prefixes preceding every marker line.
            chain: Chain = .{},
            /// Absolute start of the next item.
            cursor: usize,
            /// Exclusive end of the whole list.
            end: usize,
            ordered: bool,
            bullet: u8 = 0,
            /// `.` or `)` for ordered lists.
            delim: u8 = 0,
            /// Set once a line that cannot continue the list is reached.
            done: bool = false,
            loose: bool = false,
            /// Reference table threaded into item blocks.
            refs: ?*RefTable = null,

            /// Parses the next item's marker and bounds; the item's blocks
            /// are parsed lazily through `ListItem.blocks`.
            pub fn next(self: *Items) ?ListItem {
                if (self.done or self.cursor >= self.end) return null;
                const text = self.text;
                const first = chainLine(self.chain, text, self.cursor, self.end, false);
                const extra = leadingSpaces(first.content);
                const marker = parseMarkerLine(first.content[extra..]) orelse {
                    self.done = true;
                    self.cursor = self.end;
                    return null;
                };

                var indent = extra + marker.contentIndent();
                var content_start = first.start + extra + marker.len + marker.spaces_raw;
                var task: ?bool = null;
                var task_glyph: []const u8 = "";
                if (taskMarker(first.content[extra + marker.len + marker.spaces_raw ..])) |t| {
                    task = t.done;
                    task_glyph = first.content[extra + marker.len + marker.spaces_raw ..][0..3];
                    indent += task_width;
                    content_start += task_width;
                }
                const body = first.content[extra + marker.len + marker.spaces_raw ..];
                const marker_text = first.content[extra..][0..marker.len];
                var content_end = first.raw_end;
                var last_para = paragraphish(body);

                var pending_blank = false;
                var scan = first.next;
                while (scan < self.end) {
                    const line = chainLine(self.chain, text, scan, self.end, false);
                    if (isBlankLine(line.content)) {
                        pending_blank = true;
                        scan = line.next;
                        continue;
                    }
                    const line_extra = leadingSpaces(line.content);
                    if (line_extra >= indent) {
                        if (pending_blank) {
                            self.loose = true;
                            pending_blank = false;
                        }
                        content_end = line.raw_end;
                        last_para = paragraphish(line.content);
                        scan = line.next;
                        continue;
                    }
                    if (line_extra <= 3) {
                        const body_line = line.content[line_extra..];
                        if (parseMarkerLine(body_line)) |sibling| {
                            if (sibling.sameKindAs(self)) {
                                if (pending_blank) {
                                    self.loose = true;
                                    pending_blank = false;
                                }
                                self.cursor = scan;
                                return self.item(task, task_glyph, marker_text, indent, content_start, content_end);
                            }
                            self.done = true;
                            self.cursor = scan;
                            return self.item(task, task_glyph, marker_text, indent, content_start, content_end);
                        }
                        if (!pending_blank and last_para and paragraphish(line.content)) {
                            content_end = line.raw_end;
                            last_para = true;
                            scan = line.next;
                            continue;
                        }
                    }
                    self.done = true;
                    self.cursor = scan;
                    return self.item(task, task_glyph, marker_text, indent, content_start, content_end);
                }
                self.done = true;
                self.cursor = self.end;
                return self.item(task, task_glyph, marker_text, indent, content_start, content_end);
            }

            fn item(self: *Items, task: ?bool, task_glyph: []const u8, marker: []const u8, indent: usize, start: usize, end: usize) ListItem {
                const chain = self.chain.push(.{ .spaces = indent });
                if (chain == null or start >= end) {
                    return .{ .task = task, .task_glyph = task_glyph, .marker = marker, .indent = indent, .blocks = .{
                        .text = self.text,
                        .cursor = end,
                        .end = end,
                        .mid_line = true,
                        .refs = self.refs,
                    } };
                }
                return .{
                    .task = task,
                    .task_glyph = task_glyph,
                    .marker = marker,
                    .indent = indent,
                    .blocks = .{
                        .text = self.text,
                        .cursor = start,
                        .end = end,
                        .mid_line = true,
                        .chain = chain.?,
                        .refs = self.refs,
                    },
                };
            }
        };
    };

    pub const BlockQuote = struct {
        blocks: Blocks,
    };

    pub const Table = struct {
        ncols: usize,
        aligns: [max_table_cols]Alignment,
        header: []const u8,
        body: []const u8,
        chain: Chain = .{},
        refs: ?*RefTable = null,
    };
};

/// Width of the `- [x] ` task marker relative to the list marker.
const task_width = 4;

/// Maximum table columns; wider tables degrade to paragraphs.
pub const max_table_cols = 32;

pub const Alignment = enum { left, center, right };

pub const ListItem = struct {
    /// null when not a task list item; otherwise checked state.
    task: ?bool,
    /// Raw text of the task checkbox, e.g. `[x]`; only for task items.
    task_glyph: []const u8 = "",
    /// Raw text of the list marker, e.g. `-` or `12.`.
    marker: []const u8,
    /// Content indent in columns, for renderers.
    indent: usize,
    blocks: Blocks,
};

/// Iterates the block children of a container (list item, block quote) or
/// of the whole document.
pub const Blocks = struct {
    text: []const u8,
    /// Position of the next unparsed byte; mid-line on the first call when
    /// the parent already stripped the first line's prefixes.
    cursor: usize,
    /// Exclusive end of this container's content.
    end: usize,
    mid_line: bool = false,
    chain: Chain = .{},
    /// Reference table threaded into elements; null in tests.
    refs: ?*RefTable = null,
    /// Only the definition probe records; normal iteration just strips.
    record: bool = false,

    pub fn next(self: *Blocks) ?Element {
        const text = self.text;
        var first = self.mid_line;
        self.mid_line = false;

        while (true) {
            while (self.cursor < self.end) {
                const blank = chainLine(self.chain, text, self.cursor, self.end, first);
                if (!isBlankLine(blank.content)) break;
                self.cursor = blank.next;
                first = false;
            }
            if (self.cursor >= self.end) return null;

            const line = chainLine(self.chain, text, self.cursor, self.end, first);
            first = false;
            const extra = leadingSpaces(line.content);
            if (extra <= 3) {
                const body = line.content[extra..];
                if (parseAtxHeader(body)) |header| {
                    self.cursor = line.next;
                    return .{ .header = .{ .level = header.level, .content = header.content, .chain = self.chain, .refs = self.refs } };
                }
                if (parseFence(body)) |fence| return self.parseCodeBlock(fence, line);
                if (isThematicBreak(body)) {
                    self.cursor = line.next;
                    return .thematic_break;
                }
                if (body.len > 0 and body[0] == '>') return self.parseQuote(line);
                if (parseMarkerLine(body)) |marker| return self.parseList(marker);
                if (self.parseTable(line)) |table| return table;
                if (self.parseStandaloneImage(body)) |image| {
                    self.cursor = line.next;
                    return .{ .image = image };
                }
            }
            if (self.parseParagraph(line)) |elem| return elem;
        }
    }

    fn parseParagraph(self: *Blocks, first: Line) ?Element {
        const text = self.text;
        var content_start: ?usize = null;
        var content_end: usize = 0;

        const first_extra = leadingSpaces(first.content);
        const first_def = if (first_extra <= 3) parseRefDef(first.content[first_extra..]) else null;
        if (first_def) |def| {
            if (self.record) self.refs.?.record(def.label, def.destination, def.title);
        } else {
            var cs = first.start;
            while (cs < first.start + first.content.len and
                (text[cs] == ' ' or text[cs] == '\t'))
            {
                cs += 1;
            }
            content_start = cs;
            content_end = first.raw_end;
        }
        var scan = first.next;

        while (scan < self.end) {
            const line = chainLine(self.chain, text, scan, self.end, false);
            if (isBlankLine(line.content)) break;
            const extra = leadingSpaces(line.content);
            if (extra <= 3) {
                const body = line.content[extra..];
                if (parseRefDef(body)) |def| {
                    if (self.record) self.refs.?.record(def.label, def.destination, def.title);
                    scan = line.next;
                    continue;
                }
                if (self.parseStandaloneImage(body) != null) break;
                // A `-` run under a paragraph is a setext h2, not an hr.
                if (content_start != null) {
                    if (setextLevel(body)) |level| {
                        self.cursor = line.next;
                        return .{ .header = .{
                            .level = level,
                            .content = trimBlockContent(text[content_start.?..content_end]),
                            .chain = self.chain,
                            .refs = self.refs,
                        } };
                    }
                }
                if (parseAtxHeader(body) != null) break;
                if (parseFence(body) != null) break;
                if (isThematicBreak(body)) break;
                if (body.len > 0 and body[0] == '>') break;
                if (parseMarkerLine(body)) |marker| {
                    if (marker.interruptsParagraph()) break;
                }
            }
            if (content_start == null) {
                var cs = line.start;
                while (cs < line.start + line.content.len and
                    (text[cs] == ' ' or text[cs] == '\t'))
                {
                    cs += 1;
                }
                content_start = cs;
            }
            content_end = line.raw_end;
            scan = line.next;
        }

        const cs = content_start orelse {
            self.cursor = scan;
            return null;
        };
        self.cursor = scan;
        const content = trimBlockContent(text[cs..content_end]);
        if (self.parseStandaloneImage(content)) |image| return .{ .image = image };
        return .{ .paragraph = .{
            .content = content,
            .chain = self.chain,
            .refs = self.refs,
        } };
    }

    fn parseStandaloneImage(self: *Blocks, content: []const u8) ?Element.Image {
        if (content.len < 5 or content[0] != '!' or content[1] != '[') return null;
        var spans: Spans = .{ .content = content, .chain = self.chain, .refs = self.refs };
        const parsed = spans.parseLink(1) orelse return null;
        if (parsed.after != content.len) return null;
        return .{
            .alt = content[2..parsed.text_end],
            .source = parsed.destination,
            .title = parsed.title,
        };
    }

    fn parseCodeBlock(self: *Blocks, fence: Fence, first: Line) Element {
        const text = self.text;
        self.cursor = first.next;
        const content_start = self.cursor;
        var content_end = content_start;

        while (self.cursor < self.end) {
            const line = chainLine(self.chain, text, self.cursor, self.end, false);
            const indent = leadingSpaces(line.content);
            if (indent <= 3) {
                const body = line.content[indent..];
                const close_len = runLen(body, 0, fence.ch);
                if (close_len >= fence.len and isBlankLine(body[close_len..])) {
                    self.cursor = line.next;
                    return .{ .code_block = .{
                        .info = fence.info,
                        .content = text[content_start..content_end],
                        .chain = self.chain,
                    } };
                }
            }
            content_end = line.raw_end;
            self.cursor = line.next;
        }
        return .{ .code_block = .{
            .info = fence.info,
            .content = text[content_start..content_end],
            .chain = self.chain,
        } };
    }

    fn parseQuote(self: *Blocks, first: Line) Element {
        const text = self.text;
        var content_start = first.start + 1;
        if (content_start < first.raw_end and (text[content_start] == ' ' or text[content_start] == '\t')) {
            content_start += 1;
        }
        var content_end = first.raw_end;
        var last_para = paragraphish(text[content_start..content_end]);

        var pending_blank = false;
        var scan = first.next;
        while (scan < self.end) {
            const line = chainLine(self.chain, text, scan, self.end, false);
            if (isBlankLine(line.content)) {
                pending_blank = true;
                scan = line.next;
                continue;
            }
            const extra = leadingSpaces(line.content);
            if (extra <= 3) {
                const body = line.content[extra..];
                if (body.len > 0 and body[0] == '>') {
                    pending_blank = false;
                    content_end = line.raw_end;
                    var inner_start = line.start + extra + 1;
                    if (inner_start < line.raw_end and (text[inner_start] == ' ' or text[inner_start] == '\t')) {
                        inner_start += 1;
                    }
                    last_para = paragraphish(text[inner_start..content_end]);
                    scan = line.next;
                    continue;
                }
                if (!pending_blank and last_para and paragraphish(line.content)) {
                    // Lazy continuation of the quote's last paragraph.
                    content_end = line.raw_end;
                    scan = line.next;
                    continue;
                }
            }
            break;
        }

        self.cursor = scan;
        const chain = self.chain.push(.quote) orelse self.chain;
        const capped = self.chain.len < max_depth;
        return .{ .block_quote = .{ .blocks = .{
            .text = text,
            .cursor = content_start,
            .end = if (capped) content_end else content_start,
            .mid_line = true,
            .chain = chain,
            .refs = self.refs,
        } } };
    }

    fn parseList(self: *Blocks, first_marker: Marker) Element {
        const start_line = self.cursor;
        var probe: Element.List.Items = .{
            .text = self.text,
            .chain = self.chain,
            .cursor = start_line,
            .end = self.end,
            .ordered = first_marker.ordered,
            .bullet = first_marker.bullet,
            .delim = first_marker.delim,
            .refs = self.refs,
        };
        while (probe.next()) |_| {}
        // The scan stops at the first line that cannot continue the list.
        const list_end = @min(probe.cursor, self.end);

        self.cursor = list_end;
        return .{ .list = .{
            .ordered = first_marker.ordered,
            .start = first_marker.start,
            .tight = !probe.loose,
            .items = .{
                .text = self.text,
                .chain = self.chain,
                .cursor = start_line,
                .end = list_end,
                .ordered = first_marker.ordered,
                .bullet = first_marker.bullet,
                .delim = first_marker.delim,
                .refs = self.refs,
            },
        } };
    }

    fn parseTable(self: *Blocks, first: Line) ?Element {
        const text = self.text;
        const extra = leadingSpaces(first.content);
        if (extra > 3) return null;
        const header = mem.trim(u8, first.content[extra..], " \t");
        if (header.len == 0) return null;
        if (first.next >= self.end) return null;
        const second = chainLine(self.chain, text, first.next, self.end, false);
        if (isBlankLine(second.content)) return null;
        const extra2 = leadingSpaces(second.content);
        if (extra2 > 3) return null;
        const delimiter = mem.trim(u8, second.content[extra2..], " \t");
        if (delimiter.len == 0) return null;
        var aligns: [max_table_cols]Alignment = undefined;
        const ncols = parseDelimiterRow(delimiter, &aligns) orelse return null;
        var hbuf: [max_table_cols][]const u8 = undefined;
        if (splitCells(header, &hbuf) != ncols) return null;
        if (!containsTablePipe(header) and !containsTablePipe(delimiter)) return null;

        const body_start = second.next;
        var body_end = body_start;
        var scan = body_start;
        while (scan < self.end) {
            const line = chainLine(self.chain, text, scan, self.end, false);
            if (isBlankLine(line.content)) break;
            const e = leadingSpaces(line.content);
            if (e <= 3) {
                const b = line.content[e..];
                if (parseAtxHeader(b) != null) break;
                if (parseFence(b) != null) break;
                if (isThematicBreak(b)) break;
                if (b.len > 0 and b[0] == '>') break;
                if (parseMarkerLine(b) != null) break;
            }
            body_end = line.raw_end;
            scan = line.next;
        }

        self.cursor = scan;
        return .{ .table = .{
            .ncols = ncols,
            .aligns = aligns,
            .header = header,
            .body = text[body_start..body_end],
            .chain = self.chain,
            .refs = self.refs,
        } };
    }
};

/// Parses a list marker on a container-stripped line. The marker must be
/// followed by whitespace or end the line.
const Marker = struct {
    ordered: bool,
    start: u32,
    bullet: u8,
    /// `.` or `)` for ordered markers.
    delim: u8,
    len: usize,
    spaces_raw: usize,
    /// Nothing but whitespace after the marker: an empty item.
    empty: bool,

    /// Content indent: marker plus following spaces, capped so that more
    /// than four spaces count as one (the extras stay in the content).
    fn contentIndent(self: Marker) usize {
        const spaces: usize = if (self.spaces_raw == 0 or self.spaces_raw > 4) 1 else self.spaces_raw;
        return self.len + spaces;
    }

    fn sameKindAs(self: Marker, items: *const Element.List.Items) bool {
        if (self.ordered != items.ordered) return false;
        if (self.ordered) return self.delim == items.delim;
        return self.bullet == items.bullet;
    }

    /// Lists may interrupt a paragraph only when the item is non-empty;
    /// ordered lists additionally need start number 1.
    fn interruptsParagraph(self: Marker) bool {
        if (self.ordered and self.start != 1) return false;
        return !self.empty;
    }
};

fn parseMarkerLine(line: []const u8) ?Marker {
    if (line.len == 0) return null;
    var marker: Marker = .{
        .ordered = false,
        .start = 0,
        .bullet = 0,
        .delim = 0,
        .len = 0,
        .spaces_raw = 0,
        .empty = false,
    };
    const c = line[0];
    if (c == '-' or c == '+' or c == '*') {
        marker.bullet = c;
        marker.len = 1;
    } else if (ascii.isDigit(c)) {
        var digits: usize = 0;
        while (digits < 9 and digits < line.len and ascii.isDigit(line[digits])) digits += 1;
        if (digits >= line.len or (line[digits] != '.' and line[digits] != ')')) return null;
        marker.start = std.fmt.parseInt(u32, line[0..digits], 10) catch return null;
        marker.ordered = true;
        marker.delim = line[digits];
        marker.len = digits + 1;
    } else {
        return null;
    }
    if (marker.len < line.len and line[marker.len] != ' ' and line[marker.len] != '\t') return null;
    var i = marker.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
        marker.spaces_raw += 1;
        i += 1;
    }
    marker.empty = isBlankLine(line[i..]);
    return marker;
}

/// Recognizes `- [ ] `, `- [x] ` style task markers (GFM).
fn taskMarker(content: []const u8) ?struct { done: bool } {
    if (content.len < 3 or content[0] != '[' or content[2] != ']') return null;
    const done = switch (content[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };
    if (content.len > 3 and content[3] != ' ' and content[3] != '\t') return null;
    return .{ .done = done };
}

/// Splits a table row into cells on unescaped pipes outside code spans.
/// Strips one optional leading and trailing boundary pipe, trims each cell.
/// Returns the total count even when it exceeds `out.len`.
pub fn splitCells(line: []const u8, out: [][]const u8) usize {
    var s = mem.trim(u8, line, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|' and !isEscapedPipe(s, s.len - 1)) s = s[0 .. s.len - 1];
    if (s.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) {
            i += 2;
            continue;
        }
        if (s[i] == '`') {
            const run = runLen(s, i, '`');
            if (findRunExact(s, i + run, '`', run)) |close| {
                i = close + run;
                continue;
            }
            i += run;
            continue;
        }
        if (s[i] == '|') {
            if (count < out.len) out[count] = mem.trim(u8, s[start..i], " \t");
            count += 1;
            start = i + 1;
        }
        i += 1;
    }
    if (count < out.len) out[count] = mem.trim(u8, s[start..], " \t");
    return count + 1;
}

fn isEscapedPipe(s: []const u8, at: usize) bool {
    var backslashes: usize = 0;
    var i = at;
    while (i > 0 and s[i - 1] == '\\') {
        backslashes += 1;
        i -= 1;
    }
    return backslashes % 2 == 1;
}

fn parseDelimiterRow(line: []const u8, aligns: *[max_table_cols]Alignment) ?usize {
    var cells: [max_table_cols][]const u8 = undefined;
    const n = splitCells(line, &cells);
    if (n == 0 or n > max_table_cols) return null;
    for (cells[0..n], 0..) |cell, i| {
        var inner = cell;
        var left = false;
        var right = false;
        if (inner.len > 0 and inner[0] == ':') {
            left = true;
            inner = inner[1..];
        }
        if (inner.len > 0 and inner[inner.len - 1] == ':') {
            right = true;
            inner = inner[0 .. inner.len - 1];
        }
        if (inner.len == 0) return null;
        for (inner) |c| if (c != '-') return null;
        aligns[i] = if (left and right) .center else if (right) .right else .left;
    }
    return n;
}

fn containsTablePipe(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\\' and i + 1 < line.len and isAsciiPunct(line[i + 1])) {
            i += 2;
            continue;
        }
        if (line[i] == '`') {
            const run = runLen(line, i, '`');
            if (findRunExact(line, i + run, '`', run)) |close| {
                i = close + run;
                continue;
            }
            i += run;
            continue;
        }
        if (line[i] == '|') return true;
        i += 1;
    }
    return false;
}

/// Maximum reference definitions kept; further ones stay literal text.
pub const max_refs = 64;

/// Link reference definitions (`[label]: destination "title"`), collected
/// by one probe parse over the document and consulted for `[text][label]`,
/// `[text][]` and `[text]` links. All slices point into `Document.text`.
pub const RefTable = struct {
    pub const Def = struct {
        label: []const u8,
        destination: []const u8,
        title: ?[]const u8,
    };

    defs: [max_refs]Def = undefined,
    count: usize = 0,
    scanned: bool = false,
    text: []const u8 = "",

    pub fn lookup(self: *const RefTable, label: []const u8) ?Def {
        for (self.defs[0..self.count]) |def| {
            if (labelsEqual(def.label, label)) return def;
        }
        return null;
    }

    /// First definition wins; blank or overlong labels never record.
    pub fn record(self: *RefTable, label: []const u8, destination: []const u8, title: ?[]const u8) void {
        if (label.len == 0 or label.len > 999 or isBlankLabel(label)) return;
        for (self.defs[0..self.count]) |def| {
            if (labelsEqual(def.label, label)) return;
        }
        if (self.count >= max_refs) return;
        self.defs[self.count] = .{ .label = label, .destination = destination, .title = title };
        self.count += 1;
    }

    pub fn ensureScanned(self: *RefTable) void {
        if (self.scanned) return;
        self.scanned = true;
        var probe: Blocks = .{ .text = self.text, .cursor = 0, .end = self.text.len, .refs = self, .record = true };
        while (probe.next()) |_| {}
    }
};

fn isBlankLabel(label: []const u8) bool {
    for (label) |c| if (!isRefSpace(c)) return false;
    return true;
}

fn isRefSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skipRefSpace(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and isRefSpace(s[j])) j += 1;
    return j;
}

/// Labels match case-insensitively with internal whitespace collapsed.
fn labelsEqual(a: []const u8, b: []const u8) bool {
    var i = skipRefSpace(a, 0);
    var j = skipRefSpace(b, 0);
    while (i < a.len and j < b.len) {
        if (isRefSpace(a[i]) or isRefSpace(b[j])) {
            if (!isRefSpace(a[i]) or !isRefSpace(b[j])) return false;
            i = skipRefSpace(a, i);
            j = skipRefSpace(b, j);
            if (i >= a.len or j >= b.len) return i >= a.len and j >= b.len;
        } else {
            if (asciiToLower(a[i]) != asciiToLower(b[j])) return false;
            i += 1;
            j += 1;
        }
    }
    i = skipRefSpace(a, i);
    j = skipRefSpace(b, j);
    return i >= a.len and j >= b.len;
}

fn asciiToLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

const ParsedRefDef = struct {
    label: []const u8,
    destination: []const u8,
    title: ?[]const u8,
};

/// Parses a single-line `[label]: destination "title"` definition without
/// leading indent; null when the line is not one. Titles must close on the
/// same line.
fn parseRefDef(line: []const u8) ?ParsedRefDef {
    if (line.len == 0 or line[0] != '[') return null;
    var i: usize = 1;
    var depth: usize = 1;
    while (i < line.len) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 2;
            continue;
        }
        if (line[i] == '[') depth += 1 else if (line[i] == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
        i += 1;
    }
    if (i >= line.len or line[i] != ']') return null;
    const label = line[1..i];
    if (isBlankLabel(label)) return null;
    i += 1;
    if (i >= line.len or line[i] != ':') return null;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    var destination: []const u8 = "";
    if (i < line.len and line[i] == '<') {
        const start = i + 1;
        i = start;
        while (i < line.len and line[i] != '>') {
            if (line[i] == ' ' or line[i] == '\t') return null;
            i += 1;
        }
        if (i >= line.len) return null;
        destination = line[start..i];
        if (destination.len == 0) return null;
        i += 1;
    } else {
        const start = i;
        var parens: usize = 0;
        while (i < line.len) {
            const ch = line[i];
            if (ch == '\\' and i + 1 < line.len and isAsciiPunct(line[i + 1])) {
                i += 2;
                continue;
            }
            if (ch == '(') {
                parens += 1;
            } else if (ch == ')') {
                if (parens == 0) break;
                parens -= 1;
            } else if (ch == ' ' or ch == '\t') {
                break;
            }
            i += 1;
        }
        destination = line[start..i];
        if (destination.len == 0) return null;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    var title: ?[]const u8 = null;
    if (i < line.len) {
        const q = line[i];
        if (q != '"' and q != '\'' and q != '(') return null;
        const close: u8 = if (q == '(') ')' else q;
        i += 1;
        const start = i;
        while (i < line.len and line[i] != close) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 2;
                continue;
            }
            i += 1;
        }
        if (i >= line.len) return null;
        title = line[start..i];
        i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i < line.len) return null;
    }
    return .{ .label = label, .destination = destination, .title = title };
}

/// An inline formatting event. Emphasis, strikethrough and links are
/// open/close pairs; consumers track a style stack. Text spans never
/// contain newlines: line breaks are `soft_break` / `hard_break` events.
pub const Span = union(enum) {
    text: []const u8,
    code: []const u8,
    /// Raw entity such as `&amp;`; decode with `decodeEntity`.
    entity: []const u8,
    /// Backslash escape resolved to this character.
    escape: []const u8,
    hard_break,
    soft_break,
    em_open,
    em_close,
    strong_open,
    strong_close,
    strike_open,
    strike_close,
    link: Link,
    link_close,

    pub const Link = struct {
        destination: []const u8,
        title: ?[]const u8,
    };
};

/// Inline span iterator. Resolution follows the CommonMark emphasis
/// algorithm (delimiter runs with flanking rules and the rule of 3), GFM
/// strikethrough (one or two tildes, equal counts), and inline links.
/// Bounded fixed tables; content past the caps degrades to literal text.
pub const Spans = struct {
    const max_events = 256;
    const max_delims = 64;

    content: []const u8,
    chain: Chain = .{},
    refs: ?*RefTable = null,
    pos: usize = 0,
    events: [max_events]Event = undefined,
    event_count: usize = 0,
    degraded: bool = false,
    event_i: usize = 0,
    link_count: usize = 0,
    delims: [max_delims]Delim = undefined,
    delim_count: usize = 0,

    pub fn init(content: []const u8) Spans {
        return initChain(content, .{});
    }

    pub fn initChain(content: []const u8, chain: Chain) Spans {
        return initChainRefs(content, chain, null);
    }

    pub fn initChainRefs(content: []const u8, chain: Chain, refs: ?*RefTable) Spans {
        if (refs) |t| t.ensureScanned();
        var self: Spans = .{ .content = content, .chain = chain, .refs = refs };
        self.resolve();
        return self;
    }

    pub fn next(self: *Spans) ?Span {
        if (self.degraded) {
            if (self.event_i > 0) return null;
            self.event_i = 1;
            self.pos = self.content.len;
            return .{ .text = self.content };
        }
        while (true) {
            if (self.event_i >= self.event_count) {
                if (self.pos >= self.content.len) return null;
                const text = self.content[self.pos..];
                self.pos = self.content.len;
                return .{ .text = text };
            }
            const event = self.events[self.event_i];
            if (event.pos > self.pos) {
                const text = self.content[self.pos..event.pos];
                self.pos = event.pos;
                return .{ .text = text };
            }
            self.event_i += 1;
            self.pos = event.pos + event.skip;
            switch (event.kind) {
                .code => return .{ .code = event.slice },
                .entity => return .{ .entity = event.slice },
                .escape => return .{ .escape = event.slice },
                .hard_break => return .hard_break,
                .soft_break => return .soft_break,
                .em_open => return .em_open,
                .em_close => return .em_close,
                .strong_open => return .strong_open,
                .strong_close => return .strong_close,
                .strike_open => return .strike_open,
                .strike_close => return .strike_close,
                .link_open => return .{ .link = .{ .destination = event.slice, .title = event.extra } },
                .link_close => return .link_close,
            }
        }
    }

    const EventKind = enum {
        code,
        entity,
        escape,
        hard_break,
        soft_break,
        em_open,
        em_close,
        strong_open,
        strong_close,
        strike_open,
        strike_close,
        link_open,
        link_close,
    };

    const Event = struct {
        pos: usize,
        skip: usize,
        kind: EventKind,
        slice: []const u8 = "",
        extra: ?[]const u8 = null,
    };

    const Delim = struct {
        pos: usize,
        run_len: usize,
        count: usize,
        ch: u8,
        can_open: bool,
        can_close: bool,
        region: usize,
        open_use: usize = 0,
        close_use: usize = 0,
    };

    fn addEvent(self: *Spans, event: Event) void {
        if (self.degraded) return;
        if (self.event_count >= max_events) {
            self.degraded = true;
            self.event_count = 0;
            return;
        }
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    fn resolve(self: *Spans) void {
        self.scan();
        if (self.degraded) return;
        self.resolveEmphasis();
        self.sortEvents();
    }

    fn scan(self: *Spans) void {
        const c = self.content;
        var i: usize = 0;
        var region: usize = outside_region;
        // Currently open link, so that brackets inside link text stay literal.
        var link_text_end: usize = 0;
        var link_after: usize = 0;

        while (i < c.len) {
            if (link_after > 0 and i > link_text_end) {
                // Leaving the link text: its destination was consumed by the
                // link_close event's skip.
                region = outside_region;
                link_after = 0;
            }
            switch (c[i]) {
                '\\' => {
                    if (i + 1 < c.len and c[i + 1] == '\n') {
                        const next_start = self.lineBreakSkip(i + 2);
                        self.addEvent(.{ .pos = i, .skip = next_start - i, .kind = .hard_break });
                        i = next_start;
                        continue;
                    }
                    if (i + 1 < c.len and isAsciiPunct(c[i + 1])) {
                        self.addEvent(.{ .pos = i, .skip = 2, .kind = .escape, .slice = c[i + 1 .. i + 2] });
                        i += 2;
                        continue;
                    }
                    i += 1;
                },
                '`' => {
                    const open_len = runLen(c, i, '`');
                    if (findRunExact(c, i + open_len, '`', open_len)) |close_start| {
                        var inner = c[i + open_len .. close_start];
                        if (inner.len >= 2 and inner[0] == ' ' and inner[inner.len - 1] == ' ') {
                            inner = inner[1 .. inner.len - 1];
                        }
                        self.addEvent(.{
                            .pos = i,
                            .skip = close_start + open_len - i,
                            .kind = .code,
                            .slice = inner,
                        });
                        i = close_start + open_len;
                        continue;
                    }
                    i += open_len;
                },
                '&' => {
                    if (validEntity(c[i..])) |len| {
                        self.addEvent(.{ .pos = i, .skip = len, .kind = .entity, .slice = c[i .. i + len] });
                        i += len;
                        continue;
                    }
                    i += 1;
                },
                '\n' => {
                    var back = i;
                    if (back > 0 and c[back - 1] == '\r') back -= 1;
                    var spaces: usize = 0;
                    while (back > 0 and c[back - 1] == ' ') {
                        spaces += 1;
                        back -= 1;
                    }
                    const next_start = self.lineBreakSkip(i + 1);
                    if (spaces >= 2) {
                        self.addEvent(.{ .pos = back, .skip = next_start - back, .kind = .hard_break });
                    } else {
                        self.addEvent(.{ .pos = i, .skip = next_start - i, .kind = .soft_break });
                    }
                    i = next_start;
                    continue;
                },
                '*', '_', '~' => {
                    const ch = c[i];
                    const run = runLen(c, i, ch);
                    if (ch == '~' and run > 2) {
                        i += run;
                        continue;
                    }
                    if (self.delim_count < max_delims) {
                        self.delims[self.delim_count] = .{
                            .pos = i,
                            .run_len = run,
                            .count = run,
                            .ch = ch,
                            .can_open = canOpenEmphasis(c, i, run, ch),
                            .can_close = canCloseEmphasis(c, i, run, ch),
                            .region = region,
                        };
                        self.delim_count += 1;
                    }
                    i += run;
                },
                '[' => {
                    if (region != outside_region) {
                        // No nested links.
                        i += 1;
                        continue;
                    }
                    if (self.parseLink(i) orelse self.parseRefLink(i)) |parsed| {
                        self.addEvent(.{ .pos = i, .skip = 1, .kind = .link_open, .slice = parsed.destination, .extra = parsed.title });
                        self.addEvent(.{
                            .pos = parsed.text_end,
                            .skip = parsed.after - parsed.text_end,
                            .kind = .link_close,
                        });
                        region = self.link_count;
                        self.link_count += 1;
                        link_text_end = parsed.text_end;
                        link_after = parsed.after;
                        i += 1;
                        continue;
                    }
                    i += 1;
                },
                ']' => {
                    if (link_after > 0 and i == link_text_end) {
                        i = link_after;
                        continue;
                    }
                    i += 1;
                },
                '<' => {
                    if (region != outside_region) {
                        // No nested links.
                        i += 1;
                        continue;
                    }
                    if (self.parseAutolink(i)) |parsed| {
                        self.addEvent(.{ .pos = i, .skip = 1, .kind = .link_open, .slice = parsed.destination, .extra = parsed.title });
                        self.addEvent(.{
                            .pos = parsed.text_end,
                            .skip = parsed.after - parsed.text_end,
                            .kind = .link_close,
                        });
                        region = self.link_count;
                        self.link_count += 1;
                        link_text_end = parsed.text_end;
                        link_after = parsed.after;
                        // The interior stays literal: no inline parsing inside.
                        i = parsed.after;
                        continue;
                    }
                    i += 1;
                },
                '!' => {
                    // Inline images stay literal; standalone images are blocks.
                    i += if (i + 1 < c.len and c[i + 1] == '[') 2 else 1;
                },
                else => i += 1,
            }
        }
    }

    /// Returns the absolute content position where the line after the
    /// newline at `from - 1` begins, skipping the container prefixes.
    fn lineBreakSkip(self: *Spans, from: usize) usize {
        const c = self.content;
        if (from >= c.len) return c.len;
        const line_end = mem.indexOfScalarPos(u8, c, from, '\n') orelse c.len;
        const raw = c[from..line_end];
        const skip = chainSkip(self.chain, raw) orelse chainSpacesOnly(self.chain, raw);
        return from + skip;
    }

    const ParsedLink = struct {
        destination: []const u8,
        title: ?[]const u8,
        text_end: usize,
        after: usize,
    };

    /// Index of the `]` closing the link text at `open`, honoring escapes,
    /// code spans and nested brackets; null when unclosed.
    fn findLinkTextEnd(c: []const u8, open: usize) ?usize {
        var i = open + 1;
        var depth: usize = 1;
        while (i < c.len) {
            switch (c[i]) {
                '\\' => i += @min(@as(usize, 2), c.len - i),
                '`' => {
                    const run = runLen(c, i, '`');
                    if (findRunExact(c, i + run, '`', run)) |close| {
                        i = close + run;
                    } else {
                        i += run;
                    }
                },
                '[' => {
                    depth += 1;
                    i += 1;
                },
                ']' => {
                    depth -= 1;
                    if (depth == 0) return i;
                    i += 1;
                },
                else => i += 1,
            }
        }
        return null;
    }

    /// True when the `[` at `open` continues an image alt group
    /// (`![alt][...]`), whose labels stay literal because reference images
    /// are not supported. Inline links after an image still resolve separately.
    fn followsImageAlt(c: []const u8, open: usize) bool {
        if (open < 2 or c[open - 1] != ']') return false;
        var depth: usize = 1;
        var i = open - 1;
        var backslashes: usize = 0;
        while (i > 0) {
            i -= 1;
            const ch = c[i];
            if (ch == '\\') {
                backslashes += 1;
                continue;
            }
            const escaped = backslashes % 2 == 1;
            backslashes = 0;
            if (!escaped and ch == ']') {
                depth += 1;
            } else if (!escaped and ch == '[') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (depth != 0 or i == 0) return false;
        return c[i - 1] == '!' and !isEscapedPipe(c, i - 1);
    }

    /// Parses `[text][label]`, `[text][]` and `[text]` starting at the `[`;
    /// an empty `[]` label means the text itself. Falls back to the shortcut
    /// form when a full label is undefined. Null without definitions.
    fn parseRefLink(self: *Spans, open: usize) ?ParsedLink {
        const refs = self.refs orelse return null;
        const c = self.content;
        // Reference and inline image markers stay fully literal.
        if (open > 0 and c[open - 1] == '!' and !isEscapedPipe(c, open - 1)) return null;
        if (followsImageAlt(c, open)) return null;
        const text_end = findLinkTextEnd(c, open) orelse return null;
        if (text_end + 1 < c.len and c[text_end + 1] == '[') {
            if (findLinkTextEnd(c, text_end + 1)) |label_end| {
                const raw = c[text_end + 2 .. label_end];
                const effective = if (raw.len == 0) c[open + 1 .. text_end] else raw;
                if (refs.lookup(effective)) |def| {
                    return .{ .destination = def.destination, .title = def.title, .text_end = text_end, .after = label_end + 1 };
                }
            }
        }
        return self.shortcutRef(open, text_end);
    }

    fn shortcutRef(self: *Spans, open: usize, text_end: usize) ?ParsedLink {
        const refs = self.refs orelse return null;
        if (text_end == open + 1) return null;
        if (refs.lookup(self.content[open + 1 .. text_end])) |def| {
            return .{ .destination = def.destination, .title = def.title, .text_end = text_end, .after = text_end + 1 };
        }
        return null;
    }

    /// Parses `<scheme:...>` and `<email>` starting at the `<`; the link
    /// text is the raw interior. Email destinations stay raw (`mailto:` is
    /// a render concern). Null for anything else, including HTML.
    fn parseAutolink(self: *Spans, open: usize) ?ParsedLink {
        const c = self.content;
        var i = open + 1;
        while (i < c.len and c[i] != '>') {
            if (c[i] == ' ' or c[i] == '\t' or c[i] == '\n' or c[i] == '\r' or c[i] == '<' or c[i] < 0x20) return null;
            i += 1;
        }
        if (i >= c.len) return null;
        const inner = c[open + 1 .. i];
        if (!isUriAutolink(inner) and !isEmailAutolink(inner)) return null;
        return .{ .destination = inner, .title = null, .text_end = i, .after = i + 1 };
    }

    /// A 2-32 character scheme, then a colon; the rest was validated above.
    fn isUriAutolink(inner: []const u8) bool {
        if (inner.len == 0 or !ascii.isAlphabetic(inner[0])) return false;
        var i: usize = 1;
        while (i < inner.len and i < 32 and
            (ascii.isAlphanumeric(inner[i]) or inner[i] == '+' or inner[i] == '-' or inner[i] == '.'))
        {
            i += 1;
        }
        if (i < 2 or i > 32) return false;
        return i < inner.len and inner[i] == ':';
    }

    fn isEmailAutolink(inner: []const u8) bool {
        var i: usize = 0;
        const local_start = i;
        while (i < inner.len and isEmailLocal(inner[i])) i += 1;
        if (i == local_start or i >= inner.len or inner[i] != '@') return false;
        i += 1;
        if (!parseEmailLabel(inner, &i)) return false;
        while (i < inner.len and inner[i] == '.') {
            i += 1;
            if (!parseEmailLabel(inner, &i)) return false;
        }
        return i >= inner.len;
    }

    /// One dot-separated domain label: alphanumerics and hyphens, starting
    /// and ending alphanumeric, at most 63 characters.
    fn parseEmailLabel(inner: []const u8, i: *usize) bool {
        if (i.* >= inner.len or !ascii.isAlphanumeric(inner[i.*])) return false;
        const start = i.*;
        i.* += 1;
        while (i.* < inner.len and i.* - start < 63 and
            (ascii.isAlphanumeric(inner[i.*]) or inner[i.*] == '-'))
        {
            i.* += 1;
        }
        if (i.* < inner.len and (ascii.isAlphanumeric(inner[i.*]) or inner[i.*] == '-')) return false;
        return inner[i.* - 1] != '-';
    }

    fn isEmailLocal(c: u8) bool {
        if (ascii.isAlphanumeric(c)) return true;
        return switch (c) {
            '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
            else => false,
        };
    }

    /// Parses `[text](dest "title")` starting at the `[`; null when the
    /// syntax does not form a link.
    fn parseLink(self: *Spans, open: usize) ?ParsedLink {
        const c = self.content;
        const text_end = findLinkTextEnd(c, open) orelse return null;
        const i = text_end;
        if (i + 1 >= c.len or c[i + 1] != '(') return null;

        var j = i + 2;
        while (j < c.len and (c[j] == ' ' or c[j] == '\t')) j += 1;
        var destination: []const u8 = "";
        if (j < c.len and c[j] == '<') {
            const start = j + 1;
            j = start;
            while (j < c.len and c[j] != '>' and c[j] != '\n') j += 1;
            if (j >= c.len or c[j] != '>') return null;
            destination = c[start..j];
            j += 1;
        } else {
            const start = j;
            var parens: usize = 0;
            while (j < c.len) {
                const ch = c[j];
                if (ch == '\\' and j + 1 < c.len and isAsciiPunct(c[j + 1])) {
                    j += 2;
                    continue;
                }
                if (ch == '(') {
                    parens += 1;
                } else if (ch == ')') {
                    if (parens == 0) break;
                    parens -= 1;
                } else if (ch == ' ' or ch == '\n') {
                    break;
                }
                j += 1;
            }
            if (j >= c.len or c[j] == '\n') return null;
            destination = c[start..j];
        }
        while (j < c.len and (c[j] == ' ' or c[j] == '\t')) j += 1;

        var title: ?[]const u8 = null;
        if (j < c.len and (c[j] == '"' or c[j] == '\'' or c[j] == '(')) {
            const close: u8 = if (c[j] == '(') ')' else c[j];
            const start = j + 1;
            j = start;
            while (j < c.len and c[j] != close and c[j] != '\n') {
                if (c[j] == '\\' and j + 1 < c.len) j += 1;
                j += 1;
            }
            if (j >= c.len or c[j] != close) return null;
            title = c[start..j];
            j += 1;
            while (j < c.len and (c[j] == ' ' or c[j] == '\t')) j += 1;
        }
        if (j >= c.len or c[j] != ')') return null;
        return .{
            .destination = destination,
            .title = title,
            .text_end = text_end,
            .after = j + 1,
        };
    }

    fn resolveEmphasis(self: *Spans) void {
        const delims = self.delims[0..self.delim_count];
        for (delims, 0..) |*closer, ci| {
            if (!closer.can_close or closer.count == 0) continue;
            var oi = ci;
            while (oi > 0) {
                oi -= 1;
                const opener = &delims[oi];
                if (opener.count == 0 or !opener.can_open) continue;
                if (opener.ch != closer.ch) continue;
                if (opener.region != closer.region) continue;
                if (closer.ch == '~') {
                    // GFM strikethrough: equal counts, no rule of 3.
                    if (opener.count != closer.count) continue;
                } else if ((opener.can_close or closer.can_open) and
                    (opener.count + closer.count) % 3 == 0 and
                    !(opener.count % 3 == 0 and closer.count % 3 == 0))
                {
                    continue;
                }
                const use = if (closer.ch == '~') closer.count else @min(@min(opener.count, closer.count), 2);
                self.addEvent(.{
                    .pos = opener.pos + opener.run_len - opener.open_use - use,
                    .skip = use,
                    .kind = openKind(closer.ch, use),
                });
                opener.open_use += use;
                opener.count -= use;
                self.addEvent(.{
                    .pos = closer.pos + closer.close_use,
                    .skip = use,
                    .kind = closeKind(closer.ch, use),
                });
                closer.close_use += use;
                closer.count -= use;
                if (closer.count == 0) break;
                // Runs longer than two can pair several times; retry the
                // same opener for the remaining closer count.
                if (opener.count > 0) oi += 1;
            }
        }
    }

    /// Events are appended nearly in position order; insertion sort keeps
    /// them ordered for the emit walk.
    fn sortEvents(self: *Spans) void {
        var i: usize = 1;
        while (i < self.event_count) : (i += 1) {
            const event = self.events[i];
            var j = i;
            while (j > 0 and self.events[j - 1].pos > event.pos) : (j -= 1) {
                self.events[j] = self.events[j - 1];
            }
            self.events[j] = event;
        }
    }
};

fn openKind(ch: u8, use: usize) Spans.EventKind {
    if (ch == '~') return .strike_open;
    return if (use >= 2) .strong_open else .em_open;
}

fn closeKind(ch: u8, use: usize) Spans.EventKind {
    if (ch == '~') return .strike_close;
    return if (use >= 2) .strong_close else .em_close;
}

pub const LineIterator = struct {
    remaining: []const u8,
    chain: Chain = .{},
    first: bool = true,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.remaining.len == 0) return null;
        const end = mem.indexOfScalar(u8, self.remaining, '\n') orelse self.remaining.len;
        var line = self.remaining[0..end];
        self.remaining = self.remaining[@min(end + 1, self.remaining.len)..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (self.first) {
            self.first = false;
            return line;
        }
        if (self.chain.len == 0) return line;
        const skip = chainSkip(self.chain, line) orelse chainSpacesOnly(self.chain, line);
        return line[skip..];
    }
};

const max_depth = 8;

pub const Step = union(enum) {
    /// Skip this many leading spaces (list item content indent).
    spaces: usize,
    /// Skip up to three spaces, a `>` marker and one optional space.
    quote,
};

/// Ordered container prefixes stripped from every line: quote markers and
/// item indents, outermost first. Lists, items and block quotes carry their
/// chain so their content can be re-parsed lazily.
pub const Chain = struct {
    steps: [max_depth]Step = undefined,
    len: usize = 0,

    fn push(self: Chain, step: Step) ?Chain {
        if (self.len >= max_depth) return null;
        var out = self;
        out.steps[self.len] = step;
        out.len += 1;
        return out;
    }
};

const outside_region = std.math.maxInt(usize);

/// Bytes of `line` consumed by the container prefixes; null when a quote
/// marker is missing (lazy continuation).
fn chainSkip(chain: Chain, line: []const u8) ?usize {
    var i: usize = 0;
    for (chain.steps[0..chain.len]) |step| {
        switch (step) {
            .spaces => |n| {
                var k: usize = 0;
                while (k < n and i < line.len and line[i] == ' ') k += 1;
                i += k;
            },
            .quote => {
                var k: usize = 0;
                while (k < 3 and i < line.len and line[i] == ' ') k += 1;
                if (i + k >= line.len or line[i + k] != '>') return null;
                i += k + 1;
                if (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
            },
        }
    }
    return i;
}

/// Prefix fallback for lazy continuation lines: strip only space steps.
fn chainSpacesOnly(chain: Chain, line: []const u8) usize {
    var i: usize = 0;
    for (chain.steps[0..chain.len]) |step| {
        switch (step) {
            .spaces => |n| {
                var k: usize = 0;
                while (k < n and i < line.len and line[i] == ' ') k += 1;
                i += k;
            },
            .quote => {},
        }
    }
    return i;
}

const Line = struct {
    /// Absolute position of the content start (prefixes stripped).
    start: usize,
    /// Content bytes with container prefixes removed and CR trimmed.
    content: []const u8,
    /// Absolute end of the raw line, before the newline.
    raw_end: usize,
    /// Absolute position after the newline.
    next: usize,
};

fn chainLine(chain: Chain, text: []const u8, pos: usize, end: usize, mid_line: bool) Line {
    var line_end = mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
    if (line_end > end) line_end = end;
    var raw_end = line_end;
    if (raw_end > pos and text[raw_end - 1] == '\r') raw_end -= 1;
    const next_pos = if (line_end < end and line_end < text.len and text[line_end] == '\n') line_end + 1 else line_end;
    var skip: usize = 0;
    if (!mid_line) {
        const raw = text[pos..raw_end];
        skip = chainSkip(chain, raw) orelse chainSpacesOnly(chain, raw);
    }
    return .{
        .start = pos + skip,
        .content = text[pos + skip .. raw_end],
        .raw_end = raw_end,
        .next = next_pos,
    };
}

const Fence = struct {
    ch: u8,
    len: usize,
    info: ?[]const u8,
};

fn parseAtxHeader(body: []const u8) ?Element.Header {
    const level = runLen(body, 0, '#');
    if (level == 0 or level > 6) return null;
    if (level < body.len and body[level] != ' ' and body[level] != '\t') return null;
    var content = mem.trim(u8, body[level..], " \t");
    content = stripClosingHashes(content);
    return .{ .level = @intCast(level), .content = content };
}

/// Strips a CommonMark closing sequence: trailing `#`s preceded by whitespace
/// or making up the whole content.
fn stripClosingHashes(content: []const u8) []const u8 {
    var end = content.len;
    while (end > 0 and content[end - 1] == '#') end -= 1;
    if (end == content.len) return content;
    if (end == 0 or content[end - 1] == ' ' or content[end - 1] == '\t') {
        return mem.trimEnd(u8, content[0..end], " \t");
    }
    return content;
}

fn parseFence(body: []const u8) ?Fence {
    if (body.len < 3) return null;
    const ch = body[0];
    if (ch != '`' and ch != '~') return null;
    const len = runLen(body, 0, ch);
    if (len < 3) return null;
    const info_raw = mem.trim(u8, body[len..], " \t");
    // CommonMark: the info string may not contain the fence character.
    if (mem.indexOfScalar(u8, info_raw, ch) != null) return null;
    return .{ .ch = ch, .len = len, .info = if (info_raw.len == 0) null else info_raw };
}

fn isThematicBreak(body: []const u8) bool {
    if (body.len < 3) return false;
    const ch = body[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var count: usize = 0;
    for (body) |c| {
        if (c == ch) {
            count += 1;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return count >= 3;
}

fn setextLevel(body: []const u8) ?u8 {
    const t = mem.trim(u8, body, " \t");
    if (t.len == 0) return null;
    const ch = t[0];
    if (ch != '=' and ch != '-') return null;
    for (t) |c| if (c != ch) return null;
    return if (ch == '=') 1 else 2;
}

/// Simplified CommonMark flank rules; content start/end count as whitespace.
/// `*` (and GFM `~`) open when left-flanking and close when right-flanking;
/// `_` additionally refuses intraword positions.
fn canOpenEmphasis(c: []const u8, marker_pos: usize, run: usize, marker: u8) bool {
    const after = marker_pos + run;
    if (after >= c.len) return false;
    const next_char = c[after];
    if (isInlineWhitespace(next_char)) return false;
    const prev: ?u8 = if (marker_pos == 0) null else c[marker_pos - 1];
    if (isInlinePunct(next_char)) {
        const p = prev orelse return true;
        if (!isInlineWhitespace(p) and !isInlinePunct(p)) return false;
    }
    switch (marker) {
        '*', '~' => return true,
        '_' => {
            const p = prev orelse return true;
            return !ascii.isAlphanumeric(p);
        },
        else => unreachable,
    }
}

fn canCloseEmphasis(c: []const u8, close_pos: usize, run: usize, marker: u8) bool {
    if (close_pos == 0) return false;
    const prev = c[close_pos - 1];
    if (isInlineWhitespace(prev)) return false;
    const after = close_pos + run;
    const next_char: ?u8 = if (after >= c.len) null else c[after];
    if (isInlinePunct(prev)) {
        const n = next_char orelse return true;
        if (!isInlineWhitespace(n) and !isInlinePunct(n)) return false;
    }
    switch (marker) {
        '*', '~' => return true,
        '_' => {
            const n = next_char orelse return true;
            return !ascii.isAlphanumeric(n);
        },
        else => unreachable,
    }
}

fn isInlineWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isInlinePunct(c: u8) bool {
    return !ascii.isAlphanumeric(c) and !isInlineWhitespace(c);
}

/// Whether the line could continue a paragraph: no block start on it.
fn paragraphish(line: []const u8) bool {
    if (isBlankLine(line)) return false;
    const extra = leadingSpaces(line);
    if (extra > 3) return true;
    const body = line[extra..];
    if (body.len == 0) return false;
    if (parseAtxHeader(body) != null) return false;
    if (parseFence(body) != null) return false;
    if (isThematicBreak(body)) return false;
    if (body[0] == '>') return false;
    if (parseMarkerLine(body) != null) return false;
    if (setextLevel(body) != null) return false;
    return true;
}

fn runLen(s: []const u8, start: usize, ch: u8) usize {
    var i = start;
    while (i < s.len and s[i] == ch) i += 1;
    return i - start;
}

fn findRunExact(s: []const u8, from: usize, ch: u8, n: usize) ?usize {
    var i = from;
    while (i < s.len) {
        if (s[i] == ch) {
            const len = runLen(s, i, ch);
            if (len == n) return i;
            i += len;
        } else {
            i += 1;
        }
    }
    return null;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn trimBlockContent(content: []const u8) []const u8 {
    return mem.trimEnd(u8, content, " \t\r");
}

fn leadingSpaces(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    return i;
}

fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

const Entity = struct { name: []const u8, cp: u21 };

const named_entities = [_]Entity{
    .{ .name = "amp", .cp = 0x26 },
    .{ .name = "lt", .cp = 0x3C },
    .{ .name = "gt", .cp = 0x3E },
    .{ .name = "quot", .cp = 0x22 },
    .{ .name = "apos", .cp = 0x27 },
    .{ .name = "nbsp", .cp = 0xA0 },
    .{ .name = "copy", .cp = 0xA9 },
    .{ .name = "reg", .cp = 0xAE },
    .{ .name = "deg", .cp = 0xB0 },
    .{ .name = "plusmn", .cp = 0xB1 },
    .{ .name = "para", .cp = 0xB6 },
    .{ .name = "middot", .cp = 0xB7 },
    .{ .name = "laquo", .cp = 0xAB },
    .{ .name = "raquo", .cp = 0xBB },
    .{ .name = "times", .cp = 0xD7 },
    .{ .name = "divide", .cp = 0xF7 },
    .{ .name = "euro", .cp = 0x20AC },
    .{ .name = "pound", .cp = 0xA3 },
    .{ .name = "yen", .cp = 0xA5 },
    .{ .name = "cent", .cp = 0xA2 },
    .{ .name = "ndash", .cp = 0x2013 },
    .{ .name = "mdash", .cp = 0x2014 },
    .{ .name = "lsquo", .cp = 0x2018 },
    .{ .name = "rsquo", .cp = 0x2019 },
    .{ .name = "ldquo", .cp = 0x201C },
    .{ .name = "rdquo", .cp = 0x201D },
    .{ .name = "hellip", .cp = 0x2026 },
    .{ .name = "bull", .cp = 0x2022 },
    .{ .name = "dagger", .cp = 0x2020 },
    .{ .name = "trade", .cp = 0x2122 },
    .{ .name = "check", .cp = 0x2713 },
};

/// Validates an entity at the start of `raw` (beginning with `&`) and
/// returns its length. Named entities must be known; numeric ones must be
/// valid unicode scalars.
fn validEntity(raw: []const u8) ?usize {
    if (raw.len < 3 or raw[0] != '&') return null;
    if (raw[1] == '#') {
        var i: usize = 2;
        var value: u32 = 0;
        if (i < raw.len and (raw[i] == 'x' or raw[i] == 'X')) {
            i += 1;
            const digits_start = i;
            while (i < raw.len and i - digits_start < 6 and ascii.isHex(raw[i])) {
                value = value * 16 + hexValue(raw[i]);
                i += 1;
            }
            if (i == digits_start) return null;
        } else {
            const digits_start = i;
            while (i < raw.len and i - digits_start < 7 and ascii.isDigit(raw[i])) {
                value = value * 10 + (raw[i] - '0');
                i += 1;
            }
            if (i == digits_start) return null;
        }
        if (i >= raw.len or raw[i] != ';') return null;
        if (value == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) return null;
        return i + 1;
    }
    if (!ascii.isAlphabetic(raw[1])) return null;
    var i: usize = 1;
    while (i < raw.len and i <= 32 and ascii.isAlphanumeric(raw[i])) i += 1;
    if (i >= raw.len or raw[i] != ';') return null;
    const name = raw[1..i];
    for (named_entities) |entity| {
        if (mem.eql(u8, entity.name, name)) return i + 1;
    }
    return null;
}

fn hexValue(c: u8) u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// Decodes an entity produced by the parser into `buf` (4 bytes for a
/// unicode scalar); null for unknown entities.
pub fn decodeEntity(raw: []const u8, buf: *[4]u8) ?[]const u8 {
    if (raw.len < 3 or raw[0] != '&') return null;
    var cp: u21 = 0;
    if (raw[1] == '#') {
        var value: u32 = 0;
        if (raw[2] == 'x' or raw[2] == 'X') {
            for (raw[3 .. raw.len - 1]) |c| value = value * 16 + hexValue(c);
        } else {
            for (raw[2 .. raw.len - 1]) |c| value = value * 10 + (c - '0');
        }
        if (value == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) return null;
        cp = @intCast(value);
    } else {
        const name = raw[1 .. raw.len - 1];
        var found = false;
        for (named_entities) |entity| {
            if (mem.eql(u8, entity.name, name)) {
                cp = entity.cp;
                found = true;
                break;
            }
        }
        if (!found) return null;
    }
    const len = std.unicode.utf8Encode(cp, buf) catch return null;
    return buf[0..len];
}

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const ascii = std.ascii;

test "empty document" {
    var doc = Document.init("");
    try testing.expect(doc.next() == null);

    var doc_ws = Document.init("  \n\t\n \t \n");
    try testing.expect(doc_ws.next() == null);
}

test "ATX headers" {
    var doc = Document.init("# One\n" ++
        "## Two ##\n" ++
        "###\ttabs\t\n" ++
        "#### four#\n" ++
        "##### five # #\n" ++
        "###### six\n" ++
        "#\n" ++
        "\n" ++
        "####### seven\n" ++
        "\n" ++
        "#nospace\n");

    const h1 = doc.next().?.header;
    try testing.expectEqual(@as(u8, 1), h1.level);
    try testing.expectEqualStrings("One", h1.content);

    const h2 = doc.next().?.header;
    try testing.expectEqual(@as(u8, 2), h2.level);
    try testing.expectEqualStrings("Two", h2.content);

    const h3 = doc.next().?.header;
    try testing.expectEqual(@as(u8, 3), h3.level);
    try testing.expectEqualStrings("tabs", h3.content);

    const h4 = doc.next().?.header;
    try testing.expectEqualStrings("four#", h4.content);

    const h5 = doc.next().?.header;
    try testing.expectEqualStrings("five #", h5.content);

    const h6 = doc.next().?.header;
    try testing.expectEqual(@as(u8, 6), h6.level);
    try testing.expectEqualStrings("six", h6.content);

    const h_empty = doc.next().?.header;
    try testing.expectEqual(@as(u8, 1), h_empty.level);
    try testing.expectEqualStrings("", h_empty.content);

    // Seven hashes and missing space are paragraphs, not headers.
    const p1 = doc.next().?.paragraph;
    try testing.expectEqualStrings("####### seven", p1.content);
    const p2 = doc.next().?.paragraph;
    try testing.expectEqualStrings("#nospace", p2.content);

    try testing.expect(doc.next() == null);
}

test "paragraphs" {
    var doc = Document.init(
        "first\n" ++
            "second\n" ++
            "\n" ++
            "  trimmed\n" ++
            "  keeps inner   spacing \n" ++
            "\n" ++
            "after blank\n",
    );

    const p1 = doc.next().?.paragraph;
    try testing.expectEqualStrings("first\nsecond", p1.content);

    var lines = p1.lines();
    try testing.expectEqualStrings("first", lines.next().?);
    try testing.expectEqualStrings("second", lines.next().?);
    try testing.expect(lines.next() == null);

    // Interior lines keep their leading whitespace; only trailing whitespace
    // of the block is trimmed.
    const p2 = doc.next().?.paragraph;
    try testing.expectEqualStrings("trimmed\n  keeps inner   spacing", p2.content);

    const p3 = doc.next().?.paragraph;
    try testing.expectEqualStrings("after blank", p3.content);

    try testing.expect(doc.next() == null);
}

test "CRLF line endings" {
    var doc = Document.init("# Title\r\n\r\npara one\r\nline two\r\n\r\n```\r\ncode\r\n```\r\n");
    const h = doc.next().?.header;
    try testing.expectEqualStrings("Title", h.content);
    const p = doc.next().?.paragraph;
    // Interior breaks keep their raw CRLF bytes.
    try testing.expectEqualStrings("para one\r\nline two", p.content);
    const cb = doc.next().?.code_block;
    try testing.expect(cb.info == null);
    try testing.expectEqualStrings("code", cb.content);
    try testing.expect(doc.next() == null);
}

test "paragraphs interrupted by blocks" {
    var doc = Document.init(
        "text\n" ++
            "# header\n" ++
            "more text\n" ++
            "```\n" ++
            "after fence\n" ++
            "```\n" ++
            "***\n" ++
            "last\n",
    );
    try testing.expectEqualStrings("text", doc.next().?.paragraph.content);
    try testing.expectEqual(@as(u8, 1), doc.next().?.header.level);
    try testing.expectEqualStrings("more text", doc.next().?.paragraph.content);
    _ = doc.next().?.code_block;
    _ = doc.next().?.thematic_break;
    try testing.expectEqualStrings("last", doc.next().?.paragraph.content);
    try testing.expect(doc.next() == null);
}

test "setext headers" {
    var doc = Document.init("Title\n=====\n\nSub\n---\n\nplain\n\ndashes\n- - -\n");
    const h1 = doc.next().?.header;
    try testing.expectEqual(@as(u8, 1), h1.level);
    try testing.expectEqualStrings("Title", h1.content);
    const h2 = doc.next().?.header;
    try testing.expectEqual(@as(u8, 2), h2.level);
    try testing.expectEqualStrings("Sub", h2.content);
    try testing.expectEqualStrings("plain", doc.next().?.paragraph.content);
    // A spaced dash line is a thematic break even under a paragraph.
    try testing.expectEqualStrings("dashes", doc.next().?.paragraph.content);
    _ = doc.next().?.thematic_break;
    try testing.expect(doc.next() == null);
}

test "thematic breaks" {
    var doc = Document.init("---\n***\n___\n- - -\n  * * *\n\n--\n\n-a-\n\n_\n");
    for (0..5) |_| {
        const elem = doc.next().?;
        try testing.expect(meta.activeTag(elem) == .thematic_break);
    }
    // Two dashes, embedded chars and single underscore are paragraphs.
    try testing.expectEqualStrings("--", doc.next().?.paragraph.content);
    try testing.expectEqualStrings("-a-", doc.next().?.paragraph.content);
    try testing.expectEqualStrings("_", doc.next().?.paragraph.content);
    try testing.expect(doc.next() == null);
}

test "fenced code blocks" {
    var doc = Document.init(
        "```zig\n" ++
            "const x = 1;\n" ++
            "\n" ++
            "const y = # hash inside code;\n" ++
            "```\n" ++
            "~~~css\nbody { color: red }\n~~~\n" ++
            "````\n" ++
            "```\n" ++
            "nested fence\n" ++
            "```\n" ++
            "````\n" ++
            "```go unclosed\n" ++
            "runs to eof\n",
    );

    const zig = doc.next().?.code_block;
    try testing.expectEqualStrings("zig", zig.info.?);
    try testing.expectEqualStrings("const x = 1;\n\nconst y = # hash inside code;", zig.content);

    const css = doc.next().?.code_block;
    try testing.expectEqualStrings("css", css.info.?);
    try testing.expectEqualStrings("body { color: red }", css.content);

    const nested = doc.next().?.code_block;
    try testing.expect(nested.info == null);
    try testing.expectEqualStrings("```\nnested fence\n```", nested.content);

    const unclosed = doc.next().?.code_block;
    try testing.expectEqualStrings("go unclosed", unclosed.info.?);
    try testing.expectEqualStrings("runs to eof", unclosed.content);

    try testing.expect(doc.next() == null);
}

test "code fence edge cases" {
    // Closing fence longer than opening: allowed. Shorter: not.
    var doc = Document.init("````\na\n```\nb\n````\n");
    const cb = doc.next().?.code_block;
    try testing.expectEqualStrings("a\n```\nb", cb.content);

    // Closing fence may not carry an info string.
    var doc2 = Document.init("```\ncode\n``` not a closing fence\n");
    const cb2 = doc2.next().?.code_block;
    try testing.expectEqualStrings("code\n``` not a closing fence", cb2.content);
    try testing.expect(doc2.next() == null);

    // Info string may not contain a backtick: paragraph instead.
    var doc3 = Document.init("``` no `ticks` here\n");
    try testing.expect(doc3.next().?.paragraph.content.len > 0);
}

test "bullet lists" {
    var doc = Document.init("- one\n- two\n\nafter\n");
    const list = doc.next().?.list;
    try testing.expect(!list.ordered);
    try testing.expect(list.tight);

    var items = list.items;
    const first = items.next().?;
    try testing.expect(first.task == null);
    var first_blocks = first.blocks;
    try testing.expectEqualStrings("one", first_blocks.next().?.paragraph.content);
    try testing.expect(first_blocks.next() == null);
    const second = items.next().?;
    var second_blocks = second.blocks;
    try testing.expectEqualStrings("two", second_blocks.next().?.paragraph.content);
    try testing.expect(items.next() == null);

    try testing.expectEqualStrings("after", doc.next().?.paragraph.content);
    try testing.expect(doc.next() == null);
}

test "bullet char changes start a new list" {
    var doc = Document.init("- a\n* b\n");
    const first = doc.next().?.list;
    var items = first.items;
    _ = items.next().?;
    try testing.expect(items.next() == null);

    const second = doc.next().?.list;
    try testing.expect(!second.ordered);
    var second_items = second.items;
    const b_item = second_items.next().?;
    var b_blocks = b_item.blocks;
    try testing.expectEqualStrings("b", b_blocks.next().?.paragraph.content);
    try testing.expect(doc.next() == null);
}

test "ordered lists keep their start number" {
    var doc = Document.init("3. three\n4. four\n\n5) five\n");
    const list = doc.next().?.list;
    try testing.expect(list.ordered);
    try testing.expectEqual(@as(u32, 3), list.start);
    var items = list.items;
    _ = items.next().?;
    _ = items.next().?;
    try testing.expect(items.next() == null);

    const paren_list = doc.next().?.list;
    try testing.expect(paren_list.ordered);
    try testing.expectEqual(@as(u32, 5), paren_list.start);
    try testing.expect(doc.next() == null);
}

test "task list items" {
    var doc = Document.init("- [ ] todo\n- [x] done\n- [X] also done\n- plain\n");
    const list = doc.next().?.list;
    var items = list.items;

    const todo = items.next().?;
    try testing.expectEqual(false, todo.task.?);
    var todo_blocks = todo.blocks;
    try testing.expectEqualStrings("todo", todo_blocks.next().?.paragraph.content);

    const done = items.next().?;
    try testing.expectEqual(true, done.task.?);
    var done_blocks = done.blocks;
    try testing.expectEqualStrings("done", done_blocks.next().?.paragraph.content);

    const also_done = items.next().?;
    try testing.expectEqual(true, also_done.task.?);

    const plain = items.next().?;
    try testing.expect(plain.task == null);
    var plain_blocks = plain.blocks;
    try testing.expectEqualStrings("plain", plain_blocks.next().?.paragraph.content);
    try testing.expect(items.next() == null);
}

test "loose lists" {
    var doc = Document.init("- one\n\n- two\n");
    const list = doc.next().?.list;
    try testing.expect(!list.tight);

    var tight_doc = Document.init("- one\n- two\n");
    try testing.expect(tight_doc.next().?.list.tight);
}

test "nested lists" {
    var doc = Document.init("- a\n  - b\n    - c\n");
    const outer = doc.next().?.list;
    var outer_items = outer.items;
    const a = outer_items.next().?;
    var a_blocks = a.blocks;
    try testing.expectEqualStrings("a", a_blocks.next().?.paragraph.content);
    const middle = a_blocks.next().?.list;
    try testing.expect(!middle.ordered);

    var middle_items = middle.items;
    const b = middle_items.next().?;
    var b_blocks = b.blocks;
    try testing.expectEqualStrings("b", b_blocks.next().?.paragraph.content);
    const inner = b_blocks.next().?.list;
    var inner_items = inner.items;
    const c_item = inner_items.next().?;
    var c_blocks = c_item.blocks;
    try testing.expectEqualStrings("c", c_blocks.next().?.paragraph.content);

    try testing.expect(middle_items.next() == null);
    try testing.expect(outer_items.next() == null);
    try testing.expect(doc.next() == null);
}

test "list items hold multiple blocks" {
    var doc = Document.init("- para\n  # head\n  more\n");
    const list_elem = doc.next().?.list;
    var list_items = list_elem.items;
    const item = list_items.next().?;
    var item_blocks = item.blocks;
    try testing.expectEqualStrings("para", item_blocks.next().?.paragraph.content);
    const h = item_blocks.next().?.header;
    try testing.expectEqual(@as(u8, 1), h.level);
    try testing.expectEqualStrings("head", h.content);
    try testing.expectEqualStrings("more", item_blocks.next().?.paragraph.content);
    try testing.expect(item_blocks.next() == null);
}

test "empty list items" {
    var doc = Document.init("-\n- x\n");
    const list = doc.next().?.list;
    var items = list.items;
    const empty = items.next().?;
    var empty_blocks = empty.blocks;
    try testing.expect(empty_blocks.next() == null);
    const full = items.next().?;
    var full_blocks = full.blocks;
    try testing.expectEqualStrings("x", full_blocks.next().?.paragraph.content);
    try testing.expect(items.next() == null);
}

test "lists interrupt paragraphs" {
    var doc = Document.init("text\n- item\n");
    try testing.expectEqualStrings("text", doc.next().?.paragraph.content);
    _ = doc.next().?.list;

    var doc2 = Document.init("text\n1. item\n");
    try testing.expectEqualStrings("text", doc2.next().?.paragraph.content);
    _ = doc2.next().?.list;

    // Empty items and start numbers other than 1 do not interrupt. A lone
    // `-` is a setext underline, so use a `*` bullet for the empty item.
    var doc3 = Document.init("text\n* \nmore\n");
    try testing.expectEqualStrings("text\n* \nmore", doc3.next().?.paragraph.content);

    var doc4 = Document.init("text\n2. item\n");
    try testing.expectEqualStrings("text\n2. item", doc4.next().?.paragraph.content);
}

test "thematic break wins over list marker" {
    var doc = Document.init("- - -\n- item\n");
    try testing.expect(meta.activeTag(doc.next().?) == .thematic_break);
    _ = doc.next().?.list;
    try testing.expect(doc.next() == null);
}

test "tables" {
    var doc = Document.init("| a | b |\n|---|---|\n| c | d |\n\nafter\n");
    const table = doc.next().?.table;
    try testing.expectEqual(@as(usize, 2), table.ncols);
    try testing.expectEqualStrings("| a | b |", table.header);

    var hbuf: [max_table_cols][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), splitCells(table.header, &hbuf));
    try testing.expectEqualStrings("a", hbuf[0]);
    try testing.expectEqualStrings("b", hbuf[1]);

    var lines = LineIterator{ .remaining = table.body, .chain = table.chain, .first = false };
    var row: [max_table_cols][]const u8 = undefined;
    try testing.expectEqualStrings("| c | d |", lines.next().?);
    try testing.expect(lines.next() == null);
    try testing.expectEqual(@as(usize, 2), splitCells("| c | d |", &row));
    try testing.expectEqualStrings("c", row[0]);

    try testing.expectEqualStrings("after", doc.next().?.paragraph.content);
    try testing.expect(doc.next() == null);
}

test "table alignments and cell edge cases" {
    var doc = Document.init("| l | r | c | d |\n| :--- | ---: | :---: | --- |\n");
    const table = doc.next().?.table;
    try testing.expectEqual(@as(usize, 4), table.ncols);
    try testing.expectEqual(Alignment.left, table.aligns[0]);
    try testing.expectEqual(Alignment.right, table.aligns[1]);
    try testing.expectEqual(Alignment.center, table.aligns[2]);
    try testing.expectEqual(Alignment.left, table.aligns[3]);
    try testing.expectEqualStrings("", table.body);

    var buf: [max_table_cols][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), splitCells("| a \\| b | `c|d` |", &buf));
    try testing.expectEqualStrings("a \\| b", buf[0]);
    try testing.expectEqualStrings("`c|d`", buf[1]);
}

test "table delimiter mismatch stays a paragraph" {
    var doc = Document.init("| a | b |\n|---|\n");
    try testing.expectEqualStrings("| a | b |\n|---|", doc.next().?.paragraph.content);

    var setext = Document.init("plain\n---\n");
    try testing.expectEqual(@as(u8, 2), setext.next().?.header.level);
}

test "reference links" {
    var doc = Document.init("[full][label] and [collapsed][] and [shortcut]\n\n[label]: /a\n[collapsed]: /b \"t\"\n[shortcut]: /c\n");
    const p = doc.next().?.paragraph;
    try testing.expectEqualStrings("[full][label] and [collapsed][] and [shortcut]", p.content);

    var it = Spans.initChainRefs(p.content, p.chain, p.refs);
    try expectSpanEqual(.{ .link = .{ .destination = "/a", .title = null } }, it.next().?);
    try testing.expectEqualStrings("full", it.next().?.text);
    _ = it.next();
    try testing.expectEqualStrings(" and ", it.next().?.text);
    try expectSpanEqual(.{ .link = .{ .destination = "/b", .title = "t" } }, it.next().?);
    try testing.expectEqualStrings("collapsed", it.next().?.text);
    _ = it.next();
    try testing.expectEqualStrings(" and ", it.next().?.text);
    try expectSpanEqual(.{ .link = .{ .destination = "/c", .title = null } }, it.next().?);
    try testing.expectEqualStrings("shortcut", it.next().?.text);
    _ = it.next();
    try testing.expect(it.next() == null);
    try testing.expect(doc.next() == null);
}

test "reference definitions are stripped" {
    var doc = Document.init("Foo\n[bar]: /baz\n");
    try testing.expectEqualStrings("Foo", doc.next().?.paragraph.content);
    try testing.expect(doc.next() == null);

    var only = Document.init("[a]: /x\n");
    try testing.expect(only.next() == null);
}

test "undefined references stay literal" {
    var doc = Document.init("[foo][bar] and [baz]\n");
    const p = doc.next().?.paragraph;
    var it = Spans.initChainRefs(p.content, p.chain, p.refs);
    try testing.expectEqualStrings("[foo][bar] and [baz]", it.next().?.text);
    try testing.expect(it.next() == null);
}

test "standalone image paragraph becomes an image element" {
    var doc = Document.init("![architecture](images/architecture.png \"System overview\")");
    const image = doc.next().?.image;

    try testing.expectEqualStrings("architecture", image.alt);
    try testing.expectEqualStrings("images/architecture.png", image.source);
    try testing.expectEqualStrings("System overview", image.title.?);
    try testing.expect(doc.next() == null);
}

test "image-only lines interrupt surrounding paragraph text" {
    var doc = Document.init(
        \\before
        \\![one](one.png)
        \\![two](two.png)
        \\after
    );

    try testing.expectEqualStrings("before", doc.next().?.paragraph.content);
    try testing.expectEqualStrings("one.png", doc.next().?.image.source);
    try testing.expectEqualStrings("two.png", doc.next().?.image.source);
    try testing.expectEqualStrings("after", doc.next().?.paragraph.content);
    try testing.expect(doc.next() == null);
}

test "image markers stay literal with references defined" {
    var doc = Document.init("![alt][img]\n\n[img]: /u\n");
    const p = doc.next().?.paragraph;
    var it = Spans.initChainRefs(p.content, p.chain, p.refs);
    try testing.expectEqualStrings("![alt][img]", it.next().?.text);
    try testing.expect(it.next() == null);
}

test "reference labels match loosely, first wins" {
    var doc = Document.init("[A  B][lAb El]\n\n[lab  el]: /one\n[LAB EL]: /two\n");
    doc.refs.ensureScanned();
    const def = doc.refs.lookup("lab el").?;
    try testing.expectEqualStrings("/one", def.destination);

    const p = doc.next().?.paragraph;
    var it = Spans.initChainRefs(p.content, p.chain, p.refs);
    try expectSpanEqual(.{ .link = .{ .destination = "/one", .title = null } }, it.next().?);
}

test "autolink interiors stay literal" {
    var it = Spans.init("<http://a*b[c]>");
    try expectSpanEqual(.{ .link = .{ .destination = "http://a*b[c]", .title = null } }, it.next().?);
    try testing.expectEqualStrings("http://a*b[c]", it.next().?.text);
    _ = it.next();
    try testing.expect(it.next() == null);
}

test "full reference falls back to shortcut" {
    var doc = Document.init("[foo][bar]\n\n[foo]: /x\n");
    const p = doc.next().?.paragraph;
    var it = Spans.initChainRefs(p.content, p.chain, p.refs);
    try expectSpanEqual(.{ .link = .{ .destination = "/x", .title = null } }, it.next().?);
    try testing.expectEqualStrings("foo", it.next().?.text);
    _ = it.next();
    try testing.expectEqualStrings("[bar]", it.next().?.text);
    try testing.expect(it.next() == null);
}

test "tables inside block quotes" {
    var doc = Document.init("> | a | b |\n> |---|---|\n> | c | d |\n");
    var blocks = doc.next().?.block_quote.blocks;
    const table = blocks.next().?.table;
    try testing.expectEqual(@as(usize, 2), table.ncols);
    var lines = LineIterator{ .remaining = table.body, .chain = table.chain, .first = false };
    try testing.expectEqualStrings("| c | d |", lines.next().?);
    try testing.expect(lines.next() == null);
    try testing.expect(blocks.next() == null);
    try testing.expect(doc.next() == null);
}

test "tables inside lists" {
    var doc = Document.init("- | a |\n  |---|\n  | b |\n");
    const list = doc.next().?.list;
    var items = list.items;
    const item = items.next().?;
    var blocks = item.blocks;
    const table = blocks.next().?.table;
    try testing.expectEqual(@as(usize, 1), table.ncols);
    var lines = LineIterator{ .remaining = table.body, .chain = table.chain, .first = false };
    try testing.expectEqualStrings("| b |", lines.next().?);
    try testing.expect(lines.next() == null);
    try testing.expect(blocks.next() == null);
    try testing.expect(items.next() == null);
    try testing.expect(doc.next() == null);
}

test "block quotes" {
    var doc = Document.init("> # Title\n> para\n>\n> more\n\nafter\n");
    const quote = doc.next().?.block_quote;
    var blocks = quote.blocks;

    const h = blocks.next().?.header;
    try testing.expectEqual(@as(u8, 1), h.level);
    try testing.expectEqualStrings("Title", h.content);
    try testing.expectEqualStrings("para", blocks.next().?.paragraph.content);
    try testing.expectEqualStrings("more", blocks.next().?.paragraph.content);
    try testing.expect(blocks.next() == null);

    try testing.expectEqualStrings("after", doc.next().?.paragraph.content);
    try testing.expect(doc.next() == null);
}

test "lazy quote continuation" {
    var doc = Document.init("> para one\ncontinues here\n\nnext\n");
    var blocks = doc.next().?.block_quote.blocks;
    const p = blocks.next().?.paragraph;
    var lines = p.lines();
    try testing.expectEqualStrings("para one", lines.next().?);
    try testing.expectEqualStrings("continues here", lines.next().?);
    try testing.expect(lines.next() == null);
    try testing.expect(blocks.next() == null);
    try testing.expectEqualStrings("next", doc.next().?.paragraph.content);
}

test "nested block quotes" {
    var doc = Document.init("> level 1\n> > level 2\n");
    const outer = doc.next().?.block_quote;
    var outer_blocks = outer.blocks;
    const p1 = outer_blocks.next().?.paragraph;
    var p1_lines = p1.lines();
    try testing.expectEqualStrings("level 1", p1_lines.next().?);
    try testing.expect(p1_lines.next() == null);

    var inner = outer_blocks.next().?.block_quote;
    const p2 = inner.blocks.next().?.paragraph;
    var p2_lines = p2.lines();
    try testing.expectEqualStrings("level 2", p2_lines.next().?);
    try testing.expect(inner.blocks.next() == null);
    try testing.expect(outer_blocks.next() == null);
    try testing.expect(doc.next() == null);
}

test "lists inside block quotes" {
    var doc = Document.init("> - a\n> - b\n");
    var blocks = doc.next().?.block_quote.blocks;
    const list = blocks.next().?.list;
    var items = list.items;
    const a_item = items.next().?;
    var a_blocks = a_item.blocks;
    try testing.expectEqualStrings("a", a_blocks.next().?.paragraph.content);
    const b_item = items.next().?;
    var b_blocks = b_item.blocks;
    try testing.expectEqualStrings("b", b_blocks.next().?.paragraph.content);
    try testing.expect(items.next() == null);
    try testing.expect(blocks.next() == null);
    try testing.expect(doc.next() == null);
}

test "code blocks inside containers" {
    var doc = Document.init("> ```zig\n> let x = 1;\n> ```\n");
    var blocks = doc.next().?.block_quote.blocks;
    const cb = blocks.next().?.code_block;
    try testing.expectEqualStrings("zig", cb.info.?);
    var lines = cb.lines();
    try testing.expectEqualStrings("let x = 1;", lines.next().?);
    try testing.expect(lines.next() == null);
}

test "inline span edge cases" {
    const cases = [_]struct { input: []const u8, expected: []const Span }{
        .{ .input = "plain text", .expected = &.{.{ .text = "plain text" }} },
        // Unclosed markers are literal text.
        .{ .input = "a ** b", .expected = &.{.{ .text = "a ** b" }} },
        .{ .input = "**a", .expected = &.{.{ .text = "**a" }} },
        // Intraword `_` is not recognized.
        .{ .input = "a_b_c", .expected = &.{.{ .text = "a_b_c" }} },
        .{ .input = "foo_bar", .expected = &.{.{ .text = "foo_bar" }} },
        // Intraword `*` does emphasize, matching CommonMark.
        .{ .input = "2*3*4", .expected = &.{ .{ .text = "2" }, .em_open, .{ .text = "3" }, .em_close, .{ .text = "4" } } },
        .{ .input = "*a*b", .expected = &.{ .em_open, .{ .text = "a" }, .em_close, .{ .text = "b" } } },
        // Multi-backtick code spans.
        .{ .input = "``a`b``", .expected = &.{.{ .code = "a`b" }} },
        .{ .input = "`a``b`", .expected = &.{.{ .code = "a``b" }} },
        // One space stripped from each side when both are present.
        .{ .input = "` x `", .expected = &.{.{ .code = "x" }} },
        .{ .input = "`  x `", .expected = &.{.{ .code = " x" }} },
        // Longer closing runs leave the extra markers as text.
        .{ .input = "**a***", .expected = &.{ .strong_open, .{ .text = "a" }, .strong_close, .{ .text = "*" } } },
        // The rule of 3 keeps `*a**b*` from matching the inner run.
        .{ .input = "*a**b*", .expected = &.{ .em_open, .{ .text = "a**b" }, .em_close } },
        // Emphasis across a soft line break.
        .{ .input = "*two\nlines*", .expected = &.{ .em_open, .{ .text = "two" }, .soft_break, .{ .text = "lines" }, .em_close } },
        // Unclosed code spans merge into text.
        .{ .input = "x `` y", .expected = &.{.{ .text = "x `` y" }} },
        .{ .input = "``", .expected = &.{.{ .text = "``" }} },
        // Nested emphasis: `***` resolves to strong inside emphasis.
        .{ .input = "***a***", .expected = &.{ .em_open, .strong_open, .{ .text = "a" }, .strong_close, .em_close } },
        .{ .input = "*a *b* c*", .expected = &.{ .em_open, .{ .text = "a " }, .em_open, .{ .text = "b" }, .em_close, .{ .text = " c" }, .em_close } },
        .{ .input = "**a *b* c**", .expected = &.{ .strong_open, .{ .text = "a " }, .em_open, .{ .text = "b" }, .em_close, .{ .text = " c" }, .strong_close } },
        // Strikethrough: one or two tildes, counts must match.
        .{ .input = "~~strike~~", .expected = &.{ .strike_open, .{ .text = "strike" }, .strike_close } },
        .{ .input = "~one~", .expected = &.{ .strike_open, .{ .text = "one" }, .strike_close } },
        .{ .input = "~a~~", .expected = &.{.{ .text = "~a~~" }} },
        .{ .input = "~~~x~~~", .expected = &.{.{ .text = "~~~x~~~" }} },
        // Links: destination and title, with emphasis in the text.
        .{ .input = "[link](/url)", .expected = &.{ .{ .link = .{ .destination = "/url", .title = null } }, .{ .text = "link" }, .link_close } },
        .{ .input = "[t](/u \"ti\")", .expected = &.{ .{ .link = .{ .destination = "/u", .title = "ti" } }, .{ .text = "t" }, .link_close } },
        .{ .input = "[a](b(c))", .expected = &.{ .{ .link = .{ .destination = "b(c)", .title = null } }, .{ .text = "a" }, .link_close } },
        .{ .input = "[in *em*](u)", .expected = &.{ .{ .link = .{ .destination = "u", .title = null } }, .{ .text = "in " }, .em_open, .{ .text = "em" }, .em_close, .link_close } },
        .{ .input = "[bad](unclosed", .expected = &.{.{ .text = "[bad](unclosed" }} },
        // Entities: named (known only) and numeric.
        .{ .input = "&amp;", .expected = &.{.{ .entity = "&amp;" }} },
        .{ .input = "&#65;", .expected = &.{.{ .entity = "&#65;" }} },
        .{ .input = "&#x42;", .expected = &.{.{ .entity = "&#x42;" }} },
        .{ .input = "&nope;", .expected = &.{.{ .text = "&nope;" }} },
        .{ .input = "&copy", .expected = &.{.{ .text = "&copy" }} },
        // Escapes.
        .{ .input = "a\\*b", .expected = &.{ .{ .text = "a" }, .{ .escape = "*" }, .{ .text = "b" } } },
        .{ .input = "\\\\", .expected = &.{.{ .escape = "\\" }} },
        // Hard breaks: two trailing spaces or a backslash at the line end.
        .{ .input = "end  \nnext", .expected = &.{ .{ .text = "end" }, .hard_break, .{ .text = "next" } } },
        .{ .input = "back\\\nslash", .expected = &.{ .{ .text = "back" }, .hard_break, .{ .text = "slash" } } },
        .{ .input = "soft\nbreak", .expected = &.{ .{ .text = "soft" }, .soft_break, .{ .text = "break" } } },
        // Autolinks: URI schemes and emails; anything else stays literal.
        .{ .input = "<https://x.y/z?a=1&b=2>", .expected = &.{ .{ .link = .{ .destination = "https://x.y/z?a=1&b=2", .title = null } }, .{ .text = "https://x.y/z?a=1&b=2" }, .link_close } },
        .{ .input = "<foo@bar.com>", .expected = &.{ .{ .link = .{ .destination = "foo@bar.com", .title = null } }, .{ .text = "foo@bar.com" }, .link_close } },
        .{ .input = "<div>", .expected = &.{.{ .text = "<div>" }} },
        .{ .input = "<a b>", .expected = &.{.{ .text = "<a b>" }} },
        .{ .input = "<a:>", .expected = &.{.{ .text = "<a:>" }} },
        .{ .input = "<foo@>", .expected = &.{.{ .text = "<foo@>" }} },
    };

    for (cases) |case| {
        var it = Spans.init(case.input);
        for (case.expected) |expected| {
            const actual = it.next() orelse {
                debug.print("missing span in \"{s}\"\n", .{case.input});
                return error.TestUnexpectedResult;
            };
            expectSpanEqual(expected, actual) catch |err| {
                debug.print("in \"{s}\"\n", .{case.input});
                return err;
            };
        }
        if (it.next()) |extra| {
            debug.print("unexpected extra span in \"{s}\": {any}\n", .{ case.input, extra });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectSpanEqual(expected: Span, actual: Span) !void {
    try testing.expectEqual(meta.activeTag(expected), meta.activeTag(actual));
    switch (expected) {
        .text => |s| try testing.expectEqualStrings(s, actual.text),
        .code => |s| try testing.expectEqualStrings(s, actual.code),
        .entity => |s| try testing.expectEqualStrings(s, actual.entity),
        .escape => |s| try testing.expectEqualStrings(s, actual.escape),
        .link => |l| {
            try testing.expectEqualStrings(l.destination, actual.link.destination);
            if (l.title) |t| try testing.expectEqualStrings(t, actual.link.title.?);
        },
        .hard_break, .soft_break, .em_open, .em_close, .strong_open, .strong_close, .strike_open, .strike_close, .link_close => {},
    }
}

test "decode entities" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("&", Document.decodeEntity("&amp;", &buf).?);
    try testing.expectEqualStrings("A", Document.decodeEntity("&#65;", &buf).?);
    try testing.expectEqualStrings("\"", Document.decodeEntity("&#x22;", &buf).?);
    try testing.expect(Document.decodeEntity("&nope;", &buf) == null);
    try testing.expect(Document.decodeEntity("&#x110000;", &buf) == null);
}

test "zero-copy slices point into text" {
    const text = "# Title\n\npara `code`\n";
    var doc = Document.init(text);
    const h = doc.next().?.header;
    try testing.expect(h.content.ptr == text.ptr + 2);
    const p = doc.next().?.paragraph;
    try testing.expect(p.content.ptr == text.ptr + 9);
    var it = p.spans();
    _ = it.next().?.text;
    const code = it.next().?.code;
    try testing.expect(code.ptr == text.ptr + 15);
}

test "parse from a chunked reader matches borrowed parsing" {
    const input =
        "# Header\n" ++
        "\n" ++
        "Paragraph with **bold** and `code`.\n" ++
        "Second line.\n" ++
        "\n" ++
        "```zig\nfn main() {}\n```\n" ++
        "---\n" ++
        "Setext\n------\n" ++
        "- a\n- b\n" ++
        "> quoted\n" ++
        "[r][i]\n\n[i]: /u\n";

    var borrowed = Document.init(input);

    var calls = [_]testing.Reader.Call{
        .{ .buffer = input[0..40] },
        .{ .buffer = input[40..] },
    };
    var mock_buffer: [8]u8 = undefined;
    var mock: testing.Reader = .init(&mock_buffer, &calls);
    mock.artificial_limit = .limited(3);

    const gpa = testing.allocator;
    var streamed = try Document.parse(&mock.interface, gpa);
    defer streamed.deinit();

    try testing.expectEqualStrings(input, streamed.text);

    while (borrowed.next()) |elem_a| {
        const elem_b = streamed.next() orelse return error.TestUnexpectedResult;
        try expectEqualElements(elem_a, elem_b, 0);
    }
    try testing.expect(streamed.next() == null);
}

test "parse of empty stream" {
    var mock: testing.Reader = .init(&.{}, &.{});
    var doc = try Document.parse(&mock.interface, testing.allocator);
    defer doc.deinit();
    try testing.expectEqualStrings("", doc.text);
    try testing.expect(doc.next() == null);
}

// Corpus entries also run as plain tests in every `zig build test`.
test "fuzz parser safety" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &fuzz_corpus });
}

// Deterministic randomized runs in every `zig build test`: random byte
// streams drive `fuzzOne` through Smith's decode mode.
test "randomized inputs" {
    var prng = std.Random.DefaultPrng.init(0x6d6472f007);
    const rand = prng.random();
    for (0..512) |_| {
        var stream: [512]u8 = undefined;
        rand.bytes(&stream);
        const len = rand.uintAtMost(usize, stream.len);
        var smith: testing.Smith = .{ .in = stream[0..len] };
        try fuzzOne({}, &smith);
    }
}

test {
    testing.refAllDecls(Document);
}

fn expectWithin(slice: []const u8, text: []const u8) !void {
    const slice_start = @intFromPtr(slice.ptr);
    const text_start = @intFromPtr(text.ptr);
    try testing.expect(slice_start >= text_start);
    try testing.expect(slice_start + slice.len <= text_start + text.len);
}

fn expectValidSpans(content: []const u8) !void {
    var it = Spans.init(content);
    var prev_pos: usize = 0;
    var count: usize = 0;
    var open = [3]isize{ 0, 0, 0 };
    var in_link = false;
    while (it.next()) |span| {
        count += 1;
        try testing.expect(it.pos > prev_pos);
        try testing.expect(it.pos <= content.len);
        prev_pos = it.pos;
        switch (span) {
            .text, .code, .entity => |s| try expectWithin(s, content),
            .escape => |s| try testing.expectEqual(@as(usize, 1), s.len),
            .hard_break, .soft_break => {},
            .em_open => open[0] += 1,
            .em_close => open[0] -= 1,
            .strong_open => open[1] += 1,
            .strong_close => open[1] -= 1,
            .strike_open => open[2] += 1,
            .strike_close => open[2] -= 1,
            .link => |l| {
                try testing.expect(!in_link);
                in_link = true;
                try expectWithin(l.destination, content);
                if (l.title) |t| try expectWithin(t, content);
            },
            .link_close => in_link = false,
        }
        try testing.expect(open[0] >= 0 and open[1] >= 0 and open[2] >= 0);
        try testing.expect(count <= 2 * content.len + 1);
    }
    try testing.expectEqual(@as(isize, 0), open[0]);
    try testing.expectEqual(@as(isize, 0), open[1]);
    try testing.expectEqual(@as(isize, 0), open[2]);
    try testing.expect(!in_link);
}

fn expectValidElement(elem: Element, text: []const u8, depth: usize) anyerror!void {
    switch (elem) {
        .header => |h| {
            try testing.expect(h.level >= 1 and h.level <= 6);
            try expectWithin(h.content, text);
            try expectValidSpans(h.content);
        },
        .paragraph => |p| {
            try expectWithin(p.content, text);
            try expectValidSpans(p.content);
            var lines = p.lines();
            var line_count: usize = 0;
            while (lines.next()) |l| {
                line_count += 1;
                try expectWithin(l, text);
                const extra = leadingSpaces(l);
                if (extra <= 3) try testing.expect(parseRefDef(l[extra..]) == null);
            }
            try testing.expect(line_count <= p.content.len);
        },
        .image => |image| {
            try expectWithin(image.alt, text);
            try expectWithin(image.source, text);
            if (image.title) |title| try expectWithin(title, text);
        },
        .code_block => |cb| {
            if (cb.info) |info| try expectWithin(info, text);
            try expectWithin(cb.content, text);
            var lines = cb.lines();
            while (lines.next()) |l| try expectWithin(l, text);
        },
        .thematic_break => {},
        .table => |t| {
            try testing.expect(t.ncols >= 1 and t.ncols <= max_table_cols);
            try expectWithin(t.header, text);
            try expectWithin(t.body, text);
            var hbuf: [max_table_cols][]const u8 = undefined;
            try testing.expectEqual(t.ncols, splitCells(t.header, &hbuf));
            for (hbuf[0..t.ncols]) |cell| try expectValidSpans(cell);
            var lines = LineIterator{ .remaining = t.body, .chain = t.chain, .first = false };
            var buf: [max_table_cols][]const u8 = undefined;
            while (lines.next()) |line| {
                try expectWithin(line, text);
                const n = splitCells(line, &buf);
                try testing.expect(n <= max_table_cols);
                for (buf[0..@min(n, t.ncols)]) |cell| try expectValidSpans(cell);
            }
        },
        .list => |l| {
            var items = l.items;
            var item_count: usize = 0;
            while (items.next()) |item| {
                item_count += 1;
                try testing.expect(item.indent >= 1);
                try testing.expect(item.blocks.end <= text.len);
                try testing.expect(item.blocks.cursor <= item.blocks.end);
                try expectValidBlocks(item.blocks, text, depth + 1);
            }
            try testing.expect(item_count <= text.len);
        },
        .block_quote => |q| try expectValidBlocks(q.blocks, text, depth + 1),
    }
}

fn expectValidBlocks(blocks: Blocks, text: []const u8, depth: usize) anyerror!void {
    if (depth > 16) return;
    var it = blocks;
    var count: usize = 0;
    while (it.next()) |elem| {
        count += 1;
        try testing.expect(it.cursor <= text.len);
        try expectValidElement(elem, text, depth);
        try testing.expect(count <= text.len);
    }
}

fn expectValidDocument(doc: *Document) !void {
    const text = doc.text;
    var prev_cursor: usize = 0;
    var count: usize = 0;
    while (doc.next()) |elem| {
        count += 1;
        try testing.expect(doc.cursor > prev_cursor);
        try testing.expect(doc.cursor <= text.len);
        prev_cursor = doc.cursor;
        try expectValidElement(elem, text, 0);
        try testing.expect(count <= text.len);
    }
}

fn expectEqualElements(a: Element, b: Element, depth: usize) anyerror!void {
    try testing.expectEqual(meta.activeTag(a), meta.activeTag(b));
    if (depth > 16) return;
    switch (a) {
        .header => |h| {
            try testing.expectEqual(h.level, b.header.level);
            try testing.expectEqualStrings(h.content, b.header.content);
        },
        .paragraph => |p| try testing.expectEqualStrings(p.content, b.paragraph.content),
        .image => |image| {
            try testing.expectEqualStrings(image.alt, b.image.alt);
            try testing.expectEqualStrings(image.source, b.image.source);
            try testing.expectEqual(image.title != null, b.image.title != null);
            if (image.title) |title| try testing.expectEqualStrings(title, b.image.title.?);
        },
        .code_block => |cb| {
            try testing.expectEqual(cb.info != null, b.code_block.info != null);
            if (cb.info) |info| try testing.expectEqualStrings(info, b.code_block.info.?);
            try testing.expectEqualStrings(cb.content, b.code_block.content);
        },
        .thematic_break => {},
        .table => |t| {
            try testing.expectEqual(t.ncols, b.table.ncols);
            for (t.aligns[0..t.ncols], b.table.aligns[0..t.ncols]) |x, y| try testing.expectEqual(x, y);
            try testing.expectEqualStrings(t.header, b.table.header);
            try testing.expectEqualStrings(t.body, b.table.body);
        },
        .list => |l| {
            try testing.expectEqual(l.ordered, b.list.ordered);
            try testing.expectEqual(l.start, b.list.start);
            try testing.expectEqual(l.tight, b.list.tight);
            var ia = l.items;
            var ib = b.list.items;
            while (ia.next()) |item_a| {
                const item_b = ib.next() orelse return error.TestUnexpectedResult;
                try testing.expectEqual(item_a.task, item_b.task);
                try expectEqualBlocks(item_a.blocks, item_b.blocks, depth + 1);
            }
            try testing.expect(ib.next() == null);
        },
        .block_quote => |q| try expectEqualBlocks(q.blocks, b.block_quote.blocks, depth + 1),
    }
}

fn expectEqualBlocks(a: Blocks, b: Blocks, depth: usize) anyerror!void {
    var ia = a;
    var ib = b;
    while (ia.next()) |elem_a| {
        const elem_b = ib.next() orelse return error.TestUnexpectedResult;
        try expectEqualElements(elem_a, elem_b, depth);
    }
    try testing.expect(ib.next() == null);
}

pub const fuzz_corpus = [_][]const u8{
    "",
    "\n\n\n",
    "# Hello\n\nWorld **bold** and `code`.\n",
    "Setext\n======\n\ndash\n-----\n",
    "```zig\nconst a = 1;\n```\n\n~~~\ntilde\n~~~\n",
    "````\n```\nunclosed-ish\n```\n````\n",
    "```go unclosed\nno closing fence\n",
    "---\n***\n___\n- - -\n",
    "*a* **b** ***c*** `d` ``e`f`` ``g``\n",
    "a_b_c __d__ *e*f* **g\nh** i*\n",
    "# h1\n## h2 ##\n###### h6\n####### p7\n#nospace\n",
    "\r\n# crlf\r\n\r\nbody\r\nlines\r\n\r\n```\r\nx\r\n```\r\n",
    "  # indented header\n\n    indented code\n\npara\n",
    "**** ** * *-- --- _ _ _ ``` ` ` `````\n",
    "> quote\n- list\n1. ordered\n| table |\n",
    "#\n##\n### ####\n-\n--\n=\n",
    "- one\n- two\n\n1. a\n2) b\n\n* c\n",
    "- a\n  - b\n    - c\n- back\n",
    "- [ ] todo\n- [x] done\n- [X] also\n- [y] no\n",
    "> quote\n> more\n> > nested\n\n> lazy\ncontinues\n",
    "[link](/url \"title\") [bad](nope [also](x(y)\n",
    "&amp; &#65; &#x42; &nope; &copy &\n",
    "~~strike~~ ~one~ ~~a\nb~~ *em ~~both~~*\n",
    "hard  \nbreak\\\ntext\n",
    "10. ten\n- mix\n+ more\n",
    "- a\n\n- b\n\n\n- c\n",
    "> \n> \n",
    "- \n-\n",
    "***a*** **b *c* d** __e__ _f_\n",
    "\\*not em\\* a\\\\b \\<tag\\>\n",
    "| a | b |\n|---|---|\n| c | d |\n",
    "| left | right | center |\n| :--- | ---: | :---: |\n",
    "a | b\n--- | ---\nfoo\n",
    "| escaped \\| pipe | `code|span` |\n|---|---|\n",
    "| only header |\n|---|\n",
    "not a table\n---\n",
    "[link][ref]\n\n[ref]: /url \"title\"\n",
    "[collapsed][]\n\n[collapsed]: /u\n",
    "[shortcut]\n\n[shortcut]: /u\n",
    "[dup][a]\n\n[a]: /one\n[a]: /two\n",
    "[Case][Lab]\n\n[lab]: /x\n",
    "Foo\n[bar]: /baz\n",
    "[a]: /only-def\n",
    "[undef][missing] and [lit]\n",
    "<https://example.com/?a=1&b=2>\n",
    "<user@example.com>\n",
    "<div>not autolink</div>\n",
};

pub const fuzz_tokens = [_][]const u8{
    "# ",         "## ",         "###### ",     "#######",      "#nospace",    "#",
    "\n",         "\n\n",        "\r\n",        "\r\n\r\n",     " ",           "  ",
    "    ",       "\t",          "```",         "```zig\n",     "````\n",      "~~~",
    "~~~css\n",   "  ```",       "``` x`y\n",   "text ",        "hello world", "*em*",
    "**bold**",   "***both***",  "_under_",     "`code`",       "``a`b``",     "``",
    "` unclosed", "** unclosed", "* ",          "_ ",           "---",         "***",
    "___",        "- - -",       "--",          "=",            "=====",       "-----",
    "-a-",        "a_b",         "2*3",         "**a*",         "*a**b*",      "` x `",
    "> ",         "> > ",        "- item",      "1. item",      "1) item",     "10. item",
    "- ",         "1. ",         "[a](b)",      "[a](b \"c\")", "[",           "](",
    "(",          ")",           "&amp;",       "&#65;",        "&",           ";",
    "~~",         "~",           "~~x~~",       "\\",           "\\*",         "- [ ] ",
    "- [x] ",     "***a***",     "*a **b** c*", "![img](x)",    "   ",         "\t- ",
    "| ",         "|",           "|---|",       "---|",         ":---",        "---:",
    ":---:",      "\\|",         "`a|b`",       "[a][b]",       "[a][]",       "[a]",
    "[a]: ",      "[A][b]",      "/url",        "\"t\"",        "<https://",   "@x.com>",
    "<div>",
};

fn fuzzOne(_: void, smith: *testing.Smith) !void {
    const gpa = testing.allocator;

    var input_buf: [4096]u8 = undefined;
    var input_len: usize = 0;
    while (!smith.eos() and input_len < input_buf.len) {
        switch (smith.value(enum { token, raw, token_repeat })) {
            .token => {
                const token = fuzz_tokens[smith.index(fuzz_tokens.len)];
                if (token.len > input_buf.len - input_len) break;
                @memcpy(input_buf[input_len..][0..token.len], token);
                input_len += token.len;
            },
            .raw => {
                const n = smith.valueRangeAtMost(u16, 1, 96);
                const take = @min(@as(usize, n), input_buf.len - input_len);
                smith.bytes(input_buf[input_len..][0..take]);
                input_len += take;
            },
            .token_repeat => {
                const token = fuzz_tokens[smith.index(fuzz_tokens.len)];
                const repeats = smith.valueRangeAtMost(u8, 2, 8);
                for (0..repeats) |_| {
                    if (token.len > input_buf.len - input_len) break;
                    @memcpy(input_buf[input_len..][0..token.len], token);
                    input_len += token.len;
                }
            },
        }
    }
    const input = input_buf[0..input_len];

    // Borrowed path.
    {
        var doc = Document.init(input);
        try expectValidDocument(&doc);
    }

    // Reader path: chunked delivery must produce identical elements.
    {
        var calls = [_]testing.Reader.Call{
            .{ .buffer = input[0 .. input_len / 2] },
            .{ .buffer = input[input_len / 2 ..] },
        };
        var mock_buffer: [16]u8 = undefined;
        var mock: testing.Reader = .init(&mock_buffer, &calls);
        mock.artificial_limit = .limited(5);

        var borrowed = Document.init(input);
        var streamed = try Document.parse(&mock.interface, gpa);
        defer streamed.deinit();
        try testing.expectEqualStrings(input, streamed.text);

        while (borrowed.next()) |elem_a| {
            const elem_b = streamed.next() orelse return error.TestUnexpectedResult;
            try expectEqualElements(elem_a, elem_b, 0);
        }
        try testing.expect(streamed.next() == null);
    }
}

const testing = std.testing;
const meta = std.meta;
const debug = std.debug;
