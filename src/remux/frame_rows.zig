//! Where the cursor is and how far down a frame's content reaches, published with the frame itself so an embedder
//! lays out around the picture actually on screen rather than the terminal's newer state. Remux slides a terminal
//! that an on-screen keyboard partly covers just far enough to keep the cursor and what is drawn below it in view.
//!
//! The renderer measures each frame from the cells it is about to draw, under its draw lock, and the frame's target
//! carries the result to the layer, which sets it in the same main-thread step that sets the layer's `contents`.
const std = @import("std");

/// One frame's rows in surface pixels from the surface's top edge, padding included; a row scrolled partly off the
/// top starts above 0. -1 means none: no cursor in view (both cursor values), or nothing drawn. The layout is part of
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

/// The drawn grid a frame's rows are measured against.
pub const Grid = struct {
    /// Rows drawn, including the row revealed below while scrolled by part of a row.
    rows: usize,
    columns: usize,
    cell_height: f32,
    /// Where row 0 starts: the top padding, less any part of a row scrolled away.
    top: f32,
    /// Nothing is drawn below the surface's bottom edge.
    surface_height: f32,
};

/// Measures the frame a renderer is about to draw. Call with the renderer's draw lock held, after its cells were
/// rebuilt for the frame.
pub fn ofRenderer(renderer: anytype) FrameRows {
    const cell_height: f32 = @floatFromInt(renderer.size.cell.height);
    const padding_top: f32 = @floatFromInt(renderer.size.padding.top);
    const cells = &renderer.cells;
    return measure(
        .{
            .rows = @min(renderer.render_rows, cells.size.rows),
            .columns = cells.size.columns,
            .cell_height = cell_height,
            .top = padding_top - renderer.uniforms.scroll_cell_offset * cell_height,
            .surface_height = @floatFromInt(renderer.size.screen.height),
        },
        cells.fg_rows,
        cells.activeBackgroundCells(),
        if (renderer.terminal_state.cursor.viewport) |vp| vp.y else null,
        renderer.images.kitty_placements.items,
    );
}

/// A row holds content when it has any foreground cell (a glyph, underline, strikethrough or overline) or any
/// background that isn't fully transparent; a Kitty image holds content down to its bottom edge.
///
/// `fg_rows[y + 1]` holds row y's foreground cells (index 0 is the cursor's list). `bg_cells` holds the grid's
/// backgrounds row by row as RGBA. Each placement has `y` (its grid row, negative when it starts above the top),
/// `cell_offset_y` and `height` in pixels.
pub fn measure(
    grid: Grid,
    fg_rows: anytype,
    bg_cells: []const [4]u8,
    cursor_row: ?usize,
    placements: anytype,
) FrameRows {
    var result: FrameRows = .{ .version = FrameRows.current_version };

    var lowest: f32 = -1;
    var y = @min(grid.rows, fg_rows.len -| 1, if (grid.columns == 0) 0 else bg_cells.len / grid.columns);
    while (y > 0) {
        y -= 1;
        if (fg_rows[y + 1].items.len > 0 or hasBackground(bg_cells[y * grid.columns ..][0..grid.columns])) {
            lowest = grid.top + @as(f32, @floatFromInt(y + 1)) * grid.cell_height;
            break;
        }
    }
    for (placements) |p| {
        const top = grid.top + @as(f32, @floatFromInt(p.y)) * grid.cell_height +
            @as(f32, @floatFromInt(p.cell_offset_y));
        const bottom = top + @as(f32, @floatFromInt(p.height));
        if (bottom > 0) lowest = @max(lowest, bottom);
    }
    if (lowest > 0) result.content_bottom = @min(lowest, grid.surface_height);

    if (cursor_row) |row| if (row < grid.rows) {
        result.cursor_top = grid.top + @as(f32, @floatFromInt(row)) * grid.cell_height;
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
    const data = NSData.msgSend(objc.Object, "dataWithBytes:length:", .{
        @as(*const anyopaque, @ptrCast(&rows)),
        @as(c_ulong, @sizeOf(FrameRows)),
    });
    const key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*:0]const u8, layer_key)});
    layer.msgSend(void, "setValue:forKey:", .{ data.value, key.value });
}

