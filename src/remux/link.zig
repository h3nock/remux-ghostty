//! Link selection for TerminalSurface: the configured links with their
//! actions, and OSC 8 hyperlink runs. Upstream's renderer keeps its own link
//! set for highlighting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const hyperlink = @import("../terminal/hyperlink.zig");
const Page = terminal.Page;
const Pin = terminal.Pin;
const Screen = terminal.Screen;
const Selection = terminal.Selection;

pub const Link = struct {
    regex: oni.Regex,
    highlight: inputpkg.Link.Highlight,
    action: inputpkg.Link.Action,
};

/// The configured links, compiled once per configuration.
pub const Set = struct {
    links: []Link,

    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);
        errdefer for (links.items) |*link| link.regex.deinit();

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
        for (self.links) |*link| link.regex.deinit();
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
        pin: Pin,
        mods: ?inputpkg.Mods,
    ) !?Match {
        if (self.links.len == 0) return null;

        const line = screen.selectLine(.{
            .pin = pin,
            .whitespace = null,
            .semantic_prompt_boundary = true,
        }) orelse return null;

        const map = try screen.selectionStringMap(alloc, .{
            .sel = line,
            .trim = false,
        });
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
};

pub const Match = struct {
    action: inputpkg.Link.Action,
    selection: Selection,
};

pub const HyperlinkSelection = struct {
    selection: Selection,

    /// Borrowed from page storage and valid only while the screen is locked
    /// against mutation.
    uri: []const u8,
};

const HyperlinkRef = struct {
    page: *const Page,
    entry: *const hyperlink.PageEntry,

    fn init(pin: Pin) ?HyperlinkRef {
        const page = pin.node.page();
        const id = page.lookupHyperlink(pin.rowAndCell().cell) orelse
            return null;
        return .{
            .page = page,
            .entry = page.hyperlink_set.get(page.memory, id),
        };
    }

    fn eql(self: HyperlinkRef, other: HyperlinkRef) bool {
        return self.entry.eql(
            self.page.memory,
            other.entry,
            other.page.memory,
        );
    }
};

/// Return the contiguous OSC 8 hyperlink run containing `pin`.
///
/// Hyperlink identifiers are page-local, so equality is based on the decoded
/// hyperlink identity and URI rather than the numeric page entry ID. The URI
/// borrows page memory and must not escape synchronization around the screen.
pub fn selectHyperlink(pin: Pin) ?HyperlinkSelection {
    const origin = HyperlinkRef.init(pin) orelse return null;

    const start: Pin = start: {
        var result = pin;
        var it = pin.cellIterator(.left_up, null);
        _ = it.next(); // Skip `pin` itself.
        while (it.next()) |candidate| {
            const candidate_link = HyperlinkRef.init(candidate) orelse break;
            if (!origin.eql(candidate_link)) break;
            result = candidate;
        }
        break :start result;
    };

    const end: Pin = end: {
        var result = pin;
        var it = pin.cellIterator(.right_down, null);
        _ = it.next(); // Skip `pin` itself.
        while (it.next()) |candidate| {
            const candidate_link = HyperlinkRef.init(candidate) orelse break;
            if (!origin.eql(candidate_link)) break;
            result = candidate;
        }
        break :end result;
    };

    return .{
        .selection = .init(start, end, false),
        .uri = origin.entry.uri.slice(origin.page.memory),
    };
}

test "matchAtPin follows soft wraps, config priority, and optional modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var screen = try Screen.init(testing.io, alloc, .{
        .cols = 8,
        .rows = 4,
        .max_scrollback_bytes = 0,
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

    var screen = try Screen.init(testing.io, alloc, .{
        .cols = 16,
        .rows = 2,
        .max_scrollback_bytes = 0,
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

test "selectHyperlink exact contiguous span" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(testing.io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();

    try s.startHyperlink("https://example.com/target", null);
    try s.testWriteString("abcdefg");
    s.endHyperlink();
    try s.testWriteString("x");

    const match = selectHyperlink(s.pages.pin(.{ .active = .{
        .x = 0,
        .y = 1,
    } }).?).?;
    try testing.expectEqualStrings("https://example.com/target", match.uri);
    try testing.expectEqual(terminal.point.Point{ .screen = .{
        .x = 0,
        .y = 0,
    } }, s.pages.pointFromPin(.screen, match.selection.start()).?);
    try testing.expectEqual(terminal.point.Point{ .screen = .{
        .x = 1,
        .y = 1,
    } }, s.pages.pointFromPin(.screen, match.selection.end()).?);

    try testing.expect(selectHyperlink(s.pages.pin(.{ .active = .{
        .x = 2,
        .y = 1,
    } }).?) == null);
}

test "selectHyperlink separates adjacent implicit links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(testing.io, alloc, .{ .cols = 8, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();

    try s.startHyperlink("https://example.com/same", null);
    try s.testWriteString("abc");
    s.endHyperlink();
    try s.startHyperlink("https://example.com/same", null);
    try s.testWriteString("de");
    s.endHyperlink();

    const match = selectHyperlink(s.pages.pin(.{ .active = .{
        .x = 3,
        .y = 0,
    } }).?).?;
    try testing.expectEqual(terminal.point.Point{ .screen = .{
        .x = 3,
        .y = 0,
    } }, s.pages.pointFromPin(.screen, match.selection.start()).?);
    try testing.expectEqual(terminal.point.Point{ .screen = .{
        .x = 4,
        .y = 0,
    } }, s.pages.pointFromPin(.screen, match.selection.end()).?);
}
