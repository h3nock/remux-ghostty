//! Renderer surface over one retained terminal supplied by its caller.
pub const TerminalSurface = @This();

const std = @import("std");
const builtin = @import("builtin");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const crash = @import("../crash/main.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const rendererpkg = @import("../renderer.zig");
const sizepkg = @import("size.zig");
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.terminal_surface);

alloc: std.mem.Allocator,
runtime: rendererpkg.Runtime,
size: rendererpkg.Size,
shared: *terminal.Shared,
write_sink: ?WriteSink,
macos_option_as_alt: input.OptionAsAlt,
vt_kam_allowed: bool,
selection_clear_on_typing: bool,
scroll_to_bottom_on_keystroke: bool,
mouse_reporting: bool,
explicit_padding: rendererpkg.Padding,
padding_balance: sizepkg.PaddingBalance,
/// Scheduling hint shared with terminal producers. Terminal contents remain
/// synchronized by Shared.mutex.
visible: std.atomic.Value(bool),
focused: bool,

/// Synchronous admission boundary for already encoded terminal input. The
/// callback borrows `data` only until it returns and must copy or enqueue it
/// before returning true. It runs outside Shared.mutex and must not reenter a
/// TerminalSurface operation.
pub const WriteSink = struct {
    ptr: *anyopaque,
    callback: *const fn (ptr: *anyopaque, data: []const u8) bool,

    fn write(self: WriteSink, data: []const u8) bool {
        return self.callback(self.ptr, data);
    }
};

/// Result of terminal-aware key or paste admission.
pub const InputResult = enum(c_int) {
    sent,
    consumed_no_output,
    not_accepted,
    unavailable,
    invalid_input,
    out_of_memory,
};

pub const ScrollRoute = enum(c_int) {
    viewport,
    alternate_screen_cursor,
    remote_mouse,
};

pub const Scrollbar = struct {
    total: usize,
    offset: usize,
    len: usize,
    cell_offset: f64,
};

pub const InteractionState = struct {
    scrollbar: Scrollbar,
    route: ScrollRoute,
    mouse_captured: bool,
    has_selection: bool,
};

const ScrollPosition = struct {
    row: usize,
    cell_offset: f64,
};

pub const Options = struct {
    alloc: std.mem.Allocator,
    config: *const configpkg.Config,
    rt_surface: *apprt.RendererSurface,
    shared: *terminal.Shared,
    font_grid_set: *font.SharedGridSet,
    font_config: *const font.SharedGridSet.DerivedConfig,
    font_size: font.face.DesiredSize,
    explicit_padding: rendererpkg.Padding,
    padding_balance: sizepkg.PaddingBalance,
    event_sink: rendererpkg.EventSink,
    write_sink: ?WriteSink = null,
    macos_option_as_alt: input.OptionAsAlt = .false,
    crash_context: ?crash.sentry.ThreadState,
    visible: bool = true,
    focused: bool = true,
};

/// Initialize in stable caller-owned storage and start the renderer thread.
/// The renderer surface, font-grid set, and event-sink context are borrowed and
/// must outlive this surface. Config and derived font config are consumed only
/// during this call. The retained Shared terminal and its mutex remain valid
/// through deinit.
pub fn init(self: *TerminalSurface, opts: Options) !font.Metrics {
    const shared = opts.shared.retain();
    errdefer shared.release();

    try shared.claimRenderer();
    errdefer shared.releaseRenderer();

    try rendererpkg.Renderer.surfaceInit(opts.rt_surface);

    self.* = .{
        .alloc = opts.alloc,
        .runtime = undefined,
        .size = undefined,
        .shared = shared,
        .write_sink = opts.write_sink,
        .macos_option_as_alt = opts.macos_option_as_alt,
        .vt_kam_allowed = opts.config.@"vt-kam-allowed",
        .selection_clear_on_typing = opts.config.@"selection-clear-on-typing",
        .scroll_to_bottom_on_keystroke = opts.config.@"scroll-to-bottom".keystroke,
        .mouse_reporting = opts.config.@"mouse-reporting",
        .explicit_padding = opts.explicit_padding,
        .padding_balance = opts.padding_balance,
        .visible = .init(opts.visible),
        .focused = opts.focused,
    };

    const metrics = try self.runtime.init(.{
        .alloc = opts.alloc,
        .config = opts.config,
        .rt_surface = opts.rt_surface,
        .terminal = &shared.terminal,
        .mutex = &shared.mutex,
        .font_grid_set = opts.font_grid_set,
        .font_config = opts.font_config,
        .font_size = opts.font_size,
        .size = &self.size,
        .explicit_padding = opts.explicit_padding,
        .padding_balance = opts.padding_balance,
        .event_sink = opts.event_sink,
        .crash_context = opts.crash_context,
        .visible = opts.visible,
        .focused = opts.focused,
    });
    errdefer self.runtime.deinit();

    try self.runtime.start();
    return metrics;
}

