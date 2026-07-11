//! PDF 1.7 backend for the renderer display list.
//!
//! The writer emits deterministic classic-xref documents, vector painting,
//! selectable Unicode text backed by embedded TrueType fonts, links, and
//! pass-through JPEG image XObjects.

const std = @import("std");
const display_list = @import("display_list.zig");
const font = @import("font.zig");
const geometry = @import("geometry.zig");
const image_decoder = @import("image.zig");

const font_object_span = 5;

pub const Error = error{
    InvalidPageCount,
};

pub const Metadata = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    creator: ?[]const u8 = null,
};

pub const Options = struct {
    metadata: Metadata = .{},
    font_registry: ?*const font.Registry = null,
};

const GlyphMapping = struct {
    glyph_id: u16,
    codepoint: u21,
};

const UsedFont = struct {
    resolved: font.ResolvedFont,
    glyphs: std.ArrayList(GlyphMapping),
};

const FontUsage = struct {
    allocator: std.mem.Allocator,
    registry: ?*const font.Registry,
    fonts: std.ArrayList(UsedFont),

    fn init(allocator: std.mem.Allocator, registry: ?*const font.Registry) !FontUsage {
        return .{
            .allocator = allocator,
            .registry = registry,
            .fonts = try std.ArrayList(UsedFont).initCapacity(allocator, 4),
        };
    }

    fn deinit(self: *FontUsage, allocator: std.mem.Allocator) void {
        for (self.fonts.items) |*used| used.glyphs.deinit(allocator);
        self.fonts.deinit(allocator);
    }

    fn collect(self: *FontUsage, list: *const display_list.DisplayList) !void {
        for (list.commands.items) |page_command| {
            if (page_command.command != .text) continue;
            const run = page_command.command.text;
            const used_index = try self.ensureFont(run);
            const metrics = self.fonts.items[used_index].resolved.metrics();
            if (run.leading_space) try self.add(used_index, metrics.glyphId(' '), ' ');
            var iterator = font.Utf8Iterator{ .bytes = run.text };
            while (try iterator.next()) |codepoint| {
                try self.add(used_index, metrics.glyphId(codepoint), codepoint);
            }
        }
    }

    fn ensureFont(self: *FontUsage, run: display_list.TextRun) !usize {
        const resolved = font.resolve(self.registry, run.font_family, run.font_weight, run.font_style);
        for (self.fonts.items, 0..) |used, index| if (used.resolved.id == resolved.id) return index;
        var glyphs = try std.ArrayList(GlyphMapping).initCapacity(self.allocator, 32);
        errdefer glyphs.deinit(self.allocator);
        try self.fonts.append(self.allocator, .{ .resolved = resolved, .glyphs = glyphs });
        return self.fonts.items.len - 1;
    }

    fn indexForRun(self: *const FontUsage, run: display_list.TextRun) usize {
        const resolved = font.resolve(self.registry, run.font_family, run.font_weight, run.font_style);
        for (self.fonts.items, 0..) |used, index| if (used.resolved.id == resolved.id) return index;
        unreachable;
    }

    fn add(self: *FontUsage, used_index: usize, glyph_id: u16, codepoint: u21) !void {
        for (self.fonts.items[used_index].glyphs.items) |mapping| {
            if (mapping.glyph_id == glyph_id) return;
        }
        try self.fonts.items[used_index].glyphs.append(self.allocator, .{
            .glyph_id = glyph_id,
            .codepoint = codepoint,
        });
    }
};

