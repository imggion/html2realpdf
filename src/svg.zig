//! Safe, allocation-bounded SVG shape parsing for native PDF vector paint.
//!
//! The browser snapshot admits only a deliberately small SVG subset. This
//! module independently validates that subset and lowers geometry into paths;
//! unsupported SVG never degrades silently inside the PDF backend.

const std = @import("std");
const geometry = @import("geometry.zig");

pub const Error = error{
    UnsupportedSvg,
    InvalidDataUrl,
    InvalidSvg,
    SvgTooComplex,
};

const max_shapes = 4096;
const max_path_ops = 65_536;
const max_depth = 64;
const kappa: f32 = 0.5522847498307936;

pub const FillRule = enum { nonzero, evenodd };
pub const LineCap = enum { butt, round, square };
pub const LineJoin = enum { miter, round, bevel };

pub const Style = struct {
    fill: ?geometry.Color = geometry.Color.black,
    stroke: ?geometry.Color = null,
    fill_rule: FillRule = .nonzero,
    stroke_width: f32 = 1,
    line_cap: LineCap = .butt,
    line_join: LineJoin = .miter,
    miter_limit: f32 = 4,
    dash_values: [16]f32 = @splat(0),
    dash_len: u8 = 0,
    dash_offset: f32 = 0,
};

pub const Cubic = struct {
    control1: geometry.Point,
    control2: geometry.Point,
    end: geometry.Point,
};

pub const PathOp = union(enum) {
    move_to: geometry.Point,
    line_to: geometry.Point,
    cubic_to: Cubic,
    close,
};

pub const Shape = struct {
    first_op: usize,
    op_count: usize,
    transform: geometry.AffineTransform = .identity,
    style: Style,
};

const PreserveAspectRatio = struct {
    none: bool = false,
    slice: bool = false,
    align_x: enum { min, mid, max } = .mid,
    align_y: enum { min, mid, max } = .mid,
};

pub const Document = struct {
    ops: std.ArrayList(PathOp),
    shapes: std.ArrayList(Shape),
    view_box: geometry.Rect,
    preserve_aspect_ratio: PreserveAspectRatio = .{},

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        self.ops.deinit(allocator);
        self.shapes.deinit(allocator);
        self.* = undefined;
    }

    /// Maps SVG user coordinates into a unit-square Form XObject whose Y axis
    /// follows PDF coordinates. The caller scales that unit square to the
    /// replaced element's final CSS rectangle.
    pub fn formTransform(self: Document, viewport_width: f32, viewport_height: f32) geometry.AffineTransform {
        const view = self.view_box;
        const target_width = @max(viewport_width, 0.001);
        const target_height = @max(viewport_height, 0.001);
        if (self.preserve_aspect_ratio.none) {
            return .{
                .a = 1 / view.width,
                .d = -1 / view.height,
                .e = -view.x / view.width,
                .f = 1 + view.y / view.height,
            };
        }

        const scale_x = target_width / view.width;
        const scale_y = target_height / view.height;
        const scale = if (self.preserve_aspect_ratio.slice) @max(scale_x, scale_y) else @min(scale_x, scale_y);
        const painted_width = view.width * scale;
        const painted_height = view.height * scale;
        const remaining_x = target_width - painted_width;
        const remaining_y = target_height - painted_height;
        const offset_x = switch (self.preserve_aspect_ratio.align_x) {
            .min => 0,
            .mid => remaining_x / 2,
            .max => remaining_x,
        };
        const offset_y = switch (self.preserve_aspect_ratio.align_y) {
            .min => 0,
            .mid => remaining_y / 2,
            .max => remaining_y,
        };
        return .{
            .a = scale / target_width,
            .d = -scale / target_height,
            .e = (offset_x - view.x * scale) / target_width,
            .f = 1 - (offset_y - view.y * scale) / target_height,
        };
    }
};

const NodeState = struct {
    transform: geometry.AffineTransform = .identity,
    style: Style = .{},
    hidden: bool = false,
};

pub fn isDataUrl(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "data:image/svg+xml;base64,");
}

pub fn parseDataUrl(allocator: std.mem.Allocator, source: []const u8) !Document {
    const prefix = "data:image/svg+xml;base64,";
    if (!std.mem.startsWith(u8, source, prefix)) return Error.UnsupportedSvg;
    const encoded = source[prefix.len..];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return Error.InvalidDataUrl;
    if (decoded_len > 8 * 1024 * 1024) return Error.SvgTooComplex;
    const xml = try allocator.alloc(u8, decoded_len);
    defer allocator.free(xml);
    std.base64.standard.Decoder.decode(xml, encoded) catch return Error.InvalidDataUrl;
    return parseXml(allocator, xml);
}

