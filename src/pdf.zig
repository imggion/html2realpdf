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
const pagination = @import("pagination.zig");
const svg = @import("svg.zig");

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
    cid: u16,
    glyph_id: u16,
    unicode: []const u8,
};

const UsedFont = struct {
    resolved: font.ResolvedFont,
    glyphs: std.ArrayList(GlyphMapping),
    next_custom_cid: u32,
    uses_custom_cids: bool = false,
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
            if (run.leading_space) _ = try self.add(used_index, metrics.glyphId(' '), " ");
            if (run.shaped) |shaped| {
                for (shaped.glyphs) |glyph| {
                    _ = try self.add(used_index, glyph.glyph_id, glyphUnicode(run.text, glyph));
                }
            } else {
                var iterator = font.Utf8Iterator{ .bytes = run.text };
                while (true) {
                    const start = iterator.index;
                    const codepoint = try iterator.next() orelse break;
                    _ = try self.add(used_index, metrics.glyphId(codepoint), run.text[start..iterator.index]);
                }
            }
        }
    }

    fn ensureFont(self: *FontUsage, run: display_list.TextRun) !usize {
        const resolved = font.resolve(self.registry, run.font_family, run.font_weight, run.font_style);
        for (self.fonts.items, 0..) |used, index| if (used.resolved.id == resolved.id) return index;
        var glyphs = try std.ArrayList(GlyphMapping).initCapacity(self.allocator, 32);
        errdefer glyphs.deinit(self.allocator);
        try self.fonts.append(self.allocator, .{
            .resolved = resolved,
            .glyphs = glyphs,
            .next_custom_cid = resolved.metrics().glyph_count,
        });
        return self.fonts.items.len - 1;
    }

    fn indexForRun(self: *const FontUsage, run: display_list.TextRun) usize {
        const resolved = font.resolve(self.registry, run.font_family, run.font_weight, run.font_style);
        for (self.fonts.items, 0..) |used, index| if (used.resolved.id == resolved.id) return index;
        unreachable;
    }

    fn add(self: *FontUsage, used_index: usize, glyph_id: u16, unicode: []const u8) !u16 {
        var used = &self.fonts.items[used_index];
        for (used.glyphs.items) |mapping| {
            if (mapping.glyph_id == glyph_id and std.mem.eql(u8, mapping.unicode, unicode)) return mapping.cid;
        }

        var cid = glyph_id;
        for (used.glyphs.items) |mapping| {
            if (mapping.cid != cid) continue;
            if (used.next_custom_cid > std.math.maxInt(u16)) return error.TooManyGlyphMappings;
            cid = @intCast(used.next_custom_cid);
            used.next_custom_cid += 1;
            used.uses_custom_cids = true;
            break;
        }
        try used.glyphs.append(self.allocator, .{
            .cid = cid,
            .glyph_id = glyph_id,
            .unicode = unicode,
        });
        return cid;
    }

    fn cidFor(self: *const FontUsage, used_index: usize, glyph_id: u16, unicode: []const u8) u16 {
        for (self.fonts.items[used_index].glyphs.items) |mapping| {
            if (mapping.glyph_id == glyph_id and std.mem.eql(u8, mapping.unicode, unicode)) return mapping.cid;
        }
        unreachable;
    }

    fn customMapCount(self: *const FontUsage) usize {
        var count: usize = 0;
        for (self.fonts.items) |used| if (used.uses_custom_cids) {
            count += 1;
        };
        return count;
    }

    fn customMapObjectId(self: *const FontUsage, used_index: usize) ?usize {
        if (!self.fonts.items[used_index].uses_custom_cids) return null;
        var ordinal: usize = 0;
        for (self.fonts.items[0..used_index]) |used| if (used.uses_custom_cids) {
            ordinal += 1;
        };
        return 3 + self.fonts.items.len * font_object_span + ordinal;
    }
};

