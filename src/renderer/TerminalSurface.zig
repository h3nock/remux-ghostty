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
const renderer_link = @import("link.zig");
const sizepkg = @import("size.zig");
const SurfaceMouse = @import("../surface_mouse.zig");
const terminal = @import("../terminal/main.zig");
const terminal_config = @import("../terminal/config.zig");

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
interaction_config: InteractionConfig,
interaction: Interaction,
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

/// Result of terminal-aware input admission.
pub const InputResult = enum(c_int) {
    sent,
    consumed_no_output,
    not_accepted,
    unavailable,
    invalid_input,
    out_of_memory,
};

/// Scheme-less loopback host:port spans (`127.0.0.1:8000`, `localhost:5173`)
/// are selectable link targets on retained terminal surfaces. The configured
/// URL regex requires a scheme or a slash, so without this supplement word
/// selection splits such spans at the colon.
pub const loopback_host_port_regex =
    "(?<![\\w.\\-])(?:localhost|127(?:\\.\\d{1,3}){3}|0\\.0\\.0\\.0|\\[::1\\]):\\d{1,5}(?!\\d)(?:/[\\w\\-.~:/?#@!$&*+;=%]*)?";

const InteractionConfig = struct {
    word_chars: []const u21,
    click_repeat_interval: u64,
    scroll_multiplier: configpkg.Config.MouseScrollMultiplier,
    links: renderer_link.Set,

    fn init(
        alloc: std.mem.Allocator,
        config: *const configpkg.Config,
    ) !InteractionConfig {
        const word_chars = try alloc.dupe(
            u21,
            config.@"selection-word-chars".codepoints,
        );
        errdefer alloc.free(word_chars);

        // Configured links come first so schemed URL matches keep precedence
        // over the loopback supplement.
        var link_items: std.ArrayList(input.Link) = .empty;
        defer link_items.deinit(alloc);
        try link_items.appendSlice(alloc, config.link.links.items);
        try link_items.append(alloc, .{
            .regex = loopback_host_port_regex,
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        });

        return .{
            .word_chars = word_chars,
            .click_repeat_interval = @as(u64, config.@"click-repeat-interval") * 1_000_000,
            .scroll_multiplier = config.@"mouse-scroll-multiplier",
            .links = try renderer_link.Set.fromConfig(
                alloc,
                link_items.items,
            ),
        };
    }

    fn deinit(self: *InteractionConfig, alloc: std.mem.Allocator) void {
        self.links.deinit(alloc);
        alloc.free(self.word_chars);
        self.* = undefined;
    }
};

const Interaction = struct {
    pointer: ?input.mouse_encode.Event.Pos = null,
    mods: input.Mods = .{},
    gesture: terminal.SelectionGesture = .init,
    local_left_pressed: bool = false,
    reported_pressed: std.StaticBitSet(input.MouseButton.max + 1) = .initEmpty(),
    last_reported_cell: ?terminal.point.Coordinate = null,
    pressure_stage: input.MousePressureStage = .none,
    pending_scroll_x: f64 = 0,
    pending_scroll_y: f64 = 0,
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

pub const SelectionEndpoint = enum(c_int) {
    start = 0,
    end = 1,
};

pub const CellGeometry = extern struct {
    x_px: f64 = 0,
    y_px: f64 = 0,
    width_px: u32 = 0,
    height_px: u32 = 0,
    visible: bool = false,
};

pub const SelectionSnapshot = extern struct {
    start: CellGeometry = .{},
    end: CellGeometry = .{},
    active: bool = false,
    rectangle: bool = false,
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
    prepared_layout: *rendererpkg.Runtime.PreparedLayout,
    event_sink: rendererpkg.EventSink,
    write_sink: ?WriteSink = null,
    macos_option_as_alt: input.OptionAsAlt = .false,
    crash_context: ?crash.sentry.ThreadState,
    visible: bool = true,
    focused: bool = true,
};

pub const UpdateConfigOptions = struct {
    config: *const configpkg.Config,
    prepared_layout: *rendererpkg.Runtime.PreparedLayout,
    macos_option_as_alt: input.OptionAsAlt,
};

/// Initialize in stable caller-owned storage and start the renderer thread.
/// The renderer surface, font-grid set, and event-sink context are borrowed and
/// must outlive this surface. Config and derived font config are consumed only
/// during this call. The prepared layout is transferred on success and remains
/// caller-owned on failure. The retained Shared terminal and its mutex remain
/// valid through deinit.
pub fn init(self: *TerminalSurface, opts: Options) !font.Metrics {
    var interaction_config = try InteractionConfig.init(opts.alloc, opts.config);
    errdefer interaction_config.deinit(opts.alloc);

    const shared = opts.shared.retain();
    errdefer shared.release();

    try shared.claimRenderer();
    errdefer shared.releaseRenderer();

    shared.mutex.lock();
    terminal_config.applyColorDefaults(
        &shared.terminal,
        terminal_config.colorDefaults(opts.config),
    );
    shared.mutex.unlock();

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
        .interaction_config = interaction_config,
        .interaction = .{},
        .explicit_padding = opts.prepared_layout.explicit_padding,
        .padding_balance = opts.prepared_layout.padding_balance,
        .visible = .init(opts.visible),
        .focused = opts.focused,
    };

    const metrics = try self.runtime.init(.{
        .alloc = opts.alloc,
        .config = opts.config,
        .rt_surface = opts.rt_surface,
        .terminal = &shared.terminal,
        .mutex = &shared.mutex,
        .prepared_layout = opts.prepared_layout,
        .size = &self.size,
        .event_sink = opts.event_sink,
        .crash_context = opts.crash_context,
        .visible = opts.visible,
        .focused = opts.focused,
    });
    errdefer self.runtime.deinit();

    try self.runtime.start();
    return metrics;
}

/// Re-snapshot application configuration without replacing terminal, renderer,
/// platform surface, or interaction state. All fallible derivation completes
/// before messages or canonical terminal state are committed.
pub fn updateConfig(
    self: *TerminalSurface,
    opts: UpdateConfigOptions,
) !void {
    var interaction_config = try InteractionConfig.init(self.alloc, opts.config);
    errdefer interaction_config.deinit(self.alloc);

    const renderer_message = try rendererpkg.Message.initChangeConfig(
        self.alloc,
        opts.config,
    );

    const prepared = opts.prepared_layout.*;
    const defaults = terminal_config.colorDefaults(opts.config);

    self.shared.mutex.lock();
    terminal_config.applyColorDefaults(&self.shared.terminal, defaults);
    self.shared.mutex.unlock();

    var old_interaction_config = self.interaction_config;
    self.interaction_config = interaction_config;
    self.macos_option_as_alt = opts.macos_option_as_alt;
    self.vt_kam_allowed = opts.config.@"vt-kam-allowed";
    self.selection_clear_on_typing = opts.config.@"selection-clear-on-typing";
    self.scroll_to_bottom_on_keystroke = opts.config.@"scroll-to-bottom".keystroke;
    self.mouse_reporting = opts.config.@"mouse-reporting";
    self.explicit_padding = prepared.explicit_padding;
    self.padding_balance = prepared.padding_balance;
    self.size = prepared.size;
    old_interaction_config.deinit(self.alloc);

    self.runtime.setFontGrid(prepared.font_grid_key, prepared.font_grid);
    opts.prepared_layout.owned = false;
    _ = self.runtime.thread.mailbox.push(renderer_message, .{ .forever = {} });
    _ = self.runtime.thread.mailbox.push(.{ .resize = prepared.size }, .{ .forever = {} });
    self.runtime.thread.wakeup.notify() catch |err| {
        // The update is fully admitted at this point. Match the main Surface
        // config path: a lost notification is diagnostic, not a false report
        // that callers could interpret as a rolled-back config change.
        log.warn("failed to notify renderer of config change err={}", .{err});
    };
}

pub fn deinit(self: *TerminalSurface) void {
    self.runtime.stop();
    self.deinitInteraction();
    self.runtime.deinit();
    self.shared.releaseRenderer();
    self.shared.release();
    self.interaction_config.deinit(self.alloc);
}

