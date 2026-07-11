//! Block and inline layout for the renderer pipeline.
//!
//! The Box Tree remains structural. This module creates a separate flat list of
//! fragments because one source box can eventually produce multiple line and
//! page fragments.

const std = @import("std");
const box = @import("box.zig");
const dom = @import("dom.zig");
const font = @import("font.zig");
const geometry = @import("geometry.zig");

pub const FragmentId = usize;

pub const FragmentKind = enum {
    box,
    text,
    replaced,
};

pub const BorderPaint = struct {
    top_style: box.BorderStyle = .solid,
    right_style: box.BorderStyle = .solid,
    bottom_style: box.BorderStyle = .solid,
    left_style: box.BorderStyle = .solid,
    top_color: geometry.Color = geometry.Color.black,
    right_color: geometry.Color = geometry.Color.black,
    bottom_color: geometry.Color = geometry.Color.black,
    left_color: geometry.Color = geometry.Color.black,
};

pub const Fragment = struct {
    kind: FragmentKind,
    source_box: box.BoxId,
    rect: geometry.Rect,
    line_id: ?usize = null,
    inline_container_line_id: ?usize = null,
    text: ?[]const u8 = null,
    leading_space: bool = false,
    font_size: f32 = 16,
    font_family: []const u8 = "Noto Sans",
    letter_spacing: f32 = 0,
    font_weight: box.FontWeight = .normal,
    font_style: box.FontStyle = .normal,
    color: geometry.Color = geometry.Color.black,
    text_decoration: box.TextDecoration = .none,
    background: ?geometry.Color = null,
    border: box.EdgeSizes = .{},
    border_paint: BorderPaint = .{},
    border_radius: f32 = 0,
    page_break_before: box.PageBreak = .auto,
    page_break_after: box.PageBreak = .auto,
    page_break_inside: box.PageBreak = .auto,
    link_url: ?[]const u8 = null,
    image_source: ?[]const u8 = null,
    table_id: ?box.BoxId = null,
    is_table_header: bool = false,
};

pub const LayoutDocument = struct {
    fragments: std.ArrayList(Fragment),
    content_width: f32,
    content_height: f32,

    pub fn deinit(self: *LayoutDocument, allocator: std.mem.Allocator) void {
        self.fragments.deinit(allocator);
    }
};

pub const Options = struct {
    content_width: f32,
    page_height: ?f32 = null,
    font_registry: ?*const font.Registry = null,
};

