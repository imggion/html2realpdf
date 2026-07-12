//! Flex formatting context implementation for the Web CSS profile.
//!
//! Flex items are measured first, split into lines, flexed on the main axis,
//! laid out through the normal block formatter, and finally translated into
//! their resolved main/cross positions. The Box Tree remains flat throughout.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const floats = @import("floats.zig");
const intrinsic = @import("intrinsic.zig");

pub const supported = true;

const Item = struct {
    box_id: box.BoxId,
    source_index: usize,
    base_main: f32,
    target_main: f32,
    main_non_content: f32,
    main_margin_start: f32,
    main_margin_end: f32,
    cross_margin_start: f32,
    cross_margin_end: f32,
    main_margin_start_auto: bool,
    main_margin_end_auto: bool,
    cross_margin_start_auto: bool,
    cross_margin_end_auto: bool,
    fragment_start: usize = 0,
    fragment_end: usize = 0,
    rect: geometry.Rect = .{},
    baseline: f32 = 0,
    main_position: f32 = 0,
    frozen: bool = false,
    fragmentation_positioned: bool = false,

    fn outerMain(self: Item) f32 {
        return self.target_main + self.main_non_content + self.main_margin_start + self.main_margin_end;
    }

    fn outerCross(self: Item, row_axis: bool) f32 {
        const cross_size = if (row_axis) self.rect.height else self.rect.width;
        return cross_size + self.cross_margin_start + self.cross_margin_end;
    }
};

const Line = struct {
    start: usize,
    count: usize = 0,
    main_sum: f32 = 0,
    cross_size: f32 = 0,
    cross_position: f32 = 0,
    baseline: f32 = 0,
    fragmentation_positioned: bool = false,
};

const Distribution = struct { start: f32 = 0, between: f32 = 0 };

pub fn layout(
    state: anytype,
    container_id: box.BoxId,
    content: geometry.Rect,
    specified_content_height: ?f32,
) !f32 {
    const container = state.tree.boxes.items[container_id];
    const style = container.style;
    const row_axis = style.flex_direction.isRow();
    const main_gap = resolvedGap(if (row_axis) style.column_gap else style.row_gap, if (row_axis) content.width else specified_content_height orelse 0);
    const cross_gap = resolvedGap(if (row_axis) style.row_gap else style.column_gap, content.width);

    var items = try std.ArrayList(Item).initCapacity(state.allocator, 0);
    defer items.deinit(state.allocator);
    var child = container.first_child;
    var source_index: usize = 0;
    while (child) |child_id| : (source_index += 1) {
        const source = state.tree.boxes.items[child_id];
        child = source.next_sibling;
        if (source.style.position == .absolute or source.style.position == .fixed) {
            try state.deferPositioned(child_id, .{ .x = content.x, .y = content.y });
            continue;
        }
        try items.append(state.allocator, try makeItem(state, child_id, source_index, row_axis, content, specified_content_height));
    }
    if (items.items.len == 0) return specified_content_height orelse 0;

    std.mem.sort(Item, items.items, state.tree, itemLessThan);

    const natural_main = sumOuterMain(items.items, main_gap);
    const main_size = if (row_axis) content.width else specified_content_height orelse natural_main;
    var lines = try buildLines(state.allocator, items.items, main_size, main_gap, style.flex_wrap != .nowrap);
    defer lines.deinit(state.allocator);
    for (lines.items) |*line| {
        const line_items = items.items[line.start .. line.start + line.count];
        resolveFlexibleLengths(state, line_items, line, main_size, main_gap, row_axis);
        resolveMainAutoMargins(line_items, line, main_size, main_gap);
    }

    for (items.items) |*item| {
        try layoutItem(state, item, row_axis, content, specified_content_height, style.align_items);
    }
    for (lines.items) |*line| measureLineCross(state, items.items[line.start .. line.start + line.count], line, row_axis, style.align_items);

    var natural_cross: f32 = 0;
    for (lines.items, 0..) |line, index| {
        if (index > 0) natural_cross += cross_gap;
        natural_cross += line.cross_size;
    }
    const cross_size = if (row_axis) specified_content_height orelse natural_cross else content.width;
    if (style.flex_wrap == .nowrap) {
        lines.items[0].cross_size = cross_size;
        lines.items[0].cross_position = 0;
    } else {
        positionLines(lines.items, cross_size, natural_cross, cross_gap, style.align_content, style.flex_wrap == .wrapReverse);
    }
    const fragmented_cross = if (row_axis and state.page_height != null)
        fragmentRowLines(lines.items, content.y, state.page_height.?)
    else
        cross_size;

    const reverse_main = style.flex_direction.isReverse() != (row_axis and style.direction == .rtl);
    var fragmented_main = main_size;
    for (lines.items) |line| {
        fragmented_main = @max(fragmented_main, positionLineItems(
            state,
            items.items[line.start .. line.start + line.count],
            line,
            content,
            main_size,
            main_gap,
            row_axis,
            reverse_main,
            style.justify_content,
            style.align_items,
        ));
    }

    return if (row_axis and specified_content_height == null)
        @max(cross_size, fragmented_cross)
    else if (row_axis)
        cross_size
    else if (specified_content_height == null)
        fragmented_main
    else
        main_size;
}

