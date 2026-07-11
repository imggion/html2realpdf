//! DOM style collection, cascade ordering, inheritance, and debug output.

const std = @import("std");
const dom = @import("../dom.zig");
const box = @import("../box.zig");
const html = @import("../html.zig");
const syntax = @import("syntax.zig");
const selectors = @import("selectors.zig");
const computed = @import("computed.zig");
const expressions = @import("expressions.zig");
const variables = @import("variables.zig");
const shorthands = @import("shorthands.zig");
const diagnostics = @import("../diagnostics.zig");

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

pub const Context = struct {
    viewport_width: f32 = 800,
    viewport_height: f32 = 600,
    root_font_size: f32 = 16,
    diagnostics: ?*std.ArrayList(diagnostics.Diagnostic) = null,
};

pub fn computeStyles(
    arena: std.mem.Allocator,
    document: *const dom.Document,
    stylesheets: []const Stylesheet,
) ![]box.Style {
    return computeStylesWithContext(arena, document, stylesheets, .{});
}

pub fn computeStylesWithContext(
    arena: std.mem.Allocator,
    document: *const dom.Document,
    stylesheets: []const Stylesheet,
    context: Context,
) ![]box.Style {
    const styles = try arena.alloc(box.Style, document.nodes.items.len);
    @memset(styles, box.Style{});
    const expression_store = try arena.create(expressions.Store);
    expression_store.* = try expressions.Store.init(arena);
    const computed_context = computed.Context{
        .allocator = arena,
        .expression_store = expression_store,
        .root_font_size = context.root_font_size,
        .viewport_width = context.viewport_width,
        .viewport_height = context.viewport_height,
        .diagnostics = context.diagnostics,
    };

    try computeStylesRecursive(document, stylesheets, styles, document.root, null, null, arena, computed_context);

    return styles;
}

fn computeStylesRecursive(
    document: *const dom.Document,
    stylesheets: []const Stylesheet,
    styles: []box.Style,
    node_id: dom.NodeId,
    parent_style: ?*const box.Style,
    parent_scope: ?*const variables.Scope,
    scratch: std.mem.Allocator,
    computed_context: computed.Context,
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
        style.text_decoration_style = ps.text_decoration_style;
        style.text_decoration_color = ps.text_decoration_color;
        style.text_decoration_thickness = ps.text_decoration_thickness;
        style.letter_spacing = ps.letter_spacing;
        style.word_spacing = ps.word_spacing;
        style.text_indent = ps.text_indent;
        style.text_align = ps.text_align;
        style.text_transform = ps.text_transform;
        style.word_break = ps.word_break;
        style.overflow_wrap = ps.overflow_wrap;
        style.direction = ps.direction;
    }

    // Heading sizes are UA declarations, not inherited defaults. Preserve
    // them after inherited text properties have been copied from the parent.
    if (ua_style.font_size != (box.Style{}).font_size) {
        style.font_size = ua_style.font_size;
    }
    if (ua_style.font_weight != .normal) style.font_weight = ua_style.font_weight;
    if (ua_style.font_style != .normal) style.font_style = ua_style.font_style;
    if (!std.mem.eql(u8, ua_style.color, (box.Style{}).color)) style.color = ua_style.color;
    if (ua_style.text_decoration != .none) {
        style.text_decoration = ua_style.text_decoration;
        style.text_decoration_style = ua_style.text_decoration_style;
        style.text_decoration_color = ua_style.text_decoration_color;
        style.text_decoration_thickness = ua_style.text_decoration_thickness;
    }

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

    var node_computed_context = computed_context;
    node_computed_context.parent_style = parent_style;
    node_computed_context.ua_style = &ua_style;

    const custom_scope = try variables.Scope.create(scratch, parent_scope);
    try applyMatchedCustomProperties(custom_scope, stylesheets, matches.items, false, scratch);
    try applyInlineCustomProperties(custom_scope, document.nodes.items[node_id], scratch, false);
    try applyMatchedCustomProperties(custom_scope, stylesheets, matches.items, true, scratch);
    try applyInlineCustomProperties(custom_scope, document.nodes.items[node_id], scratch, true);

    var direction_probe = style;
    try applyMatchedDirection(&direction_probe, stylesheets, matches.items, custom_scope, node_computed_context, false, scratch);
    try applyInlineDirection(&direction_probe, document.nodes.items[node_id], custom_scope, node_computed_context, scratch, false);
    try applyMatchedDirection(&direction_probe, stylesheets, matches.items, custom_scope, node_computed_context, true, scratch);
    try applyInlineDirection(&direction_probe, document.nodes.items[node_id], custom_scope, node_computed_context, scratch, true);
    node_computed_context.logical_direction = direction_probe.direction;

    try applyMatchedDeclarations(&style, stylesheets, matches.items, custom_scope, node_computed_context, false, scratch);
    try applyInlineStyle(&style, document.nodes.items[node_id], custom_scope, node_computed_context, scratch, false);
    try applyMatchedDeclarations(&style, stylesheets, matches.items, custom_scope, node_computed_context, true, scratch);
    try applyInlineStyle(&style, document.nodes.items[node_id], custom_scope, node_computed_context, scratch, true);

    styles[node_id] = style;

    const node = document.nodes.items[node_id];
    var child = node.first_child;
    while (child) |child_id| {
        try computeStylesRecursive(document, stylesheets, styles, child_id, &style, custom_scope, scratch, computed_context);
        child = document.nodes.items[child_id].next_sibling;
    }
}

