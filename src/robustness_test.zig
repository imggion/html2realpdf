//! Deterministic parser fuzz, resource exhaustion, and large-document gates.

const std = @import("std");
const css = @import("css.zig");
const dom = @import("dom.zig");
const html = @import("html.zig");
const render = @import("render.zig");

test "robustness: deterministic malformed HTML and CSS mutation corpus never crashes" {
    const alphabet = "<>/{ }[]():;!@#%&*+-_=\\\"'abcdefghijklmnopqrstuvwxyz0123456789\n\t";
    var state: u64 = 0x6a09e667f3bcc909;
    for (0..512) |case_index| {
        var bytes: [256]u8 = undefined;
        const length = 1 + case_index % bytes.len;
        for (bytes[0..length]) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = alphabet[@intCast(state % alphabet.len)];
        }
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const allocator = arena_state.allocator();
        var tokens = html.Tokenizer.tokenizeHtml(allocator, bytes[0..length]) catch continue;
        var document = dom.Parser.parse(allocator, bytes[0..length], tokens.items) catch continue;
        _ = css.styleArrayFromDocument(allocator, &document) catch continue;
        var stylesheet = css.parseStylesheet(allocator, bytes[0..length]) catch continue;
        stylesheet.deinit(allocator);
        document.deinit(allocator);
        tokens.deinit(allocator);
    }
}

test "robustness: renderer reports allocation exhaustion instead of trapping" {
    var storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(
        error.OutOfMemory,
        render.renderHtml(
            fixed.allocator(),
            "<main><section style='display:grid;grid-template-columns:repeat(4,1fr)'>" ++
                "<article>allocation exhaustion must be an ordinary error</article></section></main>",
            .{ .css_profile = .web },
        ),
    );
}

test "robustness: large multi-page document remains native and completes" {
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("<main style='font-family:Noto Sans'>");
    for (0..400) |index| {
        try source.writer.print(
            "<section style='height:38px;break-inside:avoid;border-bottom:1px solid #94a3b8'>Row {d}: selectable content</section>",
            .{index},
        );
    }
    try source.writer.writeAll("</main>");

    var result = try render.renderHtml(
        std.testing.allocator,
        source.written(),
        .{
            .custom_page_width_points = 300,
            .custom_page_height_points = 400,
            .margins_points = .{ .top = 20, .right = 20, .bottom = 20, .left = 20 },
            .css_profile = .web,
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.page_count >= 30);
    try std.testing.expect(std.mem.startsWith(u8, result.bytes, "%PDF-1.7"));
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/ToUnicode") != null);
}
