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
        pane_changed: Viewer.PaneChange,
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
    pub const PaneInfo = struct {
        phase: PanePhase,
        current_command: []const u8,
        current_path: []const u8,
    };
    pub const Error = channel_pkg.Channel.EnqueueError ||
        channel_pkg.Channel.FeedError ||
        error{ ClientFailed, InvalidInput, PaneUnknown, WindowUnknown };

    pub fn init(
        io: std.Io,
        alloc: Allocator,
        options: Options,
    ) Allocator.Error!ControlClient {
        var channel = try channel_pkg.Channel.init(alloc);
        errdefer channel.deinit();

        return .{
            .channel = channel,
            .viewer = try .init(io, alloc, options),
        };
    }

    pub fn deinit(self: *ControlClient) void {
        self.channel.deinit();
        self.viewer.deinit();
    }

    /// Bytes awaiting transport. The slice is invalidated by the next `feed`,
    /// `enqueueCommand`, `enqueueCommandGroup`, `sendPaneInput`,
    /// `sendPaneInputTracked`, `sendPaneLiteralInputTracked`, `refreshPane`,
    /// `refreshWindowPaneMetadata`, `setClientSize`, or `consumeOutbound`
    /// call.
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
        return (self.paneInfo(pane_id) orelse return null).phase;
    }

    /// Borrow topology state for `pane_id`. String values remain valid until
    /// the next serialized client operation.
    pub fn paneInfo(
        self: *const ControlClient,
        pane_id: usize,
    ) ?PaneInfo {
        const pane = self.viewer.panes.get(pane_id) orelse return null;
        return .{
            .phase = switch (pane.phase) {
                .initial_hydrating => .hydrating,

                // A recapture replaces the contents only once complete.
                .refresh_pausing, .refreshing, .live => .live,
            },
            .current_command = pane.current_command,
            .current_path = pane.current_path,
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

    /// End `pane_id`'s render hold (see `Viewer.PaneChange.render_hold`), or
    /// return false if that pane is unknown. The host calls this when a hold
    /// outlasts its timeout, then wakes the pane's renderer. Serialize this
    /// call with other ControlClient calls.
    pub fn endRenderHold(self: *ControlClient, pane_id: usize) bool {
        const pane = self.viewer.panes.get(pane_id) orelse return false;
        pane.endRenderHold();
        return true;
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

    /// Resize the control client. Each pane's mirror follows tmux's resize
    /// with tmux's own row rules when the reply arrives; panes it can't
    /// follow exactly are recaptured. While a resize or recapture is in
    /// flight only the newest size is kept and sent afterwards.
    pub fn setClientSize(
        self: *ControlClient,
        client_size: Viewer.ClientSize,
    ) Error!void {
        try self.validateCommandAdmission();

        const Submitter = struct {
            channel: *channel_pkg.Channel,

            pub fn submitClientResize(
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
        try self.viewer.setClientSize(client_size, Submitter{
            .channel = &self.channel,
        });
    }

    /// Refresh current command and path metadata for every pane in one window.
    /// This enqueues one list-panes command and does not capture or rehydrate
    /// terminal contents.
    pub fn refreshWindowPaneMetadata(
        self: *ControlClient,
        window_id: usize,
    ) Error!void {
        try self.validateCommandAdmission();

        const Submitter = struct {
            channel: *channel_pkg.Channel,

            pub fn submitPaneMetadataRefresh(
                value: @This(),
                command: []const u8,
            ) channel_pkg.Channel.EnqueueError!void {
                _ = try value.channel.enqueueCommandFrom(.viewer, command);
            }
        };
        try self.viewer.refreshWindowPaneMetadata(window_id, Submitter{
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

        _ = try self.enqueuePaneInput(.input, pane_id, bytes);
    }

    /// Send already-encoded terminal bytes to one known pane and return the
    /// token that identifies this exact command's eventual completion.
    pub fn sendPaneInputTracked(
        self: *ControlClient,
        pane_id: usize,
        bytes: []const u8,
    ) Error!channel_pkg.CommandToken {
        try self.validateCommandAdmission();
        if (self.channel.state == .handshake) return error.NotReady;
        if (!self.viewer.panes.contains(pane_id)) return error.PaneUnknown;
        if (bytes.len == 0) return error.InvalidInput;

        return self.enqueuePaneInput(.host, pane_id, bytes);
    }

    /// Send one nonempty UTF-8 terminal payload to a known pane as a single
    /// literal tmux argument and return this command's completion token.
    /// Unlike exact key input, this path cannot represent NUL bytes.
    pub fn sendPaneLiteralInputTracked(
        self: *ControlClient,
        pane_id: usize,
        bytes: []const u8,
    ) Error!channel_pkg.CommandToken {
        try self.validateCommandAdmission();
        if (self.channel.state == .handshake) return error.NotReady;
        if (!self.viewer.panes.contains(pane_id)) return error.PaneUnknown;
        if (bytes.len == 0 or
            std.mem.indexOfScalar(u8, bytes, 0) != null or
            !std.unicode.utf8ValidateSlice(bytes))
        {
            return error.InvalidInput;
        }

        return self.enqueuePaneLiteralInput(pane_id, bytes);
    }

    fn enqueuePaneInput(
        self: *ControlClient,
        source: channel_pkg.CommandSource,
        pane_id: usize,
        bytes: []const u8,
    ) Error!channel_pkg.CommandToken {
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

        return self.channel.enqueueCommandFrom(source, command);
    }

    fn enqueuePaneLiteralInput(
        self: *ControlClient,
        pane_id: usize,
        bytes: []const u8,
    ) Error!channel_pkg.CommandToken {
        const prefix = "send-keys -l -t %";
        const payload_prefix = " -- \"";
        var id_buffer: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buffer, "{d}", .{pane_id}) catch
            unreachable;

        var encoded_len: usize = 0;
        for (bytes) |byte| {
            const width: usize = if (literalByteNeedsEscape(byte)) 4 else 1;
            encoded_len = std.math.add(usize, encoded_len, width) catch
                return error.OutOfMemory;
        }
        const command_len = std.math.add(
            usize,
            prefix.len + id.len + payload_prefix.len + 1,
            encoded_len,
        ) catch return error.OutOfMemory;

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
        @memcpy(command[offset..][0..payload_prefix.len], payload_prefix);
        offset += payload_prefix.len;
        for (bytes) |byte| {
            if (literalByteNeedsEscape(byte)) {
                command[offset] = '\\';
                command[offset + 1] = '0' + (byte >> 6);
                command[offset + 2] = '0' + ((byte >> 3) & 0x07);
                command[offset + 3] = '0' + (byte & 0x07);
                offset += 4;
            } else {
                command[offset] = byte;
                offset += 1;
            }
        }
        command[offset] = '"';
        std.debug.assert(offset + 1 == command.len);

        return self.channel.enqueueCommandFrom(.host, command);
    }

    /// Bytes escaped as octal inside the double-quoted `send-keys -l`
    /// payload, per tmux(1) PARSING SYNTAX: inside double quotes tmux
    /// still replaces `$VAR`, expands a leading `~`, and decodes `\`
    /// escapes, and a raw `"` would terminate the argument. Control
    /// bytes and DEL are escaped because quoted strings cannot span
    /// lines and the control channel is newline-delimited. Everything
    /// else is literal in double quotes — including `;` and `#{...}`,
    /// which deliberately pass through unescaped.
    fn literalByteNeedsEscape(byte: u8) bool {
        return byte < 0x20 or byte == 0x7f or
            byte == '\\' or byte == '"' or byte == '$' or byte == '~';
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
                            .skipped,
                            .{ .skipped_after_error = cause },
                        ),
                        // The host gets no reply to use, so for it the
                        // command failed.
                        .reply_too_large => |head| try self.handleCommandCompletion(
                            command.token,
                            command.source,
                            .{ .too_large = head },
                            .{ .error_block = "reply too large" },
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
                    .pane_changed => |change| self.emitHost(.{
                        .pane_changed = change,
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
            .pane_changed => |change| .{ .pane_changed = change.pane_id },
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
    try openPaneTestClient(client, actions);
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
            "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell\n" ++
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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
            "list-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout} #{window_name}'\n",
        client.outboundBytes(),
    );
}

test "control client reports initial size between version and topology" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{
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
            "list-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout} #{window_name}'\n",
        client.outboundBytes(),
    );
    try testing.expectEqual(3, client.viewer.sent_command_count);

    try client.feed(
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n%end 3 3 1\n" ++
            "%begin 4 4 1\n" ++
            "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell\n" ++
            "%end 4 4 1\n",
        &actions,
    );
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .windows);

    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 5 5 1\n%end 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\n%end 8 8 1\n" ++
            "%begin 9 9 1\n%end 9 9 1\n",
        &actions,
    );
    try testing.expectEqual(0, client.viewer.sent_command_count);
    try testing.expect(client.viewer.command_queue.empty());
}

test "control client size error stays in Viewer FIFO" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{
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

    var client = try ControlClient.init(testing.io, tracking.allocator(), .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n" ++
            "%session-changed $42 main\n" ++
            "%begin 2 2 1\n3.5a\n%end 2 2 1\n" ++
            "%begin 3 3 1\n" ++
            "$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell\n" ++
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
    try testing.expect(std.mem.endsWith(u8, outbound, "\nlist-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout} #{window_name}'\n"));
}

test "control client close notifications produce no outbound work" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n" ++
            "%session-changed $42 main\n" ++
            "%begin 2 2 1\n3.5a\n%end 2 2 1\n" ++
            "%begin 3 3 1\n" ++
            "$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell\n" ++
            "%end 3 3 1\n",
        &actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();
    var pending_host: [1]channel_pkg.CommandToken = undefined;
    try client.enqueueCommandGroup(&.{"display-message -p pending-host"}, &pending_host);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 4 4 1\n" ++
            "%0;83;44;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;43;8,16;sh;/tmp\n" ++
            "%end 4 4 1\n" ++
            "%begin 5 5 1\nfailed\n%error 5 5 1\n" ++
            "%begin 6 6 1\npending-host\n%end 6 6 1\n",
        &actions,
    );

    try expectNoExit(&actions);
    const last = actions.records.items[actions.records.items.len - 1];
    try testing.expectEqual(pending_host[0], last.command_success);
    try testing.expectEqual(ControlClient.PanePhase.hydrating, client.panePhase(0).?);
    try testing.expectEqualStrings("list-panes -s -F '#{pane_id}'\n", client.outboundBytes());
}

/// A client attached to tmux 3.5a whose window @0 holds live pane %0 at
/// 100x30, the geometry of the hydration traces below.
fn openTracePaneTestClient(
    client: *ControlClient,
    actions: *TestActions,
) !void {
    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 2 2 1\n3.5a\n%end 2 2 1\n" ++
            "%begin 3 3 1\n" ++
            "$42 @0 1 %0 100 30 a87d,100x30,0,0,0 a87d,100x30,0,0,0 shell\n" ++
            "%end 3 3 1\n",
        actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 4 4 1\n%end 4 4 1\n" ++
            "%begin 5 5 1\n%end 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\n%end 8 8 1\n",
        actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();
}

fn expectNoExit(actions: *const TestActions) !void {
    for (actions.records.items) |action| try std.testing.expect(action != .exit);
}

/// Replies to the recapture the viewer starts for %0 when a layout change
/// resizes it: the pause, then the paused pane's snapshot group.
fn feedTraceRecapture(client: *ControlClient, actions: *TestActions, first: usize) !void {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (first..first + 7) |n| try writer.print("%begin {d} {d} 1\n%end {d} {d} 1\n", .{ n, n, n, n });
    try client.feed(writer.buffered(), actions);
    try client.consumeOutbound(client.outboundBytes().len);
}

test "control client survives a pane that closes before its hydration runs" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openTracePaneTestClient(&client, &actions);

    // tmux 3.5a, `split-window 'sleep 0.2'` hydrated 300 ms after the pane
    // appeared: both layout changes arrive first, the pane state lists only
    // %0, the capture of %2 is refused and tmux skips the rest of the group.
    try client.feed(
        "%layout-change @0 408b,100x30,0,0[100x15,0,0,0,100x14,0,16,2] 408b,100x30,0,0[100x15,0,0,0,100x14,0,16,2] *\n" ++
            "%layout-change @0 a87d,100x30,0,0,0 a87d,100x30,0,0,0 *\n",
        &actions,
    );
    try testing.expect(std.mem.indexOf(u8, client.outboundBytes(), "-t %2") != null);
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();
    try client.feed(
        "%begin 9 9 1\n%end 9 9 1\n" ++
            "%begin 10 10 1\ncan't find pane: %2\n%error 10 10 1\n",
        &actions,
    );
    try expectNoExit(&actions);
    try testing.expect(client.panePhase(2) == null);
    try testing.expectEqualStrings("", client.outboundBytes());

    try feedTraceRecapture(&client, &actions, 11);
    try expectNoExit(&actions);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);

    const token = try client.enqueueCommand("display-message -p still-alive");
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();
    try client.feed("%begin 18 18 1\nstill-alive\n%end 18 18 1\n", &actions);
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(token, actions.records.items[0].command_success);
}

test "control client hydrates again a pane tmux still lists after refusing its group" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openTracePaneTestClient(&client, &actions);

    // %1 and %2 appear in one layout change and %1 closes before their group
    // runs: tmux refuses %1 and skips every capture of %2.
    try client.feed(
        "%layout-change @0 d258,100x30,0,0[100x15,0,0,0,100x7,0,16,1,100x6,0,24,2] d258,100x30,0,0[100x15,0,0,0,100x7,0,16,1,100x6,0,24,2] *\n" ++
            "%layout-change @0 9d88,100x30,0,0[100x23,0,0,0,100x6,0,24,2] 9d88,100x30,0,0[100x23,0,0,0,100x6,0,24,2] *\n",
        &actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();
    try client.feed(
        "%begin 9 9 1\n%end 9 9 1\n" ++
            "%begin 10 10 1\ncan't find pane: %1\n%error 10 10 1\n",
        &actions,
    );
    try expectNoExit(&actions);
    try testing.expect(client.panePhase(1) == null);
    try testing.expectEqual(ControlClient.PanePhase.hydrating, client.panePhase(2).?);
    try testing.expectEqualStrings("list-panes -s -F '#{pane_id}'\n", client.outboundBytes());
    try client.consumeOutbound(client.outboundBytes().len);

    // The recapture of %0 was sent before the recheck; its pause reply comes
    // first.
    try client.feed("%begin 11 11 1\n%end 11 11 1\n", &actions);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 12 12 1\n%0\n%2\n%end 12 12 1\n", &actions);
    try expectNoExit(&actions);
    try testing.expect(std.mem.startsWith(u8, client.outboundBytes(), "list-panes -s -F '#{pane_id};"));
    try testing.expect(std.mem.indexOf(u8, client.outboundBytes(), "capture-pane -p -P -C -t %2") != null);
    try client.consumeOutbound(client.outboundBytes().len);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (13..24) |n| try writer.print("%begin {d} {d} 1\n%end {d} {d} 1\n", .{ n, n, n, n });
    try client.feed(writer.buffered(), &actions);
    try expectNoExit(&actions);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(2).?);
}