const testing = std.testing;

const TestRow = struct { items: []const u8 };
const TestPlacement = struct { y: i32, cell_offset_y: u32, height: u32 };
const no_placements: []const TestPlacement = &.{};

const test_grid: Grid = .{ .rows = 4, .columns = 2, .cell_height = 20, .top = 2, .surface_height = 100 };
const blank_bg = [_][4]u8{.{ 0, 0, 0, 0 }} ** 8;

fn testRows(text_rows: []const usize) [6]TestRow {
    var rows = [_]TestRow{.{ .items = "" }} ** 6;
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
    const rows = measure(test_grid, &testRows(&.{}), &blank_bg, 1, no_placements);
    try testing.expectEqual(@as(f32, -1), rows.content_bottom);
    try testing.expectEqual(@as(f32, 22), rows.cursor_top);
    try testing.expectEqual(@as(f32, 42), rows.cursor_bottom);
    try testing.expectEqual(FrameRows.current_version, rows.version);
}

test "frame rows: content ends at the lowest row with text or a background" {
    try testing.expectEqual(@as(f32, 22), measure(test_grid, &testRows(&.{0}), &blank_bg, null, no_placements).content_bottom);

    var bg = blank_bg;
    bg[2 * 2 + 1] = .{ 10, 20, 30, 255 };
    const rows = measure(test_grid, &testRows(&.{0}), &bg, null, no_placements);
    try testing.expectEqual(@as(f32, 62), rows.content_bottom);
    try testing.expectEqual(@as(f32, -1), rows.cursor_top);

    // A colour with no opacity draws nothing.
    bg[2 * 2 + 1] = .{ 10, 20, 30, 0 };
    try testing.expectEqual(@as(f32, 22), measure(test_grid, &testRows(&.{0}), &bg, null, no_placements).content_bottom);
}

test "frame rows: a Kitty image reaches below the text" {
    const placements = [_]TestPlacement{.{ .y = 1, .cell_offset_y = 5, .height = 30 }};
    // Row 1 starts at 22; the image runs from 27 to 57.
    try testing.expectEqual(@as(f32, 57), measure(test_grid, &testRows(&.{0}), &blank_bg, null, &placements).content_bottom);
    // An image above the top edge draws nothing; text below an image wins.
    const above = [_]TestPlacement{.{ .y = -3, .cell_offset_y = 0, .height = 30 }};
    try testing.expectEqual(@as(f32, -1), measure(test_grid, &testRows(&.{}), &blank_bg, null, &above).content_bottom);
    try testing.expectEqual(@as(f32, 82), measure(test_grid, &testRows(&.{3}), &blank_bg, null, &placements).content_bottom);
    // Nothing reaches below the surface.
    const tall = [_]TestPlacement{.{ .y = 2, .cell_offset_y = 0, .height = 500 }};
    try testing.expectEqual(@as(f32, 100), measure(test_grid, &testRows(&.{}), &blank_bg, null, &tall).content_bottom);
}

test "frame rows: scrolled by part of a row" {
    // 5 pixels scrolled away; the row revealed below counts like any other.
    var grid = test_grid;
    grid.top = 2 - 5;
    grid.rows = 5;
    var bg = [_][4]u8{.{ 0, 0, 0, 0 }} ** 10;
    bg[4 * 2] = .{ 1, 1, 1, 255 };
    const rows = measure(grid, &testRows(&.{0}), &bg, 0, no_placements);
    try testing.expectEqual(@as(f32, 97), rows.content_bottom);
    try testing.expectEqual(@as(f32, -3), rows.cursor_top);
}

test "frame rows: only the rows drawn count" {
    var grid = test_grid;
    grid.rows = 3;
    const rows = measure(grid, &testRows(&.{ 0, 3 }), &blank_bg, 3, no_placements);
    try testing.expectEqual(@as(f32, 22), rows.content_bottom);
    try testing.expectEqual(@as(f32, -1), rows.cursor_top);
}
