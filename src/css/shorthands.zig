//! Expansion of supported CSS shorthands before computed-value application.

const std = @import("std");
const syntax = @import("syntax.zig");
const values = @import("values.zig");

const Declaration = syntax.Declaration;

pub const Expansion = struct {
    declarations: []const Declaration,
    owns_names: bool,
    owns_values: bool = false,

    pub fn deinit(self: Expansion, allocator: std.mem.Allocator) void {
        if (self.owns_names) for (self.declarations) |declaration| allocator.free(declaration.name);
        if (self.owns_values) for (self.declarations) |declaration| allocator.free(declaration.value);
        allocator.free(self.declarations);
    }
};

pub fn expand(
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    important: bool,
) !?Expansion {
    if (values.eqlProp(name, "margin")) return try expandQuad(allocator, "margin", value, important);
    if (values.eqlProp(name, "padding")) return try expandQuad(allocator, "padding", value, important);
    if (values.eqlProp(name, "margin-block")) return try expandLogicalPair(allocator, "margin-block", null, value, important);
    if (values.eqlProp(name, "margin-inline")) return try expandLogicalPair(allocator, "margin-inline", null, value, important);
    if (values.eqlProp(name, "padding-block")) return try expandLogicalPair(allocator, "padding-block", null, value, important);
    if (values.eqlProp(name, "padding-inline")) return try expandLogicalPair(allocator, "padding-inline", null, value, important);
    if (values.eqlProp(name, "border-width")) return try expandQuad(allocator, "border-width", value, important);
    if (values.eqlProp(name, "border-style")) return try expandQuad(allocator, "border-style", value, important);
    if (values.eqlProp(name, "border-color")) return try expandQuad(allocator, "border-color", value, important);
    if (values.eqlProp(name, "border-block-width")) return try expandLogicalPair(allocator, "border-block", "width", value, important);
    if (values.eqlProp(name, "border-inline-width")) return try expandLogicalPair(allocator, "border-inline", "width", value, important);
    if (values.eqlProp(name, "border-block-style")) return try expandLogicalPair(allocator, "border-block", "style", value, important);
    if (values.eqlProp(name, "border-inline-style")) return try expandLogicalPair(allocator, "border-inline", "style", value, important);
    if (values.eqlProp(name, "border-block-color")) return try expandLogicalPair(allocator, "border-block", "color", value, important);
    if (values.eqlProp(name, "border-inline-color")) return try expandLogicalPair(allocator, "border-inline", "color", value, important);
    if (values.eqlProp(name, "border")) return try expandBorder(allocator, null, value, important);
    if (values.eqlProp(name, "border-top")) return try expandBorder(allocator, "top", value, important);
    if (values.eqlProp(name, "border-right")) return try expandBorder(allocator, "right", value, important);
    if (values.eqlProp(name, "border-bottom")) return try expandBorder(allocator, "bottom", value, important);
    if (values.eqlProp(name, "border-left")) return try expandBorder(allocator, "left", value, important);
    if (values.eqlProp(name, "border-block-start")) return try expandLogicalBorder(allocator, "block-start", false, value, important);
    if (values.eqlProp(name, "border-block-end")) return try expandLogicalBorder(allocator, "block-end", false, value, important);
    if (values.eqlProp(name, "border-inline-start")) return try expandLogicalBorder(allocator, "inline-start", false, value, important);
    if (values.eqlProp(name, "border-inline-end")) return try expandLogicalBorder(allocator, "inline-end", false, value, important);
    if (values.eqlProp(name, "border-block")) return try expandLogicalBorder(allocator, "block", true, value, important);
    if (values.eqlProp(name, "border-inline")) return try expandLogicalBorder(allocator, "inline", true, value, important);
    if (values.eqlProp(name, "background")) return try single(allocator, "background-color", value, important);
    if (values.eqlProp(name, "text-decoration")) return try expandTextDecoration(allocator, value, important);
    return null;
}

