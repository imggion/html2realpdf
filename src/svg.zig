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
const max_gradient_stops = 16;
const max_clip_chain = 8;
const kappa: f32 = 0.5522847498307936;

pub const FillRule = enum { nonzero, evenodd };
pub const LineCap = enum { butt, round, square };
pub const LineJoin = enum { miter, round, bevel };
pub const TextAnchor = enum { start, middle, end };
pub const DominantBaseline = enum { alphabetic, middle, central, hanging };
pub const FontWeight = enum { normal, bold };
pub const FontStyle = enum { normal, italic };
pub const TextDirection = enum { ltr, rtl };

pub const Reference = struct {
    bytes: [63]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(raw: []const u8) !Reference {
        const value = trim(raw);
        if (value.len == 0 or value.len > 63) return Error.UnsupportedSvg;
        var result = Reference{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const Reference) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Reference, other: *const Reference) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const FontFamily = struct {
    bytes: [127]u8 = @splat(0),
    len: u8 = 0,

    fn set(self: *FontFamily, raw: []const u8) !void {
        const value = trim(raw);
        if (value.len == 0 or value.len > self.bytes.len) return Error.UnsupportedSvg;
        @memcpy(self.bytes[0..value.len], value);
        self.len = @intCast(value.len);
    }

    pub fn slice(self: *const FontFamily) []const u8 {
        return if (self.len == 0) "Noto Sans" else self.bytes[0..self.len];
    }
};

pub const ClipChain = struct {
    values: [max_clip_chain]Reference = @splat(.{}),
    len: u8 = 0,

    fn append(self: *ClipChain, reference: Reference) !void {
        if (self.len == self.values.len) return Error.SvgTooComplex;
        self.values[self.len] = reference;
        self.len += 1;
    }

    pub fn slice(self: *const ClipChain) []const Reference {
        return self.values[0..self.len];
    }
};

pub const Style = struct {
    fill: ?geometry.Color = geometry.Color.black,
    fill_server: ?Reference = null,
    stroke: ?geometry.Color = null,
    stroke_server: ?Reference = null,
    fill_rule: FillRule = .nonzero,
    opacity: f32 = 1,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    stroke_width: f32 = 1,
    line_cap: LineCap = .butt,
    line_join: LineJoin = .miter,
    miter_limit: f32 = 4,
    dash_values: [16]f32 = @splat(0),
    dash_len: u8 = 0,
    dash_offset: f32 = 0,
    color: geometry.Color = geometry.Color.black,
    font_family: FontFamily = .{},
    font_size: f32 = 16,
    font_weight: FontWeight = .normal,
    font_style: FontStyle = .normal,
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    text_anchor: TextAnchor = .start,
    dominant_baseline: DominantBaseline = .alphabetic,
    direction: TextDirection = .ltr,
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
    clips: ClipChain = .{},
};

pub const Text = struct {
    content_start: usize,
    content_len: usize,
    group_id: usize,
    x: ?f32 = null,
    y: ?f32 = null,
    dx: f32 = 0,
    dy: f32 = 0,
    transform: geometry.AffineTransform = .identity,
    style: Style,
    clips: ClipChain = .{},
};

pub const PaintItem = union(enum) {
    shape: usize,
    text: usize,
};

pub const GradientLength = struct {
    value: f32,
    percent: bool = false,
};

pub const GradientStop = struct {
    offset: f32,
    color: geometry.Color,
};

pub const Gradient = struct {
    id: Reference,
    kind: enum { linear, radial },
    object_bounding_box: bool = true,
    transform: geometry.AffineTransform = .identity,
    x1: GradientLength = .{ .value = 0, .percent = true },
    y1: GradientLength = .{ .value = 0, .percent = true },
    x2: GradientLength = .{ .value = 1, .percent = true },
    y2: GradientLength = .{ .value = 0, .percent = true },
    cx: GradientLength = .{ .value = 0.5, .percent = true },
    cy: GradientLength = .{ .value = 0.5, .percent = true },
    radius: GradientLength = .{ .value = 0.5, .percent = true },
    fx: ?GradientLength = null,
    fy: ?GradientLength = null,
    stops: [max_gradient_stops]GradientStop = @splat(.{ .offset = 0, .color = geometry.Color.black }),
    stop_len: u8 = 0,
};

pub const ClipPath = struct {
    id: Reference,
    object_bounding_box: bool = false,
    transform: geometry.AffineTransform = .identity,
    first_shape: usize,
    shape_count: usize = 0,
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
    texts: std.ArrayList(Text),
    text_bytes: std.ArrayList(u8),
    items: std.ArrayList(PaintItem),
    gradients: std.ArrayList(Gradient),
    clips: std.ArrayList(ClipPath),
    view_box: geometry.Rect,
    preserve_aspect_ratio: PreserveAspectRatio = .{},

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        self.ops.deinit(allocator);
        self.shapes.deinit(allocator);
        self.texts.deinit(allocator);
        self.text_bytes.deinit(allocator);
        self.items.deinit(allocator);
        self.gradients.deinit(allocator);
        self.clips.deinit(allocator);
        self.* = undefined;
    }

    pub fn textSlice(self: *const Document, item: Text) []const u8 {
        return self.text_bytes.items[item.content_start..][0..item.content_len];
    }

    pub fn gradientFor(self: *const Document, reference: Reference) ?*const Gradient {
        for (self.gradients.items) |*gradient| if (gradient.id.eql(&reference)) return gradient;
        return null;
    }

    pub fn clipFor(self: *const Document, reference: Reference) ?*const ClipPath {
        for (self.clips.items) |*clip| if (clip.id.eql(&reference)) return clip;
        return null;
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
    in_defs: bool = false,
    active_gradient: ?usize = null,
    active_clip: ?usize = null,
    started_clip: ?usize = null,
    text_group: ?usize = null,
    x: ?f32 = null,
    y: ?f32 = null,
    dx: f32 = 0,
    dy: f32 = 0,
    collect_text: bool = false,
    ignore_text: bool = false,
    clips: ClipChain = .{},
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
        .texts = try std.ArrayList(Text).initCapacity(allocator, 0),
        .text_bytes = try std.ArrayList(u8).initCapacity(allocator, 0),
        .items = try std.ArrayList(PaintItem).initCapacity(allocator, 0),
        .gradients = try std.ArrayList(Gradient).initCapacity(allocator, 0),
        .clips = try std.ArrayList(ClipPath).initCapacity(allocator, 0),
        .view_box = .{ .width = 300, .height = 150 },
    };
    errdefer document.deinit(allocator);

    var states: [max_depth]NodeState = undefined;
    var tag_names: [max_depth][]const u8 = undefined;
    states[0] = .{};
    var depth: usize = 1;
    var saw_root = false;
    var next_text_group: usize = 0;
    var index: usize = 0;
    while (index < xml.len) {
        const open = std.mem.indexOfScalarPos(u8, xml, index, '<') orelse break;
        if (open > index and states[depth - 1].collect_text and !states[depth - 1].hidden) {
            try appendTextContent(allocator, &document, states[depth - 1], xml[index..open]);
        }
        if (std.mem.startsWith(u8, xml[open..], "<!--")) {
            const close = std.mem.indexOfPos(u8, xml, open + 4, "-->") orelse return Error.InvalidSvg;
            index = close + 3;
            continue;
        }
        const close = findTagEnd(xml, open + 1) orelse return Error.InvalidSvg;
        var raw = trim(xml[open + 1 .. close]);
        index = close + 1;
        if (raw.len == 0 or raw[0] == '?') continue;
        if (raw[0] == '!') return Error.UnsupportedSvg;
        if (raw[0] == '/') {
            if (depth <= 1) return Error.InvalidSvg;
            const closing_name = trim(raw[1..]);
            if (!equals(tag_names[depth - 1], closing_name)) return Error.InvalidSvg;
            const closing_state = states[depth - 1];
            if (closing_state.started_clip) |clip_index| {
                document.clips.items[clip_index].shape_count = document.shapes.items.len - document.clips.items[clip_index].first_shape;
            }
            depth -= 1;
            continue;
        }

        const self_closing = raw[raw.len - 1] == '/';
        if (self_closing) raw = trim(raw[0 .. raw.len - 1]);
        const name_end = tokenEnd(raw, 0);
        const name = raw[0..name_end];
        const attributes = raw[name_end..];
        const parent = states[depth - 1];
        var state = parent;
        state.started_clip = null;
        state.hidden = parent.hidden or isHidden(attributes);
        const is_root = !saw_root;
        try validateNode(name, attributes, is_root);
        applyStyle(&state.style, attributes) catch return Error.UnsupportedSvg;
        try applyClipReference(&state.clips, attributes);

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

        if (equals(name, "defs")) {
            state.in_defs = true;
        } else if (equals(name, "linearGradient") or equals(name, "radialGradient")) {
            if (!parent.in_defs or parent.active_gradient != null or parent.active_clip != null) return Error.UnsupportedSvg;
            const gradient = try parseGradient(name, attributes);
            try ensureUniqueDefinition(&document, gradient.id);
            try document.gradients.append(allocator, gradient);
            state.active_gradient = document.gradients.items.len - 1;
            state.in_defs = true;
        } else if (equals(name, "stop")) {
            const gradient_index = parent.active_gradient orelse return Error.UnsupportedSvg;
            try appendGradientStop(&document.gradients.items[gradient_index], attributes);
        } else if (equals(name, "clipPath")) {
            if (!parent.in_defs or parent.active_gradient != null or parent.active_clip != null) return Error.UnsupportedSvg;
            const id = try Reference.init(attribute(attributes, "id") orelse return Error.InvalidSvg);
            try ensureUniqueDefinition(&document, id);
            const units = attribute(attributes, "clipPathUnits") orelse "userSpaceOnUse";
            if (!equals(units, "userSpaceOnUse") and !equals(units, "objectBoundingBox")) return Error.UnsupportedSvg;
            try document.clips.append(allocator, .{
                .id = id,
                .object_bounding_box = equals(units, "objectBoundingBox"),
                .first_shape = document.shapes.items.len,
            });
            state.active_clip = document.clips.items.len - 1;
            state.started_clip = state.active_clip;
            state.in_defs = true;
        } else if (equals(name, "text") or equals(name, "tspan")) {
            if (state.in_defs) return Error.UnsupportedSvg;
            if (equals(name, "text")) {
                if (parent.text_group != null) return Error.UnsupportedSvg;
                state.text_group = next_text_group;
                next_text_group += 1;
            } else if (parent.text_group == null) return Error.InvalidSvg;
            state.collect_text = true;
            state.ignore_text = false;
            state.x = try parseOptionalTextLength(attribute(attributes, "x"), document.view_box.width, state.style.font_size);
            state.y = try parseOptionalTextLength(attribute(attributes, "y"), document.view_box.height, state.style.font_size);
            state.dx = try parseTextLength(attribute(attributes, "dx") orelse "0", document.view_box.width, state.style.font_size);
            state.dy = try parseTextLength(attribute(attributes, "dy") orelse "0", document.view_box.height, state.style.font_size);
        } else if (equals(name, "title") or equals(name, "desc")) {
            state.collect_text = false;
            state.ignore_text = true;
        } else if (isShapeElement(name)) {
            if (!state.hidden) {
                const first_shape = document.shapes.items.len;
                try appendGeometryElement(allocator, &document, state, name, attributes);
                if (state.active_clip == null and !state.in_defs) {
                    for (first_shape..document.shapes.items.len) |shape_index| {
                        try document.items.append(allocator, .{ .shape = shape_index });
                    }
                }
            }
        } else if (!equals(name, "svg") and !equals(name, "g")) {
            return Error.UnsupportedSvg;
        }

        if (!self_closing) {
            if (depth == states.len) return Error.SvgTooComplex;
            states[depth] = state;
            tag_names[depth] = name;
            depth += 1;
        } else if (state.started_clip) |clip_index| {
            document.clips.items[clip_index].shape_count = document.shapes.items.len - document.clips.items[clip_index].first_shape;
        }
    }
    if (depth != 1 or !saw_root or document.items.items.len == 0) return Error.InvalidSvg;
    try validateReferences(&document);
    return document;
}

