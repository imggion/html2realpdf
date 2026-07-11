//! Backend-neutral painting commands produced from paged layout fragments.

const std = @import("std");
const geometry = @import("geometry.zig");
const pagination = @import("pagination.zig");
const box = @import("box.zig");

pub const TextRun = struct {
    position: geometry.Point,
    width: f32 = 0,
    text: []const u8,
    leading_space: bool = false,
    line_id: ?usize = null,
    font_size: f32,
    font_family: []const u8 = "Noto Sans",
    letter_spacing: f32 = 0,
    font_weight: box.FontWeight = .normal,
    font_style: box.FontStyle = .normal,
    color: geometry.Color,
};

pub const FillRect = struct {
    rect: geometry.Rect,
    color: geometry.Color,
};

pub const FillRoundedRect = struct {
    rect: geometry.Rect,
    radius: f32,
    color: geometry.Color,
};

pub const StrokeRoundedRect = struct {
    rect: geometry.Rect,
    radius: f32,
    width: f32,
    color: geometry.Color,
    style: box.BorderStyle = .solid,
};

pub const StrokeLine = struct {
    from: geometry.Point,
    to: geometry.Point,
    width: f32,
    color: geometry.Color,
    style: box.BorderStyle = .solid,
};

pub const LinkAnnotation = struct {
    rect: geometry.Rect,
    url: []const u8,
};

pub const Image = struct {
    rect: geometry.Rect,
    source: []const u8,
};

pub const Command = union(enum) {
    fill_rect: FillRect,
    fill_rounded_rect: FillRoundedRect,
    stroke_rounded_rect: StrokeRoundedRect,
    stroke_line: StrokeLine,
    text: TextRun,
    link: LinkAnnotation,
    image: Image,
};

pub const PageCommand = struct {
    page_index: usize,
    command: Command,
};

pub const DisplayList = struct {
    commands: std.ArrayList(PageCommand),
    page_count: usize,
    page_spec: pagination.PageSpec,

    pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
    }
};

pub fn build(allocator: std.mem.Allocator, document: *const pagination.PagedDocument) !DisplayList {
    var commands = try std.ArrayList(PageCommand).initCapacity(allocator, document.fragments.items.len * 2);
    errdefer commands.deinit(allocator);

    for (document.fragments.items) |paged| {
        const fragment = paged.fragment;
        if (fragment.background) |color| {
            try commands.append(allocator, .{
                .page_index = paged.page_index,
                .command = if (fragment.border_radius > 0)
                    .{ .fill_rounded_rect = .{ .rect = fragment.rect, .radius = fragment.border_radius, .color = color } }
                else
                    .{ .fill_rect = .{ .rect = fragment.rect, .color = color } },
            });
        }

        try appendBorders(allocator, &commands, paged.page_index, fragment);

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
                    .font_weight = fragment.font_weight,
                    .font_style = fragment.font_style,
                    .color = fragment.color,
                } },
            });
            if (fragment.text_decoration != .none) {
                const line_y = fragment.rect.y + fragment.font_size * (if (fragment.text_decoration == .underline) @as(f32, 1.02) else 0.55);
                try appendLine(
                    allocator,
                    &commands,
                    paged.page_index,
                    .{ .x = fragment.rect.x, .y = line_y },
                    .{ .x = fragment.rect.x + fragment.rect.width, .y = line_y },
                    @max(fragment.font_size / 16, 0.75),
                    fragment.color,
                    .solid,
                );
            }
        } else if (fragment.kind == .replaced) {
            if (fragment.image_source) |source| {
                try commands.append(allocator, .{
                    .page_index = paged.page_index,
                    .command = .{ .image = .{ .rect = fragment.rect, .source = source } },
                });
            } else if (edgeIsZero(fragment.border)) {
                const placeholder = geometry.Color{ .red = 0.6, .green = 0.6, .blue = 0.6 };
                try appendRectOutline(allocator, &commands, paged.page_index, fragment.rect, 1, placeholder);
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

fn appendBorders(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(PageCommand),
    page_index: usize,
    fragment: @import("layout.zig").Fragment,
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

fn uniformBorder(border: box.EdgeSizes, paint: @import("layout.zig").BorderPaint) bool {
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
        @abs(left.blue - right.blue) <= tolerance;
}

fn appendRectOutline(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(PageCommand),
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

fn appendLine(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(PageCommand),
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