pub fn deinit(self: *TerminalSurface) void {
    self.runtime.stop();
    self.runtime.deinit();
    self.shared.releaseRenderer();
    self.shared.release();
}

/// Force a draw from the calling thread without rebuilding terminal state.
pub fn drawFrame(self: *TerminalSurface) !void {
    try self.runtime.renderer.drawFrame(true);
}

/// Notify the renderer that canonical terminal state changed. This may be
/// called by a terminal producer after publishing its changes under
/// Shared.mutex.
pub fn terminalChanged(self: *TerminalSurface) !void {
    if (!self.visible.load(.monotonic)) return;
    try self.runtime.thread.wakeup.notify();
}

/// Submit a visibility change. Calls to presentation setters and resize must
/// be serialized by the presentation owner. Visibility is stored before the
/// wake so concurrent terminal producers cannot miss the transition. Callers
/// may retry the same value if notification fails.
pub fn setVisible(self: *TerminalSurface, visible: bool) !void {
    self.visible.store(visible, .monotonic);
    try self.queueAndWake(.{ .visible = visible });
}

/// Submit a focus change. Calls must be serialized with other presentation
/// setters and resize.
pub fn setFocused(self: *TerminalSurface, focused: bool) !void {
    if (self.focused == focused) return;
    try self.queueAndWake(.{ .focus = focused });
    self.focused = focused;
}

/// Resize renderer presentation without changing canonical terminal geometry.
/// Calls must be serialized with the presentation setters.
pub fn resize(self: *TerminalSurface, screen: rendererpkg.ScreenSize) !void {
    if (self.size.screen.equals(screen)) return;

    var size = self.size;
    size.screen = screen;
    if (self.padding_balance == .false) {
        size.padding = self.explicit_padding;
    } else {
        size.balancePadding(self.explicit_padding, self.padding_balance);
    }

    try self.queueAndWake(.{ .resize = size });
    self.size = size;
}

pub fn desiredGridSize(self: *const TerminalSurface) rendererpkg.GridSize {
    return self.size.grid();
}

/// Return the terminal interaction state from one synchronized snapshot.
pub fn interactionState(self: *TerminalSurface) InteractionState {
    self.shared.mutex.lock();
    defer self.shared.mutex.unlock();
    return self.normalizeAndSnapshotInteractionLocked();
}

/// Scroll to an absolute row plus fractional cell offset. The canonical
/// terminal viewport and renderer presentation offset are published together.
/// The output is filled before any notification failure is returned. Repeating
/// the same position is a no-op; retry a failed wake with `terminalChanged`.
pub fn scrollToPosition(
    self: *TerminalSurface,
    row: usize,
    cell_offset: f64,
    out: *InteractionState,
) !void {
    std.debug.assert(std.math.isFinite(cell_offset));

    self.shared.mutex.lock();
    const before = self.normalizeAndSnapshotInteractionLocked();
    const max_row = scrollbarMaxRow(before.scrollbar);
    const position = normalizeScrollPosition(row, cell_offset, max_row);
    const row_changed = position.row != before.scrollbar.offset;
    const fraction_changed = position.cell_offset !=
        self.runtime.state.scroll_cell_offset;

    if (row_changed) {
        self.shared.terminal.scrollViewport(.{ .row = position.row });
    }
    self.runtime.state.scroll_cell_offset = position.cell_offset;
    out.* = self.normalizeAndSnapshotInteractionLocked();
    self.shared.mutex.unlock();

    if (row_changed or fraction_changed) try self.terminalChanged();
}