fn appendGeometryElement(
    allocator: std.mem.Allocator,
    document: *Document,
    state: NodeState,
    name: []const u8,
    attributes: []const u8,
) !void {
    if (equals(name, "path")) {
        try appendPathShape(allocator, document, state, attribute(attributes, "d") orelse return Error.InvalidSvg);
    } else if (equals(name, "rect")) {
        try appendRectShape(allocator, document, state, attributes);
    } else if (equals(name, "circle")) {
        try appendEllipseShape(allocator, document, state, attributes, true);
    } else if (equals(name, "ellipse")) {
        try appendEllipseShape(allocator, document, state, attributes, false);
    } else if (equals(name, "line")) {
        try appendLineShape(allocator, document, state, attributes);
    } else if (equals(name, "polyline") or equals(name, "polygon")) {
        try appendPolyShape(allocator, document, state, attributes, equals(name, "polygon"));
    } else return Error.UnsupportedSvg;
}

fn parseGradient(name: []const u8, attributes: []const u8) !Gradient {
    if (attribute(attributes, "href") != null or attribute(attributes, "xlink:href") != null) return Error.UnsupportedSvg;
    const spread = attribute(attributes, "spreadMethod") orelse "pad";
    if (!equals(spread, "pad")) return Error.UnsupportedSvg;
    const units = attribute(attributes, "gradientUnits") orelse "objectBoundingBox";
    if (!equals(units, "objectBoundingBox") and !equals(units, "userSpaceOnUse")) return Error.UnsupportedSvg;
    var gradient = Gradient{
        .id = try Reference.init(attribute(attributes, "id") orelse return Error.InvalidSvg),
        .kind = if (equals(name, "linearGradient")) .linear else .radial,
        .object_bounding_box = equals(units, "objectBoundingBox"),
    };
    if (attribute(attributes, "gradientTransform")) |value| gradient.transform = parseTransform(value) catch return Error.UnsupportedSvg;
    if (gradient.kind == .linear) {
        if (attribute(attributes, "x1")) |value| gradient.x1 = try parseGradientLength(value);
        if (attribute(attributes, "y1")) |value| gradient.y1 = try parseGradientLength(value);
        if (attribute(attributes, "x2")) |value| gradient.x2 = try parseGradientLength(value);
        if (attribute(attributes, "y2")) |value| gradient.y2 = try parseGradientLength(value);
    } else {
        if (attribute(attributes, "cx")) |value| gradient.cx = try parseGradientLength(value);
        if (attribute(attributes, "cy")) |value| gradient.cy = try parseGradientLength(value);
        if (attribute(attributes, "r")) |value| gradient.radius = try parseGradientLength(value);
        if (attribute(attributes, "fx")) |value| gradient.fx = try parseGradientLength(value);
        if (attribute(attributes, "fy")) |value| gradient.fy = try parseGradientLength(value);
    }
    return gradient;
}

