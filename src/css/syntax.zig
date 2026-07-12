//! CSS syntax model and tolerant stylesheet parser.
//!
//! Owns token-level parsing, selector/declaration syntax, malformed-rule
//! recovery, comments, nested block skipping, and author !important parsing.

const std = @import("std");

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
    important: bool = false,
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

        while (!self.eof()) {
            if (self.peek() == '\\') {
                if (!self.consumeIdentEscape()) break;
            } else if (cssIdentChar(self.peek())) {
                _ = self.next();
            } else {
                break;
            }
        }
        return self.input[start..self.pos];
    }

    fn consumeIdentEscape(self: *CssParser) bool {
        if (self.peek() != '\\' or self.pos + 1 >= self.input.len) return false;
        const escaped = self.input[self.pos + 1];
        if (escaped == '\n' or escaped == '\r' or escaped == 0x0C) return false;
        self.advance(2);
        if (!std.ascii.isHex(escaped)) return true;

        var digits: usize = 1;
        while (!self.eof() and digits < 6 and std.ascii.isHex(self.peek())) : (digits += 1) {
            _ = self.next();
        }
        if (!self.eof() and cssWhitespace(self.peek())) {
            const first = self.next();
            if (first == '\r' and self.peek() == '\n') _ = self.next();
        }
        return true;
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
        if (!self.startsDeclarationName()) {
            self.skipMalformedDeclaration();
            return null;
        }

        const name_start = self.pos;
        const name = self.parseDeclarationName();
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
        const parsed_value = splitImportant(value_raw);
        var important = parsed_value.important;

        if (self.peek() == ';') {
            _ = self.next();
        }

        if (!important) important = self.consumeTrailingImportant();

        return Declaration{ .name = name, .value = parsed_value.value, .important = important };
    }

    fn startsDeclarationName(self: *const CssParser) bool {
        if (cssIdentStart(self.peek())) return true;
        return self.peek() == '-' and self.pos + 1 < self.input.len and
            (self.input[self.pos + 1] == '-' or cssIdentStart(self.input[self.pos + 1]));
    }

    fn parseDeclarationName(self: *CssParser) []const u8 {
        const start = self.pos;
        if (!self.startsDeclarationName()) return "";
        while (!self.eof()) {
            if (self.peek() == '\\') {
                if (!self.consumeIdentEscape()) break;
            } else if (cssIdentChar(self.peek())) {
                _ = self.next();
            } else {
                break;
            }
        }
        return self.input[start..self.pos];
    }

    fn consumeTrailingImportant(self: *CssParser) bool {
        const saved = self.pos;
        self.skipWsAndComments();
        if (self.peek() == '!') {
            _ = self.next();
            self.skipWsAndComments();
            const keyword = self.parseIdent();
            if (std.ascii.eqlIgnoreCase(keyword, "important")) {
                self.skipWsAndComments();
                if (self.peek() == ';') _ = self.next();
                return true;
            }
        }
        self.pos = saved;
        return false;
    }

    fn skipMalformedDeclaration(self: *CssParser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == ';' or c == '}' or c == '{') break;
            _ = self.next();
        }
        if (self.peek() == ';') {
            _ = self.next();
        } else if (self.peek() == '{') {
            _ = self.next();
            self.skipBalancedBlock();
        }
    }
};

const ParsedDeclarationValue = struct {
    value: []const u8,
    important: bool,
};

fn splitImportant(raw: []const u8) ParsedDeclarationValue {
    const value = std.mem.trim(u8, raw, " \t\n\r\x0C");
    const marker = std.mem.lastIndexOfScalar(u8, value, '!') orelse return .{ .value = value, .important = false };
    const keyword = std.mem.trim(u8, value[marker + 1 ..], " \t\n\r\x0C");
    if (!std.ascii.eqlIgnoreCase(keyword, "important")) return .{ .value = value, .important = false };
    return .{
        .value = std.mem.trim(u8, value[0..marker], " \t\n\r\x0C"),
        .important = true,
    };
}

fn cssWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C;
}

fn cssIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-' or c == '\\' or c > 0x7F;
}

fn cssIdentChar(c: u8) bool {
    return cssIdentStart(c) or (c >= '0' and c <= '9');
}

pub fn identifierEquals(css_identifier: []const u8, value: []const u8, ascii_insensitive: bool) bool {
    var css_index: usize = 0;
    var value_index: usize = 0;
    while (true) {
        const css_codepoint = nextCssIdentifierCodepoint(css_identifier, &css_index);
        const value_codepoint = nextUtf8Codepoint(value, &value_index);
        if (css_codepoint == null or value_codepoint == null) return css_codepoint == null and value_codepoint == null;
        const left = if (ascii_insensitive and css_codepoint.? <= 0x7F) std.ascii.toLower(@intCast(css_codepoint.?)) else css_codepoint.?;
        const right = if (ascii_insensitive and value_codepoint.? <= 0x7F) std.ascii.toLower(@intCast(value_codepoint.?)) else value_codepoint.?;
        if (left != right) return false;
    }
}

fn nextCssIdentifierCodepoint(input: []const u8, index: *usize) ?u21 {
    if (index.* >= input.len) return null;
    if (input[index.*] != '\\') return nextUtf8Codepoint(input, index);
    index.* += 1;
    if (index.* >= input.len) return 0xFFFD;

    if (std.ascii.isHex(input[index.*])) {
        var value: u32 = 0;
        var digits: usize = 0;
        while (index.* < input.len and digits < 6 and std.ascii.isHex(input[index.*])) : (digits += 1) {
            value = value * 16 + hexValue(input[index.*]);
            index.* += 1;
        }
        if (index.* < input.len and cssWhitespace(input[index.*])) {
            const first = input[index.*];
            index.* += 1;
            if (first == '\r' and index.* < input.len and input[index.*] == '\n') index.* += 1;
        }
        if (value == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) return 0xFFFD;
        return @intCast(value);
    }

    return nextUtf8Codepoint(input, index);
}

fn nextUtf8Codepoint(input: []const u8, index: *usize) ?u21 {
    if (index.* >= input.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(input[index.*]) catch {
        index.* += 1;
        return 0xFFFD;
    };
    if (index.* + length > input.len) {
        index.* = input.len;
        return 0xFFFD;
    }
    const codepoint = std.unicode.utf8Decode(input[index.* .. index.* + length]) catch 0xFFFD;
    index.* += length;
    return codepoint;
}

fn hexValue(byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => 0,
    };
}

// ---------------------------------------------------------------
// Selector matching
// ---------------------------------------------------------------
