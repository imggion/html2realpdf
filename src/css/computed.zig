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
const parseOpacity = values.parseOpacity;
const parseFloatValue = values.parseFloatValue;
const parseClear = values.parseClear;
const parseWhiteSpace = values.parseWhiteSpace;
const parseFontWeight = values.parseFontWeight;
const parseFontStyle = values.parseFontStyle;
const parseLength = values.parseLength;
const parseDimension = values.parseDimension;
const parseDimensionWithContext = values.parseDimensionWithContext;
const parseLineHeight = values.parseLineHeight;
const parseTextAlign = values.parseTextAlign;
const parseDirection = values.parseDirection;
const parseTextTransform = values.parseTextTransform;
const parseWordBreak = values.parseWordBreak;
const parseOverflowWrap = values.parseOverflowWrap;
const parseOverflow = values.parseOverflow;
const parseTextOverflow = values.parseTextOverflow;
const parseAspectRatio = values.parseAspectRatio;
const parseObjectFit = values.parseObjectFit;
const parseObjectPosition = values.parseObjectPosition;
const parseVerticalAlignKeyword = values.parseVerticalAlignKeyword;
const parseTextDecoration = values.parseTextDecoration;
const parseTextDecorationStyle = values.parseTextDecorationStyle;
const parseBoxSizing = values.parseBoxSizing;
const parseBorderCollapse = values.parseBorderCollapse;
const parseCaptionSide = values.parseCaptionSide;
const parseBoxDecorationBreak = values.parseBoxDecorationBreak;
const parseListStylePosition = values.parseListStylePosition;
const parseListStyleType = values.parseListStyleType;
const parseFlexDirection = values.parseFlexDirection;
const parseFlexWrap = values.parseFlexWrap;
const parseJustifyContent = values.parseJustifyContent;
const parseAlignItems = values.parseAlignItems;
const parseAlignSelf = values.parseAlignSelf;
const parseAlignContent = values.parseAlignContent;
const parseNonNegativeNumber = values.parseNonNegativeNumber;
const parseOrder = values.parseOrder;
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
    logical_direction: ?box.Direction = null,

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
    "align-content",         "align-items",          "align-self",            "aspect-ratio",              "background-color",
    "border-bottom-color",   "border-bottom-style",  "border-bottom-width",   "border-collapse",           "border-left-color",
    "border-left-style",     "border-left-width",    "border-radius",         "border-right-color",        "border-right-style",
    "border-right-width",    "border-top-color",     "border-top-style",      "border-top-width",          "box-decoration-break",
    "bottom",                "box-sizing",           "break-after",           "break-before",              "break-inside",
    "caption-side",          "clear",                "color",                 "column-gap",                "direction",
    "display",               "flex-basis",           "flex-direction",        "flex-grow",                 "flex-shrink",
    "flex-wrap",             "float",                "font-family",           "font-size",                 "font-style",
    "font-weight",           "gap",                  "height",                "justify-content",           "left",
    "letter-spacing",        "line-height",          "list-style-position",   "list-style-type",           "margin-bottom",
    "margin-left",           "margin-right",         "margin-top",            "max-height",                "max-width",
    "min-height",            "min-width",            "object-fit",            "object-position",           "opacity",
    "order",                 "orphans",              "overflow",              "overflow-wrap",             "padding-bottom",
    "padding-left",          "padding-right",        "padding-top",           "page-break-after",          "page-break-before",
    "page-break-inside",     "position",             "right",                 "row-gap",                   "text-align",
    "text-decoration-color", "text-decoration-line", "text-decoration-style", "text-decoration-thickness", "text-indent",
    "text-overflow",         "text-transform",       "top",                   "vertical-align",            "white-space",
    "widows",                "width",                "word-break",            "word-spacing",              "z-index",
};

