//! Stable CSS facade for parser, selectors, cascade, values, and computed style.
//!
//! The public API remains source-compatible while phase ownership lives in
//! focused modules under src/css/.

const std = @import("std");
const dom = @import("dom.zig");
const box = @import("box.zig");
const html = @import("html.zig");

pub const syntax = @import("css/syntax.zig");
pub const selectors = @import("css/selectors.zig");
pub const values = @import("css/values.zig");
pub const expressions = @import("css/expressions.zig");
pub const variables = @import("css/variables.zig");
pub const shorthands = @import("css/shorthands.zig");
pub const computed = @import("css/computed.zig");
pub const cascade = @import("css/cascade.zig");
pub const properties = @import("css/properties.zig");

pub const Combinator = syntax.Combinator;
pub const SelectorTest = syntax.SelectorTest;
pub const SelectorPart = syntax.SelectorPart;
pub const Selector = syntax.Selector;
pub const Declaration = syntax.Declaration;
pub const Rule = syntax.Rule;
pub const Stylesheet = syntax.Stylesheet;
pub const Specificity = syntax.Specificity;

pub const parseStylesheet = syntax.parseStylesheet;
pub const matchesSelector = selectors.matchesSelector;
pub const selectorSpecificity = selectors.selectorSpecificity;
pub const compareSpecificity = selectors.compareSpecificity;
pub const computeStyles = cascade.computeStyles;
pub const computeStylesWithContext = cascade.computeStylesWithContext;
pub const collectStyleText = cascade.collectStyleText;
pub const dumpCascade = cascade.dumpCascade;
pub const styleArrayFromDocument = cascade.styleArrayFromDocument;
pub const styleArrayFromDocumentWithContext = cascade.styleArrayFromDocumentWithContext;

const parseLength = values.parseLength;
const parseDimension = values.parseDimension;
const parseDisplay = values.parseDisplay;
const parseFontWeight = values.parseFontWeight;
const parseFontStyle = values.parseFontStyle;
const parseEdges = values.parseEdges;
const parseTextAlign = values.parseTextAlign;
const parseDirection = values.parseDirection;
const parseTextTransform = values.parseTextTransform;
const parseWordBreak = values.parseWordBreak;
const parseOverflowWrap = values.parseOverflowWrap;
const parseOverflow = values.parseOverflow;
const parseTextOverflow = values.parseTextOverflow;
const parseAspectRatio = values.parseAspectRatio;
const parseObjectFit = values.parseObjectFit;
const parseObjectPosition = values.parseObjectPosition;
const parseVerticalAlignKeyword = values.parseVerticalAlignKeyword;
const parseBoxSizing = values.parseBoxSizing;
const parseBorderCollapse = values.parseBorderCollapse;
const parsePageBreak = values.parsePageBreak;
const parseBorderStyle = values.parseBorderStyle;
const parsePositiveInteger = values.parsePositiveInteger;

fn deinitTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList(html.Token)) void {
    for (tokens.items) |token| {
        switch (token) {
            .tag_open => |open_tag| allocator.free(open_tag.attributes),
            else => {},
        }
    }
    tokens.deinit(allocator);
}

test "parse simple type selector rule" {
    const allocator = std.testing.allocator;
    const css = "p { color: red; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), ss.rules.len);
    try std.testing.expectEqual(@as(usize, 1), ss.rules[0].selectors.len);
    try std.testing.expectEqual(@as(usize, 1), ss.rules[0].selectors[0].parts.len);
    try std.testing.expectEqual(@as(usize, 1), ss.rules[0].selectors[0].parts[0].tests.len);
    try std.testing.expectEqualStrings("p", ss.rules[0].selectors[0].parts[0].tests[0].tag);

    try std.testing.expectEqual(@as(usize, 1), ss.rules[0].declarations.len);
    try std.testing.expectEqualStrings("color", ss.rules[0].declarations[0].name);
    try std.testing.expectEqualStrings("red", ss.rules[0].declarations[0].value);
}

test "parse compound selector with class and id" {
    const allocator = std.testing.allocator;
    const css = "div.foo#bar { color: red; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const parts = ss.rules[0].selectors[0].parts;
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    const tests = parts[0].tests;
    try std.testing.expectEqual(@as(usize, 3), tests.len);
    try std.testing.expectEqualStrings("div", tests[0].tag);
    try std.testing.expectEqualStrings("foo", tests[1].class);
    try std.testing.expectEqualStrings("bar", tests[2].id);
}

test "parse descendant combinator" {
    const allocator = std.testing.allocator;
    const css = "div p { color: red; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const parts = ss.rules[0].selectors[0].parts;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("div", parts[0].tests[0].tag);
    try std.testing.expectEqual(Combinator.descendant, parts[0].combinator.?);
    try std.testing.expectEqualStrings("p", parts[1].tests[0].tag);
    try std.testing.expectEqual(@as(?Combinator, null), parts[1].combinator);
}

