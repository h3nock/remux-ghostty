//! tmux's height-resize rules for a pane's mirror terminal.
//!
//! A resize Remux sends runs between two `list-panes` samples in one tmux
//! command line, and tmux parses no pane output between them. The samples
//! therefore bracket exactly tmux's own resize. From them and the mirror's
//! cursor, `plan` derives the rows tmux deleted below the cursor, pushed into
//! history and pulled back, and `apply` repeats those moves on the mirror.
//! Anything that can't be reproduced exactly returns null so the caller
//! recaptures the pane from tmux instead.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Terminal = @import("../../terminal/Terminal.zig");
const Selection = @import("../../terminal/Selection.zig");
const size = @import("../../terminal/size.zig");
const Layout = @import("../../terminal/tmux/layout.zig").Layout;

/// One pane as tmux reports it immediately before or after a resize.
pub const Sample = struct {
    pane_id: usize,
    width: usize,
    height: usize,
    cursor_x: usize,
    cursor_y: usize,
    history: usize,
    alternate: bool,

    /// The window's layout ignoring zoom, and the layout actually shown
    /// while it's zoomed. Either may be empty when tmux didn't print it for
    /// this pane; the zoomed pane always has both.
    layout: []const u8,
    visible_layout: []const u8,
};

pub const Move = struct {
    rows: size.CellCountInt,
    delete_below: size.CellCountInt,
    pull: size.CellCountInt,
};

pub const Plan = struct {
    cols: size.CellCountInt,
    moves: [max_steps]Move = undefined,
    len: usize = 0,

    pub fn slice(self: *const Plan) []const Move {
        return self.moves[0..self.len];
    }

    /// Rows that come back from history across the whole plan.
    pub fn pulled(self: *const Plan) usize {
        var total: usize = 0;
        for (self.slice()) |move| total += move.pull;
        return total;
    }
};

/// tmux resizes a pane once. In a zoomed window it resizes the zoomed pane
/// three times: back to its layout cell, through the layout resize, and to
/// the full window again. It does this even when the window keeps its size.
const max_steps = 3;

const Size = struct {
    cols: usize,
    rows: usize,
};

/// Derive tmux's row moves for one pane. Returns null when tmux's result
/// can't be reproduced by height-only moves: a width change at any step, a
/// change of zoom, or samples that no sequence of moves explains.
pub fn plan(
    alloc: Allocator,
    before: Sample,
    after: Sample,
) Allocator.Error!?Plan {
    assert(before.pane_id == after.pane_id);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var steps_storage: [max_steps]Size = undefined;
    const steps = try resizeSteps(arena.allocator(), before, after, &steps_storage) orelse
        return null;

    for (steps) |step| if (step.cols != before.width) return null;
    if (after.cursor_x != before.cursor_x) return null;
    if (after.alternate != before.alternate) return null;
    const cols = std.math.cast(size.CellCountInt, before.width) orelse return null;

    // tmux pulls rows back while its hidden scrolled-row counter allows,
    // and the count is not reported. Every counter value that reproduces
    // the after sample gives the same moves, because each pull only grows
    // with the counter, so the first match is the answer.
    var counter: usize = 0;
    while (counter <= before.history) : (counter += 1) {
        if (simulate(before, after, cols, steps, counter)) |result| return result;
    }
    return null;
}

fn simulate(
    before: Sample,
    after: Sample,
    cols: size.CellCountInt,
    steps: []const Size,
    initial_counter: usize,
) ?Plan {
    var result: Plan = .{ .cols = cols };
    var rows = before.height;
    var cursor_y = before.cursor_y;
    var history = before.history;
    var counter = initial_counter;
    if (cursor_y >= rows) return null;

    for (steps) |step| {
        if (step.rows == rows) continue;
        const new_rows = std.math.cast(size.CellCountInt, step.rows) orelse return null;
        var move: Move = .{ .rows = new_rows, .delete_below = 0, .pull = 0 };
        if (step.rows < rows) {
            // Delete rows below the cursor first, then move rows from the
            // top into history (or delete them, without history).
            const needed = rows - step.rows;
            const below = rows - 1 - cursor_y;
            const deleted = @min(needed, below);
            const rest = needed - deleted;
            move.delete_below = @intCast(deleted);
            if (!before.alternate) {
                history += rest;
                counter += rest;
            }
            cursor_y -= rest;
        } else {
            const needed = step.rows - rows;
            const pulled = if (before.alternate) 0 else @min(needed, counter);
            move.pull = @intCast(pulled);
            counter -= pulled;
            history -= pulled;
            cursor_y += pulled;
        }
        rows = step.rows;
        result.moves[result.len] = move;
        result.len += 1;
    }

    if (rows != after.height or
        cursor_y != after.cursor_y or
        history != after.history) return null;
    return result;
}

