//! Intrinsic measurement and containing-size resolution primitives.

const std = @import("std");
const box = @import("../box.zig");
const font = @import("../font.zig");
const line_break = @import("../line_break.zig");
const unicode_case = @import("../unicode_case.zig");

pub const InlineSizes = struct {
    min_content: f32 = 0,
    max_content: f32 = 0,
};

pub const ReplacedSize = struct {
    width: f32,
    height: f32,
    ratio: ?f32,
};

pub fn resolveContentDimension(length: box.Length, reference: f32, non_content: f32, sizing: box.BoxSizing) ?f32 {
    return resolveContentDimensionOptional(length, reference, non_content, sizing);
}

/// Resolves a dimension only when every contextual percentage has a definite
/// containing size. Absolute expressions remain usable in an indefinite axis.
pub fn resolveContentDimensionOptional(length: box.Length, reference: ?f32, non_content: f32, sizing: box.BoxSizing) ?f32 {
    const resolved = switch (length) {
        .auto => return null,
        .px => |value| value,
        .percent => |ratio| (reference orelse return null) * ratio,
        .expression => |value| if (value.dependsOnPercentage())
            value.resolve(reference orelse return null) orelse return null
        else
            value.resolve(reference orelse 0) orelse return null,
        .minContent, .maxContent, .fitContent => return null,
    };
    return contentBoxValue(resolved, non_content, sizing);
}

pub fn resolveContentInlineDimension(
    length: box.Length,
    reference: f32,
    non_content: f32,
    sizing: box.BoxSizing,
    sizes: InlineSizes,
) ?f32 {
    const resolved = switch (length) {
        .minContent => sizes.min_content,
        .maxContent => sizes.max_content,
        .fitContent => |limit| blk: {
            const available = if (limit) |value| value.resolve(reference) orelse return null else reference;
            break :blk @min(sizes.max_content, @max(sizes.min_content, available));
        },
        else => return resolveContentDimension(length, reference, non_content, sizing),
    };
    return contentBoxValue(resolved, non_content, sizing);
}

/// Transfers a non-replaced box's preferred ratio into its auto block axis.
/// The ratio operates on the box selected by `box-sizing`, then returns the
/// content-box height consumed by block layout.
pub fn contentBlockSizeFromAspectRatio(
    style: box.Style,
    content_width: f32,
    horizontal_non_content: f32,
    vertical_non_content: f32,
) ?f32 {
    const ratio = style.aspect_ratio.resolve(null) orelse return null;
    const ratio_width = switch (style.box_sizing) {
        .contentBox => content_width,
        .borderBox => content_width + horizontal_non_content,
    };
    const ratio_height = ratio_width / ratio;
    return switch (style.box_sizing) {
        .contentBox => @max(ratio_height, 0),
        .borderBox => @max(ratio_height - vertical_non_content, 0),
    };
}

fn contentBoxValue(resolved: f32, non_content: f32, sizing: box.BoxSizing) f32 {
    return switch (sizing) {
        .contentBox => @max(resolved, 0),
        .borderBox => @max(resolved - non_content, 0),
    };
}

