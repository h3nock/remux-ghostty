const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: oni.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    /// The action associated with a match. Renderers do not interpret this,
    /// but interaction owners use the same compiled link set.
    action: inputpkg.Link.Action,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }

    /// Returns true if this link's highlight condition matches the given mouse state.
    fn active(
        self: *const Link,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) bool {
        return switch (self.highlight) {
            .always => true,
            .always_mods => |v| mouse_mods.equal(v),
            .hover => mouse_viewport != null,
            .hover_mods => |v| mouse_viewport != null and mouse_mods.equal(v),
        };
    }
};

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
                .action = link.action,
            });
        }

        return .{ .links = try links.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Return the first configured link match containing `pin`.
    ///
    /// A null modifier snapshot intentionally ignores configured modifier
    /// requirements. This is used by direct-selection gestures such as a
    /// double click or long press. A non-null snapshot preserves Surface's
    /// clickable-link policy.
    pub fn matchAtPin(
        self: *const Set,
        alloc: Allocator,
        screen: *Screen,
        pin: terminal.Pin,
        mods: ?inputpkg.Mods,
    ) !?Match {
        if (self.links.len == 0) return null;

        const line = screen.selectLine(.{
            .pin = pin,
            .whitespace = null,
            .semantic_prompt_boundary = true,
        }) orelse return null;

        var map: terminal.StringMap = undefined;
        alloc.free(try screen.selectionString(alloc, .{
            .sel = line,
            .trim = false,
            .map = &map,
        }));
        defer map.deinit(alloc);

        for (self.links) |link| {
            if (mods) |value| switch (link.highlight) {
                .always, .hover => {},
                .always_mods, .hover_mods => |required| {
                    if (!required.equal(value)) continue;
                },
            };

            var it = map.searchIterator(link.regex);
            while (true) {
                var match = (try it.next()) orelse break;
                defer match.deinit();
                const selection = match.selection();
                if (!selection.contains(screen, pin)) continue;
                return .{
                    .action = link.action,
                    .selection = selection,
                };
            }
        }

        return null;
    }

    /// Fills matches with the matches from regex link matches.
    pub fn renderCellMap(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        render_state: *const terminal.RenderState,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // Fast path, not very likely since we have default links.
        if (self.links.len == 0) return;

        // Determine if any links are active before building the string and
        // byte-to-cell map. Those buffers scale with viewport size and this
        // function runs during frame updates, so avoid allocating them when
        // the current mouse/modifier state can't highlight any regex links.
        for (self.links) |*link| {
            if (link.active(mouse_viewport, mouse_mods)) break;
        } else return;

        // Convert our render state to a string + byte map.
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var map: terminal.RenderState.StringMap = .empty;
        defer map.deinit(alloc);
        try render_state.string(&builder.writer, .{
            .alloc = alloc,
            .map = &map,
        });

        const str = builder.writer.buffered();

        // Go through each link and see if we have any matches.
        for (self.links) |*link| {
            if (!link.active(mouse_viewport, mouse_mods)) continue;

            var offset: usize = 0;
            while (offset < str.len) {
                var region = link.regex.search(
                    str[offset..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => break,
                    else => return err,
                };
                defer region.deinit();

                // We have a match!
                const offset_start: usize = @intCast(region.starts()[0]);
                const offset_end: usize = @intCast(region.ends()[0]);
                const start = offset + offset_start;
                const end = offset + offset_end;

                // Increment our offset by the number of bytes in the match.
                // We defer this so that we can return the match before
                // modifying the offset.
                defer offset = end;

                switch (link.highlight) {
                    .always, .always_mods => {},
                    .hover, .hover_mods => if (mouse_viewport) |vp| {
                        for (map.items[start..end]) |pt| {
                            if (pt.eql(vp)) break;
                        } else continue;
                    } else continue,
                }

                // Record the match
                for (map.items[start..end]) |pt| {
                    try result.put(alloc, pt, {});
                }
            }
        }
    }
};

pub const Match = struct {
    action: inputpkg.Link.Action,
    selection: terminal.Selection,
};

test "renderCellMap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            null,
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            .{ .x = 1, .y = 0 },
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}

test "renderCellMap inactive links don't allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },

        .{
            .regex = "IJ",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .shift = true } },
        },
    });
    defer set.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    const failing_alloc = failing.allocator();

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(failing_alloc);
    try set.renderCellMap(
        failing_alloc,
        &result,
        &state,
        null,
        .{},
    );

    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderCellMap mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );

    // Test our matches
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "matchAtPin follows soft wraps, config priority, and optional modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var screen = try Screen.init(alloc, .{
        .cols = 8,
        .rows = 4,
        .max_scrollback = 0,
    });
    defer screen.deinit();
    try screen.testWriteString("xxhttps://example.com rest");

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "https://[^ ]+",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .ctrl = true } },
        },
        .{
            .regex = "example\\.com",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    const pin = screen.pages.pin(.{ .active = .{
        .x = 2,
        .y = 1,
    } }).?;
    try testing.expect(try set.matchAtPin(
        alloc,
        &screen,
        pin,
        .{},
    ) == null);

    const match = (try set.matchAtPin(
        alloc,
        &screen,
        pin,
        null,
    )).?;
    try testing.expect(match.action == .open);
    const text = try screen.selectionString(alloc, .{
        .sel = match.selection,
        .trim = false,
    });
    defer alloc.free(text);
    try testing.expectEqualStrings("https://example.com", text);

    try testing.expect((try set.matchAtPin(
        alloc,
        &screen,
        pin,
        .{ .ctrl = true },
    )) != null);
}

test "matchAtPin respects semantic prompt boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var screen = try Screen.init(alloc, .{
        .cols = 16,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer screen.deinit();
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("p");
    screen.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try screen.testWriteString("target");

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = "ptarget",
        .action = .{ .open = {} },
        .highlight = .{ .always = {} },
    }});
    defer set.deinit(alloc);

    const pin = screen.pages.pin(.{ .active = .{
        .x = 3,
        .y = 0,
    } }).?;
    try testing.expect(try set.matchAtPin(
        alloc,
        &screen,
        pin,
        null,
    ) == null);
}