test "parse child combinator" {
    const allocator = std.testing.allocator;
    const css = "div > p { color: red; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const parts = ss.rules[0].selectors[0].parts;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("div", parts[0].tests[0].tag);
    try std.testing.expectEqual(Combinator.child, parts[0].combinator.?);
    try std.testing.expectEqualStrings("p", parts[1].tests[0].tag);
}

test "parse multiple declarations" {
    const allocator = std.testing.allocator;
    const css = "h1 { color: red; font-size: 20px; margin: 10px 20px; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const decls = ss.rules[0].declarations;
    try std.testing.expectEqual(@as(usize, 3), decls.len);
    try std.testing.expectEqualStrings("color", decls[0].name);
    try std.testing.expectEqualStrings("red", decls[0].value);
    try std.testing.expectEqualStrings("font-size", decls[1].name);
    try std.testing.expectEqualStrings("20px", decls[1].value);
    try std.testing.expectEqualStrings("margin", decls[2].name);
    try std.testing.expectEqualStrings("10px 20px", decls[2].value);
}

test "parse and strip important declarations" {
    const allocator = std.testing.allocator;
    var stylesheet = try parseStylesheet(allocator, "p { color: red !important; width: 10px; }");
    defer stylesheet.deinit(allocator);
    try std.testing.expectEqualStrings("red", stylesheet.rules[0].declarations[0].value);
    try std.testing.expect(stylesheet.rules[0].declarations[0].important);
    try std.testing.expect(!stylesheet.rules[0].declarations[1].important);
}

test "parse comma-separated selectors" {
    const allocator = std.testing.allocator;
    const css = "h1, h2 { color: red; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), ss.rules[0].selectors.len);
    try std.testing.expectEqualStrings("h1", ss.rules[0].selectors[0].parts[0].tests[0].tag);
    try std.testing.expectEqualStrings("h2", ss.rules[0].selectors[1].parts[0].tests[0].tag);
}

test "skip at-rule" {
    const allocator = std.testing.allocator;
    const css = "@media screen { p { color: red; } } h1 { color: blue; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), ss.rules.len);
    try std.testing.expectEqualStrings("h1", ss.rules[0].selectors[0].parts[0].tests[0].tag);
}

test "skip unparseable pseudo-element and recover" {
    const allocator = std.testing.allocator;
    const css = "p { color: red; } .note::before { content: \"x\"; } div { color: blue; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), ss.rules.len);
    try std.testing.expectEqualStrings("p", ss.rules[0].selectors[0].parts[0].tests[0].tag);
    try std.testing.expectEqualStrings("div", ss.rules[1].selectors[0].parts[0].tests[0].tag);
}

test "cascade: skip style with pseudo-element" {
    const allocator = std.testing.allocator;
    const source = "<style>.note::before { content: \"x\"; } p { color: red; }</style><p>hello</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqualStrings("red", styles[p_id].color);
}

test "parse universal selector" {
    const allocator = std.testing.allocator;
    const css = "* { color: red; }";

    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const tests = ss.rules[0].selectors[0].parts[0].tests;
    try std.testing.expectEqual(@as(usize, 1), tests.len);
    try std.testing.expectEqual(SelectorTest.universal, tests[0]);
}

test "match type selector" {
    const allocator = std.testing.allocator;
    const source = "<p>hello</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css = "p { color: red; }";
    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const p_id = document.nodes.items[document.root].first_child.?;
    try std.testing.expect(matchesSelector(ss.rules[0].selectors[0], p_id, &document));
}

test "match class selector" {
    const allocator = std.testing.allocator;
    const source = "<p class=\"foo\">hello</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css = ".foo { color: red; }";
    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const p_id = document.nodes.items[document.root].first_child.?;
    try std.testing.expect(matchesSelector(ss.rules[0].selectors[0], p_id, &document));
}

test "match id selector" {
    const allocator = std.testing.allocator;
    const source = "<p id=\"intro\">hello</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css = "#intro { color: red; }";
    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const p_id = document.nodes.items[document.root].first_child.?;
    try std.testing.expect(matchesSelector(ss.rules[0].selectors[0], p_id, &document));
}

test "match descendant combinator" {
    const allocator = std.testing.allocator;
    const source = "<div><p>hello</p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css = "div p { color: red; }";
    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[div_id].first_child.?;
    try std.testing.expect(matchesSelector(ss.rules[0].selectors[0], p_id, &document));
}

test "match child combinator" {
    const allocator = std.testing.allocator;
    const source = "<div><p>hello</p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css = "div > p { color: red; }";
    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[div_id].first_child.?;
    try std.testing.expect(matchesSelector(ss.rules[0].selectors[0], p_id, &document));
}

test "child combinator does not match grandchild" {
    const allocator = std.testing.allocator;
    const source = "<div><span><p>hello</p></span></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css = "div > p { color: red; }";
    var ss = try parseStylesheet(allocator, css);
    defer ss.deinit(allocator);

    const div_id = document.nodes.items[document.root].first_child.?;
    const span_id = document.nodes.items[div_id].first_child.?;
    const p_id = document.nodes.items[span_id].first_child.?;
    try std.testing.expect(!matchesSelector(ss.rules[0].selectors[0], p_id, &document));
}

