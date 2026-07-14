//! Tolerant DOM tree builder for the HTML token stream.
//!
//! The tree is stored flat and linked with `NodeId` values. That mirrors the Box
//! Tree module, avoids recursive ownership, and makes later layout phases cheap
//! to traverse without pointer lifetime traps.

const std = @import("std");
const html = @import("html.zig");

/// Stable index into `Document.nodes`.
pub const NodeId = usize;

/// Parsed document plus the source bytes it borrows from.
///
/// Most strings point into `source`. Decoded character references are owned by
/// `owned_strings`, while attribute slices are copied so the document can
/// outlive the token list.
pub const Document = struct {
    source: []const u8,
    nodes: std.ArrayList(Node),
    owned_strings: std.ArrayList([]u8),
    root: NodeId,

    /// Frees node storage and copied attribute slices.
    ///
    /// The caller still owns `source`; deinit only releases allocations created
    /// by `Parser.parse`.
    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.nodes.items) |node| {
            if (node.kind == .element) {
                const element = node.kind.element;
                if (element.attributes.len > 0) allocator.free(element.attributes);
            }
        }
        for (self.owned_strings.items) |owned| allocator.free(owned);
        self.owned_strings.deinit(allocator);

        self.nodes.deinit(allocator);
    }

    /// Compact ASCII dump used by debug targets and structural tests.
    pub fn dump(self: *const Document, writer: *std.Io.Writer) !void {
        try dumpNode(self, self.root, 0, writer);
    }

    /// Adds a node and links it immediately under its parent.
    ///
    /// Keeping this as the only construction path preserves sibling-link
    /// invariants during parser recovery.
    fn appendNode(
        self: *Document,
        allocator: std.mem.Allocator,
        kind: NodeKind,
        parent: NodeId,
    ) !NodeId {
        const node_id = self.nodes.items.len;
        try self.nodes.append(allocator, .{ .kind = kind, .parent = parent });
        self.appendChild(parent, node_id);
        return node_id;
    }

    /// Maintains parent/child/sibling links in the same flat shape used later by
    /// the Box Tree.
    fn appendChild(self: *Document, parent: NodeId, child: NodeId) void {
        const last_child = self.nodes.items[parent].last_child;

        self.nodes.items[child].parent = parent;
        self.nodes.items[child].prev_sibling = last_child;

        if (last_child) |last_child_id| {
            self.nodes.items[last_child_id].next_sibling = child;
        } else {
            self.nodes.items[parent].first_child = child;
        }

        self.nodes.items[parent].last_child = child;
    }
};

/// One DOM node in flat storage.
pub const Node = struct {
    kind: NodeKind,
    parent: ?NodeId = null,
    first_child: ?NodeId = null,
    last_child: ?NodeId = null,
    next_sibling: ?NodeId = null,
    prev_sibling: ?NodeId = null,
};

/// Node payloads kept intentionally small for the early renderer pipeline.
pub const NodeKind = union(enum) {
    document,
    element: Element,
    text: []const u8,
};

/// Element metadata needed by style matching and Box Tree construction.
pub const Element = struct {
    tag: Tag,
    name: []const u8,
    attributes: []const html.Attribute,
};

/// Known tags get enum values so later phases avoid string matching hot paths.
///
/// Unknown tags still stay in the DOM with their original name and can be styled
/// or rendered using fallback rules.
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
    a,
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