/// The sizes tmux gives the pane during this resize, in order.
fn resizeSteps(
    alloc: Allocator,
    before: Sample,
    after: Sample,
    storage: *[max_steps]Size,
) Allocator.Error!?[]const Size {
    const zoomed_before = zoomedPane(alloc, before) catch return null;
    const zoomed_after = zoomedPane(alloc, after) catch return null;
    if (zoomed_before != zoomed_after) return null;

    if (zoomed_before != before.pane_id) {
        storage[0] = .{ .cols = after.width, .rows = after.height };
        return storage[0..1];
    }

    const cell_before = cellSize(alloc, before.layout, before.pane_id) catch return null;
    const cell_after = cellSize(alloc, after.layout, after.pane_id) catch return null;
    storage[0] = cell_before orelse return null;
    storage[1] = cell_after orelse return null;
    storage[2] = .{ .cols = after.width, .rows = after.height };
    return storage[0..3];
}

/// The zoomed pane's ID, or null when the window isn't zoomed.
fn zoomedPane(alloc: Allocator, sample: Sample) !?usize {
    if (sample.visible_layout.len == 0 or std.mem.eql(u8, sample.layout, sample.visible_layout)) return null;
    const visible = try Layout.parseWithChecksum(alloc, sample.visible_layout);
    return switch (visible.content) {
        .pane => |id| id,
        .horizontal, .vertical => error.InvalidVisibleLayout,
    };
}

fn cellSize(alloc: Allocator, layout_str: []const u8, pane_id: usize) !?Size {
    const layout = try Layout.parseWithChecksum(alloc, layout_str);
    return findCell(layout, pane_id);
}

fn findCell(layout: Layout, pane_id: usize) ?Size {
    return switch (layout.content) {
        .pane => |id| if (id == pane_id)
            .{ .cols = layout.width, .rows = layout.height }
        else
            null,
        .horizontal, .vertical => |children| for (children) |child| {
            if (findCell(child, pane_id)) |found| break found;
        } else null,
    };
}

/// tmux reports a cursor waiting to wrap at the right edge as
/// `cursor_x == width`; Ghostty keeps it on the last column with a pending
/// wrap.
pub fn cursorMatches(t: *const Terminal, x: usize, y: usize) bool {
    const cursor = t.screens.active.cursor;
    if (cursor.y != y) return false;
    if (x == t.cols) return cursor.x + 1 == t.cols and cursor.pending_wrap;
    return cursor.x == x and !cursor.pending_wrap;
}

/// Rows of history the mirror holds on its active screen.
pub fn localHistory(t: *const Terminal) usize {
    const pages = &t.screens.active.pages;
    return pages.total_rows - pages.rows;
}

/// Whether the mirror can repeat the plan: its history must hold every row
/// tmux pulled back.
pub fn canApply(t: *const Terminal, p: *const Plan) bool {
    var history = localHistory(t);
    var rows: usize = t.rows;
    for (p.slice()) |move| {
        if (move.rows < rows) {
            const pushed = rows - move.rows - move.delete_below;
            if (!t.screens.active.no_scrollback) history += pushed;
        } else {
            if (move.pull > history) return false;
            history -= move.pull;
        }
        rows = move.rows;
    }
    return true;
}

