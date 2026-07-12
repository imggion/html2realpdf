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

pub const PageSelector = struct {
    name: []const u8 = "",
    first: bool = false,
    left: bool = false,
    right: bool = false,
    blank: bool = false,

    fn matches(self: PageSelector, page_name: []const u8, page_index: usize, is_blank: bool) bool {
        if (self.name.len > 0 and !std.mem.eql(u8, self.name, page_name)) return false;
        if (self.first and page_index != 0) return false;
        if (self.left and page_index % 2 == 0) return false;
        if (self.right and page_index % 2 != 0) return false;
        if (self.blank and !is_blank) return false;
        return true;
    }

    fn specificity(self: PageSelector) [3]u8 {
        return .{
            @intFromBool(self.name.len > 0),
            @intFromBool(self.first) + @intFromBool(self.blank),
            @intFromBool(self.left) + @intFromBool(self.right),
        };
    }
};

pub const PageRule = struct {
    selector: PageSelector = .{},
    width_points: ?f32 = null,
    height_points: ?f32 = null,
    margin_top_points: ?f32 = null,
    margin_right_points: ?f32 = null,
    margin_bottom_points: ?f32 = null,
    margin_left_points: ?f32 = null,
    size_important: bool = false,
    margin_top_important: bool = false,
    margin_right_important: bool = false,
    margin_bottom_important: bool = false,
    margin_left_important: bool = false,
};

const Winner = struct {
    set: bool = false,
    important: bool = false,
    specificity: [3]u8 = .{ 0, 0, 0 },
    order: usize = 0,

    fn accepts(self: Winner, important: bool, specificity: [3]u8, order: usize) bool {
        if (!self.set) return true;
        if (self.important != important) return important;
        const comparison = std.mem.order(u8, &specificity, &self.specificity);
        return comparison == .gt or (comparison == .eq and order >= self.order);
    }
};

pub fn resolvePageSpec(base: PageSpec, rules: []const PageRule, page_name: []const u8, page_index: usize, is_blank: bool) PageSpec {
    var result = base;
    var size_winner = Winner{};
    var margin_winners = [_]Winner{.{}} ** 4;
    for (rules, 0..) |rule, order| {
        if (!rule.selector.matches(page_name, page_index, is_blank)) continue;
        const specificity = rule.selector.specificity();
        if (rule.width_points != null and rule.height_points != null and size_winner.accepts(rule.size_important, specificity, order)) {
            result.width_points = @max(rule.width_points.?, 1);
            result.height_points = @max(rule.height_points.?, 1);
            size_winner = .{ .set = true, .important = rule.size_important, .specificity = specificity, .order = order };
        }
        applyMarginWinner(&result.margins_points.top, &margin_winners[0], rule.margin_top_points, rule.margin_top_important, specificity, order);
        applyMarginWinner(&result.margins_points.right, &margin_winners[1], rule.margin_right_points, rule.margin_right_important, specificity, order);
        applyMarginWinner(&result.margins_points.bottom, &margin_winners[2], rule.margin_bottom_points, rule.margin_bottom_important, specificity, order);
        applyMarginWinner(&result.margins_points.left, &margin_winners[3], rule.margin_left_points, rule.margin_left_important, specificity, order);
    }
    if (result.margins_points.top + result.margins_points.bottom >= result.height_points or
        result.margins_points.left + result.margins_points.right >= result.width_points)
    {
        return base;
    }
    return result;
}

fn applyMarginWinner(target: *f32, winner: *Winner, candidate: ?f32, important: bool, specificity: [3]u8, order: usize) void {
    const value = candidate orelse return;
    if (!winner.accepts(important, specificity, order)) return;
    target.* = @max(value, 0);
    winner.* = .{ .set = true, .important = important, .specificity = specificity, .order = order };
}

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

    const content_height = page_spec.contentHeightCssPx();
    var page_count: usize = 1;

    for (document.fragments.items) |fragment| {
        if (fragment.fixed) {
            try fragments.append(allocator, .{ .page_index = 0, .fragment = fragment });
        } else if (fragment.kind == .box and fragment.rect.height > 0) {
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
            page_fragment.transform = shiftedTransform(fragment.transform, 0, page_y - fragment.rect.y);
            page_fragment.clip_transform = shiftedTransform(fragment.clip_transform, 0, page_y - fragment.rect.y);
            page_fragment.clip_rect = clipForPage(fragment.clip_rect, page_index, content_height);
            page_fragment.image_content_rect = rectForPage(fragment.image_content_rect, page_index, content_height);
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
            try fragments.append(allocator, .{ .page_index = page_index, .fragment = template });
        }
    }

    var page_specs = try std.ArrayList(PageSpec).initCapacity(allocator, page_count);
    errdefer page_specs.deinit(allocator);
    for (0..page_count) |page_index| {
        const page_name = if (page_index < document.page_names.items.len)
            document.page_names.items[page_index]
        else if (document.page_names.items.len > 0)
            document.page_names.items[document.page_names.items.len - 1]
        else
            "";
        try page_specs.append(allocator, resolvePageSpec(page_spec, page_rules, page_name, page_index, false));
    }

    return .{
        .fragments = fragments,
        .page_specs = page_specs,
        .page_count = page_count,
        .page_spec = page_spec,
    };
}

