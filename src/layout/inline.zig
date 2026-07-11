//! Inline formatting context, whitespace handling, wrapping, and line alignment.

const std = @import("std");
const box = @import("../box.zig");
const geometry = @import("../geometry.zig");
const intrinsic = @import("intrinsic.zig");
const types = @import("types.zig");
const font = @import("../font.zig");
const bidi = @import("../bidi.zig");
const line_break = @import("../line_break.zig");
const unicode_case = @import("../unicode_case.zig");

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
        direction: box.Direction,
        line_start_fragment: usize,
        line_id: usize,
        has_content: bool = false,
        pending_space: bool = false,
        capitalize_next: bool = true,
        ellipsis_enabled: bool = false,
        truncated: bool = false,

        pub fn init(state: *State, start_x: f32, start_y: f32, width: f32, text_align: box.TextAlign, direction: box.Direction, text_indent: f32, ellipsis_enabled: bool) Self {
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
                .direction = direction,
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
                .text => if (source.text) |text| try self.layoutText(box_id, text, source.language, effective_source.style, link_url),
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

        fn layoutText(self: *Self, box_id: box.BoxId, text: []const u8, language: []const u8, style: box.Style, link_url: ?[]const u8) !void {
            const transformed = try self.transformText(text, language, style.text_transform);
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
            if (self.state.shaping_mode == .harfbuzz) {
                try self.layoutUnicodeCollapsedText(box_id, text, style, link_url, allow_wrap);
                return;
            }
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

        fn layoutUnicodeCollapsedText(
            self: *Self,
            box_id: box.BoxId,
            text: []const u8,
            style: box.Style,
            link_url: ?[]const u8,
            allow_wrap: bool,
        ) !void {
            var normalized = try std.ArrayList(u8).initCapacity(self.state.allocator, text.len + 1);
            errdefer normalized.deinit(self.state.allocator);
            var saw_space = self.pending_space;
            self.pending_space = false;
            var index: usize = 0;
            while (index < text.len) {
                if (isHtmlWhitespace(text[index])) {
                    saw_space = true;
                    index += 1;
                    continue;
                }
                if (saw_space and (self.has_content or normalized.items.len > 0)) {
                    try normalized.append(self.state.allocator, ' ');
                }
                saw_space = false;
                const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
                const end = @min(index + sequence_length, text.len);
                try normalized.appendSlice(self.state.allocator, text[index..end]);
                index = end;
            }
            self.pending_space = saw_space;
            if (normalized.items.len == 0) {
                normalized.deinit(self.state.allocator);
                return;
            }
            const normalized_text = try normalized.toOwnedSlice(self.state.allocator);

            const opportunities = try line_break.opportunitiesForLayout(self.state.allocator, normalized_text, null);
            defer if (opportunities.len > 0) self.state.allocator.free(opportunities);
            var chunk_start: usize = 0;
            var leading_space = false;
            while (chunk_start < normalized_text.len) {
                var chunk_end = chunk_start;
                var boundary: line_break.Opportunity = .indeterminate;
                while (chunk_end < normalized_text.len) {
                    const sequence_length = std.unicode.utf8ByteSequenceLength(normalized_text[chunk_end]) catch 1;
                    chunk_end = @min(chunk_end + sequence_length, normalized_text.len);
                    boundary = opportunities[chunk_end - 1];
                    if (shouldBreakAtOpportunity(style.word_break, normalized_text, chunk_end, boundary)) break;
                }

                var body_start = chunk_start;
                while (body_start < chunk_end and normalized_text[body_start] == ' ') {
                    leading_space = true;
                    body_start += 1;
                }
                var body_end = chunk_end;
                var trailing_space = false;
                while (body_end > body_start and normalized_text[body_end - 1] == ' ') {
                    trailing_space = true;
                    body_end -= 1;
                }

                if (body_start < body_end) {
                    const body = normalized_text[body_start..body_end];
                    const body_width = self.measureStyledText(body, style);
                    var space_width = if (leading_space and self.has_content) self.spaceWidth(style) else 0;
                    leading_space = leading_space and self.has_content;

                    if (!allow_wrap and self.ellipsis_enabled and self.x + space_width + body_width > self.start_x + self.width) {
                        try self.truncateWithEllipsis(box_id, body, leading_space, style, link_url);
                        self.pending_space = false;
                        return;
                    }

                    const break_inside = allow_wrap and (style.word_break == .breakAll or
                        style.overflow_wrap == .anywhere or
                        (style.overflow_wrap == .breakWord and body_width > self.width));
                    if (break_inside and self.x + space_width + body_width > self.start_x + self.width) {
                        try self.layoutBreakableWord(box_id, body, leading_space, style, link_url);
                    } else {
                        if (allow_wrap and self.has_content and self.x + space_width + body_width > self.start_x + self.width) {
                            self.newLine();
                            leading_space = false;
                            space_width = 0;
                        }
                        try self.appendTextFragment(box_id, body, space_width + body_width, leading_space, style, link_url);
                    }
                    leading_space = false;
                }

                if (trailing_space) leading_space = true;
                if (boundary == .mandatory) {
                    self.newLine();
                    leading_space = false;
                }
                chunk_start = chunk_end;
            }
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
            const grapheme_boundaries = try line_break.graphemeBoundariesForLayout(self.state.allocator, text);
            defer if (grapheme_boundaries.len > 0) self.state.allocator.free(grapheme_boundaries);
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

                var end = index;
                while (end < text.len) {
                    const sequence_length = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
                    end = @min(end + sequence_length, text.len);
                    if (grapheme_boundaries[end - 1]) break;
                }
                const grapheme_width = self.measureStyledText(text[index..end], style);
                if (allow_wrap and self.has_content and self.x + chunk_width + grapheme_width > self.start_x + self.width) {
                    if (chunk_start < index) try self.appendTextFragment(box_id, text[chunk_start..index], chunk_width, false, style, link_url);
                    self.newLine();
                    chunk_start = index;
                    chunk_width = 0;
                }
                chunk_width += grapheme_width;
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
            const grapheme_boundaries = try line_break.graphemeBoundariesForLayout(self.state.allocator, word);
            defer if (grapheme_boundaries.len > 0) self.state.allocator.free(grapheme_boundaries);
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
                var end = index;
                while (end < word.len) {
                    const sequence_length = std.unicode.utf8ByteSequenceLength(word[end]) catch 1;
                    end = @min(end + sequence_length, word.len);
                    if (grapheme_boundaries[end - 1]) break;
                }
                const grapheme_width = self.measureStyledText(word[index..end], style);
                if (chunk_start == index and self.has_content and self.x + leading_width + grapheme_width > self.start_x + self.width) {
                    self.newLine();
                    leading_space = false;
                    leading_width = 0;
                }
                if (chunk_start < index and self.x + leading_width + chunk_width + grapheme_width > self.start_x + self.width) {
                    try self.appendTextFragment(box_id, word[chunk_start..index], leading_width + chunk_width, leading_space, style, link_url);
                    self.newLine();
                    leading_space = false;
                    leading_width = 0;
                    chunk_start = index;
                    chunk_width = 0;
                }
                chunk_width += grapheme_width;
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
            try self.trimLineToFit(line_end - ellipsis_width);
            const grapheme_boundaries = try line_break.graphemeBoundariesForLayout(self.state.allocator, word);
            defer if (grapheme_boundaries.len > 0) self.state.allocator.free(grapheme_boundaries);

            var leading_space = requested_leading_space and self.has_content;
            var consumed = if (leading_space) self.spaceWidth(style) else 0;
            var prefix_end: usize = 0;
            var index: usize = 0;
            while (index < word.len) {
                var end = index;
                while (end < word.len) {
                    const sequence_length = std.unicode.utf8ByteSequenceLength(word[end]) catch 1;
                    end = @min(end + sequence_length, word.len);
                    if (grapheme_boundaries[end - 1]) break;
                }
                const grapheme_width = self.measureStyledText(word[index..end], style);
                if (self.x + consumed + grapheme_width + ellipsis_width > line_end) break;
                consumed += grapheme_width;
                prefix_end = end;
                index = end;
            }
            if (prefix_end > 0) {
                try self.appendTextFragment(box_id, word[0..prefix_end], consumed, leading_space, style, link_url);
            } else {
                leading_space = false;
            }

            try self.trimLineToFit(line_end - ellipsis_width);
            try self.appendTextFragment(box_id, ellipsis, ellipsis_width, false, style, link_url);
            self.truncated = true;
        }

        fn trimLineToFit(self: *Self, target_x: f32) !void {
            while (self.x > target_x and self.state.fragments.items.len > self.line_start_fragment) {
                const last_index = self.state.fragments.items.len - 1;
                var fragment = &self.state.fragments.items[last_index];
                if (fragment.inline_atomic_container) |container| {
                    var remove_start = last_index;
                    var left = fragment.rect.x;
                    while (remove_start > self.line_start_fragment) {
                        const previous = self.state.fragments.items[remove_start - 1];
                        if (previous.inline_atomic_container != container) break;
                        remove_start -= 1;
                        left = @min(left, previous.rect.x);
                    }
                    self.state.fragments.items.len = remove_start;
                    self.x = left - self.state.tree.boxes.items[container].margin.left;
                    continue;
                }
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
                while (text.len > 0 and fragment.rect.x + try self.measureFragmentText(fragment.*, text) > target_x) {
                    text = text[0..previousCodepointStart(text)];
                }
                if (text.len == 0) {
                    self.x = fragment.rect.x;
                    self.state.fragments.items.len = last_index;
                    continue;
                }
                const width = try self.measureFragmentText(fragment.*, text);
                fragment.text = text;
                const resolved = font.resolve(self.state.font_registry, fragment.font_family, fragment.font_weight, fragment.font_style);
                fragment.shaped = try font.shapeWithMode(self.state.allocator, resolved, text, if (fragment.bidi_level & 1 == 0) .ltr else .rtl, self.state.shaping_mode);
                fragment.rect.width = width;
                self.x = fragment.rect.x + width;
            }
            self.has_content = self.state.fragments.items.len > self.line_start_fragment;
        }

        fn measureFragmentText(self: *Self, fragment: types.Fragment, text: []const u8) !f32 {
            const resolved = font.resolve(self.state.font_registry, fragment.font_family, fragment.font_weight, fragment.font_style);
            const shaped = try font.shapeWithMode(self.state.allocator, resolved, text, if (fragment.bidi_level & 1 == 0) .ltr else .rtl, self.state.shaping_mode);
            var width = font.shapedWidthCssPx(
                shaped,
                text,
                resolved.metrics().units_per_em,
                fragment.font_size,
                fragment.letter_spacing,
                fragment.word_spacing,
            );
            if (fragment.leading_space) {
                width += intrinsic.measureText(self.state.font_registry, self.state.shaping_mode, " ", fragment.font_family, fragment.font_size, fragment.font_weight, fragment.font_style, fragment.letter_spacing) +
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
            if (self.state.shaping_mode == .harfbuzz) {
                if (leading_space) {
                    try self.appendBidiTextFragment(box_id, " ", style, link_url, true);
                }
                try self.appendBidiTextFragment(box_id, text, style, link_url, false);
                return;
            }
            const direction = font.detectDirection(text);
            try self.appendFontRuns(box_id, text, leading_space, style, link_url, direction, if (direction == .rtl) 1 else 0, false);
        }

        fn appendBidiTextFragment(
            self: *Self,
            box_id: box.BoxId,
            text: []const u8,
            style: box.Style,
            link_url: ?[]const u8,
            collapsible_space: bool,
        ) !void {
            var resolution = try bidi.resolveForLayout(self.state.allocator, text, if (style.direction == .rtl) .rtl else .ltr);
            defer resolution.deinit(self.state.allocator);
            for (resolution.logical_runs) |run| {
                try self.appendFontRuns(box_id, text[run.start..run.end], false, style, link_url, run.direction(), run.level, collapsible_space);
            }
        }

        fn appendFontRuns(
            self: *Self,
            box_id: box.BoxId,
            text: []const u8,
            leading_space: bool,
            style: box.Style,
            link_url: ?[]const u8,
            direction: font.Direction,
            bidi_level: u8,
            collapsible_space: bool,
        ) !void {
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
                        try self.appendResolvedTextFragment(box_id, text[run_start..codepoint_start], active, leading_space and first_run, style, link_url, direction, bidi_level, collapsible_space);
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
            direction: font.Direction,
            bidi_level: u8,
            collapsible_space: bool,
        ) !void {
            const line_height = @max(style.line_height, style.font_size * 1.2);
            self.line_height = @max(self.line_height, line_height);
            const shaped = try font.shapeWithMode(self.state.allocator, resolved, text, direction, self.state.shaping_mode);
            var width = font.shapedWidthCssPx(
                shaped,
                text,
                resolved.metrics().units_per_em,
                style.font_size,
                style.letter_spacing,
                style.word_spacing,
            );
            if (leading_space) {
                width += intrinsic.measureText(self.state.font_registry, self.state.shaping_mode, " ", resolved.family, style.font_size, style.font_weight, style.font_style, style.letter_spacing);
                width += style.word_spacing;
            }
            try self.state.fragments.append(self.state.allocator, .{
                .kind = .text,
                .source_box = box_id,
                .rect = .{ .x = self.x, .y = self.line_y, .width = width, .height = line_height },
                .line_id = self.line_id,
                .text = text,
                .shaped = shaped,
                .leading_space = leading_space,
                .collapsible_space = collapsible_space,
                .bidi_level = bidi_level,
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
            return intrinsic.measureText(self.state.font_registry, self.state.shaping_mode, text, style.font_family, style.font_size, style.font_weight, style.font_style, style.letter_spacing) +
                style.word_spacing * @as(f32, @floatFromInt(countWordSeparators(text)));
        }

        fn spaceWidth(self: *Self, style: box.Style) f32 {
            return self.measureStyledText(" ", style);
        }

        fn transformText(self: *Self, text: []const u8, language: []const u8, transform: box.TextTransform) ![]const u8 {
            if (transform == .none) {
                try unicode_case.updateCapitalizeState(self.state.allocator, text, &self.capitalize_next);
                return text;
            }
            return unicode_case.transform(
                self.state.allocator,
                text,
                switch (transform) {
                    .none => unreachable,
                    .uppercase => .uppercase,
                    .lowercase => .lowercase,
                    .capitalize => .capitalize,
                },
                language,
                &self.capitalize_next,
            );
        }

        fn layoutAtomic(self: *Self, box_id: box.BoxId, source: box.Box, link_url: ?[]const u8) !void {
            const modern = self.state.atomic_inline_baselines;
            const horizontal_non_content = if (modern) source.border.left + source.border.right + source.padding.left + source.padding.right else 0;
            const vertical_non_content = if (modern) source.border.top + source.border.bottom + source.padding.top + source.padding.bottom else 0;
            const size = intrinsic.resolveReplacedSize(
                source.style,
                source.intrinsic_width,
                source.intrinsic_height,
                self.width,
                self.state.page_height orelse self.width,
                horizontal_non_content,
                vertical_non_content,
            );
            const border_width = size.width + horizontal_non_content;
            const border_height = size.height + vertical_non_content;
            const outer_width = if (modern) source.margin.left + border_width + source.margin.right else border_width;
            const outer_height = if (modern) source.margin.top + border_height + source.margin.bottom else border_height;

            if (self.has_content and self.x + outer_width > self.start_x + self.width) self.newLine();
            self.line_height = @max(self.line_height, outer_height);
            const border_x = self.x + if (modern) source.margin.left else 0;
            const border_y = self.line_y + if (modern) source.margin.top else 0;
            const background = if (modern and source.style.background != null)
                geometry.parseColor(source.style.background.?)
            else
                null;
            try self.state.fragments.append(self.state.allocator, .{
                .kind = .replaced,
                .source_box = box_id,
                .rect = .{ .x = border_x, .y = border_y, .width = border_width, .height = border_height },
                .line_id = self.line_id,
                .inline_atomic_container = if (modern) box_id else null,
                .inline_atomic_root = modern,
                .inline_baseline_offset = if (modern) border_height + source.margin.bottom else null,
                .inline_margin_top = if (modern) source.margin.top else 0,
                .inline_margin_bottom = if (modern) source.margin.bottom else 0,
                .font_size = source.style.font_size,
                .background = background,
                .border = source.border,
                .border_paint = types.borderPaint(source.style),
                .border_radius = if (modern) source.style.border_radius else 0,
                .vertical_align = source.style.vertical_align,
                .link_url = link_url,
                .image_source = self.state.attributeForBox(box_id, "src"),
                .image_content_rect = .{
                    .x = border_x + if (modern) source.border.left + source.padding.left else 0,
                    .y = border_y + if (modern) source.border.top + source.padding.top else 0,
                    .width = size.width,
                    .height = size.height,
                },
                .intrinsic_width = source.intrinsic_width,
                .intrinsic_height = source.intrinsic_height,
                .object_fit = source.style.object_fit,
                .object_position = source.style.object_position,
                .bidi_level = if (self.direction == .rtl) 1 else 0,
            });
            self.x += outer_width;
            self.has_content = true;
        }

        fn layoutInlineBlock(self: *Self, box_id: box.BoxId, source: box.Box) !void {
            const horizontal_edges = source.margin.left + source.margin.right + source.border.left + source.border.right + source.padding.left + source.padding.right;
            const horizontal_non_content = source.border.left + source.border.right + source.padding.left + source.padding.right;
            const available_content = @max(self.width - (self.x - self.start_x) - horizontal_edges, 1);
            const needs_intrinsic = self.state.web_sizing or source.style.width.usesIntrinsicSizing() or source.style.min_width.usesIntrinsicSizing() or source.style.max_width.usesIntrinsicSizing();
            const inline_sizes = if (needs_intrinsic) try self.state.measureIntrinsicInline(box_id) else intrinsic.InlineSizes{};
            var requested_content = intrinsic.resolveContentInlineDimension(source.style.width, self.width, horizontal_non_content, source.style.box_sizing, inline_sizes) orelse if (self.state.web_sizing)
                @min(inline_sizes.max_content, @max(inline_sizes.min_content, available_content))
            else
                available_content;
            const minimum = intrinsic.resolveContentInlineDimension(source.style.min_width, self.width, horizontal_non_content, source.style.box_sizing, inline_sizes);
            const maximum = intrinsic.resolveContentInlineDimension(source.style.max_width, self.width, horizontal_non_content, source.style.box_sizing, inline_sizes);
            if (self.state.web_sizing) {
                if (maximum) |value| requested_content = @min(requested_content, value);
                if (minimum) |value| requested_content = @max(requested_content, value);
            } else {
                if (minimum) |value| requested_content = @max(requested_content, value);
                if (maximum) |value| requested_content = @min(requested_content, value);
            }
            const expected_outer_width = requested_content + horizontal_edges;
            if (self.has_content and self.x + expected_outer_width > self.start_x + self.width) self.newLine();

            const fragment_start = self.state.fragments.items.len;
            var nested_cursor_y = self.line_y;
            const rect = if (self.state.web_sizing)
                try self.state.layoutBlockWithOptions(
                    box_id,
                    .{ .x = self.x, .y = self.line_y, .width = expected_outer_width },
                    &nested_cursor_y,
                    .{ .fill_available_width = true },
                )
            else
                try self.state.layoutBlock(
                    box_id,
                    .{ .x = self.x, .y = self.line_y, .width = expected_outer_width },
                    &nested_cursor_y,
                );
            var baseline: ?f32 = null;
            if (self.state.atomic_inline_baselines and source.style.overflow == .visible) {
                for (self.state.fragments.items[fragment_start..]) |fragment| {
                    if (fragment.kind != .text) continue;
                    const candidate = fragment.rect.y + self.textBaselineOffset(fragment);
                    if (baseline == null or candidate > baseline.?) baseline = candidate;
                }
            }
            for (self.state.fragments.items[fragment_start..]) |*fragment| {
                fragment.inline_container_line_id = self.line_id;
                if (self.state.atomic_inline_baselines) {
                    fragment.inline_atomic_container = box_id;
                    fragment.inline_atomic_root = false;
                }
                fragment.vertical_align = source.style.vertical_align;
            }
            if (self.state.atomic_inline_baselines) {
                const root = &self.state.fragments.items[fragment_start];
                root.inline_atomic_root = true;
                root.inline_baseline_offset = (baseline orelse rect.bottom() + source.margin.bottom) - root.rect.y;
                root.inline_margin_top = source.margin.top;
                root.inline_margin_bottom = source.margin.bottom;
                root.font_size = source.style.font_size;
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
            self.reorderCurrentLineBidi();
            self.alignVerticalLine();
            const text_align = self.resolvedTextAlign();
            if (text_align == .left) return;
            const used = self.x - self.start_x;
            const remaining = @max(self.width - used, 0);
            if (text_align == .justify) {
                if (is_last_line or remaining == 0) return;
                var spaces: usize = 0;
                for (self.state.fragments.items[self.line_start_fragment..]) |fragment| {
                    if (fragment.line_id == self.line_id and (fragment.leading_space or fragment.collapsible_space)) spaces += 1;
                }
                if (spaces == 0) return;
                const extra = remaining / @as(f32, @floatFromInt(spaces));
                var shift: f32 = 0;
                for (self.state.fragments.items[self.line_start_fragment..]) |*fragment| {
                    if (fragment.line_id != self.line_id and fragment.inline_container_line_id != self.line_id) continue;
                    if (fragment.leading_space) shift += extra;
                    shiftFragmentX(fragment, shift);
                    if (fragment.collapsible_space) shift += extra;
                }
                return;
            }
            const shift = if (text_align == .center) remaining / 2 else remaining;
            for (self.state.fragments.items[self.line_start_fragment..]) |*fragment| {
                if (fragment.line_id == self.line_id or fragment.inline_container_line_id == self.line_id) shiftFragmentX(fragment, shift);
            }
        }

        fn resolvedTextAlign(self: *Self) box.TextAlign {
            return switch (self.text_align) {
                .start => if (self.direction == .rtl) .right else .left,
                .end => if (self.direction == .rtl) .left else .right,
                else => self.text_align,
            };
        }

        /// Apply UAX #9 rule L2 to the flat fragments of a simple inline line.
        /// Inline-block subtrees remain atomic and are left for the positioned
        /// inline-container pass rather than reordering their internal paint.
        fn reorderCurrentLineBidi(self: *Self) void {
            if (self.state.shaping_mode != .harfbuzz) return;
            var line = self.state.fragments.items[self.line_start_fragment..];
            if (line.len < 2) return;
            for (line) |fragment| {
                if (fragment.line_id != self.line_id or fragment.inline_container_line_id != null) return;
            }

            var logical_text = std.ArrayList(u8).initCapacity(self.state.allocator, line.len * 4) catch return;
            defer logical_text.deinit(self.state.allocator);
            for (line) |fragment| {
                logical_text.appendSlice(self.state.allocator, fragment.text orelse "\xEF\xBF\xBC") catch return;
            }
            var resolution = bidi.resolveForLayout(
                self.state.allocator,
                logical_text.items,
                if (self.direction == .rtl) .rtl else .ltr,
            ) catch return;
            defer resolution.deinit(self.state.allocator);
            var logical_offset: usize = 0;
            for (line) |*fragment| {
                fragment.bidi_level = resolution.levels[logical_offset];
                const fragment_text: []const u8 = fragment.text orelse "\xEF\xBF\xBC";
                logical_offset += fragment_text.len;
            }

            var max_level: u8 = 0;
            var min_odd: u8 = std.math.maxInt(u8);
            var left = line[0].rect.x;
            for (line) |fragment| {
                max_level = @max(max_level, fragment.bidi_level);
                if (fragment.bidi_level & 1 == 1) min_odd = @min(min_odd, fragment.bidi_level);
                left = @min(left, fragment.rect.x);
            }
            if (min_odd == std.math.maxInt(u8)) return;

            var level = max_level;
            while (true) : (level -= 1) {
                var start: usize = 0;
                while (start < line.len) {
                    while (start < line.len and line[start].bidi_level < level) start += 1;
                    var end = start;
                    while (end < line.len and line[end].bidi_level >= level) end += 1;
                    if (end > start + 1) std.mem.reverse(types.Fragment, line[start..end]);
                    start = end;
                }
                if (level == min_odd) break;
            }

            var visual_x = left;
            for (line) |*fragment| {
                shiftFragmentX(fragment, visual_x - fragment.rect.x);
                visual_x += fragment.rect.width;
            }
        }

        fn alignVerticalLine(self: *Self) void {
            var max_baseline: f32 = 0;
            for (self.state.fragments.items[self.line_start_fragment..]) |fragment| {
                if (!self.isAlignmentParticipant(fragment)) continue;
                max_baseline = @max(max_baseline, self.naturalBaselineFromLine(fragment));
            }
            if (max_baseline == 0) return;

            var index = self.line_start_fragment;
            while (index < self.state.fragments.items.len) : (index += 1) {
                const fragment = self.state.fragments.items[index];
                if (!self.isAlignmentParticipant(fragment)) continue;
                const natural_baseline = self.naturalBaselineFromLine(fragment);
                const baseline_shift = max_baseline - natural_baseline;
                const shift = switch (fragment.vertical_align) {
                    .baseline => baseline_shift,
                    .sub => baseline_shift + fragment.font_size * 0.2,
                    .super => baseline_shift - fragment.font_size * 0.4,
                    .middle => if (self.state.atomic_inline_baselines)
                        max_baseline + fragment.font_size * 0.25 - self.alignmentCenterFromLine(fragment)
                    else
                        max_baseline - fragment.font_size * 0.25 - fragment.rect.height / 2,
                    .textTop, .top => fragment.inline_margin_top - (fragment.rect.y - self.line_y),
                    .textBottom, .bottom => self.line_height - fragment.inline_margin_bottom - (fragment.rect.bottom() - self.line_y),
                    .offset => |offset| baseline_shift - (offset.resolve(self.line_height) orelse 0),
                };
                self.shiftAlignmentParticipant(index, shift);
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
                    if (self.belongsToCurrentLine(fragment.*)) shiftFragment(fragment, correction);
                }
                max_bottom += correction;
            }
            self.line_height = @max(self.line_height, max_bottom - self.line_y);
        }

        fn naturalBaselineFromLine(self: *Self, fragment: types.Fragment) f32 {
            const offset = fragment.inline_baseline_offset orelse self.textBaselineOffset(fragment);
            return fragment.rect.y - self.line_y + offset;
        }

        fn textBaselineOffset(self: *Self, fragment: types.Fragment) f32 {
            if (fragment.kind != .text) return 0;
            const resolved = font.resolve(self.state.font_registry, fragment.font_family, fragment.font_weight, fragment.font_style);
            return fragment.font_size * resolved.metrics().ascentRatio();
        }

        fn alignmentCenterFromLine(self: *Self, fragment: types.Fragment) f32 {
            const top = fragment.rect.y - self.line_y - fragment.inline_margin_top;
            const height = fragment.inline_margin_top + fragment.rect.height + fragment.inline_margin_bottom;
            return top + height / 2;
        }

        fn isAlignmentParticipant(self: *Self, fragment: types.Fragment) bool {
            if (!self.belongsToCurrentLine(fragment)) return false;
            if (fragment.inline_atomic_container != null) return fragment.inline_atomic_root;
            if (fragment.inline_container_line_id == self.line_id) return false;
            return fragment.kind == .text;
        }

        fn shiftAlignmentParticipant(self: *Self, index: usize, shift: f32) void {
            if (shift == 0) return;
            const fragment = self.state.fragments.items[index];
            if (fragment.inline_atomic_container) |container| {
                for (self.state.fragments.items[self.line_start_fragment..]) |*member| {
                    if (member.inline_atomic_container == container) shiftFragment(member, shift);
                }
            } else {
                shiftFragment(&self.state.fragments.items[index], shift);
            }
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

fn shiftFragment(fragment: *types.Fragment, shift: f32) void {
    fragment.rect.y += shift;
    if (fragment.image_content_rect) |*image_rect| image_rect.y += shift;
    if (fragment.clip_rect) |*clip_rect| clip_rect.y += shift;
}

fn shiftFragmentX(fragment: *types.Fragment, shift: f32) void {
    fragment.rect.x += shift;
    if (fragment.image_content_rect) |*image_rect| image_rect.x += shift;
    if (fragment.clip_rect) |*clip_rect| clip_rect.x += shift;
}

fn shouldBreakAtOpportunity(word_break: box.WordBreak, text: []const u8, boundary: usize, opportunity: line_break.Opportunity) bool {
    if (!opportunity.permitsBreak()) return false;
    if (opportunity == .mandatory) return true;
    return word_break != .keepAll or !isCjkBoundary(text, boundary);
}

fn isCjkBoundary(text: []const u8, boundary: usize) bool {
    if (boundary == 0 or boundary >= text.len) return false;
    const previous_start = previousCodepointStart(text[0..boundary]);
    const previous = std.unicode.utf8Decode(text[previous_start..boundary]) catch return false;
    const next_length = std.unicode.utf8ByteSequenceLength(text[boundary]) catch return false;
    const next_end = @min(boundary + next_length, text.len);
    const next = std.unicode.utf8Decode(text[boundary..next_end]) catch return false;
    return isCjkCodepoint(previous) and isCjkCodepoint(next);
}

fn isCjkCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x11FF) or
        (codepoint >= 0x2E80 and codepoint <= 0x2FFF) or
        (codepoint >= 0x3040 and codepoint <= 0x30FF) or
        (codepoint >= 0x3130 and codepoint <= 0x318F) or
        (codepoint >= 0x31F0 and codepoint <= 0x31FF) or
        (codepoint >= 0x3400 and codepoint <= 0x4DBF) or
        (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or
        (codepoint >= 0xA960 and codepoint <= 0xA97F) or
        (codepoint >= 0xAC00 and codepoint <= 0xD7FF) or
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or
        (codepoint >= 0xFF66 and codepoint <= 0xFF9D) or
        (codepoint >= 0x20000 and codepoint <= 0x3134F);
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

test "keep-all suppresses only discretionary CJK boundaries" {
    const text = "日本 A";
    try std.testing.expect(!shouldBreakAtOpportunity(.keepAll, text, "日".len, .allowed));
    try std.testing.expect(shouldBreakAtOpportunity(.normal, text, "日".len, .allowed));
    try std.testing.expect(shouldBreakAtOpportunity(.keepAll, text, "日本 ".len, .allowed));
    try std.testing.expect(shouldBreakAtOpportunity(.keepAll, text, "日".len, .mandatory));
    try std.testing.expect(!shouldBreakAtOpportunity(.keepAll, text, "日".len, .prohibited));
}