fn glyphUnicode(text: []const u8, glyph: font.ShapedGlyph) []const u8 {
    if (!glyph.maps_cluster) return "";
    const start: usize = glyph.cluster_start;
    const end: usize = glyph.cluster_end;
    if (start > end or end > text.len) return "";
    return text[start..end];
}

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
            for (0..page_command.opacity_groups.len) |depth| try self.add(allocator, page_command.opacity_groups.values[depth]);
            switch (page_command.command) {
                .linear_gradient => |gradient| if (gradientHasVariableAlpha(gradient.stops)) try self.collectGradient(allocator, gradient.stops, page_command.opacity, 128),
                .radial_gradient => |gradient| if (gradientHasVariableAlpha(gradient.stops)) try self.collectGradient(allocator, gradient.stops, page_command.opacity, 96),
                .conic_gradient => |gradient| if (gradientHasVariableAlpha(gradient.stops)) try self.collectGradient(allocator, gradient.stops, page_command.opacity, 180),
                else => {},
            }
            const alpha: ?f32 = switch (page_command.command) {
                .fill_rect => |command| command.color.alpha * page_command.opacity,
                .fill_rounded_rect => |command| command.color.alpha * page_command.opacity,
                .stroke_rounded_rect => |command| command.color.alpha * page_command.opacity,
                .stroke_line => |command| command.color.alpha * page_command.opacity,
                .text => |command| command.color.alpha * page_command.opacity,
                .image => page_command.opacity,
                .linear_gradient => |command| uniformGradientAlpha(command.stops) * page_command.opacity,
                .radial_gradient => |command| uniformGradientAlpha(command.stops) * page_command.opacity,
                .conic_gradient => |command| uniformGradientAlpha(command.stops) * page_command.opacity,
                .box_shadow => |command| boxShadowStepAlpha(command) * page_command.opacity,
                .link => null,
            };
            if (alpha) |value| try self.add(allocator, value);
        }
    }

    fn collectGradient(self: *AlphaUsage, allocator: std.mem.Allocator, stops: display_list.GradientStops, opacity: f32, segments: usize) !void {
        for (0..segments) |segment| {
            const midpoint = (@as(f32, @floatFromInt(segment)) + 0.5) / @as(f32, @floatFromInt(segments));
            try self.add(allocator, quantizeAlpha(gradientColorAt(stops, midpoint).alpha * opacity));
        }
        try self.add(allocator, quantizeAlpha(stops.values[stops.len - 1].color.alpha * opacity));
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

const OpacityGroup = struct {
    page_index: usize,
    id: @import("box.zig").BoxId,
    depth: usize,
    path: @import("box.zig").OpacityGroupPath,
    opacity: f32,
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
    var opacity_groups = try collectOpacityGroups(allocator, list);
    defer opacity_groups.deinit(allocator);

    const first_page_id = 3 + font_usage.fonts.items.len * font_object_span + font_usage.customMapCount();
    const page_object_count = first_page_id - 1 + list.page_count * 2;
    const annotation_count = countLinkAnnotations(list);
    const first_annotation_id = page_object_count + 1;
    const image_count = countImages(list);
    const first_image_id = first_annotation_id + annotation_count;
    const gradient_count = countGradientShadings(list);
    const first_gradient_id = first_image_id + image_count * 2;
    const first_opacity_group_id = first_gradient_id + gradient_count;
    const info_id = first_opacity_group_id + opacity_groups.items.len;
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
            font_usage.customMapObjectId(used_index),
        );
    }

    for (0..list.page_count) |page_index| {
        const page_id = pageObjectId(first_page_id, page_index);
        const content_id = contentObjectId(first_page_id, page_index);
        const page_spec = list.pageSpec(page_index);

        try beginObject(&output, offsets, page_id);
        try writer.print(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.3} {d:.3}] /Resources << /Font <<",
            .{ page_spec.width_points, page_spec.height_points },
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
        for (opacity_groups.items, 0..) |group, group_index| {
            if (group.page_index != page_index) continue;
            if (!wrote_images) {
                try writer.writeAll(" /XObject <<");
                wrote_images = true;
            }
            try writer.print(" /OG{d} {d} 0 R", .{ group_index + 1, first_opacity_group_id + group_index });
        }
        if (wrote_images) try writer.writeAll(" >>");
        var gradient_index: usize = 0;
        var wrote_gradients = false;
        for (list.commands.items) |command| {
            if (isNativeShadingCommand(command.command)) {
                if (command.page_index == page_index) {
                    if (!wrote_gradients) {
                        try writer.writeAll(" /Shading <<");
                        wrote_gradients = true;
                    }
                    try writer.print(" /Sh{d} {d} 0 R", .{ gradient_index + 1, first_gradient_id + gradient_index });
                }
                gradient_index += 1;
            }
        }
        if (wrote_gradients) try writer.writeAll(" >>");
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

        const content = try pageContent(allocator, list, page_index, &font_usage, &alpha_usage, opacity_groups.items, null);
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
        try writeLinkAnnotation(writer, list.pageSpec(page_command.page_index), page_command.command.link, page_command.transform);
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

    var gradient_index: usize = 0;
    for (list.commands.items) |page_command| {
        switch (page_command.command) {
            .linear_gradient, .radial_gradient, .conic_gradient => if (isNativeShadingCommand(page_command.command)) {
                try writeGradientObject(
                    &output,
                    offsets,
                    first_gradient_id + gradient_index,
                    list.pageSpec(page_command.page_index),
                    page_command.command,
                );
                gradient_index += 1;
            },
            else => {},
        }
    }

    for (opacity_groups.items, 0..) |group, group_index| {
        const page_spec = list.pageSpec(group.page_index);
        const content = try pageContent(
            allocator,
            list,
            group.page_index,
            &font_usage,
            &alpha_usage,
            opacity_groups.items,
            group_index,
        );
        defer allocator.free(content);
        const compressed = try image_decoder.compressZlib(allocator, content);
        defer allocator.free(compressed);
        try beginObject(&output, offsets, first_opacity_group_id + group_index);
        try writer.print(
            "<< /Type /XObject /Subtype /Form /FormType 1 /BBox [0 0 {d:.3} {d:.3}] /Group << /S /Transparency /I true /K false >> /Length {d} /Filter /FlateDecode >>\nstream\n",
            .{ page_spec.width_points, page_spec.height_points, compressed.len },
        );
        try writer.writeAll(compressed);
        try writer.writeAll("\nendstream\nendobj\n");
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
    opacity_groups: []const OpacityGroup,
    active_group_index: ?usize,
) ![]u8 {
    var content = std.Io.Writer.Allocating.init(allocator);
    errdefer content.deinit();
    const writer = &content.writer;
    const scale = geometry.css_px_to_pdf_points;
    const page_spec = list.pageSpec(page_index);
    const margins = page_spec.margins_points;
    const page_height = page_spec.height_points;

    try writer.writeAll("q\n");
    var command_index: usize = 0;
    while (command_index < list.commands.items.len) {
        const page_command = list.commands.items[command_index];
        defer command_index += 1;
        if (page_command.page_index != page_index) continue;
        if (active_group_index) |active_index| {
            const active = opacity_groups[active_index];
            const direct_depth = active.depth + 1;
            if (!opacityPathHasPrefix(page_command.opacity_groups, active.path, direct_depth)) continue;
            if (page_command.opacity_groups.len > direct_depth) {
                const nested_id = page_command.opacity_groups.ids[direct_depth];
                const nested_index = findOpacityGroup(opacity_groups, page_index, nested_id) orelse continue;
                try writeOpacityGroupInvocation(writer, alpha_usage, opacity_groups[nested_index], nested_index);
                command_index = lastCommandInOpacityPrefix(list, command_index, page_index, page_command.opacity_groups, direct_depth + 1);
                continue;
            }
        } else if (page_command.opacity_groups.len > 0) {
            const group_id = page_command.opacity_groups.ids[0];
            const group_index = findOpacityGroup(opacity_groups, page_index, group_id) orelse continue;
            try writeOpacityGroupInvocation(writer, alpha_usage, opacity_groups[group_index], group_index);
            command_index = lastCommandInOpacityPrefix(list, command_index, page_index, page_command.opacity_groups, 1);
            continue;
        }
        const has_transform = !page_command.transform.isIdentity();
        if (page_command.clip_rect) |clip| try writeClipRect(writer, page_spec, clip, page_command.clip_radii, page_command.clip_transform);
        if (has_transform) try writeTransformState(writer, page_spec, page_command.transform);

        switch (page_command.command) {
            .fill_rect => |fill| {
                const x = margins.left + fill.rect.x * scale;
                const y = page_height - margins.top - (fill.rect.y + fill.rect.height) * scale;
                try writeAlphaState(writer, alpha_usage, fill.color.alpha * page_command.opacity);
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
                try writeAlphaState(writer, alpha_usage, fill.color.alpha * page_command.opacity);
                try writeFillColor(writer, fill.color);
                try writeRoundedRectPathRadii(writer, x, y, width, height, resolvedCommandRadii(fill.radii, fill.radius, scale));
                try writer.writeAll("f\n");
            },
            .stroke_rounded_rect => |stroke| {
                const x = margins.left + stroke.rect.x * scale;
                const y = page_height - margins.top - (stroke.rect.y + stroke.rect.height) * scale;
                const width = stroke.rect.width * scale;
                const height = stroke.rect.height * scale;
                try writeAlphaState(writer, alpha_usage, stroke.color.alpha * page_command.opacity);
                try writeStrokeColor(writer, stroke.color);
                switch (stroke.style) {
                    .none, .solid => try writer.writeAll("[] 0 d 0 J\n"),
                    .dashed => try writer.writeAll("[3 2] 0 d 0 J\n"),
                    .dotted => try writer.writeAll("[0.1 2] 0 d 1 J\n"),
                }
                try writer.print("{d:.3} w\n", .{@max(stroke.width * scale, 0.1)});
                try writeRoundedRectPathRadii(writer, x, y, width, height, resolvedCommandRadii(stroke.radii, stroke.radius, scale));
                try writer.writeAll("S\n");
            },
            .stroke_line => |line| {
                const x1 = margins.left + line.from.x * scale;
                const y1 = page_height - margins.top - line.from.y * scale;
                const x2 = margins.left + line.to.x * scale;
                const y2 = page_height - margins.top - line.to.y * scale;
                try writeAlphaState(writer, alpha_usage, line.color.alpha * page_command.opacity);
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
                if (run.artifact) try writer.writeAll("/Artifact BMC\n");
                try writeAlphaState(writer, alpha_usage, run.color.alpha * page_command.opacity);
                try writeFillColor(writer, run.color);
                if (requiresPositionedGlyphs(&font_usage.fonts.items[used_font_index], run)) {
                    try writePositionedTextRun(
                        writer,
                        font_usage,
                        used_font_index,
                        run,
                        font_size_points,
                        x,
                        baseline,
                        scale,
                    );
                    if (run.artifact) try writer.writeAll("EMC\n");
                    if (has_transform) try writer.writeAll("Q\n");
                    if (page_command.clip_rect != null) try writer.writeAll("Q\n");
                    continue;
                }
                try writer.print("BT /F{d} {d:.3} Tf {d:.3} Tc 1 0 0 1 {d:.3} {d:.3} Tm ", .{
                    used_font_index + 1,
                    font_size_points,
                    run.letter_spacing * scale,
                    x,
                    baseline,
                });
                try beginTextGlyphs(writer, run.word_spacing);
                try writeTextRunGlyphs(writer, font_usage, used_font_index, run);

                var previous_run = run;
                while (command_index + 1 < list.commands.items.len) {
                    const next_command = list.commands.items[command_index + 1];
                    if (next_command.page_index != page_index or next_command.command != .text) break;

                    const next_run = next_command.command.text;
                    if (next_run.line_id != run.line_id or
                        next_run.font_size != run.font_size or
                        next_run.letter_spacing != run.letter_spacing or
                        next_run.word_spacing != run.word_spacing or
                        font_usage.indexForRun(next_run) != used_font_index or
                        !clipRectsEqual(next_command.clip_rect, page_command.clip_rect) or
                        !clipRadiiEqual(next_command.clip_radii, page_command.clip_radii) or
                        !next_command.clip_transform.approxEqual(page_command.clip_transform, 0.0001) or
                        !next_command.transform.approxEqual(page_command.transform, 0.0001) or
                        !opacityPathsEqual(next_command.opacity_groups, page_command.opacity_groups) or
                        @abs(next_command.opacity - page_command.opacity) > 0.0001 or
                        next_run.artifact != run.artifact or
                        !colorsEqual(next_run.color, run.color) or
                        @abs(next_run.position.x - (previous_run.position.x + previous_run.width)) > 0.1) break;

                    try writeTextRunGlyphs(writer, font_usage, used_font_index, next_run);
                    previous_run = next_run;
                    command_index += 1;
                }

                try endTextGlyphs(writer, run.word_spacing);
                if (run.artifact) try writer.writeAll("EMC\n");
            },
            .link => {},
            .image => |image_command| {
                const image_index = imageIndexAt(list, command_index);
                const fitted = fittedImageRect(image_command);
                const clip_x = margins.left + image_command.rect.x * scale;
                const clip_y = page_height - margins.top - (image_command.rect.y + image_command.rect.height) * scale;
                const x = margins.left + fitted.x * scale;
                const y = page_height - margins.top - (fitted.y + fitted.height) * scale;
                try writeAlphaState(writer, alpha_usage, page_command.opacity);
                try writer.writeAll("q ");
                if (image_command.paint_clip) |paint_clip| {
                    try writePaintClipPath(writer, page_spec, paint_clip, image_command.paint_clip_radii);
                    try writer.writeAll("W n ");
                }
                try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} re W n {d:.3} 0 0 {d:.3} {d:.3} {d:.3} cm /Im{d} Do Q\n", .{
                    clip_x,
                    clip_y,
                    image_command.rect.width * scale,
                    image_command.rect.height * scale,
                    fitted.width * scale,
                    fitted.height * scale,
                    x,
                    y,
                    image_index + 1,
                });
            },
            .linear_gradient => |gradient| linear: {
                if (gradientHasVariableAlpha(gradient.stops)) {
                    try writeLinearAlphaGradient(writer, page_spec, gradient, page_command.opacity, alpha_usage);
                    break :linear;
                }
                const gradient_index = gradientIndexAt(list, command_index);
                try writeAlphaState(writer, alpha_usage, uniformGradientAlpha(gradient.stops) * page_command.opacity);
                try writer.writeAll("q ");
                try writePaintClipPath(writer, page_spec, gradient.paint_rect, gradient.paint_radii);
                try writer.print("W n /Sh{d} sh Q\n", .{gradient_index + 1});
            },
            .radial_gradient => |gradient| radial: {
                if (gradientHasVariableAlpha(gradient.stops)) {
                    try writeRadialAlphaGradient(writer, page_spec, gradient, page_command.opacity, alpha_usage);
                    break :radial;
                }
                const gradient_index = gradientIndexAt(list, command_index);
                const center = cssPointToPdf(page_spec, gradient.center);
                try writeAlphaState(writer, alpha_usage, uniformGradientAlpha(gradient.stops) * page_command.opacity);
                try writer.writeAll("q ");
                try writePaintClipPath(writer, page_spec, gradient.paint_rect, gradient.paint_radii);
                try writer.print("W n {d:.6} 0 0 {d:.6} {d:.3} {d:.3} cm /Sh{d} sh Q\n", .{
                    @max(gradient.radius_x * scale, 0.001),
                    @max(gradient.radius_y * scale, 0.001),
                    center.x,
                    center.y,
                    gradient_index + 1,
                });
            },
            .conic_gradient => |gradient| conic: {
                if (isNativeShadingCommand(page_command.command)) {
                    const gradient_index = gradientIndexAt(list, command_index);
                    try writeAlphaState(writer, alpha_usage, uniformGradientAlpha(gradient.stops) * page_command.opacity);
                    try writer.writeAll("q ");
                    try writePaintClipPath(writer, page_spec, gradient.paint_rect, gradient.paint_radii);
                    try writer.print("W n /Sh{d} sh Q\n", .{gradient_index + 1});
                    break :conic;
                }
                try writeConicGradient(writer, page_spec, gradient, page_command.opacity, alpha_usage);
            },
            .box_shadow => |shadow| try writeBoxShadow(writer, page_spec, shadow, page_command.opacity, alpha_usage),
        }
        if (has_transform) try writer.writeAll("Q\n");
        if (page_command.clip_rect != null) try writer.writeAll("Q\n");
    }
    try writer.writeAll("Q");

    return content.toOwnedSlice();
}

