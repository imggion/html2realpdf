const std = @import("std");

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

pub const html_hard =
    \\ <!DOCTYPE html>
    \\ <html lang="it">
    \\ <head>
    \\     <meta charset="UTF-8">
    \\     <title>Test Tokenizer</title>
    \\ </head>
    \\ <body>
    \\     <!-- Questo è un commento -->
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

pub const Attribute = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub const TagOpen = struct {
    name: []const u8,
    attributes: []const Attribute,
    self_closing: bool,
};

pub const Token = union(enum) {
    text: []const u8,
    tag_open: TagOpen,
    tag_close: []const u8,
    comment: []const u8,
    doctype: []const u8,
};

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
    Error,
};

pub const Tokenizer = struct {
    fn appendAttribute(
        allocator: std.mem.Allocator,
        attributes: *std.ArrayList(Attribute),
        name: *?[]const u8,
        value: ?[]const u8,
    ) !void {
        if (name.*) |attr_name| {
            try attributes.append(allocator, .{ .name = attr_name, .value = value });
            name.* = null;
        }
    }

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

    /// Tokenize a raw HTML and return a list of emitted tokens
    pub fn tokenizeHtml(allocator: std.mem.Allocator, html: []const u8) !std.ArrayList(Token) {
        var state: State = .Text;
        var i: usize = 0;
        var start: usize = 0;

        var current_tag_name: ?[]const u8 = null;
        var current_attrs_name: ?[]const u8 = null;
        var current_attributes = try std.ArrayList(Attribute).initCapacity(allocator, 0);
        var current_token_list = try std.ArrayList(Token).initCapacity(allocator, 0);

        while (i < html.len) {
            const c = html[i];

            switch (state) {
                .Text => {
                    if (c == '<') {
                        if (i > start) {
                            const text = html[start..i];
                            if (text.len > 0)
                                try current_token_list.append(allocator, .{ .text = text });
                        }
                        start = i + 1;
                        state = .TagOpen;
                    }
                },

                .TagOpen => {
                    switch (c) {
                        '/' => {
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
                        'a'...'z', 'A'...'Z' => {
                            state = .TagName;
                        },
                        else => {
                            state = .Text;
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
                        ' ', '\t', '\n' => {
                            current_tag_name = html[start..i];
                            start = i + 1;
                            state = .BeforeAttributeName;
                        },
                        '>' => {
                            current_tag_name = html[start..i];
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            state = .Text;
                        },
                        '/' => {
                            current_tag_name = html[start..i];
                            start = i + 1;
                            state = .SelfClosing;
                        },
                        'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
                        else => state = .Error,
                    }
                },

                .EndTagName => {
                    switch (c) {
                        '/' => {
                            start = i + 1;
                            state = .EndTagName;
                        },
                        '>' => {
                            const name = html[start..i];
                            try current_token_list.append(allocator, .{ .tag_close = name });
                            start = i + 1;
                            state = .Text;
                        },
                        ' ', '\t', '\n' => {},
                        'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
                        else => state = .Error,
                    }
                },

                .SelfClosing => {
                    if (c == '>') {
                        try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, true);
                        start = i + 1;
                        state = .Text;
                    } else {
                        state = .Error;
                    }
                },

                .BeforeAttributeName => {
                    switch (c) {
                        ' ', '\t', '\n' => {},
                        '>' => {
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            state = .Text;
                            start = i + 1;
                        },
                        '/' => state = .SelfClosing,
                        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {
                            start = i;
                            state = .AttributeName;
                        },
                        else => state = .Error,
                    }
                },

                .AttributeName => {
                    switch (c) {
                        ' ', '\t', '\n' => {
                            const name = html[start..i];
                            current_attrs_name = name;
                            start = i + 1;
                            state = .AfterAttributeName;
                        },
                        '=' => {
                            const name = html[start..i];
                            current_attrs_name = name;
                            start = i + 1;
                            state = .BeforeAttributeValue;
                        },
                        '>' => {
                            const name = html[start..i];
                            current_attrs_name = name;
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            state = .Text;
                        },
                        '/' => {
                            const name = html[start..i];
                            current_attrs_name = name;
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            start = i + 1;
                            state = .SelfClosing;
                        },
                        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
                        else => state = .Error,
                    }
                },

                .AfterAttributeName => {
                    switch (c) {
                        ' ', '\t', '\n' => {},
                        '=' => state = .BeforeAttributeValue,
                        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            start = i;
                            state = .AttributeName;
                        },
                        '>' => {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            state = .Text;
                            start = i + 1;
                        },
                        '/' => {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            state = .SelfClosing;
                        },
                        else => state = .Error,
                    }
                },

                .BeforeAttributeValue => {
                    switch (c) {
                        ' ', '\t', '\n' => {},
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
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            state = .Text;
                            start = i + 1;
                        },
                        '/' => {
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, null);
                            state = .SelfClosing;
                        },
                        else => {
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
                        ' ', '\t', '\n' => {
                            const value = html[start..i];
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, value);
                            start = i + 1;
                            state = .BeforeAttributeName;
                        },
                        '>' => {
                            const value = html[start..i];
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, value);
                            try appendTagOpen(allocator, &current_token_list, &current_attributes, &current_tag_name, false);
                            start = i + 1;
                            state = .Text;
                        },
                        '/' => {
                            const value = html[start..i];
                            try appendAttribute(allocator, &current_attributes, &current_attrs_name, value);
                            start = i + 1;
                            state = .SelfClosing;
                        },
                        else => {},
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

                .Error => {
                    std.debug.panic("Tokenization error at character '{c}' (index {})\n", .{ c, i });
                },
            }
            i += 1;
        }

        // Emit any remaining text
        if (state == .Text and i > start) {
            const text = html[start..i];
            if (text.len > 0)
                try current_token_list.append(allocator, .{ .text = text });
        }

        return current_token_list;
    }
};

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

    const source = "<div class=\"x\"><p>Hello <strong>world</strong></p><br/></div>";
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
