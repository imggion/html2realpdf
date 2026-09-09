//! Native PDF/A fixtures use the production HarfBuzz, bidi and line-break engines.
const std = @import("std");
const render = @import("render.zig");
const font = @import("font.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const shaped = try font.shapeWithMode(allocator, font.resolve(null, "Noto Sans", .normal, .normal), "office", .ltr, .harfbuzz);
    if (shaped.glyphs.len >= 6) return error.HarfBuzzNotActive;
    const html = "<article style='font-family:Noto Sans;padding:24px;color:#203040'>" ++
        "<h1>Native archival report</h1><p>office affinity caffè a\u{301} q\u{301}</p>" ++
        "<p style='direction:rtl'>مرحبا بالعالم</p><p style='direction:rtl'>שלום עולם</p>" ++
        "<p><a href='https://example.com'>Reference</a></p>" ++
        "<div style='opacity:.6;background:#daeaff;padding:18px'><div style='opacity:.7'>Transparent text</div></div></article>";
    var options = render.Options{
        .css_profile = .web,
        .margins_points = .{ .bottom = 36 },
        .conformance = .@"pdfa-3u",
        .metadata = .{ .title = "Fattura & archivio", .author = "Test", .subject = "Unicode <test>", .keywords = "PDF, archivio", .creator = "Native fixture" },
    };
    // Margin content participates in the writer Unicode checks.
    options.margin_boxes = &.{.{ .name = .bottom_center, .content = "Archivio {{page}} / {{pages}}" }};
    var result = try render.renderHtml(allocator, html, options);
    defer result.deinit(allocator);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "tmp/pdfa/native-shaping.pdf", .data = result.bytes });
    options.conformance = null;
    var ordinary = try render.renderHtml(allocator, html, options);
    defer ordinary.deinit(allocator);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "tmp/pdfa/native-ordinary.pdf", .data = ordinary.bytes });
}
