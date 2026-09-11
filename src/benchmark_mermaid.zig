pub fn main(init: std.process.Init) void {
    const io = init.io;
    const cases = [_]Case{
        .{ .name = "flowchart-120-edges", .content = "graph TD\n" ++ ("A-->B\n" ** 120) },
        .{ .name = "flowchart-over-cap-tail", .content = "graph TD\n" ++ ("A-->B\n" ** 2000) },
        .{ .name = "sequence-96-messages", .content = "sequenceDiagram\n" ++ ("A->>B: message\n" ** 96) },
        .{ .name = "class-120-relations", .content = "classDiagram\n" ++ ("A --> B\n" ** 120) },
        .{
            .name = "state-nested-regions",
            .content = "stateDiagram-v2\n" ++
                "state Active {\n" ++
                "direction LR\n" ++
                "[*] --> Ready\n" ++
                "Ready --> Running\n" ++
                "Running --> Ready\n" ++
                "--\n" ++
                "[*] --> Waiting\n" ++
                "state Waiting {\n" ++
                "[*] --> Pending\n" ++
                "Pending --> [*]\n" ++
                "}\n" ++
                "}\n",
        },
    };

    std.debug.print("Mermaid benchmark ({s}, {d} iterations)\n", .{ @tagName(builtin.mode), iterations });
    for (cases) |case| {
        for (0..warmup_iterations) |_| {
            mem.doNotOptimizeAway(parse(case.content));
            mem.doNotOptimizeAway(measure(case.content));
        }
        const parse_start = Io.Clock.awake.now(io);
        for (0..iterations) |_| mem.doNotOptimizeAway(parse(case.content));
        const parse_elapsed = parse_start.durationTo(Io.Clock.awake.now(io)).nanoseconds;

        const layout_start = Io.Clock.awake.now(io);
        for (0..iterations) |_| mem.doNotOptimizeAway(measure(case.content));
        const layout_elapsed = layout_start.durationTo(Io.Clock.awake.now(io)).nanoseconds;

        std.debug.print("{s}: parse {d} ns/op, parse+layout {d} ns/op\n", .{
            case.name,
            @divTrunc(parse_elapsed, iterations),
            @divTrunc(layout_elapsed, iterations),
        });
    }
}

const iterations = 1000;
const warmup_iterations = 20;
const width = 256;

const Case = struct {
    name: []const u8,
    content: []const u8,
};

fn parse(content: []const u8) ?Mermaid.Parsed {
    return Mermaid.parseAnyBlock(.{ .info = .{ .mermaid = "mermaid" }, .content = content });
}

fn measure(content: []const u8) usize {
    const parsed = parse(content) orelse return 0;
    return switch (parsed) {
        .flowchart => |flow| flowchart.layout(null, &flow, 0, 0, width) orelse 0,
        .sequence => |diagram| sequence.layout(null, &diagram, 0, 0, width) orelse 0,
        .structural => |diagram| structural.layout(null, &diagram, 0, 0, width) orelse 0,
    };
}

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const mem = std.mem;
const Mermaid = @import("Mermaid.zig");
const flowchart = @import("ui/renderer/mermaid.zig");
const sequence = @import("ui/renderer/sequence.zig");
const structural = @import("ui/renderer/structural.zig");