fn makeItem(
    state: anytype,
    box_id: box.BoxId,
    source_index: usize,
    row_axis: bool,
    content: geometry.Rect,
    specified_content_height: ?f32,
) !Item {
    const source = state.tree.boxes.items[box_id];
    const horizontal_non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
    const vertical_non_content = source.border.top + source.border.bottom + source.padding.top + source.padding.bottom;
    const inline_sizes = try state.measureIntrinsicInline(box_id);

    const base_main = if (row_axis) blk: {
        const basis = if (source.style.flex_basis == .auto) source.style.width else source.style.flex_basis;
        var value = intrinsic.resolveContentInlineDimension(basis, content.width, horizontal_non_content, source.style.box_sizing, inline_sizes) orelse inline_sizes.max_content;
        if (intrinsic.resolveContentInlineDimension(source.style.min_width, content.width, horizontal_non_content, source.style.box_sizing, inline_sizes)) |minimum| value = @max(value, minimum);
        if (intrinsic.resolveContentInlineDimension(source.style.max_width, content.width, horizontal_non_content, source.style.box_sizing, inline_sizes)) |maximum| value = @min(value, maximum);
        break :blk @max(value, 0);
    } else blk: {
        const basis = if (source.style.flex_basis == .auto) source.style.height else source.style.flex_basis;
        if (intrinsic.resolveContentDimensionOptional(basis, specified_content_height, vertical_non_content, source.style.box_sizing)) |value| break :blk value;
        const available_content_width = @max(content.width - horizontal_non_content - source.margin.left - source.margin.right, 1);
        break :blk try measureNaturalContentHeight(state, box_id, available_content_width, content.width, vertical_non_content);
    };

    return .{
        .box_id = box_id,
        .source_index = source_index,
        .base_main = base_main,
        .target_main = base_main,
        .main_non_content = if (row_axis) horizontal_non_content else vertical_non_content,
        .main_margin_start = if (row_axis) source.margin.left else source.margin.top,
        .main_margin_end = if (row_axis) source.margin.right else source.margin.bottom,
        .cross_margin_start = if (row_axis) source.margin.top else source.margin.left,
        .cross_margin_end = if (row_axis) source.margin.bottom else source.margin.right,
        .main_margin_start_auto = if (row_axis) source.style.margin_auto.left else source.style.margin_auto.top,
        .main_margin_end_auto = if (row_axis) source.style.margin_auto.right else source.style.margin_auto.bottom,
        .cross_margin_start_auto = if (row_axis) source.style.margin_auto.top else source.style.margin_auto.left,
        .cross_margin_end_auto = if (row_axis) source.style.margin_auto.bottom else source.style.margin_auto.right,
    };
}

fn measureNaturalContentHeight(state: anytype, box_id: box.BoxId, content_width: f32, containing_width: f32, vertical_non_content: f32) !f32 {
    const fragment_start = state.fragments.items.len;
    var cursor_y: f32 = 0;
    const rect = try state.layoutBlockWithOptions(
        box_id,
        .{ .width = containing_width },
        &cursor_y,
        .{
            .forced_content_width = content_width,
            .suppress_margin_top = true,
            .suppress_margin_bottom = true,
        },
    );
    state.fragments.items.len = fragment_start;
    return @max(rect.height - vertical_non_content, 0);
}

fn itemLessThan(tree: *const box.BoxTree, a: Item, b: Item) bool {
    const a_order = tree.boxes.items[a.box_id].style.order;
    const b_order = tree.boxes.items[b.box_id].style.order;
    return if (a_order == b_order) a.source_index < b.source_index else a_order < b_order;
}

