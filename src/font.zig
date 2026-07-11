//! TrueType parsing and deterministic built-in font selection.
//!
//! The renderer ships four OFL-licensed Noto Sans faces. This module only
//! parses the tables needed for layout and PDF embedding; it intentionally
//! leaves shaping behind a small interface so a future shaper can replace the
//! one-codepoint-to-one-glyph path without changing layout ownership.

const std = @import("std");
const box = @import("box.zig");

pub const Error = error{
    InvalidFont,
    MissingRequiredTable,
    UnsupportedCmap,
    RestrictedEmbedding,
    InvalidUtf8,
};

pub const Face = enum {
    regular,
    bold,
    italic,
    bold_italic,

    pub fn bytes(self: Face) []const u8 {
        return switch (self) {
            .regular => @embedFile("assets/fonts/NotoSans-Regular.ttf"),
            .bold => @embedFile("assets/fonts/NotoSans-Bold.ttf"),
            .italic => @embedFile("assets/fonts/NotoSans-Italic.ttf"),
            .bold_italic => @embedFile("assets/fonts/NotoSans-BoldItalic.ttf"),
        };
    }

    pub fn postscriptName(self: Face) []const u8 {
        return switch (self) {
            .regular => "NotoSans-Regular",
            .bold => "NotoSans-Bold",
            .italic => "NotoSans-Italic",
            .bold_italic => "NotoSans-BoldItalic",
        };
    }
};

pub fn faceFor(weight: box.FontWeight, style: box.FontStyle) Face {
    return switch (weight) {
        .normal => if (style == .italic) .italic else .regular,
        .bold => if (style == .italic) .bold_italic else .bold,
    };
}

pub const RegisteredFont = struct {
    family: []const u8,
    postscript_name: []const u8,
    data: []const u8,
    weight: box.FontWeight = .normal,
    style: box.FontStyle = .normal,
    unicode_ranges: []const UnicodeRange = &.{},
};

pub const UnicodeRange = struct {
    start: u21,
    end: u21,

    pub fn contains(self: UnicodeRange, codepoint: u21) bool {
        return codepoint >= self.start and codepoint <= self.end;
    }
};

pub const Registry = struct {
    fonts: []const RegisteredFont = &.{},
};

pub const ResolvedFont = struct {
    id: usize,
    family: []const u8,
    postscript_name: []const u8,
    data: []const u8,
    weight: box.FontWeight,
    style: box.FontStyle,

    pub fn metrics(self: ResolvedFont) Metrics {
        return Metrics.parse(self.data) catch unreachable;
    }
};

pub fn resolve(
    registry: ?*const Registry,
    family_list: []const u8,
    weight: box.FontWeight,
    style: box.FontStyle,
) ResolvedFont {
    if (registry) |available| {
        var families = std.mem.splitScalar(u8, family_list, ',');
        while (families.next()) |raw_family| {
            const family = trimFamilyName(raw_family);
            var fallback: ?usize = null;
            for (available.fonts, 0..) |registered, index| {
                if (!std.ascii.eqlIgnoreCase(registered.family, family)) continue;
                if (registered.weight == weight and registered.style == style) return .{
                    .id = 4 + index,
                    .family = registered.family,
                    .postscript_name = registered.postscript_name,
                    .data = registered.data,
                    .weight = registered.weight,
                    .style = registered.style,
                };
                if (fallback == null) fallback = index;
            }
            if (fallback) |index| {
                const registered = available.fonts[index];
                return .{
                    .id = 4 + index,
                    .family = registered.family,
                    .postscript_name = registered.postscript_name,
                    .data = registered.data,
                    .weight = registered.weight,
                    .style = registered.style,
                };
            }
        }
    }

    const face = faceFor(weight, style);
    return .{
        .id = @intFromEnum(face),
        .family = "Noto Sans",
        .postscript_name = face.postscriptName(),
        .data = face.bytes(),
        .weight = weight,
        .style = style,
    };
}

