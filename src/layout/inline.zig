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
        capitalize_next: bool = true,
        ellipsis_enabled: bool = false,
        truncated: bool = false,

        pub fn init(state: *State, start_x: f32, start_y: f32, width: f32, text_align: box.TextAlign, text_indent: f32, ellipsis_enabled: bool) Self {
            const line_id = state.next_line_id;
            state.next_line_id += 1;
            return .{
                .state = state,
                .start_x = start_x,
                .start_y = start_y,
                .line_y = start_y,
                .width = @max(width, 1),
                .x = start_x + text_indent,
                .line_height = 0,
                .text_align = text_align,
                .line_start_fragment = state.fragments.items.len,
                .line_id = line_id,
                .ellipsis_enabled = ellipsis_enabled,
            };
        }

        pub fn layoutBox(self: *Self, box_id: box.BoxId, inherited_link: ?[]const u8, inherited_vertical_align: box.VerticalAlign) !void {
            if (self.truncated) return;
            const source = self.state.tree.boxes.items[box_id];
            const effective_vertical_align = if (isBaselineAlignment(source.style.vertical_align)) inherited_vertical_align else source.style.vertical_align;
            var effective_source = source;
            effective_source.style.vertical_align = effective_vertical_align;
            const link_url = self.state.linkForBox(box_id) orelse inherited_link;
            if (source.style.page_break_before == .always) self.forcePageBreak();
            switch (source.kind) {
                .text => if (source.text) |text| try self.layoutText(box_id, text, effective_source.style, link_url),
                .lineBreak => self.newLine(),
                .replaced => try self.layoutAtomic(box_id, effective_source, link_url),
                .inlineBlock => try self.layoutInlineBlock(box_id, effective_source),
                .inlineBox, .anonymousInline => {
                    var child = source.first_child;
                    while (child) |child_id| {
                        try self.layoutBox(child_id, link_url, effective_vertical_align);
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
            const transformed = try self.transformText(text, style.text_transform);
            switch (style.white_space) {
                .normal => try self.layoutCollapsedText(box_id, transformed, style, link_url, true),
                .nowrap => try self.layoutCollapsedText(box_id, transformed, style, link_url, false),
                .preLine => try self.layoutPreLineText(box_id, transformed, style, link_url),
                .pre => try self.layoutPreservedText(box_id, transformed, style, link_url, false),
                .preWrap => try self.layoutPreservedText(box_id, transformed, style, link_url, true),
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
                const word_width = self.measureStyledText(word, style);
                var leading_space = saw_space and self.has_content;
                var space_width = if (leading_space) self.spaceWidth(style) else 0;

                if (!allow_wrap and self.ellipsis_enabled and self.x + space_width + word_width > self.start_x + self.width) {
                    try self.truncateWithEllipsis(box_id, word, leading_space, style, link_url);
                    self.pending_space = false;
                    return;
                }

                const break_inside = allow_wrap and (style.word_break == .breakAll or
                    style.overflow_wrap == .anywhere or
                    (style.overflow_wrap == .breakWord and word_width > self.width));
                if (break_inside) {
                    try self.layoutBreakableWord(box_id, word, leading_space, style, link_url);
                    saw_space = false;
                    continue;
                }

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
                    const tab_width = self.measureStyledText(tab_text, style);
                    if (allow_wrap and self.has_content and self.x + tab_width > self.start_x + self.width) self.newLine();
                    try self.appendTextFragment(box_id, tab_text, tab_width, false, style, link_url);
                    index += 1;
                    chunk_start = index;
                    chunk_width = 0;
                    continue;
                }

                const sequence_length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                const end = @min(index + sequence_length, text.len);
                const character_width = self.measureStyledText(text[index..end], style);
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

        fn layoutBreakableWord(
            self: *Self,
            box_id: box.BoxId,
            word: []const u8,
            has_leading_space: bool,
            style: box.Style,
            link_url: ?[]const u8,
        ) !void {
            var leading_space = has_leading_space;
            var leading_width = if (leading_space) self.spaceWidth(style) else 0;
            if (self.has_content and self.x + leading_width >= self.start_x + self.width) {
                self.newLine();
                leading_space = false;
                leading_width = 0;
            }

            var chunk_start: usize = 0;
            var chunk_width: f32 = 0;
            var index: usize = 0;
            while (index < word.len) {
                const sequence_length = std.unicode.utf8ByteSequenceLength(word[index]) catch 1;
                const end = @min(index + sequence_length, word.len);
                const character_width = self.measureStyledText(word[index..end], style);
                if (chunk_start == index and self.has_content and self.x + leading_width + character_width > self.start_x + self.width) {
                    self.newLine();
                    leading_space = false;
                    leading_width = 0;
                }
                if (chunk_start < index and self.x + leading_width + chunk_width + character_width > self.start_x + self.width) {
                    try self.appendTextFragment(box_id, word[chunk_start..index], leading_width + chunk_width, leading_space, style, link_url);
                    self.newLine();
                    leading_space = false;
                    leading_width = 0;
                    chunk_start = index;
                    chunk_width = 0;
                }
                chunk_width += character_width;
                index = end;
            }
            if (chunk_start < word.len) try self.appendTextFragment(box_id, word[chunk_start..], leading_width + chunk_width, leading_space, style, link_url);
        }

        fn truncateWithEllipsis(
            self: *Self,
            box_id: box.BoxId,
            word: []const u8,
            requested_leading_space: bool,
            style: box.Style,
            link_url: ?[]const u8,
        ) !void {
            const ellipsis = "…";
            const ellipsis_width = self.measureStyledText(ellipsis, style);
            const line_end = self.start_x + self.width;
            self.trimLineToFit(line_end - ellipsis_width);

            var leading_space = requested_leading_space and self.has_content;
            var consumed = if (leading_space) self.spaceWidth(style) else 0;
            var prefix_end: usize = 0;
            var index: usize = 0;
            while (index < word.len) {
                const sequence_length = std.unicode.utf8ByteSequenceLength(word[index]) catch 1;
                const end = @min(index + sequence_length, word.len);
                const character_width = self.measureStyledText(word[index..end], style);
                if (self.x + consumed + character_width + ellipsis_width > line_end) break;
                consumed += character_width;
                prefix_end = end;
                index = end;
            }
            if (prefix_end > 0) {
                try self.appendTextFragment(box_id, word[0..prefix_end], consumed, leading_space, style, link_url);
            } else {
                leading_space = false;
            }

            self.trimLineToFit(line_end - ellipsis_width);
            try self.appendTextFragment(box_id, ellipsis, ellipsis_width, false, style, link_url);
            self.truncated = true;
        }

        fn trimLineToFit(self: *Self, target_x: f32) void {
            while (self.x > target_x and self.state.fragments.items.len > self.line_start_fragment) {
                const last_index = self.state.fragments.items.len - 1;
                var fragment = &self.state.fragments.items[last_index];
                if (fragment.inline_container_line_id == self.line_id) {
                    var remove_start = last_index;
                    var left = fragment.rect.x;
                    while (remove_start > self.line_start_fragment) {
                        const previous = self.state.fragments.items[remove_start - 1];
                        if (previous.inline_container_line_id != self.line_id) break;
                        remove_start -= 1;
                        left = @min(left, previous.rect.x);
                    }
                    self.state.fragments.items.len = remove_start;
                    self.x = left;
                    continue;
                }
                if (fragment.line_id != self.line_id or fragment.text == null) {
                    self.x = fragment.rect.x;
                    self.state.fragments.items.len = last_index;
                    continue;
                }

                var text = fragment.text.?;
                while (text.len > 0 and fragment.rect.x + self.measureFragmentText(fragment.*, text) > target_x) {
                    text = text[0..previousCodepointStart(text)];
                }
                if (text.len == 0) {
                    self.x = fragment.rect.x;
                    self.state.fragments.items.len = last_index;
                    continue;
                }
                const width = self.measureFragmentText(fragment.*, text);
                fragment.text = text;
                fragment.rect.width = width;
                self.x = fragment.rect.x + width;
            }
            self.has_content = self.state.fragments.items.len > self.line_start_fragment;
        }

        fn measureFragmentText(self: *Self, fragment: types.Fragment, text: []const u8) f32 {
            const resolved = font.resolve(self.state.font_registry, fragment.font_family, fragment.font_weight, fragment.font_style);
            var width = (resolved.metrics().widthCssPx(text, fragment.font_size) catch 0) +
                fragment.letter_spacing * @as(f32, @floatFromInt(countCodepoints(text))) +
                fragment.word_spacing * @as(f32, @floatFromInt(countWordSeparators(text)));
            if (fragment.leading_space) {
                width += intrinsic.measureText(self.state.font_registry, " ", fragment.font_family, fragment.font_size, fragment.font_weight, fragment.font_style, fragment.letter_spacing) +
                    fragment.word_spacing;
            }
            return width;
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
                style.letter_spacing * @as(f32, @floatFromInt(countCodepoints(text))) +
                style.word_spacing * @as(f32, @floatFromInt(countWordSeparators(text)));
            if (leading_space) {
                width += intrinsic.measureText(self.state.font_registry, " ", resolved.family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
                width += style.word_spacing;
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
                .word_spacing = style.word_spacing,
                .vertical_align = style.vertical_align,
                .font_weight = style.font_weight,
                .font_style = style.font_style,
                .color = geometry.parseColor(style.color) orelse geometry.Color.black,
                .text_decoration = style.text_decoration,
                .text_decoration_style = style.text_decoration_style,
                .text_decoration_color = if (style.text_decoration_color) |value| geometry.parseColor(value) else null,
                .text_decoration_thickness = resolveTextDecorationThickness(style),
                .link_url = link_url,
            });
            self.x += width;
            self.has_content = true;
        }

        fn measureStyledText(self: *Self, text: []const u8, style: box.Style) f32 {
            return intrinsic.measureText(self.state.font_registry, text, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing) +
                style.word_spacing * @as(f32, @floatFromInt(countWordSeparators(text)));
        }

        fn spaceWidth(self: *Self, style: box.Style) f32 {
            return self.measureStyledText(" ", style);
        }

        fn transformText(self: *Self, text: []const u8, transform: box.TextTransform) ![]const u8 {
            if (transform == .none) {
                self.updateCapitalizeBoundary(text);
                return text;
            }
            const transformed = try self.state.allocator.dupe(u8, text);
            for (transformed) |*byte| {
                if (byte.* >= 0x80) {
                    self.capitalize_next = false;
                    continue;
                }
                const is_letter = std.ascii.isAlphabetic(byte.*);
                switch (transform) {
                    .none => unreachable,
                    .uppercase => if (is_letter) {
                        byte.* = std.ascii.toUpper(byte.*);
                    },
                    .lowercase => if (is_letter) {
                        byte.* = std.ascii.toLower(byte.*);
                    },
                    .capitalize => if (is_letter and self.capitalize_next) {
                        byte.* = std.ascii.toUpper(byte.*);
                    },
                }
                if (is_letter or std.ascii.isDigit(byte.*)) {
                    self.capitalize_next = false;
                } else if (isHtmlWhitespace(byte.*) or byte.* == '-' or byte.* == '/') {
                    self.capitalize_next = true;
                }
            }
            return transformed;
        }

        fn updateCapitalizeBoundary(self: *Self, text: []const u8) void {
            for (text) |byte| {
                if (byte >= 0x80 or std.ascii.isAlphanumeric(byte)) {
                    self.capitalize_next = false;
                } else if (isHtmlWhitespace(byte) or byte == '-' or byte == '/') {
                    self.capitalize_next = true;
                }
            }
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
                .vertical_align = source.style.vertical_align,
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
                fragment.vertical_align = source.style.vertical_align;
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
            if (!self.has_content) return;
            self.alignVerticalLine();
            if (self.text_align == .left) return;
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

        fn alignVerticalLine(self: *Self) void {
            var max_baseline: f32 = 0;
            for (self.state.fragments.items[self.line_start_fragment..]) |fragment| {
                if (fragment.line_id != self.line_id or fragment.kind != .text) continue;
                max_baseline = @max(max_baseline, self.naturalBaseline(fragment));
            }
            if (max_baseline == 0) return;

            for (self.state.fragments.items[self.line_start_fragment..]) |*fragment| {
                if (fragment.line_id != self.line_id or fragment.kind != .text) continue;
                const natural_baseline = self.naturalBaseline(fragment.*);
                const baseline_shift = max_baseline - natural_baseline;
                const shift = switch (fragment.vertical_align) {
                    .baseline => baseline_shift,
                    .sub => baseline_shift + fragment.font_size * 0.2,
                    .super => baseline_shift - fragment.font_size * 0.4,
                    .middle => max_baseline - fragment.font_size * 0.25 - fragment.rect.height / 2,
                    .textTop, .top => 0,
                    .textBottom, .bottom => self.line_height - fragment.rect.height,
                    .offset => |offset| baseline_shift - (offset.resolve(self.line_height) orelse 0),
                };
                fragment.rect.y += shift;
            }

            var min_y = self.line_y;
            var max_bottom = self.line_y + self.line_height;
            for (self.state.fragments.items[self.line_start_fragment..]) |fragment| {
                if (!self.belongsToCurrentLine(fragment)) continue;
                min_y = @min(min_y, fragment.rect.y);
                max_bottom = @max(max_bottom, fragment.rect.bottom());
            }
            if (min_y < self.line_y) {
                const correction = self.line_y - min_y;
                for (self.state.fragments.items[self.line_start_fragment..]) |*fragment| {
                    if (self.belongsToCurrentLine(fragment.*)) fragment.rect.y += correction;
                }
                max_bottom += correction;
            }
            self.line_height = @max(self.line_height, max_bottom - self.line_y);
        }

        fn naturalBaseline(self: *Self, fragment: types.Fragment) f32 {
            if (fragment.kind != .text) return 0;
            const resolved = font.resolve(self.state.font_registry, fragment.font_family, fragment.font_weight, fragment.font_style);
            return fragment.font_size * resolved.metrics().ascentRatio();
        }

        fn belongsToCurrentLine(self: *Self, fragment: types.Fragment) bool {
            return fragment.line_id == self.line_id or fragment.inline_container_line_id == self.line_id;
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

fn isBaselineAlignment(value: box.VerticalAlign) bool {
    return switch (value) {
        .baseline => true,
        else => false,
    };
}

fn resolveTextDecorationThickness(style: box.Style) ?f32 {
    return switch (style.text_decoration_thickness) {
        .auto, .fromFont => null,
        .length => |length| if (length.resolve(style.font_size)) |value| @max(value, 0) else null,
    };
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

fn countWordSeparators(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| if (byte == ' ') {
        count += 1;
    };
    return count;
}

fn previousCodepointStart(text: []const u8) usize {
    if (text.len == 0) return 0;
    var index = text.len - 1;
    while (index > 0 and text[index] & 0xC0 == 0x80) index -= 1;
    return index;
}