fn writeBoxShadow(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    shadow: display_list.BoxShadow,
    opacity: f32,
    alpha_usage: *const AlphaUsage,
) !void {
    const steps: usize = if (shadow.blur > 0.01) 12 else 1;
    try writeAlphaState(writer, alpha_usage, boxShadowStepAlpha(shadow) * opacity);
    try writeFillColor(writer, shadow.color);
    try writer.writeAll("q\n");
    for (0..steps) |index| {
        const reverse_step = steps - index;
        const blur_expansion = shadow.blur * @as(f32, @floatFromInt(reverse_step)) / @as(f32, @floatFromInt(steps));
        if (shadow.inset) {
            try writePaintClipPath(writer, page_spec, shadow.rect, shadow.radii);
            const inset = @max(shadow.spread + blur_expansion, 0);
            const inner = geometry.Rect{
                .x = shadow.rect.x + inset + shadow.offset_x,
                .y = shadow.rect.y + inset + shadow.offset_y,
                .width = @max(shadow.rect.width - inset * 2, 0),
                .height = @max(shadow.rect.height - inset * 2, 0),
            };
            try writePaintClipPath(writer, page_spec, inner, insetRadii(shadow.radii, inset));
            try writer.writeAll("f*\n");
        } else {
            const expansion = shadow.spread + blur_expansion;
            const outer = geometry.Rect{
                .x = shadow.rect.x + shadow.offset_x - expansion,
                .y = shadow.rect.y + shadow.offset_y - expansion,
                .width = @max(shadow.rect.width + expansion * 2, 0),
                .height = @max(shadow.rect.height + expansion * 2, 0),
            };
            try writePaintClipPath(writer, page_spec, outer, expandRadii(shadow.radii, expansion));
            try writePaintClipPath(writer, page_spec, shadow.rect, shadow.radii);
            try writer.writeAll("f*\n");
        }
    }
    try writer.writeAll("Q\n");
}

fn boxShadowStepAlpha(shadow: display_list.BoxShadow) f32 {
    if (shadow.blur <= 0.01) return shadow.color.alpha;
    return 1 - std.math.pow(f32, 1 - std.math.clamp(shadow.color.alpha, 0, 1), 1.0 / 12.0);
}

fn expandRadii(radii: @import("box.zig").ResolvedBorderRadii, amount: f32) @import("box.zig").ResolvedBorderRadii {
    var result = radii;
    inline for (.{ &result.top_left, &result.top_right, &result.bottom_right, &result.bottom_left }) |corner| {
        corner.x = @max(corner.x + amount, 0);
        corner.y = @max(corner.y + amount, 0);
    }
    return result;
}

fn insetRadii(radii: @import("box.zig").ResolvedBorderRadii, amount: f32) @import("box.zig").ResolvedBorderRadii {
    var result = radii;
    inline for (.{ &result.top_left, &result.top_right, &result.bottom_right, &result.bottom_left }) |corner| {
        corner.x = @max(corner.x - amount, 0);
        corner.y = @max(corner.y - amount, 0);
    }
    return result;
}

fn writePaintClipPath(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    rect: geometry.Rect,
    radii: @import("box.zig").ResolvedBorderRadii,
) !void {
    const scale = geometry.css_px_to_pdf_points;
    const point = cssPointToPdf(page_spec, .{ .x = rect.x, .y = rect.y + rect.height });
    try writeRoundedRectPathRadii(
        writer,
        point.x,
        point.y,
        @max(rect.width * scale, 0),
        @max(rect.height * scale, 0),
        resolvedCommandRadii(radii, 0, scale),
    );
}

fn writeConicGradient(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    gradient: display_list.ConicGradient,
    opacity: f32,
    alpha_usage: *const AlphaUsage,
) !void {
    const rect = gradient.paint_rect;
    const left = gradient.center.x - rect.x;
    const right = rect.x + rect.width - gradient.center.x;
    const top = gradient.center.y - rect.y;
    const bottom = rect.y + rect.height - gradient.center.y;
    const radius = @sqrt(@max(left, right) * @max(left, right) + @max(top, bottom) * @max(top, bottom)) * 1.01;
    const center = cssPointToPdf(page_spec, gradient.center);
    const segments: usize = 180;
    try writer.writeAll("q ");
    try writePaintClipPath(writer, page_spec, rect, gradient.paint_radii);
    try writer.writeAll("W n\n");
    for (0..segments) |index| {
        const start_t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
        const end_t = @as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(segments));
        const midpoint = (start_t + end_t) / 2;
        const color = gradientColorAt(gradient.stops, midpoint);
        const start_angle = gradient.start_angle + start_t * @as(f32, std.math.pi) * 2;
        const end_angle = gradient.start_angle + end_t * @as(f32, std.math.pi) * 2;
        const first = cssPointToPdf(page_spec, .{
            .x = gradient.center.x + @sin(start_angle) * radius,
            .y = gradient.center.y - @cos(start_angle) * radius,
        });
        const second = cssPointToPdf(page_spec, .{
            .x = gradient.center.x + @sin(end_angle) * radius,
            .y = gradient.center.y - @cos(end_angle) * radius,
        });
        try writeAlphaState(writer, alpha_usage, quantizeAlpha(color.alpha * opacity));
        try writeFillColor(writer, color);
        try writer.print("{d:.3} {d:.3} m {d:.3} {d:.3} l {d:.3} {d:.3} l h f\n", .{
            center.x, center.y, first.x, first.y, second.x, second.y,
        });
    }
    try writer.writeAll("Q\n");
}

fn writeLinearAlphaGradient(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    gradient: display_list.LinearGradient,
    opacity: f32,
    alpha_usage: *const AlphaUsage,
) !void {
    const segments: usize = 128;
    const dx = gradient.end.x - gradient.start.x;
    const dy = gradient.end.y - gradient.start.y;
    const length = @max(@sqrt(dx * dx + dy * dy), 0.001);
    const extent = @sqrt(gradient.paint_rect.width * gradient.paint_rect.width + gradient.paint_rect.height * gradient.paint_rect.height) * 1.5;
    const normal_x = -dy / length * extent;
    const normal_y = dx / length * extent;
    try writer.writeAll("q ");
    try writePaintClipPath(writer, page_spec, gradient.paint_rect, gradient.paint_radii);
    try writer.writeAll("W n\n");
    for (0..segments) |segment| {
        const start_t = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(segments));
        const end_t = @as(f32, @floatFromInt(segment + 1)) / @as(f32, @floatFromInt(segments));
        const midpoint = (start_t + end_t) / 2;
        const color = gradientColorAt(gradient.stops, midpoint);
        const start = geometry.Point{ .x = gradient.start.x + dx * start_t, .y = gradient.start.y + dy * start_t };
        const end = geometry.Point{ .x = gradient.start.x + dx * end_t, .y = gradient.start.y + dy * end_t };
        const points = [_]geometry.Point{
            .{ .x = start.x + normal_x, .y = start.y + normal_y },
            .{ .x = end.x + normal_x, .y = end.y + normal_y },
            .{ .x = end.x - normal_x, .y = end.y - normal_y },
            .{ .x = start.x - normal_x, .y = start.y - normal_y },
        };
        try writeAlphaState(writer, alpha_usage, quantizeAlpha(color.alpha * opacity));
        try writeFillColor(writer, color);
        for (points, 0..) |point, index| {
            const pdf_point = cssPointToPdf(page_spec, point);
            try writer.print("{d:.3} {d:.3} {s}\n", .{ pdf_point.x, pdf_point.y, if (index == 0) "m" else "l" });
        }
        try writer.writeAll("h f\n");
    }
    try writer.writeAll("Q\n");
}

fn writeRadialAlphaGradient(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    gradient: display_list.RadialGradient,
    opacity: f32,
    alpha_usage: *const AlphaUsage,
) !void {
    const segments: usize = 96;
    const center = cssPointToPdf(page_spec, gradient.center);
    const scale = geometry.css_px_to_pdf_points;
    try writer.writeAll("q ");
    try writePaintClipPath(writer, page_spec, gradient.paint_rect, gradient.paint_radii);
    try writer.writeAll("W n\n");

    const outside = gradientColorAt(gradient.stops, 1);
    try writeAlphaState(writer, alpha_usage, quantizeAlpha(outside.alpha * opacity));
    try writeFillColor(writer, outside);
    try writePaintClipPath(writer, page_spec, gradient.paint_rect, gradient.paint_radii);
    try writeEllipsePath(writer, center, gradient.radius_x * scale, gradient.radius_y * scale);
    try writer.writeAll("f*\n");

    var segment: usize = 0;
    while (segment < segments) : (segment += 1) {
        const inner_t = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(segments));
        const outer_t = @as(f32, @floatFromInt(segment + 1)) / @as(f32, @floatFromInt(segments));
        const color = gradientColorAt(gradient.stops, (inner_t + outer_t) / 2);
        try writeAlphaState(writer, alpha_usage, quantizeAlpha(color.alpha * opacity));
        try writeFillColor(writer, color);
        try writeEllipsePath(writer, center, gradient.radius_x * outer_t * scale, gradient.radius_y * outer_t * scale);
        if (inner_t > 0.0001) try writeEllipsePath(writer, center, gradient.radius_x * inner_t * scale, gradient.radius_y * inner_t * scale);
        try writer.writeAll(if (inner_t > 0.0001) "f*\n" else "f\n");
    }
    try writer.writeAll("Q\n");
}

