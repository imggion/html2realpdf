//! Box Tree construction for the rendering pipeline.
//!
//! The tree is intentionally stored flat, like `dom.Document`: IDs are cheap to
//! copy, stable enough for sibling links, and avoid recursive ownership problems
//! while `ArrayList` grows.

const std = @import("std");
const dom = @import("dom.zig");
const html = @import("html.zig");

/// Stable index into `BoxTree.boxes`.
///
/// A Box Tree is rewritten during anonymous-box normalization, so links use IDs
/// instead of pointers or child arrays owned by each box.
pub const BoxId = usize;

/// The formatting role a box plays before layout assigns geometry.
///
/// `anonymousBlock` exists because CSS block containers cannot freely mix block
/// children with inline runs. `replaced` keeps intrinsic dimensions near the
/// DOM node that owns them. `lineBreak` gives `<br>` a visible layout signal.
pub const BoxType = enum {
    block,
    inlineBox,
    text,
    anonymousBlock,
    anonymousInline,
    replaced,
    lineBreak,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .block => "block",
            .inlineBox => "inline",
            .text => "text",
            .anonymousBlock => "anonymous-block",
            .anonymousInline => "anonymous-inline",
            .replaced => "replaced",
            .lineBreak => "line-break",
        };
    }
};

/// The display values this first Box Tree builder needs to decide box creation.
///
/// Richer CSS display modes should only be added when the layout stage can make
/// a useful distinction between them.
pub const Display = enum {
    none,
    block,
    inlineBox,
    inlineBlock,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .block => "block",
            .inlineBox => "inline",
            .inlineBlock => "inline-block",
        };
    }
};

/// Position participates in Box Tree construction only as an early layout flag.
pub const Position = enum {
    static,
    relative,
    absolute,
    fixed,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .static => "static",
            .relative => "relative",
            .absolute => "absolute",
            .fixed => "fixed",
        };
    }
};

/// Float is tracked here so block layout can later remove it from normal flow.
pub const Float = enum {
    none,
    left,
    right,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .none => "none",
            .left => "left",
            .right => "right",
        };
    }
};

/// Text whitespace mode needed before line breaking can make final decisions.
pub const WhiteSpace = enum {
    normal,
    nowrap,
    pre,
    preWrap,
    preLine,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .normal => "normal",
            .nowrap => "nowrap",
            .pre => "pre",
            .preWrap => "pre-wrap",
            .preLine => "pre-line",
        };
    }
};

/// CSS property names used by debug output and future style parsing.
pub const StyleProperty = enum {
    fontSize,
    fontFamily,
    color,
    background,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .fontSize => "font-size",
            .fontFamily => "font-family",
            .color => "color",
            .background => "background",
        };
    }
};

/// Logical box-model edges in CSS order.
pub const EdgeSizes = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

/// Style data resolved enough for Box Tree construction.
///
/// This is not the CSS parser format. The builder only needs properties that
/// decide whether a box exists, which kind it is, and which flags/layout inputs
/// must survive into later phases.
pub const Style = struct {
    display: Display = .inlineBox,
    position: Position = .static,
    float_direction: Float = .none,
    white_space: WhiteSpace = .normal,

    font_size: f32 = 16,
    font_family: []const u8 = "serif",
    color: []const u8 = "black",
    background: ?[]const u8 = null,

    margin: EdgeSizes = .{},
    border: EdgeSizes = .{},
    padding: EdgeSizes = .{},
};

