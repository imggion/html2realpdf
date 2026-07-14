//! Small, pinned conformance subset adapted from supported Web Platform Tests.
//!
//! These are renderer-native assertions rather than browser screenshots: they
//! keep the upstream scenario and assert the resulting fragment/PDF geometry.

const std = @import("std");
const box = @import("box.zig");
const css = @import("css.zig");
const dom = @import("dom.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const render = @import("render.zig");

fn layoutHtml(allocator: std.mem.Allocator, source: []const u8, content_width: f32) !layout.LayoutDocument {
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    return layout.layout(allocator, &tree, &document, .{ .content_width = content_width, .web_sizing = true });
}

// Adapted from css/css-flexbox/align-content-wrap-001.html. The upstream test
// requires align-content to position even a single wrapped flex line.
test "WPT subset flex single-line align-content center" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var result = try layoutHtml(
        arena_state.allocator(),
        "<div style='display:flex;width:100px;height:70px;flex-wrap:wrap;align-content:center'>" ++
            "<div style='width:20px;height:20px;background:#00ff00'></div></div>",
        120,
    );
    defer result.deinit(arena_state.allocator());

    var green: ?layout.Fragment = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 0 and color.green == 1 and color.blue == 0) green = fragment;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 25), green.?.rect.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), green.?.rect.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), green.?.rect.height, 0.01);
}

// Adapted from css/css-grid/grid-items/aspect-ratio-001.html. The percentage
// block size is definite and transfers through aspect-ratio to the inline size.
test "WPT subset Grid item aspect ratio uses a definite row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var result = try layoutHtml(
        arena_state.allocator(),
        "<div style='display:inline-grid;grid-template-rows:100px'>" ++
            "<div style='aspect-ratio:1/1;height:100%;background:#00ff00'></div></div>",
        200,
    );
    defer result.deinit(arena_state.allocator());

    var green: ?layout.Fragment = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 0 and color.green == 1 and color.blue == 0) green = fragment;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100), green.?.rect.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), green.?.rect.height, 0.01);
}

// Adapted from css/CSS2/pagination/page-break-before-001.xht. The later auto
// declaration cancels the earlier forced value and must leave one PDF page.
test "WPT subset page-break-before auto does not force a page" {
    var result = try render.renderHtml(
        std.testing.allocator,
        "<style>.no-break{page-break-before:always;page-break-before:auto}</style>" ++
            "<div>first</div><div class='no-break'>second</div>",
        .{
            .custom_page_width_points = 300,
            .custom_page_height_points = 300,
            .css_profile = .web,
        },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.page_count);
}