pub fn resolveReplacedSize(
    style: box.Style,
    intrinsic_width: ?f32,
    intrinsic_height: ?f32,
    available_width: f32,
    available_height: ?f32,
    horizontal_non_content: f32,
    vertical_non_content: f32,
) ReplacedSize {
    const intrinsic_ratio = if (intrinsic_width != null and intrinsic_height != null and intrinsic_height.? > 0)
        intrinsic_width.? / intrinsic_height.?
    else
        null;
    const ratio = style.aspect_ratio.resolve(intrinsic_ratio);
    const natural_width = intrinsic_width orelse 24;
    const inline_sizes = InlineSizes{ .min_content = natural_width, .max_content = natural_width };
    const specified_width = resolveContentInlineDimension(style.width, available_width, horizontal_non_content, style.box_sizing, inline_sizes);
    const specified_height = resolveContentDimensionOptional(style.height, available_height, vertical_non_content, style.box_sizing);

    var width = specified_width orelse intrinsic_width orelse if (specified_height != null and ratio != null) specified_height.? * ratio.? else 24;
    var height = specified_height orelse intrinsic_height orelse if (ratio) |value| width / value else 24;
    if (specified_width == null and specified_height != null and ratio != null) width = height * ratio.?;
    if (specified_height == null and specified_width != null and ratio != null) height = width / ratio.?;

    if (resolveContentInlineDimension(style.min_width, available_width, horizontal_non_content, style.box_sizing, inline_sizes)) |minimum| width = @max(width, minimum);
    if (resolveContentInlineDimension(style.max_width, available_width, horizontal_non_content, style.box_sizing, inline_sizes)) |maximum| width = @min(width, maximum);
    if (specified_height == null and ratio != null) height = width / ratio.?;
    if (resolveContentDimensionOptional(style.min_height, available_height, vertical_non_content, style.box_sizing)) |minimum| height = @max(height, minimum);
    if (resolveContentDimensionOptional(style.max_height, available_height, vertical_non_content, style.box_sizing)) |maximum| height = @min(height, maximum);
    if (specified_width == null and ratio != null) width = height * ratio.?;

    return .{ .width = @max(width, 0), .height = @max(height, 0), .ratio = ratio };
}

/// Measures content-driven inline sizes without assigning a containing block.
/// These contributions are the shared input for block, flex, and grid sizing.
pub fn measureBoxInline(
    allocator: std.mem.Allocator,
    tree: *const box.BoxTree,
    box_id: box.BoxId,
    registry: ?*const font.Registry,
    shaping_mode: font.ShapingMode,
) std.mem.Allocator.Error!InlineSizes {
    const source = tree.boxes.items[box_id];
    if (source.kind == .replaced) {
        const width = source.intrinsic_width orelse 24;
        return .{ .min_content = width, .max_content = width };
    }
    if (source.text) |text| return measureTextIntrinsic(allocator, text, source.style, source.language, registry, shaping_mode);

    var result = InlineSizes{};
    var line_min: f32 = 0;
    var line_max: f32 = 0;
    var child = source.first_child;
    const line_children = source.kind == .tableRow or !hasBlockChildren(tree, box_id);
    while (child) |child_id| {
        const child_box = tree.boxes.items[child_id];
        if (child_box.kind == .lineBreak) {
            result.min_content = @max(result.min_content, line_min);
            result.max_content = @max(result.max_content, line_max);
            line_min = 0;
            line_max = 0;
        } else {
            const measured = try measureBoxInline(allocator, tree, child_id, registry, shaping_mode);
            const contribution = resolveChildContribution(child_box, measured);
            if (line_children) {
                line_min = @max(line_min, contribution.min_content);
                line_max += contribution.max_content;
            } else {
                result.min_content = @max(result.min_content, contribution.min_content);
                result.max_content = @max(result.max_content, contribution.max_content);
            }
        }
        child = child_box.next_sibling;
    }
    if (line_children) {
        result.min_content = @max(result.min_content, line_min);
        result.max_content = @max(result.max_content, line_max);
    }
    result.max_content = @max(result.max_content, result.min_content);
    return result;
}

fn hasBlockChildren(tree: *const box.BoxTree, box_id: box.BoxId) bool {
    var child = tree.boxes.items[box_id].first_child;
    while (child) |child_id| {
        if (isBlockLevel(tree.boxes.items[child_id].kind)) return true;
        child = tree.boxes.items[child_id].next_sibling;
    }
    return false;
}

fn isBlockLevel(kind: box.BoxType) bool {
    return switch (kind) {
        .block, .listItem, .anonymousBlock, .table, .tableRow, .tableCell, .tableRowGroup, .anonymousTableRow => true,
        else => false,
    };
}

fn resolveChildContribution(source: box.Box, measured: InlineSizes) InlineSizes {
    const horizontal_edges = source.margin.left + source.margin.right + source.border.left + source.border.right + source.padding.left + source.padding.right;
    var content = measured;
    if (resolveContentInlineDimension(source.style.width, measured.max_content, source.border.left + source.border.right + source.padding.left + source.padding.right, source.style.box_sizing, measured)) |width| {
        content = .{ .min_content = width, .max_content = width };
    }
    if (resolveContentInlineDimension(source.style.max_width, measured.max_content, 0, .contentBox, measured)) |maximum| {
        content.min_content = @min(content.min_content, maximum);
        content.max_content = @min(content.max_content, maximum);
    }
    if (resolveContentInlineDimension(source.style.min_width, measured.max_content, 0, .contentBox, measured)) |minimum| {
        content.min_content = @max(content.min_content, minimum);
        content.max_content = @max(content.max_content, minimum);
    }
    return .{
        .min_content = @max(content.min_content + horizontal_edges, 0),
        .max_content = @max(content.max_content + horizontal_edges, 0),
    };
}

