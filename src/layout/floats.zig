//! Float exclusion geometry for a single block formatting context.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const types = @import("types.zig");

pub const Item = struct {
    rect: geometry.Rect,
    side: box.Float,
};

pub const Band = struct {
    x: f32,
    width: f32,
    next_bottom: ?f32,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    containing: geometry.Rect,
    items: std.ArrayList(Item),

    pub fn init(allocator: std.mem.Allocator, containing: geometry.Rect) !Context {
        return .{
            .allocator = allocator,
            .containing = containing,
            .items = try std.ArrayList(Item).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Context) void {
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *Context, item: Item) !void {
        try self.items.append(self.allocator, item);
    }

    pub fn bandAt(self: *const Context, y: f32) Band {
        var left = self.containing.x;
        var right = self.containing.x + self.containing.width;
        var next_bottom: ?f32 = null;
        for (self.items.items) |item| {
            const bottom = item.rect.y + item.rect.height;
            if (item.rect.y > y or bottom <= y) continue;
            if (item.side == .left) left = @max(left, item.rect.x + item.rect.width);
            if (item.side == .right) right = @min(right, item.rect.x);
            if (next_bottom == null or bottom < next_bottom.?) next_bottom = bottom;
        }
        return .{ .x = left, .width = @max(right - left, 0), .next_bottom = next_bottom };
    }

    pub fn placementY(self: *const Context, start_y: f32, required_width: f32, clear: box.Clear) f32 {
        var y = @max(start_y, self.clearanceY(clear));
        while (true) {
            const band = self.bandAt(y);
            if (band.width >= required_width or band.next_bottom == null) return y;
            y = band.next_bottom.?;
        }
    }

    pub fn clearanceY(self: *const Context, clear: box.Clear) f32 {
        var y = self.containing.y;
        for (self.items.items) |item| {
            const matches = switch (clear) {
                .none => false,
                .left => item.side == .left,
                .right => item.side == .right,
                .both => true,
            };
            if (matches) y = @max(y, item.rect.y + item.rect.height);
        }
        return y;
    }

    pub fn maximumBottom(self: *const Context) f32 {
        var bottom = self.containing.y;
        for (self.items.items) |item| bottom = @max(bottom, item.rect.y + item.rect.height);
        return bottom;
    }
};

pub fn marginRect(rect: geometry.Rect, margins: box.EdgeSizes) geometry.Rect {
    return .{
        .x = rect.x - margins.left,
        .y = rect.y - margins.top,
        .width = rect.width + margins.left + margins.right,
        .height = rect.height + margins.top + margins.bottom,
    };
}

pub fn shiftFragments(fragments: []types.Fragment, dx: f32, dy: f32) void {
    for (fragments) |*fragment| shiftFragment(fragment, dx, dy);
}

pub fn shiftFragment(fragment: *types.Fragment, dx: f32, dy: f32) void {
    fragment.rect.x += dx;
    fragment.rect.y += dy;
    if (fragment.clip_rect) |*clip| {
        clip.x += dx;
        clip.y += dy;
    }
    if (fragment.image_content_rect) |*content| {
        content.x += dx;
        content.y += dy;
    }
}

test "float bands narrow and clear matching sides" {
    const allocator = std.testing.allocator;
    var context = try Context.init(allocator, .{ .x = 10, .y = 20, .width = 300 });
    defer context.deinit();
    try context.add(.{ .rect = .{ .x = 10, .y = 20, .width = 80, .height = 100 }, .side = .left });
    try context.add(.{ .rect = .{ .x = 250, .y = 20, .width = 60, .height = 60 }, .side = .right });

    const first = context.bandAt(40);
    try std.testing.expectApproxEqAbs(@as(f32, 90), first.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 160), first.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), context.clearanceY(.left), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), context.clearanceY(.right), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), context.clearanceY(.both), 0.01);
}
