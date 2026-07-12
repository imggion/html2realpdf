//! Fragmentainer geometry and break arbitration shared by every formatter.
//!
//! Layout uses absolute flow coordinates. A `Context` maps those coordinates
//! to a generated page sequence and is the single owner of boundary, remaining
//! extent, atomic-placement, and forced-page-side decisions.

const std = @import("std");

const epsilon: f32 = 0.0001;

pub const PageProgression = enum {
    left_to_right,
    right_to_left,
};

pub const PageSide = enum {
    left,
    right,
};

/// The result of combining the break controls that meet at one class A break
/// opportunity. A forced value wins over avoidance; when two page-side values
/// are forced, `break-before` is later in flow and therefore wins.
pub fn resolveBoundary(after: anytype, before: @TypeOf(after)) @TypeOf(after) {
    if (before.isForced()) return before;
    if (after.isForced()) return after;
    if (after.isAvoid() or before.isAvoid()) return .avoid;
    return .auto;
}

pub const Context = struct {
    extent: f32,
    progression: PageProgression = .left_to_right,

    pub fn init(extent: f32, progression: PageProgression) ?Context {
        if (extent <= 0) return null;
        return .{ .extent = @max(extent, 1), .progression = progression };
    }

    pub fn pageIndex(self: Context, position: f32) usize {
        return @intFromFloat(@floor(@max(position, 0) / self.extent));
    }

    pub fn pageStart(self: Context, position: f32) f32 {
        return @as(f32, @floatFromInt(self.pageIndex(position))) * self.extent;
    }

    pub fn offset(self: Context, position: f32) f32 {
        const raw = @mod(@max(position, 0), self.extent);
        return if (@abs(raw) <= epsilon or @abs(raw - self.extent) <= epsilon) 0 else raw;
    }

    pub fn remaining(self: Context, position: f32) f32 {
        const page_offset = self.offset(position);
        return if (page_offset == 0) self.extent else self.extent - page_offset;
    }

    pub fn crossesBoundary(self: Context, position: f32, block_size: f32) bool {
        if (block_size <= 0) return false;
        const page_offset = self.offset(position);
        return page_offset > 0 and block_size > self.extent - page_offset + epsilon;
    }

    /// Returns the boundary at or after `position`. An existing natural page
    /// boundary already satisfies a generic forced page break.
    pub fn boundaryAtOrAfter(self: Context, position: f32) f32 {
        const page_offset = self.offset(position);
        return if (page_offset == 0) @max(position, 0) else position + (self.extent - page_offset);
    }

    pub fn sideForPageIndex(_: Context, page_index: usize) PageSide {
        // CSS page index 0 is conventionally a right (recto) page.
        return if (page_index % 2 == 0) .right else .left;
    }

    /// Resolves `page`, facing-page, recto, and verso forced breaks. Recto and
    /// verso follow the root writing direction through `progression`.
    pub fn forcedBreakStart(self: Context, position: f32, value: anytype) f32 {
        if (!value.isForced()) return position;
        var target = self.boundaryAtOrAfter(position);
        const desired_side: ?PageSide = switch (value) {
            .page => null,
            .left => .left,
            .right => .right,
            .recto => if (self.progression == .left_to_right) .right else .left,
            .verso => if (self.progression == .left_to_right) .left else .right,
            .auto, .avoid => unreachable,
        };
        if (desired_side) |side| {
            if (self.sideForPageIndex(self.pageIndex(target)) != side) target += self.extent;
        }
        return target;
    }

    /// Returns the shift needed to keep a monolithic item together. Oversized
    /// items stay in place so layout keeps making progress and pagination may
    /// fragment or slice them later.
    pub fn atomicShift(self: Context, position: f32, block_size: f32) f32 {
        if (block_size > self.extent + epsilon or !self.crossesBoundary(position, block_size)) return 0;
        // Keep this as the direct remaining-extent expression. Besides avoiding
        // cancellation, it preserves the document profile's historical f32
        // coordinates byte-for-byte.
        return self.extent - self.offset(position);
    }
};

pub fn nextPageStart(position: f32, page_height: f32) f32 {
    const context = Context.init(page_height, .left_to_right) orelse return position;
    const boundary = context.boundaryAtOrAfter(position);
    return if (context.offset(position) == 0) boundary + context.extent else boundary;
}

/// Propagates a first in-flow child's `break-before` through ordinary block
/// containers. Flex, Grid, and table formatting contexts arbitrate their own
/// ordered/parallel flows and therefore stop this generic propagation.
pub fn propagatedBefore(tree: anytype, box_id: usize) @TypeOf(tree.boxes.items[0].style.page_break_before) {
    const source = tree.boxes.items[box_id];
    const result = source.style.page_break_before;
    if (!allowsGenericPropagation(source)) return result;
    const child_id = firstPropagatingChild(tree, box_id) orelse return result;
    return combinePropagated(result, propagatedBefore(tree, child_id), true);
}

/// Propagates a last in-flow child's `break-after` to its ordinary block
/// container, mirroring `propagatedBefore` at the block-end edge.
pub fn propagatedAfter(tree: anytype, box_id: usize) @TypeOf(tree.boxes.items[0].style.page_break_after) {
    const source = tree.boxes.items[box_id];
    var result = source.style.page_break_after;
    if (!allowsGenericPropagation(source)) return result;
    const child_id = lastPropagatingChild(tree, box_id) orelse return result;
    result = combinePropagated(propagatedAfter(tree, child_id), result, true);
    return result;
}