/// Renderable unit produced from the DOM.
///
/// Geometry starts nullable because this phase describes structure, not layout.
/// The original `dom.NodeId` is kept for text, attributes, and debugging; boxes
/// created by normalization have no DOM node.
pub const Box = struct {
    kind: BoxType,
    node: ?dom.NodeId = null,

    parent: ?BoxId = null,
    first_child: ?BoxId = null,
    last_child: ?BoxId = null,
    next_sibling: ?BoxId = null,
    prev_sibling: ?BoxId = null,

    content_width: ?f32 = null,
    content_height: ?f32 = null,
    x: f32 = 0,
    y: f32 = 0,

    margin: EdgeSizes = .{},
    border: EdgeSizes = .{},
    padding: EdgeSizes = .{},

    style: Style = .{},
    text: ?[]const u8 = null,

    intrinsic_width: ?f32 = null,
    intrinsic_height: ?f32 = null,
    intrinsic_ratio: ?f32 = null,

    is_floating: bool = false,
    is_positioned: bool = false,
    is_out_of_flow: bool = false,
};

/// Owns all boxes for one rendered subtree.
///
/// The caller owns the allocator lifetime. Text slices and DOM references point
/// back into the parsed document, so the document must outlive the tree.
pub const BoxTree = struct {
    boxes: std.ArrayList(Box),
    root: BoxId,

    /// Releases only Box Tree storage; DOM source slices are owned elsewhere.
    pub fn deinit(self: *BoxTree, allocator: std.mem.Allocator) void {
        self.boxes.deinit(allocator);
    }

    /// Compact structural dump for tests that should not care about style noise.
    pub fn dump(self: *const BoxTree, document: *const dom.Document, writer: *std.Io.Writer) !void {
        try dumpBox(self, document, self.root, 0, writer);
    }

    /// Debug dump for inspecting which style inputs reached each box.
    pub fn dumpWithStyles(self: *const BoxTree, document: *const dom.Document, writer: *std.Io.Writer) !void {
        try dumpBoxWithStyles(self, document, self.root, 0, writer);
    }
};

/// Errors that describe a structurally impossible Box Tree result.
pub const BuildError = error{
    RootDoesNotGenerateBox,
};

/// Converts a DOM subtree into the intermediate tree consumed by layout.
pub const Builder = struct {
    /// Builds raw boxes, then normalizes anonymous block boxes.
    ///
    /// `styles` is indexed by `dom.NodeId`. Missing entries fall back to
    /// `defaultStyleForNode`, which keeps this module usable before a real CSS
    /// cascade module is wired in.
    pub fn build(
        allocator: std.mem.Allocator,
        document: *const dom.Document,
        styles: []const Style,
        root_node: dom.NodeId,
    ) !BoxTree {
        var state = BuildState{
            .allocator = allocator,
            .document = document,
            .styles = styles,
            .boxes = try std.ArrayList(Box).initCapacity(allocator, 0),
        };
        errdefer state.boxes.deinit(allocator);

        const root = (try state.buildNode(root_node, null)) orelse return BuildError.RootDoesNotGenerateBox;

        var tree = BoxTree{
            .boxes = state.boxes,
            .root = root,
        };
        errdefer tree.deinit(allocator);

        try normalizeAnonymousBlocks(&tree, allocator, tree.root);
        return tree;
    }
};