test "named and pseudo page rules cascade by importance specificity and order" {
    const base = PageSpec{ .width_points = 600, .height_points = 800, .margins_points = .{ .top = 10 } };
    const rules = [_]PageRule{
        .{ .selector = .{ .left = true }, .margin_top_points = 20 },
        .{ .selector = .{ .name = "Report" }, .width_points = 800, .height_points = 600, .margin_top_points = 30 },
        .{ .selector = .{ .name = "report" }, .margin_top_points = 90 },
        .{ .selector = .{ .name = "Report", .left = true }, .margin_top_points = 40 },
        .{ .selector = .{ .name = "Report" }, .margin_top_points = 50, .margin_top_important = true },
    };

    const report_left = resolvePageSpec(base, &rules, "Report", 1, false);
    try std.testing.expectEqual(@as(f32, 800), report_left.width_points);
    try std.testing.expectEqual(@as(f32, 600), report_left.height_points);
    try std.testing.expectEqual(@as(f32, 50), report_left.margins_points.top);
    const lower_case = resolvePageSpec(base, &rules, "report", 0, false);
    try std.testing.expectEqual(@as(f32, 90), lower_case.margins_points.top);
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
    const first_page_index: usize = @intFromFloat(@floor(@max(absolute_y, 0) / content_height));
    const first_page_y = absolute_y - @as(f32, @floatFromInt(first_page_index)) * content_height;
    const is_split = fragment.rect.height > content_height - first_page_y;
    var is_first = true;

    while (remaining > 0) {
        const page_index: usize = @intFromFloat(@floor(@max(absolute_y, 0) / content_height));
        const page_y = absolute_y - @as(f32, @floatFromInt(page_index)) * content_height;
        const segment_height = @min(remaining, content_height - page_y);

        var segment = fragment;
        segment.rect.y = page_y;
        segment.rect.height = segment_height;
        segment.transform = shiftedTransform(fragment.transform, 0, -@as(f32, @floatFromInt(page_index)) * content_height);
        segment.clip_transform = shiftedTransform(fragment.clip_transform, 0, -@as(f32, @floatFromInt(page_index)) * content_height);
        segment.clip_rect = clipForPage(fragment.clip_rect, page_index, content_height);
        segment.image_content_rect = rectForPage(fragment.image_content_rect, page_index, content_height);
        const is_last = segment_height >= remaining;
        if (is_split) {
            if (fragment.legacy_fragment_borders) {
                segment.border_radius = 0;
                segment.border_radii = .{};
            } else switch (fragment.box_decoration_break) {
                .slice => {
                    if (!is_first) segment.border.top = 0;
                    if (!is_last) segment.border.bottom = 0;
                    // The renderer currently stores one uniform radius rather than
                    // per-corner radii, so a sliced middle edge cannot retain only
                    // the two outer rounded corners.
                    segment.border_radius = 0;
                    segment.border_radii = .{};
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

fn shiftedTransform(transform: geometry.AffineTransform, shift_x: f32, shift_y: f32) geometry.AffineTransform {
    return geometry.AffineTransform.translation(shift_x, shift_y)
        .multiply(transform)
        .multiply(geometry.AffineTransform.translation(-shift_x, -shift_y));
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

fn rectForPage(absolute_rect: ?geometry.Rect, page_index: usize, content_height: f32) ?geometry.Rect {
    var rect = absolute_rect orelse return null;
    rect.y -= @as(f32, @floatFromInt(page_index)) * content_height;
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
