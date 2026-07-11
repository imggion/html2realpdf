//! Longhand application from cascaded declarations to box.Style.
//!
//! This boundary is intentionally separate from selector matching and source
//! ordering so typed computed values can evolve without growing the parser.

const std = @import("std");
const box = @import("../box.zig");
const expressions = @import("expressions.zig");
const values = @import("values.zig");
const diagnostics = @import("../diagnostics.zig");

const eqlProp = values.eqlProp;
const parseDisplay = values.parseDisplay;
const parsePosition = values.parsePosition;
const parseFloatValue = values.parseFloatValue;
const parseWhiteSpace = values.parseWhiteSpace;
const parseFontWeight = values.parseFontWeight;
const parseFontStyle = values.parseFontStyle;
const parseLength = values.parseLength;
const parseDimension = values.parseDimension;
const parseDimensionWithContext = values.parseDimensionWithContext;
const parseLineHeight = values.parseLineHeight;
const parseTextAlign = values.parseTextAlign;
const parseTextDecoration = values.parseTextDecoration;
const parseBoxSizing = values.parseBoxSizing;
const parseBorderCollapse = values.parseBorderCollapse;
const parsePageBreak = values.parsePageBreak;
const parseBorderStyle = values.parseBorderStyle;
const parseBorderWidth = values.parseBorderWidth;
const parsePositiveInteger = values.parsePositiveInteger;

pub const Context = struct {
    allocator: std.mem.Allocator,
    expression_store: *expressions.Store,
    root_font_size: f32 = 16,
    viewport_width: f32 = 800,
    viewport_height: f32 = 600,
    parent_style: ?*const box.Style = null,
    ua_style: ?*const box.Style = null,
    diagnostics: ?*std.ArrayList(diagnostics.Diagnostic) = null,

    fn expressionContext(self: Context, font_size: f32) expressions.Context {
        return .{
            .font_size = font_size,
            .root_font_size = self.root_font_size,
            .viewport_width = self.viewport_width,
            .viewport_height = self.viewport_height,
        };
    }
};

const supported_properties = [_][]const u8{
    "background-color",  "border-bottom-color", "border-bottom-style", "border-bottom-width", "border-collapse",    "border-left-color",
    "border-left-style", "border-left-width",   "border-radius",       "border-right-color",  "border-right-style", "border-right-width",
    "border-top-color",  "border-top-style",    "border-top-width",    "box-sizing",          "break-after",        "break-before",
    "break-inside",      "color",               "display",             "float",               "font-family",        "font-size",
    "font-style",        "font-weight",         "height",              "letter-spacing",      "line-height",        "margin-bottom",
    "margin-left",       "margin-right",        "margin-top",          "max-height",          "max-width",          "min-height",
    "min-width",         "orphans",             "padding-bottom",      "padding-left",        "padding-right",      "padding-top",
    "page-break-after",  "page-break-before",   "page-break-inside",   "position",            "text-align",         "text-decoration-line",
    "white-space",       "widows",              "width",
};

pub fn supportsProperty(name: []const u8) bool {
    inline for (supported_properties) |property| {
        if (eqlProp(name, property)) return true;
    }
    return false;
}

