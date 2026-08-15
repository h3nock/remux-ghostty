//! Top-level libghostty C boundary for rendering an externally supplied
//! terminal without constructing a process-owning Surface.

const std = @import("std");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const input_mouse = @import("../input/mouse.zig");
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

pub const WriteCallback = *const fn (
    userdata: ?*anyopaque,
    data: [*]const u8,
    len: usize,
) callconv(.c) bool;

pub const InputResult = renderer.TerminalSurface.InputResult;

pub const Platform = apprt.embedded.Platform.C;

pub const Config = extern struct {
    platform_tag: c_int = 0,
    platform: Platform = undefined,
    userdata: ?*anyopaque = null,
    renderer_health_cb: ?RendererHealthCallback = null,
    write_cb: ?WriteCallback = null,
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

pub const Scrollbar = extern struct {
    total: u64,
    offset: u64,
    len: u64,
    cell_offset: f64,
};

pub const ScrollRoute = renderer.TerminalSurface.ScrollRoute;

pub const InteractionState = extern struct {
    scrollbar: Scrollbar,
    route: ScrollRoute,
    mouse_captured: bool,
    has_selection: bool,
};

pub const SelectionEndpoint = renderer.TerminalSurface.SelectionEndpoint;
pub const CellGeometry = renderer.TerminalSurface.CellGeometry;
pub const SelectionSnapshot = renderer.TerminalSurface.SelectionSnapshot;

pub const Text = extern struct {
    tl_px_x: f64,
    tl_px_y: f64,
    offset_start: u32,
    offset_len: u32,
    text: ?[*]const u8,
    text_len: usize,
};

fn emptyText() Text {
    return .{
        .tl_px_x = -1,
        .tl_px_y = -1,
        .offset_start = 0,
        .offset_len = 0,
        .text = null,
        .text_len = 0,
    };
}

fn configNew() Config {
    return .{};
}

fn inputSlice(data_ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const data = data_ptr orelse return null;
    return data[0..len];
}

fn validCellOffset(value: f64) bool {
    return std.math.isFinite(value);
}

fn inputMods(raw: c_int) ?input.Mods {
    if (raw < 0) return null;
    const value: c_uint = @intCast(raw);
    const valid_mask: c_uint = (1 << 10) - 1;
    if (value & ~valid_mask != 0) return null;
    return @bitCast(@as(input.Mods.Backing, @intCast(value)));
}

fn mouseButtonState(raw: c_int) ?input.MouseButtonState {
    return std.meta.intToEnum(input.MouseButtonState, raw) catch null;
}

fn mouseButtonValue(raw: c_int) ?input.MouseButton {
    return std.meta.intToEnum(input.MouseButton, raw) catch null;
}

fn pressureStage(raw: u32) ?input.MousePressureStage {
    return std.meta.intToEnum(input.MousePressureStage, raw) catch null;
}

fn scrollMods(raw: c_int) ?input.ScrollMods {
    if (raw < 0 or raw > std.math.maxInt(u8)) return null;
    const value: u8 = @intCast(raw);
    if (value & 0xf0 != 0) return null;
    const momentum: u3 = @truncate(value >> 1);
    if (momentum > @intFromEnum(input_mouse.Momentum.may_begin)) return null;
    return @bitCast(value);
}

fn scrollRow(value: u64) ?usize {
    return std.math.cast(usize, value);
}

fn selectionEndpoint(raw: c_int) ?SelectionEndpoint {
    return std.meta.intToEnum(SelectionEndpoint, raw) catch null;
}

fn interactionStateC(state: renderer.TerminalSurface.InteractionState) InteractionState {
    return .{
        .scrollbar = .{
            .total = @intCast(state.scrollbar.total),
            .offset = @intCast(state.scrollbar.offset),
            .len = @intCast(state.scrollbar.len),
            .cell_offset = state.scrollbar.cell_offset,
        },
        .route = state.route,
        .mouse_captured = state.mouse_captured,
        .has_selection = state.has_selection,
    };
}

fn surfaceSizeC(size: renderer.Size) SurfaceSize {
    const grid = size.grid();
    return .{
        .columns = grid.columns,
        .rows = grid.rows,
        .width_px = size.screen.width,
        .height_px = size.screen.height,
        .cell_width_px = size.cell.width,
        .cell_height_px = size.cell.height,
    };
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

fn surfaceDpi(config: Config) f32 {
    // Preserve terminal-surface creation's established rounding: the content
    // scale is narrowed before the DPI multiplication.
    const scale: f32 = @floatCast(config.scale_factor);
    return scale * font.face.default_dpi;
}

fn mapError(err: anyerror) Result {
    return switch (err) {
        error.InvalidInput => .invalid_input,
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
        app: *Runtime.App,
        font_size: f32,
        renderer_surface: apprt.RendererSurface,
        core: renderer.TerminalSurface,
        userdata: ?*anyopaque,
        renderer_health_cb: ?RendererHealthCallback,
        write_cb: ?WriteCallback,

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

        fn writeSink(self: *Surface) ?renderer.TerminalSurface.WriteSink {
            if (self.write_cb == null) return null;
            return .{
                .ptr = self,
                .callback = write,
            };
        }

        fn write(ptr: *anyopaque, data: []const u8) bool {
            const self: *Surface = @ptrCast(@alignCast(ptr));
            return self.write_cb.?(self.userdata, data.ptr, data.len);
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

    export fn ghostty_terminal_surface_measure(
        app_ptr: ?*Runtime.App,
        config_ptr: ?*const Config,
        out_ptr: ?*SurfaceSize,
    ) Result {
        const app = app_ptr orelse return .invalid_input;
        const config = config_ptr orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        if (!validConfig(config.*)) return .invalid_input;

        var prepared = prepareLayout(app, config.*) catch |err| {
            log.err("failed to measure terminal surface err={}", .{err});
            return mapError(err);
        };
        defer prepared.deinit();
        out.* = surfaceSizeC(prepared.size);
        return .ok;
    }

    fn prepareLayout(
        app: *Runtime.App,
        config: Config,
    ) !renderer.Runtime.PreparedLayout {
        const alloc = app.core_app.alloc;

        var font_config = try font.SharedGridSet.DerivedConfig.init(
            alloc,
            &app.config,
        );
        defer font_config.deinit();

        const dpi = surfaceDpi(config);
        const explicit_padding = (renderer.Padding{
            .top = app.config.@"window-padding-y".top_left,
            .bottom = app.config.@"window-padding-y".bottom_right,
            .left = app.config.@"window-padding-x".top_left,
            .right = app.config.@"window-padding-x".bottom_right,
        }).scaledDpi(dpi, dpi);

        return .init(.{
            .font_grid_set = &app.core_app.font_grid_set,
            .font_config = &font_config,
            .font_size = .{
                .points = if (config.font_size == 0)
                    app.config.@"font-size"
                else
                    config.font_size,
                .xdpi = @max(1, @as(u16, @intFromFloat(dpi))),
                .ydpi = @max(1, @as(u16, @intFromFloat(dpi))),
            },
            .screen = .{
                .width = config.width_px,
                .height = config.height_px,
            },
            .explicit_padding = explicit_padding,
            .padding_balance = app.config.@"window-padding-balance",
        });
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
            .app = app,
            .font_size = config.font_size,
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
            .write_cb = config.write_cb,
        };

        var prepared = try prepareLayout(app, config);
        defer prepared.deinit();

        _ = try surface.core.init(.{
            .alloc = alloc,
            .config = &app.config,
            .rt_surface = &surface.renderer_surface,
            .shared = shared,
            .prepared_layout = &prepared,
            .event_sink = surface.eventSink(),
            .write_sink = surface.writeSink(),
            .macos_option_as_alt = app.config.@"macos-option-as-alt" orelse
                app.keyboardLayout().detectOptionAsAlt(),
            .crash_context = null,
            .visible = config.visible,
            .focused = config.focused,
        });
        return surface;
    }

    export fn ghostty_terminal_surface_update_config(surface: ?*Surface) Result {
        const value = surface orelse return .invalid_input;
        const scale = value.renderer_surface.content_scale.x;
        var config = configNew();
        config.scale_factor = scale;
        config.font_size = value.font_size;
        config.width_px = value.renderer_surface.size.width;
        config.height_px = value.renderer_surface.size.height;

        var prepared = prepareLayout(value.app, config) catch |err| {
            log.err("failed to prepare terminal surface config update err={}", .{err});
            return mapError(err);
        };
        defer prepared.deinit();

        value.core.updateConfig(.{
            .config = &value.app.config,
            .prepared_layout = &prepared,
            .macos_option_as_alt = value.app.config.@"macos-option-as-alt" orelse
                value.app.keyboardLayout().detectOptionAsAlt(),
        }) catch |err| return operationError("update config", err);
        return .ok;
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

    export fn ghostty_terminal_surface_request_frame(surface: ?*Surface) Result {
        const value = surface orelse return .invalid_input;
        value.core.requestFrame() catch |err|
            return operationError("request frame", err);
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
        out.* = surfaceSizeC(value.core.size);
        return .ok;
    }

    export fn ghostty_terminal_surface_interaction_state(
        surface: ?*Surface,
        out_ptr: ?*InteractionState,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        out.* = interactionStateC(value.core.interactionState());
        return .ok;
    }

    export fn ghostty_terminal_surface_scroll_to_position(
        surface: ?*Surface,
        row: u64,
        cell_offset: f64,
        out_ptr: ?*InteractionState,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        if (!validCellOffset(cell_offset)) return .invalid_input;
        const row_value = scrollRow(row) orelse return .invalid_input;
        var state: renderer.TerminalSurface.InteractionState = undefined;
        value.core.scrollToPosition(
            row_value,
            cell_offset,
            &state,
        ) catch |err| {
            // scrollToPosition only reports notification failure after it
            // fills the exact state committed under the terminal lock.
            out.* = interactionStateC(state);
            return operationError("scroll to position", err);
        };
        out.* = interactionStateC(state);
        return .ok;
    }

    export fn ghostty_terminal_surface_selection_snapshot(
        surface: ?*Surface,
        out_ptr: ?*SelectionSnapshot,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        out.* = value.core.selectionSnapshot();
        return .ok;
    }

    export fn ghostty_terminal_surface_cursor_geometry(
        surface: ?*Surface,
        out_ptr: ?*CellGeometry,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        out.* = value.core.cursorGeometry();
        return .ok;
    }

    export fn ghostty_terminal_surface_select_word(
        surface: ?*Surface,
        x: f64,
        y: f64,
        out_ptr: ?*SelectionSnapshot,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        value.core.selectWord(x, y, out) catch |err| {
            return operationError("select word", err);
        };
        return .ok;
    }

    export fn ghostty_terminal_surface_select_link(
        surface: ?*Surface,
        x: f64,
        y: f64,
        out_snapshot_ptr: ?*SelectionSnapshot,
        out_matched_ptr: ?*bool,
        out_target_ptr: ?*Text,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out_snapshot = out_snapshot_ptr orelse return .invalid_input;
        const out_matched = out_matched_ptr orelse return .invalid_input;
        const out_target = out_target_ptr orelse return .invalid_input;

        out_matched.* = false;
        out_target.* = emptyText();
        var target: ?[:0]const u8 = null;
        value.core.selectLink(
            x,
            y,
            out_snapshot,
            out_matched,
            &target,
        ) catch |err| {
            std.debug.assert(!out_matched.*);
            std.debug.assert(target == null);
            return operationError("select link", err);
        };
        if (target) |text| {
            out_target.text = text.ptr;
            out_target.text_len = text.len;
        }
        return .ok;
    }

    export fn ghostty_terminal_surface_set_selection_endpoint(
        surface: ?*Surface,
        endpoint_raw: c_int,
        x: f64,
        y: f64,
        out_ptr: ?*SelectionSnapshot,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        const endpoint = selectionEndpoint(endpoint_raw) orelse {
            out.* = value.core.selectionSnapshot();
            return .invalid_input;
        };
        value.core.setSelectionEndpoint(
            endpoint,
            x,
            y,
            out,
        ) catch |err| {
            return operationError("set selection endpoint", err);
        };
        return .ok;
    }

    export fn ghostty_terminal_surface_clear_selection(
        surface: ?*Surface,
        out_ptr: ?*SelectionSnapshot,
    ) Result {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        value.core.clearSelection(out) catch |err| {
            return operationError("clear selection", err);
        };
        return .ok;
    }

    /// Filter modifiers for native key translation. The original modifiers
    /// must still be passed in the subsequent key event.
    export fn ghostty_terminal_surface_key_translation_mods(
        surface: ?*const Surface,
        mods_raw: c_int,
    ) c_int {
        const value = surface orelse return mods_raw;
        const mods: input.Mods = @bitCast(@as(
            input.Mods.Backing,
            @truncate(@as(c_uint, @bitCast(mods_raw))),
        ));
        const result = value.core.keyTranslationMods(mods);
        return @intCast(@as(input.Mods.Backing, @bitCast(result)));
    }

    export fn ghostty_terminal_surface_key(
        surface: ?*Surface,
        event: apprt.embedded.KeyEventC,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const core_event = event.core() orelse return .invalid_input;
        return value.core.key(core_event);
    }

    export fn ghostty_terminal_surface_input(
        surface: ?*Surface,
        data_ptr: ?[*]const u8,
        len: usize,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const data = inputSlice(data_ptr, len) orelse return .invalid_input;
        return value.core.committedText(data);
    }

    export fn ghostty_terminal_surface_paste(
        surface: ?*Surface,
        data_ptr: ?[*]const u8,
        len: usize,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const data = inputSlice(data_ptr, len) orelse return .invalid_input;
        return value.core.paste(data);
    }

    export fn ghostty_terminal_surface_mouse_pos(
        surface: ?*Surface,
        x: f64,
        y: f64,
        mods_raw: c_int,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const mods = inputMods(mods_raw) orelse return .invalid_input;
        return value.core.pointerPosition(x, y, mods);
    }

    export fn ghostty_terminal_surface_mouse_button(
        surface: ?*Surface,
        state_raw: c_int,
        button_raw: c_int,
        mods_raw: c_int,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const state = mouseButtonState(state_raw) orelse return .invalid_input;
        const button = mouseButtonValue(button_raw) orelse return .invalid_input;
        const mods = inputMods(mods_raw) orelse return .invalid_input;
        return value.core.mouseButton(state, button, mods);
    }

    export fn ghostty_terminal_surface_mouse_scroll(
        surface: ?*Surface,
        x: f64,
        y: f64,
        scroll_mods_raw: c_int,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const mods = scrollMods(scroll_mods_raw) orelse return .invalid_input;
        return value.core.scroll(x, y, mods);
    }

    export fn ghostty_terminal_surface_mouse_pressure(
        surface: ?*Surface,
        stage_raw: u32,
        pressure: f64,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const stage = pressureStage(stage_raw) orelse return .invalid_input;
        return value.core.mousePressure(stage, pressure);
    }

    export fn ghostty_terminal_surface_read_selection(
        surface: ?*Surface,
        out_ptr: ?*Text,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const out = out_ptr orelse return .invalid_input;
        out.* = emptyText();
        const text = value.core.selectedText() catch |err| return switch (err) {
            error.NoSelection => .consumed_no_output,
            error.OutOfMemory => .out_of_memory,
        };
        out.text = text.ptr;
        out.text_len = text.len;
        return .sent;
    }

    export fn ghostty_terminal_surface_free_text(
        surface: ?*Surface,
        text_ptr: ?*Text,
    ) InputResult {
        const value = surface orelse return .invalid_input;
        const text = text_ptr orelse return .invalid_input;
        const ptr = text.text orelse return .invalid_input;
        value.core.freeSelectedText(ptr[0..text.text_len :0]);
        text.* = emptyText();
        return .consumed_no_output;
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

    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_input"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_request_frame"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_update_config"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_selection_snapshot"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_cursor_geometry"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_select_word"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_select_link"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_set_selection_endpoint"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_surface_clear_selection"));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_terminal_surface_result_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_terminal_surface_input_result_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_terminal_surface_selection_endpoint_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_action_renderer_health_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_input_mouse_state_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_input_mouse_button_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_input_scroll_mods_t));
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.ok)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_RESULT_OK),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.renderer_in_use)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_RESULT_RENDERER_IN_USE),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(InputResult.sent)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_INPUT_SENT),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(InputResult.consumed_no_output)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_INPUT_CONSUMED_NO_OUTPUT),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(InputResult.not_accepted)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_INPUT_NOT_ACCEPTED),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(InputResult.unavailable)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_INPUT_UNAVAILABLE),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(InputResult.invalid_input)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_INPUT_INVALID_INPUT),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(InputResult.out_of_memory)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_INPUT_OUT_OF_MEMORY),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(input.MouseButtonState.release)),
        @as(c_int, c.GHOSTTY_MOUSE_RELEASE),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(input.MouseButtonState.press)),
        @as(c_int, c.GHOSTTY_MOUSE_PRESS),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(input.MouseButton.left)),
        @as(c_int, c.GHOSTTY_MOUSE_LEFT),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(input.MouseButton.eleven)),
        @as(c_int, c.GHOSTTY_MOUSE_ELEVEN),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(input_mouse.Momentum.may_begin)),
        @as(c_int, c.GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN),
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
    try expectStructLayout(Scrollbar, c.ghostty_terminal_surface_scrollbar_s);
    try expectStructLayout(
        InteractionState,
        c.ghostty_terminal_surface_interaction_state_s,
    );
    try expectStructLayout(CellGeometry, c.ghostty_terminal_surface_cell_geometry_s);
    try expectStructLayout(
        SelectionSnapshot,
        c.ghostty_terminal_surface_selection_snapshot_s,
    );
    try expectStructLayout(Text, c.ghostty_text_s);
    try expectStructLayout(apprt.embedded.KeyEventC, c.ghostty_input_key_s);
    try testing.expectEqual(
        @as(c_int, @intFromEnum(ScrollRoute.viewport)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_SCROLL_ROUTE_VIEWPORT),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(ScrollRoute.alternate_screen_cursor)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_SCROLL_ROUTE_ALTERNATE_SCREEN_CURSOR),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(ScrollRoute.remote_mouse)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_SCROLL_ROUTE_REMOTE_MOUSE),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(SelectionEndpoint.start)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_START),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(SelectionEndpoint.end)),
        @as(c_int, c.GHOSTTY_TERMINAL_SURFACE_SELECTION_ENDPOINT_END),
    );
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
    try testing.expect(config.write_cb == null);
    try testing.expect(!validConfig(config));

    config.width_px = 390;
    config.height_px = 844;
    try testing.expect(validConfig(config));
    config.scale_factor = std.math.nan(f64);
    try testing.expect(!validConfig(config));
    config.scale_factor = 2;
    config.font_size = 256;
    try testing.expect(!validConfig(config));

    config.scale_factor = 0.9027777129432222;
    try testing.expectEqual(@as(f32, 65), surfaceDpi(config));
}

