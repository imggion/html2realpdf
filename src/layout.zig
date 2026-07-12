//! Stable layout facade and render-scoped formatting-context coordinator.
//!
//! Block, inline, table, intrinsic measurement, and fragmentation primitives
//! live under src/layout/. The public flat fragment API remains unchanged.

const std = @import("std");
const box = @import("box.zig");
const dom = @import("dom.zig");
const font = @import("font.zig");
const geometry = @import("geometry.zig");

pub const types = @import("layout/types.zig");
pub const intrinsic = @import("layout/intrinsic.zig");
pub const block = @import("layout/block.zig");
pub const inline_context = @import("layout/inline.zig");
pub const table = @import("layout/table.zig");
pub const flex = @import("layout/flex.zig");
pub const grid = @import("layout/grid.zig");
pub const positioned = @import("layout/positioned.zig");
pub const floats = @import("layout/floats.zig");
pub const fragmentation = @import("layout/fragmentation.zig");

pub const FragmentId = types.FragmentId;
pub const FragmentKind = types.FragmentKind;
pub const BorderPaint = types.BorderPaint;
pub const Fragment = types.Fragment;
pub const LayoutDocument = types.LayoutDocument;
pub const Options = types.Options;

pub const ListMarkerContent = union(enum) {
    text: []const u8,
    circle,
    square,
};

pub const ListMarker = struct {
    content: ListMarkerContent,
    position: box.ListStylePosition,
};

const InlineCursor = inline_context.Cursor(State);

pub fn layout(
    allocator: std.mem.Allocator,
    tree: *const box.BoxTree,
    document: *const dom.Document,
    options: Options,
) !LayoutDocument {
    const margin_cache = try allocator.alloc(?block.MarginInfo, tree.boxes.items.len);
    defer allocator.free(margin_cache);
    @memset(margin_cache, null);
    var pending_positioned = try std.ArrayList(positioned.Pending).initCapacity(allocator, 0);
    defer pending_positioned.deinit(allocator);
    var state = State{
        .allocator = allocator,
        .tree = tree,
        .document = document,
        .fragments = try std.ArrayList(Fragment).initCapacity(allocator, tree.boxes.items.len),
        .page_height = options.page_height,
        .font_registry = options.font_registry,
        .shaping_mode = options.shaping_mode,
        .atomic_inline_baselines = options.atomic_inline_baselines,
        .web_sizing = options.web_sizing,
        .margin_cache = margin_cache,
        .pending_positioned = &pending_positioned,
    };
    errdefer state.fragments.deinit(allocator);

    var cursor_y: f32 = 0;
    const containing = geometry.Rect{
        .width = @max(options.content_width, 1),
        .height = 0,
    };
    _ = try state.layoutBlockWithOptions(tree.root, containing, &cursor_y, .{
        .containing_block_height = if (options.web_sizing) options.page_height else containing.height,
    });
    if (options.web_sizing) try positioned.layoutPending(&state, .{
        .width = containing.width,
        .height = options.page_height orelse @max(cursor_y, 1),
    });
    if (options.web_sizing) try positioned.assignPaintMetadata(&state);

    return .{
        .fragments = state.fragments,
        .content_width = containing.width,
        .content_height = cursor_y,
    };
}