fn buildLines(allocator: std.mem.Allocator, items: []const Item, main_size: f32, gap: f32, wrapping: bool) !std.ArrayList(Line) {
    var lines = try std.ArrayList(Line).initCapacity(allocator, 1);
    try lines.append(allocator, .{ .start = 0 });
    for (items, 0..) |item, index| {
        var line = &lines.items[lines.items.len - 1];
        const outer = item.outerMain();
        const next_sum = line.main_sum + (if (line.count > 0) gap else 0) + outer;
        if (wrapping and line.count > 0 and next_sum > main_size) {
            try lines.append(allocator, .{ .start = index, .count = 1, .main_sum = outer });
        } else {
            if (line.count > 0) line.main_sum += gap;
            line.main_sum += outer;
            line.count += 1;
        }
    }
    return lines;
}

fn resolveFlexibleLengths(state: anytype, items: []Item, line: *Line, main_size: f32, gap: f32, row_axis: bool) void {
    const initial_free = main_size - line.main_sum;
    if (@abs(initial_free) <= 0.001) return;
    const growing = initial_free > 0;
    for (items) |*item| {
        item.target_main = item.base_main;
        const style = state.tree.boxes.items[item.box_id].style;
        item.frozen = if (growing) style.flex_grow <= 0 else style.flex_shrink <= 0;
    }

    var iteration: usize = 0;
    while (iteration <= items.len) : (iteration += 1) {
        var hypothetical_sum = gap * @as(f32, @floatFromInt(items.len -| 1));
        var factor_sum: f32 = 0;
        var raw_factor_sum: f32 = 0;
        for (items) |item| {
            hypothetical_sum += item.main_non_content + item.main_margin_start + item.main_margin_end + if (item.frozen) item.target_main else item.base_main;
            if (!item.frozen) {
                const style = state.tree.boxes.items[item.box_id].style;
                factor_sum += if (growing) style.flex_grow else style.flex_shrink * item.base_main;
                raw_factor_sum += if (growing) style.flex_grow else style.flex_shrink;
            }
        }
        if (factor_sum <= 0) break;
        var free_space = main_size - hypothetical_sum;
        if (raw_factor_sum < 1) {
            const partial_free_space = initial_free * raw_factor_sum;
            if (@abs(partial_free_space) < @abs(free_space)) free_space = partial_free_space;
        }
        var froze_item = false;
        for (items) |*item| {
            if (item.frozen) continue;
            const style = state.tree.boxes.items[item.box_id].style;
            const factor = if (growing) style.flex_grow else style.flex_shrink * item.base_main;
            const proposed = item.base_main + free_space * factor / factor_sum;
            const clamped = clampMainSize(state, item.box_id, proposed, main_size, row_axis);
            item.target_main = clamped;
            if (@abs(clamped - proposed) > 0.001) {
                item.frozen = true;
                froze_item = true;
            }
        }
        if (!froze_item) break;
    }
    line.main_sum = sumOuterMain(items, gap);
}

fn resolveMainAutoMargins(items: []Item, line: *Line, main_size: f32, gap: f32) void {
    var auto_count: usize = 0;
    for (items) |item| {
        if (item.main_margin_start_auto) auto_count += 1;
        if (item.main_margin_end_auto) auto_count += 1;
    }
    if (auto_count == 0) return;
    const free = main_size - sumOuterMain(items, gap);
    if (free <= 0) return;
    const share = free / @as(f32, @floatFromInt(auto_count));
    for (items) |*item| {
        if (item.main_margin_start_auto) item.main_margin_start = share;
        if (item.main_margin_end_auto) item.main_margin_end = share;
    }
    line.main_sum = sumOuterMain(items, gap);
}

fn clampMainSize(state: anytype, box_id: box.BoxId, proposed: f32, main_size: f32, row_axis: bool) f32 {
    const source = state.tree.boxes.items[box_id];
    var target = @max(proposed, 0);
    if (row_axis) {
        const sizes = state.measureIntrinsicInline(box_id) catch intrinsic.InlineSizes{};
        const horizontal_non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
        const minimum = intrinsic.resolveContentInlineDimension(source.style.min_width, main_size, horizontal_non_content, source.style.box_sizing, sizes) orelse if (source.style.overflow == .visible) sizes.min_content else 0;
        if (intrinsic.resolveContentInlineDimension(source.style.max_width, main_size, horizontal_non_content, source.style.box_sizing, sizes)) |maximum| target = @min(target, maximum);
        target = @max(target, minimum);
    } else {
        const vertical_non_content = source.border.top + source.border.bottom + source.padding.top + source.padding.bottom;
        if (intrinsic.resolveContentDimensionOptional(source.style.min_height, main_size, vertical_non_content, source.style.box_sizing)) |minimum| target = @max(target, minimum);
        if (intrinsic.resolveContentDimensionOptional(source.style.max_height, main_size, vertical_non_content, source.style.box_sizing)) |maximum| target = @min(target, maximum);
    }
    return target;
}

