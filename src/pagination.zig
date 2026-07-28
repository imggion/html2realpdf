//! Page geometry and fragmentation for laid-out document fragments.

const std = @import("std");
const box = @import("box.zig");
const geometry = @import("geometry.zig");
const layout = @import("layout.zig");
const page_geometry = @import("layout/page_geometry.zig");

pub const PageFormat = page_geometry.PageFormat;
pub const Orientation = page_geometry.Orientation;
pub const Margins = page_geometry.Margins;
pub const PageSpec = page_geometry.PageSpec;
pub const PageSelector = page_geometry.PageSelector;
pub const PageRule = page_geometry.PageRule;
pub const resolvePageSpec = page_geometry.resolvePageSpec;

const epsilon: f32 = 0.0001;

const PageSequence = struct {
    document: *const layout.LayoutDocument,
    base: PageSpec,
    rules: []const PageRule,

    fn pageName(self: PageSequence, page_index: usize) []const u8 {
        if (page_index < self.document.page_names.items.len) return self.document.page_names.items[page_index];
        if (self.document.page_names.items.len > 0) return self.document.page_names.items[self.document.page_names.items.len - 1];
        return "";
    }

    fn spec(self: PageSequence, page_index: usize) PageSpec {
        const is_blank = page_index < self.document.blank_pages.items.len and self.document.blank_pages.items[page_index];
        return resolvePageSpec(self.base, self.rules, self.pageName(page_index), page_index, is_blank);
    }

    fn extent(self: PageSequence, page_index: usize) f32 {
        return self.spec(page_index).contentHeightCssPx();
    }

    fn start(self: PageSequence, page_index: usize) f32 {
        var result: f32 = 0;
        for (0..page_index) |index| result += self.extent(index);
        return result;
    }

    fn pageIndex(self: PageSequence, position: f32) usize {
        const target = @max(position, 0);
        var index: usize = 0;
        var page_start: f32 = 0;
        while (true) : (index += 1) {
            const next = page_start + self.extent(index);
            if (target < next - epsilon) return index;
            if (@abs(target - next) <= epsilon) return index + 1;
            page_start = next;
        }
    }
};

pub const PagedFragment = struct {
    page_index: usize,
    fragment: layout.Fragment,
};

pub const PagedDocument = struct {
    fragments: std.ArrayList(PagedFragment),
    page_specs: std.ArrayList(PageSpec) = .empty,
    page_count: usize,
    page_spec: PageSpec,

    pub fn deinit(self: *PagedDocument, allocator: std.mem.Allocator) void {
        self.fragments.deinit(allocator);
        self.page_specs.deinit(allocator);
    }
};

/// Splits box painting fragments at page boundaries and moves atomic text/image
/// fragments to the next page when they do not fit in the remaining space.
pub fn paginate(
    allocator: std.mem.Allocator,
    document: *const layout.LayoutDocument,
    page_spec: PageSpec,
) !PagedDocument {
    return paginateWithRules(allocator, document, page_spec, &.{});
}

