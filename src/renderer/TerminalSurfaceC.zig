//! Top-level libghostty C boundary for rendering an externally supplied
//! terminal without constructing a process-owning Surface.

const std = @import("std");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");
const SharedTerminal = @import("../terminal/Shared.zig");
const terminal = @import("../terminal/main.zig");

const log = std.log.scoped(.terminal_surface_c);

pub const Result = enum(c_int) {
    ok,
    invalid_input,
    out_of_memory,
    renderer_in_use,
    failed,
};

pub const RendererHealthCallback = *const fn (
    userdata: ?*anyopaque,
    health: renderer.Health,
) callconv(.c) void;

pub const Platform = apprt.embedded.Platform.C;

pub const Config = extern struct {
    platform_tag: c_int = 0,
    platform: Platform = undefined,
    userdata: ?*anyopaque = null,
    renderer_health_cb: ?RendererHealthCallback = null,
    scale_factor: f64 = 1,
    font_size: f32 = 0,
    width_px: u32 = 0,
    height_px: u32 = 0,
    visible: bool = true,
    focused: bool = true,
};

pub const SurfaceSize = extern struct {
    columns: u16,
    rows: u16,
    width_px: u32,
    height_px: u32,
    cell_width_px: u32,
    cell_height_px: u32,
};

fn configNew() Config {
    return .{};
}

fn validConfig(config: Config) bool {
    if (config.width_px == 0 or config.height_px == 0) return false;
    if (!std.math.isFinite(config.scale_factor) or config.scale_factor <= 0) {
        return false;
    }
    const dpi = config.scale_factor * font.face.default_dpi;
    if (dpi > std.math.maxInt(u16)) return false;
    if (!std.math.isFinite(config.font_size) or config.font_size < 0) {
        return false;
    }
    if (config.font_size != 0 and
        (config.font_size < 1 or config.font_size > 255)) return false;
    return true;
}

fn mapError(err: anyerror) Result {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.RendererAlreadyClaimed => .renderer_in_use,
        error.InvalidEnumTag,
        error.NSViewMustBeSet,
        error.UIViewMustBeSet,
        error.UnsupportedPlatform,
        => .invalid_input,
        else => .failed,
    };
}