const AlphaUsage = struct {
    values: std.ArrayList(f32),
    has_transparency: bool = false,

    fn init(allocator: std.mem.Allocator) !AlphaUsage {
        var values = try std.ArrayList(f32).initCapacity(allocator, 1);
        try values.append(allocator, 1);
        return .{ .values = values };
    }

    fn deinit(self: *AlphaUsage, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
    }

    fn collect(self: *AlphaUsage, allocator: std.mem.Allocator, list: *const display_list.DisplayList) !void {
        for (list.commands.items) |page_command| {
            const alpha: ?f32 = switch (page_command.command) {
                .fill_rect => |command| command.color.alpha,
                .fill_rounded_rect => |command| command.color.alpha,
                .stroke_rounded_rect => |command| command.color.alpha,
                .stroke_line => |command| command.color.alpha,
                .text => |command| command.color.alpha,
                .link, .image => null,
            };
            if (alpha) |value| try self.add(allocator, value);
        }
    }

    fn add(self: *AlphaUsage, allocator: std.mem.Allocator, raw: f32) !void {
        const value = std.math.clamp(raw, 0, 1);
        if (value < 0.9999) self.has_transparency = true;
        for (self.values.items) |existing| {
            if (@abs(existing - value) <= 0.0001) return;
        }
        try self.values.append(allocator, value);
    }

    fn index(self: *const AlphaUsage, raw: f32) usize {
        const value = std.math.clamp(raw, 0, 1);
        for (self.values.items, 0..) |existing, alpha_index| {
            if (@abs(existing - value) <= 0.0001) return alpha_index;
        }
        return 0;
    }
};

pub fn write(allocator: std.mem.Allocator, list: *const display_list.DisplayList) ![]u8 {
    return writeWithOptions(allocator, list, .{});
}

pub fn writeWithOptions(allocator: std.mem.Allocator, list: *const display_list.DisplayList, options: Options) ![]u8 {
    if (list.page_count == 0) return Error.InvalidPageCount;

    var font_usage = try FontUsage.init(allocator, options.font_registry);
    defer font_usage.deinit(allocator);
    try font_usage.collect(list);
    var alpha_usage = try AlphaUsage.init(allocator);
    defer alpha_usage.deinit(allocator);
    try alpha_usage.collect(allocator, list);

    const first_page_id = 3 + font_usage.fonts.items.len * font_object_span;
    const page_object_count = first_page_id - 1 + list.page_count * 2;
    const annotation_count = countLinkAnnotations(list);
    const first_annotation_id = page_object_count + 1;
    const image_count = countImages(list);
    const first_image_id = first_annotation_id + annotation_count;
    const info_id = page_object_count + annotation_count + image_count * 2 + 1;
    const object_count = info_id;
    const offsets = try allocator.alloc(usize, object_count + 1);
    defer allocator.free(offsets);
    @memset(offsets, 0);

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;

    try writer.writeAll("%PDF-1.7\n%\xE2\xE3\xCF\xD3\n");

    try beginObject(&output, offsets, 1);
    try writer.writeAll("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    try beginObject(&output, offsets, 2);
    try writer.print("<< /Type /Pages /Count {d} /Kids [", .{list.page_count});
    for (0..list.page_count) |page_index| {
        try writer.print(" {d} 0 R", .{pageObjectId(first_page_id, page_index)});
    }
    try writer.writeAll(" ] >>\nendobj\n");

    for (font_usage.fonts.items, 0..) |used, used_index| {
        try writeEmbeddedFontObjects(
            &output,
            offsets,
            fontObjectBase(used_index),
            used.resolved,
            used.glyphs.items,
        );
    }

    for (0..list.page_count) |page_index| {
        const page_id = pageObjectId(first_page_id, page_index);
        const content_id = contentObjectId(first_page_id, page_index);

        try beginObject(&output, offsets, page_id);
        try writer.print(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.3} {d:.3}] /Resources << /Font <<",
            .{ list.page_spec.width_points, list.page_spec.height_points },
        );
        for (font_usage.fonts.items, 0..) |_, used_index| {
            try writer.print(" /F{d} {d} 0 R", .{ used_index + 1, type0FontObjectId(used_index) });
        }
        try writer.writeAll(" >>");
        if (alpha_usage.has_transparency) {
            try writer.writeAll(" /ExtGState <<");
            for (alpha_usage.values.items, 0..) |alpha, alpha_index| {
                try writer.print(" /GS{d} << /Type /ExtGState /ca {d:.4} /CA {d:.4} >>", .{ alpha_index, alpha, alpha });
            }
            try writer.writeAll(" >>");
        }
        var image_index: usize = 0;
        var wrote_images = false;
        for (list.commands.items) |command| {
            if (command.command == .image) {
                if (command.page_index == page_index) {
                    if (!wrote_images) {
                        try writer.writeAll(" /XObject <<");
                        wrote_images = true;
                    }
                    try writer.print(" /Im{d} {d} 0 R", .{ image_index + 1, first_image_id + image_index * 2 });
                }
                image_index += 1;
            }
        }
        if (wrote_images) try writer.writeAll(" >>");
        try writer.print(" >> /Contents {d} 0 R", .{content_id});
        var annotation_index: usize = 0;
        var wrote_annots = false;
        for (list.commands.items) |command| {
            if (command.command == .link) {
                if (command.page_index == page_index) {
                    if (!wrote_annots) {
                        try writer.writeAll(" /Annots [");
                        wrote_annots = true;
                    }
                    try writer.print(" {d} 0 R", .{first_annotation_id + annotation_index});
                }
                annotation_index += 1;
            }
        }
        if (wrote_annots) try writer.writeAll(" ]");
        try writer.writeAll(" >>\nendobj\n");

        const content = try pageContent(allocator, list, page_index, &font_usage, &alpha_usage);
        defer allocator.free(content);
        const compressed_content = try image_decoder.compressZlib(allocator, content);
        defer allocator.free(compressed_content);
        try beginObject(&output, offsets, content_id);
        try writer.print("<< /Length {d} /Filter /FlateDecode >>\nstream\n", .{compressed_content.len});
        try writer.writeAll(compressed_content);
        try writer.writeAll("\nendstream\nendobj\n");
    }

    var annotation_index: usize = 0;
    for (list.commands.items) |page_command| {
        if (page_command.command != .link) continue;
        try beginObject(&output, offsets, first_annotation_id + annotation_index);
        try writeLinkAnnotation(writer, list, page_command.command.link);
        try writer.writeAll("\nendobj\n");
        annotation_index += 1;
    }

    var image_index: usize = 0;
    for (list.commands.items) |page_command| {
        if (page_command.command != .image) continue;
        try writeImageObjects(
            allocator,
            &output,
            offsets,
            first_image_id + image_index * 2,
            page_command.command.image,
        );
        image_index += 1;
    }

    try beginObject(&output, offsets, info_id);
    try writeDocumentInfo(writer, options.metadata);
    try writer.writeAll("\nendobj\n");

    const xref_offset = output.writer.end;
    try writer.print("xref\n0 {d}\n", .{object_count + 1});
    try writer.writeAll("0000000000 65535 f \n");
    for (1..object_count + 1) |object_id| {
        try writer.print("{d:0>10} 00000 n \n", .{offsets[object_id]});
    }
    try writer.print(
        "trailer\n<< /Size {d} /Root 1 0 R /Info {d} 0 R >>\nstartxref\n{d}\n%%EOF\n",
        .{ object_count + 1, info_id, xref_offset },
    );

    return output.toOwnedSlice();
}