test "control client ends when tmux keeps listing a pane it refuses" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openTracePaneTestClient(&client, &actions);

    try client.feed(
        "%layout-change @0 408b,100x30,0,0[100x15,0,0,0,100x14,0,16,2] 408b,100x30,0,0[100x15,0,0,0,100x14,0,16,2] *\n",
        &actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();

    // Refused, listed, hydrated again and refused again: listed after that,
    // the refusal isn't a closed pane.
    try client.feed("%begin 9 9 1\n%end 9 9 1\n%begin 10 10 1\nrefused\n%error 10 10 1\n", &actions);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 11 11 1\n%end 11 11 1\n", &actions);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 12 12 1\n%0\n%2\n%end 12 12 1\n", &actions);
    try client.consumeOutbound(client.outboundBytes().len);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (13..19) |n| try writer.print("%begin {d} {d} 1\n%end {d} {d} 1\n", .{ n, n, n, n });
    try client.feed(writer.buffered(), &actions);
    try client.feed("%begin 19 19 1\n%end 19 19 1\n%begin 20 20 1\nrefused\n%error 20 20 1\n", &actions);
    try expectNoExit(&actions);
    try testing.expectEqualStrings("list-panes -s -F '#{pane_id}'\n", client.outboundBytes());
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 21 21 1\n%0\n%2\n%end 21 21 1\n", &actions);

    var exits: usize = 0;
    for (actions.records.items) |action| if (action == .exit) {
        exits += 1;
    };
    try testing.expectEqual(1, exits);
    try testing.expectEqual(.client_failure, actions.exit_reason.?);
}

