//! Shared page-box geometry and CSS page-selector cascade.
//!
//! Layout consumes content-box extents from these rules while pagination and
//! PDF serialization consume the same resolved physical page boxes.

const std = @import("std");

const css_px_to_pdf_points: f32 = 0.75;
const Size = struct { width: f32, height: f32 };

pub const PageFormat = enum { a4, letter };
pub const Orientation = enum { portrait, landscape };

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
            .a4 => Size{ .width = 595.2756, .height = 841.8898 },
            .letter => Size{ .width = 612, .height = 792 },
        };
        const size = if (orientation == .portrait) portrait else Size{ .width = portrait.height, .height = portrait.width };
        return .{ .width_points = size.width, .height_points = size.height, .margins_points = margins };
    }

    pub fn contentWidthCssPx(self: PageSpec) f32 {
        return @max((self.width_points - self.margins_points.left - self.margins_points.right) / css_px_to_pdf_points, 1);
    }

    pub fn contentHeightCssPx(self: PageSpec) f32 {
        return @max((self.height_points - self.margins_points.top - self.margins_points.bottom) / css_px_to_pdf_points, 1);
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

pub const PageNameTransition = struct {
    page_index: usize,
    name: []const u8,
};

pub const Sequence = struct {
    base: PageSpec,
    rules: []const PageRule = &.{},
    initial_name: []const u8 = "",
    transitions: []const PageNameTransition = &.{},
    blank_pages: []const usize = &.{},

    pub fn pageName(self: Sequence, page_index: usize) []const u8 {
        var result = self.initial_name;
        for (self.transitions) |transition| {
            if (transition.page_index <= page_index) result = transition.name;
        }
        return result;
    }

    pub fn pageSpec(self: Sequence, page_index: usize) PageSpec {
        return resolvePageSpec(self.base, self.rules, self.pageName(page_index), page_index, self.isBlank(page_index));
    }

    pub fn isBlank(self: Sequence, page_index: usize) bool {
        return std.mem.indexOfScalar(usize, self.blank_pages, page_index) != null;
    }

    pub fn contentExtent(self: Sequence, page_index: usize) f32 {
        return self.pageSpec(page_index).contentHeightCssPx();
    }

    pub fn contentInlineExtent(self: Sequence, page_index: usize) f32 {
        return self.pageSpec(page_index).contentWidthCssPx();
    }
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
        result.margins_points.left + result.margins_points.right >= result.width_points) return base;
    return result;
}

fn applyMarginWinner(target: *f32, winner: *Winner, candidate: ?f32, important: bool, specificity: [3]u8, order: usize) void {
    const value = candidate orelse return;
    if (!winner.accepts(important, specificity, order)) return;
    target.* = @max(value, 0);
    winner.* = .{ .set = true, .important = important, .specificity = specificity, .order = order };
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
    try std.testing.expectEqual(@as(f32, 90), resolvePageSpec(base, &rules, "report", 0, false).margins_points.top);
}
