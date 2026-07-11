//! Longhand application from cascaded declarations to box.Style.
//!
//! This boundary is intentionally separate from selector matching and source
//! ordering so typed computed values can evolve without growing the parser.

const std = @import("std");
const box = @import("../box.zig");
const values = @import("values.zig");

const eqlProp = values.eqlProp;
const parseDisplay = values.parseDisplay;
const parsePosition = values.parsePosition;
const parseFloatValue = values.parseFloatValue;
const parseWhiteSpace = values.parseWhiteSpace;
const parseFontWeight = values.parseFontWeight;
const parseFontStyle = values.parseFontStyle;
const parseLength = values.parseLength;
const parseDimension = values.parseDimension;
const parseLineHeight = values.parseLineHeight;
const parseEdges = values.parseEdges;
const parseTextAlign = values.parseTextAlign;
const parseTextDecoration = values.parseTextDecoration;
const parseBoxSizing = values.parseBoxSizing;
const parseBorderCollapse = values.parseBorderCollapse;
const parsePageBreak = values.parsePageBreak;
const parseBorderStyle = values.parseBorderStyle;
const parsePositiveInteger = values.parsePositiveInteger;

pub fn applyDeclaration(style: *box.Style, name: []const u8, value: []const u8) void {
    if (eqlProp(name, "display")) {
        if (parseDisplay(value)) |d| {
            style.display = d;
        } else {
            style.layout_supported = false;
        }
    } else if (eqlProp(name, "position")) {
        if (parsePosition(value)) |p| style.position = p;
    } else if (eqlProp(name, "float")) {
        if (parseFloatValue(value)) |f| style.float_direction = f;
    } else if (eqlProp(name, "white-space")) {
        if (parseWhiteSpace(value)) |w| style.white_space = w;
    } else if (eqlProp(name, "font-size")) {
        if (parseLength(value)) |fs| style.font_size = fs;
    } else if (eqlProp(name, "font-family")) {
        style.font_family = value;
    } else if (eqlProp(name, "font-weight")) {
        if (parseFontWeight(value)) |weight| style.font_weight = weight;
    } else if (eqlProp(name, "font-style")) {
        if (parseFontStyle(value)) |font_style| style.font_style = font_style;
    } else if (eqlProp(name, "color")) {
        style.color = value;
    } else if (eqlProp(name, "background") or eqlProp(name, "background-color")) {
        style.background = value;
    } else if (eqlProp(name, "width")) {
        if (parseDimension(value, style.font_size)) |w| style.width = w;
    } else if (eqlProp(name, "height")) {
        if (parseDimension(value, style.font_size)) |h| style.height = h;
    } else if (eqlProp(name, "min-width")) {
        if (parseDimension(value, style.font_size)) |w| style.min_width = w;
    } else if (eqlProp(name, "max-width")) {
        if (parseDimension(value, style.font_size)) |w| style.max_width = w;
    } else if (eqlProp(name, "min-height")) {
        if (parseDimension(value, style.font_size)) |h| style.min_height = h;
    } else if (eqlProp(name, "max-height")) {
        if (parseDimension(value, style.font_size)) |h| style.max_height = h;
    } else if (eqlProp(name, "line-height")) {
        if (parseLineHeight(value, style.font_size)) |lh| style.line_height = lh;
    } else if (eqlProp(name, "letter-spacing")) {
        if (eqlProp(std.mem.trim(u8, value, " \t\n\r\x0C"), "normal")) {
            style.letter_spacing = 0;
        } else if (parseLength(value)) |spacing| {
            style.letter_spacing = spacing;
        }
    } else if (eqlProp(name, "text-align")) {
        if (parseTextAlign(value)) |ta| style.text_align = ta;
    } else if (eqlProp(name, "text-decoration") or eqlProp(name, "text-decoration-line")) {
        if (parseTextDecoration(value)) |decoration| style.text_decoration = decoration;
    } else if (eqlProp(name, "box-sizing")) {
        if (parseBoxSizing(value)) |bs| style.box_sizing = bs;
    } else if (eqlProp(name, "border-collapse")) {
        if (parseBorderCollapse(value)) |collapse| style.border_collapse = collapse;
    } else if (eqlProp(name, "border-radius")) {
        if (parseLength(value)) |radius| style.border_radius = @max(radius, 0);
    } else if (eqlProp(name, "page-break-before") or eqlProp(name, "break-before")) {
        if (parsePageBreak(value)) |pb| style.page_break_before = pb;
    } else if (eqlProp(name, "page-break-after") or eqlProp(name, "break-after")) {
        if (parsePageBreak(value)) |pb| style.page_break_after = pb;
    } else if (eqlProp(name, "page-break-inside") or eqlProp(name, "break-inside")) {
        if (parsePageBreak(value)) |pb| style.page_break_inside = pb;
    } else if (eqlProp(name, "orphans")) {
        if (parsePositiveInteger(value)) |o| style.orphans = o;
    } else if (eqlProp(name, "widows")) {
        if (parsePositiveInteger(value)) |w| style.widows = w;
    } else if (eqlProp(name, "margin")) {
        style.margin = parseEdges(value);
    } else if (eqlProp(name, "margin-top")) {
        if (parseLength(value)) |l| style.margin.top = l;
    } else if (eqlProp(name, "margin-right")) {
        if (parseLength(value)) |l| style.margin.right = l;
    } else if (eqlProp(name, "margin-bottom")) {
        if (parseLength(value)) |l| style.margin.bottom = l;
    } else if (eqlProp(name, "margin-left")) {
        if (parseLength(value)) |l| style.margin.left = l;
    } else if (eqlProp(name, "padding")) {
        style.padding = parseEdges(value);
    } else if (eqlProp(name, "padding-top")) {
        if (parseLength(value)) |l| style.padding.top = l;
    } else if (eqlProp(name, "padding-right")) {
        if (parseLength(value)) |l| style.padding.right = l;
    } else if (eqlProp(name, "padding-bottom")) {
        if (parseLength(value)) |l| style.padding.bottom = l;
    } else if (eqlProp(name, "padding-left")) {
        if (parseLength(value)) |l| style.padding.left = l;
    } else if (eqlProp(name, "border")) {
        applyBorderShorthand(style, value, .all);
    } else if (eqlProp(name, "border-top")) {
        applyBorderShorthand(style, value, .top);
    } else if (eqlProp(name, "border-right")) {
        applyBorderShorthand(style, value, .right);
    } else if (eqlProp(name, "border-bottom")) {
        applyBorderShorthand(style, value, .bottom);
    } else if (eqlProp(name, "border-left")) {
        applyBorderShorthand(style, value, .left);
    } else if (eqlProp(name, "border-style")) {
        if (parseBorderStyle(value)) |bs| {
            style.border_top_style = bs;
            style.border_right_style = bs;
            style.border_bottom_style = bs;
            style.border_left_style = bs;
        }
    } else if (eqlProp(name, "border-top-style")) {
        if (parseBorderStyle(value)) |bs| style.border_top_style = bs;
    } else if (eqlProp(name, "border-right-style")) {
        if (parseBorderStyle(value)) |bs| style.border_right_style = bs;
    } else if (eqlProp(name, "border-bottom-style")) {
        if (parseBorderStyle(value)) |bs| style.border_bottom_style = bs;
    } else if (eqlProp(name, "border-left-style")) {
        if (parseBorderStyle(value)) |bs| style.border_left_style = bs;
    } else if (eqlProp(name, "border-color")) {
        style.border_top_color = value;
        style.border_right_color = value;
        style.border_bottom_color = value;
        style.border_left_color = value;
    } else if (eqlProp(name, "border-top-color")) {
        style.border_top_color = value;
    } else if (eqlProp(name, "border-right-color")) {
        style.border_right_color = value;
    } else if (eqlProp(name, "border-bottom-color")) {
        style.border_bottom_color = value;
    } else if (eqlProp(name, "border-left-color")) {
        style.border_left_color = value;
    } else if (eqlProp(name, "border-top-width")) {
        if (parseLength(value)) |l| style.border.top = l;
    } else if (eqlProp(name, "border-right-width")) {
        if (parseLength(value)) |l| style.border.right = l;
    } else if (eqlProp(name, "border-bottom-width")) {
        if (parseLength(value)) |l| style.border.bottom = l;
    } else if (eqlProp(name, "border-left-width")) {
        if (parseLength(value)) |l| style.border.left = l;
    }
}