fn pageContent(
    allocator: std.mem.Allocator,
    list: *const display_list.DisplayList,
    page_index: usize,
    font_usage: *const FontUsage,
    alpha_usage: *const AlphaUsage,
) ![]u8 {
    var content = std.Io.Writer.Allocating.init(allocator);
    errdefer content.deinit();
    const writer = &content.writer;
    const scale = geometry.css_px_to_pdf_points;
    const margins = list.page_spec.margins_points;
    const page_height = list.page_spec.height_points;

    try writer.writeAll("q\n");
    var command_index: usize = 0;
    while (command_index < list.commands.items.len) {
        const page_command = list.commands.items[command_index];
        defer command_index += 1;
        if (page_command.page_index != page_index) continue;

        switch (page_command.command) {
            .fill_rect => |fill| {
                const x = margins.left + fill.rect.x * scale;
                const y = page_height - margins.top - (fill.rect.y + fill.rect.height) * scale;
                try writeAlphaState(writer, alpha_usage, fill.color.alpha);
                try writeFillColor(writer, fill.color);
                try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} re f\n", .{
                    x,
                    y,
                    fill.rect.width * scale,
                    fill.rect.height * scale,
                });
            },
            .fill_rounded_rect => |fill| {
                const x = margins.left + fill.rect.x * scale;
                const y = page_height - margins.top - (fill.rect.y + fill.rect.height) * scale;
                const width = fill.rect.width * scale;
                const height = fill.rect.height * scale;
                try writeAlphaState(writer, alpha_usage, fill.color.alpha);
                try writeFillColor(writer, fill.color);
                try writeRoundedRectPath(writer, x, y, width, height, fill.radius * scale);
                try writer.writeAll("f\n");
            },
            .stroke_rounded_rect => |stroke| {
                const x = margins.left + stroke.rect.x * scale;
                const y = page_height - margins.top - (stroke.rect.y + stroke.rect.height) * scale;
                const width = stroke.rect.width * scale;
                const height = stroke.rect.height * scale;
                try writeAlphaState(writer, alpha_usage, stroke.color.alpha);
                try writeStrokeColor(writer, stroke.color);
                switch (stroke.style) {
                    .none, .solid => try writer.writeAll("[] 0 d 0 J\n"),
                    .dashed => try writer.writeAll("[3 2] 0 d 0 J\n"),
                    .dotted => try writer.writeAll("[0.1 2] 0 d 1 J\n"),
                }
                try writer.print("{d:.3} w\n", .{@max(stroke.width * scale, 0.1)});
                try writeRoundedRectPath(writer, x, y, width, height, stroke.radius * scale);
                try writer.writeAll("S\n");
            },
            .stroke_line => |line| {
                const x1 = margins.left + line.from.x * scale;
                const y1 = page_height - margins.top - line.from.y * scale;
                const x2 = margins.left + line.to.x * scale;
                const y2 = page_height - margins.top - line.to.y * scale;
                try writeAlphaState(writer, alpha_usage, line.color.alpha);
                try writeStrokeColor(writer, line.color);
                switch (line.style) {
                    .none, .solid => try writer.writeAll("[] 0 d 0 J\n"),
                    .dashed => try writer.writeAll("[3 2] 0 d 0 J\n"),
                    .dotted => try writer.writeAll("[0.1 2] 0 d 1 J\n"),
                }
                try writer.print("{d:.3} w {d:.3} {d:.3} m {d:.3} {d:.3} l S\n", .{
                    @max(line.width * scale, 0.1),
                    x1,
                    y1,
                    x2,
                    y2,
                });
            },
            .text => |run| {
                const used_font_index = font_usage.indexForRun(run);
                const metrics = font_usage.fonts.items[used_font_index].resolved.metrics();
                const font_size_points = run.font_size * scale;
                const x = margins.left + run.position.x * scale;
                const baseline = page_height - margins.top - (run.position.y + run.font_size * metrics.ascentRatio()) * scale;
                try writeAlphaState(writer, alpha_usage, run.color.alpha);
                try writeFillColor(writer, run.color);
                try writer.print("BT /F{d} {d:.3} Tf {d:.3} Tc 1 0 0 1 {d:.3} {d:.3} Tm <", .{
                    used_font_index + 1,
                    font_size_points,
                    run.letter_spacing * scale,
                    x,
                    baseline,
                });
                if (run.leading_space) try writeGlyphHex(writer, metrics, " ");
                try writeGlyphHex(writer, metrics, run.text);

                var previous_run = run;
                while (command_index + 1 < list.commands.items.len) {
                    const next_command = list.commands.items[command_index + 1];
                    if (next_command.page_index != page_index or next_command.command != .text) break;

                    const next_run = next_command.command.text;
                    if (next_run.line_id != run.line_id or
                        next_run.font_size != run.font_size or
                        next_run.letter_spacing != run.letter_spacing or
                        font_usage.indexForRun(next_run) != used_font_index or
                        !colorsEqual(next_run.color, run.color) or
                        @abs(next_run.position.x - (previous_run.position.x + previous_run.width)) > 0.1) break;

                    if (next_run.leading_space) try writeGlyphHex(writer, metrics, " ");
                    try writeGlyphHex(writer, metrics, next_run.text);
                    previous_run = next_run;
                    command_index += 1;
                }

                try writer.writeAll("> Tj ET\n");
            },
            .link => {},
            .image => |image_command| {
                const image_index = imageIndexAt(list, command_index);
                const x = margins.left + image_command.rect.x * scale;
                const y = page_height - margins.top - (image_command.rect.y + image_command.rect.height) * scale;
                try writeAlphaState(writer, alpha_usage, 1);
                try writer.print("q {d:.3} 0 0 {d:.3} {d:.3} {d:.3} cm /Im{d} Do Q\n", .{
                    image_command.rect.width * scale,
                    image_command.rect.height * scale,
                    x,
                    y,
                    image_index + 1,
                });
            },
        }
    }
    try writer.writeAll("Q");

    return content.toOwnedSlice();
}

