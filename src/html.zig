const std = @import("std");

// TODO: Encoding in the tokenizer?? For special chars, maybe using ANSI or UTF-8 (need to understand more)

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

const TagOpen = struct {
    name: []const u8,
    attributes: []const Attribute,
    self_closing: bool,
};

const Token = union(enum) {
    text: []const u8, // input slice
    tag_open: TagOpen,
    tag_close: []const u8,
    comment: []const u8,
    doctype: []const u8,
};

const Attribute = struct {
    name: []const u8,
    value: ?[]const u8, // null if boolean (es. disabled)
};

const State = enum {
    // base
    Text,
    TagOpen,
    TagName,
    EndTagName,
    SelfClosing,

    // attributes
    BeforeAttributeName,
    AttributeName,
    AfterAttributeName,
    BeforeAttributeValue,
    AttributeValueDouble,
    AttributeValueSingle,
    AttributeValueUnquoted,

    // others
    Comment,
    Doctype,
    Error,
};

pub fn tokenizeHtml(html: []const u8) !void {
    const allocator = std.heap.page_allocator; // TODO: understand if page_allocator is good for WASM compiling
    var state: State = .Text;
    var i: usize = 0;
    var start: usize = 0;
    var tag_name: ?[]const u8 = null;
    var attr_name: ?[]const u8 = null;

    // The data normalization is delegated to the Parser.
    // TODO: Append tokens into the Array.
    var tokenList = try std.ArrayList(Token).initCapacity(allocator, 0);
    defer tokenList.deinit(allocator);

    std.debug.print("Raw Html:\n{s}\n", .{html});

    while (i < html.len) {
        const c = html[i];

        switch (state) {
            .Text => {
                if (c == '<') {
                    if (i > start) {
                        const text = html[start..i];
                        if (text.len > 0)
                            try tokenList.append(allocator, .{ .text = text });
                        std.debug.print("[TEXT] \"{s}\"\n", .{text});
                    }
                    start = i + 1;
                    state = .TagOpen;
                }
            },

            .TagOpen => {
                state = switch (c) {
                    '/' => .EndTagName,
                    '!' => .Doctype,
                    'a'...'z', 'A'...'Z' => .TagName,
                    else => .Text,
                };
                if (state == .TagName) {
                    start = i;
                }
            },

            .TagName => {
                switch (c) {
                    ' ', '\t', '\n' => {
                        const name = html[start..i];
                        tag_name = name;
                        std.debug.print("[START_TAG] {s}\n", .{name});
                        start = i + 1;
                        state = .BeforeAttributeName;
                    },
                    '>' => {
                        const name = html[start..i];
                        tag_name = name;
                        std.debug.print("[START_TAG] {s}\n", .{name});
                        start = i + 1;
                        state = .Text;
                    },
                    '/' => {
                        const name = html[start..i];
                        tag_name = name;
                        std.debug.print("[START_TAG] {s}\n", .{name});
                        start = i + 1;
                        state = .SelfClosing;
                    },
                    'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
                    else => state = .Error,
                }
            },

            .EndTagName => {
                switch (c) {
                    '>' => {
                        const name = html[start..i];
                        std.debug.print("[END_TAG] {s}\n", .{name});
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
                    std.debug.print("[SELF_CLOSING_TAG] {s}\n", .{tag_name orelse "unknown"});
                    tag_name = null;
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
                        attr_name = name;
                        std.debug.print("[ATTR_NAME] {s}\n", .{name});
                        start = i + 1;
                        state = .AfterAttributeName;
                    },
                    '=' => {
                        const name = html[start..i];
                        attr_name = name;
                        std.debug.print("[ATTR_NAME] {s}\n", .{name});
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
                    std.debug.print("[ATTR_VALUE] \"{s}\"\n", .{value});
                    start = i + 1;
                    state = .BeforeAttributeName;
                }
            },

            .AttributeValueSingle => {
                if (c == '\'') {
                    const value = html[start..i];
                    std.debug.print("[ATTR_VALUE] '{s}'\n", .{value});
                    start = i + 1;
                    state = .BeforeAttributeName;
                }
            },

            .AttributeValueUnquoted => {
                switch (c) {
                    ' ', '\t', '\n' => {
                        const value = html[start..i];
                        std.debug.print("[ATTR_VALUE] {s}\n", .{value});
                        start = i + 1;
                        state = .BeforeAttributeName;
                    },
                    '>' => {
                        const value = html[start..i];
                        std.debug.print("[ATTR_VALUE] {s}\n", .{value});
                        start = i + 1;
                        state = .Text;
                    },
                    '/' => {
                        const value = html[start..i];
                        std.debug.print("[ATTR_VALUE] {s}\n", .{value});
                        start = i + 1;
                        state = .SelfClosing;
                    },
                    else => {},
                }
            },

            .Comment => {
                // Simplified: look for "-->"
                if (c == '-' and i + 2 < html.len and html[i + 1] == '-' and html[i + 2] == '>') {
                    const comment = html[start..i];
                    std.debug.print("[COMMENT] {s}\n", .{comment});
                    i += 2;
                    start = i + 1;
                    state = .Text;
                }
            },

            .Doctype => {
                if (c == '>') {
                    const doctype = html[start..i];
                    std.debug.print("[DOCTYPE] {s}\n", .{doctype});
                    start = i + 1;
                    state = .Text;
                }
            },

            .Error => {
                std.debug.panic("Tokenization error at character '{c}' (index {})\n", .{ c, i });
            },
        }

        // std.debug.print("State: {} --- Char: {c}\n", .{ state, c });
        i += 1;
    }

    // debug info
    // std.debug.print("Token Array \"{s}\"\n", .{tokenList.items});
    std.debug.print("Token Array:\n", .{});
    std.debug.print("[", .{});
    for (tokenList.items) |tkn| {
        std.debug.print("{s}, ", .{tkn.text});
    }
    std.debug.print("]", .{});

    // Emit any remaining text
    if (state == .Text and i > start) {
        std.debug.print("[TEXT] \"{s}\"\n", .{html[start..i]});
    }
}

/// Converts raw HTML into a stream of tokens (start/end tags, text, comments, doctype).
///
/// ### Why a tokenizer?
/// The parser needs a structured, low‑level representation of the document.
/// By decoupling tokenization from parsing, we avoid mixing character‑by‑character
/// logic with tree‑building logic, making each phase simpler and testable in isolation.
///
/// ### Why a state machine?
/// HTML is not regular; constructs like attributes, quoted values, and comments
/// require contextual awareness. An explicit state machine (`State` enum) processes
/// the input in one forward pass without backtracking, which is both efficient
/// and matches the HTML5 tokenization algorithm.
///
/// ---
/// The tokenizer does **not** validate or normalise data (e.g., entity decoding).
/// Those tasks belong to the parser, keeping the tokenizer focused on lexical analysis.
const Tokenizer = struct {
    pub fn tokenizeHtml(html: []const u8) !void {
        _ = html;
        @compileError("Tokenizer not implemented yet");
    }
};
