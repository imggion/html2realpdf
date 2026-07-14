//! Tolerant HTML tokenizer used by the parser and WASM smoke tests.
//!
//! Token text and tag/name/value slices point into the original input. Only the
//! `tag_open.attributes` slices are allocator-owned, so callers must free those
//! slices when they are done with the returned token list.

const std = @import("std");

/// Small fixture kept near the tokenizer so CLI and tests can share it.
pub const html_simple =
    \\ <!DOCTYPE html>
    \\ <html>
    \\ <body>
    \\ <h1 class="pippo">My First Heading</h1>
    \\ <input disabled />
    \\ <p>My first paragraph.</p>
    \\ </body>
    \\ </html>
;

/// Broader fixture for parser/debug work, not a conformance corpus.
pub const html_hard =
    \\ <!DOCTYPE html>
    \\ <html lang="it">
    \\ <head>
    \\     <meta charset="UTF-8">
    \\     <title>Test Tokenizer</title>
    \\ </head>
    \\ <body>
    \\     <!-- This is a comment -->
    \\     <h1 class="title" id="main-title">Titolo Principale</h1>
    \\
    \\     <div class="container" data-info="esempio">
    \\         <p>Paragrafo con <strong>testo in grassetto</strong> e <em>corsivo</em>.</p>
    \\
    \\         <table border="1">
    \\             <tr>
    \\                 <th>Nome</th>
    \\                 <th>Età</th>
    \\             </tr>
    \\             <tr>
    \\                 <td>Mario</td>
    \\                 <td>25</td>
    \\             </tr>
    \\             <tr>
    \\                 <td>Luigi</td>
    \\                 <td>30</td>
    \\             </tr>
    \\         </table>
    \\
    \\         <img src="/image.jpg" alt="Immagine" width="100" height="auto">
    \\         <br/>
    \\         <input type="text" name="username" placeholder="Inserisci nome">
    \\     </div>
    \\
    \\     <footer>
    \\         <p>Footer &copy; 2024</p>
    \\     </footer>
    \\ </body>
    \\ </html>
;

/// Attribute names and values borrow from the input HTML.
///
/// The tokenizer allocates the containing slice for each open tag, but does not
/// duplicate the bytes of individual names or values.
pub const Attribute = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// Open-tag payload kept separate from `Token` so attribute ownership is clear.
pub const TagOpen = struct {
    name: []const u8,
    attributes: []const Attribute,
    self_closing: bool,
};

/// Token stream consumed by the DOM parser.
///
/// Comments and doctypes are preserved here even though the current DOM parser
/// ignores them; keeping them at the token layer avoids losing source facts too
/// early in the pipeline.
pub const Token = union(enum) {
    text: []const u8,
    tag_open: TagOpen,
    tag_close: []const u8,
    comment: []const u8,
    doctype: []const u8,
};

/// Explicit tokenizer states keep recovery behavior readable.
const State = enum {
    Text,
    TagOpen,
    TagName,
    EndTagName,
    SelfClosing,
    BeforeAttributeName,
    AttributeName,
    AfterAttributeName,
    BeforeAttributeValue,
    AttributeValueDouble,
    AttributeValueSingle,
    AttributeValueUnquoted,
    Comment,
    Doctype,
    /// Raw text is needed because CSS may contain `<` that is not HTML markup.
    RawText,
};

