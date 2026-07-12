//! CSS Grid formatting context for the Web CSS profile.
//!
//! Grid definitions remain compact strings on computed styles because browser
//! snapshots serialize used track values. This module parses them into
//! render-local flat tracks, places direct children into a bounded occupancy
//! map, resolves intrinsic/flexible sizing, and emits ordinary flat fragments.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const floats = @import("floats.zig");
const fragmentation = @import("fragmentation.zig");
const intrinsic = @import("intrinsic.zig");

pub const supported = true;

const max_tracks = 64;
const max_line_names = 8;

const Breadth = union(enum) {
    auto,
    fixed: f32,
    percent: f32,
    flex: f32,
    minContent,
    maxContent,
};

const TrackSize = struct {
    min: Breadth = .auto,
    max: Breadth = .auto,
};

const Track = struct {
    size: TrackSize = .{},
    base: f32 = 0,
    names: [max_line_names][]const u8 = @splat(""),
    name_count: u8 = 0,
    auto_fit: bool = false,

    fn hasName(self: Track, name: []const u8) bool {
        for (self.names[0..self.name_count]) |candidate| {
            if (std.mem.eql(u8, candidate, name)) return true;
        }
        return false;
    }
};

const Template = struct {
    tracks: std.ArrayList(Track),
    trailing_names: [max_line_names][]const u8 = @splat(""),
    trailing_name_count: u8 = 0,
    explicit_count: usize = 0,

    fn init(allocator: std.mem.Allocator) !Template {
        return .{ .tracks = try std.ArrayList(Track).initCapacity(allocator, 0) };
    }

    fn deinit(self: *Template, allocator: std.mem.Allocator) void {
        self.tracks.deinit(allocator);
    }
};

const Area = struct {
    name: []const u8,
    row_start: usize,
    row_end: usize,
    column_start: usize,
    column_end: usize,
};

const Item = struct {
    box_id: box.BoxId,
    source_index: usize,
    row: ?usize = null,
    column: ?usize = null,
    row_span: usize = 1,
    column_span: usize = 1,
    fragment_start: usize = 0,
    fragment_end: usize = 0,
    rect: geometry.Rect = .{},
};

const AxisPositions = struct {
    starts: [max_tracks]f32 = @splat(0),
    extent: f32 = 0,
};

pub fn layout(
    state: anytype,
    container_id: box.BoxId,
    content: geometry.Rect,
    specified_content_height: ?f32,
) !f32 {
    const container = state.tree.boxes.items[container_id];
    const style = container.style;
    const column_gap = resolveGap(style.column_gap, content.width);
    const row_gap = resolveGap(style.row_gap, specified_content_height orelse 0);

    var columns = try parseTemplate(state.allocator, style.grid_template_columns, content.width, column_gap, style.font_size);
    defer columns.deinit(state.allocator);
    var rows = try parseTemplate(state.allocator, style.grid_template_rows, specified_content_height orelse 0, row_gap, style.font_size);
    defer rows.deinit(state.allocator);
    var auto_columns = try parseTemplate(state.allocator, style.grid_auto_columns, content.width, column_gap, style.font_size);
    defer auto_columns.deinit(state.allocator);
    var auto_rows = try parseTemplate(state.allocator, style.grid_auto_rows, specified_content_height orelse 0, row_gap, style.font_size);
    defer auto_rows.deinit(state.allocator);
    if (auto_columns.tracks.items.len == 0) try auto_columns.tracks.append(state.allocator, .{});
    if (auto_rows.tracks.items.len == 0) try auto_rows.tracks.append(state.allocator, .{});

    var areas = try parseAreas(state.allocator, style.grid_template_areas);
    defer areas.deinit(state.allocator);
    var area_rows: usize = 0;
    var area_columns: usize = 0;
    for (areas.items) |area| {
        area_rows = @max(area_rows, area.row_end);
        area_columns = @max(area_columns, area.column_end);
    }
    try ensureTracks(state.allocator, &columns, @max(area_columns, if (columns.tracks.items.len == 0) 1 else columns.tracks.items.len), &auto_columns);
    try ensureTracks(state.allocator, &rows, @max(area_rows, if (rows.tracks.items.len == 0) 1 else rows.tracks.items.len), &auto_rows);

    var items = try std.ArrayList(Item).initCapacity(state.allocator, 0);
    defer items.deinit(state.allocator);
    var child = container.first_child;
    var source_index: usize = 0;
    while (child) |child_id| : (source_index += 1) {
        const source = state.tree.boxes.items[child_id];
        child = source.next_sibling;
        if (source.style.position == .absolute or source.style.position == .fixed) {
            try state.deferPositioned(child_id, .{ .x = content.x, .y = content.y });
            continue;
        }
        try items.append(state.allocator, makeItem(source, child_id, source_index, &columns, &rows, areas.items));
    }
    if (items.items.len == 0) return specified_content_height orelse 0;
    std.mem.sort(Item, items.items, state.tree, itemLessThan);

    var occupancy: [max_tracks * max_tracks]bool = @splat(false);
    try placeItems(state.allocator, items.items, &columns, &rows, &auto_columns, &auto_rows, style.grid_auto_flow, &occupancy);
    collapseUnusedAutoFit(columns.tracks.items, rows.tracks.items, items.items);

    try sizeColumns(state, items.items, columns.tracks.items, content.width, column_gap, style.justify_content);
    try sizeRows(state, items.items, columns.tracks.items, rows.tracks.items, content.width, specified_content_height, column_gap, row_gap, style.align_content);

    const column_positions = positionTracks(columns.tracks.items, content.width, column_gap, style.justify_content, true);
    var row_positions = positionRows(rows.tracks.items, specified_content_height, row_gap, style.align_content);
    if (state.fragmentainer()) |context| fragmentRows(state, items.items, rows.tracks.items, &row_positions, content.y, context);

    for (items.items) |*item| {
        const column = item.column orelse 0;
        const row = item.row orelse 0;
        const area_width = spanExtent(columns.tracks.items, column, item.column_span, column_gap);
        const area_height = spanPositionExtent(rows.tracks.items, row_positions.starts, row, item.row_span, row_gap);
        try layoutItem(state, item, style, .{
            .x = content.x + column_positions.starts[column],
            .y = content.y + row_positions.starts[row],
            .width = area_width,
            .height = area_height,
        });
    }

    return specified_content_height orelse row_positions.extent;
}