fn writeRoundedRectPath(
    writer: *std.Io.Writer,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    requested_radius: f32,
) !void {
    const radius = @max(@min(requested_radius, @min(width, height) / 2), 0);
    if (radius == 0) {
        try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} re\n", .{ x, y, width, height });
        return;
    }

    const control = radius * 0.55228475;
    const right = x + width;
    const top = y + height;
    try writer.print("{d:.3} {d:.3} m\n", .{ x + radius, y });
    try writer.print("{d:.3} {d:.3} l\n", .{ right - radius, y });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{
        right - radius + control, y, right, y + radius - control, right, y + radius,
    });
    try writer.print("{d:.3} {d:.3} l\n", .{ right, top - radius });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{
        right, top - radius + control, right - radius + control, top, right - radius, top,
    });
    try writer.print("{d:.3} {d:.3} l\n", .{ x + radius, top });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{
        x + radius - control, top, x, top - radius + control, x, top - radius,
    });
    try writer.print("{d:.3} {d:.3} l\n", .{ x, y + radius });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c h\n", .{
        x, y + radius - control, x + radius - control, y, x + radius, y,
    });
}

fn countLinkAnnotations(list: *const display_list.DisplayList) usize {
    var count: usize = 0;
    for (list.commands.items) |command| if (command.command == .link) {
        count += 1;
    };
    return count;
}