test "CSS escapes match identifiers and declaration names" {
    const allocator = std.testing.allocator;
    var fixture = try cascadeTestHelper(
        allocator,
        "<style>p.\\66 oo#\\62 ar, .\\31 23 { c\\6flor: rebeccapurple; }</style><p class='foo' id='bar'>escaped</p><div class='123'>digit</div>",
    );
    defer fixture.deinit(allocator);

    const style_id = fixture.document.nodes.items[fixture.document.root].first_child.?;
    const paragraph = fixture.document.nodes.items[style_id].next_sibling.?;
    const digit = fixture.document.nodes.items[paragraph].next_sibling.?;
    try std.testing.expectEqualStrings("rebeccapurple", fixture.styles[paragraph].color);
    try std.testing.expectEqualStrings("rebeccapurple", fixture.styles[digit].color);
}

test "specificity calculation" {
    const allocator = std.testing.allocator;

    const css1 = "#x .y z { color: red; }";
    var ss1 = try parseStylesheet(allocator, css1);
    defer ss1.deinit(allocator);
    const spec1 = selectorSpecificity(ss1.rules[0].selectors[0]);
    try std.testing.expectEqual(@as(u32, 1), spec1.id_count);
    try std.testing.expectEqual(@as(u32, 1), spec1.class_count);
    try std.testing.expectEqual(@as(u32, 1), spec1.type_count);

    const css2 = "div > p.foo#bar { color: red; }";
    var ss2 = try parseStylesheet(allocator, css2);
    defer ss2.deinit(allocator);
    const spec2 = selectorSpecificity(ss2.rules[0].selectors[0]);
    try std.testing.expectEqual(@as(u32, 1), spec2.id_count);
    try std.testing.expectEqual(@as(u32, 1), spec2.class_count);
    try std.testing.expectEqual(@as(u32, 2), spec2.type_count);
}

test "specificity comparison" {
    try std.testing.expectEqual(std.math.Order.gt, compareSpecificity(
        .{ .id_count = 1, .class_count = 0, .type_count = 0 },
        .{ .id_count = 0, .class_count = 5, .type_count = 5 },
    ));
    try std.testing.expectEqual(std.math.Order.gt, compareSpecificity(
        .{ .id_count = 0, .class_count = 1, .type_count = 0 },
        .{ .id_count = 0, .class_count = 0, .type_count = 5 },
    ));
}

test "cascade: element selector applies style" {
    const allocator = std.testing.allocator;
    const source = "<style>p { color: red; }</style><p>hello</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_id = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqualStrings("red", styles[p_id].color);
}

test "cascade: class selector overrides element selector" {
    const allocator = std.testing.allocator;
    const source = "<style>p { color: red; } .blue { color: blue; }</style><p class=\"blue\">hello</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[style_node].next_sibling.?;
    try std.testing.expectEqualStrings("blue", styles[p_id].color);
}

test "cascade: specificity wins over source order" {
    const allocator = std.testing.allocator;
    // .foo has (0,1,0), p.foo has (0,1,1), so p.foo wins even though it comes first
    const source = "<style>p.foo { color: blue; } .foo { color: red; }</style><p class=\"foo\">hello</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[style_node].next_sibling.?;
    try std.testing.expectEqualStrings("blue", styles[p_id].color);
}

test "cascade: source order tiebreaker" {
    const allocator = std.testing.allocator;
    const source = "<style>p { color: red; } p { color: blue; }</style><p>hello</p>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const p_id = document.nodes.items[style_node].next_sibling.?;
    try std.testing.expectEqualStrings("blue", styles[p_id].color);
}

test "cascade: property inheritance" {
    const allocator = std.testing.allocator;
    const source = "<style>body { color: red; }</style><body><p>hello</p></body>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const body_id = document.nodes.items[style_node].next_sibling.?;
    const p_id = document.nodes.items[body_id].first_child.?;
    try std.testing.expectEqualStrings("red", styles[body_id].color);
    try std.testing.expectEqualStrings("red", styles[p_id].color);
}

test "cascade: display property applied" {
    const allocator = std.testing.allocator;
    const source = "<style>span { display: block; }</style><span>hello</span>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const span_id = document.nodes.items[style_node].next_sibling.?;
    try std.testing.expectEqual(box.Display.block, styles[span_id].display);
}

test "cascade: background-color shorthand" {
    const allocator = std.testing.allocator;
    const source = "<style>div { background: #eee; }</style><div>hello</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const div_id = document.nodes.items[style_node].next_sibling.?;
    try std.testing.expectEqualStrings("#eee", styles[div_id].background.?);
}

