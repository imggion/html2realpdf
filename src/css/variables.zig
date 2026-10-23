//! Inherited custom-property scopes and recursive `var()` substitution.
//!
//! Scopes form a flat parent chain per DOM node. Values remain token strings
//! until a normal property requests substitution, matching CSS custom-property
//! inheritance and allowing fallback/cycle handling before typed parsing.

const std = @import("std");

pub const max_expanded_value_bytes = 64 * 1024;
pub const max_expansion_bytes = 8 * 1024 * 1024;
pub const max_substitutions = 65536;
const ResolveError = std.mem.Allocator.Error || error{CssExpansionLimitExceeded};

/// Shared by every scope in one cascade, including intermediate expansions.
const ExpansionBudget = struct {
    bytes: usize = max_expansion_bytes,
    substitutions: usize = max_substitutions,
};

pub const CustomValue = union(enum) {
    invalid,
    raw: []const u8,
};

pub const Scope = struct {
    parent: ?*const Scope,
    values: std.StringHashMapUnmanaged(CustomValue) = .empty,
    budget: *ExpansionBudget,

    pub fn create(allocator: std.mem.Allocator, parent: ?*const Scope) !*Scope {
        const scope = try allocator.create(Scope);
        errdefer allocator.destroy(scope);
        const budget = if (parent) |p| p.budget else try allocator.create(ExpansionBudget);
        if (parent == null) budget.* = .{};
        scope.* = .{ .parent = parent, .budget = budget };
        return scope;
    }

    pub fn set(self: *Scope, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " \t\n\r\x0C");
        if (std.ascii.eqlIgnoreCase(trimmed, "inherit") or std.ascii.eqlIgnoreCase(trimmed, "unset")) {
            return;
        }
        const custom: CustomValue = if (std.ascii.eqlIgnoreCase(trimmed, "initial")) .invalid else .{ .raw = trimmed };
        try self.values.put(allocator, name, custom);
    }

    pub fn lookup(self: *const Scope, name: []const u8) ?CustomValue {
        var current: ?*const Scope = self;
        while (current) |scope| {
            if (scope.values.get(name)) |value| return value;
            current = scope.parent;
        }
        return null;
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    scope: *const Scope,
    value: []const u8,
) !?[]const u8 {
    if (findVarFunction(value, 0) == null) return value;
    var stack = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer stack.deinit(allocator);
    return resolveValue(allocator, scope, value, &stack, 0);
}

fn resolveValue(
    allocator: std.mem.Allocator,
    scope: *const Scope,
    value: []const u8,
    stack: *std.ArrayList([]const u8),
    depth: u8,
) ResolveError!?[]const u8 {
    if (depth >= 64) return null;
    if (value.len > max_expanded_value_bytes) return error.CssExpansionLimitExceeded;
    const first = findVarFunction(value, 0) orelse return value;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var cursor: usize = 0;
    var function_start: ?usize = first;

    while (function_start) |start| {
        if (scope.budget.substitutions == 0) return error.CssExpansionLimitExceeded;
        scope.budget.substitutions -= 1;
        try appendExpanded(allocator, &output, value[cursor..start], scope.budget);
        const open = start + 3;
        const close = findClosingParen(value, open) orelse return null;
        const arguments = value[open + 1 .. close];
        const comma = findTopLevelComma(arguments);
        const name = std.mem.trim(u8, arguments[0 .. comma orelse arguments.len], " \t\n\r\x0C");
        const fallback = if (comma) |index| std.mem.trim(u8, arguments[index + 1 ..], " \t\n\r\x0C") else null;
        if (!std.mem.startsWith(u8, name, "--") or name.len <= 2) return null;

        const replacement = try resolveCustom(allocator, scope, name, stack, depth + 1) orelse blk: {
            const fallback_value = fallback orelse return null;
            break :blk try resolveValue(allocator, scope, fallback_value, stack, depth + 1) orelse return null;
        };
        try appendExpanded(allocator, &output, replacement, scope.budget);
        cursor = close + 1;
        function_start = findVarFunction(value, cursor);
    }

    try appendExpanded(allocator, &output, value[cursor..], scope.budget);
    const owned = try output.toOwnedSlice(allocator);
    return @as([]const u8, owned);
}

fn appendExpanded(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8, budget: *ExpansionBudget) ResolveError!void {
    if (value.len > max_expanded_value_bytes - output.items.len or value.len > budget.bytes) return error.CssExpansionLimitExceeded;
    budget.bytes -= value.len;
    try output.appendSlice(allocator, value);
}

