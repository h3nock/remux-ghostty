//! Connection-scoped tmux control-mode framing and command correlation.
//!
//! The channel is sans-I/O: a host feeds transport bytes, drains outbound
//! bytes, and handles synchronous events. It owns no session, pane, policy,
//! clock, transport, or presentation state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const control = @import("control.zig");

pub const CommandToken = enum(u64) { _ };

/// Identifies which ControlClient layer owns a command's semantic response.
/// Channel retains this only for FIFO response routing; it does not interpret
/// either source.
pub const CommandSource = enum {
    host,
    viewer,
    input,
};

pub const CommandFailure = union(enum) {
    /// Tmux executed the command and returned `%error`.
    error_block: []const u8,

    /// Tmux skipped this command after an earlier member of the same
    /// semicolon-joined command group failed.
    skipped_after_error: CommandToken,

    /// The connection ended before this command produced a response.
    channel_closed,
};

pub const AbortReason = union(enum) {
    protocol_error,
    buffer_overflow,
    unexpected_block,
    handshake_failed: []const u8,
    incomplete_group,
};

pub const Event = union(enum) {
    /// The implicit attach command completed and commands may be enqueued.
    handshake_ok: []const u8,

    /// A notification or server-originated block. Client-originated command
    /// response blocks are consumed by the channel instead.
    notification: control.Notification,

    command_ok: struct {
        token: CommandToken,
        source: CommandSource,
        body: []const u8,
    },

    command_failed: struct {
        token: CommandToken,
        source: CommandSource,
        failure: CommandFailure,
    },

    /// The server ended control mode cleanly. Pending command failures are
    /// emitted before this terminal event.
    exited,

    /// The channel encountered a terminal protocol or framing failure.
    /// Pending command failures are emitted before this terminal event.
    aborted: AbortReason,
};

