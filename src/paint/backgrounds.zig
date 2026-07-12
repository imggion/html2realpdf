//! Native background layers for the Web CSS profile.
//!
//! Layers are parsed from canonical computed longhands at paint time because
//! percentages and gradient stop lengths need the final fragment geometry.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const image_decoder = @import("../image.zig");
const layout = @import("../layout.zig");
const types = @import("types.zig");

const max_parts = 16;
const Parts = struct {
    values: [max_parts][]const u8 = @splat(""),
    len: usize = 0,

    fn slice(self: *const Parts) []const []const u8 {
        return self.values[0..self.len];
    }

    fn atRepeating(self: *const Parts, index: usize, fallback: []const u8) []const u8 {
        return if (self.len == 0) fallback else self.values[index % self.len];
    }
};

const RepeatAxis = enum { repeat, no_repeat, space, round };

const RepeatMode = struct {
    x: RepeatAxis = .repeat,
    y: RepeatAxis = .repeat,
};

const AxisPlan = struct { start: f32, step: f32, count: usize, tile: f32 };

const PaintLength = struct {
    percent: f32 = 0,
    px: f32 = 0,

    fn resolve(self: PaintLength, reference: f32) f32 {
        return self.percent * reference + self.px;
    }

    fn add(self: PaintLength, other: PaintLength, sign: f32) PaintLength {
        return .{
            .percent = self.percent + other.percent * sign,
            .px = self.px + other.px * sign,
        };
    }
};

const Size = struct {
    width: ?PaintLength = null,
    height: ?PaintLength = null,
    fit: ?box.ObjectFit = null,
};

const IntrinsicSize = struct { width: f32, height: f32 };

pub fn append(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
) !void {
    const radii = resolvedRadii(fragment);
    if (fragment.background) |color| try appendColor(allocator, commands, page_index, fragment.rect, radii, color);

    const images = splitTopLevel(fragment.background_image, ',');
    if (images.len == 0) return;
    const positions = splitTopLevel(fragment.background_position, ',');
    const sizes = splitTopLevel(fragment.background_size, ',');
    const repeats = splitTopLevel(fragment.background_repeat, ',');

    var reverse_index = images.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const image_value = trim(images.values[reverse_index]);
        if (equals(image_value, "none")) continue;
        const size = parseSize(sizes.atRepeating(reverse_index, "auto"));
        const repeat = parseRepeat(repeats.atRepeating(reverse_index, "repeat"));
        const source = parseUrl(image_value);
        const intrinsic = if (source) |url| imageIntrinsicSize(allocator, url) else null;
        const tile_size = resolveTileSize(fragment.rect, size, intrinsic);
        if (tile_size.width <= 0 or tile_size.height <= 0) continue;
        const origin = resolvePosition(fragment.rect, tile_size, positions.atRepeating(reverse_index, "0% 0%"));
        try appendLayerTiles(
            allocator,
            commands,
            page_index,
            fragment,
            radii,
            image_value,
            size,
            repeat,
            tile_size,
            origin,
            intrinsic,
        );
    }
}

fn appendColor(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    rect: geometry.Rect,
    radii: box.ResolvedBorderRadii,
    color: geometry.Color,
) !void {
    try commands.append(allocator, .{
        .page_index = page_index,
        .command = if (radii.hasRadius())
            .{ .fill_rounded_rect = .{ .rect = rect, .radii = radii, .color = color } }
        else
            .{ .fill_rect = .{ .rect = rect, .color = color } },
    });
}

fn appendLayerTiles(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
    radii: box.ResolvedBorderRadii,
    image_value: []const u8,
    size: Size,
    repeat: RepeatMode,
    tile_size: geometry.Rect,
    origin: geometry.Point,
    intrinsic: ?IntrinsicSize,
) !void {
    const x_plan = planAxis(fragment.rect.x, fragment.rect.width, tile_size.width, origin.x, repeat.x);
    const y_plan = planAxis(fragment.rect.y, fragment.rect.height, tile_size.height, origin.y, repeat.y);
    var emitted: usize = 0;
    for (0..y_plan.count) |row| {
        const y = y_plan.start + y_plan.step * @as(f32, @floatFromInt(row));
        for (0..x_plan.count) |column| {
            const x = x_plan.start + x_plan.step * @as(f32, @floatFromInt(column));
            const tile = geometry.Rect{ .x = x, .y = y, .width = x_plan.tile, .height = y_plan.tile };
            if (tile.intersection(fragment.rect) == null) continue;
            try appendLayer(allocator, commands, page_index, fragment, radii, image_value, size, tile, intrinsic);
            emitted += 1;
            if (emitted >= 512) return;
        }
    }
}

