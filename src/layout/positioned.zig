//! Positioned formatting context for the Web CSS profile.
//!
//! Out-of-flow boxes are collected during normal-flow traversal and laid out
//! after the continuous containing-block geometry is known. This keeps static
//! flow sizing independent while allowing nested positioned descendants to
//! resolve against an already-positioned ancestor.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const floats = @import("floats.zig");

pub const supported = true;

pub const Pending = struct {
    box_id: box.BoxId,
    static_position: geometry.Point,
};

pub fn layoutPending(state: anytype, initial_containing_block: geometry.Rect) !void {
    var index: usize = 0;
    while (index < state.pending_positioned.items.len) : (index += 1) {
        const pending = state.pending_positioned.items[index];
        const source = state.tree.boxes.items[pending.box_id];
        const containing = if (source.style.position == .fixed)
            initial_containing_block
        else
            containingBlock(state, pending.box_id, initial_containing_block);
        try layoutOne(state, pending, containing);
    }
}

fn layoutOne(state: anytype, pending: Pending, containing: geometry.Rect) !void {
    const source = state.tree.boxes.items[pending.box_id];
    const style = source.style;
    const left = style.insets.left.resolve(containing.width);
    const right = style.insets.right.resolve(containing.width);
    const top = style.insets.top.resolve(containing.height);
    const bottom = style.insets.bottom.resolve(containing.height);
    const horizontal_non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
    const vertical_non_content = source.border.top + source.border.bottom + source.padding.top + source.padding.bottom;

    const forced_width: ?f32 = if (style.width == .auto and left != null and right != null)
        @max(containing.width - left.? - right.? - source.margin.left - source.margin.right - horizontal_non_content, 0)
    else
        null;
    const forced_height: ?f32 = if (style.height == .auto and top != null and bottom != null)
        @max(containing.height - top.? - bottom.? - source.margin.top - source.margin.bottom - vertical_non_content, 0)
    else
        null;
    const available_width = @max(containing.width - (left orelse 0) - (right orelse 0), 1);

    const fragment_start = state.fragments.items.len;
    var cursor_y: f32 = 0;
    const rect = try state.layoutBlockWithOptions(
        pending.box_id,
        .{ .width = available_width, .height = containing.height },
        &cursor_y,
        .{
            .shrink_to_fit = style.width == .auto and forced_width == null,
            .containing_block_height = containing.height,
            .forced_content_width = forced_width,
            .forced_content_height = forced_height,
        },
    );

    var margin_left = source.margin.left;
    var margin_right = source.margin.right;
    if (left != null and right != null and (style.margin_auto.left or style.margin_auto.right)) {
        const auto_count: f32 = if (style.margin_auto.left and style.margin_auto.right) 2 else 1;
        const share = @max(containing.width - left.? - right.? - rect.width - margin_left - margin_right, 0) / auto_count;
        if (style.margin_auto.left) margin_left = share;
        if (style.margin_auto.right) margin_right = share;
    }
    var margin_top = source.margin.top;
    var margin_bottom = source.margin.bottom;
    if (top != null and bottom != null and (style.margin_auto.top or style.margin_auto.bottom)) {
        const auto_count: f32 = if (style.margin_auto.top and style.margin_auto.bottom) 2 else 1;
        const share = @max(containing.height - top.? - bottom.? - rect.height - margin_top - margin_bottom, 0) / auto_count;
        if (style.margin_auto.top) margin_top = share;
        if (style.margin_auto.bottom) margin_bottom = share;
    }

    const target_x = if (left) |value|
        containing.x + value + margin_left
    else if (right) |value|
        containing.x + containing.width - value - margin_right - rect.width
    else
        pending.static_position.x + margin_left;
    const target_y = if (top) |value|
        containing.y + value + margin_top
    else if (bottom) |value|
        containing.y + containing.height - value - margin_bottom - rect.height
    else
        pending.static_position.y + margin_top;
    floats.shiftFragments(state.fragments.items[fragment_start..], target_x - rect.x, target_y - rect.y);

    const inherited_clip = if (style.position == .fixed) null else ancestorClip(state, pending.box_id);
    for (state.fragments.items[fragment_start..]) |*fragment| {
        fragment.fixed = style.position == .fixed;
        fragment.positioned_group = pending.box_id;
        fragment.z_index = style.z_index;
        if (inherited_clip) |clip| {
            fragment.clip_rect = if (fragment.clip_rect) |existing|
                existing.intersection(clip) orelse geometry.Rect{ .x = clip.x, .y = clip.y }
            else
                clip;
        }
    }
}

