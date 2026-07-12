const std = @import("std");
const html2realpdf = @import("html2realpdf");

const tokenizer = html2realpdf.html.Tokenizer;
const dom = html2realpdf.dom;
const box = html2realpdf.box;
const css = html2realpdf.css;
const renderer = html2realpdf.render;
const pdf = html2realpdf.pdf;
const font = html2realpdf.font;
const geometry = html2realpdf.geometry;

const abi_version_value: u32 = 1;

var last_output_len: usize = 0;

const PdfResult = struct {
    bytes: []u8 = &.{},
    error_message: []u8 = &.{},
    diagnostics_json: []u8 = &.{},
    page_count: u32 = 0,
    status: i32 = 0,
};

const JsonMetadata = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    creator: ?[]const u8 = null,
};

const JsonMarginBox = struct {
    name: renderer.MarginBoxName,
    content: []const u8,
    fontFamily: []const u8 = "Noto Sans",
    fontSize: f32 = 12,
    fontWeight: box.FontWeight = .normal,
    fontStyle: box.FontStyle = .normal,
    color: []const u8 = "black",
    textAlign: ?box.TextAlign = null,
};

const JsonPageRule = struct {
    name: []const u8 = "",
    first: bool = false,
    left: bool = false,
    right: bool = false,
    blank: bool = false,
    widthPoints: ?f32 = null,
    heightPoints: ?f32 = null,
    marginTopPoints: ?f32 = null,
    marginRightPoints: ?f32 = null,
    marginBottomPoints: ?f32 = null,
    marginLeftPoints: ?f32 = null,
    sizeImportant: bool = false,
    marginTopImportant: bool = false,
    marginRightImportant: bool = false,
    marginBottomImportant: bool = false,
    marginLeftImportant: bool = false,
};

const JsonRenderOptions = struct {
    pageWidthPoints: f32,
    pageHeightPoints: f32,
    marginTopPoints: f32 = 0,
    marginRightPoints: f32 = 0,
    marginBottomPoints: f32 = 0,
    marginLeftPoints: f32 = 0,
    metadata: ?JsonMetadata = null,
    cssProfile: renderer.CssProfile = .document,
    marginBoxes: []const JsonMarginBox = &.{},
    pageRules: []const JsonPageRule = &.{},
};

const PdfContext = struct {
    fonts: std.ArrayList(font.RegisteredFont),

    fn deinit(self: *PdfContext) void {
        for (self.fonts.items) |registered| {
            std.heap.wasm_allocator.free(registered.family);
            std.heap.wasm_allocator.free(registered.postscript_name);
            std.heap.wasm_allocator.free(registered.data);
        }
        self.fonts.deinit(std.heap.wasm_allocator);
    }

    fn registry(self: *const PdfContext) font.Registry {
        return .{ .fonts = self.fonts.items };
    }
};

export fn html2realpdf_abi_version() u32 {
    return abi_version_value;
}

export fn pdf_context_create() usize {
    const context = std.heap.wasm_allocator.create(PdfContext) catch return 0;
    context.* = .{
        .fonts = std.ArrayList(font.RegisteredFont).initCapacity(std.heap.wasm_allocator, 0) catch {
            std.heap.wasm_allocator.destroy(context);
            return 0;
        },
    };
    return @intFromPtr(context);
}

export fn pdf_context_free(handle: usize) void {
    const context = contextFromHandle(handle) orelse return;
    context.deinit();
    std.heap.wasm_allocator.destroy(context);
}

export fn pdf_context_register_font(
    handle: usize,
    family_ptr: usize,
    family_len: usize,
    data_ptr: usize,
    data_len: usize,
    weight: u32,
    style: u32,
) i32 {
    const context = contextFromHandle(handle) orelse return -1;
    if (family_ptr == 0 or family_len == 0 or data_ptr == 0 or data_len == 0) return -3;
    const family_bytes: [*]const u8 = @ptrFromInt(family_ptr);
    const font_bytes: [*]const u8 = @ptrFromInt(data_ptr);
    _ = font.Metrics.parse(font_bytes[0..data_len]) catch return -6;
    const font_weight: box.FontWeight = if (weight >= 600) .bold else .normal;
    const font_style: box.FontStyle = if (style != 0) .italic else .normal;
    const family = std.heap.wasm_allocator.dupe(u8, family_bytes[0..family_len]) catch return -2;
    const data = std.heap.wasm_allocator.dupe(u8, font_bytes[0..data_len]) catch {
        std.heap.wasm_allocator.free(family);
        return -2;
    };
    const postscript_name = makePostscriptName(family, font_weight, font_style) catch {
        std.heap.wasm_allocator.free(family);
        std.heap.wasm_allocator.free(data);
        return -2;
    };

    for (context.fonts.items) |*registered| {
        if (!std.ascii.eqlIgnoreCase(registered.family, family) or registered.weight != font_weight or registered.style != font_style) continue;
        std.heap.wasm_allocator.free(registered.family);
        std.heap.wasm_allocator.free(registered.postscript_name);
        std.heap.wasm_allocator.free(registered.data);
        registered.* = .{
            .family = family,
            .postscript_name = postscript_name,
            .data = data,
            .weight = font_weight,
            .style = font_style,
        };
        return 0;
    }
    context.fonts.append(std.heap.wasm_allocator, .{
        .family = family,
        .postscript_name = postscript_name,
        .data = data,
        .weight = font_weight,
        .style = font_style,
    }) catch {
        std.heap.wasm_allocator.free(family);
        std.heap.wasm_allocator.free(postscript_name);
        std.heap.wasm_allocator.free(data);
        return -2;
    };
    return 0;
}

