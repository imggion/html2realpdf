//! Generated page-margin content lowered to ordinary selectable text commands.
//!
//! Layout establishes the final page count first. This phase then expands page
//! counters and positions each margin box in the page margin coordinate space
//! without manufacturing DOM boxes or changing content fragmentation.

const std = @import("std");
const box = @import("box.zig");
const display_list = @import("display_list.zig");
const font = @import("font.zig");
const geometry = @import("geometry.zig");
const intrinsic = @import("layout/intrinsic.zig");
const pagination = @import("pagination.zig");

pub const MarginBoxName = enum {
    top_left_corner,
    top_left,
    top_center,
    top_right,
    top_right_corner,
    right_top,
    right_middle,
    right_bottom,
    bottom_right_corner,
    bottom_right,
    bottom_center,
    bottom_left,
    bottom_left_corner,
    left_bottom,
    left_middle,
    left_top,
};

pub const MarginBox = struct {
    name: MarginBoxName,
    content: []const u8,
    font_family: []const u8 = "Noto Sans",
    font_size: f32 = 12,
    font_weight: box.FontWeight = .normal,
    font_style: box.FontStyle = .normal,
    color: geometry.Color = geometry.Color.black,
    text_align: ?box.TextAlign = null,
};

pub const MarginRule = struct {
    selector: pagination.PageSelector,
    boxes: []const MarginBox,
};

const Slot = struct {
    rect: geometry.Rect,
    default_align: box.TextAlign,
};

pub fn appendMarginBoxes(
    allocator: std.mem.Allocator,
    list: *display_list.DisplayList,
    boxes: []const MarginBox,
    rules: []const MarginRule,
    page_names: []const []const u8,
    blank_pages: []const bool,
    registry: ?*const font.Registry,
    shaping_mode: font.ShapingMode,
) !void {
    for (0..list.page_count) |page_index| {
        var selected = [_]?MarginBox{null} ** std.meta.fields(MarginBoxName).len;
        var winners = [_]MarginWinner{.{}} ** std.meta.fields(MarginBoxName).len;
        for (boxes) |margin_box| {
            const index = @intFromEnum(margin_box.name);
            selected[index] = margin_box;
            winners[index].set = true;
        }
        const page_name = if (page_index < page_names.len) page_names[page_index] else "";
        const is_blank = page_index < blank_pages.len and blank_pages[page_index];
        for (rules, 0..) |rule, order| {
            if (!selectorMatches(rule.selector, page_name, page_index, is_blank)) continue;
            const specificity = selectorSpecificity(rule.selector);
            for (rule.boxes) |margin_box| {
                const index = @intFromEnum(margin_box.name);
                if (!winners[index].accepts(specificity, order)) continue;
                selected[index] = margin_box;
                winners[index] = .{ .set = true, .specificity = specificity, .order = order };
            }
        }
        for (selected) |candidate| {
            const margin_box = candidate orelse continue;
            const slot = slotFor(list.pageSpec(page_index), margin_box.name);
            if (slot.rect.width <= 0 or slot.rect.height <= 0) continue;
            const text = try expandCounters(allocator, margin_box.content, page_index + 1, list.page_count);
            if (text.len == 0) continue;
            const font_size = @max(margin_box.font_size, 1);
            const width = intrinsic.measureText(
                registry,
                shaping_mode,
                text,
                margin_box.font_family,
                font_size,
                margin_box.font_weight,
                margin_box.font_style,
                0,
            );
            const alignment = margin_box.text_align orelse slot.default_align;
            const x = switch (alignment) {
                .center => slot.rect.x + @max(slot.rect.width - width, 0) / 2,
                .right, .end => slot.rect.x + @max(slot.rect.width - width, 0),
                .left, .start, .justify => slot.rect.x,
            };
            const y = slot.rect.y + @max(slot.rect.height - font_size, 0) / 2;
            try list.commands.append(allocator, .{
                .page_index = page_index,
                .command = .{ .text = .{
                    .position = .{ .x = x, .y = y },
                    .width = width,
                    .text = text,
                    .font_size = font_size,
                    .font_family = margin_box.font_family,
                    .font_weight = margin_box.font_weight,
                    .font_style = margin_box.font_style,
                    .color = margin_box.color,
                    .artifact = true,
                } },
            });
        }
    }
}

