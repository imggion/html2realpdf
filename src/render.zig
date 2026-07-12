//! Top-level HTML-to-PDF renderer orchestration.
//!
//! All parser, tree, layout, and display-list allocations live for one render.
//! Only the returned PDF byte slice is owned by the caller.

const std = @import("std");
const html = @import("html.zig");
const dom = @import("dom.zig");
const css = @import("css.zig");
const box = @import("box.zig");
const layout = @import("layout.zig");
const pagination = @import("pagination.zig");
const display_list = @import("display_list.zig");
const paged_media = @import("paged_media.zig");
const pdf = @import("pdf.zig");
const font = @import("font.zig");
const diagnostics = @import("diagnostics.zig");

pub const Diagnostic = diagnostics.Diagnostic;
pub const serializeDiagnostics = diagnostics.serialize;

pub const CssProfile = enum { document, web, strict };
pub const MarginBoxName = paged_media.MarginBoxName;
pub const MarginBox = paged_media.MarginBox;
pub const PageMarginRule = paged_media.MarginRule;
pub const PageRule = pagination.PageRule;
pub const PageSelector = pagination.PageSelector;

pub const Options = struct {
    page_format: pagination.PageFormat = .a4,
    orientation: pagination.Orientation = .portrait,
    margins_points: pagination.Margins = .{},
    custom_page_width_points: ?f32 = null,
    custom_page_height_points: ?f32 = null,
    metadata: pdf.Metadata = .{},
    font_registry: ?*const font.Registry = null,
    css_profile: CssProfile = .document,
    margin_boxes: []const MarginBox = &.{},
    page_margin_rules: []const PageMarginRule = &.{},
    page_rules: []const PageRule = &.{},
};

pub const Error = error{
    UnsupportedPositionedLayout,
    UnsupportedFloatLayout,
    UnsupportedDisplayLayout,
    UnsupportedTransform,
    UnsupportedPaintEffects,
    MissingGlyph,
};

pub const Result = struct {
    bytes: []u8,
    page_count: usize,
    diagnostics_json: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.diagnostics_json);
        self.* = undefined;
    }
};

pub fn renderHtml(
    output_allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) !Result {
    var arena_state = std.heap.ArenaAllocator.init(output_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic_list = try std.ArrayList(diagnostics.Diagnostic).initCapacity(arena, 0);

    var tokens = try html.Tokenizer.tokenizeHtml(arena, source);
    defer tokens.deinit(arena);

    var document = try dom.Parser.parse(arena, source, tokens.items);
    defer document.deinit(arena);

    const page_spec = if (options.custom_page_width_points != null and options.custom_page_height_points != null)
        pagination.PageSpec{
            .width_points = @max(options.custom_page_width_points.?, 1),
            .height_points = @max(options.custom_page_height_points.?, 1),
            .margins_points = options.margins_points,
        }
    else
        pagination.PageSpec.standard(
            options.page_format,
            options.orientation,
            options.margins_points,
        );

    const styles = try css.styleArrayFromDocumentWithContext(arena, &document, .{
        .viewport_width = page_spec.contentWidthCssPx(),
        .viewport_height = page_spec.contentHeightCssPx(),
        .diagnostics = &diagnostic_list,
    });
    for (styles) |style| {
        if (!style.layout_supported) return Error.UnsupportedDisplayLayout;
        if ((style.display == .flex or style.display == .inlineFlex) and options.css_profile == .document) return Error.UnsupportedDisplayLayout;
        if ((style.display == .grid or style.display == .inlineGrid) and options.css_profile == .document) return Error.UnsupportedDisplayLayout;
        if (style.position != .static and options.css_profile == .document) return Error.UnsupportedPositionedLayout;
        if (style.float_direction != .none and options.css_profile == .document) return Error.UnsupportedFloatLayout;
        if (style.transform.len > 0 and options.css_profile == .document) return Error.UnsupportedTransform;
        if (options.css_profile == .document and
            (!std.ascii.eqlIgnoreCase(style.background_image, "none") or
                !std.ascii.eqlIgnoreCase(style.box_shadow, "none") or
                !std.ascii.eqlIgnoreCase(style.text_shadow, "none"))) return Error.UnsupportedPaintEffects;
    }
    var tree = try box.Builder.build(arena, &document, styles, document.root);
    defer tree.deinit(arena);
    try validateGlyphCoverage(&tree, options.font_registry);

    var laid_out = try layout.layout(arena, &tree, &document, .{
        .content_width = page_spec.contentWidthCssPx(),
        .page_height = page_spec.contentHeightCssPx(),
        .font_registry = options.font_registry,
        .shaping_mode = if (options.css_profile == .document) .identity else .harfbuzz,
        .atomic_inline_baselines = options.css_profile != .document,
        .web_sizing = options.css_profile != .document,
        .page_spec = page_spec,
        .page_rules = options.page_rules,
    });
    defer laid_out.deinit(arena);

    var pages = try pagination.paginateWithRules(arena, &laid_out, page_spec, options.page_rules);
    defer pages.deinit(arena);

    var display = try display_list.build(arena, &pages);
    defer display.deinit(arena);
    try paged_media.appendMarginBoxes(
        arena,
        &display,
        options.margin_boxes,
        options.page_margin_rules,
        laid_out.page_names.items,
        laid_out.blank_pages.items,
        options.font_registry,
        if (options.css_profile == .document) .identity else .harfbuzz,
    );

    const temporary_pdf = try pdf.writeWithOptions(arena, &display, .{
        .metadata = options.metadata,
        .font_registry = options.font_registry,
    });
    const owned_pdf = try output_allocator.dupe(u8, temporary_pdf);
    errdefer output_allocator.free(owned_pdf);
    const diagnostics_json = try diagnostics.serialize(output_allocator, diagnostic_list.items);

    return .{
        .bytes = owned_pdf,
        .page_count = pages.page_count,
        .diagnostics_json = diagnostics_json,
    };
}

fn validateGlyphCoverage(tree: *const box.BoxTree, registry: ?*const font.Registry) Error!void {
    for (tree.boxes.items) |source_box| {
        const text = source_box.text orelse continue;
        var iterator = font.Utf8Iterator{ .bytes = text };
        while (iterator.next() catch return Error.MissingGlyph) |codepoint| {
            if (isCssControlWhitespace(codepoint)) continue;
            if (font.resolveForCodepoint(registry, source_box.style.font_family, source_box.style.font_weight, source_box.style.font_style, codepoint) == null) return Error.MissingGlyph;
        }
    }
}

fn isCssControlWhitespace(codepoint: u21) bool {
    return codepoint == '\t' or codepoint == '\n' or codepoint == '\r' or codepoint == 0x0C;
}

test "render HTML into a real PDF byte stream" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<html><body><h1>Invoice</h1><p>Selectable text output.</p></body></html>",
        .{ .margins_points = .{ .top = 36, .right = 36, .bottom = 36, .left = 36 } },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.page_count);
    try std.testing.expect(std.mem.startsWith(u8, result.bytes, "%PDF-1.7"));
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Type0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/ToUnicode") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
}