test "terminal surface C invalid platform tag is invalid input" {
    try std.testing.expectEqual(
        Result.invalid_input,
        mapError(error.InvalidEnumTag),
    );
}

test "terminal surface C config update rejects a null surface" {
    if (apprt.runtime != apprt.embedded) return error.SkipZigTest;
    try std.testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_update_config(null),
    );
}

test "terminal surface C frame request rejects a null surface" {
    if (apprt.runtime != apprt.embedded) return error.SkipZigTest;
    try std.testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_request_frame(null),
    );
}

test "terminal surface C selection validation" {
    const testing = std.testing;
    try testing.expectEqual(SelectionEndpoint.start, selectionEndpoint(0).?);
    try testing.expectEqual(SelectionEndpoint.end, selectionEndpoint(1).?);
    try testing.expect(selectionEndpoint(-1) == null);
    try testing.expect(selectionEndpoint(2) == null);
    try testing.expectEqual(Result.invalid_input, mapError(error.InvalidInput));

    if (apprt.runtime != apprt.embedded) return error.SkipZigTest;
    const sentinel: SelectionSnapshot = .{
        .start = .{ .x_px = 1, .visible = true },
        .active = true,
    };
    var out = sentinel;
    const geometry_sentinel: CellGeometry = .{
        .x_px = 2,
        .y_px = 3,
        .width_px = 4,
        .height_px = 5,
        .visible = true,
    };
    var geometry_out = geometry_sentinel;
    const target_sentinel: Text = .{
        .tl_px_x = 1,
        .tl_px_y = 2,
        .offset_start = 3,
        .offset_len = 4,
        .text = @ptrFromInt(1),
        .text_len = 5,
    };
    var matched = true;
    var target = target_sentinel;
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_selection_snapshot(null, &out),
    );
    try testing.expectEqualDeep(sentinel, out);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_cursor_geometry(null, &geometry_out),
    );
    try testing.expectEqualDeep(geometry_sentinel, geometry_out);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_select_link(
            null,
            0,
            0,
            &out,
            &matched,
            &target,
        ),
    );
    try testing.expectEqualDeep(sentinel, out);
    try testing.expect(matched);
    try testing.expectEqualDeep(target_sentinel, target);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_select_word(null, 0, 0, &out),
    );
    try testing.expectEqualDeep(sentinel, out);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_set_selection_endpoint(
            null,
            0,
            0,
            0,
            &out,
        ),
    );
    try testing.expectEqualDeep(sentinel, out);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_clear_selection(null, &out),
    );
    try testing.expectEqualDeep(sentinel, out);

    const fake_surface: *CAPI.Surface = @ptrFromInt(@alignOf(CAPI.Surface));
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_selection_snapshot(fake_surface, null),
    );
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_cursor_geometry(fake_surface, null),
    );
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_select_word(fake_surface, 0, 0, null),
    );
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_select_link(
            fake_surface,
            0,
            0,
            null,
            &matched,
            &target,
        ),
    );
    try testing.expectEqualDeep(target_sentinel, target);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_select_link(
            fake_surface,
            0,
            0,
            &out,
            null,
            &target,
        ),
    );
    try testing.expectEqualDeep(sentinel, out);
    try testing.expectEqualDeep(target_sentinel, target);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_select_link(
            fake_surface,
            0,
            0,
            &out,
            &matched,
            null,
        ),
    );
    try testing.expectEqualDeep(sentinel, out);
    try testing.expect(matched);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_set_selection_endpoint(
            fake_surface,
            0,
            0,
            0,
            null,
        ),
    );
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_clear_selection(fake_surface, null),
    );
}

