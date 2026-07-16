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
        exit: ExitReason,
        windows: []const Viewer.Window,
        pane_changed: usize,
        command_complete: CommandCompletion,
        input_failed: []const u8,
    };
    pub const ExitReason = Viewer.ExitReason;
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
    pub const PanePhase = enum {
        hydrating,
        live,
    };
    pub const Error = channel_pkg.Channel.EnqueueError ||
        channel_pkg.Channel.FeedError ||
        error{ ClientFailed, PaneUnknown };

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
    /// `enqueueCommand`, `enqueueCommandGroup`, `sendPaneInput`, or
    /// `consumeOutbound` call.
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

    /// Return the canonical hydration phase for `pane_id`, or null if that
    /// pane is unknown. Serialize this read with all other ControlClient calls.
    pub fn panePhase(
        self: *const ControlClient,
        pane_id: usize,
    ) ?PanePhase {
        const pane = self.viewer.panes.get(pane_id) orelse return null;
        return switch (pane.phase) {
            .initial_hydrating, .refreshing => .hydrating,
            .live => .live,
        };
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

    /// Rehydrate one live pane into its existing canonical terminal. This does
    /// not select, zoom, or otherwise change tmux presentation. The host may
    /// enqueue those commands immediately before this call; Channel preserves
    /// that outbound order without requiring an intervening transport write.
    /// Successful submission moves the pane to `hydrating` synchronously. Its
    /// next pane-changed action is the deterministic live completion.
    pub fn refreshPane(
        self: *ControlClient,
        pane_id: usize,
    ) Error!void {
        try self.validateCommandAdmission();

        const Submitter = struct {
            channel: *channel_pkg.Channel,

            pub fn submitPaneRefresh(
                value: @This(),
                members: []const []const u8,
            ) channel_pkg.Channel.EnqueueError!void {
                try value.channel.enqueueCommandGroupFrom(
                    .viewer,
                    members,
                    null,
                );
            }
        };
        try self.viewer.refreshPane(pane_id, Submitter{
            .channel = &self.channel,
        });
    }

    /// Send already-encoded terminal bytes to one known pane as an independent
    /// tmux command. Empty input validates admission and pane identity but
    /// emits no command. Terminal-mode encoding remains the host's concern.
    pub fn sendPaneInput(
        self: *ControlClient,
        pane_id: usize,
        bytes: []const u8,
    ) Error!void {
        try self.validateCommandAdmission();
        if (self.channel.state == .handshake) return error.NotReady;
        if (!self.viewer.panes.contains(pane_id)) return error.PaneUnknown;
        if (bytes.len == 0) return;

        const prefix = "send-keys -H -t %";
        var id_buffer: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buffer, "{d}", .{pane_id}) catch
            unreachable;
        const encoded_len = std.math.mul(usize, bytes.len, 3) catch
            return error.OutOfMemory;
        const command_len = std.math.add(
            usize,
            prefix.len + id.len,
            encoded_len,
        ) catch return error.OutOfMemory;

        // Normal key sequences stay entirely on the stack. Larger payloads
        // use one temporary allocation solely to preserve one atomic Channel
        // command; Channel remains the only owner of queued outbound bytes.
        var stack: [256]u8 = undefined;
        const heap = command_len > stack.len;
        const command = if (heap)
            try self.channel.alloc.alloc(u8, command_len)
        else
            stack[0..command_len];
        defer if (heap) self.channel.alloc.free(command);

        var offset: usize = 0;
        @memcpy(command[offset..][0..prefix.len], prefix);
        offset += prefix.len;
        @memcpy(command[offset..][0..id.len], id);
        offset += id.len;
        const hex = "0123456789abcdef";
        for (bytes) |byte| {
            command[offset] = ' ';
            command[offset + 1] = hex[byte >> 4];
            command[offset + 2] = hex[byte & 0x0f];
            offset += 3;
        }
        std.debug.assert(offset == command.len);

        _ = try self.channel.enqueueCommandFrom(.input, command);
    }

    /// Submit one standalone command as its own newline-delimited group.
    /// The returned token later identifies its host completion.
    pub fn enqueueCommand(
        self: *ControlClient,
        text: []const u8,
    ) Error!channel_pkg.CommandToken {
        try self.validateCommandAdmission();
        return self.channel.enqueueCommand(text);
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
        try self.validateCommandAdmission();
        if (tokens_out.len != members.len) return error.InvalidTokenCount;
        if (members.len == 0) return error.InvalidCommand;

        try self.channel.enqueueCommandGroup(members, tokens_out);
    }

    fn validateCommandAdmission(
        self: *const ControlClient,
    ) error{ ChannelClosed, ClientFailed }!void {
        switch (self.state) {
            .active => {},
            .closed => return error.ChannelClosed,
            .failed => return error.ClientFailed,
        }
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
            handler.controlClientAction(.{ .exit = .client_failure });
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
                    .exited => |detail| try self.handleViewer(.{ .tmux = .{
                        .exit = detail,
                    } }),
                    .aborted => self.emitHost(.{ .exit = .client_failure }),
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
                    .input => switch (host_result) {
                        .success => {},
                        .error_block => |body| self.emitHost(.{
                            .input_failed = body,
                        }),
                        // Input is admitted only through sendPaneInput as a
                        // standalone newline group, so it has no skipped
                        // group members.
                        .skipped_after_error => unreachable,
                    },
                }
            }

            fn handleViewer(
                self: *Self,
                input: Viewer.Input,
            ) Error!void {
                for (self.client.viewer.next(input)) |action| switch (action) {
                    .command => |group| try self.enqueueGroup(group),
                    .exit => |reason| self.emitHost(.{ .exit = reason }),
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
    exit_reason: ?std.meta.Tag(ControlClient.ExitReason) = null,
    exit_detail: [128]u8 = undefined,
    exit_detail_len: usize = 0,
    input_failure_body: [128]u8 = undefined,
    input_failure_len: usize = 0,

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
        input_failed,
    };

    fn deinit(self: *TestActions) void {
        self.records.deinit(std.testing.allocator);
    }

    pub fn controlClientAction(
        self: *TestActions,
        action: ControlClient.Action,
    ) void {
        const recorded: Recorded = switch (action) {
            .exit => |reason| exit: {
                self.exit_reason = std.meta.activeTag(reason);
                const detail: []const u8 = switch (reason) {
                    .server_exit, .unsupported_version => |value| value,
                    .client_failure => &.{},
                };
                if (detail.len > self.exit_detail.len) {
                    @panic("exit detail too long");
                }
                @memcpy(self.exit_detail[0..detail.len], detail);
                self.exit_detail_len = detail.len;
                break :exit .exit;
            },
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
            .input_failed => |body| input_failed: {
                if (body.len > self.input_failure_body.len) {
                    @panic("input failure body too long");
                }
                @memcpy(self.input_failure_body[0..body.len], body);
                self.input_failure_len = body.len;
                break :input_failed .input_failed;
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

fn openHydratingPaneTestClient(
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
            "%begin 3 3 1\n" ++
            "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
            "%end 3 3 1\n",
        actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();
    actions.input_failure_len = 0;
}

fn openPaneTestClient(
    client: *ControlClient,
    actions: *TestActions,
) !void {
    try openHydratingPaneTestClient(client, actions);
    try client.feed(
        "%begin 4 4 1\n%end 4 4 1\n" ++
            "%begin 5 5 1\n%end 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\n%end 8 8 1\n",
        actions,
    );
    actions.records.clearRetainingCapacity();
    actions.input_failure_len = 0;
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

test "control client reports initial size between version and topology" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{
        .initial_client_size = .{ .columns = 117, .rows = 41 },
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        &actions,
    );
    try testing.expectEqualStrings(
        "display-message -p '#{version}'\n" ++
            "refresh-client -C 117x41\n" ++
            "list-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout}'\n",
        client.outboundBytes(),
    );
    try testing.expectEqual(3, client.viewer.sent_command_count);

    try client.feed(
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n%end 3 3 1\n" ++
            "%begin 4 4 1\n%end 4 4 1\n",
        &actions,
    );
    try testing.expectEqual(0, client.viewer.sent_command_count);
    try testing.expect(client.viewer.command_queue.empty());
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .windows);
}

test "control client size error stays in Viewer FIFO" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{
        .initial_client_size = .{ .columns = 117, .rows = 41 },
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        &actions,
    );
    const host_token = try client.enqueueCommand("display-message -p host");
    try client.feed(
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\ninvalid size\n%error 3 3 1\n",
        &actions,
    );

    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .exit);
    try testing.expectEqual(
        std.meta.Tag(ControlClient.ExitReason).client_failure,
        actions.exit_reason.?,
    );
    try testing.expectEqual(0, actions.exit_detail_len);
    try testing.expectEqual(1, client.viewer.sent_command_count);
    try testing.expectEqual(1, client.viewer.command_queue.len());
    var pending = client.channel.pending.iterator(.forward);
    try testing.expectEqual(channel_pkg.CommandSource.viewer, pending.next().?.source);
    const host = pending.next().?;
    try testing.expectEqual(channel_pkg.CommandSource.host, host.source);
    try testing.expectEqual(host_token, host.token);
    try testing.expect(pending.next() == null);
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

test "control client close notifications produce no outbound work" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    try testing.expectEqualStrings("", client.outboundBytes());
    try client.feed("%window-close @0\n", &actions);
    try testing.expectEqualStrings("", client.outboundBytes());
    try testing.expectEqual(1, client.viewer.windows.items.len);
    try testing.expectEqual(1, client.viewer.panes.count());

    try client.feed(
        "%unlinked-window-close @0\n" ** 4,
        &actions,
    );
    try testing.expectEqualStrings("", client.outboundBytes());
    try testing.expectEqual(0, client.viewer.windows.items.len);
    try testing.expectEqual(0, client.viewer.panes.count());
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .windows);
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
            "%0;83;44;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;0;43;8,16\n" ++
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

test "control client emits borrowed server exit detail once" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed("%exit detached\n", &actions);
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .exit);
    try testing.expectEqual(
        std.meta.Tag(ControlClient.ExitReason).server_exit,
        actions.exit_reason.?,
    );
    try testing.expectEqualStrings(
        "detached",
        actions.exit_detail[0..actions.exit_detail_len],
    );

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
            try testing.expectEqual(1, actions.records.items.len);
            try testing.expect(actions.records.items[0] == .exit);
            try testing.expectEqual(
                std.meta.Tag(ControlClient.ExitReason).client_failure,
                actions.exit_reason.?,
            );
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
    try testing.expectEqual(
        std.meta.Tag(ControlClient.ExitReason).client_failure,
        actions.exit_reason.?,
    );
    try client.feed("%", &actions);
    try testing.expectEqual(1, actions.records.items.len);
}