fn normalizeAndSnapshotInteractionLocked(
    self: *TerminalSurface,
) InteractionState {
    const term = &self.shared.terminal;
    const screen = term.screens.active;
    const scrollbar = screen.pages.scrollbar();
    const max_row = if (scrollbar.total > scrollbar.len)
        scrollbar.total - scrollbar.len
    else
        0;
    if (scrollbar.offset >= max_row) {
        self.runtime.state.scroll_cell_offset = 0;
    }
    const mouse_captured = self.mouse_reporting and
        term.flags.mouse_event != .none;

    return .{
        .scrollbar = .{
            .total = scrollbar.total,
            .offset = scrollbar.offset,
            .len = scrollbar.len,
            .cell_offset = self.runtime.state.scroll_cell_offset,
        },
        .route = if (mouse_captured)
            .remote_mouse
        else if (term.screens.active_key == .alternate and
            term.flags.mouse_event == .none and
            term.modes.get(.mouse_alternate_scroll))
            .alternate_screen_cursor
        else
            .viewport,
        .mouse_captured = mouse_captured,
        .has_selection = screen.selection != null,
    };
}

fn scrollbarMaxRow(scrollbar: Scrollbar) usize {
    return if (scrollbar.total > scrollbar.len)
        scrollbar.total - scrollbar.len
    else
        0;
}

fn saturatedFloatToUsize(value: f64) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    const max_float: f64 = @floatFromInt(std.math.maxInt(usize));
    if (value >= max_float) return std.math.maxInt(usize);
    return @intFromFloat(value);
}

fn normalizeScrollPosition(
    row: usize,
    cell_offset: f64,
    max_row: usize,
) ScrollPosition {
    std.debug.assert(std.math.isFinite(cell_offset));

    var normalized_row = row;
    var fraction = cell_offset;
    if (fraction < 0 or fraction >= 1) {
        const carry = @floor(fraction);
        fraction -= carry;
        if (carry > 0) {
            const carry_usize = saturatedFloatToUsize(carry);
            normalized_row = if (carry_usize >
                std.math.maxInt(usize) - normalized_row)
                std.math.maxInt(usize)
            else
                normalized_row + carry_usize;
        } else if (carry < 0) {
            const carry_usize = saturatedFloatToUsize(-carry);
            if (carry_usize > normalized_row) {
                return .{ .row = 0, .cell_offset = 0 };
            }
            normalized_row -= carry_usize;
        }
    }

    normalized_row = @min(normalized_row, max_row);
    if (normalized_row >= max_row) {
        return .{ .row = max_row, .cell_offset = 0 };
    }
    return .{ .row = normalized_row, .cell_offset = fraction };
}

/// Filter modifiers for native text translation. The original modifiers must
/// still be passed to `key` so terminal encoding can apply Alt semantics.
pub fn keyTranslationMods(
    self: *const TerminalSurface,
    mods: input.Mods,
) input.Mods {
    return mods.translation(self.macos_option_as_alt);
}

