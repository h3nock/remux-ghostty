//! Renderer surface over one retained terminal supplied by its caller.
pub const TerminalSurface = @This();

const std = @import("std");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const crash = @import("../crash/main.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const sizepkg = @import("size.zig");
const terminal = @import("../terminal/main.zig");

runtime: rendererpkg.Runtime,
size: rendererpkg.Size,
shared: *terminal.Shared,
explicit_padding: rendererpkg.Padding,
padding_balance: sizepkg.PaddingBalance,
/// Scheduling hint shared with terminal producers. Terminal contents remain
/// synchronized by Shared.mutex.
visible: std.atomic.Value(bool),
focused: bool,

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
        .runtime = undefined,
        .size = undefined,
        .shared = shared,
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

fn queueAndWake(self: *TerminalSurface, message: rendererpkg.Message) !void {
    _ = self.runtime.thread.mailbox.push(message, .{ .forever = {} });
    try self.runtime.thread.wakeup.notify();
}
