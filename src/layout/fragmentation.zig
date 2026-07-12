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

/// Resolves `page: auto` to the nearest ancestor with a named page. The root's
/// `auto` used value is the empty page name defined by CSS Paged Media.
pub fn usedPageName(tree: anytype, box_id: usize) []const u8 {
    var current: ?usize = box_id;
    while (current) |current_id| {
        const source = tree.boxes.items[current_id];
        if (!std.ascii.eqlIgnoreCase(source.style.page_name, "auto")) return source.style.page_name;
        current = source.parent;
    }
    return "";
}

/// Returns the page name at a box's block-start edge after propagating through
/// its first in-flow child box to which the `page` property applies.
pub fn startPageName(tree: anytype, box_id: usize) []const u8 {
    const child_id = firstPageNameChild(tree, box_id) orelse return usedPageName(tree, box_id);
    return startPageName(tree, child_id);
}

/// Returns the page name at a box's block-end edge after the symmetrical last
/// child propagation required for named-page break arbitration.
pub fn endPageName(tree: anytype, box_id: usize) []const u8 {
    const child_id = lastPageNameChild(tree, box_id) orelse return usedPageName(tree, box_id);
    return endPageName(tree, child_id);
}

/// A case-sensitive page-name change at a class A opportunity is a forced page
/// break even when both ordinary break controls are `auto`.
pub fn pageNameChangesAtBoundary(tree: anytype, after_box_id: usize, before_box_id: usize) bool {
    return !std.mem.eql(u8, endPageName(tree, after_box_id), startPageName(tree, before_box_id));
}

/// Adds the forced generic page break implied by a named-page transition while
/// preserving an already-forced side-specific break at the same opportunity.
pub fn resolvePageNameBoundary(tree: anytype, after_box_id: usize, before_box_id: usize, boundary: anytype) @TypeOf(boundary) {
    if (boundary.isForced() or !pageNameChangesAtBoundary(tree, after_box_id, before_box_id)) return boundary;
    return .page;
}

fn firstPageNameChild(tree: anytype, box_id: usize) ?usize {
    var child = tree.boxes.items[box_id].first_child;
    while (child) |child_id| {
        const source = tree.boxes.items[child_id];
        if (source.style.position != .absolute and source.style.position != .fixed and pageNameApplies(source)) return child_id;
        child = source.next_sibling;
    }
    return null;
}

fn lastPageNameChild(tree: anytype, box_id: usize) ?usize {
    var child = tree.boxes.items[box_id].last_child;
    while (child) |child_id| {
        const source = tree.boxes.items[child_id];
        if (source.style.position != .absolute and source.style.position != .fixed and pageNameApplies(source)) return child_id;
        child = source.prev_sibling;
    }
    return null;
}

fn pageNameApplies(source: anytype) bool {
    return isBlockLevel(source.kind) or switch (source.style.display) {
        .flex, .inlineFlex, .grid, .inlineGrid => true,
        else => false,
    };
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

    /// Keeps an atomic item above page-end furniture such as a repeated table
    /// footer without changing the page sequence's actual boundary cadence.
    /// An item larger than the usable extent stays in place so layout can keep
    /// making progress and later fragmentation can split it if appropriate.
    pub fn atomicShiftBeforeEndInset(self: Context, position: f32, block_size: f32, end_inset: f32) f32 {
        const inset = std.math.clamp(end_inset, 0, self.extent);
        const usable_extent = self.extent - inset;
        if (block_size > usable_extent + epsilon or block_size <= 0) return 0;
        const page_offset = self.offset(position);
        if (page_offset + block_size <= usable_extent + epsilon) return 0;
        return self.extent - page_offset;
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
    try std.testing.expectEqual(@as(f32, 75), context.atomicShiftBeforeEndInset(25, 70, 10));
    try std.testing.expectEqual(@as(f32, 0), context.atomicShiftBeforeEndInset(10, 95, 10));
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

const TestTree = struct {
    boxes: struct { items: []const TestBox },
};

const TestPosition = enum { static, absolute, fixed };
const TestDisplay = enum { flex, inlineFlex, grid, inlineGrid, other };
const TestKind = enum { block, listItem, anonymousBlock, table, tableRow, tableCell, tableRowGroup, tableCaption, anonymousTableRow, other };
const TestStyle = struct {
    page_name: []const u8 = "auto",
    position: TestPosition = .static,
    display: TestDisplay = .other,
};
const TestBox = struct {
    kind: TestKind,
    style: TestStyle = .{},
    parent: ?usize = null,
    first_child: ?usize = null,
    last_child: ?usize = null,
    next_sibling: ?usize = null,
    prev_sibling: ?usize = null,
};

test "named page auto resolves through ancestors and keeps case-sensitive names" {
    var boxes = [_]TestBox{
        .{ .kind = .block, .style = .{ .page_name = "Report" }, .first_child = 1, .last_child = 1 },
        .{ .kind = .block, .parent = 0, .style = .{ .page_name = "auto" } },
        .{ .kind = .block, .style = .{ .page_name = "report" } },
    };
    const tree = TestTree{ .boxes = .{ .items = &boxes } };

    try std.testing.expectEqualStrings("Report", usedPageName(tree, 1));
    try std.testing.expectEqualStrings("Report", startPageName(tree, 0));
    try std.testing.expect(!std.mem.eql(u8, usedPageName(tree, 1), usedPageName(tree, 2)));
}

test "named page start and end values propagate through first and last children" {
    var boxes = [_]TestBox{
        .{ .kind = .block, .style = .{ .page_name = "Shell" }, .first_child = 1, .last_child = 2 },
        .{ .kind = .block, .parent = 0, .next_sibling = 2, .style = .{ .page_name = "Cover" } },
        .{ .kind = .block, .parent = 0, .prev_sibling = 1, .style = .{ .page_name = "Summary" } },
    };
    const tree = TestTree{ .boxes = .{ .items = &boxes } };

    try std.testing.expectEqualStrings("Cover", startPageName(tree, 0));
    try std.testing.expectEqualStrings("Summary", endPageName(tree, 0));
    try std.testing.expect(pageNameChangesAtBoundary(tree, 1, 2));
    try std.testing.expectEqual(TestBreak.page, resolvePageNameBoundary(tree, 1, 2, TestBreak.avoid));
    try std.testing.expectEqual(TestBreak.right, resolvePageNameBoundary(tree, 1, 2, TestBreak.right));
}