test "cascade: margin shorthand edge parsing" {
    const allocator = std.testing.allocator;
    const source = "<style>div { margin: 10px; }</style><div>hello</div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const div_id = document.nodes.items[style_node].next_sibling.?;
    try std.testing.expectEqual(@as(f32, 10), styles[div_id].margin.top);
    try std.testing.expectEqual(@as(f32, 10), styles[div_id].margin.right);
    try std.testing.expectEqual(@as(f32, 10), styles[div_id].margin.bottom);
    try std.testing.expectEqual(@as(f32, 10), styles[div_id].margin.left);
}

test "cascade: combined selector descendant matches nested element" {
    const allocator = std.testing.allocator;
    const source = "<style>body > main .invoice-title { color: #1d4ed8; margin-bottom: 12px; }</style><body><main><h1 class=\"invoice-title\">hello</h1></main></body>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const body_id = document.nodes.items[style_node].next_sibling.?;
    const main_id = document.nodes.items[body_id].first_child.?;
    const h1_id = document.nodes.items[main_id].first_child.?;
    try std.testing.expectEqualStrings("#1d4ed8", styles[h1_id].color);
    try std.testing.expectEqual(@as(f32, 12), styles[h1_id].margin.bottom);
}

test "cascade: multiple stylesheet rules" {
    const allocator = std.testing.allocator;
    const source = "<style>p { color: red; } div { color: blue; }</style><div><p>hello</p></div>";

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    const css_text = try collectStyleText(allocator, &document);
    defer allocator.free(css_text);

    var ss = try parseStylesheet(allocator, css_text);
    defer ss.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try computeStyles(arena.allocator(), &document, &.{ss});

    const style_node = document.nodes.items[document.root].first_child.?;
    const div_id = document.nodes.items[style_node].next_sibling.?;
    const p_id = document.nodes.items[div_id].first_child.?;
    try std.testing.expectEqualStrings("blue", styles[div_id].color);
    try std.testing.expectEqualStrings("red", styles[p_id].color);
}

test "debug dump cascade tree" {
    if (!std.testing.environ.containsUnemptyConstant("HTML2REALPDF_DEBUG_CSS")) return;

    const allocator = std.testing.allocator;
    const source =
        \\<style>body > main { font-family: serif; color: #222; } .title { color: #1d4ed8; margin-bottom: 12px; }</style>
        \\<body><main><h1 class="title">Fattura demo</h1><p>Questo testo verifica style raw text e DOM tree.</p></main></body>
    ;

    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);
    var document = try dom.Parser.parse(allocator, source, tokens.items);
    defer document.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const styles = try styleArrayFromDocument(arena.allocator(), &document);

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try dumpCascade(&document, styles, &writer);
    std.debug.print("\n{s}", .{writer.buffered()});
}

test "parse value: font-size pixel" {
    try std.testing.expectEqual(@as(?f32, 20), parseLength("20px"));
    try std.testing.expectEqual(@as(?f32, 0), parseLength("0"));
    try std.testing.expectEqual(@as(?f32, 16.5), parseLength("16.5px"));
}

test "parse dimensions preserve percentages and normalize absolute units" {
    try std.testing.expectEqual(box.Length{ .percent = 1 }, parseDimension("100%", 16).?);
    try std.testing.expectEqual(box.Length{ .px = 32 }, parseDimension("2em", 16).?);
    try std.testing.expectApproxEqAbs(@as(f32, 96), parseDimension("25.4mm", 16).?.px, 0.001);
}

test "parse value: display keywords" {
    try std.testing.expectEqual(box.Display.block, parseDisplay("block").?);
    try std.testing.expectEqual(box.Display.inlineBox, parseDisplay("inline").?);
    try std.testing.expectEqual(box.Display.none, parseDisplay("none").?);
    try std.testing.expectEqual(box.Display.inlineBlock, parseDisplay("inline-block").?);
}

test "parse font weight and style" {
    try std.testing.expectEqual(box.FontWeight.bold, parseFontWeight("700").?);
    try std.testing.expectEqual(box.FontWeight.normal, parseFontWeight("400").?);
    try std.testing.expectEqual(box.FontStyle.italic, parseFontStyle("oblique").?);
}

test "parse value: edges shorthand" {
    const e1 = parseEdges("10px");
    try std.testing.expectEqual(@as(f32, 10), e1.top);
    try std.testing.expectEqual(@as(f32, 10), e1.bottom);
    try std.testing.expectEqual(@as(f32, 10), e1.left);
    try std.testing.expectEqual(@as(f32, 10), e1.right);

    const e2 = parseEdges("10px 20px");
    try std.testing.expectEqual(@as(f32, 10), e2.top);
    try std.testing.expectEqual(@as(f32, 20), e2.right);
    try std.testing.expectEqual(@as(f32, 10), e2.bottom);
    try std.testing.expectEqual(@as(f32, 20), e2.left);

    const e4 = parseEdges("1 2 3 4");
    try std.testing.expectEqual(@as(f32, 1), e4.top);
    try std.testing.expectEqual(@as(f32, 2), e4.right);
    try std.testing.expectEqual(@as(f32, 3), e4.bottom);
    try std.testing.expectEqual(@as(f32, 4), e4.left);
}

