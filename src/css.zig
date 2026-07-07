//! CSS parser, selector matching, and cascade engine.
//!
//! Parses CSS text from `<style>` elements into rules, matches selectors
//! against DOM nodes, resolves specificity, and produces `box.Style` values
//! indexed by `dom.NodeId` for Box Tree construction.
//!
//! Selector support: type, class, id, universal, compound, descendant combinator,
//! and child combinator. At-rules are skipped. `!important` is ignored.
//!
//! The cascade walks the DOM in tree order and applies UA → inherited → author
//! styles, respecting specificity and source-order.

const std = @import("std");
const dom = @import("dom.zig");
const box = @import("box.zig");
const html = @import("html.zig");

// ---------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------

pub const Combinator = enum {
    descendant,
    child,
};

pub const SelectorTest = union(enum) {
    tag: []const u8,
    class: []const u8,
    id: []const u8,
    universal,
};

pub const SelectorPart = struct {
    tests: []const SelectorTest,
    combinator: ?Combinator = null,
};

pub const Selector = struct {
    parts: []const SelectorPart,
};

pub const Declaration = struct {
    name: []const u8,
    value: []const u8,
};

pub const Rule = struct {
    selectors: []const Selector,
    declarations: []const Declaration,
};

pub const Stylesheet = struct {
    rules: []const Rule,

    pub fn deinit(self: *Stylesheet, allocator: std.mem.Allocator) void {
        for (self.rules) |*rule| {
            for (rule.selectors) |*sel| {
                for (sel.parts) |*part| {
                    allocator.free(part.tests);
                }
                allocator.free(sel.parts);
            }
            allocator.free(rule.selectors);
            allocator.free(rule.declarations);
        }
        allocator.free(self.rules);
    }
};

pub const Specificity = struct {
    id_count: u32 = 0,
    class_count: u32 = 0,
    type_count: u32 = 0,
};

// ---------------------------------------------------------------
// CSS Parser
// ---------------------------------------------------------------

pub fn parseStylesheet(allocator: std.mem.Allocator, css_text: []const u8) !Stylesheet {
    var parser = CssParser{
        .input = css_text,
        .pos = 0,
        .allocator = allocator,
    };
    const rules = try parser.parseRules();
    return Stylesheet{ .rules = rules };
}

