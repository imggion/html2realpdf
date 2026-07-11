//! Block formatting context layout.
//!
//! Intrinsic measurement remains separate so future flex and grid algorithms
//! can measure before assigning the containing block.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const floats = @import("floats.zig");
const intrinsic = @import("intrinsic.zig");
const types = @import("types.zig");

pub const Options = struct {
    fill_available_width: bool = false,
    shrink_to_fit: bool = false,
    containing_block_height: ?f32 = null,
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
    const containing_height: ?f32 = if (state.web_sizing) options.containing_block_height else containing.height;

    if (style.page_break_before == .always) state.advanceToNextPage(cursor_y);

    const fragment_start = state.fragments.items.len;
    const outer_x = containing.x + margin.left;
    const available_outer_width = @max(containing.width - margin.left - margin.right, 1);
    const horizontal_non_content = border.left + border.right + padding.left + padding.right;
    const vertical_non_content = border.top + border.bottom + padding.top + padding.bottom;
    const inline_sizes = if (options.shrink_to_fit or style.width.usesIntrinsicSizing() or style.min_width.usesIntrinsicSizing() or style.max_width.usesIntrinsicSizing())
        try state.measureIntrinsicInline(box_id)
    else
        intrinsic.InlineSizes{};
    const specified_content_height = intrinsic.resolveContentDimensionOptional(style.height, containing_height, vertical_non_content, style.box_sizing);
    const replaced_size = if (source.kind == .replaced) intrinsic.resolveReplacedSize(
        style,
        source.intrinsic_width,
        source.intrinsic_height,
        available_outer_width,
        containing_height,
        horizontal_non_content,
        vertical_non_content,
    ) else null;
    var requested_content_width = if (options.fill_available_width)
        @max(available_outer_width - horizontal_non_content, 1)
    else if (replaced_size) |size|
        size.width
    else if (options.shrink_to_fit and style.width.isAuto())
        @min(inline_sizes.max_content, @max(inline_sizes.min_content, available_outer_width - horizontal_non_content))
    else
        intrinsic.resolveContentInlineDimension(style.width, available_outer_width, horizontal_non_content, style.box_sizing, inline_sizes) orelse @max(available_outer_width - horizontal_non_content, 1);
    if (!options.fill_available_width) {
        const minimum = intrinsic.resolveContentInlineDimension(style.min_width, available_outer_width, horizontal_non_content, style.box_sizing, inline_sizes);
        const maximum = intrinsic.resolveContentInlineDimension(style.max_width, available_outer_width, horizontal_non_content, style.box_sizing, inline_sizes);
        if (state.web_sizing) {
            if (maximum) |value| requested_content_width = @min(requested_content_width, value);
            if (minimum) |value| requested_content_width = @max(requested_content_width, value);
        } else {
            if (minimum) |value| requested_content_width = @max(requested_content_width, value);
            if (maximum) |value| requested_content_width = @min(requested_content_width, value);
        }
    }
    const may_overflow_inline = state.web_sizing and !options.fill_available_width and (!style.width.isAuto() or !style.min_width.isAuto());
    const content_width = if (may_overflow_inline)
        @max(requested_content_width, 1)
    else
        @max(@min(requested_content_width, available_outer_width - horizontal_non_content), 1);
    const outer_width = if (may_overflow_inline)
        content_width + horizontal_non_content
    else
        @min(content_width + horizontal_non_content, available_outer_width);
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
        .intrinsic_width = source.intrinsic_width,
        .intrinsic_height = source.intrinsic_height,
        .object_fit = style.object_fit,
        .object_position = style.object_position,
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
                .width = intrinsic.measureText(state.font_registry, state.shaping_mode, marker, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing),
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
        child_cursor_y += replaced_size.?.height;
    } else if (source.kind == .table) {
        child_cursor_y += try state.layoutTable(box_id, content_x, content_y, content_width);
    } else if (source.first_child) |_| {
        if (state.hasBlockChildren(box_id)) {
            var float_context = try floats.Context.init(state.allocator, .{
                .x = content_x,
                .y = content_y,
                .width = content_width,
            });
            defer float_context.deinit();
            var previous_bottom_margin: f32 = 0;
            var child = source.first_child;
            while (child) |child_id| {
                const child_box = state.tree.boxes.items[child_id];
                if (state.web_sizing and child_box.style.float_direction != .none) {
                    previous_bottom_margin = 0;
                    const required_width = try floatOuterWidth(state, child_id, content_width);
                    const float_y = float_context.placementY(child_cursor_y, @min(required_width, content_width), child_box.style.clear_direction);
                    const band = float_context.bandAt(float_y);
                    const float_fragment_start = state.fragments.items.len;
                    var float_cursor = float_y;
                    var rect = try state.layoutBlockWithOptions(
                        child_id,
                        .{ .x = band.x, .y = float_y, .width = @max(band.width, 1) },
                        &float_cursor,
                        .{
                            .shrink_to_fit = true,
                            .containing_block_height = if (state.web_sizing) specified_content_height else containing.height,
                        },
                    );
                    if (child_box.style.float_direction == .right) {
                        const target_right = band.x + band.width - child_box.margin.right;
                        const shift = target_right - (rect.x + rect.width);
                        floats.shiftFragments(state.fragments.items[float_fragment_start..], shift, 0);
                        rect.x += shift;
                    }
                    try float_context.add(.{
                        .rect = floats.marginRect(rect, child_box.margin),
                        .side = child_box.style.float_direction,
                    });
                } else if (isBlockLevel(child_box.kind) or (state.web_sizing and child_box.style.clear_direction != .none)) {
                    if (state.web_sizing) {
                        const required_width = try minimumOuterWidth(state, child_id);
                        child_cursor_y = float_context.placementY(child_cursor_y, @min(required_width, content_width), child_box.style.clear_direction);
                    }
                    if (state.web_sizing and child_box.style.clear_direction != .none) {
                        previous_bottom_margin = 0;
                    } else {
                        const collapsed = collapseMargins(previous_bottom_margin, child_box.margin.top);
                        child_cursor_y -= previous_bottom_margin + child_box.margin.top - collapsed;
                    }
                    const band = if (state.web_sizing) float_context.bandAt(child_cursor_y) else floats.Band{
                        .x = content_x,
                        .width = content_width,
                        .next_bottom = null,
                    };
                    _ = try state.layoutBlockWithOptions(
                        child_id,
                        .{ .x = band.x, .y = content_y, .width = @max(band.width, 1) },
                        &child_cursor_y,
                        .{ .containing_block_height = if (state.web_sizing) specified_content_height else containing.height },
                    );
                    previous_bottom_margin = child_box.margin.bottom;
                } else {
                    const run_height = try state.layoutInlineRun(child_id, content_x, child_cursor_y, content_width, style.text_align);
                    child_cursor_y += run_height;
                    previous_bottom_margin = 0;
                }
                child = child_box.next_sibling;
            }
            if (state.web_sizing) child_cursor_y = @max(child_cursor_y, float_context.maximumBottom());
        } else {
            const inline_height = try state.layoutInlineChildren(box_id, content_x, content_y, content_width, style.text_align);
            child_cursor_y += inline_height;
        }
    }

    var content_height = @max(child_cursor_y - content_y, 0);
    if (specified_content_height) |height| {
        content_height = if (state.web_sizing) height else @max(content_height, height);
    } else if (state.web_sizing and source.kind != .replaced) {
        if (intrinsic.contentBlockSizeFromAspectRatio(style, content_width, horizontal_non_content, vertical_non_content)) |ratio_height| {
            content_height = ratio_height;
        }
    }
    if (intrinsic.resolveContentDimensionOptional(style.min_height, containing_height, vertical_non_content, style.box_sizing)) |minimum| content_height = @max(content_height, minimum);
    if (intrinsic.resolveContentDimensionOptional(style.max_height, containing_height, vertical_non_content, style.box_sizing)) |maximum| content_height = @min(content_height, maximum);
    if (source.kind == .replaced) {
        content_height = @max(content_height, replaced_size.?.height);
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
    if (source.kind == .replaced) {
        state.fragments.items[fragment_id].image_content_rect = .{
            .x = content_x,
            .y = content_y,
            .width = content_width,
            .height = content_height,
        };
    }

    cursor_y.* = outer_y + outer_height + margin.bottom;
    if (style.page_break_after == .always) state.advanceToNextPage(cursor_y);
    return state.fragments.items[fragment_id].rect;
}