fn deinitInteraction(self: *TerminalSurface) void {
    self.shared.mutex.lock();
    self.interaction.gesture.deinit(&self.shared.terminal);
    self.interaction = .{};
    self.shared.mutex.unlock();
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

/// Snapshot the canonical selection in the current presentation viewport.
pub fn selectionSnapshot(self: *TerminalSurface) SelectionSnapshot {
    self.shared.mutex.lock();
    defer self.shared.mutex.unlock();
    return self.selectionSnapshotLocked();
}

/// Snapshot the active screen's logical cursor-cell geometry in the current
/// presentation viewport.
pub fn cursorGeometry(self: *TerminalSurface) CellGeometry {
    self.shared.mutex.lock();
    defer self.shared.mutex.unlock();
    return self.cursorGeometryLocked();
}

/// Select the canonical Ghostty word at a presentation point. An unwritten
/// cell clears the selection. The committed snapshot is filled before a wake
/// can fail.
pub fn selectWord(
    self: *TerminalSurface,
    x: f64,
    y: f64,
    out: *SelectionSnapshot,
) !void {
    const changed = changed: {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();

        const pin = self.selectionPinLocked(x, y) catch |err| {
            out.* = self.selectionSnapshotLocked();
            return err;
        };
        const screen = self.shared.terminal.screens.active;
        const selection = if (pin) |value|
            screen.selectWord(
                value,
                self.interaction_config.word_chars,
            )
        else
            null;
        const did_change = self.applySelectionLocked(selection) catch |err| {
            out.* = self.selectionSnapshotLocked();
            return err;
        };
        out.* = self.selectionSnapshotLocked();
        break :changed did_change;
    };

    if (changed) try self.terminalChanged();
}

/// Select a configured or OSC 8 link at a presentation point. A successful
/// no-match leaves the canonical selection untouched. `out_target` is owned by
/// this surface only for OSC 8, whose target can differ from visible text.
pub fn selectLink(
    self: *TerminalSurface,
    x: f64,
    y: f64,
    out: *SelectionSnapshot,
    out_matched: *bool,
    out_target: *?[:0]const u8,
) !void {
    out_matched.* = false;
    out_target.* = null;
    const changed = changed: {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();

        const pin = self.selectionPinLocked(x, y) catch |err| {
            out.* = self.selectionSnapshotLocked();
            return err;
        } orelse {
            out.* = self.selectionSnapshotLocked();
            break :changed false;
        };
        const screen = self.shared.terminal.screens.active;
        var selection: terminal.Selection = undefined;
        var target: ?[:0]const u8 = null;
        if (screen.selectHyperlink(pin)) |hyperlink| {
            selection = hyperlink.selection;
            target = self.alloc.dupeZ(u8, hyperlink.uri) catch |err| {
                out.* = self.selectionSnapshotLocked();
                return err;
            };
        } else if (self.interaction_config.links.matchAtPin(
            self.alloc,
            screen,
            pin,
            null,
        ) catch |err| {
            out.* = self.selectionSnapshotLocked();
            return err;
        }) |configured| {
            selection = configured.selection;
        } else {
            out.* = self.selectionSnapshotLocked();
            break :changed false;
        }
        errdefer if (target) |value| self.alloc.free(value);

        const changed = self.applySelectionLocked(selection) catch |err| {
            out.* = self.selectionSnapshotLocked();
            return err;
        };
        out.* = self.selectionSnapshotLocked();
        out_matched.* = true;
        out_target.* = target;
        break :changed changed;
    };

    if (changed) self.terminalChanged() catch |err| {
        if (out_target.*) |target| self.alloc.free(target);
        out_target.* = null;
        out_matched.* = false;
        return err;
    };
}

/// Move one role-stable canonical endpoint to a presentation point. Crossing
/// the other endpoint preserves the endpoint roles and selection direction.
pub fn setSelectionEndpoint(
    self: *TerminalSurface,
    endpoint: SelectionEndpoint,
    x: f64,
    y: f64,
    out: *SelectionSnapshot,
) !void {
    const changed = changed: {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();

        const screen = self.shared.terminal.screens.active;
        var selection = screen.selection orelse {
            out.* = self.selectionSnapshotLocked();
            return error.InvalidInput;
        };
        const pin = (self.selectionPinLocked(x, y) catch |err| {
            out.* = self.selectionSnapshotLocked();
            return err;
        }) orelse {
            out.* = self.selectionSnapshotLocked();
            return error.InvalidInput;
        };
        const target = switch (endpoint) {
            .start => selection.startPtr(),
            .end => selection.endPtr(),
        };
        if (target.*.eql(pin)) {
            out.* = self.selectionSnapshotLocked();
            break :changed false;
        }

        target.* = pin;
        // The selection is already tracked. Reinstalling the same tracked
        // pins marks selection damage without allocating replacement pins.
        screen.select(selection) catch unreachable;
        out.* = self.selectionSnapshotLocked();
        break :changed true;
    };

    if (changed) try self.terminalChanged();
}

/// Clear the canonical selection. This is idempotent.
pub fn clearSelection(
    self: *TerminalSurface,
    out: *SelectionSnapshot,
) !void {
    const changed = changed: {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();
        const did_change = self.clearSelectionLocked();
        out.* = self.selectionSnapshotLocked();
        break :changed did_change;
    };

    if (changed) try self.terminalChanged();
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

const PointerSnapshot = struct {
    event: input.mouse_encode.Event,
    opts: input.mouse_encode.Options,
    last_cell: ?terminal.point.Coordinate,
};

/// Update the interaction pointer and modifiers, continue a local
/// left-selection drag, or report one remote motion event. The host serializes
/// this with the other presentation operations.
pub fn pointerPosition(
    self: *TerminalSurface,
    x: f64,
    y: f64,
    mods: input.Mods,
) InputResult {
    if (!self.validPointerCoordinates(x, y)) {
        return .invalid_input;
    }

    var changed = false;
    var snapshot: ?PointerSnapshot = null;
    self.shared.mutex.lock();
    const term = &self.shared.terminal;
    const pos: input.mouse_encode.Event.Pos = .{
        .x = @floatCast(x),
        .y = @floatCast(y),
    };
    self.interaction.pointer = pos;
    self.interaction.mods = mods.binding();
    if (self.remoteMouseLocked()) {
        self.cancelLocalGestureLocked();
        var opts: input.mouse_encode.Options = .fromTerminal(term, self.size);
        opts.any_button_pressed = self.interaction.reported_pressed.count() != 0;
        snapshot = .{
            .event = .{
                .action = .motion,
                .button = self.firstReportedButtonLocked(),
                .mods = mods,
                .pos = pos,
            },
            .opts = opts,
            .last_cell = self.interaction.last_reported_cell,
        };
    } else {
        self.clearRemoteStateLocked();
        if (self.interaction.local_left_pressed) {
            if (self.pointerPinLocked(x, y)) |pin| {
                if (self.interaction.gesture.drag(term, .{
                    .pin = pin,
                    .xpos = x,
                    .ypos = y,
                    .rectangle = SurfaceMouse.isRectangleSelectState(mods),
                    .word_boundary_codepoints = self.interaction_config.word_chars,
                    .geometry = .{
                        .columns = self.size.grid().columns,
                        .cell_width = self.size.cell.width,
                        .padding_left = self.size.padding.left,
                        .screen_height = self.size.screen.height,
                    },
                })) |selection| {
                    changed = self.applySelectionLocked(selection) catch {
                        self.cancelLocalGestureLocked();
                        self.shared.mutex.unlock();
                        if (changed) self.committedStateChanged();
                        return .out_of_memory;
                    } or changed;
                }
            }
        }
    }
    self.shared.mutex.unlock();

    if (changed) self.committedStateChanged();
    var report = snapshot orelse return .consumed_no_output;
    const admission = self.admitMouseReport(&report);
    if (admission.result == .sent) {
        self.shared.mutex.lock();
        self.interaction.last_reported_cell = admission.last_cell;
        self.shared.mutex.unlock();
    }
    return admission.result;
}

/// Submit a mouse button transition. Remote transitions are committed only
/// after the complete encoding is accepted. Local interaction accepts the left
/// button only and delegates selection semantics to SelectionGesture.
pub fn mouseButton(
    self: *TerminalSurface,
    state: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) InputResult {
    if (button == .unknown or button == .ten or button == .eleven) {
        return .not_accepted;
    }
    var changed = false;
    var snapshot: ?PointerSnapshot = null;
    var reported_pressed = std.StaticBitSet(input.MouseButton.max + 1).initEmpty();

    self.shared.mutex.lock();
    const term = &self.shared.terminal;
    self.interaction.mods = mods.binding();
    if (self.remoteMouseLocked()) {
        self.cancelLocalGestureLocked();
        const pos = self.interaction.pointer orelse {
            return self.finishInteractionLocked(changed, .not_accepted);
        };
        reported_pressed = self.interaction.reported_pressed;
        const index: usize = @intCast(@intFromEnum(button));
        switch (state) {
            .press => reported_pressed.set(index),
            .release => reported_pressed.unset(index),
        }
        var opts: input.mouse_encode.Options = .fromTerminal(term, self.size);
        opts.any_button_pressed = reported_pressed.count() != 0;
        snapshot = .{
            .event = .{
                .action = switch (state) {
                    .press => .press,
                    .release => .release,
                },
                .button = button,
                .mods = mods,
                .pos = pos,
            },
            .opts = opts,
            .last_cell = self.interaction.last_reported_cell,
        };
    } else {
        self.clearRemoteStateLocked();
        if (button != .left) {
            return self.finishInteractionLocked(changed, .not_accepted);
        }

        switch (state) {
            .press => {
                if (self.interaction.local_left_pressed) {
                    return self.finishInteractionLocked(
                        changed,
                        .consumed_no_output,
                    );
                }
                const pointer = self.interaction.pointer orelse {
                    return self.finishInteractionLocked(
                        changed,
                        .not_accepted,
                    );
                };
                const pin = self.pointerPinLocked(pointer.x, pointer.y) orelse {
                    return self.finishInteractionLocked(
                        changed,
                        .not_accepted,
                    );
                };
                const now = std.time.Instant.now() catch |err| now: {
                    log.warn(
                        "failed to read click time; multi-click disabled err={}",
                        .{err},
                    );
                    break :now null;
                };
                const selection = self.interaction.gesture.press(term, .{
                    .time = now,
                    .pin = pin,
                    .xpos = pointer.x,
                    .ypos = pointer.y,
                    .max_distance = @floatFromInt(self.size.cell.width),
                    .repeat_interval = self.interaction_config.click_repeat_interval,
                    .word_boundary_codepoints = self.interaction_config.word_chars,
                }) catch {
                    return self.finishInteractionLocked(
                        changed,
                        .out_of_memory,
                    );
                };
                changed = (self.applySelectionLocked(selection) catch {
                    self.interaction.gesture.reset(term);
                    return self.finishInteractionLocked(
                        changed,
                        .out_of_memory,
                    );
                }) or changed;
                self.interaction.local_left_pressed = true;
            },
            .release => {
                if (!self.interaction.local_left_pressed) {
                    return self.finishInteractionLocked(
                        changed,
                        .consumed_no_output,
                    );
                }
                const pin = if (self.interaction.pointer) |pointer|
                    self.pointerPinLocked(pointer.x, pointer.y)
                else
                    null;
                self.interaction.gesture.release(term, .{ .pin = pin });
                self.interaction.local_left_pressed = false;
            },
        }
    }
    self.shared.mutex.unlock();

    var report = snapshot orelse {
        if (changed) self.committedStateChanged();
        return .consumed_no_output;
    };
    const admission = self.admitMouseReport(&report);
    if (admission.result == .sent or
        admission.result == .consumed_no_output)
    {
        self.shared.mutex.lock();
        if (admission.result == .sent) {
            self.interaction.last_reported_cell = admission.last_cell;
        }
        self.interaction.reported_pressed = reported_pressed;
        changed = self.clearSelectionLocked() or changed;
        self.shared.mutex.unlock();
    }
    if (changed) self.committedStateChanged();
    return admission.result;
}

fn finishInteractionLocked(
    self: *TerminalSurface,
    changed: bool,
    result: InputResult,
) InputResult {
    self.shared.mutex.unlock();
    if (changed) self.committedStateChanged();
    return result;
}

/// Handle local pressure selection. Pressure is never reported remotely.
pub fn mousePressure(
    self: *TerminalSurface,
    stage: input.MousePressureStage,
    pressure: f64,
) InputResult {
    if (!std.math.isFinite(pressure)) return .invalid_input;

    var changed = false;
    self.shared.mutex.lock();
    const term = &self.shared.terminal;
    if (stage == .none) {
        self.interaction.pressure_stage = .none;
    } else if (self.remoteMouseLocked()) {
        self.cancelLocalGestureLocked();
        self.interaction.pressure_stage = stage;
    } else if (stage != self.interaction.pressure_stage) {
        self.interaction.pressure_stage = stage;
        if (stage == .deep and self.interaction.local_left_pressed) {
            if (self.interaction.gesture.deepPress(term, .{
                .word_boundary_codepoints = self.interaction_config.word_chars,
            })) |selection| {
                changed = self.applySelectionLocked(selection) catch {
                    self.interaction.local_left_pressed = false;
                    self.shared.mutex.unlock();
                    return .out_of_memory;
                };
            }
        }
    }
    self.shared.mutex.unlock();

    if (changed) self.committedStateChanged();
    return .consumed_no_output;
}

fn validPointerCoordinates(
    self: *const TerminalSurface,
    x: f64,
    y: f64,
) bool {
    return validPointerCoordinate(x, self.size.padding.left) and
        validPointerCoordinate(y, self.size.padding.top);
}

fn validPointerCoordinate(value: f64, padding: u32) bool {
    if (!std.math.isFinite(value)) return false;
    // 2^31 - 128 is the largest f32 below the positive i32 boundary.
    // Validate the rounded terminal-space value too because the mouse encoder
    // subtracts padding before converting SGR-pixel coordinates to i32.
    const max_surface_f32: f64 = 2_147_483_520;
    if (value < -max_surface_f32 or value > max_surface_f32) return false;
    const narrowed: f32 = @floatCast(value);
    const terminal_value = @as(f64, @floatCast(narrowed)) -
        @as(f64, @floatFromInt(padding));
    const rounded = @round(terminal_value);
    return rounded >= @as(f64, @floatFromInt(std.math.minInt(i32))) and
        rounded <= @as(f64, @floatFromInt(std.math.maxInt(i32)));
}

fn rendererPointLocked(
    self: *const TerminalSurface,
    x: f64,
    y: f64,
) ?terminal.point.Coordinate {
    if (x < 0 or y < 0 or
        x > @as(f64, @floatFromInt(self.size.screen.width)) or
        y > @as(f64, @floatFromInt(self.size.screen.height))) return null;
    const grid = (rendererpkg.Coordinate{ .surface = .{ .x = x, .y = y } })
        .convert(.grid, self.size).grid;
    if (self.runtime.state.scroll_cell_offset == 0) {
        return .{ .x = grid.x, .y = grid.y };
    }

    const cell_height: f64 = @floatFromInt(self.size.cell.height);
    const grid_height = @as(f64, @floatFromInt(self.size.grid().rows)) *
        cell_height;
    const terminal_y = @min(
        grid_height,
        @max(
            0,
            y - @as(f64, @floatFromInt(self.size.padding.top)),
        ),
    );
    const row_float = terminal_y / cell_height +
        self.runtime.state.scroll_cell_offset;
    if (row_float > @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
        return null;
    }
    return .{ .x = grid.x, .y = @intFromFloat(@floor(row_float)) };
}

/// Resolve presentation pixels through the fractional viewport offset. A
/// positive offset exposes the next terminal row at the bottom; PageList is the
/// authority on whether that row exists.
fn pointerPinLocked(
    self: *const TerminalSurface,
    x_value: anytype,
    y_value: anytype,
) ?terminal.Pin {
    const x: f64 = @floatCast(x_value);
    const y: f64 = @floatCast(y_value);
    const viewport = self.rendererPointLocked(x, y) orelse return null;
    return self.shared.terminal.screens.active.pages.pin(.{
        .viewport = viewport,
    });
}

fn selectionPinLocked(
    self: *const TerminalSurface,
    x: f64,
    y: f64,
) error{InvalidInput}!?terminal.Pin {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        x < 0 or y < 0 or
        x >= @as(f64, @floatFromInt(self.size.screen.width)) or
        y >= @as(f64, @floatFromInt(self.size.screen.height)))
    {
        return error.InvalidInput;
    }
    return self.pointerPinLocked(x, y);
}

fn selectionSnapshotLocked(self: *const TerminalSurface) SelectionSnapshot {
    const screen = self.shared.terminal.screens.active;
    const selection = screen.selection orelse return .{};
    return .{
        .start = self.cellGeometryLocked(selection.start()),
        .end = self.cellGeometryLocked(selection.end()),
        .active = true,
        .rectangle = selection.rectangle,
    };
}

fn cursorGeometryLocked(self: *const TerminalSurface) CellGeometry {
    const screen = self.shared.terminal.screens.active;
    const cursor = screen.cursor;
    const scrollbar = screen.pages.scrollbar();
    const active_top = scrollbar.total - scrollbar.len;
    const cursor_row = std.math.add(
        usize,
        active_top,
        cursor.y,
    ) catch return .{};
    if (cursor_row < scrollbar.offset) return .{};
    const viewport_y = cursor_row - scrollbar.offset;

    return self.cellGeometryAtViewportCoordinateLocked(.{
        .x = cursor.x,
        .y = std.math.cast(u32, viewport_y) orelse return .{},
    });
}

fn cellGeometryLocked(
    self: *const TerminalSurface,
    pin: terminal.Pin,
) CellGeometry {
    const point = self.shared.terminal.screens.active.pages.pointFromPin(
        .viewport,
        pin,
    ) orelse return .{};
    return self.cellGeometryAtViewportCoordinateLocked(point.viewport);
}

fn cellGeometryAtViewportCoordinateLocked(
    self: *const TerminalSurface,
    coord: terminal.point.Coordinate,
) CellGeometry {
    const cell_width: f64 = @floatFromInt(self.size.cell.width);
    const cell_height: f64 = @floatFromInt(self.size.cell.height);
    const grid = self.size.grid();
    const left: f64 = @floatFromInt(self.size.padding.left);
    const top: f64 = @floatFromInt(self.size.padding.top);
    const right = left + @as(f64, @floatFromInt(grid.columns)) * cell_width;
    const bottom = top + @as(f64, @floatFromInt(grid.rows)) * cell_height;
    const x = left + @as(f64, @floatFromInt(coord.x)) * cell_width;
    const y = top +
        (@as(f64, @floatFromInt(coord.y)) -
            self.runtime.state.scroll_cell_offset) * cell_height;
    if (x >= right or x + cell_width <= left or
        y >= bottom or y + cell_height <= top) return .{};

    return .{
        .x_px = x,
        .y_px = y,
        .width_px = self.size.cell.width,
        .height_px = self.size.cell.height,
        .visible = true,
    };
}

fn applySelectionLocked(
    self: *TerminalSurface,
    selection: ?terminal.Selection,
) std.mem.Allocator.Error!bool {
    const screen = self.shared.terminal.screens.active;
    if (screen.selection) |current| {
        if (selection) |next| {
            if (current.eql(next)) return false;
        }
    } else if (selection == null) return false;
    try screen.select(selection);
    return true;
}

fn remoteMouseLocked(self: *const TerminalSurface) bool {
    return self.mouse_reporting and
        self.shared.terminal.flags.mouse_event != .none;
}

fn cancelLocalGestureLocked(self: *TerminalSurface) void {
    if (self.interaction.local_left_pressed or
        self.interaction.gesture.left_click_count != 0)
    {
        self.interaction.gesture.reset(&self.shared.terminal);
        self.interaction.local_left_pressed = false;
    }
}

fn clearRemoteStateLocked(self: *TerminalSurface) void {
    self.interaction.reported_pressed = .initEmpty();
    self.interaction.last_reported_cell = null;
}

fn firstReportedButtonLocked(
    self: *const TerminalSurface,
) ?input.MouseButton {
    const index = self.interaction.reported_pressed.findFirstSet() orelse
        return null;
    return @enumFromInt(index);
}

const MouseAdmission = struct {
    result: InputResult,
    last_cell: ?terminal.point.Coordinate,
};

fn admitMouseReport(
    self: *TerminalSurface,
    snapshot: *PointerSnapshot,
) MouseAdmission {
    const sink = self.write_sink orelse return .{
        .result = .unavailable,
        .last_cell = snapshot.last_cell,
    };
    var candidate_last = snapshot.last_cell;
    snapshot.opts.last_cell = &candidate_last;

    var stack: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&stack);
    input.mouse_encode.encode(
        &writer,
        snapshot.event,
        snapshot.opts,
    ) catch return .{
        .result = .not_accepted,
        .last_cell = snapshot.last_cell,
    };
    const encoded = writer.buffered();
    if (encoded.len == 0) return .{
        .result = .consumed_no_output,
        .last_cell = snapshot.last_cell,
    };
    if (!sink.write(encoded)) return .{
        .result = .not_accepted,
        .last_cell = snapshot.last_cell,
    };
    return .{ .result = .sent, .last_cell = candidate_last };
}