const CssParser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    fn eof(self: *const CssParser) bool {
        return self.pos >= self.input.len;
    }

    fn peek(self: *const CssParser) u8 {
        if (self.eof()) return 0;
        return self.input[self.pos];
    }

    fn next(self: *CssParser) u8 {
        if (self.eof()) return 0;
        const c = self.input[self.pos];
        self.pos += 1;
        return c;
    }

    fn advance(self: *CssParser, n: usize) void {
        self.pos = @min(self.pos + n, self.input.len);
    }

    fn skipWs(self: *CssParser) void {
        while (!self.eof() and cssWhitespace(self.peek())) {
            _ = self.next();
        }
    }

    fn skipComment(self: *CssParser) void {
        if (self.peek() != '/') return;
        if (self.pos + 1 >= self.input.len) return;
        if (self.input[self.pos + 1] != '*') return;
        self.advance(2);
        while (!self.eof()) {
            if (self.peek() == '*' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
                self.advance(2);
                return;
            }
            _ = self.next();
        }
    }

    fn skipWsAndComments(self: *CssParser) void {
        while (true) {
            self.skipWs();
            if (self.peek() == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '*') {
                self.skipComment();
            } else {
                break;
            }
        }
    }

    fn parseRules(self: *CssParser) ![]Rule {
        var rules = try std.ArrayList(Rule).initCapacity(self.allocator, 0);
        errdefer self.freeRuleList(rules.items);

        while (!self.eof()) {
            self.skipWsAndComments();
            if (self.eof()) break;

            if (self.peek() == '@') {
                self.skipAtRule();
                continue;
            }

            if (self.parseRule()) |rule| {
                try rules.append(self.allocator, rule);
            } else {
                self.skipInvalidContent();
            }
        }

        return rules.toOwnedSlice(self.allocator);
    }

    fn skipInvalidContent(self: *CssParser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == '{') {
                _ = self.next();
                self.skipBalancedBlock();
                return;
            } else if (c == '}' or c == ';') {
                _ = self.next();
                return;
            } else if (c == '"' or c == '\'') {
                const quote = self.next();
                while (!self.eof()) {
                    const inner = self.next();
                    if (inner == '\\') {
                        _ = self.next();
                    } else if (inner == quote) {
                        break;
                    }
                }
            } else {
                _ = self.next();
            }
        }
    }

    fn freeRuleList(self: *CssParser, rules: []Rule) void {
        for (rules) |*rule| {
            for (rule.selectors) |*sel| {
                for (sel.parts) |*part| {
                    self.allocator.free(part.tests);
                }
                self.allocator.free(sel.parts);
            }
            self.allocator.free(rule.selectors);
            self.allocator.free(rule.declarations);
        }
        self.allocator.free(rules);
    }

    fn skipAtRule(self: *CssParser) void {
        _ = self.next();
        _ = self.parseIdent();

        while (!self.eof()) {
            self.skipWsAndComments();
            if (self.eof()) return;

            if (self.peek() == '{') {
                _ = self.next();
                self.skipBalancedBlock();
                return;
            }
            if (self.peek() == ';') {
                _ = self.next();
                return;
            }
            _ = self.next();
        }
    }

    fn skipBalancedBlock(self: *CssParser) void {
        var depth: u32 = 1;
        while (depth > 0 and !self.eof()) {
            const c = self.next();
            if (c == '"' or c == '\'') {
                const quote = c;
                while (!self.eof()) {
                    const inner = self.next();
                    if (inner == '\\') {
                        _ = self.next();
                    } else if (inner == quote) {
                        break;
                    }
                }
            } else if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -= 1;
            } else if (c == '/' and self.peek() == '*') {
                self.pos -= 1;
                self.skipComment();
            }
        }
    }

    fn parseRule(self: *CssParser) ?Rule {
        const selectors = self.parseSelectorList() catch return null;
        if (selectors.len == 0) {
            self.allocator.free(selectors);
            return null;
        }

        self.skipWsAndComments();
        if (self.peek() != '{') {
            self.freeSelectorList(selectors);
            return null;
        }
        _ = self.next();

        const declarations = self.parseDeclarations() catch {
            self.freeSelectorList(selectors);
            return null;
        };

        return Rule{
            .selectors = selectors,
            .declarations = declarations,
        };
    }

    fn freeSelectorList(self: *CssParser, selectors: []Selector) void {
        for (selectors) |*sel| {
            for (sel.parts) |*part| {
                self.allocator.free(part.tests);
            }
            self.allocator.free(sel.parts);
        }
        self.allocator.free(selectors);
    }

    fn parseSelectorList(self: *CssParser) ![]Selector {
        var selectors = try std.ArrayList(Selector).initCapacity(self.allocator, 0);
        errdefer self.freeSelectorList(selectors.items);

        while (true) {
            self.skipWsAndComments();
            if (self.eof() or self.peek() == '{') break;

            if (try self.parseSelector()) |sel| {
                try selectors.append(self.allocator, sel);
            } else break;

            self.skipWsAndComments();
            if (self.peek() == ',') {
                _ = self.next();
            } else {
                break;
            }
        }

        if (selectors.items.len == 0) {
            selectors.deinit(self.allocator);
            return &.{};
        }
        return selectors.toOwnedSlice(self.allocator);
    }

    fn parseSelector(self: *CssParser) !?Selector {
        var parts = try std.ArrayList(SelectorPart).initCapacity(self.allocator, 0);
        errdefer {
            for (parts.items) |p| self.allocator.free(p.tests);
            parts.deinit(self.allocator);
        }

        const first_tests = try self.parseCompoundSelector() orelse {
            parts.deinit(self.allocator);
            return null;
        };
        try parts.append(self.allocator, .{ .tests = first_tests, .combinator = null });

        while (true) {
            self.skipWsAndComments();
            const c = self.peek();
            if (c == 0 or c == '{' or c == '}' or c == ',') break;

            const combinator: Combinator = if (c == '>') blk: {
                _ = self.next();
                self.skipWsAndComments();
                break :blk .child;
            } else blk: {
                break :blk .descendant;
            };

            const tests = try self.parseCompoundSelector() orelse {
                break;
            };

            if (parts.items.len > 0) {
                parts.items[parts.items.len - 1].combinator = combinator;
            }
            try parts.append(self.allocator, .{ .tests = tests, .combinator = null });
        }

        if (parts.items.len == 0) {
            parts.deinit(self.allocator);
            return null;
        }
        return Selector{ .parts = try parts.toOwnedSlice(self.allocator) };
    }

    fn parseCompoundSelector(self: *CssParser) !?[]SelectorTest {
        var tests = try std.ArrayList(SelectorTest).initCapacity(self.allocator, 0);
        errdefer tests.deinit(self.allocator);

        self.skipWsAndComments();
        var has_any = false;

        if (self.peek() == '*') {
            _ = self.next();
            tests.append(self.allocator, .universal) catch {
                tests.deinit(self.allocator);
                return null;
            };
            has_any = true;
        } else if (cssIdentStart(self.peek())) {
            const name = self.parseIdent();
            if (name.len > 0) {
                tests.append(self.allocator, .{ .tag = name }) catch {
                    tests.deinit(self.allocator);
                    return null;
                };
                has_any = true;
            }
        }

        while (true) {
            if (self.peek() == '.') {
                _ = self.next();
                const name = self.parseIdent();
                if (name.len == 0) break;
                tests.append(self.allocator, .{ .class = name }) catch {
                    tests.deinit(self.allocator);
                    return null;
                };
                has_any = true;
            } else if (self.peek() == '#') {
                _ = self.next();
                const name = self.parseIdent();
                if (name.len == 0) break;
                tests.append(self.allocator, .{ .id = name }) catch {
                    tests.deinit(self.allocator);
                    return null;
                };
                has_any = true;
            } else {
                break;
            }
        }

        if (!has_any) {
            tests.deinit(self.allocator);
            return null;
        }
        return tests.toOwnedSlice(self.allocator) catch {
            tests.deinit(self.allocator);
            return null;
        };
    }

    fn parseIdent(self: *CssParser) []const u8 {
        const start = self.pos;
        if (!cssIdentStart(self.peek())) return "";

        _ = self.next();
        while (!self.eof() and cssIdentChar(self.peek())) {
            _ = self.next();
        }
        return self.input[start..self.pos];
    }

    fn parseDeclarations(self: *CssParser) ![]Declaration {
        var declarations = try std.ArrayList(Declaration).initCapacity(self.allocator, 0);
        errdefer {
            self.allocator.free(declarations.items);
            declarations.deinit(self.allocator);
        }

        while (!self.eof()) {
            self.skipWsAndComments();
            if (self.eof()) break;

            if (self.peek() == '}') {
                _ = self.next();
                break;
            }

            if (self.parseDeclaration()) |decl| {
                try declarations.append(self.allocator, decl);
            }
        }

        if (declarations.items.len == 0) {
            declarations.deinit(self.allocator);
            return &.{};
        }
        return declarations.toOwnedSlice(self.allocator);
    }

    fn parseDeclaration(self: *CssParser) ?Declaration {
        self.skipWsAndComments();
        if (!cssIdentStart(self.peek())) {
            self.skipMalformedDeclaration();
            return null;
        }

        const name_start = self.pos;
        const name = self.parseIdent();
        if (name.len == 0) {
            self.skipMalformedDeclaration();
            return null;
        }

        self.skipWsAndComments();
        if (self.peek() != ':') {
            self.pos = name_start;
            self.skipMalformedDeclaration();
            return null;
        }
        _ = self.next();

        self.skipWsAndComments();
        const value_start = self.pos;

        var paren_depth: u32 = 0;
        while (!self.eof()) {
            const c = self.peek();
            if (c == '"' or c == '\'') {
                _ = self.next();
                while (!self.eof()) {
                    const inner = self.next();
                    if (inner == '\\') {
                        _ = self.next();
                    } else if (inner == c) {
                        break;
                    }
                }
            } else if (c == '(') {
                paren_depth += 1;
                _ = self.next();
            } else if (c == ')') {
                if (paren_depth > 0) paren_depth -= 1;
                _ = self.next();
            } else if (c == '{') {
                paren_depth += 1;
                _ = self.next();
            } else if (c == '}') {
                if (paren_depth > 0) {
                    paren_depth -= 1;
                    _ = self.next();
                } else {
                    break;
                }
            } else if (paren_depth == 0 and (c == ';' or c == '/')) {
                if (c == '/') {
                    if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '*') break;
                    _ = self.next();
                } else {
                    break;
                }
            } else {
                _ = self.next();
            }
        }

        const value_raw = self.input[value_start..self.pos];
        const value = std.mem.trim(u8, value_raw, " \t\n\r\x0C");

        if (self.peek() == ';') {
            _ = self.next();
        }

        self.skipToImportant();

        return Declaration{ .name = name, .value = value };
    }

    fn skipToImportant(self: *CssParser) void {
        const saved = self.pos;
        self.skipWsAndComments();
        if (self.peek() == '!') {
            _ = self.next();
            self.skipWsAndComments();
            _ = self.parseIdent();
        } else {
            self.pos = saved;
        }
    }

    fn skipMalformedDeclaration(self: *CssParser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == ';' or c == '}' or c == '{') break;
            _ = self.next();
        }
        if (self.peek() == ';') _ = self.next();
    }
};

