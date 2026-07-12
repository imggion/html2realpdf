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
    forced_content_width: ?f32 = null,
    forced_content_height: ?f32 = null,
    suppress_margin_top: bool = false,
    suppress_margin_bottom: bool = false,
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
    const margin_info = if (state.web_sizing) state.marginInfo(box_id) else MarginInfo.fromEdges(margin.top, margin.bottom);
    const used_margin_top = if (state.web_sizing and options.suppress_margin_top) 0 else margin_info.start.value();
    const used_margin_bottom = if (state.web_sizing and options.suppress_margin_bottom) 0 else margin_info.end.value();

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
    const specified_content_height = options.forced_content_height orelse intrinsic.resolveContentDimensionOptional(style.height, containing_height, vertical_non_content, style.box_sizing);
    const replaced_size = if (source.kind == .replaced) intrinsic.resolveReplacedSize(
        style,
        source.intrinsic_width,
        source.intrinsic_height,
        available_outer_width,
        containing_height,
        horizontal_non_content,
        vertical_non_content,
    ) else null;
    var requested_content_width = if (options.forced_content_width) |forced|
        forced
    else if (options.fill_available_width)
        @max(available_outer_width - horizontal_non_content, 1)
    else if (replaced_size) |size|
        size.width
    else if (options.shrink_to_fit and style.width.isAuto())
        @min(inline_sizes.max_content, @max(inline_sizes.min_content, available_outer_width - horizontal_non_content))
    else
        intrinsic.resolveContentInlineDimension(style.width, available_outer_width, horizontal_non_content, style.box_sizing, inline_sizes) orelse @max(available_outer_width - horizontal_non_content, 1);
    if (!options.fill_available_width and options.forced_content_width == null) {
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
    var outer_y = cursor_y.* + used_margin_top;

    const fragment_id = state.fragments.items.len;
    try state.fragments.append(state.allocator, .{
        .kind = if (source.kind == .replaced) .replaced else .box,
        .source_box = box_id,
        .rect = .{ .x = outer_x, .y = outer_y, .width = outer_width },
        .background = if (style.background) |value| geometry.parseColor(value) else null,
        .border = border,
        .border_paint = types.borderPaint(style),
        .border_radius = style.border_radius,
        .border_radii = style.border_radii,
        .box_decoration_break = style.box_decoration_break,
        .legacy_fragment_borders = !state.web_sizing,
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
    var inline_marker_offset: f32 = 0;
    var marker_line_height: f32 = 0;

    if (try state.listMarkerForBox(box_id)) |marker| {
        const marker_width = switch (marker.content) {
            .text => |text| intrinsic.measureText(state.font_registry, state.shaping_mode, text, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing),
            .circle, .square => style.font_size * 0.45,
        };
        const marker_gap = style.font_size * 0.5;
        marker_line_height = @max(style.line_height, style.font_size * 1.2);
        const marker_x = switch (marker.position) {
            .inside => content_x,
            .outside => if (style.direction == .rtl)
                content_x + content_width + marker_gap
            else
                @max(content_x - marker_width - marker_gap, 0),
        };
        if (marker.position == .inside) inline_marker_offset = marker_width + marker_gap;
        switch (marker.content) {
            .text => |text| try state.fragments.append(state.allocator, .{
                .kind = .text,
                .source_box = box_id,
                .rect = .{
                    .x = marker_x,
                    .y = content_y,
                    .width = marker_width,
                    .height = marker_line_height,
                },
                .text = text,
                .font_size = style.font_size,
                .font_family = style.font_family,
                .letter_spacing = style.letter_spacing,
                .font_weight = style.font_weight,
                .font_style = style.font_style,
                .color = geometry.parseColor(style.color) orelse geometry.Color.black,
                .text_decoration = style.text_decoration,
            }),
            .circle, .square => {
                const marker_color = geometry.parseColor(style.color) orelse geometry.Color.black;
                const is_circle = switch (marker.content) {
                    .circle => true,
                    .square => false,
                    else => unreachable,
                };
                try state.fragments.append(state.allocator, .{
                    .kind = .box,
                    .source_box = box_id,
                    .rect = .{
                        .x = marker_x,
                        .y = content_y + (marker_line_height - marker_width) / 2,
                        .width = marker_width,
                        .height = marker_width,
                    },
                    .background = if (is_circle) null else marker_color,
                    .border = if (is_circle) .{ .top = 1, .right = 1, .bottom = 1, .left = 1 } else .{},
                    .border_paint = .{
                        .top_color = marker_color,
                        .right_color = marker_color,
                        .bottom_color = marker_color,
                        .left_color = marker_color,
                    },
                    .border_radius = if (is_circle) marker_width / 2 else 0,
                    .border_radii = if (is_circle) blk: {
                        const radius = box.CornerRadius{ .x = .{ .px = marker_width / 2 }, .y = .{ .px = marker_width / 2 } };
                        break :blk .{ .top_left = radius, .top_right = radius, .bottom_right = radius, .bottom_left = radius };
                    } else .{},
                });
            },
        }
    }

    if (source.kind == .replaced) {
        child_cursor_y += replaced_size.?.height;
    } else if (state.web_sizing and (style.display == .flex or style.display == .inlineFlex)) {
        child_cursor_y += try state.layoutFlex(
            box_id,
            .{ .x = content_x, .y = content_y, .width = content_width, .height = specified_content_height orelse 0 },
            specified_content_height,
        );
    } else if (state.web_sizing and (style.display == .grid or style.display == .inlineGrid)) {
        child_cursor_y += try state.layoutGrid(
            box_id,
            .{ .x = content_x, .y = content_y, .width = content_width, .height = specified_content_height orelse 0 },
            specified_content_height,
        );
    } else if (source.kind == .table) {
        child_cursor_y += try state.layoutTable(box_id, content_x, content_y, content_width);
    } else if (source.first_child) |_| {
        if (state.hasBlockChildren(box_id)) {
            if (inline_marker_offset > 0) {
                child_cursor_y += marker_line_height;
                inline_marker_offset = 0;
            }
            var float_context = try floats.Context.init(state.allocator, .{
                .x = content_x,
                .y = content_y,
                .width = content_width,
            });
            defer float_context.deinit();
            var previous_bottom_margin: f32 = 0;
            var pending_margin = MarginStrut{};
            var parent_start_open = state.web_sizing and canCollapseStartWithChildren(state.tree, box_id);
            var last_in_flow_was_block = false;
            var child = source.first_child;
            while (child) |child_id| {
                const child_box = state.tree.boxes.items[child_id];
                if (state.web_sizing and (child_box.style.position == .absolute or child_box.style.position == .fixed)) {
                    try state.deferPositioned(child_id, .{ .x = content_x, .y = child_cursor_y });
                } else if (state.web_sizing and child_box.style.float_direction != .none) {
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
                        const child_margin = state.marginInfo(child_id);
                        if (child_margin.through and child_box.style.clear_direction == .none) {
                            pending_margin.combine(child_margin.start);
                            var empty_cursor = child_cursor_y;
                            _ = try state.layoutBlockWithOptions(
                                child_id,
                                .{ .x = content_x, .y = content_y, .width = content_width },
                                &empty_cursor,
                                .{
                                    .containing_block_height = specified_content_height,
                                    .suppress_margin_top = true,
                                    .suppress_margin_bottom = true,
                                },
                            );
                            child = child_box.next_sibling;
                            continue;
                        }

                        if (child_box.style.clear_direction != .none) {
                            child_cursor_y += pending_margin.value() + child_margin.start.value();
                        } else if (!parent_start_open) {
                            var collapsed = pending_margin;
                            collapsed.combine(child_margin.start);
                            child_cursor_y += collapsed.value();
                        }
                        pending_margin = .{};
                        const required_width = try minimumOuterWidth(state, child_id);
                        child_cursor_y = float_context.placementY(child_cursor_y, @min(required_width, content_width), child_box.style.clear_direction);
                        const band = float_context.bandAt(child_cursor_y);
                        _ = try state.layoutBlockWithOptions(
                            child_id,
                            .{ .x = band.x, .y = content_y, .width = @max(band.width, 1) },
                            &child_cursor_y,
                            .{
                                .containing_block_height = specified_content_height,
                                .suppress_margin_top = true,
                                .suppress_margin_bottom = true,
                            },
                        );
                        pending_margin = child_margin.end;
                        parent_start_open = false;
                        last_in_flow_was_block = true;
                    } else {
                        const collapsed = collapseMargins(previous_bottom_margin, child_box.margin.top);
                        child_cursor_y -= previous_bottom_margin + child_box.margin.top - collapsed;
                        _ = try state.layoutBlockWithOptions(
                            child_id,
                            .{ .x = content_x, .y = content_y, .width = content_width },
                            &child_cursor_y,
                            .{ .containing_block_height = containing.height },
                        );
                        previous_bottom_margin = child_box.margin.bottom;
                    }
                } else {
                    if (state.web_sizing) {
                        child_cursor_y += pending_margin.value();
                        pending_margin = .{};
                        parent_start_open = false;
                        last_in_flow_was_block = false;
                    }
                    const run_height = try state.layoutInlineRun(child_id, content_x, child_cursor_y, content_width, style.text_align);
                    child_cursor_y += run_height;
                    previous_bottom_margin = 0;
                }
                child = child_box.next_sibling;
            }
            if (state.web_sizing) {
                if (!(last_in_flow_was_block and canCollapseEndWithChildren(state.tree, box_id))) {
                    child_cursor_y += pending_margin.value();
                }
                child_cursor_y = @max(child_cursor_y, float_context.maximumBottom());
            }
        } else {
            const inline_height = try state.layoutInlineChildrenWithOffset(box_id, content_x, content_y, content_width, style.text_align, inline_marker_offset);
            child_cursor_y += inline_height;
        }
    } else if (marker_line_height > 0) {
        child_cursor_y += marker_line_height;
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
        if (options.forced_content_height == null and options.forced_content_width != null and replaced_size.?.ratio != null) {
            content_height = options.forced_content_width.? / replaced_size.?.ratio.?;
        } else if (options.forced_content_height == null and style.width.isAuto() and style.height.isAuto() and replaced_size.?.ratio != null) {
            content_height = content_width / replaced_size.?.ratio.?;
        } else {
            content_height = @max(content_height, replaced_size.?.height);
        }
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

    cursor_y.* = outer_y + outer_height + used_margin_bottom;
    if (style.page_break_after == .always) state.advanceToNextPage(cursor_y);
    return state.fragments.items[fragment_id].rect;
}

pub fn isBlockLevel(kind: box.BoxType) bool {
    return switch (kind) {
        .block, .listItem, .anonymousBlock, .table, .tableRow, .tableCell, .tableRowGroup, .tableCaption, .anonymousTableRow => true,
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

pub const MarginStrut = struct {
    positive: f32 = 0,
    negative: f32 = 0,

    fn fromValue(value_: f32) MarginStrut {
        var result = MarginStrut{};
        result.add(value_);
        return result;
    }

    fn add(self: *MarginStrut, margin: f32) void {
        if (margin >= 0) {
            self.positive = @max(self.positive, margin);
        } else {
            self.negative = @min(self.negative, margin);
        }
    }

    fn combine(self: *MarginStrut, other: MarginStrut) void {
        self.positive = @max(self.positive, other.positive);
        self.negative = @min(self.negative, other.negative);
    }

    fn value(self: MarginStrut) f32 {
        return self.positive + self.negative;
    }
};

pub const MarginInfo = struct {
    start: MarginStrut,
    end: MarginStrut,
    through: bool = false,

    fn fromEdges(top: f32, bottom: f32) MarginInfo {
        return .{ .start = .fromValue(top), .end = .fromValue(bottom) };
    }
};

/// Collects every adjoining margin before geometry is assigned. Keeping the
/// positive maximum and negative minimum separately makes the operation
/// associative, which is required for empty blocks that collapse through.
pub fn marginInfo(tree: *const box.BoxTree, box_id: box.BoxId, cache: []?MarginInfo) MarginInfo {
    if (cache[box_id]) |cached| return cached;
    const source = tree.boxes.items[box_id];
    var result = MarginInfo.fromEdges(source.margin.top, source.margin.bottom);

    if (marginsCollapseThrough(tree, box_id, cache)) {
        var group = result.start;
        group.combine(result.end);
        var child = source.first_child;
        while (child) |child_id| {
            const child_box = tree.boxes.items[child_id];
            if (!isOutOfFlowMarginBox(child_box)) {
                const child_info = marginInfo(tree, child_id, cache);
                group.combine(child_info.start);
                group.combine(child_info.end);
            }
            child = child_box.next_sibling;
        }
        const collapsed = MarginInfo{ .start = group, .end = group, .through = true };
        cache[box_id] = collapsed;
        return collapsed;
    }

    if (canCollapseStartWithChildren(tree, box_id)) {
        var child = source.first_child;
        while (child) |child_id| {
            const child_box = tree.boxes.items[child_id];
            child = child_box.next_sibling;
            if (isOutOfFlowMarginBox(child_box)) continue;
            if (!isMarginCollapsingBlock(child_box.kind) or child_box.style.clear_direction != .none) break;
            const child_info = marginInfo(tree, child_id, cache);
            result.start.combine(child_info.start);
            if (!child_info.through) break;
            result.start.combine(child_info.end);
        }
    }

    if (canCollapseEndWithChildren(tree, box_id)) {
        var child = source.last_child;
        while (child) |child_id| {
            const child_box = tree.boxes.items[child_id];
            child = child_box.prev_sibling;
            if (isOutOfFlowMarginBox(child_box)) continue;
            if (!isMarginCollapsingBlock(child_box.kind) or child_box.style.clear_direction != .none) break;
            const child_info = marginInfo(tree, child_id, cache);
            result.end.combine(child_info.end);
            if (!child_info.through) break;
            result.end.combine(child_info.start);
        }
    }

    cache[box_id] = result;
    return result;
}

fn canCollapseStartWithChildren(tree: *const box.BoxTree, box_id: box.BoxId) bool {
    if (box_id == tree.root) return false;
    const source = tree.boxes.items[box_id];
    return acceptsCollapsingChildren(source) and source.border.top == 0 and source.padding.top == 0;
}

fn canCollapseEndWithChildren(tree: *const box.BoxTree, box_id: box.BoxId) bool {
    if (box_id == tree.root) return false;
    const source = tree.boxes.items[box_id];
    return acceptsCollapsingChildren(source) and
        source.border.bottom == 0 and source.padding.bottom == 0 and
        isAutoOrZero(source.style.height) and isAutoOrZero(source.style.min_height);
}

fn marginsCollapseThrough(tree: *const box.BoxTree, box_id: box.BoxId, cache: []?MarginInfo) bool {
    const source = tree.boxes.items[box_id];
    if (!canCollapseStartWithChildren(tree, box_id) or !canCollapseEndWithChildren(tree, box_id)) return false;
    if (source.style.clear_direction != .none) return false;
    if (source.kind == .listItem and source.style.list_style_type != .none) return false;

    var child = source.first_child;
    while (child) |child_id| {
        const child_box = tree.boxes.items[child_id];
        child = child_box.next_sibling;
        if (isOutOfFlowMarginBox(child_box)) continue;
        if (!isMarginCollapsingBlock(child_box.kind) or !marginInfo(tree, child_id, cache).through) return false;
    }
    return true;
}

fn acceptsCollapsingChildren(source: box.Box) bool {
    const block_container = source.kind == .block or source.kind == .listItem or source.kind == .anonymousBlock;
    return block_container and source.style.float_direction == .none and
        source.style.display != .flex and source.style.display != .inlineFlex and
        source.style.display != .grid and source.style.display != .inlineGrid and
        source.style.position != .absolute and source.style.position != .fixed and
        source.style.overflow == .visible;
}

fn isOutOfFlowMarginBox(source: box.Box) bool {
    return source.style.float_direction != .none or source.style.position == .absolute or source.style.position == .fixed;
}

fn isMarginCollapsingBlock(kind: box.BoxType) bool {
    return kind == .block or kind == .listItem or kind == .anonymousBlock or kind == .table;
}

fn isAutoOrZero(length: box.Length) bool {
    return switch (length) {
        .auto => true,
        .px => |value_| @abs(value_) <= 0.0001,
        else => false,
    };
}
