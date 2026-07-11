//! Intrinsic measurement and containing-size resolution primitives.

const box = @import("../box.zig");
const font = @import("../font.zig");

pub fn resolveContentDimension(length: box.Length, reference: f32, non_content: f32, sizing: box.BoxSizing) ?f32 {
    const resolved = length.resolve(reference) orelse return null;
    return switch (sizing) {
        .contentBox => @max(resolved, 0),
        .borderBox => @max(resolved - non_content, 0),
    };
}

pub fn measureText(
    registry: ?*const font.Registry,
    text: []const u8,
    family: []const u8,
    font_size: f32,
    weight: box.FontWeight,
    style: box.FontStyle,
    letter_spacing: f32,
) f32 {
    const metrics = font.resolve(registry, family, weight, style).metrics();
    var iterator = font.Utf8Iterator{ .bytes = text };
    var glyph_count: usize = 0;
    while (iterator.next() catch null) |_| glyph_count += 1;
    return (metrics.widthCssPx(text, font_size) catch 0) + letter_spacing * @as(f32, @floatFromInt(glyph_count));
}