fn cssWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C;
}

fn cssIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c > 0x7F;
}

fn cssIdentChar(c: u8) bool {
    return cssIdentStart(c) or (c >= '0' and c <= '9') or c == '-';
}

// ---------------------------------------------------------------
// Selector matching
// ---------------------------------------------------------------

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

fn applyDeclaration(style: *box.Style, name: []const u8, value: []const u8) void {
    if (eqlProp(name, "display")) {
        if (parseDisplay(value)) |d| style.display = d;
    } else if (eqlProp(name, "position")) {
        if (parsePosition(value)) |p| style.position = p;
    } else if (eqlProp(name, "float")) {
        if (parseFloatValue(value)) |f| style.float_direction = f;
    } else if (eqlProp(name, "white-space")) {
        if (parseWhiteSpace(value)) |w| style.white_space = w;
    } else if (eqlProp(name, "font-size")) {
        if (parseLength(value)) |fs| style.font_size = fs;
    } else if (eqlProp(name, "font-family")) {
        style.font_family = value;
    } else if (eqlProp(name, "color")) {
        style.color = value;
    } else if (eqlProp(name, "background") or eqlProp(name, "background-color")) {
        style.background = value;
    } else if (eqlProp(name, "width")) {
        if (parseLength(value)) |w| style.width = w;
    } else if (eqlProp(name, "height")) {
        if (parseLength(value)) |h| style.height = h;
    } else if (eqlProp(name, "min-width")) {
        if (parseLength(value)) |w| style.min_width = w;
    } else if (eqlProp(name, "max-width")) {
        if (parseLength(value)) |w| style.max_width = w;
    } else if (eqlProp(name, "min-height")) {
        if (parseLength(value)) |h| style.min_height = h;
    } else if (eqlProp(name, "max-height")) {
        if (parseLength(value)) |h| style.max_height = h;
    } else if (eqlProp(name, "line-height")) {
        if (parseLength(value)) |lh| style.line_height = lh;
    } else if (eqlProp(name, "text-align")) {
        if (parseTextAlign(value)) |ta| style.text_align = ta;
    } else if (eqlProp(name, "box-sizing")) {
        if (parseBoxSizing(value)) |bs| style.box_sizing = bs;
    } else if (eqlProp(name, "page-break-before")) {
        if (parsePageBreak(value)) |pb| style.page_break_before = pb;
    } else if (eqlProp(name, "page-break-after")) {
        if (parsePageBreak(value)) |pb| style.page_break_after = pb;
    } else if (eqlProp(name, "orphans")) {
        if (parsePositiveInteger(value)) |o| style.orphans = o;
    } else if (eqlProp(name, "widows")) {
        if (parsePositiveInteger(value)) |w| style.widows = w;
    } else if (eqlProp(name, "margin")) {
        style.margin = parseEdges(value);
    } else if (eqlProp(name, "margin-top")) {
        if (parseLength(value)) |l| style.margin.top = l;
    } else if (eqlProp(name, "margin-right")) {
        if (parseLength(value)) |l| style.margin.right = l;
    } else if (eqlProp(name, "margin-bottom")) {
        if (parseLength(value)) |l| style.margin.bottom = l;
    } else if (eqlProp(name, "margin-left")) {
        if (parseLength(value)) |l| style.margin.left = l;
    } else if (eqlProp(name, "padding")) {
        style.padding = parseEdges(value);
    } else if (eqlProp(name, "padding-top")) {
        if (parseLength(value)) |l| style.padding.top = l;
    } else if (eqlProp(name, "padding-right")) {
        if (parseLength(value)) |l| style.padding.right = l;
    } else if (eqlProp(name, "padding-bottom")) {
        if (parseLength(value)) |l| style.padding.bottom = l;
    } else if (eqlProp(name, "padding-left")) {
        if (parseLength(value)) |l| style.padding.left = l;
    } else if (eqlProp(name, "border")) {
        const len = parseFirstLength(value);
        style.border = .{ .top = len, .right = len, .bottom = len, .left = len };
    } else if (eqlProp(name, "border-top")) {
        style.border.top = parseFirstLength(value);
    } else if (eqlProp(name, "border-right")) {
        style.border.right = parseFirstLength(value);
    } else if (eqlProp(name, "border-bottom")) {
        style.border.bottom = parseFirstLength(value);
    } else if (eqlProp(name, "border-left")) {
        style.border.left = parseFirstLength(value);
    } else if (eqlProp(name, "border-style")) {
        if (parseBorderStyle(value)) |bs| {
            style.border_top_style = bs;
            style.border_right_style = bs;
            style.border_bottom_style = bs;
            style.border_left_style = bs;
        }
    } else if (eqlProp(name, "border-top-style")) {
        if (parseBorderStyle(value)) |bs| style.border_top_style = bs;
    } else if (eqlProp(name, "border-right-style")) {
        if (parseBorderStyle(value)) |bs| style.border_right_style = bs;
    } else if (eqlProp(name, "border-bottom-style")) {
        if (parseBorderStyle(value)) |bs| style.border_bottom_style = bs;
    } else if (eqlProp(name, "border-left-style")) {
        if (parseBorderStyle(value)) |bs| style.border_left_style = bs;
    } else if (eqlProp(name, "border-color")) {
        style.border_top_color = value;
        style.border_right_color = value;
        style.border_bottom_color = value;
        style.border_left_color = value;
    } else if (eqlProp(name, "border-top-color")) {
        style.border_top_color = value;
    } else if (eqlProp(name, "border-right-color")) {
        style.border_right_color = value;
    } else if (eqlProp(name, "border-bottom-color")) {
        style.border_bottom_color = value;
    } else if (eqlProp(name, "border-left-color")) {
        style.border_left_color = value;
    } else if (eqlProp(name, "border-top-width")) {
        if (parseLength(value)) |l| style.border.top = l;
    } else if (eqlProp(name, "border-right-width")) {
        if (parseLength(value)) |l| style.border.right = l;
    } else if (eqlProp(name, "border-bottom-width")) {
        if (parseLength(value)) |l| style.border.bottom = l;
    } else if (eqlProp(name, "border-left-width")) {
        if (parseLength(value)) |l| style.border.left = l;
    }
}