/// Namespace for tokenizer routines.
///
/// Keeping the state machine here, instead of spreading helpers across modules,
/// makes HTML recovery rules easier to audit as the parser grows.
pub const Tokenizer = struct {
    /// Keeps the first spelling of duplicate attributes.
    ///
    /// Browser parsers ignore later duplicates; doing the same here prevents the
    /// DOM builder from having to resolve conflicting attributes later.
    fn appendAttribute(
        allocator: std.mem.Allocator,
        attributes: *std.ArrayList(Attribute),
        name: *?[]const u8,
        value: ?[]const u8,
    ) !void {
        if (name.*) |attr_name| {
            if (attr_name.len == 0) {
                name.* = null;
                return;
            }

            for (attributes.items) |attribute| {
                if (std.ascii.eqlIgnoreCase(attribute.name, attr_name)) {
                    name.* = null;
                    return;
                }
            }

            try attributes.append(allocator, .{ .name = attr_name, .value = value });
            name.* = null;
        }
    }

    /// Transfers the temporary attribute list into a token.
    ///
    /// The returned token owns that slice, then the tokenizer starts a fresh list
    /// for the next tag without copying attribute name/value bytes.
    fn appendTagOpen(
        allocator: std.mem.Allocator,
        tokens: *std.ArrayList(Token),
        attributes: *std.ArrayList(Attribute),
        name: *?[]const u8,
        self_closing: bool,
    ) !void {
        if (name.*) |tag_name| {
            const attrs_slice = try attributes.toOwnedSlice(allocator);
            try tokens.append(allocator, .{
                .tag_open = .{
                    .name = tag_name,
                    .attributes = attrs_slice,
                    .self_closing = self_closing,
                },
            });
            attributes.* = try std.ArrayList(Attribute).initCapacity(allocator, 0);
            name.* = null;
        }
    }

    /// Accepts forgiving raw-text end tags such as `</STYLE >`.
    ///
    /// This keeps style content opaque until the matching end tag instead of
    /// trying to parse CSS-like text as HTML markup.
    fn rawTextEndTagLen(source: []const u8, index: usize, name: []const u8) ?usize {
        if (index + 2 + name.len > source.len) return null;
        if (source[index] != '<' or source[index + 1] != '/') return null;
        if (!std.ascii.eqlIgnoreCase(source[index + 2 .. index + 2 + name.len], name)) return null;

        var i = index + 2 + name.len;
        while (i < source.len and isHtmlWhitespace(source[i])) : (i += 1) {}

        if (i >= source.len or source[i] != '>') return null;
        return i - index + 1;
    }

    /// Enters raw-text mode only for tags whose body should stay opaque here.
    fn enterTextOrRawText(tag_name: ?[]const u8, raw_text_tag: *?[]const u8, state: *State) void {
        state.* = .Text;
        if (tag_name) |name| {
            if (std.ascii.eqlIgnoreCase(name, "style")) {
                raw_text_tag.* = name;
                state.* = .RawText;
            }
        }
    }

    /// Converts an HTML byte slice into tokens without owning the source bytes.
    ///
    /// Malformed or incomplete markup is kept as text where possible. The caller
    /// owns the returned `ArrayList` and every `tag_open.attributes` slice inside
    /// it.
    pub fn tokenizeHtml(allocator: std.mem.Allocator, html: []const u8) !std.ArrayList(Token) {
        var state: State = .Text;
        var i: usize = 0;
        var start: usize = 0;
        var markup_start: usize = 0;

        var raw_text_tag: ?[]const u8 = null;
        var current_tag_name: ?[]const u8 = null;
        var current_attrs_name: ?[]const u8 = null;
        var current_attributes = try std.ArrayList(Attribute).initCapacity(allocator, 0);
        defer current_attributes.deinit(allocator);
        var current_token_list = try std.ArrayList(Token).initCapacity(allocator, 0);

        while (i < html.len) {
            const c = html[i];

            switch (state) {
                .Text => {
                    if (c == '<' and canStartMarkup(html, i)) {
                        if (i > start) {
                            const text = html[start..i];
                            if (text.len > 0)
                                try current_token_list.append(allocator, .{ .text = text });
                        }
                        markup_start = i;
                        start = i + 1;
                        state = .TagOpen;
                    }
                },

                .TagOpen => {
                    switch (c) {
                        '/' => {
                            current_tag_name = null;
                            start = i + 1;
                            state = .EndTagName;
                        },
                        '!' => {
                            // look forward to distinguish between comment and doctype
                            if (i + 1 < html.len and html[i + 1] == '-' and i + 2 < html.len and html[i + 2] == '-') {
                                start = i + 3; // after "<!--"
                                state = .Comment;
                            } else {
                                state = .Doctype;
                            }
                        },
                        else => {
                            state = .TagName;
                        },
                    }
                    if (state == .TagName) start = i;
                },

                .TagName => {
                    if (start == i) {
                        current_tag_name = null;
                        current_attributes.clearRetainingCapacity();
                    }
                    switch (c) {
                        else => if (isHtmlWhitespace(c)) {
                            current_tag_name = html[start..i];
                            start = i + 1;
                            state = .BeforeAttributeName;
                        } else if (c == '>') {
                            current_tag_name = html[start..i];
                            const raw_tag_name = current_tag_name;
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            enterTextOrRawText(raw_tag_name, &raw_text_tag, &state);
                        } else if (c == '/') {
                            current_tag_name = html[start..i];
                            start = i + 1;
                            state = .SelfClosing;
                        },
                    }
                },

                .EndTagName => {
                    switch (c) {
                        '>' => {
                            const name = current_tag_name orelse html[start..i];
                            try current_token_list.append(allocator, .{ .tag_close = name });
                            current_tag_name = null;
                            start = i + 1;
                            state = .Text;
                        },
                        else => if (isHtmlWhitespace(c) and current_tag_name == null) {
                            current_tag_name = html[start..i];
                        },
                    }
                },

                .SelfClosing => {
                    if (c == '>') {
                        try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, true);
                        start = i + 1;
                        state = .Text;
                    } else if (isHtmlWhitespace(c)) {
                        state = .SelfClosing;
                    } else {
                        state = .BeforeAttributeName;
                    }
                },

                .BeforeAttributeName => {
                    switch (c) {
                        '>' => {
                            const raw_tag_name = current_tag_name;
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            enterTextOrRawText(raw_tag_name, &raw_text_tag, &state);
                        },
                        '/' => state = .SelfClosing,
                        else => if (isHtmlWhitespace(c)) {} else {
                            start = i;
                            state = .AttributeName;
                        },
                    }
                },

                .AttributeName => {
                    switch (c) {
                        else => if (isHtmlWhitespace(c)) {
                            const name = html[start..i];
                            current_attrs_name = name;
                            start = i + 1;
                            state = .AfterAttributeName;
                        } else if (c == '=') {
                            const name = html[start..i];
                            current_attrs_name = name;
                            start = i + 1;
                            state = .BeforeAttributeValue;
                        } else if (c == '>') {
                            const name = html[start..i];
                            current_attrs_name = name;
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            const raw_tag_name = current_tag_name;
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            enterTextOrRawText(raw_tag_name, &raw_text_tag, &state);
                        } else if (c == '/') {
                            const name = html[start..i];
                            current_attrs_name = name;
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            start = i + 1;
                            state = .SelfClosing;
                        },
                    }
                },

                .AfterAttributeName => {
                    switch (c) {
                        '=' => state = .BeforeAttributeValue,
                        '>' => {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            const raw_tag_name = current_tag_name;
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            enterTextOrRawText(raw_tag_name, &raw_text_tag, &state);
                        },
                        '/' => {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            state = .SelfClosing;
                        },
                        else => if (isHtmlWhitespace(c)) {} else {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            start = i;
                            state = .AttributeName;
                        },
                    }
                },

                .BeforeAttributeValue => {
                    switch (c) {
                        '"' => {
                            start = i + 1;
                            state = .AttributeValueDouble;
                        },
                        '\'' => {
                            start = i + 1;
                            state = .AttributeValueSingle;
                        },
                        '>' => {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            const raw_tag_name = current_tag_name;
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            enterTextOrRawText(raw_tag_name, &raw_text_tag, &state);
                        },
                        '/' => {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            state = .SelfClosing;
                        },
                        else => if (isHtmlWhitespace(c)) {} else {
                            start = i;
                            state = .AttributeValueUnquoted;
                        },
                    }
                },

                .AttributeValueDouble => {
                    if (c == '"') {
                        const value = html[start..i];
                        try appendAttribute(allocator, &current_attributes, &current_attrs_name, value);
                        start = i + 1;
                        state = .BeforeAttributeName;
                    }
                },

                .AttributeValueSingle => {
                    if (c == '\'') {
                        const value = html[start..i];
                        try appendAttribute(allocator, &current_attributes, &current_attrs_name, value);
                        start = i + 1;
                        state = .BeforeAttributeName;
                    }
                },

                .AttributeValueUnquoted => {
                    switch (c) {
                        else => if (isHtmlWhitespace(c)) {
                            const value = html[start..i];
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, value);
                            start = i + 1;
                            state = .BeforeAttributeName;
                        } else if (c == '>') {
                            const value = html[start..i];
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, value);
                            const raw_tag_name = current_tag_name;
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            enterTextOrRawText(raw_tag_name, &raw_text_tag, &state);
                        } else if (c == '/') {
                            const value = html[start..i];
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, value);
                            start = i + 1;
                            state = .SelfClosing;
                        },
                    }
                },

                .Comment => {
                    if (c == '-' and i + 2 < html.len and html[i + 1] == '-' and html[i + 2] == '>') {
                        const comment = html[start..i];
                        try current_token_list.append(allocator, .{ .comment = comment });
                        i += 2;
                        start = i + 1;
                        state = .Text;
                    }
                },

                .Doctype => {
                    if (c == '>') {
                        const doctype = html[start..i];
                        try current_token_list.append(allocator, .{ .doctype = doctype });
                        start = i + 1;
                        state = .Text;
                    }
                },
                .RawText => {
                    if (raw_text_tag) |tag_name| {
                        if (c == '<') {
                            if (rawTextEndTagLen(html, i, tag_name)) |end_len| {
                                if (i > start) {
                                    try current_token_list.append(
                                        allocator,
                                        .{ .text = html[start..i] },
                                    );
                                }
                                try current_token_list.append(allocator, .{ .tag_close = tag_name });
                                i += end_len - 1;
                                start = i + 1;
                                raw_text_tag = null;
                                state = .Text;
                            }
                        }
                    }
                },
            }
            i += 1;
        }

        // Preserve malformed trailing markup as text instead of dropping bytes.
        if (state == .Text and i > start) {
            const text = html[start..i];
            if (text.len > 0)
                try current_token_list.append(allocator, .{ .text = text });
        } else if (state == .RawText and i > start) {
            try current_token_list.append(allocator, .{ .text = html[start..i] });
        } else if (state != .Text and i > markup_start) {
            try current_token_list.append(allocator, .{ .text = html[markup_start..i] });
        }

        return current_token_list;
    }
};

