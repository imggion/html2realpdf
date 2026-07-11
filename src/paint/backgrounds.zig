//! Background painting for the current document profile.

const std = @import("std");
const layout = @import("../layout.zig");
const types = @import("types.zig");

pub fn append(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    const color = fragment.background orelse return;
    try commands.append(allocator, .{
        .page_index = page_index,
        .command = if (fragment.border_radius > 0)
            .{ .fill_rounded_rect = .{ .rect = fragment.rect, .radius = fragment.border_radius, .color = color } }
        else
            .{ .fill_rect = .{ .rect = fragment.rect, .color = color } },
    });
}
