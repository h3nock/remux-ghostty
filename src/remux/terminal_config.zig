//! Projection of application configuration into canonical terminal state.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Terminal = @import("../terminal/Terminal.zig");
const color = @import("../terminal/color.zig");

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
    alloc: std.mem.Allocator,
    terminal: *Terminal,
    defaults: ColorDefaults,
) void {
    terminal.colors.palette.changeDefault(alloc, defaults.palette) catch |err| {
        std.log.scoped(.terminal_config).warn("error changing default palette, using built-in default err={}", .{err});
        terminal.colors.palette.resetDefault(alloc);
    };
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

    var terminal = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    defer terminal.deinit(testing.allocator);
    terminal.colors.background.set(.{ .r = 10, .g = 11, .b = 12 });
    terminal.colors.foreground.set(.{ .r = 19, .g = 20, .b = 21 });
    terminal.colors.cursor.set(.{ .r = 22, .g = 23, .b = 24 });
    terminal.colors.palette.set(2, .{ .r = 13, .g = 14, .b = 15 });

    applyColorDefaults(testing.allocator, &terminal, colorDefaults(&config));

    try testing.expectEqual(config.background.toTerminalRGB(), terminal.colors.background.default.?);
    try testing.expectEqual(color.RGB{ .r = 10, .g = 11, .b = 12 }, terminal.colors.background.get().?);
    try testing.expectEqual(config.foreground.toTerminalRGB(), terminal.colors.foreground.default.?);
    try testing.expectEqual(color.RGB{ .r = 19, .g = 20, .b = 21 }, terminal.colors.foreground.get().?);
    try testing.expectEqual(config.@"cursor-color".?.toTerminalRGB(), terminal.colors.cursor.default);
    try testing.expectEqual(color.RGB{ .r = 22, .g = 23, .b = 24 }, terminal.colors.cursor.get().?);
    try testing.expectEqual(config.palette.value[2], terminal.colors.palette.original[2]);
    try testing.expectEqual(color.RGB{ .r = 13, .g = 14, .b = 15 }, terminal.colors.palette.current[2]);
}

test "color defaults match the derivation in upstream's Termio" {
    const testing = std.testing;
    const Termio = @import("../termio/Termio.zig");

    const cases = [_]struct {
        generate: bool = false,
        harmonious: bool = false,
        set_entry: bool = false,
        cursor: ?Config.TerminalColor = null,
    }{
        .{},
        .{ .generate = true },
        .{ .generate = true, .set_entry = true },
        .{ .generate = true, .harmonious = true, .set_entry = true },
        .{ .cursor = .{ .color = .{ .r = 16, .g = 17, .b = 18 } } },
        .{ .cursor = .@"cell-foreground" },
    };

    for (cases) |case| {
        var config = try Config.default(testing.allocator);
        defer config.deinit();
        config.background = .{ .r = 1, .g = 2, .b = 3 };
        config.foreground = .{ .r = 250, .g = 251, .b = 252 };
        config.@"palette-generate" = case.generate;
        config.@"palette-harmonious" = case.harmonious;
        if (case.set_entry) {
            config.palette.value[3] = .{ .r = 7, .g = 8, .b = 9 };
            config.palette.mask.set(3);
        }
        config.@"cursor-color" = case.cursor;

        var derived = try Termio.DerivedConfig.init(testing.allocator, &config);
        defer derived.deinit();
        const defaults = colorDefaults(&config);

        try testing.expectEqual(derived.palette, defaults.palette);
        try testing.expectEqual(derived.background.toTerminalRGB(), defaults.background);
        try testing.expectEqual(derived.foreground.toTerminalRGB(), defaults.foreground);
        const cursor: ?color.RGB = if (derived.cursor_color) |value| value.toTerminalRGB() else null;
        try testing.expectEqual(cursor, defaults.cursor);
    }
}