test "parse value: table display keywords" {
    try std.testing.expectEqual(box.Display.table, parseDisplay("table").?);
    try std.testing.expectEqual(box.Display.tableRow, parseDisplay("table-row").?);
    try std.testing.expectEqual(box.Display.tableCell, parseDisplay("table-cell").?);
    try std.testing.expectEqual(box.Display.tableRowGroup, parseDisplay("table-row-group").?);
}

test "parse value: text-align" {
    try std.testing.expectEqual(box.TextAlign.start, parseTextAlign("start").?);
    try std.testing.expectEqual(box.TextAlign.end, parseTextAlign("end").?);
    try std.testing.expectEqual(box.TextAlign.left, parseTextAlign("left").?);
    try std.testing.expectEqual(box.TextAlign.center, parseTextAlign("center").?);
    try std.testing.expectEqual(box.TextAlign.right, parseTextAlign("right").?);
    try std.testing.expectEqual(box.TextAlign.justify, parseTextAlign("justify").?);
}

test "parse value: direction" {
    try std.testing.expectEqual(box.Direction.ltr, parseDirection("ltr").?);
    try std.testing.expectEqual(box.Direction.rtl, parseDirection("rtl").?);
}

test "parse CSS Text inline properties" {
    try std.testing.expectEqual(box.TextTransform.uppercase, parseTextTransform("uppercase").?);
    try std.testing.expectEqual(box.TextTransform.capitalize, parseTextTransform("capitalize").?);
    try std.testing.expectEqual(box.WordBreak.breakAll, parseWordBreak("break-all").?);
    try std.testing.expectEqual(box.WordBreak.keepAll, parseWordBreak("keep-all").?);
    try std.testing.expectEqual(box.OverflowWrap.breakWord, parseOverflowWrap("break-word").?);
    try std.testing.expectEqual(box.OverflowWrap.anywhere, parseOverflowWrap("anywhere").?);
    try std.testing.expect(parseVerticalAlignKeyword("super").? == .super);
    try std.testing.expect(parseVerticalAlignKeyword("text-bottom").? == .textBottom);
    try std.testing.expectEqual(box.Overflow.hidden, parseOverflow("hidden").?);
    try std.testing.expectEqual(box.Overflow.clip, parseOverflow("clip").?);
    try std.testing.expectEqual(box.TextOverflow.ellipsis, parseTextOverflow("ellipsis").?);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), parseAspectRatio("16 / 9").?.ratio.?, 0.001);
    try std.testing.expectEqual(box.ObjectFit.cover, parseObjectFit("cover").?);
    try std.testing.expectApproxEqAbs(@as(f32, 1), parseObjectPosition("right 25%").?.x.resolve(1).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), parseObjectPosition("right 25%").?.y.resolve(1).?, 0.001);
}

test "parse value: box-sizing" {
    try std.testing.expectEqual(box.BoxSizing.contentBox, parseBoxSizing("content-box").?);
    try std.testing.expectEqual(box.BoxSizing.borderBox, parseBoxSizing("border-box").?);
    try std.testing.expectEqual(box.BorderCollapse.collapse, parseBorderCollapse("collapse").?);
}

test "parse value: page-break" {
    try std.testing.expectEqual(box.PageBreak.auto, parsePageBreak("auto").?);
    try std.testing.expectEqual(box.PageBreak.always, parsePageBreak("always").?);
    try std.testing.expectEqual(box.PageBreak.avoid, parsePageBreak("avoid").?);
    try std.testing.expectEqual(box.PageBreak.always, parsePageBreak("page").?);
    try std.testing.expectEqual(box.PageBreak.avoid, parsePageBreak("avoid-page").?);
}

test "parse value: border-style" {
    try std.testing.expectEqual(box.BorderStyle.none, parseBorderStyle("none").?);
    try std.testing.expectEqual(box.BorderStyle.solid, parseBorderStyle("solid").?);
    try std.testing.expectEqual(box.BorderStyle.dashed, parseBorderStyle("dashed").?);
    try std.testing.expectEqual(box.BorderStyle.dotted, parseBorderStyle("dotted").?);
}

test "parse value: positive integer" {
    try std.testing.expectEqual(@as(u32, 3), parsePositiveInteger("3").?);
    try std.testing.expectEqual(@as(u32, 42), parsePositiveInteger("42").?);
    try std.testing.expect(parsePositiveInteger("0") == null);
    try std.testing.expect(parsePositiveInteger("-1") == null);
}

const CascadeTest = struct {
    document: dom.Document,
    styles: []box.Style,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CascadeTest, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        self.document.deinit(allocator);
    }
};

fn cascadeTestHelper(allocator: std.mem.Allocator, source: []const u8) !CascadeTest {
    var tokens = try html.Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var document = try dom.Parser.parse(allocator, source, tokens.items);
    errdefer document.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const css_text = try collectStyleText(arena_alloc, &document);
    const ss = try parseStylesheet(arena_alloc, css_text);
    const styles = try computeStyles(arena_alloc, &document, &.{ss});

    return CascadeTest{
        .document = document,
        .styles = styles,
        .arena = arena,
    };
}