fn writeEllipsePath(writer: *std.Io.Writer, center: geometry.Point, radius_x: f32, radius_y: f32) !void {
    const control: f32 = 0.55228475;
    const rx = @max(radius_x, 0);
    const ry = @max(radius_y, 0);
    try writer.print("{d:.3} {d:.3} m\n", .{ center.x + rx, center.y });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{ center.x + rx, center.y + ry * control, center.x + rx * control, center.y + ry, center.x, center.y + ry });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{ center.x - rx * control, center.y + ry, center.x - rx, center.y + ry * control, center.x - rx, center.y });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{ center.x - rx, center.y - ry * control, center.x - rx * control, center.y - ry, center.x, center.y - ry });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c h\n", .{ center.x + rx * control, center.y - ry, center.x + rx, center.y - ry * control, center.x + rx, center.y });
}

fn writeTransformState(writer: *std.Io.Writer, page_spec: pagination.PageSpec, transform: geometry.AffineTransform) !void {
    const scale = geometry.css_px_to_pdf_points;
    const margins = page_spec.margins_points;
    const top = page_spec.height_points - margins.top;
    const pdf_transform = geometry.AffineTransform{
        .a = transform.a,
        .b = -transform.b,
        .c = -transform.c,
        .d = transform.d,
        .e = margins.left + scale * transform.e - transform.a * margins.left + transform.c * top,
        .f = top - scale * transform.f + transform.b * margins.left - transform.d * top,
    };
    try writer.print("q {d:.6} {d:.6} {d:.6} {d:.6} {d:.3} {d:.3} cm\n", .{
        pdf_transform.a,
        pdf_transform.b,
        pdf_transform.c,
        pdf_transform.d,
        pdf_transform.e,
        pdf_transform.f,
    });
}

fn fittedImageRect(command: display_list.Image) geometry.Rect {
    const intrinsic_width = command.intrinsic_width orelse return command.rect;
    const intrinsic_height = command.intrinsic_height orelse return command.rect;
    if (intrinsic_width <= 0 or intrinsic_height <= 0 or command.object_fit == .fill) return command.rect;

    const contain_scale = @min(command.rect.width / intrinsic_width, command.rect.height / intrinsic_height);
    const cover_scale = @max(command.rect.width / intrinsic_width, command.rect.height / intrinsic_height);
    const used_scale: f32 = switch (command.object_fit) {
        .fill => unreachable,
        .contain => contain_scale,
        .cover => cover_scale,
        .none => 1,
        .scaleDown => @min(contain_scale, 1),
    };
    const width = intrinsic_width * used_scale;
    const height = intrinsic_height * used_scale;
    const remaining_x = command.rect.width - width;
    const remaining_y = command.rect.height - height;
    const offset_x = command.object_position.x.resolve(remaining_x) orelse remaining_x * 0.5;
    const offset_y = command.object_position.y.resolve(remaining_y) orelse remaining_y * 0.5;
    return .{
        .x = command.rect.x + offset_x,
        .y = command.rect.y + offset_y,
        .width = width,
        .height = height,
    };
}

fn writeClipRect(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    clip: geometry.Rect,
    radii: ?@import("box.zig").ResolvedBorderRadii,
    transform: geometry.AffineTransform,
) !void {
    if (!transform.isIdentity()) {
        try writer.writeAll("q ");
        try writeTransformedClipPath(writer, page_spec, clip, radii orelse .{}, transform);
        try writer.writeAll("W n\n");
        return;
    }
    const scale = geometry.css_px_to_pdf_points;
    const margins = page_spec.margins_points;
    const x = margins.left + clip.x * scale;
    const y = page_spec.height_points - margins.top - (clip.y + clip.height) * scale;
    try writer.writeAll("q ");
    if (radii) |resolved| {
        try writeRoundedRectPathRadii(writer, x, y, @max(clip.width * scale, 0), @max(clip.height * scale, 0), resolvedCommandRadii(resolved, 0, scale));
        try writer.writeAll("W n\n");
    } else {
        try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} re W n\n", .{
            x,
            y,
            @max(clip.width * scale, 0),
            @max(clip.height * scale, 0),
        });
    }
}

fn writeTransformedClipPath(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    rect: geometry.Rect,
    radii: @import("box.zig").ResolvedBorderRadii,
    transform: geometry.AffineTransform,
) !void {
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;
    if (!radii.hasRadius()) {
        try writeTransformedPoint(writer, page_spec, transform, .{ .x = rect.x, .y = rect.y }, "m");
        try writeTransformedPoint(writer, page_spec, transform, .{ .x = right, .y = rect.y }, "l");
        try writeTransformedPoint(writer, page_spec, transform, .{ .x = right, .y = bottom }, "l");
        try writeTransformedPoint(writer, page_spec, transform, .{ .x = rect.x, .y = bottom }, "l");
        try writer.writeAll("h\n");
        return;
    }

    const control: f32 = 0.55228475;
    const top_left = radii.top_left;
    const top_right = radii.top_right;
    const bottom_right = radii.bottom_right;
    const bottom_left = radii.bottom_left;
    try writeTransformedPoint(writer, page_spec, transform, .{ .x = rect.x + top_left.x, .y = rect.y }, "m");
    try writeTransformedPoint(writer, page_spec, transform, .{ .x = right - top_right.x, .y = rect.y }, "l");
    try writeTransformedCurve(writer, page_spec, transform, .{ .x = right - top_right.x + top_right.x * control, .y = rect.y }, .{ .x = right, .y = rect.y + top_right.y - top_right.y * control }, .{ .x = right, .y = rect.y + top_right.y });
    try writeTransformedPoint(writer, page_spec, transform, .{ .x = right, .y = bottom - bottom_right.y }, "l");
    try writeTransformedCurve(writer, page_spec, transform, .{ .x = right, .y = bottom - bottom_right.y + bottom_right.y * control }, .{ .x = right - bottom_right.x + bottom_right.x * control, .y = bottom }, .{ .x = right - bottom_right.x, .y = bottom });
    try writeTransformedPoint(writer, page_spec, transform, .{ .x = rect.x + bottom_left.x, .y = bottom }, "l");
    try writeTransformedCurve(writer, page_spec, transform, .{ .x = rect.x + bottom_left.x - bottom_left.x * control, .y = bottom }, .{ .x = rect.x, .y = bottom - bottom_left.y + bottom_left.y * control }, .{ .x = rect.x, .y = bottom - bottom_left.y });
    try writeTransformedPoint(writer, page_spec, transform, .{ .x = rect.x, .y = rect.y + top_left.y }, "l");
    try writeTransformedCurve(writer, page_spec, transform, .{ .x = rect.x, .y = rect.y + top_left.y - top_left.y * control }, .{ .x = rect.x + top_left.x - top_left.x * control, .y = rect.y }, .{ .x = rect.x + top_left.x, .y = rect.y });
    try writer.writeAll("h\n");
}

fn writeTransformedPoint(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    transform: geometry.AffineTransform,
    point: geometry.Point,
    operator: []const u8,
) !void {
    const mapped = cssPointToPdf(page_spec, transform.applyPoint(point));
    try writer.print("{d:.3} {d:.3} {s}\n", .{ mapped.x, mapped.y, operator });
}

fn writeTransformedCurve(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    transform: geometry.AffineTransform,
    first: geometry.Point,
    second: geometry.Point,
    end: geometry.Point,
) !void {
    const first_pdf = cssPointToPdf(page_spec, transform.applyPoint(first));
    const second_pdf = cssPointToPdf(page_spec, transform.applyPoint(second));
    const end_pdf = cssPointToPdf(page_spec, transform.applyPoint(end));
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{
        first_pdf.x, first_pdf.y, second_pdf.x, second_pdf.y, end_pdf.x, end_pdf.y,
    });
}

fn cssPointToPdf(page_spec: pagination.PageSpec, point: geometry.Point) geometry.Point {
    return .{
        .x = page_spec.margins_points.left + point.x * geometry.css_px_to_pdf_points,
        .y = page_spec.height_points - page_spec.margins_points.top - point.y * geometry.css_px_to_pdf_points,
    };
}

fn clipRectsEqual(left: ?geometry.Rect, right: ?geometry.Rect) bool {
    if (left == null or right == null) return left == null and right == null;
    const tolerance: f32 = 0.0001;
    return @abs(left.?.x - right.?.x) <= tolerance and
        @abs(left.?.y - right.?.y) <= tolerance and
        @abs(left.?.width - right.?.width) <= tolerance and
        @abs(left.?.height - right.?.height) <= tolerance;
}

fn clipRadiiEqual(left: ?@import("box.zig").ResolvedBorderRadii, right: ?@import("box.zig").ResolvedBorderRadii) bool {
    if (left == null or right == null) return left == null and right == null;
    const tolerance: f32 = 0.0001;
    inline for (.{
        .{ left.?.top_left, right.?.top_left },
        .{ left.?.top_right, right.?.top_right },
        .{ left.?.bottom_right, right.?.bottom_right },
        .{ left.?.bottom_left, right.?.bottom_left },
    }) |pair| {
        if (@abs(pair[0].x - pair[1].x) > tolerance or @abs(pair[0].y - pair[1].y) > tolerance) return false;
    }
    return true;
}

