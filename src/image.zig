//! Image resource decoding used by the PDF backend.
//!
//! JPEG bytes are passed through unchanged into a PDF DCTDecode image object.
//! PNG scanlines are decoded only when an alpha channel must be split into a
//! PDF soft mask; opaque PNG data remains losslessly Flate-compressed.

const std = @import("std");

pub const Error = error{
    UnsupportedImage,
    InvalidDataUrl,
    InvalidJpeg,
    InvalidPng,
};

pub const Jpeg = struct {
    bytes: []u8,
    width: u16,
    height: u16,
    components: u8,

    pub fn deinit(self: *Jpeg, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn decodeJpegDataUrl(allocator: std.mem.Allocator, source: []const u8) !Jpeg {
    const prefix = "data:image/jpeg;base64,";
    const alternate_prefix = "data:image/jpg;base64,";
    const encoded = if (std.mem.startsWith(u8, source, prefix))
        source[prefix.len..]
    else if (std.mem.startsWith(u8, source, alternate_prefix))
        source[alternate_prefix.len..]
    else
        return Error.UnsupportedImage;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return Error.InvalidDataUrl;
    const bytes = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(bytes);
    std.base64.standard.Decoder.decode(bytes, encoded) catch return Error.InvalidDataUrl;

    const dimensions = jpegDimensions(bytes) catch return Error.InvalidJpeg;
    return .{
        .bytes = bytes,
        .width = dimensions.width,
        .height = dimensions.height,
        .components = dimensions.components,
    };
}

pub const Png = struct {
    color_bytes: []u8,
    alpha_bytes: ?[]u8,
    width: u32,
    height: u32,
    color_components: u8,
    predictor_encoded: bool,

    pub fn deinit(self: *Png, allocator: std.mem.Allocator) void {
        allocator.free(self.color_bytes);
        if (self.alpha_bytes) |alpha| allocator.free(alpha);
        self.* = undefined;
    }
};

pub fn decodePngDataUrl(allocator: std.mem.Allocator, source: []const u8) !Png {
    const bytes = try decodeBase64DataUrl(allocator, source, "data:image/png;base64,");
    defer allocator.free(bytes);
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1A\n")) return Error.InvalidPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var idat = std.Io.Writer.Allocating.init(allocator);
    defer idat.deinit();
    var offset: usize = 8;
    while (offset + 12 <= bytes.len) {
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const chunk_end = std.math.add(usize, offset + 12, length) catch return Error.InvalidPng;
        if (chunk_end > bytes.len) return Error.InvalidPng;
        const chunk_type = bytes[offset + 4 .. offset + 8];
        const data = bytes[offset + 8 .. offset + 8 + length];
        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (data.len != 13) return Error.InvalidPng;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            bit_depth = data[8];
            color_type = data[9];
            if (data[10] != 0 or data[11] != 0 or data[12] != 0) return Error.UnsupportedImage;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.writer.writeAll(data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
        offset = chunk_end;
    }
    if (width == 0 or height == 0 or bit_depth != 8 or idat.writer.end == 0) return Error.InvalidPng;
    const components: u8 = switch (color_type) {
        0 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return Error.UnsupportedImage,
    };

    if (color_type == 0 or color_type == 2) {
        return .{
            .color_bytes = try allocator.dupe(u8, idat.written()),
            .alpha_bytes = null,
            .width = width,
            .height = height,
            .color_components = components,
            .predictor_encoded = true,
        };
    }

    const stride = std.math.mul(usize, width, components) catch return Error.InvalidPng;
    const filtered_len = std.math.mul(usize, height, stride + 1) catch return Error.InvalidPng;
    const filtered = try inflateZlib(allocator, idat.written(), filtered_len);
    defer allocator.free(filtered);
    if (filtered.len != filtered_len) return Error.InvalidPng;
    const pixels = try allocator.alloc(u8, stride * height);
    defer allocator.free(pixels);
    try unfilterPng(pixels, filtered, @intCast(width), @intCast(height), components);

    const color_components: u8 = if (color_type == 4) 1 else 3;
    const pixel_count = std.math.mul(usize, width, height) catch return Error.InvalidPng;
    const colors = try allocator.alloc(u8, pixel_count * color_components);
    defer allocator.free(colors);
    const alpha = try allocator.alloc(u8, pixel_count);
    defer allocator.free(alpha);
    for (0..pixel_count) |pixel_index| {
        const source_index = pixel_index * components;
        const color_index = pixel_index * color_components;
        @memcpy(colors[color_index..][0..color_components], pixels[source_index..][0..color_components]);
        alpha[pixel_index] = pixels[source_index + color_components];
    }

    return .{
        .color_bytes = try compressZlib(allocator, colors),
        .alpha_bytes = try compressZlib(allocator, alpha),
        .width = width,
        .height = height,
        .color_components = color_components,
        .predictor_encoded = false,
    };
}

fn decodeBase64DataUrl(allocator: std.mem.Allocator, source: []const u8, prefix: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, source, prefix)) return Error.UnsupportedImage;
    const encoded = source[prefix.len..];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return Error.InvalidDataUrl;
    const bytes = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(bytes);
    std.base64.standard.Decoder.decode(bytes, encoded) catch return Error.InvalidDataUrl;
    return bytes;
}

fn inflateZlib(allocator: std.mem.Allocator, compressed: []const u8, expected_size: usize) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, expected_size);
    errdefer output.deinit();
    var decompressor: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    _ = try decompressor.reader.streamRemaining(&output.writer);
    return output.toOwnedSlice();
}