fn parseXml(allocator: std.mem.Allocator, xml: []const u8) !Document {
    var document = Document{
        .ops = try std.ArrayList(PathOp).initCapacity(allocator, 0),
        .shapes = try std.ArrayList(Shape).initCapacity(allocator, 0),
        .view_box = .{ .width = 300, .height = 150 },
    };
    errdefer document.deinit(allocator);

    var states: [max_depth]NodeState = undefined;
    states[0] = .{};
    var depth: usize = 1;
    var saw_root = false;
    var index: usize = 0;
    while (index < xml.len) {
        const open = std.mem.indexOfScalarPos(u8, xml, index, '<') orelse break;
        if (std.mem.startsWith(u8, xml[open..], "<!--")) {
            const close = std.mem.indexOfPos(u8, xml, open + 4, "-->") orelse return Error.InvalidSvg;
            index = close + 3;
            continue;
        }
        const close = findTagEnd(xml, open + 1) orelse return Error.InvalidSvg;
        var raw = trim(xml[open + 1 .. close]);
        index = close + 1;
        if (raw.len == 0 or raw[0] == '?' or raw[0] == '!') continue;
        if (raw[0] == '/') {
            if (depth > 1) depth -= 1 else return Error.InvalidSvg;
            continue;
        }

        const self_closing = raw[raw.len - 1] == '/';
        if (self_closing) raw = trim(raw[0 .. raw.len - 1]);
        const name_end = tokenEnd(raw, 0);
        const name = raw[0..name_end];
        const attributes = raw[name_end..];
        const parent = states[depth - 1];
        var state = parent;
        state.hidden = parent.hidden or isHidden(attributes);
        const is_root = !saw_root;
        try validateNode(attributes, is_root);
        applyStyle(&state.style, attributes) catch return Error.UnsupportedSvg;

        if (is_root) {
            if (!equals(name, "svg")) return Error.InvalidSvg;
            saw_root = true;
            document.view_box = parseRootViewBox(attributes) orelse return Error.InvalidSvg;
            document.preserve_aspect_ratio = parsePreserveAspectRatio(attribute(attributes, "preserveAspectRatio"));
        } else {
            if (equals(name, "svg")) return Error.UnsupportedSvg;
            const transform_value = styleProperty(attribute(attributes, "style"), "transform") orelse attribute(attributes, "transform");
            if (transform_value) |value| {
                if (!equals(value, "none")) state.transform = parent.transform.multiply(parseTransform(value) catch return Error.UnsupportedSvg);
            }
        }

        if (!state.hidden) {
            if (equals(name, "path")) {
                try appendPathShape(allocator, &document, state, attribute(attributes, "d") orelse return Error.InvalidSvg);
            } else if (equals(name, "rect")) {
                try appendRectShape(allocator, &document, state, attributes);
            } else if (equals(name, "circle")) {
                try appendEllipseShape(allocator, &document, state, attributes, true);
            } else if (equals(name, "ellipse")) {
                try appendEllipseShape(allocator, &document, state, attributes, false);
            } else if (equals(name, "line")) {
                try appendLineShape(allocator, &document, state, attributes);
            } else if (equals(name, "polyline") or equals(name, "polygon")) {
                try appendPolyShape(allocator, &document, state, attributes, equals(name, "polygon"));
            } else if (!equals(name, "svg") and !equals(name, "g") and !equals(name, "title") and !equals(name, "desc")) {
                return Error.UnsupportedSvg;
            }
        }

        if (!self_closing) {
            if (depth == states.len) return Error.SvgTooComplex;
            states[depth] = state;
            depth += 1;
        }
    }
    if (!saw_root or document.shapes.items.len == 0) return Error.InvalidSvg;
    return document;
}

fn appendPathShape(allocator: std.mem.Allocator, document: *Document, state: NodeState, raw: []const u8) !void {
    const first = document.ops.items.len;
    var parser = PathParser{ .source = raw };
    try parser.parse(allocator, &document.ops);
    try appendShape(allocator, document, state, first);
}

fn appendRectShape(allocator: std.mem.Allocator, document: *Document, state: NodeState, attributes: []const u8) !void {
    const x = parseNumber(attribute(attributes, "x") orelse "0") orelse return Error.InvalidSvg;
    const y = parseNumber(attribute(attributes, "y") orelse "0") orelse return Error.InvalidSvg;
    const width = parseNumber(attribute(attributes, "width") orelse return Error.InvalidSvg) orelse return Error.InvalidSvg;
    const height = parseNumber(attribute(attributes, "height") orelse return Error.InvalidSvg) orelse return Error.InvalidSvg;
    if (width <= 0 or height <= 0) return;
    var rx = parseNumber(attribute(attributes, "rx") orelse "0") orelse return Error.InvalidSvg;
    var ry = parseNumber(attribute(attributes, "ry") orelse "0") orelse return Error.InvalidSvg;
    if (rx > 0 and ry == 0) ry = rx;
    if (ry > 0 and rx == 0) rx = ry;
    rx = @min(@abs(rx), width / 2);
    ry = @min(@abs(ry), height / 2);
    const first = document.ops.items.len;
    if (rx == 0 or ry == 0) {
        try appendOp(allocator, &document.ops, .{ .move_to = .{ .x = x, .y = y } });
        try appendOp(allocator, &document.ops, .{ .line_to = .{ .x = x + width, .y = y } });
        try appendOp(allocator, &document.ops, .{ .line_to = .{ .x = x + width, .y = y + height } });
        try appendOp(allocator, &document.ops, .{ .line_to = .{ .x = x, .y = y + height } });
        try appendOp(allocator, &document.ops, .close);
    } else {
        try appendRoundedRect(allocator, &document.ops, x, y, width, height, rx, ry);
    }
    try appendShape(allocator, document, state, first);
}

