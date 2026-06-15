const std = @import("std");
const html = @import("html.zig");

pub const NodeId = usize;

pub const Document = struct {
    source: []const u8,
    nodes: std.ArrayList(Node),
    root: NodeId,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.nodes.items) |node| {
            if (node.kind == .element) {
                const element = node.kind.element;
                if (element.attributes.len > 0) allocator.free(element.attributes);
            }
        }

        self.nodes.deinit(allocator);
    }

    pub fn dump(self: *const Document, writer: *std.Io.Writer) !void {
        try dumpNode(self, self.root, 0, writer);
    }
};

pub const Node = struct {
    kind: NodeKind,
    parent: ?NodeId = null,
    first_child: ?NodeId = null,
    last_child: ?NodeId = null,
    next_sibling: ?NodeId = null,
    prev_sibling: ?NodeId = null,
};

pub const NodeKind = union(enum) {
    document,
    element: Element,
    text: []const u8,
};

pub const Element = struct {
    tag: Tag,
    name: []const u8,
    attributes: []const html.Attribute,
};

pub const Tag = enum {
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    p,
    div,
    span,
    strong,
    em,
    img,
    br,
    ul,
    ol,
    li,
    table,
    tr,
    td,
    th,
    html,
    body,
    unknown,
};

pub const Parser = struct {
    pub fn parse(allocator: std.mem.Allocator, source: []const u8, tokens: []const html.Token) !Document {
        var nodes = try std.ArrayList(Node).initCapacity(allocator, 0);
        {
            errdefer nodes.deinit(allocator);
            try nodes.append(allocator, .{ .kind = .document });
        }

        var document = Document{
            .source = source,
            .nodes = nodes,
            .root = 0,
        };
        errdefer document.deinit(allocator);

        var stack = try std.ArrayList(NodeId).initCapacity(allocator, 0);
        defer stack.deinit(allocator);

        try stack.append(allocator, document.root);

        for (tokens) |token| {
            switch (token) {
                .text => |text| {
                    if (text.len > 0) {
                        _ = try appendNode(&document, allocator, .{ .text = text }, stack.items[stack.items.len - 1]);
                    }
                },
                .tag_open => |open_tag| {
                    const attributes = try copyAttributes(allocator, open_tag.attributes);
                    const node_id = appendNode(
                        &document,
                        allocator,
                        .{ .element = .{
                            .tag = tagFromName(open_tag.name),
                            .name = open_tag.name,
                            .attributes = attributes,
                        } },
                        stack.items[stack.items.len - 1],
                    ) catch |err| {
                        if (attributes.len > 0) {
                            allocator.free(attributes);
                        }
                        return err;
                    };

                    if (!open_tag.self_closing and !isVoidElementName(open_tag.name)) {
                        try stack.append(allocator, node_id);
                    }
                },
                .tag_close => |name| closeElement(&document, &stack, name),
                .comment => {},
                .doctype => {},
            }
        }

        return document;
    }
};

pub fn tagFromName(name: []const u8) Tag {
    if (eqlTag(name, "h1")) return .h1;
    if (eqlTag(name, "h2")) return .h2;
    if (eqlTag(name, "h3")) return .h3;
    if (eqlTag(name, "h4")) return .h4;
    if (eqlTag(name, "h5")) return .h5;
    if (eqlTag(name, "h6")) return .h6;
    if (eqlTag(name, "p")) return .p;
    if (eqlTag(name, "div")) return .div;
    if (eqlTag(name, "span")) return .span;
    if (eqlTag(name, "strong")) return .strong;
    if (eqlTag(name, "em")) return .em;
    if (eqlTag(name, "img")) return .img;
    if (eqlTag(name, "br")) return .br;
    if (eqlTag(name, "ul")) return .ul;
    if (eqlTag(name, "ol")) return .ol;
    if (eqlTag(name, "li")) return .li;
    if (eqlTag(name, "table")) return .table;
    if (eqlTag(name, "tr")) return .tr;
    if (eqlTag(name, "td")) return .td;
    if (eqlTag(name, "th")) return .th;
    if (eqlTag(name, "html")) return .html;
    if (eqlTag(name, "body")) return .body;
    return .unknown;
}

