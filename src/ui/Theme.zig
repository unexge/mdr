//! Default theme: ayu-dark palette.

pub const muted: vaxis.Color = .{ .rgb = .{ 0x62, 0x6a, 0x73 } };
pub const success: vaxis.Color = .{ .rgb = .{ 0xaa, 0xd9, 0x4c } };
pub const code: vaxis.Color = .{ .rgb = .{ 0x59, 0xc2, 0xff } };
pub const link: vaxis.Color = .{ .rgb = .{ 0x39, 0xba, 0xe6 } };
pub const panel: vaxis.Color = .{ .rgb = .{ 0x13, 0x17, 0x21 } };
pub const accent: vaxis.Color = .{ .rgb = .{ 0xff, 0x8f, 0x40 } };
pub const gold: vaxis.Color = .{ .rgb = .{ 0xff, 0xb4, 0x54 } };
pub const violet: vaxis.Color = .{ .rgb = .{ 0xd2, 0xa6, 0xff } };

const vaxis = @import("vaxis");
