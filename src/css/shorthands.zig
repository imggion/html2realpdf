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
    if (values.eqlProp(name, "border-radius")) return try expandBorderRadius(allocator, value, important);
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
    if (values.eqlProp(name, "flex")) return try expandFlex(allocator, value, important);
    if (values.eqlProp(name, "flex-flow")) return try expandFlexFlow(allocator, value, important);
    if (values.eqlProp(name, "gap")) return try expandGap(allocator, value, important);
    if (values.eqlProp(name, "inset")) return try expandInset(allocator, value, important);
    if (values.eqlProp(name, "inset-block")) return try expandLogicalPair(allocator, "inset-block", null, value, important);
    if (values.eqlProp(name, "inset-inline")) return try expandLogicalPair(allocator, "inset-inline", null, value, important);
    if (values.eqlProp(name, "grid-column")) return try expandGridAxis(allocator, "column", value, important);
    if (values.eqlProp(name, "grid-row")) return try expandGridAxis(allocator, "row", value, important);
    if (values.eqlProp(name, "grid-area")) return try expandGridArea(allocator, value, important);
    if (values.eqlProp(name, "grid-template") or values.eqlProp(name, "grid")) return try expandGridTemplate(allocator, value, important);
    if (values.eqlProp(name, "list-style")) return try expandListStyle(allocator, value, important);
    if (values.eqlProp(name, "text-decoration")) return try expandTextDecoration(allocator, value, important);
    return null;
}

fn expandBorderRadius(allocator: std.mem.Allocator, value: []const u8, important: bool) !Expansion {
    if (isCssWideKeyword(std.mem.trim(u8, value, " \t\n\r\x0C"))) {
        const declarations = try allocator.alloc(Declaration, 4);
        const names = [_][]const u8{ "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius" };
        for (names, 0..) |name, index| declarations[index] = .{ .name = name, .value = value, .important = important };
        return .{ .declarations = declarations, .owns_names = false };
    }
    const axes = splitSlashComponents(value);
    if (axes.len == 0 or axes.len > 2) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
    const horizontal = splitComponents(axes.items[0]);
    const vertical = if (axes.len == 2) splitComponents(axes.items[1]) else horizontal;
    if (horizontal.len == 0 or horizontal.len > 4 or vertical.len == 0 or vertical.len > 4) {
        return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
    }
    const horizontal_values = expandRadiusQuad(horizontal);
    const vertical_values = expandRadiusQuad(vertical);
    const names = [_][]const u8{ "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius" };
    const declarations = try allocator.alloc(Declaration, 4);
    for (names, 0..) |name, index| declarations[index] = .{
        .name = name,
        .value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ horizontal_values[index], vertical_values[index] }),
        .important = important,
    };
    return .{ .declarations = declarations, .owns_names = false, .owns_values = true };
}

fn expandRadiusQuad(components: Components) [4][]const u8 {
    return switch (components.len) {
        1 => .{ components.items[0], components.items[0], components.items[0], components.items[0] },
        2 => .{ components.items[0], components.items[1], components.items[0], components.items[1] },
        3 => .{ components.items[0], components.items[1], components.items[2], components.items[1] },
        4 => .{ components.items[0], components.items[1], components.items[2], components.items[3] },
        else => unreachable,
    };
}

fn expandGridAxis(allocator: std.mem.Allocator, axis: []const u8, value: []const u8, important: bool) !Expansion {
    const components = splitSlashComponents(value);
    if (components.len == 0 or components.len > 2) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = true };
    const declarations = try allocator.alloc(Declaration, 2);
    declarations[0] = .{
        .name = try std.fmt.allocPrint(allocator, "grid-{s}-start", .{axis}),
        .value = components.items[0],
        .important = important,
    };
    declarations[1] = .{
        .name = try std.fmt.allocPrint(allocator, "grid-{s}-end", .{axis}),
        .value = if (components.len == 2) components.items[1] else "auto",
        .important = important,
    };
    return .{ .declarations = declarations, .owns_names = true };
}