/// HTML's whitespace set is smaller and more precise than general Unicode space.
fn isHtmlWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C;
}

/// Rejects `<` that is ordinary text, such as `2 < 3`.
///
/// This cheap guard avoids turning common text into broken tags without adding a
/// full HTML5 tokenizer front-end.
fn canStartMarkup(source: []const u8, index: usize) bool {
    if (index + 1 >= source.len) return false;

    const next = source[index + 1];
    if (std.ascii.isAlphabetic(next) or next == '!') return true;
    if (next == '/') return index + 2 < source.len and std.ascii.isAlphabetic(source[index + 2]);

    return false;
}

/// Debug helper used by tests and WASM-facing diagnostics.
pub fn dumpTokens(tokens: []const Token, writer: *std.Io.Writer) !void {
    for (tokens) |token| {
        switch (token) {
            .text => |text| try writer.print("TEXT \"{s}\"\n", .{text}),
            .tag_open => |open_tag| {
                try writer.print("OPEN {s}", .{open_tag.name});
                try dumpAttributes(open_tag.attributes, writer);
                if (open_tag.self_closing) {
                    try writer.writeAll(" self_closing=true");
                }
                try writer.writeAll("\n");
            },
            .tag_close => |name| try writer.print("CLOSE {s}\n", .{name}),
            .comment => |comment| try writer.print("COMMENT \"{s}\"\n", .{comment}),
            .doctype => |doctype| try writer.print("DOCTYPE \"{s}\"\n", .{doctype}),
        }
    }
}