pub fn applyDeclaration(context: Context, style: *box.Style, name: []const u8, value: []const u8) !void {
    const normalized = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (cssWideKeyword(normalized)) |keyword| {
        applyCssWide(context, style, name, keyword);
        return;
    }
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
        if (parseLength(value)) |fs| {
            style.font_size = fs;
        } else if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |dimension| {
            if (dimension.resolve(style.font_size)) |resolved| style.font_size = @max(resolved, 0);
        }
    } else if (eqlProp(name, "font-family")) {
        style.font_family = value;
    } else if (eqlProp(name, "font-weight")) {
        if (parseFontWeight(value)) |weight| style.font_weight = weight;
    } else if (eqlProp(name, "font-style")) {
        if (parseFontStyle(value)) |font_style| style.font_style = font_style;
    } else if (eqlProp(name, "color")) {
        style.color = if (eqlProp(normalized, "currentColor"))
            if (context.parent_style) |parent| parent.color else (box.Style{}).color
        else
            value;
    } else if (eqlProp(name, "background-color")) {
        style.background = if (eqlProp(normalized, "currentColor")) style.color else value;
    } else if (eqlProp(name, "width")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |w| style.width = w;
    } else if (eqlProp(name, "height")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |h| style.height = h;
    } else if (eqlProp(name, "min-width")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |w| style.min_width = w;
    } else if (eqlProp(name, "max-width")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |w| style.max_width = w;
    } else if (eqlProp(name, "min-height")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |h| style.min_height = h;
    } else if (eqlProp(name, "max-height")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |h| style.max_height = h;
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
    } else if (eqlProp(name, "text-decoration-line")) {
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
    } else if (eqlProp(name, "margin-top")) {
        if (parseLength(value)) |l| style.margin.top = l;
    } else if (eqlProp(name, "margin-right")) {
        if (parseLength(value)) |l| style.margin.right = l;
    } else if (eqlProp(name, "margin-bottom")) {
        if (parseLength(value)) |l| style.margin.bottom = l;
    } else if (eqlProp(name, "margin-left")) {
        if (parseLength(value)) |l| style.margin.left = l;
    } else if (eqlProp(name, "padding-top")) {
        if (parseLength(value)) |l| style.padding.top = l;
    } else if (eqlProp(name, "padding-right")) {
        if (parseLength(value)) |l| style.padding.right = l;
    } else if (eqlProp(name, "padding-bottom")) {
        if (parseLength(value)) |l| style.padding.bottom = l;
    } else if (eqlProp(name, "padding-left")) {
        if (parseLength(value)) |l| style.padding.left = l;
    } else if (eqlProp(name, "border-top-style")) {
        if (parseBorderStyle(value)) |bs| style.border_top_style = bs;
    } else if (eqlProp(name, "border-right-style")) {
        if (parseBorderStyle(value)) |bs| style.border_right_style = bs;
    } else if (eqlProp(name, "border-bottom-style")) {
        if (parseBorderStyle(value)) |bs| style.border_bottom_style = bs;
    } else if (eqlProp(name, "border-left-style")) {
        if (parseBorderStyle(value)) |bs| style.border_left_style = bs;
    } else if (eqlProp(name, "border-top-color")) {
        style.border_top_color = if (eqlProp(normalized, "currentColor")) style.color else value;
    } else if (eqlProp(name, "border-right-color")) {
        style.border_right_color = if (eqlProp(normalized, "currentColor")) style.color else value;
    } else if (eqlProp(name, "border-bottom-color")) {
        style.border_bottom_color = if (eqlProp(normalized, "currentColor")) style.color else value;
    } else if (eqlProp(name, "border-left-color")) {
        style.border_left_color = if (eqlProp(normalized, "currentColor")) style.color else value;
    } else if (eqlProp(name, "border-top-width")) {
        if (parseBorderWidth(value)) |l| style.border.top = l;
    } else if (eqlProp(name, "border-right-width")) {
        if (parseBorderWidth(value)) |l| style.border.right = l;
    } else if (eqlProp(name, "border-bottom-width")) {
        if (parseBorderWidth(value)) |l| style.border.bottom = l;
    } else if (eqlProp(name, "border-left-width")) {
        if (parseBorderWidth(value)) |l| style.border.left = l;
    }
}

const CssWideKeyword = enum { initial, inherit, unset, revert };

fn cssWideKeyword(value: []const u8) ?CssWideKeyword {
    if (eqlProp(value, "initial")) return .initial;
    if (eqlProp(value, "inherit")) return .inherit;
    if (eqlProp(value, "unset")) return .unset;
    if (eqlProp(value, "revert")) return .revert;
    return null;
}

fn applyCssWide(context: Context, style: *box.Style, name: []const u8, keyword: CssWideKeyword) void {
    const initial = box.Style{};
    const inherited = isInheritedProperty(name);
    const source = switch (keyword) {
        .initial => &initial,
        .inherit => context.parent_style orelse &initial,
        .unset => if (inherited) context.parent_style orelse &initial else &initial,
        .revert => if (inherited) context.parent_style orelse &initial else context.ua_style orelse &initial,
    };
    copyProperty(style, source, name);
}

fn isInheritedProperty(name: []const u8) bool {
    return eqlProp(name, "color") or eqlProp(name, "font-family") or eqlProp(name, "font-size") or
        eqlProp(name, "font-style") or eqlProp(name, "font-weight") or eqlProp(name, "line-height") or
        eqlProp(name, "letter-spacing") or eqlProp(name, "text-align") or eqlProp(name, "text-decoration") or
        eqlProp(name, "text-decoration-line") or eqlProp(name, "white-space") or eqlProp(name, "orphans") or
        eqlProp(name, "widows");
}