test "control client hydrates a pane tmux only skipped after other panes closed twice" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openTracePaneTestClient(&client, &actions);

    // tmux 3.5a: a new window brings %1, %2 and %3, top to bottom, hydrated
    // in one group. %1 closes before that group runs and %2 before the retry
    // of %2 and %3, so tmux skips every capture of %3 twice without ever
    // refusing one.
    const state_0 = "%0;100;30;8;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;29;8,16,24,32,40,48,56,64,72,80,88,96;bash;/private/tmp";
    const state_3 = "%3;100;30;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;29;8,16,24,32,40,48,56,64,72,80,88,96;sleep;/private/tmp";
    try client.feed(
        "%window-renamed @0 bash\n%window-add @1\n" ++
            "%layout-change @1 527d,100x30,0,0[100x15,0,0,1,100x7,0,16,2,100x6,0,24,3] 527d,100x30,0,0[100x15,0,0,1,100x7,0,16,2,100x6,0,24,3] \n" ++
            "%layout-change @1 527d,100x30,0,0[100x15,0,0,1,100x7,0,16,2,100x6,0,24,3] 527d,100x30,0,0[100x15,0,0,1,100x7,0,16,2,100x6,0,24,3] \n" ++
            "%window-renamed @1 zsh\n",
        &actions,
    );
    try testing.expect(std.mem.startsWith(u8, client.outboundBytes(), "list-windows "));
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 1792879758 286 1\n" ++
            "$42 @0 1 %0 100 30 a87d,100x30,0,0,0 a87d,100x30,0,0,0 bash\n" ++
            "$42 @1 0 %1 100 30 527d,100x30,0,0[100x15,0,0,1,100x7,0,16,2,100x6,0,24,3] 527d,100x30,0,0[100x15,0,0,1,100x7,0,16,2,100x6,0,24,3] zsh\n" ++
            "%end 1792879758 286 1\n",
        &actions,
    );
    const first = client.outboundBytes();
    try testing.expect(std.mem.indexOf(u8, first, "-t %1 ;").? < std.mem.indexOf(u8, first, "-t %2 ;").?);
    try testing.expect(std.mem.indexOf(u8, first, "-t %2 ;").? < std.mem.indexOf(u8, first, "-t %3 ;").?);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%layout-change @1 1d91,100x30,0,0[100x23,0,0,2,100x6,0,24,3] 1d91,100x30,0,0[100x23,0,0,2,100x6,0,24,3] \n" ++
            "%window-pane-changed @1 %2\n%window-renamed @1 sleep\n" ++
            "%begin 1792879759 292 1\n" ++ state_0 ++ "\n" ++
            "%2;100;23;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;22;8,16,24,32,40,48,56,64,72,80,88,96;sleep;/private/tmp\n" ++
            "%3;100;6;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;5;8,16,24,32,40,48,56,64,72,80,88,96;sleep;/private/tmp\n" ++
            "%end 1792879759 292 1\n" ++
            "%begin 1792879759 293 1\ncan't find pane: %1\n%error 1792879759 293 1\n",
        &actions,
    );
    try expectNoExit(&actions);
    try testing.expectEqualStrings("list-panes -s -F '#{pane_id}'\n", client.outboundBytes());
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 1792879759 294 1\n%0\n%2\n%3\n%end 1792879759 294 1\n", &actions);
    const retry = client.outboundBytes();
    try testing.expect(std.mem.indexOf(u8, retry, "-t %2 ;").? < std.mem.indexOf(u8, retry, "-t %3 ;").?);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%layout-change @1 a880,100x30,0,0,3 a880,100x30,0,0,3 \n%window-pane-changed @1 %3\n" ++
            "%begin 1792879760 299 1\n" ++ state_0 ++ "\n" ++ state_3 ++ "\n%end 1792879760 299 1\n" ++
            "%begin 1792879760 300 1\ncan't find pane: %2\n%error 1792879760 300 1\n",
        &actions,
    );
    try expectNoExit(&actions);
    try testing.expectEqualStrings("list-panes -s -F '#{pane_id}'\n", client.outboundBytes());
    try client.consumeOutbound(client.outboundBytes().len);

    // tmux still lists %3. It never refused it, so it's hydrated again.
    try client.feed("%begin 1792879761 301 1\n%0\n%3\n%end 1792879761 301 1\n", &actions);
    try expectNoExit(&actions);
    try testing.expect(std.mem.indexOf(u8, client.outboundBytes(), "capture-pane -p -P -C -t %3\n") != null);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 1792879761 302 1\n" ++ state_0 ++ "\n" ++ state_3 ++ "\n%end 1792879761 302 1\n" ++
            "%begin 1792879761 303 1\n\n%end 1792879761 303 1\n" ++
            "%begin 1792879761 304 1\n\n%end 1792879761 304 1\n" ++
            "%begin 1792879761 305 1\n" ++ "\n" ** 30 ++ "%end 1792879761 305 1\n" ++
            "%begin 1792879761 306 1\n\n%end 1792879761 306 1\n",
        &actions,
    );
    try expectNoExit(&actions);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(3).?);
}