fn makeItem(source: box.Box, box_id: box.BoxId, source_index: usize, columns: *const Template, rows: *const Template, areas: []const Area) Item {
    var item = Item{ .box_id = box_id, .source_index = source_index };
    if (namedArea(source.style, areas)) |area| {
        item.row = area.row_start;
        item.column = area.column_start;
        item.row_span = @max(area.row_end - area.row_start, 1);
        item.column_span = @max(area.column_end - area.column_start, 1);
        return item;
    }
    resolvePlacementAxis(source.style.grid_column_start, source.style.grid_column_end, columns, &item.column, &item.column_span);
    resolvePlacementAxis(source.style.grid_row_start, source.style.grid_row_end, rows, &item.row, &item.row_span);
    return item;
}

fn namedArea(style: box.Style, areas: []const Area) ?Area {
    const row_name = switch (style.grid_row_start) {
        .named => |name| name,
        else => return null,
    };
    const column_name = switch (style.grid_column_start) {
        .named => |name| name,
        else => return null,
    };
    if (!std.mem.eql(u8, row_name, column_name)) return null;
    for (areas) |area| if (std.mem.eql(u8, area.name, row_name)) return area;
    return null;
}

fn resolvePlacementAxis(start: box.GridLine, end: box.GridLine, template: *const Template, resolved_start: *?usize, span: *usize) void {
    const start_line = resolveGridLine(start, template);
    const end_line = resolveGridLine(end, template);
    span.* = switch (end) {
        .span => |value| @max(value, 1),
        .namedSpan => |value| @max(value.count, 1),
        else => switch (start) {
            .span => |value| @max(value, 1),
            .namedSpan => |value| @max(value.count, 1),
            else => 1,
        },
    };
    if (start_line) |line| {
        resolved_start.* = line;
        if (end_line) |finish| {
            if (finish > line) span.* = finish - line;
        }
    } else if (end_line) |finish| {
        resolved_start.* = finish -| span.*;
    }
}

fn resolveGridLine(value: box.GridLine, template: *const Template) ?usize {
    return switch (value) {
        .auto, .span, .namedSpan => null,
        .line => |line| if (line > 0)
            @min(@as(usize, @intCast(line - 1)), max_tracks - 1)
        else
            @min(template.tracks.items.len -| @as(usize, @intCast(-line)) + 1, max_tracks - 1),
        .named => |name| findNamedLine(template, name),
    };
}

fn findNamedLine(template: *const Template, name: []const u8) ?usize {
    for (template.tracks.items, 0..) |track, index| if (track.hasName(name)) return index;
    for (template.trailing_names[0..template.trailing_name_count]) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return template.tracks.items.len;
    }
    return null;
}

fn itemLessThan(tree: *const box.BoxTree, a: Item, b: Item) bool {
    const a_order = tree.boxes.items[a.box_id].style.order;
    const b_order = tree.boxes.items[b.box_id].style.order;
    return if (a_order == b_order) a.source_index < b.source_index else a_order < b_order;
}