fn expandLogicalPair(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    suffix: ?[]const u8,
    value: []const u8,
    important: bool,
) !Expansion {
    const components = splitComponents(value);
    if (components.len == 0 or components.len > 2) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = true };
    const resolved = [2][]const u8{ components.items[0], if (components.len == 1) components.items[0] else components.items[1] };
    const sides = [_][]const u8{ "start", "end" };
    const declarations = try allocator.alloc(Declaration, 2);
    for (sides, resolved, 0..) |side, component, index| {
        const name = if (suffix) |component_name|
            try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ prefix, side, component_name })
        else
            try std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, side });
        declarations[index] = .{ .name = name, .value = component, .important = important };
    }
    return .{ .declarations = declarations, .owns_names = true };
}

fn expandTextDecoration(
    allocator: std.mem.Allocator,
    value: []const u8,
    important: bool,
) !Expansion {
    const components = splitComponents(value);
    var line: []const u8 = "none";
    var decoration_style: []const u8 = "solid";
    var color: []const u8 = "currentColor";
    var thickness: []const u8 = "auto";
    var underline = false;
    var overline = false;
    var line_through = false;

    if (components.len == 1 and isCssWideKeyword(components.items[0])) {
        line = components.items[0];
        decoration_style = components.items[0];
        color = components.items[0];
        thickness = components.items[0];
    } else {
        for (components.slice()) |component| {
            if (values.eqlProp(component, "underline")) {
                underline = true;
            } else if (values.eqlProp(component, "overline")) {
                overline = true;
            } else if (values.eqlProp(component, "line-through")) {
                line_through = true;
            } else if (values.eqlProp(component, "none")) {
                line = "none";
            } else if (values.parseTextDecorationStyle(component) != null) {
                decoration_style = component;
            } else if (isTextDecorationThickness(component)) {
                thickness = component;
            } else {
                color = component;
            }
        }
    }

    if (underline or overline or line_through) {
        line = if (underline and overline and line_through)
            "underline overline line-through"
        else if (underline and overline)
            "underline overline"
        else if (underline and line_through)
            "underline line-through"
        else if (overline and line_through)
            "overline line-through"
        else if (underline)
            "underline"
        else if (overline)
            "overline"
        else
            "line-through";
    }

    const names = [_][]const u8{
        "text-decoration-line",
        "text-decoration-style",
        "text-decoration-color",
        "text-decoration-thickness",
    };
    const resolved_values = [_][]const u8{ line, decoration_style, color, thickness };
    const declarations = try allocator.alloc(Declaration, names.len);
    for (names, resolved_values, 0..) |declaration_name, resolved_value, index| {
        declarations[index] = .{
            .name = declaration_name,
            .value = resolved_value,
            .important = important,
        };
    }
    return .{ .declarations = declarations, .owns_names = false };
}

fn isCssWideKeyword(value: []const u8) bool {
    return values.eqlProp(value, "initial") or values.eqlProp(value, "inherit") or
        values.eqlProp(value, "unset") or values.eqlProp(value, "revert");
}

fn isTextDecorationThickness(value: []const u8) bool {
    if (values.eqlProp(value, "auto") or values.eqlProp(value, "from-font")) return true;
    if (values.parseDimension(value, 16) != null) return true;
    return startsWithIgnoreCase(value, "calc(") or startsWithIgnoreCase(value, "min(") or
        startsWithIgnoreCase(value, "max(") or startsWithIgnoreCase(value, "clamp(");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn single(allocator: std.mem.Allocator, name: []const u8, value: []const u8, important: bool) !Expansion {
    const declarations = try allocator.alloc(Declaration, 1);
    declarations[0] = .{ .name = name, .value = value, .important = important };
    return .{ .declarations = declarations, .owns_names = false };
}

fn expandQuad(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    value: []const u8,
    important: bool,
) !Expansion {
    const components = splitComponents(value);
    if (components.len == 0 or components.len > 4) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = true };
    const expanded = switch (components.len) {
        1 => [4][]const u8{ components.items[0], components.items[0], components.items[0], components.items[0] },
        2 => [4][]const u8{ components.items[0], components.items[1], components.items[0], components.items[1] },
        3 => [4][]const u8{ components.items[0], components.items[1], components.items[2], components.items[1] },
        4 => [4][]const u8{ components.items[0], components.items[1], components.items[2], components.items[3] },
        else => unreachable,
    };
    const suffixes = [_][]const u8{ "top", "right", "bottom", "left" };
    const declarations = try allocator.alloc(Declaration, 4);
    for (&suffixes, expanded, 0..) |suffix, component, index| {
        const name = if (std.mem.startsWith(u8, prefix, "border-"))
            try std.fmt.allocPrint(allocator, "border-{s}-{s}", .{ suffix, prefix["border-".len..] })
        else
            try std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, suffix });
        declarations[index] = .{
            .name = name,
            .value = component,
            .important = important,
        };
    }
    return .{ .declarations = declarations, .owns_names = true };
}