fn ancestorClip(state: anytype, box_id: box.BoxId) ?geometry.Rect {
    var result: ?geometry.Rect = null;
    var ancestor = state.tree.boxes.items[box_id].parent;
    while (ancestor) |ancestor_id| {
        const source = state.tree.boxes.items[ancestor_id];
        if (source.style.overflow.clips()) {
            if (fragmentContainingBlock(state, ancestor_id)) |clip| {
                result = if (result) |existing| existing.intersection(clip) orelse geometry.Rect{ .x = clip.x, .y = clip.y } else clip;
            }
        }
        ancestor = source.parent;
    }
    return result;
}

pub fn assignPaintMetadata(state: anytype) !void {
    const count = state.tree.boxes.items.len;
    const orders = try state.allocator.alloc(usize, count);
    defer state.allocator.free(orders);
    const opacity = try state.allocator.alloc(f32, count);
    defer state.allocator.free(opacity);
    const transforms = try state.allocator.alloc(geometry.AffineTransform, count);
    defer state.allocator.free(transforms);
    @memset(orders, 0);
    @memset(opacity, 1);
    @memset(transforms, geometry.AffineTransform.identity);
    var next_order: usize = 0;
    try assignBoxMetadata(state, state.tree.root, 1, geometry.AffineTransform.identity, orders, opacity, transforms, &next_order);
    for (state.fragments.items) |*fragment| {
        fragment.paint_order = orders[fragment.source_box];
        fragment.opacity = opacity[fragment.source_box];
        fragment.transform = transforms[fragment.source_box];
        if (fragment.clip_rect != null) {
            if (nearestClippingAncestor(state, fragment.source_box)) |ancestor_id| fragment.clip_transform = transforms[ancestor_id];
        }
    }
}

fn nearestClippingAncestor(state: anytype, box_id: box.BoxId) ?box.BoxId {
    var ancestor = state.tree.boxes.items[box_id].parent;
    while (ancestor) |ancestor_id| {
        const source = state.tree.boxes.items[ancestor_id];
        if (source.style.overflow.clips()) return ancestor_id;
        ancestor = source.parent;
    }
    return null;
}

const Child = struct {
    box_id: box.BoxId,
    source_index: usize,
};

const SortContext = struct {
    tree: *const box.BoxTree,
    flex_parent: bool,
};

fn assignBoxMetadata(
    state: anytype,
    box_id: box.BoxId,
    parent_opacity: f32,
    parent_transform: geometry.AffineTransform,
    orders: []usize,
    opacity: []f32,
    transforms: []geometry.AffineTransform,
    next_order: *usize,
) !void {
    const source = state.tree.boxes.items[box_id];
    orders[box_id] = next_order.*;
    next_order.* += 1;
    opacity[box_id] = parent_opacity * source.style.opacity;
    transforms[box_id] = parent_transform.multiply(resolveBoxTransform(state, box_id));

    var children = try std.ArrayList(Child).initCapacity(state.allocator, 0);
    defer children.deinit(state.allocator);
    var child = source.first_child;
    var source_index: usize = 0;
    while (child) |child_id| : (source_index += 1) {
        try children.append(state.allocator, .{ .box_id = child_id, .source_index = source_index });
        child = state.tree.boxes.items[child_id].next_sibling;
    }
    std.mem.sort(Child, children.items, SortContext{
        .tree = state.tree,
        .flex_parent = source.style.display == .flex or source.style.display == .inlineFlex or source.style.display == .grid or source.style.display == .inlineGrid,
    }, childLessThan);
    for (children.items) |entry| {
        try assignBoxMetadata(state, entry.box_id, opacity[box_id], transforms[box_id], orders, opacity, transforms, next_order);
    }
}

