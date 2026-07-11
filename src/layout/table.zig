//! Table formatting context and track resolution.
//!
//! Percentage cell hints resolve into tracks before cells are laid out; cells
//! then fill the assigned track or colspan width exactly.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const intrinsic = @import("intrinsic.zig");
const types = @import("types.zig");

const FragmentId = types.FragmentId;
const Fragment = types.Fragment;
const borderPaint = types.borderPaint;
const resolveContentDimension = intrinsic.resolveContentDimension;

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
    if (rows.items.len == 0) return 0;

    const column_count = try tableGridColumnCount(state, rows.items);
    const column_widths = try tableColumnWidths(state, rows.items, column_count, width);
    defer state.allocator.free(column_widths);
    var row_y = start_y;
    var header_template_start: ?usize = null;
    var header_template_end: usize = 0;
    var header_start_y: f32 = 0;
    var header_height: f32 = 0;
    var last_repeated_page: ?usize = null;
    const ActiveSpan = struct { remaining: usize = 0, fragment_id: ?FragmentId = null };
    const NewSpan = struct { first_column: usize, column_span: usize, row_span: usize, fragment_id: FragmentId };
    const active_spans = try state.allocator.alloc(ActiveSpan, column_count);
    defer state.allocator.free(active_spans);
    @memset(active_spans, ActiveSpan{});
    const occupied = try state.allocator.alloc(bool, column_count);
    defer state.allocator.free(occupied);

    const collapse_borders = state.tree.boxes.items[table_id].style.border_collapse == .collapse;
    for (rows.items, 0..) |row_id, row_index| {
        const is_header_row = isTableHeaderRow(state, row_id);
        const row_start_fragment = state.fragments.items.len;
        const row_source = state.tree.boxes.items[row_id];
        const row_fragment_id = state.fragments.items.len;
        try state.fragments.append(state.allocator, .{
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
        var cell_roots = try std.ArrayList(FragmentId).initCapacity(state.allocator, column_count);
        defer cell_roots.deinit(state.allocator);
        var new_spans = try std.ArrayList(NewSpan).initCapacity(state.allocator, 0);
        defer new_spans.deinit(state.allocator);
        var old_span_roots = try std.ArrayList(FragmentId).initCapacity(state.allocator, 0);
        defer old_span_roots.deinit(state.allocator);
        for (active_spans, 0..) |active, index| {
            occupied[index] = active.remaining > 0;
            const root = active.fragment_id orelse continue;
            var already_added = false;
            for (old_span_roots.items) |existing| if (existing == root) {
                already_added = true;
                break;
            };
            if (!already_added) try old_span_roots.append(state.allocator, root);
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
                try cell_roots.append(state.allocator, cell_fragment_id);
                for (occupied[column_index .. column_index + span]) |*slot| slot.* = true;
                if (row_span > 1) try new_spans.append(state.allocator, .{
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

        row_height = @max(row_height, row_source.style.height.resolve(state.page_height orelse 0) orelse 1);
        state.fragments.items[row_fragment_id].rect.height = row_height;
        for (cell_roots.items) |fragment_id| {
            state.fragments.items[fragment_id].rect.height = @max(state.fragments.items[fragment_id].rect.height, row_height);
        }
        for (state.fragments.items[row_start_fragment..]) |*fragment| {
            fragment.table_id = table_id;
            fragment.is_table_header = is_header_row;
        }

        if (state.page_height) |page_height| {
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
        }

        if (is_header_row) {
            if (header_template_start == null) {
                header_template_start = row_start_fragment;
                header_start_y = row_y;
            }
            header_template_end = state.fragments.items.len;
            header_height = row_y + row_height - header_start_y;
        }

        for (old_span_roots.items) |fragment_id| {
            const fragment = &state.fragments.items[fragment_id];
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

/// Resolve table-cell width hints into final track widths before laying out
/// cell contents. Percentage hints are relative to the table, not to the
/// already allocated track that will later contain the cell.
fn tableColumnWidths(state: anytype, rows: []const box.BoxId, column_count: usize, table_width: f32) ![]f32 {
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
