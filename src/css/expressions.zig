//! Flat, arena-backed CSS math expression storage and evaluation.
//!
//! Parsed expressions use integer IDs instead of recursively owned nodes. A
//! `Reference` carries the store pointer plus root ID so box styles remain cheap
//! to copy while percentages resolve against the eventual containing block.

const std = @import("std");

pub const Id = u32;

pub const Context = struct {
    font_size: f32 = 16,
    root_font_size: f32 = 16,
    viewport_width: f32 = 800,
    viewport_height: f32 = 600,
};

pub const LengthPercentage = struct {
    px: f32 = 0,
    percent: f32 = 0,

    fn resolve(self: LengthPercentage, reference: f32) f32 {
        return self.px + self.percent * reference;
    }
};

const Pair = struct { left: Id, right: Id };
const Triple = struct { minimum: Id, preferred: Id, maximum: Id };

pub const Node = union(enum) {
    number: f32,
    length: LengthPercentage,
    negate: Id,
    add: Pair,
    subtract: Pair,
    multiply: Pair,
    divide: Pair,
    minimum: Pair,
    maximum: Pair,
    clamp: Triple,
};

pub const Store = struct {
    nodes: std.ArrayList(Node),

    pub fn init(allocator: std.mem.Allocator) !Store {
        return .{ .nodes = try std.ArrayList(Node).initCapacity(allocator, 16) };
    }

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }

    fn append(self: *Store, allocator: std.mem.Allocator, node: Node) !Id {
        const id: Id = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        return id;
    }

    pub fn resolve(self: *const Store, root: Id, reference: f32) ?f32 {
        const value = self.evaluate(root, reference, 0) orelse return null;
        return switch (value) {
            .number => |number| number,
            .length => |length| length.resolve(reference),
        };
    }

    fn evaluate(self: *const Store, id: Id, reference: f32, depth: u8) ?Value {
        if (depth >= 64 or id >= self.nodes.items.len) return null;
        const next_depth = depth + 1;
        return switch (self.nodes.items[id]) {
            .number => |number| .{ .number = number },
            .length => |length| .{ .length = length },
            .negate => |child| negate(self.evaluate(child, reference, next_depth) orelse return null),
            .add => |pair| add(
                self.evaluate(pair.left, reference, next_depth) orelse return null,
                self.evaluate(pair.right, reference, next_depth) orelse return null,
            ),
            .subtract => |pair| subtract(
                self.evaluate(pair.left, reference, next_depth) orelse return null,
                self.evaluate(pair.right, reference, next_depth) orelse return null,
            ),
            .multiply => |pair| multiply(
                self.evaluate(pair.left, reference, next_depth) orelse return null,
                self.evaluate(pair.right, reference, next_depth) orelse return null,
            ),
            .divide => |pair| divide(
                self.evaluate(pair.left, reference, next_depth) orelse return null,
                self.evaluate(pair.right, reference, next_depth) orelse return null,
            ),
            .minimum => |pair| extremum(self, pair, reference, next_depth, .minimum),
            .maximum => |pair| extremum(self, pair, reference, next_depth, .maximum),
            .clamp => |triple| clampValue(self, triple, reference, next_depth),
        };
    }
};

pub const Reference = struct {
    store: *const Store,
    root: Id,

    pub fn resolve(self: Reference, containing_size: f32) ?f32 {
        return self.store.resolve(self.root, containing_size);
    }
};

const Value = union(enum) {
    number: f32,
    length: LengthPercentage,
};

const Extremum = enum { minimum, maximum };

fn negate(value: Value) Value {
    return switch (value) {
        .number => |number| .{ .number = -number },
        .length => |length| .{ .length = .{ .px = -length.px, .percent = -length.percent } },
    };
}

fn add(left: Value, right: Value) ?Value {
    return switch (left) {
        .number => |lhs| switch (right) {
            .number => |rhs| .{ .number = lhs + rhs },
            .length => null,
        },
        .length => |lhs| switch (right) {
            .number => null,
            .length => |rhs| .{ .length = .{ .px = lhs.px + rhs.px, .percent = lhs.percent + rhs.percent } },
        },
    };
}

fn subtract(left: Value, right: Value) ?Value {
    return add(left, negate(right));
}

fn multiply(left: Value, right: Value) ?Value {
    return switch (left) {
        .number => |lhs| switch (right) {
            .number => |rhs| .{ .number = lhs * rhs },
            .length => |rhs| .{ .length = .{ .px = rhs.px * lhs, .percent = rhs.percent * lhs } },
        },
        .length => |lhs| switch (right) {
            .number => |rhs| .{ .length = .{ .px = lhs.px * rhs, .percent = lhs.percent * rhs } },
            .length => null,
        },
    };
}

fn divide(left: Value, right: Value) ?Value {
    const divisor = switch (right) {
        .number => |number| number,
        .length => return null,
    };
    if (divisor == 0) return null;
    return multiply(left, .{ .number = 1 / divisor });
}