fn expandBorder(
    allocator: std.mem.Allocator,
    side: ?[]const u8,
    value: []const u8,
    important: bool,
) !Expansion {
    const components = borderComponents(value);

    const sides = [_][]const u8{ "top", "right", "bottom", "left" };
    const count: usize = if (side == null) 12 else 3;
    const declarations = try allocator.alloc(Declaration, count);
    var index: usize = 0;
    for (&sides) |candidate| {
        if (side) |selected| if (!std.mem.eql(u8, selected, candidate)) continue;
        declarations[index] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-width", .{candidate}), .value = components.width, .important = important };
        declarations[index + 1] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-style", .{candidate}), .value = components.style, .important = important };
        declarations[index + 2] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-color", .{candidate}), .value = components.color, .important = important };
        index += 3;
    }
    return .{ .declarations = declarations, .owns_names = true };
}

const BorderComponents = struct {
    width: []const u8 = "medium",
    style: []const u8 = "none",
    color: []const u8 = "currentColor",
};

fn borderComponents(value: []const u8) BorderComponents {
    const tokens = splitComponents(value);
    var result = BorderComponents{};
    for (tokens.slice()) |component| {
        if (values.parseBorderStyle(component) != null) {
            result.style = component;
        } else if (isBorderWidth(component)) {
            result.width = component;
        } else {
            result.color = component;
        }
    }
    return result;
}

fn expandLogicalBorder(
    allocator: std.mem.Allocator,
    axis_or_side: []const u8,
    both_sides: bool,
    value: []const u8,
    important: bool,
) !Expansion {
    const components = borderComponents(value);
    const count: usize = if (both_sides) 6 else 3;
    const declarations = try allocator.alloc(Declaration, count);
    const sides = [_][]const u8{ "start", "end" };
    var index: usize = 0;
    for (sides) |side| {
        if (!both_sides and index > 0) break;
        const owned_logical_side = if (both_sides) try std.fmt.allocPrint(allocator, "{s}-{s}", .{ axis_or_side, side }) else null;
        defer if (owned_logical_side) |owned| allocator.free(owned);
        const logical_side = owned_logical_side orelse axis_or_side;
        declarations[index] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-width", .{logical_side}), .value = components.width, .important = important };
        declarations[index + 1] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-style", .{logical_side}), .value = components.style, .important = important };
        declarations[index + 2] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-color", .{logical_side}), .value = components.color, .important = important };
        index += 3;
    }
    return .{ .declarations = declarations, .owns_names = true };
}

fn isBorderWidth(value: []const u8) bool {
    return values.eqlProp(value, "thin") or values.eqlProp(value, "medium") or values.eqlProp(value, "thick") or
        values.parseLength(value) != null;
}

const Components = struct {
    items: [8][]const u8 = @splat(""),
    len: usize = 0,

    fn slice(self: *const Components) []const []const u8 {
        return self.items[0..self.len];
    }
};

fn splitComponents(value: []const u8) Components {
    var result = Components{};
    var index: usize = 0;
    while (index < value.len) {
        while (index < value.len and cssWhitespace(value[index])) index += 1;
        if (index >= value.len or result.len == result.items.len) break;
        const start = index;
        var depth: usize = 0;
        var quote: ?u8 = null;
        while (index < value.len) : (index += 1) {
            const byte = value[index];
            if (quote) |active| {
                if (byte == '\\' and index + 1 < value.len) index += 1 else if (byte == active) quote = null;
                continue;
            }
            if (byte == '"' or byte == '\'') quote = byte else if (byte == '(' or byte == '[' or byte == '{') depth += 1 else if (byte == ')' or byte == ']' or byte == '}') depth -|= 1 else if (depth == 0 and cssWhitespace(byte)) break;
        }
        result.items[result.len] = value[start..index];
        result.len += 1;
    }
    return result;
}

