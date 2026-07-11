//! Page geometry and fragmentation for laid-out document fragments.

const std = @import("std");
const geometry = @import("geometry.zig");
const layout = @import("layout.zig");

pub const PageFormat = enum {
    a4,
    letter,
};

pub const Orientation = enum {
    portrait,
    landscape,
};

pub const Margins = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

pub const PageSpec = struct {
    width_points: f32,
    height_points: f32,
    margins_points: Margins = .{},

    pub fn standard(format: PageFormat, orientation: Orientation, margins: Margins) PageSpec {
        const portrait = switch (format) {
            .a4 => geometry.Size{ .width = 595.2756, .height = 841.8898 },
            .letter => geometry.Size{ .width = 612, .height = 792 },
        };
        const size = if (orientation == .portrait)
            portrait
        else
            geometry.Size{ .width = portrait.height, .height = portrait.width };

        return .{
            .width_points = size.width,
            .height_points = size.height,
            .margins_points = margins,
        };
    }

    pub fn contentWidthCssPx(self: PageSpec) f32 {
        const points = self.width_points - self.margins_points.left - self.margins_points.right;
        return @max(points / geometry.css_px_to_pdf_points, 1);
    }

    pub fn contentHeightCssPx(self: PageSpec) f32 {
        const points = self.height_points - self.margins_points.top - self.margins_points.bottom;
        return @max(points / geometry.css_px_to_pdf_points, 1);
    }
};

pub const PagedFragment = struct {
    page_index: usize,
    fragment: layout.Fragment,
};

pub const PagedDocument = struct {
    fragments: std.ArrayList(PagedFragment),
    page_count: usize,
    page_spec: PageSpec,

    pub fn deinit(self: *PagedDocument, allocator: std.mem.Allocator) void {
        self.fragments.deinit(allocator);
    }
};

/// Splits box painting fragments at page boundaries and moves atomic text/image
/// fragments to the next page when they do not fit in the remaining space.
pub fn paginate(
    allocator: std.mem.Allocator,
    document: *const layout.LayoutDocument,
    page_spec: PageSpec,
) !PagedDocument {
    var fragments = try std.ArrayList(PagedFragment).initCapacity(allocator, document.fragments.items.len);
    errdefer fragments.deinit(allocator);

    const content_height = page_spec.contentHeightCssPx();
    var page_count: usize = 1;

    for (document.fragments.items) |fragment| {
        if (fragment.kind == .box and fragment.rect.height > 0) {
            try appendSplitBox(allocator, &fragments, fragment, content_height, &page_count);
        } else {
            var page_index: usize = @intFromFloat(@floor(@max(fragment.rect.y, 0) / content_height));
            var page_y = fragment.rect.y - @as(f32, @floatFromInt(page_index)) * content_height;

            if (page_y > 0 and page_y + fragment.rect.height > content_height and fragment.rect.height <= content_height) {
                page_index += 1;
                page_y = 0;
            }

            var page_fragment = fragment;
            page_fragment.rect.y = page_y;
            page_fragment.clip_rect = clipForPage(fragment.clip_rect, page_index, content_height);
            try fragments.append(allocator, .{ .page_index = page_index, .fragment = page_fragment });
            page_count = @max(page_count, page_index + 1);
        }
    }

    // A computed DOM snapshot may end a few pixels past the content area while
    // only continuing the root's white background. That continuation paints
    // exactly the default PDF page color and must not manufacture a trailing
    // blank page. Text, images, borders, and non-white fills still determine
    // the final page count normally.
    page_count = visiblePageCount(fragments.items);

    return .{
        .fragments = fragments,
        .page_count = page_count,
        .page_spec = page_spec,
    };
}

fn visiblePageCount(fragments: []const PagedFragment) usize {
    var count: usize = 1;
    for (fragments) |paged| {
        if (!fragmentMakesPageVisible(paged.fragment)) continue;
        count = @max(count, paged.page_index + 1);
    }
    return count;
}

fn fragmentMakesPageVisible(fragment: layout.Fragment) bool {
    if (fragment.kind != .box) return true;
    if (fragment.background) |color| {
        if (!isWhite(color)) return true;
    }
    const border = fragment.border;
    const paint = fragment.border_paint;
    return (border.top > 0 and paint.top_style != .none) or
        (border.right > 0 and paint.right_style != .none) or
        (border.bottom > 0 and paint.bottom_style != .none) or
        (border.left > 0 and paint.left_style != .none);
}