test "control client server block cannot consume a Viewer command" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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
        var client = ControlClient.init(testing.io, failing.allocator(), .{}) catch |err| {
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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
            "$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell\n" ++
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

    retained.mutex.lockUncancelable(retained.terminal.io());
    defer retained.mutex.unlock(retained.terminal.io());
    try testing.expectEqual(83, retained.terminal.cols);
    try testing.expectEqual(44, retained.terminal.rows);
    try retained.terminal.printString("alive");
    const contents = try retained.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("alive", contents);
}

test "control client pane refresh admission and command order" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
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

test "control client refreshes window pane metadata without hydration" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try testing.expectError(error.NotReady, client.refreshWindowPaneMetadata(0));
    try openPaneTestClient(&client, &actions);
    try testing.expectError(error.WindowUnknown, client.refreshWindowPaneMetadata(99));

    try client.refreshWindowPaneMetadata(0);
    try testing.expectEqualStrings(
        "list-panes -t @0 -F '#{pane_id};#{pane_current_command};#{pane_current_path}'\n",
        client.outboundBytes(),
    );
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);

    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 9 9 1\n%0;nvim;/work/editor;branch\n%end 9 9 1\n",
        &actions,
    );
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .windows);
    try testing.expectEqualStrings("nvim", client.paneInfo(0).?.current_command);
    try testing.expectEqualStrings("/work/editor;branch", client.paneInfo(0).?.current_path);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
    actions.records.clearRetainingCapacity();

    try client.refreshWindowPaneMetadata(0);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 10 10 1\n%0;nvim;/work/editor;branch\n%end 10 10 1\n",
        &actions,
    );
    try testing.expectEqual(0, actions.records.items.len);
}

test "control client window pane metadata failure is nonfatal" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    try client.refreshWindowPaneMetadata(0);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 9 9 1\ncan't find window: @0\n%error 9 9 1\n",
        &actions,
    );
    try testing.expectEqual(0, actions.records.items.len);

    const token = try client.enqueueCommand("display-message -p still-alive");
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 10 10 1\nstill-alive\n%end 10 10 1\n",
        &actions,
    );
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(token, actions.records.items[0].command_success);
}

test "control client pane refresh preserves identity and output cut" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    const retained = client.retainPaneTerminal(0).?;
    defer retained.release();
    {
        retained.mutex.lockUncancelable(retained.terminal.io());
        defer retained.mutex.unlock(retained.terminal.io());
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
            "%0;100;40;12;0;1;block;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;39;8,16;nvim;/work/editor\n" ++
            "%end 9 9 1\n",
        &actions,
    );
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expect(actions.records.items[0] == .windows);
    actions.records.clearRetainingCapacity();
    try testing.expectEqualStrings("nvim", client.paneInfo(0).?.current_command);
    try testing.expectEqualStrings("/work/editor", client.paneInfo(0).?.current_path);
    // The pane keeps its contents until the whole snapshot has arrived.
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
    const same = client.retainPaneTerminal(0).?;
    defer same.release();
    try testing.expectEqual(retained, same);
    {
        retained.mutex.lockUncancelable(retained.terminal.io());
        defer retained.mutex.unlock(retained.terminal.io());
        try testing.expectEqual(83, retained.terminal.cols);
        try testing.expectEqual(44, retained.terminal.rows);
        const kept = try retained.terminal.plainString(testing.allocator);
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings("before", kept);
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
    retained.mutex.lockUncancelable(retained.terminal.io());
    defer retained.mutex.unlock(retained.terminal.io());
    try testing.expectEqual(100, retained.terminal.cols);
    try testing.expectEqual(40, retained.terminal.rows);
    const contents = try retained.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("beforeduringafter", contents);
    try testing.expectEqualStrings("pane title", retained.terminal.getTitle().?);
    try testing.expectEqualStrings("file:///work", retained.terminal.getPwd().?);
    try testing.expectEqual(@as(u8, 10), retained.terminal.colors.background.get().?.r);
    try testing.expectEqual(@as(u8, 13), retained.terminal.colors.palette.current[3].r);
}