/// Encode and synchronously admit one key event. Terminal modes are
/// snapshotted under Shared.mutex; encoding and the write callback are
/// lock-free. Local selection and viewport effects are applied only after the
/// sink accepts the complete encoding.
pub fn key(
    self: *TerminalSurface,
    event: input.KeyEvent,
) InputResult {
    const encoding_opts: input.key_encode.Options = opts: {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();

        if (self.vt_kam_allowed and
            self.shared.terminal.modes.get(.disable_keyboard))
        {
            return .consumed_no_output;
        }

        var opts: input.key_encode.Options = .fromTerminal(
            &self.shared.terminal,
        );
        opts.macos_option_as_alt = self.macos_option_as_alt;
        break :opts opts;
    };

    const sink = self.write_sink orelse return .unavailable;

    // This matches the established process-surface fast path and contains
    // ordinary legacy and Kitty key encodings without allocation.
    var stack: [38]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&stack);
    input.key_encode.encode(&writer, event, encoding_opts) catch |err| switch (err) {
        error.WriteFailed => return self.keyLong(sink, event, encoding_opts),
    };

    const encoded = writer.buffered();
    if (encoded.len == 0) return .not_accepted;
    if (!sink.write(encoded)) return .not_accepted;

    self.acceptedKey(event.key);
    return .sent;
}

fn keyLong(
    self: *TerminalSurface,
    sink: WriteSink,
    event: input.KeyEvent,
    encoding_opts: input.key_encode.Options,
) InputResult {
    // Count first so the rare fallback performs exactly one allocation and
    // never resizes. Encoding has no side effects.
    var counter: std.Io.Writer.Discarding = .init(&.{});
    input.key_encode.encode(
        &counter.writer,
        event,
        encoding_opts,
    ) catch unreachable;
    const len = std.math.cast(usize, counter.fullCount()) orelse
        return .out_of_memory;
    if (len == 0) return .not_accepted;

    const encoded = self.alloc.alloc(u8, len) catch return .out_of_memory;
    defer self.alloc.free(encoded);
    var writer: std.Io.Writer = .fixed(encoded);
    input.key_encode.encode(&writer, event, encoding_opts) catch unreachable;
    std.debug.assert(writer.buffered().len == encoded.len);

    if (!sink.write(encoded)) return .not_accepted;
    self.acceptedKey(event.key);
    return .sent;
}

/// Transform and synchronously admit one paste as a single callback payload.
/// Empty paste is a consumed no-op. Unchanged unbracketed input is borrowed
/// directly; framing or byte transformation performs one combined allocation.
pub fn paste(
    self: *TerminalSurface,
    data: []const u8,
) InputResult {
    if (data.len == 0) return .consumed_no_output;
    const sink = self.write_sink orelse return .unavailable;

    const encoding_opts: input.paste.Options = opts: {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();
        break :opts .fromTerminal(&self.shared.terminal);
    };

    const vecs = input.paste.encode(data, encoding_opts) catch |err| switch (err) {
        error.MutableRequired => return self.pasteAllocated(
            sink,
            data,
            encoding_opts,
        ),
    };

    // The only allocation-free contiguous representation is an unchanged,
    // unbracketed body.
    if (vecs[0].len == 0 and vecs[2].len == 0) {
        if (!sink.write(vecs[1])) return .not_accepted;
        self.acceptedPaste();
        return .sent;
    }

    return self.pasteAllocated(sink, data, encoding_opts);
}

fn pasteAllocated(
    self: *TerminalSurface,
    sink: WriteSink,
    data: []const u8,
    encoding_opts: input.paste.Options,
) InputResult {
    const fence_len: usize = if (encoding_opts.bracketed) 6 else 0;
    const framed_len = std.math.add(
        usize,
        data.len,
        2 * fence_len,
    ) catch return .out_of_memory;

    const encoded = self.alloc.alloc(u8, framed_len) catch return .out_of_memory;
    defer self.alloc.free(encoded);
    const body = encoded[fence_len .. fence_len + data.len];
    @memcpy(body, data);

    const vecs = input.paste.encode(body, encoding_opts);
    std.debug.assert(vecs[0].len == fence_len);
    std.debug.assert(vecs[2].len == fence_len);
    @memcpy(encoded[0..fence_len], vecs[0]);
    @memcpy(encoded[fence_len + data.len ..], vecs[2]);

    if (!sink.write(encoded)) return .not_accepted;
    self.acceptedPaste();
    return .sent;
}