test "cascade: width and height properties" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>div { width: 200px; height: 100px; }</style><div>box</div>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const div_id = ct.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqual(box.Length{ .px = 200 }, ct.styles[div_id].width);
    try std.testing.expectEqual(box.Length{ .px = 100 }, ct.styles[div_id].height);
}

test "cascade: border-style per side" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>div { border-top-style: solid; border-bottom-style: dashed; }</style><div>box</div>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const div_id = ct.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqual(box.BorderStyle.solid, ct.styles[div_id].border_top_style);
    try std.testing.expectEqual(box.BorderStyle.none, ct.styles[div_id].border_right_style);
    try std.testing.expectEqual(box.BorderStyle.dashed, ct.styles[div_id].border_bottom_style);
    try std.testing.expectEqual(box.BorderStyle.none, ct.styles[div_id].border_left_style);
}

test "cascade: uniform border radius" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>.card { border-radius: 14px; }</style><div class='card'>rounded</div>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const div_id = ct.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqual(@as(f32, 14), ct.styles[div_id].border_radius);
}

test "cascade: text-align and line-height" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>p { text-align: center; line-height: 1.5; }</style><p>centered</p>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const p_id = ct.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqual(box.TextAlign.center, ct.styles[p_id].text_align);
    try std.testing.expectEqual(@as(f32, 24), ct.styles[p_id].line_height);
}

test "cascade: direction and logical text alignment inherit" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>p { direction: rtl; text-align: start; } span { direction: inherit; text-align: inherit; }</style><p><span>שלום</span></p>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const p_id = ct.document.nodes.items[style_id].next_sibling.?;
    const span_id = ct.document.nodes.items[p_id].first_child.?;
    try std.testing.expectEqual(box.Direction.rtl, ct.styles[span_id].direction);
    try std.testing.expectEqual(box.TextAlign.start, ct.styles[span_id].text_align);
}

test "cascade: logical box properties use final direction and shared physical priority" {
    const allocator = std.testing.allocator;
    const source =
        "<style>" ++
        "#rtl{margin-inline-start:11px;padding-inline-end:7px;border-inline-start:3px solid red;inline-size:120px;block-size:40px;direction:rtl}" ++
        "#physical-last{direction:rtl;margin-inline-start:10px;margin-right:20px}" ++
        "#logical-last{direction:rtl;margin-right:20px;margin-inline-start:10px}" ++
        "#axes{margin-block:4px 8px;padding-inline:3px 9px;border-block:2px dashed blue;min-inline-size:50px;max-block-size:60px}" ++
        "</style>" ++
        "<div id='rtl'></div><div id='physical-last'></div><div id='logical-last'></div><div id='axes'></div>";
    var ct = try cascadeTestHelper(allocator, source);
    defer ct.deinit(allocator);

    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const rtl_id = ct.document.nodes.items[style_id].next_sibling.?;
    const physical_last_id = ct.document.nodes.items[rtl_id].next_sibling.?;
    const logical_last_id = ct.document.nodes.items[physical_last_id].next_sibling.?;
    const axes_id = ct.document.nodes.items[logical_last_id].next_sibling.?;

    const rtl = ct.styles[rtl_id];
    try std.testing.expectEqual(box.Direction.rtl, rtl.direction);
    try std.testing.expectEqual(@as(f32, 11), rtl.margin.right);
    try std.testing.expectEqual(@as(f32, 7), rtl.padding.left);
    try std.testing.expectEqual(@as(f32, 3), rtl.border.right);
    try std.testing.expectEqual(box.BorderStyle.solid, rtl.border_right_style);
    try std.testing.expectEqualStrings("red", rtl.border_right_color);
    try std.testing.expectEqual(box.Length{ .px = 120 }, rtl.width);
    try std.testing.expectEqual(box.Length{ .px = 40 }, rtl.height);

    try std.testing.expectEqual(@as(f32, 20), ct.styles[physical_last_id].margin.right);
    try std.testing.expectEqual(@as(f32, 10), ct.styles[logical_last_id].margin.right);

    const axes = ct.styles[axes_id];
    try std.testing.expectEqual(@as(f32, 4), axes.margin.top);
    try std.testing.expectEqual(@as(f32, 8), axes.margin.bottom);
    try std.testing.expectEqual(@as(f32, 3), axes.padding.left);
    try std.testing.expectEqual(@as(f32, 9), axes.padding.right);
    try std.testing.expectEqual(@as(f32, 2), axes.border.top);
    try std.testing.expectEqual(@as(f32, 2), axes.border.bottom);
    try std.testing.expectEqual(box.BorderStyle.dashed, axes.border_top_style);
    try std.testing.expectEqualStrings("blue", axes.border_bottom_color);
    try std.testing.expectEqual(box.Length{ .px = 50 }, axes.min_width);
    try std.testing.expectEqual(box.Length{ .px = 60 }, axes.max_height);
}