const State = struct {
    allocator: std.mem.Allocator,
    tree: *const box.BoxTree,
    document: *const dom.Document,
    fragments: std.ArrayList(Fragment),
    page_height: ?f32,
    font_registry: ?*const font.Registry,
    shaping_mode: font.ShapingMode,
    atomic_inline_baselines: bool,
    web_sizing: bool,
    margin_cache: []?block.MarginInfo,
    pending_positioned: *std.ArrayList(positioned.Pending),
    next_line_id: usize = 0,

    const BlockLayoutOptions = struct {
        fill_available_width: bool = false,
    };

    pub fn layoutBlock(
        self: *State,
        box_id: box.BoxId,
        containing: geometry.Rect,
        cursor_y: *f32,
    ) std.mem.Allocator.Error!geometry.Rect {
        const options = block.Options{
            .containing_block_height = if (self.web_sizing) null else containing.height,
        };
        const fragment_start = self.fragments.items.len;
        const rect = try block.layoutWithOptions(self, box_id, containing, cursor_y, options);
        return self.finishBlockLayout(box_id, containing, cursor_y, fragment_start, rect, options);
    }

    pub fn layoutBlockWithOptions(
        self: *State,
        box_id: box.BoxId,
        containing: geometry.Rect,
        cursor_y: *f32,
        options: block.Options,
    ) std.mem.Allocator.Error!geometry.Rect {
        const fragment_start = self.fragments.items.len;
        const rect = try block.layoutWithOptions(self, box_id, containing, cursor_y, options);
        return self.finishBlockLayout(box_id, containing, cursor_y, fragment_start, rect, options);
    }

    fn finishBlockLayout(
        self: *State,
        box_id: box.BoxId,
        containing: geometry.Rect,
        cursor_y: *f32,
        fragment_start: usize,
        raw_rect: geometry.Rect,
        options: block.Options,
    ) geometry.Rect {
        const source = self.tree.boxes.items[box_id];
        const style = source.style;
        var rect = raw_rect;
        if (style.overflow.clips() and fragment_start < self.fragments.items.len) {
            const vertical_edges = source.border.top + source.border.bottom + source.padding.top + source.padding.bottom;
            const containing_height: ?f32 = if (self.web_sizing) options.containing_block_height else containing.height;
            if (intrinsic.resolveContentDimensionOptional(style.height, containing_height, vertical_edges, style.box_sizing)) |requested_content_height| {
                const requested_outer_height = requested_content_height + vertical_edges;
                if (requested_outer_height < rect.height) {
                    const reduction = rect.height - requested_outer_height;
                    rect.height = requested_outer_height;
                    self.fragments.items[fragment_start].rect.height = requested_outer_height;
                    cursor_y.* -= reduction;
                }
            }

            const clip = geometry.Rect{
                .x = rect.x + source.border.left,
                .y = rect.y + source.border.top,
                .width = @max(rect.width - source.border.left - source.border.right, 0),
                .height = @max(rect.height - source.border.top - source.border.bottom, 0),
            };
            var clip_radii = style.border_radii.resolve(rect.width, rect.height);
            if (!clip_radii.hasRadius() and style.border_radius > 0) clip_radii = box.ResolvedBorderRadii.uniform(style.border_radius);
            clip_radii = clip_radii.inset(source.border);
            for (self.fragments.items[fragment_start + 1 ..]) |*fragment| {
                if (fragment.clip_rect) |existing| {
                    fragment.clip_rect = existing.intersection(clip) orelse geometry.Rect{ .x = clip.x, .y = clip.y };
                    fragment.clip_radii = null;
                } else {
                    fragment.clip_rect = clip;
                    fragment.clip_radii = if (clip_radii.hasRadius()) clip_radii else null;
                }
            }
        }
        if (self.web_sizing and (style.position == .relative or style.position == .sticky)) {
            self.shiftRelativeFragments(box_id, fragment_start, containing.width, options.containing_block_height orelse containing.height);
        }
        return rect;
    }

    pub fn deferPositioned(self: *State, box_id: box.BoxId, static_position: geometry.Point) !void {
        try self.pending_positioned.append(self.allocator, .{ .box_id = box_id, .static_position = static_position });
    }

    pub fn shiftRelativeFragments(self: *State, box_id: box.BoxId, fragment_start: usize, containing_width: f32, containing_height: f32) void {
        const style = self.tree.boxes.items[box_id].style;
        const left = style.insets.left.resolve(containing_width);
        const right = style.insets.right.resolve(containing_width);
        const top = style.insets.top.resolve(containing_height);
        const bottom = style.insets.bottom.resolve(containing_height);
        const shift_x: f32 = if (style.direction == .rtl and right != null)
            -right.?
        else if (left) |value|
            value
        else if (right) |value|
            -value
        else
            0;
        const shift_y: f32 = if (top) |value| value else if (bottom) |value| -value else 0;
        floats.shiftFragments(self.fragments.items[fragment_start..], shift_x, shift_y);
        for (self.fragments.items[fragment_start..]) |*fragment| {
            fragment.positioned_group = box_id;
            fragment.z_index = style.z_index;
        }
    }

    pub fn fragmentainer(self: *const State) ?fragmentation.Context {
        const page_height = self.page_height orelse return null;
        const progression: fragmentation.PageProgression = if (self.rootFlowDirection() == .rtl)
            .right_to_left
        else
            .left_to_right;
        return fragmentation.Context.init(page_height, progression);
    }

    fn rootFlowDirection(self: *const State) box.Direction {
        var current: ?box.BoxId = self.tree.root;
        while (current) |box_id| {
            const source = self.tree.boxes.items[box_id];
            if (source.node != null) return source.style.direction;
            current = source.first_child;
        }
        return self.tree.boxes.items[self.tree.root].style.direction;
    }

    pub fn applyForcedBreak(self: *const State, cursor_y: *f32, value: box.PageBreak) void {
        const context = self.fragmentainer() orelse return;
        cursor_y.* = context.forcedBreakStart(cursor_y.*, value);
    }

    pub fn atomicFragmentainerShift(self: *const State, position: f32, block_size: f32) f32 {
        const context = self.fragmentainer() orelse return 0;
        return context.atomicShift(position, block_size);
    }

    pub fn enforceLineConstraints(
        self: *State,
        fragment_start: usize,
        outer_y: *f32,
        outer_height: *f32,
        orphans: u32,
        widows: u32,
    ) !void {
        if (!self.web_sizing) return self.enforceLegacyLineConstraints(fragment_start, outer_y, outer_height, orphans, widows);
        const context = self.fragmentainer() orelse return;
        const page_height = context.extent;
        const LineInfo = struct { id: usize, y: f32 };
        var lines = try std.ArrayList(LineInfo).initCapacity(self.allocator, 0);
        defer lines.deinit(self.allocator);

        var previous_line: ?usize = null;
        for (self.fragments.items[fragment_start..]) |fragment| {
            const line_id = fragment.line_id orelse continue;
            if (previous_line == line_id) continue;
            try lines.append(self.allocator, .{ .id = line_id, .y = fragment.rect.y });
            previous_line = line_id;
        }
        if (lines.items.len < 2) return;

        const first_page = context.pageIndex(lines.items[0].y);
        const last_page = context.pageIndex(lines.items[lines.items.len - 1].y);
        if (first_page == last_page) return;

        var first_page_lines: usize = 0;
        var last_page_lines: usize = 0;
        for (lines.items) |line| {
            const page = context.pageIndex(line.y);
            if (page == first_page) first_page_lines += 1;
            if (page == last_page) last_page_lines += 1;
        }

        if (first_page_lines < orphans) {
            const shift = context.atomicShift(outer_y.*, @min(outer_height.*, page_height));
            if (shift > 0) {
                floats.shiftFragments(self.fragments.items[fragment_start..], 0, shift);
                outer_y.* += shift;
            }
            return;
        }

        if (last_page_lines >= widows) return;
        const required = @as(usize, @intCast(widows)) - last_page_lines;
        if (lines.items.len <= last_page_lines + required) return;
        const split_index = lines.items.len - last_page_lines - required;
        if (split_index < orphans) return;

        const split_y = lines.items[split_index].y;
        const last_page_start = context.pageStart(lines.items[lines.items.len - 1].y);
        const shift = last_page_start - split_y;
        if (shift <= 0) return;

        for (self.fragments.items[fragment_start..]) |*fragment| {
            if (fragment.rect.y >= split_y) floats.shiftFragment(fragment, 0, shift);
        }
        outer_height.* += shift;
    }

    fn enforceLegacyLineConstraints(
        self: *State,
        fragment_start: usize,
        outer_y: *f32,
        outer_height: *f32,
        orphans: u32,
        widows: u32,
    ) !void {
        const page_height = self.page_height orelse return;
        const LineInfo = struct { id: usize, y: f32 };
        var lines = try std.ArrayList(LineInfo).initCapacity(self.allocator, 0);
        defer lines.deinit(self.allocator);

        var previous_line: ?usize = null;
        for (self.fragments.items[fragment_start..]) |fragment| {
            const line_id = fragment.line_id orelse continue;
            if (previous_line == line_id) continue;
            try lines.append(self.allocator, .{ .id = line_id, .y = fragment.rect.y });
            previous_line = line_id;
        }
        if (lines.items.len < 2) return;

        const first_page: usize = @intFromFloat(@floor(lines.items[0].y / page_height));
        const last_page: usize = @intFromFloat(@floor(lines.items[lines.items.len - 1].y / page_height));
        if (first_page == last_page) return;

        var first_page_lines: usize = 0;
        var last_page_lines: usize = 0;
        for (lines.items) |line| {
            const page: usize = @intFromFloat(@floor(line.y / page_height));
            if (page == first_page) first_page_lines += 1;
            if (page == last_page) last_page_lines += 1;
        }

        if (first_page_lines < orphans) {
            const page_y = @mod(outer_y.*, page_height);
            if (page_y > 0) {
                const shift = page_height - page_y;
                for (self.fragments.items[fragment_start..]) |*fragment| fragment.rect.y += shift;
                outer_y.* += shift;
            }
            return;
        }

        if (last_page_lines >= widows) return;
        const required = @as(usize, @intCast(widows)) - last_page_lines;
        if (lines.items.len <= last_page_lines + required) return;
        const split_index = lines.items.len - last_page_lines - required;
        if (split_index < orphans) return;

        const split_y = lines.items[split_index].y;
        const last_page_start = @as(f32, @floatFromInt(last_page)) * page_height;
        const shift = last_page_start - split_y;
        if (shift <= 0) return;

        for (self.fragments.items[fragment_start..]) |*fragment| {
            if (fragment.rect.y >= split_y) fragment.rect.y += shift;
        }
        outer_height.* += shift;
    }

    pub fn hasBlockChildren(self: *const State, box_id: box.BoxId) bool {
        var child = self.tree.boxes.items[box_id].first_child;
        while (child) |child_id| {
            const child_box = self.tree.boxes.items[child_id];
            if (child_box.style.position == .absolute or child_box.style.position == .fixed) {
                child = child_box.next_sibling;
                continue;
            }
            if (block.isBlockLevel(child_box.kind) or (self.web_sizing and child_box.style.float_direction != .none)) return true;
            child = child_box.next_sibling;
        }
        return false;
    }

    pub fn measureIntrinsicInline(self: *State, box_id: box.BoxId) std.mem.Allocator.Error!intrinsic.InlineSizes {
        return intrinsic.measureBoxInline(self.allocator, self.tree, box_id, self.font_registry, self.shaping_mode);
    }

    pub fn marginInfo(self: *State, box_id: box.BoxId) block.MarginInfo {
        return block.marginInfo(self.tree, box_id, self.margin_cache);
    }

    pub fn layoutTable(
        self: *State,
        table_id: box.BoxId,
        x: f32,
        y: f32,
        width: f32,
    ) !f32 {
        return table.layout(self, table_id, x, y, width);
    }

    pub fn layoutFlex(
        self: *State,
        container_id: box.BoxId,
        content: geometry.Rect,
        specified_content_height: ?f32,
    ) !f32 {
        return flex.layout(self, container_id, content, specified_content_height);
    }

    pub fn layoutGrid(
        self: *State,
        container_id: box.BoxId,
        content: geometry.Rect,
        specified_content_height: ?f32,
    ) !f32 {
        return grid.layout(self, container_id, content, specified_content_height);
    }

    pub fn linkForBox(self: *const State, box_id: box.BoxId) ?[]const u8 {
        const node_id = self.tree.boxes.items[box_id].node orelse return null;
        const node = self.document.nodes.items[node_id];
        const element = switch (node.kind) {
            .element => |value| value,
            else => return null,
        };
        if (element.tag != .a) return null;

        return self.attributeForBox(box_id, "href");
    }

    pub fn attributeForBox(self: *const State, box_id: box.BoxId, name: []const u8) ?[]const u8 {
        const node_id = self.tree.boxes.items[box_id].node orelse return null;
        const node = self.document.nodes.items[node_id];
        const element = switch (node.kind) {
            .element => |value| value,
            else => return null,
        };
        for (element.attributes) |attribute| {
            if (std.ascii.eqlIgnoreCase(attribute.name, name)) return attribute.value;
        }
        return null;
    }

    pub fn listMarkerForBox(self: *const State, box_id: box.BoxId) !?ListMarker {
        const source = self.tree.boxes.items[box_id];
        if (source.kind != .listItem) return null;
        const content: ListMarkerContent = switch (source.style.list_style_type) {
            .none => return null,
            .disc => .{ .text = "•" },
            .circle => .circle,
            .square => .square,
            else => .{ .text = try formatListCounter(self.allocator, try self.listItemValue(box_id), source.style.list_style_type) },
        };
        return .{ .content = content, .position = source.style.list_style_position };
    }

    fn listItemValue(self: *const State, box_id: box.BoxId) !i64 {
        const source = self.tree.boxes.items[box_id];
        const parent_id = source.parent orelse return 1;
        const parent = self.tree.boxes.items[parent_id];
        const reversed = self.hasAttributeForBox(parent_id, "reversed");
        const step: i64 = if (reversed) -1 else 1;
        var value: i64 = if (self.attributeForBox(parent_id, "start")) |start|
            std.fmt.parseInt(i64, start, 10) catch 1
        else if (reversed)
            @intCast(countListItems(self.tree, parent_id))
        else
            1;

        var child = parent.first_child;
        while (child) |child_id| {
            const child_box = self.tree.boxes.items[child_id];
            if (child_box.kind == .listItem) {
                if (self.attributeForBox(child_id, "value")) |explicit| {
                    value = std.fmt.parseInt(i64, explicit, 10) catch value;
                }
                if (child_id == box_id) return value;
                value += step;
            }
            child = child_box.next_sibling;
        }
        return 1;
    }

    fn hasAttributeForBox(self: *const State, box_id: box.BoxId, name: []const u8) bool {
        const node_id = self.tree.boxes.items[box_id].node orelse return false;
        const element = switch (self.document.nodes.items[node_id].kind) {
            .element => |value| value,
            else => return false,
        };
        for (element.attributes) |attribute| {
            if (std.ascii.eqlIgnoreCase(attribute.name, name)) return true;
        }
        return false;
    }

    pub fn layoutInlineChildren(
        self: *State,
        parent_id: box.BoxId,
        start_x: f32,
        start_y: f32,
        width: f32,
        text_align: box.TextAlign,
    ) !f32 {
        return self.layoutInlineChildrenWithOffset(parent_id, start_x, start_y, width, text_align, 0);
    }

    pub fn layoutInlineChildrenWithOffset(
        self: *State,
        parent_id: box.BoxId,
        start_x: f32,
        start_y: f32,
        width: f32,
        text_align: box.TextAlign,
        first_line_offset: f32,
    ) !f32 {
        const style = self.tree.boxes.items[parent_id].style;
        const text_indent = (style.text_indent.resolve(width) orelse 0) + first_line_offset;
        const ellipsis_enabled = style.text_overflow == .ellipsis and style.overflow.clips();
        var cursor = InlineCursor.init(self, start_x, start_y, width, text_align, style.direction, text_indent, ellipsis_enabled);
        const parent_link = self.linkForBox(parent_id);
        var child = self.tree.boxes.items[parent_id].first_child;
        while (child) |child_id| {
            try cursor.layoutBox(child_id, parent_link, .baseline);
            child = self.tree.boxes.items[child_id].next_sibling;
        }
        return cursor.finish();
    }

    pub fn layoutInlineRun(
        self: *State,
        first_box: box.BoxId,
        start_x: f32,
        start_y: f32,
        width: f32,
        text_align: box.TextAlign,
    ) !f32 {
        const first = self.tree.boxes.items[first_box];
        const style = if (first.parent) |parent_id| self.tree.boxes.items[parent_id].style else first.style;
        const text_indent = style.text_indent.resolve(width) orelse 0;
        const ellipsis_enabled = style.text_overflow == .ellipsis and style.overflow.clips();
        var cursor = InlineCursor.init(self, start_x, start_y, width, text_align, style.direction, text_indent, ellipsis_enabled);
        try cursor.layoutBox(first_box, null, .baseline);
        return cursor.finish();
    }
};

fn countListItems(tree: *const box.BoxTree, parent_id: box.BoxId) usize {
    var count: usize = 0;
    var child = tree.boxes.items[parent_id].first_child;
    while (child) |child_id| {
        const source = tree.boxes.items[child_id];
        if (source.kind == .listItem) count += 1;
        child = source.next_sibling;
    }
    return count;
}

fn formatListCounter(allocator: std.mem.Allocator, value: i64, style: box.ListStyleType) ![]const u8 {
    return switch (style) {
        .decimal => std.fmt.allocPrint(allocator, "{d}.", .{value}),
        .decimalLeadingZero => if (value >= 0 and value < 10)
            std.fmt.allocPrint(allocator, "0{d}.", .{value})
        else if (value < 0 and value > -10)
            std.fmt.allocPrint(allocator, "-0{d}.", .{-value})
        else
            std.fmt.allocPrint(allocator, "{d}.", .{value}),
        .lowerAlpha => formatAlphabeticCounter(allocator, value, false),
        .upperAlpha => formatAlphabeticCounter(allocator, value, true),
        .lowerRoman => formatRomanCounter(allocator, value, false),
        .upperRoman => formatRomanCounter(allocator, value, true),
        else => unreachable,
    };
}