fn acceptedKey(self: *TerminalSurface, key_value: input.Key) void {
    if (key_value.modifier()) return;

    var changed = false;
    self.shared.mutex.lock();
    const screen = self.shared.terminal.screens.active;
    if ((self.selection_clear_on_typing or key_value == .escape) and
        screen.selection != null)
    {
        screen.clearSelection();
        changed = true;
    }
    if (self.scroll_to_bottom_on_keystroke) {
        if (!screen.viewportIsBottom()) {
            self.shared.terminal.scrollViewport(.bottom);
            changed = true;
        }
        if (self.runtime.state.scroll_cell_offset != 0) {
            self.runtime.state.scroll_cell_offset = 0;
            changed = true;
        }
    }
    self.shared.mutex.unlock();

    if (changed) self.inputEffectsChanged();
}

fn acceptedPaste(self: *TerminalSurface) void {
    var changed = false;
    self.shared.mutex.lock();
    if (!self.shared.terminal.screens.active.viewportIsBottom()) {
        self.shared.terminal.scrollViewport(.bottom);
        changed = true;
    }
    if (self.runtime.state.scroll_cell_offset != 0) {
        self.runtime.state.scroll_cell_offset = 0;
        changed = true;
    }
    self.shared.mutex.unlock();

    if (changed) self.inputEffectsChanged();
}

fn inputEffectsChanged(self: *TerminalSurface) void {
    self.terminalChanged() catch |err| {
        // The sink has already accepted the bytes, so reporting failure would
        // invite duplicate input on retry. Dirty terminal state remains
        // available to a later draw or successful notification.
        log.err("failed to wake renderer after accepted input err={}", .{err});
    };
}

fn queueAndWake(self: *TerminalSurface, message: rendererpkg.Message) !void {
    _ = self.runtime.thread.mailbox.push(message, .{ .forever = {} });
    try self.runtime.thread.wakeup.notify();
}

const TestSink = struct {
    shared: *terminal.Shared,
    accept: bool = true,
    calls: usize = 0,
    lock_was_free: bool = false,
    last_ptr: ?[*]const u8 = null,
    data: [256]u8 = undefined,
    len: usize = 0,

    fn writeSink(self: *TestSink) WriteSink {
        return .{ .ptr = self, .callback = write };
    }

    fn write(ptr: *anyopaque, data: []const u8) bool {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.last_ptr = data.ptr;
        self.len = data.len;
        @memcpy(self.data[0..data.len], data);
        self.lock_was_free = self.shared.mutex.tryLock();
        if (self.lock_was_free) self.shared.mutex.unlock();
        return self.accept;
    }
};

fn testSurface(
    alloc: std.mem.Allocator,
    shared: *terminal.Shared,
    write_sink: ?WriteSink,
) TerminalSurface {
    var result: TerminalSurface = .{
        .alloc = alloc,
        .runtime = undefined,
        .size = undefined,
        .shared = shared,
        .write_sink = write_sink,
        .macos_option_as_alt = .false,
        .vt_kam_allowed = false,
        .selection_clear_on_typing = true,
        .scroll_to_bottom_on_keystroke = true,
        .mouse_reporting = true,
        .explicit_padding = undefined,
        .padding_balance = undefined,
        // Headless tests suppress renderer notification after verifying the
        // terminal-side effects published before it.
        .visible = .init(false),
        .focused = true,
    };
    result.runtime.state = .{
        .terminal = &shared.terminal,
        .mutex = &shared.mutex,
    };
    return result;
}

fn setTestSelectionAndViewport(shared: *terminal.Shared) !void {
    shared.mutex.lock();
    defer shared.mutex.unlock();
    const screen = shared.terminal.screens.active;
    const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
    try screen.select(terminal.Selection.init(pin, pin, false));
    shared.terminal.scrollViewport(.top);
}

fn testCompressionActivity(shared: *terminal.Shared) u64 {
    shared.mutex.lock();
    defer shared.mutex.unlock();
    return shared.terminal.compressionActivity();
}