fn applyMatchedDirection(
    style: *box.Style,
    stylesheets: []const Stylesheet,
    matches: []const Match,
    custom_scope: *const variables.Scope,
    computed_context: computed.Context,
    important: bool,
    scratch: std.mem.Allocator,
) !void {
    for (matches) |match| {
        const rule = stylesheets[match.stylesheet_idx].rules[match.rule_idx];
        for (rule.declarations) |declaration| {
            if (declaration.important != important or !std.ascii.eqlIgnoreCase(declaration.name, "direction")) continue;
            const resolved = try variables.resolve(scratch, custom_scope, declaration.value) orelse continue;
            try applyDeclaration(computed_context, style, declaration.name, resolved);
        }
    }
}

fn applyInlineDirection(
    style: *box.Style,
    node: dom.Node,
    custom_scope: *const variables.Scope,
    computed_context: computed.Context,
    scratch: std.mem.Allocator,
    important: bool,
) !void {
    const element = switch (node.kind) {
        .element => |value| value,
        else => return,
    };
    const inline_text = getAttributeValue(element.attributes, "style") orelse return;
    if (inline_text.len == 0) return;

    const wrapped = try std.fmt.allocPrint(scratch, "*{{{s}}}", .{inline_text});
    const stylesheet = try parseStylesheet(scratch, wrapped);
    if (stylesheet.rules.len == 0) return;
    for (stylesheet.rules[0].declarations) |declaration| {
        if (declaration.important != important or !std.ascii.eqlIgnoreCase(declaration.name, "direction")) continue;
        const resolved = try variables.resolve(scratch, custom_scope, declaration.value) orelse continue;
        try applyDeclaration(computed_context, style, declaration.name, resolved);
    }
}

fn applyMatchedDeclarations(
    style: *box.Style,
    stylesheets: []const Stylesheet,
    matches: []const Match,
    custom_scope: *const variables.Scope,
    computed_context: computed.Context,
    important: bool,
    scratch: std.mem.Allocator,
) !void {
    for (matches) |match| {
        const rule = stylesheets[match.stylesheet_idx].rules[match.rule_idx];
        for (rule.declarations) |declaration| {
            if (declaration.important != important or isCustomProperty(declaration.name)) continue;
            const resolved = try variables.resolve(scratch, custom_scope, declaration.value) orelse continue;
            try applyCascadedDeclaration(style, declaration.name, resolved, declaration.important, computed_context, scratch);
        }
    }
}

