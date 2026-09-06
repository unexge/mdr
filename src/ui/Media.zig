pub const SourceKind = enum {
    local,
    remote,
    unsupported,
};

pub const Dimensions = struct {
    width: u16,
    height: u16,
};

pub const Sizing = enum {
    fit,
    width,
};

pub fn classify(source: []const u8) SourceKind {
    if (mem.startsWith(u8, source, "http://") or
        mem.startsWith(u8, source, "https://") or
        mem.startsWith(u8, source, "//"))
    {
        return .remote;
    }
    if (mem.startsWith(u8, source, "file:///")) return .local;
    if (path.isAbsolute(source)) return .local;
    if (mem.indexOfScalar(u8, source, ':') != null) return .unsupported;
    return .local;
}

pub fn resolveLocal(gpa: mem.Allocator, base_dir: []const u8, source: []const u8) ![]u8 {
    const local = if (mem.startsWith(u8, source, "file:///"))
        source["file://".len..]
    else
        source;
    if (path.isAbsolute(local)) return gpa.dupe(u8, local);
    return path.resolve(gpa, &.{ base_dir, local });
}

/// A PNG raster prepared off the UI thread for terminal transmission.
pub const Artifact = struct {
    payload: []u8,
    width: u16,
    height: u16,

    pub fn fromPng(gpa: mem.Allocator, png: []const u8, width: u16, height: u16) !Artifact {
        const encoder = base64.standard.Encoder;
        const payload_size = encoder.calcSize(png.len);
        if (payload_size > max_payload_size) return error.ImageTooLarge;
        const payload = try gpa.alloc(u8, payload_size);
        errdefer gpa.free(payload);
        _ = encoder.encode(payload, png);
        return .{ .payload = payload, .width = width, .height = height };
    }

    pub fn deinit(self: *Artifact, gpa: mem.Allocator) void {
        gpa.free(self.payload);
        self.* = undefined;
    }
};

pub const State = union(enum) {
    idle,
    loading,
    ready: vaxis.Image,
    remote,
    unsupported,
    failed,

    pub fn init(source: []const u8) State {
        return switch (classify(source)) {
            .local => .idle,
            .remote => .remote,
            .unsupported => .unsupported,
        };
    }
};

pub fn loadLocal(
    io: Io,
    gpa: mem.Allocator,
    file_path: []const u8,
    target_width: u16,
    max_height: u16,
    sizing: Sizing,
) !Artifact {
    var read_buffer: [64 * 1024]u8 = undefined;
    var decoded = try vaxis.zigimg.Image.fromFilePath(gpa, io, file_path, &read_buffer);
    defer decoded.deinit(gpa);

    if (decoded.width == 0 or decoded.height == 0 or
        decoded.width > math.maxInt(u16) or decoded.height > math.maxInt(u16))
    {
        return error.InvalidImageDimensions;
    }
    const pixels = math.mul(usize, decoded.width, decoded.height) catch return error.ImageTooLarge;
    if (pixels > 4 * 1024 * 1024) return error.ImageTooLarge;

    const dimensions = switch (sizing) {
        .fit => fitDimensions(
            @intCast(decoded.width),
            @intCast(decoded.height),
            target_width,
            max_height,
        ),
        .width => dimensionsForWidth(
            @intCast(decoded.width),
            @intCast(decoded.height),
            target_width,
            max_height,
        ),
    };
    const output_pixels = math.mul(usize, dimensions.width, dimensions.height) catch return error.ImageTooLarge;
    if (output_pixels > 4 * 1024 * 1024) return error.ImageTooLarge;
    var resized: ?vaxis.zigimg.Image = null;
    defer if (resized) |*image| image.deinit(gpa);
    const output_image: *vaxis.zigimg.Image = if (dimensions.width != decoded.width or dimensions.height != decoded.height) image: {
        try decoded.convert(gpa, .rgba32);
        var smaller = try vaxis.zigimg.Image.create(gpa, dimensions.width, dimensions.height, .rgba32);
        errdefer smaller.deinit(gpa);
        for (0..dimensions.height) |y| {
            const source_y = y * decoded.height / dimensions.height;
            for (0..dimensions.width) |x| {
                const source_x = x * decoded.width / dimensions.width;
                smaller.pixels.rgba32[y * dimensions.width + x] =
                    decoded.pixels.rgba32[source_y * decoded.width + source_x];
            }
        }
        resized = smaller;
        break :image &resized.?;
    } else &decoded;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const raw_size = output_image.imageByteSize();
    const output_size = math.add(usize, raw_size, raw_size / 8 + 4096) catch return error.ImageTooLarge;
    const output_buffer = try arena.allocator().alloc(u8, output_size);
    const png = try output_image.writeToMemory(arena.allocator(), output_buffer, .{ .png = .{} });
    return Artifact.fromPng(gpa, png, dimensions.width, dimensions.height);
}

pub fn fitDimensions(width: u16, height: u16, max_width: u16, max_height: u16) Dimensions {
    const bound_width = @max(1, max_width);
    const bound_height = @max(1, max_height);
    if (width <= bound_width and height <= bound_height) return .{ .width = width, .height = height };

    if (@as(u64, width) * bound_height > @as(u64, height) * bound_width) {
        return .{
            .width = bound_width,
            .height = @intCast(@max(1, (@as(u64, height) * bound_width + width / 2) / width)),
        };
    }
    return .{
        .width = @intCast(@max(1, (@as(u64, width) * bound_height + height / 2) / height)),
        .height = bound_height,
    };
}