const logical_properties = [_][]const u8{
    "block-size",
    "border-block-end-color",
    "border-block-end-style",
    "border-block-end-width",
    "border-block-start-color",
    "border-block-start-style",
    "border-block-start-width",
    "border-inline-end-color",
    "border-inline-end-style",
    "border-inline-end-width",
    "border-inline-start-color",
    "border-inline-start-style",
    "border-inline-start-width",
    "inline-size",
    "inset-block-end",
    "inset-block-start",
    "inset-inline-end",
    "inset-inline-start",
    "margin-block-end",
    "margin-block-start",
    "margin-inline-end",
    "margin-inline-start",
    "max-block-size",
    "max-inline-size",
    "min-block-size",
    "min-inline-size",
    "padding-block-end",
    "padding-block-start",
    "padding-inline-end",
    "padding-inline-start",
};

pub fn supportsProperty(name: []const u8) bool {
    inline for (supported_properties) |property| {
        if (eqlProp(name, property)) return true;
    }
    inline for (logical_properties) |property| {
        if (eqlProp(name, property)) return true;
    }
    return false;
}

pub fn applyDeclaration(context: Context, style: *box.Style, property_name: []const u8, value: []const u8) !void {
    const logical_direction = context.logical_direction orelse style.direction;
    const name = physicalPropertyName(property_name, logical_direction);
    const normalized = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (cssWideKeyword(normalized)) |keyword| {
        if (isLogicalProperty(property_name)) {
            applyLogicalCssWide(context, style, property_name, logical_direction, keyword);
        } else {
            applyCssWide(context, style, name, keyword);
        }
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
    } else if (eqlProp(name, "top")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |inset| style.insets.top = inset;
    } else if (eqlProp(name, "right")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |inset| style.insets.right = inset;
    } else if (eqlProp(name, "bottom")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |inset| style.insets.bottom = inset;
    } else if (eqlProp(name, "left")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |inset| style.insets.left = inset;
    } else if (eqlProp(name, "z-index")) {
        if (eqlProp(normalized, "auto")) {
            style.z_index = null;
        } else if (std.fmt.parseInt(i32, normalized, 10) catch null) |z_index| {
            style.z_index = z_index;
        }
    } else if (eqlProp(name, "opacity")) {
        if (parseOpacity(value)) |opacity| style.opacity = opacity;
    } else if (eqlProp(name, "direction")) {
        if (parseDirection(value)) |direction| style.direction = direction;
    } else if (eqlProp(name, "float")) {
        if (parseFloatValue(value)) |f| style.float_direction = f;
    } else if (eqlProp(name, "clear")) {
        if (parseClear(value)) |clear| style.clear_direction = clear;
    } else if (eqlProp(name, "flex-direction")) {
        if (parseFlexDirection(value)) |direction| style.flex_direction = direction;
    } else if (eqlProp(name, "flex-wrap")) {
        if (parseFlexWrap(value)) |wrap| style.flex_wrap = wrap;
    } else if (eqlProp(name, "flex-grow")) {
        if (parseNonNegativeNumber(value)) |grow| style.flex_grow = grow;
    } else if (eqlProp(name, "flex-shrink")) {
        if (parseNonNegativeNumber(value)) |shrink| style.flex_shrink = shrink;
    } else if (eqlProp(name, "flex-basis")) {
        if (eqlProp(normalized, "content")) {
            style.flex_basis = .maxContent;
        } else if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |basis| {
            style.flex_basis = basis;
        }
    } else if (eqlProp(name, "order")) {
        if (parseOrder(value)) |order| style.order = order;
    } else if (eqlProp(name, "justify-content")) {
        if (parseJustifyContent(value)) |alignment| style.justify_content = alignment;
    } else if (eqlProp(name, "align-items")) {
        if (parseAlignItems(value)) |alignment| style.align_items = alignment;
    } else if (eqlProp(name, "align-self")) {
        if (parseAlignSelf(value)) |alignment| style.align_self = alignment;
    } else if (eqlProp(name, "align-content")) {
        if (parseAlignContent(value)) |alignment| style.align_content = alignment;
    } else if (eqlProp(name, "row-gap") or eqlProp(name, "column-gap") or eqlProp(name, "gap")) {
        const gap: ?box.Length = if (eqlProp(normalized, "normal")) .{ .px = 0 } else try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size));
        if (gap) |resolved| {
            if (eqlProp(name, "row-gap") or eqlProp(name, "gap")) style.row_gap = resolved;
            if (eqlProp(name, "column-gap") or eqlProp(name, "gap")) style.column_gap = resolved;
        }
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
    } else if (eqlProp(name, "aspect-ratio")) {
        if (parseAspectRatio(value)) |ratio| style.aspect_ratio = ratio;
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
    } else if (eqlProp(name, "word-spacing")) {
        if (eqlProp(normalized, "normal")) {
            style.word_spacing = 0;
        } else if (parseLength(value)) |spacing| {
            style.word_spacing = spacing;
        }
    } else if (eqlProp(name, "text-indent")) {
        if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |indent| style.text_indent = indent;
    } else if (eqlProp(name, "text-align")) {
        if (parseTextAlign(value)) |ta| style.text_align = ta;
    } else if (eqlProp(name, "text-transform")) {
        if (parseTextTransform(value)) |transform| style.text_transform = transform;
    } else if (eqlProp(name, "word-break")) {
        if (parseWordBreak(value)) |word_break| style.word_break = word_break;
    } else if (eqlProp(name, "overflow-wrap")) {
        if (parseOverflowWrap(value)) |overflow_wrap| style.overflow_wrap = overflow_wrap;
    } else if (eqlProp(name, "overflow")) {
        if (parseOverflow(value)) |overflow| style.overflow = overflow;
    } else if (eqlProp(name, "text-overflow")) {
        if (parseTextOverflow(value)) |text_overflow| style.text_overflow = text_overflow;
    } else if (eqlProp(name, "object-fit")) {
        if (parseObjectFit(value)) |fit| style.object_fit = fit;
    } else if (eqlProp(name, "object-position")) {
        if (parseObjectPosition(value)) |position| style.object_position = position;
    } else if (eqlProp(name, "vertical-align")) {
        if (parseVerticalAlignKeyword(value)) |alignment| {
            style.vertical_align = alignment;
        } else if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |offset| {
            style.vertical_align = .{ .offset = offset };
        }
    } else if (eqlProp(name, "text-decoration-line")) {
        if (parseTextDecoration(value)) |decoration| style.text_decoration = decoration;
    } else if (eqlProp(name, "text-decoration-style")) {
        if (parseTextDecorationStyle(value)) |decoration_style| style.text_decoration_style = decoration_style;
    } else if (eqlProp(name, "text-decoration-color")) {
        style.text_decoration_color = if (eqlProp(normalized, "currentColor")) null else value;
    } else if (eqlProp(name, "text-decoration-thickness")) {
        if (eqlProp(normalized, "auto")) {
            style.text_decoration_thickness = .auto;
        } else if (eqlProp(normalized, "from-font")) {
            style.text_decoration_thickness = .fromFont;
        } else if (try parseDimensionWithContext(context.allocator, context.expression_store, value, context.expressionContext(style.font_size))) |thickness| {
            style.text_decoration_thickness = .{ .length = thickness };
        }
    } else if (eqlProp(name, "box-sizing")) {
        if (parseBoxSizing(value)) |bs| style.box_sizing = bs;
    } else if (eqlProp(name, "box-decoration-break")) {
        if (parseBoxDecorationBreak(value)) |decoration_break| style.box_decoration_break = decoration_break;
    } else if (eqlProp(name, "list-style-type")) {
        if (parseListStyleType(value)) |list_style_type| style.list_style_type = list_style_type;
    } else if (eqlProp(name, "list-style-position")) {
        if (parseListStylePosition(value)) |list_style_position| style.list_style_position = list_style_position;
    } else if (eqlProp(name, "border-collapse")) {
        if (parseBorderCollapse(value)) |collapse| style.border_collapse = collapse;
    } else if (eqlProp(name, "caption-side")) {
        if (parseCaptionSide(value)) |side| style.caption_side = side;
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
        style.margin_auto.top = eqlProp(normalized, "auto");
        if (style.margin_auto.top) style.margin.top = 0 else if (parseLength(value)) |l| style.margin.top = l;
    } else if (eqlProp(name, "margin-right")) {
        style.margin_auto.right = eqlProp(normalized, "auto");
        if (style.margin_auto.right) style.margin.right = 0 else if (parseLength(value)) |l| style.margin.right = l;
    } else if (eqlProp(name, "margin-bottom")) {
        style.margin_auto.bottom = eqlProp(normalized, "auto");
        if (style.margin_auto.bottom) style.margin.bottom = 0 else if (parseLength(value)) |l| style.margin.bottom = l;
    } else if (eqlProp(name, "margin-left")) {
        style.margin_auto.left = eqlProp(normalized, "auto");
        if (style.margin_auto.left) style.margin.left = 0 else if (parseLength(value)) |l| style.margin.left = l;
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

/// The native profile currently implements horizontal-tb writing. Logical
/// longhands therefore map block sides vertically and inline sides by the
/// element's final computed direction.
fn physicalPropertyName(name: []const u8, direction: box.Direction) []const u8 {
    if (eqlProp(name, "block-size")) return "height";
    if (eqlProp(name, "inline-size")) return "width";
    if (eqlProp(name, "min-block-size")) return "min-height";
    if (eqlProp(name, "max-block-size")) return "max-height";
    if (eqlProp(name, "min-inline-size")) return "min-width";
    if (eqlProp(name, "max-inline-size")) return "max-width";

    if (eqlProp(name, "margin-block-start")) return "margin-top";
    if (eqlProp(name, "margin-block-end")) return "margin-bottom";
    if (eqlProp(name, "inset-block-start")) return "top";
    if (eqlProp(name, "inset-block-end")) return "bottom";
    if (eqlProp(name, "padding-block-start")) return "padding-top";
    if (eqlProp(name, "padding-block-end")) return "padding-bottom";
    if (eqlProp(name, "border-block-start-width")) return "border-top-width";
    if (eqlProp(name, "border-block-end-width")) return "border-bottom-width";
    if (eqlProp(name, "border-block-start-style")) return "border-top-style";
    if (eqlProp(name, "border-block-end-style")) return "border-bottom-style";
    if (eqlProp(name, "border-block-start-color")) return "border-top-color";
    if (eqlProp(name, "border-block-end-color")) return "border-bottom-color";

    const start_is_left = direction == .ltr;
    if (eqlProp(name, "margin-inline-start")) return if (start_is_left) "margin-left" else "margin-right";
    if (eqlProp(name, "margin-inline-end")) return if (start_is_left) "margin-right" else "margin-left";
    if (eqlProp(name, "inset-inline-start")) return if (start_is_left) "left" else "right";
    if (eqlProp(name, "inset-inline-end")) return if (start_is_left) "right" else "left";
    if (eqlProp(name, "padding-inline-start")) return if (start_is_left) "padding-left" else "padding-right";
    if (eqlProp(name, "padding-inline-end")) return if (start_is_left) "padding-right" else "padding-left";
    if (eqlProp(name, "border-inline-start-width")) return if (start_is_left) "border-left-width" else "border-right-width";
    if (eqlProp(name, "border-inline-end-width")) return if (start_is_left) "border-right-width" else "border-left-width";
    if (eqlProp(name, "border-inline-start-style")) return if (start_is_left) "border-left-style" else "border-right-style";
    if (eqlProp(name, "border-inline-end-style")) return if (start_is_left) "border-right-style" else "border-left-style";
    if (eqlProp(name, "border-inline-start-color")) return if (start_is_left) "border-left-color" else "border-right-color";
    if (eqlProp(name, "border-inline-end-color")) return if (start_is_left) "border-right-color" else "border-left-color";
    return name;
}

fn isLogicalProperty(name: []const u8) bool {
    inline for (logical_properties) |property| {
        if (eqlProp(name, property)) return true;
    }
    return false;
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

fn applyLogicalCssWide(
    context: Context,
    style: *box.Style,
    logical_name: []const u8,
    target_direction: box.Direction,
    keyword: CssWideKeyword,
) void {
    const initial = box.Style{};
    const source = switch (keyword) {
        .initial, .unset => &initial,
        .inherit => context.parent_style orelse &initial,
        .revert => context.ua_style orelse &initial,
    };
    const target_name = physicalPropertyName(logical_name, target_direction);
    const source_name = physicalPropertyName(logical_name, source.direction);
    copyMappedPhysicalProperty(style, source, target_name, source_name);
}

fn copyMappedPhysicalProperty(target: *box.Style, source: *const box.Style, target_name: []const u8, source_name: []const u8) void {
    if (eqlProp(target_name, source_name)) {
        copyProperty(target, source, target_name);
        return;
    }

    if (eqlProp(target_name, "margin-left") or eqlProp(target_name, "margin-right")) {
        const value = if (eqlProp(source_name, "margin-left")) source.margin.left else source.margin.right;
        if (eqlProp(target_name, "margin-left")) target.margin.left = value else target.margin.right = value;
        return;
    }
    if (eqlProp(target_name, "left") or eqlProp(target_name, "right")) {
        const value = if (eqlProp(source_name, "left")) source.insets.left else source.insets.right;
        if (eqlProp(target_name, "left")) target.insets.left = value else target.insets.right = value;
        return;
    }
    if (eqlProp(target_name, "padding-left") or eqlProp(target_name, "padding-right")) {
        const value = if (eqlProp(source_name, "padding-left")) source.padding.left else source.padding.right;
        if (eqlProp(target_name, "padding-left")) target.padding.left = value else target.padding.right = value;
        return;
    }
    if (eqlProp(target_name, "border-left-width") or eqlProp(target_name, "border-right-width")) {
        const value = if (eqlProp(source_name, "border-left-width")) source.border.left else source.border.right;
        if (eqlProp(target_name, "border-left-width")) target.border.left = value else target.border.right = value;
        return;
    }
    if (eqlProp(target_name, "border-left-style") or eqlProp(target_name, "border-right-style")) {
        const value = if (eqlProp(source_name, "border-left-style")) source.border_left_style else source.border_right_style;
        if (eqlProp(target_name, "border-left-style")) target.border_left_style = value else target.border_right_style = value;
        return;
    }
    if (eqlProp(target_name, "border-left-color") or eqlProp(target_name, "border-right-color")) {
        const value = if (eqlProp(source_name, "border-left-color")) source.border_left_color else source.border_right_color;
        if (eqlProp(target_name, "border-left-color")) target.border_left_color = value else target.border_right_color = value;
    }
}

fn isInheritedProperty(name: []const u8) bool {
    return eqlProp(name, "color") or eqlProp(name, "font-family") or eqlProp(name, "font-size") or
        eqlProp(name, "font-style") or eqlProp(name, "font-weight") or eqlProp(name, "line-height") or eqlProp(name, "direction") or
        eqlProp(name, "letter-spacing") or eqlProp(name, "word-spacing") or eqlProp(name, "text-align") or
        eqlProp(name, "text-indent") or eqlProp(name, "text-transform") or eqlProp(name, "word-break") or
        eqlProp(name, "overflow-wrap") or eqlProp(name, "text-decoration") or
        eqlProp(name, "text-decoration-line") or eqlProp(name, "text-decoration-style") or
        eqlProp(name, "text-decoration-color") or eqlProp(name, "text-decoration-thickness") or
        eqlProp(name, "white-space") or eqlProp(name, "caption-side") or eqlProp(name, "list-style-type") or
        eqlProp(name, "list-style-position") or eqlProp(name, "orphans") or
        eqlProp(name, "widows");
}

fn copyProperty(target: *box.Style, source: *const box.Style, name: []const u8) void {
    if (eqlProp(name, "top")) {
        target.insets.top = source.insets.top;
        return;
    }
    if (eqlProp(name, "right")) {
        target.insets.right = source.insets.right;
        return;
    }
    if (eqlProp(name, "bottom")) {
        target.insets.bottom = source.insets.bottom;
        return;
    }
    if (eqlProp(name, "left")) {
        target.insets.left = source.insets.left;
        return;
    }
    if (eqlProp(name, "z-index")) {
        target.z_index = source.z_index;
        return;
    }
    if (eqlProp(name, "opacity")) {
        target.opacity = source.opacity;
        return;
    }
    if (eqlProp(name, "flex-direction")) {
        target.flex_direction = source.flex_direction;
        return;
    }
    if (eqlProp(name, "flex-wrap")) {
        target.flex_wrap = source.flex_wrap;
        return;
    }
    if (eqlProp(name, "flex-grow")) {
        target.flex_grow = source.flex_grow;
        return;
    }
    if (eqlProp(name, "flex-shrink")) {
        target.flex_shrink = source.flex_shrink;
        return;
    }
    if (eqlProp(name, "flex-basis")) {
        target.flex_basis = source.flex_basis;
        return;
    }
    if (eqlProp(name, "order")) {
        target.order = source.order;
        return;
    }
    if (eqlProp(name, "row-gap")) {
        target.row_gap = source.row_gap;
        return;
    }
    if (eqlProp(name, "column-gap")) {
        target.column_gap = source.column_gap;
        return;
    }
    if (eqlProp(name, "gap")) {
        target.row_gap = source.row_gap;
        target.column_gap = source.column_gap;
        return;
    }
    if (eqlProp(name, "justify-content")) {
        target.justify_content = source.justify_content;
        return;
    }
    if (eqlProp(name, "align-items")) {
        target.align_items = source.align_items;
        return;
    }
    if (eqlProp(name, "align-self")) {
        target.align_self = source.align_self;
        return;
    }
    if (eqlProp(name, "align-content")) {
        target.align_content = source.align_content;
        return;
    }
    if (eqlProp(name, "box-decoration-break")) {
        target.box_decoration_break = source.box_decoration_break;
        return;
    }
    if (eqlProp(name, "clear")) {
        target.clear_direction = source.clear_direction;
        return;
    }
    if (eqlProp(name, "list-style-type")) {
        target.list_style_type = source.list_style_type;
        return;
    }
    if (eqlProp(name, "list-style-position")) {
        target.list_style_position = source.list_style_position;
        return;
    }
    if (eqlProp(name, "caption-side")) {
        target.caption_side = source.caption_side;
        return;
    }
    if (eqlProp(name, "display")) target.display = source.display else if (eqlProp(name, "direction")) target.direction = source.direction else if (eqlProp(name, "position")) target.position = source.position else if (eqlProp(name, "float")) target.float_direction = source.float_direction else if (eqlProp(name, "white-space")) target.white_space = source.white_space else if (eqlProp(name, "font-size")) target.font_size = source.font_size else if (eqlProp(name, "font-family")) target.font_family = source.font_family else if (eqlProp(name, "font-weight")) target.font_weight = source.font_weight else if (eqlProp(name, "font-style")) target.font_style = source.font_style else if (eqlProp(name, "color")) target.color = source.color else if (eqlProp(name, "background") or eqlProp(name, "background-color")) target.background = source.background else if (eqlProp(name, "width")) target.width = source.width else if (eqlProp(name, "height")) target.height = source.height else if (eqlProp(name, "aspect-ratio")) target.aspect_ratio = source.aspect_ratio else if (eqlProp(name, "min-width")) target.min_width = source.min_width else if (eqlProp(name, "max-width")) target.max_width = source.max_width else if (eqlProp(name, "min-height")) target.min_height = source.min_height else if (eqlProp(name, "max-height")) target.max_height = source.max_height else if (eqlProp(name, "line-height")) target.line_height = source.line_height else if (eqlProp(name, "letter-spacing")) target.letter_spacing = source.letter_spacing else if (eqlProp(name, "word-spacing")) target.word_spacing = source.word_spacing else if (eqlProp(name, "text-indent")) target.text_indent = source.text_indent else if (eqlProp(name, "text-align")) target.text_align = source.text_align else if (eqlProp(name, "text-transform")) target.text_transform = source.text_transform else if (eqlProp(name, "word-break")) target.word_break = source.word_break else if (eqlProp(name, "overflow-wrap")) target.overflow_wrap = source.overflow_wrap else if (eqlProp(name, "overflow")) target.overflow = source.overflow else if (eqlProp(name, "text-overflow")) target.text_overflow = source.text_overflow else if (eqlProp(name, "object-fit")) target.object_fit = source.object_fit else if (eqlProp(name, "object-position")) target.object_position = source.object_position else if (eqlProp(name, "vertical-align")) target.vertical_align = source.vertical_align else if (eqlProp(name, "text-decoration") or eqlProp(name, "text-decoration-line")) target.text_decoration = source.text_decoration else if (eqlProp(name, "text-decoration-style")) target.text_decoration_style = source.text_decoration_style else if (eqlProp(name, "text-decoration-color")) target.text_decoration_color = source.text_decoration_color else if (eqlProp(name, "text-decoration-thickness")) target.text_decoration_thickness = source.text_decoration_thickness else if (eqlProp(name, "box-sizing")) target.box_sizing = source.box_sizing else if (eqlProp(name, "border-collapse")) target.border_collapse = source.border_collapse else if (eqlProp(name, "border-radius")) target.border_radius = source.border_radius else if (eqlProp(name, "page-break-before") or eqlProp(name, "break-before")) target.page_break_before = source.page_break_before else if (eqlProp(name, "page-break-after") or eqlProp(name, "break-after")) target.page_break_after = source.page_break_after else if (eqlProp(name, "page-break-inside") or eqlProp(name, "break-inside")) target.page_break_inside = source.page_break_inside else if (eqlProp(name, "orphans")) target.orphans = source.orphans else if (eqlProp(name, "widows")) target.widows = source.widows else if (eqlProp(name, "margin")) {
        target.margin = source.margin;
        target.margin_auto = source.margin_auto;
    } else if (eqlProp(name, "margin-top")) {
        target.margin.top = source.margin.top;
        target.margin_auto.top = source.margin_auto.top;
    } else if (eqlProp(name, "margin-right")) {
        target.margin.right = source.margin.right;
        target.margin_auto.right = source.margin_auto.right;
    } else if (eqlProp(name, "margin-bottom")) {
        target.margin.bottom = source.margin.bottom;
        target.margin_auto.bottom = source.margin_auto.bottom;
    } else if (eqlProp(name, "margin-left")) {
        target.margin.left = source.margin.left;
        target.margin_auto.left = source.margin_auto.left;
    } else if (eqlProp(name, "padding")) target.padding = source.padding else if (eqlProp(name, "padding-top")) target.padding.top = source.padding.top else if (eqlProp(name, "padding-right")) target.padding.right = source.padding.right else if (eqlProp(name, "padding-bottom")) target.padding.bottom = source.padding.bottom else if (eqlProp(name, "padding-left")) target.padding.left = source.padding.left else if (eqlProp(name, "border")) {
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