/// The C implementation is only instantiated for libghostty's embedded
/// runtime. Keeping it behind the same compile-time boundary as the existing
/// app/surface C API avoids pulling embedded runtime types into executable
/// builds and their tests.
pub const CAPI = if (apprt.runtime == apprt.embedded) struct {
    const Runtime = apprt.runtime;

    pub const Surface = struct {
        alloc: std.mem.Allocator,
        renderer_surface: apprt.RendererSurface,
        core: renderer.TerminalSurface,
        userdata: ?*anyopaque,
        renderer_health_cb: ?RendererHealthCallback,

        const event_vtable: renderer.EventSink.VTable = .{
            .scrollbar = eventScrollbar,
            .renderer_health = eventRendererHealth,
            .redraw = eventRedraw,
        };

        fn eventSink(self: *Surface) renderer.EventSink {
            return .{
                .ptr = self,
                .vtable = &event_vtable,
            };
        }

        fn eventScrollbar(_: *anyopaque, _: terminal.Scrollbar) bool {
            // This renderer-only boundary has no scrolling contract yet.
            // Accept the event so the renderer clears scrollbar_dirty rather
            // than retrying it on every later frame.
            return true;
        }

        fn eventRendererHealth(ptr: *anyopaque, health: renderer.Health) void {
            const self: *Surface = @ptrCast(@alignCast(ptr));
            const callback = self.renderer_health_cb orelse {
                log.warn("terminal surface renderer health changed health={}", .{health});
                return;
            };
            callback(self.userdata, health);
        }

        fn eventRedraw(_: *anyopaque) void {
            // Embedded renderers draw off the renderer thread and never ask
            // this sink for an app-thread redraw. Do not fabricate a process
            // Surface target for a path this runtime does not use.
            log.warn("unexpected app-thread redraw request for terminal surface", .{});
        }
    };

    export fn ghostty_terminal_surface_config_new() Config {
        return configNew();
    }

    export fn ghostty_terminal_surface_new(
        app_ptr: ?*Runtime.App,
        terminal_ptr: ?*SharedTerminal,
        config_ptr: ?*const Config,
        out_ptr: ?*?*Surface,
    ) Result {
        const out = out_ptr orelse return .invalid_input;
        out.* = null;
        const app = app_ptr orelse return .invalid_input;
        const shared = terminal_ptr orelse return .invalid_input;
        const config = config_ptr orelse return .invalid_input;
        if (!validConfig(config.*)) return .invalid_input;

        const surface = initSurface(app, shared, config.*) catch |err| {
            log.err("failed to initialize terminal surface err={}", .{err});
            return mapError(err);
        };
        out.* = surface;
        return .ok;
    }

    fn initSurface(
        app: *Runtime.App,
        shared: *SharedTerminal,
        config: Config,
    ) !*Surface {
        const alloc = app.core_app.alloc;
        const surface = try alloc.create(Surface);
        errdefer alloc.destroy(surface);

        const scale: f32 = @floatCast(config.scale_factor);
        surface.* = .{
            .alloc = alloc,
            .renderer_surface = .{
                .platform = try .init(config.platform_tag, config.platform),
                .content_scale = .{ .x = scale, .y = scale },
                .size = .{
                    .width = config.width_px,
                    .height = config.height_px,
                },
            },
            .core = undefined,
            .userdata = config.userdata,
            .renderer_health_cb = config.renderer_health_cb,
        };

        // Runtime consumes this while creating/referring to its shared font
        // grid. It does not borrow the derived configuration afterward.
        var font_config = try font.SharedGridSet.DerivedConfig.init(
            alloc,
            &app.config,
        );
        defer font_config.deinit();

        const x_dpi: f32 = scale * font.face.default_dpi;
        const y_dpi: f32 = scale * font.face.default_dpi;
        const explicit_padding = (renderer.Padding{
            .top = app.config.@"window-padding-y".top_left,
            .bottom = app.config.@"window-padding-y".bottom_right,
            .left = app.config.@"window-padding-x".top_left,
            .right = app.config.@"window-padding-x".bottom_right,
        }).scaledDpi(x_dpi, y_dpi);

        _ = try surface.core.init(.{
            .alloc = alloc,
            .config = &app.config,
            .rt_surface = &surface.renderer_surface,
            .shared = shared,
            .font_grid_set = &app.core_app.font_grid_set,
            .font_config = &font_config,
            .font_size = .{
                .points = if (config.font_size == 0)
                    app.config.@"font-size"
                else
                    config.font_size,
                .xdpi = @max(1, @as(u16, @intFromFloat(x_dpi))),
                .ydpi = @max(1, @as(u16, @intFromFloat(y_dpi))),
            },
            .explicit_padding = explicit_padding,
            .padding_balance = app.config.@"window-padding-balance",
            .event_sink = surface.eventSink(),
            .crash_context = null,
            .visible = config.visible,
            .focused = config.focused,
        });
        return surface;
    }

    export fn ghostty_terminal_surface_free(surface: ?*Surface) void {
        const value = surface orelse return;
        const alloc = value.alloc;
        value.core.deinit();
        alloc.destroy(value);
    }

    export fn ghostty_terminal_surface_draw(surface: ?*Surface) Result {
        const value = surface orelse return .invalid_input;
        value.core.drawFrame() catch |err| return operationError("draw", err);
        return .ok;
    }

    export fn ghostty_terminal_surface_terminal_changed(surface: ?*Surface) Result {
        const value = surface orelse return .invalid_input;
        value.core.terminalChanged() catch |err|
            return operationError("terminal changed", err);
        return .ok;
    }

    export fn ghostty_terminal_surface_set_visible(
        surface: ?*Surface,
        visible: bool,
    ) Result {
        const value = surface orelse return .invalid_input;
        value.core.setVisible(visible) catch |err|
            return operationError("set visible", err);
        return .ok;
    }

    export fn ghostty_terminal_surface_set_focused(
        surface: ?*Surface,
        focused: bool,
    ) Result {
        const value = surface orelse return .invalid_input;
        value.core.setFocused(focused) catch |err|
            return operationError("set focused", err);
        return .ok;
    }

    export fn ghostty_terminal_surface_set_size(
        surface: ?*Surface,
        width: u32,
        height: u32,
    ) Result {
        const value = surface orelse return .invalid_input;
        if (width == 0 or height == 0) return .invalid_input;
        value.core.resize(.{ .width = width, .height = height }) catch |err|
            return operationError("set size", err);
        value.renderer_surface.size = .{ .width = width, .height = height };
        return .ok;
    }

    export fn ghostty_terminal_surface_size(
        surface: ?*const Surface,
        out_ptr: ?*SurfaceSize,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        const size = value.core.size;
        const grid = size.grid();
        out.* = .{
            .columns = grid.columns,
            .rows = grid.rows,
            .width_px = size.screen.width,
            .height_px = size.screen.height,
            .cell_width_px = size.cell.width,
            .cell_height_px = size.cell.height,
        };
        return .ok;
    }

    fn operationError(comptime operation: []const u8, err: anyerror) Result {
        log.err("terminal surface operation failed operation={s} err={}", .{
            operation,
            err,
        });
        return mapError(err);
    }
} else struct {};