fn layoutItem(state: anytype, item: *Item, row_axis: bool, content: geometry.Rect, specified_height: ?f32, container_align: box.AlignItems) !void {
    const source = state.tree.boxes.items[item.box_id];
    const horizontal_non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
    const available_cross_content = @max(content.width - horizontal_non_content - source.margin.left - source.margin.right, 1);
    const alignment = resolvedAlignment(source.style.align_self, container_align);
    const forced_width: ?f32 = if (row_axis)
        item.target_main
    else if (alignment == .stretch and source.style.width == .auto)
        available_cross_content
    else
        intrinsic.resolveContentInlineDimension(source.style.width, content.width, horizontal_non_content, source.style.box_sizing, try state.measureIntrinsicInline(item.box_id));
    const forced_height: ?f32 = if (row_axis) null else item.target_main;
    const slot_width = (forced_width orelse available_cross_content) + horizontal_non_content + source.margin.left + source.margin.right;

    item.fragment_start = state.fragments.items.len;
    var cursor_y: f32 = 0;
    item.rect = try state.layoutBlockWithOptions(
        item.box_id,
        .{ .width = slot_width, .height = specified_height orelse 0 },
        &cursor_y,
        .{
            .forced_content_width = forced_width,
            .forced_content_height = forced_height,
            .containing_block_height = specified_height,
            .suppress_margin_top = true,
            .suppress_margin_bottom = true,
        },
    );
    item.fragment_end = state.fragments.items.len;
    item.baseline = itemBaseline(state.fragments.items[item.fragment_start..item.fragment_end], item.rect, row_axis);
}

fn measureLineCross(state: anytype, items: []Item, line: *Line, row_axis: bool, container_align: box.AlignItems) void {
    for (items) |item| {
        line.cross_size = @max(line.cross_size, item.outerCross(row_axis));
        const source = state.tree.boxes.items[item.box_id];
        if (resolvedAlignment(source.style.align_self, container_align) == .baseline) {
            line.baseline = @max(line.baseline, item.cross_margin_start + item.baseline);
        }
    }
}

fn positionLines(lines: []Line, cross_size: f32, natural_cross: f32, gap: f32, alignment: box.AlignContent, reverse: bool) void {
    var effective_gap = gap;
    const free = cross_size - natural_cross;
    const distribution = alignContentDistribution(alignment, free, lines.len);
    effective_gap += distribution.between;
    if (alignment == .stretch and free > 0 and lines.len > 0) {
        const extra = free / @as(f32, @floatFromInt(lines.len));
        for (lines) |*line| line.cross_size += extra;
    }

    var cursor = distribution.start;
    for (0..lines.len) |offset| {
        const index = if (reverse) lines.len - offset - 1 else offset;
        lines[index].cross_position = cursor;
        cursor += lines[index].cross_size + effective_gap;
    }
}

/// Keep a flex line together when it fits on one page but not in the remaining
/// fragmentainer space. Lines are visited by physical cross position so
/// `wrap-reverse` receives the same page-boundary behavior without changing
/// order-modified painting order.
fn fragmentRowLines(lines: []Line, content_y: f32, page_height: f32) f32 {
    var cumulative_shift: f32 = 0;
    var extent: f32 = 0;
    var positioned: usize = 0;
    while (positioned < lines.len) : (positioned += 1) {
        var next_index: ?usize = null;
        for (lines, 0..) |line, index| {
            if (line.fragmentation_positioned) continue;
            if (next_index == null or line.cross_position < lines[next_index.?].cross_position) next_index = index;
        }
        const line = &lines[next_index.?];
        line.cross_position += cumulative_shift;
        const absolute_y = content_y + line.cross_position;
        const page_y = @mod(absolute_y, page_height);
        if (page_y > 0 and line.cross_size <= page_height and page_y + line.cross_size > page_height) {
            const shift = page_height - page_y;
            line.cross_position += shift;
            cumulative_shift += shift;
        }
        line.fragmentation_positioned = true;
        extent = @max(extent, line.cross_position + line.cross_size);
    }
    return extent;
}

