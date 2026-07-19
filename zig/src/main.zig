//! Minimal smoke program proving libghostty-vt is consumable as a
//! native Zig module. Feeds VT bytes into a terminal and prints the
//! resulting plain-text screen contents.
const std = @import("std");
const ghostty = @import("ghostty-vt");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var terminal: ghostty.Terminal = try .init(allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer terminal.deinit(allocator);

    var stream: ghostty.TerminalStream = .initAlloc(
        allocator,
        .init(&terminal),
    );
    defer stream.deinit();

    stream.nextSlice("hello from \x1b[32mlibghostty-vt\x1b[0m as a native zig module");

    const screen_text = try terminal.plainString(allocator);
    defer allocator.free(screen_text);

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{screen_text});
    try stdout.flush();
}
