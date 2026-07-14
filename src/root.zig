//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const harfbuzz_runtime = @import("harfbuzz.zig");
const bidi_runtime = @import("bidi.zig");

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
pub const build_info = @import("build_info");

/// Retains allocator exports required by native C objects even when a small
/// executable uses only the package banner and the linker sees no render call.
pub fn retainNativeRuntimeSymbols() void {
    std.mem.doNotOptimizeAway(&harfbuzz_runtime.html2realpdf_hb_malloc);
    std.mem.doNotOptimizeAway(&harfbuzz_runtime.html2realpdf_hb_calloc);
    std.mem.doNotOptimizeAway(&harfbuzz_runtime.html2realpdf_hb_realloc);
    std.mem.doNotOptimizeAway(&harfbuzz_runtime.html2realpdf_hb_free);
    std.mem.doNotOptimizeAway(&bidi_runtime.html2realpdf_sb_malloc);
    std.mem.doNotOptimizeAway(&bidi_runtime.html2realpdf_sb_realloc);
    std.mem.doNotOptimizeAway(&bidi_runtime.html2realpdf_sb_free);
}

/// Writes the native executable identity without coupling library modules to
/// process stdout.
pub fn writeBanner(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print(
        "{s} v{s}\nAuthor: {s}\n",
        .{
            build_info.name,
            build_info.version,
            build_info.author,
        },
    );
}