fn positionLineItems(
    state: anytype,
    items: []Item,
    line: Line,
    content: geometry.Rect,
    main_size: f32,
    gap: f32,
    row_axis: bool,
    reverse_main: bool,
    justify: box.JustifyContent,
    container_align: box.AlignItems,
) f32 {
    const free = main_size - line.main_sum;
    const distribution = justifyDistribution(justify, free, items.len);
    const between = gap + distribution.between;
    var cursor = if (reverse_main) main_size - distribution.start else distribution.start;

    for (items) |*item| {
        const outer_main = item.outerMain();
        const margin_box_main = if (reverse_main) blk: {
            cursor -= outer_main;
            break :blk cursor;
        } else cursor;
        item.main_position = margin_box_main + item.main_margin_start;
        if (!reverse_main) cursor += outer_main;
        cursor += if (reverse_main) -between else between;
    }

    const fragmented_main = if (!row_axis and state.page_height != null)
        fragmentColumnItems(items, content.y, state.page_height.?)
    else
        main_size;

    for (items) |*item| {
        const source = state.tree.boxes.items[item.box_id];
        const has_cross_auto_margin = item.cross_margin_start_auto or item.cross_margin_end_auto;
        const alignment = resolvedAlignment(source.style.align_self, container_align);
        var cross_size = if (row_axis) item.rect.height else item.rect.width;
        if (!has_cross_auto_margin and alignment == .stretch and crossSizeIsAuto(source.style, row_axis)) {
            cross_size = clampCrossSize(
                state,
                item.box_id,
                @max(line.cross_size - item.cross_margin_start - item.cross_margin_end, 0),
                line.cross_size,
                row_axis,
            );
            if (item.fragment_start < item.fragment_end) {
                const root_fragment = &state.fragments.items[item.fragment_start];
                if (row_axis) {
                    root_fragment.rect.height = cross_size;
                    if (root_fragment.image_content_rect) |*image_rect| {
                        image_rect.height = @max(cross_size - source.border.top - source.border.bottom - source.padding.top - source.padding.bottom, 0);
                    }
                } else {
                    root_fragment.rect.width = cross_size;
                    if (root_fragment.image_content_rect) |*image_rect| {
                        image_rect.width = @max(cross_size - source.border.left - source.border.right - source.padding.left - source.padding.right, 0);
                    }
                }
            }
            if (row_axis) item.rect.height = cross_size else item.rect.width = cross_size;
        }
        const outer_cross = cross_size + item.cross_margin_start + item.cross_margin_end;
        const auto_cross_space = @max(line.cross_size - outer_cross, 0);
        const cross_offset = if (has_cross_auto_margin)
            item.cross_margin_start + if (item.cross_margin_start_auto)
                auto_cross_space / @as(f32, if (item.cross_margin_end_auto) 2 else 1)
            else
                0
        else switch (alignment) {
            .stretch, .flexStart => item.cross_margin_start,
            .flexEnd => line.cross_size - cross_size - item.cross_margin_end,
            .center => (line.cross_size - outer_cross) / 2 + item.cross_margin_start,
            .baseline => @max(line.baseline - item.baseline, item.cross_margin_start),
        };

        const target_x = if (row_axis) content.x + item.main_position else content.x + line.cross_position + cross_offset;
        const target_y = if (row_axis) content.y + line.cross_position + cross_offset else content.y + item.main_position;
        const shift_x = target_x - item.rect.x;
        const shift_y = target_y - item.rect.y;
        floats.shiftFragments(state.fragments.items[item.fragment_start..item.fragment_end], shift_x, shift_y);
        item.rect.x = target_x;
        item.rect.y = target_y;
    }
    return fragmented_main;
}

fn clampCrossSize(state: anytype, box_id: box.BoxId, proposed: f32, reference: f32, row_axis: bool) f32 {
    const source = state.tree.boxes.items[box_id];
    var target = proposed;
    if (row_axis) {
        const non_content = source.border.top + source.border.bottom + source.padding.top + source.padding.bottom;
        if (intrinsic.resolveContentDimensionOptional(source.style.max_height, reference, non_content, source.style.box_sizing)) |maximum| target = @min(target, maximum + non_content);
        if (intrinsic.resolveContentDimensionOptional(source.style.min_height, reference, non_content, source.style.box_sizing)) |minimum| target = @max(target, minimum + non_content);
    } else {
        const non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
        const sizes = state.measureIntrinsicInline(box_id) catch intrinsic.InlineSizes{};
        if (intrinsic.resolveContentInlineDimension(source.style.max_width, reference, non_content, source.style.box_sizing, sizes)) |maximum| target = @min(target, maximum + non_content);
        if (intrinsic.resolveContentInlineDimension(source.style.min_width, reference, non_content, source.style.box_sizing, sizes)) |minimum| target = @max(target, minimum + non_content);
    }
    return @max(target, 0);
}

