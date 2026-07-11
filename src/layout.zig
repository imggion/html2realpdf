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

const InlineCursor = inline_context.Cursor(State);

pub fn layout(
    allocator: std.mem.Allocator,
    tree: *const box.BoxTree,
    document: *const dom.Document,
    options: Options,
) !LayoutDocument {
    var state = State{
        .allocator = allocator,
        .tree = tree,
        .document = document,
        .fragments = try std.ArrayList(Fragment).initCapacity(allocator, tree.boxes.items.len),
        .page_height = options.page_height,
        .font_registry = options.font_registry,
        .shaping_mode = options.shaping_mode,
    };
    errdefer state.fragments.deinit(allocator);

    var cursor_y: f32 = 0;
    const containing = geometry.Rect{
        .width = @max(options.content_width, 1),
        .height = 0,
    };
    _ = try state.layoutBlock(tree.root, containing, &cursor_y);

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
        const fragment_start = self.fragments.items.len;
        const rect = try block.layout(self, box_id, containing, cursor_y);
        return self.finishBlockLayout(box_id, containing, cursor_y, fragment_start, rect);
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
        return self.finishBlockLayout(box_id, containing, cursor_y, fragment_start, rect);
    }

    fn finishBlockLayout(
        self: *State,
        box_id: box.BoxId,
        containing: geometry.Rect,
        cursor_y: *f32,
        fragment_start: usize,
        raw_rect: geometry.Rect,
    ) geometry.Rect {
        const source = self.tree.boxes.items[box_id];
        const style = source.style;
        if (!style.overflow.clips() or fragment_start >= self.fragments.items.len) return raw_rect;

        var rect = raw_rect;
        const vertical_edges = source.border.top + source.border.bottom + source.padding.top + source.padding.bottom;
        if (intrinsic.resolveContentDimension(style.height, containing.height, vertical_edges, style.box_sizing)) |requested_content_height| {
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
        for (self.fragments.items[fragment_start + 1 ..]) |*fragment| {
            fragment.clip_rect = if (fragment.clip_rect) |existing|
                existing.intersection(clip) orelse geometry.Rect{ .x = clip.x, .y = clip.y }
            else
                clip;
        }
        return rect;
    }

    pub fn advanceToNextPage(self: *const State, cursor_y: *f32) void {
        const page_height = self.page_height orelse return;
        const page_y = @mod(cursor_y.*, page_height);
        if (page_y > 0) cursor_y.* += page_height - page_y;
    }

    pub fn enforceLineConstraints(
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
            if (block.isBlockLevel(child_box.kind)) return true;
            child = child_box.next_sibling;
        }
        return false;
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

    pub fn listMarkerForBox(self: *const State, box_id: box.BoxId) !?[]const u8 {
        const node_id = self.tree.boxes.items[box_id].node orelse return null;
        const node = self.document.nodes.items[node_id];
        const element = switch (node.kind) {
            .element => |value| value,
            else => return null,
        };
        if (element.tag != .li) return null;

        const parent_id = node.parent orelse return "•";
        const parent = self.document.nodes.items[parent_id];
        const parent_element = switch (parent.kind) {
            .element => |value| value,
            else => return "•",
        };
        if (parent_element.tag != .ol) return "•";

        for (element.attributes) |attribute| {
            if (!std.ascii.eqlIgnoreCase(attribute.name, "value")) continue;
            const value = attribute.value orelse break;
            const explicit = std.fmt.parseInt(usize, value, 10) catch break;
            return try std.fmt.allocPrint(self.allocator, "{d}.", .{explicit});
        }

        var item_number: usize = 1;
        for (parent_element.attributes) |attribute| {
            if (!std.ascii.eqlIgnoreCase(attribute.name, "start")) continue;
            const value = attribute.value orelse break;
            item_number = std.fmt.parseInt(usize, value, 10) catch 1;
            break;
        }
        var sibling = node.prev_sibling;
        while (sibling) |sibling_id| {
            const sibling_node = self.document.nodes.items[sibling_id];
            if (sibling_node.kind == .element and sibling_node.kind.element.tag == .li) item_number += 1;
            sibling = sibling_node.prev_sibling;
        }
        return try std.fmt.allocPrint(self.allocator, "{d}.", .{item_number});
    }

    pub fn layoutInlineChildren(
        self: *State,
        parent_id: box.BoxId,
        start_x: f32,
        start_y: f32,
        width: f32,
        text_align: box.TextAlign,
    ) !f32 {
        const style = self.tree.boxes.items[parent_id].style;
        const text_indent = style.text_indent.resolve(width) orelse 0;
        const ellipsis_enabled = style.text_overflow == .ellipsis and style.overflow.clips();
        var cursor = InlineCursor.init(self, start_x, start_y, width, text_align, style.direction, text_indent, ellipsis_enabled);
        var child = self.tree.boxes.items[parent_id].first_child;
        while (child) |child_id| {
            try cursor.layoutBox(child_id, null, .baseline);
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