pub fn paginateWithRules(
    allocator: std.mem.Allocator,
    document: *const layout.LayoutDocument,
    page_spec: PageSpec,
    page_rules: []const PageRule,
) !PagedDocument {
    var fragments = try std.ArrayList(PagedFragment).initCapacity(allocator, document.fragments.items.len);
    errdefer fragments.deinit(allocator);

    const sequence = PageSequence{ .document = document, .base = page_spec, .rules = page_rules };
    var page_count: usize = 1;

    for (document.fragments.items) |fragment| {
        if (fragment.fixed) {
            try fragments.append(allocator, .{ .page_index = 0, .fragment = fragment });
        } else if (fragment.kind == .box and fragment.rect.height > 0) {
            try appendSplitBox(allocator, &fragments, fragment, sequence, &page_count);
        } else {
            var page_index = sequence.pageIndex(fragment.rect.y);
            var page_start = sequence.start(page_index);
            var content_height = sequence.extent(page_index);
            var page_y = fragment.rect.y - page_start;

            if (page_y > 0 and page_y + fragment.rect.height > content_height and fragment.rect.height <= sequence.extent(page_index + 1)) {
                page_index += 1;
                page_start = sequence.start(page_index);
                content_height = sequence.extent(page_index);
                page_y = 0;
            }

            var page_fragment = fragment;
            page_fragment.rect.y = page_y;
            page_fragment.transform = shiftedTransform(fragment.transform, 0, page_y - fragment.rect.y);
            page_fragment.clip_transform = shiftedTransform(fragment.clip_transform, 0, page_y - fragment.rect.y);
            const page_clip = clipForPage(fragment.clip_rect, fragment.clip_radii, page_start, content_height);
            page_fragment.clip_rect = page_clip.rect;
            page_fragment.clip_radii = page_clip.radii;
            page_fragment.clip_paths = clipPathsForPage(fragment.clip_paths, page_start, content_height, page_y - fragment.rect.y);
            page_fragment.image_content_rect = rectForPage(fragment.image_content_rect, page_start);
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
    var fixed_templates = try std.ArrayList(layout.Fragment).initCapacity(allocator, 0);
    defer fixed_templates.deinit(allocator);
    for (fragments.items) |paged| {
        if (paged.fragment.fixed) try fixed_templates.append(allocator, paged.fragment);
    }
    for (fixed_templates.items) |template| {
        for (1..page_count) |page_index| {
            var repeated = template;
            resolveFragmentainerInlineExtent(&repeated, sequence.spec(page_index));
            try fragments.append(allocator, .{ .page_index = page_index, .fragment = repeated });
        }
    }

    var page_specs = try std.ArrayList(PageSpec).initCapacity(allocator, page_count);
    errdefer page_specs.deinit(allocator);
    for (0..page_count) |page_index| {
        try page_specs.append(allocator, sequence.spec(page_index));
    }

    return .{
        .fragments = fragments,
        .page_specs = page_specs,
        .page_count = page_count,
        .page_spec = page_spec,
    };
}

test "fixed fragments repeat at page-relative coordinates" {
    const allocator = std.testing.allocator;
    var source = try std.ArrayList(layout.Fragment).initCapacity(allocator, 2);
    defer source.deinit(allocator);
    try source.append(allocator, .{
        .kind = .text,
        .source_box = 0,
        .rect = .{ .y = 120, .width = 20, .height = 10 },
        .text = "page two",
    });
    try source.append(allocator, .{
        .kind = .text,
        .source_box = 1,
        .rect = .{ .x = 5, .y = 4, .width = 40, .height = 10 },
        .text = "header",
        .fixed = true,
    });
    const continuous = layout.LayoutDocument{ .fragments = source, .content_width = 100, .content_height = 130 };
    var paged = try paginate(allocator, &continuous, .{ .width_points = 75, .height_points = 75 });
    defer paged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), paged.page_count);
    var header_count: usize = 0;
    for (paged.fragments.items) |fragment| {
        if (!fragment.fragment.fixed) continue;
        header_count += 1;
        try std.testing.expectApproxEqAbs(@as(f32, 4), fragment.fragment.rect.y, 0.01);
    }
    try std.testing.expectEqual(@as(usize, 2), header_count);
}