fn placeItems(
    allocator: std.mem.Allocator,
    items: []Item,
    columns: *Template,
    rows: *Template,
    auto_columns: *const Template,
    auto_rows: *const Template,
    flow: box.GridAutoFlow,
    occupancy: *[max_tracks * max_tracks]bool,
) !void {
    for (items) |*item| {
        if (item.column == null or item.row == null) continue;
        try ensureTracks(allocator, columns, item.column.? + item.column_span, auto_columns);
        try ensureTracks(allocator, rows, item.row.? + item.row_span, auto_rows);
        markOccupied(occupancy, item.row.?, item.column.?, item.row_span, item.column_span);
    }

    const column_flow = flow == .column or flow == .columnDense;
    const dense = flow == .rowDense or flow == .columnDense;
    var cursor_row: usize = 0;
    var cursor_column: usize = 0;
    for (items) |*item| {
        if (item.column != null and item.row != null) continue;
        var row = if (dense) 0 else cursor_row;
        var column = if (dense) 0 else cursor_column;
        var attempts: usize = 0;
        while (attempts < max_tracks * max_tracks) : (attempts += 1) {
            if (item.row) |fixed_row| row = fixed_row;
            if (item.column) |fixed_column| column = fixed_column;
            if (!column_flow and item.column == null and column + item.column_span > columns.tracks.items.len) {
                column = 0;
                row += 1;
            }
            if (column_flow and item.row == null and row + item.row_span > rows.tracks.items.len) {
                row = 0;
                column += 1;
            }
            try ensureTracks(allocator, columns, column + item.column_span, auto_columns);
            try ensureTracks(allocator, rows, row + item.row_span, auto_rows);
            if (canPlace(occupancy, row, column, item.row_span, item.column_span)) break;

            if (column_flow) {
                row += 1;
                if (item.row != null or row + item.row_span > rows.tracks.items.len) {
                    row = item.row orelse 0;
                    column += 1;
                }
            } else {
                column += 1;
                if (item.column != null or column + item.column_span > columns.tracks.items.len) {
                    column = item.column orelse 0;
                    row += 1;
                }
            }
        }
        item.row = row;
        item.column = column;
        markOccupied(occupancy, row, column, item.row_span, item.column_span);
        if (!dense) {
            cursor_row = row;
            cursor_column = column;
            if (column_flow) cursor_row += item.row_span else cursor_column += item.column_span;
        }
    }
}

fn canPlace(occupancy: *const [max_tracks * max_tracks]bool, row: usize, column: usize, row_span: usize, column_span: usize) bool {
    if (row + row_span > max_tracks or column + column_span > max_tracks) return false;
    for (row..row + row_span) |candidate_row| {
        for (column..column + column_span) |candidate_column| {
            if (occupancy[candidate_row * max_tracks + candidate_column]) return false;
        }
    }
    return true;
}

fn markOccupied(occupancy: *[max_tracks * max_tracks]bool, row: usize, column: usize, row_span: usize, column_span: usize) void {
    if (row + row_span > max_tracks or column + column_span > max_tracks) return;
    for (row..row + row_span) |candidate_row| {
        for (column..column + column_span) |candidate_column| occupancy[candidate_row * max_tracks + candidate_column] = true;
    }
}

fn collapseUnusedAutoFit(columns: []Track, rows: []Track, items: []const Item) void {
    for (columns, 0..) |*track, index| {
        if (!track.auto_fit) continue;
        var used = false;
        for (items) |item| if (item.column.? <= index and item.column.? + item.column_span > index) {
            used = true;
            break;
        };
        if (!used) track.size = .{ .min = .{ .fixed = 0 }, .max = .{ .fixed = 0 } };
    }
    for (rows, 0..) |*track, index| {
        if (!track.auto_fit) continue;
        var used = false;
        for (items) |item| if (item.row.? <= index and item.row.? + item.row_span > index) {
            used = true;
            break;
        };
        if (!used) track.size = .{ .min = .{ .fixed = 0 }, .max = .{ .fixed = 0 } };
    }
}

fn sizeColumns(state: anytype, items: []const Item, tracks: []Track, available: f32, gap: f32, alignment: box.JustifyContent) !void {
    initializeTracks(tracks, available);
    for (items) |item| {
        const sizes = try state.measureIntrinsicInline(item.box_id);
        const source = state.tree.boxes.items[item.box_id];
        const contribution = sizes.max_content + source.margin.left + source.margin.right + source.border.left + source.border.right + source.padding.left + source.padding.right;
        growForContribution(tracks, item.column.?, item.column_span, contribution, gap);
    }
    resolveFlexibleTracks(tracks, available, gap);
    if (alignment == .normal) stretchAutoTracks(tracks, available, gap);
}

fn sizeRows(
    state: anytype,
    items: []const Item,
    columns: []const Track,
    rows: []Track,
    content_width: f32,
    specified_height: ?f32,
    column_gap: f32,
    row_gap: f32,
    alignment: box.AlignContent,
) !void {
    _ = content_width;
    initializeTracks(rows, specified_height orelse 0);
    for (items) |item| {
        const width = spanExtent(columns, item.column.?, item.column_span, column_gap);
        const contribution = try measureItemHeight(state, item.box_id, width);
        growForContribution(rows, item.row.?, item.row_span, contribution, row_gap);
    }
    if (specified_height) |height| {
        resolveFlexibleTracks(rows, height, row_gap);
        if (alignment == .stretch) stretchAutoTracks(rows, height, row_gap);
    }
}

fn initializeTracks(tracks: []Track, reference: f32) void {
    for (tracks) |*track| {
        track.base = switch (track.size.min) {
            .fixed => |value| value,
            .percent => |ratio| reference * ratio,
            else => 0,
        };
        switch (track.size.max) {
            .fixed => |value| track.base = @max(track.base, value),
            .percent => |ratio| track.base = @max(track.base, reference * ratio),
            else => {},
        }
    }
}