test "cascade: logical inherit keeps the parent's flow-relative side" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(
        allocator,
        "<div style='direction:ltr;margin-inline-start:13px;border-inline-start-color:red'>" ++
            "<span style='display:block;direction:rtl;margin-inline-start:inherit;border-inline-start-color:inherit'></span>" ++
            "</div>",
    );
    defer ct.deinit(allocator);

    const parent_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const child_id = ct.document.nodes.items[parent_id].first_child.?;
    try std.testing.expectEqual(@as(f32, 13), ct.styles[parent_id].margin.left);
    try std.testing.expectEqual(@as(f32, 13), ct.styles[child_id].margin.right);
    try std.testing.expectEqualStrings("red", ct.styles[parent_id].border_left_color);
    try std.testing.expectEqualStrings("red", ct.styles[child_id].border_right_color);
}

test "cascade: CSS Text inline properties inherit as computed values" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>div { word-spacing: 3px; text-indent: 10%; text-transform: uppercase; word-break: break-all; overflow-wrap: anywhere; }</style>" ++
        "<div><span>inline</span></div>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const div_id = ct.document.nodes.items[style_id].next_sibling.?;
    const span_id = ct.document.nodes.items[div_id].first_child.?;

    try std.testing.expectEqual(@as(f32, 3), ct.styles[div_id].word_spacing);
    try std.testing.expectApproxEqAbs(@as(f32, 20), ct.styles[div_id].text_indent.resolve(200).?, 0.01);
    try std.testing.expectEqual(box.TextTransform.uppercase, ct.styles[span_id].text_transform);
    try std.testing.expectEqual(box.WordBreak.breakAll, ct.styles[span_id].word_break);
    try std.testing.expectEqual(box.OverflowWrap.anywhere, ct.styles[span_id].overflow_wrap);
    try std.testing.expectEqual(@as(f32, 3), ct.styles[span_id].word_spacing);
}

test "cascade: vertical-align keeps keyword and percentage computed values" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<span style='vertical-align:super'>super</span><span style='vertical-align:25%'>offset</span>");
    defer ct.deinit(allocator);
    const first_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const second_id = ct.document.nodes.items[first_id].next_sibling.?;
    try std.testing.expect(ct.styles[first_id].vertical_align == .super);
    switch (ct.styles[second_id].vertical_align) {
        .offset => |offset| try std.testing.expectApproxEqAbs(@as(f32, 4.5), offset.resolve(18).?, 0.01),
        else => return error.TestExpectedEqual,
    }
}

test "cascade: text-decoration shorthand keeps line style color and thickness" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<p style='text-decoration:underline overline wavy rebeccapurple 2px'>decorated</p>");
    defer ct.deinit(allocator);
    const p_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const style = ct.styles[p_id];
    try std.testing.expectEqual(box.TextDecoration.underlineOverline, style.text_decoration);
    try std.testing.expectEqual(box.TextDecorationStyle.wavy, style.text_decoration_style);
    try std.testing.expectEqualStrings("rebeccapurple", style.text_decoration_color.?);
    switch (style.text_decoration_thickness) {
        .length => |length| try std.testing.expectApproxEqAbs(@as(f32, 2), length.resolve(style.font_size).?, 0.01),
        else => return error.TestExpectedEqual,
    }
}

test "cascade: overflow and text-overflow remain container properties" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<div style='overflow:hidden;text-overflow:ellipsis'><span>clipped</span></div>");
    defer ct.deinit(allocator);
    const div_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const span_id = ct.document.nodes.items[div_id].first_child.?;
    try std.testing.expectEqual(box.Overflow.hidden, ct.styles[div_id].overflow);
    try std.testing.expectEqual(box.TextOverflow.ellipsis, ct.styles[div_id].text_overflow);
    try std.testing.expectEqual(box.Overflow.visible, ct.styles[span_id].overflow);
    try std.testing.expectEqual(box.TextOverflow.clip, ct.styles[span_id].text_overflow);
}

test "cascade: replaced sizing and fit properties remain local" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<div style='aspect-ratio:16/9;object-fit:cover;object-position:right 25%'><img></div>");
    defer ct.deinit(allocator);
    const div_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const image_id = ct.document.nodes.items[div_id].first_child.?;
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), ct.styles[div_id].aspect_ratio.ratio.?, 0.001);
    try std.testing.expectEqual(box.ObjectFit.cover, ct.styles[div_id].object_fit);
    try std.testing.expectEqual(box.ObjectFit.fill, ct.styles[image_id].object_fit);
    try std.testing.expect(ct.styles[image_id].aspect_ratio.ratio == null);
}

test "cascade: page-break and orphans/widows" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>div { break-before: page; page-break-after: avoid; break-inside: avoid-page; orphans: 3; widows: 4; }</style><div>page</div>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const div_id = ct.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqual(box.PageBreak.always, ct.styles[div_id].page_break_before);
    try std.testing.expectEqual(box.PageBreak.avoid, ct.styles[div_id].page_break_after);
    try std.testing.expectEqual(box.PageBreak.avoid, ct.styles[div_id].page_break_inside);
    try std.testing.expectEqual(@as(u32, 3), ct.styles[div_id].orphans);
    try std.testing.expectEqual(@as(u32, 4), ct.styles[div_id].widows);
}