fn eqlProp(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn parseDisplay(value: []const u8) ?box.Display {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "none")) return .none;
    if (eqlProp(v, "block")) return .block;
    if (eqlProp(v, "inline")) return .inlineBox;
    if (eqlProp(v, "inline-block")) return .inlineBlock;
    if (eqlProp(v, "table")) return .table;
    if (eqlProp(v, "table-row")) return .tableRow;
    if (eqlProp(v, "table-cell")) return .tableCell;
    if (eqlProp(v, "table-row-group")) return .tableRowGroup;
    return null;
}

fn parsePosition(value: []const u8) ?box.Position {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "static")) return .static;
    if (eqlProp(v, "relative")) return .relative;
    if (eqlProp(v, "absolute")) return .absolute;
    if (eqlProp(v, "fixed")) return .fixed;
    return null;
}

fn parseFloatValue(value: []const u8) ?box.Float {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "none")) return .none;
    if (eqlProp(v, "left")) return .left;
    if (eqlProp(v, "right")) return .right;
    return null;
}

fn parseWhiteSpace(value: []const u8) ?box.WhiteSpace {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "normal")) return .normal;
    if (eqlProp(v, "nowrap")) return .nowrap;
    if (eqlProp(v, "pre")) return .pre;
    if (eqlProp(v, "pre-wrap")) return .preWrap;
    if (eqlProp(v, "pre-line")) return .preLine;
    return null;
}

