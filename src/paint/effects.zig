//! Text decoration effects supported without rasterization.

const std = @import("std");
const layout = @import("../layout.zig");
const geometry = @import("../geometry.zig");
const box = @import("../box.zig");
const borders = @import("borders.zig");
const types = @import("types.zig");

const Shadow = struct {
    offset_x: f32,
    offset_y: f32,
    blur: f32 = 0,
    spread: f32 = 0,
    color: geometry.Color,
    inset: bool = false,
};

const Parts = struct {
    values: [16][]const u8 = @splat(""),
    len: usize = 0,

    fn slice(self: *const Parts) []const []const u8 {
        return self.values[0..self.len];
    }
};

pub fn appendOuterBoxShadows(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    return appendBoxShadows(allocator, commands, page_index, fragment, false);
}

pub fn appendInsetBoxShadows(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    return appendBoxShadows(allocator, commands, page_index, fragment, true);
}

fn appendBoxShadows(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
    inset: bool,
) !void {
    const layers = splitTopLevel(fragment.box_shadow, ',');
    var reverse_index = layers.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const shadow = parseShadow(layers.values[reverse_index], fragment.color, true) orelse continue;
        if (shadow.inset != inset) continue;
        var radii = fragment.border_radii.resolve(fragment.rect.width, fragment.rect.height);
        if (!radii.hasRadius() and fragment.border_radius > 0) radii = box.ResolvedBorderRadii.uniform(fragment.border_radius);
        try commands.append(allocator, .{ .page_index = page_index, .command = .{ .box_shadow = .{
            .rect = fragment.rect,
            .radii = radii,
            .offset_x = shadow.offset_x,
            .offset_y = shadow.offset_y,
            .blur = shadow.blur,
            .spread = shadow.spread,
            .color = shadow.color,
            .inset = shadow.inset,
        } } });
    }
}

pub fn appendTextShadows(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    const layers = splitTopLevel(fragment.text_shadow, ',');
    var reverse_index = layers.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const shadow = parseShadow(layers.values[reverse_index], fragment.color, false) orelse continue;
        const samples: usize = if (shadow.blur > 0.01) 9 else 1;
        const sample_alpha = if (samples == 1) shadow.color.alpha else shadow.color.alpha / 3;
        for (0..samples) |sample| {
            const angle = if (sample == 0) @as(f32, 0) else @as(f32, @floatFromInt(sample - 1)) * @as(f32, std.math.pi) / 4;
            const radius = if (sample == 0) @as(f32, 0) else shadow.blur * 0.45;
            try commands.append(allocator, .{
                .page_index = page_index,
                .command = .{ .text = .{
                    .position = .{
                        .x = fragment.rect.x + shadow.offset_x + @cos(angle) * radius,
                        .y = fragment.rect.y + shadow.offset_y + @sin(angle) * radius,
                    },
                    .width = fragment.rect.width,
                    .text = fragment.text orelse "",
                    .shaped = fragment.shaped,
                    .leading_space = fragment.leading_space,
                    .font_size = fragment.font_size,
                    .font_family = fragment.font_family,
                    .letter_spacing = fragment.letter_spacing,
                    .word_spacing = fragment.word_spacing,
                    .font_weight = fragment.font_weight,
                    .font_style = fragment.font_style,
                    .color = .{
                        .red = shadow.color.red,
                        .green = shadow.color.green,
                        .blue = shadow.color.blue,
                        .alpha = sample_alpha,
                    },
                    .artifact = true,
                } },
            });
        }
    }
}

fn parseShadow(raw: []const u8, current_color: geometry.Color, allow_spread: bool) ?Shadow {
    const value = std.mem.trim(u8, raw, " \t\n\r\x0C");
    if (std.ascii.eqlIgnoreCase(value, "none")) return null;
    const tokens = splitWhitespace(value);
    var lengths: [4]f32 = @splat(0);
    var length_count: usize = 0;
    var color = current_color;
    var inset = false;
    for (tokens.slice()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "inset")) {
            inset = true;
        } else if (std.ascii.eqlIgnoreCase(token, "currentColor")) {
            color = current_color;
        } else if (geometry.parseColor(token)) |parsed| {
            color = parsed;
        } else if (parsePx(token)) |length| {
            if (length_count == lengths.len) return null;
            lengths[length_count] = length;
            length_count += 1;
        } else {
            return null;
        }
    }
    if (length_count < 2 or (!allow_spread and inset)) return null;
    return .{
        .offset_x = lengths[0],
        .offset_y = lengths[1],
        .blur = if (length_count > 2) @max(lengths[2], 0) else 0,
        .spread = if (allow_spread and length_count > 3) lengths[3] else 0,
        .color = color,
        .inset = inset,
    };
}

fn parsePx(raw: []const u8) ?f32 {
    const value = std.mem.trim(u8, raw, " \t\n\r\x0C");
    if (std.ascii.eqlIgnoreCase(value, "0")) return 0;
    if (value.len < 3 or !std.ascii.eqlIgnoreCase(value[value.len - 2 ..], "px")) return null;
    return std.fmt.parseFloat(f32, value[0 .. value.len - 2]) catch null;
}

