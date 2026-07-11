const std = @import("std");
const harfbuzz = @import("harfbuzz.zig");

test "HarfBuzz shapes OpenType ligatures into positioned UTF-8 clusters" {
    const allocator = std.testing.allocator;
    const text = "office";
    const shaped = try harfbuzz.shape(
        allocator,
        @embedFile("assets/fonts/NotoSans-Regular.ttf"),
        1000,
        text,
        .ltr,
    );
    defer allocator.free(shaped.glyphs);

    try std.testing.expect(shaped.glyphs.len < text.len);
    var found_ligature_cluster = false;
    for (shaped.glyphs) |glyph| {
        try std.testing.expect(glyph.cluster_end <= text.len);
        if (glyph.cluster_end - glyph.cluster_start > 1) found_ligature_cluster = true;
    }
    try std.testing.expect(found_ligature_cluster);
}

test "HarfBuzz shapes built-in Arabic and Hebrew fallbacks right-to-left" {
    const allocator = std.testing.allocator;
    const samples = .{
        .{ @embedFile("assets/fonts/NotoSansArabic-Regular.ttf"), "مرحبا" },
        .{ @embedFile("assets/fonts/NotoSansHebrew-Regular.ttf"), "שלום" },
    };
    inline for (samples) |sample| {
        const shaped = try harfbuzz.shape(allocator, sample[0], 1000, sample[1], .rtl);
        defer allocator.free(shaped.glyphs);
        try std.testing.expect(shaped.glyphs.len > 0);
        for (shaped.glyphs) |glyph| try std.testing.expect(glyph.glyph_id != 0);
        try std.testing.expect(shaped.glyphs[0].cluster_start > shaped.glyphs[shaped.glyphs.len - 1].cluster_start);
    }
}