pub const Channel = struct {
    alloc: Allocator,
    parser: control.Parser,
    state: State = .handshake,

    /// Contiguous transport bytes. Consumed bytes remain at the front until
    /// the buffer is drained or tail capacity is needed again.
    outbound: std.ArrayList(u8) = .empty,
    outbound_head: usize = 0,

    /// Commands awaiting client-originated response blocks, strictly FIFO.
    pending: PendingQueue,
    next_token: u64 = 1,
    feeding: bool = false,

    const pending_initial_capacity = 8;
    const PendingQueue = CircBuf(Pending, undefined);

    const Pending = struct {
        token: CommandToken,
        source: CommandSource,

        /// True for standalone commands and the final member of a
        /// semicolon-joined group.
        ends_group: bool,
    };

    pub const State = enum {
        handshake,
        running,
        exited,
        aborted,
    };

    pub const EnqueueError = Allocator.Error || error{
        ChannelClosed,
        NotReady,
        InvalidCommand,
        InvalidTokenCount,
        TokenExhausted,
    };

    pub const ConsumeError = error{InvalidByteCount};
    pub const FeedError = error{ReentrantFeed};

    pub fn init(alloc: Allocator) Allocator.Error!Channel {
        return .{
            .alloc = alloc,
            .parser = .{ .buffer = .init(alloc) },
            .pending = try .init(alloc, pending_initial_capacity),
        };
    }

    pub fn deinit(self: *Channel) void {
        self.parser.deinit();
        self.outbound.deinit(self.alloc);
        self.pending.deinit(self.alloc);
    }

    pub fn isTerminal(self: *const Channel) bool {
        return switch (self.state) {
            .handshake, .running => false,
            .exited, .aborted => true,
        };
    }

    /// Queue one command as one newline-delimited tmux command list.
    ///
    /// `text` must already be serialized as exactly one nonempty tmux command.
    /// The channel rejects transport delimiters but intentionally does not
    /// duplicate tmux's quoting grammar to validate separator placement.
    /// Use `enqueueCommandGroup` to join multiple commands.
    pub fn enqueueCommand(
        self: *Channel,
        text: []const u8,
    ) EnqueueError!CommandToken {
        return self.enqueueCommandFrom(.host, text);
    }

    pub fn enqueueCommandFrom(
        self: *Channel,
        source: CommandSource,
        text: []const u8,
    ) EnqueueError!CommandToken {
        try self.validateEnqueue();
        if (!isValidCommand(text)) return error.InvalidCommand;
        try self.ensureTokens(1);

        try self.ensurePendingCapacity(1);
        try self.ensureOutboundCapacity(std.math.add(usize, text.len, 1) catch
            return error.InvalidCommand);

        const token = self.mintToken();
        self.outbound.appendSliceAssumeCapacity(text);
        self.outbound.appendAssumeCapacity('\n');
        self.pending.appendAssumeCapacity(.{
            .token = token,
            .source = source,
            .ends_group = true,
        });
        return token;
    }

    /// Queue one semicolon-joined tmux command group.
    ///
    /// The group controls framing and skip-on-error accounting only. It is
    /// not a transaction and does not imply rollback or liveness. Every text
    /// must independently satisfy `enqueueCommand`'s single-command contract.
    /// Pass null when the caller does not need the per-member tokens.
    pub fn enqueueCommandGroup(
        self: *Channel,
        texts: []const []const u8,
        tokens_out: ?[]CommandToken,
    ) EnqueueError!void {
        return self.enqueueCommandGroupFrom(.host, texts, tokens_out);
    }

    pub fn enqueueCommandGroupFrom(
        self: *Channel,
        source: CommandSource,
        texts: []const []const u8,
        tokens_out: ?[]CommandToken,
    ) EnqueueError!void {
        try self.validateEnqueue();
        if (texts.len == 0) return error.InvalidCommand;
        if (tokens_out) |tokens| {
            if (tokens.len != texts.len) return error.InvalidTokenCount;
        }
        try self.ensureTokens(texts.len);

        var wire_len: usize = 1;
        for (texts, 0..) |text, i| {
            if (!isValidCommand(text)) return error.InvalidCommand;
            wire_len = std.math.add(usize, wire_len, text.len) catch
                return error.InvalidCommand;
            if (i != 0) wire_len = std.math.add(
                usize,
                wire_len,
                " ; ".len,
            ) catch return error.InvalidCommand;
        }

        // Both reserves precede every logical mutation. If either allocation
        // fails, no token, pending record, or wire byte becomes observable.
        try self.ensurePendingCapacity(texts.len);
        try self.ensureOutboundCapacity(wire_len);

        for (texts, 0..) |text, i| {
            if (i != 0) self.outbound.appendSliceAssumeCapacity(" ; ");
            self.outbound.appendSliceAssumeCapacity(text);

            const token = self.mintToken();
            self.pending.appendAssumeCapacity(.{
                .token = token,
                .source = source,
                .ends_group = i + 1 == texts.len,
            });
            if (tokens_out) |tokens| tokens[i] = token;
        }
        self.outbound.appendAssumeCapacity('\n');
    }

    /// Bytes awaiting transport. The slice is valid until the next enqueue,
    /// feed, or consume call.
    pub fn outboundBytes(self: *const Channel) []const u8 {
        return self.outbound.items[self.outbound_head..];
    }

    /// Acknowledge bytes successfully written by the host transport.
    pub fn consumeOutbound(self: *Channel, n: usize) ConsumeError!void {
        if (n > self.outboundBytes().len) return error.InvalidByteCount;
        self.outbound_head += n;
        if (self.outbound_head == self.outbound.items.len) {
            self.outbound.clearRetainingCapacity();
            self.outbound_head = 0;
        }
    }

    fn pendingCount(self: *const Channel) usize {
        return self.pending.len();
    }

    /// Feed bytes received from the control-mode transport.
    ///
    /// Event payloads borrow parser storage and are valid only during the
    /// callback. A handler may enqueue commands reentrantly, but must not call
    /// `feed` reentrantly. Caller serialization is required.
    pub fn feed(
        self: *Channel,
        bytes: []const u8,
        handler: anytype,
    ) FeedError!void {
        if (self.isTerminal()) return;
        if (self.feeding) return error.ReentrantFeed;
        self.feeding = true;
        defer self.feeding = false;

        for (bytes) |byte| {
            const notification = self.parser.put(byte) catch {
                self.abort(.buffer_overflow, handler);
                return;
            } orelse continue;

            self.dispatch(notification, handler);
            if (self.isTerminal()) return;
        }
    }

    fn validateEnqueue(self: *const Channel) EnqueueError!void {
        return switch (self.state) {
            .handshake => error.NotReady,
            .running => {},
            .exited, .aborted => error.ChannelClosed,
        };
    }

    fn isValidCommand(text: []const u8) bool {
        var has_content = false;
        for (text) |byte| {
            if (byte == 0 or byte == '\r' or byte == '\n') return false;
            if (!std.ascii.isWhitespace(byte)) has_content = true;
        }
        return has_content;
    }

    fn ensureTokens(self: *const Channel, count: usize) EnqueueError!void {
        if (count > std.math.maxInt(u64) - self.next_token) {
            return error.TokenExhausted;
        }
    }

    fn mintToken(self: *Channel) CommandToken {
        const token: CommandToken = @enumFromInt(self.next_token);
        self.next_token += 1;
        return token;
    }

    fn ensurePendingCapacity(
        self: *Channel,
        additional: usize,
    ) Allocator.Error!void {
        const needed = std.math.add(usize, self.pending.len(), additional) catch
            return error.OutOfMemory;
        if (needed <= self.pending.capacity()) return;

        // CircBuf's general helper grows exactly to the request. Commands may
        // arrive in bursts, so grow geometrically here to avoid one resize per
        // enqueue after the initial capacity is exhausted.
        const doubled = std.math.mul(usize, self.pending.capacity(), 2) catch
            return error.OutOfMemory;
        try self.pending.resize(self.alloc, @max(needed, doubled));
    }

    fn ensureOutboundCapacity(
        self: *Channel,
        additional: usize,
    ) Allocator.Error!void {
        if (self.outbound.capacity - self.outbound.items.len >= additional) {
            return;
        }

        // Reclaim an acknowledged prefix only when an append needs the tail
        // space. Partial writes therefore never cause per-consume memmoves.
        if (self.outbound_head > 0) {
            const unread = self.outbound.items[self.outbound_head..];
            std.mem.copyForwards(u8, self.outbound.items[0..unread.len], unread);
            self.outbound.shrinkRetainingCapacity(unread.len);
            self.outbound_head = 0;
        }
        try self.outbound.ensureUnusedCapacity(self.alloc, additional);
    }

    fn popPending(self: *Channel) ?Pending {
        const ptr = self.pending.first() orelse return null;
        const pending = ptr.*;
        self.pending.deleteOldest(1);
        return pending;
    }

    fn dispatch(
        self: *Channel,
        notification: control.Notification,
        handler: anytype,
    ) void {
        switch (notification) {
            .block_end => |block| self.dispatchBlock(block, false, notification, handler),
            .block_err => |block| self.dispatchBlock(block, true, notification, handler),
            .exit => if (self.parser.isBroken())
                self.abort(.protocol_error, handler)
            else
                self.exit(handler),
            else => switch (self.state) {
                .handshake => {}, // Notifications open only after attach.
                .running => handler.channelEvent(.{ .notification = notification }),
                .exited, .aborted => unreachable,
            },
        }
    }

    fn dispatchBlock(
        self: *Channel,
        block: control.Notification.Block,
        is_error: bool,
        notification: control.Notification,
        handler: anytype,
    ) void {
        switch (self.state) {
            .handshake => {
                if (block.meta.flags != 0) {
                    self.abort(.unexpected_block, handler);
                    return;
                }
                if (is_error) {
                    self.abort(.{ .handshake_failed = block.data }, handler);
                    return;
                }

                self.state = .running;
                handler.channelEvent(.{ .handshake_ok = block.data });
            },

            .running => {
                if (!block.meta.isClient()) {
                    handler.channelEvent(.{ .notification = notification });
                    return;
                }

                const pending = self.popPending() orelse {
                    self.abort(.unexpected_block, handler);
                    return;
                };

                if (!is_error) {
                    handler.channelEvent(.{ .command_ok = .{
                        .token = pending.token,
                        .source = pending.source,
                        .body = block.data,
                    } });
                    return;
                }

                handler.channelEvent(.{ .command_failed = .{
                    .token = pending.token,
                    .source = pending.source,
                    .failure = .{ .error_block = block.data },
                } });

                var member = pending;
                while (!member.ends_group) {
                    member = self.popPending() orelse {
                        self.abort(.incomplete_group, handler);
                        return;
                    };
                    handler.channelEvent(.{ .command_failed = .{
                        .token = member.token,
                        .source = member.source,
                        .failure = .{ .skipped_after_error = pending.token },
                    } });
                }
            },

            .exited, .aborted => unreachable,
        }
    }

    fn exit(self: *Channel, handler: anytype) void {
        self.state = .exited;
        self.discardOutbound();
        self.failAllPending(handler);
        handler.channelEvent(.exited);
    }

    fn abort(
        self: *Channel,
        reason: AbortReason,
        handler: anytype,
    ) void {
        if (self.isTerminal()) return;
        self.state = .aborted;
        self.discardOutbound();
        self.failAllPending(handler);
        handler.channelEvent(.{ .aborted = reason });
    }

    fn discardOutbound(self: *Channel) void {
        self.outbound.clearRetainingCapacity();
        self.outbound_head = 0;
    }

    fn failAllPending(self: *Channel, handler: anytype) void {
        while (self.popPending()) |pending| {
            handler.channelEvent(.{ .command_failed = .{
                .token = pending.token,
                .source = pending.source,
                .failure = .channel_closed,
            } });
        }
    }
};