fn dumpAttributes(attributes: []const Attribute, writer: *std.Io.Writer) !void {
    for (attributes) |attribute| {
        try writer.print(" {s}", .{attribute.name});
        if (attribute.value) |value| {
            try writer.print("=\"{s}\"", .{value});
        }
    }
}

fn deinitTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList(Token)) void {
    for (tokens.items) |token| {
        switch (token) {
            .tag_open => |open_tag| allocator.free(open_tag.attributes),
            else => {},
        }
    }

    tokens.deinit(allocator);
}

// ========================================================================================
// TESTS
// ========================================================================================
test "tokenize open tags with attributes" {
    const source = "<div class=\"x\" data-id=1><input disabled /></div>";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);

    switch (tokens.items[0]) {
        .tag_open => |open_tag| {
            try std.testing.expectEqualStrings("div", open_tag.name);
            try std.testing.expect(!open_tag.self_closing);
            try std.testing.expectEqual(@as(usize, 2), open_tag.attributes.len);
            try std.testing.expectEqualStrings("class", open_tag.attributes[0].name);
            try std.testing.expectEqualStrings("x", open_tag.attributes[0].value.?);
            try std.testing.expectEqualStrings("data-id", open_tag.attributes[1].name);
            try std.testing.expectEqualStrings("1", open_tag.attributes[1].value.?);
        },
        else => return error.ExpectedTagOpen,
    }

    switch (tokens.items[1]) {
        .tag_open => |open_tag| {
            try std.testing.expectEqualStrings("input", open_tag.name);
            try std.testing.expect(open_tag.self_closing);
            try std.testing.expectEqual(@as(usize, 1), open_tag.attributes.len);
            try std.testing.expectEqualStrings("disabled", open_tag.attributes[0].name);
            try std.testing.expectEqual(@as(?[]const u8, null), open_tag.attributes[0].value);
        },
        else => return error.ExpectedTagOpen,
    }

    switch (tokens.items[2]) {
        .tag_close => |name| try std.testing.expectEqualStrings("div", name),
        else => return error.ExpectedTagClose,
    }
}