fn committedStateChanged(self: *TerminalSurface) void {
    self.terminalChanged() catch |err| {
        // The canonical mutation has already happened. Reporting failure would
        // invite the host to replay input or a relative interaction.
        log.err("failed to wake renderer after committed state change err={}", .{err});
    };
}

fn clearSelectionLocked(self: *TerminalSurface) bool {
    const screen = self.shared.terminal.screens.active;
    if (screen.selection != null) {
        screen.clearSelection();
        return true;
    }
    return false;
}

const ScrollAmount = struct {
    delta: isize = 0,
    pending: f64,

    fn magnitude(self: ScrollAmount) usize {
        return @abs(self.delta);
    }
};

const ScrollSnapshot = struct {
    route: ScrollRoute,
    x: ScrollAmount,
    y: ScrollAmount,
    pointer: ?input.mouse_encode.Event.Pos,
    mods: input.Mods,
    opts: input.mouse_encode.Options,
    last_cell: ?terminal.point.Coordinate,
    any_button_pressed: bool,
    cursor_keys: bool,
};

/// Normalize and route one host scroll event. Remote wheel reports and
/// alternate-screen cursor sequences are each admitted as one callback payload.
pub fn scroll(
    self: *TerminalSurface,
    xoff: f64,
    yoff: f64,
    scroll_mods: input.ScrollMods,
) InputResult {
    if (!std.math.isFinite(xoff) or !std.math.isFinite(yoff)) {
        return .invalid_input;
    }

    var changed = false;
    var snapshot: ScrollSnapshot = undefined;
    self.shared.mutex.lock();
    const term = &self.shared.terminal;
    const x = normalizeScrollAxis(
        xoff,
        self.interaction.pending_scroll_x,
        self.size.cell.width,
        if (scroll_mods.precision) 1 else 0,
        scroll_mods.precision,
    ) catch {
        self.shared.mutex.unlock();
        return .invalid_input;
    };
    const y_multiplier = if (scroll_mods.precision)
        self.interaction_config.scroll_multiplier.precision
    else
        self.interaction_config.scroll_multiplier.discrete;
    const normalized_yoff = if (comptime builtin.target.os.tag.isDarwin())
        if (!scroll_mods.precision and yoff != 0)
            if (yoff > 0) @max(yoff, 1) else @min(yoff, -1)
        else
            yoff
    else
        yoff;
    const y = normalizeScrollAxis(
        normalized_yoff,
        self.interaction.pending_scroll_y,
        self.size.cell.height,
        y_multiplier,
        scroll_mods.precision,
    ) catch {
        self.shared.mutex.unlock();
        return .invalid_input;
    };
    const interaction_state = self.normalizeAndSnapshotInteractionLocked();

    snapshot = .{
        .route = interaction_state.route,
        .x = x,
        .y = y,
        .pointer = self.interaction.pointer,
        .mods = self.interaction.mods,
        .opts = .fromTerminal(term, self.size),
        .last_cell = self.interaction.last_reported_cell,
        .any_button_pressed = self.interaction.reported_pressed.count() != 0,
        .cursor_keys = term.modes.get(.cursor_keys),
    };

    switch (snapshot.route) {
        .viewport => {
            self.clearRemoteStateLocked();
            self.interaction.pending_scroll_x = x.pending;
            self.interaction.pending_scroll_y = y.pending;
            if (y.delta != 0) {
                const screen = term.screens.active;
                const scrollbar = screen.pages.scrollbar();
                const max_offset = scrollbarMaxRow(.{
                    .total = scrollbar.total,
                    .offset = scrollbar.offset,
                    .len = scrollbar.len,
                    .cell_offset = 0,
                });
                const terminal_delta = -y.delta;
                if ((terminal_delta < 0 and scrollbar.offset > 0) or
                    (terminal_delta > 0 and scrollbar.offset < max_offset))
                {
                    term.scrollViewport(.{ .delta = terminal_delta });
                    changed = true;
                }
                if (self.runtime.state.scroll_cell_offset != 0) {
                    self.runtime.state.scroll_cell_offset = 0;
                    changed = true;
                }
            }
        },
        .alternate_screen_cursor => self.clearRemoteStateLocked(),
        .remote_mouse => self.cancelLocalGestureLocked(),
    }

    if (snapshot.route != .viewport and
        snapshot.x.delta == 0 and
        snapshot.y.delta == 0)
    {
        self.interaction.pending_scroll_x = snapshot.x.pending;
        self.interaction.pending_scroll_y = snapshot.y.pending;
        self.shared.mutex.unlock();
        return .consumed_no_output;
    }
    self.shared.mutex.unlock();

    if (snapshot.route == .viewport) {
        if (changed) self.committedStateChanged();
        return .consumed_no_output;
    }
    const admission: MouseAdmission = switch (snapshot.route) {
        .alternate_screen_cursor => .{
            .result = self.admitAlternateScroll(snapshot),
            .last_cell = snapshot.last_cell,
        },
        .remote_mouse => self.admitRemoteScroll(&snapshot),
        .viewport => unreachable,
    };
    if (admission.result == .sent or
        admission.result == .consumed_no_output)
    {
        var selection_changed = false;
        self.shared.mutex.lock();
        self.interaction.pending_scroll_x = snapshot.x.pending;
        self.interaction.pending_scroll_y = snapshot.y.pending;
        if (snapshot.route == .remote_mouse and admission.result == .sent) {
            self.interaction.last_reported_cell = admission.last_cell;
        }
        if (snapshot.route == .remote_mouse or snapshot.y.delta != 0) {
            selection_changed = self.clearSelectionLocked();
        }
        self.shared.mutex.unlock();
        if (selection_changed) self.committedStateChanged();
    }
    return admission.result;
}

