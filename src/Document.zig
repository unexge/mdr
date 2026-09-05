//! Zero-copy, lazily parsed Markdown.
//!
//! `Document` returns one block-level `Element` per `next` call; every slice
//! it hands out points into the input text. `parse` reads a `std.Io.Reader`
//! into a single buffer, the only allocation in the library; `init` borrows
//! text already in memory. Markdown has no syntax errors, so parsing cannot
//! fail.
//!
//! Supported: ATX and setext headers, fenced code blocks, thematic breaks,
//! paragraphs, and inline bold/italic/code spans. Lists, block quotes,
//! tables, indented code and nested emphasis are not supported yet.

const Document = @This();

/// The full input text. Every returned slice points into this buffer.
text: []const u8,
cursor: usize = 0,
/// Set by `parse`, freed by `deinit`.
owned: ?[]u8 = null,
gpa: ?mem.Allocator = null,

/// Reads the entire stream into one buffer; the reader is not retained.
/// Wrap the reader in `limited()` first to bound memory for untrusted input.
pub fn parse(reader: *Io.Reader, gpa: mem.Allocator) ParseError!Document {
    const owned = try reader.allocRemaining(gpa, .unlimited);
    return .{ .text = owned, .owned = owned, .gpa = gpa };
}

pub const ParseError = Io.Reader.LimitedAllocError;

/// Borrows `text`; it must stay valid and unmodified while iterating.
pub fn init(text: []const u8) Document {
    return .{ .text = text };
}

/// Frees the `parse` buffer; a no-op for `init` documents.
pub fn deinit(self: *Document) void {
    if (self.owned) |buf| self.gpa.?.free(buf);
    self.* = undefined;
}

/// Returns the next block-level element, or null at the end.
pub fn next(self: *Document) ?Element {
    const text = self.text;

    while (self.cursor < text.len) {
        if (!isBlankLine(lineSlice(text, self.cursor))) break;
        self.cursor = nextLineStart(text, self.cursor);
    }
    if (self.cursor >= text.len) return null;

    const line = lineSlice(text, self.cursor);
    const indent = leadingSpaces(line);
    if (indent <= 3) {
        const body = line[indent..];
        if (parseAtxHeader(body)) |header| {
            self.cursor = nextLineStart(text, self.cursor);
            return .{ .header = header };
        }
        if (parseFence(body)) |fence| return self.parseCodeBlock(fence);
        if (isThematicBreak(body)) {
            self.cursor = nextLineStart(text, self.cursor);
            return .thematic_break;
        }
    }
    return self.parseParagraph();
}

fn parseParagraph(self: *Document) Element {
    const text = self.text;

    // `next` dispatches here only for lines that are not blank or another
    // block, so the first line is always paragraph content.
    var content_start = self.cursor;
    while (content_start < text.len and
        (text[content_start] == ' ' or text[content_start] == '\t'))
    {
        content_start += 1;
    }
    var content_end = lineEndTrimCr(text, self.cursor);
    var scan = nextLineStart(text, self.cursor);

    while (scan < text.len) {
        const line = lineSlice(text, scan);
        if (isBlankLine(line)) break;
        const indent = leadingSpaces(line);
        if (indent <= 3) {
            const body = line[indent..];
            // A `-` run under a paragraph is a setext h2, not an hr.
            if (setextLevel(body)) |level| {
                const content = trimBlockContent(text[content_start..content_end]);
                self.cursor = nextLineStart(text, scan);
                return .{ .header = .{ .level = level, .content = content } };
            }
            if (parseAtxHeader(body) != null) break;
            if (parseFence(body) != null) break;
            if (isThematicBreak(body)) break;
        }
        content_end = lineEndTrimCr(text, scan);
        scan = nextLineStart(text, scan);
    }

    self.cursor = scan;
    return .{ .paragraph = .{ .content = trimBlockContent(text[content_start..content_end]) } };
}

