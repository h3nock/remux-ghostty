//! tmux's height-resize rules for a pane's mirror terminal.
//!
//! A resize Remux sends runs between two `list-panes` samples in one tmux
//! command line, and tmux parses no pane output between them. The samples
//! therefore bracket exactly tmux's own resize. From them and the mirror's
//! cursor, `plan` derives the rows tmux deleted below the cursor, pushed into
//! history and pulled back, and `apply` repeats those moves on the mirror.
//! Anything that can't be reproduced exactly returns null so the caller
//! recaptures the pane from tmux instead.
//!
//! A zoomed pane in a cell narrower than its window is narrowed and widened
//! again, which no row moves reproduce. Its history afterwards is still the
//! mirror's: `detour` and `applyDetour` keep it, and the caller draws tmux's
//! screen, captured in the same command line.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Terminal = @import("../../terminal/Terminal.zig");
const Screen = @import("../../terminal/Screen.zig");
const Selection = @import("../../terminal/Selection.zig");
const formatter_pkg = @import("../../terminal/formatter.zig");
const point = @import("../../terminal/point.zig");
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

/// tmux's resize of a zoomed pane whose layout cell is narrower or wider
/// than its window: its width goes to the cell's and back, and its rows
/// reflow twice. Its history afterwards is, as drawn, the first rows of its
/// history and screen before (measured on tmux 3.1 and 3.5a), so the mirror
/// keeps its own rows and takes only the screen from tmux.
pub const Detour = struct {
    /// Rows tmux moved from the top of the screen into history, or back out
    /// of history when negative.
    history: isize,

    /// A step changed the height, which resets tmux's scroll region.
    rows_changed: bool,
};