test "auto-width fixed fragments follow each repeated page width" {
    const allocator = std.testing.allocator;
    var source = try std.ArrayList(layout.Fragment).initCapacity(allocator, 2);
    defer source.deinit(allocator);
    try source.append(allocator, .{
        .kind = .text,
        .source_box = 0,
        .rect = .{ .y = 120, .width = 20, .height = 10 },
        .text = "page two",
    });
    try source.append(allocator, .{
        .kind = .box,
        .source_box = 1,
        .rect = .{ .x = 10, .y = 4, .width = 70, .height = 10 },
        .fixed = true,
        .fragmentainer_inline_insets = .{ .left = 10, .right = 20 },
    });
    var names = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    defer names.deinit(allocator);
    try names.appendSlice(allocator, &.{ "Report", "Summary" });
    const continuous = layout.LayoutDocument{
        .fragments = source,
        .page_names = names,
        .content_width = 100,
        .content_height = 130,
    };
    var paged = try paginateWithRules(
        allocator,
        &continuous,
        .{ .width_points = 75, .height_points = 75 },
        &.{.{ .selector = .{ .name = "Summary" }, .width_points = 150, .height_points = 75 }},
    );
    defer paged.deinit(allocator);

    var widths: [2]f32 = @splat(0);
    for (paged.fragments.items) |fragment| {
        if (!fragment.fragment.fixed) continue;
        widths[fragment.page_index] = fragment.fragment.rect.width;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 70), widths[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 170), widths[1], 0.01);
}

test "auto-width box fragments resolve each page inline extent" {
    const allocator = std.testing.allocator;
    var source = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
    defer source.deinit(allocator);
    try source.append(allocator, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 70, .height = 150 },
        .background = .{ .red = 1, .green = 0, .blue = 0 },
        .fragmentainer_inline_insets = .{ .left = 10, .right = 20 },
    });
    var names = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    defer names.deinit(allocator);
    try names.appendSlice(allocator, &.{ "Report", "Summary" });
    const continuous = layout.LayoutDocument{
        .fragments = source,
        .page_names = names,
        .content_width = 100,
        .content_height = 150,
    };
    var paged = try paginateWithRules(
        allocator,
        &continuous,
        .{ .width_points = 75, .height_points = 75 },
        &.{.{ .selector = .{ .name = "Summary" }, .width_points = 150, .height_points = 75 }},
    );
    defer paged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), paged.page_count);
    try std.testing.expectApproxEqAbs(@as(f32, 10), paged.fragments.items[0].fragment.rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 70), paged.fragments.items[0].fragment.rect.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), paged.fragments.items[1].fragment.rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 170), paged.fragments.items[1].fragment.rect.width, 0.01);
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
    sequence: PageSequence,
    page_count: *usize,
) !void {
    var remaining = fragment.rect.height;
    var absolute_y = fragment.rect.y;
    const first_page_index = sequence.pageIndex(absolute_y);
    const first_page_start = sequence.start(first_page_index);
    const first_page_height = sequence.extent(first_page_index);
    const first_page_y = absolute_y - first_page_start;
    const is_split = fragment.rect.height > first_page_height - first_page_y;
    var is_first = true;

    while (remaining > 0) {
        const page_index = sequence.pageIndex(absolute_y);
        const page_start = sequence.start(page_index);
        const content_height = sequence.extent(page_index);
        const page_y = absolute_y - page_start;
        const segment_height = @min(remaining, content_height - page_y);

        var segment = fragment;
        segment.rect.y = page_y;
        segment.rect.height = segment_height;
        resolveFragmentainerInlineExtent(&segment, sequence.spec(page_index));
        segment.transform = shiftedTransform(fragment.transform, 0, -page_start);
        segment.clip_transform = shiftedTransform(fragment.clip_transform, 0, -page_start);
        const page_clip = clipForPage(fragment.clip_rect, fragment.clip_radii, page_start, content_height);
        segment.clip_rect = page_clip.rect;
        segment.clip_radii = page_clip.radii;
        segment.clip_paths = clipPathsForPage(fragment.clip_paths, page_start, content_height, -page_start);
        segment.image_content_rect = rectForPage(fragment.image_content_rect, page_start);
        const is_last = segment_height >= remaining;
        if (is_split) {
            if (fragment.legacy_fragment_borders) {
                segment.border_radius = 0;
                segment.border_radii = .{};
            } else switch (fragment.box_decoration_break) {
                .slice => {
                    if (!is_first) segment.border.top = 0;
                    if (!is_last) segment.border.bottom = 0;
                    segment.border_radius = 0;
                    segment.border_radii = slicedDecorationRadii(fragment, is_first, is_last);
                },
                .clone => {},
            }
        }
        try output.append(allocator, .{ .page_index = page_index, .fragment = segment });

        page_count.* = @max(page_count.*, page_index + 1);
        remaining -= segment_height;
        absolute_y += segment_height;
        is_first = false;
        if (segment_height <= 0) break;
    }
}