/// Resolves the first family in the CSS list that contains a concrete glyph.
/// Style matching is preferred, then a family-local face fallback is allowed,
/// and finally the built-in Noto Sans face is considered.
pub fn resolveForCodepoint(
    registry: ?*const Registry,
    family_list: []const u8,
    weight: box.FontWeight,
    style: box.FontStyle,
    codepoint: u21,
) ?ResolvedFont {
    if (registry) |available| {
        var families = std.mem.splitScalar(u8, family_list, ',');
        while (families.next()) |raw_family| {
            const family = trimFamilyName(raw_family);
            var fallback: ?ResolvedFont = null;
            for (available.fonts, 0..) |registered, index| {
                if (!std.ascii.eqlIgnoreCase(registered.family, family)) continue;
                const candidate = ResolvedFont{
                    .id = 4 + index,
                    .family = registered.family,
                    .postscript_name = registered.postscript_name,
                    .data = registered.data,
                    .weight = registered.weight,
                    .style = registered.style,
                };
                if (!registeredSupportsCodepoint(registered, codepoint) or candidate.metrics().glyphId(codepoint) == 0) continue;
                if (registered.weight == weight and registered.style == style) return candidate;
                if (fallback == null) fallback = candidate;
            }
            if (fallback) |candidate| return candidate;
        }
    }

    const built_in = resolve(null, family_list, weight, style);
    return if (built_in.metrics().glyphId(codepoint) != 0) built_in else null;
}

fn registeredSupportsCodepoint(registered: RegisteredFont, codepoint: u21) bool {
    if (registered.unicode_ranges.len == 0) return true;
    for (registered.unicode_ranges) |range| if (range.contains(codepoint)) return true;
    return false;
}

pub fn measureWithFallback(
    registry: ?*const Registry,
    text: []const u8,
    family_list: []const u8,
    font_size: f32,
    weight: box.FontWeight,
    style: box.FontStyle,
    letter_spacing: f32,
) Error!f32 {
    var width: f32 = 0;
    var iterator = Utf8Iterator{ .bytes = text };
    while (try iterator.next()) |codepoint| {
        const resolved = resolveForCodepoint(registry, family_list, weight, style, codepoint) orelse continue;
        const metrics = resolved.metrics();
        width += @as(f32, @floatFromInt(metrics.advanceWidth(metrics.glyphId(codepoint)))) * font_size /
            @as(f32, @floatFromInt(metrics.units_per_em));
        width += letter_spacing;
    }
    return width;
}

