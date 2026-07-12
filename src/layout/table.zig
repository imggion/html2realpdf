//! Table formatting context and track resolution.
//!
//! Percentage cell hints resolve into tracks before cells are laid out; cells
//! then fill the assigned track or colspan width exactly.

const std = @import("std");
const box = @import("../box.zig");
const font = @import("../font.zig");
const geometry = @import("../geometry.zig");
const fragmentation = @import("fragmentation.zig");
const intrinsic = @import("intrinsic.zig");
const types = @import("types.zig");

const FragmentId = types.FragmentId;
const Fragment = types.Fragment;
const borderPaint = types.borderPaint;
const resolveContentDimension = intrinsic.resolveContentDimension;

const CellLayout = struct {
    root: FragmentId,
    end: usize,
    natural_height: f32,
    row_span: usize = 1,
};

pub fn layout(
    state: anytype,
    table_id: box.BoxId,
    start_x: f32,
    start_y: f32,
    width: f32,
) !f32 {
    var rows = try std.ArrayList(box.BoxId).initCapacity(state.allocator, 0);
    defer rows.deinit(state.allocator);
    try collectTableRows(state, table_id, &rows);

    var top_captions = try std.ArrayList(box.BoxId).initCapacity(state.allocator, 0);
    defer top_captions.deinit(state.allocator);
    var bottom_captions = try std.ArrayList(box.BoxId).initCapacity(state.allocator, 0);
    defer bottom_captions.deinit(state.allocator);
    try collectTableCaptions(state, table_id, &top_captions, &bottom_captions);

    const column_count = @max(try tableGridColumnCount(state, rows.items), tableDefinedColumnCount(state, table_id));
    const column_widths = try tableColumnWidths(state, table_id, rows.items, column_count, width);
    defer state.allocator.free(column_widths);
    var table_width: f32 = 0;
    for (column_widths) |track_width| table_width += track_width;
    expandTableRootWidth(state, table_id, table_width - width);

    var row_y = start_y;
    try layoutCaptions(state, table_id, top_captions.items, start_x, &row_y, table_width);
    var header_template_start: ?usize = null;
    var header_template_end: usize = 0;
    var header_start_y: f32 = 0;
    var header_height: f32 = 0;
    var last_repeated_page: ?usize = null;
    var previous_break_after = box.PageBreak.auto;
    var sibling_group_fragment_start: ?usize = null;
    var sibling_group_y: f32 = 0;
    const ActiveSpan = struct { remaining: usize = 0, cell: ?CellLayout = null };
    const NewSpan = struct { first_column: usize, column_span: usize, cell: CellLayout };
    const active_spans = try state.allocator.alloc(ActiveSpan, column_count);
    defer state.allocator.free(active_spans);
    @memset(active_spans, ActiveSpan{});
    const occupied = try state.allocator.alloc(bool, column_count);
    defer state.allocator.free(occupied);

    const collapse_borders = state.tree.boxes.items[table_id].style.border_collapse == .collapse;
    for (rows.items, 0..) |row_id, row_index| {
        const is_header_row = isTableHeaderRow(state, row_id);
        const row_source = state.tree.boxes.items[row_id];
        const boundary_break = fragmentation.resolveBoundary(previous_break_after, row_source.style.page_break_before);
        if (state.web_sizing and boundary_break.isForced()) {
            if (state.fragmentainer()) |context| {
                const target_page_start = context.forcedBreakStart(row_y, boundary_break);
                if (target_page_start > row_y) {
                    const target_page = context.pageIndex(target_page_start);
                    const should_repeat_header = !is_header_row and
                        header_template_start != null and
                        header_height < context.extent and
                        last_repeated_page != target_page;
                    row_y = target_page_start + (if (should_repeat_header) header_height else 0);
                    if (should_repeat_header) {
                        try cloneTableHeader(
                            state,
                            header_template_start.?,
                            header_template_end,
                            header_start_y,
                            target_page_start,
                        );
                        last_repeated_page = target_page;
                    }
                }
            }
        }
        const row_start_fragment = state.fragments.items.len;
        const row_fragment_id = state.fragments.items.len;
        try state.fragments.append(state.allocator, .{
            .kind = .box,
            .source_box = row_id,
            .rect = .{ .x = start_x, .y = row_y, .width = table_width },
            .background = if (row_source.style.background) |value| geometry.parseColor(value) else null,
            .background_image = row_source.style.background_image,
            .background_position = row_source.style.background_position,
            .background_size = row_source.style.background_size,
            .background_repeat = row_source.style.background_repeat,
            .box_shadow = row_source.style.box_shadow,
            .border = row_source.border,
            .border_paint = borderPaint(row_source.style),
            .border_radius = row_source.style.border_radius,
            .border_radii = row_source.style.border_radii,
            .box_decoration_break = row_source.style.box_decoration_break,
            .legacy_fragment_borders = !state.web_sizing,
            .page_break_before = row_source.style.page_break_before,
            .page_break_after = row_source.style.page_break_after,
            .page_break_inside = row_source.style.page_break_inside,
        });

        var row_height: f32 = 0;
        var column_index: usize = 0;
        var cell_layouts = try std.ArrayList(CellLayout).initCapacity(state.allocator, column_count);
        defer cell_layouts.deinit(state.allocator);
        var new_spans = try std.ArrayList(NewSpan).initCapacity(state.allocator, 0);
        defer new_spans.deinit(state.allocator);
        var old_span_cells = try std.ArrayList(CellLayout).initCapacity(state.allocator, 0);
        defer old_span_cells.deinit(state.allocator);
        for (active_spans, 0..) |active, index| {
            occupied[index] = active.remaining > 0;
            const spanning_cell = active.cell orelse continue;
            var already_added = false;
            for (old_span_cells.items) |existing| if (existing.root == spanning_cell.root) {
                already_added = true;
                break;
            };
            if (!already_added) try old_span_cells.append(state.allocator, spanning_cell);
        }

        var cell = row_source.first_child;
        while (cell) |cell_id| {
            const cell_source = state.tree.boxes.items[cell_id];
            if (cell_source.kind == .tableCell) {
                const span = tableCellSpan(state, cell_id);
                const row_span = tableCellRowSpan(state, cell_id);
                column_index = findFreeColumns(occupied, column_index, span);
                if (column_index + span > column_count) break;
                var cell_x = start_x;
                for (column_widths[0..column_index]) |track_width| cell_x += track_width;
                var cell_width: f32 = 0;
                for (column_widths[column_index .. column_index + span]) |track_width| cell_width += track_width;
                var cell_cursor = row_y;
                const cell_fragment_id = state.fragments.items.len;
                _ = try state.layoutBlockWithOptions(
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
                    if (column_index > 0) state.fragments.items[cell_fragment_id].border.left = 0;
                    if (row_index > 0) state.fragments.items[cell_fragment_id].border.top = 0;
                }
                const cell_layout = CellLayout{
                    .root = cell_fragment_id,
                    .end = state.fragments.items.len,
                    .natural_height = state.fragments.items[cell_fragment_id].rect.height,
                    .row_span = row_span,
                };
                try cell_layouts.append(state.allocator, cell_layout);
                for (occupied[column_index .. column_index + span]) |*slot| slot.* = true;
                if (row_span > 1) try new_spans.append(state.allocator, .{
                    .first_column = column_index,
                    .column_span = span,
                    .cell = cell_layout,
                });
                row_height = @max(row_height, cell_cursor - row_y);
                column_index += span;
            }
            cell = cell_source.next_sibling;
        }

        row_height = @max(row_height, row_source.style.height.resolve(state.page_height orelse 0) orelse 1);
        state.fragments.items[row_fragment_id].rect.height = row_height;
        alignCellContents(state, cell_layouts.items, row_height);
        for (state.fragments.items[row_start_fragment..]) |*fragment| {
            fragment.table_id = table_id;
            fragment.is_table_header = is_header_row;
        }

        if (!state.web_sizing and state.page_height != null) {
            const page_height = state.page_height.?;
            const page_y = @mod(row_y, page_height);
            if (row_height <= page_height and page_y > 0 and page_y + row_height > page_height) {
                const target_page_start = row_y + page_height - page_y;
                const target_page: usize = @intFromFloat(@floor(target_page_start / page_height));
                const should_repeat_header = !is_header_row and
                    header_template_start != null and
                    header_height + row_height <= page_height and
                    last_repeated_page != target_page;
                const shift = page_height - page_y + (if (should_repeat_header) header_height else 0);
                for (state.fragments.items[row_start_fragment..]) |*fragment| fragment.rect.y += shift;
                row_y += shift;
                if (should_repeat_header) {
                    try cloneTableHeader(
                        state,
                        header_template_start.?,
                        header_template_end,
                        header_start_y,
                        target_page_start,
                    );
                    last_repeated_page = target_page;
                }
            }
        } else if (state.fragmentainer()) |context| {
            var kept_group = false;
            var retain_group = false;
            if (boundary_break.isAvoid() and sibling_group_fragment_start != null) {
                const group_end = row_y + row_height;
                const group_size = group_end - sibling_group_y;
                const can_repeat_for_group = !is_header_row and
                    header_template_start != null and
                    header_height + group_size <= context.extent;
                retain_group = group_size <= context.extent + 0.0001;
                const group_shift = context.atomicShift(sibling_group_y, group_size);
                if (group_shift > 0) {
                    const target_page_start = context.boundaryAtOrAfter(sibling_group_y);
                    const target_page = context.pageIndex(target_page_start);
                    const should_repeat_header = can_repeat_for_group and last_repeated_page != target_page;
                    const shift = group_shift + (if (should_repeat_header) header_height else 0);
                    for (state.fragments.items[sibling_group_fragment_start.?..]) |*fragment| shiftFragmentY(fragment, shift);
                    row_y += shift;
                    sibling_group_y += shift;
                    kept_group = true;
                    if (should_repeat_header) {
                        try cloneTableHeader(
                            state,
                            header_template_start.?,
                            header_template_end,
                            header_start_y,
                            target_page_start,
                        );
                        last_repeated_page = target_page;
                    }
                }
            }

            const automatic_shift = if (kept_group) 0 else context.atomicShift(row_y, row_height);
            if (automatic_shift > 0) {
                const target_page_start = row_y + automatic_shift;
                const target_page = context.pageIndex(target_page_start);
                const should_repeat_header = !is_header_row and
                    header_template_start != null and
                    header_height + row_height <= context.extent and
                    last_repeated_page != target_page;
                const shift = automatic_shift + (if (should_repeat_header) header_height else 0);
                for (state.fragments.items[row_start_fragment..]) |*fragment| shiftFragmentY(fragment, shift);
                row_y += shift;
                if (should_repeat_header) {
                    try cloneTableHeader(
                        state,
                        header_template_start.?,
                        header_template_end,
                        header_start_y,
                        target_page_start,
                    );
                    last_repeated_page = target_page;
                }
            }
            if (!retain_group) {
                sibling_group_fragment_start = row_start_fragment;
                sibling_group_y = row_y;
            }
        }

        if (is_header_row) {
            if (header_template_start == null) {
                header_template_start = row_start_fragment;
                header_start_y = row_y;
            }
            header_template_end = state.fragments.items.len;
            header_height = row_y + row_height - header_start_y;
        }

        for (old_span_cells.items) |spanning_cell| {
            const fragment = &state.fragments.items[spanning_cell.root];
            const spanned_height = row_y + row_height - fragment.rect.y;
            fragment.rect.height = @max(fragment.rect.height, spanned_height);
            var completes_here = false;
            for (active_spans) |active| {
                if (active.cell != null and active.cell.?.root == spanning_cell.root and active.remaining == 1) {
                    completes_here = true;
                    break;
                }
            }
            if (completes_here) {
                var final_cell = spanning_cell;
                final_cell.row_span = 1;
                alignCellContents(state, &.{final_cell}, spanned_height);
            }
        }
        for (active_spans) |*active| {
            if (active.remaining > 0) active.remaining -= 1;
            if (active.remaining == 0) active.cell = null;
        }
        for (new_spans.items) |new_span| {
            for (active_spans[new_span.first_column .. new_span.first_column + new_span.column_span]) |*active| {
                active.* = .{
                    .remaining = new_span.cell.row_span - 1,
                    .cell = new_span.cell,
                };
            }
        }

        row_y += row_height;
        previous_break_after = row_source.style.page_break_after;
    }

    if (state.web_sizing and previous_break_after.isForced()) state.applyForcedBreak(&row_y, previous_break_after);

    try layoutCaptions(state, table_id, bottom_captions.items, start_x, &row_y, table_width);

    return row_y - start_y;
}