fn fragmentColumnItems(items: []Item, content_y: f32, page_height: f32) f32 {
    var cumulative_shift: f32 = 0;
    var extent: f32 = 0;
    var positioned: usize = 0;
    while (positioned < items.len) : (positioned += 1) {
        var next_index: ?usize = null;
        for (items, 0..) |item, index| {
            if (item.fragmentation_positioned) continue;
            if (next_index == null or item.main_position < items[next_index.?].main_position) next_index = index;
        }
        const item = &items[next_index.?];
        item.main_position += cumulative_shift;
        const absolute_y = content_y + item.main_position;
        const page_y = @mod(absolute_y, page_height);
        if (page_y > 0 and item.rect.height <= page_height and page_y + item.rect.height > page_height) {
            const shift = page_height - page_y;
            item.main_position += shift;
            cumulative_shift += shift;
        }
        item.fragmentation_positioned = true;
        extent = @max(extent, item.main_position + item.rect.height + item.main_margin_end);
    }
    return extent;
}

fn resolvedAlignment(self: box.AlignSelf, parent: box.AlignItems) box.AlignItems {
    return switch (self) {
        .auto => parent,
        .stretch => .stretch,
        .flexStart => .flexStart,
        .flexEnd => .flexEnd,
        .center => .center,
        .baseline => .baseline,
    };
}

fn crossSizeIsAuto(style: box.Style, row_axis: bool) bool {
    return if (row_axis) style.height == .auto else style.width == .auto;
}

fn itemBaseline(fragments: []const @import("types.zig").Fragment, rect: geometry.Rect, row_axis: bool) f32 {
    if (!row_axis) return rect.width;
    for (fragments) |fragment| {
        if (fragment.kind == .text) return fragment.rect.y - rect.y + fragment.font_size * 0.8;
    }
    return rect.height;
}

fn justifyDistribution(alignment: box.JustifyContent, free_space: f32, count: usize) Distribution {
    return switch (alignment) {
        .normal, .flexStart => .{},
        .flexEnd => .{ .start = free_space },
        .center => .{ .start = free_space / 2 },
        .spaceBetween => if (count > 1 and free_space > 0) .{ .between = free_space / @as(f32, @floatFromInt(count - 1)) } else .{},
        .spaceAround => if (count > 0 and free_space > 0) blk: {
            const space = free_space / @as(f32, @floatFromInt(count));
            break :blk .{ .start = space / 2, .between = space };
        } else .{},
        .spaceEvenly => if (count > 0 and free_space > 0) blk: {
            const space = free_space / @as(f32, @floatFromInt(count + 1));
            break :blk .{ .start = space, .between = space };
        } else .{},
    };
}

fn alignContentDistribution(alignment: box.AlignContent, free_space: f32, count: usize) Distribution {
    return switch (alignment) {
        .stretch, .flexStart => .{},
        .flexEnd => .{ .start = free_space },
        .center => .{ .start = free_space / 2 },
        .spaceBetween => if (count > 1 and free_space > 0) .{ .between = free_space / @as(f32, @floatFromInt(count - 1)) } else .{},
        .spaceAround => if (count > 0 and free_space > 0) blk: {
            const space = free_space / @as(f32, @floatFromInt(count));
            break :blk .{ .start = space / 2, .between = space };
        } else .{},
        .spaceEvenly => if (count > 0 and free_space > 0) blk: {
            const space = free_space / @as(f32, @floatFromInt(count + 1));
            break :blk .{ .start = space, .between = space };
        } else .{},
    };
}

fn resolvedGap(length: box.Length, reference: f32) f32 {
    return @max(length.resolve(reference) orelse 0, 0);
}

fn sumOuterMain(items: []const Item, gap: f32) f32 {
    var sum: f32 = 0;
    for (items, 0..) |item, index| {
        if (index > 0) sum += gap;
        sum += item.outerMain();
    }
    return sum;
}