fn formatAlphabeticCounter(allocator: std.mem.Allocator, value: i64, uppercase: bool) ![]const u8 {
    if (value <= 0) return std.fmt.allocPrint(allocator, "{d}.", .{value});
    var reversed: [64]u8 = undefined;
    var len: usize = 0;
    var remaining: u64 = @intCast(value);
    while (remaining > 0) {
        remaining -= 1;
        const digit: u8 = @intCast(remaining % 26);
        reversed[len] = (if (uppercase) @as(u8, 'A') else @as(u8, 'a')) + digit;
        len += 1;
        remaining /= 26;
    }
    const result = try allocator.alloc(u8, len + 1);
    for (0..len) |index| result[index] = reversed[len - index - 1];
    result[len] = '.';
    return result;
}

fn formatRomanCounter(allocator: std.mem.Allocator, value: i64, uppercase: bool) ![]const u8 {
    if (value <= 0 or value > 3999) return std.fmt.allocPrint(allocator, "{d}.", .{value});
    const numerals = [_]struct { value: u16, upper: []const u8, lower: []const u8 }{
        .{ .value = 1000, .upper = "M", .lower = "m" }, .{ .value = 900, .upper = "CM", .lower = "cm" },
        .{ .value = 500, .upper = "D", .lower = "d" },  .{ .value = 400, .upper = "CD", .lower = "cd" },
        .{ .value = 100, .upper = "C", .lower = "c" },  .{ .value = 90, .upper = "XC", .lower = "xc" },
        .{ .value = 50, .upper = "L", .lower = "l" },   .{ .value = 40, .upper = "XL", .lower = "xl" },
        .{ .value = 10, .upper = "X", .lower = "x" },   .{ .value = 9, .upper = "IX", .lower = "ix" },
        .{ .value = 5, .upper = "V", .lower = "v" },    .{ .value = 4, .upper = "IV", .lower = "iv" },
        .{ .value = 1, .upper = "I", .lower = "i" },
    };
    var result = try std.ArrayList(u8).initCapacity(allocator, 16);
    var remaining: u16 = @intCast(value);
    for (numerals) |numeral| {
        while (remaining >= numeral.value) {
            try result.appendSlice(allocator, if (uppercase) numeral.upper else numeral.lower);
            remaining -= numeral.value;
        }
    }
    try result.append(allocator, '.');
    return result.toOwnedSlice(allocator);
}

test "layout block and wrapped inline text into separate fragments" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<div><p>Hello world from layout</p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);

    var result = try layout(allocator, &tree, &document, .{ .content_width = 90 });
    defer result.deinit(allocator);

    var text_count: usize = 0;
    var last_line: ?usize = null;
    for (result.fragments.items) |fragment| {
        if (fragment.kind == .text) {
            text_count += 1;
            last_line = fragment.line_id;
        }
    }

    try std.testing.expect(text_count >= 4);
    try std.testing.expect(last_line.? > 0);
    try std.testing.expect(result.content_height > 0);
}

test "preserve whitespace across adjacent nested inline boxes" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<p><strong>Bold</strong>, <em>italic</em></p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);

    for (result.fragments.items) |fragment| {
        if (fragment.text) |text| {
            if (std.mem.eql(u8, text, "italic")) {
                try std.testing.expect(fragment.leading_space);
                return;
            }
        }
    }
    return error.TestExpectedEqual;
}

test "honor nowrap pre and justified line layout" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<p style=\"width:40px;white-space:nowrap\">alpha beta gamma</p>" ++
        "<p style=\"white-space:pre\">one  two\nthree</p>" ++
        "<p style=\"width:100px;text-align:justify\">red green blue yellow violet</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);

    var nowrap_line: ?usize = null;
    var pre_first_line: ?usize = null;
    var pre_second_line: ?usize = null;
    var justified_first: ?Fragment = null;
    var justified_second: ?Fragment = null;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        if (std.mem.eql(u8, text, "alpha") or std.mem.eql(u8, text, "beta") or std.mem.eql(u8, text, "gamma")) {
            if (nowrap_line) |line| try std.testing.expectEqual(line, fragment.line_id.?) else nowrap_line = fragment.line_id;
        }
        if (std.mem.eql(u8, text, "one  two")) pre_first_line = fragment.line_id;
        if (std.mem.eql(u8, text, "three")) pre_second_line = fragment.line_id;
        if (std.mem.eql(u8, text, "red")) justified_first = fragment;
        if (std.mem.eql(u8, text, "green")) justified_second = fragment;
    }
    try std.testing.expect(pre_first_line.? != pre_second_line.?);
    try std.testing.expectEqual(justified_first.?.line_id, justified_second.?.line_id);
    try std.testing.expect(justified_second.?.rect.x > justified_first.?.rect.x + justified_first.?.rect.width);
}

test "apply text transform indent word spacing and emergency word breaks" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<p style=\"margin:0;width:100px;text-indent:20%;text-transform:uppercase\">hello world</p>" ++
        "<p style=\"margin:0;width:28px;word-break:break-all\">abcdefghij</p>" ++
        "<p style=\"margin:0;width:28px;overflow-wrap:break-word\">klmnopqrst</p>" ++
        "<p style=\"margin:0;white-space:pre;word-spacing:10px\">A B</p>" ++
        "<p style=\"margin:0;white-space:pre\">A B</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200 });
    defer result.deinit(allocator);

    var uppercase_x: ?f32 = null;
    var break_all_first_line: ?usize = null;
    var break_all_wrapped = false;
    var break_word_first_line: ?usize = null;
    var break_word_wrapped = false;
    var spaced_width: ?f32 = null;
    var normal_width: ?f32 = null;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        if (std.mem.eql(u8, text, "HELLO")) uppercase_x = fragment.rect.x;
        if (std.mem.indexOf(u8, "abcdefghij", text) != null and text.len > 0) {
            if (break_all_first_line) |line| {
                if (fragment.line_id.? != line) break_all_wrapped = true;
            } else break_all_first_line = fragment.line_id;
        }
        if (std.mem.indexOf(u8, "klmnopqrst", text) != null and text.len > 0) {
            if (break_word_first_line) |line| {
                if (fragment.line_id.? != line) break_word_wrapped = true;
            } else break_word_first_line = fragment.line_id;
        }
        if (std.mem.eql(u8, text, "A B")) {
            if (spaced_width == null) spaced_width = fragment.rect.width else normal_width = fragment.rect.width;
        }
    }

    try std.testing.expectApproxEqAbs(@as(f32, 20), uppercase_x.?, 0.01);
    try std.testing.expect(break_all_wrapped);
    try std.testing.expect(break_word_wrapped);
    try std.testing.expectApproxEqAbs(@as(f32, 10), spaced_width.? - normal_width.?, 0.01);
}

test "apply full Unicode and language-sensitive text transforms" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<p lang='de' style='margin:0;text-transform:uppercase'>straße</p>" ++
        "<p lang='tr' style='margin:0;text-transform:uppercase'>iyi</p>" ++
        "<p lang='el' style='margin:0;text-transform:lowercase'>ΟΣ</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);

    var saw_german = false;
    var saw_turkish = false;
    var saw_greek = false;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        saw_german = saw_german or std.mem.eql(u8, text, "STRASSE");
        saw_turkish = saw_turkish or std.mem.eql(u8, text, "İYİ");
        saw_greek = saw_greek or std.mem.eql(u8, text, "ος");
    }
    try std.testing.expect(saw_german);
    try std.testing.expect(saw_turkish);
    try std.testing.expect(saw_greek);
}

test "align mixed inline font baselines and vertical-align offsets" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<p style='margin:0;line-height:40px'>" ++
        "<span style='font-size:30px'>Large</span>" ++
        "<span style='font-size:10px'>small</span>" ++
        "<span style='font-size:12px;vertical-align:super'>super</span>" ++
        "<span style='font-size:12px;vertical-align:5px'>raised</span>" ++
        "</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);

    var large_baseline: ?f32 = null;
    var small_baseline: ?f32 = null;
    var super_baseline: ?f32 = null;
    var raised_baseline: ?f32 = null;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        const resolved = font.resolve(null, fragment.font_family, fragment.font_weight, fragment.font_style);
        const baseline = fragment.rect.y + fragment.font_size * resolved.metrics().ascentRatio();
        if (std.mem.eql(u8, text, "Large")) large_baseline = baseline;
        if (std.mem.eql(u8, text, "small")) small_baseline = baseline;
        if (std.mem.eql(u8, text, "super")) super_baseline = baseline;
        if (std.mem.eql(u8, text, "raised")) raised_baseline = baseline;
    }

    try std.testing.expectApproxEqAbs(large_baseline.?, small_baseline.?, 0.01);
    try std.testing.expect(super_baseline.? < large_baseline.?);
    try std.testing.expectApproxEqAbs(@as(f32, 5), large_baseline.? - raised_baseline.?, 0.01);
}

test "align replaced and inline-block atomic baselines" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<p style='margin:0;font-size:18px'>Text<img width='20' height='40' style='margin:2px 0 3px;padding:4px;border:2px solid'></p>" ++
        "<p style='margin:0;font-size:18px'><span style='display:inline-block;width:60px;padding:4px;border:1px solid'><span>inner</span></span><span>peer</span></p>" ++
        "<p style='margin:0;font-size:18px'><span style='display:inline-block;overflow:hidden;width:40px;height:30px'>hidden</span><span>tail</span></p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .atomic_inline_baselines = true });
    defer result.deinit(allocator);

    var text_baseline: ?f32 = null;
    var image_baseline: ?f32 = null;
    var image_inset: ?f32 = null;
    var inner_baseline: ?f32 = null;
    var peer_baseline: ?f32 = null;
    var hidden_bottom: ?f32 = null;
    var tail_baseline: ?f32 = null;
    for (result.fragments.items) |fragment| {
        if (fragment.kind == .replaced) {
            image_baseline = fragment.rect.bottom() + fragment.inline_margin_bottom;
            image_inset = fragment.image_content_rect.?.y - fragment.rect.y;
        }
        if (fragment.inline_atomic_root and fragment.kind == .box and tree.boxes.items[fragment.source_box].style.overflow == .hidden) {
            hidden_bottom = fragment.rect.bottom() + fragment.inline_margin_bottom;
        }
        const text = fragment.text orelse continue;
        const resolved = font.resolve(null, fragment.font_family, fragment.font_weight, fragment.font_style);
        const baseline = fragment.rect.y + fragment.font_size * resolved.metrics().ascentRatio();
        if (std.mem.eql(u8, text, "Text")) text_baseline = baseline;
        if (std.mem.eql(u8, text, "inner")) inner_baseline = baseline;
        if (std.mem.eql(u8, text, "peer")) peer_baseline = baseline;
        if (std.mem.eql(u8, text, "tail")) tail_baseline = baseline;
    }

    try std.testing.expectApproxEqAbs(image_baseline.?, text_baseline.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 6), image_inset.?, 0.01);
    try std.testing.expectApproxEqAbs(inner_baseline.?, peer_baseline.?, 0.01);
    try std.testing.expectApproxEqAbs(hidden_bottom.?, tail_baseline.?, 0.01);
}