fn appendRoundedRect(allocator: std.mem.Allocator, ops: *std.ArrayList(PathOp), x: f32, y: f32, width: f32, height: f32, rx: f32, ry: f32) !void {
    try appendOp(allocator, ops, .{ .move_to = .{ .x = x + rx, .y = y } });
    try appendOp(allocator, ops, .{ .line_to = .{ .x = x + width - rx, .y = y } });
    try appendOp(allocator, ops, .{ .cubic_to = .{ .control1 = .{ .x = x + width - rx + rx * kappa, .y = y }, .control2 = .{ .x = x + width, .y = y + ry - ry * kappa }, .end = .{ .x = x + width, .y = y + ry } } });
    try appendOp(allocator, ops, .{ .line_to = .{ .x = x + width, .y = y + height - ry } });
    try appendOp(allocator, ops, .{ .cubic_to = .{ .control1 = .{ .x = x + width, .y = y + height - ry + ry * kappa }, .control2 = .{ .x = x + width - rx + rx * kappa, .y = y + height }, .end = .{ .x = x + width - rx, .y = y + height } } });
    try appendOp(allocator, ops, .{ .line_to = .{ .x = x + rx, .y = y + height } });
    try appendOp(allocator, ops, .{ .cubic_to = .{ .control1 = .{ .x = x + rx - rx * kappa, .y = y + height }, .control2 = .{ .x = x, .y = y + height - ry + ry * kappa }, .end = .{ .x = x, .y = y + height - ry } } });
    try appendOp(allocator, ops, .{ .line_to = .{ .x = x, .y = y + ry } });
    try appendOp(allocator, ops, .{ .cubic_to = .{ .control1 = .{ .x = x, .y = y + ry - ry * kappa }, .control2 = .{ .x = x + rx - rx * kappa, .y = y }, .end = .{ .x = x + rx, .y = y } } });
    try appendOp(allocator, ops, .close);
}

fn appendEllipseShape(allocator: std.mem.Allocator, document: *Document, state: NodeState, attributes: []const u8, circle: bool) !void {
    const cx = parseNumber(attribute(attributes, "cx") orelse "0") orelse return Error.InvalidSvg;
    const cy = parseNumber(attribute(attributes, "cy") orelse "0") orelse return Error.InvalidSvg;
    const rx = parseNumber(attribute(attributes, if (circle) "r" else "rx") orelse return Error.InvalidSvg) orelse return Error.InvalidSvg;
    const ry = if (circle) rx else parseNumber(attribute(attributes, "ry") orelse return Error.InvalidSvg) orelse return Error.InvalidSvg;
    if (rx <= 0 or ry <= 0) return;
    const first = document.ops.items.len;
    try appendOp(allocator, &document.ops, .{ .move_to = .{ .x = cx + rx, .y = cy } });
    try appendOp(allocator, &document.ops, .{ .cubic_to = .{ .control1 = .{ .x = cx + rx, .y = cy + ry * kappa }, .control2 = .{ .x = cx + rx * kappa, .y = cy + ry }, .end = .{ .x = cx, .y = cy + ry } } });
    try appendOp(allocator, &document.ops, .{ .cubic_to = .{ .control1 = .{ .x = cx - rx * kappa, .y = cy + ry }, .control2 = .{ .x = cx - rx, .y = cy + ry * kappa }, .end = .{ .x = cx - rx, .y = cy } } });
    try appendOp(allocator, &document.ops, .{ .cubic_to = .{ .control1 = .{ .x = cx - rx, .y = cy - ry * kappa }, .control2 = .{ .x = cx - rx * kappa, .y = cy - ry }, .end = .{ .x = cx, .y = cy - ry } } });
    try appendOp(allocator, &document.ops, .{ .cubic_to = .{ .control1 = .{ .x = cx + rx * kappa, .y = cy - ry }, .control2 = .{ .x = cx + rx, .y = cy - ry * kappa }, .end = .{ .x = cx + rx, .y = cy } } });
    try appendOp(allocator, &document.ops, .close);
    try appendShape(allocator, document, state, first);
}

fn appendLineShape(allocator: std.mem.Allocator, document: *Document, state: NodeState, attributes: []const u8) !void {
    const first = document.ops.items.len;
    try appendOp(allocator, &document.ops, .{ .move_to = .{
        .x = parseNumber(attribute(attributes, "x1") orelse "0") orelse return Error.InvalidSvg,
        .y = parseNumber(attribute(attributes, "y1") orelse "0") orelse return Error.InvalidSvg,
    } });
    try appendOp(allocator, &document.ops, .{ .line_to = .{
        .x = parseNumber(attribute(attributes, "x2") orelse "0") orelse return Error.InvalidSvg,
        .y = parseNumber(attribute(attributes, "y2") orelse "0") orelse return Error.InvalidSvg,
    } });
    try appendShape(allocator, document, state, first);
}

fn appendPolyShape(allocator: std.mem.Allocator, document: *Document, state: NodeState, attributes: []const u8, closed: bool) !void {
    const points = attribute(attributes, "points") orelse return Error.InvalidSvg;
    var scanner = NumberScanner{ .source = points };
    const first = document.ops.items.len;
    var count: usize = 0;
    while (scanner.next()) |x| {
        const y = scanner.next() orelse return Error.InvalidSvg;
        try appendOp(allocator, &document.ops, if (count == 0) .{ .move_to = .{ .x = x, .y = y } } else .{ .line_to = .{ .x = x, .y = y } });
        count += 1;
    }
    if (count < 2) return Error.InvalidSvg;
    if (closed) try appendOp(allocator, &document.ops, .close);
    try appendShape(allocator, document, state, first);
}

fn appendShape(allocator: std.mem.Allocator, document: *Document, state: NodeState, first: usize) !void {
    if (document.shapes.items.len >= max_shapes) return Error.SvgTooComplex;
    const count = document.ops.items.len - first;
    if (count == 0) return;
    try document.shapes.append(allocator, .{
        .first_op = first,
        .op_count = count,
        .transform = state.transform,
        .style = state.style,
    });
}