/// Mutable state for a single build call.
///
/// Keeping it private lets `Builder.build` expose a small API while the recursive
/// walk can still share allocator, DOM, styles, and partially built boxes.
const BuildState = struct {
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    styles: []const Style,
    boxes: std.ArrayList(Box),

    /// Walks DOM nodes and emits the raw box tree before CSS anonymous boxes.
    ///
    /// The DOM document node becomes an anonymous block so callers can build from
    /// either a document root or a concrete renderable element.
    fn buildNode(self: *BuildState, node_id: dom.NodeId, parent_box: ?BoxId) !?BoxId {
        const node = self.document.nodes.items[node_id];

        switch (node.kind) {
            .document => {
                const root_box = try self.appendBox(.{
                    .kind = .anonymousBlock,
                    .style = defaultStyleForNode(self.document, node_id),
                }, parent_box);

                var child = node.first_child;
                while (child) |child_id| {
                    _ = try self.buildNode(child_id, root_box);
                    child = self.document.nodes.items[child_id].next_sibling;
                }

                return root_box;
            },
            .text => |text| return try self.buildTextBox(node_id, text, parent_box),
            .element => |element| {
                if (isNonRenderingElement(element.name)) return null;

                const style = self.styleForNode(node_id);
                if (style.display == .none) return null;

                if (element.tag == .br) {
                    return try self.appendBox(.{
                        .kind = .lineBreak,
                        .node = node_id,
                        .style = style,
                    }, parent_box);
                }

                var box = Box{
                    .kind = boxTypeForElement(element, style),
                    .node = node_id,
                    .style = style,
                    .margin = style.margin,
                    .border = style.border,
                    .padding = style.padding,
                    .is_floating = style.float_direction != .none,
                    .is_positioned = style.position != .static,
                    .is_out_of_flow = style.position == .absolute or style.position == .fixed,
                };

                if (box.kind == .replaced) {
                    fillIntrinsicSize(&box, element);
                }

                const box_id = try self.appendBox(box, parent_box);

                var child = node.first_child;
                while (child) |child_id| {
                    _ = try self.buildNode(child_id, box_id);
                    child = self.document.nodes.items[child_id].next_sibling;
                }

                return box_id;
            },
        }
    }

    /// Text boxes inherit text-facing style but stay inline participants.
    ///
    /// Inheriting `display` or box-model edges from a block parent would turn text
    /// into block layout input, which is not how CSS inline content behaves.
    fn buildTextBox(self: *BuildState, node_id: dom.NodeId, text: []const u8, parent_box: ?BoxId) !?BoxId {
        const style = self.inheritedTextStyle(parent_box);

        if (collapsesWhitespace(style.white_space) and isOnlyHtmlWhitespace(text)) {
            return null;
        }

        return try self.appendBox(.{
            .kind = .text,
            .node = node_id,
            .style = style,
            .text = text,
        }, parent_box);
    }

    /// Accepts sparse style arrays while CSS cascade is still a separate concern.
    fn styleForNode(self: *const BuildState, node_id: dom.NodeId) Style {
        if (node_id < self.styles.len) return self.styles[node_id];
        return defaultStyleForNode(self.document, node_id);
    }

    /// Preserves inherited typography and whitespace without copying layout-only
    /// properties that belong to the parent element's own box.
    fn inheritedTextStyle(self: *const BuildState, parent_box: ?BoxId) Style {
        var style: Style = if (parent_box) |box_id| self.boxes.items[box_id].style else .{};

        style.display = .inlineBox;
        style.position = .static;
        style.float_direction = .none;
        style.background = null;
        style.margin = .{};
        style.border = .{};
        style.padding = .{};

        return style;
    }

    /// Appends a box and wires sibling links immediately.
    ///
    /// All tree rewrites later reuse the same link shape, so there is one boring
    /// place responsible for parent/child bookkeeping during initial construction.
    fn appendBox(self: *BuildState, box: Box, parent_box: ?BoxId) !BoxId {
        const box_id = self.boxes.items.len;
        var next_box = box;
        next_box.parent = parent_box;
        try self.boxes.append(self.allocator, next_box);

        if (parent_box) |parent_id| {
            appendExistingChild(&self.boxes, parent_id, box_id);
        }

        return box_id;
    }
};

/// Temporary UA-style fallback used until CSS cascade produces every `Style`.
///
/// Keeping this here makes Box Tree tests independent from the future CSS parser
/// while still preserving the browser-default block/inline split.
pub fn defaultStyleForNode(document: *const dom.Document, node_id: dom.NodeId) Style {
    const node = document.nodes.items[node_id];

    return switch (node.kind) {
        .document => .{ .display = .block },
        .text => .{ .display = .inlineBox },
        .element => |element| .{
            .display = if (isNonRenderingElement(element.name))
                .none
            else if (isDefaultBlockElement(element))
                .block
            else
                .inlineBox,
        },
    };
}

