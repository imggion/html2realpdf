//! Unicode Bidirectional Algorithm bridge for UTF-8 paragraph and line runs.
//!
//! SheenBidi owns UAX #9 resolution. This module copies its byte-indexed
//! levels and runs into renderer-owned slices so no C object outlives a call.

const std = @import("std");
const builtin = @import("builtin");
const harfbuzz = @import("harfbuzz.zig");

pub const Direction = enum {
    ltr,
    rtl,
    auto_ltr,
    auto_rtl,

    fn baseLevel(self: Direction) u8 {
        return switch (self) {
            .ltr => 0,
            .rtl => 1,
            .auto_ltr => 0xFE,
            .auto_rtl => 0xFD,
        };
    }
};

pub const Run = struct {
    start: usize,
    end: usize,
    level: u8,

    pub fn direction(self: Run) harfbuzz.Direction {
        return if (self.level & 1 == 0) .ltr else .rtl;
    }
};

pub const Resolution = struct {
    base_level: u8,
    levels: []const u8,
    logical_runs: []const Run,
    visual_runs: []const Run,

    pub fn deinit(self: *Resolution, allocator: std.mem.Allocator) void {
        if (self.levels.len > 0) allocator.free(self.levels);
        if (self.logical_runs.len > 0) allocator.free(self.logical_runs);
        if (self.visual_runs.len > 0) allocator.free(self.visual_runs);
        self.* = .{ .base_level = 0, .levels = &.{}, .logical_runs = &.{}, .visual_runs = &.{} };
    }
};

const Algorithm = opaque {};
const Paragraph = opaque {};
const Line = opaque {};

const CodepointSequence = extern struct {
    encoding: u32,
    buffer: ?*const anyopaque,
    length: usize,
};

const CRun = extern struct {
    offset: usize,
    length: usize,
    level: u8,
};

extern fn SBAlgorithmCreate(*const CodepointSequence) ?*const Algorithm;
extern fn SBAlgorithmRelease(*const Algorithm) void;
extern fn SBAlgorithmCreateParagraph(*const Algorithm, usize, usize, u8) ?*const Paragraph;
extern fn SBParagraphRelease(*const Paragraph) void;
extern fn SBParagraphGetBaseLevel(*const Paragraph) u8;
extern fn SBParagraphGetLevelsPtr(*const Paragraph) [*]const u8;
extern fn SBParagraphCreateLine(*const Paragraph, usize, usize) ?*const Line;
extern fn SBLineRelease(*const Line) void;
extern fn SBLineGetRunCount(*const Line) usize;
extern fn SBLineGetRunsPtr(*const Line) [*]const CRun;

/// Resolve one UTF-8 paragraph and its complete line into logical levels and
/// UAX #9 L2 visual runs. Offsets remain UTF-8 byte offsets throughout.
pub fn resolve(
    allocator: std.mem.Allocator,
    text: []const u8,
    direction: Direction,
) std.mem.Allocator.Error!Resolution {
    if (text.len == 0) return .{ .base_level = direction.baseLevel() & 1, .levels = &.{}, .logical_runs = &.{}, .visual_runs = &.{} };

    const sequence = CodepointSequence{
        .encoding = 0,
        .buffer = text.ptr,
        .length = text.len,
    };
    const algorithm = SBAlgorithmCreate(&sequence) orelse return error.OutOfMemory;
    defer SBAlgorithmRelease(algorithm);
    const paragraph = SBAlgorithmCreateParagraph(algorithm, 0, text.len, direction.baseLevel()) orelse return error.OutOfMemory;
    defer SBParagraphRelease(paragraph);
    const line = SBParagraphCreateLine(paragraph, 0, text.len) orelse return error.OutOfMemory;
    defer SBLineRelease(line);

    const levels = try allocator.dupe(u8, SBParagraphGetLevelsPtr(paragraph)[0..text.len]);
    errdefer allocator.free(levels);

    var logical = try std.ArrayList(Run).initCapacity(allocator, 4);
    errdefer logical.deinit(allocator);
    var start: usize = 0;
    while (start < text.len) {
        const level = levels[start];
        var end = nextCodepoint(text, start);
        while (end < text.len and levels[end] == level) end = nextCodepoint(text, end);
        try logical.append(allocator, .{ .start = start, .end = end, .level = level });
        start = end;
    }

    const c_visual = SBLineGetRunsPtr(line)[0..SBLineGetRunCount(line)];
    const visual = try allocator.alloc(Run, c_visual.len);
    errdefer allocator.free(visual);
    for (c_visual, visual) |source, *target| {
        target.* = .{
            .start = source.offset,
            .end = source.offset + source.length,
            .level = source.level,
        };
    }

    return .{
        .base_level = SBParagraphGetBaseLevel(paragraph),
        .levels = levels,
        .logical_runs = try logical.toOwnedSlice(allocator),
        .visual_runs = visual,
    };
}

/// Layout's ordinary inline tests intentionally remain standalone `zig test`
/// commands. They use a single-level result; the linked bridge tests exercise
/// the real UAX #9 implementation, and production builds always call it.
pub fn resolveForLayout(
    allocator: std.mem.Allocator,
    text: []const u8,
    direction: Direction,
) std.mem.Allocator.Error!Resolution {
    if (!builtin.is_test) return resolve(allocator, text, direction);
    if (text.len == 0) return .{ .base_level = direction.baseLevel() & 1, .levels = &.{}, .logical_runs = &.{}, .visual_runs = &.{} };
    const level: u8 = if (direction == .rtl or direction == .auto_rtl) 1 else 0;
    const levels = try allocator.alloc(u8, text.len);
    errdefer allocator.free(levels);
    @memset(levels, level);
    const logical = try allocator.alloc(Run, 1);
    errdefer allocator.free(logical);
    logical[0] = .{ .start = 0, .end = text.len, .level = level };
    const visual = try allocator.dupe(Run, logical);
    return .{ .base_level = level, .levels = levels, .logical_runs = logical, .visual_runs = visual };
}

fn nextCodepoint(text: []const u8, start: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
    return @min(start + length, text.len);
}

export fn html2realpdf_sb_malloc(size: usize) ?*anyopaque {
    return harfbuzz.html2realpdf_hb_malloc(size);
}

export fn html2realpdf_sb_realloc(optional_ptr: ?*anyopaque, size: usize) ?*anyopaque {
    return harfbuzz.html2realpdf_hb_realloc(optional_ptr, size);
}

export fn html2realpdf_sb_free(optional_ptr: ?*anyopaque) void {
    harfbuzz.html2realpdf_hb_free(optional_ptr);
}

export fn memset(destination: ?*anyopaque, value: c_int, length: usize) ?*anyopaque {
    const pointer = destination orelse return null;
    const bytes: [*]volatile u8 = @ptrCast(pointer);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    var index: usize = 0;
    while (index < length) : (index += 1) bytes[index] = byte;
    return pointer;
}
