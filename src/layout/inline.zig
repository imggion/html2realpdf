//! Inline formatting context, whitespace handling, wrapping, and line alignment.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const intrinsic = @import("intrinsic.zig");
const types = @import("types.zig");
const font = @import("../font.zig");

pub fn Cursor(comptime State: type) type {
    return struct {
        const Self = @This();
        state: *State,
        start_x: f32,
        start_y: f32,
        line_y: f32,
        width: f32,
        x: f32,
        line_height: f32,
        text_align: box.TextAlign,
        line_start_fragment: usize,
        line_id: usize,
        has_content: bool = false,
        pending_space: bool = false,

        pub fn init(state: *State, start_x: f32, start_y: f32, width: f32, text_align: box.TextAlign) Self {
            const line_id = state.next_line_id;
            state.next_line_id += 1;
            return .{
                .state = state,
                .start_x = start_x,
                .start_y = start_y,
                .line_y = start_y,
                .width = @max(width, 1),
                .x = start_x,
                .line_height = 0,
                .text_align = text_align,
                .line_start_fragment = state.fragments.items.len,
                .line_id = line_id,
            };
        }

        pub fn layoutBox(self: *Self, box_id: box.BoxId, inherited_link: ?[]const u8) !void {
            const source = self.state.tree.boxes.items[box_id];
            const link_url = self.state.linkForBox(box_id) orelse inherited_link;
            if (source.style.page_break_before == .always) self.forcePageBreak();
            switch (source.kind) {
                .text => if (source.text) |text| try self.layoutText(box_id, text, source.style, link_url),
                .lineBreak => self.newLine(),
                .replaced => try self.layoutAtomic(box_id, source, link_url),
                .inlineBlock => try self.layoutInlineBlock(box_id, source),
                .inlineBox, .anonymousInline => {
                    var child = source.first_child;
                    while (child) |child_id| {
                        try self.layoutBox(child_id, link_url);
                        child = self.state.tree.boxes.items[child_id].next_sibling;
                    }
                },
                else => {},
            }
            if (source.style.page_break_after == .always) self.forcePageBreak();
        }

        /// Finish the current inline line and place the next fragment at the top of
        /// the following page. Selector-driven page break rules must work for
        /// replaced and inline elements as well as block boxes.
        fn forcePageBreak(self: *Self) void {
            const page_height = self.state.page_height orelse return;
            if (self.has_content) {
                self.alignCurrentLine(false);
                self.line_y += if (self.line_height > 0) self.line_height else 18;
            }
            const page_y = @mod(self.line_y, page_height);
            if (page_y > 0) self.line_y += page_height - page_y;
            self.x = self.start_x;
            self.line_height = 0;
            self.line_start_fragment = self.state.fragments.items.len;
            self.line_id = self.state.next_line_id;
            self.state.next_line_id += 1;
            self.has_content = false;
            self.pending_space = false;
        }

        fn layoutText(self: *Self, box_id: box.BoxId, text: []const u8, style: box.Style, link_url: ?[]const u8) !void {
            switch (style.white_space) {
                .normal => try self.layoutCollapsedText(box_id, text, style, link_url, true),
                .nowrap => try self.layoutCollapsedText(box_id, text, style, link_url, false),
                .preLine => try self.layoutPreLineText(box_id, text, style, link_url),
                .pre => try self.layoutPreservedText(box_id, text, style, link_url, false),
                .preWrap => try self.layoutPreservedText(box_id, text, style, link_url, true),
            }
        }

        fn layoutCollapsedText(
            self: *Self,
            box_id: box.BoxId,
            text: []const u8,
            style: box.Style,
            link_url: ?[]const u8,
            allow_wrap: bool,
        ) !void {
            var index: usize = 0;
            var saw_space = self.pending_space;
            self.pending_space = false;

            while (index < text.len) {
                while (index < text.len and isHtmlWhitespace(text[index])) : (index += 1) {
                    saw_space = true;
                }
                if (index >= text.len) break;

                const word_start = index;
                while (index < text.len and !isHtmlWhitespace(text[index])) : (index += 1) {}
                const word = text[word_start..index];
                const word_width = intrinsic.measureText(self.state.font_registry, word, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
                var leading_space = saw_space and self.has_content;
                var space_width = if (leading_space) intrinsic.measureText(self.state.font_registry, " ", style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing) else 0;

                if (allow_wrap and self.has_content and self.x + space_width + word_width > self.start_x + self.width) {
                    self.newLine();
                    leading_space = false;
                    space_width = 0;
                }

                try self.appendTextFragment(box_id, word, space_width + word_width, leading_space, style, link_url);
                saw_space = false;
            }
            self.pending_space = saw_space;
        }

        fn layoutPreLineText(self: *Self, box_id: box.BoxId, text: []const u8, style: box.Style, link_url: ?[]const u8) !void {
            var start: usize = 0;
            var index: usize = 0;
            while (index < text.len) {
                if (text[index] != '\n' and text[index] != '\r') {
                    index += 1;
                    continue;
                }
                try self.layoutCollapsedText(box_id, text[start..index], style, link_url, true);
                self.pending_space = false;
                self.newLine();
                if (text[index] == '\r' and index + 1 < text.len and text[index + 1] == '\n') index += 1;
                index += 1;
                start = index;
            }
            try self.layoutCollapsedText(box_id, text[start..], style, link_url, true);
        }

        fn layoutPreservedText(
            self: *Self,
            box_id: box.BoxId,
            text: []const u8,
            style: box.Style,
            link_url: ?[]const u8,
            allow_wrap: bool,
        ) !void {
            self.pending_space = false;
            var chunk_start: usize = 0;
            var chunk_width: f32 = 0;
            var index: usize = 0;
            while (index < text.len) {
                const byte = text[index];
                if (byte == '\n' or byte == '\r') {
                    if (chunk_start < index) try self.appendTextFragment(box_id, text[chunk_start..index], chunk_width, false, style, link_url);
                    self.newLine();
                    if (byte == '\r' and index + 1 < text.len and text[index + 1] == '\n') index += 1;
                    index += 1;
                    chunk_start = index;
                    chunk_width = 0;
                    continue;
                }

                if (byte == '\t') {
                    if (chunk_start < index) try self.appendTextFragment(box_id, text[chunk_start..index], chunk_width, false, style, link_url);
                    const tab_text = "    ";
                    const tab_width = intrinsic.measureText(self.state.font_registry, tab_text, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
                    if (allow_wrap and self.has_content and self.x + tab_width > self.start_x + self.width) self.newLine();
                    try self.appendTextFragment(box_id, tab_text, tab_width, false, style, link_url);
                    index += 1;
                    chunk_start = index;
                    chunk_width = 0;
                    continue;
                }

                const sequence_length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                const end = @min(index + sequence_length, text.len);
                const character_width = intrinsic.measureText(self.state.font_registry, text[index..end], style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
                if (allow_wrap and self.has_content and self.x + chunk_width + character_width > self.start_x + self.width) {
                    if (chunk_start < index) try self.appendTextFragment(box_id, text[chunk_start..index], chunk_width, false, style, link_url);
                    self.newLine();
                    chunk_start = index;
                    chunk_width = 0;
                }
                chunk_width += character_width;
                index = end;
            }
            if (chunk_start < text.len) try self.appendTextFragment(box_id, text[chunk_start..], chunk_width, false, style, link_url);
        }

        fn appendTextFragment(
            self: *Self,
            box_id: box.BoxId,
            text: []const u8,
            _: f32,
            leading_space: bool,
            style: box.Style,
            link_url: ?[]const u8,
        ) !void {
            if (text.len == 0) return;
            var iterator = font.Utf8Iterator{ .bytes = text };
            var run_start: usize = 0;
            var run_font: ?font.ResolvedFont = null;
            var first_run = true;
            while (true) {
                const codepoint_start = iterator.index;
                const codepoint = iterator.next() catch unreachable;
                const resolved = if (codepoint) |value|
                    font.resolveForCodepoint(self.state.font_registry, style.font_family, style.font_weight, style.font_style, value) orelse unreachable
                else
                    null;
                if (run_font) |active| {
                    if (resolved == null or resolved.?.id != active.id) {
                        try self.appendResolvedTextFragment(box_id, text[run_start..codepoint_start], active, leading_space and first_run, style, link_url);
                        first_run = false;
                        run_start = codepoint_start;
                    }
                }
                if (resolved) |next_font| run_font = next_font else break;
            }
        }

        fn appendResolvedTextFragment(
            self: *Self,
            box_id: box.BoxId,
            text: []const u8,
            resolved: font.ResolvedFont,
            leading_space: bool,
            style: box.Style,
            link_url: ?[]const u8,
        ) !void {
            const line_height = @max(style.line_height, style.font_size * 1.2);
            self.line_height = @max(self.line_height, line_height);
            var width = (resolved.metrics().widthCssPx(text, style.font_size) catch 0) +
                style.letter_spacing * @as(f32, @floatFromInt(countCodepoints(text)));
            if (leading_space) {
                width += intrinsic.measureText(self.state.font_registry, " ", resolved.family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
            }
            try self.state.fragments.append(self.state.allocator, .{
                .kind = .text,
                .source_box = box_id,
                .rect = .{ .x = self.x, .y = self.line_y, .width = width, .height = line_height },
                .line_id = self.line_id,
                .text = text,
                .leading_space = leading_space,
                .font_size = style.font_size,
                .font_family = resolved.family,
                .letter_spacing = style.letter_spacing,
                .font_weight = style.font_weight,
                .font_style = style.font_style,
                .color = geometry.parseColor(style.color) orelse geometry.Color.black,
                .text_decoration = style.text_decoration,
                .link_url = link_url,
            });
            self.x += width;
            self.has_content = true;
        }

        fn layoutAtomic(self: *Self, box_id: box.BoxId, source: box.Box, link_url: ?[]const u8) !void {
            const width = source.style.width.resolve(self.width) orelse source.intrinsic_width orelse 24;
            const height = source.style.height.resolve(self.state.page_height orelse 0) orelse source.intrinsic_height orelse 24;

            if (self.has_content and self.x + width > self.start_x + self.width) self.newLine();
            self.line_height = @max(self.line_height, height);
            try self.state.fragments.append(self.state.allocator, .{
                .kind = .replaced,
                .source_box = box_id,
                .rect = .{ .x = self.x, .y = self.line_y, .width = width, .height = height },
                .line_id = self.line_id,
                .border = source.border,
                .border_paint = types.borderPaint(source.style),
                .link_url = link_url,
                .image_source = self.state.attributeForBox(box_id, "src"),
            });
            self.x += width;
            self.has_content = true;
        }

        fn layoutInlineBlock(self: *Self, box_id: box.BoxId, source: box.Box) !void {
            const horizontal_edges = source.margin.left + source.margin.right + source.border.left + source.border.right + source.padding.left + source.padding.right;
            const requested_content = source.style.width.resolve(self.width) orelse @max(self.width - (self.x - self.start_x) - horizontal_edges, 1);
            const expected_outer_width = requested_content + horizontal_edges;
            if (self.has_content and self.x + expected_outer_width > self.start_x + self.width) self.newLine();

            const fragment_start = self.state.fragments.items.len;
            var nested_cursor_y = self.line_y;
            const rect = try self.state.layoutBlock(
                box_id,
                .{ .x = self.x, .y = self.line_y, .width = expected_outer_width },
                &nested_cursor_y,
            );
            for (self.state.fragments.items[fragment_start..]) |*fragment| {
                fragment.inline_container_line_id = self.line_id;
            }
            const outer_height = source.margin.top + rect.height + source.margin.bottom;
            self.line_height = @max(self.line_height, outer_height);
            self.x += source.margin.left + rect.width + source.margin.right;
            self.has_content = true;
        }

        fn newLine(self: *Self) void {
            self.alignCurrentLine(false);
            self.line_y += if (self.line_height > 0) self.line_height else 18;
            self.x = self.start_x;
            self.line_height = 0;
            self.line_start_fragment = self.state.fragments.items.len;
            self.line_id = self.state.next_line_id;
            self.state.next_line_id += 1;
            self.has_content = false;
            self.pending_space = false;
        }

        fn alignCurrentLine(self: *Self, is_last_line: bool) void {
            if (!self.has_content or self.text_align == .left) return;
            const used = self.x - self.start_x;
            const remaining = @max(self.width - used, 0);
            if (self.text_align == .justify) {
                if (is_last_line or remaining == 0) return;
                var spaces: usize = 0;
                for (self.state.fragments.items[self.line_start_fragment..]) |fragment| {
                    if (fragment.line_id == self.line_id and fragment.leading_space) spaces += 1;
                }
                if (spaces == 0) return;
                const extra = remaining / @as(f32, @floatFromInt(spaces));
                var shift: f32 = 0;
                for (self.state.fragments.items[self.line_start_fragment..]) |*fragment| {
                    if (fragment.line_id != self.line_id and fragment.inline_container_line_id != self.line_id) continue;
                    if (fragment.leading_space) shift += extra;
                    fragment.rect.x += shift;
                }
                return;
            }
            const shift = if (self.text_align == .center) remaining / 2 else remaining;
            for (self.state.fragments.items[self.line_start_fragment..]) |*fragment| {
                if (fragment.line_id == self.line_id or fragment.inline_container_line_id == self.line_id) fragment.rect.x += shift;
            }
        }

        pub fn finish(self: *Self) f32 {
            self.alignCurrentLine(true);
            if (!self.has_content and self.line_y == self.start_y) return 0;
            return (self.line_y + @max(self.line_height, 18)) - self.start_y;
        }
    };
}

fn isHtmlWhitespace(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\n' or value == '\r' or value == 0x0C;
}

fn countCodepoints(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (count += 1) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        index = @min(index + length, text.len);
    }
    return count;
}