test "carry text decoration paint through inline fragments" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<p style='text-decoration:underline overline wavy rebeccapurple 2px'>decorated</p>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);
    for (result.fragments.items) |fragment| {
        if (fragment.text == null) continue;
        try std.testing.expectEqual(box.TextDecoration.underlineOverline, fragment.text_decoration);
        try std.testing.expectEqual(box.TextDecorationStyle.wavy, fragment.text_decoration_style);
        try std.testing.expectApproxEqAbs(@as(f32, 0.4), fragment.text_decoration_color.?.red, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 2), fragment.text_decoration_thickness.?, 0.001);
        return;
    }
    return error.TestExpectedEqual;
}

test "clip fixed-height overflow and keep following flow at declared height" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:30px;padding:5px;border:2px solid black;overflow:hidden'><div style='height:100px;background:red'>inside</div></div>" ++
        "<p style='margin:0'>after</p>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200 });
    defer result.deinit(allocator);

    var clipped_child: ?Fragment = null;
    var after: ?Fragment = null;
    for (result.fragments.items) |fragment| {
        if (fragment.background) |background| {
            if (background.red == 1 and background.green == 0) clipped_child = fragment;
        }
        if (fragment.text) |text| {
            if (std.mem.eql(u8, text, "after")) after = fragment;
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 44), after.?.rect.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), clipped_child.?.clip_rect.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), clipped_child.?.clip_rect.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), clipped_child.?.clip_rect.?.height, 0.01);
}

test "truncate nowrap overflow with a selectable ellipsis" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<p style='margin:0;width:90px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis'>alpha beta gamma delta</p>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200 });
    defer result.deinit(allocator);

    var saw_ellipsis = false;
    var saw_hidden_tail = false;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        if (std.mem.eql(u8, text, "…")) saw_ellipsis = true;
        if (std.mem.indexOf(u8, text, "delta") != null) saw_hidden_tail = true;
        try std.testing.expect(fragment.rect.x + fragment.rect.width <= 90.01);
        try std.testing.expect(fragment.clip_rect != null);
    }
    try std.testing.expect(saw_ellipsis);
    try std.testing.expect(!saw_hidden_tail);
}

test "size replaced elements from aspect ratio and captured intrinsic data" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<p style='margin:0'><img data-html2realpdf-intrinsic-width='320' data-html2realpdf-intrinsic-height='200' style='width:160px;aspect-ratio:16/9;object-fit:cover'></p>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);

    for (result.fragments.items) |fragment| {
        if (fragment.kind != .replaced) continue;
        try std.testing.expectApproxEqAbs(@as(f32, 160), fragment.rect.width, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 90), fragment.rect.height, 0.01);
        try std.testing.expectEqual(box.ObjectFit.cover, fragment.object_fit);
        try std.testing.expectApproxEqAbs(@as(f32, 320), fragment.intrinsic_width.?, 0.01);
        return;
    }
    return error.TestExpectedEqual;
}

test "layout inline-block children as an atomic inline group" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<p>before <span style=\"display:inline-block;width:100px;padding:5px\"><strong>inside</strong></span> after</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 260 });
    defer result.deinit(allocator);

    var found_text = false;
    var found_group = false;
    for (result.fragments.items) |fragment| {
        if (fragment.text) |text| {
            if (std.mem.eql(u8, text, "inside")) found_text = true;
        }
        if (tree.boxes.items[fragment.source_box].kind == .inlineBlock and fragment.kind == .box) {
            found_group = fragment.inline_container_line_id != null;
        }
    }
    try std.testing.expect(found_text);
    try std.testing.expect(found_group);
}

test "forced page break advances following content to the next page" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<div>first</div><div style=\"break-before: page\">second</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{
        .content_width = 200,
        .page_height = 100,
    });
    defer result.deinit(allocator);

    var second_y: ?f32 = null;
    for (result.fragments.items) |fragment| {
        if (fragment.text) |text| {
            if (std.mem.eql(u8, text, "second")) second_y = fragment.rect.y;
        }
    }
    try std.testing.expect(second_y != null);
    try std.testing.expect(second_y.? >= 100);
}

test "Web facing-page breaks arbitrate adjacent before and after values" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:10px;break-after:right'></div>" ++
        "<div style='height:10px;break-before:left;background:#ff0000'>left</div>" ++
        "<div style='height:10px;break-before:right;background:#0000ff'>right</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 100, .web_sizing = true });
    defer result.deinit(allocator);

    var left: ?geometry.Rect = null;
    var right: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) left = fragment.rect;
        if (color.blue == 1 and color.red == 0) right = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100), left.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), right.?.y, 0.01);
}

test "Web named page changes force a new page at block boundaries" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:20px;page:Report;background:#ff0000'>report</div>" ++
        "<div style='height:20px;page:Summary;background:#0000ff'>summary</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 100, .web_sizing = true });
    defer result.deinit(allocator);

    var report: ?geometry.Rect = null;
    var summary: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) report = fragment.rect;
        if (color.blue == 1 and color.red == 0) summary = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), report.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), summary.?.y, 0.01);
}

test "Web recto and verso follow the DOM root direction" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='direction:rtl'>" ++
        "<div style='height:10px'></div>" ++
        "<div style='height:10px;break-before:recto;background:#ff0000'>recto</div>" ++
        "<div style='height:10px;break-before:verso;background:#0000ff'>verso</div></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 100, .web_sizing = true });
    defer result.deinit(allocator);

    var recto: ?geometry.Rect = null;
    var verso: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) recto = fragment.rect;
        if (color.blue == 1 and color.red == 0) verso = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100), recto.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), verso.?.y, 0.01);
}

test "Web first-child forced break propagates before the parent decorations" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:20px'></div>" ++
        "<div style='padding-top:10px;background:#ff0000'>" ++
        "<div style='height:10px;break-before:page'>target</div></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 100, .web_sizing = true });
    defer result.deinit(allocator);

    var parent: ?geometry.Rect = null;
    var target_y: ?f32 = null;
    for (result.fragments.items) |fragment| {
        if (fragment.background) |color| {
            if (color.red == 1 and color.blue == 0) parent = fragment.rect;
        }
        if (fragment.text) |text| {
            if (std.mem.eql(u8, text, "target")) target_y = fragment.rect.y;
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100), parent.?.y, 0.01);
    try std.testing.expect(target_y.? >= 110);
}

test "Web avoid boundary moves an adjacent sibling group intact" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:20px'></div>" ++
        "<div style='height:35px;break-after:avoid;background:#ff0000'>first</div>" ++
        "<div style='height:20px;background:#0000ff'>second</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 60, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 95), second.?.y, 0.01);
}

test "Web descendant forced break overrides ancestor break-inside avoid" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:40px'></div>" ++
        "<div style='break-inside:avoid;background:#ff0000'>" ++
        "<div style='height:10px'></div>" ++
        "<div style='height:10px;break-before:page;background:#0000ff'>target</div></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 60, .web_sizing = true });
    defer result.deinit(allocator);

    var parent: ?geometry.Rect = null;
    var target: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) parent = fragment.rect;
        if (color.blue == 1 and color.red == 0) target = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 40), parent.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), target.?.y, 0.01);
}

test "forced page break applies to inline replaced elements" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<style>#target{break-before:page}</style><p>first<img id=\"target\" style=\"width:20px;height:20px\"></p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{
        .content_width = 200,
        .page_height = 100,
    });
    defer result.deinit(allocator);

    for (result.fragments.items) |fragment| {
        if (fragment.kind != .replaced) continue;
        try std.testing.expect(fragment.rect.y >= 100);
        return;
    }
    return error.TestExpectedEqual;
}

test "table layout places cells in shared row columns" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<table style=\"width:200px\"><tr><td>A</td><td>B</td></tr></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200 });
    defer result.deinit(allocator);

    var cells: [2]geometry.Rect = undefined;
    var cell_count: usize = 0;
    for (result.fragments.items) |fragment| {
        if (tree.boxes.items[fragment.source_box].kind != .tableCell) continue;
        if (cell_count < cells.len) cells[cell_count] = fragment.rect;
        cell_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), cell_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cells[0].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cells[1].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cells[0].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cells[1].width, 0.01);
    try std.testing.expectApproxEqAbs(cells[0].height, cells[1].height, 0.01);
}

test "table cells align top middle bottom and shared baselines" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<table style='width:300px'>" ++
        "<tr style='height:100px'><td style='vertical-align:top'>top</td><td style='vertical-align:middle'>middle</td><td style='vertical-align:bottom'>bottom</td></tr>" ++
        "<tr><td style='font-size:12px;vertical-align:baseline'>small</td><td style='font-size:24px;vertical-align:baseline'>large</td></tr>" ++
        "</table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);

    var top_y: ?f32 = null;
    var middle_y: ?f32 = null;
    var bottom_y: ?f32 = null;
    var small_baseline: ?f32 = null;
    var large_baseline: ?f32 = null;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        if (std.mem.eql(u8, text, "top")) top_y = fragment.rect.y;
        if (std.mem.eql(u8, text, "middle")) middle_y = fragment.rect.y;
        if (std.mem.eql(u8, text, "bottom")) bottom_y = fragment.rect.y;
        if (std.mem.eql(u8, text, "small") or std.mem.eql(u8, text, "large")) {
            const resolved = font.resolve(null, fragment.font_family, fragment.font_weight, fragment.font_style);
            const baseline = fragment.rect.y + fragment.font_size * resolved.metrics().ascentRatio();
            if (std.mem.eql(u8, text, "small")) small_baseline = baseline else large_baseline = baseline;
        }
    }

    try std.testing.expect(top_y.? < middle_y.? and middle_y.? < bottom_y.?);
    try std.testing.expectApproxEqAbs(middle_y.? - top_y.?, bottom_y.? - middle_y.?, 0.01);
    try std.testing.expectApproxEqAbs(small_baseline.?, large_baseline.?, 0.01);
}