test "control client refresh failure is pane local" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    try client.refreshPane(0);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 9 9 1\npane gone\n%error 9 9 1\n", &actions);
    try testing.expectEqual(0, actions.records.items.len);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
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

/// Start a client on a traced tmux's replies to the startup queries,
/// leaving the hydration group they produce to be answered.
fn openTraceStartupTestClient(
    client: *ControlClient,
    actions: *TestActions,
    startup_replies: []const u8,
) !void {
    try client.feed(
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $0 ov\n",
        actions,
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(startup_replies, actions);
}

test "control client recaptures fewer history rows after their reply is too large" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{
        .history_line_limit = 2_000,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    // Traced from tmux 3.5a: a 6x2 pane whose seven history rows give every
    // cell its own 24-bit colors, as half-block image viewers print. With a
    // 1 KiB limit the seven rows are too large and three aren't.
    const row0 = "\x1b[38;2;0;0;0m\x1b[48;2;0;0;0m▀\x1b[38;2;0;30;15m\x1b[48;2;25;0;10m▀\x1b[38;2;0;60;30m\x1b[48;2;50;0;20m▀\x1b[38;2;0;90;45m\x1b[48;2;75;0;30m▀\x1b[38;2;0;120;60m\x1b[48;2;100;0;40m▀\x1b[38;2;0;150;75m\x1b[48;2;125;0;50m▀";
    const row1 = "\x1b[38;2;30;0;15m\x1b[48;2;0;30;0m▀\x1b[38;2;30;30;30m\x1b[48;2;25;30;10m▀\x1b[38;2;30;60;45m\x1b[48;2;50;30;20m▀\x1b[38;2;30;90;60m\x1b[48;2;75;30;30m▀\x1b[38;2;30;120;75m\x1b[48;2;100;30;40m▀\x1b[38;2;30;150;90m\x1b[48;2;125;30;50m▀";
    const row2 = "\x1b[38;2;60;0;30m\x1b[48;2;0;60;0m▀\x1b[38;2;60;30;45m\x1b[48;2;25;60;10m▀\x1b[38;2;60;60;60m\x1b[48;2;50;60;20m▀\x1b[38;2;60;90;75m\x1b[48;2;75;60;30m▀\x1b[38;2;60;120;90m\x1b[48;2;100;60;40m▀\x1b[38;2;60;150;105m\x1b[48;2;125;60;50m▀";
    const row3 = "\x1b[38;2;90;0;45m\x1b[48;2;0;90;0m▀\x1b[38;2;90;30;60m\x1b[48;2;25;90;10m▀\x1b[38;2;90;60;75m\x1b[48;2;50;90;20m▀\x1b[38;2;90;90;90m\x1b[48;2;75;90;30m▀\x1b[38;2;90;120;105m\x1b[48;2;100;90;40m▀\x1b[38;2;90;150;120m\x1b[48;2;125;90;50m▀";
    const row4 = "\x1b[38;2;120;0;60m\x1b[48;2;0;120;0m▀\x1b[38;2;120;30;75m\x1b[48;2;25;120;10m▀\x1b[38;2;120;60;90m\x1b[48;2;50;120;20m▀\x1b[38;2;120;90;105m\x1b[48;2;75;120;30m▀\x1b[38;2;120;120;120m\x1b[48;2;100;120;40m▀\x1b[38;2;120;150;135m\x1b[48;2;125;120;50m▀";
    const row5 = "\x1b[38;2;150;0;75m\x1b[48;2;0;150;0m▀\x1b[38;2;150;30;90m\x1b[48;2;25;150;10m▀\x1b[38;2;150;60;105m\x1b[48;2;50;150;20m▀\x1b[38;2;150;90;120m\x1b[48;2;75;150;30m▀\x1b[38;2;150;120;135m\x1b[48;2;100;150;40m▀\x1b[38;2;150;150;150m\x1b[48;2;125;150;50m▀";
    const row6 = "\x1b[38;2;180;0;90m\x1b[48;2;0;180;0m▀\x1b[38;2;180;30;105m\x1b[48;2;25;180;10m▀\x1b[38;2;180;60;120m\x1b[48;2;50;180;20m▀\x1b[38;2;180;90;135m\x1b[48;2;75;180;30m▀\x1b[38;2;180;120;150m\x1b[48;2;100;180;40m▀\x1b[38;2;180;150;165m\x1b[48;2;125;180;50m▀";
    const row7 = "\x1b[38;2;210;0;105m\x1b[48;2;0;210;0m▀\x1b[38;2;210;30;120m\x1b[48;2;25;210;10m▀\x1b[38;2;210;60;135m\x1b[48;2;50;210;20m▀\x1b[38;2;210;90;150m\x1b[48;2;75;210;30m▀\x1b[38;2;210;120;165m\x1b[48;2;100;210;40m▀\x1b[38;2;210;150;180m\x1b[48;2;125;210;50m▀";
    const state = "%0;6;2;0;1;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;7;0;1;;sleep;/private/tmp";
    client.channel.parser.max_bytes = 1024;

    try openTraceStartupTestClient(
        &client,
        &actions,
        "%begin 1792870512 278 1\n3.5a\n%end 1792870512 278 1\n" ++
            "%begin 1792870513 279 1\n$0 @0 1 %0 6 2 ce5d,6x2,0,0,0 ce5d,6x2,0,0,0 sleep\n%end 1792870513 279 1\n",
    );
    try testing.expect(std.mem.containsAtLeast(
        u8,
        client.outboundBytes(),
        1,
        " ; capture-pane -p -e -N -q -S -2000 -E -1 -t %0 ; ",
    ));
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 1792870513 280 1\n" ++ state ++ "\n%end 1792870513 280 1\n" ++
            "%begin 1792870513 281 1\n" ++
            row0 ++ "\n" ++ row1 ++ "\n" ++ row2 ++ "\n" ++ row3 ++ "\n" ++
            row4 ++ "\n" ++ row5 ++ "\n" ++ row6 ++ "\n" ++
            "%end 1792870513 281 1\n" ++
            "%begin 1792870513 282 1\n\n%end 1792870513 282 1\n" ++
            "%begin 1792870513 283 1\n" ++ row7 ++ "\n\n%end 1792870513 283 1\n" ++
            "%begin 1792870513 284 1\n\n%end 1792870513 284 1\n",
        &actions,
    );

    // The pane goes live without its history, and is captured again with
    // half the rows tmux has.
    for (actions.records.items) |action| try testing.expect(action != .exit);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
    try testing.expectEqualStrings("refresh-client -A '%0:pause'\n", client.outboundBytes());
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 1792870514 285 1\n%pause %0\n%end 1792870514 285 1\n", &actions);
    try testing.expect(std.mem.containsAtLeast(
        u8,
        client.outboundBytes(),
        1,
        " ; capture-pane -p -e -N -q -S -3 -E -1 -t %0 ; ",
    ));
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();
    try client.feed(
        "%begin 1792870514 286 1\n" ++ state ++ "\n%end 1792870514 286 1\n" ++
            "%begin 1792870514 287 1\n" ++
            row4 ++ "\n" ++ row5 ++ "\n" ++ row6 ++ "\n" ++
            "%end 1792870514 287 1\n" ++
            "%begin 1792870514 288 1\n\n%end 1792870514 288 1\n" ++
            "%begin 1792870514 289 1\n" ++ row7 ++ "\n\n%end 1792870514 289 1\n" ++
            "%begin 1792870514 290 1\n\n%end 1792870514 290 1\n" ++
            "%begin 1792870514 291 1\n%continue %0\n%end 1792870514 291 1\n",
        &actions,
    );
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(@as(usize, 0), actions.records.items[0].pane_changed);
    try testing.expectEqualStrings("", client.outboundBytes());

    const owner = client.retainPaneTerminal(0).?;
    defer owner.release();
    owner.mutex.lockUncancelable(owner.terminal.io());
    defer owner.mutex.unlock(owner.terminal.io());
    const screen = owner.terminal.screens.active;
    const history = try screen.dumpStringAlloc(testing.allocator, .{ .history = .{} });
    defer testing.allocator.free(history);
    try testing.expectEqualStrings("▀▀▀▀▀▀\n▀▀▀▀▀▀\n▀▀▀▀▀▀", history);
    const fg = screen.pages.getCell(.{ .history = .{ .x = 0, .y = 0 } }).?.style().fg_color;
    try testing.expect(fg == .rgb);
    try testing.expectEqual(120, fg.rgb.r);
}