fn planAxis(paint_start: f32, paint_size: f32, raw_tile: f32, origin: f32, mode: RepeatAxis) AxisPlan {
    const tile = @max(raw_tile, 0.001);
    switch (mode) {
        .no_repeat => return .{ .start = origin, .step = tile, .count = 1, .tile = tile },
        .round => {
            const count = @max(@as(usize, @intFromFloat(@round(paint_size / tile))), 1);
            const rounded_tile = paint_size / @as(f32, @floatFromInt(count));
            return .{ .start = paint_start, .step = rounded_tile, .count = count, .tile = rounded_tile };
        },
        .space => {
            const count: usize = @intFromFloat(@floor(paint_size / tile));
            if (count < 2) return .{ .start = origin, .step = tile, .count = 1, .tile = tile };
            return .{
                .start = paint_start,
                .step = (paint_size - tile) / @as(f32, @floatFromInt(count - 1)),
                .count = count,
                .tile = tile,
            };
        },
        .repeat => {
            var start = origin;
            while (start > paint_start) start -= tile;
            const count = @max(@as(usize, @intFromFloat(@ceil((paint_start + paint_size - start) / tile))), 1);
            return .{ .start = start, .step = tile, .count = count, .tile = tile };
        },
    }
}

fn appendLayer(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(types.PageCommand),
    page_index: usize,
    fragment: layout.Fragment,
    radii: box.ResolvedBorderRadii,
    image_value: []const u8,
    size: Size,
    tile: geometry.Rect,
    intrinsic: ?IntrinsicSize,
) !void {
    if (functionBody(image_value, "linear-gradient")) |body| {
        const gradient = parseLinearGradient(body, tile, fragment.color) orelse return;
        try commands.append(allocator, .{ .page_index = page_index, .command = .{ .linear_gradient = .{
            .paint_rect = fragment.rect,
            .paint_radii = radii,
            .start = gradient.start,
            .end = gradient.end,
            .stops = gradient.stops,
        } } });
        return;
    }
    if (functionBody(image_value, "radial-gradient")) |body| {
        const gradient = parseRadialGradient(body, tile, fragment.color) orelse return;
        try commands.append(allocator, .{ .page_index = page_index, .command = .{ .radial_gradient = .{
            .paint_rect = fragment.rect,
            .paint_radii = radii,
            .center = gradient.center,
            .radius_x = gradient.radius_x,
            .radius_y = gradient.radius_y,
            .stops = gradient.stops,
        } } });
        return;
    }
    if (functionBody(image_value, "conic-gradient")) |body| {
        const gradient = parseConicGradient(body, tile, fragment.color) orelse return;
        try commands.append(allocator, .{ .page_index = page_index, .command = .{ .conic_gradient = .{
            .paint_rect = fragment.rect,
            .paint_radii = radii,
            .center = gradient.center,
            .start_angle = gradient.start_angle,
            .stops = gradient.stops,
        } } });
        return;
    }
    if (parseUrl(image_value)) |source| {
        try commands.append(allocator, .{ .page_index = page_index, .command = .{ .image = .{
            .rect = tile,
            .source = source,
            .intrinsic_width = if (intrinsic) |value| value.width else null,
            .intrinsic_height = if (intrinsic) |value| value.height else null,
            .object_fit = size.fit orelse .fill,
            .paint_clip = fragment.rect,
            .paint_clip_radii = radii,
        } } });
    }
}

const Linear = struct { start: geometry.Point, end: geometry.Point, stops: types.GradientStops };