fn normalizeScrollAxis(
    offset: f64,
    pending: f64,
    cell_size_int: u32,
    multiplier: f64,
    precision: bool,
) error{InvalidInput}!ScrollAmount {
    if (offset == 0) return .{ .pending = pending };
    const cell_size: f64 = @floatFromInt(cell_size_int);
    if (!precision and multiplier == 0) {
        const amount = @round(offset);
        const min: f64 = @floatFromInt(std.math.minInt(isize));
        const max_exclusive = -min;
        if (amount <= min or amount >= max_exclusive) {
            return error.InvalidInput;
        }
        return .{ .delta = @intFromFloat(amount), .pending = pending };
    }
    const adjusted = if (precision)
        offset * multiplier
    else
        offset * cell_size * multiplier;
    if (!std.math.isFinite(adjusted)) return error.InvalidInput;
    const total = pending + adjusted;
    if (!std.math.isFinite(total)) return error.InvalidInput;
    const amount = @trunc(total / cell_size);
    const min: f64 = @floatFromInt(std.math.minInt(isize));
    const max_exclusive = -min;
    if (amount <= min or amount >= max_exclusive) {
        return error.InvalidInput;
    }
    const delta: isize = @intFromFloat(amount);
    var remainder = total - amount * cell_size;
    if (remainder >= cell_size or remainder <= -cell_size) {
        remainder = @rem(total, cell_size);
    }
    std.debug.assert(@abs(remainder) < cell_size);
    return .{ .delta = delta, .pending = remainder };
}

const RepeatedChunk = struct {
    bytes: []const u8 = &.{},
    count: usize = 0,
};

fn admitAlternateScroll(
    self: *TerminalSurface,
    snapshot: ScrollSnapshot,
) InputResult {
    if (snapshot.y.delta == 0) return .consumed_no_output;
    const sequence: []const u8 = if (snapshot.cursor_keys)
        if (snapshot.y.delta > 0) "\x1bOA" else "\x1bOB"
    else if (snapshot.y.delta > 0)
        "\x1b[A"
    else
        "\x1b[B";
    return self.admitRepeated(.{
        .{ .bytes = sequence, .count = snapshot.y.magnitude() },
        .{},
    });
}

