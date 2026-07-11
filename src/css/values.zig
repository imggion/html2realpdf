//! Typed parsing helpers for CSS values accepted by the document profile.
//!
//! Absolute units are normalized to CSS pixels here. Context-dependent values
//! stay represented by box.Length until layout resolves the containing size.

const std = @import("std");
const box = @import("../box.zig");
const expressions = @import("expressions.zig");
const syntax = @import("syntax.zig");

pub fn eqlProp(a: []const u8, b: []const u8) bool {
    return syntax.identifierEquals(a, b, true);
}

pub fn parseDisplay(value: []const u8) ?box.Display {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "none")) return .none;
    if (eqlProp(v, "block")) return .block;
    if (eqlProp(v, "inline")) return .inlineBox;
    if (eqlProp(v, "inline-block")) return .inlineBlock;
    if (eqlProp(v, "table")) return .table;
    if (eqlProp(v, "table-row")) return .tableRow;
    if (eqlProp(v, "table-cell")) return .tableCell;
    if (eqlProp(v, "table-row-group") or eqlProp(v, "table-header-group") or eqlProp(v, "table-footer-group")) return .tableRowGroup;
    return null;
}

pub fn parsePosition(value: []const u8) ?box.Position {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "static")) return .static;
    if (eqlProp(v, "relative")) return .relative;
    if (eqlProp(v, "absolute")) return .absolute;
    if (eqlProp(v, "fixed")) return .fixed;
    return null;
}

pub fn parseFloatValue(value: []const u8) ?box.Float {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "none")) return .none;
    if (eqlProp(v, "left")) return .left;
    if (eqlProp(v, "right")) return .right;
    return null;
}

pub fn parseWhiteSpace(value: []const u8) ?box.WhiteSpace {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "normal")) return .normal;
    if (eqlProp(v, "nowrap")) return .nowrap;
    if (eqlProp(v, "pre")) return .pre;
    if (eqlProp(v, "pre-wrap")) return .preWrap;
    if (eqlProp(v, "pre-line")) return .preLine;
    return null;
}

pub fn parseFontWeight(value: []const u8) ?box.FontWeight {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "normal") or eqlProp(v, "400")) return .normal;
    if (eqlProp(v, "bold") or eqlProp(v, "bolder")) return .bold;
    const numeric = std.fmt.parseInt(u16, v, 10) catch return null;
    return if (numeric >= 600) .bold else .normal;
}

pub fn parseFontStyle(value: []const u8) ?box.FontStyle {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "normal")) return .normal;
    if (eqlProp(v, "italic") or eqlProp(v, "oblique")) return .italic;
    return null;
}

pub fn parseLength(value: []const u8) ?f32 {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (v.len == 0) return null;

    var end: usize = 0;
    while (end < v.len) : (end += 1) {
        const c = v[end];
        if (!((c >= '0' and c <= '9') or c == '.' or c == '-')) break;
    }

    const num_str = v[0..end];
    if (num_str.len == 0) return null;

    const num = std.fmt.parseFloat(f32, num_str) catch return null;

    if (end < v.len and v[end] != ' ') {
        const unit = std.mem.trim(u8, v[end..], " \t\n\r\x0C");
        if (eqlProp(unit, "px") or unit.len == 0) return num;
        if (eqlProp(unit, "pt")) return num / 0.75;
        if (eqlProp(unit, "in")) return num * 96;
        if (eqlProp(unit, "cm")) return num * 96 / 2.54;
        if (eqlProp(unit, "mm")) return num * 96 / 25.4;
        return null;
    }

    return num;
}

pub fn parseDimension(value: []const u8, font_size: f32) ?box.Length {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "auto")) return .auto;
    if (v.len == 0) return null;

    var end: usize = 0;
    while (end < v.len) : (end += 1) {
        const c = v[end];
        if (!((c >= '0' and c <= '9') or c == '.' or c == '-')) break;
    }
    if (end == 0) return null;
    const number = std.fmt.parseFloat(f32, v[0..end]) catch return null;
    const unit = std.mem.trim(u8, v[end..], " \t\n\r\x0C");

    if (unit.len == 0 or eqlProp(unit, "px")) return .{ .px = number };
    if (eqlProp(unit, "%")) return .{ .percent = number / 100 };
    if (eqlProp(unit, "em")) return .{ .px = number * font_size };
    if (eqlProp(unit, "rem")) return .{ .px = number * 16 };
    if (eqlProp(unit, "pt")) return .{ .px = number / 0.75 };
    if (eqlProp(unit, "in")) return .{ .px = number * 96 };
    if (eqlProp(unit, "cm")) return .{ .px = number * 96 / 2.54 };
    if (eqlProp(unit, "mm")) return .{ .px = number * 96 / 25.4 };
    return null;
}

pub fn parseDimensionWithContext(
    allocator: std.mem.Allocator,
    store: *expressions.Store,
    value: []const u8,
    context: expressions.Context,
) !?box.Length {
    if (parseDimension(value, context.font_size)) |simple| return simple;
    const reference = try expressions.parse(allocator, store, value, context) orelse return null;
    return .{ .expression = reference };
}