fn growForContribution(tracks: []Track, start: usize, span: usize, contribution: f32, gap: f32) void {
    if (start >= tracks.len) return;
    const end = @min(start + span, tracks.len);
    var current = gap * @as(f32, @floatFromInt(end - start -| 1));
    var growable: usize = 0;
    for (tracks[start..end]) |track| {
        current += track.base;
        if (trackCanGrow(track)) growable += 1;
    }
    if (contribution <= current or growable == 0) return;
    const share = (contribution - current) / @as(f32, @floatFromInt(growable));
    for (tracks[start..end]) |*track| {
        if (trackCanGrow(track.*)) track.base += share;
    }
}

fn trackCanGrow(track: Track) bool {
    return switch (track.size.max) {
        .fixed, .percent => false,
        .flex => switch (track.size.min) {
            .fixed, .percent => false,
            else => true,
        },
        else => true,
    };
}

fn resolveFlexibleTracks(tracks: []Track, available: f32, gap: f32) void {
    const total_gap = gap * @as(f32, @floatFromInt(tracks.len -| 1));
    var used = total_gap;
    var flex_sum: f32 = 0;
    for (tracks) |track| {
        used += track.base;
        flex_sum += flexFactor(track);
    }
    if (flex_sum <= 0 or available <= used) return;
    const fraction = (available - used) / flex_sum;
    for (tracks) |*track| {
        const factor = flexFactor(track.*);
        if (factor > 0) track.base += fraction * factor;
    }
}

fn flexFactor(track: Track) f32 {
    return switch (track.size.max) {
        .flex => |factor| @max(factor, 0),
        else => 0,
    };
}

fn stretchAutoTracks(tracks: []Track, available: f32, gap: f32) void {
    var used = gap * @as(f32, @floatFromInt(tracks.len -| 1));
    var count: usize = 0;
    for (tracks) |track| {
        used += track.base;
        if (track.size.max == .auto) count += 1;
    }
    if (count == 0 or available <= used) return;
    const share = (available - used) / @as(f32, @floatFromInt(count));
    for (tracks) |*track| {
        if (track.size.max == .auto) track.base += share;
    }
}

fn measureItemHeight(state: anytype, box_id: box.BoxId, area_width: f32) !f32 {
    const source = state.tree.boxes.items[box_id];
    const horizontal_non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
    const forced_width = @max(area_width - source.margin.left - source.margin.right - horizontal_non_content, 0);
    const fragment_start = state.fragments.items.len;
    const pending_start = state.pending_positioned.items.len;
    var cursor_y: f32 = 0;
    const rect = try state.layoutBlockWithOptions(box_id, .{ .width = area_width }, &cursor_y, .{
        .forced_content_width = forced_width,
        .suppress_margin_top = true,
        .suppress_margin_bottom = true,
    });
    state.fragments.items.len = fragment_start;
    state.pending_positioned.items.len = pending_start;
    return rect.height + source.margin.top + source.margin.bottom;
}

fn positionTracks(tracks: []const Track, available: f32, gap: f32, alignment: box.JustifyContent, inline_axis: bool) AxisPositions {
    _ = inline_axis;
    const natural = tracksExtent(tracks, gap);
    const distribution = distributionForJustify(alignment, @max(available - natural, 0), tracks.len);
    var result = AxisPositions{};
    var cursor = distribution.start;
    for (tracks, 0..) |track, index| {
        result.starts[index] = cursor;
        cursor += track.base;
        if (index + 1 < tracks.len) cursor += gap + distribution.between;
    }
    result.extent = @max(cursor, natural);
    return result;
}

fn positionRows(tracks: []const Track, specified_height: ?f32, gap: f32, alignment: box.AlignContent) AxisPositions {
    const natural = tracksExtent(tracks, gap);
    const available = specified_height orelse natural;
    const distribution = distributionForAlign(alignment, @max(available - natural, 0), tracks.len);
    var result = AxisPositions{};
    var cursor = distribution.start;
    for (tracks, 0..) |track, index| {
        result.starts[index] = cursor;
        cursor += track.base;
        if (index + 1 < tracks.len) cursor += gap + distribution.between;
    }
    result.extent = @max(cursor, natural);
    return result;
}

const Distribution = struct { start: f32 = 0, between: f32 = 0 };

fn distributionForJustify(alignment: box.JustifyContent, free: f32, count: usize) Distribution {
    return switch (alignment) {
        .normal, .flexStart => .{},
        .flexEnd => .{ .start = free },
        .center => .{ .start = free / 2 },
        .spaceBetween => if (count > 1) .{ .between = free / @as(f32, @floatFromInt(count - 1)) } else .{},
        .spaceAround => if (count > 0) blk: {
            const between = free / @as(f32, @floatFromInt(count));
            break :blk .{ .start = between / 2, .between = between };
        } else .{},
        .spaceEvenly => if (count > 0) blk: {
            const between = free / @as(f32, @floatFromInt(count + 1));
            break :blk .{ .start = between, .between = between };
        } else .{},
    };
}