/// Moves an already allocated box under a parent.
///
/// Normalization reuses boxes instead of cloning them, preserving `BoxId` values
/// that tests or later phases may already hold.
fn appendExistingChild(boxes: *std.ArrayList(Box), parent_id: BoxId, child_id: BoxId) void {
    const last_child = boxes.items[parent_id].last_child;

    boxes.items[child_id].parent = parent_id;
    boxes.items[child_id].prev_sibling = last_child;
    boxes.items[child_id].next_sibling = null;

    if (last_child) |last_child_id| {
        boxes.items[last_child_id].next_sibling = child_id;
    } else {
        boxes.items[parent_id].first_child = child_id;
    }

    boxes.items[parent_id].last_child = child_id;
}

/// Allocates boxes introduced by normalization, not by DOM nodes.
fn appendDetachedBox(tree: *BoxTree, allocator: std.mem.Allocator, box: Box) !BoxId {
    const box_id = tree.boxes.items.len;
    try tree.boxes.append(allocator, box);
    return box_id;
}

/// Runs after raw construction so DOM walking stays simple.
///
/// This pass is where CSS structural rules reshape the tree without mixing those
/// rules into tag handling or text handling.
fn normalizeAnonymousBlocks(tree: *BoxTree, allocator: std.mem.Allocator, box_id: BoxId) !void {
    var child = tree.boxes.items[box_id].first_child;
    while (child) |child_id| {
        const next = tree.boxes.items[child_id].next_sibling;
        try normalizeAnonymousBlocks(tree, allocator, child_id);
        child = next;
    }

    if (!isBlockContainer(tree.boxes.items[box_id].kind)) return;
    try wrapInlineRuns(tree, allocator, box_id);
}

/// Wraps consecutive inline participants when they share a block container with
/// real block children.
///
/// Pure-inline containers are left alone; wrapping them early would create extra
/// boxes the inline layout stage does not need.
fn wrapInlineRuns(tree: *BoxTree, allocator: std.mem.Allocator, parent_id: BoxId) !void {
    var has_inline = false;
    var has_block = false;

    var child = tree.boxes.items[parent_id].first_child;
    while (child) |child_id| {
        if (isInlineLevelBox(tree.boxes.items[child_id])) {
            has_inline = true;
        } else {
            has_block = true;
        }
        child = tree.boxes.items[child_id].next_sibling;
    }

    if (!has_inline or !has_block) return;

    const old_first = tree.boxes.items[parent_id].first_child;
    var new_first: ?BoxId = null;
    var new_last: ?BoxId = null;
    var current_run: ?BoxId = null;

    tree.boxes.items[parent_id].first_child = null;
    tree.boxes.items[parent_id].last_child = null;

    child = old_first;
    while (child) |child_id| {
        const next = tree.boxes.items[child_id].next_sibling;

        if (isInlineLevelBox(tree.boxes.items[child_id])) {
            if (current_run == null) {
                const anonymous_id = try appendDetachedBox(tree, allocator, .{
                    .kind = .anonymousBlock,
                    .style = tree.boxes.items[parent_id].style,
                });
                appendToRebuiltChildList(tree, parent_id, anonymous_id, &new_first, &new_last);
                current_run = anonymous_id;
            }

            appendExistingChild(&tree.boxes, current_run.?, child_id);
        } else {
            current_run = null;
            appendToRebuiltChildList(tree, parent_id, child_id, &new_first, &new_last);
        }

        child = next;
    }

    tree.boxes.items[parent_id].first_child = new_first;
    tree.boxes.items[parent_id].last_child = new_last;
}