fn resolveCustom(
    allocator: std.mem.Allocator,
    scope: *const Scope,
    name: []const u8,
    stack: *std.ArrayList([]const u8),
    depth: u8,
) ResolveError!?[]const u8 {
    for (stack.items) |active| {
        if (std.mem.eql(u8, active, name)) return null;
    }
    const custom = scope.lookup(name) orelse return null;
    const raw = switch (custom) {
        .invalid => return null,
        .raw => |value| value,
    };
    try stack.append(allocator, name);
    defer _ = stack.pop();
    return resolveValue(allocator, scope, raw, stack, depth);
}

fn findVarFunction(value: []const u8, from: usize) ?usize {
    var index = from;
    while (index + 4 <= value.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(value[index .. index + 3], "var")) continue;
        if (value[index + 3] != '(') continue;
        if (index > 0 and isIdent(value[index - 1])) continue;
        return index;
    }
    return null;
}

fn findClosingParen(value: []const u8, open: usize) ?usize {
    if (open >= value.len or value[open] != '(') return null;
    var depth: usize = 1;
    var quote: ?u8 = null;
    var index = open + 1;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (quote) |active| {
            if (byte == '\\') index += 1 else if (byte == active) quote = null;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '(') {
            depth += 1;
        } else if (byte == ')') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn findTopLevelComma(value: []const u8) ?usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (quote) |active| {
            if (byte == '\\') index += 1 else if (byte == active) quote = null;
            continue;
        }
        if (byte == '\'' or byte == '"') quote = byte else if (byte == '(') depth += 1 else if (byte == ')') {
            if (depth > 0) depth -= 1;
        } else if (byte == ',' and depth == 0) return index;
    }
    return null;
}

fn isIdent(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

test "custom properties inherit and var resolves nested fallbacks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const root = try Scope.create(allocator, null);
    try root.set(allocator, "--space", "12px");
    try root.set(allocator, "--card-width", "calc(100% - var(--space))");
    const child = try Scope.create(allocator, root);

    try std.testing.expectEqualStrings("calc(100% - 12px)", (try resolve(allocator, child, "var(--card-width)")).?);
    try std.testing.expectEqualStrings("24px", (try resolve(allocator, child, "var(--missing, var(--fallback, 24px))")).?);
}

test "var cycles use fallback or invalidate the declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const scope = try Scope.create(allocator, null);
    try scope.set(allocator, "--a", "var(--b)");
    try scope.set(allocator, "--b", "var(--a)");
    try std.testing.expect((try resolve(allocator, scope, "var(--a)")) == null);
    try std.testing.expectEqualStrings("10px", (try resolve(allocator, scope, "var(--a, 10px)")).?);
}

test "var expansion rejects exponential output before exhausting memory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const scope = try Scope.create(allocator, null);
    try scope.set(allocator, "--x0", "1px");
    for (1..19) |index| {
        const name = try std.fmt.allocPrint(allocator, "--x{d}", .{index});
        const value = try std.fmt.allocPrint(allocator, "var(--x{d}) var(--x{d})", .{ index - 1, index - 1 });
        try scope.set(allocator, name, value);
    }
    try std.testing.expectError(error.CssExpansionLimitExceeded, resolve(allocator, scope, "var(--x18)"));
}

test "var expansion budgets span declarations and descendant scopes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const root = try Scope.create(allocator, null);
    const child = try Scope.create(allocator, root);
    try root.set(allocator, "--x", "1px");
    root.budget.bytes = 6;
    try std.testing.expectEqualStrings("1px", (try resolve(allocator, root, "var(--x)")).?);
    try std.testing.expectEqualStrings("1px", (try resolve(allocator, child, "var(--x)")).?);
    try std.testing.expectError(error.CssExpansionLimitExceeded, resolve(allocator, child, "var(--x)"));

    const empty = try Scope.create(allocator, null);
    try empty.set(allocator, "--empty", "");
    empty.budget.substitutions = 2;
    try std.testing.expectEqualStrings("", (try resolve(allocator, empty, "var(--empty)var(--empty)")).?);
    try std.testing.expectError(error.CssExpansionLimitExceeded, resolve(allocator, empty, "var(--empty)"));
}

test "var expanded value accepts the limit and rejects one extra byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const scope = try Scope.create(allocator, null);
    const value = try allocator.alloc(u8, max_expanded_value_bytes);
    @memset(value, 'x');
    try scope.set(allocator, "--value", value);
    try std.testing.expectEqualStrings(value, (try resolve(allocator, scope, "var(--value)")).?);
    try std.testing.expectError(error.CssExpansionLimitExceeded, resolve(allocator, scope, "var(--value)x"));
}