const TestEvents = struct {
    items: std.ArrayList(Recorded) = .empty,

    const Recorded = union(enum) {
        handshake_ok,
        notification: std.meta.Tag(control.Notification),
        command_ok: CommandToken,
        command_error: CommandToken,
        command_skipped: struct {
            token: CommandToken,
            cause: CommandToken,
        },
        command_closed: CommandToken,
        exited,
        aborted: std.meta.Tag(AbortReason),
    };

    fn deinit(self: *TestEvents, alloc: Allocator) void {
        self.items.deinit(alloc);
    }

    pub fn channelEvent(self: *TestEvents, event: Event) void {
        const recorded: Recorded = switch (event) {
            .handshake_ok => .handshake_ok,
            .notification => |notification| .{
                .notification = std.meta.activeTag(notification),
            },
            .command_ok => |command| .{ .command_ok = command.token },
            .command_failed => |command| switch (command.failure) {
                .error_block => .{ .command_error = command.token },
                .skipped_after_error => |cause| .{ .command_skipped = .{
                    .token = command.token,
                    .cause = cause,
                } },
                .channel_closed => .{ .command_closed = command.token },
            },
            .exited => .exited,
            .aborted => |reason| .{ .aborted = std.meta.activeTag(reason) },
        };
        self.items.append(std.testing.allocator, recorded) catch @panic("oom");
    }
};