fn parseGradientLength(raw: []const u8) !GradientLength {
    const value = trim(raw);
    if (std.mem.endsWith(u8, value, "%")) {
        return .{
            .value = (std.fmt.parseFloat(f32, value[0 .. value.len - 1]) catch return Error.UnsupportedSvg) / 100,
            .percent = true,
        };
    }
    return .{ .value = parseNumber(value) orelse return Error.UnsupportedSvg };
}

fn appendGradientStop(gradient: *Gradient, attributes: []const u8) !void {
    if (gradient.stop_len == gradient.stops.len) return Error.SvgTooComplex;
    const declaration = attribute(attributes, "style");
    const raw_offset = attribute(attributes, "offset") orelse "0";
    const parsed_offset = try parseGradientLength(raw_offset);
    var offset = if (parsed_offset.percent) parsed_offset.value else parsed_offset.value;
    offset = std.math.clamp(offset, 0, 1);
    if (gradient.stop_len > 0) offset = @max(offset, gradient.stops[gradient.stop_len - 1].offset);
    const raw_color = styleProperty(declaration, "stop-color") orelse attribute(attributes, "stop-color") orelse "black";
    var color = geometry.parseColor(trim(raw_color)) orelse return Error.UnsupportedSvg;
    const opacity = parseAlpha(styleProperty(declaration, "stop-opacity") orelse attribute(attributes, "stop-opacity") orelse "1") orelse return Error.UnsupportedSvg;
    color.alpha *= opacity;
    gradient.stops[gradient.stop_len] = .{ .offset = offset, .color = color };
    gradient.stop_len += 1;
}