/// Builds a document tree from tokenizer output.
///
/// The parser is deliberately forgiving: it recovers from mismatched closes,
/// auto-closes a few common elements, and keeps still-open nodes in the tree.
pub const Parser = struct {
    /// Parses tokens into a flat DOM document that can outlive the token list.
    pub fn parse(allocator: std.mem.Allocator, source: []const u8, tokens: []const html.Token) !Document {
        var nodes = try std.ArrayList(Node).initCapacity(allocator, 0);
        {
            errdefer nodes.deinit(allocator);
            try nodes.append(allocator, .{ .kind = .document });
        }

        const owned_strings = std.ArrayList([]u8).initCapacity(allocator, 0) catch |err| {
            nodes.deinit(allocator);
            return err;
        };
        var document = Document{
            .source = source,
            .nodes = nodes,
            .owned_strings = owned_strings,
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
                        const parent = stack.items[stack.items.len - 1];
                        const node_text = if (isRawTextParent(&document, parent))
                            text
                        else
                            try decodeAndOwn(&document, allocator, text);
                        _ = try document.appendNode(allocator, .{ .text = node_text }, parent);
                    }
                },
                .tag_open => |open_tag| {
                    const tag = tagFromName(open_tag.name);
                    closeImpliedElements(&document, &stack, tag);

                    const attributes = try copyAttributes(&document, allocator, open_tag.attributes);
                    const node_id = document.appendNode(
                        allocator,
                        .{ .element = .{
                            .tag = tag,
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

    /// Copies only the attribute slice, not the borrowed attribute strings.
    ///
    /// This lets tokenizer tokens be freed immediately after parsing while DOM
    /// elements still expose their attributes.
    fn copyAttributes(document: *Document, allocator: std.mem.Allocator, attributes: []const html.Attribute) ![]const html.Attribute {
        if (attributes.len == 0) return &.{};

        const copied = try allocator.alloc(html.Attribute, attributes.len);
        errdefer allocator.free(copied);
        @memcpy(copied, attributes);
        for (copied) |*attribute| {
            if (attribute.value) |value| attribute.value = try decodeAndOwn(document, allocator, value);
        }
        return copied;
    }

    fn decodeAndOwn(document: *Document, allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
        const decoded = try decodeCharacterReferences(allocator, value) orelse return value;
        errdefer allocator.free(decoded);
        try document.owned_strings.append(allocator, decoded);
        return decoded;
    }

    /// Recovers from mismatched close tags by popping back to the first matching
    /// open element, ignoring unmatched closes.
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

    /// Handles a small set of HTML implied-end-tag rules that matter for layout.
    ///
    /// This is not a full HTML5 tree builder; it covers common paragraphs, lists,
    /// and table rows/cells so downstream layout sees a sane tree.
    fn closeImpliedElements(document: *const Document, stack: *std.ArrayList(NodeId), incoming_tag: Tag) void {
        switch (incoming_tag) {
            .p, .li => popCurrentIf(document, stack, incoming_tag),
            .tr => {
                popCurrentIf(document, stack, .td);
                popCurrentIf(document, stack, .th);
                popCurrentIf(document, stack, .tr);
            },
            .td, .th => {
                popCurrentIf(document, stack, .td);
                popCurrentIf(document, stack, .th);
            },
            else => {},
        }
    }

    /// Pops only the current stack item, preserving the parser's tolerant shape.
    fn popCurrentIf(document: *const Document, stack: *std.ArrayList(NodeId), tag: Tag) void {
        if (stack.items.len <= 1) return;

        const node_id = stack.items[stack.items.len - 1];
        switch (document.nodes.items[node_id].kind) {
            .element => |element| {
                if (element.tag == tag) {
                    stack.shrinkRetainingCapacity(stack.items.len - 1);
                }
            },
            else => {},
        }
    }
};

fn isRawTextParent(document: *const Document, node_id: NodeId) bool {
    return switch (document.nodes.items[node_id].kind) {
        .element => |element| std.ascii.eqlIgnoreCase(element.name, "style") or
            std.ascii.eqlIgnoreCase(element.name, "script"),
        else => false,
    };
}

/// Decodes the character references commonly used in report templates plus
/// decimal and hexadecimal numeric references. Unknown names remain literal.
fn decodeCharacterReferences(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, value, '&') == null) return null;

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    var changed = false;
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] != '&') {
            try output.writer.writeByte(value[index]);
            index += 1;
            continue;
        }

        const search_end = @min(index + 34, value.len);
        const relative_end = std.mem.indexOfScalar(u8, value[index + 1 .. search_end], ';') orelse {
            try output.writer.writeByte('&');
            index += 1;
            continue;
        };
        const semicolon = index + 1 + relative_end;
        const body = value[index + 1 .. semicolon];
        const codepoint = parseCharacterReference(body) orelse {
            try output.writer.writeByte('&');
            index += 1;
            continue;
        };
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch {
            _ = try std.unicode.utf8Encode(0xFFFD, &encoded);
            try output.writer.writeAll(encoded[0..3]);
            index = semicolon + 1;
            changed = true;
            continue;
        };
        try output.writer.writeAll(encoded[0..length]);
        index = semicolon + 1;
        changed = true;
    }

    if (!changed) {
        output.deinit();
        return null;
    }
    return @as(?[]u8, try output.toOwnedSlice());
}