fn openTestChannel(channel: *Channel, events: *TestEvents) void {
    channel.feed("%begin 1 1 0\n%end 1 1 0\n", events) catch unreachable;
}

test "tmux channel standalone and independent commands share outbound" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    const first = try channel.enqueueCommand("display-message -p one");
    const second = try channel.enqueueCommand("display-message -p two");
    try testing.expectEqualStrings(
        "display-message -p one\ndisplay-message -p two\n",
        channel.outboundBytes(),
    );

    try channel.feed(
        "%begin 2 2 1\none\n%end 2 2 1\n" ++
            "%begin 3 3 1\ntwo\n%end 3 3 1\n",
        &events,
    );
    try testing.expectEqual(0, channel.pendingCount());
    try testing.expectEqual(first, events.items.items[1].command_ok);
    try testing.expectEqual(second, events.items.items[2].command_ok);
}

test "tmux channel group failure skips only its remaining members" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    var group: [3]CommandToken = undefined;
    try channel.enqueueCommandGroup(&.{ "command-a", "command-b", "command-c" }, &group);
    const independent = try channel.enqueueCommand("command-d");
    try testing.expectEqualStrings(
        "command-a ; command-b ; command-c\ncommand-d\n",
        channel.outboundBytes(),
    );

    try channel.feed(
        "%begin 2 2 1\n%end 2 2 1\n" ++
            "%begin 3 3 1\nfailed\n%error 3 3 1\n" ++
            "%begin 4 4 1\n%end 4 4 1\n",
        &events,
    );

    try testing.expectEqual(group[0], events.items.items[1].command_ok);
    try testing.expectEqual(group[1], events.items.items[2].command_error);
    try testing.expectEqual(group[2], events.items.items[3].command_skipped.token);
    try testing.expectEqual(group[1], events.items.items[3].command_skipped.cause);
    try testing.expectEqual(independent, events.items.items[4].command_ok);
    try testing.expectEqual(0, channel.pendingCount());
}

