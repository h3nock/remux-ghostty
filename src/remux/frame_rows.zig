//! Where the cursor is and how far down a frame's content reaches, published with the frame itself so an embedder
//! lays out around the picture actually on screen rather than the terminal's newer state. Remux slides a terminal
//! that an on-screen keyboard partly covers just far enough to keep the cursor and what is drawn below it in view.
//!
//! The renderer notes the cursor when it rebuilds its cells and measures each frame from those cells when it draws,
//! both under its draw lock, so the two describe the same picture. The frame's target carries the result to the
//! layer, which sets it in the same main-thread step that sets the layer's `contents`.
const std = @import("std");

/// One frame's rows in surface pixels from the surface's top edge, padding included; a row scrolled partly off the
/// top starts above 0. -1 means none: no cursor shown (both cursor values), or nothing drawn. The layout is part of
/// the embedder contract (16 bytes, read by offset): a cursor is there when its bottom is below its top.
pub const FrameRows = extern struct {
    cursor_top: f32 = -1,
    cursor_bottom: f32 = -1,
    content_bottom: f32 = -1,
    /// The layout's version; 0 only in a value that never described a frame.
    version: u32 = 0,

    pub const current_version: u32 = 1;
};

/// The layer key holding a frame's `FrameRows` as NSData: `[layer valueForKey:@"remuxFrameRows"]`.
pub const layer_key = "remuxFrameRows";

/// The cursor as of the cells last rebuilt: its row when the terminal shows it. A cursor the program hid isn't
/// published, since a program that draws its own input often parks a hidden cursor elsewhere.
pub const Cursor = struct {
    row: ?usize = null,

    /// From the render state the cells were just rebuilt from. A blinking cursor counts as shown in both phases of
    /// its blink, so the value doesn't change with it.
    pub fn of(state: anytype, preedit: bool) Cursor {
        const style = @import("../renderer/cursor.zig").style;
        const viewport = state.cursor.viewport orelse return .{};
        const shown = style(state, .{ .preedit = preedit, .focused = true, .blink_visible = true }) != null;
        return .{ .row = if (shown) viewport.y else null };
    }
};

/// The drawn grid a frame's rows are measured against.
pub const Grid = struct {
    /// Rows drawn, including the row revealed below while scrolled by part of a row.
    rows: usize,
    columns: usize,
    cell_height: f32,
    /// Where row 0 starts: the top padding, less any part of a row scrolled away.
    top: f32,
    /// The surface's height: a row or image that starts at or below it isn't in the picture.
    surface_height: f32,

    /// How many rows start above the surface's bottom edge.
    fn rowsInSurface(self: Grid) usize {
        if (self.cell_height <= 0) return self.rows;
        const room = @ceil((self.surface_height - self.top) / self.cell_height);
        if (!(room > 0)) return 0;
        return @min(self.rows, @as(usize, @intFromFloat(@min(room, @as(f32, @floatFromInt(self.rows))))));
    }

    fn rowTop(self: Grid, row: anytype) f32 {
        return self.top + @as(f32, @floatFromInt(row)) * self.cell_height;
    }
};

/// Measures the frame a renderer is about to draw. Call with the renderer's draw lock held, from `drawFrame`: the
/// cells, the cursor noted with them (`remux_cursor`), the scroll offset and the uploaded images all describe the
/// picture drawn.
pub fn ofRenderer(renderer: anytype) FrameRows {
    const cells = &renderer.cells;
    const grid: Grid = .{
        .rows = cells.size.rows,
        .columns = cells.size.columns,
        .cell_height = @floatFromInt(renderer.size.cell.height),
        .top = @as(f32, @floatFromInt(renderer.size.padding.top)) -
            renderer.uniforms.scroll_cell_offset * @as(f32, @floatFromInt(renderer.size.cell.height)),
        .surface_height = @floatFromInt(renderer.size.screen.height),
    };
    // Only images the renderer has uploaded are drawn; one still pending or that failed to upload is skipped.
    var image_bottom: ?f32 = null;
    for (renderer.images.kitty_placements.items) |placement| {
        const entry = renderer.images.images.get(placement.image_id) orelse continue;
        switch (entry.image) {
            .ready, .unload_ready => {},
            else => continue,
        }
        if (placementBottom(grid, placement)) |bottom| image_bottom = @max(image_bottom orelse bottom, bottom);
    }
    return measure(grid, cells.fg_rows, cells.activeBackgroundCells(), renderer.remux_cursor.row, image_bottom);
}