test "control client recaptures plain screens after their styled reply is too large" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{
        .history_line_limit = 0,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    // Traced from tmux 3.5a: a 6x2 pane both of whose rows give every cell
    // its own 24-bit colors. With a 256-byte limit the styled screen is too
    // large and the plain one isn't.
    const row0 = "\x1b[38;2;0;0;0m\x1b[48;2;0;0;0m▀\x1b[38;2;0;30;15m\x1b[48;2;25;0;10m▀\x1b[38;2;0;60;30m\x1b[48;2;50;0;20m▀\x1b[38;2;0;90;45m\x1b[48;2;75;0;30m▀\x1b[38;2;0;120;60m\x1b[48;2;100;0;40m▀\x1b[38;2;0;150;75m\x1b[48;2;125;0;50m▀";
    const row1 = "\x1b[38;2;60;0;15m\x1b[48;2;0;60;0m▀\x1b[38;2;60;30;30m\x1b[48;2;25;60;10m▀\x1b[38;2;60;60;45m\x1b[48;2;50;60;20m▀\x1b[38;2;60;90;60m\x1b[48;2;75;60;30m▀\x1b[38;2;60;120;75m\x1b[48;2;100;60;40m▀\x1b[38;2;60;150;90m\x1b[48;2;125;60;50m▀";
    const state = "%0;6;2;6;1;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;1;;sleep;/private/tmp";
    client.channel.parser.max_bytes = 256;

    try openTraceStartupTestClient(
        &client,
        &actions,
        "%begin 1792870564 278 1\n3.5a\n%end 1792870564 278 1\n" ++
            "%begin 1792870564 279 1\n$0 @0 1 %0 6 2 ce5d,6x2,0,0,0 ce5d,6x2,0,0,0 sleep\n%end 1792870564 279 1\n",
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 1792870565 280 1\n" ++ state ++ "\n%end 1792870565 280 1\n" ++
            "%begin 1792870565 281 1\n\n%end 1792870565 281 1\n" ++
            "%begin 1792870565 282 1\n" ++ row0 ++ "\n" ++ row1 ++ "\n%end 1792870565 282 1\n" ++
            "%begin 1792870565 283 1\n\n%end 1792870565 283 1\n",
        &actions,
    );

    for (actions.records.items) |action| try testing.expect(action != .exit);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
    try testing.expectEqualStrings("refresh-client -A '%0:pause'\n", client.outboundBytes());
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 1792870565 284 1\n%pause %0\n%end 1792870565 284 1\n", &actions);
    try testing.expect(std.mem.containsAtLeast(
        u8,
        client.outboundBytes(),
        1,
        " ; capture-pane -p -N -a -q -t %0 ; capture-pane -p -N -q -t %0 ; ",
    ));
    try client.consumeOutbound(client.outboundBytes().len);
    actions.records.clearRetainingCapacity();
    try client.feed(
        "%begin 1792870566 285 1\n" ++ state ++ "\n%end 1792870566 285 1\n" ++
            "%begin 1792870566 286 1\n\n%end 1792870566 286 1\n" ++
            "%begin 1792870566 287 1\n▀▀▀▀▀▀\n▀▀▀▀▀▀\n%end 1792870566 287 1\n" ++
            "%begin 1792870566 288 1\n\n%end 1792870566 288 1\n" ++
            "%begin 1792870566 289 1\n%continue %0\n%end 1792870566 289 1\n",
        &actions,
    );
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(@as(usize, 0), actions.records.items[0].pane_changed);
    try testing.expectEqualStrings("", client.outboundBytes());
    {
        const owner = client.retainPaneTerminal(0).?;
        defer owner.release();
        owner.mutex.lockUncancelable(owner.terminal.io());
        defer owner.mutex.unlock(owner.terminal.io());
        const contents = try owner.terminal.plainString(testing.allocator);
        defer testing.allocator.free(contents);
        try testing.expectEqualStrings("▀▀▀▀▀▀\n▀▀▀▀▀▀", contents);
    }

    // The screen may have changed by the next capture, which has its
    // styles again.
    try client.refreshPane(0);
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 1792870567 290 1\n%pause %0\n%end 1792870567 290 1\n", &actions);
    try testing.expect(std.mem.containsAtLeast(
        u8,
        client.outboundBytes(),
        1,
        " ; capture-pane -p -e -N -a -q -t %0 ; capture-pane -p -e -N -q -t %0 ; ",
    ));
}