test "control client reports unsupported tmux version detail" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        &actions,
    );
    try client.feed("%begin 2 2 1\n3.0a\n%end 2 2 1\n", &actions);

    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .exit);
    try testing.expectEqual(
        std.meta.Tag(ControlClient.ExitReason).unsupported_version,
        actions.exit_reason.?,
    );
    try testing.expectEqualStrings(
        "3.0a",
        actions.exit_detail[0..actions.exit_detail_len],
    );
}

test "control client exposes pane phase and retained terminal lifetime" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    var client_live = true;
    defer if (client_live) client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try testing.expect(client.panePhase(99) == null);
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
    try testing.expectEqual(
        ControlClient.PanePhase.hydrating,
        client.panePhase(0).?,
    );

    try client.feed(
        "%begin 4 4 1\n%end 4 4 1\n" ++
            "%begin 5 5 1\n%end 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\n%end 8 8 1\n",
        &actions,
    );
    try testing.expectEqual(
        ControlClient.PanePhase.live,
        client.panePhase(0).?,
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

test "control client pane refresh admission and command order" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try testing.expectError(error.NotReady, client.refreshPane(0));
    try openHydratingPaneTestClient(&client, &actions);
    try testing.expectError(error.NotReady, client.refreshPane(0));
    try testing.expectError(error.PaneUnknown, client.refreshPane(99));

    try client.feed(
        "%begin 4 4 1\n%end 4 4 1\n" ++
            "%begin 5 5 1\n%end 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\n%end 8 8 1\n",
        &actions,
    );
    actions.records.clearRetainingCapacity();

    _ = try client.enqueueCommand("select-pane -Z -t %0");
    try client.refreshPane(0);
    try testing.expectEqual(ControlClient.PanePhase.hydrating, client.panePhase(0).?);
    try testing.expectError(error.NotReady, client.refreshPane(0));

    const outbound = client.outboundBytes();
    try testing.expect(std.mem.startsWith(
        u8,
        outbound,
        "select-pane -Z -t %0\ndisplay-message -p -t %0 -F ",
    ));
    const state_index = std.mem.indexOf(
        u8,
        outbound,
        "display-message -p -t %0 -F ",
    ).?;
    const history_index = std.mem.indexOf(u8, outbound, "capture-pane -p -e -N -q -S -").?;
    const saved_index = std.mem.indexOf(u8, outbound, "capture-pane -p -e -N -a").?;
    const visible_index = std.mem.indexOfPos(u8, outbound, saved_index + 1, "capture-pane -p -e -N -q -t %0").?;
    const pending_index = std.mem.indexOf(u8, outbound, "capture-pane -p -P -C -t %0").?;
    try testing.expect(state_index < history_index);
    try testing.expect(history_index < saved_index);
    try testing.expect(saved_index < visible_index);
    try testing.expect(visible_index < pending_index);
    try testing.expectEqual(4, std.mem.count(u8, outbound[state_index..], " ; "));
}

