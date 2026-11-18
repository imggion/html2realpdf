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

    // Browsers keep modern color spaces in computed values; Tailwind v4 emits
    // its palette as `oklch()` and alpha utilities resolve to `oklab()`.
    if (startsWithIgnoreCase(text, "oklab(")) return parseOklabColor(text, false);
    if (startsWithIgnoreCase(text, "oklch(")) return parseOklabColor(text, true);
    if (startsWithIgnoreCase(text, "color(")) return parseColorFunction(text);

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

pub fn isColorFunction(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \t\n\r\x0C");
    for ([_][]const u8{ "rgb(", "rgba(", "oklab(", "oklch(", "color(" }) |prefix| {
        if (startsWithIgnoreCase(value, prefix)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

/// Space-separated color-function arguments with an optional `/ alpha`.
/// `none` components resolve to zero as CSS Color 4 specifies.
const ColorArguments = struct {
    values: [4]f32 = .{ 0, 0, 0, 1 },
    percent: [4]bool = .{ false, false, false, false },
    count: usize = 0,
    has_alpha: bool = false,
};

fn parseColorArguments(body: []const u8) ?ColorArguments {
    var result = ColorArguments{};
    var parts = std.mem.tokenizeAny(u8, body, " \t\n\r\x0C");
    var saw_slash = false;
    while (parts.next()) |raw_part| {
        var part = raw_part;
        // Accept both `0.5 / 0.2` and the compact `0.5/0.2` spelling.
        while (part.len > 0) {
            if (part[0] == '/') {
                if (saw_slash or result.count != 3) return null;
                saw_slash = true;
                part = part[1..];
                continue;
            }
            const slash = std.mem.indexOfScalar(u8, part, '/');
            const token = if (slash) |index| part[0..index] else part;
            part = if (slash) |index| part[index..] else "";

            const slot = if (saw_slash) 3 else result.count;
            if (saw_slash and result.has_alpha) return null;
            if (!saw_slash and result.count >= 3) return null;

            if (std.ascii.eqlIgnoreCase(token, "none")) {
                result.values[slot] = 0;
            } else {
                const is_percent = token.len > 0 and token[token.len - 1] == '%';
                var numeric = if (is_percent) token[0 .. token.len - 1] else token;
                if (std.ascii.endsWithIgnoreCase(numeric, "deg")) numeric = numeric[0 .. numeric.len - 3];
                const parsed = std.fmt.parseFloat(f32, numeric) catch return null;
                if (!std.math.isFinite(parsed)) return null;
                result.values[slot] = parsed;
                result.percent[slot] = is_percent;
            }
            if (saw_slash) result.has_alpha = true else result.count += 1;
        }
    }
    if (result.count != 3 or (saw_slash and !result.has_alpha)) return null;
    return result;
}

fn colorAlpha(arguments: ColorArguments) f32 {
    const raw = if (arguments.percent[3]) arguments.values[3] / 100 else arguments.values[3];
    return std.math.clamp(raw, 0, 1);
}

fn functionArguments(text: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    if (text[text.len - 1] != ')' or text.len < open + 2) return null;
    return text[open + 1 .. text.len - 1];
}

/// Converts CSS `oklab()`/`oklch()` to sRGB with Björn Ottosson's matrices.
/// Out-of-gamut channels are clipped, matching browsers on sRGB output.
fn parseOklabColor(text: []const u8, polar: bool) ?Color {
    const arguments = parseColorArguments(functionArguments(text) orelse return null) orelse return null;
    const lightness = if (arguments.percent[0]) arguments.values[0] / 100 else arguments.values[0];
    var a: f32 = undefined;
    var b: f32 = undefined;
    if (polar) {
        // 100% chroma is 0.4 in CSS Color 4; hue is in degrees.
        const chroma = @max(if (arguments.percent[1]) arguments.values[1] * 0.4 / 100 else arguments.values[1], 0);
        const hue = arguments.values[2] * std.math.pi / 180;
        a = chroma * @cos(hue);
        b = chroma * @sin(hue);
    } else {
        a = if (arguments.percent[1]) arguments.values[1] * 0.4 / 100 else arguments.values[1];
        b = if (arguments.percent[2]) arguments.values[2] * 0.4 / 100 else arguments.values[2];
    }

    const l_root = lightness + 0.3963377774 * a + 0.2158037573 * b;
    const m_root = lightness - 0.1055613458 * a - 0.0638541728 * b;
    const s_root = lightness - 0.0894841775 * a - 1.2914855480 * b;
    const l = l_root * l_root * l_root;
    const m = m_root * m_root * m_root;
    const s = s_root * s_root * s_root;
    return linearSrgbColor(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        colorAlpha(arguments),
    );
}

/// Parses `color(srgb|srgb-linear|display-p3 r g b [/ a])`; browsers emit it
/// for `color-mix(in srgb, …)` and wide-gamut authored colors.
fn parseColorFunction(text: []const u8) ?Color {
    const body = std.mem.trim(u8, functionArguments(text) orelse return null, " \t\n\r\x0C");
    const space_end = std.mem.indexOfAny(u8, body, " \t\n\r\x0C") orelse return null;
    const space = body[0..space_end];
    const arguments = parseColorArguments(body[space_end..]) orelse return null;
    var channels: [3]f32 = undefined;
    for (0..3) |index| {
        channels[index] = if (arguments.percent[index]) arguments.values[index] / 100 else arguments.values[index];
    }
    const alpha = colorAlpha(arguments);

    if (std.ascii.eqlIgnoreCase(space, "srgb")) {
        return .{
            .red = std.math.clamp(channels[0], 0, 1),
            .green = std.math.clamp(channels[1], 0, 1),
            .blue = std.math.clamp(channels[2], 0, 1),
            .alpha = alpha,
        };
    }
    if (std.ascii.eqlIgnoreCase(space, "srgb-linear")) {
        return linearSrgbColor(channels[0], channels[1], channels[2], alpha);
    }
    if (std.ascii.eqlIgnoreCase(space, "display-p3")) {
        // Display P3 shares the sRGB transfer curve; convert in linear light.
        const red = srgbToLinear(channels[0]);
        const green = srgbToLinear(channels[1]);
        const blue = srgbToLinear(channels[2]);
        return linearSrgbColor(
            1.2249401 * red - 0.2249404 * green,
            -0.0420569 * red + 1.0420571 * green,
            -0.0196376 * red - 0.0786361 * green + 1.0982735 * blue,
            alpha,
        );
    }
    return null;
}

fn linearSrgbColor(red: f32, green: f32, blue: f32, alpha: f32) Color {
    return .{
        .red = std.math.clamp(linearToSrgb(red), 0, 1),
        .green = std.math.clamp(linearToSrgb(green), 0, 1),
        .blue = std.math.clamp(linearToSrgb(blue), 0, 1),
        .alpha = alpha,
    };
}

fn linearToSrgb(value: f32) f32 {
    const magnitude = @abs(value);
    const encoded = if (magnitude <= 0.0031308) magnitude * 12.92 else 1.055 * std.math.pow(f32, magnitude, 1.0 / 2.4) - 0.055;
    return std.math.copysign(encoded, value);
}

fn srgbToLinear(value: f32) f32 {
    const magnitude = @abs(value);
    const decoded = if (magnitude <= 0.04045) magnitude / 12.92 else std.math.pow(f32, (magnitude + 0.055) / 1.055, 2.4);
    return std.math.copysign(decoded, value);
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

test "parse modern CSS color spaces emitted by browser snapshots" {
    // sRGB red expressed in Oklab and Oklch.
    inline for (.{ "oklab(0.627955 0.224863 0.125846)", "oklch(62.7955% 0.257683 29.2339)", "oklch(0.627955 0.257683 29.2339deg)" }) |source| {
        const red = parseColor(source).?;
        try std.testing.expectApproxEqAbs(@as(f32, 1), red.red, 0.002);
        try std.testing.expectApproxEqAbs(@as(f32, 0), red.green, 0.002);
        try std.testing.expectApproxEqAbs(@as(f32, 0), red.blue, 0.002);
        try std.testing.expectEqual(@as(f32, 1), red.alpha);
    }

    // Tailwind v4 `bg-black/40` resolves to an Oklab color with alpha.
    const overlay = parseColor("oklab(0 0 0 / 0.4)").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0), overlay.red, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), overlay.alpha, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), parseColor("oklch(1 0 none/25%)").?.alpha, 0.0001);
    const white = parseColor("oklch(1 0 0)").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), white.green, 0.001);

    const srgb = parseColor("color(srgb 1 0.5 0 / 0.5)").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), srgb.green, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), srgb.alpha, 0.0001);
    const gray = parseColor("color(display-p3 0.5 0.5 0.5)").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), gray.red, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), gray.blue, 0.001);
    const linear = parseColor("color(srgb-linear 0.214041 0.214041 0.214041)").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), linear.red, 0.001);

    try std.testing.expect(parseColor("oklch(0.5 0.1)") == null);
    try std.testing.expect(parseColor("oklch(0.5 0.1 20 0.3)") == null);
    try std.testing.expect(parseColor("color(rec2020 1 0 0)") == null);
    try std.testing.expect(isColorFunction(" oklch(0.5 0.1 20)"));
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
