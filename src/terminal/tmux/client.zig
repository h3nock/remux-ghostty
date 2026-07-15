//! Transport-independent composition of the tmux Channel and Viewer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SharedTerminal = @import("../Shared.zig");
const channel_pkg = @import("channel.zig");
const Viewer = @import("viewer.zig").Viewer;

/// A sans-I/O tmux control-mode client.
///
/// Channel exclusively owns framing and FIFO response correlation. Viewer
/// owns tmux session state and command meaning. The host feeds transport bytes
/// through `feed`, drains `outboundBytes`, and acknowledges writes with
/// `consumeOutbound`. Host actions are delivered synchronously and never
/// contain `.command`; command groups are synchronously enqueued into Channel.
/// Action payloads are borrowed only for the duration of the callback. The
/// caller must serialize all access and must not call `feed` reentrantly. Any
/// returned error is terminal for this client.
pub const ControlClient = struct {
    channel: channel_pkg.Channel,
    viewer: Viewer,
    failed: bool = false,

    pub const Action = Viewer.Action;
    pub const Options = Viewer.Options;
    pub const Error = channel_pkg.Channel.EnqueueError ||
        channel_pkg.Channel.FeedError ||
        error{ClientFailed};

    pub fn init(
        alloc: Allocator,
        options: Options,
    ) Allocator.Error!ControlClient {
        var channel = try channel_pkg.Channel.init(alloc);
        errdefer channel.deinit();

        return .{
            .channel = channel,
            .viewer = try .init(alloc, options),
        };
    }

    pub fn deinit(self: *ControlClient) void {
        self.channel.deinit();
        self.viewer.deinit();
    }

    /// Bytes awaiting transport. The slice is invalidated by the next `feed`
    /// or `consumeOutbound` call.
    pub fn outboundBytes(self: *const ControlClient) []const u8 {
        return self.channel.outboundBytes();
    }

    pub fn consumeOutbound(
        self: *ControlClient,
        n: usize,
    ) channel_pkg.Channel.ConsumeError!void {
        return self.channel.consumeOutbound(n);
    }

    /// Retain the canonical terminal for `pane_id`, or return null if that
    /// pane is unknown. Serialize this lookup with other ControlClient calls.
    /// The caller must release the returned owner. It may outlive the pane and
    /// this client; every Terminal access must hold the owner's mutex.
    pub fn retainPaneTerminal(
        self: *ControlClient,
        pane_id: usize,
    ) ?*SharedTerminal {
        const pane = self.viewer.panes.get(pane_id) orelse return null;
        return pane.retainTerminal();
    }

    /// Process bytes received from a tmux control-mode connection.
    ///
    /// The handler must provide `controlClientAction(Action)`. It is called
    /// synchronously for each non-command Viewer action. Borrowed payloads are
    /// valid only during that callback.
    pub fn feed(
        self: *ControlClient,
        bytes: []const u8,
        handler: anytype,
    ) Error!void {
        if (self.failed) return error.ClientFailed;

        var event_handler: EventHandler(@TypeOf(handler)) = .{
            .client = self,
            .host = handler,
        };
        self.channel.feed(bytes, &event_handler) catch |err| {
            self.failed = true;
            return err;
        };
        if (event_handler.err) |err| {
            self.failed = true;
            return err;
        }
    }

    fn EventHandler(comptime Host: type) type {
        return struct {
            const Self = @This();

            client: *ControlClient,
            host: Host,
            err: ?Error = null,

            pub fn channelEvent(self: *Self, event: channel_pkg.Event) void {
                if (self.err != null) return;
                self.handleEvent(event) catch |err| {
                    self.err = err;
                };
            }

            fn handleEvent(
                self: *Self,
                event: channel_pkg.Event,
            ) Error!void {
                switch (event) {
                    .handshake_ok => try self.handleViewer(.handshake_ok),
                    .notification => |notification| try self.handleViewer(.{
                        .tmux = notification,
                    }),
                    .command_ok => |command| try self.handleViewer(.{
                        .command_complete = .{ .success = command.body },
                    }),
                    .command_failed => |command| switch (command.failure) {
                        // Channel emits these immediately before its terminal
                        // event. The terminal event closes Viewer exactly once;
                        // it is not a tmux command rejection.
                        .channel_closed => {},
                        .error_block, .skipped_after_error => try self.handleViewer(.{
                            .command_complete = .failure,
                        }),
                    },
                    .exited, .aborted => try self.handleViewer(.{ .tmux = .exit }),
                }
            }

            fn handleViewer(
                self: *Self,
                input: Viewer.Input,
            ) Error!void {
                for (self.client.viewer.next(input)) |action| switch (action) {
                    .command => |group| try self.enqueueGroup(group),
                    .exit, .windows, .pane_changed => self.host.controlClientAction(action),
                };
            }

            fn enqueueGroup(
                self: *Self,
                group: Viewer.CommandGroup,
            ) Error!void {
                assertValidGroup(group);
                if (group.members.len == 1) {
                    _ = try self.client.channel.enqueueCommand(group.members[0]);
                    return;
                }

                try self.client.channel.enqueueCommandGroup(group.members, null);
            }

            fn assertValidGroup(group: Viewer.CommandGroup) void {
                std.debug.assert(group.members.len > 0);
                for (group.members) |member| {
                    std.debug.assert(member.len > 0);
                    std.debug.assert(std.mem.indexOfAny(u8, member, "\r\n") == null);
                }
            }
        };
    }
};