/// Lays out a Box Tree in a continuous vertical canvas. Pagination consumes
/// these line- and box-level fragments without mutating the Box Tree.
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
    next_line_id: usize = 0,

    const BlockLayoutOptions = struct {
        fill_available_width: bool = false,
    };

    fn layoutBlock(
        self: *State,
        box_id: box.BoxId,
        containing: geometry.Rect,
        cursor_y: *f32,
    ) std.mem.Allocator.Error!geometry.Rect {
        return self.layoutBlockWithOptions(box_id, containing, cursor_y, .{});
    }

    fn layoutBlockWithOptions(
        self: *State,
        box_id: box.BoxId,
        containing: geometry.Rect,
        cursor_y: *f32,
        options: BlockLayoutOptions,
    ) std.mem.Allocator.Error!geometry.Rect {
        const source = self.tree.boxes.items[box_id];
        const style = source.style;
        const margin = source.margin;
        const border = source.border;
        const padding = source.padding;

        if (style.page_break_before == .always) self.advanceToNextPage(cursor_y);

        const fragment_start = self.fragments.items.len;
        const outer_x = containing.x + margin.left;
        const available_outer_width = @max(containing.width - margin.left - margin.right, 1);
        const horizontal_non_content = border.left + border.right + padding.left + padding.right;
        var requested_content_width = if (options.fill_available_width)
            @max(available_outer_width - horizontal_non_content, 1)
        else
            resolveContentDimension(style.width, available_outer_width, horizontal_non_content, style.box_sizing) orelse @max(available_outer_width - horizontal_non_content, 1);
        if (!options.fill_available_width) {
            if (resolveContentDimension(style.min_width, available_outer_width, horizontal_non_content, style.box_sizing)) |minimum| requested_content_width = @max(requested_content_width, minimum);
            if (resolveContentDimension(style.max_width, available_outer_width, horizontal_non_content, style.box_sizing)) |maximum| requested_content_width = @min(requested_content_width, maximum);
        }
        const content_width = @max(@min(requested_content_width, available_outer_width - horizontal_non_content), 1);
        const outer_width = @min(content_width + horizontal_non_content, available_outer_width);
        var outer_y = cursor_y.* + margin.top;

        const fragment_id = self.fragments.items.len;
        try self.fragments.append(self.allocator, .{
            .kind = if (source.kind == .replaced) .replaced else .box,
            .source_box = box_id,
            .rect = .{ .x = outer_x, .y = outer_y, .width = outer_width },
            .background = if (style.background) |value| geometry.parseColor(value) else null,
            .border = border,
            .border_paint = borderPaint(style),
            .border_radius = style.border_radius,
            .page_break_before = style.page_break_before,
            .page_break_after = style.page_break_after,
            .page_break_inside = style.page_break_inside,
            .image_source = if (source.kind == .replaced) self.attributeForBox(box_id, "src") else null,
        });

        const content_x = outer_x + border.left + padding.left;
        const content_y = outer_y + border.top + padding.top;
        var child_cursor_y = content_y;

        if (try self.listMarkerForBox(box_id)) |marker| {
            try self.fragments.append(self.allocator, .{
                .kind = .text,
                .source_box = box_id,
                .rect = .{
                    .x = @max(content_x - style.font_size * 1.25, containing.x),
                    .y = content_y,
                    .width = measureText(self.font_registry, marker, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing),
                    .height = @max(style.line_height, style.font_size * 1.2),
                },
                .text = marker,
                .font_size = style.font_size,
                .font_family = style.font_family,
                .letter_spacing = style.letter_spacing,
                .font_weight = style.font_weight,
                .font_style = style.font_style,
                .color = geometry.parseColor(style.color) orelse geometry.Color.black,
                .text_decoration = style.text_decoration,
            });
        }

        if (source.kind == .replaced) {
            const intrinsic_height = source.intrinsic_height orelse source.style.height.resolve(containing.height) orelse source.intrinsic_width orelse 24;
            child_cursor_y += intrinsic_height;
        } else if (source.kind == .table) {
            child_cursor_y += try self.layoutTable(box_id, content_x, content_y, content_width);
        } else if (source.first_child) |_| {
            if (self.hasBlockChildren(box_id)) {
                var previous_bottom_margin: f32 = 0;
                var child = source.first_child;
                while (child) |child_id| {
                    const child_box = self.tree.boxes.items[child_id];
                    if (isBlockLevel(child_box.kind)) {
                        const collapsed = collapseMargins(previous_bottom_margin, child_box.margin.top);
                        child_cursor_y -= previous_bottom_margin + child_box.margin.top - collapsed;
                        _ = try self.layoutBlock(
                            child_id,
                            .{ .x = content_x, .y = content_y, .width = content_width },
                            &child_cursor_y,
                        );
                        previous_bottom_margin = child_box.margin.bottom;
                    } else {
                        const run_height = try self.layoutInlineRun(child_id, content_x, child_cursor_y, content_width, style.text_align);
                        child_cursor_y += run_height;
                        previous_bottom_margin = 0;
                    }
                    child = child_box.next_sibling;
                }
            } else {
                const inline_height = try self.layoutInlineChildren(box_id, content_x, content_y, content_width, style.text_align);
                child_cursor_y += inline_height;
            }
        }

        const vertical_non_content = border.top + border.bottom + padding.top + padding.bottom;
        var content_height = @max(child_cursor_y - content_y, 0);
        if (resolveContentDimension(style.height, containing.height, vertical_non_content, style.box_sizing)) |height| content_height = @max(content_height, height);
        if (resolveContentDimension(style.min_height, containing.height, vertical_non_content, style.box_sizing)) |minimum| content_height = @max(content_height, minimum);
        if (resolveContentDimension(style.max_height, containing.height, vertical_non_content, style.box_sizing)) |maximum| content_height = @min(content_height, maximum);
        if (source.kind == .replaced) {
            content_height = @max(content_height, source.intrinsic_height orelse 24);
        }

        var outer_height = border.top + padding.top + content_height + padding.bottom + border.bottom;
        if (!self.hasBlockChildren(box_id)) {
            try self.enforceLineConstraints(fragment_start, &outer_y, &outer_height, style.orphans, style.widows);
        }

        if (style.page_break_inside == .avoid) {
            if (self.page_height) |page_height| {
                const page_y = @mod(outer_y, page_height);
                if (outer_height <= page_height and page_y > 0 and page_y + outer_height > page_height) {
                    const shift = page_height - page_y;
                    for (self.fragments.items[fragment_start..]) |*fragment| fragment.rect.y += shift;
                    outer_y += shift;
                }
            }
        }

        self.fragments.items[fragment_id].rect.height = outer_height;

        cursor_y.* = outer_y + outer_height + margin.bottom;
        if (style.page_break_after == .always) self.advanceToNextPage(cursor_y);
        return self.fragments.items[fragment_id].rect;
    }

    fn advanceToNextPage(self: *const State, cursor_y: *f32) void {
        const page_height = self.page_height orelse return;
        const page_y = @mod(cursor_y.*, page_height);
        if (page_y > 0) cursor_y.* += page_height - page_y;
    }

    fn enforceLineConstraints(
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

    fn hasBlockChildren(self: *const State, box_id: box.BoxId) bool {
        var child = self.tree.boxes.items[box_id].first_child;
        while (child) |child_id| {
            const child_box = self.tree.boxes.items[child_id];
            if (isBlockLevel(child_box.kind)) return true;
            child = child_box.next_sibling;
        }
        return false;
    }

    fn layoutTable(
        self: *State,
        table_id: box.BoxId,
        start_x: f32,
        start_y: f32,
        width: f32,
    ) !f32 {
        var rows = try std.ArrayList(box.BoxId).initCapacity(self.allocator, 0);
        defer rows.deinit(self.allocator);
        try self.collectTableRows(table_id, &rows);
        if (rows.items.len == 0) return 0;

        const column_count = try self.tableGridColumnCount(rows.items);
        const column_widths = try self.tableColumnWidths(rows.items, column_count, width);
        defer self.allocator.free(column_widths);
        var row_y = start_y;
        var header_template_start: ?usize = null;
        var header_template_end: usize = 0;
        var header_start_y: f32 = 0;
        var header_height: f32 = 0;
        var last_repeated_page: ?usize = null;
        const ActiveSpan = struct { remaining: usize = 0, fragment_id: ?FragmentId = null };
        const NewSpan = struct { first_column: usize, column_span: usize, row_span: usize, fragment_id: FragmentId };
        const active_spans = try self.allocator.alloc(ActiveSpan, column_count);
        defer self.allocator.free(active_spans);
        @memset(active_spans, ActiveSpan{});
        const occupied = try self.allocator.alloc(bool, column_count);
        defer self.allocator.free(occupied);

        const collapse_borders = self.tree.boxes.items[table_id].style.border_collapse == .collapse;
        for (rows.items, 0..) |row_id, row_index| {
            const is_header_row = self.isTableHeaderRow(row_id);
            const row_start_fragment = self.fragments.items.len;
            const row_source = self.tree.boxes.items[row_id];
            const row_fragment_id = self.fragments.items.len;
            try self.fragments.append(self.allocator, .{
                .kind = .box,
                .source_box = row_id,
                .rect = .{ .x = start_x, .y = row_y, .width = width },
                .background = if (row_source.style.background) |value| geometry.parseColor(value) else null,
                .border = row_source.border,
                .border_paint = borderPaint(row_source.style),
                .border_radius = row_source.style.border_radius,
                .page_break_before = row_source.style.page_break_before,
                .page_break_after = row_source.style.page_break_after,
                .page_break_inside = row_source.style.page_break_inside,
            });

            var row_height: f32 = 0;
            var column_index: usize = 0;
            var cell_roots = try std.ArrayList(FragmentId).initCapacity(self.allocator, column_count);
            defer cell_roots.deinit(self.allocator);
            var new_spans = try std.ArrayList(NewSpan).initCapacity(self.allocator, 0);
            defer new_spans.deinit(self.allocator);
            var old_span_roots = try std.ArrayList(FragmentId).initCapacity(self.allocator, 0);
            defer old_span_roots.deinit(self.allocator);
            for (active_spans, 0..) |active, index| {
                occupied[index] = active.remaining > 0;
                const root = active.fragment_id orelse continue;
                var already_added = false;
                for (old_span_roots.items) |existing| if (existing == root) {
                    already_added = true;
                    break;
                };
                if (!already_added) try old_span_roots.append(self.allocator, root);
            }

            var cell = row_source.first_child;
            while (cell) |cell_id| {
                const cell_source = self.tree.boxes.items[cell_id];
                if (cell_source.kind == .tableCell) {
                    const span = self.tableCellSpan(cell_id);
                    const row_span = self.tableCellRowSpan(cell_id);
                    column_index = findFreeColumns(occupied, column_index, span);
                    if (column_index + span > column_count) break;
                    var cell_x = start_x;
                    for (column_widths[0..column_index]) |track_width| cell_x += track_width;
                    var cell_width: f32 = 0;
                    for (column_widths[column_index .. column_index + span]) |track_width| cell_width += track_width;
                    var cell_cursor = row_y;
                    const cell_fragment_id = self.fragments.items.len;
                    _ = try self.layoutBlockWithOptions(
                        cell_id,
                        .{
                            .x = cell_x,
                            .y = row_y,
                            .width = cell_width,
                        },
                        &cell_cursor,
                        .{ .fill_available_width = true },
                    );
                    if (collapse_borders) {
                        if (column_index > 0) self.fragments.items[cell_fragment_id].border.left = 0;
                        if (row_index > 0) self.fragments.items[cell_fragment_id].border.top = 0;
                    }
                    try cell_roots.append(self.allocator, cell_fragment_id);
                    for (occupied[column_index .. column_index + span]) |*slot| slot.* = true;
                    if (row_span > 1) try new_spans.append(self.allocator, .{
                        .first_column = column_index,
                        .column_span = span,
                        .row_span = row_span,
                        .fragment_id = cell_fragment_id,
                    });
                    row_height = @max(row_height, cell_cursor - row_y);
                    column_index += span;
                }
                cell = cell_source.next_sibling;
            }

            row_height = @max(row_height, row_source.style.height.resolve(self.page_height orelse 0) orelse 1);
            self.fragments.items[row_fragment_id].rect.height = row_height;
            for (cell_roots.items) |fragment_id| {
                self.fragments.items[fragment_id].rect.height = @max(self.fragments.items[fragment_id].rect.height, row_height);
            }
            for (self.fragments.items[row_start_fragment..]) |*fragment| {
                fragment.table_id = table_id;
                fragment.is_table_header = is_header_row;
            }

            if (self.page_height) |page_height| {
                const page_y = @mod(row_y, page_height);
                if (row_height <= page_height and page_y > 0 and page_y + row_height > page_height) {
                    const target_page_start = row_y + page_height - page_y;
                    const target_page: usize = @intFromFloat(@floor(target_page_start / page_height));
                    const should_repeat_header = !is_header_row and
                        header_template_start != null and
                        header_height + row_height <= page_height and
                        last_repeated_page != target_page;
                    const shift = page_height - page_y + (if (should_repeat_header) header_height else 0);
                    for (self.fragments.items[row_start_fragment..]) |*fragment| fragment.rect.y += shift;
                    row_y += shift;
                    if (should_repeat_header) {
                        try self.cloneTableHeader(
                            header_template_start.?,
                            header_template_end,
                            header_start_y,
                            target_page_start,
                        );
                        last_repeated_page = target_page;
                    }
                }
            }

            if (is_header_row) {
                if (header_template_start == null) {
                    header_template_start = row_start_fragment;
                    header_start_y = row_y;
                }
                header_template_end = self.fragments.items.len;
                header_height = row_y + row_height - header_start_y;
            }

            for (old_span_roots.items) |fragment_id| {
                const fragment = &self.fragments.items[fragment_id];
                fragment.rect.height = @max(fragment.rect.height, row_y + row_height - fragment.rect.y);
            }
            for (active_spans) |*active| {
                if (active.remaining > 0) active.remaining -= 1;
                if (active.remaining == 0) active.fragment_id = null;
            }
            for (new_spans.items) |new_span| {
                for (active_spans[new_span.first_column .. new_span.first_column + new_span.column_span]) |*active| {
                    active.* = .{
                        .remaining = new_span.row_span - 1,
                        .fragment_id = new_span.fragment_id,
                    };
                }
            }

            row_y += row_height;
        }

        return row_y - start_y;
    }

    fn cloneTableHeader(
        self: *State,
        start: usize,
        end: usize,
        source_y: f32,
        target_y: f32,
    ) !void {
        const count = end - start;
        const copies = try self.allocator.alloc(Fragment, count);
        defer self.allocator.free(copies);
        @memcpy(copies, self.fragments.items[start..end]);
        for (copies) |*fragment| fragment.rect.y = target_y + fragment.rect.y - source_y;
        try self.fragments.appendSlice(self.allocator, copies);
    }

    fn isTableHeaderRow(self: *const State, row_id: box.BoxId) bool {
        const parent_id = self.tree.boxes.items[row_id].parent orelse return false;
        const parent = self.tree.boxes.items[parent_id];
        if (parent.kind != .tableRowGroup) return false;
        const node_id = parent.node orelse return false;
        const node = self.document.nodes.items[node_id];
        return node.kind == .element and std.ascii.eqlIgnoreCase(node.kind.element.name, "thead");
    }

    fn collectTableRows(self: *State, parent_id: box.BoxId, rows: *std.ArrayList(box.BoxId)) !void {
        var child = self.tree.boxes.items[parent_id].first_child;
        while (child) |child_id| {
            const child_box = self.tree.boxes.items[child_id];
            switch (child_box.kind) {
                .tableRow, .anonymousTableRow => try rows.append(self.allocator, child_id),
                .tableRowGroup => try self.collectTableRows(child_id, rows),
                else => {},
            }
            child = child_box.next_sibling;
        }
    }

    /// Resolve table-cell width hints into final track widths before laying out
    /// cell contents. Percentage hints are relative to the table, not to the
    /// already allocated track that will later contain the cell.
    fn tableColumnWidths(self: *State, rows: []const box.BoxId, column_count: usize, table_width: f32) ![]f32 {
        const widths = try self.allocator.alloc(f32, column_count);
        errdefer self.allocator.free(widths);
        @memset(widths, 0);

        const active = try self.allocator.alloc(usize, column_count);
        defer self.allocator.free(active);
        @memset(active, 0);

        for (rows) |row_id| {
            var column: usize = 0;
            var child = self.tree.boxes.items[row_id].first_child;
            while (child) |child_id| {
                const child_box = self.tree.boxes.items[child_id];
                if (child_box.kind == .tableCell) {
                    const span = self.tableCellSpan(child_id);
                    while (column < column_count and active[column] > 0) column += 1;
                    while (column + span <= column_count) {
                        var free = true;
                        for (active[column .. column + span]) |remaining| if (remaining > 0) {
                            free = false;
                            break;
                        };
                        if (free) break;
                        column += 1;
                        while (column < column_count and active[column] > 0) column += 1;
                    }
                    if (column + span > column_count) break;

                    if (tableCellOuterWidthHint(child_box, table_width)) |hint| {
                        const track_hint = hint / @as(f32, @floatFromInt(span));
                        for (widths[column .. column + span]) |*track_width| {
                            track_width.* = @max(track_width.*, track_hint);
                        }
                    }

                    const row_span = self.tableCellRowSpan(child_id);
                    for (active[column .. column + span]) |*remaining| {
                        remaining.* = @max(remaining.*, row_span);
                    }
                    column += span;
                }
                child = child_box.next_sibling;
            }
            for (active) |*remaining| {
                if (remaining.* > 0) remaining.* -= 1;
            }
        }

        var hinted_total: f32 = 0;
        var unhinted_count: usize = 0;
        for (widths) |track_width| {
            hinted_total += track_width;
            if (track_width == 0) unhinted_count += 1;
        }

        if (hinted_total < table_width) {
            const recipient_count = if (unhinted_count > 0) unhinted_count else column_count;
            const extra = (table_width - hinted_total) / @as(f32, @floatFromInt(recipient_count));
            for (widths) |*track_width| {
                if (unhinted_count == 0 or track_width.* == 0) track_width.* += extra;
            }
        }

        var actual_total: f32 = 0;
        for (widths) |*track_width| {
            track_width.* = @max(track_width.*, 1);
            actual_total += track_width.*;
        }
        const scale = table_width / actual_total;
        for (widths) |*track_width| track_width.* *= scale;
        return widths;
    }

    fn tableCellOuterWidthHint(cell: box.Box, table_width: f32) ?f32 {
        return switch (cell.style.width) {
            .auto => null,
            .percent => |ratio| @max(table_width * ratio, 0),
            .px => {
                const horizontal_edges = cell.border.left + cell.border.right + cell.padding.left + cell.padding.right;
                const content_width = resolveContentDimension(cell.style.width, table_width, horizontal_edges, cell.style.box_sizing) orelse return null;
                return content_width + horizontal_edges;
            },
        };
    }

    fn tableGridColumnCount(self: *State, rows: []const box.BoxId) !usize {
        var active = try std.ArrayList(usize).initCapacity(self.allocator, 0);
        defer active.deinit(self.allocator);
        var maximum: usize = 1;

        for (rows) |row_id| {
            var column: usize = 0;
            var child = self.tree.boxes.items[row_id].first_child;
            while (child) |child_id| {
                const child_box = self.tree.boxes.items[child_id];
                if (child_box.kind == .tableCell) {
                    const column_span = self.tableCellSpan(child_id);
                    while (true) {
                        while (column < active.items.len and active.items[column] > 0) column += 1;
                        if (column + column_span > active.items.len) {
                            const old_len = active.items.len;
                            try active.resize(self.allocator, column + column_span);
                            @memset(active.items[old_len..], 0);
                        }
                        var free = true;
                        for (active.items[column .. column + column_span]) |remaining| if (remaining > 0) {
                            free = false;
                            break;
                        };
                        if (free) break;
                        column += 1;
                    }
                    const row_span = self.tableCellRowSpan(child_id);
                    for (active.items[column .. column + column_span]) |*remaining| remaining.* = row_span;
                    column += column_span;
                    maximum = @max(maximum, column);
                }
                child = child_box.next_sibling;
            }
            for (active.items) |*remaining| if (remaining.* > 0) {
                remaining.* -= 1;
            };
        }
        return maximum;
    }

    fn tableCellSpan(self: *const State, cell_id: box.BoxId) usize {
        return self.tableCellIntegerAttribute(cell_id, "colspan");
    }

    fn tableCellRowSpan(self: *const State, cell_id: box.BoxId) usize {
        return self.tableCellIntegerAttribute(cell_id, "rowspan");
    }

    fn tableCellIntegerAttribute(self: *const State, cell_id: box.BoxId, name: []const u8) usize {
        const node_id = self.tree.boxes.items[cell_id].node orelse return 1;
        const node = self.document.nodes.items[node_id];
        const element = switch (node.kind) {
            .element => |value| value,
            else => return 1,
        };

        for (element.attributes) |attribute| {
            if (!std.ascii.eqlIgnoreCase(attribute.name, name)) continue;
            const value = attribute.value orelse return 1;
            const parsed = std.fmt.parseInt(usize, value, 10) catch return 1;
            return std.math.clamp(parsed, 1, 1000);
        }
        return 1;
    }

    fn linkForBox(self: *const State, box_id: box.BoxId) ?[]const u8 {
        const node_id = self.tree.boxes.items[box_id].node orelse return null;
        const node = self.document.nodes.items[node_id];
        const element = switch (node.kind) {
            .element => |value| value,
            else => return null,
        };
        if (element.tag != .a) return null;

        return self.attributeForBox(box_id, "href");
    }

    fn attributeForBox(self: *const State, box_id: box.BoxId, name: []const u8) ?[]const u8 {
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

    fn listMarkerForBox(self: *const State, box_id: box.BoxId) !?[]const u8 {
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

    fn layoutInlineChildren(
        self: *State,
        parent_id: box.BoxId,
        start_x: f32,
        start_y: f32,
        width: f32,
        text_align: box.TextAlign,
    ) !f32 {
        var cursor = InlineCursor.init(self, start_x, start_y, width, text_align);
        var child = self.tree.boxes.items[parent_id].first_child;
        while (child) |child_id| {
            try cursor.layoutBox(child_id, null);
            child = self.tree.boxes.items[child_id].next_sibling;
        }
        return cursor.finish();
    }

    fn layoutInlineRun(
        self: *State,
        first_box: box.BoxId,
        start_x: f32,
        start_y: f32,
        width: f32,
        text_align: box.TextAlign,
    ) !f32 {
        var cursor = InlineCursor.init(self, start_x, start_y, width, text_align);
        try cursor.layoutBox(first_box, null);
        return cursor.finish();
    }
};

const InlineCursor = struct {
    state: *State,
    start_x: f32,
    start_y: f32,
    line_y: f32,
    width: f32,
    x: f32,
    line_height: f32,
    text_align: box.TextAlign,
    line_start_fragment: usize,
    line_id: usize,
    has_content: bool = false,
    pending_space: bool = false,

    fn init(state: *State, start_x: f32, start_y: f32, width: f32, text_align: box.TextAlign) InlineCursor {
        const line_id = state.next_line_id;
        state.next_line_id += 1;
        return .{
            .state = state,
            .start_x = start_x,
            .start_y = start_y,
            .line_y = start_y,
            .width = @max(width, 1),
            .x = start_x,
            .line_height = 0,
            .text_align = text_align,
            .line_start_fragment = state.fragments.items.len,
            .line_id = line_id,
        };
    }

    fn layoutBox(self: *InlineCursor, box_id: box.BoxId, inherited_link: ?[]const u8) !void {
        const source = self.state.tree.boxes.items[box_id];
        const link_url = self.state.linkForBox(box_id) orelse inherited_link;
        if (source.style.page_break_before == .always) self.forcePageBreak();
        switch (source.kind) {
            .text => if (source.text) |text| try self.layoutText(box_id, text, source.style, link_url),
            .lineBreak => self.newLine(),
            .replaced => try self.layoutAtomic(box_id, source, link_url),
            .inlineBlock => try self.layoutInlineBlock(box_id, source),
            .inlineBox, .anonymousInline => {
                var child = source.first_child;
                while (child) |child_id| {
                    try self.layoutBox(child_id, link_url);
                    child = self.state.tree.boxes.items[child_id].next_sibling;
                }
            },
            else => {},
        }
        if (source.style.page_break_after == .always) self.forcePageBreak();
    }

    /// Finish the current inline line and place the next fragment at the top of
    /// the following page. Selector-driven page break rules must work for
    /// replaced and inline elements as well as block boxes.
    fn forcePageBreak(self: *InlineCursor) void {
        const page_height = self.state.page_height orelse return;
        if (self.has_content) {
            self.alignCurrentLine(false);
            self.line_y += if (self.line_height > 0) self.line_height else 18;
        }
        const page_y = @mod(self.line_y, page_height);
        if (page_y > 0) self.line_y += page_height - page_y;
        self.x = self.start_x;
        self.line_height = 0;
        self.line_start_fragment = self.state.fragments.items.len;
        self.line_id = self.state.next_line_id;
        self.state.next_line_id += 1;
        self.has_content = false;
        self.pending_space = false;
    }

    fn layoutText(self: *InlineCursor, box_id: box.BoxId, text: []const u8, style: box.Style, link_url: ?[]const u8) !void {
        switch (style.white_space) {
            .normal => try self.layoutCollapsedText(box_id, text, style, link_url, true),
            .nowrap => try self.layoutCollapsedText(box_id, text, style, link_url, false),
            .preLine => try self.layoutPreLineText(box_id, text, style, link_url),
            .pre => try self.layoutPreservedText(box_id, text, style, link_url, false),
            .preWrap => try self.layoutPreservedText(box_id, text, style, link_url, true),
        }
    }

    fn layoutCollapsedText(
        self: *InlineCursor,
        box_id: box.BoxId,
        text: []const u8,
        style: box.Style,
        link_url: ?[]const u8,
        allow_wrap: bool,
    ) !void {
        var index: usize = 0;
        var saw_space = self.pending_space;
        self.pending_space = false;

        while (index < text.len) {
            while (index < text.len and isHtmlWhitespace(text[index])) : (index += 1) {
                saw_space = true;
            }
            if (index >= text.len) break;

            const word_start = index;
            while (index < text.len and !isHtmlWhitespace(text[index])) : (index += 1) {}
            const word = text[word_start..index];
            const word_width = measureText(self.state.font_registry, word, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
            var leading_space = saw_space and self.has_content;
            var space_width = if (leading_space) measureText(self.state.font_registry, " ", style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing) else 0;

            if (allow_wrap and self.has_content and self.x + space_width + word_width > self.start_x + self.width) {
                self.newLine();
                leading_space = false;
                space_width = 0;
            }

            try self.appendTextFragment(box_id, word, space_width + word_width, leading_space, style, link_url);
            saw_space = false;
        }
        self.pending_space = saw_space;
    }

    fn layoutPreLineText(self: *InlineCursor, box_id: box.BoxId, text: []const u8, style: box.Style, link_url: ?[]const u8) !void {
        var start: usize = 0;
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] != '\n' and text[index] != '\r') {
                index += 1;
                continue;
            }
            try self.layoutCollapsedText(box_id, text[start..index], style, link_url, true);
            self.pending_space = false;
            self.newLine();
            if (text[index] == '\r' and index + 1 < text.len and text[index + 1] == '\n') index += 1;
            index += 1;
            start = index;
        }
        try self.layoutCollapsedText(box_id, text[start..], style, link_url, true);
    }

    fn layoutPreservedText(
        self: *InlineCursor,
        box_id: box.BoxId,
        text: []const u8,
        style: box.Style,
        link_url: ?[]const u8,
        allow_wrap: bool,
    ) !void {
        self.pending_space = false;
        var chunk_start: usize = 0;
        var chunk_width: f32 = 0;
        var index: usize = 0;
        while (index < text.len) {
            const byte = text[index];
            if (byte == '\n' or byte == '\r') {
                if (chunk_start < index) try self.appendTextFragment(box_id, text[chunk_start..index], chunk_width, false, style, link_url);
                self.newLine();
                if (byte == '\r' and index + 1 < text.len and text[index + 1] == '\n') index += 1;
                index += 1;
                chunk_start = index;
                chunk_width = 0;
                continue;
            }

            if (byte == '\t') {
                if (chunk_start < index) try self.appendTextFragment(box_id, text[chunk_start..index], chunk_width, false, style, link_url);
                const tab_text = "    ";
                const tab_width = measureText(self.state.font_registry, tab_text, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
                if (allow_wrap and self.has_content and self.x + tab_width > self.start_x + self.width) self.newLine();
                try self.appendTextFragment(box_id, tab_text, tab_width, false, style, link_url);
                index += 1;
                chunk_start = index;
                chunk_width = 0;
                continue;
            }

            const sequence_length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            const end = @min(index + sequence_length, text.len);
            const character_width = measureText(self.state.font_registry, text[index..end], style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
            if (allow_wrap and self.has_content and self.x + chunk_width + character_width > self.start_x + self.width) {
                if (chunk_start < index) try self.appendTextFragment(box_id, text[chunk_start..index], chunk_width, false, style, link_url);
                self.newLine();
                chunk_start = index;
                chunk_width = 0;
            }
            chunk_width += character_width;
            index = end;
        }
        if (chunk_start < text.len) try self.appendTextFragment(box_id, text[chunk_start..], chunk_width, false, style, link_url);
    }

    fn appendTextFragment(
        self: *InlineCursor,
        box_id: box.BoxId,
        text: []const u8,
        width: f32,
        leading_space: bool,
        style: box.Style,
        link_url: ?[]const u8,
    ) !void {
        if (text.len == 0) return;
        const line_height = @max(style.line_height, style.font_size * 1.2);
        self.line_height = @max(self.line_height, line_height);
        try self.state.fragments.append(self.state.allocator, .{
            .kind = .text,
            .source_box = box_id,
            .rect = .{ .x = self.x, .y = self.line_y, .width = width, .height = line_height },
            .line_id = self.line_id,
            .text = text,
            .leading_space = leading_space,
            .font_size = style.font_size,
            .font_family = style.font_family,
            .letter_spacing = style.letter_spacing,
            .font_weight = style.font_weight,
            .font_style = style.font_style,
            .color = geometry.parseColor(style.color) orelse geometry.Color.black,
            .text_decoration = style.text_decoration,
            .link_url = link_url,
        });
        self.x += width;
        self.has_content = true;
    }

    fn layoutAtomic(self: *InlineCursor, box_id: box.BoxId, source: box.Box, link_url: ?[]const u8) !void {
        const width = source.style.width.resolve(self.width) orelse source.intrinsic_width orelse 24;
        const height = source.style.height.resolve(self.state.page_height orelse 0) orelse source.intrinsic_height orelse 24;

        if (self.has_content and self.x + width > self.start_x + self.width) self.newLine();
        self.line_height = @max(self.line_height, height);
        try self.state.fragments.append(self.state.allocator, .{
            .kind = .replaced,
            .source_box = box_id,
            .rect = .{ .x = self.x, .y = self.line_y, .width = width, .height = height },
            .line_id = self.line_id,
            .border = source.border,
            .border_paint = borderPaint(source.style),
            .link_url = link_url,
            .image_source = self.state.attributeForBox(box_id, "src"),
        });
        self.x += width;
        self.has_content = true;
    }

    fn layoutInlineBlock(self: *InlineCursor, box_id: box.BoxId, source: box.Box) !void {
        const horizontal_edges = source.margin.left + source.margin.right + source.border.left + source.border.right + source.padding.left + source.padding.right;
        const requested_content = source.style.width.resolve(self.width) orelse @max(self.width - (self.x - self.start_x) - horizontal_edges, 1);
        const expected_outer_width = requested_content + horizontal_edges;
        if (self.has_content and self.x + expected_outer_width > self.start_x + self.width) self.newLine();

        const fragment_start = self.state.fragments.items.len;
        var nested_cursor_y = self.line_y;
        const rect = try self.state.layoutBlock(
            box_id,
            .{ .x = self.x, .y = self.line_y, .width = expected_outer_width },
            &nested_cursor_y,
        );
        for (self.state.fragments.items[fragment_start..]) |*fragment| {
            fragment.inline_container_line_id = self.line_id;
        }
        const outer_height = source.margin.top + rect.height + source.margin.bottom;
        self.line_height = @max(self.line_height, outer_height);
        self.x += source.margin.left + rect.width + source.margin.right;
        self.has_content = true;
    }

    fn newLine(self: *InlineCursor) void {
        self.alignCurrentLine(false);
        self.line_y += if (self.line_height > 0) self.line_height else 18;
        self.x = self.start_x;
        self.line_height = 0;
        self.line_start_fragment = self.state.fragments.items.len;
        self.line_id = self.state.next_line_id;
        self.state.next_line_id += 1;
        self.has_content = false;
        self.pending_space = false;
    }

    fn alignCurrentLine(self: *InlineCursor, is_last_line: bool) void {
        if (!self.has_content or self.text_align == .left) return;
        const used = self.x - self.start_x;
        const remaining = @max(self.width - used, 0);
        if (self.text_align == .justify) {
            if (is_last_line or remaining == 0) return;
            var spaces: usize = 0;
            for (self.state.fragments.items[self.line_start_fragment..]) |fragment| {
                if (fragment.line_id == self.line_id and fragment.leading_space) spaces += 1;
            }
            if (spaces == 0) return;
            const extra = remaining / @as(f32, @floatFromInt(spaces));
            var shift: f32 = 0;
            for (self.state.fragments.items[self.line_start_fragment..]) |*fragment| {
                if (fragment.line_id != self.line_id and fragment.inline_container_line_id != self.line_id) continue;
                if (fragment.leading_space) shift += extra;
                fragment.rect.x += shift;
            }
            return;
        }
        const shift = if (self.text_align == .center) remaining / 2 else remaining;
        for (self.state.fragments.items[self.line_start_fragment..]) |*fragment| {
            if (fragment.line_id == self.line_id or fragment.inline_container_line_id == self.line_id) fragment.rect.x += shift;
        }
    }

    fn finish(self: *InlineCursor) f32 {
        self.alignCurrentLine(true);
        if (!self.has_content and self.line_y == self.start_y) return 0;
        return (self.line_y + @max(self.line_height, 18)) - self.start_y;
    }
};

fn isBlockLevel(kind: box.BoxType) bool {
    return switch (kind) {
        .block, .anonymousBlock, .table, .tableRow, .tableCell, .tableRowGroup, .anonymousTableRow => true,
        else => false,
    };
}

fn findFreeColumns(occupied: []const bool, start: usize, span: usize) usize {
    var column = start;
    while (column + span <= occupied.len) : (column += 1) {
        var free = true;
        for (occupied[column .. column + span]) |slot| if (slot) {
            free = false;
            break;
        };
        if (free) return column;
    }
    return occupied.len;
}

fn isHtmlWhitespace(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\n' or value == '\r' or value == 0x0C;
}

fn collapseMargins(previous: f32, next: f32) f32 {
    if (previous >= 0 and next >= 0) return @max(previous, next);
    if (previous <= 0 and next <= 0) return @min(previous, next);
    return previous + next;
}

fn resolveContentDimension(length: box.Length, reference: f32, non_content: f32, sizing: box.BoxSizing) ?f32 {
    const resolved = length.resolve(reference) orelse return null;
    return switch (sizing) {
        .contentBox => @max(resolved, 0),
        .borderBox => @max(resolved - non_content, 0),
    };
}

fn borderPaint(style: box.Style) BorderPaint {
    return .{
        .top_style = style.border_top_style,
        .right_style = style.border_right_style,
        .bottom_style = style.border_bottom_style,
        .left_style = style.border_left_style,
        .top_color = geometry.parseColor(style.border_top_color) orelse geometry.Color.black,
        .right_color = geometry.parseColor(style.border_right_color) orelse geometry.Color.black,
        .bottom_color = geometry.parseColor(style.border_bottom_color) orelse geometry.Color.black,
        .left_color = geometry.parseColor(style.border_left_color) orelse geometry.Color.black,
    };
}

fn measureText(
    registry: ?*const font.Registry,
    text: []const u8,
    family: []const u8,
    font_size: f32,
    weight: box.FontWeight,
    style: box.FontStyle,
    letter_spacing: f32,
) f32 {
    const metrics = font.resolve(registry, family, weight, style).metrics();
    var iterator = font.Utf8Iterator{ .bytes = text };
    var glyph_count: usize = 0;
    while (iterator.next() catch null) |_| glyph_count += 1;
    return (metrics.widthCssPx(text, font_size) catch 0) + letter_spacing * @as(f32, @floatFromInt(glyph_count));
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
