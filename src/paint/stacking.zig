//! Stable stacking-context ordering for paged fragments.
//!
//! Layout assigns a tree-derived `paint_order` that keeps each positioned or
//! opacity context atomic while sorting negative, normal-flow, auto/zero, and
//! positive layers. Pagination replicas retain the same order key.

const std = @import("std");
const pagination = @import("../pagination.zig");

pub const supports_stacking_contexts = true;

const Indexed = struct {
    paged: pagination.PagedFragment,
    source_index: usize,
};

pub fn orderedFragments(allocator: std.mem.Allocator, source: []const pagination.PagedFragment) ![]pagination.PagedFragment {
    const indexed = try allocator.alloc(Indexed, source.len);
    defer allocator.free(indexed);
    for (source, 0..) |paged, index| indexed[index] = .{ .paged = paged, .source_index = index };
    std.mem.sort(Indexed, indexed, {}, lessThan);
    const result = try allocator.alloc(pagination.PagedFragment, source.len);
    for (indexed, 0..) |entry, index| result[index] = entry.paged;
    return result;
}

fn lessThan(_: void, a: Indexed, b: Indexed) bool {
    if (a.paged.page_index != b.paged.page_index) return a.paged.page_index < b.paged.page_index;
    if (a.paged.fragment.paint_order != b.paged.fragment.paint_order) return a.paged.fragment.paint_order < b.paged.fragment.paint_order;
    return a.source_index < b.source_index;
}