test "control client pane refresh preserves identity and output cut" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    const retained = client.retainPaneTerminal(0).?;
    defer retained.release();
    {
        retained.mutex.lock();
        defer retained.mutex.unlock();
        try retained.terminal.setTitle("pane title");
        try retained.terminal.setPwd("file:///work");
        retained.terminal.colors.background.set(.{ .r = 10, .g = 11, .b = 12 });
        retained.terminal.colors.palette.set(3, .{ .r = 13, .g = 14, .b = 15 });
    }

    try client.feed("%output %0 before\n", &actions);
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .pane_changed);
    try testing.expectEqualStrings("", client.outboundBytes());
    actions.records.clearRetainingCapacity();

    try client.refreshPane(0);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%output %0 during\n", &actions);
    try testing.expectEqual(0, actions.records.items.len);

    try client.feed(
        "%begin 9 9 1\n" ++
            "%0;100;40;12;0;1;block;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;0;39;8,16\n" ++
            "%end 9 9 1\n",
        &actions,
    );
    try testing.expectEqual(0, actions.records.items.len);
    try testing.expectEqual(ControlClient.PanePhase.hydrating, client.panePhase(0).?);
    const same = client.retainPaneTerminal(0).?;
    defer same.release();
    try testing.expectEqual(retained, same);
    {
        retained.mutex.lock();
        defer retained.mutex.unlock();
        try testing.expectEqual(100, retained.terminal.cols);
        try testing.expectEqual(40, retained.terminal.rows);
        const blank = try retained.terminal.plainString(testing.allocator);
        defer testing.allocator.free(blank);
        try testing.expectEqualStrings("", blank);
        try testing.expectEqualStrings("pane title", retained.terminal.getTitle().?);
        try testing.expectEqualStrings("file:///work", retained.terminal.getPwd().?);
        try testing.expectEqual(@as(u8, 10), retained.terminal.colors.background.get().?.r);
        try testing.expectEqual(@as(u8, 13), retained.terminal.colors.palette.current[3].r);
    }

    try client.feed(
        "%begin 10 10 1\n%end 10 10 1\n" ++
            "%begin 11 11 1\n%end 11 11 1\n" ++
            "%begin 12 12 1\nbeforeduring\n%end 12 12 1\n" ++
            "%begin 13 13 1\n%end 13 13 1\n",
        &actions,
    );
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(@as(usize, 0), actions.records.items[0].pane_changed);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
    actions.records.clearRetainingCapacity();

    try client.feed("%output %0 after\n", &actions);
    try testing.expectEqual(1, actions.records.items.len);
    retained.mutex.lock();
    defer retained.mutex.unlock();
    const contents = try retained.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("beforeduringafter", contents);
}