const MarginWinner = struct {
    set: bool = false,
    specificity: [3]u8 = .{ 0, 0, 0 },
    order: usize = 0,

    fn accepts(self: MarginWinner, specificity: [3]u8, order: usize) bool {
        if (!self.set) return true;
        const comparison = std.mem.order(u8, &specificity, &self.specificity);
        return comparison == .gt or (comparison == .eq and order >= self.order);
    }
};

fn selectorMatches(selector: pagination.PageSelector, page_name: []const u8, page_index: usize, is_blank: bool) bool {
    if (selector.name.len > 0 and !std.mem.eql(u8, selector.name, page_name)) return false;
    if (selector.first and page_index != 0) return false;
    if (selector.left and page_index % 2 == 0) return false;
    if (selector.right and page_index % 2 != 0) return false;
    if (selector.blank and !is_blank) return false;
    return true;
}

fn selectorSpecificity(selector: pagination.PageSelector) [3]u8 {
    return .{
        @intFromBool(selector.name.len > 0),
        @intFromBool(selector.first) + @intFromBool(selector.blank),
        @intFromBool(selector.left) + @intFromBool(selector.right),
    };
}

fn slotFor(spec: @import("pagination.zig").PageSpec, name: MarginBoxName) Slot {
    const scale = geometry.css_px_to_pdf_points;
    const margin_top = spec.margins_points.top / scale;
    const margin_right = spec.margins_points.right / scale;
    const margin_bottom = spec.margins_points.bottom / scale;
    const margin_left = spec.margins_points.left / scale;
    const content_width = spec.contentWidthCssPx();
    const content_height = spec.contentHeightCssPx();
    const horizontal_third = content_width / 3;
    const vertical_third = content_height / 3;

    return switch (name) {
        .top_left_corner => .{ .rect = .{ .x = -margin_left, .y = -margin_top, .width = margin_left, .height = margin_top }, .default_align = .center },
        .top_left => .{ .rect = .{ .y = -margin_top, .width = horizontal_third, .height = margin_top }, .default_align = .left },
        .top_center => .{ .rect = .{ .x = horizontal_third, .y = -margin_top, .width = horizontal_third, .height = margin_top }, .default_align = .center },
        .top_right => .{ .rect = .{ .x = horizontal_third * 2, .y = -margin_top, .width = horizontal_third, .height = margin_top }, .default_align = .right },
        .top_right_corner => .{ .rect = .{ .x = content_width, .y = -margin_top, .width = margin_right, .height = margin_top }, .default_align = .center },
        .right_top => .{ .rect = .{ .x = content_width, .width = margin_right, .height = vertical_third }, .default_align = .center },
        .right_middle => .{ .rect = .{ .x = content_width, .y = vertical_third, .width = margin_right, .height = vertical_third }, .default_align = .center },
        .right_bottom => .{ .rect = .{ .x = content_width, .y = vertical_third * 2, .width = margin_right, .height = vertical_third }, .default_align = .center },
        .bottom_right_corner => .{ .rect = .{ .x = content_width, .y = content_height, .width = margin_right, .height = margin_bottom }, .default_align = .center },
        .bottom_right => .{ .rect = .{ .x = horizontal_third * 2, .y = content_height, .width = horizontal_third, .height = margin_bottom }, .default_align = .right },
        .bottom_center => .{ .rect = .{ .x = horizontal_third, .y = content_height, .width = horizontal_third, .height = margin_bottom }, .default_align = .center },
        .bottom_left => .{ .rect = .{ .y = content_height, .width = horizontal_third, .height = margin_bottom }, .default_align = .left },
        .bottom_left_corner => .{ .rect = .{ .x = -margin_left, .y = content_height, .width = margin_left, .height = margin_bottom }, .default_align = .center },
        .left_bottom => .{ .rect = .{ .x = -margin_left, .y = vertical_third * 2, .width = margin_left, .height = vertical_third }, .default_align = .center },
        .left_middle => .{ .rect = .{ .x = -margin_left, .y = vertical_third, .width = margin_left, .height = vertical_third }, .default_align = .center },
        .left_top => .{ .rect = .{ .x = -margin_left, .width = margin_left, .height = vertical_third }, .default_align = .center },
    };
}

