//! Lifecycle owner for a renderer-backed terminal surface.
pub const Runtime = @This();

const std = @import("std");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const crash = @import("../crash/main.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const sizepkg = @import("size.zig");
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.renderer_runtime);

alloc: std.mem.Allocator,
font_grid_set: *font.SharedGridSet,
font_grid_key: font.SharedGridSet.Key,
renderer: rendererpkg.Renderer,
state: rendererpkg.State,
thread: rendererpkg.Thread,
os_thread: std.Thread,

pub const Options = struct {
    alloc: std.mem.Allocator,
    config: *const configpkg.Config,
    rt_surface: *apprt.RendererSurface,
    terminal: *terminal.Terminal,
    mutex: *std.Thread.Mutex,
    prepared_layout: *PreparedLayout,
    size: *rendererpkg.Size,
    event_sink: rendererpkg.EventSink,
    crash_context: ?crash.sentry.ThreadState,
    visible: bool = true,
    focused: bool = true,
};

/// Owned font-grid reference and the exact renderer geometry derived from it.
/// Callers must either deinitialize this value or transfer it to Runtime.init.
pub const PreparedLayout = struct {
    font_grid_set: *font.SharedGridSet,
    font_grid_key: font.SharedGridSet.Key,
    font_grid: *font.SharedGrid,
    size: rendererpkg.Size,
    explicit_padding: rendererpkg.Padding,
    padding_balance: sizepkg.PaddingBalance,
    owned: bool = true,

    pub const Options = struct {
        font_grid_set: *font.SharedGridSet,
        font_config: *const font.SharedGridSet.DerivedConfig,
        font_size: font.face.DesiredSize,
        screen: rendererpkg.ScreenSize,
        explicit_padding: rendererpkg.Padding,
        padding_balance: sizepkg.PaddingBalance,
    };

    pub fn init(opts: PreparedLayout.Options) !PreparedLayout {
        const font_grid_key, const font_grid = try opts.font_grid_set.ref(
            opts.font_config,
            opts.font_size,
        );
        errdefer opts.font_grid_set.deref(font_grid_key);

        var size: rendererpkg.Size = .{
            .screen = opts.screen,
            .cell = font_grid.cellSize(),
            .padding = opts.explicit_padding,
        };
        if (opts.padding_balance != .false) {
            size.balancePadding(opts.explicit_padding, opts.padding_balance);
        }

        return .{
            .font_grid_set = opts.font_grid_set,
            .font_grid_key = font_grid_key,
            .font_grid = font_grid,
            .size = size,
            .explicit_padding = opts.explicit_padding,
            .padding_balance = opts.padding_balance,
        };
    }

    pub fn deinit(self: *PreparedLayout) void {
        if (!self.owned) return;
        self.font_grid_set.deref(self.font_grid_key);
        self.owned = false;
    }
};

/// Initialize a runtime in stable caller-owned storage. The terminal, mutex,
/// renderer surface, and event-sink context are borrowed and must outlive the
/// runtime. The prepared layout and its font-grid reference are transferred to
/// the runtime on success and remain caller-owned on failure. Config is
/// consumed only during this call and may be released when it returns. This
/// initializes all renderer resources but does not start the renderer OS
/// thread.
pub fn init(self: *Runtime, opts: Options) !font.Metrics {
    const prepared = opts.prepared_layout.*;
    opts.size.* = prepared.size;

    self.alloc = opts.alloc;
    self.renderer = renderer: {
        var derived = try rendererpkg.Renderer.DerivedConfig.init(
            opts.alloc,
            opts.config,
        );
        errdefer derived.deinit();
        break :renderer try rendererpkg.Renderer.init(opts.alloc, .{
            .config = derived,
            .font_grid = prepared.font_grid,
            .size = opts.size.*,
            .event_sink = opts.event_sink,
            .rt_surface = opts.rt_surface,
        });
    };
    errdefer self.renderer.deinit();

    self.state = .{
        .terminal = opts.terminal,
        .mutex = opts.mutex,
    };
    self.thread = try rendererpkg.Thread.init(
        opts.alloc,
        opts.config,
        opts.rt_surface,
        &self.renderer,
        &self.state,
        opts.event_sink,
        opts.crash_context,
        .{
            .visible = opts.visible,
            .focused = opts.focused,
        },
    );
    errdefer self.thread.deinit();

    self.font_grid_set = prepared.font_grid_set;
    self.font_grid_key = prepared.font_grid_key;
    opts.prepared_layout.owned = false;
    return prepared.font_grid.metrics;
}