pub fn dimensionsForWidth(width: u16, height: u16, target_width: u16, max_height: u16) Dimensions {
    const output_width = @max(1, target_width);
    const bound_height = @max(1, max_height);
    const output_height = @max(1, (@as(u64, height) * output_width + width / 2) / width);
    if (output_height <= bound_height) {
        return .{ .width = output_width, .height = @intCast(output_height) };
    }
    return .{
        .width = @intCast(@max(1, (@as(u64, width) * bound_height + height / 2) / height)),
        .height = bound_height,
    };
}

pub fn rowsForSize(image_width: u16, image_height: u16, cols: usize, cell_width: usize, cell_height: usize) usize {
    if (image_width == 0 or image_height == 0 or cols == 0 or cell_width == 0 or cell_height == 0) return 1;
    const rendered_width = @as(u64, cols) * cell_width;
    const rendered_height = (@as(u64, image_height) * rendered_width + image_width - 1) / image_width;
    const rows = (rendered_height + cell_height - 1) / cell_height;
    return @intCast(@max(1, @min(math.maxInt(u16), rows)));
}

const std = @import("std");
const base64 = std.base64;
const Io = std.Io;
const math = std.math;
const mem = std.mem;
const path = std.fs.path;
const vaxis = @import("vaxis");
const max_payload_size = 4 * 1024 * 1024;

test "classifies remote and local image sources" {
    try testing.expectEqual(SourceKind.remote, classify("https://example.com/image.png"));
    try testing.expectEqual(SourceKind.remote, classify("//example.com/image.png"));
    try testing.expectEqual(SourceKind.local, classify("images/image.png"));
    try testing.expectEqual(SourceKind.local, classify("/tmp/image.png"));
    try testing.expectEqual(SourceKind.local, classify("file:///tmp/image.png"));
    try testing.expectEqual(SourceKind.unsupported, classify("data:image/png;base64,abc"));
}

test "resolves local sources against the document directory" {
    const relative = try resolveLocal(testing.allocator, "/docs/guide", "images/image.png");
    defer testing.allocator.free(relative);
    try testing.expectEqualStrings("/docs/guide/images/image.png", relative);

    const file_url = try resolveLocal(testing.allocator, "/ignored", "file:///tmp/image.png");
    defer testing.allocator.free(file_url);
    try testing.expectEqualStrings("/tmp/image.png", file_url);
}

test "prepares PNG output as a reusable raster artifact" {
    var artifact = try Artifact.fromPng(testing.allocator, "\x89PNG", 10, 20);
    defer artifact.deinit(testing.allocator);

    try testing.expectEqualStrings("iVBORw==", artifact.payload);
    try testing.expectEqual(@as(u16, 10), artifact.width);
    try testing.expectEqual(@as(u16, 20), artifact.height);
}

test "sizes raster output to terminal cells at the requested width" {
    try testing.expectEqual(@as(usize, 10), rowsForSize(800, 400, 40, 10, 20));
    try testing.expectEqual(@as(usize, 40), rowsForSize(800, 1600, 40, 10, 20));
    try testing.expectEqual(@as(usize, 1), rowsForSize(800, 1, 40, 10, 20));
}

test "fits large rasters to their terminal pixel bounds" {
    try testing.expectEqual(
        Dimensions{ .width = 569, .height = 320 },
        fitDimensions(1920, 1080, 1000, 320),
    );
    try testing.expectEqual(
        Dimensions{ .width = 320, .height = 568 },
        fitDimensions(1080, 1920, 1000, 568),
    );
    try testing.expectEqual(
        Dimensions{ .width = 100, .height = 50 },
        fitDimensions(100, 50, 1000, 320),
    );
}

test "sizes rasters to an exact target width" {
    try testing.expectEqual(
        Dimensions{ .width = 200, .height = 100 },
        dimensionsForWidth(100, 50, 200, 320),
    );
    try testing.expectEqual(
        Dimensions{ .width = 160, .height = 320 },
        dimensionsForWidth(100, 200, 200, 320),
    );
}

test "loads and resizes a local image raster" {
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP4z8DwHxkzoAsAAA8hD/EEN8afAAAAAElFTkSuQmCC";
    var png: [base64.standard.Decoder.calcSizeForSlice(encoded) catch unreachable]u8 = undefined;
    try base64.standard.Decoder.decode(&png, encoded);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pixel.png", .data = &png });
    var file_path_buffer: [128]u8 = undefined;
    const file_path = try fmt.bufPrint(&file_path_buffer, ".zig-cache/tmp/{s}/pixel.png", .{tmp.sub_path});

    var artifact = try loadLocal(testing.io, testing.allocator, file_path, 2, 2, .fit);
    defer artifact.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 2), artifact.width);
    try testing.expectEqual(@as(u16, 1), artifact.height);
    try testing.expect(artifact.payload.len > 0);
}

const fmt = std.fmt;
const testing = std.testing;
