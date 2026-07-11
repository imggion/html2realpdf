//! Fragmentainer helpers shared by block, inline, table, flex, and grid layout.
//!
//! Full CSS Fragmentation is not implemented yet; this module centralizes page
//! boundary arithmetic so the later model does not grow inside a formatter.

pub fn nextPageStart(position: f32, page_height: f32) f32 {
    if (page_height <= 0) return position;
    const page_y = @mod(position, page_height);
    return if (page_y == 0) position + page_height else position + (page_height - page_y);
}

test "next page start advances from a boundary and a partial page" {
    const std = @import("std");
    try std.testing.expectEqual(@as(f32, 200), nextPageStart(100, 100));
    try std.testing.expectEqual(@as(f32, 200), nextPageStart(125, 100));
}