fn expandGridArea(allocator: std.mem.Allocator, value: []const u8, important: bool) !Expansion {
    const components = splitSlashComponents(value);
    if (components.len == 0 or components.len > 4) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
    const single_named = if (components.len == 1)
        if (values.parseGridLine(components.items[0])) |line| switch (line) {
            .named => true,
            else => false,
        } else false
    else
        false;
    const row_start = components.items[0];
    const column_start = if (components.len > 1) components.items[1] else if (single_named) row_start else "auto";
    const row_end = if (components.len > 2) components.items[2] else if (single_named) row_start else "auto";
    const column_end = if (components.len > 3) components.items[3] else if (single_named) row_start else "auto";
    const declarations = try allocator.alloc(Declaration, 4);
    declarations[0] = .{ .name = "grid-row-start", .value = row_start, .important = important };
    declarations[1] = .{ .name = "grid-column-start", .value = column_start, .important = important };
    declarations[2] = .{ .name = "grid-row-end", .value = row_end, .important = important };
    declarations[3] = .{ .name = "grid-column-end", .value = column_end, .important = important };
    return .{ .declarations = declarations, .owns_names = false };
}

fn expandGridTemplate(allocator: std.mem.Allocator, value: []const u8, important: bool) !Expansion {
    const components = splitSlashComponents(value);
    if (components.len != 2) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
    const declarations = try allocator.alloc(Declaration, 2);
    declarations[0] = .{ .name = "grid-template-rows", .value = components.items[0], .important = important };
    declarations[1] = .{ .name = "grid-template-columns", .value = components.items[1], .important = important };
    return .{ .declarations = declarations, .owns_names = false };
}

fn expandInset(allocator: std.mem.Allocator, value: []const u8, important: bool) !Expansion {
    const components = splitComponents(value);
    if (components.len == 0 or components.len > 4) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
    const top = components.items[0];
    const right = if (components.len > 1) components.items[1] else top;
    const bottom = if (components.len > 2) components.items[2] else top;
    const left = if (components.len > 3) components.items[3] else right;
    const declarations = try allocator.alloc(Declaration, 4);
    declarations[0] = .{ .name = "top", .value = top, .important = important };
    declarations[1] = .{ .name = "right", .value = right, .important = important };
    declarations[2] = .{ .name = "bottom", .value = bottom, .important = important };
    declarations[3] = .{ .name = "left", .value = left, .important = important };
    return .{ .declarations = declarations, .owns_names = false };
}

fn expandFlex(allocator: std.mem.Allocator, value: []const u8, important: bool) !Expansion {
    const components = splitComponents(value);
    var grow: []const u8 = "1";
    var shrink: []const u8 = "1";
    var basis: []const u8 = "0%";

    if (components.len == 1 and isCssWideKeyword(components.items[0])) {
        grow = components.items[0];
        shrink = components.items[0];
        basis = components.items[0];
    } else if (components.len == 1 and values.eqlProp(components.items[0], "none")) {
        grow = "0";
        shrink = "0";
        basis = "auto";
    } else if (components.len == 1 and values.eqlProp(components.items[0], "auto")) {
        grow = "1";
        shrink = "1";
        basis = "auto";
    } else {
        var number_count: usize = 0;
        var saw_basis = false;
        for (components.slice()) |component| {
            if (values.parseNonNegativeNumber(component) != null and !saw_basis and number_count < 2) {
                if (number_count == 0) grow = component else shrink = component;
                number_count += 1;
            } else if (!saw_basis and (values.parseDimension(component, 16) != null or values.eqlProp(component, "auto") or values.eqlProp(component, "content"))) {
                basis = component;
                saw_basis = true;
            } else {
                return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
            }
        }
        if (number_count == 0 and !saw_basis) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
        if (number_count == 0) grow = "1";
    }

    const declarations = try allocator.alloc(Declaration, 3);
    declarations[0] = .{ .name = "flex-grow", .value = grow, .important = important };
    declarations[1] = .{ .name = "flex-shrink", .value = shrink, .important = important };
    declarations[2] = .{ .name = "flex-basis", .value = basis, .important = important };
    return .{ .declarations = declarations, .owns_names = false };
}

