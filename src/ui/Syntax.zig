//! Tree-sitter highlighting for fenced code blocks.

pub const max_source_bytes = 256 * 1024;

pub const Kind = enum {
    comment,
    string,
    constant,
    keyword,
    function,
    type,
};

pub const Span = struct {
    row: u32,
    start_col: u32,
    end_col: u32,
    kind: Kind,
    priority: i32,
    pattern_index: u32,
};

pub const Highlights = struct {
    spans: []Span,

    pub fn deinit(self: *Highlights, allocator: mem.Allocator) void {
        allocator.free(self.spans);
        self.* = undefined;
    }

    pub fn kindAt(self: Highlights, row: usize, off: usize, len: usize) ?Kind {
        var low: usize = 0;
        var high = self.spans.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.spans[mid].row < row) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        var best: ?Span = null;
        for (self.spans[low..]) |span| {
            if (span.row != row) break;
            if (span.start_col >= off + len or off >= span.end_col) continue;
            if (best == null or outranks(span, best.?)) best = span;
        }
        return if (best) |span| span.kind else null;
    }
};

pub const Cache = struct {
    queries: [language_count]?*treez.Query = @splat(null),

    pub fn deinit(self: *Cache) void {
        for (&self.queries) |*query| {
            if (query.*) |value| value.destroy();
            query.* = null;
        }
    }

    fn get(self: *Cache, language: Language, parser_language: *const treez.Language) !*treez.Query {
        const index = @intFromEnum(language);
        if (self.queries[index]) |query| return query;
        var error_offset: u32 = 0;
        const query = try treez.Query.create(parser_language, querySource(language), &error_offset);
        self.queries[index] = query;
        return query;
    }
};

pub fn load(allocator: mem.Allocator, cache: *Cache, block: Document.Element.CodeBlock) !Highlights {
    if (block.content.len > max_source_bytes) return error.CodeBlockTooLarge;
    const language = languageName(block) orelse return error.NotFound;

    var content: ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var lines = block.lines();
    var first = true;
    while (lines.next()) |line| {
        if (!first) try content.append(allocator, '\n');
        first = false;
        try content.appendSlice(allocator, line);
    }

    const parser_language = try parserLanguage(language);
    const parser = try treez.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(parser_language);
    const tree = try parser.parseString(null, content.items);
    defer tree.destroy();
    const query = try cache.get(language, parser_language);

    const count = try countCaptures(query, tree.getRootNode(), content.items);
    const spans = try allocator.alloc(Span, count);
    errdefer allocator.free(spans);
    try collectCaptures(query, tree.getRootNode(), content.items, spans);
    mem.sort(Span, spans, {}, lessThan);
    return .{ .spans = spans };
}

const Language = enum {
    bash,
    c,
    cpp,
    javascript,
    go,
    json,
    python,
    rust,
    typescript,
    tsx,
    zig,
};

const language_count = @typeInfo(Language).@"enum".fields.len;

fn languageName(block: Document.Element.CodeBlock) ?Language {
    const info = block.info orelse return null;
    if (info.isMermaid()) return null;
    const raw = info.text();
    var end: usize = 0;
    while (end < raw.len and raw[end] != ' ' and raw[end] != '\t') : (end += 1) {}
    const name = raw[0..end];

    if (anyName(name, &.{ "bash", "sh", "shell", "zsh" })) return .bash;
    if (ascii.eqlIgnoreCase(name, "c")) return .c;
    if (anyName(name, &.{ "cpp", "c++", "cc", "cxx" })) return .cpp;
    if (anyName(name, &.{ "javascript", "js", "jsx" })) return .javascript;
    if (anyName(name, &.{ "go", "golang" })) return .go;
    if (ascii.eqlIgnoreCase(name, "json")) return .json;
    if (anyName(name, &.{ "python", "py" })) return .python;
    if (anyName(name, &.{ "rust", "rs" })) return .rust;
    if (anyName(name, &.{ "typescript", "ts" })) return .typescript;
    if (ascii.eqlIgnoreCase(name, "tsx")) return .tsx;
    if (anyName(name, &.{ "zig", "zon" })) return .zig;
    return null;
}

