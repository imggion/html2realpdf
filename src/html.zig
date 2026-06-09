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

const Attribute = struct {
    name: []const u8,
    value: ?[]const u8,
};

const TagOpen = struct {
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
                            if (current_tag_name) |name| {
                                const attrs_slice = try current_attributes.toOwnedSlice(allocator);
                                try current_token_list.append(allocator, .{
                                    .tag_open = .{
                                        .name = name,
                                        .attributes = attrs_slice,
                                        .self_closing = false,
                                    },
                                });
                                current_attributes = try std.ArrayList(Attribute).initCapacity(allocator, 0);
                            }
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
                        if (current_tag_name) |name| {
                            const attrs_slice = try current_attributes.toOwnedSlice(allocator);
                            try current_token_list.append(allocator, .{
                                .tag_open = .{
                                    .name = name,
                                    .attributes = attrs_slice,
                                    .self_closing = true,
                                },
                            });
                            current_attributes = try std.ArrayList(Attribute).initCapacity(allocator, 0);
                        }
                        current_tag_name = null;
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
                        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
                        else => state = .Error,
                    }
                },

                .AfterAttributeName => {
                    switch (c) {
                        ' ', '\t', '\n' => {},
                        '=' => state = .BeforeAttributeValue,
                        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {
                            start = i;
                            state = .AttributeName;
                        },
                        '>' => {
                            state = .Text;
                            start = i + 1;
                        },
                        '/' => state = .SelfClosing,
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
                            state = .Text;
                            start = i + 1;
                        },
                        '/' => state = .SelfClosing,
                        else => {
                            start = i;
                            state = .AttributeValueUnquoted;
                        },
                    }
                },

                .AttributeValueDouble => {
                    if (c == '"') {
                        const value = html[start..i];
                        if (current_attrs_name) |name| {
                            try current_attributes.append(allocator, Attribute{ .name = name, .value = value });
                        }
                        start = i + 1;
                        state = .BeforeAttributeName;
                    }
                },

                .AttributeValueSingle => {
                    if (c == '\'') {
                        const value = html[start..i];
                        if (current_attrs_name) |name| {
                            try current_attributes.append(allocator, Attribute{ .name = name, .value = value });
                        }
                        start = i + 1;
                        state = .BeforeAttributeName;
                    }
                },

                .AttributeValueUnquoted => {
                    switch (c) {
                        ' ', '\t', '\n' => {
                            const value = html[start..i];
                            if (current_attrs_name) |name| {
                                try current_attributes.append(allocator, Attribute{ .name = name, .value = value });
                            }
                            start = i + 1;
                            state = .BeforeAttributeName;
                        },
                        '>' => {
                            const value = html[start..i];
                            if (current_attrs_name) |name| {
                                try current_attributes.append(allocator, Attribute{ .name = name, .value = value });
                            }
                            start = i + 1;
                            state = .Text;
                        },
                        '/' => {
                            const value = html[start..i];
                            if (current_attrs_name) |name| {
                                try current_attributes.append(allocator, Attribute{ .name = name, .value = value });
                            }
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

test "tokenize html and show tokens" {
    const html = html_hard;
    const allocator = std.testing.allocator;

    var tokens = try Tokenizer.tokenizeHtml(allocator, html);
    defer {
        // dealloc memory for every open tag's attributes
        for (tokens.items) |token| {
            switch (token) {
                .tag_open => |open_tag| allocator.free(open_tag.attributes),
                else => {},
            }
        }
        tokens.deinit(allocator);
    }

    for (tokens.items) |token| {
        switch (token) {
            .text => |t| std.debug.print("TEXT: {s}\n", .{t}),
            .tag_open => |o| std.debug.print("OPEN: {s} (self_closing={})\n", .{ o.name, o.self_closing }),
            .tag_close => |c| std.debug.print("CLOSE: {s}\n", .{c}),
            .comment => |c| std.debug.print("COMMENT: {s}\n", .{c}),
            .doctype => |d| std.debug.print("DOCTYPE: {s}\n", .{d}),
        }
    }

    std.debug.print("Token count: {}\n", .{tokens.items.len});
}