/// Repeat the plan's moves with Ghostty's own resize, set up so it moves the
/// same rows as tmux. Returns false when it couldn't, and the pane must be
/// recaptured.
pub fn apply(alloc: Allocator, t: *Terminal, p: *const Plan) Terminal.ResizeError!bool {
    const screen = t.screens.active;

    // tmux keeps the saved cursor's coordinates through a resize, while
    // Ghostty moves it with its row. tmux also never clears a prompt for
    // the shell to redraw; the shell's redraw reaches both as output.
    const saved_cursor = screen.saved_cursor;
    const redraw = t.flags.shell_redraws_prompt;
    const pull_scrollback = t.flags.resize_pull_scrollback;
    screen.saved_cursor = null;
    t.flags.shell_redraws_prompt = .false;
    defer {
        screen.saved_cursor = saved_cursor;
        t.flags.shell_redraws_prompt = redraw;
        t.flags.resize_pull_scrollback = pull_scrollback;
    }

    for (p.slice()) |move| {
        if (move.rows < t.rows) {
            if (!try applyShrink(alloc, t, p.cols, move)) return false;
        } else {
            try applyGrow(alloc, t, p.cols, move);
        }
    }
    return true;
}

/// tmux deletes the rows below the cursor whatever they hold, and Ghostty's
/// shrink trims trailing rows without text, so the deleted rows are cleared
/// first. The rest of the shrink moves rows from the top into history in
/// both.
fn applyShrink(
    alloc: Allocator,
    t: *Terminal,
    cols: size.CellCountInt,
    move: Move,
) Terminal.ResizeError!bool {
    const screen = t.screens.active;
    if (move.delete_below > 0) {
        assert(move.delete_below < t.rows - screen.cursor.y);
        const top = t.rows - move.delete_below;
        screen.clearRows(.{ .active = .{ .y = top } }, null, false);

        // The row above no longer continues onto a deleted row.
        const above = screen.pages.pin(.{ .active = .{ .y = top - 1 } }).?;
        above.rowAndCell().row.wrap = false;
    }

    const total = screen.pages.total_rows;
    try t.resize(alloc, .{ .cols = cols, .rows = move.rows });

    // Ghostty doesn't trim a row that holds a tracked pin, such as a
    // selection's end.
    return screen.pages.total_rows == total - move.delete_below;
}

/// Ghostty brings history back only when the cursor is on the last row, and
/// then as many rows as the screen grows. tmux brings back `move.pull` rows
/// wherever the cursor is, then adds blank rows.
fn applyGrow(
    alloc: Allocator,
    t: *Terminal,
    cols: size.CellCountInt,
    move: Move,
) Terminal.ResizeError!void {
    const screen = t.screens.active;
    if (move.pull > 0) {
        const cursor = screen.cursor;
        screen.cursorAbsolute(cursor.x, t.rows - 1);
        t.flags.resize_pull_scrollback = true;
        try t.resize(alloc, .{ .cols = cols, .rows = t.rows + move.pull });
        screen.cursorAbsolute(cursor.x, cursor.y + move.pull);
        screen.cursor.pending_wrap = cursor.pending_wrap;
    }
    if (move.rows > t.rows) {
        t.flags.resize_pull_scrollback = false;
        try t.resize(alloc, .{ .cols = cols, .rows = move.rows });
    }
}

const assert = std.debug.assert;

fn testSample(height: usize, cursor_y: usize, history: usize) Sample {
    return .{
        .pane_id = 0,
        .width = 20,
        .height = height,
        .cursor_x = 0,
        .cursor_y = cursor_y,
        .history = history,
        .alternate = false,
        .layout = "9edd,20x10,0,0,0",
        .visible_layout = "9edd,20x10,0,0,0",
    };
}

test "plan: a sample tmux printed without layouts is a single step" {
    var before = testSample(10, 5, 0);
    var after = testSample(6, 5, 0);
    for ([_]*Sample{ &before, &after }) |sample| {
        sample.layout = "";
        sample.visible_layout = "";
    }
    const p = (try plan(testing.allocator, before, after)).?;
    try testing.expectEqual(1, p.len);
    try testing.expectEqual(4, p.moves[0].delete_below);
}

test "plan: shrink deletes rows below the cursor before pushing" {
    // tmux 3.5a: cursor on row 5 of 10, shrink to 6 deletes the four rows
    // below it and keeps history at 0.
    const p = (try plan(testing.allocator, testSample(10, 5, 0), testSample(6, 5, 0))).?;
    try testing.expectEqual(1, p.len);
    try testing.expectEqual(Move{ .rows = 6, .delete_below = 4, .pull = 0 }, p.moves[0]);
}