fn copyProperty(target: *box.Style, source: *const box.Style, name: []const u8) void {
    if (eqlProp(name, "display")) target.display = source.display else if (eqlProp(name, "position")) target.position = source.position else if (eqlProp(name, "float")) target.float_direction = source.float_direction else if (eqlProp(name, "white-space")) target.white_space = source.white_space else if (eqlProp(name, "font-size")) target.font_size = source.font_size else if (eqlProp(name, "font-family")) target.font_family = source.font_family else if (eqlProp(name, "font-weight")) target.font_weight = source.font_weight else if (eqlProp(name, "font-style")) target.font_style = source.font_style else if (eqlProp(name, "color")) target.color = source.color else if (eqlProp(name, "background") or eqlProp(name, "background-color")) target.background = source.background else if (eqlProp(name, "width")) target.width = source.width else if (eqlProp(name, "height")) target.height = source.height else if (eqlProp(name, "min-width")) target.min_width = source.min_width else if (eqlProp(name, "max-width")) target.max_width = source.max_width else if (eqlProp(name, "min-height")) target.min_height = source.min_height else if (eqlProp(name, "max-height")) target.max_height = source.max_height else if (eqlProp(name, "line-height")) target.line_height = source.line_height else if (eqlProp(name, "letter-spacing")) target.letter_spacing = source.letter_spacing else if (eqlProp(name, "text-align")) target.text_align = source.text_align else if (eqlProp(name, "text-decoration") or eqlProp(name, "text-decoration-line")) target.text_decoration = source.text_decoration else if (eqlProp(name, "box-sizing")) target.box_sizing = source.box_sizing else if (eqlProp(name, "border-collapse")) target.border_collapse = source.border_collapse else if (eqlProp(name, "border-radius")) target.border_radius = source.border_radius else if (eqlProp(name, "page-break-before") or eqlProp(name, "break-before")) target.page_break_before = source.page_break_before else if (eqlProp(name, "page-break-after") or eqlProp(name, "break-after")) target.page_break_after = source.page_break_after else if (eqlProp(name, "page-break-inside") or eqlProp(name, "break-inside")) target.page_break_inside = source.page_break_inside else if (eqlProp(name, "orphans")) target.orphans = source.orphans else if (eqlProp(name, "widows")) target.widows = source.widows else if (eqlProp(name, "margin")) target.margin = source.margin else if (eqlProp(name, "margin-top")) target.margin.top = source.margin.top else if (eqlProp(name, "margin-right")) target.margin.right = source.margin.right else if (eqlProp(name, "margin-bottom")) target.margin.bottom = source.margin.bottom else if (eqlProp(name, "margin-left")) target.margin.left = source.margin.left else if (eqlProp(name, "padding")) target.padding = source.padding else if (eqlProp(name, "padding-top")) target.padding.top = source.padding.top else if (eqlProp(name, "padding-right")) target.padding.right = source.padding.right else if (eqlProp(name, "padding-bottom")) target.padding.bottom = source.padding.bottom else if (eqlProp(name, "padding-left")) target.padding.left = source.padding.left else if (eqlProp(name, "border")) {
        target.border = source.border;
        target.border_top_style = source.border_top_style;
        target.border_right_style = source.border_right_style;
        target.border_bottom_style = source.border_bottom_style;
        target.border_left_style = source.border_left_style;
        target.border_top_color = source.border_top_color;
        target.border_right_color = source.border_right_color;
        target.border_bottom_color = source.border_bottom_color;
        target.border_left_color = source.border_left_color;
    } else if (eqlProp(name, "border-color")) {
        target.border_top_color = source.border_top_color;
        target.border_right_color = source.border_right_color;
        target.border_bottom_color = source.border_bottom_color;
        target.border_left_color = source.border_left_color;
    } else if (eqlProp(name, "border-style")) {
        target.border_top_style = source.border_top_style;
        target.border_right_style = source.border_right_style;
        target.border_bottom_style = source.border_bottom_style;
        target.border_left_style = source.border_left_style;
    } else if (eqlProp(name, "border-top-color")) target.border_top_color = source.border_top_color else if (eqlProp(name, "border-right-color")) target.border_right_color = source.border_right_color else if (eqlProp(name, "border-bottom-color")) target.border_bottom_color = source.border_bottom_color else if (eqlProp(name, "border-left-color")) target.border_left_color = source.border_left_color else if (eqlProp(name, "border-top-style")) target.border_top_style = source.border_top_style else if (eqlProp(name, "border-right-style")) target.border_right_style = source.border_right_style else if (eqlProp(name, "border-bottom-style")) target.border_bottom_style = source.border_bottom_style else if (eqlProp(name, "border-left-style")) target.border_left_style = source.border_left_style else if (eqlProp(name, "border-top-width")) target.border.top = source.border.top else if (eqlProp(name, "border-right-width")) target.border.right = source.border.right else if (eqlProp(name, "border-bottom-width")) target.border.bottom = source.border.bottom else if (eqlProp(name, "border-left-width")) target.border.left = source.border.left;
}