export fn alloc(len: usize) usize {
    const buf = std.heap.wasm_allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

export fn free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;

    const bytes: [*]u8 = @ptrFromInt(ptr);
    std.heap.wasm_allocator.free(bytes[0..len]);
}

/// Returns the number of tokenizer tokens for a borrowed HTML input slice.
export fn tokenize_html(ptr: usize, len: usize) isize {
    if (ptr == 0) return -1;

    const input_ptr: [*]const u8 = @ptrFromInt(ptr);
    const input = input_ptr[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const tokens = tokenizer.tokenizeHtml(arena, input) catch return -1;

    return @intCast(tokens.items.len);
}

export fn dom_tree_output_len() usize {
    return last_output_len;
}

export fn box_tree_output_len() usize {
    return last_output_len;
}

export fn cascade_tree_output_len() usize {
    return last_output_len;
}

export fn dom_tree_html(ptr: usize, len: usize) usize {
    last_output_len = 0;
    if (ptr == 0) return 0;

    const input_ptr: [*]const u8 = @ptrFromInt(ptr);
    const input = input_ptr[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const tokens = tokenizer.tokenizeHtml(arena, input) catch return 0;
    var document = dom.Parser.parse(arena, input, tokens.items) catch return 0;
    defer document.deinit(arena);

    var dump_writer = std.Io.Writer.Allocating.init(arena);
    document.dump(&dump_writer.writer) catch return 0;

    const dump = dump_writer.writer.buffered();
    const output = std.heap.wasm_allocator.dupe(u8, dump) catch return 0;

    last_output_len = output.len;
    return @intFromPtr(output.ptr);
}

export fn box_tree_html(ptr: usize, len: usize) usize {
    last_output_len = 0;
    if (ptr == 0) return 0;

    const input_ptr: [*]const u8 = @ptrFromInt(ptr);
    const input = input_ptr[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const tokens = tokenizer.tokenizeHtml(arena, input) catch return 0;
    var document = dom.Parser.parse(arena, input, tokens.items) catch return 0;
    defer document.deinit(arena);

    const styles = css.styleArrayFromDocument(arena, &document) catch return 0;

    var tree = box.Builder.build(arena, &document, styles, document.root) catch return 0;
    defer tree.deinit(arena);

    var dump_writer = std.Io.Writer.Allocating.init(arena);
    tree.dumpWithStyles(&document, &dump_writer.writer) catch return 0;

    const dump = dump_writer.writer.buffered();
    const output = std.heap.wasm_allocator.dupe(u8, dump) catch return 0;

    last_output_len = output.len;
    return @intFromPtr(output.ptr);
}

export fn cascade_tree_html(ptr: usize, len: usize) usize {
    last_output_len = 0;
    if (ptr == 0) return 0;

    const input_ptr: [*]const u8 = @ptrFromInt(ptr);
    const input = input_ptr[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const tokens = tokenizer.tokenizeHtml(arena, input) catch return 0;
    var document = dom.Parser.parse(arena, input, tokens.items) catch return 0;
    defer document.deinit(arena);

    const styles = css.styleArrayFromDocument(arena, &document) catch return 0;

    var dump_writer = std.Io.Writer.Allocating.init(arena);
    css.dumpCascade(&document, styles, &dump_writer.writer) catch return 0;

    const dump = dump_writer.writer.buffered();
    const output = std.heap.wasm_allocator.dupe(u8, dump) catch return 0;

    last_output_len = output.len;
    return @intFromPtr(output.ptr);
}

/// Renders HTML into an owned PDF result. The returned handle remains valid
/// until `pdf_result_free` is called and does not share output state with other
/// render calls.
export fn render_html_to_pdf(ptr: usize, len: usize) usize {
    return renderPdf(ptr, len, .{});
}

export fn render_html_to_pdf_with_options(
    ptr: usize,
    len: usize,
    page_width_points: f32,
    page_height_points: f32,
    margin_top_points: f32,
    margin_right_points: f32,
    margin_bottom_points: f32,
    margin_left_points: f32,
) usize {
    return renderPdf(ptr, len, .{
        .custom_page_width_points = page_width_points,
        .custom_page_height_points = page_height_points,
        .margins_points = .{
            .top = @max(margin_top_points, 0),
            .right = @max(margin_right_points, 0),
            .bottom = @max(margin_bottom_points, 0),
            .left = @max(margin_left_points, 0),
        },
    });
}

/// Extensible render entrypoint used by the JavaScript package. The fixed
/// numeric entrypoint remains exported for compatibility with early callers.
export fn render_html_to_pdf_with_json_options(
    ptr: usize,
    len: usize,
    options_ptr: usize,
    options_len: usize,
) usize {
    return renderPdfWithJson(null, ptr, len, options_ptr, options_len);
}

export fn render_html_to_pdf_with_context_json_options(
    context_handle: usize,
    ptr: usize,
    len: usize,
    options_ptr: usize,
    options_len: usize,
) usize {
    const context = contextFromHandle(context_handle) orelse return createErrorResult(-3, "PDF context handle is invalid");
    return renderPdfWithJson(context, ptr, len, options_ptr, options_len);
}

fn renderPdfWithJson(
    context: ?*const PdfContext,
    ptr: usize,
    len: usize,
    options_ptr: usize,
    options_len: usize,
) usize {
    if (options_ptr == 0) return createErrorResult(-4, "Render options pointer is null");
    const raw_ptr: [*]const u8 = @ptrFromInt(options_ptr);
    const parsed = std.json.parseFromSlice(
        JsonRenderOptions,
        std.heap.wasm_allocator,
        raw_ptr[0..options_len],
        .{ .ignore_unknown_fields = true },
    ) catch return createErrorResult(-4, "Render options JSON is invalid");
    defer parsed.deinit();
    const value = parsed.value;
    const metadata: pdf.Metadata = if (value.metadata) |metadata| .{
        .title = metadata.title,
        .author = metadata.author,
        .subject = metadata.subject,
        .keywords = metadata.keywords,
        .creator = metadata.creator,
    } else .{};
    const margin_boxes = std.heap.wasm_allocator.alloc(renderer.MarginBox, value.marginBoxes.len) catch return createErrorResult(-2, "Margin box allocation failed");
    defer std.heap.wasm_allocator.free(margin_boxes);
    for (value.marginBoxes, margin_boxes) |input, *output| output.* = .{
        .name = input.name,
        .content = input.content,
        .font_family = input.fontFamily,
        .font_size = if (std.math.isFinite(input.fontSize)) @max(input.fontSize, 1) else 12,
        .font_weight = input.fontWeight,
        .font_style = input.fontStyle,
        .color = geometry.parseColor(input.color) orelse geometry.Color.black,
        .text_align = input.textAlign,
    };
    const page_rules = std.heap.wasm_allocator.alloc(renderer.PageRule, value.pageRules.len) catch return createErrorResult(-2, "Page rule allocation failed");
    defer std.heap.wasm_allocator.free(page_rules);
    for (value.pageRules, page_rules) |input, *output| output.* = .{
        .selector = .{
            .name = input.name,
            .first = input.first,
            .left = input.left,
            .right = input.right,
            .blank = input.blank,
        },
        .width_points = input.widthPoints,
        .height_points = input.heightPoints,
        .margin_top_points = input.marginTopPoints,
        .margin_right_points = input.marginRightPoints,
        .margin_bottom_points = input.marginBottomPoints,
        .margin_left_points = input.marginLeftPoints,
        .size_important = input.sizeImportant,
        .margin_top_important = input.marginTopImportant,
        .margin_right_important = input.marginRightImportant,
        .margin_bottom_important = input.marginBottomImportant,
        .margin_left_important = input.marginLeftImportant,
    };
    var registry = if (context) |available| available.registry() else font.Registry{};
    return renderPdf(ptr, len, .{
        .custom_page_width_points = value.pageWidthPoints,
        .custom_page_height_points = value.pageHeightPoints,
        .margins_points = .{
            .top = @max(value.marginTopPoints, 0),
            .right = @max(value.marginRightPoints, 0),
            .bottom = @max(value.marginBottomPoints, 0),
            .left = @max(value.marginLeftPoints, 0),
        },
        .metadata = metadata,
        .font_registry = if (context != null) &registry else null,
        .css_profile = value.cssProfile,
        .margin_boxes = margin_boxes,
        .page_rules = page_rules,
    });
}

fn createErrorResult(status: i32, message: []const u8) usize {
    const result = std.heap.wasm_allocator.create(PdfResult) catch return 0;
    result.* = .{};
    setResultError(result, status, message);
    return @intFromPtr(result);
}

fn renderPdf(ptr: usize, len: usize, options: renderer.Options) usize {
    const result = std.heap.wasm_allocator.create(PdfResult) catch return 0;
    result.* = .{};

    if (ptr == 0) {
        setResultError(result, -3, "HTML input pointer is null");
        return @intFromPtr(result);
    }
    if (options.custom_page_width_points) |width| {
        const height = options.custom_page_height_points orelse 0;
        if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0 or
            options.margins_points.left + options.margins_points.right >= width or
            options.margins_points.top + options.margins_points.bottom >= height)
        {
            setResultError(result, -4, "Page dimensions and margins do not leave a positive content area");
            return @intFromPtr(result);
        }
    }

    const input_ptr: [*]const u8 = @ptrFromInt(ptr);
    const input = input_ptr[0..len];
    const rendered = renderer.renderHtml(std.heap.wasm_allocator, input, options) catch |err| {
        setResultError(result, renderStatus(err), @errorName(err));
        return @intFromPtr(result);
    };

    result.bytes = rendered.bytes;
    result.diagnostics_json = rendered.diagnostics_json;
    result.page_count = @intCast(rendered.page_count);
    return @intFromPtr(result);
}

fn renderStatus(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => -2,
        error.UnsupportedImage => -5,
        error.InvalidDataUrl, error.InvalidJpeg, error.InvalidPng => -6,
        else => -1,
    };
}

fn setResultError(result: *PdfResult, status: i32, message: []const u8) void {
    result.status = status;
    result.error_message = std.heap.wasm_allocator.dupe(u8, message) catch &.{};
    const values = [_]renderer.Diagnostic{.{
        .code = "WASM_RENDER_FAILED",
        .severity = .@"error",
        .message = message,
        .phase = .pdf,
    }};
    result.diagnostics_json = renderer.serializeDiagnostics(std.heap.wasm_allocator, &values) catch &.{};
}

export fn pdf_result_status(handle: usize) i32 {
    const result = pdfResultFromHandle(handle) orelse return -2;
    return result.status;
}

export fn pdf_result_data_ptr(handle: usize) usize {
    const result = pdfResultFromHandle(handle) orelse return 0;
    if (result.bytes.len == 0) return 0;
    return @intFromPtr(result.bytes.ptr);
}

export fn pdf_result_data_len(handle: usize) usize {
    const result = pdfResultFromHandle(handle) orelse return 0;
    return result.bytes.len;
}

export fn pdf_result_page_count(handle: usize) u32 {
    const result = pdfResultFromHandle(handle) orelse return 0;
    return result.page_count;
}

export fn pdf_result_error_ptr(handle: usize) usize {
    const result = pdfResultFromHandle(handle) orelse return 0;
    if (result.error_message.len == 0) return 0;
    return @intFromPtr(result.error_message.ptr);
}

export fn pdf_result_error_len(handle: usize) usize {
    const result = pdfResultFromHandle(handle) orelse return 0;
    return result.error_message.len;
}

export fn pdf_result_diagnostics_ptr(handle: usize) usize {
    const result = pdfResultFromHandle(handle) orelse return 0;
    if (result.diagnostics_json.len == 0) return 0;
    return @intFromPtr(result.diagnostics_json.ptr);
}

export fn pdf_result_diagnostics_len(handle: usize) usize {
    const result = pdfResultFromHandle(handle) orelse return 0;
    return result.diagnostics_json.len;
}

export fn pdf_result_free(handle: usize) void {
    const result = pdfResultFromHandle(handle) orelse return;
    if (result.bytes.len > 0) std.heap.wasm_allocator.free(result.bytes);
    if (result.error_message.len > 0) std.heap.wasm_allocator.free(result.error_message);
    if (result.diagnostics_json.len > 0) std.heap.wasm_allocator.free(result.diagnostics_json);
    std.heap.wasm_allocator.destroy(result);
}

fn pdfResultFromHandle(handle: usize) ?*PdfResult {
    if (handle == 0) return null;
    return @ptrFromInt(handle);
}

fn contextFromHandle(handle: usize) ?*PdfContext {
    if (handle == 0) return null;
    return @ptrFromInt(handle);
}

fn makePostscriptName(family: []const u8, weight: box.FontWeight, style: box.FontStyle) ![]u8 {
    var output = std.Io.Writer.Allocating.init(std.heap.wasm_allocator);
    errdefer output.deinit();
    for (family) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
        try output.writer.writeByte(if (safe) byte else '-');
    }
    if (output.writer.end == 0) try output.writer.writeAll("CustomFont");
    if (weight == .bold) try output.writer.writeAll("-Bold");
    if (style == .italic) try output.writer.writeAll("-Italic");
    return output.toOwnedSlice();
}