fn collectTableCaptions(
    state: anytype,
    table_id: box.BoxId,
    top: *std.ArrayList(box.BoxId),
    bottom: *std.ArrayList(box.BoxId),
) !void {
    var child = state.tree.boxes.items[table_id].first_child;
    while (child) |child_id| {
        const source = state.tree.boxes.items[child_id];
        if (source.kind == .tableCaption) {
            if (source.style.caption_side == .bottom) {
                try bottom.append(state.allocator, child_id);
            } else {
                try top.append(state.allocator, child_id);
            }
        }
        child = source.next_sibling;
    }
}

fn layoutCaptions(
    state: anytype,
    table_id: box.BoxId,
    captions: []const box.BoxId,
    x: f32,
    cursor_y: *f32,
    width: f32,
) !void {
    for (captions) |caption_id| {
        const fragment_start = state.fragments.items.len;
        _ = try state.layoutBlockWithOptions(
            caption_id,
            .{ .x = x, .y = cursor_y.*, .width = width },
            cursor_y,
            .{ .fill_available_width = true },
        );
        for (state.fragments.items[fragment_start..]) |*fragment| fragment.table_id = table_id;
    }
}

fn expandTableRootWidth(state: anytype, table_id: box.BoxId, extra: f32) void {
    if (extra <= 0) return;
    var index = state.fragments.items.len;
    while (index > 0) {
        index -= 1;
        const fragment = &state.fragments.items[index];
        if (fragment.source_box != table_id) continue;
        fragment.rect.width += extra;
        return;
    }
}

