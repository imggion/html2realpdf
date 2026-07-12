const std = @import("std");
const Io = std.Io;
const html2realpdf = @import("html2realpdf");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    html2realpdf.retainNativeRuntimeSymbols();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try html2realpdf.writeBanner(stdout_writer);
    try stdout_writer.flush();
}
