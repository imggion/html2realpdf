const std = @import("std");
const html = @import("html.zig");

const tokenizer = html.Tokenizer;

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
