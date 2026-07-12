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

    pub fn intersection(self: Rect, other: Rect) ?Rect {
        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right = @min(self.x + self.width, other.x + other.width);
        const bottom_edge = @min(self.y + self.height, other.y + other.height);
        if (right <= left or bottom_edge <= top) return null;
        return .{ .x = left, .y = top, .width = right - left, .height = bottom_edge - top };
    }
};

/// CSS-space 2D affine transform using the `matrix(a,b,c,d,e,f)` convention.
/// Coordinates keep the browser's downward-positive Y axis until the PDF
/// backend performs the single page-space conjugation.
pub const AffineTransform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: AffineTransform = .{};

    pub fn translation(x: f32, y: f32) AffineTransform {
        return .{ .e = x, .f = y };
    }

    pub fn scaling(x: f32, y: f32) AffineTransform {
        return .{ .a = x, .d = y };
    }

    pub fn rotation(radians: f32) AffineTransform {
        const cosine = @cos(radians);
        const sine = @sin(radians);
        return .{ .a = cosine, .b = sine, .c = -sine, .d = cosine };
    }

    pub fn skewing(x_radians: f32, y_radians: f32) AffineTransform {
        return .{ .b = @tan(y_radians), .c = @tan(x_radians) };
    }

    /// Returns `self * next`, matching CSS transform-list matrix post-multiplication.
    pub fn multiply(self: AffineTransform, next: AffineTransform) AffineTransform {
        return .{
            .a = self.a * next.a + self.c * next.b,
            .b = self.b * next.a + self.d * next.b,
            .c = self.a * next.c + self.c * next.d,
            .d = self.b * next.c + self.d * next.d,
            .e = self.a * next.e + self.c * next.f + self.e,
            .f = self.b * next.e + self.d * next.f + self.f,
        };
    }

    pub fn around(self: AffineTransform, origin: Point) AffineTransform {
        return translation(origin.x, origin.y).multiply(self).multiply(translation(-origin.x, -origin.y));
    }

    pub fn applyPoint(self: AffineTransform, point: Point) Point {
        return .{
            .x = self.a * point.x + self.c * point.y + self.e,
            .y = self.b * point.x + self.d * point.y + self.f,
        };
    }

    pub fn bounds(self: AffineTransform, rect: Rect) Rect {
        const top_left = self.applyPoint(.{ .x = rect.x, .y = rect.y });
        const top_right = self.applyPoint(.{ .x = rect.x + rect.width, .y = rect.y });
        const bottom_right = self.applyPoint(.{ .x = rect.x + rect.width, .y = rect.y + rect.height });
        const bottom_left = self.applyPoint(.{ .x = rect.x, .y = rect.y + rect.height });
        const left = @min(@min(top_left.x, top_right.x), @min(bottom_right.x, bottom_left.x));
        const top = @min(@min(top_left.y, top_right.y), @min(bottom_right.y, bottom_left.y));
        const right = @max(@max(top_left.x, top_right.x), @max(bottom_right.x, bottom_left.x));
        const bottom = @max(@max(top_left.y, top_right.y), @max(bottom_right.y, bottom_left.y));
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }

    pub fn isIdentity(self: AffineTransform) bool {
        return self.approxEqual(identity, 0.0001);
    }

    pub fn approxEqual(self: AffineTransform, other: AffineTransform, tolerance: f32) bool {
        return @abs(self.a - other.a) <= tolerance and @abs(self.b - other.b) <= tolerance and
            @abs(self.c - other.c) <= tolerance and @abs(self.d - other.d) <= tolerance and
            @abs(self.e - other.e) <= tolerance and @abs(self.f - other.f) <= tolerance;
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

test "intersect clipping rectangles" {
    const overlap = (Rect{ .x = 10, .y = 10, .width = 30, .height = 20 }).intersection(.{ .x = 20, .y = 5, .width = 30, .height = 20 }).?;
    try std.testing.expectEqual(@as(f32, 20), overlap.x);
    try std.testing.expectEqual(@as(f32, 10), overlap.y);
    try std.testing.expectEqual(@as(f32, 20), overlap.width);
    try std.testing.expectEqual(@as(f32, 15), overlap.height);
    try std.testing.expect((Rect{ .width = 5, .height = 5 }).intersection(.{ .x = 6, .width = 2, .height = 2 }) == null);
}

test "compose CSS affine transforms and compute transformed bounds" {
    const transform = AffineTransform.translation(10, 20).multiply(AffineTransform.rotation(@as(f32, std.math.pi / 2.0)));
    const point = transform.applyPoint(.{ .x = 4, .y = 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 8), point.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), point.y, 0.001);

    const bounds = AffineTransform.scaling(2, 3).around(.{ .x = 5, .y = 5 }).bounds(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    try std.testing.expectApproxEqAbs(@as(f32, -5), bounds.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -10), bounds.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), bounds.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), bounds.height, 0.001);
}