fn alignCellContents(state: anytype, cells: []const CellLayout, row_height: f32) void {
    var row_baseline: ?f32 = null;
    for (cells) |cell| {
        if (cell.row_span > 1) continue;
        const source = state.tree.boxes.items[state.fragments.items[cell.root].source_box];
        if (source.style.vertical_align != .baseline) continue;
        const baseline = firstTextBaseline(state, cell.root + 1, cell.end) orelse continue;
        if (row_baseline == null or baseline > row_baseline.?) row_baseline = baseline;
    }

    for (cells) |cell| {
        if (cell.row_span > 1) continue;
        const root = &state.fragments.items[cell.root];
        const source = state.tree.boxes.items[root.source_box];
        const free_space = @max(row_height - cell.natural_height, 0);
        const shift = switch (source.style.vertical_align) {
            .middle => free_space / 2,
            .bottom, .textBottom => free_space,
            .baseline => if (row_baseline) |target|
                if (firstTextBaseline(state, cell.root + 1, cell.end)) |baseline| @max(target - baseline, 0) else 0
            else
                0,
            else => 0,
        };
        if (shift > 0) {
            for (state.fragments.items[cell.root + 1 .. cell.end]) |*fragment| shiftFragmentY(fragment, shift);
        }
        root.rect.height = @max(root.rect.height, row_height);
    }
}