fn countImages(list: *const display_list.DisplayList) usize {
    var count: usize = 0;
    for (list.commands.items) |command| if (command.command == .image) {
        count += 1;
    };
    return count;
}

fn imageIndexAt(list: *const display_list.DisplayList, command_index: usize) usize {
    var image_index: usize = 0;
    for (list.commands.items[0..command_index]) |command| {
        if (command.command == .image) image_index += 1;
    }
    return image_index;
}

fn writeImageObjects(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    offsets: []usize,
    object_id: usize,
    image_command: display_list.Image,
) !void {
    const writer = &output.writer;
    if (std.mem.startsWith(u8, image_command.source, "data:image/png;base64,")) {
        var png = try image_decoder.decodePngDataUrl(allocator, image_command.source);
        defer png.deinit(allocator);
        const color_space = if (png.color_components == 1) "/DeviceGray" else "/DeviceRGB";
        try beginObject(output, offsets, object_id);
        try writer.print(
            "<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace {s} /BitsPerComponent 8 /Filter /FlateDecode /Length {d}",
            .{ png.width, png.height, color_space, png.color_bytes.len },
        );
        if (png.predictor_encoded) try writer.print(
            " /DecodeParms << /Predictor 15 /Colors {d} /BitsPerComponent 8 /Columns {d} >>",
            .{ png.color_components, png.width },
        );
        if (png.alpha_bytes != null) try writer.print(" /SMask {d} 0 R", .{object_id + 1});
        try writer.writeAll(" >>\nstream\n");
        try writer.writeAll(png.color_bytes);
        try writer.writeAll("\nendstream\nendobj\n");

        try beginObject(output, offsets, object_id + 1);
        if (png.alpha_bytes) |alpha| {
            try writer.print(
                "<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length {d} >>\nstream\n",
                .{ png.width, png.height, alpha.len },
            );
            try writer.writeAll(alpha);
            try writer.writeAll("\nendstream\nendobj\n");
        } else {
            try writer.writeAll("null\nendobj\n");
        }
        return;
    }

    var jpeg = try image_decoder.decodeJpegDataUrl(allocator, image_command.source);
    defer jpeg.deinit(allocator);
    const color_space = switch (jpeg.components) {
        1 => "/DeviceGray",
        3 => "/DeviceRGB",
        4 => "/DeviceCMYK",
        else => return image_decoder.Error.InvalidJpeg,
    };
    try beginObject(output, offsets, object_id);
    try writer.print(
        "<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace {s} /BitsPerComponent 8 /Filter /DCTDecode /Length {d} >>\nstream\n",
        .{ jpeg.width, jpeg.height, color_space, jpeg.bytes.len },
    );
    try writer.writeAll(jpeg.bytes);
    try writer.writeAll("\nendstream\nendobj\n");
    try beginObject(output, offsets, object_id + 1);
    try writer.writeAll("null\nendobj\n");
}

