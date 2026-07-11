//! Production-mode bidi/layout integration gate linked with SheenBidi and HarfBuzz.

const std = @import("std");
const html = @import("html.zig");
const dom = @import("dom.zig");
const css = @import("css.zig");
const box = @import("box.zig");
const layout = @import("layout.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const source = "<p style=\"direction:rtl;text-align:start\">שלום hello עולם</p>";

    const tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    const result = try layout.layout(allocator, &tree, &document, .{
        .content_width = 400,
        .shaping_mode = .harfbuzz,
    });

    var visual_texts: [5][]const u8 = undefined;
    var count: usize = 0;
    var previous_x: f32 = 0;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        if (count >= visual_texts.len) return error.BidiLayoutMismatch;
        if (count > 0 and fragment.rect.x < previous_x) return error.BidiLayoutMismatch;
        visual_texts[count] = text;
        previous_x = fragment.rect.x;
        count += 1;
    }

    if (count != visual_texts.len or
        !std.mem.eql(u8, visual_texts[0], "עולם") or
        !std.mem.eql(u8, visual_texts[1], " ") or
        !std.mem.eql(u8, visual_texts[2], "hello") or
        !std.mem.eql(u8, visual_texts[3], " ") or
        !std.mem.eql(u8, visual_texts[4], "שלום")) return error.BidiLayoutMismatch;

    const break_source = "<p>alpha-beta-gamma</p>";
    const break_tokens = try html.Tokenizer.tokenizeHtml(allocator, break_source);
    var break_document = try dom.Parser.parse(allocator, break_source, break_tokens.items);
    const break_styles = try css.styleArrayFromDocument(allocator, &break_document);
    var break_tree = try box.Builder.build(allocator, &break_document, break_styles, break_document.root);
    const break_result = try layout.layout(allocator, &break_tree, &break_document, .{
        .content_width = 55,
        .shaping_mode = .harfbuzz,
    });
    var first_line: ?usize = null;
    var last_line: ?usize = null;
    for (break_result.fragments.items) |fragment| {
        if (fragment.kind != .text) continue;
        first_line = first_line orelse fragment.line_id;
        last_line = fragment.line_id;
    }
    if (first_line == null or last_line == null or first_line.? == last_line.?) return error.UnicodeLineBreakMismatch;
}