fn appendOp(allocator: std.mem.Allocator, ops: *std.ArrayList(PathOp), op: PathOp) !void {
    if (ops.items.len >= max_path_ops) return Error.SvgTooComplex;
    try ops.append(allocator, op);
}

const PathParser = struct {
    source: []const u8,
    index: usize = 0,
    current: geometry.Point = .{},
    subpath_start: geometry.Point = .{},
    last_cubic_control: ?geometry.Point = null,
    last_quadratic_control: ?geometry.Point = null,
    command: u8 = 0,

    fn parse(self: *PathParser, allocator: std.mem.Allocator, ops: *std.ArrayList(PathOp)) !void {
        while (true) {
            self.skipSeparators();
            if (self.index >= self.source.len) break;
            if (std.ascii.isAlphabetic(self.source[self.index])) {
                self.command = self.source[self.index];
                self.index += 1;
            } else if (self.command == 0) return Error.InvalidSvg;
            try self.consumeCommand(allocator, ops);
        }
    }

    fn consumeCommand(self: *PathParser, allocator: std.mem.Allocator, ops: *std.ArrayList(PathOp)) !void {
        const lower = std.ascii.toLower(self.command);
        const relative = std.ascii.isLower(self.command);
        if (lower == 'z') {
            try appendOp(allocator, ops, .close);
            self.current = self.subpath_start;
            self.resetControls();
            self.command = 0;
            return;
        }

        var consumed = false;
        while (self.hasNumber()) {
            consumed = true;
            switch (lower) {
                'm' => {
                    const point = try self.readPoint(relative);
                    if (self.command == 'm' or self.command == 'M') {
                        try appendOp(allocator, ops, .{ .move_to = point });
                        self.subpath_start = point;
                        self.command = if (relative) 'l' else 'L';
                    } else try appendOp(allocator, ops, .{ .line_to = point });
                    self.current = point;
                    self.resetControls();
                },
                'l' => {
                    const point = try self.readPoint(relative);
                    try appendOp(allocator, ops, .{ .line_to = point });
                    self.current = point;
                    self.resetControls();
                },
                'h' => {
                    var x = try self.readNumber();
                    if (relative) x += self.current.x;
                    self.current.x = x;
                    try appendOp(allocator, ops, .{ .line_to = self.current });
                    self.resetControls();
                },
                'v' => {
                    var y = try self.readNumber();
                    if (relative) y += self.current.y;
                    self.current.y = y;
                    try appendOp(allocator, ops, .{ .line_to = self.current });
                    self.resetControls();
                },
                'c' => {
                    const control1 = try self.readPoint(relative);
                    const control2 = try self.readPoint(relative);
                    const end = try self.readPoint(relative);
                    try appendOp(allocator, ops, .{ .cubic_to = .{ .control1 = control1, .control2 = control2, .end = end } });
                    self.current = end;
                    self.last_cubic_control = control2;
                    self.last_quadratic_control = null;
                },
                's' => {
                    const control1 = if (self.last_cubic_control) |previous| reflect(previous, self.current) else self.current;
                    const control2 = try self.readPoint(relative);
                    const end = try self.readPoint(relative);
                    try appendOp(allocator, ops, .{ .cubic_to = .{ .control1 = control1, .control2 = control2, .end = end } });
                    self.current = end;
                    self.last_cubic_control = control2;
                    self.last_quadratic_control = null;
                },
                'q' => {
                    const control = try self.readPoint(relative);
                    const end = try self.readPoint(relative);
                    try self.appendQuadratic(allocator, ops, control, end);
                },
                't' => {
                    const control = if (self.last_quadratic_control) |previous| reflect(previous, self.current) else self.current;
                    const end = try self.readPoint(relative);
                    try self.appendQuadratic(allocator, ops, control, end);
                },
                'a' => {
                    const rx = @abs(try self.readNumber());
                    const ry = @abs(try self.readNumber());
                    const angle = try self.readNumber();
                    const large_arc = (try self.readNumber()) != 0;
                    const sweep = (try self.readNumber()) != 0;
                    const end = try self.readPoint(relative);
                    try self.appendArc(allocator, ops, rx, ry, angle, large_arc, sweep, end);
                },
                else => return Error.UnsupportedSvg,
            }
        }
        if (!consumed) return Error.InvalidSvg;
    }

    fn appendQuadratic(self: *PathParser, allocator: std.mem.Allocator, ops: *std.ArrayList(PathOp), control: geometry.Point, end: geometry.Point) !void {
        const control1: geometry.Point = .{
            .x = self.current.x + (control.x - self.current.x) * 2 / 3,
            .y = self.current.y + (control.y - self.current.y) * 2 / 3,
        };
        const control2: geometry.Point = .{
            .x = end.x + (control.x - end.x) * 2 / 3,
            .y = end.y + (control.y - end.y) * 2 / 3,
        };
        try appendOp(allocator, ops, .{ .cubic_to = .{ .control1 = control1, .control2 = control2, .end = end } });
        self.current = end;
        self.last_quadratic_control = control;
        self.last_cubic_control = null;
    }

    fn appendArc(self: *PathParser, allocator: std.mem.Allocator, ops: *std.ArrayList(PathOp), raw_rx: f32, raw_ry: f32, degrees: f32, large_arc: bool, sweep: bool, end: geometry.Point) !void {
        if ((raw_rx == 0 or raw_ry == 0) or (self.current.x == end.x and self.current.y == end.y)) {
            if (self.current.x != end.x or self.current.y != end.y) try appendOp(allocator, ops, .{ .line_to = end });
            self.current = end;
            self.resetControls();
            return;
        }
        const phi = degrees * @as(f32, std.math.pi) / 180;
        const cos_phi = @cos(phi);
        const sin_phi = @sin(phi);
        const dx = (self.current.x - end.x) / 2;
        const dy = (self.current.y - end.y) / 2;
        const x_prime = cos_phi * dx + sin_phi * dy;
        const y_prime = -sin_phi * dx + cos_phi * dy;
        var rx = raw_rx;
        var ry = raw_ry;
        const radii_scale = x_prime * x_prime / (rx * rx) + y_prime * y_prime / (ry * ry);
        if (radii_scale > 1) {
            const factor = @sqrt(radii_scale);
            rx *= factor;
            ry *= factor;
        }
        const rx2 = rx * rx;
        const ry2 = ry * ry;
        const numerator = @max(0, rx2 * ry2 - rx2 * y_prime * y_prime - ry2 * x_prime * x_prime);
        const denominator = rx2 * y_prime * y_prime + ry2 * x_prime * x_prime;
        const sign: f32 = if (large_arc == sweep) -1 else 1;
        const coefficient = if (denominator <= 0) 0 else sign * @sqrt(numerator / denominator);
        const center_prime_x = coefficient * (rx * y_prime / ry);
        const center_prime_y = coefficient * (-ry * x_prime / rx);
        const center = geometry.Point{
            .x = cos_phi * center_prime_x - sin_phi * center_prime_y + (self.current.x + end.x) / 2,
            .y = sin_phi * center_prime_x + cos_phi * center_prime_y + (self.current.y + end.y) / 2,
        };
        const start_vector = geometry.Point{ .x = (x_prime - center_prime_x) / rx, .y = (y_prime - center_prime_y) / ry };
        const end_vector = geometry.Point{ .x = (-x_prime - center_prime_x) / rx, .y = (-y_prime - center_prime_y) / ry };
        var start_angle = std.math.atan2(start_vector.y, start_vector.x);
        var delta = vectorAngle(start_vector, end_vector);
        if (!sweep and delta > 0) delta -= @as(f32, std.math.pi) * 2;
        if (sweep and delta < 0) delta += @as(f32, std.math.pi) * 2;
        const segment_count: usize = @intFromFloat(@ceil(@abs(delta) / (@as(f32, std.math.pi) / 2)));
        const segment_delta = delta / @as(f32, @floatFromInt(@max(segment_count, 1)));
        for (0..@max(segment_count, 1)) |_| {
            const end_angle = start_angle + segment_delta;
            const alpha = 4.0 / 3.0 * @tan(segment_delta / 4);
            const start_point = arcPoint(center, rx, ry, phi, start_angle);
            const end_point = arcPoint(center, rx, ry, phi, end_angle);
            const start_derivative = arcDerivative(rx, ry, phi, start_angle);
            const end_derivative = arcDerivative(rx, ry, phi, end_angle);
            try appendOp(allocator, ops, .{ .cubic_to = .{
                .control1 = .{ .x = start_point.x + alpha * start_derivative.x, .y = start_point.y + alpha * start_derivative.y },
                .control2 = .{ .x = end_point.x - alpha * end_derivative.x, .y = end_point.y - alpha * end_derivative.y },
                .end = end_point,
            } });
            start_angle = end_angle;
        }
        self.current = end;
        self.resetControls();
    }

    fn readPoint(self: *PathParser, relative: bool) !geometry.Point {
        var point = geometry.Point{ .x = try self.readNumber(), .y = try self.readNumber() };
        if (relative) {
            point.x += self.current.x;
            point.y += self.current.y;
        }
        return point;
    }

    fn readNumber(self: *PathParser) !f32 {
        self.skipSeparators();
        const start = self.index;
        if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) self.index += 1;
        var digits = false;
        while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) digits = true;
        if (self.index < self.source.len and self.source[self.index] == '.') {
            self.index += 1;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) digits = true;
        }
        if (!digits) return Error.InvalidSvg;
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            self.index += 1;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) self.index += 1;
            const exponent_start = self.index;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.index += 1;
            if (self.index == exponent_start) return Error.InvalidSvg;
        }
        return std.fmt.parseFloat(f32, self.source[start..self.index]) catch return Error.InvalidSvg;
    }

    fn hasNumber(self: *PathParser) bool {
        self.skipSeparators();
        if (self.index >= self.source.len) return false;
        const byte = self.source[self.index];
        return byte == '+' or byte == '-' or byte == '.' or std.ascii.isDigit(byte);
    }

    fn skipSeparators(self: *PathParser) void {
        while (self.index < self.source.len and (std.ascii.isWhitespace(self.source[self.index]) or self.source[self.index] == ',')) self.index += 1;
    }

    fn resetControls(self: *PathParser) void {
        self.last_cubic_control = null;
        self.last_quadratic_control = null;
    }
};