test "terminal surface key admission contract" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer shared.release();
    var sink: TestSink = .{ .shared = shared };
    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    var surface = testSurface(tracking.allocator(), shared, sink.writeSink());
    const letter: input.KeyEvent = .{
        .key = .key_a,
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    };

    try testing.expectEqual(InputResult.sent, surface.key(.{
        .key = .arrow_up,
    }));
    try testing.expectEqualStrings("\x1b[A", sink.data[0..sink.len]);
    try testing.expect(sink.lock_was_free);
    try testing.expectEqual(@as(usize, 0), tracking.allocations);

    shared.mutex.lock();
    shared.terminal.modes.set(.cursor_keys, true);
    shared.mutex.unlock();
    sink.calls = 0;
    try testing.expectEqual(InputResult.sent, surface.key(.{
        .key = .arrow_up,
    }));
    try testing.expectEqualStrings("\x1bOA", sink.data[0..sink.len]);

    shared.mutex.lock();
    shared.terminal.modes.set(.disable_keyboard, true);
    shared.mutex.unlock();
    surface.vt_kam_allowed = true;
    sink.calls = 0;
    try testing.expectEqual(InputResult.consumed_no_output, surface.key(.{
        .key = .arrow_up,
    }));
    try testing.expectEqual(@as(usize, 0), sink.calls);
    surface.write_sink = null;
    try testing.expectEqual(InputResult.consumed_no_output, surface.key(.{}));
    surface.write_sink = sink.writeSink();

    shared.mutex.lock();
    shared.terminal.modes.set(.disable_keyboard, false);
    shared.mutex.unlock();
    sink.calls = 0;
    try testing.expectEqual(InputResult.not_accepted, surface.key(.{}));
    try testing.expectEqual(@as(usize, 0), sink.calls);

    try setTestSelectionAndViewport(shared);
    shared.mutex.lock();
    surface.runtime.state.scroll_cell_offset = 0.5;
    shared.mutex.unlock();
    sink.accept = false;
    try testing.expectEqual(InputResult.not_accepted, surface.key(letter));
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection != null);
        try testing.expect(shared.terminal.screens.active.pages.viewport == .top);
        try testing.expectEqual(
            @as(f64, 0.5),
            surface.runtime.state.scroll_cell_offset,
        );
    }

    sink.accept = true;
    try testing.expectEqual(InputResult.sent, surface.key(letter));
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection == null);
        try testing.expect(shared.terminal.screens.active.pages.viewport == .active);
        try testing.expectEqual(
            @as(f64, 0),
            surface.runtime.state.scroll_cell_offset,
        );
    }
    const compression_before_noop_key = testCompressionActivity(shared);
    try testing.expectEqual(InputResult.sent, surface.key(letter));
    try testing.expectEqual(
        compression_before_noop_key,
        testCompressionActivity(shared),
    );

    var unavailable = testSurface(testing.allocator, shared, null);
    try testing.expectEqual(InputResult.unavailable, unavailable.key(letter));
    try testing.expectEqual(InputResult.unavailable, unavailable.key(.{}));

    // Escape clears even when selection-clear-on-typing is disabled.
    try setTestSelectionAndViewport(shared);
    surface.selection_clear_on_typing = false;
    surface.scroll_to_bottom_on_keystroke = false;
    try testing.expectEqual(InputResult.sent, surface.key(.{
        .key = .escape,
    }));
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection == null);
        try testing.expect(shared.terminal.screens.active.pages.viewport == .top);
    }

    surface.macos_option_as_alt = .true;
    const original: input.Mods = .{ .alt = true };
    const translated = surface.keyTranslationMods(original);
    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expect(!translated.alt);
        try testing.expectEqual(InputResult.sent, surface.key(.{
            .key = .key_b,
            .mods = original,
            .utf8 = "b",
            .unshifted_codepoint = 'b',
        }));
        try testing.expectEqualStrings("\x1bb", sink.data[0..sink.len]);
    } else {
        try testing.expect(translated.alt);
    }

    const long = "x" ** 128;
    try testing.expectEqual(InputResult.sent, surface.key(.{ .utf8 = long }));
    try testing.expectEqualStrings(long, sink.data[0..sink.len]);
    try testing.expectEqual(@as(usize, 1), tracking.allocations);
    try testing.expectEqual(@as(usize, 1), tracking.deallocations);
}

