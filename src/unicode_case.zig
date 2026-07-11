//! Full Unicode case mapping for CSS text-transform.

const std = @import("std");
const data = @import("unicode_case_data.zig");
const line_break = @import("line_break.zig");

pub const Kind = enum {
    uppercase,
    lowercase,
    capitalize,
};

const Locale = enum {
    root,
    lithuanian,
    turkic,
};

const Unit = struct {
    codepoint: u21,
    start: usize,
    end: usize,
    valid: bool,
};

/// Applies the full default Unicode mappings plus the conditional Lithuanian,
/// Turkish, and Azeri rules required by Unicode SpecialCasing.txt. The caller
/// retains the capitalization state across adjacent DOM text nodes.
pub fn transform(
    allocator: std.mem.Allocator,
    text: []const u8,
    kind: Kind,
    language: []const u8,
    capitalize_next: *bool,
) ![]const u8 {
    const units = try decodeUnits(allocator, text);
    defer allocator.free(units);
    const boundaries = try line_break.wordBoundariesForLayout(allocator, text, null);
    defer if (boundaries.len > 0) allocator.free(boundaries);

    var output = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer output.deinit(allocator);
    const locale = parseLocale(language);
    for (units, 0..) |unit, index| {
        if (!unit.valid) {
            try output.appendSlice(allocator, text[unit.start..unit.end]);
        } else switch (kind) {
            .uppercase => try appendMapped(&output, allocator, units, index, .uppercase, locale),
            .lowercase => try appendMapped(&output, allocator, units, index, .lowercase, locale),
            .capitalize => {
                if (capitalize_next.* and isCased(unit.codepoint)) {
                    try appendMapped(&output, allocator, units, index, .titlecase, locale);
                } else {
                    try appendCodepoint(&output, allocator, unit.codepoint);
                }
            },
        }
        updateState(text, unit, boundaries, capitalize_next);
    }
    return output.toOwnedSlice(allocator);
}

/// Updates word state for untransformed text so a later adjacent inline using
/// capitalize observes the same typographic word boundary.
pub fn updateCapitalizeState(
    allocator: std.mem.Allocator,
    text: []const u8,
    capitalize_next: *bool,
) !void {
    const units = try decodeUnits(allocator, text);
    defer allocator.free(units);
    const boundaries = try line_break.wordBoundariesForLayout(allocator, text, null);
    defer if (boundaries.len > 0) allocator.free(boundaries);
    for (units) |unit| updateState(text, unit, boundaries, capitalize_next);
}

const MappingKind = enum { uppercase, lowercase, titlecase };

fn appendMapped(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    units: []const Unit,
    index: usize,
    kind: MappingKind,
    locale: Locale,
) !void {
    if (specialMapping(units, index, kind, locale)) |mapping| {
        for (mapping) |codepoint| try appendCodepoint(output, allocator, codepoint);
        return;
    }
    const codepoint = units[index].codepoint;
    const mapping = switch (kind) {
        .uppercase => findMapping(&data.upper_mappings, &data.upper_data, codepoint),
        .lowercase => findMapping(&data.lower_mappings, &data.lower_data, codepoint),
        .titlecase => findMapping(&data.title_mappings, &data.title_data, codepoint),
    };
    if (mapping) |mapped| {
        for (mapped) |value| try appendCodepoint(output, allocator, value);
    } else {
        try appendCodepoint(output, allocator, codepoint);
    }
}

fn specialMapping(units: []const Unit, index: usize, kind: MappingKind, locale: Locale) ?[]const u21 {
    const codepoint = units[index].codepoint;
    if (kind == .lowercase and codepoint == 0x03A3) {
        return if (isFinalSigma(units, index)) &.{0x03C2} else &.{0x03C3};
    }

    if (locale == .lithuanian and kind == .lowercase) {
        if (codepoint == 0x0307 and isAfterSoftDotted(units, index)) return &.{};
        if (hasMoreAbove(units, index)) switch (codepoint) {
            0x0049 => return &.{ 0x0069, 0x0307 },
            0x004A => return &.{ 0x006A, 0x0307 },
            0x012E => return &.{ 0x012F, 0x0307 },
            else => {},
        };
        return switch (codepoint) {
            0x00CC => &.{ 0x0069, 0x0307, 0x0300 },
            0x00CD => &.{ 0x0069, 0x0307, 0x0301 },
            0x0128 => &.{ 0x0069, 0x0307, 0x0303 },
            else => null,
        };
    }

    if (locale == .turkic) {
        if (kind == .lowercase) return switch (codepoint) {
            0x0130 => &.{0x0069},
            0x0307 => if (isAfterI(units, index)) &.{} else null,
            0x0049 => if (!isBeforeDot(units, index)) &.{0x0131} else null,
            else => null,
        };
        if ((kind == .uppercase or kind == .titlecase) and codepoint == 0x0069) return &.{0x0130};
    }
    return null;
}

fn findMapping(mappings: []const data.Mapping, values: []const u21, codepoint: u21) ?[]const u21 {
    var low: usize = 0;
    var high = mappings.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = mappings[middle];
        if (entry.codepoint < codepoint) {
            low = middle + 1;
        } else if (entry.codepoint > codepoint) {
            high = middle;
        } else {
            const start: usize = entry.offset;
            return values[start .. start + entry.length];
        }
    }
    return null;
}