fn measureTextIntrinsic(
    allocator: std.mem.Allocator,
    text: []const u8,
    style: box.Style,
    language: []const u8,
    registry: ?*const font.Registry,
    shaping_mode: font.ShapingMode,
) std.mem.Allocator.Error!InlineSizes {
    var capitalize_next = true;
    const transformed = switch (style.text_transform) {
        .none => text,
        .uppercase => try unicode_case.transform(allocator, text, .uppercase, language, &capitalize_next),
        .lowercase => try unicode_case.transform(allocator, text, .lowercase, language, &capitalize_next),
        .capitalize => try unicode_case.transform(allocator, text, .capitalize, language, &capitalize_next),
    };
    defer if (style.text_transform != .none) allocator.free(transformed);

    const normalized = try normalizeWhitespace(allocator, transformed, style.white_space);
    defer allocator.free(normalized);
    const max_content = longestForcedLineWidth(registry, shaping_mode, normalized, style);
    if (style.white_space == .nowrap or style.white_space == .pre) {
        return .{ .min_content = max_content, .max_content = max_content };
    }

    const min_content = if (style.word_break == .breakAll or style.overflow_wrap == .anywhere)
        try widestGrapheme(allocator, registry, shaping_mode, normalized, style)
    else
        try widestBreakSegment(allocator, registry, shaping_mode, normalized, style);
    return .{ .min_content = @min(min_content, max_content), .max_content = max_content };
}

fn normalizeWhitespace(allocator: std.mem.Allocator, text: []const u8, mode: box.WhiteSpace) std.mem.Allocator.Error![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer output.deinit(allocator);
    if (mode == .pre or mode == .preWrap) {
        try output.appendSlice(allocator, text);
        return output.toOwnedSlice(allocator);
    }

    var pending_space = false;
    for (text) |byte| {
        if (byte == '\n' and mode == .preLine) {
            while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') _ = output.pop();
            try output.append(allocator, '\n');
            pending_space = false;
        } else if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0C) {
            pending_space = output.items.len > 0 and output.items[output.items.len - 1] != '\n';
        } else {
            if (pending_space) try output.append(allocator, ' ');
            try output.append(allocator, byte);
            pending_space = false;
        }
    }
    return output.toOwnedSlice(allocator);
}

fn longestForcedLineWidth(registry: ?*const font.Registry, shaping_mode: font.ShapingMode, text: []const u8, style: box.Style) f32 {
    var result: f32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| result = @max(result, measureStyledText(registry, shaping_mode, line, style));
    return result;
}

fn widestGrapheme(
    allocator: std.mem.Allocator,
    registry: ?*const font.Registry,
    shaping_mode: font.ShapingMode,
    text: []const u8,
    style: box.Style,
) std.mem.Allocator.Error!f32 {
    const boundaries = try line_break.graphemeBoundariesForLayout(allocator, text);
    defer if (boundaries.len > 0) allocator.free(boundaries);
    var widest: f32 = 0;
    var start: usize = 0;
    for (boundaries, 0..) |boundary, index| {
        if (!boundary) continue;
        widest = @max(widest, measureStyledText(registry, shaping_mode, text[start .. index + 1], style));
        start = index + 1;
    }
    return widest;
}

