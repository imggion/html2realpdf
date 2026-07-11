//! Shared geometry and color primitives for layout and rendering.
//!
//! Layout uses CSS pixels. The PDF backend performs the single conversion to
//! points, keeping rounding decisions out of the layout algorithms.

const std = @import("std");

pub const css_px_per_inch: f32 = 96;
pub const pdf_points_per_inch: f32 = 72;
pub const css_px_to_pdf_points: f32 = pdf_points_per_inch / css_px_per_inch;

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn bottom(self: Rect) f32 {
        return self.y + self.height;
    }
};

pub const Color = struct {
    red: f32,
    green: f32,
    blue: f32,
    alpha: f32 = 1,

    pub const black: Color = .{ .red = 0, .green = 0, .blue = 0 };
    pub const white: Color = .{ .red = 1, .green = 1, .blue = 1 };
    pub const transparent: Color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
};

/// Parses the small CSS color subset currently accepted by the renderer.
/// Unsupported values return null so the caller can emit a diagnostic instead
/// of silently painting an arbitrary color.
pub fn parseColor(value: []const u8) ?Color {
    const text = std.mem.trim(u8, value, " \t\n\r\x0C");

    if (namedColor(text)) |color| return color;

    if (std.mem.startsWith(u8, text, "rgb(") or std.mem.startsWith(u8, text, "rgba(")) {
        return parseRgbColor(text);
    }

    if (text.len == 4 and text[0] == '#') {
        return .{
            .red = @as(f32, @floatFromInt(parseHexNibble(text[1]) orelse return null)) / 15,
            .green = @as(f32, @floatFromInt(parseHexNibble(text[2]) orelse return null)) / 15,
            .blue = @as(f32, @floatFromInt(parseHexNibble(text[3]) orelse return null)) / 15,
        };
    }

    if (text.len == 5 and text[0] == '#') {
        return .{
            .red = @as(f32, @floatFromInt(parseHexNibble(text[1]) orelse return null)) / 15,
            .green = @as(f32, @floatFromInt(parseHexNibble(text[2]) orelse return null)) / 15,
            .blue = @as(f32, @floatFromInt(parseHexNibble(text[3]) orelse return null)) / 15,
            .alpha = @as(f32, @floatFromInt(parseHexNibble(text[4]) orelse return null)) / 15,
        };
    }

    if (text.len == 7 and text[0] == '#') {
        return .{
            .red = @as(f32, @floatFromInt(parseHexByte(text[1..3]) orelse return null)) / 255,
            .green = @as(f32, @floatFromInt(parseHexByte(text[3..5]) orelse return null)) / 255,
            .blue = @as(f32, @floatFromInt(parseHexByte(text[5..7]) orelse return null)) / 255,
        };
    }

    if (text.len == 9 and text[0] == '#') {
        return .{
            .red = @as(f32, @floatFromInt(parseHexByte(text[1..3]) orelse return null)) / 255,
            .green = @as(f32, @floatFromInt(parseHexByte(text[3..5]) orelse return null)) / 255,
            .blue = @as(f32, @floatFromInt(parseHexByte(text[5..7]) orelse return null)) / 255,
            .alpha = @as(f32, @floatFromInt(parseHexByte(text[7..9]) orelse return null)) / 255,
        };
    }

    return null;
}

const NamedColor = struct {
    name: []const u8,
    red: u8,
    green: u8,
    blue: u8,
};