test "cascade: inline style overrides stylesheet declarations" {
    const allocator = std.testing.allocator;
    var fixture = try cascadeTestHelper(
        allocator,
        "<style>p { color: red; width: 10px; }</style><p style=\"color: #123456; width: 240px\">inline</p>",
    );
    defer fixture.deinit(allocator);

    const style_id = fixture.document.nodes.items[fixture.document.root].first_child.?;
    const paragraph = fixture.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqualStrings("#123456", fixture.styles[paragraph].color);
    try std.testing.expectEqual(box.Length{ .px = 240 }, fixture.styles[paragraph].width);
}

test "cascade: important author rule overrides normal inline style" {
    const allocator = std.testing.allocator;
    var fixture = try cascadeTestHelper(
        allocator,
        "<style>#target { color: blue; } .notice { color: red !important; }</style><p id=\"target\" class=\"notice\" style=\"color: green\">important</p>",
    );
    defer fixture.deinit(allocator);

    const style_id = fixture.document.nodes.items[fixture.document.root].first_child.?;
    const paragraph = fixture.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqualStrings("red", fixture.styles[paragraph].color);
}

test "cascade: important inline style overrides important author rule" {
    const allocator = std.testing.allocator;
    var fixture = try cascadeTestHelper(
        allocator,
        "<style>#target { color: red !important; }</style><p id=\"target\" style=\"color: green !important\">important</p>",
    );
    defer fixture.deinit(allocator);

    const style_id = fixture.document.nodes.items[fixture.document.root].first_child.?;
    const paragraph = fixture.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqualStrings("green", fixture.styles[paragraph].color);
}

test "cascade: retains every match beyond the old fixed buffer limit" {
    const allocator = std.testing.allocator;
    var source = std.Io.Writer.Allocating.init(allocator);
    defer source.deinit();
    try source.writer.writeAll("<style>");
    for (0..80) |index| try source.writer.print(".target {{ margin-left: {d}px; }}", .{index});
    try source.writer.writeAll("</style><div class=\"target\">all rules match</div>");

    var fixture = try cascadeTestHelper(allocator, source.written());
    defer fixture.deinit(allocator);
    const style_id = fixture.document.nodes.items[fixture.document.root].first_child.?;
    const div = fixture.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqual(@as(f32, 79), fixture.styles[div].margin.left);
}

test "cascade: custom properties inherit into calc dimensions" {
    const allocator = std.testing.allocator;
    var fixture = try cascadeTestHelper(
        allocator,
        "<style>body { --gutter: 20px; } .card { width: calc(50% - var(--gutter)); }</style><body><div class='card'>card</div></body>",
    );
    defer fixture.deinit(allocator);
    const style_id = fixture.document.nodes.items[fixture.document.root].first_child.?;
    const body = fixture.document.nodes.items[style_id].next_sibling.?;
    const card = fixture.document.nodes.items[body].first_child.?;
    try std.testing.expectApproxEqAbs(@as(f32, 180), fixture.styles[card].width.resolve(400).?, 0.001);
}

test "cascade: var fallback survives a custom-property cycle" {
    const allocator = std.testing.allocator;
    var fixture = try cascadeTestHelper(
        allocator,
        "<style>.card { --a: var(--b); --b: var(--a); width: var(--a, clamp(120px, 50%, 300px)); }</style><div class='card'>card</div>",
    );
    defer fixture.deinit(allocator);
    const style_id = fixture.document.nodes.items[fixture.document.root].first_child.?;
    const card = fixture.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectApproxEqAbs(@as(f32, 250), fixture.styles[card].width.resolve(500).?, 0.001);
}

test "cascade: CSS-wide keywords and currentColor resolve at computed value time" {
    const allocator = std.testing.allocator;
    var fixture = try cascadeTestHelper(
        allocator,
        "<style>body { color: #123456; } h1 { color: inherit; display: initial; } .reset { color: unset; background-color: currentColor; width: 240px; max-width: initial; }</style><body><h1>Title</h1><div class='reset'>card</div></body>",
    );
    defer fixture.deinit(allocator);
    const style_id = fixture.document.nodes.items[fixture.document.root].first_child.?;
    const body = fixture.document.nodes.items[style_id].next_sibling.?;
    const heading = fixture.document.nodes.items[body].first_child.?;
    const card = fixture.document.nodes.items[heading].next_sibling.?;
    try std.testing.expectEqualStrings("#123456", fixture.styles[heading].color);
    try std.testing.expectEqual(box.Display.inlineBox, fixture.styles[heading].display);
    try std.testing.expectEqualStrings("#123456", fixture.styles[card].color);
    try std.testing.expectEqualStrings("#123456", fixture.styles[card].background.?);
    try std.testing.expectEqual(box.Length.auto, fixture.styles[card].max_width);
}