/// A descendant forced break overrides `break-inside: avoid` on an ancestor.
pub fn subtreeHasForcedBreak(tree: anytype, box_id: usize) bool {
    var child = tree.boxes.items[box_id].first_child;
    while (child) |child_id| {
        const source = tree.boxes.items[child_id];
        child = source.next_sibling;
        if (source.style.position == .absolute or source.style.position == .fixed) continue;
        if (source.style.page_break_before.isForced() or source.style.page_break_after.isForced()) return true;
        if (subtreeHasForcedBreak(tree, child_id)) return true;
    }
    return false;
}

fn combinePropagated(outer: anytype, inner: @TypeOf(outer), inner_is_later: bool) @TypeOf(outer) {
    if (outer.isForced() and inner.isForced()) return if (inner_is_later) inner else outer;
    if (inner.isForced()) return inner;
    if (outer.isForced()) return outer;
    if (outer.isAvoid() or inner.isAvoid()) return .avoid;
    return .auto;
}

pub fn firstPropagatingChild(tree: anytype, box_id: usize) ?usize {
    const source = tree.boxes.items[box_id];
    if (!allowsGenericPropagation(source)) return null;
    return firstInFlowBlockChild(tree, source.first_child);
}

pub fn lastPropagatingChild(tree: anytype, box_id: usize) ?usize {
    const source = tree.boxes.items[box_id];
    if (!allowsGenericPropagation(source)) return null;
    return lastInFlowBlockChild(tree, source.first_child);
}

fn allowsGenericPropagation(source: anytype) bool {
    return switch (source.style.display) {
        .flex, .inlineFlex, .grid, .inlineGrid, .table, .tableRow, .tableRowGroup => false,
        else => switch (source.kind) {
            .block, .listItem, .anonymousBlock, .tableCell, .tableCaption => true,
            else => false,
        },
    };
}

fn firstInFlowBlockChild(tree: anytype, first_child: ?usize) ?usize {
    var child = first_child;
    while (child) |child_id| {
        const source = tree.boxes.items[child_id];
        if (source.style.position != .absolute and source.style.position != .fixed) {
            return if (isBlockLevel(source.kind)) child_id else null;
        }
        child = source.next_sibling;
    }
    return null;
}

fn lastInFlowBlockChild(tree: anytype, first_child: ?usize) ?usize {
    var child = first_child;
    var last: ?usize = null;
    while (child) |child_id| {
        const source = tree.boxes.items[child_id];
        if (source.style.position != .absolute and source.style.position != .fixed) last = child_id;
        child = source.next_sibling;
    }
    const last_id = last orelse return null;
    return if (isBlockLevel(tree.boxes.items[last_id].kind)) last_id else null;
}

fn isBlockLevel(kind: anytype) bool {
    return switch (kind) {
        .block, .listItem, .anonymousBlock, .table, .tableRow, .tableCell, .tableRowGroup, .tableCaption, .anonymousTableRow => true,
        else => false,
    };
}

const TestBreak = enum {
    auto,
    avoid,
    page,
    left,
    right,
    recto,
    verso,

    fn isForced(self: @This()) bool {
        return switch (self) {
            .page, .left, .right, .recto, .verso => true,
            .auto, .avoid => false,
        };
    }

    fn isAvoid(self: @This()) bool {
        return self == .avoid;
    }
};

test "fragmentainer geometry reports remaining extent and atomic placement" {
    const context = Context.init(100, .left_to_right).?;
    try std.testing.expectEqual(@as(usize, 1), context.pageIndex(125));
    try std.testing.expectEqual(@as(f32, 25), context.offset(125));
    try std.testing.expectEqual(@as(f32, 75), context.remaining(125));
    try std.testing.expectEqual(@as(f32, 75), context.atomicShift(125, 80));
    try std.testing.expectEqual(@as(f32, 0), context.atomicShift(125, 101));
}

test "forced page sides honor page parity and progression" {
    const ltr = Context.init(100, .left_to_right).?;
    try std.testing.expectEqual(@as(f32, 100), ltr.forcedBreakStart(25, TestBreak.left));
    try std.testing.expectEqual(@as(f32, 200), ltr.forcedBreakStart(25, TestBreak.right));
    try std.testing.expectEqual(@as(f32, 200), ltr.forcedBreakStart(25, TestBreak.recto));
    try std.testing.expectEqual(@as(f32, 100), ltr.forcedBreakStart(25, TestBreak.verso));

    const rtl = Context.init(100, .right_to_left).?;
    try std.testing.expectEqual(@as(f32, 100), rtl.forcedBreakStart(25, TestBreak.recto));
    try std.testing.expectEqual(@as(f32, 200), rtl.forcedBreakStart(25, TestBreak.verso));
}

test "break boundary arbitration makes forced values override avoid" {
    try std.testing.expectEqual(TestBreak.avoid, resolveBoundary(TestBreak.avoid, .auto));
    try std.testing.expectEqual(TestBreak.page, resolveBoundary(TestBreak.avoid, .page));
    try std.testing.expectEqual(TestBreak.left, resolveBoundary(TestBreak.right, .left));
}

test "next page start advances from a boundary and a partial page" {
    try std.testing.expectEqual(@as(f32, 200), nextPageStart(100, 100));
    try std.testing.expectEqual(@as(f32, 200), nextPageStart(125, 100));
}