const named_colors = [_]NamedColor{
    .{ .name = "aliceblue", .red = 240, .green = 248, .blue = 255 },
    .{ .name = "aqua", .red = 0, .green = 255, .blue = 255 },
    .{ .name = "black", .red = 0, .green = 0, .blue = 0 },
    .{ .name = "blue", .red = 0, .green = 0, .blue = 255 },
    .{ .name = "cyan", .red = 0, .green = 255, .blue = 255 },
    .{ .name = "fuchsia", .red = 255, .green = 0, .blue = 255 },
    .{ .name = "gray", .red = 128, .green = 128, .blue = 128 },
    .{ .name = "green", .red = 0, .green = 128, .blue = 0 },
    .{ .name = "grey", .red = 128, .green = 128, .blue = 128 },
    .{ .name = "lime", .red = 0, .green = 255, .blue = 0 },
    .{ .name = "magenta", .red = 255, .green = 0, .blue = 255 },
    .{ .name = "maroon", .red = 128, .green = 0, .blue = 0 },
    .{ .name = "navy", .red = 0, .green = 0, .blue = 128 },
    .{ .name = "olive", .red = 128, .green = 128, .blue = 0 },
    .{ .name = "orange", .red = 255, .green = 165, .blue = 0 },
    .{ .name = "purple", .red = 128, .green = 0, .blue = 128 },
    .{ .name = "rebeccapurple", .red = 102, .green = 51, .blue = 153 },
    .{ .name = "red", .red = 255, .green = 0, .blue = 0 },
    .{ .name = "silver", .red = 192, .green = 192, .blue = 192 },
    .{ .name = "teal", .red = 0, .green = 128, .blue = 128 },
    .{ .name = "white", .red = 255, .green = 255, .blue = 255 },
    .{ .name = "yellow", .red = 255, .green = 255, .blue = 0 },
};

fn namedColor(text: []const u8) ?Color {
    if (std.ascii.eqlIgnoreCase(text, "transparent")) return Color.transparent;
    for (named_colors) |entry| {
        if (!std.ascii.eqlIgnoreCase(text, entry.name)) continue;
        return .{
            .red = @as(f32, @floatFromInt(entry.red)) / 255,
            .green = @as(f32, @floatFromInt(entry.green)) / 255,
            .blue = @as(f32, @floatFromInt(entry.blue)) / 255,
        };
    }
    return null;
}

fn parseRgbColor(text: []const u8) ?Color {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close <= open) return null;

    var values: [4]f32 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    var parts = std.mem.tokenizeAny(u8, text[open + 1 .. close], " ,/\t\n\r");
    while (parts.next()) |part| {
        if (count >= values.len) return null;
        const is_percent = part.len > 0 and part[part.len - 1] == '%';
        const numeric = if (is_percent) part[0 .. part.len - 1] else part;
        const parsed = std.fmt.parseFloat(f32, numeric) catch return null;
        values[count] = if (is_percent) parsed / 100 else parsed;
        count += 1;
    }
    if (count < 3) return null;

    const alpha = if (count == 4) std.math.clamp(values[3], 0, 1) else 1;
    const red = if (values[0] <= 1 and std.mem.indexOfScalar(u8, text, '%') != null) values[0] else values[0] / 255;
    const green = if (values[1] <= 1 and std.mem.indexOfScalar(u8, text, '%') != null) values[1] else values[1] / 255;
    const blue = if (values[2] <= 1 and std.mem.indexOfScalar(u8, text, '%') != null) values[2] else values[2] / 255;

    return .{
        .red = std.math.clamp(red, 0, 1),
        .green = std.math.clamp(green, 0, 1),
        .blue = std.math.clamp(blue, 0, 1),
        .alpha = alpha,
    };
}

fn parseHexNibble(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

fn parseHexByte(value: []const u8) ?u8 {
    if (value.len != 2) return null;
    const high = parseHexNibble(value[0]) orelse return null;
    const low = parseHexNibble(value[1]) orelse return null;
    return high * 16 + low;
}

test "parse named and hexadecimal colors" {
    try std.testing.expectEqual(Color.black, parseColor("black").?);

    const short = parseColor("#1d4").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 15.0), short.red, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 13.0 / 15.0), short.green, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 15.0), short.blue, 0.0001);

    const long = parseColor("#1d4ed8").?;
    try std.testing.expectApproxEqAbs(@as(f32, 29.0 / 255.0), long.red, 0.0001);
    try std.testing.expect(parseColor("hsl(1, 2%, 3%)") == null);
    const rgb = parseColor("rgb(29, 78, 216)").?;
    try std.testing.expectApproxEqAbs(@as(f32, 29.0 / 255.0), rgb.red, 0.0001);
    const rgba = parseColor("rgba(0, 0, 0, 0.5)").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0), rgba.red, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rgba.alpha, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5333), parseColor("#33669988").?.alpha, 0.0001);
    try std.testing.expectEqual(Color.transparent, parseColor("transparent").?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), parseColor("rebeccapurple").?.red, 0.0001);
}