test "table captions and column definitions participate in Web layout" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<table style='width:300px'>" ++
        "<caption>TOP</caption>" ++
        "<colgroup><col style='width:60px'><col span='2' style='width:120px'></colgroup>" ++
        "<tr><td>A</td><td>B</td><td>C</td></tr>" ++
        "<caption style='caption-side:bottom'>BOTTOM</caption>" ++
        "</table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var cells: [3]geometry.Rect = undefined;
    var cell_count: usize = 0;
    var top_y: ?f32 = null;
    var row_y: ?f32 = null;
    var bottom_y: ?f32 = null;
    for (result.fragments.items) |fragment| {
        if (tree.boxes.items[fragment.source_box].kind == .tableCell) {
            cells[cell_count] = fragment.rect;
            cell_count += 1;
        }
        const text = fragment.text orelse continue;
        if (std.mem.eql(u8, text, "TOP")) top_y = fragment.rect.y;
        if (std.mem.eql(u8, text, "A")) row_y = fragment.rect.y;
        if (std.mem.eql(u8, text, "BOTTOM")) bottom_y = fragment.rect.y;
    }

    try std.testing.expectEqual(@as(usize, 3), cell_count);
    try std.testing.expectApproxEqAbs(@as(f32, 60), cells[0].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), cells[1].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), cells[2].width, 0.01);
    try std.testing.expect(top_y.? < row_y.? and row_y.? < bottom_y.?);
}

test "Web table auto layout uses intrinsic cell contributions" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<table style='width:300px'><tr><td>substantially-wide-content</td><td>x</td></tr></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var widths: [2]f32 = undefined;
    var count: usize = 0;
    for (result.fragments.items) |fragment| {
        if (tree.boxes.items[fragment.source_box].kind != .tableCell) continue;
        widths[count] = fragment.rect.width;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(widths[0] > widths[1] * 2);
}

test "percentage table cells fill their allocated tracks" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<table style=\"width:400px\"><tr>" ++
        "<td style=\"width:25%;padding:10px;border:1px solid\">A</td>" ++
        "<td style=\"width:25%;padding:10px;border:1px solid\">B</td>" ++
        "<td style=\"width:25%;padding:10px;border:1px solid\">C</td>" ++
        "<td style=\"width:25%;padding:10px;border:1px solid\">D</td>" ++
        "</tr></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 400 });
    defer result.deinit(allocator);

    var cell_index: usize = 0;
    for (result.fragments.items) |fragment| {
        if (tree.boxes.items[fragment.source_box].kind != .tableCell) continue;
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(cell_index * 100)), fragment.rect.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 100), fragment.rect.width, 0.01);
        cell_index += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), cell_index);
}

test "percentage table hints produce unequal tracks without double resolution" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<table style=\"width:400px\"><tr>" ++
        "<td style=\"width:50%\">wide</td>" ++
        "<td style=\"width:25%\">medium</td>" ++
        "<td style=\"width:25%\">medium</td>" ++
        "</tr></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 400 });
    defer result.deinit(allocator);

    var cells: [3]geometry.Rect = undefined;
    var count: usize = 0;
    for (result.fragments.items) |fragment| {
        if (tree.boxes.items[fragment.source_box].kind != .tableCell) continue;
        cells[count] = fragment.rect;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectApproxEqAbs(@as(f32, 200), cells[0].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cells[1].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cells[2].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), cells[1].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 300), cells[2].x, 0.01);
}

test "percentage table hint is distributed across colspan tracks" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<table style=\"width:400px\"><tr>" ++
        "<td colspan=\"2\" style=\"width:50%\">wide</td>" ++
        "<td style=\"width:25%\">medium</td>" ++
        "<td style=\"width:25%\">medium</td>" ++
        "</tr></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 400 });
    defer result.deinit(allocator);

    var cells: [3]geometry.Rect = undefined;
    var count: usize = 0;
    for (result.fragments.items) |fragment| {
        if (tree.boxes.items[fragment.source_box].kind != .tableCell) continue;
        cells[count] = fragment.rect;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectApproxEqAbs(@as(f32, 200), cells[0].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cells[1].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), cells[2].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), cells[1].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 300), cells[2].x, 0.01);
}

test "table grid honors row and column spans" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<table style=\"width:300px\"><tr><td rowspan=\"2\">A</td><td>B</td></tr><tr><td>C</td></tr></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);

    var cells: [3]geometry.Rect = undefined;
    var count: usize = 0;
    for (result.fragments.items) |fragment| {
        if (tree.boxes.items[fragment.source_box].kind != .tableCell) continue;
        cells[count] = fragment.rect;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cells[0].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), cells[1].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), cells[2].x, 0.01);
    try std.testing.expect(cells[2].y > cells[1].y);
    try std.testing.expectApproxEqAbs(cells[1].height + cells[2].height, cells[0].height, 0.01);
}

test "row-spanning cells align after their final row height is known" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<table style='width:200px'>" ++
        "<tr style='height:40px'><td rowspan='2' style='vertical-align:bottom'>SPAN</td><td>FIRST</td></tr>" ++
        "<tr style='height:40px'><td>SECOND</td></tr>" ++
        "</table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200 });
    defer result.deinit(allocator);

    var span_y: ?f32 = null;
    var second_y: ?f32 = null;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        if (std.mem.eql(u8, text, "SPAN")) span_y = fragment.rect.y;
        if (std.mem.eql(u8, text, "SECOND")) second_y = fragment.rect.y;
    }
    try std.testing.expect(span_y.? > second_y.?);
}

test "repeat table headers when rows continue on another page" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<table style=\"width:200px;border-collapse:collapse\">" ++
        "<thead><tr style=\"height:20px\"><th style=\"border:1px\">Header</th></tr></thead>" ++
        "<tbody><tr style=\"height:30px\"><td style=\"border:1px\">first</td></tr>" ++
        "<tr style=\"height:30px\"><td style=\"border:1px\">second</td></tr></tbody></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200, .page_height = 60 });
    defer result.deinit(allocator);

    var header_count: usize = 0;
    var repeated_header_y: f32 = 0;
    var second_y: f32 = 0;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        if (std.mem.eql(u8, text, "Header")) {
            header_count += 1;
            repeated_header_y = @max(repeated_header_y, fragment.rect.y);
        }
        if (std.mem.eql(u8, text, "second")) second_y = fragment.rect.y;
    }
    try std.testing.expectEqual(@as(usize, 2), header_count);
    try std.testing.expectApproxEqAbs(@as(f32, 61), repeated_header_y, 0.01);
    try std.testing.expect(second_y >= 80);
}

test "Web table reserves and repeats footer groups on every occupied page" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<table style='width:200px;border-collapse:collapse'>" ++
        "<thead><tr style='height:20px'><th>HEAD</th></tr></thead>" ++
        "<tfoot><tr style='height:20px'><td>FOOT</td></tr></tfoot>" ++
        "<tbody><tr style='height:30px'><td>ONE</td></tr>" ++
        "<tr style='height:30px'><td>TWO</td></tr>" ++
        "<tr style='height:30px'><td>THREE</td></tr></tbody></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200, .page_height = 100, .web_sizing = true });
    defer result.deinit(allocator);

    var head_pages: [2]bool = .{ false, false };
    var foot_pages: [2]bool = .{ false, false };
    var three_y: ?f32 = null;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        const page_index: usize = @intFromFloat(@floor(fragment.rect.y / 100));
        if (std.mem.eql(u8, text, "HEAD") and page_index < head_pages.len) head_pages[page_index] = true;
        if (std.mem.eql(u8, text, "FOOT") and page_index < foot_pages.len) foot_pages[page_index] = true;
        if (std.mem.eql(u8, text, "THREE")) three_y = fragment.rect.y;
    }

    try std.testing.expectEqual([2]bool{ true, true }, head_pages);
    try std.testing.expectEqual([2]bool{ true, true }, foot_pages);
    try std.testing.expectApproxEqAbs(@as(f32, 120), three_y.?, 0.01);
    var footer_roots: [2]f32 = undefined;
    var footer_count: usize = 0;
    for (result.fragments.items) |fragment| {
        if (!fragment.is_table_footer or tree.boxes.items[fragment.source_box].kind != .tableRow) continue;
        footer_roots[footer_count] = fragment.rect.y;
        footer_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), footer_count);
    std.mem.sort(f32, &footer_roots, {}, std.sort.asc(f32));
    try std.testing.expectApproxEqAbs(@as(f32, 80), footer_roots[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 180), footer_roots[1], 0.01);
}

test "Web table keeps avoid-linked rows with their repeated header" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:10px'></div>" ++
        "<table style='width:100px;border-collapse:collapse'>" ++
        "<thead><tr style='height:20px;background:#00ff00'><th>Header</th></tr></thead>" ++
        "<tbody><tr style='height:20px;break-after:avoid;background:#ff0000'><td>first</td></tr>" ++
        "<tr style='height:20px;background:#0000ff'><td>second</td></tr></tbody></table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 60, .web_sizing = true });
    defer result.deinit(allocator);

    var repeated_header_y: f32 = 0;
    var header_count: usize = 0;
    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.green == 1 and color.red == 0 and fragment.source_box != tree.root) {
            header_count += 1;
            repeated_header_y = @max(repeated_header_y, fragment.rect.y);
        }
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
    }
    try std.testing.expectEqual(@as(usize, 2), header_count);
    try std.testing.expectApproxEqAbs(@as(f32, 60), repeated_header_y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), second.?.y, 0.01);
}

test "border-box dimensions include padding and borders" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<div style=\"box-sizing:border-box;width:100px;height:80px;padding:10px;border:5px solid\">box</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200 });
    defer result.deinit(allocator);

    for (result.fragments.items) |fragment| {
        const source_box = tree.boxes.items[fragment.source_box];
        const node_id = source_box.node orelse continue;
        if (document.nodes.items[node_id].kind != .element or document.nodes.items[node_id].kind.element.tag != .div) continue;
        try std.testing.expectApproxEqAbs(@as(f32, 100), fragment.rect.width, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 80), fragment.rect.height, 0.01);
        return;
    }
    return error.TestExpectedEqual;
}

test "Web non-replaced boxes transfer aspect ratio into auto height" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='width:160px;aspect-ratio:16/9'></div>" ++
        "<div style='box-sizing:border-box;width:160px;aspect-ratio:16/9;padding:10px;border:5px solid'></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 400, .web_sizing = true });
    defer result.deinit(allocator);

    var boxes: [2]geometry.Rect = undefined;
    var count: usize = 0;
    for (result.fragments.items) |fragment| {
        if (fragment.source_box == tree.root) continue;
        if (tree.boxes.items[fragment.source_box].kind != .block) continue;
        boxes[count] = fragment.rect;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectApproxEqAbs(@as(f32, 160), boxes[0].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), boxes[0].height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 160), boxes[1].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), boxes[1].height, 0.01);
}