fn parseCodeBlock(self: *Document, fence: Fence) Element {
    const text = self.text;
    self.cursor = nextLineStart(text, self.cursor);
    const content_start = self.cursor;
    var content_end = content_start;

    while (self.cursor < text.len) {
        const line = lineSlice(text, self.cursor);
        const indent = leadingSpaces(line);
        if (indent <= 3) {
            const body = line[indent..];
            const close_len = runLen(body, 0, fence.ch);
            if (close_len >= fence.len and isBlankLine(body[close_len..])) {
                self.cursor = nextLineStart(text, self.cursor);
                return .{ .code_block = .{
                    .info = fence.info,
                    .content = text[content_start..content_end],
                } };
            }
        }
        content_end = lineEndTrimCr(text, self.cursor);
        self.cursor = nextLineStart(text, self.cursor);
    }
    return .{ .code_block = .{
        .info = fence.info,
        .content = text[content_start..content_end],
    } };
}

/// One block-level element; all payloads are slices into `Document.text`.
pub const Element = union(enum) {
    header: Header,
    paragraph: Paragraph,
    code_block: CodeBlock,
    thematic_break: ThematicBreak,

    pub const Header = struct {
        /// 1 to 6.
        level: u8,
        content: []const u8,

        pub fn spans(self: Header) Spans {
            return .init(self.content);
        }
    };

    pub const Paragraph = struct {
        /// Raw text; multi-line paragraphs keep interior newlines.
        content: []const u8,

        pub fn lines(self: Paragraph) LineIterator {
            return .{ .remaining = self.content };
        }

        pub fn spans(self: Paragraph) Spans {
            return .init(self.content);
        }
    };

    pub const CodeBlock = struct {
        info: ?[]const u8,
        /// Verbatim text between the fences.
        content: []const u8,
    };

    pub const ThematicBreak = struct {};
};

/// An inline formatting run. Emphasis is flat: bold/italic content is raw
/// text that may still contain markers.
pub const Span = union(enum) {
    text: []const u8,
    code: []const u8,
    bold: []const u8,
    italic: []const u8,
    bold_italic: []const u8,
};

/// Inline span iterator. Code spans close at a run of exactly N backticks,
/// emphasis at a later run of the same marker at least as long; unclosed
/// markers are literal text. Intraword `_` never emphasizes, `*` does.
pub const Spans = struct {
    content: []const u8,
    pos: usize = 0,

    pub fn init(content: []const u8) Spans {
        return .{ .content = content };
    }

    pub fn next(self: *Spans) ?Span {
        const c = self.content;
        if (self.pos >= c.len) return null;
        const start = self.pos;
        switch (c[start]) {
            '`' => {
                const open_len = runLen(c, start, '`');
                if (findRunExact(c, start + open_len, '`', open_len)) |close_start| {
                    var inner = c[start + open_len .. close_start];
                    if (inner.len >= 2 and inner[0] == ' ' and inner[inner.len - 1] == ' ') {
                        inner = inner[1 .. inner.len - 1];
                    }
                    self.pos = close_start + open_len;
                    return .{ .code = inner };
                }
                return self.textSpan(start, start + open_len);
            },
            '*', '_' => {
                const marker = c[start];
                const open_len = runLen(c, start, marker);
                if (canOpenEmphasis(c, start, open_len, marker)) {
                    var search = start + open_len;
                    while (findRunAtLeast(c, search, marker, open_len)) |close_start| {
                        if (canCloseEmphasis(c, close_start, open_len, marker)) {
                            self.pos = close_start + open_len;
                            const inner = c[start + open_len .. close_start];
                            return switch (open_len) {
                                1 => .{ .italic = inner },
                                2 => .{ .bold = inner },
                                else => .{ .bold_italic = inner },
                            };
                        }
                        search = close_start + runLen(c, close_start, marker);
                    }
                }
                return self.textSpan(start, start + open_len);
            },
            else => return self.textSpan(start, start),
        }
    }

    /// Extends a literal text run through marker runs that cannot open a
    /// span, so `a_b_c` does not fragment into tiny spans.
    fn textSpan(self: *Spans, start: usize, from: usize) Span {
        const c = self.content;
        var i = from;
        while (i < c.len) {
            switch (c[i]) {
                '`' => break,
                '*', '_' => {
                    const run = runLen(c, i, c[i]);
                    if (canOpenEmphasis(c, i, run, c[i])) break;
                    i += run;
                },
                else => i += 1,
            }
        }
        self.pos = i;
        return .{ .text = c[start..i] };
    }
};