fn arcPoint(center: geometry.Point, rx: f32, ry: f32, phi: f32, angle: f32) geometry.Point {
    return .{
        .x = center.x + @cos(phi) * rx * @cos(angle) - @sin(phi) * ry * @sin(angle),
        .y = center.y + @sin(phi) * rx * @cos(angle) + @cos(phi) * ry * @sin(angle),
    };
}

fn arcDerivative(rx: f32, ry: f32, phi: f32, angle: f32) geometry.Point {
    return .{
        .x = -@cos(phi) * rx * @sin(angle) - @sin(phi) * ry * @cos(angle),
        .y = -@sin(phi) * rx * @sin(angle) + @cos(phi) * ry * @cos(angle),
    };
}

fn vectorAngle(left: geometry.Point, right: geometry.Point) f32 {
    return std.math.atan2(left.x * right.y - left.y * right.x, left.x * right.x + left.y * right.y);
}

fn reflect(point: geometry.Point, around: geometry.Point) geometry.Point {
    return .{ .x = around.x * 2 - point.x, .y = around.y * 2 - point.y };
}

fn applyStyle(style: *Style, attributes: []const u8) !void {
    const declaration = attribute(attributes, "style");
    try applyPaint(style, "fill", styleProperty(declaration, "fill") orelse attribute(attributes, "fill"));
    try applyPaint(style, "stroke", styleProperty(declaration, "stroke") orelse attribute(attributes, "stroke"));
    if (styleProperty(declaration, "fill-rule") orelse attribute(attributes, "fill-rule")) |value| {
        style.fill_rule = if (equals(value, "evenodd")) .evenodd else .nonzero;
    }
    if (styleProperty(declaration, "stroke-width") orelse attribute(attributes, "stroke-width")) |value| {
        style.stroke_width = @max(parseNumber(value) orelse return Error.UnsupportedSvg, 0);
    }
    if (styleProperty(declaration, "stroke-linecap") orelse attribute(attributes, "stroke-linecap")) |value| {
        style.line_cap = if (equals(value, "round")) .round else if (equals(value, "square")) .square else .butt;
    }
    if (styleProperty(declaration, "stroke-linejoin") orelse attribute(attributes, "stroke-linejoin")) |value| {
        style.line_join = if (equals(value, "round")) .round else if (equals(value, "bevel")) .bevel else .miter;
    }
    if (styleProperty(declaration, "stroke-miterlimit") orelse attribute(attributes, "stroke-miterlimit")) |value| {
        style.miter_limit = @max(parseNumber(value) orelse return Error.UnsupportedSvg, 1);
    }
    if (styleProperty(declaration, "stroke-dashoffset") orelse attribute(attributes, "stroke-dashoffset")) |value| {
        style.dash_offset = parseNumber(value) orelse return Error.UnsupportedSvg;
    }
    if (styleProperty(declaration, "stroke-dasharray") orelse attribute(attributes, "stroke-dasharray")) |value| {
        style.dash_len = 0;
        if (!equals(value, "none")) {
            var scanner = NumberScanner{ .source = value };
            while (scanner.next()) |item| {
                if (style.dash_len == style.dash_values.len or item < 0) return Error.UnsupportedSvg;
                style.dash_values[style.dash_len] = item;
                style.dash_len += 1;
            }
        }
    }
}

