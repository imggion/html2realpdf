//! Structured renderer diagnostics shared by CSS, orchestration, and the WASM ABI.

const std = @import("std");

pub const Severity = enum { warning, @"error" };

pub const Phase = enum {
    snapshot,
    parse,
    cascade,
    computed,
    layout,
    fragmentation,
    paint,
    pdf,
};

pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    property: ?[]const u8 = null,
    nodePath: ?[]const u8 = null,
    phase: Phase,
    fallback: ?[]const u8 = null,
};

pub fn serialize(allocator: std.mem.Allocator, values: []const Diagnostic) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try std.json.Stringify.value(values, .{ .emit_null_optional_fields = false }, &output.writer);
    return output.toOwnedSlice();
}

test "serialize diagnostics as stable structured JSON" {
    const allocator = std.testing.allocator;
    const values = [_]Diagnostic{.{
        .code = "UNSUPPORTED_CSS_PROPERTY",
        .severity = .warning,
        .message = "Unsupported CSS property was ignored: filter",
        .property = "filter",
        .phase = .computed,
    }};
    const json = try serialize(allocator, &values);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"severity\":\"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"property\":\"filter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "nodePath") == null);
}