test "tmux channel whole-line parse error skips the complete group" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    var group: [3]CommandToken = undefined;
    try channel.enqueueCommandGroup(&.{ "bad-command", "second", "third" }, &group);
    const independent = try channel.enqueueCommand("independent");

    // Tmux returns exactly one client-originated error block when the whole
    // semicolon-joined line fails to parse. No blocks are emitted for the
    // other members of that line.
    try channel.feed(
        "%begin 2 2 1\nparse error\n%error 2 2 1\n" ++
            "%begin 3 3 1\n%end 3 3 1\n",
        &events,
    );

    try testing.expectEqual(group[0], events.items.items[1].command_error);
    try testing.expectEqual(group[1], events.items.items[2].command_skipped.token);
    try testing.expectEqual(group[0], events.items.items[2].command_skipped.cause);
    try testing.expectEqual(group[2], events.items.items[3].command_skipped.token);
    try testing.expectEqual(group[0], events.items.items[3].command_skipped.cause);
    try testing.expectEqual(independent, events.items.items[4].command_ok);
    try testing.expectEqual(0, channel.pendingCount());
}

test "tmux channel group success completes every member" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    var group: [3]CommandToken = undefined;
    try channel.enqueueCommandGroup(&.{ "first", "second", "third" }, &group);
    try channel.feed(
        "%begin 2 2 1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n%end 3 3 1\n" ++
            "%begin 4 4 1\n%end 4 4 1\n",
        &events,
    );

    for (group, events.items.items[1..]) |token, event| {
        try testing.expectEqual(token, event.command_ok);
    }
    try testing.expectEqual(0, channel.pendingCount());
}

test "tmux channel server block does not consume client queue" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    const token = try channel.enqueueCommand("display-message -p ok");
    try channel.feed(
        "%begin 2 2 0\nserver\n%end 2 2 0\n" ++
            "%begin 3 3 1\nok\n%end 3 3 1\n",
        &events,
    );

    try testing.expectEqual(
        std.meta.Tag(control.Notification).block_end,
        events.items.items[1].notification,
    );
    try testing.expectEqual(token, events.items.items[2].command_ok);
    try testing.expectEqual(0, channel.pendingCount());
}

test "tmux channel partial outbound consumption preserves remainder" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    _ = try channel.enqueueCommand("first");
    _ = try channel.enqueueCommand("second");
    try channel.consumeOutbound("first\nsec".len);
    try testing.expectEqualStrings("ond\n", channel.outboundBytes());

    // Force prefix reclamation while unread bytes remain.
    _ = try channel.enqueueCommand("a-command-long-enough-to-grow-the-buffer");
    try testing.expectEqualStrings(
        "ond\na-command-long-enough-to-grow-the-buffer\n",
        channel.outboundBytes(),
    );
    try testing.expectError(
        error.InvalidByteCount,
        channel.consumeOutbound(channel.outboundBytes().len + 1),
    );
    try testing.expectEqualStrings(
        "ond\na-command-long-enough-to-grow-the-buffer\n",
        channel.outboundBytes(),
    );
}

test "tmux channel handshake validates block origin and failure" {
    const testing = std.testing;

    {
        var channel = try Channel.init(testing.allocator);
        defer channel.deinit();
        var events: TestEvents = .{};
        defer events.deinit(testing.allocator);

        try channel.feed("%begin 1 1 1\n%end 1 1 1\n", &events);
        try testing.expectEqual(Channel.State.aborted, channel.state);
        try testing.expectEqual(
            std.meta.Tag(AbortReason).unexpected_block,
            events.items.items[0].aborted,
        );
    }

    {
        var channel = try Channel.init(testing.allocator);
        defer channel.deinit();
        var events: TestEvents = .{};
        defer events.deinit(testing.allocator);

        try channel.feed(
            "%begin 1 1 0\nattach failed\n%error 1 1 0\n",
            &events,
        );
        try testing.expectEqual(Channel.State.aborted, channel.state);
        try testing.expectEqual(
            std.meta.Tag(AbortReason).handshake_failed,
            events.items.items[0].aborted,
        );
    }
}