fn expandFlexFlow(allocator: std.mem.Allocator, value: []const u8, important: bool) !Expansion {
    const components = splitComponents(value);
    var direction: []const u8 = "row";
    var wrap: []const u8 = "nowrap";
    if (components.len == 1 and isCssWideKeyword(components.items[0])) {
        direction = components.items[0];
        wrap = components.items[0];
    } else {
        for (components.slice()) |component| {
            if (values.parseFlexDirection(component) != null) {
                direction = component;
            } else if (values.parseFlexWrap(component) != null) {
                wrap = component;
            } else {
                return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
            }
        }
    }
    const declarations = try allocator.alloc(Declaration, 2);
    declarations[0] = .{ .name = "flex-direction", .value = direction, .important = important };
    declarations[1] = .{ .name = "flex-wrap", .value = wrap, .important = important };
    return .{ .declarations = declarations, .owns_names = false };
}

fn expandGap(allocator: std.mem.Allocator, value: []const u8, important: bool) !Expansion {
    const components = splitComponents(value);
    if (components.len == 0 or components.len > 2) return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
    const row = components.items[0];
    const column = if (components.len == 1) row else components.items[1];
    const declarations = try allocator.alloc(Declaration, 2);
    declarations[0] = .{ .name = "row-gap", .value = row, .important = important };
    declarations[1] = .{ .name = "column-gap", .value = column, .important = important };
    return .{ .declarations = declarations, .owns_names = false };
}

fn expandListStyle(
    allocator: std.mem.Allocator,
    value: []const u8,
    important: bool,
) !Expansion {
    const components = splitComponents(value);
    var list_style_type: []const u8 = "disc";
    var list_style_position: []const u8 = "outside";

    if (components.len == 1 and isCssWideKeyword(components.items[0])) {
        list_style_type = components.items[0];
        list_style_position = components.items[0];
    } else {
        for (components.slice()) |component| {
            if (values.parseListStylePosition(component) != null) {
                list_style_position = component;
            } else if (values.parseListStyleType(component) != null) {
                list_style_type = component;
            } else {
                return .{ .declarations = try allocator.alloc(Declaration, 0), .owns_names = false };
            }
        }
    }

    const declarations = try allocator.alloc(Declaration, 2);
    declarations[0] = .{ .name = "list-style-type", .value = list_style_type, .important = important };
    declarations[1] = .{ .name = "list-style-position", .value = list_style_position, .important = important };
    return .{ .declarations = declarations, .owns_names = false };
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

fn splitSlashComponents(value: []const u8) Components {
    var result = Components{};
    var start: usize = 0;
    var index: usize = 0;
    var depth: usize = 0;
    var quote: ?u8 = null;
    while (index <= value.len) : (index += 1) {
        const at_end = index == value.len;
        const byte = if (at_end) 0 else value[index];
        if (!at_end and quote != null) {
            if (byte == '\\' and index + 1 < value.len) index += 1 else if (byte == quote.?) quote = null;
            continue;
        }
        if (!at_end and (byte == '"' or byte == '\'')) {
            quote = byte;
        } else if (!at_end and (byte == '(' or byte == '[' or byte == '{')) {
            depth += 1;
        } else if (!at_end and (byte == ')' or byte == ']' or byte == '}')) {
            depth -|= 1;
        } else if (at_end or (depth == 0 and byte == '/')) {
            if (result.len == result.items.len) break;
            const component = std.mem.trim(u8, value[start..index], " \t\n\r\x0C");
            if (component.len == 0) return .{};
            result.items[result.len] = component;
            result.len += 1;
            start = index + 1;
        }
    }
    return result;
}

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

test "expand list-style into inherited marker longhands" {
    const allocator = std.testing.allocator;
    const expansion = (try expand(allocator, "list-style", "inside upper-roman", true)).?;
    defer expansion.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), expansion.declarations.len);
    try std.testing.expectEqualStrings("list-style-type", expansion.declarations[0].name);
    try std.testing.expectEqualStrings("upper-roman", expansion.declarations[0].value);
    try std.testing.expectEqualStrings("list-style-position", expansion.declarations[1].name);
    try std.testing.expectEqualStrings("inside", expansion.declarations[1].value);
    try std.testing.expect(expansion.declarations[0].important);
}