test "web sizing resolves percentage heights only through definite containing blocks" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:200px;background:#ff0000'>" ++
        "<div style='height:50%;background:#00ff00'></div>" ++
        "<div style='height:calc(50% - 10px);background:#0000ff'></div>" ++
        "</div>" ++
        "<div style='background:#ffff00'>" ++
        "<div style='height:50%;background:#ff00ff'><div style='height:60px'></div></div>" ++
        "<div style='height:calc(40px + 10px);background:#00ffff'></div>" ++
        "</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{
        .content_width = 300,
        .page_height = 400,
        .web_sizing = true,
    });
    defer result.deinit(allocator);

    var definite_percent: ?f32 = null;
    var definite_calc: ?f32 = null;
    var indefinite_percent: ?f32 = null;
    var absolute_calc: ?f32 = null;
    for (result.fragments.items) |fragment| {
        const background = fragment.background orelse continue;
        if (background.green == 1 and background.red == 0 and background.blue == 0) definite_percent = fragment.rect.height;
        if (background.blue == 1 and background.red == 0 and background.green == 0) definite_calc = fragment.rect.height;
        if (background.red == 1 and background.blue == 1 and background.green == 0) indefinite_percent = fragment.rect.height;
        if (background.green == 1 and background.blue == 1 and background.red == 0) absolute_calc = fragment.rect.height;
    }

    try std.testing.expectApproxEqAbs(@as(f32, 100), definite_percent.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), definite_calc.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), indefinite_percent.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), absolute_calc.?, 0.01);
}

test "web sizing measures min max fit content and shrink-to-fit inline blocks" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='width:min-content;background:#ff0000'>alpha longestword beta</div>" ++
        "<div style='width:max-content;background:#00ff00'>alpha longestword beta</div>" ++
        "<div style='width:fit-content(100px);background:#0000ff'>alpha longestword beta</div>" ++
        "<p style='margin:0'><span style='display:inline-block;background:#ff00ff'>tiny words</span></p>" ++
        "<div style='width:50px;min-width:120px;max-width:80px;background:#00ffff'></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 140, .web_sizing = true });
    defer result.deinit(allocator);

    const text_style = styles[document.nodes.items[document.root].first_child.?];
    const min_expected = intrinsic.measureText(null, .identity, "longestword", text_style.font_family, text_style.font_size, text_style.font_weight, text_style.font_style, text_style.letter_spacing);
    const max_expected = intrinsic.measureText(null, .identity, "alpha longestword beta", text_style.font_family, text_style.font_size, text_style.font_weight, text_style.font_style, text_style.letter_spacing);
    const inline_expected = intrinsic.measureText(null, .identity, "tiny words", text_style.font_family, text_style.font_size, text_style.font_weight, text_style.font_style, text_style.letter_spacing);
    try std.testing.expect(min_expected < 100 and max_expected > 140);

    var min_width: ?f32 = null;
    var max_width: ?f32 = null;
    var fit_width: ?f32 = null;
    var inline_width: ?f32 = null;
    var constrained_width: ?f32 = null;
    for (result.fragments.items) |fragment| {
        const background = fragment.background orelse continue;
        if (background.red == 1 and background.green == 0 and background.blue == 0) min_width = fragment.rect.width;
        if (background.green == 1 and background.red == 0 and background.blue == 0) max_width = fragment.rect.width;
        if (background.blue == 1 and background.red == 0 and background.green == 0) fit_width = fragment.rect.width;
        if (background.red == 1 and background.blue == 1 and background.green == 0) inline_width = fragment.rect.width;
        if (background.green == 1 and background.blue == 1 and background.red == 0) constrained_width = fragment.rect.width;
    }

    try std.testing.expectApproxEqAbs(min_expected, min_width.?, 0.01);
    try std.testing.expectApproxEqAbs(max_expected, max_width.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), fit_width.?, 0.01);
    try std.testing.expectApproxEqAbs(inline_expected, inline_width.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), constrained_width.?, 0.01);
}

test "adjacent block margins collapse instead of adding" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source = "<div><p>first</p><p>second</p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300 });
    defer result.deinit(allocator);

    var paragraphs: [2]geometry.Rect = undefined;
    var paragraph_count: usize = 0;
    for (result.fragments.items) |fragment| {
        const source_box = tree.boxes.items[fragment.source_box];
        const node_id = source_box.node orelse continue;
        if (document.nodes.items[node_id].kind != .element or document.nodes.items[node_id].kind.element.tag != .p) continue;
        if (paragraph_count < paragraphs.len) paragraphs[paragraph_count] = fragment.rect;
        paragraph_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), paragraph_count);
    const gap = paragraphs[1].y - paragraphs[0].bottom();
    try std.testing.expectApproxEqAbs(@as(f32, 16), gap, 0.01);
}

test "Web parent and child margins collapse at both block edges" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='margin:10px 0 12px;background:#00ff00'>" ++
        "<div style='height:20px;margin:30px 0 40px;background:#ff0000'></div></div>" ++
        "<div style='height:10px;background:#0000ff'></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var parent: ?geometry.Rect = null;
    var child: ?geometry.Rect = null;
    var next: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.green == 1 and color.red == 0) parent = fragment.rect;
        if (color.red == 1 and color.green == 0) child = fragment.rect;
        if (color.blue == 1 and color.red == 0) next = fragment.rect;
    }

    try std.testing.expectApproxEqAbs(@as(f32, 30), parent.?.y, 0.01);
    try std.testing.expectApproxEqAbs(parent.?.y, child.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), next.?.y - child.?.bottom(), 0.01);
}

test "Web empty blocks collapse positive and negative margin groups" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:10px;margin-bottom:30px;background:#ff0000'></div>" ++
        "<div style='margin-top:20px;margin-bottom:-15px'></div>" ++
        "<div style='height:10px;margin-top:10px;background:#0000ff'></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var last: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) last = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 15), last.?.y - first.?.bottom(), 0.01);
}

test "Web padding and overflow establish margin-collapse boundaries" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='margin-top:10px;padding-top:5px'><div style='height:10px;margin-top:30px;background:#ff0000'></div></div>" ++
        "<div style='overflow:hidden;margin-top:10px'><div style='height:10px;margin-top:30px;background:#0000ff'></div></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var padded_parent: ?geometry.Rect = null;
    var padded_child: ?geometry.Rect = null;
    var clipped_parent: ?geometry.Rect = null;
    var clipped_child: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const source_box = tree.boxes.items[fragment.source_box];
        if (fragment.background) |color| {
            if (color.red == 1 and color.blue == 0) padded_child = fragment.rect;
            if (color.blue == 1 and color.red == 0) clipped_child = fragment.rect;
        } else if (source_box.first_child != null and source_box.kind == .block) {
            if (source_box.style.padding.top == 5) padded_parent = fragment.rect;
            if (source_box.style.overflow == .hidden) clipped_parent = fragment.rect;
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 35), padded_child.?.y - padded_parent.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), clipped_child.?.y - clipped_parent.?.y, 0.01);
}

test "Web list markers honor CSS styles and HTML counter hints" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<ol reversed start='5' style='list-style:inside upper-roman'>" ++
        "<li>five</li><li value='2'>two</li><li>one</li></ol>" ++
        "<ul style='list-style-type:square'><li>box</li></ul>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    const expected = [_][]const u8{ "V.", "II.", "I." };
    var found: usize = 0;
    var first_marker_x: ?f32 = null;
    var first_text_x: ?f32 = null;
    var square_marker_x: ?f32 = null;
    var square_text_x: ?f32 = null;
    for (result.fragments.items) |fragment| {
        if (fragment.kind == .box and fragment.rect.width > 0 and fragment.rect.width < 10 and fragment.background != null) {
            square_marker_x = fragment.rect.x;
        }
        const text = fragment.text orelse continue;
        if (found < expected.len and std.mem.eql(u8, text, expected[found])) {
            if (found == 0) first_marker_x = fragment.rect.x;
            found += 1;
        } else if (std.mem.eql(u8, text, "five")) {
            first_text_x = fragment.rect.x;
        } else if (std.mem.eql(u8, text, "box")) {
            square_text_x = fragment.rect.x;
        }
    }
    try std.testing.expectEqual(expected.len, found);
    try std.testing.expect(first_text_x.? > first_marker_x.?);
    try std.testing.expect(square_text_x.? > square_marker_x.?);
}

test "list counter formatting covers alphabetic Roman and leading zero styles" {
    const allocator = std.testing.allocator;
    const alpha = try formatListCounter(allocator, 27, .upperAlpha);
    defer allocator.free(alpha);
    const roman = try formatListCounter(allocator, 49, .lowerRoman);
    defer allocator.free(roman);
    const leading_zero = try formatListCounter(allocator, -3, .decimalLeadingZero);
    defer allocator.free(leading_zero);
    try std.testing.expectEqualStrings("AA.", alpha);
    try std.testing.expectEqualStrings("xlix.", roman);
    try std.testing.expectEqualStrings("-03.", leading_zero);
}

test "Web floats occupy side bands and clear moves below them" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='width:300px'>" ++
        "<div style='float:left;width:80px;height:80px;margin-right:10px'>LEFT</div>" ++
        "<div style='float:right;width:60px;height:50px;margin-left:10px'>RIGHT</div>" ++
        "<p style='margin:0'>FLOW</p>" ++
        "<div style='clear:both;height:20px'>CLEAR</div>" ++
        "</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var left: ?geometry.Rect = null;
    var right: ?geometry.Rect = null;
    var flow: ?geometry.Rect = null;
    var clear: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const text = fragment.text orelse continue;
        if (std.mem.eql(u8, text, "LEFT")) left = fragment.rect;
        if (std.mem.eql(u8, text, "RIGHT")) right = fragment.rect;
        if (std.mem.eql(u8, text, "FLOW")) flow = fragment.rect;
        if (std.mem.eql(u8, text, "CLEAR")) clear = fragment.rect;
    }
    try std.testing.expect(left.?.x < flow.?.x);
    try std.testing.expect(flow.?.x < right.?.x);
    try std.testing.expect(clear.?.y >= left.?.y + 80);
}

test "Web relative positioning shifts paint without changing normal flow" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='position:relative;left:20px;top:10px;height:20px;background:#ff0000'>shifted</div>" ++
        "<div style='height:20px;background:#0000ff'>flow</div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200, .web_sizing = true });
    defer result.deinit(allocator);

    var shifted: ?geometry.Rect = null;
    var flow: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) shifted = fragment.rect;
        if (color.blue == 1 and color.red == 0) flow = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 20), shifted.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), shifted.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), flow.?.y, 0.01);
}