fn isWhite(color: geometry.Color) bool {
    const tolerance: f32 = 0.0001;
    return @abs(color.red - 1) <= tolerance and
        @abs(color.green - 1) <= tolerance and
        @abs(color.blue - 1) <= tolerance;
}

fn appendSplitBox(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(PagedFragment),
    fragment: layout.Fragment,
    content_height: f32,
    page_count: *usize,
) !void {
    var remaining = fragment.rect.height;
    var absolute_y = fragment.rect.y;

    while (remaining > 0) {
        const page_index: usize = @intFromFloat(@floor(@max(absolute_y, 0) / content_height));
        const page_y = absolute_y - @as(f32, @floatFromInt(page_index)) * content_height;
        const segment_height = @min(remaining, content_height - page_y);

        var segment = fragment;
        segment.rect.y = page_y;
        segment.rect.height = segment_height;
        segment.clip_rect = clipForPage(fragment.clip_rect, page_index, content_height);
        if (segment_height < fragment.rect.height) segment.border_radius = 0;
        try output.append(allocator, .{ .page_index = page_index, .fragment = segment });

        page_count.* = @max(page_count.*, page_index + 1);
        remaining -= segment_height;
        absolute_y += segment_height;
        if (segment_height <= 0) break;
    }
}

fn clipForPage(absolute_clip: ?geometry.Rect, page_index: usize, content_height: f32) ?geometry.Rect {
    const source = absolute_clip orelse return null;
    var local = source;
    local.y -= @as(f32, @floatFromInt(page_index)) * content_height;
    const top = @max(local.y, 0);
    const bottom = @min(local.bottom(), content_height);
    if (bottom <= top or local.width <= 0) return geometry.Rect{ .x = local.x, .y = top };
    local.y = top;
    local.height = bottom - top;
    return local;
}

test "paginate text and split tall box fragments" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 2);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 100, .height = 150 },
    });
    try fragments.append(allocator, .{
        .kind = .text,
        .source_box = 1,
        .rect = .{ .y = 95, .width = 20, .height = 10 },
        .text = "next",
    });
    const continuous = layout.LayoutDocument{
        .fragments = fragments,
        .content_width = 100,
        .content_height = 150,
    };
    const spec = PageSpec{
        .width_points = 75,
        .height_points = 75,
    };
    var paged = try paginate(allocator, &continuous, spec);
    defer paged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), paged.page_count);
    try std.testing.expectEqual(@as(usize, 1), paged.fragments.items[2].page_index);
    try std.testing.expectEqual(@as(f32, 0), paged.fragments.items[2].fragment.rect.y);
}

test "trailing white box continuation does not create a blank page" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 2);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 100, .height = 120 },
        .background = geometry.Color.white,
    });
    try fragments.append(allocator, .{
        .kind = .text,
        .source_box = 1,
        .rect = .{ .y = 10, .width = 20, .height = 10 },
        .text = "content",
    });
    const continuous = layout.LayoutDocument{
        .fragments = fragments,
        .content_width = 100,
        .content_height = 120,
    };
    const spec = PageSpec{ .width_points = 75, .height_points = 75 };
    var paged = try paginate(allocator, &continuous, spec);
    defer paged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), paged.page_count);
}

test "trailing colored box continuation keeps its page" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 100, .height = 120 },
        .background = .{ .red = 0.9, .green = 0.95, .blue = 1 },
    });
    const continuous = layout.LayoutDocument{
        .fragments = fragments,
        .content_width = 100,
        .content_height = 120,
    };
    const spec = PageSpec{ .width_points = 75, .height_points = 75 };
    var paged = try paginate(allocator, &continuous, spec);
    defer paged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), paged.page_count);
}

test "translate clipping rectangles into the destination page" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .kind = .text,
        .source_box = 0,
        .rect = .{ .y = 95, .width = 20, .height = 10 },
        .clip_rect = .{ .y = 90, .width = 100, .height = 20 },
        .text = "next",
    });
    const continuous = layout.LayoutDocument{ .fragments = fragments, .content_width = 100, .content_height = 110 };
    const spec = PageSpec{ .width_points = 75, .height_points = 75 };
    var paged = try paginate(allocator, &continuous, spec);
    defer paged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), paged.fragments.items[0].page_index);
    try std.testing.expectApproxEqAbs(@as(f32, 0), paged.fragments.items[0].fragment.clip_rect.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), paged.fragments.items[0].fragment.clip_rect.?.height, 0.01);
}
