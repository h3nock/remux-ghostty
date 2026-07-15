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
/// caller must serialize all access and must not call `feed` reentrantly.
/// Commands may be submitted synchronously from an action callback. A returned
/// `feed` error is terminal. Command-admission errors leave logical state
/// unchanged and the client usable. An `exit` action cancels every unresolved
/// host token; later feeds are ignored and command submissions return
/// `ChannelClosed`.
pub const ControlClient = struct {
    channel: channel_pkg.Channel,
    viewer: Viewer,
    state: State = .active,

    const State = enum {
        active,
        closed,
        failed,
    };

    pub const Action = union(enum) {
        exit,
        windows: []const Viewer.Window,
        pane_changed: usize,
        command_complete: CommandCompletion,
    };
    pub const CommandCompletion = struct {
        token: channel_pkg.CommandToken,
        result: Result,

        pub const Result = union(enum) {
            success: []const u8,
            error_block: []const u8,
            skipped_after_error: channel_pkg.CommandToken,
        };
    };
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

    /// Bytes awaiting transport. The slice is invalidated by the next `feed`,
    /// `enqueueCommandGroup`, or `consumeOutbound` call.
    pub fn outboundBytes(self: *const ControlClient) []const u8 {
        if (self.state != .active) return &.{};
        return self.channel.outboundBytes();
    }

    pub fn consumeOutbound(
        self: *ControlClient,
        n: usize,
    ) channel_pkg.Channel.ConsumeError!void {
        return self.channel.consumeOutbound(n);
    }

    /// Borrow the canonical session name. The slice remains valid until the
    /// next `feed` call or `deinit`. Serialize this read with all other
    /// ControlClient calls.
    pub fn sessionName(self: *const ControlClient) []const u8 {
        return self.viewer.session_name;
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

    /// Submit one standalone command (`members.len == 1`) or one
    /// semicolon-dependent command group. Repeated calls are independent
    /// newline groups and share Channel's contiguous outbound buffer. One
    /// token is returned per member and later identifies its host completion.
    pub fn enqueueCommandGroup(
        self: *ControlClient,
        members: []const []const u8,
        tokens_out: []channel_pkg.CommandToken,
    ) Error!void {
        switch (self.state) {
            .active => {},
            .closed => return error.ChannelClosed,
            .failed => return error.ClientFailed,
        }
        if (tokens_out.len != members.len) return error.InvalidTokenCount;
        if (members.len == 0) return error.InvalidCommand;

        try self.channel.enqueueCommandGroup(members, tokens_out);
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
        switch (self.state) {
            .active => {},
            .closed => return,
            .failed => return error.ClientFailed,
        }

        var event_handler: EventHandler(@TypeOf(handler)) = .{
            .client = self,
            .host = handler,
        };
        self.channel.feed(bytes, &event_handler) catch |err| {
            self.state = .failed;
            return err;
        };
        if (event_handler.err) |err| {
            self.state = .failed;
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
                if (self.err != null or self.client.state != .active) return;
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
                    .command_ok => |command| try self.handleCommandCompletion(
                        command.token,
                        command.source,
                        .{ .success = command.body },
                        .{ .success = command.body },
                    ),
                    .command_failed => |command| switch (command.failure) {
                        // Channel emits these immediately before its terminal
                        // event. The terminal event closes Viewer exactly once;
                        // it is not a tmux command rejection.
                        .channel_closed => {},
                        .error_block => |body| try self.handleCommandCompletion(
                            command.token,
                            command.source,
                            .failure,
                            .{ .error_block = body },
                        ),
                        .skipped_after_error => |cause| try self.handleCommandCompletion(
                            command.token,
                            command.source,
                            .failure,
                            .{ .skipped_after_error = cause },
                        ),
                    },
                    .exited, .aborted => try self.handleViewer(.{ .tmux = .exit }),
                }
            }

            fn handleCommandCompletion(
                self: *Self,
                token: channel_pkg.CommandToken,
                source: channel_pkg.CommandSource,
                viewer_completion: Viewer.CommandCompletion,
                host_result: CommandCompletion.Result,
            ) Error!void {
                switch (source) {
                    .viewer => try self.handleViewer(.{
                        .command_complete = viewer_completion,
                    }),
                    .host => self.emitHost(.{ .command_complete = .{
                        .token = token,
                        .result = host_result,
                    } }),
                }
            }

            fn handleViewer(
                self: *Self,
                input: Viewer.Input,
            ) Error!void {
                for (self.client.viewer.next(input)) |action| switch (action) {
                    .command => |group| try self.enqueueGroup(group),
                    .exit => self.emitHost(.exit),
                    .windows => |windows| self.emitHost(.{ .windows = windows }),
                    .pane_changed => |pane_id| self.emitHost(.{
                        .pane_changed = pane_id,
                    }),
                };
            }

            fn emitHost(self: *Self, action: Action) void {
                if (action == .exit) self.client.state = .closed;
                self.host.controlClientAction(action);
            }

            fn enqueueGroup(
                self: *Self,
                group: Viewer.CommandGroup,
            ) Error!void {
                assertValidGroup(group);
                if (group.members.len == 1) {
                    _ = try self.client.channel.enqueueCommandFrom(
                        .viewer,
                        group.members[0],
                    );
                    return;
                }

                try self.client.channel.enqueueCommandGroupFrom(
                    .viewer,
                    group.members,
                    null,
                );
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
        command_success: channel_pkg.CommandToken,
        command_error: channel_pkg.CommandToken,
        command_skipped: struct {
            token: channel_pkg.CommandToken,
            cause: channel_pkg.CommandToken,
        },
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
            .command_complete => |completion| switch (completion.result) {
                .success => .{ .command_success = completion.token },
                .error_block => .{ .command_error = completion.token },
                .skipped_after_error => |cause| .{ .command_skipped = .{
                    .token = completion.token,
                    .cause = cause,
                } },
            },
        };
        self.records.append(std.testing.allocator, recorded) catch @panic("OOM");
    }
};