test "terminal surface paste admission contract" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer shared.release();
    var sink: TestSink = .{ .shared = shared };
    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    var surface = testSurface(tracking.allocator(), shared, sink.writeSink());

    try setTestSelectionAndViewport(shared);
    try testing.expectEqual(InputResult.consumed_no_output, surface.paste(""));
    try testing.expectEqual(@as(usize, 0), sink.calls);
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.pages.viewport == .top);
    }
    var unavailable = testSurface(testing.allocator, shared, null);
    try testing.expectEqual(InputResult.consumed_no_output, unavailable.paste(""));
    try testing.expectEqual(InputResult.unavailable, unavailable.paste("plain"));

    const unchanged = "plain";
    try testing.expectEqual(InputResult.sent, surface.paste(unchanged));
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqualStrings(unchanged, sink.data[0..sink.len]);
    try testing.expect(sink.last_ptr.? == unchanged.ptr);
    try testing.expect(sink.lock_was_free);
    try testing.expectEqual(@as(usize, 0), tracking.allocations);
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection != null);
        try testing.expect(shared.terminal.screens.active.pages.viewport == .active);
    }
    const compression_before_noop_paste = testCompressionActivity(shared);
    try testing.expectEqual(InputResult.sent, surface.paste(unchanged));
    try testing.expectEqual(
        compression_before_noop_paste,
        testCompressionActivity(shared),
    );

    try setTestSelectionAndViewport(shared);
    shared.mutex.lock();
    surface.runtime.state.scroll_cell_offset = 0.5;
    shared.mutex.unlock();
    sink.accept = false;
    try testing.expectEqual(InputResult.not_accepted, surface.paste(unchanged));
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection != null);
        try testing.expect(shared.terminal.screens.active.pages.viewport == .top);
        try testing.expectEqual(
            @as(f64, 0.5),
            surface.runtime.state.scroll_cell_offset,
        );
    }
    sink.accept = true;

    shared.mutex.lock();
    shared.terminal.modes.set(.bracketed_paste, true);
    shared.mutex.unlock();
    sink.calls = 0;
    try testing.expectEqual(InputResult.sent, surface.paste("a\nb\x00c"));
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqualStrings("\x1b[200~a\nb c\x1b[201~", sink.data[0..sink.len]);
    try testing.expectEqual(@as(usize, 1), tracking.allocations);
    try testing.expectEqual(@as(usize, 1), tracking.deallocations);
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expectEqual(
            @as(f64, 0),
            surface.runtime.state.scroll_cell_offset,
        );
    }

    shared.mutex.lock();
    shared.terminal.modes.set(.bracketed_paste, false);
    shared.mutex.unlock();
    sink.calls = 0;
    try testing.expectEqual(InputResult.sent, surface.paste("a\nb\x03c"));
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqualStrings("a\rb c", sink.data[0..sink.len]);
    try testing.expectEqual(@as(usize, 2), tracking.allocations);
    try testing.expectEqual(@as(usize, 2), tracking.deallocations);

    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    surface.alloc = failing.allocator();
    sink.calls = 0;
    try testing.expectEqual(InputResult.out_of_memory, surface.paste("line\n"));
    try testing.expectEqual(@as(usize, 0), sink.calls);
}