test "tmux channel unsolicited client block aborts" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    try channel.feed("%begin 2 2 1\n%end 2 2 1\n", &events);
    try testing.expectEqual(Channel.State.aborted, channel.state);
    try testing.expectEqual(
        std.meta.Tag(AbortReason).unexpected_block,
        events.items.items[1].aborted,
    );
}

test "tmux channel malformed stream is not a clean exit" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    const token = try channel.enqueueCommand("pending");
    try channel.feed("not-control-mode", &events);

    try testing.expectEqual(token, events.items.items[1].command_closed);
    try testing.expectEqual(
        std.meta.Tag(AbortReason).protocol_error,
        events.items.items[2].aborted,
    );
    try testing.expectEqual(Channel.State.aborted, channel.state);
}

test "tmux channel clean exit fails pending before terminal event" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    const first = try channel.enqueueCommand("first");
    const second = try channel.enqueueCommand("second");
    try channel.feed("%exit detached\n", &events);

    try testing.expectEqual(first, events.items.items[1].command_closed);
    try testing.expectEqual(second, events.items.items[2].command_closed);
    try testing.expect(events.items.items[3] == .exited);
    try testing.expectEqual(Channel.State.exited, channel.state);
    try testing.expectEqualStrings("", channel.outboundBytes());
    try testing.expectError(error.ChannelClosed, channel.enqueueCommand("later"));
}

test "tmux channel validates enqueue inputs without mutation" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    try testing.expectError(error.NotReady, channel.enqueueCommand("valid"));

    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    try testing.expectError(error.InvalidCommand, channel.enqueueCommand(""));
    try testing.expectError(error.InvalidCommand, channel.enqueueCommand(" \t\r"));
    try testing.expectError(error.InvalidCommand, channel.enqueueCommand("one\ntwo"));
    try testing.expectError(error.InvalidCommand, channel.enqueueCommand("one\rtwo"));
    try testing.expectError(error.InvalidCommand, channel.enqueueCommand("one\x00two"));
    var tokens: [1]CommandToken = undefined;
    try testing.expectError(
        error.InvalidTokenCount,
        channel.enqueueCommandGroup(&.{ "one", "two" }, &tokens),
    );
    try testing.expectEqual(0, channel.pendingCount());
    try testing.expectEqualStrings("", channel.outboundBytes());

    try channel.enqueueCommandGroup(&.{ "one", "two" }, null);
    try testing.expectEqual(2, channel.pendingCount());
    try testing.expectEqualStrings("one ; two\n", channel.outboundBytes());
}

test "tmux channel preserves quoted semicolons in one command" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    _ = try channel.enqueueCommand("list-panes -F '#{pane_id};#{pane_width}'");
    try testing.expectEqualStrings(
        "list-panes -F '#{pane_id};#{pane_width}'\n",
        channel.outboundBytes(),
    );

    var group: [2]CommandToken = undefined;
    try channel.enqueueCommandGroup(
        &.{ "display-message -p ';'", "display-message -p done" },
        &group,
    );
    try testing.expectEqualStrings(
        "list-panes -F '#{pane_id};#{pane_width}'\n" ++
            "display-message -p ';' ; display-message -p done\n",
        channel.outboundBytes(),
    );
}

test "tmux channel enqueue is allocation atomic" {
    const testing = std.testing;
    const sentinel: CommandToken = @enumFromInt(999);
    const texts = [_][]const u8{
        "one",
        "two",
        "three",
        "four",
        "five",
        "six",
        "seven",
        "eight",
        "nine",
    };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const alloc = failing.allocator();

        var channel = Channel.init(alloc) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        channel.state = .running;
        var tokens = [_]CommandToken{sentinel} ** texts.len;

        if (channel.enqueueCommandGroup(&texts, &tokens)) |_| {
            try testing.expectEqualStrings(
                "one ; two ; three ; four ; five ; six ; seven ; eight ; nine\n",
                channel.outboundBytes(),
            );
            try testing.expectEqual(texts.len, channel.pendingCount());
            channel.deinit();
            if (!failing.has_induced_failure) break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqualStrings("", channel.outboundBytes());
            try testing.expectEqual(0, channel.pendingCount());
            try testing.expectEqual(1, channel.next_token);
            for (tokens) |token| try testing.expectEqual(sentinel, token);
            channel.deinit();
        }
    }
}

