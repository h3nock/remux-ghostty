//! Where a backend sizes the terminal's grid, as tmux does for a pane's mirror, the embedder resizes the drawable only
//! after it hears that the terminal changed. Until then the drawable holds another grid than the cells, and a frame
//! drawn then would show a shorter grid with blank space under it, or a taller one cut off at the bottom. A renderer
//! created with `renderer.Options.backend_sized_grid` keeps its last frame instead, as during a synchronized-output
//! block, and these are its rules.
const std = @import("std");
const size = @import("../renderer/size.zig");

/// Whether a drawable of `screen` pixels holds `grid` with this padding and cell size. A drawable's pixels are its
/// bounds in points times its scale, truncated, so one laid out for the grid in points can come out a pixel short of
/// the grid's exact size; it still holds the grid. An empty grid, before any cells are built, never fits.
pub fn drawableHolds(
    screen: size.ScreenSize,
    padding: size.Padding,
    cell: size.CellSize,
    grid: size.GridSize,
) bool {
    const drawable: size.Size = .{
        .screen = .{ .width = screen.width + 1, .height = screen.height + 1 },
        .padding = padding,
        .cell = cell,
    };
    return grid.equals(drawable.grid());
}

/// Whether a synchronized-output block can keep the last frame. A frame shows only cells built for the drawable's
/// grid, so there is none to keep before the first build, or for a requested frame while the drawable holds another
/// grid; the cells are then built as the terminal is, even inside a block. `api.surfaceSize()` gives the drawable's
/// size and is read only when the answer depends on it.
pub fn syncKeepsFrame(
    api: anytype,
    requested: bool,
    cells_grid: size.GridSize,
    padding: size.Padding,
    cell: size.CellSize,
) bool {
    if (cells_grid.equals(.{})) return false;
    if (!requested) return true;
    const surface = api.surfaceSize() catch return true;
    return drawableHolds(.{ .width = surface.width, .height = surface.height }, padding, cell, cells_grid);
}

// 24x53 px cells, as a tmux pane's mirror shrinking from 41 rows to 25.
const test_cell: size.CellSize = .{ .width = 24, .height = 53 };
const tall: size.ScreenSize = .{ .width = 1200, .height = 2173 };
const short: size.ScreenSize = .{ .width = 1200, .height = 1325 };
const grid_41: size.GridSize = .{ .columns = 50, .rows = 41 };
const grid_25: size.GridSize = .{ .columns = 50, .rows = 25 };

test "a drawable holds the grid it was sized for" {
    try std.testing.expect(drawableHolds(tall, .{}, test_cell, grid_41));
    try std.testing.expect(!drawableHolds(tall, .{}, test_cell, grid_25));
    try std.testing.expect(drawableHolds(short, .{}, test_cell, grid_25));
    try std.testing.expect(!drawableHolds(short, .{}, test_cell, grid_41));
    try std.testing.expect(!drawableHolds(short, .{}, test_cell, .{ .columns = 49, .rows = 25 }));

    // Laid out in points at 3x: 41 rows of 44 px cells come out at 1803 px, not 1804.
    const cell_44: size.CellSize = .{ .width = 22, .height = 44 };
    try std.testing.expect(drawableHolds(.{ .width = 1100, .height = 1803 }, .{}, cell_44, grid_41));
    try std.testing.expect(drawableHolds(.{ .width = 1100, .height = 1804 }, .{}, cell_44, grid_41));
    try std.testing.expect(!drawableHolds(.{ .width = 1100, .height = 1803 }, .{}, cell_44, .{ .columns = 50, .rows = 40 }));
    try std.testing.expect(!drawableHolds(.{ .width = 1100, .height = 1847 }, .{}, cell_44, grid_41));

    // Before any cells are built.
    try std.testing.expect(!drawableHolds(tall, .{}, test_cell, .{}));
}

const TestApi = struct {
    screen: ?size.ScreenSize,
    reads: usize = 0,

    fn surfaceSize(self: *TestApi) !struct { width: u32, height: u32 } {
        self.reads += 1;
        const screen = self.screen orelse return error.NoSurface;
        return .{ .width = screen.width, .height = screen.height };
    }
};

test "a synchronized-output block keeps a frame the drawable can show" {
    // Built cells, no request: the block keeps them without asking the drawable.
    var api: TestApi = .{ .screen = short };
    try std.testing.expect(syncKeepsFrame(&api, false, grid_41, .{}, test_cell));
    try std.testing.expectEqual(0, api.reads);

    // A request whose cells still fit keeps them.
    try std.testing.expect(syncKeepsFrame(&api, true, grid_25, .{}, test_cell));

    // A request while the drawable holds another grid builds through the block.
    try std.testing.expect(!syncKeepsFrame(&api, true, grid_41, .{}, test_cell));

    // Before the first build there is no frame to keep, requested or not, whatever the drawable.
    var none: TestApi = .{ .screen = null };
    try std.testing.expect(!syncKeepsFrame(&none, false, .{}, .{}, test_cell));
    try std.testing.expect(!syncKeepsFrame(&none, true, .{}, .{}, test_cell));
    try std.testing.expectEqual(0, none.reads);

    // Without a drawable size the block keeps what it has.
    try std.testing.expect(syncKeepsFrame(&none, true, grid_41, .{}, test_cell));
}
