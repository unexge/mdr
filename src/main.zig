//! mdr TUI: opens a markdown file and scrolls it in the terminal.

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const stdin = Io.File.stdin();
    const stdin_is_tty = stdin.isTty(io) catch false;
    const input = resolveInput(args, stdin_is_tty) orelse {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        try stderr_writer.interface.writeAll("usage: mdr <file>\n       mdr - | <cmd> | mdr\n");
        try stderr_writer.interface.flush();
        return;
    };

    switch (input) {
        .file => |path| {
            const file = try Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);

            var reader_buffer: [4096]u8 = undefined;
            var file_reader: Io.File.Reader = .init(file, io, &reader_buffer);

            var doc = try mdr.Document.parse(&file_reader.interface, arena);
            defer doc.deinit();

            var app = mdr.ui.initFile(init.gpa, &doc, path);
            defer app.deinit();

            try app.run(io, init.environ_map);
        },
        .stdin => {
            var reader_buffer: [4096]u8 = undefined;
            var stdin_reader: Io.File.Reader = .initStreaming(stdin, io, &reader_buffer);

            var doc = try mdr.Document.parse(&stdin_reader.interface, arena);
            defer doc.deinit();

            var app = mdr.ui.init(init.gpa, &doc);
            defer app.deinit();

            try app.run(io, init.environ_map);
        },
    }
}

const Input = union(enum) {
    file: []const u8,
    stdin,
};

fn resolveInput(args: []const [:0]const u8, stdin_is_tty: bool) ?Input {
    if (args.len >= 2) {
        if (mem.eql(u8, args[1], "-")) return .stdin;
        return .{ .file = args[1] };
    }
    if (stdin_is_tty) return null;
    return .stdin;
}

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const mdr = @import("mdr");

test resolveInput {
    const t = std.testing;
    const prog: [:0]const u8 = "mdr";
    const file: [:0]const u8 = "notes.md";
    const dash: [:0]const u8 = "-";

    const file_args = [_][:0]const u8{ prog, file };
    try t.expectEqualStrings(file, resolveInput(&file_args, true).?.file);
    try t.expectEqualStrings(file, resolveInput(&file_args, false).?.file);

    const dash_args = [_][:0]const u8{ prog, dash };
    try t.expect(resolveInput(&dash_args, true).? == .stdin);
    try t.expect(resolveInput(&dash_args, false).? == .stdin);

    const bare_args = [_][:0]const u8{prog};
    try t.expect(resolveInput(&bare_args, true) == null);
    try t.expect(resolveInput(&bare_args, false).? == .stdin);
}

test {
    _ = mdr;
}