fn cssWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0C;
}

test "expand quad shorthand while preserving nested math" {
    const allocator = std.testing.allocator;
    const expansion = (try expand(allocator, "margin", "calc(10px + 2px) 4px 8px", false)).?;
    defer expansion.deinit(allocator);
    const declarations = expansion.declarations;
    try std.testing.expectEqual(@as(usize, 4), declarations.len);
    try std.testing.expectEqualStrings("calc(10px + 2px)", declarations[0].value);
    try std.testing.expectEqualStrings("4px", declarations[1].value);
    try std.testing.expectEqualStrings("8px", declarations[2].value);
    try std.testing.expectEqualStrings("4px", declarations[3].value);
}

test "expand border shorthand into physical longhands" {
    const allocator = std.testing.allocator;
    const expansion = (try expand(allocator, "border-top", "2px dashed rebeccapurple", true)).?;
    defer expansion.deinit(allocator);
    const declarations = expansion.declarations;
    try std.testing.expectEqual(@as(usize, 3), declarations.len);
    try std.testing.expectEqualStrings("border-top-width", declarations[0].name);
    try std.testing.expectEqualStrings("2px", declarations[0].value);
    try std.testing.expectEqualStrings("dashed", declarations[1].value);
    try std.testing.expectEqualStrings("rebeccapurple", declarations[2].value);
    try std.testing.expect(declarations[0].important);
}

test "expand border component quads with canonical longhand names" {
    const allocator = std.testing.allocator;
    const expansion = (try expand(allocator, "border-style", "solid dashed", false)).?;
    defer expansion.deinit(allocator);
    try std.testing.expectEqualStrings("border-top-style", expansion.declarations[0].name);
    try std.testing.expectEqualStrings("border-right-style", expansion.declarations[1].name);
    try std.testing.expectEqualStrings("solid", expansion.declarations[0].value);
    try std.testing.expectEqualStrings("dashed", expansion.declarations[1].value);
}

test "expand logical axis and border shorthands" {
    const allocator = std.testing.allocator;
    const margins = (try expand(allocator, "margin-inline", "4px 12px", false)).?;
    defer margins.deinit(allocator);
    try std.testing.expectEqualStrings("margin-inline-start", margins.declarations[0].name);
    try std.testing.expectEqualStrings("margin-inline-end", margins.declarations[1].name);
    try std.testing.expectEqualStrings("4px", margins.declarations[0].value);
    try std.testing.expectEqualStrings("12px", margins.declarations[1].value);

    const borders = (try expand(allocator, "border-block", "3px dashed rebeccapurple", true)).?;
    defer borders.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 6), borders.declarations.len);
    try std.testing.expectEqualStrings("border-block-start-width", borders.declarations[0].name);
    try std.testing.expectEqualStrings("border-block-end-color", borders.declarations[5].name);
    try std.testing.expectEqualStrings("3px", borders.declarations[0].value);
    try std.testing.expectEqualStrings("dashed", borders.declarations[1].value);
    try std.testing.expectEqualStrings("rebeccapurple", borders.declarations[2].value);
    try std.testing.expect(borders.declarations[5].important);
}

test "expand text-decoration into line style color and thickness" {
    const allocator = std.testing.allocator;
    const expansion = (try expand(allocator, "text-decoration", "underline overline 2px wavy rebeccapurple", true)).?;
    defer expansion.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), expansion.declarations.len);
    try std.testing.expectEqualStrings("underline overline", expansion.declarations[0].value);
    try std.testing.expectEqualStrings("wavy", expansion.declarations[1].value);
    try std.testing.expectEqualStrings("rebeccapurple", expansion.declarations[2].value);
    try std.testing.expectEqualStrings("2px", expansion.declarations[3].value);
    try std.testing.expect(expansion.declarations[0].important);
}