test "control client reads past the rest of a pending escape sequence too large to keep" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{
        .history_line_limit = 0,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    // Traced from tmux 3.5a: a program has written the start of an OSC title
    // sequence, writes more of it after the pane's capture, and only later the
    // BEL that ends it and a line of text. With a 256-byte limit the
    // unfinished sequence is too large.
    client.channel.parser.max_bytes = 256;
    try openTraceStartupTestClient(
        &client,
        &actions,
        "%begin 1792879996 277 1\n3.5a\n%end 1792879996 277 1\n" ++
            "%begin 1792879996 278 1\n$0 @0 1 %0 6 2 ce5d,6x2,0,0,0 ce5d,6x2,0,0,0 zsh\n%end 1792879996 278 1\n",
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 1792879997 279 1\n%0;6;2;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;1;;zsh;/private/tmp\n%end 1792879997 279 1\n" ++
            "%begin 1792879997 280 1\n\n%end 1792879997 280 1\n" ++
            "%begin 1792879997 281 1\n\n\n%end 1792879997 281 1\n" ++
            "%begin 1792879997 282 1\n\\033]2;" ++ "a" ** 300 ++ "\n%end 1792879997 282 1\n",
        &actions,
    );
    for (actions.records.items) |action| try testing.expect(action != .exit);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);

    // Until the program ends the sequence, a capture of the pane gets the
    // same unfinished sequence again.
    try testing.expectEqualStrings("", client.outboundBytes());
    try client.feed("%output %0 " ++ "a" ** 200 ++ "\n", &actions);
    try testing.expectEqualStrings("", client.outboundBytes());
    try client.feed("%output %0 \\007after\\015\\015\\012\n", &actions);
    try testing.expectEqualStrings("", client.outboundBytes());

    const owner = client.retainPaneTerminal(0).?;
    defer owner.release();
    owner.mutex.lockUncancelable(owner.terminal.io());
    defer owner.mutex.unlock(owner.terminal.io());
    const contents = try owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("after", contents);
    try testing.expect(owner.terminal.getTitle() == null);
}

/// Start a client on a traced tmux 3.5a pane, 20x4 and showing BEFORE, whose
/// program has written the start of an escape sequence and 300 bytes of
/// filler. Its pending capture, `pending`, is too large to keep with a
/// 256-byte limit.
fn openDroppedPendingTestClient(
    client: *ControlClient,
    actions: *TestActions,
    pending: []const u8,
) !void {
    const testing = std.testing;
    client.channel.parser.max_bytes = 256;
    try openTraceStartupTestClient(
        client,
        actions,
        "%begin 1792883185 278 1\n3.5a\n%end 1792883185 278 1\n" ++
            "%begin 1792883185 279 1\n$0 @0 1 %0 20 4 e95d,20x4,0,0,0 e95d,20x4,0,0,0 Python\n%end 1792883185 279 1\n",
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 1792883185 280 1\n%0;20;4;0;1;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;3;8,16;Python;/private/tmp\n%end 1792883185 280 1\n" ++
            "%begin 1792883185 281 1\n\n%end 1792883185 281 1\n" ++
            "%begin 1792883185 282 1\nBEFORE    \n\n\n\n%end 1792883185 282 1\n" ++
            "%begin 1792883185 283 1\n",
        actions,
    );
    try client.feed(pending, actions);
    try client.feed("\n%end 1792883185 283 1\n", actions);
    for (actions.records.items) |action| try testing.expect(action != .exit);
    try testing.expectEqual(ControlClient.PanePhase.live, client.panePhase(0).?);
}

/// Feed the pane's traced output, which ends the dropped sequence and writes
/// AFTER, and expect the sequence did nothing: the pane shows only the text
/// after it, and its title, colors and images are as before. No capture is
/// sent.
fn expectDroppedPendingRestSkipped(
    client: *ControlClient,
    actions: *TestActions,
    output: []const u8,
) !void {
    const testing = std.testing;
    try client.feed(output, actions);
    try testing.expectEqualStrings("", client.outboundBytes());

    const owner = client.retainPaneTerminal(0).?;
    defer owner.release();
    owner.mutex.lockUncancelable(owner.terminal.io());
    defer owner.mutex.unlock(owner.terminal.io());
    const t = &owner.terminal;
    const contents = try t.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("BEFORE    \nAFTER", contents);
    try testing.expect(t.getTitle() == null);
    try testing.expect(t.colors.background.override == null);
    try testing.expect(t.colors.foreground.override == null);
    try testing.expect(t.colors.cursor.override == null);
    if (comptime @import("terminal_options").kitty_graphics) {
        try testing.expectEqual(0, t.screens.active.kitty_images.images.count());
    }
}

// The cases below are traced from tmux 3.5a: the program ends the sequence
// 2 s after it began, before tmux's string timeout, and tmux's own pane then
// shows BEFORE and AFTER.