fn splitTopLevel(raw: []const u8, delimiter: u8) Parts {
    var result = Parts{};
    var start: usize = 0;
    var index: usize = 0;
    var depth: usize = 0;
    while (index <= raw.len) : (index += 1) {
        const at_end = index == raw.len;
        const byte = if (at_end) 0 else raw[index];
        if (!at_end and byte == '(') depth += 1 else if (!at_end and byte == ')') depth -|= 1 else if (at_end or (depth == 0 and byte == delimiter)) {
            if (result.len == result.values.len) break;
            const part = std.mem.trim(u8, raw[start..index], " \t\n\r\x0C");
            if (part.len > 0) {
                result.values[result.len] = part;
                result.len += 1;
            }
            start = index + 1;
        }
    }
    return result;
}

fn splitWhitespace(raw: []const u8) Parts {
    var result = Parts{};
    var index: usize = 0;
    while (index < raw.len) {
        while (index < raw.len and std.ascii.isWhitespace(raw[index])) index += 1;
        if (index >= raw.len or result.len == result.values.len) break;
        const start = index;
        var depth: usize = 0;
        while (index < raw.len) : (index += 1) {
            if (raw[index] == '(') depth += 1 else if (raw[index] == ')') depth -|= 1 else if (depth == 0 and std.ascii.isWhitespace(raw[index])) break;
        }
        result.values[result.len] = raw[start..index];
        result.len += 1;
    }
    return result;
}

pub fn appendTextDecoration(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    if (fragment.text_decoration == .none) return;
    const thickness = fragment.text_decoration_thickness orelse @max(fragment.font_size / 16, 0.75);
    if (thickness <= 0) return;
    const color = fragment.text_decoration_color orelse fragment.color;
    if (fragment.text_decoration.hasOverline()) try appendDecorationLine(
        allocator,
        commands,
        page_index,
        fragment.rect,
        fragment.rect.y + fragment.font_size * 0.12,
        thickness,
        color,
        fragment.text_decoration_style,
    );
    if (fragment.text_decoration.hasLineThrough()) try appendDecorationLine(
        allocator,
        commands,
        page_index,
        fragment.rect,
        fragment.rect.y + fragment.font_size * 0.55,
        thickness,
        color,
        fragment.text_decoration_style,
    );
    if (fragment.text_decoration.hasUnderline()) try appendDecorationLine(
        allocator,
        commands,
        page_index,
        fragment.rect,
        fragment.rect.y + fragment.font_size * 1.02,
        thickness,
        color,
        fragment.text_decoration_style,
    );
}

fn appendDecorationLine(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    rect: geometry.Rect,
    y: f32,
    thickness: f32,
    color: geometry.Color,
    style: box.TextDecorationStyle,
) !void {
    if (style == .wavy) return appendWavyLine(allocator, commands, page_index, rect, y, thickness, color);
    const line_style: box.BorderStyle = switch (style) {
        .solid, .double => .solid,
        .dotted => .dotted,
        .dashed => .dashed,
        .wavy => unreachable,
    };
    try borders.appendLine(
        allocator,
        commands,
        page_index,
        .{ .x = rect.x, .y = y },
        .{ .x = rect.x + rect.width, .y = y },
        thickness,
        color,
        line_style,
    );
    if (style == .double) try borders.appendLine(
        allocator,
        commands,
        page_index,
        .{ .x = rect.x, .y = y + thickness * 1.8 },
        .{ .x = rect.x + rect.width, .y = y + thickness * 1.8 },
        thickness,
        color,
        .solid,
    );
}

fn appendWavyLine(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    rect: geometry.Rect,
    y: f32,
    thickness: f32,
    color: geometry.Color,
) !void {
    const step = @max(thickness * 2.5, 2);
    const amplitude = @max(thickness, 0.75);
    var x = rect.x;
    var direction: f32 = -1;
    while (x < rect.x + rect.width) {
        const next_x = @min(x + step, rect.x + rect.width);
        try borders.appendLine(
            allocator,
            commands,
            page_index,
            .{ .x = x, .y = y + amplitude * direction },
            .{ .x = next_x, .y = y - amplitude * direction },
            thickness,
            color,
            .solid,
        );
        direction *= -1;
        x = next_x;
    }
}

test "emit combined double decorations with explicit paint" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(types.PageCommand).initCapacity(allocator, 0);
    defer commands.deinit(allocator);
    try appendTextDecoration(allocator, &commands, 0, .{
        .kind = .text,
        .source_box = 0,
        .rect = .{ .x = 10, .y = 20, .width = 80, .height = 24 },
        .font_size = 20,
        .text_decoration = .all,
        .text_decoration_style = .double,
        .text_decoration_color = .{ .red = 0.7, .green = 0.1, .blue = 0.3 },
        .text_decoration_thickness = 2,
    });
    try std.testing.expectEqual(@as(usize, 6), commands.items.len);
    for (commands.items) |command| {
        try std.testing.expect(command.command == .stroke_line);
        try std.testing.expectEqual(@as(f32, 2), command.command.stroke_line.width);
        try std.testing.expectApproxEqAbs(@as(f32, 0.7), command.command.stroke_line.color.red, 0.001);
    }
}

test "emit wavy decorations as vector segments" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(types.PageCommand).initCapacity(allocator, 0);
    defer commands.deinit(allocator);
    try appendTextDecoration(allocator, &commands, 0, .{
        .kind = .text,
        .source_box = 0,
        .rect = .{ .width = 30, .height = 18 },
        .font_size = 16,
        .text_decoration = .underline,
        .text_decoration_style = .wavy,
    });
    try std.testing.expect(commands.items.len >= 6);
    for (commands.items) |command| try std.testing.expect(command.command == .stroke_line);
}