fn resolveFragmentainerInlineExtent(fragment: *layout.Fragment, spec: PageSpec) void {
    const insets = fragment.fragmentainer_inline_insets orelse return;
    fragment.rect.x = insets.left;
    fragment.rect.width = @max(spec.contentWidthCssPx() - insets.left - insets.right, 1);
}

fn shiftedTransform(transform: geometry.AffineTransform, shift_x: f32, shift_y: f32) geometry.AffineTransform {
    return geometry.AffineTransform.translation(shift_x, shift_y)
        .multiply(transform)
        .multiply(geometry.AffineTransform.translation(-shift_x, -shift_y));
}

const PageClip = struct {
    rect: ?geometry.Rect = null,
    radii: ?box.ResolvedBorderRadii = null,
};

fn clipForPage(
    absolute_clip: ?geometry.Rect,
    absolute_radii: ?box.ResolvedBorderRadii,
    page_start: f32,
    content_height: f32,
) PageClip {
    const source = absolute_clip orelse return .{};
    var local = source;
    local.y -= page_start;
    const top = @max(local.y, 0);
    const bottom = @min(local.bottom(), content_height);
    if (bottom <= top or local.width <= 0) return .{ .rect = .{ .x = local.x, .y = top } };
    var radii = absolute_radii;
    if (radii) |*resolved| {
        if (source.y < page_start - epsilon) {
            resolved.top_left = .{};
            resolved.top_right = .{};
        }
        if (source.bottom() > page_start + content_height + epsilon) {
            resolved.bottom_left = .{};
            resolved.bottom_right = .{};
        }
    }
    local.y = top;
    local.height = bottom - top;
    if (radii) |resolved| {
        const normalized = resolved.normalized(local.width, local.height);
        radii = if (normalized.hasRadius()) normalized else null;
    }
    return .{ .rect = local, .radii = radii };
}

fn clipPathsForPage(
    absolute_paths: layout.ClipPathStack,
    page_start: f32,
    content_height: f32,
    transform_shift: f32,
) layout.ClipPathStack {
    var result = absolute_paths;
    var write_index: usize = 0;
    for (absolute_paths.slice()) |path| {
        const page_clip = clipForPage(path.rect, path.radii, page_start, content_height);
        const rect = page_clip.rect orelse continue;
        result.items[write_index] = path;
        result.items[write_index].rect = rect;
        result.items[write_index].radii = page_clip.radii;
        result.items[write_index].transform = shiftedTransform(path.transform, 0, transform_shift);
        write_index += 1;
    }
    result.len = @intCast(write_index);
    return result;
}

fn slicedDecorationRadii(fragment: layout.Fragment, is_first: bool, is_last: bool) box.BorderRadii {
    var radii = fragment.border_radii;
    if (!radii.resolve(fragment.rect.width, fragment.rect.height).hasRadius() and fragment.border_radius > 0) {
        const corner = box.CornerRadius{
            .x = .{ .px = fragment.border_radius },
            .y = .{ .px = fragment.border_radius },
        };
        radii = .{
            .top_left = corner,
            .top_right = corner,
            .bottom_right = corner,
            .bottom_left = corner,
        };
    }
    if (!is_first) {
        radii.top_left = .{};
        radii.top_right = .{};
    }
    if (!is_last) {
        radii.bottom_left = .{};
        radii.bottom_right = .{};
    }
    return radii;
}

