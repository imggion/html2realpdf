//! Backend-neutral display-list command types.

const std = @import("std");
const geometry = @import("../geometry.zig");
const pagination = @import("../pagination.zig");
const box = @import("../box.zig");

pub const TextRun = struct {
    position: geometry.Point,
    width: f32 = 0,
    text: []const u8,
    leading_space: bool = false,
    line_id: ?usize = null,
    font_size: f32,
    font_family: []const u8 = "Noto Sans",
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    font_weight: box.FontWeight = .normal,
    font_style: box.FontStyle = .normal,
    color: geometry.Color,
};

pub const FillRect = struct {
    rect: geometry.Rect,
    color: geometry.Color,
};

pub const FillRoundedRect = struct {
    rect: geometry.Rect,
    radius: f32,
    color: geometry.Color,
};

pub const StrokeRoundedRect = struct {
    rect: geometry.Rect,
    radius: f32,
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
};

pub const Command = union(enum) {
    fill_rect: FillRect,
    fill_rounded_rect: FillRoundedRect,
    stroke_rounded_rect: StrokeRoundedRect,
    stroke_line: StrokeLine,
    text: TextRun,
    link: LinkAnnotation,
    image: Image,
};

pub const PageCommand = struct {
    page_index: usize,
    command: Command,
};

pub const DisplayList = struct {
    commands: std.ArrayList(PageCommand),
    page_count: usize,
    page_spec: pagination.PageSpec,

    pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
    }
};