/// Finalize platform renderer setup and start the renderer OS thread. The
/// runtime must be stopped before deinit.
pub fn start(self: *Runtime) !void {
    try self.renderer.finalizeSurfaceInit(self.thread.surface);
    self.os_thread = try std.Thread.spawn(
        .{},
        rendererpkg.Thread.threadMain,
        .{&self.thread},
    );
    self.os_thread.setName("renderer") catch {};
}

/// Stop and join the renderer OS thread, then restore graphics ownership to
/// the calling thread as required by the renderer implementation.
pub fn stop(self: *Runtime) void {
    self.thread.stop.notify() catch |err|
        log.err(
            "error notifying renderer thread to stop, may stall err={}",
            .{err},
        );
    self.os_thread.join();
    self.renderer.threadEnter(self.thread.surface) catch unreachable;
}

/// Deinitialize an unstarted or already-stopped runtime.
pub fn deinit(self: *Runtime) void {
    self.thread.deinit();
    self.renderer.deinit();
    self.font_grid_set.deref(self.font_grid_key);
    if (self.state.preedit) |*preedit| preedit.deinit(self.alloc);
}

/// Queue a new font grid and adopt the caller's reference. The caller must
/// update terminal sizing before calling this method.
pub fn setFontGrid(
    self: *Runtime,
    key: font.SharedGridSet.Key,
    grid: *font.SharedGrid,
) void {
    _ = self.thread.mailbox.push(.{
        .font_grid = .{
            .grid = grid,
            .set = self.font_grid_set,
            .old_key = self.font_grid_key,
            .new_key = key,
        },
    }, .{ .forever = {} });
    self.font_grid_key = key;
}

test "PreparedLayout owns one font grid and canonical balanced geometry" {
    const testing = std.testing;

    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();
    var font_config = try font.SharedGridSet.DerivedConfig.init(
        testing.allocator,
        &config,
    );
    defer font_config.deinit();
    var font_grid_set = try font.SharedGridSet.init(testing.allocator);
    defer font_grid_set.deinit();

    const screen: rendererpkg.ScreenSize = .{
        .width = 391,
        .height = 845,
    };
    const explicit_padding: rendererpkg.Padding = .{
        .top = 4,
        .bottom = 8,
        .left = 6,
        .right = 10,
    };
    var prepared = try PreparedLayout.init(.{
        .font_grid_set = &font_grid_set,
        .font_config = &font_config,
        .font_size = .{ .points = 13, .xdpi = 192, .ydpi = 192 },
        .screen = screen,
        .explicit_padding = explicit_padding,
        .padding_balance = .equal,
    });
    try testing.expectEqual(@as(usize, 1), font_grid_set.count());
    try testing.expectEqual(screen, prepared.size.screen);
    try testing.expectEqual(explicit_padding, prepared.explicit_padding);
    try testing.expectEqual(sizepkg.PaddingBalance.equal, prepared.padding_balance);

    var expected: rendererpkg.Size = .{
        .screen = screen,
        .cell = prepared.font_grid.cellSize(),
        .padding = explicit_padding,
    };
    expected.balancePadding(explicit_padding, .equal);
    try testing.expectEqual(expected, prepared.size);

    prepared.deinit();
    try testing.expectEqual(@as(usize, 0), font_grid_set.count());
}