fn rectForPage(absolute_rect: ?geometry.Rect, page_start: f32) ?geometry.Rect {
    var rect = absolute_rect orelse return null;
    rect.y -= page_start;
    return rect;
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

test "translate transform coordinate systems into destination pages" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .kind = .text,
        .source_box = 0,
        .rect = .{ .y = 95, .width = 20, .height = 10 },
        .transform = geometry.AffineTransform.rotation(@as(f32, std.math.pi / 2.0)).around(.{ .y = 100 }),
        .text = "next",
    });
    const continuous = layout.LayoutDocument{ .fragments = fragments, .content_width = 100, .content_height = 110 };
    var paged = try paginate(allocator, &continuous, .{ .width_points = 75, .height_points = 75 });
    defer paged.deinit(allocator);

    const transformed_origin = paged.fragments.items[0].fragment.transform.applyPoint(.{ .y = 5 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), transformed_origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), transformed_origin.y, 0.001);
}

test "slice decoration paints borders only at the box ends" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 100, .height = 150 },
        .border = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 },
        .border_radius = 8,
        .box_decoration_break = .slice,
    });
    const continuous = layout.LayoutDocument{ .fragments = fragments, .content_width = 100, .content_height = 150 };
    const spec = PageSpec{ .width_points = 75, .height_points = 75 };
    var paged = try paginate(allocator, &continuous, spec);
    defer paged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), paged.fragments.items.len);
    try std.testing.expectEqual(@as(f32, 2), paged.fragments.items[0].fragment.border.top);
    try std.testing.expectEqual(@as(f32, 0), paged.fragments.items[0].fragment.border.bottom);
    try std.testing.expectEqual(@as(f32, 0), paged.fragments.items[1].fragment.border.top);
    try std.testing.expectEqual(@as(f32, 2), paged.fragments.items[1].fragment.border.bottom);
    try std.testing.expectEqual(@as(f32, 0), paged.fragments.items[0].fragment.border_radius);
    try std.testing.expectEqual(@as(f32, 0), paged.fragments.items[1].fragment.border_radius);
}

test "clone decoration repeats borders and radius on every fragment" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 100, .height = 150 },
        .border = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 },
        .border_radius = 8,
        .box_decoration_break = .clone,
    });
    const continuous = layout.LayoutDocument{ .fragments = fragments, .content_width = 100, .content_height = 150 };
    const spec = PageSpec{ .width_points = 75, .height_points = 75 };
    var paged = try paginate(allocator, &continuous, spec);
    defer paged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), paged.fragments.items.len);
    for (paged.fragments.items) |item| {
        try std.testing.expectEqual(@as(f32, 2), item.fragment.border.top);
        try std.testing.expectEqual(@as(f32, 2), item.fragment.border.bottom);
        try std.testing.expectEqual(@as(f32, 8), item.fragment.border_radius);
    }
}

