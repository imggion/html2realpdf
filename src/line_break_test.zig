const std = @import("std");
const line_break = @import("line_break.zig");

test "CJK breaks between ideographs but not before closing punctuation" {
    const allocator = std.testing.allocator;
    const text = "日本語、テスト";
    const breaks = try line_break.opportunities(allocator, text, null);
    defer allocator.free(breaks);

    try std.testing.expect(breaks["日".len - 1].permitsBreak());
    try std.testing.expect(!breaks["日本語".len - 1].permitsBreak());
    try std.testing.expect(breaks[text.len - 1].permitsBreak());
}

test "combining sequence and emoji ZWJ remain unbroken" {
    const allocator = std.testing.allocator;
    const text = "a\u{301}b 👩‍💻 ok";
    const breaks = try line_break.opportunities(allocator, text, null);
    defer allocator.free(breaks);

    try std.testing.expect(!breaks[0].permitsBreak());
    const emoji_start = std.mem.indexOf(u8, text, "👩").?;
    const emoji_end = emoji_start + "👩‍💻".len;
    for (breaks[emoji_start .. emoji_end - 1]) |opportunity| {
        try std.testing.expect(!opportunity.permitsBreak());
    }
}

test "extended grapheme boundaries keep combining marks and emoji ZWJ together" {
    const allocator = std.testing.allocator;
    const text = "a\u{301}b👩‍💻c";
    const boundaries = try line_break.graphemeBoundaries(allocator, text);
    defer allocator.free(boundaries);

    try std.testing.expect(!boundaries[0]);
    try std.testing.expect(boundaries["a\u{301}".len - 1]);
    const emoji_start = "a\u{301}b".len;
    for (boundaries[emoji_start .. emoji_start + "👩‍💻".len - 1]) |boundary| {
        try std.testing.expect(!boundary);
    }
    try std.testing.expect(boundaries[emoji_start + "👩‍💻".len - 1]);
}

test "word boundaries preserve letters within words and separate whitespace" {
    const allocator = std.testing.allocator;
    const text = "hello world";
    const boundaries = try line_break.wordBoundaries(allocator, text, null);
    defer allocator.free(boundaries);

    try std.testing.expect(!boundaries[0]);
    try std.testing.expect(boundaries["hello".len - 1]);
    try std.testing.expect(boundaries["hello ".len - 1]);
    try std.testing.expect(boundaries[text.len - 1]);
}