/// Rebuilds one parent's child list without reallocating existing boxes.
fn appendToRebuiltChildList(
    tree: *BoxTree,
    parent_id: BoxId,
    child_id: BoxId,
    first_child: *?BoxId,
    last_child: *?BoxId,
) void {
    tree.boxes.items[child_id].parent = parent_id;
    tree.boxes.items[child_id].prev_sibling = last_child.*;
    tree.boxes.items[child_id].next_sibling = null;

    if (last_child.*) |last_child_id| {
        tree.boxes.items[last_child_id].next_sibling = child_id;
    } else {
        first_child.* = child_id;
    }

    last_child.* = child_id;
}

fn isBlockContainer(kind: BoxType) bool {
    return kind == .block or kind == .anonymousBlock;
}

/// Classifies the external formatting role used by anonymous-box normalization.
fn isInlineLevelBox(box: Box) bool {
    return switch (box.kind) {
        .inlineBox, .text, .anonymousInline, .lineBreak => true,
        .replaced => box.style.display != .block,
        else => false,
    };
}

/// Maps style display and replaced-element status to the initial box kind.
fn boxTypeForElement(element: dom.Element, style: Style) BoxType {
    if (isReplacedElement(element.tag)) return .replaced;

    return switch (style.display) {
        .block => .block,
        .inlineBox => .inlineBox,
        .inlineBlock => .inlineBox,
        .none => unreachable,
    };
}

fn isReplacedElement(tag: dom.Tag) bool {
    return switch (tag) {
        .img => true,
        else => false,
    };
}

/// Small UA-style default list used only as a fallback before CSS exists.
fn isDefaultBlockElement(element: dom.Element) bool {
    return switch (element.tag) {
        .h1,
        .h2,
        .h3,
        .h4,
        .h5,
        .h6,
        .p,
        .div,
        .ul,
        .ol,
        .li,
        .table,
        .tr,
        .td,
        .th,
        .html,
        .body,
        => true,
        else => isDefaultBlockElementName(element.name),
    };
}

fn isDefaultBlockElementName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "article") or
        std.ascii.eqlIgnoreCase(name, "aside") or
        std.ascii.eqlIgnoreCase(name, "footer") or
        std.ascii.eqlIgnoreCase(name, "header") or
        std.ascii.eqlIgnoreCase(name, "main") or
        std.ascii.eqlIgnoreCase(name, "nav") or
        std.ascii.eqlIgnoreCase(name, "section");
}

/// Elements whose contents are parser data or metadata, not PDF layout input.
fn isNonRenderingElement(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "head") or
        std.ascii.eqlIgnoreCase(name, "style") or
        std.ascii.eqlIgnoreCase(name, "script") or
        std.ascii.eqlIgnoreCase(name, "title") or
        std.ascii.eqlIgnoreCase(name, "meta") or
        std.ascii.eqlIgnoreCase(name, "link");
}

/// Captures cheap intrinsic data available from attributes.
///
/// Reading actual image headers belongs in a later resource loader; the Box Tree
/// should not perform filesystem or network work.
fn fillIntrinsicSize(box: *Box, element: dom.Element) void {
    box.intrinsic_width = parsePositiveFloat(attributeValue(element.attributes, "width"));
    box.intrinsic_height = parsePositiveFloat(attributeValue(element.attributes, "height"));

    if (box.intrinsic_width) |width| {
        if (box.intrinsic_height) |height| {
            if (height > 0) box.intrinsic_ratio = width / height;
        }
    }
}

fn attributeValue(attributes: []const html.Attribute, name: []const u8) ?[]const u8 {
    for (attributes) |attribute| {
        if (std.ascii.eqlIgnoreCase(attribute.name, name)) return attribute.value;
    }

    return null;
}

fn parsePositiveFloat(value: ?[]const u8) ?f32 {
    const text = value orelse return null;
    const parsed = std.fmt.parseFloat(f32, text) catch return null;
    if (parsed <= 0) return null;
    return parsed;
}

fn collapsesWhitespace(white_space: WhiteSpace) bool {
    return white_space == .normal or white_space == .nowrap or white_space == .preLine;
}