test "plan: grow pulls back exactly what tmux pulled" {
    // tmux 3.5a: history 2 at 4 rows, grow to 10 pulls both rows back.
    const p = (try plan(testing.allocator, testSample(4, 3, 2), testSample(10, 5, 0))).?;
    try testing.expectEqual(Move{ .rows = 10, .delete_below = 0, .pull = 2 }, p.moves[0]);
}

test "plan: grow with history tmux can't pull back" {
    // History 3 that was cleared into history (counter 0): nothing comes back.
    const p = (try plan(testing.allocator, testSample(5, 0, 3), testSample(7, 0, 3))).?;
    try testing.expectEqual(Move{ .rows = 7, .delete_below = 0, .pull = 0 }, p.moves[0]);
}

test "plan: inconsistent samples recapture" {
    try testing.expect(try plan(testing.allocator, testSample(10, 5, 0), testSample(6, 5, 3)) == null);
}

test "plan: width change recaptures" {
    var after = testSample(10, 5, 0);
    after.width = 10;
    try testing.expect(try plan(testing.allocator, testSample(10, 5, 0), after) == null);
}

test "plan: zoomed pane replays unzoom, resize and rezoom" {
    // Pane 0 zoomed over pane 1 in a 20x10 window split top/bottom
    // (0 is 20x6). A same-size refresh unzooms to 6 rows, deleting the four
    // rows below a cursor on row 1, then rezooms to 10 with blank rows.
    var before = testSample(10, 1, 0);
    before.layout = "9762,20x10,0,0[20x6,0,0,0,20x3,0,7,1]";
    before.visible_layout = "9edd,20x10,0,0,0";
    const after = before;
    const p = (try plan(testing.allocator, before, after)).?;
    try testing.expectEqual(2, p.len);
    try testing.expectEqual(Move{ .rows = 6, .delete_below = 4, .pull = 0 }, p.moves[0]);
    try testing.expectEqual(Move{ .rows = 10, .delete_below = 0, .pull = 0 }, p.moves[1]);
}

test "plan: zoomed side-by-side pane changes width and recaptures" {
    var before = testSample(10, 1, 0);
    before.layout = "f436,20x10,0,0{10x10,0,0,0,9x10,11,0,1}";
    before.visible_layout = "9edd,20x10,0,0,0";
    try testing.expect(try plan(testing.allocator, before, before) == null);
}

fn testTerminal(rows: size.CellCountInt, bytes: []const u8) !Terminal {
    var t: Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 20,
        .rows = rows,
        .max_scrollback_bytes = 1_000_000,
    });
    errdefer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    return t;
}

fn expectDump(t: *Terminal, history: []const u8, active: []const u8) !void {
    const screen = t.screens.active;
    if (history.len == 0) {
        try testing.expectEqual(0, localHistory(t));
    } else {
        const dump = try screen.dumpStringAlloc(testing.allocator, .{ .history = .{} });
        defer testing.allocator.free(dump);
        try testing.expectEqualStrings(history, dump);
    }
    const dump = try screen.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(dump);
    try testing.expectEqualStrings(active, dump);
}

test "apply: footer below the cursor matches tmux across shrink and grow" {
    // L0..L4 on rows 0-4, F6..F9 on rows 6-9, cursor on row 5. The expected
    // rows are what tmux 3.5a shows for the same bytes and sizes.
    var t = try testTerminal(10, "L0\r\nL1\r\nL2\r\nL3\r\nL4\x1b[7;1HF6\r\nF7\r\nF8\r\nF9\x1b[6;1H");
    defer t.deinit(testing.allocator);

    const shrink = (try plan(testing.allocator, testSample(10, 5, 0), testSample(6, 5, 0))).?;
    try testing.expect(canApply(&t, &shrink));
    try testing.expect(try apply(testing.allocator, &t, &shrink));
    try expectDump(&t, "", "L0\nL1\nL2\nL3\nL4");
    try testing.expect(cursorMatches(&t, 0, 5));

    const shrink_more = (try plan(testing.allocator, testSample(6, 5, 0), testSample(4, 3, 2))).?;
    try testing.expect(try apply(testing.allocator, &t, &shrink_more));
    try expectDump(&t, "L0\nL1", "L2\nL3\nL4");
    try testing.expect(cursorMatches(&t, 0, 3));

    const grow = (try plan(testing.allocator, testSample(4, 3, 2), testSample(10, 5, 0))).?;
    try testing.expect(canApply(&t, &grow));
    try testing.expect(try apply(testing.allocator, &t, &grow));
    try expectDump(&t, "", "L0\nL1\nL2\nL3\nL4");
    try testing.expect(cursorMatches(&t, 0, 5));
}

