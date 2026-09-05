//! mdr: a zero-copy, lazily parsed Markdown library.
//!
//! Entry point is `Document`: `parse` builds one from any `std.Io.Reader`,
//! `init` borrows text already in memory. `ui` is a libvaxis terminal UI
//! that lazily renders a `Document`.

pub const Document = @import("Document.zig");
pub const ui = @import("ui/App.zig");

const std = @import("std");

test {
    _ = Document;
    _ = ui;
    std.testing.refAllDecls(Document);
}
