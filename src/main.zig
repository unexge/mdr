//! mdr TUI: opens a markdown file and scrolls it in the terminal.

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        try stderr_writer.interface.writeAll("usage: mdr <file>\n");
        try stderr_writer.interface.flush();
        return;
    }

    const file = try Io.Dir.cwd().openFile(io, args[1], .{});
    defer file.close(io);

    var reader_buffer: [4096]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &reader_buffer);

    var doc = try mdr.Document.parse(&file_reader.interface, arena);
    defer doc.deinit();

    var app = mdr.ui.init(init.gpa, &doc);
    defer app.deinit();

    try app.run(io, init.environ_map);
}

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const mdr = @import("mdr");

test {
    _ = mdr;
}
