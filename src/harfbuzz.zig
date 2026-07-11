//! Minimal HarfBuzz bridge for native and freestanding WebAssembly shaping.
//!
//! HarfBuzz is compiled with its tiny profile and custom allocator symbols.
//! The bridge deliberately exposes only positioned glyphs and UTF-8 clusters;
//! font ownership and PDF mapping remain in the Zig renderer.

const std = @import("std");
const builtin = @import("builtin");

pub const Direction = enum {
    ltr,
    rtl,
};

pub const Glyph = struct {
    glyph_id: u16,
    x_advance: i32,
    y_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    cluster_start: u32,
    cluster_end: u32,
    maps_cluster: bool = true,
};

pub const Run = struct {
    glyphs: []const Glyph,
    direction: Direction = .ltr,
};

const Blob = opaque {};
const Face = opaque {};
const Font = opaque {};
const Buffer = opaque {};

const GlyphInfo = extern struct {
    codepoint: u32,
    mask: u32,
    cluster: u32,
    var1: u32,
    var2: u32,
};

const GlyphPosition = extern struct {
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
    variation: u32,
};

extern fn hb_blob_create([*]const u8, c_uint, c_uint, ?*anyopaque, ?*const anyopaque) ?*Blob;
extern fn hb_blob_destroy(*Blob) void;
extern fn hb_face_create(*Blob, c_uint) ?*Face;
extern fn hb_face_destroy(*Face) void;
extern fn hb_font_create(*Face) ?*Font;
extern fn hb_font_destroy(*Font) void;
extern fn hb_ot_font_set_funcs(*Font) void;
extern fn hb_font_set_scale(*Font, c_int, c_int) void;
extern fn hb_buffer_create() ?*Buffer;
extern fn hb_buffer_destroy(*Buffer) void;
extern fn hb_buffer_set_cluster_level(*Buffer, c_uint) void;
extern fn hb_buffer_set_direction(*Buffer, c_uint) void;
extern fn hb_buffer_add_utf8(*Buffer, [*]const u8, c_int, c_uint, c_int) void;
extern fn hb_buffer_guess_segment_properties(*Buffer) void;
extern fn hb_shape(*Font, *Buffer, ?*const anyopaque, c_uint) void;
extern fn hb_buffer_get_glyph_infos(*Buffer, *c_uint) ?[*]const GlyphInfo;
extern fn hb_buffer_get_glyph_positions(*Buffer, *c_uint) ?[*]const GlyphPosition;

const hb_memory_mode_readonly = 1;
const hb_cluster_level_monotone_characters = 1;
const hb_direction_ltr = 4;
const hb_direction_rtl = 5;

pub fn shape(
    allocator: std.mem.Allocator,
    font_data: []const u8,
    units_per_em: u16,
    text: []const u8,
    direction: Direction,
) std.mem.Allocator.Error!Run {
    if (text.len == 0) return .{ .glyphs = &.{}, .direction = direction };
    const blob = hb_blob_create(font_data.ptr, @intCast(font_data.len), hb_memory_mode_readonly, null, null) orelse return error.OutOfMemory;
    defer hb_blob_destroy(blob);
    const face = hb_face_create(blob, 0) orelse return error.OutOfMemory;
    defer hb_face_destroy(face);
    const hb_font = hb_font_create(face) orelse return error.OutOfMemory;
    defer hb_font_destroy(hb_font);
    hb_ot_font_set_funcs(hb_font);
    hb_font_set_scale(hb_font, units_per_em, units_per_em);

    const buffer = hb_buffer_create() orelse return error.OutOfMemory;
    defer hb_buffer_destroy(buffer);
    hb_buffer_set_cluster_level(buffer, hb_cluster_level_monotone_characters);
    hb_buffer_set_direction(buffer, switch (direction) {
        .ltr => hb_direction_ltr,
        .rtl => hb_direction_rtl,
    });
    hb_buffer_add_utf8(buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(hb_font, buffer, null, 0);

    var info_count: c_uint = 0;
    var position_count: c_uint = 0;
    const infos = hb_buffer_get_glyph_infos(buffer, &info_count) orelse return error.OutOfMemory;
    const positions = hb_buffer_get_glyph_positions(buffer, &position_count) orelse return error.OutOfMemory;
    const glyph_count = @min(info_count, position_count);
    const glyphs = try allocator.alloc(Glyph, glyph_count);
    for (glyphs, 0..) |*glyph, index| {
        const cluster_start = @min(infos[index].cluster, @as(u32, @intCast(text.len)));
        var cluster_end: u32 = @intCast(text.len);
        for (infos[0..glyph_count]) |candidate| {
            if (candidate.cluster > cluster_start) cluster_end = @min(cluster_end, candidate.cluster);
        }
        var maps_cluster = true;
        for (infos[0..index]) |previous| {
            if (previous.cluster == cluster_start) {
                maps_cluster = false;
                break;
            }
        }
        glyph.* = .{
            .glyph_id = if (infos[index].codepoint <= std.math.maxInt(u16)) @intCast(infos[index].codepoint) else 0,
            .x_advance = positions[index].x_advance,
            .y_advance = positions[index].y_advance,
            .x_offset = positions[index].x_offset,
            .y_offset = positions[index].y_offset,
            .cluster_start = cluster_start,
            .cluster_end = @max(cluster_end, cluster_start),
            .maps_cluster = maps_cluster,
        };
    }
    return .{ .glyphs = glyphs, .direction = direction };
}

pub fn detectDirection(text: []const u8) Direction {
    var view = std.unicode.Utf8View.init(text) catch return .ltr;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if ((codepoint >= 0x0590 and codepoint <= 0x08FF) or
            (codepoint >= 0xFB1D and codepoint <= 0xFDFF) or
            (codepoint >= 0xFE70 and codepoint <= 0xFEFF)) return .rtl;
        if ((codepoint >= 'A' and codepoint <= 'Z') or
            (codepoint >= 'a' and codepoint <= 'z')) return .ltr;
    }
    return .ltr;
}

