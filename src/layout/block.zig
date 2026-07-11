//! Block formatting context layout.
//!
//! Intrinsic measurement remains separate so future flex and grid algorithms
//! can measure before assigning the containing block.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const intrinsic = @import("intrinsic.zig");
const types = @import("types.zig");

pub const Options = struct {
    fill_available_width: bool = false,
};

pub fn layout(
    state: anytype,
    box_id: box.BoxId,
    containing: geometry.Rect,
    cursor_y: *f32,
) std.mem.Allocator.Error!geometry.Rect {
    return layoutWithOptions(state, box_id, containing, cursor_y, .{});
}

pub fn layoutWithOptions(
    state: anytype,
    box_id: box.BoxId,
    containing: geometry.Rect,
    cursor_y: *f32,
    options: Options,
) std.mem.Allocator.Error!geometry.Rect {
    const source = state.tree.boxes.items[box_id];
    const style = source.style;
    const margin = source.margin;
    const border = source.border;
    const padding = source.padding;

    if (style.page_break_before == .always) state.advanceToNextPage(cursor_y);

    const fragment_start = state.fragments.items.len;
    const outer_x = containing.x + margin.left;
    const available_outer_width = @max(containing.width - margin.left - margin.right, 1);
    const horizontal_non_content = border.left + border.right + padding.left + padding.right;
    var requested_content_width = if (options.fill_available_width)
        @max(available_outer_width - horizontal_non_content, 1)
    else
        intrinsic.resolveContentDimension(style.width, available_outer_width, horizontal_non_content, style.box_sizing) orelse @max(available_outer_width - horizontal_non_content, 1);
    if (!options.fill_available_width) {
        if (intrinsic.resolveContentDimension(style.min_width, available_outer_width, horizontal_non_content, style.box_sizing)) |minimum| requested_content_width = @max(requested_content_width, minimum);
        if (intrinsic.resolveContentDimension(style.max_width, available_outer_width, horizontal_non_content, style.box_sizing)) |maximum| requested_content_width = @min(requested_content_width, maximum);
    }
    const content_width = @max(@min(requested_content_width, available_outer_width - horizontal_non_content), 1);
    const outer_width = @min(content_width + horizontal_non_content, available_outer_width);
    var outer_y = cursor_y.* + margin.top;

    const fragment_id = state.fragments.items.len;
    try state.fragments.append(state.allocator, .{
        .kind = if (source.kind == .replaced) .replaced else .box,
        .source_box = box_id,
        .rect = .{ .x = outer_x, .y = outer_y, .width = outer_width },
        .background = if (style.background) |value| geometry.parseColor(value) else null,
        .border = border,
        .border_paint = types.borderPaint(style),
        .border_radius = style.border_radius,
        .page_break_before = style.page_break_before,
        .page_break_after = style.page_break_after,
        .page_break_inside = style.page_break_inside,
        .image_source = if (source.kind == .replaced) state.attributeForBox(box_id, "src") else null,
    });

    const content_x = outer_x + border.left + padding.left;
    const content_y = outer_y + border.top + padding.top;
    var child_cursor_y = content_y;

    if (try state.listMarkerForBox(box_id)) |marker| {
        try state.fragments.append(state.allocator, .{
            .kind = .text,
            .source_box = box_id,
            .rect = .{
                .x = @max(content_x - style.font_size * 1.25, containing.x),
                .y = content_y,
                .width = intrinsic.measureText(state.font_registry, marker, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing),
                .height = @max(style.line_height, style.font_size * 1.2),
            },
            .text = marker,
            .font_size = style.font_size,
            .font_family = style.font_family,
            .letter_spacing = style.letter_spacing,
            .font_weight = style.font_weight,
            .font_style = style.font_style,
            .color = geometry.parseColor(style.color) orelse geometry.Color.black,
            .text_decoration = style.text_decoration,
        });
    }

    if (source.kind == .replaced) {
        const intrinsic_height = source.intrinsic_height orelse source.style.height.resolve(containing.height) orelse source.intrinsic_width orelse 24;
        child_cursor_y += intrinsic_height;
    } else if (source.kind == .table) {
        child_cursor_y += try state.layoutTable(box_id, content_x, content_y, content_width);
    } else if (source.first_child) |_| {
        if (state.hasBlockChildren(box_id)) {
            var previous_bottom_margin: f32 = 0;
            var child = source.first_child;
            while (child) |child_id| {
                const child_box = state.tree.boxes.items[child_id];
                if (isBlockLevel(child_box.kind)) {
                    const collapsed = collapseMargins(previous_bottom_margin, child_box.margin.top);
                    child_cursor_y -= previous_bottom_margin + child_box.margin.top - collapsed;
                    _ = try state.layoutBlock(
                        child_id,
                        .{ .x = content_x, .y = content_y, .width = content_width },
                        &child_cursor_y,
                    );
                    previous_bottom_margin = child_box.margin.bottom;
                } else {
                    const run_height = try state.layoutInlineRun(child_id, content_x, child_cursor_y, content_width, style.text_align);
                    child_cursor_y += run_height;
                    previous_bottom_margin = 0;
                }
                child = child_box.next_sibling;
            }
        } else {
            const inline_height = try state.layoutInlineChildren(box_id, content_x, content_y, content_width, style.text_align);
            child_cursor_y += inline_height;
        }
    }

    const vertical_non_content = border.top + border.bottom + padding.top + padding.bottom;
    var content_height = @max(child_cursor_y - content_y, 0);
    if (intrinsic.resolveContentDimension(style.height, containing.height, vertical_non_content, style.box_sizing)) |height| content_height = @max(content_height, height);
    if (intrinsic.resolveContentDimension(style.min_height, containing.height, vertical_non_content, style.box_sizing)) |minimum| content_height = @max(content_height, minimum);
    if (intrinsic.resolveContentDimension(style.max_height, containing.height, vertical_non_content, style.box_sizing)) |maximum| content_height = @min(content_height, maximum);
    if (source.kind == .replaced) {
        content_height = @max(content_height, source.intrinsic_height orelse 24);
    }

    var outer_height = border.top + padding.top + content_height + padding.bottom + border.bottom;
    if (!state.hasBlockChildren(box_id)) {
        try state.enforceLineConstraints(fragment_start, &outer_y, &outer_height, style.orphans, style.widows);
    }

    if (style.page_break_inside == .avoid) {
        if (state.page_height) |page_height| {
            const page_y = @mod(outer_y, page_height);
            if (outer_height <= page_height and page_y > 0 and page_y + outer_height > page_height) {
                const shift = page_height - page_y;
                for (state.fragments.items[fragment_start..]) |*fragment| fragment.rect.y += shift;
                outer_y += shift;
            }
        }
    }

    state.fragments.items[fragment_id].rect.height = outer_height;

    cursor_y.* = outer_y + outer_height + margin.bottom;
    if (style.page_break_after == .always) state.advanceToNextPage(cursor_y);
    return state.fragments.items[fragment_id].rect;
}

pub fn isBlockLevel(kind: box.BoxType) bool {
    return switch (kind) {
        .block, .anonymousBlock, .table, .tableRow, .tableCell, .tableRowGroup, .anonymousTableRow => true,
        else => false,
    };
}

fn collapseMargins(previous: f32, next: f32) f32 {
    if (previous >= 0 and next >= 0) return @max(previous, next);
    if (previous <= 0 and next <= 0) return @min(previous, next);
    return previous + next;
}
