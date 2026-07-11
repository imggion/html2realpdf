//! Selector matching and specificity for the native document profile.

const std = @import("std");
const dom = @import("../dom.zig");
const html = @import("../html.zig");
const syntax = @import("syntax.zig");

const Selector = syntax.Selector;
const SelectorTest = syntax.SelectorTest;
const Specificity = syntax.Specificity;

pub fn matchesSelector(selector: Selector, node_id: dom.NodeId, document: *const dom.Document) bool {
    if (selector.parts.len == 0) return false;

    const last_idx = selector.parts.len - 1;
    if (!matchesCompound(selector.parts[last_idx].tests, node_id, document)) return false;

    var current_id = node_id;
    var part_idx = last_idx;

    while (part_idx > 0) : (part_idx -= 1) {
        const combinator = selector.parts[part_idx - 1].combinator orelse break;

        switch (combinator) {
            .descendant => {
                const found = findAncestorMatching(selector.parts[part_idx - 1].tests, current_id, document);
                if (found) |ancestor_id| {
                    current_id = ancestor_id;
                } else {
                    return false;
                }
            },
            .child => {
                const parent_id = document.nodes.items[current_id].parent orelse return false;
                if (!matchesCompound(selector.parts[part_idx - 1].tests, parent_id, document)) return false;
                current_id = parent_id;
            },
        }
    }

    return true;
}

fn matchesCompound(tests: []const SelectorTest, node_id: dom.NodeId, document: *const dom.Document) bool {
    const node = document.nodes.items[node_id];
    const element = switch (node.kind) {
        .element => |e| e,
        .document, .text => {
            for (tests) |t| {
                if (t != .universal) return false;
            }
            return true;
        },
    };

    for (tests) |t| {
        switch (t) {
            .universal => {},
            .tag => |tag| {
                if (!std.ascii.eqlIgnoreCase(element.name, tag)) return false;
            },
            .class => |class_name| {
                if (!matchesClass(element, class_name)) return false;
            },
            .id => |id_value| {
                if (!matchesId(element, id_value)) return false;
            },
        }
    }
    return true;
}

fn findAncestorMatching(tests: []const SelectorTest, node_id: dom.NodeId, document: *const dom.Document) ?dom.NodeId {
    var current_id: ?dom.NodeId = document.nodes.items[node_id].parent;
    while (current_id) |id| {
        if (matchesCompound(tests, id, document)) return id;
        current_id = document.nodes.items[id].parent;
    }
    return null;
}

fn matchesClass(element: dom.Element, class_name: []const u8) bool {
    const attr_value = getAttributeValue(element.attributes, "class") orelse return false;
    return hasToken(attr_value, class_name);
}

fn matchesId(element: dom.Element, id_value: []const u8) bool {
    const attr_value = getAttributeValue(element.attributes, "id") orelse return false;
    return std.ascii.eqlIgnoreCase(attr_value, id_value);
}

fn hasToken(value: []const u8, token: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");
    while (iter.next()) |t| {
        if (std.mem.eql(u8, t, token)) return true;
    }
    return false;
}

// ---------------------------------------------------------------
// Specificity
// ---------------------------------------------------------------

pub fn selectorSpecificity(selector: Selector) Specificity {
    var spec = Specificity{};
    for (selector.parts) |part| {
        for (part.tests) |t| {
            switch (t) {
                .id => spec.id_count += 1,
                .class => spec.class_count += 1,
                .tag => spec.type_count += 1,
                .universal => {},
            }
        }
    }
    return spec;
}

pub fn compareSpecificity(a: Specificity, b: Specificity) std.math.Order {
    if (a.id_count != b.id_count) return std.math.order(a.id_count, b.id_count);
    if (a.class_count != b.class_count) return std.math.order(a.class_count, b.class_count);
    return std.math.order(a.type_count, b.type_count);
}

// ---------------------------------------------------------------
// Value parsing helpers
// ---------------------------------------------------------------

fn getAttributeValue(attributes: []const html.Attribute, name: []const u8) ?[]const u8 {
    for (attributes) |attr| {
        if (std.ascii.eqlIgnoreCase(attr.name, name)) return attr.value;
    }
    return null;
}