fn resolvedCommandRadii(radii: @import("box.zig").ResolvedBorderRadii, legacy_radius: f32, scale: f32) @import("box.zig").ResolvedBorderRadii {
    var result = if (radii.hasRadius()) radii else @import("box.zig").ResolvedBorderRadii.uniform(legacy_radius);
    inline for (.{ &result.top_left, &result.top_right, &result.bottom_right, &result.bottom_left }) |corner| {
        corner.x *= scale;
        corner.y *= scale;
    }
    return result;
}

fn writeRoundedRectPathRadii(
    writer: *std.Io.Writer,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radii: @import("box.zig").ResolvedBorderRadii,
) !void {
    if (!radii.hasRadius()) {
        try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} re\n", .{ x, y, width, height });
        return;
    }
    const control: f32 = 0.55228475;
    const right = x + width;
    const top = y + height;
    const bottom_left = radii.bottom_left;
    const bottom_right = radii.bottom_right;
    const top_right = radii.top_right;
    const top_left = radii.top_left;
    try writer.print("{d:.3} {d:.3} m\n", .{ x + bottom_left.x, y });
    try writer.print("{d:.3} {d:.3} l\n", .{ right - bottom_right.x, y });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{
        right - bottom_right.x + bottom_right.x * control,
        y,
        right,
        y + bottom_right.y - bottom_right.y * control,
        right,
        y + bottom_right.y,
    });
    try writer.print("{d:.3} {d:.3} l\n", .{ right, top - top_right.y });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{
        right,
        top - top_right.y + top_right.y * control,
        right - top_right.x + top_right.x * control,
        top,
        right - top_right.x,
        top,
    });
    try writer.print("{d:.3} {d:.3} l\n", .{ x + top_left.x, top });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c\n", .{
        x + top_left.x - top_left.x * control,
        top,
        x,
        top - top_left.y + top_left.y * control,
        x,
        top - top_left.y,
    });
    try writer.print("{d:.3} {d:.3} l\n", .{ x, y + bottom_left.y });
    try writer.print("{d:.3} {d:.3} {d:.3} {d:.3} {d:.3} {d:.3} c h\n", .{
        x,
        y + bottom_left.y - bottom_left.y * control,
        x + bottom_left.x - bottom_left.x * control,
        y,
        x + bottom_left.x,
        y,
    });
}

fn countLinkAnnotations(list: *const display_list.DisplayList) usize {
    var count: usize = 0;
    for (list.commands.items) |command| if (command.command == .link) {
        count += 1;
    };
    return count;
}

fn collectOpacityGroups(allocator: std.mem.Allocator, list: *const display_list.DisplayList) !std.ArrayList(OpacityGroup) {
    var groups = try std.ArrayList(OpacityGroup).initCapacity(allocator, 0);
    errdefer groups.deinit(allocator);
    for (list.commands.items) |command| {
        for (0..command.opacity_groups.len) |depth| {
            const id = command.opacity_groups.ids[depth];
            if (findOpacityGroup(groups.items, command.page_index, id) != null) continue;
            try groups.append(allocator, .{
                .page_index = command.page_index,
                .id = id,
                .depth = depth,
                .path = command.opacity_groups,
                .opacity = command.opacity_groups.values[depth],
            });
        }
    }
    return groups;
}

fn findOpacityGroup(groups: []const OpacityGroup, page_index: usize, id: @import("box.zig").BoxId) ?usize {
    for (groups, 0..) |group, index| if (group.page_index == page_index and group.id == id) return index;
    return null;
}

fn writeOpacityGroupInvocation(
    writer: *std.Io.Writer,
    alpha_usage: *const AlphaUsage,
    group: OpacityGroup,
    group_index: usize,
) !void {
    try writer.writeAll("q ");
    try writeAlphaState(writer, alpha_usage, group.opacity);
    try writer.print("/OG{d} Do Q\n", .{group_index + 1});
}

fn lastCommandInOpacityPrefix(
    list: *const display_list.DisplayList,
    start_index: usize,
    page_index: usize,
    path: @import("box.zig").OpacityGroupPath,
    prefix_len: usize,
) usize {
    var last = start_index;
    var index = start_index + 1;
    while (index < list.commands.items.len) : (index += 1) {
        const command = list.commands.items[index];
        if (command.page_index != page_index or !opacityPathHasPrefix(command.opacity_groups, path, prefix_len)) break;
        last = index;
    }
    return last;
}

fn opacityPathHasPrefix(
    candidate: @import("box.zig").OpacityGroupPath,
    prefix: @import("box.zig").OpacityGroupPath,
    prefix_len: usize,
) bool {
    if (candidate.len < prefix_len or prefix.len < prefix_len) return false;
    for (0..prefix_len) |index| if (candidate.ids[index] != prefix.ids[index]) return false;
    return true;
}

fn opacityPathsEqual(left: @import("box.zig").OpacityGroupPath, right: @import("box.zig").OpacityGroupPath) bool {
    if (left.len != right.len) return false;
    for (0..left.len) |index| {
        if (left.ids[index] != right.ids[index] or @abs(left.values[index] - right.values[index]) > 0.0001) return false;
    }
    return true;
}

fn countImages(list: *const display_list.DisplayList) usize {
    var count: usize = 0;
    for (list.commands.items) |command| if (command.command == .image) {
        count += 1;
    };
    return count;
}

fn countGradientShadings(list: *const display_list.DisplayList) usize {
    var count: usize = 0;
    for (list.commands.items) |command| {
        if (isNativeShadingCommand(command.command)) count += 1;
    }
    return count;
}

fn imageIndexAt(list: *const display_list.DisplayList, command_index: usize) usize {
    var image_index: usize = 0;
    for (list.commands.items[0..command_index]) |command| {
        if (command.command == .image) image_index += 1;
    }
    return image_index;
}

fn gradientIndexAt(list: *const display_list.DisplayList, command_index: usize) usize {
    var gradient_index: usize = 0;
    for (list.commands.items[0..command_index]) |command| {
        if (isNativeShadingCommand(command.command)) gradient_index += 1;
    }
    return gradient_index;
}

fn isNativeShadingCommand(command: display_list.Command) bool {
    return switch (command) {
        .linear_gradient => |gradient| !gradientHasVariableAlpha(gradient.stops),
        .radial_gradient => |gradient| !gradientHasVariableAlpha(gradient.stops),
        .conic_gradient => |gradient| !gradientHasVariableAlpha(gradient.stops),
        else => false,
    };
}

fn uniformGradientAlpha(stops: display_list.GradientStops) f32 {
    const values = stops.slice();
    if (values.len == 0) return 1;
    const alpha = values[0].color.alpha;
    for (values[1..]) |stop| if (@abs(stop.color.alpha - alpha) > 0.0001) return 1;
    return alpha;
}

fn gradientHasVariableAlpha(stops: display_list.GradientStops) bool {
    const values = stops.slice();
    if (values.len < 2) return false;
    const alpha = values[0].color.alpha;
    for (values[1..]) |stop| if (@abs(stop.color.alpha - alpha) > 0.0001) return true;
    return false;
}

fn quantizeAlpha(value: f32) f32 {
    return @round(std.math.clamp(value, 0, 1) * 64) / 64;
}

fn gradientColorAt(stops: display_list.GradientStops, raw_offset: f32) geometry.Color {
    const values = stops.slice();
    if (values.len == 0) return geometry.Color.transparent;
    const offset = std.math.clamp(raw_offset, 0, 1);
    if (offset <= values[0].offset) return values[0].color;
    for (values[1..], 1..) |stop, index| {
        if (offset > stop.offset) continue;
        const previous = values[index - 1];
        const span = stop.offset - previous.offset;
        const progress = if (span <= 0.00001) 1 else (offset - previous.offset) / span;
        return .{
            .red = previous.color.red + (stop.color.red - previous.color.red) * progress,
            .green = previous.color.green + (stop.color.green - previous.color.green) * progress,
            .blue = previous.color.blue + (stop.color.blue - previous.color.blue) * progress,
            .alpha = previous.color.alpha + (stop.color.alpha - previous.color.alpha) * progress,
        };
    }
    return values[values.len - 1].color;
}

fn writeGradientObject(
    output: *std.Io.Writer.Allocating,
    offsets: []usize,
    object_id: usize,
    page_spec: pagination.PageSpec,
    command: display_list.Command,
) !void {
    const writer = &output.writer;
    try beginObject(output, offsets, object_id);
    switch (command) {
        .linear_gradient => |gradient| {
            const start = cssPointToPdf(page_spec, gradient.start);
            const end = cssPointToPdf(page_spec, gradient.end);
            try writer.print("<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [{d:.4} {d:.4} {d:.4} {d:.4}] /Domain [0 1] /Extend [true true] /Function ", .{
                start.x, start.y, end.x, end.y,
            });
            try writeGradientFunction(writer, gradient.stops);
            try writer.writeAll(" >>\nendobj\n");
        },
        .radial_gradient => |gradient| {
            try writer.writeAll("<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [0 0 0 0 0 1] /Domain [0 1] /Extend [true true] /Function ");
            try writeGradientFunction(writer, gradient.stops);
            try writer.writeAll(" >>\nendobj\n");
        },
        .conic_gradient => |gradient| {
            const segments: usize = 180;
            const stream_length = segments * 3 * 16 + 1;
            try writer.print(
                "<< /ShadingType 4 /ColorSpace /DeviceRGB /BitsPerCoordinate 16 /BitsPerComponent 8 /BitsPerFlag 8 /Decode [0 {d:.4} 0 {d:.4} 0 1 0 1 0 1] /AntiAlias true /Filter /ASCIIHexDecode /Length {d} >>\nstream\n",
                .{ page_spec.width_points, page_spec.height_points, stream_length },
            );
            const rect = gradient.paint_rect;
            const left = gradient.center.x - rect.x;
            const right = rect.x + rect.width - gradient.center.x;
            const top = gradient.center.y - rect.y;
            const bottom = rect.y + rect.height - gradient.center.y;
            const radius = @sqrt(@max(left, right) * @max(left, right) + @max(top, bottom) * @max(top, bottom)) * 1.02;
            for (0..segments) |segment| {
                const start_t = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(segments));
                const end_t = @as(f32, @floatFromInt(segment + 1)) / @as(f32, @floatFromInt(segments));
                const start_angle = gradient.start_angle + start_t * @as(f32, std.math.pi) * 2;
                const end_angle = gradient.start_angle + end_t * @as(f32, std.math.pi) * 2;
                try writeMeshVertex(writer, page_spec, gradient.center, gradientColorAt(gradient.stops, (start_t + end_t) / 2));
                try writeMeshVertex(writer, page_spec, .{
                    .x = gradient.center.x + @sin(start_angle) * radius,
                    .y = gradient.center.y - @cos(start_angle) * radius,
                }, gradientColorAt(gradient.stops, start_t));
                try writeMeshVertex(writer, page_spec, .{
                    .x = gradient.center.x + @sin(end_angle) * radius,
                    .y = gradient.center.y - @cos(end_angle) * radius,
                }, gradientColorAt(gradient.stops, end_t));
            }
            try writer.writeAll(">\nendstream\nendobj\n");
        },
        else => unreachable,
    }
}

