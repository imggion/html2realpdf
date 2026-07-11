//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const html = @import("html.zig");
pub const dom = @import("dom.zig");
pub const box = @import("box.zig");
pub const css = @import("css.zig");
pub const geometry = @import("geometry.zig");
pub const image = @import("image.zig");
pub const font = @import("font.zig");
pub const layout = @import("layout.zig");
pub const pagination = @import("pagination.zig");
pub const display_list = @import("display_list.zig");
pub const pdf = @import("pdf.zig");
pub const render = @import("render.zig");

/// Writes the native executable identity without coupling library modules to
/// process stdout.
pub fn writeBanner(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll("html2realpdf 0.1.0-alpha.0\n");
}