test "Web absolute positioning resolves padding containing blocks and inset sizing" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='position:relative;width:200px;height:100px;padding:10px;background:#f1f5f9'>" ++
        "<div style='height:20px;background:#ff0000'>normal</div>" ++
        "<div style='position:absolute;right:20px;top:10px;width:50px;height:30px;background:#0000ff'>corner</div>" ++
        "<div style='position:absolute;inset:5px 20px 15px 10px;background:#ff00ff'></div>" ++
        "<div style='position:absolute;left:0;right:0;top:0;width:20px;height:10px;margin-left:auto;margin-right:auto;background:#00ffff'></div>" ++
        "</div><div style='height:10px;background:#00ff00'>after</div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 240, .page_height = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var normal: ?geometry.Rect = null;
    var corner: ?geometry.Rect = null;
    var stretched: ?geometry.Rect = null;
    var after: ?geometry.Rect = null;
    var centered: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.green == 0 and color.blue == 0) normal = fragment.rect;
        if (color.blue == 1 and color.red == 0 and color.green == 0) corner = fragment.rect;
        if (color.red == 1 and color.blue == 1) stretched = fragment.rect;
        if (color.green == 1 and color.red == 0 and color.blue == 0) after = fragment.rect;
        if (color.green == 1 and color.blue == 1 and color.red == 0) centered = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 10), normal.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), normal.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), corner.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), corner.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 10), stretched.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 5), stretched.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 190), stretched.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), stretched.?.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), after.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), centered.?.x, 0.01);
}

test "Web fixed positioning repeats without consuming normal flow" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    const pagination = @import("pagination.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:80px;background:#00ff00'></div>" ++
        "<div style='position:fixed;left:10px;top:5px;width:50px;height:10px;background:#ff0000'>header</div>" ++
        "<div style='position:fixed;left:10px;bottom:5px;width:50px;height:10px;background:#ff00ff'>footer</div>" ++
        "<div style='height:80px;background:#0000ff'></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 60, .web_sizing = true });
    defer result.deinit(allocator);
    var pages = try pagination.paginate(allocator, &result, .{ .width_points = 75, .height_points = 45 });
    defer pages.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), pages.page_count);
    var header_count: usize = 0;
    var footer_count: usize = 0;
    var footer_text_count: usize = 0;
    for (pages.fragments.items) |paged| {
        if (paged.fragment.fixed and paged.fragment.text != null and std.mem.eql(u8, paged.fragment.text.?, "footer")) {
            footer_text_count += 1;
            try std.testing.expectApproxEqAbs(@as(f32, 45), paged.fragment.rect.y, 0.01);
        }
        if (!paged.fragment.fixed or paged.fragment.background == null) continue;
        const color = paged.fragment.background.?;
        try std.testing.expectApproxEqAbs(@as(f32, 10), paged.fragment.rect.x, 0.01);
        if (color.red == 1 and color.green == 0 and color.blue == 0) {
            header_count += 1;
            try std.testing.expectApproxEqAbs(@as(f32, 5), paged.fragment.rect.y, 0.01);
        }
        if (color.red == 1 and color.green == 0 and color.blue == 1) {
            footer_count += 1;
            try std.testing.expectApproxEqAbs(@as(f32, 45), paged.fragment.rect.y, 0.01);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), header_count);
    try std.testing.expectEqual(@as(usize, 3), footer_count);
    try std.testing.expectEqual(@as(usize, 3), footer_text_count);
}

test "Web stacking metadata orders positioned layers and compounds opacity" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='position:relative;width:100px;height:100px;opacity:.5;background:#f1f5f9'>" ++
        "<div style='position:absolute;inset:0;z-index:2;background:#ff0000'></div>" ++
        "<div style='height:20px;opacity:.5;background:#00ff00'></div>" ++
        "<div style='position:absolute;inset:0;z-index:-1;background:#0000ff'></div>" ++
        "<div style='position:relative;z-index:0;height:20px;background:#ff00ff'></div>" ++
        "</div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 200, .web_sizing = true });
    defer result.deinit(allocator);

    var negative_order: ?usize = null;
    var normal_order: ?usize = null;
    var zero_order: ?usize = null;
    var positive_order: ?usize = null;
    var normal_opacity: ?f32 = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.blue == 1 and color.red == 0) negative_order = fragment.paint_order;
        if (color.green == 1 and color.red == 0) {
            normal_order = fragment.paint_order;
            normal_opacity = fragment.opacity;
        }
        if (color.red == 1 and color.blue == 1) zero_order = fragment.paint_order;
        if (color.red == 1 and color.green == 0 and color.blue == 0) positive_order = fragment.paint_order;
    }
    try std.testing.expect(negative_order.? < normal_order.?);
    try std.testing.expect(normal_order.? < zero_order.?);
    try std.testing.expect(zero_order.? < positive_order.?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), normal_opacity.?, 0.001);
}

test "Web transforms propagate to descendants and establish positioned containing blocks" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='width:100px;height:60px;padding:10px;overflow:hidden;transform:translate(20px,10px) rotate(90deg);transform-origin:0 0;background:#0000ff'>" ++
        "<div style='position:absolute;right:0;top:0;width:20px;height:10px;transform:scale(1.5,.8);transform-origin:0 0;background:#ff0000'>x</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .page_height = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var parent_transform: ?geometry.AffineTransform = null;
    var child_transform: ?geometry.AffineTransform = null;
    var child_clip_transform: ?geometry.AffineTransform = null;
    var text_transform: ?geometry.AffineTransform = null;
    var child_x: ?f32 = null;
    for (result.fragments.items) |fragment| {
        if (fragment.text != null) text_transform = fragment.transform;
        const color = fragment.background orelse continue;
        if (color.blue == 1) parent_transform = fragment.transform;
        if (color.red == 1) {
            child_transform = fragment.transform;
            child_clip_transform = fragment.clip_transform;
            child_x = fragment.rect.x;
        }
    }
    try std.testing.expect(parent_transform != null and child_transform != null and child_clip_transform != null and text_transform != null);
    try std.testing.expect(!parent_transform.?.approxEqual(child_transform.?, 0.001));
    try std.testing.expect(parent_transform.?.approxEqual(child_clip_transform.?, 0.001));
    try std.testing.expect(child_transform.?.approxEqual(text_transform.?, 0.001));
    try std.testing.expectApproxEqAbs(@as(f32, 0), parent_transform.?.a, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), parent_transform.?.b, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), parent_transform.?.c, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), parent_transform.?.e, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), parent_transform.?.f, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), child_x.?, 0.001);
}

test "Web overflow clips deferred absolute descendants" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='position:relative;width:100px;height:50px;overflow:hidden'>" ++
        "<div style='position:absolute;left:80px;top:0;width:40px;height:20px;background:#ff0000'></div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 200, .web_sizing = true });
    defer result.deinit(allocator);
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red != 1) continue;
        try std.testing.expectApproxEqAbs(@as(f32, 80), fragment.rect.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 100), fragment.clip_rect.?.width, 0.01);
        return;
    }
    return error.TestExpectedEqual;
}

test "Web flex row distributes grow factors gap and stretch" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;width:300px;height:100px;gap:10px'>" ++
        "<div style='flex:1;background:#ff0000'>A</div>" ++
        "<div style='flex:2;background:#0000ff'>B</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 96.667), first.?.width, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 193.333), second.?.width, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 10), second.?.x - (first.?.x + first.?.width), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), first.?.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), second.?.height, 0.01);
}

test "Web flex wrap order and align content create stable lines" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;flex-wrap:wrap;width:220px;gap:10px'>" ++
        "<div style='order:2;flex:0 0 100px;height:20px;background:#ff0000'>third</div>" ++
        "<div style='order:0;flex:0 0 100px;height:20px;background:#00ff00'>first</div>" ++
        "<div style='order:1;flex:0 0 100px;height:20px;background:#0000ff'>second</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 220, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    var third: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.green == 1 and color.red == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
        if (color.red == 1 and color.green == 0) third = fragment.rect;
    }
    try std.testing.expect(first.?.x < second.?.x);
    try std.testing.expectApproxEqAbs(first.?.y, second.?.y, 0.01);
    try std.testing.expect(third.?.y > first.?.bottom());
    try std.testing.expectApproxEqAbs(@as(f32, 10), third.?.y - first.?.bottom(), 0.01);
}

test "Web column reverse and justify content place items on the vertical axis" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;flex-direction:column-reverse;justify-content:space-between;width:100px;height:300px'>" ++
        "<div style='flex:0 0 50px;background:#ff0000'>first</div>" ++
        "<div style='flex:0 0 50px;background:#0000ff'>second</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 250), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), second.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), first.?.height, 0.01);
}

test "Web flex shrink redistributes after min constraints and aligns individual items" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;width:200px;height:100px;align-items:flex-end'>" ++
        "<div style='flex:0 1 150px;min-width:120px;height:20px;align-self:center;background:#ff0000'>A</div>" ++
        "<div style='flex:0 1 150px;min-width:0;height:30px;background:#0000ff'>B</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200, .web_sizing = true });
    defer result.deinit(allocator);
    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 120), first.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), second.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 70), second.?.y, 0.01);
}

test "Web flex supports percentage basis nested containers and replaced ratios" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;width:300px'>" ++
        "<div style='display:flex;flex:0 0 50%;height:60px;background:#00ff00'>" ++
        "<div style='flex:1;background:#ff0000'>nested</div></div>" ++
        "<img width='200' height='100' style='flex:0 0 100px'></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);
    var nested: ?geometry.Rect = null;
    var image: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        if (fragment.kind == .replaced) image = fragment.rect;
        if (fragment.background) |color| {
            if (color.green == 1 and color.red == 0) nested = fragment.rect;
        }
    }
    try std.testing.expectApproxEqAbs(@as(f32, 150), nested.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), image.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), image.?.height, 0.01);
}

test "Web flex baseline alignment and inline-flex intrinsic width" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;align-items:baseline;width:200px'>" ++
        "<div style='font-size:30px'>Large</div><div style='font-size:12px'>small</div></div>" ++
        "<p><span style='display:inline-flex;gap:5px;background:#00ff00'>" ++
        "<span style='flex:0 0 40px'>one</span><span style='flex:0 0 40px'>two</span></span></p>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200, .web_sizing = true });
    defer result.deinit(allocator);
    var large_baseline: ?f32 = null;
    var small_baseline: ?f32 = null;
    var inline_flex: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        if (fragment.text) |text| {
            if (std.mem.eql(u8, text, "Large")) large_baseline = fragment.rect.y + fragment.font_size * 0.8;
            if (std.mem.eql(u8, text, "small")) small_baseline = fragment.rect.y + fragment.font_size * 0.8;
        }
        if (fragment.background) |color| {
            if (color.green == 1 and color.red == 0) inline_flex = fragment.rect;
        }
    }
    try std.testing.expectApproxEqAbs(large_baseline.?, small_baseline.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 85), inline_flex.?.width, 0.1);
}

test "Web nowrap ignores align content and cross stretch honors max size" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;width:100px;height:100px;align-content:flex-end;align-items:flex-start'>" ++
        "<div style='width:30px;height:20px;background:#ff0000'>start</div></div>" ++
        "<div style='display:flex;width:100px;height:100px;align-items:stretch'>" ++
        "<div style='width:30px;max-height:60px;background:#0000ff'>capped</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .web_sizing = true });
    defer result.deinit(allocator);

    var start: ?geometry.Rect = null;
    var capped: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) start = fragment.rect;
        if (color.blue == 1 and color.red == 0) capped = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), start.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), capped.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), capped.?.height, 0.01);
}

