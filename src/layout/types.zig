//! Shared flat fragment and layout option types.

const std = @import("std");
const box = @import("../box.zig");
const font = @import("../font.zig");
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
    line_id: ?usize = null,
    inline_container_line_id: ?usize = null,
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
    border: box.EdgeSizes = .{},
    border_paint: BorderPaint = .{},
    border_radius: f32 = 0,
    page_break_before: box.PageBreak = .auto,
    page_break_after: box.PageBreak = .auto,
    page_break_inside: box.PageBreak = .auto,
    link_url: ?[]const u8 = null,
    image_source: ?[]const u8 = null,
    image_content_rect: ?geometry.Rect = null,
    intrinsic_width: ?f32 = null,
    intrinsic_height: ?f32 = null,
    object_fit: box.ObjectFit = .fill,
    object_position: box.ObjectPosition = .{},
    table_id: ?box.BoxId = null,
    is_table_header: bool = false,
};

pub const LayoutDocument = struct {
    fragments: std.ArrayList(Fragment),
    content_width: f32,
    content_height: f32,

    pub fn deinit(self: *LayoutDocument, allocator: std.mem.Allocator) void {
        self.fragments.deinit(allocator);
    }
};

pub const Options = struct {
    content_width: f32,
    page_height: ?f32 = null,
    font_registry: ?*const font.Registry = null,
    shaping_mode: font.ShapingMode = .identity,
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