fn validateNode(attributes: []const u8, is_root: bool) !void {
    const declaration = attribute(attributes, "style");
    const unsupported = [_][]const u8{
        "filter",
        "mix-blend-mode",
        "clip-path",
        "mask",
        "mask-image",
        "marker-start",
        "marker-mid",
        "marker-end",
        "vector-effect",
        "paint-order",
    };
    for (unsupported) |property| {
        const value = styleProperty(declaration, property) orelse attribute(attributes, property) orelse continue;
        if (!equals(value, "none") and !equals(value, "auto") and
            !((equals(property, "mix-blend-mode") or equals(property, "paint-order")) and equals(value, "normal"))) return Error.UnsupportedSvg;
    }
    const alpha_properties = [_][]const u8{ "fill-opacity", "stroke-opacity" };
    for (alpha_properties) |property| {
        const value = styleProperty(declaration, property) orelse attribute(attributes, property) orelse continue;
        if (@abs((parseNumber(value) orelse return Error.UnsupportedSvg) - 1) > 0.0001) return Error.UnsupportedSvg;
    }
    if (!is_root) {
        if (styleProperty(declaration, "opacity") orelse attribute(attributes, "opacity")) |value| {
            if (@abs((parseNumber(value) orelse return Error.UnsupportedSvg) - 1) > 0.0001) return Error.UnsupportedSvg;
        }
        const transform = styleProperty(declaration, "transform") orelse attribute(attributes, "transform") orelse "none";
        if (!equals(transform, "none")) {
            const origin = styleProperty(declaration, "transform-origin") orelse attribute(attributes, "transform-origin") orelse "0 0";
            if (!allZeroLengths(origin)) return Error.UnsupportedSvg;
        }
    }
}

fn allZeroLengths(raw: []const u8) bool {
    var start: usize = 0;
    var count: usize = 0;
    while (start < raw.len) {
        while (start < raw.len and std.ascii.isWhitespace(raw[start])) start += 1;
        if (start >= raw.len) break;
        var end = start;
        while (end < raw.len and !std.ascii.isWhitespace(raw[end])) end += 1;
        if (@abs(parseNumber(raw[start..end]) orelse return false) > 0.0001) return false;
        count += 1;
        start = end;
    }
    return count >= 2;
}

fn applyPaint(style: *Style, comptime property: []const u8, raw: ?[]const u8) !void {
    const value = raw orelse return;
    const destination = if (comptime std.mem.eql(u8, property, "fill")) &style.fill else &style.stroke;
    if (equals(value, "none")) {
        destination.* = null;
        return;
    }
    const color = geometry.parseColor(trim(value)) orelse return Error.UnsupportedSvg;
    if (color.alpha < 0.9999) return Error.UnsupportedSvg;
    destination.* = color;
}