fn openReadyTestClient(
    client: *ControlClient,
    actions: *TestActions,
) !void {
    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n%end 3 3 1\n",
        actions,
    );
    actions.records.clearRetainingCapacity();
}

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
            "list-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout}'\n",
        client.outboundBytes(),
    );
}

test "control client owns and replaces session name" {
    const testing = std.testing;
    var tracking = testing.FailingAllocator.init(testing.allocator, .{});

    var client = try ControlClient.init(tracking.allocator(), .{});
    var client_live = true;
    defer if (client_live) client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openReadyTestClient(&client, &actions);

    // Opening the ready client reused the parser storage that supplied the
    // borrowed notification name.
    try testing.expectEqualStrings("main", client.sessionName());

    try client.feed("%session-changed $43 replacement\n", &actions);

    try testing.expectEqualStrings("replacement", client.sessionName());

    client.deinit();
    client_live = false;
    try testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
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
            "$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
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
    try testing.expect(std.mem.endsWith(u8, outbound, "\nlist-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout}'\n"));
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
            "$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
            "%end 3 3 1\n" ++
            "%window-add @1\n",
        &actions,
    );
    var pending_host: [1]channel_pkg.CommandToken = undefined;
    try client.enqueueCommandGroup(&.{"display-message -p pending-host"}, &pending_host);
    try client.feed(
        "%begin 4 4 1\n" ++
            "%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;0;43;8,16\n" ++
            "%end 4 4 1\n" ++
            "%begin 5 5 1\nfailed\n%error 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\npending-host\n%end 7 7 1\n",
        &actions,
    );

    var exits: usize = 0;
    for (actions.records.items) |action| if (action == .exit) {
        exits += 1;
    };
    try testing.expectEqual(1, exits);
    var host_completions: usize = 0;
    for (actions.records.items) |action| switch (action) {
        .command_success, .command_error, .command_skipped => host_completions += 1,
        else => {},
    };
    try testing.expectEqual(0, host_completions);
    try testing.expectEqualStrings("", client.outboundBytes());
    try testing.expectEqual(channel_pkg.Channel.State.running, client.channel.state);
    var token: [1]channel_pkg.CommandToken = undefined;
    try testing.expectError(
        error.ChannelClosed,
        client.enqueueCommandGroup(&.{"must-not-run-after-exit"}, &token),
    );
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
            "$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
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

test "control client submits independent host commands in one outbound buffer" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openReadyTestClient(&client, &actions);

    var first: [1]channel_pkg.CommandToken = undefined;
    var second: [1]channel_pkg.CommandToken = undefined;
    try client.enqueueCommandGroup(&.{"display-message -p one"}, &first);
    try client.enqueueCommandGroup(&.{"display-message -p two"}, &second);
    try testing.expectEqualStrings(
        "display-message -p one\ndisplay-message -p two\n",
        client.outboundBytes(),
    );

    try client.feed(
        "%begin 4 4 1\none\n%end 4 4 1\n" ++
            "%begin 5 5 1\ntwo\n%end 5 5 1\n",
        &actions,
    );
    try testing.expectEqual(2, actions.records.items.len);
    try testing.expectEqual(first[0], actions.records.items[0].command_success);
    try testing.expectEqual(second[0], actions.records.items[1].command_success);
}