fn writeLinkAnnotation(
    writer: *std.Io.Writer,
    list: *const display_list.DisplayList,
    annotation: display_list.LinkAnnotation,
) !void {
    const scale = geometry.css_px_to_pdf_points;
    const margins = list.page_spec.margins_points;
    const x1 = margins.left + annotation.rect.x * scale;
    const x2 = x1 + annotation.rect.width * scale;
    const y2 = list.page_spec.height_points - margins.top - annotation.rect.y * scale;
    const y1 = y2 - annotation.rect.height * scale;
    try writer.print(
        "<< /Type /Annot /Subtype /Link /Rect [{d:.3} {d:.3} {d:.3} {d:.3}] /Border [0 0 0] /A << /S /URI /URI (",
        .{ x1, y1, x2, y2 },
    );
    try writePdfString(writer, annotation.url);
    try writer.writeAll(") >> >>");
}

fn writeDocumentInfo(writer: *std.Io.Writer, metadata: Metadata) !void {
    try writer.writeAll("<< /Producer ");
    try writePdfTextString(writer, "html2realpdf");
    if (metadata.title) |value| try writeInfoEntry(writer, "Title", value);
    if (metadata.author) |value| try writeInfoEntry(writer, "Author", value);
    if (metadata.subject) |value| try writeInfoEntry(writer, "Subject", value);
    if (metadata.keywords) |value| try writeInfoEntry(writer, "Keywords", value);
    if (metadata.creator) |value| try writeInfoEntry(writer, "Creator", value);
    try writer.writeAll(" >>");
}

fn writeInfoEntry(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.print(" /{s} ", .{key});
    try writePdfTextString(writer, value);
}

fn writePdfTextString(writer: *std.Io.Writer, text: []const u8) !void {
    const ascii = for (text) |byte| {
        if (byte >= 0x80) break false;
    } else true;
    if (ascii) {
        try writer.writeByte('(');
        try writePdfString(writer, text);
        try writer.writeByte(')');
        return;
    }

    try writer.writeAll("<FEFF");
    var iterator = font.Utf8Iterator{ .bytes = text };
    while (try iterator.next()) |codepoint| try writeUnicodeHex(writer, codepoint);
    try writer.writeByte('>');
}

fn colorsEqual(a: geometry.Color, b: geometry.Color) bool {
    return a.red == b.red and a.green == b.green and a.blue == b.blue and a.alpha == b.alpha;
}

fn beginObject(output: *std.Io.Writer.Allocating, offsets: []usize, object_id: usize) !void {
    offsets[object_id] = output.writer.end;
    try output.writer.print("{d} 0 obj\n", .{object_id});
}