test "control client skips the rest of a dropped pending CSI" {
    var client = try ControlClient.init(std.testing.io, std.testing.allocator, .{
        .history_line_limit = 0,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    // The parameters overflow tmux's buffer, so it ignores the CSI at its
    // final byte. Read as a new CSI, its rest would clear the screen.
    try openDroppedPendingTestClient(&client, &actions, "\\033[" ++ "1;" ** 150);
    try expectDroppedPendingRestSkipped(&client, &actions, "%output %0 2JAFTER\\015\\015\\012\n");
}

test "control client skips the rest of a dropped pending OSC that would set a color" {
    var client = try ControlClient.init(std.testing.io, std.testing.allocator, .{
        .history_line_limit = 0,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    // tmux reads the rest as more of the title.
    try openDroppedPendingTestClient(&client, &actions, "\\033]2;" ++ "a" ** 300);
    try expectDroppedPendingRestSkipped(
        &client,
        &actions,
        "%output %0 11;rgb:ffff/0000/0000\\007AFTER\\015\\015\\012\n",
    );
}

test "control client skips the rest of a dropped pending OSC that would set a title" {
    var client = try ControlClient.init(std.testing.io, std.testing.allocator, .{
        .history_line_limit = 0,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    try openDroppedPendingTestClient(&client, &actions, "\\033]2;" ++ "a" ** 300);
    try expectDroppedPendingRestSkipped(
        &client,
        &actions,
        "%output %0 2;SUFFIX_TITLE\\007AFTER\\015\\015\\012\n",
    );
}

test "control client skips the rest of a dropped pending DCS through its ST" {
    var client = try ControlClient.init(std.testing.io, std.testing.allocator, .{
        .history_line_limit = 0,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    // A passthrough DCS, which tmux ignores by default. Its data holds an
    // OSC title with a doubled ESC and an ESC [ 2 J; tmux reads both as data
    // until ESC \.
    try openDroppedPendingTestClient(&client, &actions, "\\033Ptmux;" ++ "a" ** 300);
    try expectDroppedPendingRestSkipped(
        &client,
        &actions,
        "%output %0 b\\033\\033]2;INNER\\007\\033[2Jc\\033\\134AFTER\\015\\015\\012\n",
    );
}

test "control client skips the rest of a dropped pending APC that would draw an image" {
    var client = try ControlClient.init(std.testing.io, std.testing.allocator, .{
        .history_line_limit = 0,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    // Read as a new APC, the rest would be a kitty graphics command.
    try openDroppedPendingTestClient(&client, &actions, "\\033_" ++ "a" ** 300);
    try expectDroppedPendingRestSkipped(
        &client,
        &actions,
        "%output %0 Gf=24,s=1,v=1,a=T;AAAA\\033\\134AFTER\\015\\015\\012\n",
    );
}

test "control client skips the rest of a dropped pending screen title through ESC" {
    var client = try ControlClient.init(std.testing.io, std.testing.allocator, .{
        .history_line_limit = 0,
    });
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();

    // tmux reads the CR and LF in the title as nothing.
    try openDroppedPendingTestClient(&client, &actions, "\\033k" ++ "a" ** 300);
    try expectDroppedPendingRestSkipped(
        &client,
        &actions,
        "%output %0 b\\015\\015\\012c\\033\\134AFTER\\015\\015\\012\n",
    );
}

test "control client reports a host command reply too large as an error" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openReadyTestClient(&client, &actions);
    client.channel.parser.max_bytes = 16;

    const token = try client.enqueueCommand("show-buffer");
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 9 9 1\nmore than sixteen bytes\n%end 9 9 1\n", &actions);
    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(token, actions.records.items[0].command_error);
    try testing.expectEqual(channel_pkg.Channel.State.running, client.channel.state);
}

test "control client serializes exact binary pane input" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

test "control client correlates tracked pane input completion" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    const token = try client.sendPaneInputTracked(0, "message");
    try testing.expectEqualStrings(
        "send-keys -H -t %0 6d 65 73 73 61 67 65\n",
        client.outboundBytes(),
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 9 9 1\n%end 9 9 1\n", &actions);

    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(token, actions.records.items[0].command_success);
}

test "control client serializes tracked literal pane input as one argument" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    const payload = "\x1b[200~line 1\n'\"$~\\;#{x}\t café🙂\x1b[201~";
    const token = try client.sendPaneLiteralInputTracked(0, payload);
    try testing.expectEqualStrings(
        "send-keys -l -t %0 -- \"\\033[200\\176line 1\\012'\\042\\044" ++
            "\\176\\134;#{x}\\011 café🙂\\033[201\\176\"\n",
        client.outboundBytes(),
    );
    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed("%begin 9 9 1\n%end 9 9 1\n", &actions);

    try testing.expectEqual(1, actions.records.items.len);
    try testing.expectEqual(token, actions.records.items[0].command_success);
}

test "control client tracked literal input terminates flags before payload" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    _ = try client.sendPaneLiteralInputTracked(0, "-l");
    try testing.expectEqualStrings(
        "send-keys -l -t %0 -- \"-l\"\n",
        client.outboundBytes(),
    );
}

test "control client tracked literal input rejects non-text bytes atomically" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    const next_token = client.channel.next_token;
    try testing.expectError(
        error.InvalidInput,
        client.sendPaneLiteralInputTracked(0, &.{ 'a', 0, 'b' }),
    );
    try testing.expectError(
        error.InvalidInput,
        client.sendPaneLiteralInputTracked(0, &.{ 0x80, 0xff }),
    );
    try testing.expectEqual(next_token, client.channel.next_token);
    try testing.expectEqualStrings("", client.outboundBytes());
}

test "control client tracked literal input keeps large payload in one argument" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    const payload = [_]u8{'x'} ** (64 * 1024);
    _ = try client.sendPaneLiteralInputTracked(0, &payload);
    const outbound = client.outboundBytes();
    try testing.expect(std.mem.startsWith(u8, outbound, "send-keys -l -t %0 -- \""));
    try testing.expect(std.mem.endsWith(u8, outbound, "\"\n"));
    try testing.expectEqual(payload.len + "send-keys -l -t %0 -- \"\"\n".len, outbound.len);
}

test "control client tracked literal input formatting failure is allocation atomic" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});

    var client = try ControlClient.init(testing.io, failing.allocator(), .{});
    defer client.deinit();
    var actions: TestActions = .{};
    defer actions.deinit();
    try openPaneTestClient(&client, &actions);

    const bytes = [_]u8{'x'} ** 512;
    const next_token = client.channel.next_token;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(
        error.OutOfMemory,
        client.sendPaneLiteralInputTracked(0, &bytes),
    );
    try testing.expectEqual(next_token, client.channel.next_token);
    try testing.expectEqualStrings("", client.outboundBytes());
}

test "control client pane input validates without no-op mutation" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, failing.allocator(), .{});
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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
        "%begin 9 9 1\none\n%end 9 9 1\n" ++
            "%begin 10 10 1\ntwo\n%end 10 10 1\n",
        &actions,
    );
    try testing.expectEqual(2, actions.records.items.len);
    try testing.expectEqual(first, actions.records.items[0].command_success);
    try testing.expectEqual(second, actions.records.items[1].command_success);
}

test "control client host group failure preserves later independent command" {
    const testing = std.testing;

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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
        "%begin 9 9 1\n%end 9 9 1\n" ++
            "%begin 10 10 1\nfailed\n%error 10 10 1\n" ++
            "%begin 11 11 1\n%end 11 11 1\n",
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

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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
            "%begin 3 3 1\n" ++
            "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell\n" ++
            "%end 3 3 1\n",
        &handler,
    );
    try testing.expect(handler.token != null);
    try testing.expect(std.mem.startsWith(
        u8,
        client.outboundBytes(),
        "display-message -p host\n",
    ));
    try testing.expectEqual(0, handler.completion_count);

    try client.consumeOutbound(client.outboundBytes().len);
    try client.feed(
        "%begin 4 4 1\nhost\n%end 4 4 1\n" ++
            "%begin 5 5 1\n%end 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\n%end 8 8 1\n" ++
            "%begin 9 9 1\n%end 9 9 1\n",
        &handler,
    );
    try testing.expectEqual(1, handler.completion_count);
}

test "control client command admission rejects without mutation" {
    const testing = std.testing;
    const sentinel: channel_pkg.CommandToken = @enumFromInt(999);

    var client = try ControlClient.init(testing.io, testing.allocator, .{});
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

    var client = try ControlClient.init(testing.io, failing.allocator(), .{});
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