fn admitRemoteScroll(
    self: *TerminalSurface,
    snapshot: *ScrollSnapshot,
) MouseAdmission {
    const pos = snapshot.pointer orelse return .{
        .result = .not_accepted,
        .last_cell = snapshot.last_cell,
    };
    var candidate_last = snapshot.last_cell;
    snapshot.opts.last_cell = &candidate_last;
    snapshot.opts.any_button_pressed = snapshot.any_button_pressed;

    var y_buf: [64]u8 = undefined;
    var y_writer: std.Io.Writer = .fixed(&y_buf);
    if (snapshot.y.delta != 0) {
        input.mouse_encode.encode(&y_writer, .{
            .button = if (snapshot.y.delta > 0) .four else .five,
            .action = .press,
            .mods = snapshot.mods,
            .pos = pos,
        }, snapshot.opts) catch return .{
            .result = .not_accepted,
            .last_cell = snapshot.last_cell,
        };
    }

    var x_buf: [64]u8 = undefined;
    var x_writer: std.Io.Writer = .fixed(&x_buf);
    if (snapshot.x.delta != 0) {
        input.mouse_encode.encode(&x_writer, .{
            .button = if (snapshot.x.delta > 0) .six else .seven,
            .action = .press,
            .mods = snapshot.mods,
            .pos = pos,
        }, snapshot.opts) catch return .{
            .result = .not_accepted,
            .last_cell = snapshot.last_cell,
        };
    }

    const y_encoded = y_writer.buffered();
    const x_encoded = x_writer.buffered();
    if (y_encoded.len == 0 and x_encoded.len == 0) {
        return .{
            .result = .consumed_no_output,
            .last_cell = snapshot.last_cell,
        };
    }
    const result = self.admitRepeated(.{
        .{ .bytes = y_encoded, .count = snapshot.y.magnitude() },
        .{ .bytes = x_encoded, .count = snapshot.x.magnitude() },
    });
    return .{
        .result = result,
        .last_cell = if (result == .sent)
            candidate_last
        else
            snapshot.last_cell,
    };
}

fn admitRepeated(
    self: *TerminalSurface,
    chunks: [2]RepeatedChunk,
) InputResult {
    const sink = self.write_sink orelse return .unavailable;
    var len: usize = 0;
    for (chunks) |chunk| {
        const chunk_len = std.math.mul(usize, chunk.bytes.len, chunk.count) catch
            return .invalid_input;
        len = std.math.add(usize, len, chunk_len) catch return .invalid_input;
    }
    if (len == 0) return .consumed_no_output;

    var stack: [256]u8 = undefined;
    var heap: ?[]u8 = null;
    defer if (heap) |value| self.alloc.free(value);
    const encoded = if (len <= stack.len) stack[0..len] else encoded: {
        heap = self.alloc.alloc(u8, len) catch return .out_of_memory;
        break :encoded heap.?;
    };

    var offset: usize = 0;
    for (chunks) |chunk| {
        const chunk_len = chunk.bytes.len * chunk.count;
        fillRepeated(encoded[offset..][0..chunk_len], chunk.bytes);
        offset += chunk_len;
    }
    std.debug.assert(offset == encoded.len);
    return if (sink.write(encoded)) .sent else .not_accepted;
}

fn fillRepeated(dest: []u8, pattern: []const u8) void {
    if (dest.len == 0) return;
    std.debug.assert(pattern.len != 0 and dest.len % pattern.len == 0);
    @memcpy(dest[0..pattern.len], pattern);
    var filled = pattern.len;
    while (filled < dest.len) {
        const copy_len = @min(filled, dest.len - filled);
        @memcpy(dest[filled..][0..copy_len], dest[0..copy_len]);
        filled += copy_len;
    }
}

pub const SelectedTextError = error{ NoSelection, OutOfMemory };

/// Copy selected text while holding Shared.mutex. The caller owns the returned
/// sentinel slice and must release it through freeSelectedText.
pub fn selectedText(self: *TerminalSurface) SelectedTextError![:0]const u8 {
    self.shared.mutex.lock();
    defer self.shared.mutex.unlock();
    const screen = self.shared.terminal.screens.active;
    const selection = screen.selection orelse return error.NoSelection;
    return screen.selectionString(self.alloc, .{
        .sel = selection,
        .trim = false,
    });
}

pub fn freeSelectedText(
    self: *TerminalSurface,
    text: [:0]const u8,
) void {
    self.alloc.free(text);
}

/// Copy the active screen's currently visible viewport while holding
/// Shared.mutex. The snapshot does not change selection or scroll state. The
/// caller owns the returned bytes and must release them through
/// freeSelectedText.
pub fn viewportText(self: *TerminalSurface) ![:0]const u8 {
    self.shared.mutex.lock();
    defer self.shared.mutex.unlock();
    const text = try self.shared.terminal.plainString(self.alloc);
    defer self.alloc.free(text);
    return self.alloc.dupeZ(u8, text);
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

/// Synchronously admit already-committed text without key encoding or paste
/// transformation. This is for software-keyboard and IME commits that have no
/// physical key event. The caller's bytes are borrowed through the synchronous
/// sink and may contain arbitrary values, including NUL and control bytes.
pub fn committedText(
    self: *TerminalSurface,
    data: []const u8,
) InputResult {
    if (data.len == 0) return .consumed_no_output;

    self.shared.mutex.lock();
    const keyboard_disabled = self.vt_kam_allowed and
        self.shared.terminal.modes.get(.disable_keyboard);
    self.shared.mutex.unlock();
    if (keyboard_disabled) return .consumed_no_output;

    const sink = self.write_sink orelse return .unavailable;
    if (!sink.write(data)) return .not_accepted;

    self.acceptedTyping(false);
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

    self.acceptedTyping(key_value == .escape);
}

fn acceptedTyping(
    self: *TerminalSurface,
    force_selection_clear: bool,
) void {
    var changed = false;
    self.shared.mutex.lock();
    const screen = self.shared.terminal.screens.active;
    if ((self.selection_clear_on_typing or force_selection_clear) and
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

    if (changed) self.committedStateChanged();
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

    if (changed) self.committedStateChanged();
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
    data: [4096]u8 = undefined,
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
        .interaction_config = .{
            .word_chars = &.{},
            .click_repeat_interval = 500 * std.time.ns_per_ms,
            .scroll_multiplier = .{},
            .links = .{ .links = &.{} },
        },
        .interaction = .{},
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
    result.size = .{
        .screen = .{ .width = 100, .height = 60 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{},
    };
    result.interaction_config.word_chars = &[_]u21{ ' ', '\t' };
    return result;
}

fn testFeed(shared: *terminal.Shared, bytes: []const u8) void {
    shared.mutex.lock();
    defer shared.mutex.unlock();
    var stream = shared.terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
}

test "terminal surface config derivation failure does not partially commit" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer shared.release();

    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();
    try testing.expect(config.@"selection-word-chars".codepoints.len > 0);

    const before_background = shared.terminal.colors.background;
    const before_foreground = shared.terminal.colors.foreground;
    const before_cursor = shared.terminal.colors.cursor;
    const before_palette = shared.terminal.colors.palette;

    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    var surface = testSurface(failing.allocator(), shared, null);
    var prepared: rendererpkg.Runtime.PreparedLayout = undefined;
    try testing.expectError(error.OutOfMemory, surface.updateConfig(.{
        .config = &config,
        .prepared_layout = &prepared,
        .macos_option_as_alt = .false,
    }));

    try testing.expectEqualDeep(before_background, shared.terminal.colors.background);
    try testing.expectEqualDeep(before_foreground, shared.terminal.colors.foreground);
    try testing.expectEqualDeep(before_cursor, shared.terminal.colors.cursor);
    try testing.expectEqualDeep(before_palette, shared.terminal.colors.palette);
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

test "terminal surface committed text admission contract" {
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
    var unavailable = testSurface(testing.allocator, shared, null);
    try testing.expectEqual(
        InputResult.consumed_no_output,
        unavailable.committedText(""),
    );
    try testing.expectEqual(
        InputResult.unavailable,
        unavailable.committedText("text"),
    );
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection != null);
        try testing.expect(shared.terminal.screens.active.pages.viewport == .top);
    }

    const arbitrary = [_]u8{ 'a', 0, 0x03, 0xf0, 0x9f, 0x98, 0x80 };
    shared.mutex.lock();
    shared.terminal.modes.set(.bracketed_paste, true);
    shared.mutex.unlock();
    try testing.expectEqual(
        InputResult.sent,
        surface.committedText(&arbitrary),
    );
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqualSlices(u8, &arbitrary, sink.data[0..sink.len]);
    try testing.expect(sink.last_ptr.? == &arbitrary);
    try testing.expect(sink.lock_was_free);
    try testing.expectEqual(@as(usize, 0), tracking.allocations);

    try setTestSelectionAndViewport(shared);
    shared.mutex.lock();
    shared.terminal.modes.set(.disable_keyboard, true);
    surface.runtime.state.scroll_cell_offset = 0.5;
    shared.mutex.unlock();
    surface.vt_kam_allowed = true;
    surface.write_sink = null;
    sink.calls = 0;
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.committedText("blocked"),
    );
    try testing.expectEqual(@as(usize, 0), sink.calls);
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

    surface.vt_kam_allowed = false;
    try testing.expectEqual(
        InputResult.unavailable,
        surface.committedText("not gated"),
    );

    shared.mutex.lock();
    shared.terminal.modes.set(.disable_keyboard, false);
    shared.mutex.unlock();
    surface.write_sink = sink.writeSink();
    sink.accept = false;
    try testing.expectEqual(
        InputResult.not_accepted,
        surface.committedText("rejected"),
    );
    try testing.expectEqual(@as(usize, 1), sink.calls);
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

    // Committed Escape is text, not a physical Escape key, so it does not
    // receive the key operation's unconditional Escape selection behavior.
    sink.accept = true;
    surface.selection_clear_on_typing = false;
    surface.scroll_to_bottom_on_keystroke = false;
    try testing.expectEqual(InputResult.sent, surface.committedText("\x1b"));
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

    surface.selection_clear_on_typing = true;
    try testing.expectEqual(InputResult.sent, surface.committedText("clear"));
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection == null);
        try testing.expect(shared.terminal.screens.active.pages.viewport == .top);
        try testing.expectEqual(
            @as(f64, 0.5),
            surface.runtime.state.scroll_cell_offset,
        );
    }

    try setTestSelectionAndViewport(shared);
    shared.mutex.lock();
    surface.runtime.state.scroll_cell_offset = 0.5;
    shared.mutex.unlock();
    surface.selection_clear_on_typing = false;
    surface.scroll_to_bottom_on_keystroke = true;
    try testing.expectEqual(InputResult.sent, surface.committedText("scroll"));
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection != null);
        try testing.expect(shared.terminal.screens.active.pages.viewport == .active);
        try testing.expectEqual(
            @as(f64, 0),
            surface.runtime.state.scroll_cell_offset,
        );
    }

    const activity = testCompressionActivity(shared);
    try testing.expectEqual(InputResult.sent, surface.committedText("no-op"));
    try testing.expectEqual(activity, testCompressionActivity(shared));
    try testing.expectEqual(@as(usize, 0), tracking.allocations);
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