fn parseLength(value: []const u8) ?f32 {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (v.len == 0) return null;

    var end: usize = 0;
    while (end < v.len) : (end += 1) {
        const c = v[end];
        if (!((c >= '0' and c <= '9') or c == '.' or c == '-')) break;
    }

    const num_str = v[0..end];
    if (num_str.len == 0) return null;

    const num = std.fmt.parseFloat(f32, num_str) catch return null;

    if (end < v.len and v[end] != ' ') {
        const unit = std.mem.trim(u8, v[end..], " \t\n\r\x0C");
        if (eqlProp(unit, "px") or unit.len == 0) return num;
        // ponytail: em/rem/% need font-size context, defer
        if (eqlProp(unit, "em") or eqlProp(unit, "rem") or unit[0] == '%') return num;
        return null;
    }

    return num;
}

fn parseFirstLength(value: []const u8) f32 {
    var iter = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");
    while (iter.next()) |token| {
        if (parseLength(token)) |len| return len;
    }
    return 0;
}

fn parseEdges(value: []const u8) box.EdgeSizes {
    var parts: [4]?f32 = .{ null, null, null, null };
    var i: usize = 0;
    var iter = std.mem.tokenizeAny(u8, value, " \t\n\r\x0C");

    while (iter.next()) |token| : (i += 1) {
        if (i >= 4) break;
        parts[i] = parseLength(token);
    }

    return switch (i) {
        0 => .{},
        1 => .{ .top = parts[0].?, .right = parts[0].?, .bottom = parts[0].?, .left = parts[0].? },
        2 => .{ .top = parts[0].?, .right = parts[1].?, .bottom = parts[0].?, .left = parts[1].? },
        3 => .{ .top = parts[0].?, .right = parts[1].?, .bottom = parts[2].?, .left = parts[1].? },
        else => .{ .top = parts[0].?, .right = parts[1].?, .bottom = parts[2].?, .left = parts[3].? },
    };
}

