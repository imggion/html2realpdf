//! PDF/A policy, deterministic XMP and the pinned sRGB output profile.
//! Object ownership and PDF syntax remain in pdf.zig; no post-processing occurs.

const std = @import("std");
const font = @import("font.zig");

pub const Conformance = enum { @"pdfa-3u" };
pub const Relationship = enum { Source, Data, Alternative, Supplement, Unspecified };

/// Bytes and UTF-8 strings are borrowed for one synchronous render.
pub const Attachment = struct {
    name: []const u8,
    data: []const u8,
    mime_type: []const u8 = "application/octet-stream",
    relationship: Relationship = .Unspecified,
    description: ?[]const u8 = null,
    /// Canonical UTC PDF date: D:YYYYMMDDHHmmSSZ. Omitted dates stay absent.
    modified_at: ?[]const u8 = null,
};

pub const srgb = @embedFile("assets/color/sRGB2014.icc");
pub const srgb_sha256 = "384b832de3412066743b52a75ee906b6fb9fb8d9e09e936fc2c43223815c6e0a";
pub const max_string_bytes = 32767;
pub const max_name_bytes = 127;
pub const max_objects = 8388607;

pub fn validateAttachments(attachments: []const Attachment, archival: bool) !void {
    for (attachments, 0..) |attachment, index| {
        if (std.mem.trim(u8, attachment.name, " \t\r\n").len == 0) return error.InvalidAttachmentName;
        try validateText(attachment.name, archival);
        for (attachments[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, attachment.name)) return error.DuplicateAttachmentName;
        }
        const slash = std.mem.indexOfScalar(u8, attachment.mime_type, '/') orelse return error.InvalidAttachmentMimeType;
        if (slash == 0 or slash + 1 == attachment.mime_type.len) return error.InvalidAttachmentMimeType;
        for (attachment.mime_type, 0..) |byte, i| {
            if (i == slash) continue;
            if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+.^_`|~-", byte) == null) return error.InvalidAttachmentMimeType;
        }
        if (archival and attachment.mime_type.len > max_name_bytes) return error.PdfaNameTooLong;
        if (attachment.description) |description| try validateText(description, archival);
        if (attachment.modified_at) |date| try validateDate(date);
        if (archival and attachment.data.len > std.math.maxInt(i32)) return error.PdfaIntegerOutOfRange;
    }
}

pub fn validateDate(date: []const u8) !void {
    if (date.len != 17 or !std.mem.startsWith(u8, date, "D:") or date[16] != 'Z') return error.InvalidAttachmentDate;
    for (date[2..16]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidAttachmentDate;
    const year = std.fmt.parseInt(u16, date[2..6], 10) catch return error.InvalidAttachmentDate;
    const month = std.fmt.parseInt(u8, date[6..8], 10) catch return error.InvalidAttachmentDate;
    const day = std.fmt.parseInt(u8, date[8..10], 10) catch return error.InvalidAttachmentDate;
    const hour = std.fmt.parseInt(u8, date[10..12], 10) catch return error.InvalidAttachmentDate;
    const minute = std.fmt.parseInt(u8, date[12..14], 10) catch return error.InvalidAttachmentDate;
    const second = std.fmt.parseInt(u8, date[14..16], 10) catch return error.InvalidAttachmentDate;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (year == 0 or month < 1 or month > 12 or day < 1 or day > days[month - 1] or hour > 23 or minute > 59 or second > 59) return error.InvalidAttachmentDate;
}

/// Returns encoded UTF-16BE length, excluding the optional BOM.
pub fn unicodeLength(text: []const u8) !usize {
    var iterator = font.Utf8Iterator{ .bytes = text };
    var length: usize = 0;
    while (try iterator.next()) |cp| {
        if (cp == 0 or cp == 0xfffe or cp == 0xffff) return error.PdfaInvalidUnicode;
        length += if (cp > 0xffff) @as(usize, 4) else 2;
    }
    return length;
}

pub fn validateText(text: []const u8, archival: bool) !void {
    const length = try unicodeLength(text);
    if (archival and length + 2 > max_string_bytes) return error.PdfaStringTooLong;
}

pub fn validateMetadata(metadata: anytype) !void {
    inline for (@typeInfo(@TypeOf(metadata)).@"struct".fields) |field| {
        if (@field(metadata, field.name)) |value| {
            try validateText(value, true);
            for (value) |byte| if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') return error.PdfaInvalidMetadata;
        }
    }
}

pub fn validatePage(width: f32, height: f32) !void {
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width < 3 or width > 14400 or height < 3 or height > 14400) return error.PdfaInvalidPageSize;
}

/// Every emitted CID needs Unicode, even subsequent glyphs of a cluster.
/// This deliberately leaves the spacing-sensitive font helper unchanged.
pub fn glyphUnicode(text: []const u8, glyph: font.ShapedGlyph) ![]const u8 {
    if (glyph.cluster_start >= glyph.cluster_end or glyph.cluster_end > text.len) return error.PdfaInvalidUnicode;
    const unicode = text[glyph.cluster_start..glyph.cluster_end];
    try validateText(unicode, true);
    return unicode;
}

fn xml(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\r' => try writer.writeAll("&#13;"),
        else => try writer.writeByte(byte),
    };
}

pub fn writeXmp(writer: *std.Io.Writer, metadata: anytype) !void {
    try writer.writeAll("<?xpacket begin=\"\xef\xbb\xbf\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" ++
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" ++
        "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\">" ++
        "<pdfaid:part>3</pdfaid:part><pdfaid:conformance>U</pdfaid:conformance><pdf:Producer>html2realpdf</pdf:Producer><dc:format>application/pdf</dc:format>");
    if (metadata.title) |value| {
        try writer.writeAll("<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">");
        try xml(writer, value);
        try writer.writeAll("</rdf:li></rdf:Alt></dc:title>");
    }
    if (metadata.author) |value| {
        try writer.writeAll("<dc:creator><rdf:Seq><rdf:li>");
        try xml(writer, value);
        try writer.writeAll("</rdf:li></rdf:Seq></dc:creator>");
    }
    if (metadata.subject) |value| {
        try writer.writeAll("<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">");
        try xml(writer, value);
        try writer.writeAll("</rdf:li></rdf:Alt></dc:description>");
    }
    if (metadata.keywords) |value| {
        try writer.writeAll("<pdf:Keywords>");
        try xml(writer, value);
        try writer.writeAll("</pdf:Keywords>");
    }
    if (metadata.creator) |value| {
        try writer.writeAll("<xmp:CreatorTool>");
        try xml(writer, value);
        try writer.writeAll("</xmp:CreatorTool>");
    }
    try writer.writeAll("</rdf:Description></rdf:RDF></x:xmpmeta>\n<?xpacket end=\"w\"?>");
}

test "PDF/A profile is pinned and limits reject invalid values" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(srgb, &digest, .{});
    try std.testing.expectEqualStrings(srgb_sha256, &std.fmt.bytesToHex(digest, .lower));
    try std.testing.expectError(error.PdfaInvalidPageSize, validatePage(14401, 800));
    try std.testing.expectError(error.InvalidAttachmentDate, validateDate("D:20260229000000Z"));
    try validateDate("D:20240229000000Z");
    try std.testing.expectError(error.PdfaInvalidUnicode, unicodeLength("\x00"));
}