/// The bottom of a Kitty image placement, or null when it starts at or below the surface's bottom edge or ends above
/// its top. A placement has `y` (its grid row, negative when it starts above the top), and `cell_offset_y` and
/// `height` in pixels.
pub fn placementBottom(grid: Grid, placement: anytype) ?f32 {
    const top = grid.rowTop(placement.y) + @as(f32, @floatFromInt(placement.cell_offset_y));
    const bottom = top + @as(f32, @floatFromInt(placement.height));
    if (top >= grid.surface_height or bottom <= 0) return null;
    return bottom;
}

/// A row holds content when it has any foreground cell (a glyph, underline, strikethrough or overline) or any
/// background that isn't fully transparent; `image_bottom` is the bottom of the lowest drawn Kitty image. Only rows
/// that start inside the surface count, and nothing reaches below its bottom edge.
///
/// `fg_rows[y + 1]` holds row y's foreground cells (index 0 is the cursor's list). `bg_cells` holds the grid's
/// backgrounds row by row as RGBA.
pub fn measure(
    grid: Grid,
    fg_rows: anytype,
    bg_cells: []const [4]u8,
    cursor_row: ?usize,
    image_bottom: ?f32,
) FrameRows {
    var result: FrameRows = .{ .version = FrameRows.current_version };
    const rows = grid.rowsInSurface();

    var lowest: f32 = image_bottom orelse -1;
    var y = @min(rows, fg_rows.len -| 1, if (grid.columns == 0) 0 else bg_cells.len / grid.columns);
    while (y > 0) {
        y -= 1;
        if (fg_rows[y + 1].items.len > 0 or hasBackground(bg_cells[y * grid.columns ..][0..grid.columns])) {
            lowest = @max(lowest, grid.rowTop(y + 1));
            break;
        }
    }
    if (lowest > 0) result.content_bottom = @min(lowest, grid.surface_height);

    if (cursor_row) |row| if (row < rows) {
        result.cursor_top = grid.rowTop(row);
        result.cursor_bottom = result.cursor_top + grid.cell_height;
    };
    return result;
}

fn hasBackground(row: []const [4]u8) bool {
    for (row) |cell| if (cell[3] != 0) return true;
    return false;
}

/// Attaches a frame's rows to the layer about to show it. Call on the main thread right before setting the layer's
/// `contents`, so the two always describe the same picture.
pub fn publish(layer: anytype, rows: FrameRows) void {
    const objc = @import("objc");
    const NSData = objc.getClass("NSData") orelse return;
    const NSString = objc.getClass("NSString") orelse return;
    // Most frames don't change the rows: leave the value, so an embedder observing it hears only of changes.
    const key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*:0]const u8, layer_key)});
    const current = layer.msgSend(objc.Object, "valueForKey:", .{key.value});
    if (current.value != null and current.msgSend(c_ulong, "length", .{}) == @sizeOf(FrameRows)) {
        const bytes = current.msgSend(?*const anyopaque, "bytes", .{});
        if (bytes) |b| if (std.mem.eql(u8, @as([*]const u8, @ptrCast(b))[0..@sizeOf(FrameRows)], std.mem.asBytes(&rows))) return;
    }
    const data = NSData.msgSend(objc.Object, "dataWithBytes:length:", .{
        @as(*const anyopaque, @ptrCast(&rows)),
        @as(c_ulong, @sizeOf(FrameRows)),
    });
    layer.msgSend(void, "setValue:forKey:", .{ data.value, key.value });
}

const testing = std.testing;

const TestRow = struct { items: []const u8 };
const TestPlacement = struct { y: i32, cell_offset_y: u32, height: u32 };

const test_grid: Grid = .{ .rows = 4, .columns = 2, .cell_height = 20, .top = 2, .surface_height = 100 };
const blank_bg = [_][4]u8{.{ 0, 0, 0, 0 }} ** 16;

fn testRows(text_rows: []const usize) [10]TestRow {
    var rows = [_]TestRow{.{ .items = "" }} ** 10;
    for (text_rows) |y| rows[y + 1] = .{ .items = "x" };
    return rows;
}

