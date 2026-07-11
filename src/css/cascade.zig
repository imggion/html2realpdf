//! DOM style collection, cascade ordering, inheritance, and debug output.

const std = @import("std");
const dom = @import("../dom.zig");
const box = @import("../box.zig");
const html = @import("../html.zig");
const syntax = @import("syntax.zig");
const selectors = @import("selectors.zig");
const computed = @import("computed.zig");

const Stylesheet = syntax.Stylesheet;
const Specificity = syntax.Specificity;
const parseStylesheet = syntax.parseStylesheet;
const matchesSelector = selectors.matchesSelector;
const selectorSpecificity = selectors.selectorSpecificity;
const compareSpecificity = selectors.compareSpecificity;
const applyDeclaration = computed.applyDeclaration;

fn getAttributeValue(attributes: []const html.Attribute, name: []const u8) ?[]const u8 {
    for (attributes) |attr| {
        if (std.ascii.eqlIgnoreCase(attr.name, name)) return attr.value;
    }
    return null;
}

// ---------------------------------------------------------------
// Cascade engine
// ---------------------------------------------------------------

const Match = struct {
    stylesheet_idx: u32,
    rule_idx: u32,
    specificity: Specificity,
};

pub fn computeStyles(
    arena: std.mem.Allocator,
    document: *const dom.Document,
    stylesheets: []const Stylesheet,
) ![]box.Style {
    const styles = try arena.alloc(box.Style, document.nodes.items.len);
    @memset(styles, box.Style{});

    try computeStylesRecursive(document, stylesheets, styles, document.root, null, arena);

    return styles;
}

fn computeStylesRecursive(
    document: *const dom.Document,
    stylesheets: []const Stylesheet,
    styles: []box.Style,
    node_id: dom.NodeId,
    parent_style: ?*const box.Style,
    scratch: std.mem.Allocator,
) !void {
    const ua_style = box.defaultStyleForNode(document, node_id);
    var style = ua_style;

    if (parent_style) |ps| {
        style.font_size = ps.font_size;
        style.font_family = ps.font_family;
        style.font_weight = ps.font_weight;
        style.font_style = ps.font_style;
        style.color = ps.color;
        style.white_space = ps.white_space;
        style.text_decoration = ps.text_decoration;
        style.letter_spacing = ps.letter_spacing;
    }

    // Heading sizes are UA declarations, not inherited defaults. Preserve
    // them after inherited text properties have been copied from the parent.
    if (ua_style.font_size != (box.Style{}).font_size) {
        style.font_size = ua_style.font_size;
    }
    if (ua_style.font_weight != .normal) style.font_weight = ua_style.font_weight;
    if (ua_style.font_style != .normal) style.font_style = ua_style.font_style;
    if (!std.mem.eql(u8, ua_style.color, (box.Style{}).color)) style.color = ua_style.color;
    if (ua_style.text_decoration != .none) style.text_decoration = ua_style.text_decoration;

    var matches = try std.ArrayList(Match).initCapacity(scratch, 0);
    defer matches.deinit(scratch);

    for (stylesheets, 0..) |ss, ss_idx| {
        for (ss.rules, 0..) |rule, rule_idx| {
            var best_specificity: ?Specificity = null;
            for (rule.selectors) |sel| {
                if (matchesSelector(sel, node_id, document)) {
                    const specificity = selectorSpecificity(sel);
                    if (best_specificity == null or compareSpecificity(best_specificity.?, specificity) == .lt) {
                        best_specificity = specificity;
                    }
                }
            }
            if (best_specificity) |specificity| try matches.append(scratch, .{
                .stylesheet_idx = @intCast(ss_idx),
                .rule_idx = @intCast(rule_idx),
                .specificity = specificity,
            });
        }
    }

    std.mem.sort(Match, matches.items, {}, compareMatchBySpecificity);

    applyMatchedDeclarations(&style, stylesheets, matches.items, false);
    applyInlineStyle(&style, document.nodes.items[node_id], scratch, false);
    applyMatchedDeclarations(&style, stylesheets, matches.items, true);
    applyInlineStyle(&style, document.nodes.items[node_id], scratch, true);

    styles[node_id] = style;

    const node = document.nodes.items[node_id];
    var child = node.first_child;
    while (child) |child_id| {
        try computeStylesRecursive(document, stylesheets, styles, child_id, &style, scratch);
        child = document.nodes.items[child_id].next_sibling;
    }
}

fn applyMatchedDeclarations(
    style: *box.Style,
    stylesheets: []const Stylesheet,
    matches: []const Match,
    important: bool,
) void {
    for (matches) |match| {
        const rule = stylesheets[match.stylesheet_idx].rules[match.rule_idx];
        for (rule.declarations) |declaration| {
            if (declaration.important == important) applyDeclaration(style, declaration.name, declaration.value);
        }
    }
}

fn applyInlineStyle(style: *box.Style, node: dom.Node, scratch: std.mem.Allocator, important: bool) void {
    const element = switch (node.kind) {
        .element => |value| value,
        else => return,
    };
    const inline_text = getAttributeValue(element.attributes, "style") orelse return;
    if (inline_text.len == 0) return;

    const wrapped = std.fmt.allocPrint(scratch, "*{{{s}}}", .{inline_text}) catch return;
    const stylesheet = parseStylesheet(scratch, wrapped) catch return;
    if (stylesheet.rules.len == 0) return;

    for (stylesheet.rules[0].declarations) |declaration| {
        if (declaration.important == important) applyDeclaration(style, declaration.name, declaration.value);
    }
}