test "expand flex flow sizing and gap shorthands" {
    const allocator = std.testing.allocator;
    const flex = (try expand(allocator, "flex", "2 3 120px", false)).?;
    defer flex.deinit(allocator);
    try std.testing.expectEqualStrings("2", flex.declarations[0].value);
    try std.testing.expectEqualStrings("3", flex.declarations[1].value);
    try std.testing.expectEqualStrings("120px", flex.declarations[2].value);

    const flow = (try expand(allocator, "flex-flow", "column-reverse wrap", false)).?;
    defer flow.deinit(allocator);
    try std.testing.expectEqualStrings("column-reverse", flow.declarations[0].value);
    try std.testing.expectEqualStrings("wrap", flow.declarations[1].value);

    const gap = (try expand(allocator, "gap", "8px 12px", false)).?;
    defer gap.deinit(allocator);
    try std.testing.expectEqualStrings("8px", gap.declarations[0].value);
    try std.testing.expectEqualStrings("12px", gap.declarations[1].value);
}

test "expand physical and logical inset shorthands" {
    const allocator = std.testing.allocator;
    const physical = (try expand(allocator, "inset", "1px 2px 3px 4px", false)).?;
    defer physical.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), physical.declarations.len);
    try std.testing.expectEqualStrings("top", physical.declarations[0].name);
    try std.testing.expectEqualStrings("right", physical.declarations[1].name);
    try std.testing.expectEqualStrings("bottom", physical.declarations[2].name);
    try std.testing.expectEqualStrings("left", physical.declarations[3].name);

    const logical = (try expand(allocator, "inset-inline", "10% auto", false)).?;
    defer logical.deinit(allocator);
    try std.testing.expectEqualStrings("inset-inline-start", logical.declarations[0].name);
    try std.testing.expectEqualStrings("inset-inline-end", logical.declarations[1].name);
}

test "expand elliptical border radius into corner longhands" {
    const allocator = std.testing.allocator;
    const radius = (try expand(allocator, "border-radius", "10px 20% 30px / 4px 8px", true)).?;
    defer radius.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), radius.declarations.len);
    try std.testing.expectEqualStrings("border-top-left-radius", radius.declarations[0].name);
    try std.testing.expectEqualStrings("10px 4px", radius.declarations[0].value);
    try std.testing.expectEqualStrings("border-top-right-radius", radius.declarations[1].name);
    try std.testing.expectEqualStrings("20% 8px", radius.declarations[1].value);
    try std.testing.expectEqualStrings("border-bottom-right-radius", radius.declarations[2].name);
    try std.testing.expectEqualStrings("30px 4px", radius.declarations[2].value);
    try std.testing.expectEqualStrings("border-bottom-left-radius", radius.declarations[3].name);
    try std.testing.expectEqualStrings("20% 8px", radius.declarations[3].value);
    for (radius.declarations) |declaration| try std.testing.expect(declaration.important);
}

test "expand Grid placement and template shorthands" {
    const allocator = std.testing.allocator;
    const column = (try expand(allocator, "grid-column", "2 / span 3", false)).?;
    defer column.deinit(allocator);
    try std.testing.expectEqualStrings("grid-column-start", column.declarations[0].name);
    try std.testing.expectEqualStrings("2", column.declarations[0].value);
    try std.testing.expectEqualStrings("span 3", column.declarations[1].value);

    const area = (try expand(allocator, "grid-area", "hero", false)).?;
    defer area.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), area.declarations.len);
    for (area.declarations) |declaration| try std.testing.expectEqualStrings("hero", declaration.value);

    const template = (try expand(allocator, "grid-template", "auto 1fr / 120px minmax(0,1fr)", true)).?;
    defer template.deinit(allocator);
    try std.testing.expectEqualStrings("auto 1fr", template.declarations[0].value);
    try std.testing.expectEqualStrings("120px minmax(0,1fr)", template.declarations[1].value);
    try std.testing.expect(template.declarations[0].important);
}