fn firstTextBaseline(state: anytype, start: usize, end: usize) ?f32 {
    for (state.fragments.items[start..end]) |fragment| {
        if (fragment.kind != .text) continue;
        const resolved = font.resolve(state.font_registry, fragment.font_family, fragment.font_weight, fragment.font_style);
        return fragment.rect.y + fragment.font_size * resolved.metrics().ascentRatio();
    }
    return null;
}

fn shiftFragmentY(fragment: *Fragment, shift: f32) void {
    fragment.rect.y += shift;
    if (fragment.clip_rect) |*clip| clip.y += shift;
    if (fragment.image_content_rect) |*content| content.y += shift;
}

fn cloneTableHeader(
    state: anytype,
    start: usize,
    end: usize,
    source_y: f32,
    target_y: f32,
) !void {
    const count = end - start;
    const copies = try state.allocator.alloc(Fragment, count);
    defer state.allocator.free(copies);
    @memcpy(copies, state.fragments.items[start..end]);
    for (copies) |*fragment| fragment.rect.y = target_y + fragment.rect.y - source_y;
    try state.fragments.appendSlice(state.allocator, copies);
}

fn isTableHeaderRow(state: anytype, row_id: box.BoxId) bool {
    const parent_id = state.tree.boxes.items[row_id].parent orelse return false;
    const parent = state.tree.boxes.items[parent_id];
    if (parent.kind != .tableRowGroup) return false;
    const node_id = parent.node orelse return false;
    const node = state.document.nodes.items[node_id];
    return node.kind == .element and std.ascii.eqlIgnoreCase(node.kind.element.name, "thead");
}