fn extremum(store: *const Store, pair: Pair, reference: f32, depth: u8, kind: Extremum) ?Value {
    const left = store.evaluate(pair.left, reference, depth) orelse return null;
    const right = store.evaluate(pair.right, reference, depth) orelse return null;
    const left_resolved = resolvedValue(left, reference) orelse return null;
    const right_resolved = resolvedValue(right, reference) orelse return null;
    const result = if (kind == .minimum) @min(left_resolved, right_resolved) else @max(left_resolved, right_resolved);
    return .{ .length = .{ .px = result } };
}

fn clampValue(store: *const Store, triple: Triple, reference: f32, depth: u8) ?Value {
    const minimum = resolvedValue(store.evaluate(triple.minimum, reference, depth) orelse return null, reference) orelse return null;
    const preferred = resolvedValue(store.evaluate(triple.preferred, reference, depth) orelse return null, reference) orelse return null;
    const maximum = resolvedValue(store.evaluate(triple.maximum, reference, depth) orelse return null, reference) orelse return null;
    return .{ .length = .{ .px = @max(minimum, @min(preferred, maximum)) } };
}

fn resolvedValue(value: Value, reference: f32) ?f32 {
    return switch (value) {
        .number => null,
        .length => |length| length.resolve(reference),
    };
}

pub fn parse(
    allocator: std.mem.Allocator,
    store: *Store,
    source: []const u8,
    context: Context,
) std.mem.Allocator.Error!?Reference {
    var parser = Parser{ .source = source, .allocator = allocator, .store = store, .context = context };
    const root = try parser.parseExpression() orelse return null;
    parser.skipWhitespace();
    if (!parser.eof()) return null;
    return .{ .store = store, .root = root };
}

