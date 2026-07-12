//! Shared flat fragment and layout option types.

const std = @import("std");
const box = @import("../box.zig");
const font = @import("../font.zig");
const page_geometry = @import("page_geometry.zig");
const geometry = @import("../geometry.zig");

pub const FragmentId = usize;

pub const FragmentKind = enum {
    box,
    text,
    replaced,
};

pub const BorderPaint = struct {
    top_style: box.BorderStyle = .solid,
    right_style: box.BorderStyle = .solid,
    bottom_style: box.BorderStyle = .solid,
    left_style: box.BorderStyle = .solid,
    top_color: geometry.Color = geometry.Color.black,
    right_color: geometry.Color = geometry.Color.black,
    bottom_color: geometry.Color = geometry.Color.black,
    left_color: geometry.Color = geometry.Color.black,
};

pub const Fragment = struct {
    kind: FragmentKind,
    source_box: box.BoxId,
    rect: geometry.Rect,
    clip_rect: ?geometry.Rect = null,
    clip_radii: ?box.ResolvedBorderRadii = null,
    clip_transform: geometry.AffineTransform = .identity,
    line_id: ?usize = null,
    inline_container_line_id: ?usize = null,
    inline_atomic_container: ?box.BoxId = null,
    inline_atomic_root: bool = false,
    inline_baseline_offset: ?f32 = null,
    inline_margin_top: f32 = 0,
    inline_margin_bottom: f32 = 0,
    text: ?[]const u8 = null,
    shaped: ?font.ShapedRun = null,
    leading_space: bool = false,
    collapsible_space: bool = false,
    bidi_level: u8 = 0,
    font_size: f32 = 16,
    font_family: []const u8 = "Noto Sans",
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    vertical_align: box.VerticalAlign = .baseline,
    font_weight: box.FontWeight = .normal,
    font_style: box.FontStyle = .normal,
    color: geometry.Color = geometry.Color.black,
    text_decoration: box.TextDecoration = .none,
    text_decoration_style: box.TextDecorationStyle = .solid,
    text_decoration_color: ?geometry.Color = null,
    text_decoration_thickness: ?f32 = null,
    background: ?geometry.Color = null,
    background_image: []const u8 = "none",
    background_position: []const u8 = "0% 0%",
    background_size: []const u8 = "auto",
    background_repeat: []const u8 = "repeat",
    box_shadow: []const u8 = "none",
    text_shadow: []const u8 = "none",
    border: box.EdgeSizes = .{},
    border_paint: BorderPaint = .{},
    border_radius: f32 = 0,
    border_radii: box.BorderRadii = .{},
    box_decoration_break: box.BoxDecorationBreak = .slice,
    legacy_fragment_borders: bool = false,
    page_break_before: box.PageBreak = .auto,
    page_break_after: box.PageBreak = .auto,
    page_break_inside: box.PageBreak = .auto,
    fixed: bool = false,
    positioned_group: ?box.BoxId = null,
    z_index: ?i32 = null,
    opacity: f32 = 1,
    opacity_groups: box.OpacityGroupPath = .{},
    transform: geometry.AffineTransform = .identity,
    paint_order: usize = 0,
    link_url: ?[]const u8 = null,
    image_source: ?[]const u8 = null,
    image_content_rect: ?geometry.Rect = null,
    intrinsic_width: ?f32 = null,
    intrinsic_height: ?f32 = null,
    object_fit: box.ObjectFit = .fill,
    object_position: box.ObjectPosition = .{},
    table_id: ?box.BoxId = null,
    is_table_header: bool = false,
    is_table_footer: bool = false,
};

pub const LayoutDocument = struct {
    fragments: std.ArrayList(Fragment),
    page_names: std.ArrayList([]const u8) = .empty,
    content_width: f32,
    content_height: f32,

    pub fn deinit(self: *LayoutDocument, allocator: std.mem.Allocator) void {
        self.fragments.deinit(allocator);
        self.page_names.deinit(allocator);
    }
};

pub const Options = struct {
    content_width: f32,
    page_height: ?f32 = null,
    font_registry: ?*const font.Registry = null,
    shaping_mode: font.ShapingMode = .identity,
    atomic_inline_baselines: bool = false,
    web_sizing: bool = false,
    page_spec: ?page_geometry.PageSpec = null,
    page_rules: []const page_geometry.PageRule = &.{},
};

pub fn borderPaint(style: box.Style) BorderPaint {
    return .{
        .top_style = style.border_top_style,
        .right_style = style.border_right_style,
        .bottom_style = style.border_bottom_style,
        .left_style = style.border_left_style,
        .top_color = geometry.parseColor(style.border_top_color) orelse geometry.Color.black,
        .right_color = geometry.parseColor(style.border_right_color) orelse geometry.Color.black,
        .bottom_color = geometry.parseColor(style.border_bottom_color) orelse geometry.Color.black,
        .left_color = geometry.parseColor(style.border_left_color) orelse geometry.Color.black,
    };
}