fn collectTableRows(state: anytype, parent_id: box.BoxId, rows: *std.ArrayList(box.BoxId)) !void {
    var child = state.tree.boxes.items[parent_id].first_child;
    while (child) |child_id| {
        const child_box = state.tree.boxes.items[child_id];
        switch (child_box.kind) {
            .tableRow, .anonymousTableRow => try rows.append(state.allocator, child_id),
            .tableRowGroup => try collectTableRows(state, child_id, rows),
            else => {},
        }
        child = child_box.next_sibling;
    }
}

/// Resolves auto-layout tracks from column hints and cell min/max-content
/// contributions. Document profile keeps the legacy percentage-track behavior
/// so existing PDF baselines remain byte stable.
fn tableColumnWidths(
    state: anytype,
    table_id: box.BoxId,
    rows: []const box.BoxId,
    column_count: usize,
    table_width: f32,
) ![]f32 {
    if (!state.web_sizing) return legacyTableColumnWidths(state, rows, column_count, table_width);

    const minimums = try state.allocator.alloc(f32, column_count);
    defer state.allocator.free(minimums);
    @memset(minimums, 0);
    const preferred = try state.allocator.alloc(f32, column_count);
    defer state.allocator.free(preferred);
    @memset(preferred, 0);
    applyColumnWidthHints(state, table_id, minimums, preferred, table_width);

    const active = try state.allocator.alloc(usize, column_count);
    defer state.allocator.free(active);
    @memset(active, 0);

    for (rows) |row_id| {
        var column: usize = 0;
        var child = state.tree.boxes.items[row_id].first_child;
        while (child) |child_id| {
            const child_box = state.tree.boxes.items[child_id];
            if (child_box.kind == .tableCell) {
                const span = tableCellSpan(state, child_id);
                column = findFreeColumnSpan(active, column, span);
                if (column + span > column_count) break;

                const measured = try state.measureIntrinsicInline(child_id);
                const edges = child_box.border.left + child_box.border.right + child_box.padding.left + child_box.padding.right;
                var minimum = measured.min_content + edges;
                var maximum = @max(measured.max_content + edges, minimum);
                if (tableCellOuterWidthHint(child_box, table_width)) |hint| {
                    minimum = @max(minimum, hint);
                    maximum = @max(maximum, hint);
                }
                applySpanningContribution(minimums, column, span, minimum);
                applySpanningContribution(preferred, column, span, maximum);

                const row_span = tableCellRowSpan(state, child_id);
                for (active[column .. column + span]) |*remaining| remaining.* = @max(remaining.*, row_span);
                column += span;
            }
            child = child_box.next_sibling;
        }
        for (active) |*remaining| if (remaining.* > 0) {
            remaining.* -= 1;
        };
    }

    for (preferred, minimums) |*maximum, minimum| maximum.* = @max(maximum.*, minimum);
    return distributeIntrinsicTracks(state.allocator, minimums, preferred, table_width);
}