fn distributionForAlign(alignment: box.AlignContent, free: f32, count: usize) Distribution {
    return switch (alignment) {
        .stretch, .flexStart => .{},
        .flexEnd => .{ .start = free },
        .center => .{ .start = free / 2 },
        .spaceBetween => if (count > 1) .{ .between = free / @as(f32, @floatFromInt(count - 1)) } else .{},
        .spaceAround => if (count > 0) blk: {
            const between = free / @as(f32, @floatFromInt(count));
            break :blk .{ .start = between / 2, .between = between };
        } else .{},
        .spaceEvenly => if (count > 0) blk: {
            const between = free / @as(f32, @floatFromInt(count + 1));
            break :blk .{ .start = between, .between = between };
        } else .{},
    };
}

fn fragmentRows(state: anytype, items: []const Item, tracks: []const Track, positions: *AxisPositions, content_y: f32, context: fragmentation.Context) void {
    var cumulative_shift: f32 = 0;
    var previous_break_after = box.PageBreak.auto;
    var previous_page_box: ?box.BoxId = null;
    var group_start: ?f32 = null;
    for (tracks, 0..) |track, index| {
        positions.starts[index] += cumulative_shift;
        var absolute_y = content_y + positions.starts[index];
        const break_before = gridRowBreakBefore(state, items, index);
        var boundary_break = if (group_start != null)
            fragmentation.resolveBoundary(previous_break_after, break_before)
        else
            box.PageBreak.auto;
        const current_page_box = gridRowStartPageBox(items, index);
        if (previous_page_box) |previous_id| {
            if (current_page_box) |current_id| {
                boundary_break = fragmentation.resolvePageNameBoundary(state.tree, previous_id, current_id, boundary_break);
            }
        }
        if (boundary_break.isForced()) {
            const forced_start = context.forcedBreakStart(absolute_y, boundary_break);
            const forced_shift = forced_start - absolute_y;
            positions.starts[index] += forced_shift;
            cumulative_shift += forced_shift;
            absolute_y = forced_start;
            if (current_page_box) |current_id| {
                state.recordPageName(forced_start, fragmentation.startPageName(state.tree, current_id));
            }
        }

        var kept_group = false;
        var retain_group = false;
        if (boundary_break.isAvoid() and group_start != null) {
            const group_end = absolute_y + track.base;
            const group_size = group_end - group_start.?;
            retain_group = group_size <= context.extentAt(group_start.?) + 0.0001;
            const group_shift = context.atomicShift(group_start.?, group_size);
            if (group_shift > 0) {
                shiftPositionedRows(positions, index, content_y, group_start.?, group_shift);
                positions.starts[index] += group_shift;
                cumulative_shift += group_shift;
                absolute_y += group_shift;
                group_start.? += group_shift;
                kept_group = true;
            }
        }
        if (!kept_group) {
            const automatic_shift = context.atomicShift(absolute_y, track.base);
            if (automatic_shift > 0) {
                positions.starts[index] += automatic_shift;
                cumulative_shift += automatic_shift;
                absolute_y += automatic_shift;
            }
        }
        if (!retain_group) group_start = absolute_y;
        previous_break_after = gridRowBreakAfter(state, items, index);
        if (gridRowEndPageBox(items, index)) |end_id| previous_page_box = end_id;
    }
    if (tracks.len > 0) positions.extent = positions.starts[tracks.len - 1] + tracks[tracks.len - 1].base;
    if (previous_break_after.isForced()) {
        positions.extent = @max(positions.extent, context.forcedBreakStart(content_y + positions.extent, previous_break_after) - content_y);
    }
}

fn gridRowBreakBefore(state: anytype, items: []const Item, row: usize) box.PageBreak {
    var result = box.PageBreak.auto;
    for (items) |item| {
        if ((item.row orelse 0) != row) continue;
        result = fragmentation.resolveBoundary(result, state.tree.boxes.items[item.box_id].style.page_break_before);
    }
    return result;
}

fn gridRowBreakAfter(state: anytype, items: []const Item, row: usize) box.PageBreak {
    var result = box.PageBreak.auto;
    for (items) |item| {
        const item_row = item.row orelse 0;
        if (item_row + item.row_span - 1 != row) continue;
        result = fragmentation.resolveBoundary(result, state.tree.boxes.items[item.box_id].style.page_break_after);
    }
    return result;
}

fn gridRowStartPageBox(items: []const Item, row: usize) ?box.BoxId {
    for (items) |item| {
        if ((item.row orelse 0) == row) return item.box_id;
    }
    return null;
}

fn gridRowEndPageBox(items: []const Item, row: usize) ?box.BoxId {
    var result: ?box.BoxId = null;
    for (items) |item| {
        const item_row = item.row orelse 0;
        if (item_row + item.row_span - 1 == row) result = item.box_id;
    }
    return result;
}

fn shiftPositionedRows(positions: *AxisPositions, positioned_count: usize, content_y: f32, group_start: f32, shift: f32) void {
    for (positions.starts[0..positioned_count]) |*start| {
        if (content_y + start.* + 0.0001 < group_start) continue;
        start.* += shift;
    }
}