fn anyName(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn parserLanguage(language: Language) !*const treez.Language {
    return switch (language) {
        .bash => treez.Language.get("bash"),
        .c => treez.Language.get("c"),
        .cpp => treez.Language.get("cpp"),
        .javascript => treez.Language.get("javascript"),
        .go => treez.Language.get("go"),
        .json => treez.Language.get("json"),
        .python => treez.Language.get("python"),
        .rust => treez.Language.get("rust"),
        .typescript => treez.Language.get("typescript"),
        .tsx => treez.Language.get("tsx"),
        .zig => treez.Language.get("zig"),
    };
}

fn querySource(language: Language) []const u8 {
    return switch (language) {
        .bash => @embedFile("syntax_bash"),
        .c => @embedFile("syntax_c"),
        .cpp => @embedFile("syntax_c") ++ "\n" ++ @embedFile("syntax_cpp"),
        .javascript => @embedFile("syntax_javascript"),
        .go => @embedFile("syntax_go"),
        .json => @embedFile("syntax_json"),
        .python => @embedFile("syntax_python"),
        .rust => @embedFile("syntax_rust"),
        .typescript, .tsx => @embedFile("syntax_javascript") ++ "\n" ++ @embedFile("syntax_typescript"),
        .zig => @embedFile("syntax_zig"),
    };
}

fn countCaptures(query: *treez.Query, root: treez.Node, source: []const u8) !usize {
    const cursor = try treez.Query.Cursor.create();
    defer cursor.destroy();
    cursor.execute(query, root);
    var count: usize = 0;
    while (cursor.nextMatch()) |match| {
        const evaluation = evaluateMatch(query, match, source);
        if (!evaluation.applies) continue;
        for (match.captures()) |capture| {
            if (kindForScope(query.getCaptureNameForId(capture.id)) == null) continue;
            const range = capture.node.getRange();
            count += range.end_point.row - range.start_point.row + 1;
        }
    }
    return count;
}

fn collectCaptures(query: *treez.Query, root: treez.Node, source: []const u8, spans: []Span) !void {
    const cursor = try treez.Query.Cursor.create();
    defer cursor.destroy();
    cursor.execute(query, root);
    var index: usize = 0;
    while (cursor.nextMatch()) |match| {
        const evaluation = evaluateMatch(query, match, source);
        if (!evaluation.applies) continue;
        for (match.captures()) |capture| {
            const kind = kindForScope(query.getCaptureNameForId(capture.id)) orelse continue;
            const range = capture.node.getRange();
            var row = range.start_point.row;
            while (row <= range.end_point.row) : (row += 1) {
                spans[index] = .{
                    .row = row,
                    .start_col = if (row == range.start_point.row) range.start_point.column else 0,
                    .end_col = if (row == range.end_point.row) range.end_point.column else math.maxInt(u32),
                    .kind = kind,
                    .priority = evaluation.priority,
                    .pattern_index = match.pattern_index,
                };
                index += 1;
            }
        }
    }
}

const Evaluation = struct {
    applies: bool = true,
    priority: i32 = 100,
};

fn evaluateMatch(query: *const treez.Query, match: treez.Query.Match, source: []const u8) Evaluation {
    var evaluation: Evaluation = .{};
    const steps = query.getPredicatesForPattern(match.pattern_index);
    var start: usize = 0;
    while (start < steps.len) {
        var end = start;
        while (end < steps.len and steps[end].type != .done) : (end += 1) {}
        if (!evaluatePredicate(query, match, source, steps[start..end], &evaluation)) {
            evaluation.applies = false;
            return evaluation;
        }
        start = end + 1;
    }
    return evaluation;
}

fn evaluatePredicate(
    query: *const treez.Query,
    match: treez.Query.Match,
    source: []const u8,
    steps: []const treez.Query.PredicateStep,
    evaluation: *Evaluation,
) bool {
    if (steps.len == 0 or steps[0].type != .string) return false;
    const operation = query.getStringValueForId(steps[0].value_id);
    if (mem.eql(u8, operation, "set!")) {
        if (steps.len == 3 and steps[1].type == .string and steps[2].type == .string and
            mem.eql(u8, query.getStringValueForId(steps[1].value_id), "priority"))
        {
            evaluation.priority = fmt.parseInt(i32, query.getStringValueForId(steps[2].value_id), 10) catch evaluation.priority;
        }
        return true;
    }
    if (mem.eql(u8, operation, "eq?")) return evaluateEquality(query, match, source, steps);
    if (mem.eql(u8, operation, "any-of?")) return evaluateAnyOf(query, match, source, steps);
    if (mem.eql(u8, operation, "match?") or mem.eql(u8, operation, "lua-match?")) {
        return evaluatePattern(query, match, source, steps);
    }
    return mem.endsWith(u8, operation, "!");
}

fn evaluateEquality(
    query: *const treez.Query,
    match: treez.Query.Match,
    source: []const u8,
    steps: []const treez.Query.PredicateStep,
) bool {
    if (steps.len != 3 or steps[1].type != .capture or steps[2].type != .string) return false;
    const target = query.getStringValueForId(steps[2].value_id);
    for (match.captures()) |capture| {
        if (capture.id == steps[1].value_id and !mem.eql(u8, nodeText(source, capture.node), target)) return false;
    }
    return true;
}

fn evaluateAnyOf(
    query: *const treez.Query,
    match: treez.Query.Match,
    source: []const u8,
    steps: []const treez.Query.PredicateStep,
) bool {
    if (steps.len < 3 or steps[1].type != .capture) return false;
    for (match.captures()) |capture| {
        if (capture.id != steps[1].value_id) continue;
        const text = nodeText(source, capture.node);
        var present = false;
        for (steps[2..]) |step| {
            if (step.type != .string) return false;
            if (mem.eql(u8, text, query.getStringValueForId(step.value_id))) present = true;
        }
        if (!present) return false;
    }
    return true;
}

fn evaluatePattern(
    query: *const treez.Query,
    match: treez.Query.Match,
    source: []const u8,
    steps: []const treez.Query.PredicateStep,
) bool {
    if (steps.len != 3 or steps[1].type != .capture or steps[2].type != .string) return false;
    const pattern = query.getStringValueForId(steps[2].value_id);
    for (match.captures()) |capture| {
        if (capture.id == steps[1].value_id and !matchesPattern(pattern, nodeText(source, capture.node))) return false;
    }
    return true;
}

fn matchesPattern(pattern: []const u8, text: []const u8) bool {
    if (!mem.startsWith(u8, pattern, "^")) return false;
    var expression = pattern[1..];
    const anchored_end = mem.endsWith(u8, expression, "$");
    if (anchored_end) expression = expression[0 .. expression.len - 1];

    if (expression.len >= 2 and expression[0] == '(' and expression[expression.len - 1] == ')') {
        var alternatives = mem.splitScalar(u8, expression[1 .. expression.len - 1], '|');
        while (alternatives.next()) |alternative| {
            if (mem.eql(u8, text, alternative)) return true;
        }
        return false;
    }

    var pattern_index: usize = 0;
    var text_index: usize = 0;
    while (pattern_index < expression.len) {
        if (expression[pattern_index] != '[') {
            if (text_index >= text.len or expression[pattern_index] != text[text_index]) return false;
            pattern_index += 1;
            text_index += 1;
            continue;
        }
        const class_end = pattern_index + 1 +
            (mem.indexOfScalar(u8, expression[pattern_index + 1 ..], ']') orelse return false);
        const class = expression[pattern_index + 1 .. class_end];
        pattern_index = class_end + 1;
        const quantifier: u8 = if (pattern_index < expression.len and
            (expression[pattern_index] == '*' or expression[pattern_index] == '+'))
        blk: {
            const value = expression[pattern_index];
            pattern_index += 1;
            break :blk value;
        } else 0;
        var matched: usize = 0;
        while (text_index < text.len and classContains(class, text[text_index])) {
            text_index += 1;
            matched += 1;
            if (quantifier == 0) break;
        }
        if ((quantifier == '+' and matched == 0) or (quantifier == 0 and matched != 1)) return false;
    }
    return !anchored_end or text_index == text.len;
}

fn classContains(class: []const u8, value: u8) bool {
    var index: usize = 0;
    while (index < class.len) {
        if (index + 1 < class.len and class[index] == '\\' and class[index + 1] == 'd') {
            if (ascii.isDigit(value)) return true;
            index += 2;
            continue;
        }
        if (index + 2 < class.len and class[index + 1] == '-') {
            if (value >= class[index] and value <= class[index + 2]) return true;
            index += 3;
            continue;
        }
        if (class[index] == value) return true;
        index += 1;
    }
    return false;
}

fn nodeText(source: []const u8, node: treez.Node) []const u8 {
    const start = node.getStartByte();
    const end = node.getEndByte();
    if (start > end or end > source.len) return "";
    return source[start..end];
}

fn kindForScope(raw_scope: []const u8) ?Kind {
    const scope = if (mem.startsWith(u8, raw_scope, "@")) raw_scope[1..] else raw_scope;
    const end = mem.indexOfScalar(u8, scope, '.') orelse scope.len;
    const root = scope[0..end];
    if (mem.eql(u8, root, "comment")) return .comment;
    if (mem.eql(u8, root, "string") or mem.eql(u8, root, "character")) return .string;
    if (mem.eql(u8, root, "number") or mem.eql(u8, root, "boolean") or
        mem.eql(u8, root, "constant") or mem.eql(u8, root, "float")) return .constant;
    if (mem.eql(u8, root, "keyword") or mem.eql(u8, root, "operator") or
        mem.eql(u8, root, "conditional") or mem.eql(u8, root, "repeat")) return .keyword;
    if (mem.eql(u8, root, "function") or mem.eql(u8, root, "method")) return .function;
    if (mem.eql(u8, root, "type") or mem.eql(u8, root, "constructor") or
        mem.eql(u8, root, "tag")) return .type;
    return null;
}

fn lessThan(_: void, left: Span, right: Span) bool {
    if (left.row != right.row) return left.row < right.row;
    return left.start_col < right.start_col;
}

fn outranks(candidate: Span, current: Span) bool {
    return candidate.priority > current.priority or
        (candidate.priority == current.priority and candidate.pattern_index >= current.pattern_index);
}

const std = @import("std");
const ascii = std.ascii;
const ArrayList = std.ArrayList;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;
const Document = @import("../Document.zig");
const treez = @import("treez");

test "loads Zig highlights" {
    const allocator = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit();
    var highlights = try load(allocator, &cache, .{
        .info = .{ .other = "zig" },
        .content = "pub const answer = 42; // value\nconst text = \"hi\"; // note\n",
    });
    defer highlights.deinit(allocator);

    try testing.expectEqual(Kind.keyword, highlights.kindAt(0, 0, 3).?);
    try testing.expectEqual(Kind.constant, highlights.kindAt(0, 19, 2).?);
    try testing.expectEqual(Kind.comment, highlights.kindAt(0, 23, 8).?);
    try testing.expectEqual(Kind.string, highlights.kindAt(1, 13, 4).?);
    try testing.expectEqual(Kind.comment, highlights.kindAt(1, 19, 7).?);
}

test "supported languages produce captures" {
    const cases = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "bash", .source = "echo \"hi\"" },
        .{ .name = "c", .source = "const int answer = 42;" },
        .{ .name = "cpp", .source = "class Answer {};" },
        .{ .name = "javascript", .source = "const answer = 42;" },
        .{ .name = "go", .source = "func answer() int { return 42 }" },
        .{ .name = "json", .source = "{\"answer\": 42}" },
        .{ .name = "python", .source = "def answer(): return 42" },
        .{ .name = "rust", .source = "fn answer() -> i32 { 42 }" },
        .{ .name = "typescript", .source = "const answer: number = 42;" },
        .{ .name = "tsx", .source = "const value = <div>hi</div>;" },
    };
    const allocator = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit();
    for (cases) |case| {
        var highlights = try load(allocator, &cache, .{
            .info = .{ .other = case.name },
            .content = case.source,
        });
        defer highlights.deinit(allocator);
        try testing.expect(highlights.spans.len > 0);
    }
}

test "unknown languages fail without highlights" {
    const allocator = testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit();
    try testing.expectError(error.NotFound, load(allocator, &cache, .{
        .info = .{ .other = "not-a-language" },
        .content = "plain text",
    }));
}

test "normalizes common fence aliases" {
    try testing.expectEqual(Language.javascript, languageName(.{
        .info = .{ .other = "js title=example" },
        .content = "",
    }).?);
    try testing.expectEqual(Language.cpp, languageName(.{
        .info = .{ .other = "C++" },
        .content = "",
    }).?);
    try testing.expect(languageName(.{ .info = null, .content = "" }) == null);
}

test "matches supported query patterns" {
    try testing.expect(matchesPattern("^[A-Z][A-Z_0-9]+$", "HTTP_2"));
    try testing.expect(!matchesPattern("^[A-Z][A-Z_0-9]+$", "Http"));
    try testing.expect(matchesPattern("^(console|window|document)$", "window"));
    try testing.expect(matchesPattern("^//!", "//! docs"));
}

const testing = std.testing;