const Header = extern struct {
    units: usize,
    requested: usize,
};
const AllocationUnit = u128;

fn backingAllocator() std.mem.Allocator {
    return if (builtin.target.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator;
}

fn headerFromData(ptr: *anyopaque) *Header {
    return @ptrFromInt(@intFromPtr(ptr) - @sizeOf(AllocationUnit));
}

export fn html2realpdf_hb_malloc(size: usize) ?*anyopaque {
    const payload_units = (size + @sizeOf(AllocationUnit) - 1) / @sizeOf(AllocationUnit);
    const units = payload_units + 1;
    const storage = backingAllocator().alloc(AllocationUnit, units) catch return null;
    const header: *Header = @ptrCast(&storage[0]);
    header.* = .{ .units = units, .requested = size };
    return @ptrFromInt(@intFromPtr(storage.ptr) + @sizeOf(AllocationUnit));
}

export fn html2realpdf_hb_calloc(count: usize, size: usize) ?*anyopaque {
    const total = std.math.mul(usize, count, size) catch return null;
    const result = html2realpdf_hb_malloc(total) orelse return null;
    const bytes: [*]u8 = @ptrCast(result);
    @memset(bytes[0..total], 0);
    return result;
}

export fn html2realpdf_hb_free(optional_ptr: ?*anyopaque) void {
    const ptr = optional_ptr orelse return;
    const header = headerFromData(ptr);
    const storage: [*]AllocationUnit = @ptrCast(@alignCast(header));
    backingAllocator().free(storage[0..header.units]);
}

export fn html2realpdf_hb_realloc(optional_ptr: ?*anyopaque, size: usize) ?*anyopaque {
    const ptr = optional_ptr orelse return html2realpdf_hb_malloc(size);
    if (size == 0) {
        html2realpdf_hb_free(ptr);
        return null;
    }
    const old_size = headerFromData(ptr).requested;
    const replacement = html2realpdf_hb_malloc(size) orelse return null;
    const old_bytes: [*]const u8 = @ptrCast(ptr);
    const new_bytes: [*]u8 = @ptrCast(replacement);
    @memcpy(new_bytes[0..@min(old_size, size)], old_bytes[0..@min(old_size, size)]);
    html2realpdf_hb_free(ptr);
    return replacement;
}

export fn strlen(value: [*]const u8) usize {
    var length: usize = 0;
    while (value[length] != 0) length += 1;
    return length;
}

export fn strcmp(left: [*]const u8, right: [*]const u8) c_int {
    var index: usize = 0;
    while (left[index] != 0 and left[index] == right[index]) index += 1;
    return @as(c_int, left[index]) - @as(c_int, right[index]);
}

export fn strncmp(left: [*]const u8, right: [*]const u8, length: usize) c_int {
    var index: usize = 0;
    while (index < length and left[index] != 0 and left[index] == right[index]) index += 1;
    if (index == length) return 0;
    return @as(c_int, left[index]) - @as(c_int, right[index]);
}

export fn strchr(value: [*]const u8, needle: c_int) ?[*]const u8 {
    const byte: u8 = @truncate(@as(c_uint, @bitCast(needle)));
    var index: usize = 0;
    while (true) : (index += 1) {
        if (value[index] == byte) return value + index;
        if (value[index] == 0) return null;
    }
}

export fn strstr(haystack: [*]const u8, needle: [*]const u8) ?[*]const u8 {
    const needle_length = strlen(needle);
    if (needle_length == 0) return haystack;
    var index: usize = 0;
    while (haystack[index] != 0) : (index += 1) {
        if (strncmp(haystack + index, needle, needle_length) == 0) return haystack + index;
    }
    return null;
}

export fn strncpy(destination: [*]u8, source: [*]const u8, length: usize) [*]u8 {
    var index: usize = 0;
    while (index < length and source[index] != 0) : (index += 1) destination[index] = source[index];
    while (index < length) : (index += 1) destination[index] = 0;
    return destination;
}

export fn wcslen(value: [*]const u32) usize {
    var length: usize = 0;
    while (value[length] != 0) length += 1;
    return length;
}
