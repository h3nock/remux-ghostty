//! Which rows of a rendered frame hold anything, and where the cursor is, published with the frame so an
//! embedder can lay out around the picture actually on screen (Remux slides a terminal partly covered by an
//! on-screen keyboard just far enough to keep the cursor and what is drawn below it in view).
//!
//! The renderer notes each row as it rebuilds it: a row holds something when it has any foreground cell (a glyph,
//! underline, strikethrough or overline) or a background that isn't fully transparent. Rows it doesn't rebuild keep
//! their note, so the cost is one check per rebuilt row, outside the terminal's lock. At draw time the notes become a
//! `FrameRows` in surface pixels, which travels with the frame's target to the layer that shows it.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The cursor's row and the lowest row holding anything in one frame, in surface pixels from the surface's top
/// edge, padding included. A value of -1 means none: no cursor in view, or no row with anything in it.
pub const FrameRows = extern struct {
    cursor_top: f32 = -1,
    cursor_bottom: f32 = -1,
    content_bottom: f32 = -1,
    /// Counts the frames the renderer prepared; 0 before the first.
    serial: u32 = 0,
};

/// The renderer's per-row notes between frames.
pub const Tracker = struct {
    rows: std.DynamicBitSetUnmanaged = .{},
    cursor_row: ?usize = null,
    serial: u32 = 0,

    pub fn deinit(self: *Tracker, alloc: Allocator) void {
        self.rows.deinit(alloc);
    }

    /// Matches the notes to a new row count; every row starts empty until it is rebuilt.
    pub fn resize(self: *Tracker, alloc: Allocator, row_count: usize) Allocator.Error!void {
        try self.rows.resize(alloc, row_count, false);
        self.rows.unsetAll();
    }

    /// Notes row `y` right after the renderer rebuilt or cleared it, from its foreground cell list and its
    /// background cells.
    pub fn noteRow(self: *Tracker, y: usize, fg_cell_count: usize, bg_cells: []const [4]u8) void {
        if (y >= self.rows.bit_length) return;
        const filled = fg_cell_count > 0 or for (bg_cells) |cell| {
            if (cell[3] != 0) break true;
        } else false;
        self.rows.setValue(y, filled);
    }

    /// The frame's rows for the first `row_count` rows, with rows `cell_height` pixels tall starting
    /// `padding_top - scroll_offset` pixels below the surface's top edge.
    pub fn frame(
        self: *Tracker,
        row_count: usize,
        cell_height: f32,
        padding_top: f32,
        scroll_offset: f32,
    ) FrameRows {
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        const top = padding_top - scroll_offset;
        var result: FrameRows = .{ .serial = self.serial };
        var y = @min(row_count, self.rows.bit_length);
        while (y > 0) {
            y -= 1;
            if (self.rows.isSet(y)) {
                result.content_bottom = top + @as(f32, @floatFromInt(y + 1)) * cell_height;
                break;
            }
        }
        if (self.cursor_row) |row| if (row < row_count) {
            result.cursor_top = top + @as(f32, @floatFromInt(row)) * cell_height;
            result.cursor_bottom = result.cursor_top + cell_height;
        };
        return result;
    }
};

test "frame rows follow the rows noted and the cursor" {
    const testing = std.testing;
    var tracker: Tracker = .{};
    defer tracker.deinit(testing.allocator);
    try tracker.resize(testing.allocator, 4);
    const blank = [_][4]u8{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
    const filled = [_][4]u8{ .{ 0, 0, 0, 0 }, .{ 10, 20, 30, 255 } };

    // Nothing noted: no content; the cursor alone.
    tracker.cursor_row = 1;
    var rows = tracker.frame(4, 20, 2, 0);
    try testing.expectEqual(@as(f32, -1), rows.content_bottom);
    try testing.expectEqual(@as(f32, 22), rows.cursor_top);
    try testing.expectEqual(@as(f32, 42), rows.cursor_bottom);
    try testing.expectEqual(@as(u32, 1), rows.serial);

    // Text on row 0, a background on row 2: the content ends at the bottom of row 2.
    tracker.noteRow(0, 3, &blank);
    tracker.noteRow(2, 0, &filled);
    rows = tracker.frame(4, 20, 2, 0);
    try testing.expectEqual(@as(f32, 62), rows.content_bottom);

    // Row 2 rebuilt blank: the content ends at row 0 again; untouched row 0 keeps its note.
    tracker.noteRow(2, 0, &blank);
    rows = tracker.frame(4, 20, 2, 0);
    try testing.expectEqual(@as(f32, 22), rows.content_bottom);

    // A fractional scroll offset moves everything up; a cursor out of view is none.
    tracker.cursor_row = null;
    rows = tracker.frame(4, 20, 2, 5);
    try testing.expectEqual(@as(f32, 17), rows.content_bottom);
    try testing.expectEqual(@as(f32, -1), rows.cursor_top);

    // Only the rows shown count, and a resize forgets every note.
    tracker.noteRow(3, 1, &blank);
    try testing.expectEqual(@as(f32, 22), tracker.frame(3, 20, 2, 0).content_bottom);
    try tracker.resize(testing.allocator, 5);
    try testing.expectEqual(@as(f32, -1), tracker.frame(5, 20, 2, 0).content_bottom);
}
