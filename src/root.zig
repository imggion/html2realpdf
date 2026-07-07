//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const html = @import("html.zig");
pub const dom = @import("dom.zig");
pub const box = @import("box.zig");
pub const css = @import("css.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}
