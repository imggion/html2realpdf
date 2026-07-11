//! Backend-neutral painting commands produced from paged layout fragments.

const std = @import("std");
const geometry = @import("geometry.zig");
const pagination = @import("pagination.zig");
pub const paint = struct {
    pub const types = @import("paint/types.zig");
    pub const stacking = @import("paint/stacking.zig");
    pub const backgrounds = @import("paint/backgrounds.zig");
    pub const borders = @import("paint/borders.zig");
    pub const effects = @import("paint/effects.zig");
};

pub const TextRun = paint.types.TextRun;
pub const FillRect = paint.types.FillRect;
pub const FillRoundedRect = paint.types.FillRoundedRect;
pub const StrokeRoundedRect = paint.types.StrokeRoundedRect;
pub const StrokeLine = paint.types.StrokeLine;
pub const LinkAnnotation = paint.types.LinkAnnotation;
pub const Image = paint.types.Image;
pub const Command = paint.types.Command;
pub const PageCommand = paint.types.PageCommand;
pub const DisplayList = paint.types.DisplayList;

pub fn build(allocator: std.mem.Allocator, document: *const pagination.PagedDocument) !DisplayList {
    var commands = try std.ArrayList(PageCommand).initCapacity(allocator, document.fragments.items.len * 2);
    errdefer commands.deinit(allocator);

    for (document.fragments.items) |paged| {
        const fragment = paged.fragment;
        try paint.backgrounds.append(allocator, &commands, paged.page_index, fragment);
        try paint.borders.append(allocator, &commands, paged.page_index, fragment);

        if (fragment.kind == .text) {
            try commands.append(allocator, .{
                .page_index = paged.page_index,
                .command = .{ .text = .{
                    .position = .{ .x = fragment.rect.x, .y = fragment.rect.y },
                    .width = fragment.rect.width,
                    .text = fragment.text orelse "",
                    .leading_space = fragment.leading_space,
                    .line_id = fragment.line_id,
                    .font_size = fragment.font_size,
                    .font_family = fragment.font_family,
                    .letter_spacing = fragment.letter_spacing,
                    .word_spacing = fragment.word_spacing,
                    .font_weight = fragment.font_weight,
                    .font_style = fragment.font_style,
                    .color = fragment.color,
                } },
            });
            try paint.effects.appendTextDecoration(allocator, &commands, paged.page_index, fragment);
        } else if (fragment.kind == .replaced) {
            if (fragment.image_source) |source| {
                try commands.append(allocator, .{
                    .page_index = paged.page_index,
                    .command = .{ .image = .{ .rect = fragment.rect, .source = source } },
                });
            } else if (edgeIsZero(fragment.border)) {
                const placeholder = geometry.Color{ .red = 0.6, .green = 0.6, .blue = 0.6 };
                try paint.borders.appendRectOutline(allocator, &commands, paged.page_index, fragment.rect, 1, placeholder);
            }
        }

        if (fragment.link_url) |url| {
            try commands.append(allocator, .{
                .page_index = paged.page_index,
                .command = .{ .link = .{ .rect = fragment.rect, .url = url } },
            });
        }
    }

    return .{
        .commands = commands,
        .page_count = document.page_count,
        .page_spec = document.page_spec,
    };
}

fn edgeIsZero(edge: @import("box.zig").EdgeSizes) bool {
    return edge.top == 0 and edge.right == 0 and edge.bottom == 0 and edge.left == 0;
}

test "build text and border commands" {
    const layout = @import("layout.zig");
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(pagination.PagedFragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .page_index = 0,
        .fragment = .{
            .kind = .text,
            .source_box = 0,
            .rect = .{ .width = 20, .height = 18 },
            .text = "Hello",
            .border = .{ .bottom = 1 },
        },
    });
    const paged = pagination.PagedDocument{
        .fragments = fragments,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    _ = layout;
    var list = try build(allocator, &paged);
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    try std.testing.expect(list.commands.items[1].command == .text);
}

test "build rounded fill and uniform rounded border commands" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(pagination.PagedFragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .page_index = 0,
        .fragment = .{
            .kind = .box,
            .source_box = 0,
            .rect = .{ .width = 120, .height = 60 },
            .background = .{ .red = 0.9, .green = 0.95, .blue = 1 },
            .border = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
            .border_paint = .{
                .top_style = .solid,
                .right_style = .solid,
                .bottom_style = .solid,
                .left_style = .solid,
            },
            .border_radius = 12,
        },
    });
    const paged = pagination.PagedDocument{
        .fragments = fragments,
        .page_count = 1,
        .page_spec = pagination.PageSpec.standard(.a4, .portrait, .{}),
    };
    var list = try build(allocator, &paged);
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    try std.testing.expect(list.commands.items[0].command == .fill_rounded_rect);
    try std.testing.expect(list.commands.items[1].command == .stroke_rounded_rect);
}
