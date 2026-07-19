//! Smoke tests proving the native Zig API of libghostty-vt covers what
//! Herdr needs: init/deinit, feeding VT bytes, reading cell content and
//! styling, resize, and grapheme clustering (DEC mode 2027) without the
//! local C-API default-modes patch.
const std = @import("std");
const testing = std.testing;
const ghostty = @import("ghostty-vt");

fn cellAt(
    terminal: *ghostty.Terminal,
    x: ghostty.size.CellCountInt,
    y: ghostty.size.CellCountInt,
) ghostty.PageList.Cell {
    return terminal.screens.active.pages.getCell(
        .{ .screen = .{ .x = x, .y = y } },
    ).?;
}

test "init, feed bytes, read cell content and styling, deinit" {
    const allocator = testing.allocator;

    var terminal: ghostty.Terminal = try .init(allocator, .{
        .cols = 20,
        .rows = 5,
    });
    defer terminal.deinit(allocator);

    var stream: ghostty.TerminalStream = .initAlloc(
        allocator,
        .init(&terminal),
    );
    defer stream.deinit();

    stream.nextSlice("hello\x1b[31mred");

    const screen_text = try terminal.plainString(allocator);
    defer allocator.free(screen_text);
    try testing.expectEqualStrings("hellored", screen_text);

    // Unstyled cell content.
    {
        const list_cell = cellAt(&terminal, 0, 0);
        try testing.expectEqual(@as(u21, 'h'), list_cell.cell.content.codepoint);
        try testing.expectEqual(ghostty.Style{}, list_cell.style());
    }

    // Styled cell content: "r" of "red" at x=5 must carry SGR 31,
    // palette color 1 (red).
    {
        const list_cell = cellAt(&terminal, 5, 0);
        try testing.expectEqual(@as(u21, 'r'), list_cell.cell.content.codepoint);
        const style = list_cell.style();
        try testing.expectEqual(
            ghostty.Style.Color{ .palette = 1 },
            style.fg_color,
        );
    }
}

test "resize preserves content" {
    const allocator = testing.allocator;

    var terminal: ghostty.Terminal = try .init(allocator, .{
        .cols = 20,
        .rows = 5,
    });
    defer terminal.deinit(allocator);

    var stream: ghostty.TerminalStream = .initAlloc(
        allocator,
        .init(&terminal),
    );
    defer stream.deinit();

    stream.nextSlice("resize me");

    try terminal.resize(allocator, 40, 10);
    try testing.expectEqual(@as(ghostty.size.CellCountInt, 40), terminal.cols);
    try testing.expectEqual(@as(ghostty.size.CellCountInt, 10), terminal.rows);

    const screen_text = try terminal.plainString(allocator);
    defer allocator.free(screen_text);
    try testing.expectEqualStrings("resize me", screen_text);
}

// The local Rust-tree patch 0001-default-grapheme-cluster-mode.patch exists
// only because the C API's ghostty_terminal_new cannot set default modes.
// The native Zig Terminal.Options has `default_modes` directly, so the Zig
// tree does not need the patch. These tests prove it.
test "grapheme clustering via native default_modes without patch" {
    const allocator = testing.allocator;

    var terminal: ghostty.Terminal = try .init(allocator, .{
        .cols = 10,
        .rows = 3,
        .default_modes = .{ .grapheme_cluster = true },
    });
    defer terminal.deinit(allocator);

    try testing.expect(terminal.modes.get(.grapheme_cluster));

    var stream: ghostty.TerminalStream = .initAlloc(
        allocator,
        .init(&terminal),
    );
    defer stream.deinit();

    // Woman-firefighter ZWJ sequence: woman + ZWJ + fire engine.
    // With mode 2027 on, this clusters into ONE wide cell (2 columns).
    stream.nextSlice("\u{1F469}\u{200D}\u{1F692}");
    try testing.expectEqual(
        @as(ghostty.size.CellCountInt, 2),
        terminal.screens.active.cursor.x,
    );

    // The cluster lives in a single cell: base codepoint plus grapheme
    // continuation data, followed by a wide spacer tail.
    {
        const list_cell = cellAt(&terminal, 0, 0);
        try testing.expectEqual(@as(u21, 0x1F469), list_cell.cell.content.codepoint);
        try testing.expectEqual(ghostty.Cell.Wide.wide, list_cell.cell.wide);
        try testing.expect(list_cell.cell.hasGrapheme());
        const extra_codepoints = list_cell.node.page().lookupGrapheme(list_cell.cell).?;
        try testing.expectEqualSlices(u21, &.{ 0x200D, 0x1F692 }, extra_codepoints);
    }
    {
        const list_cell = cellAt(&terminal, 1, 0);
        try testing.expectEqual(ghostty.Cell.Wide.spacer_tail, list_cell.cell.wide);
    }

    // The patch's real purpose: RIS (full reset) must restore clustering
    // instead of dropping back to the spec default (off). With
    // `default_modes` this holds natively.
    stream.nextSlice("\x1bc");
    try testing.expect(terminal.modes.get(.grapheme_cluster));
}

test "grapheme clustering off by default matches upstream" {
    const allocator = testing.allocator;

    var terminal: ghostty.Terminal = try .init(allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer terminal.deinit(allocator);

    // Upstream default: mode 2027 is off. The runtime mode API can still
    // enable it after init.
    try testing.expect(!terminal.modes.get(.grapheme_cluster));
    terminal.modes.set(.grapheme_cluster, true);
    try testing.expect(terminal.modes.get(.grapheme_cluster));

    var stream: ghostty.TerminalStream = .initAlloc(
        allocator,
        .init(&terminal),
    );
    defer stream.deinit();

    // Flag of Sweden: two regional indicators cluster into one wide cell.
    stream.nextSlice("\u{1F1F8}\u{1F1EA}");
    try testing.expectEqual(
        @as(ghostty.size.CellCountInt, 2),
        terminal.screens.active.cursor.x,
    );

    const list_cell = cellAt(&terminal, 0, 0);
    try testing.expectEqual(@as(u21, 0x1F1F8), list_cell.cell.content.codepoint);
    try testing.expect(list_cell.cell.hasGrapheme());
}