pub fn isBlockLevel(kind: box.BoxType) bool {
    return switch (kind) {
        .block, .anonymousBlock, .table, .tableRow, .tableCell, .tableRowGroup, .tableCaption, .anonymousTableRow => true,
        else => false,
    };
}

fn minimumOuterWidth(state: anytype, box_id: box.BoxId) !f32 {
    const source = state.tree.boxes.items[box_id];
    const sizes = try state.measureIntrinsicInline(box_id);
    return sizes.min_content + source.margin.left + source.margin.right + source.border.left + source.border.right + source.padding.left + source.padding.right;
}

fn floatOuterWidth(state: anytype, box_id: box.BoxId, available: f32) !f32 {
    const source = state.tree.boxes.items[box_id];
    const sizes = try state.measureIntrinsicInline(box_id);
    const non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
    const content_width = intrinsic.resolveContentInlineDimension(source.style.width, available, non_content, source.style.box_sizing, sizes) orelse
        @min(sizes.max_content, @max(sizes.min_content, available - non_content));
    return content_width + non_content + source.margin.left + source.margin.right;
}

fn collapseMargins(previous: f32, next: f32) f32 {
    if (previous >= 0 and next >= 0) return @max(previous, next);
    if (previous <= 0 and next <= 0) return @min(previous, next);
    return previous + next;
}