test "terminal surface C measurement validates without writing output" {
    if (apprt.runtime != apprt.embedded) return error.SkipZigTest;

    const testing = std.testing;
    const CoreApp = @import("../App.zig");
    const ConfigPackage = @import("../config.zig");

    var app_config = try ConfigPackage.Config.default(testing.allocator);
    defer app_config.deinit();
    const core_app = try CoreApp.create(testing.allocator);
    defer core_app.destroy();
    var app: apprt.embedded.App = undefined;
    app.core_app = core_app;
    app.config = try app_config.clone(testing.allocator);
    defer app.config.deinit();

    var config = configNew();
    config.width_px = 390;
    config.height_px = 844;
    const sentinel: SurfaceSize = .{
        .columns = 1,
        .rows = 2,
        .width_px = 3,
        .height_px = 4,
        .cell_width_px = 5,
        .cell_height_px = 6,
    };
    var out = sentinel;

    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_measure(null, &config, &out),
    );
    try testing.expectEqual(sentinel, out);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_measure(&app, null, &out),
    );
    try testing.expectEqual(sentinel, out);
    try testing.expectEqual(
        Result.invalid_input,
        CAPI.ghostty_terminal_surface_measure(&app, &config, null),
    );

    const invalid_values = [_]Config{
        invalid: {
            var value = config;
            value.width_px = 0;
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.height_px = 0;
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.scale_factor = 0;
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.scale_factor = std.math.nan(f64);
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.scale_factor = std.math.inf(f64);
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.scale_factor = (@as(f64, std.math.maxInt(u16)) + 1) /
                font.face.default_dpi;
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.font_size = std.math.nan(f32);
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.font_size = -1;
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.font_size = 0.5;
            break :invalid value;
        },
        invalid: {
            var value = config;
            value.font_size = 256;
            break :invalid value;
        },
    };
    for (invalid_values) |invalid| {
        out = sentinel;
        try testing.expectEqual(
            Result.invalid_input,
            CAPI.ghostty_terminal_surface_measure(&app, &invalid, &out),
        );
        try testing.expectEqual(sentinel, out);
    }
    try testing.expectEqual(@as(usize, 0), core_app.font_grid_set.count());
}