test "keep invalid less-than as text" {
    const source = "2 < 3";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);

    switch (tokens.items[0]) {
        .text => |text| try std.testing.expectEqualStrings(source, text),
        else => return error.ExpectedText,
    }
}

test "tokenize html whitespace and permissive attribute names" {
    const source = "<div\rdata-x=1\x0C@bad=x>ok</div>";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);

    switch (tokens.items[0]) {
        .tag_open => |open_tag| {
            try std.testing.expectEqualStrings("div", open_tag.name);
            try std.testing.expectEqual(@as(usize, 2), open_tag.attributes.len);
            try std.testing.expectEqualStrings("data-x", open_tag.attributes[0].name);
            try std.testing.expectEqualStrings("1", open_tag.attributes[0].value.?);
            try std.testing.expectEqualStrings("@bad", open_tag.attributes[1].name);
            try std.testing.expectEqualStrings("x", open_tag.attributes[1].value.?);
        },
        else => return error.ExpectedTagOpen,
    }
}

test "ignore duplicate attributes" {
    const source = "<input class=x class=y CLASS=z>";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);

    switch (tokens.items[0]) {
        .tag_open => |open_tag| {
            try std.testing.expectEqual(@as(usize, 1), open_tag.attributes.len);
            try std.testing.expectEqualStrings("class", open_tag.attributes[0].name);
            try std.testing.expectEqualStrings("x", open_tag.attributes[0].value.?);
        },
        else => return error.ExpectedTagOpen,
    }
}