test "control client refresh failure is pane local" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    try client.refreshPane(0);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 9 9 1\npane gone\n%error 9 9 1\n", &actions);
    try testing.expectEqual(0, actions.records.items.len);
    try testing.expectEqual(ControlClient.PanePhase.hydrating, client.panePhase(0).?);
    try testing.expect(client.viewer.command_queue.empty());
    try testing.expectEqual(0, client.viewer.sent_command_count);

    const token = try client.enqueueCommand("display-message -p still-alive");
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 10 10 1\nstill-alive\n%end 10 10 1\n",
        &actions,
    );
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(token, actions.records.items[0].command_success);
    actions.records.clearRetainingCapacity();

    try client.feed("%unlinked-window-close @0\n", &actions);
    try testing.expect(client.panePhase(0) == null);
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .windows);
}

test "control client serializes exact binary pane input" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    try client.sendPaneInput(0, &.{ 'A', 0x00, 0x1b, 0x7f, 0x80, 0xff });
    try testing.expectEqualStrings(
        "send-keys -H -t %0 41 00 1b 7f 80 ff\n",
        client.outboundBytes(),
    );
}

test "control client pane input validates without no-op mutation" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try testing.expectError(error.NotReady, client.sendPaneInput(0, &.{}));
    try openPaneTestClient(&client, &actions);

    const next_token = client.channel.next_token;
    try client.sendPaneInput(0, &.{});
    try testing.expectEqual(next_token, client.channel.next_token);
    try testing.expectEqualStrings("", client.outboundBytes());
    try testing.expectError(error.PaneUnknown, client.sendPaneInput(99, &.{}));
    try testing.expectEqual(next_token, client.channel.next_token);
    try testing.expectEqualStrings("", client.outboundBytes());

    try client.sendPaneInput(0, "a");
    try client.sendPaneInput(0, "\n");
    try testing.expectEqualStrings(
        "send-keys -H -t %0 61\n" ++
            "send-keys -H -t %0 0a\n",
        client.outboundBytes(),
    );
}