fn writeEmbeddedFontObjects(
    output: *std.Io.Writer.Allocating,
    offsets: []usize,
    object_base: usize,
    resolved: font.ResolvedFont,
    usage: []const GlyphMapping,
) !void {
    const metrics = resolved.metrics();
    const name = try std.fmt.allocPrint(output.allocator, "HREALP+{s}", .{resolved.postscript_name});
    defer output.allocator.free(name);
    const glyph_ids = try output.allocator.alloc(u16, usage.len);
    defer output.allocator.free(glyph_ids);
    for (usage, 0..) |mapping, index| glyph_ids[index] = mapping.glyph_id;
    const subset_bytes = try font.subset(output.allocator, metrics.data, glyph_ids);
    defer output.allocator.free(subset_bytes);
    const compressed_subset = try image_decoder.compressZlib(output.allocator, subset_bytes);
    defer output.allocator.free(compressed_subset);

    try beginObject(output, offsets, object_base);
    try output.writer.print("<< /Length {d} /Length1 {d} /Filter /FlateDecode >>\nstream\n", .{ compressed_subset.len, subset_bytes.len });
    try output.writer.writeAll(compressed_subset);
    try output.writer.writeAll("\nendstream\nendobj\n");

    const flags: u32 = 32 |
        (if (resolved.style == .italic) @as(u32, 64) else 0) |
        (if (resolved.weight == .bold) @as(u32, 262144) else 0);
    try beginObject(output, offsets, object_base + 1);
    try output.writer.print(
        "<< /Type /FontDescriptor /FontName /{s} /Flags {d} /FontBBox [{d} {d} {d} {d}] /ItalicAngle {d} /Ascent {d} /Descent {d} /CapHeight {d} /StemV {d} /FontFile2 {d} 0 R >>\nendobj\n",
        .{
            name,
            flags,
            pdfMetric(metrics.x_min, metrics.units_per_em),
            pdfMetric(metrics.y_min, metrics.units_per_em),
            pdfMetric(metrics.x_max, metrics.units_per_em),
            pdfMetric(metrics.y_max, metrics.units_per_em),
            if (resolved.style == .italic) @as(i32, -12) else 0,
            pdfMetric(metrics.ascender, metrics.units_per_em),
            pdfMetric(metrics.descender, metrics.units_per_em),
            pdfMetric(metrics.ascender, metrics.units_per_em),
            if (resolved.weight == .bold) @as(u16, 120) else 80,
            object_base,
        },
    );

    try beginObject(output, offsets, object_base + 2);
    try output.writer.print(
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{s} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {d} 0 R /CIDToGIDMap /Identity /DW 600 /W [0 [",
        .{ name, object_base + 1 },
    );
    for (0..metrics.glyph_count) |glyph_id| {
        try output.writer.print(" {d}", .{pdfAdvance(metrics.advanceWidth(@intCast(glyph_id)), metrics.units_per_em)});
    }
    try output.writer.writeAll(" ]] >>\nendobj\n");

    try writeToUnicodeObject(output, offsets, object_base + 3, resolved.postscript_name, usage);

    try beginObject(output, offsets, object_base + 4);
    try output.writer.print(
        "<< /Type /Font /Subtype /Type0 /BaseFont /{s} /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>\nendobj\n",
        .{ name, object_base + 2, object_base + 3 },
    );
}

fn writeToUnicodeObject(
    output: *std.Io.Writer.Allocating,
    offsets: []usize,
    object_id: usize,
    postscript_name: []const u8,
    usage: []const GlyphMapping,
) !void {
    var cmap = std.Io.Writer.Allocating.init(output.allocator);
    defer cmap.deinit();
    const writer = &cmap.writer;
    try writer.writeAll(
        "/CIDInit /ProcSet findresource begin\n" ++
            "12 dict begin\n" ++
            "begincmap\n" ++
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n",
    );
    try writer.print("/CMapName /{s}-UCS def\n", .{postscript_name});
    try writer.writeAll(
        "/CMapType 2 def\n" ++
            "1 begincodespacerange\n" ++
            "<0000> <FFFF>\n" ++
            "endcodespacerange\n",
    );

    var start: usize = 0;
    while (start < usage.len) {
        const count = @min(usage.len - start, 100);
        try writer.print("{d} beginbfchar\n", .{count});
        for (usage[start .. start + count]) |mapping| {
            try writer.print("<{X:0>4}> <", .{mapping.glyph_id});
            try writeUnicodeHex(writer, mapping.codepoint);
            try writer.writeAll(">\n");
        }
        try writer.writeAll("endbfchar\n");
        start += count;
    }

    try writer.writeAll(
        "endcmap\n" ++
            "CMapName currentdict /CMap defineresource pop\n" ++
            "end\n" ++
            "end",
    );

    try beginObject(output, offsets, object_id);
    try output.writer.print("<< /Length {d} >>\nstream\n", .{cmap.writer.end});
    try output.writer.writeAll(cmap.written());
    try output.writer.writeAll("\nendstream\nendobj\n");
}

fn writeGlyphHex(writer: *std.Io.Writer, metrics: font.Metrics, text: []const u8) !void {
    var iterator = font.Utf8Iterator{ .bytes = text };
    while (try iterator.next()) |codepoint| {
        try writer.print("{X:0>4}", .{metrics.glyphId(codepoint)});
    }
}

fn writeUnicodeHex(writer: *std.Io.Writer, codepoint: u21) !void {
    if (codepoint <= 0xFFFF) {
        try writer.print("{X:0>4}", .{codepoint});
        return;
    }
    const scalar = @as(u32, codepoint) - 0x10000;
    const high: u16 = @intCast(0xD800 + (scalar >> 10));
    const low: u16 = @intCast(0xDC00 + (scalar & 0x3FF));
    try writer.print("{X:0>4}{X:0>4}", .{ high, low });
}

fn pdfMetric(value: i16, units_per_em: u16) i32 {
    return @intCast(@divTrunc(@as(i64, value) * 1000, units_per_em));
}

fn pdfAdvance(value: u16, units_per_em: u16) u16 {
    return @intCast(@divTrunc(@as(u32, value) * 1000, units_per_em));
}

fn pageObjectId(first_page_id: usize, page_index: usize) usize {
    return first_page_id + page_index * 2;
}

fn fontObjectBase(face_index: usize) usize {
    return 3 + face_index * font_object_span;
}

fn type0FontObjectId(face_index: usize) usize {
    return fontObjectBase(face_index) + 4;
}

fn contentObjectId(first_page_id: usize, page_index: usize) usize {
    return pageObjectId(first_page_id, page_index) + 1;
}

fn writeFillColor(writer: *std.Io.Writer, color: geometry.Color) !void {
    try writer.print("{d:.4} {d:.4} {d:.4} rg\n", .{ color.red, color.green, color.blue });
}

fn writeAlphaState(writer: *std.Io.Writer, usage: *const AlphaUsage, alpha: f32) !void {
    if (!usage.has_transparency) return;
    try writer.print("/GS{d} gs\n", .{usage.index(alpha)});
}

fn writeStrokeColor(writer: *std.Io.Writer, color: geometry.Color) !void {
    try writer.print("{d:.4} {d:.4} {d:.4} RG\n", .{ color.red, color.green, color.blue });
}

fn writePdfString(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '(', ')', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...0x1F => try writer.writeByte(' '),
            else => try writer.writeByte(byte),
        }
    }
}