/// The detour tmux's resize took with this pane, or null if it wasn't one.
pub fn detour(
    alloc: Allocator,
    before: Sample,
    after: Sample,
) Allocator.Error!?Detour {
    assert(before.pane_id == after.pane_id);
    if (after.width != before.width or after.alternate != before.alternate) return null;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var steps_storage: [max_steps]Size = undefined;
    const steps = try resizeSteps(arena.allocator(), before, after, &steps_storage) orelse
        return null;

    // Only the pane zoomed before and after takes more than one step.
    if (steps.len != max_steps) return null;
    var narrowed = false;
    var rows_changed = false;
    var rows = before.height;
    for (steps) |step| {
        narrowed = narrowed or step.cols != before.width;
        rows_changed = rows_changed or step.rows != rows;
        rows = step.rows;
    }
    if (!narrowed) return null;
    const history_before = std.math.cast(isize, before.history) orelse return null;
    const history_after = std.math.cast(isize, after.history) orelse return null;
    return .{ .history = history_after - history_before, .rows_changed = rows_changed };
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

/// The size of the pane's cell in the layout, or null if it has none.
pub fn findCell(layout: Layout, pane_id: usize) ?Size {
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

/// Terminal state Ghostty's resize would change but tmux's keeps.
const KeptState = struct {
    screen: *Screen,
    saved_cursor: ?Screen.SavedCursor,
    redraw: @FieldType(@FieldType(Terminal, "flags"), "shell_redraws_prompt"),
    pull_scrollback: bool,

    /// tmux keeps the saved cursor's coordinates through a resize, while
    /// Ghostty moves it with its row. tmux also never clears a prompt for
    /// the shell to redraw; the shell's redraw reaches both as output.
    fn begin(t: *Terminal) KeptState {
        const screen = t.screens.active;
        const kept: KeptState = .{
            .screen = screen,
            .saved_cursor = screen.saved_cursor,
            .redraw = t.flags.shell_redraws_prompt,
            .pull_scrollback = t.flags.resize_pull_scrollback,
        };
        screen.saved_cursor = null;
        t.flags.shell_redraws_prompt = .false;
        return kept;
    }

    fn restore(self: KeptState, t: *Terminal) void {
        self.screen.saved_cursor = self.saved_cursor;
        t.flags.shell_redraws_prompt = self.redraw;
        t.flags.resize_pull_scrollback = self.pull_scrollback;
    }
};

/// Repeat the plan's moves with Ghostty's own resize, set up so it moves the
/// same rows as tmux. Returns false when it couldn't, and the pane must be
/// recaptured.
pub fn apply(alloc: Allocator, t: *Terminal, p: *const Plan) Terminal.ResizeError!bool {
    const kept: KeptState = .begin(t);
    defer kept.restore(t);

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

/// Whether the mirror can repeat the detour with its own rows: the rows tmux
/// took back out of history must be in its history, and a row must stay on
/// the screen below the ones moved into history. The alternate screen has
/// no history to move.
pub fn canApplyDetour(t: *const Terminal, d: Detour) bool {
    if (t.screens.active_key == .alternate) return d.history == 0;
    if (d.history < 0) return @abs(d.history) <= @min(
        localHistory(t),
        std.math.maxInt(size.CellCountInt) - t.rows,
    );
    return @abs(d.history) < t.rows;
}

/// Repeat a detour on the mirror with its own rows: move the history
/// boundary by the rows tmux moved, then blank the screen and give it
/// `rows`, for the caller to draw tmux's screen. Tab stops and the scroll
/// region end as tmux leaves them. Returns false when another row crossed
/// the boundary, and the pane must be recaptured.
pub fn applyDetour(
    alloc: Allocator,
    t: *Terminal,
    d: Detour,
    rows: size.CellCountInt,
) Terminal.ResizeError!bool {
    assert(canApplyDetour(t, d));
    const kept: KeptState = .begin(t);
    defer kept.restore(t);

    // tmux resets the tab stops when a pane's width changes, and the scroll
    // region when its height does.
    const region = t.scrolling_region;
    defer {
        t.tabReset();
        t.scrolling_region = if (d.rows_changed) .{
            .top = 0,
            .bottom = t.rows - 1,
            .left = 0,
            .right = t.cols - 1,
        } else region;
    }

    if (t.screens.active_key == .alternate) {
        try t.resize(alloc, .{ .cols = t.cols, .rows = rows });
        return true;
    }

    // The row that is the screen's first once the boundary has moved. It
    // must still be after the resize, whatever old history Ghostty prunes.
    // A tracked pin keeps Ghostty from trimming its row, but the moves
    // below never trim at or above the cursor's row, where it is.
    const screen = t.screens.active;
    const moved: size.CellCountInt = @intCast(@abs(d.history));
    const first = if (d.history < 0)
        screen.pages.pin(.{ .history = .{ .y = @intCast(localHistory(t) - moved) } }).?
    else
        screen.pages.pin(.{ .active = .{ .y = moved } }).?;
    const tracked = try screen.pages.trackPin(first);
    defer screen.pages.untrackPin(tracked);

    if (moved > 0) {
        // Ghostty never trims the cursor's row, so with the cursor on the
        // last row a shrink pushes exactly the top rows into history, and a
        // grow pulls exactly the rows back.
        screen.cursorAbsolute(0, t.rows - 1);
        t.flags.resize_pull_scrollback = true;
        try t.resize(alloc, .{
            .cols = t.cols,
            .rows = if (d.history > 0) t.rows - moved else t.rows + moved,
        });
    }

    // The screen's rows are replaced, so a selection on them can't stay.
    if (screen.selection) |sel| {
        if (screen.pages.pointFromPin(.active, sel.bottomRight(screen)) != null) {
            screen.clearSelection();
        }
    }

    // A blank screen with the cursor on its first row takes its new height
    // without pushing or pulling a row.
    screen.clearRows(.{ .active = .{} }, null, false);
    screen.cursorAbsolute(0, 0);
    t.flags.resize_pull_scrollback = false;
    try t.resize(alloc, .{ .cols = t.cols, .rows = rows });

    if (tracked.garbage) return false;
    const top = screen.pages.pointFromPin(.active, tracked.*) orelse return false;
    return top.active.y == 0;
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

/// Pane 0 zoomed in a 20-column window split left/right (its cell is 10
/// columns wide).
fn testZoomedSample(height: usize, cursor_y: usize, history: usize) Sample {
    var sample = testSample(height, cursor_y, history);
    sample.layout = switch (height) {
        10 => "f436,20x10,0,0{10x10,0,0,0,9x10,11,0,1}",
        6 => "23d6,20x6,0,0{10x6,0,0,0,9x6,11,0,1}",
        else => unreachable,
    };
    sample.visible_layout = switch (height) {
        10 => "9edd,20x10,0,0,0",
        6 => "f15d,20x6,0,0,0",
        else => unreachable,
    };
    return sample;
}

test "detour: a zoomed pane in a narrower cell is narrowed and widened" {
    // tmux 3.5a, the cursor on the last row: shrinking the cell to 6 rows
    // pushes four rows into history.
    const before = testZoomedSample(10, 9, 3);
    const after = testZoomedSample(6, 5, 7);
    try testing.expect(try plan(testing.allocator, before, after) == null);
    try testing.expectEqual(
        Detour{ .history = 4, .rows_changed = true },
        (try detour(testing.allocator, before, after)).?,
    );

    // A same-size refresh changes no height, so tmux keeps its scroll
    // region.
    try testing.expectEqual(
        Detour{ .history = 0, .rows_changed = false },
        (try detour(testing.allocator, before, before)).?,
    );
}

test "detour: a resize that keeps the width at every step isn't one" {
    // Zoomed in a full-width cell.
    var top = testSample(10, 1, 0);
    top.layout = "9762,20x10,0,0[20x6,0,0,0,20x3,0,7,1]";
    top.visible_layout = "9edd,20x10,0,0,0";
    try testing.expect(try detour(testing.allocator, top, top) == null);

    // Not zoomed.
    try testing.expect(try detour(testing.allocator, testSample(10, 1, 0), testSample(6, 1, 0)) == null);

    // Unzoomed between the samples.
    var unzoomed = testZoomedSample(10, 9, 3);
    unzoomed.visible_layout = unzoomed.layout;
    try testing.expect(try detour(testing.allocator, testZoomedSample(10, 9, 3), unzoomed) == null);

    // A width change, and a change of screen.
    var wider = testZoomedSample(10, 9, 3);
    wider.width = 21;
    try testing.expect(try detour(testing.allocator, testZoomedSample(10, 9, 3), wider) == null);
    var alternate = testZoomedSample(10, 9, 3);
    alternate.alternate = true;
    try testing.expect(try detour(testing.allocator, testZoomedSample(10, 9, 3), alternate) == null);
}

/// The rows from `tl` to `br`, inclusive, with their styles.
fn testVtRows(t: *const Terminal, tl: point.Point, br: point.Point) ![]u8 {
    const pages = &t.screens.active.pages;
    var formatter: formatter_pkg.PageListFormatter = .init(pages, .vt);
    formatter.top_left = pages.pin(tl).?;
    formatter.bottom_right = pages.pin(br).?;
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer builder.deinit();
    try formatter.format(&builder.writer);
    return builder.toOwnedSlice();
}

/// Every history row with its styles.
fn testVtHistory(t: *const Terminal) ![]u8 {
    return testVtRows(
        t,
        .{ .history = .{} },
        .{ .history = .{ .x = t.cols - 1, .y = @intCast(localHistory(t) - 1) } },
    );
}

/// L00 (red) to L14, a row each, then a scroll region on rows 2-5 and no
/// tab stops: history L00-L05, the screen L06-L14 and a blank row with the
/// cursor.
const test_detour_rows = "\x1b[31mL00\x1b[0m\r\nL01\r\nL02\r\nL03\r\nL04\r\nL05\r\nL06\r\nL07\r\n" ++
    "L08\r\nL09\r\nL10\r\nL11\r\nL12\r\nL13\r\nL14\r\n\x1b[3g\x1b7\x1b[2;5r\x1b8";

test "applyDetour: rows tmux moved into history are the mirror's own" {
    var t = try testTerminal(10, test_detour_rows);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(6, localHistory(&t));
    const expected = try testVtRows(&t, .{ .history = .{} }, .{ .active = .{ .x = 19, .y = 2 } });
    defer testing.allocator.free(expected);

    const d: Detour = .{ .history = 3, .rows_changed = true };
    try testing.expect(canApplyDetour(&t, d));
    try testing.expect(try applyDetour(testing.allocator, &t, d, 6));
    try testing.expectEqual(6, t.rows);
    try expectDump(&t, "L00\nL01\nL02\nL03\nL04\nL05\nL06\nL07\nL08", "");
    const history = try testVtHistory(&t);
    defer testing.allocator.free(history);
    try testing.expectEqualStrings(expected, history);

    // tmux's height changed, so its scroll region is reset; its width
    // changed, so its tab stops are.
    try testing.expectEqual(0, t.scrolling_region.top);
    try testing.expectEqual(5, t.scrolling_region.bottom);
    try testing.expect(t.tabstops.get(8));
}

test "applyDetour: a detour that moves no row keeps history and the scroll region" {
    var t = try testTerminal(10, test_detour_rows);
    defer t.deinit(testing.allocator);
    const expected = try testVtHistory(&t);
    defer testing.allocator.free(expected);

    const d: Detour = .{ .history = 0, .rows_changed = false };
    try testing.expect(try applyDetour(testing.allocator, &t, d, 10));
    try expectDump(&t, "L00\nL01\nL02\nL03\nL04\nL05", "");
    const history = try testVtHistory(&t);
    defer testing.allocator.free(history);
    try testing.expectEqualStrings(expected, history);
    try testing.expectEqual(1, t.scrolling_region.top);
    try testing.expectEqual(4, t.scrolling_region.bottom);
    try testing.expect(t.tabstops.get(8));
}

test "applyDetour: rows tmux took back out of history come from the mirror's history" {
    var t = try testTerminal(10, test_detour_rows);
    defer t.deinit(testing.allocator);
    const expected = try testVtRows(&t, .{ .history = .{} }, .{ .history = .{ .x = 19, .y = 1 } });
    defer testing.allocator.free(expected);

    const d: Detour = .{ .history = -4, .rows_changed = true };
    try testing.expect(canApplyDetour(&t, d));
    try testing.expect(!canApplyDetour(&t, .{ .history = -7, .rows_changed = true }));
    try testing.expect(try applyDetour(testing.allocator, &t, d, 10));
    try expectDump(&t, "L00\nL01", "");
    const history = try testVtHistory(&t);
    defer testing.allocator.free(history);
    try testing.expectEqualStrings(expected, history);
}

test "applyDetour: a selection keeps its history rows and leaves the redrawn screen" {
    var t = try testTerminal(10, test_detour_rows);
    defer t.deinit(testing.allocator);
    const screen = t.screens.active;

    // L01 to L02, in history.
    try screen.select(Selection.init(
        screen.pages.pin(.{ .history = .{ .y = 1 } }).?,
        screen.pages.pin(.{ .history = .{ .x = 2, .y = 2 } }).?,
        false,
    ));
    try testing.expect(try applyDetour(testing.allocator, &t, .{ .history = 3, .rows_changed = true }, 6));
    try testing.expect(screen.selection != null);

    // From L05 in history to the screen's first row, which the detour
    // redraws.
    try screen.select(Selection.init(
        screen.pages.pin(.{ .history = .{ .y = 5 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?,
        false,
    ));
    try testing.expect(try applyDetour(testing.allocator, &t, .{ .history = 0, .rows_changed = false }, 6));
    try testing.expect(screen.selection == null);
}

test "applyDetour: a row Ghostty won't trim crosses into history and recaptures" {
    var t = try testTerminal(10, test_detour_rows);
    defer t.deinit(testing.allocator);

    // A tracked pin, such as a search match's, on the last row.
    const pages = &t.screens.active.pages;
    const pin = try pages.trackPin(pages.pin(.{ .active = .{ .y = 9 } }).?);
    defer pages.untrackPin(pin);
    try testing.expect(!try applyDetour(testing.allocator, &t, .{ .history = 0, .rows_changed = true }, 6));
}

test "applyDetour: history at the scrollback limit stays whole near the boundary" {
    // The app's limit, Ghostty's two-page minimum at this size.
    var t: Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 50,
        .rows = 41,
        .max_scrollback_bytes = 10_000,
    });
    defer t.deinit(testing.allocator);
    var stream = t.vtStream();
    defer stream.deinit();

    // Fill both pages until the last can't take the ten rows the resize
    // grows by: it allocates a page, which drops the oldest.
    const pages = &t.screens.active.pages;
    var line: usize = 0;
    while (line < 100_000) : (line += 1) {
        var buffer: [32]u8 = undefined;
        stream.nextSlice(try std.fmt.bufPrint(&buffer, "\x1b[3{d}mline {d}\x1b[0m\r\n", .{ line % 8, line }));
        const last = pages.pages.last.?;
        if (pages.pages.first != last and last.capacity().rows - last.rows() < 10) break;
    }
    const history_before = localHistory(&t);
    const expected = try testVtRows(
        &t,
        .{ .history = .{ .y = @intCast(history_before - 20) } },
        .{ .active = .{ .x = 49, .y = 9 } },
    );
    defer testing.allocator.free(expected);

    try testing.expect(try applyDetour(testing.allocator, &t, .{ .history = 10, .rows_changed = true }, 41));
    try testing.expect(localHistory(&t) < history_before + 10);
    const kept = try testVtRows(
        &t,
        .{ .history = .{ .y = @intCast(localHistory(&t) - 30) } },
        .{ .history = .{ .x = 49, .y = @intCast(localHistory(&t) - 1) } },
    );
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(expected, kept);
}