test "ignore non-painted CSS control whitespace during glyph validation" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<p>\n\tselectable text\r\n</p>",
        .{},
    );
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.bytes, "%PDF-1.7"));
}

test "reject positioned and floating layout instead of silently misrendering" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        Error.UnsupportedPositionedLayout,
        renderHtml(allocator, "<div style=\"position:absolute\">no</div>", .{}),
    );
    try std.testing.expectError(
        Error.UnsupportedFloatLayout,
        renderHtml(allocator, "<div style=\"float:left\">no</div>", .{}),
    );
    try std.testing.expectError(
        Error.UnsupportedDisplayLayout,
        renderHtml(allocator, "<div style=\"display:flex\">no</div>", .{}),
    );
    try std.testing.expectError(
        Error.UnsupportedTransform,
        renderHtml(allocator, "<div style=\"transform:translateX(10px)\">no</div>", .{}),
    );
    try std.testing.expectError(
        Error.UnsupportedPaintEffects,
        renderHtml(allocator, "<div style=\"background-image:linear-gradient(red,blue)\">no</div>", .{}),
    );
    try std.testing.expectError(
        Error.MissingGlyph,
        renderHtml(allocator, "<p>Unsupported emoji 😀</p>", .{}),
    );
}

test "render Web positioned layout as native PDF content" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<div style='position:relative;width:200px;height:100px'>" ++
            "<span style='position:absolute;right:10px;top:12px'>positioned</span></div>",
        .{ .css_profile = .web },
    );
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.bytes, "%PDF-1.7"));
}

test "render Web 2D transforms as native PDF matrices" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<a href='https://example.com/transform' style='display:block;width:120px;height:40px;transform:translate(20px,10px) rotate(12deg);transform-origin:left top;background:#2563eb;color:white'>matrix</a>",
        .{ .css_profile = .web },
    );
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.bytes, "%PDF-1.7"));
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Link") != null);
}

test "render Web gradient backgrounds as native PDF shadings" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<div style='width:240px;height:100px;border-radius:12px;background:linear-gradient(120deg,#2563eb 0%,#7c3aed 55%,#db2777 100%) no-repeat'>gradient</div>",
        .{ .css_profile = .web },
    );
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/ShadingType 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
}

