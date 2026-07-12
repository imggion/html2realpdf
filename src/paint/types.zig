//! Backend-neutral display-list command types.

const std = @import("std");
const geometry = @import("../geometry.zig");
const pagination = @import("../pagination.zig");
const box = @import("../box.zig");
const font = @import("../font.zig");

pub const TextRun = struct {
    position: geometry.Point,
    width: f32 = 0,
    text: []const u8,
    shaped: ?font.ShapedRun = null,
    leading_space: bool = false,
    line_id: ?usize = null,
    font_size: f32,
    font_family: []const u8 = "Noto Sans",
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    font_weight: box.FontWeight = .normal,
    font_style: box.FontStyle = .normal,
    color: geometry.Color,
    artifact: bool = false,
};

pub const FillRect = struct {
    rect: geometry.Rect,
    color: geometry.Color,
};

pub const FillRoundedRect = struct {
    rect: geometry.Rect,
    radius: f32 = 0,
    radii: box.ResolvedBorderRadii = .{},
    color: geometry.Color,
};

pub const StrokeRoundedRect = struct {
    rect: geometry.Rect,
    radius: f32 = 0,
    radii: box.ResolvedBorderRadii = .{},
    width: f32,
    color: geometry.Color,
    style: box.BorderStyle = .solid,
};

pub const StrokeLine = struct {
    from: geometry.Point,
    to: geometry.Point,
    width: f32,
    color: geometry.Color,
    style: box.BorderStyle = .solid,
};

pub const LinkAnnotation = struct {
    rect: geometry.Rect,
    url: []const u8,
};

pub const Image = struct {
    rect: geometry.Rect,
    source: []const u8,
    intrinsic_width: ?f32 = null,
    intrinsic_height: ?f32 = null,
    object_fit: box.ObjectFit = .fill,
    object_position: box.ObjectPosition = .{},
    paint_clip: ?geometry.Rect = null,
    paint_clip_radii: box.ResolvedBorderRadii = .{},
};

pub const GradientStop = struct {
    offset: f32,
    color: geometry.Color,
};

pub const GradientStops = struct {
    values: [16]GradientStop = @splat(.{ .offset = 0, .color = geometry.Color.transparent }),
    len: u8 = 0,

    pub fn slice(self: *const GradientStops) []const GradientStop {
        return self.values[0..self.len];
    }
};

pub const LinearGradient = struct {
    paint_rect: geometry.Rect,
    paint_radii: box.ResolvedBorderRadii = .{},
    start: geometry.Point,
    end: geometry.Point,
    stops: GradientStops,
};

pub const RadialGradient = struct {
    paint_rect: geometry.Rect,
    paint_radii: box.ResolvedBorderRadii = .{},
    center: geometry.Point,
    radius_x: f32,
    radius_y: f32,
    stops: GradientStops,
};

pub const ConicGradient = struct {
    paint_rect: geometry.Rect,
    paint_radii: box.ResolvedBorderRadii = .{},
    center: geometry.Point,
    start_angle: f32,
    stops: GradientStops,
};

pub const BoxShadow = struct {
    rect: geometry.Rect,
    radii: box.ResolvedBorderRadii = .{},
    offset_x: f32,
    offset_y: f32,
    blur: f32 = 0,
    spread: f32 = 0,
    color: geometry.Color,
    inset: bool = false,
};

pub const Command = union(enum) {
    fill_rect: FillRect,
    fill_rounded_rect: FillRoundedRect,
    stroke_rounded_rect: StrokeRoundedRect,
    stroke_line: StrokeLine,
    text: TextRun,
    link: LinkAnnotation,
    image: Image,
    linear_gradient: LinearGradient,
    radial_gradient: RadialGradient,
    conic_gradient: ConicGradient,
    box_shadow: BoxShadow,
};

pub const PageCommand = struct {
    page_index: usize,
    command: Command,
    clip_rect: ?geometry.Rect = null,
    clip_radii: ?box.ResolvedBorderRadii = null,
    clip_transform: geometry.AffineTransform = .identity,
    opacity: f32 = 1,
    opacity_groups: box.OpacityGroupPath = .{},
    transform: geometry.AffineTransform = .identity,
};

pub const DisplayList = struct {
    commands: std.ArrayList(PageCommand),
    page_count: usize,
    page_spec: pagination.PageSpec,

    pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
    }
};
