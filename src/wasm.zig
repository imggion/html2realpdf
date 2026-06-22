const std = @import("std");
const html2realpdf = @import("html2realpdf");

const tokenizer = html2realpdf.html.Tokenizer;
const dom = html2realpdf.dom;
const box = html2realpdf.box;

var last_output_len: usize = 0;

export fn alloc(len: usize) usize {
    const buf = std.heap.wasm_allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

export fn free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;

    const bytes: [*]u8 = @ptrFromInt(ptr);
    std.heap.wasm_allocator.free(bytes[0..len]);
}

/// Tokenize Html function exported to Javascript
export fn tokenize_html(ptr: usize, len: usize) isize {
    if (ptr == 0) return -1;

    const input_ptr: [*]const u8 = @ptrFromInt(ptr);
    const input = input_ptr[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const tokens = tokenizer.tokenizeHtml(arena, input) catch return -1;

    return @intCast(tokens.items.len);
}

export fn dom_tree_output_len() usize {
    return last_output_len;
}

export fn box_tree_output_len() usize {
    return last_output_len;
}

export fn dom_tree_html(ptr: usize, len: usize) usize {
    last_output_len = 0;
    if (ptr == 0) return 0;

    const input_ptr: [*]const u8 = @ptrFromInt(ptr);
    const input = input_ptr[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const tokens = tokenizer.tokenizeHtml(arena, input) catch return 0;
    var document = dom.Parser.parse(arena, input, tokens.items) catch return 0;
    defer document.deinit(arena);

    var dump_writer = std.Io.Writer.Allocating.init(arena);
    document.dump(&dump_writer.writer) catch return 0;

    const dump = dump_writer.writer.buffered();
    const output = std.heap.wasm_allocator.dupe(u8, dump) catch return 0;

    last_output_len = output.len;
    return @intFromPtr(output.ptr);
}

export fn box_tree_html(ptr: usize, len: usize) usize {
    last_output_len = 0;
    if (ptr == 0) return 0;

    const input_ptr: [*]const u8 = @ptrFromInt(ptr);
    const input = input_ptr[0..len];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const tokens = tokenizer.tokenizeHtml(arena, input) catch return 0;
    var document = dom.Parser.parse(arena, input, tokens.items) catch return 0;
    defer document.deinit(arena);

    var tree = box.Builder.build(arena, &document, &.{}, document.root) catch return 0;
    defer tree.deinit(arena);

    var dump_writer = std.Io.Writer.Allocating.init(arena);
    tree.dumpWithStyles(&document, &dump_writer.writer) catch return 0;

    const dump = dump_writer.writer.buffered();
    const output = std.heap.wasm_allocator.dupe(u8, dump) catch return 0;

    last_output_len = output.len;
    return @intFromPtr(output.ptr);
}