pub const LineIterator = struct {
    remaining: []const u8,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.remaining.len == 0) return null;
        const end = mem.indexOfScalar(u8, self.remaining, '\n') orelse self.remaining.len;
        var line = self.remaining[0..end];
        self.remaining = self.remaining[@min(end + 1, self.remaining.len)..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

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
/// `*` opens when left-flanking and closes when right-flanking; `_`
/// additionally refuses intraword positions.
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
        '*' => return true,
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
        '*' => return true,
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

fn findRunAtLeast(s: []const u8, from: usize, ch: u8, n: usize) ?usize {
    var i = from;
    while (i < s.len) {
        if (s[i] == ch) {
            if (runLen(s, i, ch) >= n) return i;
            i += runLen(s, i, ch);
        } else {
            i += 1;
        }
    }
    return null;
}

fn lineEndTrimCr(text: []const u8, start: usize) usize {
    var end = mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    if (end > start and text[end - 1] == '\r') end -= 1;
    return end;
}

fn lineSlice(text: []const u8, start: usize) []const u8 {
    return text[start..lineEndTrimCr(text, start)];
}

fn nextLineStart(text: []const u8, start: usize) usize {
    const end = mem.indexOfScalarPos(u8, text, start, '\n') orelse return text.len;
    return end + 1;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn leadingSpaces(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    return i;
}

fn trimBlockContent(content: []const u8) []const u8 {
    return mem.trimEnd(u8, content, " \t\r");
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

test "inline span edge cases" {
    const cases = [_]struct { input: []const u8, expected: []const Span }{
        .{ .input = "plain text", .expected = &.{.{ .text = "plain text" }} },
        // Unclosed markers are literal text, merged with surrounding text.
        .{ .input = "a ** b", .expected = &.{.{ .text = "a ** b" }} },
        .{ .input = "**a", .expected = &.{.{ .text = "**a" }} },
        // Intraword `_` is not recognized.
        .{ .input = "a_b_c", .expected = &.{.{ .text = "a_b_c" }} },
        .{ .input = "foo_bar", .expected = &.{.{ .text = "foo_bar" }} },
        // Intraword `*` does emphasize, matching CommonMark.
        .{ .input = "2*3*4", .expected = &.{ .{ .text = "2" }, .{ .italic = "3" }, .{ .text = "4" } } },
        .{ .input = "*a*b", .expected = &.{ .{ .italic = "a" }, .{ .text = "b" } } },
        // Multi-backtick code spans.
        .{ .input = "``a`b``", .expected = &.{.{ .code = "a`b" }} },
        .{ .input = "`a``b`", .expected = &.{.{ .code = "a``b" }} },
        // One space stripped from each side when both are present.
        .{ .input = "` x `", .expected = &.{.{ .code = "x" }} },
        .{ .input = "`  x `", .expected = &.{.{ .code = " x" }} },
        // Longer closing runs leave the extra markers as text.
        .{ .input = "**a***", .expected = &.{ .{ .bold = "a" }, .{ .text = "*" } } },
        // A `*` run may close inside a longer run: `*a**b*` is two emphases.
        .{ .input = "*a**b*", .expected = &.{ .{ .italic = "a" }, .{ .italic = "b" } } },
        // Emphasis across a soft line break.
        .{ .input = "*two\nlines*", .expected = &.{.{ .italic = "two\nlines" }} },
        // Unclosed code span merges into text.
        .{ .input = "x `` y", .expected = &.{ .{ .text = "x " }, .{ .text = "`` y" } } },
        .{ .input = "``", .expected = &.{.{ .text = "``" }} },
    };

    for (cases) |case| {
        var it = Spans.init(case.input);
        for (case.expected) |expected| {
            const actual = it.next() orelse {
                debug.print("missing span in \"{s}\"\n", .{case.input});
                return error.TestUnexpectedResult;
            };
            try testing.expectEqual(meta.activeTag(expected), meta.activeTag(actual));
            switch (expected) {
                inline else => |exp, tag| {
                    try testing.expectEqualStrings(exp, @field(actual, @tagName(tag)));
                },
            }
        }
        if (it.next()) |extra| {
            debug.print("unexpected extra span in \"{s}\": {any}\n", .{ case.input, extra });
            return error.TestUnexpectedResult;
        }
    }
}

test "zero-copy slices point into text" {
    const text = "# Title\n\npara **bold**\n";
    var doc = Document.init(text);
    const h = doc.next().?.header;
    try testing.expect(h.content.ptr == text.ptr + 2);
    const p = doc.next().?.paragraph;
    try testing.expect(p.content.ptr == text.ptr + 9);
    var it = p.spans();
    _ = it.next().?.text;
    const bold = it.next().?.bold;
    try testing.expect(bold.ptr == text.ptr + 16);
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
        "Setext\n------\n";

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
        try testing.expectEqual(meta.activeTag(elem_a), meta.activeTag(elem_b));
        switch (elem_a) {
            .header => |h| {
                try testing.expectEqual(h.level, elem_b.header.level);
                try testing.expectEqualStrings(h.content, elem_b.header.content);
            },
            .paragraph => |p| try testing.expectEqualStrings(p.content, elem_b.paragraph.content),
            .code_block => |cb| {
                try testing.expectEqual(cb.info != null, elem_b.code_block.info != null);
                if (cb.info) |info| try testing.expectEqualStrings(info, elem_b.code_block.info.?);
                try testing.expectEqualStrings(cb.content, elem_b.code_block.content);
            },
            .thematic_break => {},
        }
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
    try testing.fuzz({}, fuzzOne, .{ .corpus = &corpus });
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
    while (it.next()) |span| {
        count += 1;
        try testing.expect(it.pos > prev_pos);
        try testing.expect(it.pos <= content.len);
        prev_pos = it.pos;
        switch (span) {
            inline else => |s| try expectWithin(s, content),
        }
    }
    try testing.expect(count <= content.len);
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
                }
                try testing.expect(line_count <= p.content.len);
            },
            .code_block => |cb| {
                if (cb.info) |info| try expectWithin(info, text);
                try expectWithin(cb.content, text);
            },
            .thematic_break => {},
        }
        try testing.expect(count <= text.len);
    }
}