pub fn parseLineHeight(value: []const u8, font_size: f32) ?f32 {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "normal")) return font_size * 1.2;
    if (std.mem.indexOfAny(u8, v, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ%") == null) {
        const multiplier = std.fmt.parseFloat(f32, v) catch return null;
        return multiplier * font_size;
    }
    const dimension = parseDimension(v, font_size) orelse return null;
    return dimension.resolve(font_size);
}

pub fn parseFirstLength(value: []const u8) f32 {
    var iter = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");
    while (iter.next()) |token| {
        if (parseLength(token)) |len| return len;
    }
    return 0;
}

pub fn parseEdges(value: []const u8) box.EdgeSizes {
    var parts: [4]?f32 = .{ null, null, null, null };
    var i: usize = 0;
    var iter = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");

    while (iter.next()) |token| : (i += 1) {
        if (i >= 4) break;
        parts[i] = parseLength(token);
    }

    return switch (i) {
        0 => .{},
        1 => .{ .top = parts[0] orelse 0, .right = parts[0] orelse 0, .bottom = parts[0] orelse 0, .left = parts[0] orelse 0 },
        2 => .{ .top = parts[0] orelse 0, .right = parts[1] orelse 0, .bottom = parts[0] orelse 0, .left = parts[1] orelse 0 },
        3 => .{ .top = parts[0] orelse 0, .right = parts[1] orelse 0, .bottom = parts[2] orelse 0, .left = parts[1] orelse 0 },
        else => .{ .top = parts[0] orelse 0, .right = parts[1] orelse 0, .bottom = parts[2] orelse 0, .left = parts[3] orelse 0 },
    };
}

pub fn parseTextAlign(value: []const u8) ?box.TextAlign {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "start")) return .start;
    if (eqlProp(v, "end")) return .end;
    if (eqlProp(v, "left")) return .left;
    if (eqlProp(v, "center")) return .center;
    if (eqlProp(v, "right")) return .right;
    if (eqlProp(v, "justify")) return .justify;
    return null;
}

pub fn parseDirection(value: []const u8) ?box.Direction {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "ltr")) return .ltr;
    if (eqlProp(v, "rtl")) return .rtl;
    return null;
}

pub fn parseTextTransform(value: []const u8) ?box.TextTransform {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "none")) return .none;
    if (eqlProp(v, "uppercase")) return .uppercase;
    if (eqlProp(v, "lowercase")) return .lowercase;
    if (eqlProp(v, "capitalize")) return .capitalize;
    return null;
}

pub fn parseWordBreak(value: []const u8) ?box.WordBreak {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "normal")) return .normal;
    if (eqlProp(v, "break-all")) return .breakAll;
    if (eqlProp(v, "keep-all")) return .keepAll;
    return null;
}

pub fn parseOverflowWrap(value: []const u8) ?box.OverflowWrap {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "normal")) return .normal;
    if (eqlProp(v, "break-word")) return .breakWord;
    if (eqlProp(v, "anywhere")) return .anywhere;
    return null;
}

pub fn parseOverflow(value: []const u8) ?box.Overflow {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "visible")) return .visible;
    if (eqlProp(v, "hidden")) return .hidden;
    if (eqlProp(v, "clip")) return .clip;
    if (eqlProp(v, "auto")) return .auto;
    if (eqlProp(v, "scroll")) return .scroll;
    return null;
}

pub fn parseTextOverflow(value: []const u8) ?box.TextOverflow {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "clip")) return .clip;
    if (eqlProp(v, "ellipsis")) return .ellipsis;
    return null;
}

pub fn parseAspectRatio(value: []const u8) ?box.AspectRatio {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "auto")) return .{};
    var use_intrinsic = false;
    var ratio_text = v;
    if (v.len >= 4 and std.ascii.eqlIgnoreCase(v[0..4], "auto")) {
        if (v.len == 4 or !std.ascii.isWhitespace(v[4])) return null;
        use_intrinsic = true;
        ratio_text = std.mem.trim(u8, v[4..], " \t\n\r\x0C");
    }
    var parts = std.mem.splitScalar(u8, ratio_text, '/');
    const numerator_text = std.mem.trim(u8, parts.next() orelse return null, " \t\n\r\x0C");
    const denominator_text = std.mem.trim(u8, parts.next() orelse "1", " \t\n\r\x0C");
    if (parts.next() != null) return null;
    const numerator = std.fmt.parseFloat(f32, numerator_text) catch return null;
    const denominator = std.fmt.parseFloat(f32, denominator_text) catch return null;
    if (numerator <= 0 or denominator <= 0) return null;
    return .{ .ratio = numerator / denominator, .use_intrinsic = use_intrinsic };
}

pub fn parseObjectFit(value: []const u8) ?box.ObjectFit {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "fill")) return .fill;
    if (eqlProp(v, "contain")) return .contain;
    if (eqlProp(v, "cover")) return .cover;
    if (eqlProp(v, "none")) return .none;
    if (eqlProp(v, "scale-down")) return .scaleDown;
    return null;
}