fn writeMeshVertex(writer: *std.Io.Writer, page_spec: pagination.PageSpec, point: geometry.Point, color: geometry.Color) !void {
    const pdf_point = cssPointToPdf(page_spec, point);
    const x: u16 = @intFromFloat(@round(std.math.clamp(pdf_point.x / page_spec.width_points, 0, 1) * 65535));
    const y: u16 = @intFromFloat(@round(std.math.clamp(pdf_point.y / page_spec.height_points, 0, 1) * 65535));
    const red: u8 = @intFromFloat(@round(std.math.clamp(color.red, 0, 1) * 255));
    const green: u8 = @intFromFloat(@round(std.math.clamp(color.green, 0, 1) * 255));
    const blue: u8 = @intFromFloat(@round(std.math.clamp(color.blue, 0, 1) * 255));
    try writer.print("00{X:0>4}{X:0>4}{X:0>2}{X:0>2}{X:0>2}", .{ x, y, red, green, blue });
}

fn writeGradientFunction(writer: *std.Io.Writer, stops: display_list.GradientStops) !void {
    const values = stops.slice();
    if (values.len < 2) {
        try writer.writeAll("<< /FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [0 0 0] /N 1 >>");
        return;
    }
    if (values.len == 2) {
        try writeInterpolationFunction(writer, values[0].color, values[1].color);
        return;
    }
    try writer.writeAll("<< /FunctionType 3 /Domain [0 1] /Functions [");
    for (values[0 .. values.len - 1], values[1..]) |start, end| {
        try writer.writeByte(' ');
        try writeInterpolationFunction(writer, start.color, end.color);
    }
    try writer.writeAll(" ] /Bounds [");
    var previous: f32 = 0;
    for (values[1 .. values.len - 1]) |stop| {
        const bound = std.math.clamp(@max(stop.offset, previous + 0.00001), 0.00001, 0.99999);
        try writer.print(" {d:.6}", .{bound});
        previous = bound;
    }
    try writer.writeAll(" ] /Encode [");
    for (0..values.len - 1) |_| try writer.writeAll(" 0 1");
    try writer.writeAll(" ] >>");
}

fn writeInterpolationFunction(writer: *std.Io.Writer, start: geometry.Color, end: geometry.Color) !void {
    try writer.print("<< /FunctionType 2 /Domain [0 1] /C0 [{d:.6} {d:.6} {d:.6}] /C1 [{d:.6} {d:.6} {d:.6}] /N 1 >>", .{
        start.red, start.green, start.blue, end.red, end.green, end.blue,
    });
}

fn writeImageObjects(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    offsets: []usize,
    object_id: usize,
    image_command: display_list.Image,
) !void {
    const writer = &output.writer;
    if (svg.isDataUrl(image_command.source)) {
        var document = try svg.parseDataUrl(allocator, image_command.source);
        defer document.deinit(allocator);
        const content = try svgFormContent(allocator, document, image_command);
        defer allocator.free(content);
        const compressed = try image_decoder.compressZlib(allocator, content);
        defer allocator.free(compressed);
        try beginObject(output, offsets, object_id);
        try writer.print(
            "<< /Type /XObject /Subtype /Form /FormType 1 /BBox [0 0 1 1] /Resources << >> /Length {d} /Filter /FlateDecode >>\nstream\n",
            .{compressed.len},
        );
        try writer.writeAll(compressed);
        try writer.writeAll("\nendstream\nendobj\n");
        try beginObject(output, offsets, object_id + 1);
        try writer.writeAll("null\nendobj\n");
        return;
    }
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

fn svgFormContent(allocator: std.mem.Allocator, document: svg.Document, image_command: display_list.Image) ![]u8 {
    var content = std.Io.Writer.Allocating.init(allocator);
    errdefer content.deinit();
    const writer = &content.writer;
    const fitted = fittedImageRect(image_command);
    const root_transform = document.formTransform(fitted.width, fitted.height);
    try writer.writeAll("q 0 0 1 1 re W n\n");
    for (document.shapes.items) |shape| {
        if (shape.style.fill == null and (shape.style.stroke == null or shape.style.stroke_width <= 0)) continue;
        const transform = root_transform.multiply(shape.transform);
        try writer.print("q {d:.8} {d:.8} {d:.8} {d:.8} {d:.8} {d:.8} cm\n", .{
            transform.a,
            transform.b,
            transform.c,
            transform.d,
            transform.e,
            transform.f,
        });
        if (shape.style.fill) |fill| try writeFillColor(writer, fill);
        if (shape.style.stroke) |stroke| {
            try writeStrokeColor(writer, stroke);
            try writer.print("{d:.5} w {d} J {d} j {d:.5} M [", .{
                shape.style.stroke_width,
                @intFromEnum(shape.style.line_cap),
                @intFromEnum(shape.style.line_join),
                shape.style.miter_limit,
            });
            for (shape.style.dash_values[0..shape.style.dash_len]) |value| try writer.print(" {d:.5}", .{value});
            try writer.print(" ] {d:.5} d\n", .{shape.style.dash_offset});
        }
        try writeSvgPath(writer, document.ops.items[shape.first_op..][0..shape.op_count]);
        if (shape.style.fill != null and shape.style.stroke != null and shape.style.stroke_width > 0) {
            try writer.writeAll(if (shape.style.fill_rule == .evenodd) "B*\n" else "B\n");
        } else if (shape.style.fill != null) {
            try writer.writeAll(if (shape.style.fill_rule == .evenodd) "f*\n" else "f\n");
        } else {
            try writer.writeAll("S\n");
        }
        try writer.writeAll("Q\n");
    }
    try writer.writeAll("Q\n");
    return content.toOwnedSlice();
}

fn writeSvgPath(writer: *std.Io.Writer, ops: []const svg.PathOp) !void {
    for (ops) |op| switch (op) {
        .move_to => |point| try writer.print("{d:.5} {d:.5} m\n", .{ point.x, point.y }),
        .line_to => |point| try writer.print("{d:.5} {d:.5} l\n", .{ point.x, point.y }),
        .cubic_to => |curve| try writer.print("{d:.5} {d:.5} {d:.5} {d:.5} {d:.5} {d:.5} c\n", .{
            curve.control1.x,
            curve.control1.y,
            curve.control2.x,
            curve.control2.y,
            curve.end.x,
            curve.end.y,
        }),
        .close => try writer.writeAll("h\n"),
    };
}

fn writeLinkAnnotation(
    writer: *std.Io.Writer,
    page_spec: pagination.PageSpec,
    annotation: display_list.LinkAnnotation,
    transform: geometry.AffineTransform,
) !void {
    const scale = geometry.css_px_to_pdf_points;
    const margins = page_spec.margins_points;
    const rect = transform.bounds(annotation.rect);
    const x1 = margins.left + rect.x * scale;
    const x2 = x1 + rect.width * scale;
    const y2 = page_spec.height_points - margins.top - rect.y * scale;
    const y1 = y2 - rect.height * scale;
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
    cid_to_gid_object_id: ?usize,
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
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{s} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {d} 0 R /CIDToGIDMap ",
        .{ name, object_base + 1 },
    );
    if (cid_to_gid_object_id) |map_object_id| {
        try output.writer.print("{d} 0 R", .{map_object_id});
    } else {
        try output.writer.writeAll("/Identity");
    }
    try output.writer.writeAll(" /DW 600 /W [0 [");
    const width_count: usize = if (cid_to_gid_object_id != null) maxCid(usage) + 1 else metrics.glyph_count;
    for (0..width_count) |cid| {
        const glyph_id = glyphForCid(usage, @intCast(cid));
        try output.writer.print(" {d}", .{pdfAdvance(metrics.advanceWidth(glyph_id), metrics.units_per_em)});
    }
    try output.writer.writeAll(" ]] >>\nendobj\n");

    try writeToUnicodeObject(output, offsets, object_base + 3, resolved.postscript_name, usage);

    try beginObject(output, offsets, object_base + 4);
    try output.writer.print(
        "<< /Type /Font /Subtype /Type0 /BaseFont /{s} /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>\nendobj\n",
        .{ name, object_base + 2, object_base + 3 },
    );

    if (cid_to_gid_object_id) |map_object_id| {
        try writeCidToGidMapObject(output, offsets, map_object_id, usage);
    }
}

fn maxCid(usage: []const GlyphMapping) usize {
    var maximum: u16 = 0;
    for (usage) |mapping| maximum = @max(maximum, mapping.cid);
    return maximum;
}

