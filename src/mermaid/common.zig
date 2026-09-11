pub const Direction = enum { tb, bt, lr, rl };

pub fn feedLines(parser: anytype, text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        const newline = mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        parser.feed(rest[0..newline]);
        rest = if (newline < rest.len) rest[newline + 1 ..] else "";
    }
}

pub fn isComment(line: []const u8) bool {
    return mem.startsWith(u8, line, "%%") and !mem.startsWith(u8, line, "%%{");
}

pub fn isConfigDirective(line: []const u8) bool {
    return mem.startsWith(u8, line, "%%{") and mem.endsWith(u8, line, "}%%");
}

pub fn parseDirection(raw: []const u8) ?Direction {
    const direction = mem.trim(u8, raw, " \t\r");
    if (eqlIgnoreCase(direction, "TD") or eqlIgnoreCase(direction, "TB")) return .tb;
    if (eqlIgnoreCase(direction, "BT")) return .bt;
    if (eqlIgnoreCase(direction, "LR")) return .lr;
    if (eqlIgnoreCase(direction, "RL")) return .rl;
    return null;
}

pub fn metadataValue(raw: []const u8) ?[]const u8 {
    const value = mem.trim(u8, raw, " \t\r");
    if (value.len == 0) return null;
    if (value[0] != '"') return value;
    if (value.len < 2 or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

pub fn stripKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (line.len < keyword.len or !eqlIgnoreCase(line[0..keyword.len], keyword)) return null;
    if (line.len > keyword.len and line[keyword.len] != ' ' and line[keyword.len] != '\t') return null;
    return mem.trim(u8, line[keyword.len..], " \t");
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |actual, expected| {
        if (ascii.toLower(actual) != ascii.toLower(expected)) return false;
    }
    return true;
}

const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