test "terminal surface C measurement uses font scale and app padding" {
    if (apprt.runtime != apprt.embedded) return error.SkipZigTest;

    const testing = std.testing;
    const CoreApp = @import("../App.zig");
    const ConfigPackage = @import("../config.zig");

    var app_config = try ConfigPackage.Config.default(testing.allocator);
    defer app_config.deinit();
    app_config.@"window-padding-x" = .{ .top_left = 0, .bottom_right = 0 };
    app_config.@"window-padding-y" = .{ .top_left = 0, .bottom_right = 0 };
    const core_app = try CoreApp.create(testing.allocator);
    defer core_app.destroy();
    var app: apprt.embedded.App = undefined;
    app.core_app = core_app;
    app.config = try app_config.clone(testing.allocator);
    defer app.config.deinit();

    var config = configNew();
    config.width_px = 1170;
    config.height_px = 2532;

    var default_size: SurfaceSize = undefined;
    try testing.expectEqual(
        Result.ok,
        CAPI.ghostty_terminal_surface_measure(&app, &config, &default_size),
    );
    try testing.expectEqual(@as(usize, 0), core_app.font_grid_set.count());

    config.font_size = 24;
    var override_size: SurfaceSize = undefined;
    try testing.expectEqual(
        Result.ok,
        CAPI.ghostty_terminal_surface_measure(&app, &config, &override_size),
    );
    try testing.expect(override_size.cell_width_px > default_size.cell_width_px);
    try testing.expect(override_size.cell_height_px > default_size.cell_height_px);
    try testing.expect(override_size.columns < default_size.columns);
    try testing.expect(override_size.rows < default_size.rows);
    try testing.expectEqual(@as(usize, 0), core_app.font_grid_set.count());

    config.scale_factor = 2;
    var scaled_size: SurfaceSize = undefined;
    try testing.expectEqual(
        Result.ok,
        CAPI.ghostty_terminal_surface_measure(&app, &config, &scaled_size),
    );
    try testing.expect(scaled_size.cell_width_px > override_size.cell_width_px);
    try testing.expect(scaled_size.cell_height_px > override_size.cell_height_px);
    try testing.expectEqual(@as(usize, 0), core_app.font_grid_set.count());

    app.config.@"window-padding-x" = .{ .top_left = 40, .bottom_right = 40 };
    app.config.@"window-padding-y" = .{ .top_left = 40, .bottom_right = 40 };
    app.config.@"window-padding-balance" = .equal;
    var padded_size: SurfaceSize = undefined;
    try testing.expectEqual(
        Result.ok,
        CAPI.ghostty_terminal_surface_measure(&app, &config, &padded_size),
    );
    try testing.expect(padded_size.columns < scaled_size.columns);
    try testing.expect(padded_size.rows < scaled_size.rows);
    try testing.expectEqual(@as(usize, 0), core_app.font_grid_set.count());
}

