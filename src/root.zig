//! mdr: a zero-copy, lazily parsed Markdown library.
//!
//! Entry point is `Document`: `parse` builds one from any `std.Io.Reader`,
//! `init` borrows text already in memory.

pub const Document = @import("Document.zig");

const std = @import("std");

test {
    _ = Document;
    std.testing.refAllDecls(Document);
}