fn glyphForCid(usage: []const GlyphMapping, cid: u16) u16 {
    for (usage) |mapping| if (mapping.cid == cid) return mapping.glyph_id;
    return cid;
}

fn writeCidToGidMapObject(
    output: *std.Io.Writer.Allocating,
    offsets: []usize,
    object_id: usize,
    usage: []const GlyphMapping,
) !void {
    const cid_count = maxCid(usage) + 1;
    const mapping = try output.allocator.alloc(u8, cid_count * 2);
    defer output.allocator.free(mapping);
    for (0..cid_count) |cid| {
        const glyph_id = glyphForCid(usage, @intCast(cid));
        mapping[cid * 2] = @truncate(glyph_id >> 8);
        mapping[cid * 2 + 1] = @truncate(glyph_id);
    }
    const compressed = try image_decoder.compressZlib(output.allocator, mapping);
    defer output.allocator.free(compressed);
    try beginObject(output, offsets, object_id);
    try output.writer.print("<< /Length {d} /Filter /FlateDecode >>\nstream\n", .{compressed.len});
    try output.writer.writeAll(compressed);
    try output.writer.writeAll("\nendstream\nendobj\n");
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
            try writer.print("<{X:0>4}> <", .{mapping.cid});
            try writeUnicodeTextHex(writer, mapping.unicode);
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

fn writeGlyphHex(writer: *std.Io.Writer, usage: *const FontUsage, used_index: usize, text: []const u8) !void {
    const metrics = usage.fonts.items[used_index].resolved.metrics();
    var iterator = font.Utf8Iterator{ .bytes = text };
    while (true) {
        const start = iterator.index;
        const codepoint = try iterator.next() orelse break;
        const cid = usage.cidFor(used_index, metrics.glyphId(codepoint), text[start..iterator.index]);
        try writer.print("{X:0>4}", .{cid});
    }
}

fn beginTextGlyphs(writer: *std.Io.Writer, word_spacing: f32) !void {
    try writer.writeAll(if (word_spacing == 0) "<" else "[<");
}

fn endTextGlyphs(writer: *std.Io.Writer, word_spacing: f32) !void {
    try writer.writeAll(if (word_spacing == 0) "> Tj ET\n" else ">] TJ ET\n");
}

/// Emit explicit TJ adjustments after word separators. Type 0 fonts use
/// two-byte character codes, so PDF's `Tw` operator cannot reliably identify
/// U+0020; TJ keeps spacing deterministic for every embedded font subset.
fn writeTextRunGlyphs(
    writer: *std.Io.Writer,
    usage: *const FontUsage,
    used_index: usize,
    run: display_list.TextRun,
) !void {
    if (run.leading_space) {
        try writeGlyphHex(writer, usage, used_index, " ");
        try writeWordSpacingAdjustment(writer, run.word_spacing, run.font_size);
    }

    if (run.shaped) |shaped| {
        for (shaped.glyphs) |glyph| {
            const unicode = glyphUnicode(run.text, glyph);
            try writer.print("{X:0>4}", .{usage.cidFor(used_index, glyph.glyph_id, unicode)});
            if (unicode.len == 1 and unicode[0] == ' ') {
                try writeWordSpacingAdjustment(writer, run.word_spacing, run.font_size);
            }
        }
        return;
    }

    var iterator = font.Utf8Iterator{ .bytes = run.text };
    var chunk_start: usize = 0;
    while (try iterator.next()) |codepoint| {
        if (codepoint != ' ' or run.word_spacing == 0) continue;
        try writeGlyphHex(writer, usage, used_index, run.text[chunk_start..iterator.index]);
        try writeWordSpacingAdjustment(writer, run.word_spacing, run.font_size);
        chunk_start = iterator.index;
    }
    try writeGlyphHex(writer, usage, used_index, run.text[chunk_start..]);
}

fn writeWordSpacingAdjustment(writer: *std.Io.Writer, word_spacing: f32, font_size: f32) !void {
    if (word_spacing == 0) return;
    const adjustment = -word_spacing * 1000 / @max(font_size, 0.001);
    try writer.print("> {d:.3} <", .{adjustment});
}

fn requiresPositionedGlyphs(used: *const UsedFont, run: display_list.TextRun) bool {
    const shaped = run.shaped orelse return false;
    if (shaped.direction == .rtl) return true;
    const metrics = used.resolved.metrics();
    for (shaped.glyphs) |glyph| {
        if (glyph.x_advance != metrics.advanceWidth(glyph.glyph_id) or
            glyph.y_advance != 0 or glyph.x_offset != 0 or glyph.y_offset != 0 or !glyph.maps_cluster) return true;
    }
    return false;
}

fn writePositionedTextRun(
    writer: *std.Io.Writer,
    usage: *const FontUsage,
    used_index: usize,
    run: display_list.TextRun,
    font_size_points: f32,
    origin_x_points: f32,
    baseline_points: f32,
    css_to_points: f32,
) !void {
    const shaped = run.shaped orelse return;
    const used = &usage.fonts.items[used_index];
    const metrics = used.resolved.metrics();
    const units_to_css = run.font_size / @as(f32, @floatFromInt(metrics.units_per_em));

    try writer.writeAll("/Span << /ActualText <FEFF");
    if (run.leading_space) try writeUnicodeTextHex(writer, " ");
    try writeUnicodeTextHex(writer, run.text);
    try writer.writeAll("> >> BDC\n");

    var cursor_x_css: f32 = 0;
    var cursor_y_css: f32 = 0;
    if (run.leading_space) {
        const glyph_id = metrics.glyphId(' ');
        const cid = usage.cidFor(used_index, glyph_id, " ");
        try writePositionedGlyph(writer, used_index, font_size_points, origin_x_points, baseline_points, cid);
        cursor_x_css += @as(f32, @floatFromInt(metrics.advanceWidth(glyph_id))) * units_to_css + run.letter_spacing + run.word_spacing;
    }

    for (shaped.glyphs) |glyph| {
        const unicode = glyphUnicode(run.text, glyph);
        const cid = usage.cidFor(used_index, glyph.glyph_id, unicode);
        const glyph_x = origin_x_points + (cursor_x_css + @as(f32, @floatFromInt(glyph.x_offset)) * units_to_css) * css_to_points;
        const glyph_y = baseline_points + (cursor_y_css + @as(f32, @floatFromInt(glyph.y_offset)) * units_to_css) * css_to_points;
        try writePositionedGlyph(writer, used_index, font_size_points, glyph_x, glyph_y, cid);
        cursor_x_css += @as(f32, @floatFromInt(glyph.x_advance)) * units_to_css;
        cursor_y_css += @as(f32, @floatFromInt(glyph.y_advance)) * units_to_css;
        if (glyph.maps_cluster) cursor_x_css += run.letter_spacing;
        if (unicode.len == 1 and unicode[0] == ' ') cursor_x_css += run.word_spacing;
    }
    try writer.writeAll("EMC\n");
}

fn writePositionedGlyph(
    writer: *std.Io.Writer,
    used_index: usize,
    font_size_points: f32,
    x: f32,
    y: f32,
    cid: u16,
) !void {
    try writer.print("BT /F{d} {d:.3} Tf 0 Tc 1 0 0 1 {d:.3} {d:.3} Tm <{X:0>4}> Tj ET\n", .{
        used_index + 1,
        font_size_points,
        x,
        y,
        cid,
    });
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

fn writeUnicodeTextHex(writer: *std.Io.Writer, text: []const u8) !void {
    var iterator = font.Utf8Iterator{ .bytes = text };
    while (try iterator.next()) |codepoint| try writeUnicodeHex(writer, codepoint);
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
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 2);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{
        .page_index = 0,
        .opacity = 0.5,
        .command = .{ .fill_rect = .{
            .rect = .{ .x = 10, .y = 10, .width = 80, .height = 30 },
            .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 0.5 },
        } },
    });
    try commands.append(allocator, .{
        .page_index = 0,
        .opacity = 0.5,
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ca 0.2500 /CA 0.2500") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ca 0.1250 /CA 0.1250") != null);
}

test "serialize Web gradients as axial radial and mesh PDF shadings" {
    const allocator = std.testing.allocator;
    const stops = display_list.GradientStops{
        .values = blk: {
            var values: [16]display_list.GradientStop = @splat(.{ .offset = 0, .color = geometry.Color.transparent });
            values[0] = .{ .offset = 0, .color = .{ .red = 1, .green = 0, .blue = 0 } };
            values[1] = .{ .offset = 0.5, .color = .{ .red = 0, .green = 1, .blue = 0 } };
            values[2] = .{ .offset = 1, .color = .{ .red = 0, .green = 0, .blue = 1 } };
            break :blk values;
        },
        .len = 3,
    };
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 3);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{ .page_index = 0, .command = .{ .linear_gradient = .{
        .paint_rect = .{ .width = 100, .height = 40 },
        .start = .{ .x = 0, .y = 20 },
        .end = .{ .x = 100, .y = 20 },
        .stops = stops,
    } } });
    try commands.append(allocator, .{ .page_index = 0, .command = .{ .radial_gradient = .{
        .paint_rect = .{ .y = 50, .width = 100, .height = 40 },
        .center = .{ .x = 50, .y = 70 },
        .radius_x = 50,
        .radius_y = 20,
        .stops = stops,
    } } });
    try commands.append(allocator, .{ .page_index = 0, .command = .{ .conic_gradient = .{
        .paint_rect = .{ .y = 100, .width = 100, .height = 40 },
        .center = .{ .x = 50, .y = 120 },
        .start_angle = 0,
        .stops = stops,
    } } });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    const bytes = try write(allocator, &list);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Shading << /Sh1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ShadingType 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ShadingType 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ShadingType 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/FunctionType 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Subtype /Image") == null);
}