const Parser = struct {
    source: []const u8,
    allocator: std.mem.Allocator,
    store: *Store,
    context: Context,
    position: usize = 0,

    fn eof(self: *const Parser) bool {
        return self.position >= self.source.len;
    }

    fn peek(self: *const Parser) u8 {
        return if (self.eof()) 0 else self.source[self.position];
    }

    fn skipWhitespace(self: *Parser) void {
        while (!self.eof() and std.ascii.isWhitespace(self.peek())) self.position += 1;
    }

    fn parseExpression(self: *Parser) std.mem.Allocator.Error!?Id {
        return self.parseSum();
    }

    fn parseSum(self: *Parser) std.mem.Allocator.Error!?Id {
        var left = try self.parseProduct() orelse return null;
        while (true) {
            self.skipWhitespace();
            const operator = self.peek();
            if (operator != '+' and operator != '-') break;
            self.position += 1;
            const right = try self.parseProduct() orelse return null;
            left = try self.store.append(self.allocator, if (operator == '+')
                .{ .add = .{ .left = left, .right = right } }
            else
                .{ .subtract = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseProduct(self: *Parser) std.mem.Allocator.Error!?Id {
        var left = try self.parseUnary() orelse return null;
        while (true) {
            self.skipWhitespace();
            const operator = self.peek();
            if (operator != '*' and operator != '/') break;
            self.position += 1;
            const right = try self.parseUnary() orelse return null;
            left = try self.store.append(self.allocator, if (operator == '*')
                .{ .multiply = .{ .left = left, .right = right } }
            else
                .{ .divide = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) std.mem.Allocator.Error!?Id {
        self.skipWhitespace();
        if (self.peek() == '+') {
            self.position += 1;
            return self.parseUnary();
        }
        if (self.peek() == '-') {
            self.position += 1;
            const child = try self.parseUnary() orelse return null;
            return try self.store.append(self.allocator, .{ .negate = child });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) std.mem.Allocator.Error!?Id {
        self.skipWhitespace();
        if (self.peek() == '(') {
            self.position += 1;
            const value = try self.parseExpression() orelse return null;
            self.skipWhitespace();
            if (self.peek() != ')') return null;
            self.position += 1;
            return value;
        }
        if (std.ascii.isAlphabetic(self.peek())) return self.parseFunction();
        return self.parseNumeric();
    }

    fn parseFunction(self: *Parser) std.mem.Allocator.Error!?Id {
        const name_start = self.position;
        while (!self.eof() and (std.ascii.isAlphabetic(self.peek()) or self.peek() == '-')) self.position += 1;
        const name = self.source[name_start..self.position];
        self.skipWhitespace();
        if (self.peek() != '(') return null;
        self.position += 1;

        if (std.ascii.eqlIgnoreCase(name, "calc")) {
            const value = try self.parseExpression() orelse return null;
            return if (self.consumeClosingParen()) value else null;
        }
        if (std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max")) {
            var value = try self.parseExpression() orelse return null;
            var count: usize = 1;
            while (true) {
                self.skipWhitespace();
                if (self.peek() != ',') break;
                self.position += 1;
                const right = try self.parseExpression() orelse return null;
                value = try self.store.append(self.allocator, if (std.ascii.eqlIgnoreCase(name, "min"))
                    .{ .minimum = .{ .left = value, .right = right } }
                else
                    .{ .maximum = .{ .left = value, .right = right } });
                count += 1;
            }
            if (count < 2 or !self.consumeClosingParen()) return null;
            return value;
        }
        if (std.ascii.eqlIgnoreCase(name, "clamp")) {
            const minimum = try self.parseExpression() orelse return null;
            if (!self.consumeComma()) return null;
            const preferred = try self.parseExpression() orelse return null;
            if (!self.consumeComma()) return null;
            const maximum = try self.parseExpression() orelse return null;
            if (!self.consumeClosingParen()) return null;
            return try self.store.append(self.allocator, .{ .clamp = .{
                .minimum = minimum,
                .preferred = preferred,
                .maximum = maximum,
            } });
        }
        return null;
    }

    fn parseNumeric(self: *Parser) std.mem.Allocator.Error!?Id {
        const start = self.position;
        var saw_digit = false;
        while (!self.eof() and std.ascii.isDigit(self.peek())) : (self.position += 1) saw_digit = true;
        if (self.peek() == '.') {
            self.position += 1;
            while (!self.eof() and std.ascii.isDigit(self.peek())) : (self.position += 1) saw_digit = true;
        }
        if (!saw_digit) return null;
        const number = std.fmt.parseFloat(f32, self.source[start..self.position]) catch return null;
        if (self.peek() == '%') {
            self.position += 1;
            return try self.store.append(self.allocator, .{ .length = .{ .percent = number / 100 } });
        }
        const unit_start = self.position;
        while (!self.eof() and std.ascii.isAlphabetic(self.peek())) self.position += 1;
        const unit = self.source[unit_start..self.position];
        if (unit.len == 0) return try self.store.append(self.allocator, .{ .number = number });
        const pixels = unitToPixels(number, unit, self.context) orelse return null;
        return try self.store.append(self.allocator, .{ .length = .{ .px = pixels } });
    }

    fn consumeComma(self: *Parser) bool {
        self.skipWhitespace();
        if (self.peek() != ',') return false;
        self.position += 1;
        return true;
    }

    fn consumeClosingParen(self: *Parser) bool {
        self.skipWhitespace();
        if (self.peek() != ')') return false;
        self.position += 1;
        return true;
    }
};

fn unitToPixels(value: f32, unit: []const u8, context: Context) ?f32 {
    if (std.ascii.eqlIgnoreCase(unit, "px")) return value;
    if (std.ascii.eqlIgnoreCase(unit, "pt")) return value / 0.75;
    if (std.ascii.eqlIgnoreCase(unit, "in")) return value * 96;
    if (std.ascii.eqlIgnoreCase(unit, "cm")) return value * 96 / 2.54;
    if (std.ascii.eqlIgnoreCase(unit, "mm")) return value * 96 / 25.4;
    if (std.ascii.eqlIgnoreCase(unit, "em")) return value * context.font_size;
    if (std.ascii.eqlIgnoreCase(unit, "rem")) return value * context.root_font_size;
    if (std.ascii.eqlIgnoreCase(unit, "ch") or std.ascii.eqlIgnoreCase(unit, "ex")) return value * context.font_size * 0.5;
    if (std.ascii.eqlIgnoreCase(unit, "vw")) return value * context.viewport_width / 100;
    if (std.ascii.eqlIgnoreCase(unit, "vh")) return value * context.viewport_height / 100;
    if (std.ascii.eqlIgnoreCase(unit, "vmin")) return value * @min(context.viewport_width, context.viewport_height) / 100;
    if (std.ascii.eqlIgnoreCase(unit, "vmax")) return value * @max(context.viewport_width, context.viewport_height) / 100;
    return null;
}

test "flat expressions resolve calc min max clamp and viewport units" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator);
    defer store.deinit(allocator);
    const context = Context{ .font_size = 20, .viewport_width = 1200, .viewport_height = 800 };

    const calc = (try parse(allocator, &store, "calc(100% - 2em)", context)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 460), calc.resolve(500).?, 0.001);
    const minimum = (try parse(allocator, &store, "min(80vw, 900px)", context)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 900), minimum.resolve(500).?, 0.001);
    const maximum = (try parse(allocator, &store, "max(25%, 180px)", context)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 180), maximum.resolve(600).?, 0.001);
    const clamped = (try parse(allocator, &store, "clamp(200px, 50%, 420px)", context)).?;
    try std.testing.expectApproxEqAbs(@as(f32, 400), clamped.resolve(800).?, 0.001);
}

test "expression evaluator rejects dimensional multiplication and division by zero" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator);
    defer store.deinit(allocator);
    const invalid_product = (try parse(allocator, &store, "calc(2px * 3px)", .{})).?;
    try std.testing.expect(invalid_product.resolve(100) == null);
    const division_by_zero = (try parse(allocator, &store, "calc(10px / 0)", .{})).?;
    try std.testing.expect(division_by_zero.resolve(100) == null);
}