fn decodeUnits(allocator: std.mem.Allocator, text: []const u8) ![]Unit {
    var units = try std.ArrayList(Unit).initCapacity(allocator, text.len);
    errdefer units.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + length, text.len);
        const codepoint = std.unicode.utf8Decode(text[index..end]) catch {
            try units.append(allocator, .{ .codepoint = 0xFFFD, .start = index, .end = index + 1, .valid = false });
            index += 1;
            continue;
        };
        try units.append(allocator, .{ .codepoint = codepoint, .start = index, .end = end, .valid = true });
        index = end;
    }
    return units.toOwnedSlice(allocator);
}

fn appendCodepoint(output: *std.ArrayList(u8), allocator: std.mem.Allocator, codepoint: u21) std.mem.Allocator.Error!void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
    try output.appendSlice(allocator, encoded[0..length]);
}

fn updateState(text: []const u8, unit: Unit, boundaries: []const bool, capitalize_next: *bool) void {
    if (unit.valid and isCased(unit.codepoint)) capitalize_next.* = false;
    if (unit.end < text.len and boundaries[unit.end - 1]) {
        capitalize_next.* = true;
    } else if (unit.end == text.len and isExplicitWordSeparator(unit.codepoint)) {
        capitalize_next.* = true;
    }
}

fn parseLocale(language: []const u8) Locale {
    const separator = std.mem.indexOfAny(u8, language, "-_") orelse language.len;
    const primary = language[0..separator];
    if (std.ascii.eqlIgnoreCase(primary, "lt")) return .lithuanian;
    if (std.ascii.eqlIgnoreCase(primary, "tr") or std.ascii.eqlIgnoreCase(primary, "az")) return .turkic;
    return .root;
}

fn isFinalSigma(units: []const Unit, index: usize) bool {
    var before = index;
    var cased_before = false;
    while (before > 0) {
        before -= 1;
        const codepoint = units[before].codepoint;
        if (isCaseIgnorable(codepoint)) continue;
        cased_before = isCased(codepoint);
        break;
    }
    if (!cased_before) return false;
    for (units[index + 1 ..]) |unit| {
        if (isCaseIgnorable(unit.codepoint)) continue;
        return !isCased(unit.codepoint);
    }
    return true;
}

fn isAfterSoftDotted(units: []const Unit, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        const codepoint = units[cursor].codepoint;
        const class = combiningClass(codepoint);
        if (class == 0 or class == 230) return isSoftDotted(codepoint);
    }
    return false;
}

fn hasMoreAbove(units: []const Unit, index: usize) bool {
    for (units[index + 1 ..]) |unit| {
        const class = combiningClass(unit.codepoint);
        if (class == 230) return true;
        if (class == 0) return false;
    }
    return false;
}

fn isBeforeDot(units: []const Unit, index: usize) bool {
    for (units[index + 1 ..]) |unit| {
        if (unit.codepoint == 0x0307) return true;
        const class = combiningClass(unit.codepoint);
        if (class == 0 or class == 230) return false;
    }
    return false;
}

fn isAfterI(units: []const Unit, index: usize) bool {
    var cursor = index;
    while (cursor > 0) {
        cursor -= 1;
        const codepoint = units[cursor].codepoint;
        const class = combiningClass(codepoint);
        if (class == 0 or class == 230) return codepoint == 0x0049;
    }
    return false;
}

fn isCased(codepoint: u21) bool {
    return inRanges(&data.cased_ranges, codepoint);
}

fn isCaseIgnorable(codepoint: u21) bool {
    return inRanges(&data.case_ignorable_ranges, codepoint);
}

fn isSoftDotted(codepoint: u21) bool {
    return inRanges(&data.soft_dotted_ranges, codepoint);
}

fn inRanges(ranges: []const data.Range, codepoint: u21) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = ranges[middle];
        if (codepoint < entry.start) {
            high = middle;
        } else if (codepoint > entry.end) {
            low = middle + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn combiningClass(codepoint: u21) u8 {
    var low: usize = 0;
    var high = data.combining_classes.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = data.combining_classes[middle];
        if (entry.codepoint < codepoint) {
            low = middle + 1;
        } else if (entry.codepoint > codepoint) {
            high = middle;
        } else {
            return entry.class;
        }
    }
    return 0;
}

fn isExplicitWordSeparator(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == '\t' or codepoint == '\n' or codepoint == '\r' or
        codepoint == 0x0C or codepoint == '-' or codepoint == '/';
}

fn expectTransform(input: []const u8, kind: Kind, language: []const u8, expected: []const u8) !void {
    var capitalize_next = true;
    const actual = try transform(std.testing.allocator, input, kind, language, &capitalize_next);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "full default mappings expand multi-codepoint uppercase" {
    try expectTransform("straße ﬁancée", .uppercase, "", "STRASSE FIANCÉE");
    try expectTransform("İ", .lowercase, "", "i\u{307}");
}

test "lowercase chooses final Greek sigma from context" {
    try expectTransform("ΟΣ ΟΣΑ", .lowercase, "el", "ος οσα");
}

test "Turkic and Lithuanian SpecialCasing rules use content language" {
    try expectTransform("Iİ iı", .lowercase, "tr", "ıi iı");
    try expectTransform("Iİ iı", .uppercase, "az-Latn", "Iİ İI");
    try expectTransform("I\u{301}", .lowercase, "lt", "i\u{307}\u{301}");
}

test "capitalize titlecases the first Unicode letter of each word" {
    try expectTransform("élan vital", .capitalize, "fr", "Élan Vital");
}