test "frame rows: the layout the embedder reads" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(FrameRows));
    try testing.expectEqual(@as(usize, 0), @offsetOf(FrameRows, "cursor_top"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(FrameRows, "cursor_bottom"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(FrameRows, "content_bottom"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(FrameRows, "version"));
}

test "frame rows: nothing drawn, the cursor alone" {
    const rows = measure(test_grid, &testRows(&.{}), blank_bg[0..8], 1, null);
    try testing.expectEqual(@as(f32, -1), rows.content_bottom);
    try testing.expectEqual(@as(f32, 22), rows.cursor_top);
    try testing.expectEqual(@as(f32, 42), rows.cursor_bottom);
    try testing.expectEqual(FrameRows.current_version, rows.version);
}

test "frame rows: content ends at the lowest row with text or a background" {
    try testing.expectEqual(@as(f32, 22), measure(test_grid, &testRows(&.{0}), blank_bg[0..8], null, null).content_bottom);

    var bg = blank_bg;
    bg[2 * 2 + 1] = .{ 10, 20, 30, 255 };
    const rows = measure(test_grid, &testRows(&.{0}), bg[0..8], null, null);
    try testing.expectEqual(@as(f32, 62), rows.content_bottom);
    try testing.expectEqual(@as(f32, -1), rows.cursor_top);

    // A colour with no opacity draws nothing.
    bg[2 * 2 + 1] = .{ 10, 20, 30, 0 };
    try testing.expectEqual(@as(f32, 22), measure(test_grid, &testRows(&.{0}), bg[0..8], null, null).content_bottom);
}

test "frame rows: a Kitty image reaches below the text" {
    // Row 1 starts at 22; the image runs from 27 to 57.
    const bottom = placementBottom(test_grid, TestPlacement{ .y = 1, .cell_offset_y = 5, .height = 30 });
    try testing.expectEqual(@as(?f32, 57), bottom);
    try testing.expectEqual(@as(f32, 57), measure(test_grid, &testRows(&.{0}), blank_bg[0..8], null, bottom).content_bottom);
    // Text below an image wins.
    try testing.expectEqual(@as(f32, 82), measure(test_grid, &testRows(&.{3}), blank_bg[0..8], null, bottom).content_bottom);
    // An image that ends above the top edge, or starts at or below the bottom edge, isn't in the picture.
    try testing.expectEqual(@as(?f32, null), placementBottom(test_grid, TestPlacement{ .y = -3, .cell_offset_y = 0, .height = 30 }));
    try testing.expectEqual(@as(?f32, null), placementBottom(test_grid, TestPlacement{ .y = 5, .cell_offset_y = 0, .height = 30 }));
    // Nothing reaches below the surface.
    const tall = placementBottom(test_grid, TestPlacement{ .y = 2, .cell_offset_y = 0, .height = 500 });
    try testing.expectEqual(@as(f32, 100), measure(test_grid, &testRows(&.{}), blank_bg[0..8], null, tall).content_bottom);
}

test "frame rows: scrolled by part of a row" {
    // 5 pixels scrolled away; the row revealed below counts like any other.
    var grid = test_grid;
    grid.top = 2 - 5;
    grid.rows = 5;
    var bg = [_][4]u8{.{ 0, 0, 0, 0 }} ** 10;
    bg[4 * 2] = .{ 1, 1, 1, 255 };
    const rows = measure(grid, &testRows(&.{0}), &bg, 0, null);
    try testing.expectEqual(@as(f32, 97), rows.content_bottom);
    try testing.expectEqual(@as(f32, -3), rows.cursor_top);
}

test "frame rows: only the rows drawn count" {
    var grid = test_grid;
    grid.rows = 3;
    const rows = measure(grid, &testRows(&.{ 0, 3 }), blank_bg[0..8], 3, null);
    try testing.expectEqual(@as(f32, 22), rows.content_bottom);
    try testing.expectEqual(@as(f32, -1), rows.cursor_top);
}

test "frame rows: rows that start below a shorter surface don't count" {
    // Eight rows drawn into a surface that ends inside row 2, as while a resize shortens it before the cells follow.
    var grid = test_grid;
    grid.rows = 8;
    grid.surface_height = 60;
    try testing.expectEqual(@as(f32, -1), measure(grid, &testRows(&.{7}), &blank_bg, 7, null).content_bottom);
    try testing.expectEqual(@as(f32, -1), measure(grid, &testRows(&.{7}), &blank_bg, 7, null).cursor_top);
    // Row 2 starts at 42, inside the surface, and is cut at its bottom edge.
    const rows = measure(grid, &testRows(&.{ 2, 7 }), &blank_bg, 2, null);
    try testing.expectEqual(@as(f32, 60), rows.content_bottom);
    try testing.expectEqual(@as(f32, 42), rows.cursor_top);
}

test "frame rows: the cursor is noted only while the terminal shows it, through its blink" {
    const terminal = @import("../terminal/main.zig");
    const alloc = testing.allocator;
    var term: terminal.Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.setCursorPos(4, 3);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);

    try state.update(alloc, &term);
    try testing.expectEqual(@as(?usize, 3), Cursor.of(&state, false).row);

    term.modes.set(.cursor_blinking, true);
    try state.update(alloc, &term);
    try testing.expectEqual(@as(?usize, 3), Cursor.of(&state, false).row);

    term.modes.set(.cursor_visible, false);
    try state.update(alloc, &term);
    try testing.expectEqual(@as(?usize, null), Cursor.of(&state, false).row);
}
