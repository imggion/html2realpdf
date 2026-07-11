//! Intrinsic measurement and containing-size resolution primitives.

const std = @import("std");
const box = @import("../box.zig");
const font = @import("../font.zig");

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
    };
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
    const specified_width = resolveContentDimension(style.width, available_width, horizontal_non_content, style.box_sizing);
    const specified_height = resolveContentDimensionOptional(style.height, available_height, vertical_non_content, style.box_sizing);

    var width = specified_width orelse intrinsic_width orelse if (specified_height != null and ratio != null) specified_height.? * ratio.? else 24;
    var height = specified_height orelse intrinsic_height orelse if (ratio) |value| width / value else 24;
    if (specified_width == null and specified_height != null and ratio != null) width = height * ratio.?;
    if (specified_height == null and specified_width != null and ratio != null) height = width / ratio.?;

    if (resolveContentDimension(style.min_width, available_width, horizontal_non_content, style.box_sizing)) |minimum| width = @max(width, minimum);
    if (resolveContentDimension(style.max_width, available_width, horizontal_non_content, style.box_sizing)) |maximum| width = @min(width, maximum);
    if (specified_height == null and ratio != null) height = width / ratio.?;
    if (resolveContentDimensionOptional(style.min_height, available_height, vertical_non_content, style.box_sizing)) |minimum| height = @max(height, minimum);
    if (resolveContentDimensionOptional(style.max_height, available_height, vertical_non_content, style.box_sizing)) |maximum| height = @min(height, maximum);
    if (specified_width == null and ratio != null) width = height * ratio.?;

    return .{ .width = @max(width, 0), .height = @max(height, 0), .ratio = ratio };
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