fn parseCharacterReference(body: []const u8) ?u21 {
    if (std.mem.eql(u8, body, "amp")) return '&';
    if (std.mem.eql(u8, body, "lt")) return '<';
    if (std.mem.eql(u8, body, "gt")) return '>';
    if (std.mem.eql(u8, body, "quot")) return '"';
    if (std.mem.eql(u8, body, "apos")) return '\'';
    if (std.mem.eql(u8, body, "nbsp")) return 0x00A0;
    if (std.mem.eql(u8, body, "copy")) return 0x00A9;
    if (std.mem.eql(u8, body, "reg")) return 0x00AE;
    if (std.mem.eql(u8, body, "trade")) return 0x2122;
    if (std.mem.eql(u8, body, "euro")) return 0x20AC;
    if (std.mem.eql(u8, body, "pound")) return 0x00A3;
    if (std.mem.eql(u8, body, "yen")) return 0x00A5;
    if (std.mem.eql(u8, body, "cent")) return 0x00A2;
    if (std.mem.eql(u8, body, "deg")) return 0x00B0;
    if (std.mem.eql(u8, body, "ndash")) return 0x2013;
    if (std.mem.eql(u8, body, "mdash")) return 0x2014;
    if (std.mem.eql(u8, body, "hellip")) return 0x2026;
    if (std.mem.eql(u8, body, "bull")) return 0x2022;
    if (std.mem.eql(u8, body, "middot")) return 0x00B7;
    if (std.mem.eql(u8, body, "laquo")) return 0x00AB;
    if (std.mem.eql(u8, body, "raquo")) return 0x00BB;
    if (body.len < 2 or body[0] != '#') return null;

    const hexadecimal = body[1] == 'x' or body[1] == 'X';
    const digits = if (hexadecimal) body[2..] else body[1..];
    if (digits.len == 0) return null;
    const parsed = std.fmt.parseInt(u32, digits, if (hexadecimal) 16 else 10) catch return null;
    if (parsed == 0 or parsed > 0x10FFFF or (parsed >= 0xD800 and parsed <= 0xDFFF)) return 0xFFFD;
    return @intCast(parsed);
}

/// Maps known tag names to enum values without losing unknown tag names.
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
    if (eqlTag(name, "a")) return .a;
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

/// Void elements never push onto the open-element stack.
///
/// The tokenizer may not mark real-world void tags as self-closing, so the DOM
/// parser keeps the HTML void-element rule here.
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

/// Centralizes tag-name comparison so case-insensitive HTML matching stays
/// consistent across parser helpers.
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

test "decode named and numeric character references in text and attributes" {
    const allocator = std.testing.allocator;
    const source = "<p title=\"Tom &amp; Jerry\">A &lt; B &amp;&amp; C &#x20AC; &#233; &nbsp; end</p>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const paragraph_id = document.nodes.items[document.root].first_child.?;
    const paragraph = document.nodes.items[paragraph_id].kind.element;
    try std.testing.expectEqualStrings("Tom & Jerry", paragraph.attributes[0].value.?);
    try expectText(&document, document.nodes.items[paragraph_id].first_child.?, "A < B && C € é \xC2\xA0 end");
}

test "preserve character references inside raw style text" {
    const allocator = std.testing.allocator;
    const source = "<style>.x::before { content: '&amp;'; }</style>";
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const style_id = document.nodes.items[document.root].first_child.?;
    try expectText(&document, document.nodes.items[style_id].first_child.?, ".x::before { content: '&amp;'; }");
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

test "auto-close paragraphs when another paragraph starts" {
    const allocator = std.testing.allocator;
    const source = "<div><p>one<p>two</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try document.dump(&writer);

    const expected =
        \\#document
        \\  div
        \\    p
        \\      #text "one"
        \\    p
        \\      #text "two"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "auto-close list items when another item starts" {
    const allocator = std.testing.allocator;
    const source = "<ul><li>one<li>two</ul>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try document.dump(&writer);

    const expected =
        \\#document
        \\  ul
        \\    li
        \\      #text "one"
        \\    li
        \\      #text "two"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "auto-close table cells and rows" {
    const allocator = std.testing.allocator;
    const source = "<table><tr><td>a<td>b<tr><th>h</table>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try document.dump(&writer);

    const expected =
        \\#document
        \\  table
        \\    tr
        \\      td
        \\        #text "a"
        \\      td
        \\        #text "b"
        \\    tr
        \\      th
        \\        #text "h"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
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
    const source = "<style>body > p { color: red; }.x::before { content: \"<\"; }</style><div class=\"x\"><p>Hello <strong>world</strong></p><br><img src=\"x.png\"></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try document.dump(&writer);

    std.debug.print("\n{s}", .{writer.buffered()});
}
