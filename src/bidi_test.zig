const std = @import("std");
const bidi = @import("bidi.zig");

test "resolve mixed LTR Hebrew and numeric runs in visual order" {
    const allocator = std.testing.allocator;
    const text = "abc אבג 123";
    var resolution = try bidi.resolve(allocator, text, .auto_ltr);
    defer resolution.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), resolution.base_level);
    try std.testing.expectEqual(@as(usize, 3), resolution.visual_runs.len);
    try std.testing.expectEqual(bidi.Run{ .start = 0, .end = 4, .level = 0 }, resolution.visual_runs[0]);
    try std.testing.expectEqual(bidi.Run{ .start = 11, .end = 14, .level = 2 }, resolution.visual_runs[1]);
    try std.testing.expectEqual(bidi.Run{ .start = 4, .end = 11, .level = 1 }, resolution.visual_runs[2]);
}

test "explicit RTL base keeps embedded Latin phrase LTR" {
    const allocator = std.testing.allocator;
    const text = "שלום hello עולם";
    var resolution = try bidi.resolve(allocator, text, .rtl);
    defer resolution.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), resolution.base_level);
    try std.testing.expect(resolution.visual_runs.len >= 3);
    var saw_ltr = false;
    var saw_rtl = false;
    for (resolution.visual_runs) |run| {
        saw_ltr = saw_ltr or run.direction() == .ltr;
        saw_rtl = saw_rtl or run.direction() == .rtl;
    }
    try std.testing.expect(saw_ltr and saw_rtl);
}
