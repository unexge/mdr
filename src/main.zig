//! Demo CLI: parses stdin (or a file given as the first argument) and prints
//! each block-level element with its inline spans.

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var reader_buffer: [4096]u8 = undefined;
    var file_reader: Io.File.Reader = undefined;
    if (args.len > 1) {
        const file = try Io.Dir.cwd().openFile(io, args[1], .{});
        file_reader = .init(file, io, &reader_buffer);
    } else {
        file_reader = .init(.stdin(), io, &reader_buffer);
    }

    var doc = try mdr.Document.parse(&file_reader.interface, arena);
    defer doc.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    while (doc.next()) |elem| {
        switch (elem) {
            .header => |h| {
                try stdout.print("header h{d}: \"{s}\"\n", .{ h.level, h.content });
                try printSpans(stdout, h.spans());
            },
            .paragraph => |p| {
                try stdout.print("paragraph: \"{s}\"\n", .{p.content});
                try printSpans(stdout, p.spans());
            },
            .code_block => |cb| {
                if (cb.info) |info| {
                    try stdout.print("code_block [{s}]: \"{s}\"\n", .{ info, cb.content });
                } else {
                    try stdout.print("code_block: \"{s}\"\n", .{cb.content});
                }
            },
            .thematic_break => try stdout.print("thematic_break\n", .{}),
        }
    }

    try stdout.flush();
}

fn printSpans(stdout: *Io.Writer, spans: mdr.Document.Spans) !void {
    var it = spans;
    while (it.next()) |span| {
        switch (span) {
            inline else => |content, tag| try stdout.print("  {s}: \"{s}\"\n", .{ @tagName(tag), content }),
        }
    }
}

const std = @import("std");
const Io = std.Io;
const mdr = @import("mdr");

test {
    _ = mdr;
}
