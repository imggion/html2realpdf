//! Text decoration effects supported without rasterization.

const std = @import("std");
const layout = @import("../layout.zig");
const geometry = @import("../geometry.zig");
const box = @import("../box.zig");
const borders = @import("borders.zig");
const types = @import("types.zig");

pub fn appendTextDecoration(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    if (fragment.text_decoration == .none) return;
    const thickness = fragment.text_decoration_thickness orelse @max(fragment.font_size / 16, 0.75);
    if (thickness <= 0) return;
    const color = fragment.text_decoration_color orelse fragment.color;
    if (fragment.text_decoration.hasOverline()) try appendDecorationLine(
        allocator,
        commands,
        page_index,
        fragment.rect,
        fragment.rect.y + fragment.font_size * 0.12,
        thickness,
        color,
        fragment.text_decoration_style,
    );
    if (fragment.text_decoration.hasLineThrough()) try appendDecorationLine(
        allocator,
        commands,
        page_index,
        fragment.rect,
        fragment.rect.y + fragment.font_size * 0.55,
        thickness,
        color,
        fragment.text_decoration_style,
    );
    if (fragment.text_decoration.hasUnderline()) try appendDecorationLine(
        allocator,
        commands,
        page_index,
        fragment.rect,
        fragment.rect.y + fragment.font_size * 1.02,
        thickness,
        color,
        fragment.text_decoration_style,
    );
}

fn appendDecorationLine(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    rect: geometry.Rect,
    y: f32,
    thickness: f32,
    color: geometry.Color,
    style: box.TextDecorationStyle,
) !void {
    if (style == .wavy) return appendWavyLine(allocator, commands, page_index, rect, y, thickness, color);
    const line_style: box.BorderStyle = switch (style) {
        .solid, .double => .solid,
        .dotted => .dotted,
        .dashed => .dashed,
        .wavy => unreachable,
    };
    try borders.appendLine(
        allocator,
        commands,
        page_index,
        .{ .x = rect.x, .y = y },
        .{ .x = rect.x + rect.width, .y = y },
        thickness,
        color,
        line_style,
    );
    if (style == .double) try borders.appendLine(
        allocator,
        commands,
        page_index,
        .{ .x = rect.x, .y = y + thickness * 1.8 },
        .{ .x = rect.x + rect.width, .y = y + thickness * 1.8 },
        thickness,
        color,
        .solid,
    );
}

fn appendWavyLine(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    rect: geometry.Rect,
    y: f32,
    thickness: f32,
    color: geometry.Color,
) !void {
    const step = @max(thickness * 2.5, 2);
    const amplitude = @max(thickness, 0.75);
    var x = rect.x;
    var direction: f32 = -1;
    while (x < rect.x + rect.width) {
        const next_x = @min(x + step, rect.x + rect.width);
        try borders.appendLine(
            allocator,
            commands,
            page_index,
            .{ .x = x, .y = y + amplitude * direction },
            .{ .x = next_x, .y = y - amplitude * direction },
            thickness,
            color,
            .solid,
        );
        direction *= -1;
        x = next_x;
    }
}

test "emit combined double decorations with explicit paint" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(types.PageCommand).initCapacity(allocator, 0);
    defer commands.deinit(allocator);
    try appendTextDecoration(allocator, &commands, 0, .{
        .kind = .text,
        .source_box = 0,
        .rect = .{ .x = 10, .y = 20, .width = 80, .height = 24 },
        .font_size = 20,
        .text_decoration = .all,
        .text_decoration_style = .double,
        .text_decoration_color = .{ .red = 0.7, .green = 0.1, .blue = 0.3 },
        .text_decoration_thickness = 2,
    });
    try std.testing.expectEqual(@as(usize, 6), commands.items.len);
    for (commands.items) |command| {
        try std.testing.expect(command.command == .stroke_line);
        try std.testing.expectEqual(@as(f32, 2), command.command.stroke_line.width);
        try std.testing.expectApproxEqAbs(@as(f32, 0.7), command.command.stroke_line.color.red, 0.001);
    }
}

test "emit wavy decorations as vector segments" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(types.PageCommand).initCapacity(allocator, 0);
    defer commands.deinit(allocator);
    try appendTextDecoration(allocator, &commands, 0, .{
        .kind = .text,
        .source_box = 0,
        .rect = .{ .width = 30, .height = 18 },
        .font_size = 16,
        .text_decoration = .underline,
        .text_decoration_style = .wavy,
    });
    try std.testing.expect(commands.items.len >= 6);
    for (commands.items) |command| try std.testing.expect(command.command == .stroke_line);
}