fn parseTextAlign(value: []const u8) ?box.TextAlign {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "left")) return .left;
    if (eqlProp(v, "center")) return .center;
    if (eqlProp(v, "right")) return .right;
    if (eqlProp(v, "justify")) return .justify;
    return null;
}

fn parseBoxSizing(value: []const u8) ?box.BoxSizing {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "content-box")) return .contentBox;
    if (eqlProp(v, "border-box")) return .borderBox;
    return null;
}

fn parsePageBreak(value: []const u8) ?box.PageBreak {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "auto")) return .auto;
    if (eqlProp(v, "always")) return .always;
    if (eqlProp(v, "avoid")) return .avoid;
    return null;
}

fn parseBorderStyle(value: []const u8) ?box.BorderStyle {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (eqlProp(v, "none")) return .none;
    if (eqlProp(v, "solid")) return .solid;
    if (eqlProp(v, "dashed")) return .dashed;
    if (eqlProp(v, "dotted")) return .dotted;
    return null;
}

fn parsePositiveInteger(value: []const u8) ?u32 {
    const v = std.mem.trim(u8, value, " \t\n\r\x0C");
    const n = std.fmt.parseInt(u32, v, 10) catch return null;
    if (n == 0) return null;
    return n;
}

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

    // ponytail: fixed buffer for match collection, enlarge if complex stylesheets overflow
    var match_buf: [64]Match = undefined;

    computeStylesRecursive(document, stylesheets, styles, document.root, null, &match_buf, arena);

    return styles;
}