fn expandCounters(allocator: std.mem.Allocator, template: []const u8, page: usize, pages: usize) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var cursor: usize = 0;
    while (cursor < template.len) {
        const page_match = std.mem.indexOfPos(u8, template, cursor, "{{page}}") orelse template.len;
        const pages_match = std.mem.indexOfPos(u8, template, cursor, "{{pages}}") orelse template.len;
        const next = @min(page_match, pages_match);
        try output.writer.writeAll(template[cursor..next]);
        if (next == template.len) break;
        if (next == pages_match) {
            try output.writer.print("{d}", .{pages});
            cursor = next + "{{pages}}".len;
        } else {
            try output.writer.print("{d}", .{page});
            cursor = next + "{{page}}".len;
        }
    }
    return output.toOwnedSlice();
}

test "expand margin counters without confusing page and pages" {
    const allocator = std.testing.allocator;
    const text = try expandCounters(allocator, "Page {{page}} of {{pages}}", 2, 12);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Page 2 of 12", text);
}

test "append selectable margin content on every page" {
    const allocator = std.testing.allocator;
    const commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 0);
    var list = display_list.DisplayList{
        .commands = commands,
        .page_count = 2,
        .page_spec = .{ .width_points = 150, .height_points = 75, .margins_points = .{ .top = 15, .bottom = 15 } },
    };
    defer {
        for (list.commands.items) |command| allocator.free(command.command.text.text);
        list.deinit(allocator);
    }
    try appendMarginBoxes(allocator, &list, &.{.{ .name = .top_center, .content = "{{page}}/{{pages}}" }}, &.{}, &.{}, &.{}, null, .identity);
    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    try std.testing.expectEqualStrings("1/2", list.commands.items[0].command.text.text);
    try std.testing.expectEqualStrings("2/2", list.commands.items[1].command.text.text);
    try std.testing.expect(list.commands.items[0].command.text.position.y < 0);
}

test "named and blank page margin boxes select by page specificity" {
    const allocator = std.testing.allocator;
    const commands = try std.ArrayList(display_list.PageCommand).initCapacity(allocator, 0);
    var list = display_list.DisplayList{
        .commands = commands,
        .page_count = 3,
        .page_spec = .{ .width_points = 150, .height_points = 75, .margins_points = .{ .bottom = 15 } },
    };
    defer {
        for (list.commands.items) |command| allocator.free(command.command.text.text);
        list.deinit(allocator);
    }
    const summary = [_]MarginBox{.{ .name = .bottom_center, .content = "Summary" }};
    const blank = [_]MarginBox{.{ .name = .bottom_center, .content = "Blank" }};
    try appendMarginBoxes(
        allocator,
        &list,
        &.{.{ .name = .bottom_center, .content = "Default" }},
        &.{
            .{ .selector = .{ .name = "Summary" }, .boxes = &summary },
            .{ .selector = .{ .name = "Summary", .blank = true }, .boxes = &blank },
        },
        &.{ "Report", "Summary", "Summary" },
        &.{ false, true, false },
        null,
        .identity,
    );
    try std.testing.expectEqual(@as(usize, 3), list.commands.items.len);
    try std.testing.expectEqualStrings("Default", list.commands.items[0].command.text.text);
    try std.testing.expectEqualStrings("Blank", list.commands.items[1].command.text.text);
    try std.testing.expectEqualStrings("Summary", list.commands.items[2].command.text.text);
}