test "control client host group failure preserves later independent command" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openReadyTestClient(&client, &actions);

    var group: [3]channel_pkg.CommandToken = undefined;
    var later: [1]channel_pkg.CommandToken = undefined;
    try client.enqueueCommandGroup(&.{ "first", "second", "third" }, &group);
    try client.enqueueCommandGroup(&.{"later"}, &later);
    try testing.expectEqualStrings(
        "first ; second ; third\nlater\n",
        client.outboundBytes(),
    );

    try client.feed(
        "%begin 4 4 1\n%end 4 4 1\n" ++
            "%begin 5 5 1\nfailed\n%error 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n",
        &actions,
    );
    try testing.expectEqual(4, actions.records.items.len);
    try testing.expectEqual(group[0], actions.records.items[0].command_success);
    try testing.expectEqual(group[1], actions.records.items[1].command_error);
    try testing.expectEqual(group[2], actions.records.items[2].command_skipped.token);
    try testing.expectEqual(group[1], actions.records.items[2].command_skipped.cause);
    try testing.expectEqual(later[0], actions.records.items[3].command_success);
    try testing.expect(client.viewer.command_queue.empty());
    try testing.expectEqual(0, client.viewer.sent_command_count);
}

test "control client callback submission bypasses viewer correlation" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    const Handler = struct {
        client: *ControlClient,
        token: ?channel_pkg.CommandToken = null,
        completion_count: usize = 0,

        pub fn controlClientAction(self: *@This(), action: ControlClient.Action) void {
            switch (action) {
                .windows => {
                    var tokens: [1]channel_pkg.CommandToken = undefined;
                    self.client.enqueueCommandGroup(
                        &.{"display-message -p host"},
                        &tokens,
                    ) catch @panic("callback submission failed");
                    self.token = tokens[0];
                },
                .command_complete => |completion| {
                    if (completion.token != self.token.?) {
                        @panic("wrong host completion token");
                    }
                    self.completion_count += 1;
                },
                else => {},
            }
        }
    };
    var handler: Handler = .{ .client = &client };

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        &handler,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n%end 3 3 1\n",
        &handler,
    );
    try testing.expect(handler.token != null);
    try testing.expectEqualStrings("display-message -p host\n", client.outboundBytes());
    try testing.expectEqual(0, handler.completion_count);

    try client.feed("%begin 4 4 1\nhost\n%end 4 4 1\n", &handler);
    try testing.expectEqual(1, handler.completion_count);
}

test "control client command admission rejects without mutation" {
    const testing = std.testing;
    const sentinel: channel_pkg.CommandToken = @enumFromInt(999);

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var token = [1]channel_pkg.CommandToken{sentinel};
    try testing.expectError(
        error.NotReady,
        client.enqueueCommandGroup(&.{"valid"}, &token),
    );
    try testing.expectEqual(sentinel, token[0]);
    try testing.expect(client.viewer.command_queue.empty());
    try testing.expectEqualStrings("", client.outboundBytes());

    var actions: TestActions = .{};
    defer actions.deinit();
    try openReadyTestClient(&client, &actions);
    try testing.expectError(
        error.InvalidCommand,
        client.enqueueCommandGroup(&.{}, &.{}),
    );
    try testing.expectError(
        error.InvalidCommand,
        client.enqueueCommandGroup(&.{"one\ntwo"}, &token),
    );
    try testing.expectError(
        error.InvalidTokenCount,
        client.enqueueCommandGroup(&.{ "one", "two" }, &token),
    );
    try testing.expectEqual(sentinel, token[0]);
    try testing.expect(client.viewer.command_queue.empty());
    try testing.expectEqualStrings("", client.outboundBytes());
}

test "control client allocation failure leaves submission atomic" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});

    var client = try ControlClient.init(failing.allocator(), .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openReadyTestClient(&client, &actions);

    const command = try testing.allocator.alloc(u8, 8192);
    defer testing.allocator.free(command);
    @memset(command, 'x');
    var token: [1]channel_pkg.CommandToken = undefined;

    failing.fail_index = failing.alloc_index;
    try testing.expectError(
        error.OutOfMemory,
        client.enqueueCommandGroup(&.{command}, &token),
    );
    try testing.expect(client.viewer.command_queue.empty());
    try testing.expectEqualStrings("", client.outboundBytes());

    failing.fail_index = std.math.maxInt(usize);
    try client.enqueueCommandGroup(&.{"later"}, &token);
    try testing.expectEqualStrings("later\n", client.outboundBytes());
}