pub fn isVoidElementName(name: []const u8) bool {
    return eqlTag(name, "area") or
        eqlTag(name, "base") or
        eqlTag(name, "br") or
        eqlTag(name, "col") or
        eqlTag(name, "embed") or
        eqlTag(name, "hr") or
        eqlTag(name, "img") or
        eqlTag(name, "input") or
        eqlTag(name, "link") or
        eqlTag(name, "meta") or
        eqlTag(name, "source") or
        eqlTag(name, "track") or
        eqlTag(name, "wbr");
}

fn appendNode(
    document: *Document,
    allocator: std.mem.Allocator,
    kind: NodeKind,
    parent: NodeId,
) !NodeId {
    const node_id = document.nodes.items.len;
    try document.nodes.append(allocator, .{ .kind = kind, .parent = parent });
    appendChild(document, parent, node_id);
    return node_id;
}

fn appendChild(document: *Document, parent: NodeId, child: NodeId) void {
    const last_child = document.nodes.items[parent].last_child;

    document.nodes.items[child].parent = parent;
    document.nodes.items[child].prev_sibling = last_child;

    if (last_child) |last_child_id| {
        document.nodes.items[last_child_id].next_sibling = child;
    } else {
        document.nodes.items[parent].first_child = child;
    }

    document.nodes.items[parent].last_child = child;
}

fn copyAttributes(allocator: std.mem.Allocator, attributes: []const html.Attribute) ![]const html.Attribute {
    if (attributes.len == 0) return &.{};

    const copied = try allocator.alloc(html.Attribute, attributes.len);
    @memcpy(copied, attributes);
    return copied;
}

fn closeElement(document: *const Document, stack: *std.ArrayList(NodeId), name: []const u8) void {
    var index = stack.items.len;

    while (index > 1) {
        index -= 1;

        const node_id = stack.items[index];
        switch (document.nodes.items[node_id].kind) {
            .element => |element| {
                if (eqlTag(element.name, name)) {
                    stack.shrinkRetainingCapacity(index);
                    return;
                }
            },
            else => {},
        }
    }
}

fn dumpNode(document: *const Document, node_id: NodeId, depth: usize, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }

    const node = document.nodes.items[node_id];
    switch (node.kind) {
        .document => try writer.writeAll("#document\n"),
        .text => |text| try writer.print("#text \"{s}\"\n", .{text}),
        .element => |element| {
            try writer.print("{s}", .{element.name});
            try dumpAttributes(element.attributes, writer);
            try writer.writeAll("\n");
        },
    }

    var child = node.first_child;
    while (child) |child_id| {
        try dumpNode(document, child_id, depth + 1, writer);
        child = document.nodes.items[child_id].next_sibling;
    }
}

fn dumpAttributes(attributes: []const html.Attribute, writer: *std.Io.Writer) !void {
    for (attributes) |attribute| {
        try writer.print(" {s}", .{attribute.name});
        if (attribute.value) |value| {
            try writer.print("=\"{s}\"", .{value});
        }
    }
}

fn eqlTag(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn deinitTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList(html.Token)) void {
    for (tokens.items) |token| {
        switch (token) {
            .tag_open => |open_tag| allocator.free(open_tag.attributes),
            else => {},
        }
    }

    tokens.deinit(allocator);
}

fn expectElement(document: *const Document, node_id: NodeId, tag: Tag, name: []const u8) !void {
    switch (document.nodes.items[node_id].kind) {
        .element => |element| {
            try std.testing.expectEqual(tag, element.tag);
            try std.testing.expectEqualStrings(name, element.name);
        },
        else => return error.ExpectedElement,
    }
}

fn expectText(document: *const Document, node_id: NodeId, text: []const u8) !void {
    switch (document.nodes.items[node_id].kind) {
        .text => |node_text| try std.testing.expectEqualStrings(text, node_text),
        else => return error.ExpectedText,
    }
}