fn resolveBoxTransform(state: anytype, box_id: box.BoxId) geometry.AffineTransform {
    const source = state.tree.boxes.items[box_id];
    if (source.style.transform.len == 0 or source.kind == .inlineBox or source.kind == .anonymousInline) return .identity;
    const rect = referenceRectForBox(state, box_id) orelse return .identity;
    const origin = geometry.Point{
        .x = rect.x + (source.style.transform_origin.x.resolve(rect.width) orelse rect.width * 0.5),
        .y = rect.y + (source.style.transform_origin.y.resolve(rect.height) orelse rect.height * 0.5),
    };
    return box.resolveTransform(source.style.transform, rect.width, rect.height).around(origin);
}

fn referenceRectForBox(state: anytype, box_id: box.BoxId) ?geometry.Rect {
    var descendant_bounds: ?geometry.Rect = null;
    for (state.fragments.items) |fragment| {
        if (fragment.source_box == box_id and (fragment.kind == .box or fragment.kind == .replaced)) return fragment.rect;
        if (!isDescendantOf(state.tree, fragment.source_box, box_id)) continue;
        descendant_bounds = if (descendant_bounds) |existing| unionRect(existing, fragment.rect) else fragment.rect;
    }
    return descendant_bounds;
}

fn childLessThan(context: SortContext, a: Child, b: Child) bool {
    const a_style = context.tree.boxes.items[a.box_id].style;
    const b_style = context.tree.boxes.items[b.box_id].style;
    const a_phase = paintPhase(a_style);
    const b_phase = paintPhase(b_style);
    if (a_phase != b_phase) return a_phase < b_phase;
    if (a_phase == 0 or a_phase == 3) {
        const a_z = a_style.z_index orelse 0;
        const b_z = b_style.z_index orelse 0;
        if (a_z != b_z) return a_z < b_z;
    }
    if (a_phase == 1 and context.flex_parent and a_style.order != b_style.order) return a_style.order < b_style.order;
    return a.source_index < b.source_index;
}

fn paintPhase(style: box.Style) u8 {
    const positioned = style.position != .static or style.z_index != null or style.opacity < 0.9999 or style.transform.len > 0;
    const z_index = style.z_index orelse 0;
    if (positioned and z_index < 0) return 0;
    if (!positioned) return 1;
    if (z_index > 0) return 3;
    return 2;
}

fn containingBlock(state: anytype, box_id: box.BoxId, initial: geometry.Rect) geometry.Rect {
    var ancestor = state.tree.boxes.items[box_id].parent;
    while (ancestor) |ancestor_id| {
        const source = state.tree.boxes.items[ancestor_id];
        if (source.style.position != .static or source.style.transform.len > 0) return fragmentContainingBlock(state, ancestor_id) orelse initial;
        ancestor = source.parent;
    }
    return initial;
}

fn fragmentContainingBlock(state: anytype, ancestor_id: box.BoxId) ?geometry.Rect {
    const source = state.tree.boxes.items[ancestor_id];
    if (source.kind == .inlineBox or source.kind == .anonymousInline) return inlineContainingBlock(state, ancestor_id);
    for (state.fragments.items) |fragment| {
        if (fragment.source_box != ancestor_id or fragment.kind != .box) continue;
        return .{
            .x = fragment.rect.x + source.border.left,
            .y = fragment.rect.y + source.border.top,
            .width = @max(fragment.rect.width - source.border.left - source.border.right, 0),
            .height = @max(fragment.rect.height - source.border.top - source.border.bottom, 0),
        };
    }
    return null;
}

fn inlineContainingBlock(state: anytype, ancestor_id: box.BoxId) ?geometry.Rect {
    var result: ?geometry.Rect = null;
    for (state.fragments.items) |fragment| {
        if (!isDescendantOf(state.tree, fragment.source_box, ancestor_id)) continue;
        result = if (result) |existing| unionRect(existing, fragment.rect) else fragment.rect;
    }
    return result;
}

fn isDescendantOf(tree: *const box.BoxTree, candidate: box.BoxId, ancestor_id: box.BoxId) bool {
    var current: ?box.BoxId = candidate;
    while (current) |box_id| {
        if (box_id == ancestor_id) return true;
        current = tree.boxes.items[box_id].parent;
    }
    return false;
}

fn unionRect(a: geometry.Rect, b: geometry.Rect) geometry.Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(a.x + a.width, b.x + b.width);
    const bottom = @max(a.y + a.height, b.y + b.height);
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}