const corpus = [_][]const u8{
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
};

const fuzz_tokens = [_][]const u8{
    "# ",         "## ",         "###### ",   "#######",  "#nospace",    "#",
    "\n",         "\n\n",        "\r\n",      "\r\n\r\n", " ",           "  ",
    "    ",       "\t",          "```",       "```zig\n", "````\n",      "~~~",
    "~~~css\n",   "  ```",       "``` x`y\n", "text ",    "hello world", "*em*",
    "**bold**",   "***both***",  "_under_",   "`code`",   "``a`b``",     "``",
    "` unclosed", "** unclosed", "* ",        "_ ",       "---",         "***",
    "___",        "- - -",       "--",        "=",        "=====",       "-----",
    "-a-",        "a_b",         "2*3",       "**a*",     "*a**b*",      "` x `",
    "> ",         "- item",      "1. item",
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
            try testing.expectEqual(meta.activeTag(elem_a), meta.activeTag(elem_b));
            switch (elem_a) {
                .header => |h| {
                    try testing.expectEqual(h.level, elem_b.header.level);
                    try testing.expectEqualStrings(h.content, elem_b.header.content);
                },
                .paragraph => |p| try testing.expectEqualStrings(p.content, elem_b.paragraph.content),
                .code_block => |cb| {
                    try testing.expectEqual(cb.info != null, elem_b.code_block.info != null);
                    if (cb.info) |info| try testing.expectEqualStrings(info, elem_b.code_block.info.?);
                    try testing.expectEqualStrings(cb.content, elem_b.code_block.content);
                },
                .thematic_break => {},
            }
        }
        try testing.expect(streamed.next() == null);
    }
}

const testing = std.testing;
const meta = std.meta;
const debug = std.debug;