fn widestBreakSegment(
    allocator: std.mem.Allocator,
    registry: ?*const font.Registry,
    shaping_mode: font.ShapingMode,
    text: []const u8,
    style: box.Style,
) std.mem.Allocator.Error!f32 {
    const opportunities = try line_break.opportunitiesForLayout(allocator, text, null);
    defer if (opportunities.len > 0) allocator.free(opportunities);
    var widest: f32 = 0;
    var start: usize = 0;
    for (opportunities, 0..) |opportunity, index| {
        const ascii_space = text[index] == ' ' or text[index] == '\n';
        if (!opportunity.permitsBreak() or (style.word_break == .keepAll and !ascii_space and index + 1 < text.len)) continue;
        const segment = std.mem.trim(u8, text[start .. index + 1], " \t\n\r\x0C");
        widest = @max(widest, measureStyledText(registry, shaping_mode, segment, style));
        start = index + 1;
    }
    if (start < text.len) widest = @max(widest, measureStyledText(registry, shaping_mode, text[start..], style));
    return widest;
}

fn measureStyledText(registry: ?*const font.Registry, shaping_mode: font.ShapingMode, text: []const u8, style: box.Style) f32 {
    var spaces: usize = 0;
    for (text) |byte| if (byte == ' ') {
        spaces += 1;
    };
    return measureText(registry, shaping_mode, text, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing) +
        @as(f32, @floatFromInt(spaces)) * style.word_spacing;
}

pub fn measureText(
    registry: ?*const font.Registry,
    shaping_mode: font.ShapingMode,
    text: []const u8,
    family: []const u8,
    font_size: f32,
    weight: box.FontWeight,
    style: box.FontStyle,
    letter_spacing: f32,
) f32 {
    return font.measureWithFallback(registry, text, family, font_size, weight, style, letter_spacing, shaping_mode) catch 0;
}

test "resolve replaced sizes from preferred and intrinsic ratios" {
    const sized = resolveReplacedSize(
        .{ .width = .{ .px = 160 }, .aspect_ratio = .{ .ratio = 16.0 / 9.0, .use_intrinsic = false } },
        400,
        300,
        500,
        500,
        0,
        0,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 160), sized.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 90), sized.height, 0.001);

    const intrinsic = resolveReplacedSize(.{}, 320, 200, 500, 500, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 320), intrinsic.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), intrinsic.height, 0.001);
}

test "resolve vertical dimensions only against definite references" {
    const expressions = @import("../css/expressions.zig");
    const allocator = std.testing.allocator;
    var store = try expressions.Store.init(allocator);
    defer store.deinit(allocator);

    const contextual = (try expressions.parse(allocator, &store, "calc(50% - 10px)", .{})).?;
    const absolute = (try expressions.parse(allocator, &store, "calc(40px + 10px)", .{})).?;

    try std.testing.expect(resolveContentDimensionOptional(.{ .percent = 0.5 }, null, 0, .contentBox) == null);
    try std.testing.expect(resolveContentDimensionOptional(.{ .expression = contextual }, null, 0, .contentBox) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 90), resolveContentDimensionOptional(.{ .expression = contextual }, 200, 0, .contentBox).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), resolveContentDimensionOptional(.{ .expression = absolute }, null, 0, .contentBox).?, 0.001);
}

test "clamp intrinsic inline sizing keywords" {
    const sizes = InlineSizes{ .min_content = 80, .max_content = 220 };
    try std.testing.expectApproxEqAbs(@as(f32, 80), resolveContentInlineDimension(.minContent, 150, 0, .contentBox, sizes).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 220), resolveContentInlineDimension(.maxContent, 150, 0, .contentBox, sizes).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), resolveContentInlineDimension(.{ .fitContent = null }, 150, 0, .contentBox, sizes).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), resolveContentInlineDimension(.{ .fitContent = .{ .px = 100 } }, 150, 0, .contentBox, sizes).?, 0.001);
}

test "transfer preferred aspect ratio through content and border boxes" {
    const content_style = box.Style{ .aspect_ratio = .{ .ratio = 16.0 / 9.0, .use_intrinsic = false } };
    try std.testing.expectApproxEqAbs(@as(f32, 90), contentBlockSizeFromAspectRatio(content_style, 160, 30, 30).?, 0.01);

    const border_style = box.Style{
        .box_sizing = .borderBox,
        .aspect_ratio = .{ .ratio = 16.0 / 9.0, .use_intrinsic = false },
    };
    try std.testing.expectApproxEqAbs(@as(f32, 60), contentBlockSizeFromAspectRatio(border_style, 130, 30, 30).?, 0.01);
}
