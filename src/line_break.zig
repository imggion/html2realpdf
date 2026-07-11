//! UTF-8 Unicode line-break opportunities backed by libunibreak UAX #14.

const std = @import("std");
const builtin = @import("builtin");

pub const Opportunity = enum(u8) {
    mandatory = 0,
    allowed = 1,
    prohibited = 2,
    inside_codepoint = 3,
    indeterminate = 4,

    pub fn permitsBreak(self: Opportunity) bool {
        return self == .mandatory or self == .allowed or self == .indeterminate;
    }
};

extern fn set_linebreaks_utf8([*]const u8, usize, ?[*:0]const u8, [*]u8) void;
extern fn set_graphemebreaks_utf8([*]const u8, usize, ?[*:0]const u8, [*]u8) void;
extern fn set_wordbreaks_utf8([*]const u8, usize, ?[*:0]const u8, [*]u8) void;

/// Return one break classification per UTF-8 code unit. A permitted entry at
/// index `i` means the line may end after byte `i`.
pub fn opportunities(
    allocator: std.mem.Allocator,
    text: []const u8,
    language: ?[*:0]const u8,
) std.mem.Allocator.Error![]Opportunity {
    if (text.len == 0) return &.{};
    const raw = try allocator.alloc(u8, text.len);
    set_linebreaks_utf8(text.ptr, text.len, language, raw.ptr);
    return @ptrCast(raw);
}

/// Return a byte-indexed mask whose true entries are extended grapheme-cluster
/// boundaries after that byte. Continuation bytes are always false.
pub fn graphemeBoundaries(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]bool {
    if (text.len == 0) return &.{};
    const raw = try allocator.alloc(u8, text.len);
    defer allocator.free(raw);
    set_graphemebreaks_utf8(text.ptr, text.len, null, raw.ptr);
    const boundaries = try allocator.alloc(bool, text.len);
    for (raw, boundaries) |value, *boundary| boundary.* = value == 0;
    return boundaries;
}

pub fn graphemeBoundariesForLayout(
    allocator: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error![]bool {
    if (!builtin.is_test) return graphemeBoundaries(allocator, text);
    if (text.len == 0) return &.{};
    const boundaries = try allocator.alloc(bool, text.len);
    @memset(boundaries, false);
    var index: usize = 0;
    while (index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + sequence_length, text.len);
        boundaries[end - 1] = true;
        index = end;
    }
    return boundaries;
}

/// Return a byte-indexed mask whose true entries are UAX #29 word boundaries
/// after that byte. The language argument is reserved for backend tailoring.
pub fn wordBoundaries(
    allocator: std.mem.Allocator,
    text: []const u8,
    language: ?[*:0]const u8,
) std.mem.Allocator.Error![]bool {
    if (text.len == 0) return &.{};
    const raw = try allocator.alloc(u8, text.len);
    defer allocator.free(raw);
    set_wordbreaks_utf8(text.ptr, text.len, language, raw.ptr);
    const boundaries = try allocator.alloc(bool, text.len);
    for (raw, boundaries) |value, *boundary| boundary.* = value == 0;
    return boundaries;
}

pub fn wordBoundariesForLayout(
    allocator: std.mem.Allocator,
    text: []const u8,
    language: ?[*:0]const u8,
) std.mem.Allocator.Error![]bool {
    if (!builtin.is_test) return wordBoundaries(allocator, text, language);
    if (text.len == 0) return &.{};
    const boundaries = try allocator.alloc(bool, text.len);
    @memset(boundaries, false);
    var index: usize = 0;
    while (index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + sequence_length, text.len);
        boundaries[end - 1] = text[index] == ' ' or text[index] == '-' or text[index] == '/';
        index = end;
    }
    boundaries[text.len - 1] = true;
    return boundaries;
}

/// Keep standalone layout unit tests independent from linked C objects. The
/// production renderer and the linked line-break gate always use UAX #14.
pub fn opportunitiesForLayout(
    allocator: std.mem.Allocator,
    text: []const u8,
    language: ?[*:0]const u8,
) std.mem.Allocator.Error![]Opportunity {
    if (!builtin.is_test) return opportunities(allocator, text, language);
    if (text.len == 0) return &.{};
    const result = try allocator.alloc(Opportunity, text.len);
    @memset(result, .prohibited);
    var index: usize = 0;
    while (index < text.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + sequence_length, text.len);
        result[end - 1] = if (text[index] == ' ') .allowed else .prohibited;
        index = end;
    }
    result[text.len - 1] = .indeterminate;
    return result;
}