fn trimFamilyName(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\n\r\x0C");
    if (trimmed.len >= 2 and ((trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') or
        (trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"')))
    {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

pub const Metrics = struct {
    data: []const u8,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
    glyph_count: u16,
    number_of_h_metrics: u16,
    hmtx: []const u8,
    cmap: []const u8,
    fs_type: u16,

    pub fn parse(data: []const u8) Error!Metrics {
        if (data.len < 12) return Error.InvalidFont;
        const head = table(data, "head") orelse return Error.MissingRequiredTable;
        const hhea = table(data, "hhea") orelse return Error.MissingRequiredTable;
        const maxp = table(data, "maxp") orelse return Error.MissingRequiredTable;
        const hmtx = table(data, "hmtx") orelse return Error.MissingRequiredTable;
        const cmap_table = table(data, "cmap") orelse return Error.MissingRequiredTable;
        const os2 = table(data, "OS/2") orelse return Error.MissingRequiredTable;
        if (head.len < 54 or hhea.len < 36 or maxp.len < 6 or os2.len < 10) return Error.InvalidFont;

        const units_per_em = try readU16(head, 18);
        const number_of_h_metrics = try readU16(hhea, 34);
        const glyph_count = try readU16(maxp, 4);
        if (units_per_em == 0 or number_of_h_metrics == 0 or glyph_count == 0) return Error.InvalidFont;
        if (@as(usize, number_of_h_metrics) * 4 > hmtx.len) return Error.InvalidFont;

        const fs_type = try readU16(os2, 8);
        if ((fs_type & 0x0002) != 0) return Error.RestrictedEmbedding;

        return .{
            .data = data,
            .units_per_em = units_per_em,
            .ascender = try readI16(hhea, 4),
            .descender = try readI16(hhea, 6),
            .x_min = try readI16(head, 36),
            .y_min = try readI16(head, 38),
            .x_max = try readI16(head, 40),
            .y_max = try readI16(head, 42),
            .glyph_count = glyph_count,
            .number_of_h_metrics = number_of_h_metrics,
            .hmtx = hmtx,
            .cmap = try selectCmap(cmap_table),
            .fs_type = fs_type,
        };
    }

    pub fn glyphId(self: Metrics, codepoint: u21) u16 {
        const format = readU16(self.cmap, 0) catch return 0;
        return switch (format) {
            4 => self.glyphIdFormat4(codepoint),
            12 => self.glyphIdFormat12(codepoint),
            else => 0,
        };
    }

    pub fn advanceWidth(self: Metrics, glyph_id: u16) u16 {
        const metric_index = @min(@as(usize, glyph_id), @as(usize, self.number_of_h_metrics - 1));
        return readU16(self.hmtx, metric_index * 4) catch 0;
    }

    pub fn widthCssPx(self: Metrics, text: []const u8, font_size: f32) Error!f32 {
        var total_units: u64 = 0;
        var iterator = Utf8Iterator{ .bytes = text };
        while (try iterator.next()) |codepoint| {
            total_units += self.advanceWidth(self.glyphId(codepoint));
        }
        return @as(f32, @floatFromInt(total_units)) * font_size / @as(f32, @floatFromInt(self.units_per_em));
    }

    pub fn ascentRatio(self: Metrics) f32 {
        return @as(f32, @floatFromInt(self.ascender)) / @as(f32, @floatFromInt(self.units_per_em));
    }

    fn glyphIdFormat4(self: Metrics, codepoint: u21) u16 {
        if (codepoint > 0xFFFF or self.cmap.len < 16) return 0;
        const segment_count = (readU16(self.cmap, 6) catch return 0) / 2;
        const end_codes = 14;
        const start_codes = end_codes + @as(usize, segment_count) * 2 + 2;
        const deltas = start_codes + @as(usize, segment_count) * 2;
        const range_offsets = deltas + @as(usize, segment_count) * 2;
        const cp: u16 = @intCast(codepoint);

        for (0..segment_count) |index| {
            const end_code = readU16(self.cmap, end_codes + index * 2) catch return 0;
            if (cp > end_code) continue;
            const start_code = readU16(self.cmap, start_codes + index * 2) catch return 0;
            if (cp < start_code) return 0;
            const delta = readI16(self.cmap, deltas + index * 2) catch return 0;
            const range_offset_position = range_offsets + index * 2;
            const range_offset = readU16(self.cmap, range_offset_position) catch return 0;
            if (range_offset == 0) return @bitCast(@as(i16, @bitCast(cp)) +% delta);

            const glyph_position = range_offset_position + @as(usize, range_offset) + @as(usize, cp - start_code) * 2;
            var glyph = readU16(self.cmap, glyph_position) catch return 0;
            if (glyph != 0) glyph = @bitCast(@as(i16, @bitCast(glyph)) +% delta);
            return glyph;
        }
        return 0;
    }

    fn glyphIdFormat12(self: Metrics, codepoint: u21) u16 {
        if (self.cmap.len < 16) return 0;
        const group_count = readU32(self.cmap, 12) catch return 0;
        var low: usize = 0;
        var high: usize = group_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const offset = 16 + middle * 12;
            const start = readU32(self.cmap, offset) catch return 0;
            const end = readU32(self.cmap, offset + 4) catch return 0;
            if (codepoint < start) {
                high = middle;
            } else if (codepoint > end) {
                low = middle + 1;
            } else {
                const first_glyph = readU32(self.cmap, offset + 8) catch return 0;
                const glyph = first_glyph + codepoint - start;
                return if (glyph <= std.math.maxInt(u16)) @intCast(glyph) else 0;
            }
        }
        return 0;
    }
};

pub fn builtInMetrics(face: Face) Metrics {
    return Metrics.parse(face.bytes()) catch unreachable;
}

/// Builds a compact, valid TrueType font while preserving original glyph IDs.
/// Preserving IDs lets the PDF use an Identity CID-to-GID map and keeps the
/// display-list text representation independent from the subsetter.
pub fn subset(allocator: std.mem.Allocator, data: []const u8, requested_glyphs: []const u16) ![]u8 {
    const metrics = try Metrics.parse(data);
    const head_source = table(data, "head") orelse return Error.MissingRequiredTable;
    const loca_source = table(data, "loca") orelse return Error.MissingRequiredTable;
    const glyf_source = table(data, "glyf") orelse return Error.MissingRequiredTable;
    if (head_source.len < 54) return Error.InvalidFont;
    const long_loca = (try readI16(head_source, 50)) == 1;

    const selected = try allocator.alloc(bool, metrics.glyph_count);
    defer allocator.free(selected);
    @memset(selected, false);
    selected[0] = true;
    for (requested_glyphs) |glyph_id| {
        if (glyph_id < metrics.glyph_count) selected[glyph_id] = true;
    }
    try selectCompositeDependencies(selected, loca_source, glyf_source, long_loca);

    const new_offsets = try allocator.alloc(u32, @as(usize, metrics.glyph_count) + 1);
    defer allocator.free(new_offsets);
    var glyf_output = std.Io.Writer.Allocating.init(allocator);
    defer glyf_output.deinit();
    for (0..metrics.glyph_count) |glyph_id| {
        new_offsets[glyph_id] = @intCast(glyf_output.writer.end);
        if (selected[glyph_id]) {
            const range = try glyphRange(loca_source, glyf_source, long_loca, @intCast(glyph_id));
            try glyf_output.writer.writeAll(glyf_source[range.start..range.end]);
            while (glyf_output.writer.end % 4 != 0) try glyf_output.writer.writeByte(0);
        }
    }
    new_offsets[metrics.glyph_count] = @intCast(glyf_output.writer.end);

    const loca_output = try allocator.alloc(u8, new_offsets.len * 4);
    defer allocator.free(loca_output);
    for (new_offsets, 0..) |offset, index| writeU32(loca_output, index * 4, offset);

    const head_output = try allocator.dupe(u8, head_source);
    defer allocator.free(head_output);
    writeU32(head_output, 8, 0);
    writeU16(head_output, 50, 1);

    var tables = try std.ArrayList(TableSource).initCapacity(allocator, 14);
    defer tables.deinit(allocator);
    const copied_tags = [_]*const [4]u8{
        "OS/2", "cmap", "cvt ", "fpgm", "gasp", "hhea", "hmtx", "maxp", "name", "post", "prep",
    };
    for (copied_tags) |tag| {
        if (table(data, tag)) |bytes| try tables.append(allocator, .{ .tag = tag.*, .bytes = bytes });
    }
    try tables.append(allocator, .{ .tag = "glyf".*, .bytes = glyf_output.written() });
    try tables.append(allocator, .{ .tag = "head".*, .bytes = head_output });
    try tables.append(allocator, .{ .tag = "loca".*, .bytes = loca_output });
    std.mem.sort(TableSource, tables.items, {}, tableLessThan);

    const directory_size = 12 + tables.items.len * 16;
    var output_size = directory_size;
    for (tables.items) |source| output_size += align4(source.bytes.len);
    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);
    @memset(output, 0);
    @memcpy(output[0..4], data[0..4]);
    writeU16(output, 4, @intCast(tables.items.len));
    const selector = tableSearchParameters(@intCast(tables.items.len));
    writeU16(output, 6, selector.search_range);
    writeU16(output, 8, selector.entry_selector);
    writeU16(output, 10, selector.range_shift);

    var data_offset = directory_size;
    var head_offset: usize = 0;
    for (tables.items, 0..) |source, index| {
        const record = 12 + index * 16;
        @memcpy(output[record..][0..4], &source.tag);
        writeU32(output, record + 4, tableChecksum(source.bytes));
        writeU32(output, record + 8, @intCast(data_offset));
        writeU32(output, record + 12, @intCast(source.bytes.len));
        @memcpy(output[data_offset..][0..source.bytes.len], source.bytes);
        if (std.mem.eql(u8, &source.tag, "head")) head_offset = data_offset;
        data_offset += align4(source.bytes.len);
    }

    const adjustment = 0xB1B0AFBA -% tableChecksum(output);
    writeU32(output, head_offset + 8, adjustment);
    return output;
}

pub const Utf8Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *Utf8Iterator) Error!?u21 {
        if (self.index >= self.bytes.len) return null;
        const first = self.bytes[self.index];
        const length: usize = std.unicode.utf8ByteSequenceLength(first) catch return Error.InvalidUtf8;
        if (self.index + length > self.bytes.len) return Error.InvalidUtf8;
        const codepoint = std.unicode.utf8Decode(self.bytes[self.index..][0..length]) catch return Error.InvalidUtf8;
        self.index += length;
        return codepoint;
    }
};

const TableSource = struct {
    tag: [4]u8,
    bytes: []const u8,
};

const GlyphRange = struct {
    start: usize,
    end: usize,
};

fn selectCompositeDependencies(selected: []bool, loca: []const u8, glyf: []const u8, long_loca: bool) Error!void {
    var changed = true;
    while (changed) {
        changed = false;
        for (selected, 0..) |is_selected, glyph_id| {
            if (!is_selected) continue;
            const range = try glyphRange(loca, glyf, long_loca, @intCast(glyph_id));
            const glyph = glyf[range.start..range.end];
            if (glyph.len < 10 or try readI16(glyph, 0) >= 0) continue;

            var offset: usize = 10;
            while (offset + 4 <= glyph.len) {
                const flags = try readU16(glyph, offset);
                const component = try readU16(glyph, offset + 2);
                if (component < selected.len and !selected[component]) {
                    selected[component] = true;
                    changed = true;
                }
                offset += 4;
                offset += if ((flags & 0x0001) != 0) 4 else 2;
                if ((flags & 0x0008) != 0) offset += 2;
                if ((flags & 0x0040) != 0) offset += 4;
                if ((flags & 0x0080) != 0) offset += 8;
                if ((flags & 0x0020) == 0) break;
            }
        }
    }
}

fn glyphRange(loca: []const u8, glyf: []const u8, long_loca: bool, glyph_id: u16) Error!GlyphRange {
    const index: usize = glyph_id;
    const start = if (long_loca)
        try readU32(loca, index * 4)
    else
        @as(u32, try readU16(loca, index * 2)) * 2;
    const end = if (long_loca)
        try readU32(loca, (index + 1) * 4)
    else
        @as(u32, try readU16(loca, (index + 1) * 2)) * 2;
    if (start > end or end > glyf.len) return Error.InvalidFont;
    return .{ .start = start, .end = end };
}

fn tableLessThan(_: void, left: TableSource, right: TableSource) bool {
    return std.mem.order(u8, &left.tag, &right.tag) == .lt;
}

fn align4(value: usize) usize {
    return (value + 3) & ~@as(usize, 3);
}

const SearchParameters = struct {
    search_range: u16,
    entry_selector: u16,
    range_shift: u16,
};

fn tableSearchParameters(table_count: u16) SearchParameters {
    var power: u16 = 1;
    var selector: u16 = 0;
    while (power * 2 <= table_count) {
        power *= 2;
        selector += 1;
    }
    return .{
        .search_range = power * 16,
        .entry_selector = selector,
        .range_shift = table_count * 16 - power * 16,
    };
}

fn tableChecksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 4) {
        var word: u32 = 0;
        for (0..4) |index| {
            word <<= 8;
            if (offset + index < bytes.len) word |= bytes[offset + index];
        }
        sum +%= word;
    }
    return sum;
}

