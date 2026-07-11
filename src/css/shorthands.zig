//! Expansion of supported CSS shorthands before computed-value application.

const std = @import("std");
const syntax = @import("syntax.zig");
const values = @import("values.zig");

const Declaration = syntax.Declaration;

pub const Expansion = struct {
    declarations: []const Declaration,
    owns_names: bool,

    pub fn deinit(self: Expansion, allocator: std.mem.Allocator) void {
        if (self.owns_names) for (self.declarations) |declaration| allocator.free(declaration.name);
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
    if (values.eqlProp(name, "border-width")) return try expandQuad(allocator, "border-width", value, important);
    if (values.eqlProp(name, "border-style")) return try expandQuad(allocator, "border-style", value, important);
    if (values.eqlProp(name, "border-color")) return try expandQuad(allocator, "border-color", value, important);
    if (values.eqlProp(name, "border")) return try expandBorder(allocator, null, value, important);
    if (values.eqlProp(name, "border-top")) return try expandBorder(allocator, "top", value, important);
    if (values.eqlProp(name, "border-right")) return try expandBorder(allocator, "right", value, important);
    if (values.eqlProp(name, "border-bottom")) return try expandBorder(allocator, "bottom", value, important);
    if (values.eqlProp(name, "border-left")) return try expandBorder(allocator, "left", value, important);
    if (values.eqlProp(name, "background")) return try single(allocator, "background-color", value, important);
    if (values.eqlProp(name, "text-decoration")) return try single(allocator, "text-decoration-line", value, important);
    return null;
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
    const components = splitComponents(value);
    var width: []const u8 = "medium";
    var style: []const u8 = "none";
    var color: []const u8 = "currentColor";
    for (components.slice()) |component| {
        if (values.parseBorderStyle(component) != null) {
            style = component;
        } else if (isBorderWidth(component)) {
            width = component;
        } else {
            color = component;
        }
    }

    const sides = [_][]const u8{ "top", "right", "bottom", "left" };
    const count: usize = if (side == null) 12 else 3;
    const declarations = try allocator.alloc(Declaration, count);
    var index: usize = 0;
    for (&sides) |candidate| {
        if (side) |selected| if (!std.mem.eql(u8, selected, candidate)) continue;
        declarations[index] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-width", .{candidate}), .value = width, .important = important };
        declarations[index + 1] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-style", .{candidate}), .value = style, .important = important };
        declarations[index + 2] = .{ .name = try std.fmt.allocPrint(allocator, "border-{s}-color", .{candidate}), .value = color, .important = important };
        index += 3;
    }
    return .{ .declarations = declarations, .owns_names = true };
}

fn isBorderWidth(value: []const u8) bool {
    return values.eqlProp(value, "thin") or values.eqlProp(value, "medium") or values.eqlProp(value, "thick") or
        values.parseLength(value) != null;
}

const Components = struct {
    items: [4][]const u8 = @splat(""),
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