fn parseTransform(raw: []const u8) !geometry.AffineTransform {
    var result = geometry.AffineTransform.identity;
    var index: usize = 0;
    while (index < raw.len) {
        while (index < raw.len and (std.ascii.isWhitespace(raw[index]) or raw[index] == ',')) index += 1;
        if (index >= raw.len) break;
        const name_start = index;
        while (index < raw.len and (std.ascii.isAlphabetic(raw[index]) or std.ascii.isDigit(raw[index]))) index += 1;
        const name = raw[name_start..index];
        while (index < raw.len and std.ascii.isWhitespace(raw[index])) index += 1;
        if (index >= raw.len or raw[index] != '(') return Error.UnsupportedSvg;
        const end = std.mem.indexOfScalarPos(u8, raw, index + 1, ')') orelse return Error.UnsupportedSvg;
        var scanner = NumberScanner{ .source = raw[index + 1 .. end] };
        var values: [6]f32 = @splat(0);
        var count: usize = 0;
        while (scanner.next()) |value| {
            if (count == values.len) return Error.UnsupportedSvg;
            values[count] = value;
            count += 1;
        }
        const operation = if (equals(name, "matrix") and count == 6)
            geometry.AffineTransform{ .a = values[0], .b = values[1], .c = values[2], .d = values[3], .e = values[4], .f = values[5] }
        else if (equals(name, "translate") and (count == 1 or count == 2))
            geometry.AffineTransform.translation(values[0], if (count == 2) values[1] else 0)
        else if (equals(name, "scale") and (count == 1 or count == 2))
            geometry.AffineTransform.scaling(values[0], if (count == 2) values[1] else values[0])
        else if (equals(name, "rotate") and (count == 1 or count == 3)) rotate: {
            const rotation = geometry.AffineTransform.rotation(values[0] * @as(f32, std.math.pi) / 180);
            break :rotate if (count == 3) rotation.around(.{ .x = values[1], .y = values[2] }) else rotation;
        } else if (equals(name, "skewx") and count == 1)
            geometry.AffineTransform.skewing(values[0] * @as(f32, std.math.pi) / 180, 0)
        else if (equals(name, "skewy") and count == 1)
            geometry.AffineTransform.skewing(0, values[0] * @as(f32, std.math.pi) / 180)
        else
            return Error.UnsupportedSvg;
        result = result.multiply(operation);
        index = end + 1;
    }
    return result;
}

const NumberScanner = struct {
    source: []const u8,
    index: usize = 0,

    fn next(self: *NumberScanner) ?f32 {
        while (self.index < self.source.len and (std.ascii.isWhitespace(self.source[self.index]) or self.source[self.index] == ',')) self.index += 1;
        if (self.index >= self.source.len) return null;
        const start = self.index;
        if (self.source[self.index] == '+' or self.source[self.index] == '-') self.index += 1;
        var digits = false;
        while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) digits = true;
        if (self.index < self.source.len and self.source[self.index] == '.') {
            self.index += 1;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) digits = true;
        }
        if (!digits) return null;
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            self.index += 1;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) self.index += 1;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) self.index += 1;
        }
        const number_end = self.index;
        if (self.index + 2 <= self.source.len and std.ascii.eqlIgnoreCase(self.source[self.index..][0..2], "px")) self.index += 2;
        return std.fmt.parseFloat(f32, self.source[start..number_end]) catch null;
    }
};

fn parseRootViewBox(attributes: []const u8) ?geometry.Rect {
    if (attribute(attributes, "viewBox")) |raw| {
        var scanner = NumberScanner{ .source = raw };
        const rect = geometry.Rect{
            .x = scanner.next() orelse return null,
            .y = scanner.next() orelse return null,
            .width = scanner.next() orelse return null,
            .height = scanner.next() orelse return null,
        };
        if (rect.width <= 0 or rect.height <= 0 or scanner.next() != null) return null;
        return rect;
    }
    const width = parseNumber(attribute(attributes, "width") orelse "300") orelse return null;
    const height = parseNumber(attribute(attributes, "height") orelse "150") orelse return null;
    if (width <= 0 or height <= 0) return null;
    return .{ .width = width, .height = height };
}

fn parsePreserveAspectRatio(raw: ?[]const u8) PreserveAspectRatio {
    const value = trim(raw orelse "xMidYMid meet");
    if (startsWithIgnoreCase(value, "none")) return .{ .none = true };
    var result = PreserveAspectRatio{ .slice = indexOfIgnoreCase(value, "slice") != null };
    if (startsWithIgnoreCase(value, "xmin")) result.align_x = .min else if (startsWithIgnoreCase(value, "xmax")) result.align_x = .max;
    if (indexOfIgnoreCase(value, "ymin") != null) result.align_y = .min else if (indexOfIgnoreCase(value, "ymax") != null) result.align_y = .max;
    return result;
}

fn isHidden(attributes: []const u8) bool {
    const style = attribute(attributes, "style");
    const display = styleProperty(style, "display") orelse attribute(attributes, "display") orelse "inline";
    const visibility = styleProperty(style, "visibility") orelse attribute(attributes, "visibility") orelse "visible";
    return equals(display, "none") or equals(visibility, "hidden") or equals(visibility, "collapse");
}