test "Web flex wrap reverse and align content distribute lines on the cross axis" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;flex-wrap:wrap-reverse;align-content:space-between;width:210px;height:120px'>" ++
        "<div style='flex:0 0 100px;height:20px;background:#ff0000'>one</div>" ++
        "<div style='flex:0 0 100px;height:20px;background:#00ff00'>two</div>" ++
        "<div style='flex:0 0 100px;height:20px;background:#0000ff'>three</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 210, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    var third: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.green == 0) first = fragment.rect;
        if (color.green == 1 and color.red == 0) second = fragment.rect;
        if (color.blue == 1 and color.red == 0) third = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(first.?.y, second.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), third.?.y, 0.01);
}

test "Web flex row directions honor RTL main start" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;direction:rtl;width:200px'>" ++
        "<div style='flex:0 0 50px;background:#ff0000'>rtl row</div>" ++
        "<div style='flex:0 0 50px;background:#00ff00'>next</div></div>" ++
        "<div style='display:flex;direction:rtl;flex-direction:row-reverse;width:200px'>" ++
        "<div style='flex:0 0 50px;background:#0000ff'>rtl reverse</div>" ++
        "<div style='flex:0 0 50px;background:#ff00ff'>next</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 200, .web_sizing = true });
    defer result.deinit(allocator);

    var row_first: ?geometry.Rect = null;
    var row_second: ?geometry.Rect = null;
    var reverse_first: ?geometry.Rect = null;
    var reverse_second: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.green == 0 and color.blue == 0) row_first = fragment.rect;
        if (color.green == 1 and color.red == 0) row_second = fragment.rect;
        if (color.blue == 1 and color.red == 0) reverse_first = fragment.rect;
        if (color.red == 1 and color.blue == 1) reverse_second = fragment.rect;
    }
    try std.testing.expect(row_first.?.x > row_second.?.x);
    try std.testing.expect(reverse_first.?.x < reverse_second.?.x);
}

test "Web flex preserves partial grow free space and freezes max constraints" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;width:400px'>" ++
        "<div style='flex:0.25 0 100px;background:#ff0000'>quarter</div>" ++
        "<div style='flex:0.25 0 100px;background:#00ff00'>quarter</div></div>" ++
        "<div style='display:flex;width:500px'>" ++
        "<div style='flex:1 0 100px;max-width:120px;background:#0000ff'>capped</div>" ++
        "<div style='flex:1 0 100px;background:#ff00ff'>rest</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 500, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    var capped: ?geometry.Rect = null;
    var rest: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.green == 0 and color.blue == 0) first = fragment.rect;
        if (color.green == 1 and color.red == 0) second = fragment.rect;
        if (color.blue == 1 and color.red == 0) capped = fragment.rect;
        if (color.red == 1 and color.blue == 1) rest = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 150), first.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), second.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), @as(f32, 400) - second.?.x - second.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), capped.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 380), rest.?.width, 0.01);
}

test "Web flex auto margins absorb main and cross-axis free space" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:flex;width:300px;height:100px'>" ++
        "<div style='width:50px;height:20px;background:#ff0000'>brand</div>" ++
        "<div style='width:50px;height:20px;margin-left:auto;margin-top:auto;margin-bottom:auto;background:#0000ff'>actions</div>" ++
        "</div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var brand: ?geometry.Rect = null;
    var actions: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) brand = fragment.rect;
        if (color.blue == 1 and color.red == 0) actions = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), brand.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 250), actions.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), actions.?.y, 0.01);
}

test "Web flex wrapping advances intact lines to the next fragmentainer" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:45px'></div>" ++
        "<div style='display:flex;flex-wrap:wrap;width:100px;row-gap:5px'>" ++
        "<div style='flex:0 0 100px;height:30px;background:#ff0000'>first</div>" ++
        "<div style='flex:0 0 100px;height:30px;background:#0000ff'>second</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{
        .content_width = 100,
        .page_height = 60,
        .web_sizing = true,
    });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), second.?.y, 0.01);
}

test "Web column flex advances atomic items across fragmentainers" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:45px'></div>" ++
        "<div style='display:flex;flex-direction:column;width:100px;row-gap:5px'>" ++
        "<div style='flex:0 0 30px;background:#ff0000'>first</div>" ++
        "<div style='flex:0 0 30px;background:#0000ff'>second</div></div>" ++
        "<div style='height:10px;background:#00ff00'>after</div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{
        .content_width = 100,
        .page_height = 60,
        .web_sizing = true,
    });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    var after: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
        if (color.green == 1 and color.red == 0) after = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), second.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), after.?.y, 0.01);
}

test "Web Flex arbitrates avoid and facing-page breaks in order-modified flow" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:70px'></div>" ++
        "<div style='display:flex;flex-direction:column;width:100px'>" ++
        "<div style='flex:0 0 20px;break-after:avoid;background:#ff0000'>first</div>" ++
        "<div style='flex:0 0 20px;background:#0000ff'>second</div>" ++
        "<div style='flex:0 0 20px;break-before:right;background:#00ff00'>third</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 100, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    var third: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0 and color.green == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
        if (color.green == 1 and color.red == 0 and color.blue == 0) third = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), second.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), third.?.y, 0.01);
}

test "Web Grid lays out named areas fixed and flexible tracks" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:grid;width:300px;height:120px;grid-template-columns:100px 1fr;grid-template-rows:40px 1fr;grid-template-areas:&quot;head head&quot; &quot;side main&quot;;gap:10px'>" ++
        "<div style='grid-area:head;background:#ff0000'>header</div>" ++
        "<div style='grid-area:side;background:#00ff00'>side</div>" ++
        "<div style='grid-area:main;background:#0000ff'>main</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 300, .web_sizing = true });
    defer result.deinit(allocator);

    var header: ?geometry.Rect = null;
    var side: ?geometry.Rect = null;
    var main: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.green == 0) header = fragment.rect;
        if (color.green == 1 and color.red == 0) side = fragment.rect;
        if (color.blue == 1 and color.red == 0) main = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 300), header.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), header.?.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), side.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), side.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 110), main.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 190), main.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 70), main.?.height, 0.01);
}

test "Web Grid auto placement spans alignment and nested grids" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='display:grid;width:330px;grid-template-columns:repeat(3,minmax(0,1fr));grid-auto-rows:60px;gap:15px;align-items:center'>" ++
        "<div style='height:20px;justify-self:end;background:#ff0000'>one</div>" ++
        "<div style='grid-column:span 2;background:#00ff00'>span</div>" ++
        "<div style='display:grid;grid-template-columns:1fr 1fr;gap:4px;background:#0000ff'><span style='background:#ffff00'>a</span><span>b</span></div>" ++
        "<div style='background:#ff00ff'>four</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 330, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var spanning: ?geometry.Rect = null;
    var nested: ?geometry.Rect = null;
    var fourth: ?geometry.Rect = null;
    var nested_cell: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.green == 0 and color.blue == 0) first = fragment.rect;
        if (color.green == 1 and color.red == 0) spanning = fragment.rect;
        if (color.blue == 1 and color.red == 0) nested = fragment.rect;
        if (color.red == 1 and color.blue == 1) fourth = fragment.rect;
        if (color.red == 1 and color.green == 1 and color.blue == 0) nested_cell = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 20), first.?.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 215), spanning.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 95.4), nested.?.y, 0.1);
    try std.testing.expectApproxEqAbs(nested.?.y, fourth.?.y, 0.01);
    try std.testing.expect(nested_cell.?.width < nested.?.width / 2);
}

test "Web inline Grid uses track intrinsic width and preserves replaced ratios" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<p style='margin:0'><span style='display:inline-grid;grid-template-columns:40px 50px;column-gap:5px;background:#00ff00'><span>a</span><span>b</span></span><span>tail</span></p>" ++
        "<div style='display:grid;width:200px;grid-template-columns:minmax(0,1fr) minmax(0,1fr);grid-template-rows:100px'><img width='200' height='100'></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 220, .web_sizing = true });
    defer result.deinit(allocator);

    var inline_grid: ?geometry.Rect = null;
    var image: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        if (fragment.background) |color| {
            if (color.green == 1 and color.red == 0) inline_grid = fragment.rect;
        }
        if (fragment.kind == .replaced) image = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 95), inline_grid.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), image.?.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), image.?.height, 0.01);
}

test "Web Grid advances intact rows across fragmentainers" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:45px'></div>" ++
        "<div style='display:grid;width:100px;grid-template-columns:1fr;grid-auto-rows:30px;row-gap:5px'>" ++
        "<div style='background:#ff0000'>first</div><div style='background:#0000ff'>second</div></div>" ++
        "<div style='height:10px;background:#00ff00'>after</div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 60, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    var after: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
        if (color.green == 1 and color.red == 0) after = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 120), second.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), after.?.y, 0.01);
}

test "Web Grid keeps avoid-linked rows together" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style='height:30px'></div>" ++
        "<div style='display:grid;width:100px;grid-template-columns:1fr;grid-auto-rows:20px'>" ++
        "<div style='break-after:avoid;background:#ff0000'>first</div>" ++
        "<div style='background:#0000ff'>second</div></div>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{ .content_width = 100, .page_height = 60, .web_sizing = true });
    defer result.deinit(allocator);

    var first: ?geometry.Rect = null;
    var second: ?geometry.Rect = null;
    for (result.fragments.items) |fragment| {
        const color = fragment.background orelse continue;
        if (color.red == 1 and color.blue == 0) first = fragment.rect;
        if (color.blue == 1 and color.red == 0) second = fragment.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 60), first.?.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), second.?.y, 0.01);
}

test "orphans move a paragraph that would leave one line at page bottom" {
    const html = @import("html.zig");
    const css = @import("css.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        "<div style=\"height:45px\"></div>" ++
        "<p style=\"margin:0;line-height:18px;orphans:2;width:70px\">one two three four five six seven eight</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer tokens.deinit(allocator);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);
    const styles = try css.styleArrayFromDocument(allocator, &document);
    var tree = try box.Builder.build(allocator, &document, styles, document.root);
    defer tree.deinit(allocator);
    var result = try layout(allocator, &tree, &document, .{
        .content_width = 200,
        .page_height = 60,
    });
    defer result.deinit(allocator);

    var first_text_y: ?f32 = null;
    for (result.fragments.items) |fragment| {
        if (fragment.kind != .text or fragment.line_id == null) continue;
        first_text_y = if (first_text_y) |current| @min(current, fragment.rect.y) else fragment.rect.y;
    }
    try std.testing.expect(first_text_y != null);
    try std.testing.expect(first_text_y.? >= 60);
}
