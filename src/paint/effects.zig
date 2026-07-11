//! Text decoration effects supported without rasterization.

const std = @import("std");
const layout = @import("../layout.zig");
const borders = @import("borders.zig");
const types = @import("types.zig");

pub fn appendTextDecoration(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    if (fragment.text_decoration == .none) return;
    const line_y = fragment.rect.y + fragment.font_size * (if (fragment.text_decoration == .underline) @as(f32, 1.02) else 0.55);
    try borders.appendLine(
        allocator,
        commands,
        page_index,
        .{ .x = fragment.rect.x, .y = line_y },
        .{ .x = fragment.rect.x + fragment.rect.width, .y = line_y },
        @max(fragment.font_size / 16, 0.75),
        fragment.color,
        .solid,
    );
}