test "terminal surface selection snapshot follows viewport and active screen" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 100,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);
    surface.size = .{
        .screen = .{ .width = 104, .height = 64 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{ .top = 2, .bottom = 2, .left = 2, .right = 2 },
    };

    try testing.expect(!surface.selectionSnapshot().active);
    testFeed(shared, "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive");
    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        const screen = shared.terminal.screens.active;
        shared.terminal.scrollViewport(.top);
        try screen.select(terminal.Selection.init(
            screen.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            screen.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            true,
        ));
    }

    var snapshot = surface.selectionSnapshot();
    try testing.expect(snapshot.active);
    try testing.expect(snapshot.rectangle);
    try testing.expect(snapshot.start.visible);
    try testing.expectEqual(@as(f64, 2), snapshot.start.x_px);
    try testing.expectEqual(@as(f64, 2), snapshot.start.y_px);
    try testing.expect(!snapshot.end.visible);

    surface.runtime.state.scroll_cell_offset = 0.5;
    snapshot = surface.selectionSnapshot();
    try testing.expect(snapshot.start.visible);
    try testing.expectEqual(@as(f64, -8), snapshot.start.y_px);
    // The renderer materializes one row beyond the viewport for this peek.
    try testing.expect(snapshot.end.visible);
    try testing.expectEqual(@as(f64, 22), snapshot.end.x_px);
    try testing.expectEqual(@as(f64, 52), snapshot.end.y_px);

    testFeed(shared, "\x1b[?1049hALT");
    try testing.expect(!surface.selectionSnapshot().active);
    surface.runtime.state.scroll_cell_offset = 0;
    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        const screen = shared.terminal.screens.active;
        try screen.select(terminal.Selection.init(
            screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
            screen.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?,
            false,
        ));
    }
    snapshot = surface.selectionSnapshot();
    try testing.expect(snapshot.active);
    try testing.expectEqual(@as(f64, 2), snapshot.start.x_px);
    try testing.expectEqual(@as(f64, 22), snapshot.end.x_px);

    testFeed(shared, "\x1b[?1049l");
    snapshot = surface.selectionSnapshot();
    // Ghostty clears the destination screen's prior selection on a switch.
    try testing.expect(!snapshot.active);
}

test "terminal surface cursor geometry follows viewport and active screen" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 100,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);
    surface.size = .{
        .screen = .{ .width = 104, .height = 64 },
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{ .top = 2, .bottom = 2, .left = 2, .right = 2 },
    };

    var geometry = surface.cursorGeometry();
    try testing.expect(geometry.visible);
    try testing.expectEqual(@as(f64, 2), geometry.x_px);
    try testing.expectEqual(@as(f64, 2), geometry.y_px);
    try testing.expectEqual(@as(u32, 10), geometry.width_px);
    try testing.expectEqual(@as(u32, 20), geometry.height_px);

    testFeed(shared, "\x1b[3;4H");
    geometry = surface.cursorGeometry();
    try testing.expect(geometry.visible);
    try testing.expectEqual(@as(f64, 32), geometry.x_px);
    try testing.expectEqual(@as(f64, 42), geometry.y_px);

    surface.runtime.state.scroll_cell_offset = 0.5;
    geometry = surface.cursorGeometry();
    try testing.expect(geometry.visible);
    try testing.expectEqual(@as(f64, 32), geometry.y_px);

    surface.runtime.state.scroll_cell_offset = 0;
    testFeed(shared, "\r\nzero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive");
    shared.mutex.lock();
    shared.terminal.scrollViewport(.top);
    shared.mutex.unlock();
    geometry = surface.cursorGeometry();
    try testing.expect(!geometry.visible);
    try testing.expectEqualDeep(CellGeometry{}, geometry);

    testFeed(shared, "\x1b[2;3H");
    shared.mutex.lock();
    const scrollbar = shared.terminal.screens.active.pages.scrollbar();
    shared.terminal.scrollViewport(.{ .row = scrollbar.total - scrollbar.len - 1 });
    shared.mutex.unlock();
    geometry = surface.cursorGeometry();
    try testing.expect(geometry.visible);
    try testing.expectEqual(@as(f64, 22), geometry.x_px);
    try testing.expectEqual(@as(f64, 42), geometry.y_px);

    surface.runtime.state.scroll_cell_offset = 0.5;
    testFeed(shared, "\x1b[3;3H");
    geometry = surface.cursorGeometry();
    try testing.expect(geometry.visible);
    try testing.expectEqual(@as(f64, 22), geometry.x_px);
    try testing.expectEqual(@as(f64, 52), geometry.y_px);

    surface.runtime.state.scroll_cell_offset = 0;
    testFeed(shared, "\x1b[?1049h\x1b[2;3H");
    geometry = surface.cursorGeometry();
    try testing.expect(geometry.visible);
    try testing.expectEqual(@as(f64, 22), geometry.x_px);
    try testing.expectEqual(@as(f64, 22), geometry.y_px);
}

test "terminal surface word selection is local and refreshes after reflow" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 20,
        .rows = 3,
    });
    defer shared.release();
    var sink: TestSink = .{ .shared = shared };
    var surface = testSurface(testing.allocator, shared, sink.writeSink());
    surface.size.screen.width = 200;
    testFeed(shared, "hello\x1b[41m \x1b[0mworld.foo");
    shared.mutex.lock();
    shared.terminal.flags.mouse_event = .normal;
    shared.mutex.unlock();

    surface.interaction_config.word_chars = &[_]u21{ ' ', '\t', '.' };
    var snapshot: SelectionSnapshot = undefined;
    try surface.selectWord(75, 5, &snapshot);
    try testing.expect(snapshot.active);
    try testing.expectEqual(@as(f64, 60), snapshot.start.x_px);
    try testing.expectEqual(@as(f64, 100), snapshot.end.x_px);
    try testing.expectEqual(@as(usize, 0), sink.calls);

    surface.interaction_config.word_chars = &[_]u21{ ' ', '\t' };
    try surface.selectWord(75, 5, &snapshot);
    try testing.expectEqual(@as(f64, 140), snapshot.end.x_px);
    try surface.selectWord(55, 5, &snapshot);
    try testing.expect(snapshot.active);
    try testing.expectEqual(@as(f64, 50), snapshot.start.x_px);
    try testing.expectEqual(@as(f64, 50), snapshot.end.x_px);
    try testing.expectEqual(@as(usize, 0), sink.calls);

    try surface.selectWord(75, 5, &snapshot);
    try surface.selectWord(5, 45, &snapshot);
    try testing.expect(!snapshot.active);

    try surface.selectWord(75, 5, &snapshot);
    try testing.expectError(
        error.InvalidInput,
        surface.selectWord(std.math.nan(f64), 5, &snapshot),
    );
    try testing.expect(snapshot.active);
    try testing.expectError(
        error.InvalidInput,
        surface.selectWord(200, 5, &snapshot),
    );
    try testing.expect(snapshot.active);

    shared.mutex.lock();
    try shared.terminal.resize(testing.allocator, 10, 3);
    shared.mutex.unlock();
    snapshot = surface.selectionSnapshot();
    try testing.expect(snapshot.active);
    try testing.expectEqual(@as(f64, 40), snapshot.end.x_px);
    try testing.expectEqual(@as(f64, 20), snapshot.end.y_px);
    try testing.expectEqual(@as(usize, 0), sink.calls);
}

test "terminal surface link selection preserves no-match and target ownership" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 8,
        .rows = 3,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);
    surface.size.screen.width = 80;

    var links = try renderer_link.Set.fromConfig(testing.allocator, &.{.{
        .regex = "https://[^ ]+",
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = .{ .ctrl = true } },
    }});
    defer links.deinit(testing.allocator);
    surface.interaction_config.links = links;

    testFeed(shared, "xxhttps://example.com ");
    var snapshot: SelectionSnapshot = undefined;
    var matched: bool = undefined;
    var target: ?[:0]const u8 = undefined;
    try surface.selectLink(25, 25, &snapshot, &matched, &target);
    try testing.expect(matched);
    try testing.expect(snapshot.active);
    try testing.expect(target == null);
    const selected = try surface.selectedText();
    defer surface.freeSelectedText(selected);
    try testing.expectEqualStrings("https://example.com", selected);

    const before = snapshot;
    try surface.selectLink(65, 45, &snapshot, &matched, &target);
    try testing.expect(!matched);
    try testing.expectEqualDeep(before, snapshot);
    try testing.expect(target == null);

    const surface_alloc = surface.alloc;
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    surface.alloc = failing.allocator();
    try testing.expectError(
        error.OutOfMemory,
        surface.selectLink(25, 25, &snapshot, &matched, &target),
    );
    surface.alloc = surface_alloc;
    try testing.expectEqualDeep(before, snapshot);
    try testing.expect(!matched);
    try testing.expect(target == null);
}