fn expectStructLayout(comptime Zig: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(Zig), @sizeOf(C));
    try std.testing.expectEqual(@alignOf(Zig), @alignOf(C));
    inline for (std.meta.fields(Zig)) |field| {
        try std.testing.expectEqual(
            @offsetOf(Zig, field.name),
            @offsetOf(C, field.name),
        );
    }
}

test "terminal surface C ABI matches ghostty header" {
    const testing = std.testing;
    const c = @import("ghostty.h");

    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_terminal_surface_result_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_action_renderer_health_e));
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.ok)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_RESULT_OK),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.renderer_in_use)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_RESULT_RENDERER_IN_USE),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(renderer.Health.healthy)),
        @as(c_int, c.GHOSTTY_RENDERER_HEALTH_HEALTHY),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(renderer.Health.unhealthy)),
        @as(c_int, c.GHOSTTY_RENDERER_HEALTH_UNHEALTHY),
    );
    try testing.expectEqual(@sizeOf(Platform), @sizeOf(c.ghostty_platform_u));
    try testing.expectEqual(@alignOf(Platform), @alignOf(c.ghostty_platform_u));
    try expectStructLayout(Config, c.ghostty_terminal_surface_config_s);
    try expectStructLayout(SurfaceSize, c.ghostty_surface_size_s);
}

test "terminal surface C config defaults and validation" {
    const testing = std.testing;
    var config = configNew();
    try testing.expectEqual(@as(f64, 1), config.scale_factor);
    try testing.expectEqual(@as(f32, 0), config.font_size);
    try testing.expectEqual(@as(u32, 0), config.width_px);
    try testing.expectEqual(@as(u32, 0), config.height_px);
    try testing.expect(config.visible);
    try testing.expect(config.focused);
    try testing.expect(!validConfig(config));

    config.width_px = 390;
    config.height_px = 844;
    try testing.expect(validConfig(config));
    config.scale_factor = std.math.nan(f64);
    try testing.expect(!validConfig(config));
    config.scale_factor = 2;
    config.font_size = 256;
    try testing.expect(!validConfig(config));
}

test "terminal surface C invalid platform tag is invalid input" {
    try std.testing.expectEqual(
        Result.invalid_input,
        mapError(error.InvalidEnumTag),
    );
}