fn computeStylesRecursive(
    document: *const dom.Document,
    stylesheets: []const Stylesheet,
    styles: []box.Style,
    node_id: dom.NodeId,
    parent_style: ?*const box.Style,
    match_buf: []Match,
    scratch: std.mem.Allocator,
) void {
    var style = box.defaultStyleForNode(document, node_id);

    if (parent_style) |ps| {
        style.font_size = ps.font_size;
        style.font_family = ps.font_family;
        style.color = ps.color;
        style.white_space = ps.white_space;
    }

    var match_count: usize = 0;

    for (stylesheets, 0..) |ss, ss_idx| {
        for (ss.rules, 0..) |rule, rule_idx| {
            for (rule.selectors) |sel| {
                if (matchesSelector(sel, node_id, document)) {
                    if (match_count < match_buf.len) {
                        match_buf[match_count] = Match{
                            .stylesheet_idx = @intCast(ss_idx),
                            .rule_idx = @intCast(rule_idx),
                            .specificity = selectorSpecificity(sel),
                        };
                        match_count += 1;
                    }
                    break;
                }
            }
        }
    }

    std.mem.sort(Match, match_buf[0..match_count], {}, compareMatchBySpecificity);

    for (match_buf[0..match_count]) |m| {
        const rule = stylesheets[m.stylesheet_idx].rules[m.rule_idx];
        for (rule.declarations) |decl| {
            applyDeclaration(&style, decl.name, decl.value);
        }
    }

    styles[node_id] = style;

    const node = document.nodes.items[node_id];
    var child = node.first_child;
    while (child) |child_id| {
        computeStylesRecursive(document, stylesheets, styles, child_id, &style, match_buf, scratch);
        child = document.nodes.items[child_id].next_sibling;
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
    // ponytail: stylesheet memory freed by arena

    return computeStyles(arena, document, &.{stylesheet});
}

// ---------------------------------------------------------------
// Tests
// ---------------------------------------------------------------

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

test "parse value: display keywords" {
    try std.testing.expectEqual(box.Display.block, parseDisplay("block").?);
    try std.testing.expectEqual(box.Display.inlineBox, parseDisplay("inline").?);
    try std.testing.expectEqual(box.Display.none, parseDisplay("none").?);
    try std.testing.expectEqual(box.Display.inlineBlock, parseDisplay("inline-block").?);
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
    try std.testing.expectEqual(box.TextAlign.left, parseTextAlign("left").?);
    try std.testing.expectEqual(box.TextAlign.center, parseTextAlign("center").?);
    try std.testing.expectEqual(box.TextAlign.right, parseTextAlign("right").?);
    try std.testing.expectEqual(box.TextAlign.justify, parseTextAlign("justify").?);
}

test "parse value: box-sizing" {
    try std.testing.expectEqual(box.BoxSizing.contentBox, parseBoxSizing("content-box").?);
    try std.testing.expectEqual(box.BoxSizing.borderBox, parseBoxSizing("border-box").?);
}

test "parse value: page-break" {
    try std.testing.expectEqual(box.PageBreak.auto, parsePageBreak("auto").?);
    try std.testing.expectEqual(box.PageBreak.always, parsePageBreak("always").?);
    try std.testing.expectEqual(box.PageBreak.avoid, parsePageBreak("avoid").?);
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
    try std.testing.expectEqual(@as(?f32, 200), ct.styles[div_id].width);
    try std.testing.expectEqual(@as(?f32, 100), ct.styles[div_id].height);
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

test "cascade: text-align and line-height" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>p { text-align: center; line-height: 1.5; }</style><p>centered</p>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const p_id = ct.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqual(box.TextAlign.center, ct.styles[p_id].text_align);
    try std.testing.expectEqual(@as(f32, 1.5), ct.styles[p_id].line_height);
}

test "cascade: page-break and orphans/widows" {
    const allocator = std.testing.allocator;
    var ct = try cascadeTestHelper(allocator, "<style>div { page-break-before: always; page-break-after: avoid; orphans: 3; widows: 4; }</style><div>page</div>");
    defer ct.deinit(allocator);
    const style_id = ct.document.nodes.items[ct.document.root].first_child.?;
    const div_id = ct.document.nodes.items[style_id].next_sibling.?;
    try std.testing.expectEqual(box.PageBreak.always, ct.styles[div_id].page_break_before);
    try std.testing.expectEqual(box.PageBreak.avoid, ct.styles[div_id].page_break_after);
    try std.testing.expectEqual(@as(u32, 3), ct.styles[div_id].orphans);
    try std.testing.expectEqual(@as(u32, 4), ct.styles[div_id].widows);
}