test "terminal surface selects scheme-less loopback host:port spans" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 26,
        .rows = 3,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);
    surface.size.screen.width = 260;

    var links = try renderer_link.Set.fromConfig(testing.allocator, &.{.{
        .regex = loopback_host_port_regex,
        .action = .{ .open = {} },
        .highlight = .{ .always = {} },
    }});
    defer links.deinit(testing.allocator);
    surface.interaction_config.links = links;

    testFeed(shared, "srv on 127.0.0.1:8000, ok");
    var snapshot: SelectionSnapshot = undefined;
    var matched: bool = undefined;
    var target: ?[:0]const u8 = undefined;
    try surface.selectLink(125, 10, &snapshot, &matched, &target);
    try testing.expect(matched);
    try testing.expect(target == null);
    const selected = try surface.selectedText();
    defer surface.freeSelectedText(selected);
    try testing.expectEqualStrings("127.0.0.1:8000", selected);

    // Text after the span stays ordinary; the comma is not over-captured.
    try surface.selectLink(235, 10, &snapshot, &matched, &target);
    try testing.expect(!matched);
    try testing.expect(target == null);
}

test "terminal surface OSC 8 link selection takes precedence over configured links" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 5,
        .rows = 3,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);
    surface.size.screen.width = 50;

    var links = try renderer_link.Set.fromConfig(testing.allocator, &.{.{
        .regex = "https://[^ ]+",
        .action = .{ .open = {} },
        .highlight = .{ .always = {} },
    }});
    defer links.deinit(testing.allocator);
    surface.interaction_config.links = links;

    shared.mutex.lock();
    try shared.terminal.screens.active.startHyperlink(
        "https://example.com/target",
        null,
    );
    try shared.terminal.screens.active.testWriteString("https://a");
    shared.terminal.screens.active.endHyperlink();
    shared.mutex.unlock();

    var snapshot: SelectionSnapshot = undefined;
    var matched: bool = undefined;
    var target: ?[:0]const u8 = undefined;
    try surface.selectLink(5, 25, &snapshot, &matched, &target);
    try testing.expect(matched);
    try testing.expect(snapshot.active);
    try testing.expectEqual(@as(f64, 0), snapshot.start.x_px);
    try testing.expectEqual(@as(f64, 0), snapshot.start.y_px);
    try testing.expectEqual(@as(f64, 30), snapshot.end.x_px);
    try testing.expectEqual(@as(f64, 20), snapshot.end.y_px);
    try testing.expectEqualStrings(
        "https://example.com/target",
        target.?,
    );
    surface.freeSelectedText(target.?);

    const selected = try surface.selectedText();
    defer surface.freeSelectedText(selected);
    try testing.expectEqualStrings("https://a", selected);

    var cleared: SelectionSnapshot = undefined;
    try surface.clearSelection(&cleared);
    const xev = @import("../global.zig").xev;
    var closed_wakeup = try xev.Async.init();
    closed_wakeup.deinit();
    surface.runtime.thread.wakeup = closed_wakeup;
    surface.visible.store(true, .monotonic);
    var wake_failed = false;
    surface.selectLink(5, 25, &snapshot, &matched, &target) catch {
        wake_failed = true;
    };
    try testing.expect(wake_failed);
    try testing.expect(!matched);
    try testing.expect(snapshot.active);
    try testing.expect(target == null);
}

test "terminal surface selection endpoints preserve roles and allocation" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);
    testFeed(shared, "abc defgh");

    const initial_pins = shared.terminal.screens.active.pages.countTrackedPins();
    var snapshot: SelectionSnapshot = undefined;
    try surface.selectWord(15, 5, &snapshot);
    try testing.expectEqual(
        initial_pins + 2,
        shared.terminal.screens.active.pages.countTrackedPins(),
    );

    try surface.setSelectionEndpoint(.start, 55, 5, &snapshot);
    try testing.expectEqual(@as(f64, 50), snapshot.start.x_px);
    try testing.expectEqual(@as(f64, 20), snapshot.end.x_px);
    try testing.expectEqual(
        initial_pins + 2,
        shared.terminal.screens.active.pages.countTrackedPins(),
    );
    try surface.setSelectionEndpoint(.end, 75, 5, &snapshot);
    try testing.expectEqual(@as(f64, 50), snapshot.start.x_px);
    try testing.expectEqual(@as(f64, 70), snapshot.end.x_px);

    shared.mutex.lock();
    shared.terminal.screens.active.selection.?.rectangle = true;
    shared.terminal.screens.active.dirty.selection = false;
    shared.mutex.unlock();
    try surface.setSelectionEndpoint(.end, 75, 5, &snapshot);
    try testing.expect(snapshot.rectangle);
    shared.mutex.lock();
    try testing.expect(!shared.terminal.screens.active.dirty.selection);
    shared.mutex.unlock();

    try testing.expectError(
        error.InvalidInput,
        surface.setSelectionEndpoint(.end, 100, 5, &snapshot),
    );
    try testing.expect(snapshot.active);
    try testing.expectEqual(@as(f64, 70), snapshot.end.x_px);

    try surface.clearSelection(&snapshot);
    try testing.expect(!snapshot.active);
    try testing.expectEqual(
        initial_pins,
        shared.terminal.screens.active.pages.countTrackedPins(),
    );
    shared.mutex.lock();
    shared.terminal.screens.active.dirty.selection = false;
    shared.mutex.unlock();
    try surface.clearSelection(&snapshot);
    shared.mutex.lock();
    try testing.expect(!shared.terminal.screens.active.dirty.selection);
    shared.mutex.unlock();
    try testing.expectError(
        error.InvalidInput,
        surface.setSelectionEndpoint(.start, 5, 5, &snapshot),
    );
    try testing.expect(!snapshot.active);

    const xev = @import("../global.zig").xev;
    var closed_wakeup = try xev.Async.init();
    closed_wakeup.deinit();
    surface.runtime.thread.wakeup = closed_wakeup;
    surface.visible.store(true, .monotonic);
    var wake_failed = false;
    surface.selectWord(15, 5, &snapshot) catch {
        wake_failed = true;
    };
    try testing.expect(wake_failed);
    try testing.expect(snapshot.active);
    try testing.expect(shared.terminal.screens.active.selection != null);
}

test "terminal surface local pointer selection pressure and text ownership" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer shared.release();
    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    var surface = testSurface(tracking.allocator(), shared, null);

    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        var stream = shared.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice("hello world");
    }

    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.pointerPosition(5, 5, .{}),
    );
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.mouseButton(.press, .left, .{}),
    );
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.pointerPosition(25, 5, if (comptime builtin.target.os.tag.isDarwin())
            .{ .alt = true }
        else
            .{ .ctrl = true, .alt = true }),
    );
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        const selection = shared.terminal.screens.active.selection.?;
        try testing.expect(selection.rectangle);
    }
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.mouseButton(.release, .left, .{}),
    );

    const surface_alloc = surface.alloc;
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    surface.alloc = failing.allocator();
    try testing.expectError(error.OutOfMemory, surface.selectedText());
    surface.alloc = surface_alloc;

    const drag_text = try surface.selectedText();
    try testing.expect(drag_text.len != 0);
    surface.freeSelectedText(drag_text);
    try testing.expect(tracking.allocations != 0);
    try testing.expectEqual(tracking.allocations, tracking.deallocations);

    shared.mutex.lock();
    surface.interaction.gesture.reset(&shared.terminal);
    shared.mutex.unlock();
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.pointerPosition(15, 5, .{}),
    );
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.mouseButton(.press, .left, .{}),
    );
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.mousePressure(.deep, 1),
    );
    const word = try surface.selectedText();
    defer surface.freeSelectedText(word);
    try testing.expectEqualStrings("hello", word);
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.mousePressure(.none, 0),
    );
    try testing.expectEqual(input.MousePressureStage.none, surface.interaction.pressure_stage);

    shared.mutex.lock();
    surface.runtime.state.scroll_cell_offset = 0.5;
    try testing.expectEqual(
        @as(u32, 1),
        surface.rendererPointLocked(5, 15).?.y,
    );
    const fractional_pin = surface.pointerPinLocked(5, 15).?;
    const fractional_point = shared.terminal.screens.active.pages
        .pointFromPin(.viewport, fractional_pin).?;
    surface.size.screen.height = 70;
    surface.size.padding.bottom = 10;
    try testing.expectEqual(
        @as(u32, 3),
        surface.rendererPointLocked(5, 70).?.y,
    );
    shared.mutex.unlock();
    try testing.expectEqual(@as(u32, 1), fractional_point.coord().y);

    // A live press owns a tracked pin. TerminalSurface teardown must release it
    // while Shared and its terminal are still alive.
    _ = surface.mouseButton(.release, .left, .{});
    _ = surface.mouseButton(.press, .left, .{});
    try testing.expect(surface.interaction.gesture.left_click_pin != null);
    surface.deinitInteraction();
    try testing.expect(surface.interaction.gesture.left_click_pin == null);
    try testing.expect(!surface.interaction.local_left_pressed);
}