pub fn compressZlib(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, @max(input.len / 2, 16));
    errdefer output.deinit();
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&output.writer, &buffer, .zlib, .default);
    try compressor.writer.writeAll(input);
    try compressor.finish();
    return output.toOwnedSlice();
}

fn unfilterPng(output: []u8, filtered: []const u8, width: usize, height: usize, components: usize) Error!void {
    const stride = width * components;
    for (0..height) |row| {
        const source = filtered[row * (stride + 1) + 1 ..][0..stride];
        const destination = output[row * stride ..][0..stride];
        const previous: ?[]const u8 = if (row == 0) null else output[(row - 1) * stride ..][0..stride];
        const filter = filtered[row * (stride + 1)];
        for (source, 0..) |value, index| {
            const left: u8 = if (index >= components) destination[index - components] else 0;
            const above: u8 = if (previous) |line| line[index] else 0;
            const upper_left: u8 = if (previous != null and index >= components) previous.?[index - components] else 0;
            destination[index] = switch (filter) {
                0 => value,
                1 => value +% left,
                2 => value +% above,
                3 => value +% @as(u8, @intCast((@as(u16, left) + above) / 2)),
                4 => value +% paeth(left, above, upper_left),
                else => return Error.InvalidPng,
            };
        }
    }
}

fn paeth(left: u8, above: u8, upper_left: u8) u8 {
    const prediction = @as(i16, left) + @as(i16, above) - @as(i16, upper_left);
    const left_distance = @abs(prediction - @as(i16, left));
    const above_distance = @abs(prediction - @as(i16, above));
    const upper_left_distance = @abs(prediction - @as(i16, upper_left));
    if (left_distance <= above_distance and left_distance <= upper_left_distance) return left;
    if (above_distance <= upper_left_distance) return above;
    return upper_left;
}

const Dimensions = struct {
    width: u16,
    height: u16,
    components: u8,
};

fn jpegDimensions(bytes: []const u8) Error!Dimensions {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return Error.InvalidJpeg;
    var index: usize = 2;

    while (index + 3 < bytes.len) {
        while (index < bytes.len and bytes[index] != 0xFF) : (index += 1) {}
        while (index < bytes.len and bytes[index] == 0xFF) : (index += 1) {}
        if (index >= bytes.len) break;

        const marker = bytes[index];
        index += 1;
        if (marker == 0xD8 or marker == 0xD9 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) continue;
        if (index + 2 > bytes.len) return Error.InvalidJpeg;

        const segment_length = std.mem.readInt(u16, bytes[index..][0..2], .big);
        if (segment_length < 2 or index + segment_length > bytes.len) return Error.InvalidJpeg;
        if (isStartOfFrame(marker)) {
            if (segment_length < 8) return Error.InvalidJpeg;
            return .{
                .height = std.mem.readInt(u16, bytes[index + 3 ..][0..2], .big),
                .width = std.mem.readInt(u16, bytes[index + 5 ..][0..2], .big),
                .components = bytes[index + 7],
            };
        }
        index += segment_length;
    }

    return Error.InvalidJpeg;
}

fn isStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => true,
        else => false,
    };
}

test "decode JPEG data URL and read dimensions" {
    const allocator = std.testing.allocator;
    const jpeg_bytes = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xC0,
        0x00, 0x0B,
        0x08, 0x00,
        0x02, 0x00,
        0x03, 0x03,
        0x01, 0x11,
        0x00,
    };
    const encoded_len = std.base64.standard.Encoder.calcSize(jpeg_bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, &jpeg_bytes);
    const source = try std.fmt.allocPrint(allocator, "data:image/jpeg;base64,{s}", .{encoded});
    defer allocator.free(source);

    var jpeg = try decodeJpegDataUrl(allocator, source);
    defer jpeg.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 3), jpeg.width);
    try std.testing.expectEqual(@as(u16, 2), jpeg.height);
    try std.testing.expectEqual(@as(u8, 3), jpeg.components);
}

test "decode RGBA PNG and preserve a soft-mask channel" {
    const allocator = std.testing.allocator;
    const source = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+X1y8WQAAAABJRU5ErkJggg==";
    var png = try decodePngDataUrl(allocator, source);
    defer png.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), png.width);
    try std.testing.expectEqual(@as(u32, 1), png.height);
    try std.testing.expectEqual(@as(u8, 3), png.color_components);
    try std.testing.expect(png.alpha_bytes != null);
}