fn layoutItem(state: anytype, item: *Item, container_style: box.Style, area: geometry.Rect) !void {
    const source = state.tree.boxes.items[item.box_id];
    const horizontal_non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
    const vertical_non_content = source.border.top + source.border.bottom + source.padding.top + source.padding.bottom;
    const justify = if (source.kind == .replaced and source.style.justify_self == .auto)
        box.AlignSelf.flexStart
    else
        resolvedSelf(source.style.justify_self, container_style.justify_items);
    const block_alignment = if (source.kind == .replaced and source.style.align_self == .auto)
        box.AlignSelf.flexStart
    else
        resolvedSelf(source.style.align_self, container_style.align_items);
    const stretch_width = justify == .stretch and source.style.width.isAuto() and !source.style.margin_auto.left and !source.style.margin_auto.right;
    const stretch_height = block_alignment == .stretch and source.style.height.isAuto() and !source.style.margin_auto.top and !source.style.margin_auto.bottom;
    const forced_width = if (stretch_width) @max(area.width - source.margin.left - source.margin.right - horizontal_non_content, 0) else null;
    const forced_height = if (stretch_height) @max(area.height - source.margin.top - source.margin.bottom - vertical_non_content, 0) else null;

    item.fragment_start = state.fragments.items.len;
    var cursor_y: f32 = 0;
    item.rect = try state.layoutBlockWithOptions(item.box_id, .{ .width = area.width }, &cursor_y, .{
        .forced_content_width = forced_width,
        .forced_content_height = forced_height,
        .shrink_to_fit = !stretch_width,
        .containing_block_height = area.height,
        .suppress_margin_top = true,
        .suppress_margin_bottom = true,
    });
    item.fragment_end = state.fragments.items.len;

    const free_x = @max(area.width - item.rect.width - source.margin.left - source.margin.right, 0);
    const free_y = @max(area.height - item.rect.height - source.margin.top - source.margin.bottom, 0);
    const margin_x = autoMarginOffset(source.style.margin_auto.left, source.style.margin_auto.right, free_x);
    const margin_y = autoMarginOffset(source.style.margin_auto.top, source.style.margin_auto.bottom, free_y);
    const offset_x = if (source.style.margin_auto.left or source.style.margin_auto.right)
        margin_x
    else
        alignmentOffset(justify, free_x);
    const offset_y = if (source.style.margin_auto.top or source.style.margin_auto.bottom)
        margin_y
    else
        alignmentOffset(block_alignment, free_y);
    const target_x = area.x + source.margin.left + offset_x;
    const target_y = area.y + source.margin.top + offset_y;
    floats.shiftFragments(state.fragments.items[item.fragment_start..item.fragment_end], target_x - item.rect.x, target_y - item.rect.y);
    item.rect.x = target_x;
    item.rect.y = target_y;
}

fn resolvedSelf(self: box.AlignSelf, parent: box.AlignItems) box.AlignSelf {
    if (self != .auto) return self;
    return switch (parent) {
        .stretch => .stretch,
        .flexStart => .flexStart,
        .flexEnd => .flexEnd,
        .center => .center,
        .baseline => .baseline,
    };
}

fn alignmentOffset(alignment: box.AlignSelf, free: f32) f32 {
    return switch (alignment) {
        .auto, .stretch, .flexStart, .baseline => 0,
        .flexEnd => free,
        .center => free / 2,
    };
}

fn autoMarginOffset(start_auto: bool, end_auto: bool, free: f32) f32 {
    if (start_auto and end_auto) return free / 2;
    if (start_auto) return free;
    return 0;
}

fn spanExtent(tracks: []const Track, start: usize, span: usize, gap: f32) f32 {
    if (start >= tracks.len) return 0;
    const end = @min(start + span, tracks.len);
    var extent = gap * @as(f32, @floatFromInt(end - start -| 1));
    for (tracks[start..end]) |track| extent += track.base;
    return extent;
}

fn spanPositionExtent(tracks: []const Track, positions: [max_tracks]f32, start: usize, span: usize, gap: f32) f32 {
    _ = gap;
    if (start >= tracks.len) return 0;
    const end = @min(start + span, tracks.len);
    return positions[end - 1] + tracks[end - 1].base - positions[start];
}

fn tracksExtent(tracks: []const Track, gap: f32) f32 {
    return spanExtent(tracks, 0, tracks.len, gap);
}

fn resolveGap(value: box.Length, reference: f32) f32 {
    return @max(value.resolve(reference) orelse 0, 0);
}

fn ensureTracks(allocator: std.mem.Allocator, target: *Template, count: usize, automatic: *const Template) !void {
    const bounded = @min(count, max_tracks);
    while (target.tracks.items.len < bounded) {
        const index = target.tracks.items.len -| target.explicit_count;
        var track = automatic.tracks.items[index % automatic.tracks.items.len];
        track.names = @splat("");
        track.name_count = 0;
        try target.tracks.append(allocator, track);
    }
}