test "slice and clone preserve elliptical corners across three fragments" {
    const allocator = std.testing.allocator;
    const top_left = box.CornerRadius{ .x = .{ .px = 18 }, .y = .{ .px = 9 } };
    const top_right = box.CornerRadius{ .x = .{ .px = 12 }, .y = .{ .px = 6 } };
    const bottom_right = box.CornerRadius{ .x = .{ .px = 16 }, .y = .{ .px = 8 } };
    const bottom_left = box.CornerRadius{ .x = .{ .px = 10 }, .y = .{ .px = 5 } };

    inline for (.{ box.BoxDecorationBreak.slice, box.BoxDecorationBreak.clone }) |mode| {
        var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
        defer fragments.deinit(allocator);
        try fragments.append(allocator, .{
            .kind = .box,
            .source_box = 0,
            .rect = .{ .width = 100, .height = 250 },
            .border = .{ .top = 3, .right = 1, .bottom = 5, .left = 2 },
            .border_paint = .{
                .top_color = .{ .red = 1, .green = 0, .blue = 0 },
                .right_color = .{ .red = 0, .green = 1, .blue = 0 },
                .bottom_color = .{ .red = 0, .green = 0, .blue = 1 },
                .left_color = .{ .red = 1, .green = 0, .blue = 1 },
            },
            .border_radii = .{
                .top_left = top_left,
                .top_right = top_right,
                .bottom_right = bottom_right,
                .bottom_left = bottom_left,
            },
            .box_decoration_break = mode,
        });
        const continuous = layout.LayoutDocument{
            .fragments = fragments,
            .content_width = 100,
            .content_height = 250,
        };
        var paged = try paginate(allocator, &continuous, .{ .width_points = 75, .height_points = 75 });
        defer paged.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 3), paged.fragments.items.len);
        for (paged.fragments.items, 0..) |item, index| {
            const resolved = item.fragment.border_radii.resolve(item.fragment.rect.width, item.fragment.rect.height);
            if (mode == .clone or index == 0) {
                try std.testing.expect(resolved.top_left.x > 0 and resolved.top_right.y > 0);
            } else {
                try std.testing.expectEqual(@as(f32, 0), resolved.top_left.x);
                try std.testing.expectEqual(@as(f32, 0), resolved.top_right.y);
            }
            if (mode == .clone or index == 2) {
                try std.testing.expect(resolved.bottom_left.x > 0 and resolved.bottom_right.y > 0);
            } else {
                try std.testing.expectEqual(@as(f32, 0), resolved.bottom_left.x);
                try std.testing.expectEqual(@as(f32, 0), resolved.bottom_right.y);
            }
        }
    }
}

test "page clipping keeps only radii on uncut overflow edges" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    var fragment = layout.Fragment{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 100, .height = 250 },
        .background = .{ .red = 0.2, .green = 0.4, .blue = 0.8 },
    };
    const radii = box.ResolvedBorderRadii{
        .top_left = .{ .x = 18, .y = 9 },
        .top_right = .{ .x = 12, .y = 6 },
        .bottom_right = .{ .x = 16, .y = 8 },
        .bottom_left = .{ .x = 10, .y = 5 },
    };
    fragment.appendClipPath(0, .{ .width = 100, .height = 250 }, radii);
    try fragments.append(allocator, fragment);
    const continuous = layout.LayoutDocument{
        .fragments = fragments,
        .content_width = 100,
        .content_height = 250,
    };
    var paged = try paginate(allocator, &continuous, .{ .width_points = 75, .height_points = 75 });
    defer paged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), paged.fragments.items.len);
    const first = paged.fragments.items[0].fragment.clip_paths.items[0].radii.?;
    const middle = paged.fragments.items[1].fragment.clip_paths.items[0].radii;
    const last = paged.fragments.items[2].fragment.clip_paths.items[0].radii.?;
    try std.testing.expect(first.top_left.x > 0 and first.bottom_left.x == 0);
    try std.testing.expect(middle == null);
    try std.testing.expect(last.top_left.x == 0 and last.bottom_left.x > 0);
}

test "document profile preserves repeated fragment borders" {
    const allocator = std.testing.allocator;
    var fragments = try std.ArrayList(layout.Fragment).initCapacity(allocator, 1);
    defer fragments.deinit(allocator);
    try fragments.append(allocator, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 100, .height = 150 },
        .border = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 },
        .border_radius = 8,
        .legacy_fragment_borders = true,
    });
    const continuous = layout.LayoutDocument{ .fragments = fragments, .content_width = 100, .content_height = 150 };
    const spec = PageSpec{ .width_points = 75, .height_points = 75 };
    var paged = try paginate(allocator, &continuous, spec);
    defer paged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), paged.fragments.items.len);
    for (paged.fragments.items) |item| {
        try std.testing.expectEqual(@as(f32, 2), item.fragment.border.top);
        try std.testing.expectEqual(@as(f32, 2), item.fragment.border.bottom);
        try std.testing.expectEqual(@as(f32, 0), item.fragment.border_radius);
    }
}