const TestActions = struct {
    records: std.ArrayList(Recorded) = .empty,

    const Recorded = union(enum) {
        exit,
        windows: usize,
        pane_changed: usize,
    };

    fn deinit(self: *TestActions) void {
        self.records.deinit(std.testing.allocator);
    }

    pub fn controlClientAction(
        self: *TestActions,
        action: ControlClient.Action,
    ) void {
        const recorded: Recorded = switch (action) {
            .exit => .exit,
            .windows => |windows| .{ .windows = windows.len },
            .pane_changed => |pane_id| .{ .pane_changed = pane_id },
            .command => unreachable,
        };
        self.records.append(std.testing.allocator, recorded) catch @panic("OOM");
    }
};

test "control client sends startup commands before either response" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        &actions,
    );
    try testing.expectEqual(0, actions.records.items.len);
    try testing.expectEqualStrings(
        "display-message -p '#{version}'\n" ++
            "list-windows -F '#{session_id} #{window_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout}'\n",
        client.outboundBytes(),
    );
}

test "control client hydrates as one group and keeps later command independent" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n" ++
            "%session-changed $42 main\n" ++
            "%begin 2 2 1\n3.5a\n%end 2 2 1\n" ++
            "%begin 3 3 1\n" ++
            "$0 @0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
            "%end 3 3 1\n" ++
            "%window-add @1\n",
        &actions,
    );

    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .windows);
    const outbound = client.outboundBytes();
    try testing.expectEqual(4, std.mem.count(u8, outbound, " ; "));
    try testing.expect(std.mem.startsWith(u8, outbound, "display-message"));
    try testing.expect(std.mem.containsAtLeast(
        u8,
        outbound,
        1,
        "list-panes -s",
    ));
    try testing.expect(std.mem.endsWith(u8, outbound, "\nlist-windows -F '#{session_id} #{window_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout}'\n"));
}

test "control client hydration error skips only its group" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n" ++
            "%session-changed $42 main\n" ++
            "%begin 2 2 1\n3.5a\n%end 2 2 1\n" ++
            "%begin 3 3 1\n" ++
            "$0 @0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
            "%end 3 3 1\n" ++
            "%window-add @1\n" ++
            "%begin 4 4 1\n" ++
            "%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;0;43;8,16\n" ++
            "%end 4 4 1\n" ++
            "%begin 5 5 1\nfailed\n%error 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n",
        &actions,
    );

    var exits: usize = 0;
    for (actions.records.items) |action| if (action == .exit) {
        exits += 1;
    };
    try testing.expectEqual(1, exits);
    try testing.expectEqual(channel_pkg.Channel.State.running, client.channel.state);
}

test "control client server block cannot consume a Viewer command" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n" ++
            "%session-changed $42 main\n" ++
            "%begin 2 2 0\nserver\n%end 2 2 0\n",
        &actions,
    );
    try testing.expectEqual(2, client.viewer.sent_command_count);

    try client.feed(
        "%begin 3 3 1\n3.5a\n%end 3 3 1\n",
        &actions,
    );
    try testing.expectEqualStrings("3.5a", client.viewer.tmux_version);
    try testing.expectEqual(1, client.viewer.sent_command_count);
}

test "control client forwards partial outbound consumption" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        &actions,
    );

    const prefix_len = "display-message".len;
    const expected = try testing.allocator.dupe(u8, client.outboundBytes()[prefix_len..]);
    defer testing.allocator.free(expected);
    try client.consumeOutbound(prefix_len);
    try testing.expectEqualStrings(expected, client.outboundBytes());
    try testing.expectError(
        error.InvalidByteCount,
        client.consumeOutbound(client.outboundBytes().len + 1),
    );
}

test "control client emits exit once" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed("%exit detached\n", &actions);
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .exit);

    try client.feed("%exit again\n", &actions);
    try testing.expectEqual(1, actions.records.items.len);
}

test "control client closes without rejecting pending viewer commands" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        &actions,
    );
    try testing.expectEqual(2, client.viewer.sent_command_count);

    try client.feed("%exit detached\n", &actions);
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .exit);
    try testing.expectEqual(2, client.viewer.sent_command_count);
}

test "control client enqueue failure is terminal" {
    const testing = std.testing;
    const input = "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n";
    var observed_enqueue_failure = false;

    for (0..64) |fail_index| {
        var failing = testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        var client = ControlClient.init(failing.allocator(), .{}) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer client.deinit();
        var actions: TestActions = .{};
        defer actions.deinit();

        client.feed(input, &actions) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectError(
                error.ClientFailed,
                client.feed("%exit\n", &actions),
            );
            observed_enqueue_failure = true;
            break;
        };
    }

    try testing.expect(observed_enqueue_failure);
}

test "control client malformed stream exits" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed("x", &actions);
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .exit);
    try client.feed("%", &actions);
    try testing.expectEqual(1, actions.records.items.len);
}

test "control client retained pane terminal outlives client" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    var client_live = true;
    defer if (client_live) client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try testing.expect(client.retainPaneTerminal(99) == null);

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n" ++
            "%session-changed $42 main\n" ++
            "%begin 2 2 1\n3.5a\n%end 2 2 1\n" ++
            "%begin 3 3 1\n" ++
            "$0 @0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
            "%end 3 3 1\n",
        &actions,
    );

    const retained = client.retainPaneTerminal(0).?;
    const same_terminal = client.retainPaneTerminal(0).?;
    try testing.expectEqual(retained, same_terminal);
    try testing.expectEqual(&retained.terminal, &same_terminal.terminal);
    same_terminal.release();

    client.deinit();
    client_live = false;
    defer retained.release();

    retained.mutex.lock();
    defer retained.mutex.unlock();
    try testing.expectEqual(83, retained.terminal.cols);
    try testing.expectEqual(44, retained.terminal.rows);
    try retained.terminal.printString("alive");
    const contents = try retained.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("alive", contents);
}