fn parseLinearGradient(body: []const u8, rect: geometry.Rect, current_color: geometry.Color) ?Linear {
    const args = splitTopLevel(body, ',');
    if (args.len < 2) return null;
    var first_stop: usize = 0;
    var angle: f32 = std.math.pi;
    if (parseLinearDirection(args.values[0])) |parsed| {
        angle = parsed;
        first_stop = 1;
    }
    const center = geometry.Point{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    const direction = geometry.Point{ .x = @sin(angle), .y = -@cos(angle) };
    const extent = @abs(direction.x) * rect.width / 2 + @abs(direction.y) * rect.height / 2;
    const line_length = @max(extent * 2, 0.001);
    return .{
        .start = .{ .x = center.x - direction.x * extent, .y = center.y - direction.y * extent },
        .end = .{ .x = center.x + direction.x * extent, .y = center.y + direction.y * extent },
        .stops = parseStops(args.slice()[first_stop..], line_length, false, current_color) orelse return null,
    };
}

const Radial = struct { center: geometry.Point, radius_x: f32, radius_y: f32, stops: types.GradientStops };

fn parseRadialGradient(body: []const u8, rect: geometry.Rect, current_color: geometry.Color) ?Radial {
    const args = splitTopLevel(body, ',');
    if (args.len < 2) return null;
    var first_stop: usize = 0;
    var center = geometry.Point{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    var circle = false;
    if (geometry.parseColor(trim(args.values[0])) == null and !startsWithColorFunction(args.values[0])) {
        const descriptor = trim(args.values[0]);
        circle = containsWord(descriptor, "circle");
        if (indexOfWord(descriptor, "at")) |at| center = resolvePositionPoint(rect, descriptor[at + 2 ..]);
        first_stop = 1;
    }
    var radius_x = @max(rect.width / 2, 0.001);
    var radius_y = @max(rect.height / 2, 0.001);
    if (circle) {
        const dx = @max(center.x - rect.x, rect.x + rect.width - center.x);
        const dy = @max(center.y - rect.y, rect.y + rect.height - center.y);
        const radius = @sqrt(dx * dx + dy * dy);
        radius_x = radius;
        radius_y = radius;
    }
    return .{
        .center = center,
        .radius_x = radius_x,
        .radius_y = radius_y,
        .stops = parseStops(args.slice()[first_stop..], @max(radius_x, radius_y), false, current_color) orelse return null,
    };
}

const Conic = struct { center: geometry.Point, start_angle: f32, stops: types.GradientStops };

fn parseConicGradient(body: []const u8, rect: geometry.Rect, current_color: geometry.Color) ?Conic {
    const args = splitTopLevel(body, ',');
    if (args.len < 2) return null;
    var first_stop: usize = 0;
    var center = geometry.Point{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    var angle: f32 = 0;
    const descriptor = trim(args.values[0]);
    if (startsWithIgnoreCase(descriptor, "from ") or startsWithIgnoreCase(descriptor, "at ")) {
        const tokens = splitWhitespace(descriptor);
        for (tokens.slice(), 0..) |token, index| {
            if (equals(token, "from") and index + 1 < tokens.len) angle = parseAngle(tokens.values[index + 1]) orelse 0;
            if (equals(token, "at") and index + 1 < tokens.len) {
                const start = tokenOffset(descriptor, tokens.values[index + 1]);
                center = resolvePositionPoint(rect, descriptor[start..]);
                break;
            }
        }
        first_stop = 1;
    }
    return .{
        .center = center,
        .start_angle = angle,
        .stops = parseStops(args.slice()[first_stop..], 1, true, current_color) orelse return null,
    };
}

fn parseStops(values: []const []const u8, reference: f32, angular: bool, current_color: geometry.Color) ?types.GradientStops {
    if (values.len < 2 or values.len > 16) return null;
    var result = types.GradientStops{};
    result.len = @intCast(values.len);
    var specified: [16]bool = @splat(false);
    for (values, 0..) |raw, index| {
        const tokens = splitWhitespace(raw);
        if (tokens.len == 0) return null;
        const color = if (equals(tokens.values[0], "currentColor")) current_color else geometry.parseColor(tokens.values[0]) orelse return null;
        result.values[index].color = color;
        if (tokens.len > 1) {
            const offset = if (angular) parseAngularStop(tokens.values[1]) else parseLengthPercentage(tokens.values[1], reference);
            if (offset) |value| {
                result.values[index].offset = value;
                specified[index] = true;
            }
        }
    }
    if (!specified[0]) {
        result.values[0].offset = 0;
        specified[0] = true;
    }
    const last = values.len - 1;
    if (!specified[last]) {
        result.values[last].offset = 1;
        specified[last] = true;
    }
    var run_start: usize = 0;
    while (run_start < last) {
        var run_end = run_start + 1;
        while (run_end < values.len and !specified[run_end]) run_end += 1;
        const start_value = result.values[run_start].offset;
        const end_value = @max(result.values[run_end].offset, start_value);
        const span: f32 = @floatFromInt(run_end - run_start);
        for (run_start + 1..run_end) |index| {
            const step: f32 = @floatFromInt(index - run_start);
            result.values[index].offset = start_value + (end_value - start_value) * step / span;
        }
        result.values[run_end].offset = end_value;
        run_start = run_end;
    }
    for (result.values[0..values.len]) |*stop| stop.offset = std.math.clamp(stop.offset, 0, 1);
    return result;
}

fn parseLinearDirection(raw: []const u8) ?f32 {
    const value = trim(raw);
    if (parseAngle(value)) |angle| return angle;
    if (!startsWithIgnoreCase(value, "to ")) return null;
    const top = containsWord(value, "top");
    const bottom = containsWord(value, "bottom");
    const left = containsWord(value, "left");
    const right = containsWord(value, "right");
    const x: f32 = if (right) 1 else if (left) -1 else 0;
    const y: f32 = if (bottom) 1 else if (top) -1 else 0;
    if (x == 0 and y == 0) return null;
    return std.math.atan2(x, -y);
}

fn parseAngle(raw: []const u8) ?f32 {
    const value = trim(raw);
    const units = [_]struct { suffix: []const u8, scale: f32 }{
        .{ .suffix = "deg", .scale = @as(f32, std.math.pi) / 180 },
        .{ .suffix = "grad", .scale = @as(f32, std.math.pi) / 200 },
        .{ .suffix = "rad", .scale = 1 },
        .{ .suffix = "turn", .scale = @as(f32, std.math.pi) * 2 },
    };
    inline for (units) |unit| if (endsWithIgnoreCase(value, unit.suffix)) {
        return (std.fmt.parseFloat(f32, trim(value[0 .. value.len - unit.suffix.len])) catch return null) * unit.scale;
    };
    if (equals(value, "0")) return 0;
    return null;
}

fn parseAngularStop(raw: []const u8) ?f32 {
    const value = trim(raw);
    if (value.len > 0 and value[value.len - 1] == '%') return (std.fmt.parseFloat(f32, value[0 .. value.len - 1]) catch return null) / 100;
    return (parseAngle(value) orelse return null) / (@as(f32, std.math.pi) * 2);
}

fn parseLengthPercentage(raw: []const u8, reference: f32) ?f32 {
    const value = trim(raw);
    if (value.len > 0 and value[value.len - 1] == '%') return (std.fmt.parseFloat(f32, value[0 .. value.len - 1]) catch return null) / 100;
    if (endsWithIgnoreCase(value, "px")) return (std.fmt.parseFloat(f32, value[0 .. value.len - 2]) catch return null) / @max(reference, 0.001);
    if (equals(value, "0")) return 0;
    return null;
}

fn parseSize(raw: []const u8) Size {
    const tokens = splitWhitespace(raw);
    if (tokens.len == 1 and equals(tokens.values[0], "cover")) return .{ .fit = .cover };
    if (tokens.len == 1 and equals(tokens.values[0], "contain")) return .{ .fit = .contain };
    return .{
        .width = if (tokens.len > 0) parseBackgroundLength(tokens.values[0]) else null,
        .height = if (tokens.len > 1) parseBackgroundLength(tokens.values[1]) else null,
    };
}

fn parseBackgroundLength(raw: []const u8) ?PaintLength {
    const value = trim(raw);
    if (equals(value, "auto")) return null;
    if (functionBody(value, "calc")) |body| {
        const tokens = splitWhitespace(body);
        if (tokens.len == 0) return null;
        var result = parseBackgroundLengthTerm(tokens.values[0]) orelse return null;
        var index: usize = 1;
        while (index + 1 < tokens.len) : (index += 2) {
            const sign: f32 = if (equals(tokens.values[index], "+")) 1 else if (equals(tokens.values[index], "-")) -1 else return null;
            result = result.add(parseBackgroundLengthTerm(tokens.values[index + 1]) orelse return null, sign);
        }
        if (index != tokens.len) return null;
        return result;
    }
    return parseBackgroundLengthTerm(value);
}

fn parseBackgroundLengthTerm(value: []const u8) ?PaintLength {
    if (value.len > 0 and value[value.len - 1] == '%') return .{ .percent = (std.fmt.parseFloat(f32, value[0 .. value.len - 1]) catch return null) / 100 };
    if (endsWithIgnoreCase(value, "px")) return .{ .px = std.fmt.parseFloat(f32, value[0 .. value.len - 2]) catch return null };
    if (equals(value, "0")) return .{};
    return null;
}

fn resolveTileSize(paint_rect: geometry.Rect, size: Size, intrinsic: ?IntrinsicSize) geometry.Rect {
    if (size.fit != null) return .{ .width = paint_rect.width, .height = paint_rect.height };
    var width = if (size.width) |value| value.resolve(paint_rect.width) else if (intrinsic) |value| value.width else paint_rect.width;
    var height = if (size.height) |value| value.resolve(paint_rect.height) else if (intrinsic) |value| value.height else paint_rect.height;
    if (intrinsic) |value| {
        if (size.width != null and size.height == null and value.width > 0) height = width * value.height / value.width;
        if (size.width == null and size.height != null and value.height > 0) width = height * value.width / value.height;
    }
    return .{ .width = @max(width, 0), .height = @max(height, 0) };
}

fn imageIntrinsicSize(allocator: std.mem.Allocator, source: []const u8) ?IntrinsicSize {
    if (std.mem.startsWith(u8, source, "data:image/png;base64,")) {
        var image = image_decoder.decodePngDataUrl(allocator, source) catch return null;
        defer image.deinit(allocator);
        return .{ .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) };
    }
    if (std.mem.startsWith(u8, source, "data:image/jpeg;base64,") or std.mem.startsWith(u8, source, "data:image/jpg;base64,")) {
        var image = image_decoder.decodeJpegDataUrl(allocator, source) catch return null;
        defer image.deinit(allocator);
        return .{ .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) };
    }
    return null;
}

fn resolvePosition(paint_rect: geometry.Rect, tile: geometry.Rect, raw: []const u8) geometry.Point {
    const point = resolvePositionPoint(.{ .width = paint_rect.width - tile.width, .height = paint_rect.height - tile.height }, raw);
    return .{ .x = paint_rect.x + point.x, .y = paint_rect.y + point.y };
}

fn resolvePositionPoint(rect: geometry.Rect, raw: []const u8) geometry.Point {
    const tokens = splitWhitespace(raw);
    if (tokens.len >= 3) return resolveEdgePosition(rect, tokens);
    var x_token: []const u8 = "50%";
    var y_token: []const u8 = "50%";
    if (tokens.len == 1) {
        if (equals(tokens.values[0], "top") or equals(tokens.values[0], "bottom")) y_token = tokens.values[0] else x_token = tokens.values[0];
    } else if (tokens.len >= 2) {
        x_token = tokens.values[0];
        y_token = tokens.values[1];
        if (equals(x_token, "top") or equals(x_token, "bottom")) {
            const swap = x_token;
            x_token = y_token;
            y_token = swap;
        }
    }
    return .{
        .x = rect.x + resolveAxisPosition(x_token, rect.width, true),
        .y = rect.y + resolveAxisPosition(y_token, rect.height, false),
    };
}

fn resolveEdgePosition(rect: geometry.Rect, tokens: Parts) geometry.Point {
    var x = rect.width / 2;
    var y = rect.height / 2;
    var index: usize = 0;
    while (index < tokens.len) {
        const token = tokens.values[index];
        const next = if (index + 1 < tokens.len) parseBackgroundLength(tokens.values[index + 1]) else null;
        if (equals(token, "left") or equals(token, "right")) {
            const offset = if (next) |length| length.resolve(rect.width) else 0;
            x = if (equals(token, "right")) rect.width - offset else offset;
            if (next != null) index += 1;
        } else if (equals(token, "top") or equals(token, "bottom")) {
            const offset = if (next) |length| length.resolve(rect.height) else 0;
            y = if (equals(token, "bottom")) rect.height - offset else offset;
            if (next != null) index += 1;
        } else if (equals(token, "center")) {
            if (x != rect.width / 2) y = rect.height / 2 else x = rect.width / 2;
        }
        index += 1;
    }
    return .{ .x = rect.x + x, .y = rect.y + y };
}

fn resolveAxisPosition(raw: []const u8, available: f32, horizontal: bool) f32 {
    if (equals(raw, "center")) return available / 2;
    if ((horizontal and equals(raw, "left")) or (!horizontal and equals(raw, "top"))) return 0;
    if ((horizontal and equals(raw, "right")) or (!horizontal and equals(raw, "bottom"))) return available;
    if (parseBackgroundLength(raw)) |value| return value.resolve(available);
    return 0;
}

fn parseRepeat(raw: []const u8) RepeatMode {
    const tokens = splitWhitespace(raw);
    if (tokens.len == 0) return .{};
    if (equals(tokens.values[0], "repeat-x")) return .{ .x = .repeat, .y = .no_repeat };
    if (equals(tokens.values[0], "repeat-y")) return .{ .x = .no_repeat, .y = .repeat };
    const x = parseRepeatAxis(tokens.values[0]);
    const y = if (tokens.len > 1) parseRepeatAxis(tokens.values[1]) else x;
    return .{ .x = x, .y = y };
}

fn parseRepeatAxis(raw: []const u8) RepeatAxis {
    if (equals(raw, "no-repeat")) return .no_repeat;
    if (equals(raw, "space")) return .space;
    if (equals(raw, "round")) return .round;
    return .repeat;
}

fn resolvedRadii(fragment: layout.Fragment) box.ResolvedBorderRadii {
    var result = fragment.border_radii.resolve(fragment.rect.width, fragment.rect.height);
    if (!result.hasRadius() and fragment.border_radius > 0) result = box.ResolvedBorderRadii.uniform(fragment.border_radius);
    return result;
}

fn parseUrl(raw: []const u8) ?[]const u8 {
    const body = functionBody(raw, "url") orelse return null;
    const value = trim(body);
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) return value[1 .. value.len - 1];
    return value;
}