fn ensureUniqueDefinition(document: *const Document, id: Reference) !void {
    for (document.gradients.items) |gradient| if (gradient.id.eql(&id)) return Error.InvalidSvg;
    for (document.clips.items) |clip| if (clip.id.eql(&id)) return Error.InvalidSvg;
}

fn validateReferences(document: *const Document) !void {
    for (document.gradients.items) |gradient| if (gradient.stop_len == 0) return Error.InvalidSvg;
    for (document.clips.items) |clip| if (clip.shape_count == 0) return Error.InvalidSvg;
    for (document.shapes.items) |shape| {
        if (shape.style.fill_server) |reference| if (document.gradientFor(reference) == null) return Error.InvalidSvg;
        if (shape.style.stroke_server) |reference| {
            if (document.gradientFor(reference) == null) return Error.InvalidSvg;
            return Error.UnsupportedSvg;
        }
        try validateClipChain(document, shape.clips, null, 0);
    }
    for (document.texts.items) |text| {
        if (text.style.fill_server != null or text.style.stroke_server != null) return Error.UnsupportedSvg;
        try validateClipChain(document, text.clips, null, 0);
    }
}

fn validateClipChain(document: *const Document, chain: ClipChain, active: ?Reference, depth: usize) !void {
    if (depth > max_clip_chain) return Error.SvgTooComplex;
    for (chain.slice()) |reference| {
        if (active) |current| if (current.eql(&reference)) return Error.InvalidSvg;
        const clip = document.clipFor(reference) orelse return Error.InvalidSvg;
        for (document.shapes.items[clip.first_shape..][0..clip.shape_count]) |shape| {
            try validateClipChain(document, shape.clips, reference, depth + 1);
        }
    }
}