fn parseTemplate(allocator: std.mem.Allocator, raw_value: []const u8, available: f32, gap: f32, font_size: f32) !Template {
    var result = try Template.init(allocator);
    errdefer result.deinit(allocator);
    const value = std.mem.trim(u8, raw_value, " \t\n\r\x0C");
    if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "none")) return result;
    try appendTrackList(allocator, &result, value, available, gap, font_size, false);
    result.explicit_count = result.tracks.items.len;
    return result;
}

fn appendTrackList(
    allocator: std.mem.Allocator,
    template: *Template,
    value: []const u8,
    available: f32,
    gap: f32,
    font_size: f32,
    auto_fit: bool,
) !void {
    var pending_names: [max_line_names][]const u8 = @splat("");
    var pending_count: usize = 0;
    var index: usize = 0;
    while (nextTrackToken(value, &index)) |token| {
        if (token[0] == '[') {
            var names = std.mem.tokenizeAny(u8, token[1 .. token.len - 1], " \t\n\r\x0C");
            while (names.next()) |name| if (pending_count < pending_names.len) {
                pending_names[pending_count] = name;
                pending_count += 1;
            };
            continue;
        }
        if (startsFunction(token, "repeat")) {
            const inner = functionContents(token);
            const comma = topLevelComma(inner) orelse continue;
            const count_value = std.mem.trim(u8, inner[0..comma], " \t\n\r\x0C");
            const pattern = std.mem.trim(u8, inner[comma + 1 ..], " \t\n\r\x0C");
            var repeat_count: usize = std.fmt.parseInt(usize, count_value, 10) catch 0;
            const is_auto_fit = std.ascii.eqlIgnoreCase(count_value, "auto-fit");
            const is_auto_fill = std.ascii.eqlIgnoreCase(count_value, "auto-fill");
            if (is_auto_fit or is_auto_fill) repeat_count = autoRepeatCount(pattern, available, gap, font_size);
            repeat_count = @min(@max(repeat_count, 1), max_tracks - template.tracks.items.len);
            const first_repeated_track = template.tracks.items.len;
            for (0..repeat_count) |_| try appendTrackList(allocator, template, pattern, available, gap, font_size, is_auto_fit);
            if (pending_count > 0 and first_repeated_track < template.tracks.items.len) {
                const target = &template.tracks.items[first_repeated_track];
                target.name_count = @intCast(pending_count);
                for (pending_names[0..pending_count], 0..) |name, name_index| target.names[name_index] = name;
                pending_count = 0;
            }
            continue;
        }
        var track = Track{ .size = parseTrackSize(token, font_size), .auto_fit = auto_fit };
        track.name_count = @intCast(pending_count);
        for (pending_names[0..pending_count], 0..) |name, name_index| track.names[name_index] = name;
        pending_count = 0;
        if (template.tracks.items.len < max_tracks) try template.tracks.append(allocator, track);
    }
    template.trailing_name_count = @intCast(pending_count);
    for (pending_names[0..pending_count], 0..) |name, name_index| template.trailing_names[name_index] = name;
}

fn nextTrackToken(value: []const u8, index: *usize) ?[]const u8 {
    while (index.* < value.len and std.ascii.isWhitespace(value[index.*])) index.* += 1;
    if (index.* >= value.len) return null;
    const start = index.*;
    if (value[start] == '[') {
        index.* += 1;
        while (index.* < value.len and value[index.*] != ']') index.* += 1;
        if (index.* < value.len) index.* += 1;
        return value[start..index.*];
    }
    var depth: usize = 0;
    while (index.* < value.len) : (index.* += 1) {
        const byte = value[index.*];
        if (byte == '(') depth += 1 else if (byte == ')') depth -|= 1 else if (depth == 0 and std.ascii.isWhitespace(byte)) break;
    }
    return value[start..index.*];
}

fn parseTrackSize(token: []const u8, font_size: f32) TrackSize {
    if (startsFunction(token, "minmax")) {
        const inner = functionContents(token);
        if (topLevelComma(inner)) |comma| return .{
            .min = parseBreadth(inner[0..comma], font_size),
            .max = parseBreadth(inner[comma + 1 ..], font_size),
        };
    }
    if (startsFunction(token, "fit-content")) return .{ .min = .auto, .max = parseBreadth(functionContents(token), font_size) };
    const breadth = parseBreadth(token, font_size);
    return switch (breadth) {
        .flex => .{ .min = .auto, .max = breadth },
        else => .{ .min = breadth, .max = breadth },
    };
}

fn parseBreadth(raw: []const u8, font_size: f32) Breadth {
    const value = std.mem.trim(u8, raw, " \t\n\r\x0C");
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "min-content")) return .minContent;
    if (std.ascii.eqlIgnoreCase(value, "max-content")) return .maxContent;
    if (std.mem.endsWith(u8, value, "fr")) return .{ .flex = parseNumber(value[0 .. value.len - 2]) orelse 1 };
    if (std.mem.endsWith(u8, value, "%")) return .{ .percent = (parseNumber(value[0 .. value.len - 1]) orelse 0) / 100 };
    return .{ .fixed = parseAbsoluteLength(value, font_size) orelse 0 };
}

