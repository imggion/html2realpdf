//! Physical border painting and rounded uniform-border detection.

const std = @import("std");
const geometry = @import("../geometry.zig");
const layout = @import("../layout.zig");
const box = @import("../box.zig");
const types = @import("types.zig");

pub fn append(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    const rect = fragment.rect;
    const border = fragment.border;
    const paint = fragment.border_paint;
    if (fragment.border_radius > 0 and uniformBorder(border, paint)) {
        try commands.append(allocator, .{
            .page_index = page_index,
            .command = .{ .stroke_rounded_rect = .{
                .rect = rect,
                .radius = fragment.border_radius,
                .width = border.top,
                .color = paint.top_color,
                .style = paint.top_style,
            } },
        });
        return;
    }
    if (border.top > 0 and paint.top_style != .none) try appendLine(allocator, commands, page_index, .{ .x = rect.x, .y = rect.y }, .{ .x = rect.x + rect.width, .y = rect.y }, border.top, paint.top_color, paint.top_style);
    if (border.right > 0 and paint.right_style != .none) try appendLine(allocator, commands, page_index, .{ .x = rect.x + rect.width, .y = rect.y }, .{ .x = rect.x + rect.width, .y = rect.y + rect.height }, border.right, paint.right_color, paint.right_style);
    if (border.bottom > 0 and paint.bottom_style != .none) try appendLine(allocator, commands, page_index, .{ .x = rect.x, .y = rect.y + rect.height }, .{ .x = rect.x + rect.width, .y = rect.y + rect.height }, border.bottom, paint.bottom_color, paint.bottom_style);
    if (border.left > 0 and paint.left_style != .none) try appendLine(allocator, commands, page_index, .{ .x = rect.x, .y = rect.y }, .{ .x = rect.x, .y = rect.y + rect.height }, border.left, paint.left_color, paint.left_style);
}

pub fn appendRectOutline(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    rect: geometry.Rect,
    width: f32,
    color: geometry.Color,
) !void {
    try appendLine(allocator, commands, page_index, .{ .x = rect.x, .y = rect.y }, .{ .x = rect.x + rect.width, .y = rect.y }, width, color, .solid);
    try appendLine(allocator, commands, page_index, .{ .x = rect.x + rect.width, .y = rect.y }, .{ .x = rect.x + rect.width, .y = rect.y + rect.height }, width, color, .solid);
    try appendLine(allocator, commands, page_index, .{ .x = rect.x + rect.width, .y = rect.y + rect.height }, .{ .x = rect.x, .y = rect.y + rect.height }, width, color, .solid);
    try appendLine(allocator, commands, page_index, .{ .x = rect.x, .y = rect.y + rect.height }, .{ .x = rect.x, .y = rect.y }, width, color, .solid);
}

pub fn appendLine(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    from: geometry.Point,
    to: geometry.Point,
    width: f32,
    color: geometry.Color,
    style: box.BorderStyle,
) !void {
    try commands.append(allocator, .{
        .page_index = page_index,
        .command = .{ .stroke_line = .{
            .from = from,
            .to = to,
            .width = width,
            .color = color,
            .style = style,
        } },
    });
}

fn uniformBorder(border: box.EdgeSizes, paint: layout.BorderPaint) bool {
    const tolerance: f32 = 0.0001;
    return border.top > 0 and
        @abs(border.top - border.right) <= tolerance and
        @abs(border.top - border.bottom) <= tolerance and
        @abs(border.top - border.left) <= tolerance and
        paint.top_style != .none and
        paint.top_style == paint.right_style and
        paint.top_style == paint.bottom_style and
        paint.top_style == paint.left_style and
        colorsEqual(paint.top_color, paint.right_color) and
        colorsEqual(paint.top_color, paint.bottom_color) and
        colorsEqual(paint.top_color, paint.left_color);
}

fn colorsEqual(left: geometry.Color, right: geometry.Color) bool {
    const tolerance: f32 = 0.0001;
    return @abs(left.red - right.red) <= tolerance and
        @abs(left.green - right.green) <= tolerance and
        @abs(left.blue - right.blue) <= tolerance and
        @abs(left.alpha - right.alpha) <= tolerance;
}