fn parseOptionalTextLength(raw: ?[]const u8, axis: f32, em: f32) !?f32 {
    return if (raw) |value| try parseTextLength(value, axis, em) else null;
}

fn parseTextLength(raw: []const u8, axis: f32, em: f32) !f32 {
    const value = trim(raw);
    if (std.mem.endsWith(u8, value, "%")) {
        return (std.fmt.parseFloat(f32, value[0 .. value.len - 1]) catch return Error.UnsupportedSvg) * axis / 100;
    }
    if (endsWithIgnoreCase(value, "em")) {
        return (std.fmt.parseFloat(f32, value[0 .. value.len - 2]) catch return Error.UnsupportedSvg) * em;
    }
    return parseNumber(value) orelse return Error.UnsupportedSvg;
}

fn appendTextContent(
    allocator: std.mem.Allocator,
    document: *Document,
    state: NodeState,
    raw: []const u8,
) !void {
    const group_id = state.text_group orelse return;
    var decoded = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    defer decoded.deinit(allocator);
    try decodeAndCollapseXmlText(allocator, &decoded, raw);
    if (decoded.items.len == 0) return;
    if (document.items.items.len >= max_shapes) return Error.SvgTooComplex;
    const content_start = document.text_bytes.items.len;
    try document.text_bytes.appendSlice(allocator, decoded.items);
    try document.texts.append(allocator, .{
        .content_start = content_start,
        .content_len = decoded.items.len,
        .group_id = group_id,
        .x = state.x,
        .y = state.y,
        .dx = state.dx,
        .dy = state.dy,
        .transform = state.transform,
        .style = state.style,
        .clips = state.clips,
    });
    try document.items.append(allocator, .{ .text = document.texts.items.len - 1 });
}