test "tmux channel terminal state precedes cancellation callbacks" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var open_events: TestEvents = .{};
    defer open_events.deinit(testing.allocator);
    openTestChannel(&channel, &open_events);

    _ = try channel.enqueueCommand("first");
    _ = try channel.enqueueCommand("second");

    const Handler = struct {
        channel: *Channel,
        cancellations: usize = 0,
        rejected_enqueues: usize = 0,
        terminal_seen: bool = false,
        callback_after_terminal: bool = false,

        pub fn channelEvent(self: *@This(), event: Event) void {
            switch (event) {
                .command_failed => |command| {
                    if (command.failure != .channel_closed) {
                        @panic("unexpected command failure");
                    }
                    self.callback_after_terminal = self.callback_after_terminal or
                        self.channel.state == .exited;
                    self.cancellations += 1;
                    _ = self.channel.enqueueCommand("must reject") catch |err| {
                        if (err != error.ChannelClosed) {
                            @panic("unexpected enqueue error");
                        }
                        self.rejected_enqueues += 1;
                        return;
                    };
                    @panic("terminal channel accepted a command");
                },
                .exited => self.terminal_seen = true,
                else => @panic("unexpected event"),
            }
        }
    };
    var handler: Handler = .{ .channel = &channel };
    try channel.feed("%exit detached\n", &handler);

    try testing.expect(handler.callback_after_terminal);
    try testing.expectEqual(2, handler.cancellations);
    try testing.expectEqual(2, handler.rejected_enqueues);
    try testing.expect(handler.terminal_seen);
    try testing.expectEqual(0, channel.pendingCount());
    try testing.expectEqualStrings("", channel.outboundBytes());
}

test "tmux channel pending FIFO survives wrap and growth" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    var initial: [8]CommandToken = undefined;
    for (&initial, 0..) |*token, i| {
        var text: [16]u8 = undefined;
        token.* = try channel.enqueueCommand(try std.fmt.bufPrint(
            &text,
            "initial-{d}",
            .{i},
        ));
    }
    try channel.feed(
        "%begin 2 2 1\n%end 2 2 1\n" ** 6,
        &events,
    );

    var group: [9]CommandToken = undefined;
    try channel.enqueueCommandGroup(
        &.{ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" },
        &group,
    );

    const expected = [_]CommandToken{ initial[6], initial[7] } ++ group;
    var it = channel.pending.iterator(.forward);
    for (expected) |token| try testing.expectEqual(token, it.next().?.token);
    try testing.expect(it.next() == null);
}

test "tmux channel rejects recursive feed without corrupting correlation" {
    const testing = std.testing;

    var channel = try Channel.init(testing.allocator);
    defer channel.deinit();
    var events: TestEvents = .{};
    defer events.deinit(testing.allocator);
    openTestChannel(&channel, &events);

    const first = try channel.enqueueCommand("first");
    const second = try channel.enqueueCommand("second");

    const ReentrantHandler = struct {
        channel: *Channel,
        first: CommandToken,
        queued: ?CommandToken = null,
        feed_error: ?Channel.FeedError = null,

        pub fn channelEvent(self: *@This(), event: Event) void {
            switch (event) {
                .command_ok => |command| if (command.token == self.first) {
                    self.channel.feed(
                        "%begin 99 99 1\n%end 99 99 1\n",
                        self,
                    ) catch |err| {
                        self.feed_error = err;
                    };
                    self.queued = self.channel.enqueueCommand("third") catch
                        @panic("reentrant enqueue failed");
                },
                else => {},
            }
        }
    };
    var handler: ReentrantHandler = .{ .channel = &channel, .first = first };

    try channel.feed("%begin 2 2 1\n%end 2 2 1\n", &handler);
    try testing.expectEqual(error.ReentrantFeed, handler.feed_error.?);
    try testing.expectEqual(2, channel.pendingCount());

    try channel.feed(
        "%begin 3 3 1\n%end 3 3 1\n" ++
            "%begin 4 4 1\n%end 4 4 1\n",
        &events,
    );
    try testing.expectEqual(second, events.items.items[1].command_ok);
    try testing.expectEqual(handler.queued.?, events.items.items[2].command_ok);
    try testing.expectEqual(0, channel.pendingCount());
}