test "render Web PNG data URL backgrounds as scoped image objects" {
    const allocator = std.testing.allocator;
    const png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+X1y8WQAAAABJRU5ErkJggg==";
    const source = try std.fmt.allocPrint(allocator, "<div style=\"width:120px;height:70px;background-image:url('{s}');background-size:20px 20px;background-repeat:space round\"></div>", .{png});
    defer allocator.free(source);
    var result = try renderHtml(allocator, source, .{ .css_profile = .web });
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") != null);
}

test "render Web shadows and nested opacity as native PDF effects" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<div style='width:220px;height:90px;opacity:.65;border-radius:14px;background:#fff;box-shadow:0 10px 24px rgba(15,23,42,.35),inset 0 0 6px #2563eb'>" ++
            "<strong style='opacity:.7;text-shadow:2px 3px 4px rgba(0,0,0,.45)'>native effects</strong></div>",
        .{ .css_profile = .web },
    );
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Group << /S /Transparency /I true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Artifact BMC") == null); // compressed page/form content
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
}

test "render Web floats and clear as native PDF content" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<div><div style='float:left;width:80px;height:60px;background:#fee2e2'>float</div><p>flowing selectable text</p><p style='clear:both'>clear</p></div>",
        .{ .css_profile = .web },
    );
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.bytes, "%PDF-1.7"));
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
}

test "return structured diagnostics for ignored CSS declarations" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<p style=\"filter:blur(2px); color:#123456\">diagnostic</p>",
        .{},
    );
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics_json, "\"code\":\"UNSUPPORTED_CSS_PROPERTY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics_json, "\"property\":\"filter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics_json, "\"phase\":\"computed\"") != null);
}

test "preserve CSS alpha as a native PDF graphics state" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<p style=\"background:rgba(255, 0, 0, 0.5);color:rgba(0, 0, 255, 0.75)\">alpha</p>",
        .{},
    );
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/ExtGState <<") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/ca 0.5000 /CA 0.5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/ca 0.7500 /CA 0.7500") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
}

test "render anchor elements as PDF link annotations" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<p>Visit <a href=\"https://example.com/docs\">the docs</a>.</p>",
        .{},
    );
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Link") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "https://example.com/docs") != null);
}

test "write ASCII and Unicode document metadata" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(allocator, "<p>metadata</p>", .{
        .metadata = .{ .title = "Fattura €", .author = "Example Author" },
    });
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Author (Example Author)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Title <FEFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Info ") != null);
}

test "resolve and embed a registered TrueType font family" {
    const allocator = std.testing.allocator;
    const registered = [_]font.RegisteredFont{.{
        .family = "Custom Report",
        .postscript_name = "CustomReport-Regular",
        .data = font.Face.regular.bytes(),
    }};
    const registry = font.Registry{ .fonts = &registered };
    var result = try renderHtml(
        allocator,
        "<p style=\"font-family:'Custom Report'\">custom font</p>",
        .{ .font_registry = &registry },
    );
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "HREALP+CustomReport-Regular") != null);
}

test "split one text node across registered per-glyph fallback fonts" {
    const allocator = std.testing.allocator;
    const uppercase = [_]font.UnicodeRange{.{ .start = 'A', .end = 'Z' }};
    const registered = [_]font.RegisteredFont{
        .{
            .family = "Primary Latin",
            .postscript_name = "PrimaryLatin-Regular",
            .data = font.Face.regular.bytes(),
            .unicode_ranges = &uppercase,
        },
        .{
            .family = "Fallback Full",
            .postscript_name = "FallbackFull-Regular",
            .data = font.Face.regular.bytes(),
        },
    };
    const registry = font.Registry{ .fonts = &registered };
    var result = try renderHtml(
        allocator,
        "<p style=\"font-family:'Primary Latin','Fallback Full'\">Aé</p>",
        .{ .font_registry = &registry },
    );
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "HREALP+PrimaryLatin-Regular") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "HREALP+FallbackFull-Regular") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
}

test "render semantic bold and italic text with distinct PDF fonts" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<p><strong>bold</strong> and <em>italic</em></p>",
        .{},
    );
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/CMapName /NotoSans-Bold-UCS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/CMapName /NotoSans-Italic-UCS") != null);
}

test "render list markers as native PDF text" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<ul><li>alpha</li></ul><ol><li>one</li><li>two</li></ol>",
        .{},
    );
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "> <2022>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "> <0031>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "> <0032>") != null);
}