test "apply: pending wrap cursor and saved cursor survive a shrink" {
    var t = try testTerminal(10, "\x1b[9;6H\x1b7\x1b[1;1H" ++ "X" ** 20);
    defer t.deinit(testing.allocator);
    try testing.expect(cursorMatches(&t, 20, 0));

    var before = testSample(10, 0, 0);
    before.cursor_x = 20;
    var after = testSample(5, 0, 0);
    after.cursor_x = 20;
    const p = (try plan(testing.allocator, before, after)).?;
    try testing.expect(try apply(testing.allocator, &t, &p));
    try testing.expectEqual(0, localHistory(&t));
    try testing.expect(cursorMatches(&t, 20, 0));

    // The saved cursor keeps its coordinates and is clamped on restore,
    // as tmux does.
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b8");
    try testing.expect(cursorMatches(&t, 5, 4));
}

test "region scrolls below the top row are counted, top-row regions aren't" {
    var t = try testTerminal(6, "");
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();

    // Line feeds at the bottom of a region starting on row 3.
    stream.nextSlice("\x1b[3;6r\x1b[6;1Ha\r\nb\r\nc");
    try testing.expectEqual(2, t.region_rows_scrolled_out);

    // Scroll up (CSI S) in the same region.
    stream.nextSlice("\x1b[3S");
    try testing.expectEqual(5, t.region_rows_scrolled_out);

    // A region from the top row scrolls into scrollback as tmux does.
    stream.nextSlice("\x1b[1;4r\x1b[4;1Hd\r\ne\x1b[2S");
    try testing.expectEqual(5, t.region_rows_scrolled_out);
}

test "apply: a selection on a deleted row needs a recapture" {
    var t = try testTerminal(10, "L0\x1b[9;1HF8\x1b[2;1H");
    defer t.deinit(testing.allocator);
    const screen = t.screens.active;
    const pin = screen.pages.pin(.{ .active = .{ .y = 9 } }).?;
    try screen.select(Selection.init(pin, pin, false));

    const p = (try plan(testing.allocator, testSample(10, 1, 0), testSample(6, 1, 0))).?;
    try testing.expect(!try apply(testing.allocator, &t, &p));
}

test "apply: grow pulls back exactly the plan's rows with the cursor above a footer" {
    // H0..H5 in history; the cursor on row 2 with F3..F5 below it, where
    // Ghostty's own resize wouldn't pull at all. The plan brings back two
    // of the six history rows and adds two blank rows.
    var t = try testTerminal(6, "H0\r\nH1\r\nH2\r\nH3\r\nH4\r\nH5\r\nA6\r\nA7\r\nC\r\nF3\r\nF4\r\nF5\x1b[3;2H");
    defer t.deinit(testing.allocator);
    try expectDump(&t, "H0\nH1\nH2\nH3\nH4\nH5", "A6\nA7\nC\nF3\nF4\nF5");

    const p = (try plan(testing.allocator, testSample(6, 2, 6), testSample(10, 4, 4))).?;
    try testing.expectEqual(2, p.pulled());
    try testing.expect(canApply(&t, &p));
    try testing.expect(try apply(testing.allocator, &t, &p));
    try expectDump(&t, "H0\nH1\nH2\nH3", "H4\nH5\nA6\nA7\nC\nF3\nF4\nF5");
    try testing.expect(cursorMatches(&t, 1, 4));
}

test "apply: the mirror needs the rows tmux pulled back" {
    var t = try testTerminal(4, "a\r\nb");
    defer t.deinit(testing.allocator);
    const p = (try plan(testing.allocator, testSample(4, 1, 2), testSample(6, 3, 0))).?;
    try testing.expect(!canApply(&t, &p));
}
