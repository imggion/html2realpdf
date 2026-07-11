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
const pdf = @import("pdf.zig");
const font = @import("font.zig");
const diagnostics = @import("diagnostics.zig");

pub const Diagnostic = diagnostics.Diagnostic;
pub const serializeDiagnostics = diagnostics.serialize;

pub const CssProfile = enum { document, web, strict };

pub const Options = struct {
    page_format: pagination.PageFormat = .a4,
    orientation: pagination.Orientation = .portrait,
    margins_points: pagination.Margins = .{},
    custom_page_width_points: ?f32 = null,
    custom_page_height_points: ?f32 = null,
    metadata: pdf.Metadata = .{},
    font_registry: ?*const font.Registry = null,
    css_profile: CssProfile = .document,
};

pub const Error = error{
    UnsupportedPositionedLayout,
    UnsupportedFloatLayout,
    UnsupportedDisplayLayout,
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
        if (style.position != .static) return Error.UnsupportedPositionedLayout;
        if (style.float_direction != .none) return Error.UnsupportedFloatLayout;
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
    });
    defer laid_out.deinit(arena);

    var pages = try pagination.paginate(arena, &laid_out, page_spec);
    defer pages.deinit(arena);

    var display = try display_list.build(arena, &pages);
    defer display.deinit(arena);

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
        Error.MissingGlyph,
        renderHtml(allocator, "<p>Unsupported emoji 😀</p>", .{}),
    );
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
