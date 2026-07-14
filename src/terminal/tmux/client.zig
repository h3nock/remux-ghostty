//! Transport-independent composition of the tmux control parser and Viewer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const control = @import("control.zig");
const Viewer = @import("viewer.zig").Viewer;

/// A sans-I/O tmux control-mode client.
///
/// The host owns transport and feeds received bytes through `put`. Returned
/// actions must be consumed or copied before the next call. In particular, if
/// a `.command` action cannot be written, the host must terminate the client
/// because Viewer already considers that command in flight. The caller must
/// serialize all access. An allocation error is terminal for this client.
pub const ControlClient = struct {
    parser: control.Parser,
    viewer: Viewer,

    pub const Action = Viewer.Action;
    pub const Options = Viewer.Options;

    pub fn init(
        alloc: Allocator,
        options: Options,
    ) Allocator.Error!ControlClient {
        return .{
            .parser = .{ .buffer = .init(alloc) },
            .viewer = try .init(alloc, options),
        };
    }

    pub fn deinit(self: *ControlClient) void {
        self.parser.deinit();
        self.viewer.deinit();
    }

    /// Process one byte received from a tmux control-mode connection.
    ///
    /// An empty slice means either the notification is incomplete or it did
    /// not produce a host action. Any returned payload is borrowed until the
    /// next call to `put`.
    pub fn put(
        self: *ControlClient,
        byte: u8,
    ) Allocator.Error![]const Action {
        const notification = try self.parser.put(byte) orelse return &.{};
        return self.viewer.next(.{ .tmux = notification });
    }
};

test "control client raw startup preserves action order" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();

    const expected = [_]enum { display_message, list_windows, windows, hydrate_panes, pane_changed }{
        .display_message,
        .list_windows,
        .windows,
        .hydrate_panes,
        .pane_changed,
    };
    var actual: [expected.len]@TypeOf(expected[0]) = undefined;
    var actual_len: usize = 0;

    const input =
        "%begin 1 1 1\n" ++
        "%end 1 1 1\n" ++
        "%session-changed $42 main\n" ++
        "%begin 2 2 1\n" ++
        "3.5a\n" ++
        "%end 2 2 1\n" ++
        "%begin 3 3 1\n" ++
        "$0 @0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
        "%end 3 3 1\n" ++
        "%begin 4 4 1\n" ++
        "%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;0;43;8,16\n" ++
        "%end 4 4 1\n" ++
        "%begin 5 5 1\n" ++
        "%end 5 5 1\n" ++
        "%begin 6 6 1\n" ++
        "%end 6 6 1\n" ++
        "%begin 7 7 1\n" ++
        "%end 7 7 1\n" ++
        "%begin 8 8 1\n" ++
        "%end 8 8 1\n";

    for (input) |byte| {
        for (try client.put(byte)) |action| {
            try testing.expect(actual_len < actual.len);
            switch (action) {
                .exit => return error.UnexpectedExit,
                .windows => |windows| {
                    try testing.expectEqual(1, windows.len);
                    try testing.expectEqual(0, windows[0].id);
                    actual[actual_len] = .windows;
                },
                .pane_changed => |id| {
                    try testing.expectEqual(0, id);
                    try testing.expectEqual(
                        Viewer.Pane.Phase.live,
                        client.viewer.panes.get(id).?.phase,
                    );
                    actual[actual_len] = .pane_changed;
                },
                .command => |command| {
                    try testing.expect(std.mem.endsWith(u8, command, "\n"));
                    actual[actual_len] = if (std.mem.startsWith(
                        u8,
                        command,
                        "display-message",
                    ))
                        .display_message
                    else if (std.mem.startsWith(u8, command, "list-windows"))
                        .list_windows
                    else if (std.mem.startsWith(u8, command, "list-panes -s")) hydrate: {
                        try testing.expect(std.mem.containsAtLeast(
                            u8,
                            command,
                            1,
                            " -S - -E -1 ",
                        ));
                        break :hydrate .hydrate_panes;
                    } else return error.UnexpectedCommand;
                },
            }
            actual_len += 1;
        }
    }

    try testing.expectEqual(expected.len, actual_len);
    try testing.expectEqualSlices(@TypeOf(expected[0]), &expected, &actual);
    try testing.expectEqual(Viewer.Pane.Phase.live, client.viewer.panes.get(0).?.phase);
    try testing.expect(client.viewer.command_queue.empty());
}

test "control client raw exit" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();

    var exits: usize = 0;
    for ("%exit detached\n") |byte| {
        for (try client.put(byte)) |action| switch (action) {
            .exit => exits += 1,
            else => return error.UnexpectedAction,
        };
    }
    try testing.expectEqual(1, exits);

    for ("%exit again\n") |byte| {
        try testing.expectEqual(0, (try client.put(byte)).len);
    }
}

test "control client malformed stream exits" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();

    const actions = try client.put('x');
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
    try testing.expectEqual(0, (try client.put('%')).len);
}

test "control client propagates parser buffer failure" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    client.parser.max_bytes = 1;

    try testing.expectEqual(0, (try client.put('%')).len);
    try testing.expectError(error.OutOfMemory, client.put('x'));
    try testing.expectEqual(0, (try client.put('\n')).len);
}