test "parse nested elements into a DOM tree" {
    const allocator = std.testing.allocator;
    const source = "<div><p>Hello <strong>world</strong></p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    try expectElement(&document, div_id, .div, "div");

    const p_id = document.nodes.items[div_id].first_child.?;
    try expectElement(&document, p_id, .p, "p");

    const hello_id = document.nodes.items[p_id].first_child.?;
    try expectText(&document, hello_id, "Hello ");

    const strong_id = document.nodes.items[hello_id].next_sibling.?;
    try expectElement(&document, strong_id, .strong, "strong");

    const world_id = document.nodes.items[strong_id].first_child.?;
    try expectText(&document, world_id, "world");
}

test "parse mismatched closing tags tolerantly" {
    const allocator = std.testing.allocator;
    const source = "<div><p>x</div></span>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    try expectElement(&document, div_id, .div, "div");

    const p_id = document.nodes.items[div_id].first_child.?;
    try expectElement(&document, p_id, .p, "p");

    const text_id = document.nodes.items[p_id].first_child.?;
    try expectText(&document, text_id, "x");
}

test "parse void elements without pushing them on the stack" {
    const allocator = std.testing.allocator;
    const source = "<div>a<br><img src=\"x.png\">b</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const a_id = document.nodes.items[div_id].first_child.?;
    const br_id = document.nodes.items[a_id].next_sibling.?;
    const img_id = document.nodes.items[br_id].next_sibling.?;
    const b_id = document.nodes.items[img_id].next_sibling.?;

    try expectText(&document, a_id, "a");
    try expectElement(&document, br_id, .br, "br");
    try expectElement(&document, img_id, .img, "img");
    try expectText(&document, b_id, "b");

    try std.testing.expectEqual(@as(?NodeId, null), document.nodes.items[br_id].first_child);
    try std.testing.expectEqual(@as(?NodeId, null), document.nodes.items[img_id].first_child);

    const img = document.nodes.items[img_id].kind.element;
    try std.testing.expectEqual(@as(usize, 1), img.attributes.len);
    try std.testing.expectEqualStrings("src", img.attributes[0].name);
    try std.testing.expectEqualStrings("x.png", img.attributes[0].value.?);
}

test "parse lists and tables" {
    const allocator = std.testing.allocator;
    const source = "<div><ul><li>one</li><li>two</li></ul><table><tr><th>h</th><td>c</td></tr></table></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const ul_id = document.nodes.items[div_id].first_child.?;
    const table_id = document.nodes.items[ul_id].next_sibling.?;

    try expectElement(&document, ul_id, .ul, "ul");
    try expectElement(&document, table_id, .table, "table");

    const first_li_id = document.nodes.items[ul_id].first_child.?;
    const second_li_id = document.nodes.items[first_li_id].next_sibling.?;
    try expectElement(&document, first_li_id, .li, "li");
    try expectElement(&document, second_li_id, .li, "li");

    const tr_id = document.nodes.items[table_id].first_child.?;
    const th_id = document.nodes.items[tr_id].first_child.?;
    const td_id = document.nodes.items[th_id].next_sibling.?;
    try expectElement(&document, tr_id, .tr, "tr");
    try expectElement(&document, th_id, .th, "th");
    try expectElement(&document, td_id, .td, "td");
}

test "dump DOM tree" {
    const allocator = std.testing.allocator;
    const source = "<div><p>Hello <strong>world</strong></p><br><img src=\"x.png\"></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try document.dump(&writer);

    const expected =
        \\#document
        \\  div
        \\    p
        \\      #text "Hello "
        \\      strong
        \\        #text "world"
        \\    br
        \\    img src="x.png"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "debug dump DOM tree" {
    if (!std.testing.environ.containsUnemptyConstant("HTML2REALPDF_DEBUG_DOM")) return;

    const allocator = std.testing.allocator;
    const source = "<div><p>Hello <strong>world</strong></p><br><img src=\"x.png\"></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try document.dump(&writer);

    std.debug.print("\n{s}", .{writer.buffered()});
}