test "serialize nested opacity as isolated PDF transparency groups" {
    const allocator = std.testing.allocator;
    var outer_path = @import("box.zig").OpacityGroupPath{};
    outer_path.append(10, 0.5);
    var inner_path = outer_path;
    inner_path.append(11, 0.4);
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 3);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{ .page_index = 0, .opacity_groups = outer_path, .command = .{ .fill_rect = .{
        .rect = .{ .width = 80, .height = 40 },
        .color = .{ .red = 1, .green = 0, .blue = 0 },
    } } });
    try commands.append(allocator, .{ .page_index = 0, .opacity_groups = outer_path, .command = .{ .fill_rect = .{
        .rect = .{ .x = 30, .width = 80, .height = 40 },
        .color = .{ .red = 0, .green = 0, .blue = 1 },
    } } });
    try commands.append(allocator, .{ .page_index = 0, .opacity_groups = inner_path, .command = .{ .fill_rect = .{
        .rect = .{ .x = 20, .y = 10, .width = 40, .height = 20 },
        .color = .{ .red = 0, .green = 1, .blue = 0 },
    } } });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    const bytes = try write(allocator, &list);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "/Group << /S /Transparency /I true"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/OG1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/OG2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ca 0.5000 /CA 0.5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/ca 0.4000 /CA 0.4000") != null);
}

test "write word spacing with Type 0 font TJ adjustments" {
    const allocator = std.testing.allocator;
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const run = display_list.TextRun{
        .position = .{},
        .text = "one two",
        .font_size = 16,
        .word_spacing = 4,
        .color = geometry.Color.black,
    };
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 1);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{ .page_index = 0, .command = .{ .text = run } });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = @import("pagination.zig").PageSpec.standard(.a4, .portrait, .{}),
    };
    var usage = try FontUsage.init(allocator, null);
    defer usage.deinit(allocator);
    try usage.collect(&list);
    try beginTextGlyphs(&output.writer, run.word_spacing);
    try writeTextRunGlyphs(&output.writer, &usage, 0, run);
    try endTextGlyphs(&output.writer, run.word_spacing);
    const content = output.written();
    try std.testing.expect(std.mem.count(u8, content, "<") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, content, ">] TJ ET") != null);
}

test "map shaped ligature clusters and conflicting glyph Unicode through custom CIDs" {
    const allocator = std.testing.allocator;
    const resolved = font.resolve(null, "Noto Sans", .normal, .normal);
    const glyph_id = resolved.metrics().glyphId('f');
    const ligature_glyphs = [_]font.ShapedGlyph{.{
        .glyph_id = glyph_id,
        .x_advance = resolved.metrics().advanceWidth(glyph_id),
        .cluster_start = 0,
        .cluster_end = 2,
    }};
    const plain_glyphs = [_]font.ShapedGlyph{.{
        .glyph_id = glyph_id,
        .x_advance = resolved.metrics().advanceWidth(glyph_id),
        .cluster_start = 0,
        .cluster_end = 1,
    }};
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 2);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{ .page_index = 0, .command = .{ .text = .{
        .position = .{ .x = 10, .y = 10 },
        .text = "fi",
        .shaped = .{ .glyphs = &ligature_glyphs },
        .font_size = 16,
        .color = geometry.Color.black,
    } } });
    try commands.append(allocator, .{ .page_index = 0, .command = .{ .text = .{
        .position = .{ .x = 20, .y = 10 },
        .text = "f",
        .shaped = .{ .glyphs = &plain_glyphs },
        .font_size = 16,
        .color = geometry.Color.black,
    } } });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    const bytes = try write(allocator, &list);
    defer allocator.free(bytes);

    var expected_ligature = std.Io.Writer.Allocating.init(allocator);
    defer expected_ligature.deinit();
    try expected_ligature.writer.print("<{X:0>4}> <00660069>", .{glyph_id});
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected_ligature.written()) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/CIDToGIDMap /Identity") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/CIDToGIDMap ") != null);
}

test "wrap clipped paint commands in PDF graphics state" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 1);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{
        .page_index = 0,
        .clip_rect = .{ .x = 10, .y = 10, .width = 40, .height = 20 },
        .command = .{ .fill_rect = .{
            .rect = .{ .width = 100, .height = 100 },
            .color = geometry.Color.black,
        } },
    });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    var font_usage = try FontUsage.init(allocator, null);
    defer font_usage.deinit(allocator);
    try font_usage.collect(&list);
    var alpha_usage = try AlphaUsage.init(allocator);
    defer alpha_usage.deinit(allocator);
    try alpha_usage.collect(allocator, &list);
    const content = try pageContent(allocator, &list, 0, &font_usage, &alpha_usage, &.{}, null);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, " re W n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Q\nQ") != null);
}

test "serialize elliptical rounded paths and rounded clipping as PDF curves" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 1);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{
        .page_index = 0,
        .clip_rect = .{ .x = 10, .y = 10, .width = 80, .height = 40 },
        .clip_radii = .{
            .top_left = .{ .x = 12, .y = 6 },
            .top_right = .{ .x = 18, .y = 9 },
            .bottom_right = .{ .x = 4, .y = 8 },
            .bottom_left = .{ .x = 10, .y = 5 },
        },
        .command = .{ .fill_rounded_rect = .{
            .rect = .{ .x = 5, .y = 5, .width = 100, .height = 60 },
            .radii = .{
                .top_left = .{ .x = 20, .y = 8 },
                .top_right = .{ .x = 10, .y = 16 },
                .bottom_right = .{ .x = 6, .y = 12 },
                .bottom_left = .{ .x = 14, .y = 7 },
            },
            .color = geometry.Color.black,
        } },
    });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    var font_usage = try FontUsage.init(allocator, null);
    defer font_usage.deinit(allocator);
    try font_usage.collect(&list);
    var alpha_usage = try AlphaUsage.init(allocator);
    defer alpha_usage.deinit(allocator);
    try alpha_usage.collect(allocator, &list);
    const content = try pageContent(allocator, &list, 0, &font_usage, &alpha_usage, &.{}, null);
    defer allocator.free(content);

    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, content, " c\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, content, " c h\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "W n\n"));
    try std.testing.expect(std.mem.indexOf(u8, content, " re W n\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "f\nQ\nQ") != null);
}

test "serialize CSS transforms as PDF matrices and transform link bounds" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 2);
    defer commands.deinit(allocator);
    const transform = geometry.AffineTransform.translation(10, 20);
    try commands.append(allocator, .{
        .page_index = 0,
        .transform = transform,
        .command = .{ .fill_rect = .{
            .rect = .{ .x = 5, .y = 5, .width = 20, .height = 10 },
            .color = geometry.Color.black,
        } },
    });
    try commands.append(allocator, .{
        .page_index = 0,
        .transform = transform,
        .command = .{ .link = .{
            .rect = .{ .x = 5, .y = 5, .width = 20, .height = 10 },
            .url = "https://example.com/transformed",
        } },
    });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = pagination.PageSpec{ .width_points = 150, .height_points = 150 },
    };
    var font_usage = try FontUsage.init(allocator, null);
    defer font_usage.deinit(allocator);
    try font_usage.collect(&list);
    var alpha_usage = try AlphaUsage.init(allocator);
    defer alpha_usage.deinit(allocator);
    try alpha_usage.collect(allocator, &list);
    const content = try pageContent(allocator, &list, 0, &font_usage, &alpha_usage, &.{}, null);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "1.000000 -0.000000 -0.000000 1.000000 7.500 -15.000 cm") != null);

    var annotation_output = std.Io.Writer.Allocating.init(allocator);
    defer annotation_output.deinit();
    try writeLinkAnnotation(&annotation_output.writer, list.page_spec, commands.items[1].command.link, transform);
    try std.testing.expect(std.mem.indexOf(u8, annotation_output.written(), "/Rect [11.250 123.750 26.250 131.250]") != null);
}

test "fit and position native images inside their content box" {
    const contain = fittedImageRect(.{
        .rect = .{ .width = 100, .height = 100 },
        .source = "data:image/png;base64,",
        .intrinsic_width = 200,
        .intrinsic_height = 100,
        .object_fit = .contain,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 100), contain.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), contain.height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 25), contain.y, 0.001);

    const cover = fittedImageRect(.{
        .rect = .{ .width = 100, .height = 100 },
        .source = "data:image/png;base64,",
        .intrinsic_width = 200,
        .intrinsic_height = 100,
        .object_fit = .cover,
        .object_position = .{ .x = .{ .percent = 1 }, .y = .{ .percent = 0.5 } },
    });
    try std.testing.expectApproxEqAbs(@as(f32, 200), cover.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -100), cover.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cover.y, 0.001);
}

test "preserve supported SVG images as native PDF Form XObjects" {
    const allocator = std.testing.allocator;
    const xml = "<svg viewBox='0 0 100 50'><rect x='5' y='5' width='90' height='40' rx='8' fill='#2563eb'/><path d='M20 30 C35 5 65 45 80 20' fill='none' stroke='#111827' stroke-width='3'/></svg>";
    const encoded_len = std.base64.standard.Encoder.calcSize(xml.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, xml);
    const source = try std.fmt.allocPrint(allocator, "data:image/svg+xml;base64,{s}", .{encoded});
    defer allocator.free(source);

    var commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 1);
    defer commands.deinit(allocator);
    try commands.append(allocator, .{
        .page_index = 0,
        .command = .{ .image = .{
            .rect = .{ .x = 10, .y = 20, .width = 200, .height = 100 },
            .source = source,
            .intrinsic_width = 100,
            .intrinsic_height = 50,
        } },
    });
    const list = display_list.DisplayList{
        .commands = commands,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    const bytes = try write(allocator, &list);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Subtype /Form") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Subtype /Image") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/Im1 ") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "%%EOF\n"));
}