fn compareMatchBySpecificity(_: void, a: Match, b: Match) bool {
    const order = compareSpecificity(a.specificity, b.specificity);
    if (order != .eq) return order == .lt;
    if (a.stylesheet_idx != b.stylesheet_idx) return a.stylesheet_idx < b.stylesheet_idx;
    return a.rule_idx < b.rule_idx;
}

// ---------------------------------------------------------------
// DOM helpers for CSS extraction
// ---------------------------------------------------------------

pub fn collectStyleText(allocator: std.mem.Allocator, document: *const dom.Document) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer buf.deinit(allocator);

    try collectStyleTextFrom(document, document.root, &buf, allocator);
    if (buf.items.len > 0) {
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

fn collectStyleTextFrom(document: *const dom.Document, node_id: dom.NodeId, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const node = document.nodes.items[node_id];

    if (node.kind == .element) {
        const element = node.kind.element;
        if (std.ascii.eqlIgnoreCase(element.name, "style")) {
            var child = node.first_child;
            while (child) |child_id| {
                const child_node = document.nodes.items[child_id];
                if (child_node.kind == .text) {
                    try buf.appendSlice(allocator, child_node.kind.text);
                }
                child = child_node.next_sibling;
            }
        }
    }

    var child = node.first_child;
    while (child) |child_id| {
        try collectStyleTextFrom(document, child_id, buf, allocator);
        child = document.nodes.items[child_id].next_sibling;
    }
}

// ---------------------------------------------------------------
// Cascade dump for debugging and WASM output
// ---------------------------------------------------------------

pub fn dumpCascade(
    document: *const dom.Document,
    styles: []const box.Style,
    writer: *std.Io.Writer,
) !void {
    try dumpCascadeNode(document, styles, document.root, 0, writer);
}

fn dumpCascadeNode(
    document: *const dom.Document,
    styles: []const box.Style,
    node_id: dom.NodeId,
    depth: usize,
    writer: *std.Io.Writer,
) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }

    const node = document.nodes.items[node_id];
    const style = if (node_id < styles.len) styles[node_id] else box.Style{};

    switch (node.kind) {
        .document => try writer.print("#document [display={s}]\n", .{style.display.toString()}),
        .text => |text| try writer.print("#text \"{s}\" [display={s} font-size={d:.2} font-family={s} color={s}]\n", .{
            text, style.display.toString(), style.font_size, style.font_family, style.color,
        }),
        .element => |element| {
            try writer.print("{s}", .{element.name});
            for (element.attributes) |attr| {
                if (std.ascii.eqlIgnoreCase(attr.name, "class")) {
                    if (attr.value) |v| try writer.print(".{s}", .{v});
                } else if (std.ascii.eqlIgnoreCase(attr.name, "id")) {
                    if (attr.value) |v| try writer.print("#{s}", .{v});
                }
            }
            try writer.print(" [display={s} font-size={d:.2} font-family={s} color={s}", .{
                style.display.toString(), style.font_size, style.font_family, style.color,
            });
            if (style.background) |bg| {
                try writer.print(" background={s}", .{bg});
            }
            if (!edgeIsZero(style.margin)) {
                try writer.print(" margin={d:.2},{d:.2},{d:.2},{d:.2}", .{
                    style.margin.top, style.margin.right, style.margin.bottom, style.margin.left,
                });
            }
            if (!edgeIsZero(style.padding)) {
                try writer.print(" padding={d:.2},{d:.2},{d:.2},{d:.2}", .{
                    style.padding.top, style.padding.right, style.padding.bottom, style.padding.left,
                });
            }
            if (!edgeIsZero(style.border)) {
                try writer.print(" border={d:.2},{d:.2},{d:.2},{d:.2}", .{
                    style.border.top, style.border.right, style.border.bottom, style.border.left,
                });
            }
            try writer.writeAll("]\n");
        },
    }

    var child = node.first_child;
    while (child) |child_id| {
        try dumpCascadeNode(document, styles, child_id, depth + 1, writer);
        child = document.nodes.items[child_id].next_sibling;
    }
}

fn edgeIsZero(e: box.EdgeSizes) bool {
    return e.top == 0 and e.right == 0 and e.bottom == 0 and e.left == 0;
}

// ---------------------------------------------------------------
// Convenience: full pipeline from DOM to Style array
// ---------------------------------------------------------------

pub fn styleArrayFromDocument(
    arena: std.mem.Allocator,
    document: *const dom.Document,
) ![]box.Style {
    const css_text = collectStyleText(arena, document) catch &.{};
    if (css_text.len == 0) {
        return computeStyles(arena, document, &.{});
    }

    const stylesheet = parseStylesheet(arena, css_text) catch {
        return computeStyles(arena, document, &.{});
    };
    // The stylesheet borrows arena memory for the complete render lifetime.

    return computeStyles(arena, document, &.{stylesheet});
}

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------