pub fn parseObjectPosition(value: []const u8) ?box.ObjectPosition {
    var tokens = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");
    const first = tokens.next() orelse return null;
    const second = tokens.next();
    if (tokens.next() != null) return null;

    if (second) |vertical_or_horizontal| {
        if (isVerticalPosition(first) and isHorizontalPosition(vertical_or_horizontal)) {
            return .{ .x = parsePositionComponent(vertical_or_horizontal, true) orelse return null, .y = parsePositionComponent(first, false) orelse return null };
        }
        return .{
            .x = parsePositionComponent(first, true) orelse return null,
            .y = parsePositionComponent(vertical_or_horizontal, false) orelse return null,
        };
    }
    if (isVerticalPosition(first)) return .{ .y = parsePositionComponent(first, false) orelse return null };
    return .{ .x = parsePositionComponent(first, true) orelse return null };
}

fn parsePositionComponent(value: []const u8, horizontal: bool) ?box.Length {
    if (eqlProp(value, "center")) return .{ .percent = 0.5 };
    if (horizontal and eqlProp(value, "left")) return .{ .percent = 0 };
    if (horizontal and eqlProp(value, "right")) return .{ .percent = 1 };
    if (!horizontal and eqlProp(value, "top")) return .{ .percent = 0 };
    if (!horizontal and eqlProp(value, "bottom")) return .{ .percent = 1 };
    return parseDimension(value, 16);
}

fn isHorizontalPosition(value: []const u8) bool {
    return eqlProp(value, "left") or eqlProp(value, "right") or eqlProp(value, "center");
}

fn isVerticalPosition(value: []const u8) bool {
    return eqlProp(value, "top") or eqlProp(value, "bottom") or eqlProp(value, "center");
}

pub fn parseVerticalAlignKeyword(value: []const u8) ?box.VerticalAlign {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "baseline")) return .baseline;
    if (eqlProp(v, "sub")) return .sub;
    if (eqlProp(v, "super")) return .super;
    if (eqlProp(v, "text-top")) return .textTop;
    if (eqlProp(v, "text-bottom")) return .textBottom;
    if (eqlProp(v, "middle")) return .middle;
    if (eqlProp(v, "top")) return .top;
    if (eqlProp(v, "bottom")) return .bottom;
    return null;
}

pub fn parseTextDecoration(value: []const u8) ?box.TextDecoration {
    var tokens = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");
    var underline = false;
    var overline = false;
    var line_through = false;
    var recognized = false;
    while (tokens.next()) |token| {
        if (eqlProp(token, "underline")) {
            underline = true;
            recognized = true;
        } else if (eqlProp(token, "overline")) {
            overline = true;
            recognized = true;
        } else if (eqlProp(token, "line-through")) {
            line_through = true;
            recognized = true;
        }
        if (eqlProp(token, "none")) return .none;
    }
    if (!recognized) return null;
    if (underline and overline and line_through) return .all;
    if (underline and overline) return .underlineOverline;
    if (underline and line_through) return .underlineLineThrough;
    if (overline and line_through) return .overlineLineThrough;
    if (underline) return .underline;
    if (overline) return .overline;
    return .lineThrough;
}

pub fn parseTextDecorationStyle(value: []const u8) ?box.TextDecorationStyle {
    var tokens = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");
    while (tokens.next()) |token| {
        if (eqlProp(token, "solid")) return .solid;
        if (eqlProp(token, "double")) return .double;
        if (eqlProp(token, "dotted")) return .dotted;
        if (eqlProp(token, "dashed")) return .dashed;
        if (eqlProp(token, "wavy")) return .wavy;
    }
    return null;
}

pub fn parseBoxSizing(value: []const u8) ?box.BoxSizing {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "content-box")) return .contentBox;
    if (eqlProp(v, "border-box")) return .borderBox;
    return null;
}

pub fn parseBorderCollapse(value: []const u8) ?box.BorderCollapse {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "separate")) return .separate;
    if (eqlProp(v, "collapse")) return .collapse;
    return null;
}

pub fn parsePageBreak(value: []const u8) ?box.PageBreak {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "auto")) return .auto;
    if (eqlProp(v, "always")) return .always;
    if (eqlProp(v, "page") or eqlProp(v, "left") or eqlProp(v, "right")) return .always;
    if (eqlProp(v, "avoid")) return .avoid;
    if (eqlProp(v, "avoid-page")) return .avoid;
    return null;
}

pub fn parseBorderStyle(value: []const u8) ?box.BorderStyle {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "none")) return .none;
    if (eqlProp(v, "solid")) return .solid;
    if (eqlProp(v, "dashed")) return .dashed;
    if (eqlProp(v, "dotted")) return .dotted;
    return null;
}

pub fn parseBorderWidth(value: []const u8) ?f32 {
    if (eqlProp(value, "thin")) return 1;
    if (eqlProp(value, "medium")) return 3;
    if (eqlProp(value, "thick")) return 5;
    return parseLength(value);
}

pub fn parsePositiveInteger(value: []const u8) ?u32 {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    const n = std.fmt.parseInt(u32, v, 10) catch return null;
    if (n == 0) return null;
    return n;
}