fn table(data: []const u8, tag: *const [4]u8) ?[]const u8 {
    const table_count = readU16(data, 4) catch return null;
    if (12 + @as(usize, table_count) * 16 > data.len) return null;
    for (0..table_count) |index| {
        const record = 12 + index * 16;
        if (!std.mem.eql(u8, data[record..][0..4], tag)) continue;
        const offset = readU32(data, record + 8) catch return null;
        const length = readU32(data, record + 12) catch return null;
        const start: usize = offset;
        const end = std.math.add(usize, start, length) catch return null;
        if (end > data.len) return null;
        return data[start..end];
    }
    return null;
}

fn selectCmap(cmap: []const u8) Error![]const u8 {
    if (cmap.len < 4) return Error.InvalidFont;
    const count = try readU16(cmap, 2);
    if (4 + @as(usize, count) * 8 > cmap.len) return Error.InvalidFont;

    var format4: ?[]const u8 = null;
    for (0..count) |index| {
        const record = 4 + index * 8;
        const platform = try readU16(cmap, record);
        const encoding = try readU16(cmap, record + 2);
        const offset = try readU32(cmap, record + 4);
        if (offset + 2 > cmap.len) continue;
        const subtable = cmap[offset..];
        const format = try readU16(subtable, 0);
        if (format == 12 and (platform == 0 or (platform == 3 and encoding == 10))) return subtable;
        if (format == 4 and (platform == 0 or (platform == 3 and encoding == 1))) format4 = subtable;
    }
    return format4 orelse Error.UnsupportedCmap;
}

fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset + 2 > bytes.len) return Error.InvalidFont;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readI16(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try readU16(bytes, offset));
}

fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset + 4 > bytes.len) return Error.InvalidFont;
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value >> 24);
    bytes[offset + 1] = @truncate(value >> 16);
    bytes[offset + 2] = @truncate(value >> 8);
    bytes[offset + 3] = @truncate(value);
}

test "parse built-in Noto Sans metrics" {
    const metrics = try Metrics.parse(Face.regular.bytes());
    try std.testing.expectEqual(@as(u16, 1000), metrics.units_per_em);
    try std.testing.expect(metrics.glyph_count > 1000);
    try std.testing.expect(metrics.glyphId('A') != 0);
    try std.testing.expect(metrics.glyphId('é') != 0);
    try std.testing.expect(metrics.advanceWidth(metrics.glyphId('W')) > metrics.advanceWidth(metrics.glyphId('i')));
    try std.testing.expectEqual(@as(u16, 0), metrics.fs_type);
}

test "measure UTF-8 text from TrueType advances" {
    const metrics = builtInMetrics(.regular);
    const narrow = try metrics.widthCssPx("iiii", 16);
    const wide = try metrics.widthCssPx("WWWW", 16);
    try std.testing.expect(wide > narrow * 2);
    try std.testing.expect((try metrics.widthCssPx("café", 16)) > 0);
}

test "subset keeps requested and composite glyphs in a valid TrueType file" {
    const allocator = std.testing.allocator;
    const metrics = builtInMetrics(.regular);
    const glyphs = [_]u16{ metrics.glyphId('A'), metrics.glyphId('é') };
    const compact = try subset(allocator, Face.regular.bytes(), &glyphs);
    defer allocator.free(compact);
    const compact_metrics = try Metrics.parse(compact);
    try std.testing.expect(compact.len < Face.regular.bytes().len / 2);
    try std.testing.expectEqual(metrics.glyph_count, compact_metrics.glyph_count);
    try std.testing.expectEqual(metrics.glyphId('A'), compact_metrics.glyphId('A'));
    try std.testing.expectEqual(@as(u32, 0xB1B0AFBA), tableChecksum(compact));
}