test "write a valid-looking multi-page PDF with selectable text commands" {
    const pagination = @import("pagination.zig");
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 3);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{
        .page_index = 0,
        .command = .{ .text = .{
            .position = .{ .x = 10, .y = 10 },
            .text = "Hello (PDF)",
            .font_size = 16,
            .color = geometry.Color.black,
        } },
    });
    try commands.append(allocator, .{
        .page_index = 0,
        .command = .{ .link = .{
            .rect = .{ .x = 10, .y = 10, .width = 60, .height = 16 },
            .url = "https://example.com",
        } },
    });
    try commands.append(allocator, .{
        .page_index = 1,
        .command = .{ .text = .{
            .position = .{ .x = 10, .y = 10 },
            .text = "Page two",
            .font_size = 16,
            .color = geometry.Color.black,
        } },
    });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 2,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };

    const bytes = try write(allocator, &list);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "%PDF-1.7"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Count 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Subtype /Type0") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/FontFile2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ToUnicode") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "<002B> <0048>") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Subtype /Link") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "https://example.com") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "%%EOF\n"));
}

test "write real fill and stroke alpha through PDF ExtGState" {
    const pagination = @import("pagination.zig");
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 2);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{
        .page_index = 0,
        .command = .{ .fill_rect = .{
            .rect = .{ .x = 10, .y = 10, .width = 80, .height = 30 },
            .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 0.5 },
        } },
    });
    try commands.append(allocator, .{
        .page_index = 0,
        .command = .{ .stroke_line = .{
            .from = .{ .x = 10, .y = 50 },
            .to = .{ .x = 90, .y = 50 },
            .width = 2,
            .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 0.25 },
        } },
    });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    const bytes = try write(allocator, &list);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ExtGState <<") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ca 0.5000 /CA 0.5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ca 0.2500 /CA 0.2500") != null);
}