test "embed JPEG data URLs as PDF image objects" {
    const allocator = std.testing.allocator;
    const jpeg_bytes = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xC0,
        0x00, 0x0B,
        0x08, 0x00,
        0x02, 0x00,
        0x03, 0x03,
        0x01, 0x11,
        0x00,
    };
    const encoded_len = std.base64.standard.Encoder.calcSize(jpeg_bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, &jpeg_bytes);
    const source = try std.fmt.allocPrint(
        allocator,
        "<img src=\"data:image/jpeg;base64,{s}\" width=\"30\" height=\"20\">",
        .{encoded},
    );
    defer allocator.free(source);

    var result = try renderHtml(allocator, source, .{});
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/DCTDecode") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Im1 ") != null);
}

test "embed transparent PNG data URLs with a PDF soft mask" {
    const allocator = std.testing.allocator;
    const source = "<img src=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+X1y8WQAAAABJRU5ErkJggg==\" width=\"30\" height=\"20\">";
    var result = try renderHtml(allocator, source, .{});
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/FlateDecode") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/SMask") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Im1 ") != null);
}

test "render supported SVG data URLs as vector PDF forms" {
    const allocator = std.testing.allocator;
    const svg_source = "<svg viewBox='0 0 80 40'><rect x='2' y='2' width='76' height='36' rx='8' fill='#dbeafe' stroke='#2563eb' stroke-width='4'/><path d='M12 28 C28 4 50 36 68 12' fill='none' stroke='#7c3aed' stroke-width='5'/></svg>";
    const encoded_len = std.base64.standard.Encoder.calcSize(svg_source.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, svg_source);
    const html_source = try std.fmt.allocPrint(
        allocator,
        "<p>Selectable sibling</p><img src=\"data:image/svg+xml;base64,{s}\" width=\"160\" height=\"80\">",
        .{encoded},
    );
    defer allocator.free(html_source);
    var result = try renderHtml(allocator, html_source, .{ .css_profile = .web });
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Form") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/Subtype /Image") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/ToUnicode") != null);
}

test "render named pages with distinct PDF media boxes" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<div style='height:20px;page:Report'>REPORT</div><div style='height:20px;page:Summary'>SUMMARY</div>",
        .{
            .css_profile = .web,
            .custom_page_width_points = 150,
            .custom_page_height_points = 75,
            .page_rules = &.{
                .{ .selector = .{ .name = "Report" }, .width_points = 150, .height_points = 75 },
                .{ .selector = .{ .name = "Summary" }, .width_points = 225, .height_points = 90 },
            },
        },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.page_count);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/MediaBox [0 0 150.000 75.000]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "/MediaBox [0 0 225.000 90.000]") != null);
}

test "render named page height as the layout fragmentainer extent" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<div style='height:20px;page:Report'>REPORT</div>" ++
            "<section style='page:Summary'>" ++
            "<div style='height:70px;break-inside:avoid'>SUMMARY ONE</div>" ++
            "<div style='height:70px;break-inside:avoid'>SUMMARY TWO</div>" ++
            "<div style='height:70px;break-inside:avoid'>SUMMARY THREE</div></section>",
        .{
            .css_profile = .web,
            .custom_page_width_points = 150,
            .custom_page_height_points = 75,
            .page_rules = &.{
                .{ .selector = .{ .name = "Report" }, .width_points = 150, .height_points = 75 },
                .{ .selector = .{ .name = "Summary" }, .width_points = 225, .height_points = 120 },
            },
        },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.page_count);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.bytes, "/MediaBox [0 0 150.000 75.000]"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.bytes, "/MediaBox [0 0 225.000 120.000]"));
}

test "render pseudo page width as the inline layout extent" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<p style='margin:0;font-size:16px;line-height:20px'>MMMMMM MMMMMM MMMMMM MMMMMM MMMMMM MMMMMM</p>",
        .{
            .css_profile = .web,
            .custom_page_width_points = 75,
            .custom_page_height_points = 30,
            .page_rules = &.{
                .{ .selector = .{ .left = true }, .width_points = 150, .height_points = 30 },
            },
        },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.page_count);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.bytes, "/MediaBox [0 0 75.000 30.000]"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.bytes, "/MediaBox [0 0 150.000 30.000]"));
}

test "render forced blank pages with blank page geometry" {
    const allocator = std.testing.allocator;
    var result = try renderHtml(
        allocator,
        "<div style='height:20px'>FIRST</div><div style='height:20px;break-before:right'>THIRD</div>",
        .{
            .css_profile = .web,
            .custom_page_width_points = 75,
            .custom_page_height_points = 75,
            .page_rules = &.{
                .{ .selector = .{ .blank = true }, .width_points = 150, .height_points = 112.5 },
            },
        },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.page_count);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.bytes, "/MediaBox [0 0 75.000 75.000]"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.bytes, "/MediaBox [0 0 150.000 112.500]"));
}