fn applyInlineStyle(
    style: *box.Style,
    node: dom.Node,
    custom_scope: *const variables.Scope,
    computed_context: computed.Context,
    scratch: std.mem.Allocator,
    important: bool,
) !void {
    const element = switch (node.kind) {
        .element => |value| value,
        else => return,
    };
    const inline_text = getAttributeValue(element.attributes, "style") orelse return;
    if (inline_text.len == 0) return;

    const wrapped = try std.fmt.allocPrint(scratch, "*{{{s}}}", .{inline_text});
    const stylesheet = try parseStylesheet(scratch, wrapped);
    if (stylesheet.rules.len == 0) return;

    for (stylesheet.rules[0].declarations) |declaration| {
        if (declaration.important != important or isCustomProperty(declaration.name)) continue;
        const resolved = try variables.resolve(scratch, custom_scope, declaration.value) orelse continue;
        try applyCascadedDeclaration(style, declaration.name, resolved, declaration.important, computed_context, scratch);
    }
}

fn applyCascadedDeclaration(
    style: *box.Style,
    name: []const u8,
    value: []const u8,
    important: bool,
    computed_context: computed.Context,
    scratch: std.mem.Allocator,
) !void {
    if (try shorthands.expand(scratch, name, value, important)) |expansion| {
        defer expansion.deinit(scratch);
        for (expansion.declarations) |longhand| {
            try applyDeclaration(computed_context, style, longhand.name, longhand.value);
        }
        return;
    }
    if (!computed.supportsProperty(name)) {
        try reportUnsupportedProperty(computed_context.allocator, computed_context, name);
        return;
    }
    try applyDeclaration(computed_context, style, name, value);
}

fn reportUnsupportedProperty(
    allocator: std.mem.Allocator,
    context: computed.Context,
    property: []const u8,
) !void {
    const collector = context.diagnostics orelse return;
    for (collector.items) |existing| {
        if (existing.property) |reported| {
            if (std.ascii.eqlIgnoreCase(reported, property)) return;
        }
    }
    const message = try std.fmt.allocPrint(allocator, "Unsupported CSS property was ignored: {s}", .{property});
    try collector.append(allocator, .{
        .code = "UNSUPPORTED_CSS_PROPERTY",
        .severity = .warning,
        .message = message,
        .property = property,
        .phase = .computed,
    });
}

fn applyMatchedCustomProperties(
    scope: *variables.Scope,
    stylesheets: []const Stylesheet,
    matches: []const Match,
    important: bool,
    scratch: std.mem.Allocator,
) !void {
    for (matches) |match| {
        const rule = stylesheets[match.stylesheet_idx].rules[match.rule_idx];
        for (rule.declarations) |declaration| {
            if (declaration.important == important and isCustomProperty(declaration.name)) {
                try scope.set(scratch, declaration.name, declaration.value);
            }
        }
    }
}

fn applyInlineCustomProperties(
    scope: *variables.Scope,
    node: dom.Node,
    scratch: std.mem.Allocator,
    important: bool,
) !void {
    const element = switch (node.kind) {
        .element => |value| value,
        else => return,
    };
    const inline_text = getAttributeValue(element.attributes, "style") orelse return;
    if (inline_text.len == 0) return;
    const wrapped = try std.fmt.allocPrint(scratch, "*{{{s}}}", .{inline_text});
    const stylesheet = try parseStylesheet(scratch, wrapped);
    if (stylesheet.rules.len == 0) return;
    for (stylesheet.rules[0].declarations) |declaration| {
        if (declaration.important == important and isCustomProperty(declaration.name)) {
            try scope.set(scratch, declaration.name, declaration.value);
        }
    }
}

fn isCustomProperty(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "--");
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
    return styleArrayFromDocumentWithContext(arena, document, .{});
}

pub fn styleArrayFromDocumentWithContext(
    arena: std.mem.Allocator,
    document: *const dom.Document,
    context: Context,
) ![]box.Style {
    const css_text = collectStyleText(arena, document) catch &.{};
    if (css_text.len == 0) {
        return computeStylesWithContext(arena, document, &.{}, context);
    }

    const stylesheet = parseStylesheet(arena, css_text) catch {
        return computeStylesWithContext(arena, document, &.{}, context);
    };
    // The stylesheet borrows arena memory for the complete render lifetime.

    return computeStylesWithContext(arena, document, &.{stylesheet}, context);
}

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------