fn decodeAndCollapseXmlText(allocator: std.mem.Allocator, output: *std.ArrayList(u8), raw: []const u8) !void {
    var index: usize = 0;
    var pending_space = false;
    while (index < raw.len) {
        if (std.ascii.isWhitespace(raw[index])) {
            pending_space = output.items.len > 0;
            index += 1;
            continue;
        }
        if (pending_space) {
            try output.append(allocator, ' ');
            pending_space = false;
        }
        if (raw[index] != '&') {
            try output.append(allocator, raw[index]);
            index += 1;
            continue;
        }
        const semicolon = std.mem.indexOfScalarPos(u8, raw, index + 1, ';') orelse return Error.InvalidSvg;
        const entity = raw[index + 1 .. semicolon];
        if (std.mem.eql(u8, entity, "amp")) try output.append(allocator, '&') else if (std.mem.eql(u8, entity, "lt")) try output.append(allocator, '<') else if (std.mem.eql(u8, entity, "gt")) try output.append(allocator, '>') else if (std.mem.eql(u8, entity, "quot")) try output.append(allocator, '"') else if (std.mem.eql(u8, entity, "apos")) try output.append(allocator, '\'') else if (entity.len > 1 and entity[0] == '#') {
            const hexadecimal = entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X');
            const digits = entity[if (hexadecimal) 2 else 1..];
            const codepoint = std.fmt.parseInt(u21, digits, if (hexadecimal) 16 else 10) catch return Error.InvalidSvg;
            var encoded: [4]u8 = undefined;
            const count = std.unicode.utf8Encode(codepoint, &encoded) catch return Error.InvalidSvg;
            try output.appendSlice(allocator, encoded[0..count]);
        } else return Error.UnsupportedSvg;
        index = semicolon + 1;
    }
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
        .clips = state.clips,
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
    if (styleProperty(declaration, "color") orelse attribute(attributes, "color")) |value| {
        style.color = geometry.parseColor(trim(value)) orelse return Error.UnsupportedSvg;
    }
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
    if (styleProperty(declaration, "opacity") orelse attribute(attributes, "opacity")) |value| {
        style.opacity = parseAlpha(value) orelse return Error.UnsupportedSvg;
    }
    if (styleProperty(declaration, "fill-opacity") orelse attribute(attributes, "fill-opacity")) |value| {
        style.fill_opacity = parseAlpha(value) orelse return Error.UnsupportedSvg;
    }
    if (styleProperty(declaration, "stroke-opacity") orelse attribute(attributes, "stroke-opacity")) |value| {
        style.stroke_opacity = parseAlpha(value) orelse return Error.UnsupportedSvg;
    }
    if (styleProperty(declaration, "font-family") orelse attribute(attributes, "font-family")) |value| try style.font_family.set(value);
    if (styleProperty(declaration, "font-size") orelse attribute(attributes, "font-size")) |value| {
        style.font_size = @max(parseNumber(value) orelse return Error.UnsupportedSvg, 0.001);
    }
    if (styleProperty(declaration, "font-weight") orelse attribute(attributes, "font-weight")) |value| {
        style.font_weight = if (equals(value, "bold") or (parseNumber(value) orelse 0) >= 600) .bold else .normal;
    }
    if (styleProperty(declaration, "font-style") orelse attribute(attributes, "font-style")) |value| {
        style.font_style = if (equals(value, "italic") or equals(value, "oblique")) .italic else .normal;
    }
    if (styleProperty(declaration, "letter-spacing") orelse attribute(attributes, "letter-spacing")) |value| {
        style.letter_spacing = if (equals(value, "normal")) 0 else parseNumber(value) orelse return Error.UnsupportedSvg;
    }
    if (styleProperty(declaration, "word-spacing") orelse attribute(attributes, "word-spacing")) |value| {
        style.word_spacing = if (equals(value, "normal")) 0 else parseNumber(value) orelse return Error.UnsupportedSvg;
    }
    if (styleProperty(declaration, "text-anchor") orelse attribute(attributes, "text-anchor")) |value| {
        style.text_anchor = if (equals(value, "middle")) .middle else if (equals(value, "end")) .end else if (equals(value, "start")) .start else return Error.UnsupportedSvg;
    }
    if (styleProperty(declaration, "dominant-baseline") orelse attribute(attributes, "dominant-baseline")) |value| {
        style.dominant_baseline = if (equals(value, "auto") or equals(value, "alphabetic"))
            .alphabetic
        else if (equals(value, "middle"))
            .middle
        else if (equals(value, "central"))
            .central
        else if (equals(value, "hanging"))
            .hanging
        else
            return Error.UnsupportedSvg;
    }
    if (styleProperty(declaration, "direction") orelse attribute(attributes, "direction")) |value| {
        style.direction = if (equals(value, "rtl")) .rtl else if (equals(value, "ltr")) .ltr else return Error.UnsupportedSvg;
    }
}