test "terminal surface remote mouse admission and rejection state" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer shared.release();
    var sink: TestSink = .{ .shared = shared };
    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    var surface = testSurface(tracking.allocator(), shared, sink.writeSink());

    shared.mutex.lock();
    shared.terminal.flags.mouse_event = .any;
    shared.terminal.flags.mouse_format = .sgr;
    shared.mutex.unlock();

    try testing.expectEqual(InputResult.sent, surface.pointerPosition(5, 5, .{}));
    try testing.expectEqualStrings("\x1b[<35;1;1M", sink.data[0..sink.len]);
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expect(sink.lock_was_free);
    try testing.expect(surface.runtime.state.mouse.point == null);
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.pointerPosition(5, 5, .{}),
    );
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqual(@as(usize, 0), tracking.allocations);

    try testing.expectEqual(
        InputResult.not_accepted,
        surface.mouseButton(.press, .ten, .{}),
    );
    try testing.expectEqual(
        InputResult.not_accepted,
        surface.mouseButton(.press, .eleven, .{}),
    );
    try testing.expect(!surface.interaction.reported_pressed.isSet(
        @intFromEnum(input.MouseButton.ten),
    ));
    try testing.expect(!surface.interaction.reported_pressed.isSet(
        @intFromEnum(input.MouseButton.eleven),
    ));
    try testing.expectEqual(@as(usize, 1), sink.calls);

    sink.accept = false;
    try testing.expectEqual(
        InputResult.not_accepted,
        surface.pointerPosition(15, 5, .{}),
    );
    try testing.expectEqual(@as(f32, 15), surface.interaction.pointer.?.x);
    try testing.expect(surface.runtime.state.mouse.point == null);
    sink.accept = true;
    try testing.expectEqual(InputResult.sent, surface.pointerPosition(15, 5, .{}));

    try setTestSelectionAndViewport(shared);
    sink.accept = false;
    try testing.expectEqual(
        InputResult.not_accepted,
        surface.mouseButton(.press, .left, .{}),
    );
    try testing.expect(!surface.interaction.reported_pressed.isSet(
        @intFromEnum(input.MouseButton.left),
    ));
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection != null);
    }

    sink.accept = true;
    try testing.expectEqual(
        InputResult.sent,
        surface.mouseButton(.press, .left, .{ .ctrl = true }),
    );
    try testing.expect(surface.interaction.mods.ctrl);
    try testing.expect(!surface.runtime.state.mouse.mods.ctrl);
    try testing.expect(surface.interaction.reported_pressed.isSet(
        @intFromEnum(input.MouseButton.left),
    ));
    {
        shared.mutex.lock();
        defer shared.mutex.unlock();
        try testing.expect(shared.terminal.screens.active.selection == null);
    }

    sink.calls = 0;
    try testing.expectEqual(InputResult.sent, surface.scroll(0, 1, .{}));
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqualStrings(
        "\x1b[<80;2;1M" ** 3,
        sink.data[0..sink.len],
    );
    try testing.expect(sink.lock_was_free);
    try testing.expectEqual(
        InputResult.sent,
        surface.mouseButton(.release, .left, .{ .ctrl = true }),
    );
    try testing.expect(!surface.interaction.reported_pressed.isSet(
        @intFromEnum(input.MouseButton.left),
    ));
    try testing.expectEqual(@as(usize, 0), tracking.allocations);
}

test "terminal surface scroll routing concatenation and remainders" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 100,
    });
    defer shared.release();
    var sink: TestSink = .{ .shared = shared };
    var surface = testSurface(testing.allocator, shared, sink.writeSink());

    shared.mutex.lock();
    shared.terminal.flags.mouse_event = .normal;
    shared.terminal.flags.mouse_format = .sgr;
    shared.mutex.unlock();
    try testing.expectEqual(InputResult.consumed_no_output, surface.pointerPosition(5, 5, .{}));

    sink.calls = 0;
    try testing.expectEqual(InputResult.sent, surface.scroll(0, 2, .{}));
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqual(@as(usize, 6 * "\x1b[<64;1;1M".len), sink.len);

    sink.calls = 0;
    const darwin_subtick = surface.scroll(0, 0.1, .{});
    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expectEqual(InputResult.sent, darwin_subtick);
        try testing.expectEqual(@as(usize, 1), sink.calls);
        try testing.expectEqual(@as(usize, 3 * "\x1b[<64;1;1M".len), sink.len);
    } else {
        try testing.expectEqual(InputResult.consumed_no_output, darwin_subtick);
        try testing.expectEqual(@as(usize, 0), sink.calls);
        try testing.expectApproxEqAbs(
            @as(f64, 6),
            surface.interaction.pending_scroll_y,
            0.0001,
        );
        surface.interaction.pending_scroll_y = 0;
    }

    sink.calls = 0;
    try testing.expectEqual(InputResult.sent, surface.scroll(1, 0, .{}));
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqualStrings("\x1b[<66;1;1M", sink.data[0..sink.len]);

    surface.interaction.pending_scroll_y = 0;
    sink.accept = false;
    try testing.expectEqual(
        InputResult.not_accepted,
        surface.scroll(0, 20, .{ .precision = true }),
    );
    try testing.expectEqual(@as(f64, 0), surface.interaction.pending_scroll_y);
    sink.accept = true;

    sink.calls = 0;
    try testing.expectEqual(
        InputResult.consumed_no_output,
        surface.scroll(0, 5, .{ .precision = true }),
    );
    try testing.expectEqual(@as(f64, 5), surface.interaction.pending_scroll_y);
    try testing.expectEqual(@as(usize, 0), sink.calls);
    try testing.expectEqual(
        InputResult.sent,
        surface.scroll(0, 15, .{ .precision = true }),
    );
    try testing.expectEqual(@as(f64, 0), surface.interaction.pending_scroll_y);
    try testing.expectEqual(@as(usize, 1), sink.calls);

    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        shared.terminal.flags.mouse_event = .none;
        var stream = shared.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[?1049h");
        const screen = shared.terminal.screens.active;
        const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try screen.select(terminal.Selection.init(pin, pin, false));
    }
    sink.calls = 0;
    try testing.expectEqual(InputResult.sent, surface.scroll(0, 2, .{}));
    try testing.expectEqual(@as(usize, 1), sink.calls);
    try testing.expectEqualStrings("\x1b[A" ** 6, sink.data[0..sink.len]);
    shared.mutex.lock();
    try testing.expect(shared.terminal.screens.active.selection == null);
    shared.mutex.unlock();

    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        var stream = shared.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[?1049l0\r\n1\r\n2\r\n3\r\n4");
        surface.runtime.state.scroll_cell_offset = 0.5;
    }
    const activity = testCompressionActivity(shared);
    try testing.expectEqual(InputResult.consumed_no_output, surface.scroll(0, -1, .{}));
    try testing.expectEqual(@as(f64, 0), surface.runtime.state.scroll_cell_offset);
    try testing.expectEqual(activity, testCompressionActivity(shared));
    const noop_activity = testCompressionActivity(shared);
    try testing.expectEqual(InputResult.consumed_no_output, surface.scroll(0, -1, .{}));
    try testing.expectEqual(noop_activity, testCompressionActivity(shared));

    try testing.expectEqual(
        InputResult.invalid_input,
        surface.scroll(std.math.floatMax(f64), 0, .{}),
    );

    const isize_min: f64 = @floatFromInt(std.math.minInt(isize));
    try testing.expectError(
        error.InvalidInput,
        normalizeScrollAxis(isize_min, 0, 1, 1, true),
    );
    try testing.expectError(
        error.InvalidInput,
        normalizeScrollAxis(-isize_min, 0, 1, 1, true),
    );
}

test "terminal surface pointer and pressure validation" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);

    try testing.expectEqual(
        InputResult.invalid_input,
        surface.pointerPosition(std.math.nan(f64), 0, .{}),
    );
    try testing.expectEqual(
        InputResult.invalid_input,
        surface.pointerPosition(2_147_483_648, 0, .{}),
    );
    try testing.expectEqual(
        InputResult.invalid_input,
        surface.mousePressure(.normal, std.math.inf(f64)),
    );
    try testing.expectEqual(
        InputResult.not_accepted,
        surface.mouseButton(.press, .left, .{ .ctrl = true }),
    );
    try testing.expect(surface.interaction.mods.ctrl);
    try testing.expect(!surface.runtime.state.mouse.mods.ctrl);
    try testing.expect(validPointerCoordinate(2_147_483_520, 0));
    try testing.expect(!validPointerCoordinate(2_147_483_648, 0));
    try testing.expect(!validPointerCoordinate(-2_147_483_520, 256));
}

test "TerminalSurface viewport text snapshots active visible rows without mutation" {
    const testing = std.testing;
    const shared = try terminal.Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer shared.release();
    var surface = testSurface(testing.allocator, shared, null);

    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        var stream = shared.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice("0\r\n1\r\n2\r\n3\r\n4");
        const screen = shared.terminal.screens.active;
        const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
        try screen.select(terminal.Selection.init(pin, pin, false));
        surface.runtime.state.scroll_cell_offset = 0.5;
    }

    const before = surface.selectionSnapshot();
    const selected = try surface.selectedText();
    surface.freeSelectedText(selected);
    const text = try surface.viewportText();
    defer surface.freeSelectedText(text);
    try testing.expectEqualStrings("2\n3\n4", text);
    try testing.expectEqual(before, surface.selectionSnapshot());
    try testing.expectEqual(@as(f64, 0.5), surface.runtime.state.scroll_cell_offset);

    shared.mutex.lock();
    {
        defer shared.mutex.unlock();
        var stream = shared.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b[?1049halt");
    }
    const alternate = try surface.viewportText();
    defer surface.freeSelectedText(alternate);
    try testing.expect(std.mem.indexOf(u8, alternate, "alt") != null);
    try testing.expect(std.mem.indexOf(u8, alternate, "4") == null);
}