fn functionBody(raw: []const u8, name: []const u8) ?[]const u8 {
    const value = trim(raw);
    if (value.len <= name.len + 2 or !startsWithIgnoreCase(value, name) or value[name.len] != '(' or value[value.len - 1] != ')') return null;
    return value[name.len + 1 .. value.len - 1];
}

fn splitTopLevel(raw: []const u8, delimiter: u8) Parts {
    var result = Parts{};
    var start: usize = 0;
    var index: usize = 0;
    var depth: usize = 0;
    var quote: ?u8 = null;
    while (index <= raw.len) : (index += 1) {
        const at_end = index == raw.len;
        const byte = if (at_end) 0 else raw[index];
        if (!at_end and quote != null) {
            if (byte == '\\' and index + 1 < raw.len) index += 1 else if (byte == quote.?) quote = null;
            continue;
        }
        if (!at_end and (byte == '"' or byte == '\'')) quote = byte else if (!at_end and byte == '(') depth += 1 else if (!at_end and byte == ')') depth -|= 1 else if (at_end or (depth == 0 and byte == delimiter)) {
            if (result.len == result.values.len) break;
            const value = trim(raw[start..index]);
            if (value.len > 0) {
                result.values[result.len] = value;
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
        var quote: ?u8 = null;
        while (index < raw.len) : (index += 1) {
            const byte = raw[index];
            if (quote != null) {
                if (byte == '\\' and index + 1 < raw.len) index += 1 else if (byte == quote.?) quote = null;
                continue;
            }
            if (byte == '"' or byte == '\'') quote = byte else if (byte == '(') depth += 1 else if (byte == ')') depth -|= 1 else if (depth == 0 and std.ascii.isWhitespace(byte)) break;
        }
        result.values[result.len] = raw[start..index];
        result.len += 1;
    }
    return result;
}

fn startsWithColorFunction(raw: []const u8) bool {
    const value = trim(raw);
    return startsWithIgnoreCase(value, "rgb(") or startsWithIgnoreCase(value, "rgba(");
}

fn tokenOffset(haystack: []const u8, token: []const u8) usize {
    return @intFromPtr(token.ptr) - @intFromPtr(haystack.ptr);
}

fn indexOfWord(raw: []const u8, word: []const u8) ?usize {
    var index: usize = 0;
    while (index + word.len <= raw.len) : (index += 1) {
        if ((index == 0 or std.ascii.isWhitespace(raw[index - 1])) and
            (index + word.len == raw.len or std.ascii.isWhitespace(raw[index + word.len])) and
            std.ascii.eqlIgnoreCase(raw[index .. index + word.len], word)) return index;
    }
    return null;
}

fn containsWord(raw: []const u8, word: []const u8) bool {
    return indexOfWord(raw, word) != null;
}

fn equals(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(trim(left), right);
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\n\r\x0C");
}

test "emit native multiple gradient layers with repeat geometry" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(types.PageCommand).initCapacity(allocator, 0);
    defer commands.deinit(allocator);
    try append(allocator, &commands, 0, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .x = 10, .y = 20, .width = 120, .height = 80 },
        .background_image = "linear-gradient(90deg, red 0%, blue 100%), radial-gradient(circle, white, black)",
        .background_size = "40px 40px, auto",
        .background_repeat = "repeat-x, no-repeat",
    });
    try std.testing.expect(commands.items.len >= 4);
    try std.testing.expect(commands.items[0].command == .radial_gradient);
    try std.testing.expect(commands.items[1].command == .linear_gradient);
    try std.testing.expectApproxEqAbs(@as(f32, 40), commands.items[1].command.linear_gradient.end.x - commands.items[1].command.linear_gradient.start.x, 0.01);
}