const BorderSide = enum { all, top, right, bottom, left };

const BorderShorthand = struct {
    width: f32 = 3,
    border_style: box.BorderStyle = .none,
    color: ?[]const u8 = null,
};

fn applyBorderShorthand(style: *box.Style, value: []const u8, side: BorderSide) void {
    var parsed = BorderShorthand{};
    var saw_width = false;
    var saw_style = false;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");
    while (tokens.next()) |token| {
        if (!saw_width) {
            if (parseBorderWidth(token)) |width| {
                parsed.width = width;
                saw_width = true;
                continue;
            }
        }
        if (!saw_style) {
            if (parseBorderStyle(token)) |border_style| {
                parsed.border_style = border_style;
                saw_style = true;
                continue;
            }
        }
        parsed.color = token;
    }
    const color = parsed.color orelse style.color;

    if (side == .all or side == .top) {
        style.border.top = parsed.width;
        style.border_top_style = parsed.border_style;
        style.border_top_color = color;
    }
    if (side == .all or side == .right) {
        style.border.right = parsed.width;
        style.border_right_style = parsed.border_style;
        style.border_right_color = color;
    }
    if (side == .all or side == .bottom) {
        style.border.bottom = parsed.width;
        style.border_bottom_style = parsed.border_style;
        style.border_bottom_color = color;
    }
    if (side == .all or side == .left) {
        style.border.left = parsed.width;
        style.border_left_style = parsed.border_style;
        style.border_left_color = color;
    }
}

fn parseBorderWidth(value: []const u8) ?f32 {
    if (eqlProp(value, "thin")) return 1;
    if (eqlProp(value, "medium")) return 3;
    if (eqlProp(value, "thick")) return 5;
    return parseLength(value);
}