fn isOnlyHtmlWhitespace(text: []const u8) bool {
    for (text) |c| {
        if (!(c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C)) return false;
    }

    return true;
}

fn dumpBox(tree: *const BoxTree, document: *const dom.Document, box_id: BoxId, depth: usize, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }

    const box = tree.boxes.items[box_id];
    try writeBoxLabel(box, document, writer);
    try writer.writeAll("\n");

    var child = box.first_child;
    while (child) |child_id| {
        try dumpBox(tree, document, child_id, depth + 1, writer);
        child = tree.boxes.items[child_id].next_sibling;
    }
}

/// Verbose dump used when inspecting style propagation and layout flags.
fn dumpBoxWithStyles(tree: *const BoxTree, document: *const dom.Document, box_id: BoxId, depth: usize, writer: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.writeAll("  ");
    }

    const box = tree.boxes.items[box_id];
    try writeBoxLabel(box, document, writer);
    try writeBoxStyleDebug(box, writer);
    try writer.writeAll("\n");

    var child = box.first_child;
    while (child) |child_id| {
        try dumpBoxWithStyles(tree, document, child_id, depth + 1, writer);
        child = tree.boxes.items[child_id].next_sibling;
    }
}

fn writeBoxLabel(box: Box, document: *const dom.Document, writer: *std.Io.Writer) !void {
    try writer.writeAll(box.kind.toString());

    if (box.node) |node_id| {
        switch (document.nodes.items[node_id].kind) {
            .element => |element| try writer.print(" {s}", .{element.name}),
            .text => |text| try writer.print(" \"{s}\"", .{text}),
            .document => {},
        }
    }
}

/// Keeps debug output compact by printing only layout-relevant style state.
fn writeBoxStyleDebug(box: Box, writer: *std.Io.Writer) !void {
    const style = box.style;

    try writer.print(
        " [display={s} position={s} float={s} white-space={s} font-size={d:.2} font-family=\"{s}\" color={s}",
        .{
            style.display.toString(),
            style.position.toString(),
            style.float_direction.toString(),
            style.white_space.toString(),
            style.font_size,
            style.font_family,
            style.color,
        },
    );

    if (style.background) |background| {
        try writer.print(" background={s}", .{background});
    }

    try writeEdgeDebug("margin", box.margin, writer);
    try writeEdgeDebug("border", box.border, writer);
    try writeEdgeDebug("padding", box.padding, writer);

    if (box.is_out_of_flow) try writer.writeAll(" out-of-flow=true");
    if (box.is_positioned) try writer.writeAll(" positioned=true");
    if (box.is_floating) try writer.writeAll(" floating=true");

    if (box.intrinsic_width != null or box.intrinsic_height != null) {
        try writer.writeAll(" intrinsic=");
        if (box.intrinsic_width) |width| {
            try writer.print("{d:.2}", .{width});
        } else {
            try writer.writeAll("auto");
        }

        try writer.writeAll("x");

        if (box.intrinsic_height) |height| {
            try writer.print("{d:.2}", .{height});
        } else {
            try writer.writeAll("auto");
        }
    }

    if (box.intrinsic_ratio) |ratio| {
        try writer.print(" ratio={d:.2}", .{ratio});
    }

    try writer.writeAll("]");
}

fn writeEdgeDebug(name: []const u8, edge: EdgeSizes, writer: *std.Io.Writer) !void {
    if (edgeIsZero(edge)) return;

    try writer.print(
        " {s}={d:.2},{d:.2},{d:.2},{d:.2}",
        .{ name, edge.top, edge.right, edge.bottom, edge.left },
    );
}