fn isShapeElement(name: []const u8) bool {
    return equals(name, "path") or equals(name, "rect") or equals(name, "circle") or equals(name, "ellipse") or
        equals(name, "line") or equals(name, "polyline") or equals(name, "polygon");
}

fn findTagEnd(xml: []const u8, start: usize) ?usize {
    var quote: ?u8 = null;
    var index = start;
    while (index < xml.len) : (index += 1) {
        const byte = xml[index];
        if (quote) |expected| {
            if (byte == expected) quote = null;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') return index;
    }
    return null;
}

fn tokenEnd(raw: []const u8, start: usize) usize {
    var index = start;
    while (index < raw.len and !std.ascii.isWhitespace(raw[index]) and raw[index] != '/') index += 1;
    return index;
}

fn attribute(raw: []const u8, wanted: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < raw.len) {
        while (index < raw.len and std.ascii.isWhitespace(raw[index])) index += 1;
        if (index >= raw.len) break;
        const name_start = index;
        while (index < raw.len and !std.ascii.isWhitespace(raw[index]) and raw[index] != '=') index += 1;
        const name = raw[name_start..index];
        while (index < raw.len and std.ascii.isWhitespace(raw[index])) index += 1;
        if (index >= raw.len or raw[index] != '=') {
            while (index < raw.len and !std.ascii.isWhitespace(raw[index])) index += 1;
            continue;
        }
        index += 1;
        while (index < raw.len and std.ascii.isWhitespace(raw[index])) index += 1;
        if (index >= raw.len) return null;
        const quote = raw[index];
        if (quote != '\'' and quote != '"') return null;
        index += 1;
        const value_start = index;
        while (index < raw.len and raw[index] != quote) index += 1;
        if (index >= raw.len) return null;
        const value = raw[value_start..index];
        index += 1;
        if (std.ascii.eqlIgnoreCase(name, wanted)) return value;
    }
    return null;
}

fn styleProperty(style: ?[]const u8, wanted: []const u8) ?[]const u8 {
    const raw = style orelse return null;
    var start: usize = 0;
    while (start < raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, start, ';') orelse raw.len;
        const declaration = trim(raw[start..end]);
        if (std.mem.indexOfScalar(u8, declaration, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(trim(declaration[0..colon]), wanted)) return trim(declaration[colon + 1 ..]);
        }
        start = end + 1;
    }
    return null;
}

fn parseNumber(raw: []const u8) ?f32 {
    const value = trim(raw);
    const numeric = if (endsWithIgnoreCase(value, "px")) value[0 .. value.len - 2] else value;
    return std.fmt.parseFloat(f32, numeric) catch null;
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

fn indexOfIgnoreCase(value: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > value.len) return null;
    for (0..value.len - needle.len + 1) |index| if (std.ascii.eqlIgnoreCase(value[index..][0..needle.len], needle)) return index;
    return null;
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\n\r\x0C");
}

test "parse native SVG shapes paths arcs and transforms" {
    const allocator = std.testing.allocator;
    const xml = "<svg viewBox='0 0 100 50'><g transform='translate(5 3)'><rect x='1' y='2' width='20' height='10' rx='2' fill='#336699'/><path d='M30 20 Q40 0 50 20 A10 5 0 0 1 70 20 Z' fill='rgb(10, 20, 30)'/></g></svg>";
    const encoded_len = std.base64.standard.Encoder.calcSize(xml.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, xml);
    const source = try std.fmt.allocPrint(allocator, "data:image/svg+xml;base64,{s}", .{encoded});
    defer allocator.free(source);
    var document = try parseDataUrl(allocator, source);
    defer document.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), document.shapes.items.len);
    try std.testing.expect(document.ops.items.len >= 12);
    try std.testing.expectApproxEqAbs(@as(f32, 5), document.shapes.items[0].transform.e, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), document.formTransform(200, 100).a, 0.0001);
}

test "parse XMLSerializer-style closing tags and computed SVG stroke lengths" {
    const allocator = std.testing.allocator;
    var document = try parseXml(
        allocator,
        "<svg viewBox=\"0 0 40 20\"><g><rect x=\"1\" y=\"1\" width=\"18\" height=\"18\" style=\"fill:rgb(10, 20, 30);stroke:rgb(40, 50, 60);stroke-width:2px;stroke-dasharray:4px, 2px;stroke-miterlimit:6\"></rect><path d=\"M22 2 L38 18\" style=\"fill:none;stroke:#111827;stroke-width:1px\"></path></g></svg>",
    );
    defer document.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), document.shapes.items.len);
    try std.testing.expectEqual(@as(u8, 2), document.shapes.items[0].style.dash_len);
    try std.testing.expectApproxEqAbs(@as(f32, 6), document.shapes.items[0].style.miter_limit, 0.001);
}

test "reject SVG constructs that need a scoped raster fallback" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Error.UnsupportedSvg, parseXml(
        allocator,
        "<svg viewBox='0 0 10 10'><svg viewBox='0 0 5 5'><rect width='5' height='5'/></svg></svg>",
    ));
    try std.testing.expectError(Error.UnsupportedSvg, parseXml(
        allocator,
        "<svg viewBox='0 0 10 10'><rect width='10' height='10' style='fill:url(#paint)'/></svg>",
    ));
    try std.testing.expectError(Error.UnsupportedSvg, parseXml(
        allocator,
        "<svg viewBox='0 0 10 10'><rect width='10' height='10' opacity='.5'/></svg>",
    ));
}