test "parse conic stops and background URL clipping" {
    const allocator = std.testing.allocator;
    var commands = try std.ArrayList(types.PageCommand).initCapacity(allocator, 0);
    defer commands.deinit(allocator);
    try append(allocator, &commands, 0, .{
        .kind = .box,
        .source_box = 0,
        .rect = .{ .width = 100, .height = 60 },
        .background_image = "conic-gradient(from 45deg at 25% 50%, red 0deg, blue 360deg), url(\"data:image/png;base64,AA==\")",
        .background_repeat = "no-repeat",
        .border_radii = .{ .top_left = .{ .x = .{ .px = 8 }, .y = .{ .px = 8 } } },
    });
    try std.testing.expectEqual(@as(usize, 2), commands.items.len);
    try std.testing.expect(commands.items[0].command == .image);
    try std.testing.expect(commands.items[0].command.image.paint_clip != null);
    try std.testing.expect(commands.items[1].command == .conic_gradient);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi) / 4, commands.items[1].command.conic_gradient.start_angle, 0.001);
}

test "resolve four-value positions and space round repeat axes" {
    const positioned = resolvePosition(
        .{ .x = 10, .y = 20, .width = 200, .height = 100 },
        .{ .width = 40, .height = 20 },
        "right 12px bottom 8px",
    );
    try std.testing.expectApproxEqAbs(@as(f32, 158), positioned.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 92), positioned.y, 0.001);

    const canonical = resolvePosition(
        .{ .x = 10, .y = 20, .width = 200, .height = 100 },
        .{ .width = 40, .height = 20 },
        "calc(100% - 12px) calc(100% - 8px)",
    );
    try std.testing.expectApproxEqAbs(positioned.x, canonical.x, 0.001);
    try std.testing.expectApproxEqAbs(positioned.y, canonical.y, 0.001);

    const calculated_size = resolveTileSize(
        .{ .width = 200, .height = 100 },
        parseSize("calc(50% - 10px) calc(25% + 5px)"),
        null,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 90), calculated_size.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), calculated_size.height, 0.001);

    const spaced = planAxis(0, 100, 30, 15, .space);
    try std.testing.expectEqual(@as(usize, 3), spaced.count);
    try std.testing.expectApproxEqAbs(@as(f32, 35), spaced.step, 0.001);
    const rounded = planAxis(0, 100, 28, 0, .round);
    try std.testing.expectEqual(@as(usize, 4), rounded.count);
    try std.testing.expectApproxEqAbs(@as(f32, 25), rounded.tile, 0.001);
}