fn edgeIsZero(edge: EdgeSizes) bool {
    return edge.top == 0 and edge.right == 0 and edge.bottom == 0 and edge.left == 0;
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

test "build block and inline boxes from DOM" {
    const allocator = std.testing.allocator;
    const source = "<div><p>Hello <strong>world</strong></p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, div_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\block div
        \\  block p
        \\    text "Hello "
        \\    inline strong
        \\      text "world"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "wrap mixed block and inline children in anonymous blocks" {
    const allocator = std.testing.allocator;
    const source = "<div>before<p>block</p><span>after</span></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, div_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\block div
        \\  anonymous-block
        \\    text "before"
        \\  block p
        \\    text "block"
        \\  anonymous-block
        \\    inline span
        \\      text "after"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "create line break and replaced boxes" {
    const allocator = std.testing.allocator;
    const source = "<div>a<br><img width=100 height=50>b</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    var tree = try Builder.build(allocator, &document, &.{}, div_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\block div
        \\  text "a"
        \\  line-break br
        \\  replaced img
        \\  text "b"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());

    const a_id = tree.boxes.items[tree.root].first_child.?;
    const br_id = tree.boxes.items[a_id].next_sibling.?;
    const img_id = tree.boxes.items[br_id].next_sibling.?;
    try std.testing.expectEqual(BoxType.lineBreak, tree.boxes.items[br_id].kind);
    try std.testing.expectEqual(BoxType.replaced, tree.boxes.items[img_id].kind);
    try std.testing.expectEqual(@as(?f32, 100), tree.boxes.items[img_id].intrinsic_width);
    try std.testing.expectEqual(@as(?f32, 50), tree.boxes.items[img_id].intrinsic_height);
    try std.testing.expectEqual(@as(?f32, 2), tree.boxes.items[img_id].intrinsic_ratio);
}

test "skip display none subtree" {
    const allocator = std.testing.allocator;
    const source = "<div><p>gone</p><span>kept</span></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[div_id].first_child.?;

    var styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (styles, 0..) |*style, node_id| {
        style.* = defaultStyleForNode(&document, node_id);
    }
    styles[p_id].display = .none;

    var tree = try Builder.build(allocator, &document, styles, div_id);
    defer tree.deinit(allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dump(&document, &writer);

    const expected =
        \\block div
        \\  inline span
        \\    text "kept"
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "dump Box Tree with styles" {
    const allocator = std.testing.allocator;
    const source = "<div><p>x</p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[div_id].first_child.?;

    var styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (styles, 0..) |*style, node_id| {
        style.* = defaultStyleForNode(&document, node_id);
    }
    styles[p_id].font_size = 18.5;
    styles[p_id].color = "red";
    styles[p_id].margin.top = 4;

    var tree = try Builder.build(allocator, &document, styles, div_id);
    defer tree.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dumpWithStyles(&document, &writer);

    const dumped = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, dumped, "block p [display=block") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "font-size=18.50") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "color=red") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "margin=4.00,0.00,0.00,0.00") != null);
}

test "debug dump Box Tree" {
    if (!std.testing.environ.containsUnemptyConstant("HTML2REALPDF_DEBUG_BOX")) return;

    const allocator = std.testing.allocator;
    const source = "<div>a<br><img width=100 height=50><p>Hello <strong>world</strong></p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[div_id].last_child.?;
    const hello_id = document.nodes.items[p_id].first_child.?;
    const strong_id = document.nodes.items[hello_id].next_sibling.?;

    var styles = try allocator.alloc(Style, document.nodes.items.len);
    defer allocator.free(styles);
    for (styles, 0..) |*style, node_id| {
        style.* = defaultStyleForNode(&document, node_id);
    }
    styles[p_id].font_size = 18;
    styles[p_id].color = "red";
    styles[p_id].margin.top = 12;
    styles[strong_id].font_size = 18;
    styles[strong_id].color = "blue";
    styles[strong_id].background = "#eeeeee";

    var tree = try Builder.build(allocator, &document, styles, div_id);
    defer tree.deinit(allocator);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try tree.dumpWithStyles(&document, &writer);

    std.debug.print("\n{s}", .{writer.buffered()});
}
