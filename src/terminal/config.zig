//! Projection of application configuration into canonical terminal state.

const Config = @import("../config/Config.zig");
const Terminal = @import("Terminal.zig");
const color = @import("color.zig");

pub const ColorDefaults = struct {
    background: color.RGB,
    foreground: color.RGB,
    cursor: ?color.RGB,
    palette: color.Palette,
};

/// Derive the terminal color defaults represented by an application config.
pub fn colorDefaults(config: *const Config) ColorDefaults {
    return .{
        .background = config.background.toTerminalRGB(),
        .foreground = config.foreground.toTerminalRGB(),
        .cursor = if (config.@"cursor-color") |value|
            value.toTerminalRGB()
        else
            null,
        .palette = if (config.@"palette-generate" and
            config.palette.mask.findFirstSet() != null)
            color.generate256Color(
                config.palette.value,
                config.palette.mask,
                config.background.toTerminalRGB(),
                config.foreground.toTerminalRGB(),
                config.@"palette-harmonious",
            )
        else
            config.palette.value,
    };
}

/// Update only config-owned defaults. Program-owned OSC overrides survive.
/// The caller must hold the terminal's synchronization lock when required.
pub fn applyColorDefaults(
    terminal: *Terminal,
    defaults: ColorDefaults,
) void {
    terminal.colors.palette.changeDefault(defaults.palette);
    terminal.colors.background.default = defaults.background;
    terminal.colors.foreground.default = defaults.foreground;
    terminal.colors.cursor.default = defaults.cursor;
    terminal.flags.dirty.palette = true;
}

test "config color defaults preserve terminal overrides" {
    const testing = @import("std").testing;

    var config = try Config.default(testing.allocator);
    defer config.deinit();
    config.background = .{ .r = 1, .g = 2, .b = 3 };
    config.foreground = .{ .r = 4, .g = 5, .b = 6 };
    config.@"cursor-color" = .{ .color = .{ .r = 16, .g = 17, .b = 18 } };
    config.palette.value[2] = .{ .r = 7, .g = 8, .b = 9 };

    var terminal = try Terminal.init(testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    defer terminal.deinit(testing.allocator);
    terminal.colors.background.set(.{ .r = 10, .g = 11, .b = 12 });
    terminal.colors.foreground.set(.{ .r = 19, .g = 20, .b = 21 });
    terminal.colors.cursor.set(.{ .r = 22, .g = 23, .b = 24 });
    terminal.colors.palette.set(2, .{ .r = 13, .g = 14, .b = 15 });

    applyColorDefaults(&terminal, colorDefaults(&config));

    try testing.expectEqual(config.background.toTerminalRGB(), terminal.colors.background.default.?);
    try testing.expectEqual(color.RGB{ .r = 10, .g = 11, .b = 12 }, terminal.colors.background.get().?);
    try testing.expectEqual(config.foreground.toTerminalRGB(), terminal.colors.foreground.default.?);
    try testing.expectEqual(color.RGB{ .r = 19, .g = 20, .b = 21 }, terminal.colors.foreground.get().?);
    try testing.expectEqual(config.@"cursor-color".?.toTerminalRGB(), terminal.colors.cursor.default);
    try testing.expectEqual(color.RGB{ .r = 22, .g = 23, .b = 24 }, terminal.colors.cursor.get().?);
    try testing.expectEqual(config.palette.value[2], terminal.colors.palette.original[2]);
    try testing.expectEqual(color.RGB{ .r = 13, .g = 14, .b = 15 }, terminal.colors.palette.current[2]);
}