fn validateNode(name: []const u8, attributes: []const u8, is_root: bool) !void {
    const declaration = attribute(attributes, "style");
    const unsupported = [_][]const u8{
        "filter",
        "mix-blend-mode",
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
    if (!is_root) {
        if (styleProperty(declaration, "opacity") orelse attribute(attributes, "opacity")) |value| {
            const opacity = parseAlpha(value) orelse return Error.UnsupportedSvg;
            if ((equals(name, "g") or equals(name, "defs") or equals(name, "clipPath")) and opacity < 0.9999) return Error.UnsupportedSvg;
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
    const server = if (comptime std.mem.eql(u8, property, "fill")) &style.fill_server else &style.stroke_server;
    if (equals(value, "none")) {
        destination.* = null;
        server.* = null;
        return;
    }
    if (parseLocalUrlReference(value)) |reference| {
        destination.* = null;
        server.* = reference;
        return;
    }
    server.* = null;
    destination.* = if (equals(value, "currentColor")) style.color else geometry.parseColor(trim(value)) orelse return Error.UnsupportedSvg;
}

fn parseAlpha(raw: []const u8) ?f32 {
    const value = trim(raw);
    if (std.mem.endsWith(u8, value, "%")) {
        const percent = std.fmt.parseFloat(f32, value[0 .. value.len - 1]) catch return null;
        return std.math.clamp(percent / 100, 0, 1);
    }
    return std.math.clamp(parseNumber(value) orelse return null, 0, 1);
}

fn parseLocalUrlReference(raw: []const u8) ?Reference {
    const value = trim(raw);
    if (!startsWithIgnoreCase(value, "url(")) return null;
    if (value.len < 7 or value[value.len - 1] != ')') return null;
    var inside = trim(value[4 .. value.len - 1]);
    if (inside.len >= 2 and ((inside[0] == '"' and inside[inside.len - 1] == '"') or (inside[0] == '\'' and inside[inside.len - 1] == '\''))) {
        inside = trim(inside[1 .. inside.len - 1]);
    } else if (inside.len >= 12 and
        ((std.mem.startsWith(u8, inside, "&quot;") and std.mem.endsWith(u8, inside, "&quot;")) or
            (std.mem.startsWith(u8, inside, "&apos;") and std.mem.endsWith(u8, inside, "&apos;"))))
    {
        inside = trim(inside[6 .. inside.len - 6]);
    }
    if (inside.len < 2 or inside[0] != '#') return null;
    return Reference.init(inside[1..]) catch null;
}

fn applyClipReference(clips: *ClipChain, attributes: []const u8) !void {
    const declaration = attribute(attributes, "style");
    const value = styleProperty(declaration, "clip-path") orelse attribute(attributes, "clip-path") orelse return;
    if (equals(value, "none")) return;
    const reference = parseLocalUrlReference(value) orelse return Error.UnsupportedSvg;
    try clips.append(reference);
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

test "parse selectable SVG text gradients and clipping in paint order" {
    const allocator = std.testing.allocator;
    var document = try parseXml(
        allocator,
        "<svg viewBox='0 0 200 100'><defs><linearGradient id='revenue' x1='0%' y1='0%' x2='100%' y2='0%'><stop offset='0%' stop-color='#2563eb'/><stop offset='100%' style='stop-color:#7c3aed;stop-opacity:.5'/></linearGradient><clipPath id='plot'><rect x='10' y='10' width='180' height='70'/></clipPath></defs><g clip-path='url(#plot)'><rect x='0' y='0' width='200' height='90' fill='url(#revenue)'/><text x='20' y='50' font-size='14' text-anchor='start'>Q2 &amp; <tspan dx='4' font-weight='bold'>€4.82M</tspan></text></g></svg>",
    );
    defer document.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), document.gradients.items.len);
    try std.testing.expectEqual(@as(u8, 2), document.gradients.items[0].stop_len);
    try std.testing.expectEqual(@as(usize, 1), document.clips.items.len);
    try std.testing.expectEqual(@as(usize, 1), document.clips.items[0].shape_count);
    try std.testing.expectEqual(@as(usize, 2), document.texts.items.len);
    try std.testing.expectEqualStrings("Q2 &", document.textSlice(document.texts.items[0]));
    try std.testing.expectEqualStrings("€4.82M", document.textSlice(document.texts.items[1]));
    try std.testing.expectEqual(@as(usize, 3), document.items.items.len);
    try std.testing.expect(document.shapes.items[1].style.fill_server != null);
    try std.testing.expectEqual(@as(u8, 1), document.shapes.items[1].clips.len);
}

test "reject SVG constructs that need a scoped raster fallback" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(Error.UnsupportedSvg, parseXml(
        allocator,
        "<svg viewBox='0 0 10 10'><svg viewBox='0 0 5 5'><rect width='5' height='5'/></svg></svg>",
    ));
    try std.testing.expectError(Error.UnsupportedSvg, parseXml(
        allocator,
        "<svg viewBox='0 0 10 10'><rect width='10' height='10' filter='url(#blur)'/></svg>",
    ));
    try std.testing.expectError(Error.UnsupportedSvg, parseXml(
        allocator,
        "<svg viewBox='0 0 10 10'><g opacity='.5'><rect width='10' height='10'/></g></svg>",
    ));
    try std.testing.expectError(Error.InvalidSvg, parseXml(
        allocator,
        "<svg viewBox='0 0 10 10'><rect width='10' height='10' fill='url(#missing)'/></svg>",
    ));
}