test "terminal surface interaction state and position scrolling" {
    const testing = std.testing;

    try testing.expectEqualDeep(
        ScrollPosition{ .row = 0, .cell_offset = 0 },
        normalizeScrollPosition(0, -0.25, 10),
    );
    try testing.expectEqualDeep(
        ScrollPosition{ .row = 0, .cell_offset = 0.75 },
        normalizeScrollPosition(1, -0.25, 10),
    );
    try testing.expectEqualDeep(
        ScrollPosition{ .row = 3, .cell_offset = 0.25 },
        normalizeScrollPosition(1, 2.25, 10),
    );
    try testing.expectEqualDeep(
        ScrollPosition{ .row = 9, .cell_offset = 0.75 },
        normalizeScrollPosition(10, -0.25, 10),
    );
    try testing.expectEqualDeep(
        ScrollPosition{ .row = 10, .cell_offset = 0 },
        normalizeScrollPosition(std.math.maxInt(usize), -0.25, 10),
    );
    try testing.expectEqualDeep(
        ScrollPosition{ .row = 10, .cell_offset = 0 },
        normalizeScrollPosition(
            std.math.maxInt(usize),
            std.math.floatMax(f64),
            10,
        ),
    );
    try testing.expectEqualDeep(
        ScrollPosition{ .row = 0, .cell_offset = 0 },
        normalizeScrollPosition(
            std.math.maxInt(usize),
            -std.math.floatMax(f64),
            10,
        ),
    );
    const usize_boundary: f64 = @floatFromInt(std.math.maxInt(usize));
    try testing.expectEqualDeep(
        ScrollPosition{ .row = 0, .cell_offset = 0 },
        normalizeScrollPosition(
            std.math.maxInt(usize),
            -usize_boundary,
            10,
        ),
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        saturatedFloatToUsize(usize_boundary),
    );
    try testing.expectEqualDeep(
        ScrollPosition{ .row = 10, .cell_offset = 0 },
        normalizeScrollPosition(0, usize_boundary, 10),
    );

    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 100,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);

    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        var stream = shared.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice("0\r\n1\r\n2\r\n3\r\n4\r\n5");
    }

    var state = surface.interactionState();
    try testing.expectEqual(state.scrollbar.total - state.scrollbar.len, state.scrollbar.offset);
    try testing.expectEqual(@as(f64, 0), state.scrollbar.cell_offset);
    try testing.expectEqual(ScrollRoute.viewport, state.route);
    try testing.expect(!state.mouse_captured);
    try testing.expect(!state.has_selection);

    try surface.scrollToPosition(1, -0.25, &state);
    try testing.expectEqual(@as(usize, 0), state.scrollbar.offset);
    try testing.expectEqual(@as(f64, 0.75), state.scrollbar.cell_offset);
    const activity = testCompressionActivity(shared);
    var retry_state: InteractionState = undefined;
    try surface.scrollToPosition(0, 0.75, &retry_state);
    try testing.expectEqualDeep(state, retry_state);
    try testing.expectEqual(activity, testCompressionActivity(shared));

    try surface.scrollToPosition(
        std.math.maxInt(usize),
        std.math.floatMax(f64),
        &state,
    );
    try testing.expectEqual(state.scrollbar.total - state.scrollbar.len, state.scrollbar.offset);
    try testing.expectEqual(@as(f64, 0), state.scrollbar.cell_offset);

    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        var stream = shared.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[?1049h");
        const screen = shared.terminal.screens.active;
        const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try screen.select(terminal.Selection.init(pin, pin, false));
    }
    state = surface.interactionState();
    try testing.expectEqual(ScrollRoute.alternate_screen_cursor, state.route);
    try testing.expect(!state.mouse_captured);
    try testing.expect(state.has_selection);

    shared.mutex.lock();
    shared.terminal.flags.mouse_event = .normal;
    surface.runtime.state.scroll_cell_offset = 0.5;
    shared.mutex.unlock();
    state = surface.interactionState();
    try testing.expectEqual(ScrollRoute.remote_mouse, state.route);
    try testing.expect(state.mouse_captured);
    try testing.expectEqual(@as(f64, 0), state.scrollbar.cell_offset);
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expectEqual(
            @as(f64, 0),
            surface.runtime.state.scroll_cell_offset,
        );
    }

    surface.mouse_reporting = false;
    state = surface.interactionState();
    try testing.expectEqual(ScrollRoute.viewport, state.route);
    try testing.expect(!state.mouse_captured);
}