fn parseAbsoluteLength(value: []const u8, font_size: f32) ?f32 {
    if (std.mem.eql(u8, value, "0")) return 0;
    const units = [_]struct { suffix: []const u8, scale: f32 }{
        .{ .suffix = "px", .scale = 1 },
        .{ .suffix = "pt", .scale = 96.0 / 72.0 },
        .{ .suffix = "pc", .scale = 16 },
        .{ .suffix = "in", .scale = 96 },
        .{ .suffix = "cm", .scale = 96.0 / 2.54 },
        .{ .suffix = "mm", .scale = 96.0 / 25.4 },
        .{ .suffix = "em", .scale = font_size },
        .{ .suffix = "rem", .scale = 16 },
    };
    inline for (units) |unit| if (std.mem.endsWith(u8, value, unit.suffix)) {
        return (parseNumber(value[0 .. value.len - unit.suffix.len]) orelse return null) * unit.scale;
    };
    return null;
}

fn parseNumber(value: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, value, " \t\n\r\x0C")) catch null;
}

fn startsFunction(value: []const u8, name: []const u8) bool {
    return value.len > name.len + 1 and std.ascii.eqlIgnoreCase(value[0..name.len], name) and value[name.len] == '(' and value[value.len - 1] == ')';
}

fn functionContents(value: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, value, '(') orelse return "";
    return value[open + 1 .. value.len - 1];
}

fn topLevelComma(value: []const u8) ?usize {
    var depth: usize = 0;
    for (value, 0..) |byte, index| {
        if (byte == '(') depth += 1 else if (byte == ')') depth -|= 1 else if (byte == ',' and depth == 0) return index;
    }
    return null;
}

fn autoRepeatCount(pattern: []const u8, available: f32, gap: f32, font_size: f32) usize {
    var index: usize = 0;
    var minimum: f32 = 0;
    var count: usize = 0;
    while (nextTrackToken(pattern, &index)) |token| {
        if (token[0] == '[') continue;
        const track = parseTrackSize(token, font_size);
        minimum += switch (track.min) {
            .fixed => |value| value,
            .percent => |ratio| available * ratio,
            else => 1,
        };
        count += 1;
    }
    if (count == 0) return 1;
    minimum += gap * @as(f32, @floatFromInt(count - 1));
    if (minimum <= 0) return 1;
    return @max(@as(usize, @intFromFloat(@floor((available + gap) / (minimum + gap)))), 1);
}

fn parseAreas(allocator: std.mem.Allocator, raw: []const u8) !std.ArrayList(Area) {
    var areas = try std.ArrayList(Area).initCapacity(allocator, 0);
    errdefer areas.deinit(allocator);
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\n\r\x0C"), "none")) return areas;
    var index: usize = 0;
    var row: usize = 0;
    while (index < raw.len) {
        while (index < raw.len and raw[index] != '"' and raw[index] != '\'') index += 1;
        if (index >= raw.len) break;
        const quote = raw[index];
        const start = index + 1;
        index = start;
        while (index < raw.len and raw[index] != quote) index += 1;
        const row_value = raw[start..index];
        var columns = std.mem.tokenizeAny(u8, row_value, " \t\n\r\x0C");
        var column: usize = 0;
        while (columns.next()) |name| : (column += 1) {
            if (std.mem.eql(u8, name, ".")) continue;
            var found: ?usize = null;
            for (areas.items, 0..) |area, area_index| if (std.mem.eql(u8, area.name, name)) {
                found = area_index;
                break;
            };
            if (found) |area_index| {
                areas.items[area_index].row_end = @max(areas.items[area_index].row_end, row + 1);
                areas.items[area_index].column_start = @min(areas.items[area_index].column_start, column);
                areas.items[area_index].column_end = @max(areas.items[area_index].column_end, column + 1);
            } else {
                try areas.append(allocator, .{
                    .name = name,
                    .row_start = row,
                    .row_end = row + 1,
                    .column_start = column,
                    .column_end = column + 1,
                });
            }
        }
        row += 1;
        index += @intFromBool(index < raw.len);
    }
    return areas;
}

test "parse repeat minmax named-line grid templates" {
    const allocator = std.testing.allocator;
    var template = try parseTemplate(allocator, "[start] repeat(2, minmax(40px, 1fr)) [end]", 210, 10, 16);
    defer template.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), template.tracks.items.len);
    try std.testing.expect(template.tracks.items[0].hasName("start"));
    try std.testing.expectEqual(@as(f32, 40), template.tracks.items[0].size.min.fixed);
    try std.testing.expectEqual(@as(f32, 1), template.tracks.items[1].size.max.flex);
    try std.testing.expectEqualStrings("end", template.trailing_names[0]);
}

test "parse named grid areas into rectangular extents" {
    const allocator = std.testing.allocator;
    var areas = try parseAreas(allocator, "\"header header\" \"side main\"");
    defer areas.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), areas.items.len);
    try std.testing.expectEqual(@as(usize, 2), areas.items[0].column_end);
    try std.testing.expectEqual(@as(usize, 1), areas.items[2].row_start);
}