test "terminal surface C input validation and key mapping" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), inputSlice(null, 0).?.len);
    try testing.expect(inputSlice(null, 1) == null);
    const bytes = "a\x00b";
    try testing.expectEqualSlices(u8, bytes, inputSlice(bytes.ptr, bytes.len).?);

    const valid: apprt.embedded.KeyEventC = .{
        .action = @intFromEnum(input.Action.press),
        .mods = 0,
        .consumed_mods = 0,
        .keycode = 0,
        .text = "a",
        .unshifted_codepoint = 'a',
        .composing = false,
    };
    try testing.expect(valid.core() != null);
    var invalid = valid;
    invalid.action = 99;
    try testing.expect(invalid.core() == null);

    try testing.expect(!validCellOffset(std.math.nan(f64)));
    try testing.expect(!validCellOffset(std.math.inf(f64)));
    try testing.expect(validCellOffset(-0.25));
    try testing.expectEqual(@as(?usize, 42), scrollRow(42));
    if (@bitSizeOf(usize) < @bitSizeOf(u64)) {
        try testing.expect(scrollRow(std.math.maxInt(u64)) == null);
    } else {
        try testing.expectEqual(
            @as(?usize, std.math.maxInt(usize)),
            scrollRow(std.math.maxInt(u64)),
        );
    }

    try testing.expect(inputMods(-1) == null);
    try testing.expect(inputMods(1 << 10) == null);
    try testing.expect(inputMods(1 << 9) != null);
    try testing.expect(mouseButtonState(99) == null);
    try testing.expect(mouseButtonValue(99) == null);
    try testing.expect(pressureStage(3) == null);
    try testing.expect(scrollMods(-1) == null);
    try testing.expect(scrollMods(0x10) == null);
    try testing.expect(scrollMods(0x0e) == null);
    try testing.expect(scrollMods(0x0d) != null);
}