test "trim end tag whitespace" {
    const source = "<div>x</div >";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);

    switch (tokens.items[2]) {
        .tag_close => |name| try std.testing.expectEqualStrings("div", name),
        else => return error.ExpectedTagClose,
    }
}

test "keep incomplete tag as text" {
    const source = "<div class=";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);

    switch (tokens.items[0]) {
        .text => |text| try std.testing.expectEqualStrings(source, text),
        else => return error.ExpectedText,
    }
}

test "tokenize style content as raw text" {
    const source = "<style>body > p { color: red; }</style>";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);

    switch (tokens.items[0]) {
        .tag_open => |open_tag| try std.testing.expectEqualStrings("style", open_tag.name),
        else => return error.ExpectedTagOpen,
    }

    switch (tokens.items[1]) {
        .text => |text| try std.testing.expectEqualStrings("body > p { color: red; }", text),
        else => return error.ExpectedText,
    }

    switch (tokens.items[2]) {
        .tag_close => |name| try std.testing.expectEqualStrings("style", name),
        else => return error.ExpectedTagClose,
    }
}

test "do not parse less-than inside style" {
    const source = "<style>.x::before { content: \"<\"; }</style>";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);

    switch (tokens.items[1]) {
        .text => |text| try std.testing.expectEqualStrings(".x::before { content: \"<\"; }", text),
        else => return error.ExpectedText,
    }
}

test "tokenize uppercase style as raw text" {
    const source = "<STYLE>.x{color:red}</STYLE >";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);

    switch (tokens.items[0]) {
        .tag_open => |open_tag| try std.testing.expectEqualStrings("STYLE", open_tag.name),
        else => return error.ExpectedTagOpen,
    }

    switch (tokens.items[1]) {
        .text => |text| try std.testing.expectEqualStrings(".x{color:red}", text),
        else => return error.ExpectedText,
    }

    switch (tokens.items[2]) {
        .tag_close => |name| try std.testing.expectEqualStrings("STYLE", name),
        else => return error.ExpectedTagClose,
    }
}

test "dump tokenizer tokens" {
    const source = "<div class=\"x\" data-id=1><input disabled /></div>";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try dumpTokens(tokens.items, &writer);

    const expected =
        \\OPEN div class="x" data-id="1"
        \\OPEN input disabled self_closing=true
        \\CLOSE div
        \\
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "debug dump tokenizer tokens" {
    if (!std.testing.environ.containsUnemptyConstant("HTML2REALPDF_DEBUG_TOKENIZER")) return;

    const source = "<style>body > p { color: red; }.x::before { content: \"<\"; }</style><div class=\"x\"><p>Hello <strong>world</strong></p><br/></div>";
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, source);
    defer deinitTokens(allocator, &tokens);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try dumpTokens(tokens.items, &writer);

    std.debug.print("\n{s}", .{writer.buffered()});
}

test "tokenize hard html sample" {
    const html = html_hard;
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, html);
    defer deinitTokens(allocator, &tokens);

    var found_container = false;
    for (tokens.items) |token| {
        switch (token) {
            .tag_open => |open_tag| {
                if (std.ascii.eqlIgnoreCase(open_tag.name, "div")) {
                    found_container = true;
                    try std.testing.expectEqual(@as(usize, 2), open_tag.attributes.len);
                    try std.testing.expectEqualStrings("class", open_tag.attributes[0].name);
                    try std.testing.expectEqualStrings("container", open_tag.attributes[0].value.?);
                    try std.testing.expectEqualStrings("data-info", open_tag.attributes[1].name);
                    try std.testing.expectEqualStrings("esempio", open_tag.attributes[1].value.?);
                    break;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(found_container);
}