test "control client pane input completion stays independently correlated" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openHydratingPaneTestClient(&client, &actions);

    const before = try client.enqueueCommand("display-message -p before");
    try client.sendPaneInput(0, "a");
    try client.sendPaneInput(0, "b");
    const after = try client.enqueueCommand("display-message -p after");
    try client.feed(
        "%begin 4 4 1\n%end 4 4 1\n" ++
            "%begin 5 5 1\n%end 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\n%end 8 8 1\n" ++
            "%begin 9 9 1\nbefore\n%end 9 9 1\n" ++
            "%begin 10 10 1\n%end 10 10 1\n" ++
            "%begin 11 11 1\npane input rejected\n%error 11 11 1\n" ++
            "%begin 12 12 1\nafter\n%end 12 12 1\n",
        &actions,
    );

    try testing.expectEqual(4, actions.records.items.len);
    try testing.expectEqual(0, actions.records.items[0].pane_changed);
    try testing.expectEqual(before, actions.records.items[1].command_success);
    try testing.expect(actions.records.items[2] == .input_failed);
    try testing.expectEqual(after, actions.records.items[3].command_success);
    try testing.expectEqualStrings(
        "pane input rejected",
        actions.input_failure_body[0..actions.input_failure_len],
    );
}

test "control client pane input formatting failure is allocation atomic" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});

    var client = try ControlClient.init(failing.allocator(), .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    const bytes = [_]u8{'x'} ** 128;
    const next_token = client.channel.next_token;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(
        error.OutOfMemory,
        client.sendPaneInput(0, &bytes),
    );
    try testing.expectEqual(next_token, client.channel.next_token);
    try testing.expectEqualStrings("", client.outboundBytes());
}

test "control client submits independent host commands in one outbound buffer" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openReadyTestClient(&client, &actions);

    const first = try client.enqueueCommand("display-message -p one");
    const second = try client.enqueueCommand("display-message -p two");
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
    try testing.expectEqual(first, actions.records.items[0].command_success);
    try testing.expectEqual(second, actions.records.items[1].command_success);
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