fn legacyTableColumnWidths(state: anytype, rows: []const box.BoxId, column_count: usize, table_width: f32) ![]f32 {
    const widths = try state.allocator.alloc(f32, column_count);
    errdefer state.allocator.free(widths);
    @memset(widths, 0);

    const active = try state.allocator.alloc(usize, column_count);
    defer state.allocator.free(active);
    @memset(active, 0);

    for (rows) |row_id| {
        var column: usize = 0;
        var child = state.tree.boxes.items[row_id].first_child;
        while (child) |child_id| {
            const child_box = state.tree.boxes.items[child_id];
            if (child_box.kind == .tableCell) {
                const span = tableCellSpan(state, child_id);
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

                const row_span = tableCellRowSpan(state, child_id);
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

fn applyColumnWidthHints(
    state: anytype,
    table_id: box.BoxId,
    minimums: []f32,
    preferred: []f32,
    table_width: f32,
) void {
    var column_index: usize = 0;
    var child = state.tree.boxes.items[table_id].first_child;
    while (child) |child_id| {
        const source = state.tree.boxes.items[child_id];
        if (source.kind == .tableColumn) {
            const span = @min(tableColumnSpan(state, child_id), minimums.len -| column_index);
            applyColumnBoxHint(source, minimums, preferred, column_index, span, table_width, true);
            column_index += span;
        } else if (source.kind == .tableColumnGroup) {
            const group_start = column_index;
            var group_child = source.first_child;
            while (group_child) |column_id| {
                const column = state.tree.boxes.items[column_id];
                if (column.kind == .tableColumn) {
                    const span = @min(tableColumnSpan(state, column_id), minimums.len -| column_index);
                    applyColumnBoxHint(column, minimums, preferred, column_index, span, table_width, true);
                    column_index += span;
                }
                group_child = column.next_sibling;
            }
            if (column_index == group_start) column_index += @min(tableColumnSpan(state, child_id), minimums.len -| column_index);
            const group_span = column_index - group_start;
            applyColumnBoxHint(source, minimums, preferred, group_start, group_span, table_width, false);
        }
        child = source.next_sibling;
    }
}

fn applyColumnBoxHint(
    source: box.Box,
    minimums: []f32,
    preferred: []f32,
    start: usize,
    span: usize,
    table_width: f32,
    per_column: bool,
) void {
    if (span == 0 or start >= minimums.len) return;
    const hint = tableCellOuterWidthHint(source, table_width) orelse return;
    if (per_column) {
        const end = @min(start + span, minimums.len);
        for (minimums[start..end]) |*minimum| minimum.* = @max(minimum.*, hint);
        for (preferred[start..end]) |*maximum| maximum.* = @max(maximum.*, hint);
    } else {
        applySpanningContribution(minimums, start, span, hint);
        applySpanningContribution(preferred, start, span, hint);
    }
}

fn applySpanningContribution(tracks: []f32, start: usize, span: usize, contribution: f32) void {
    if (span == 0 or start >= tracks.len) return;
    const end = @min(start + span, tracks.len);
    var current: f32 = 0;
    for (tracks[start..end]) |track| current += track;
    if (current >= contribution) return;
    const extra = (contribution - current) / @as(f32, @floatFromInt(end - start));
    for (tracks[start..end]) |*track| track.* += extra;
}

fn distributeIntrinsicTracks(
    allocator: std.mem.Allocator,
    minimums: []const f32,
    preferred: []const f32,
    table_width: f32,
) ![]f32 {
    const widths = try allocator.dupe(f32, minimums);
    errdefer allocator.free(widths);
    var minimum_total: f32 = 0;
    var growth_total: f32 = 0;
    for (minimums, preferred) |minimum, maximum| {
        minimum_total += minimum;
        growth_total += @max(maximum - minimum, 0);
    }

    var extra = @max(table_width - minimum_total, 0);
    if (extra > 0 and growth_total > 0) {
        const assigned = @min(extra, growth_total);
        for (widths, minimums, preferred) |*width, minimum, maximum| {
            width.* += assigned * @max(maximum - minimum, 0) / growth_total;
        }
        extra -= assigned;
    }
    if (extra > 0) {
        const share = extra / @as(f32, @floatFromInt(widths.len));
        for (widths) |*width| width.* += share;
    }
    for (widths) |*width| width.* = @max(width.*, 1);
    return widths;
}

fn findFreeColumnSpan(active: []const usize, start: usize, span: usize) usize {
    var column = start;
    while (column + span <= active.len) : (column += 1) {
        var free = true;
        for (active[column .. column + span]) |remaining| if (remaining > 0) {
            free = false;
            break;
        };
        if (free) return column;
    }
    return active.len;
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
        .expression => {
            const horizontal_edges = cell.border.left + cell.border.right + cell.padding.left + cell.padding.right;
            const content_width = resolveContentDimension(cell.style.width, table_width, horizontal_edges, cell.style.box_sizing) orelse return null;
            return content_width + horizontal_edges;
        },
        .minContent, .maxContent, .fitContent => null,
    };
}

fn tableGridColumnCount(state: anytype, rows: []const box.BoxId) !usize {
    var active = try std.ArrayList(usize).initCapacity(state.allocator, 0);
    defer active.deinit(state.allocator);
    var maximum: usize = 1;

    for (rows) |row_id| {
        var column: usize = 0;
        var child = state.tree.boxes.items[row_id].first_child;
        while (child) |child_id| {
            const child_box = state.tree.boxes.items[child_id];
            if (child_box.kind == .tableCell) {
                const column_span = tableCellSpan(state, child_id);
                while (true) {
                    while (column < active.items.len and active.items[column] > 0) column += 1;
                    if (column + column_span > active.items.len) {
                        const old_len = active.items.len;
                        try active.resize(state.allocator, column + column_span);
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
                const row_span = tableCellRowSpan(state, child_id);
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

fn tableDefinedColumnCount(state: anytype, table_id: box.BoxId) usize {
    var total: usize = 0;
    var child = state.tree.boxes.items[table_id].first_child;
    while (child) |child_id| {
        const source = state.tree.boxes.items[child_id];
        if (source.kind == .tableColumn) {
            total += tableColumnSpan(state, child_id);
        } else if (source.kind == .tableColumnGroup) {
            var group_total: usize = 0;
            var group_child = source.first_child;
            while (group_child) |column_id| {
                const column = state.tree.boxes.items[column_id];
                if (column.kind == .tableColumn) group_total += tableColumnSpan(state, column_id);
                group_child = column.next_sibling;
            }
            total += if (group_total > 0) group_total else tableColumnSpan(state, child_id);
        }
        child = source.next_sibling;
    }
    return @max(total, 1);
}

fn tableColumnSpan(state: anytype, column_id: box.BoxId) usize {
    return tableCellIntegerAttribute(state, column_id, "span");
}

fn tableCellSpan(state: anytype, cell_id: box.BoxId) usize {
    return tableCellIntegerAttribute(state, cell_id, "colspan");
}

fn tableCellRowSpan(state: anytype, cell_id: box.BoxId) usize {
    return tableCellIntegerAttribute(state, cell_id, "rowspan");
}

fn tableCellIntegerAttribute(state: anytype, cell_id: box.BoxId, name: []const u8) usize {
    const node_id = state.tree.boxes.items[cell_id].node orelse return 1;
    const node = state.document.nodes.items[node_id];
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
