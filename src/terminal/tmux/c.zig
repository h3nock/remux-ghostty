//! Top-level libghostty C boundary for the sans-I/O tmux control client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ControlClient = @import("client.zig").ControlClient;
const SharedTerminal = @import("../Shared.zig");
const Viewer = @import("viewer.zig").Viewer;
const Layout = @import("layout.zig").Layout;
const CommandToken = @import("channel.zig").CommandToken;
const state = &@import("../../global.zig").state;

pub const Result = enum(c_int) {
    ok,
    invalid_input,
    out_of_memory,
    not_ready,
    closed,
    failed,
    reentrant_feed,
    invalid_command,
    token_exhausted,
    invalid_consumption,
    pane_unknown,
    callback_active,
};

pub const Bytes = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    fn fromSlice(value: []const u8) Bytes {
        return .{
            .ptr = if (value.len == 0) null else value.ptr,
            .len = value.len,
        };
    }

    fn slice(self: Bytes) error{InvalidInput}![]const u8 {
        const ptr = self.ptr orelse {
            if (self.len != 0) return error.InvalidInput;
            return &.{};
        };
        return ptr[0..self.len];
    }
};

pub const ActionTag = enum(c_int) {
    exit,
    topology,
    pane_changed,
    command_complete,
    input_failed,
};

pub const ExitReason = enum(c_int) {
    server,
    unsupported_version,
    client_failure,
};

pub const CommandStatus = enum(c_int) {
    success,
    error_block,
    skipped,
};

pub const PanePhase = enum(c_int) {
    hydrating,
    live,
};

pub const TopologyRecordTag = enum(c_int) {
    window,
    pane,
};

pub const WindowRecord = extern struct {
    id: u64,
    active: bool,
    zoomed: bool,
    width: usize,
    height: usize,
    active_pane_id: u64,
    name: Bytes,
};

pub const PaneRecord = extern struct {
    id: u64,
    window_id: u64,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    phase: PanePhase,
};

pub const TopologyRecordValue = extern union {
    window: WindowRecord,
    pane: PaneRecord,
};

pub const TopologyRecord = extern struct {
    tag: TopologyRecordTag,
    value: TopologyRecordValue,
};

pub const CommandCompletion = extern struct {
    token: u64,
    status: CommandStatus,
    body: Bytes,
    cause_token: u64,
};

pub const TopologyAction = extern struct {
    view: *const TopologyView,
    session_name: Bytes,
};

pub const ExitAction = extern struct {
    reason: ExitReason,
    detail: Bytes,
};

pub const ActionValue = extern union {
    exit: ExitAction,
    topology: TopologyAction,
    pane_id: u64,
    command: CommandCompletion,
    input_failure: Bytes,
};

pub const Action = extern struct {
    tag: ActionTag,
    value: ActionValue,
};

pub const ActionCallback = *const fn (
    userdata: ?*anyopaque,
    action: *const Action,
) callconv(.c) void;

pub const TopologyVisitor = *const fn (
    userdata: ?*anyopaque,
    record: *const TopologyRecord,
) callconv(.c) void;

pub const Config = extern struct {
    userdata: ?*anyopaque = null,
    action_cb: ?ActionCallback = null,
    history_line_limit_is_set: bool = false,
    history_line_limit: usize = 0,
    max_scrollback: usize = 10_000,
    initial_columns: u16 = 0,
    initial_rows: u16 = 0,

    fn initialClientSize(self: Config) error{InvalidInput}!?Viewer.ClientSize {
        if (self.initial_columns == 0 and self.initial_rows == 0) return null;
        if (self.initial_columns == 0 or self.initial_rows == 0) {
            return error.InvalidInput;
        }
        return .{
            .columns = self.initial_columns,
            .rows = self.initial_rows,
        };
    }
};

pub const TopologyView = struct {
    client: *const ControlClient,
    windows: []const Viewer.Window,
};

pub const Client = struct {
    alloc: Allocator,
    control: ControlClient,
    userdata: ?*anyopaque,
    action_cb: ActionCallback,
    group_members: std.ArrayList([]const u8) = .empty,
    callback_active: bool = false,

    fn init(
        alloc: Allocator,
        config: Config,
    ) (Allocator.Error || error{InvalidInput})!Client {
        return .{
            .alloc = alloc,
            .control = try .init(alloc, .{
                .max_scrollback = config.max_scrollback,
                .history_line_limit = if (config.history_line_limit_is_set)
                    config.history_line_limit
                else
                    null,
                .initial_client_size = try config.initialClientSize(),
            }),
            .userdata = config.userdata,
            .action_cb = config.action_cb.?,
        };
    }

    fn deinit(self: *Client) void {
        self.group_members.deinit(self.alloc);
        self.control.deinit();
    }

    pub fn controlClientAction(
        self: *Client,
        action: ControlClient.Action,
    ) void {
        switch (action) {
            .exit => |reason| {
                const exit: ExitAction = switch (reason) {
                    .server_exit => |detail| .{
                        .reason = .server,
                        .detail = .fromSlice(detail),
                    },
                    .unsupported_version => |version| .{
                        .reason = .unsupported_version,
                        .detail = .fromSlice(version),
                    },
                    .client_failure => .{
                        .reason = .client_failure,
                        .detail = .fromSlice(&.{}),
                    },
                };
                var value: Action = .{
                    .tag = .exit,
                    .value = .{ .exit = exit },
                };
                self.emit(&value);
            },

            .windows => |windows| {
                var view: TopologyView = .{
                    .client = &self.control,
                    .windows = windows,
                };
                var value: Action = .{
                    .tag = .topology,
                    .value = .{ .topology = .{
                        .view = &view,
                        .session_name = .fromSlice(self.control.sessionName()),
                    } },
                };
                self.emit(&value);
            },

            .pane_changed => |pane_id| {
                var value: Action = .{
                    .tag = .pane_changed,
                    .value = .{ .pane_id = @intCast(pane_id) },
                };
                self.emit(&value);
            },

            .command_complete => |completion| {
                const command: CommandCompletion = switch (completion.result) {
                    .success => |body| .{
                        .token = @intFromEnum(completion.token),
                        .status = .success,
                        .body = .fromSlice(body),
                        .cause_token = 0,
                    },
                    .error_block => |body| .{
                        .token = @intFromEnum(completion.token),
                        .status = .error_block,
                        .body = .fromSlice(body),
                        .cause_token = 0,
                    },
                    .skipped_after_error => |cause| .{
                        .token = @intFromEnum(completion.token),
                        .status = .skipped,
                        .body = .fromSlice(&.{}),
                        .cause_token = @intFromEnum(cause),
                    },
                };
                var value: Action = .{
                    .tag = .command_complete,
                    .value = .{ .command = command },
                };
                self.emit(&value);
            },

            .input_failed => |body| {
                var value: Action = .{
                    .tag = .input_failed,
                    .value = .{ .input_failure = .fromSlice(body) },
                };
                self.emit(&value);
            },
        }
    }

    fn emit(self: *Client, action: *const Action) void {
        std.debug.assert(!self.callback_active);
        self.callback_active = true;
        defer self.callback_active = false;
        self.action_cb(self.userdata, action);
    }
};

export fn ghostty_tmux_client_config_new() Config {
    return .{};
}

export fn ghostty_tmux_client_new(
    config_ptr: ?*const Config,
    out_ptr: ?*?*Client,
) Result {
    const out = out_ptr orelse return .invalid_input;
    out.* = null;
    const config = config_ptr orelse return .invalid_input;
    if (config.action_cb == null) return .invalid_input;
    _ = config.initialClientSize() catch return .invalid_input;

    const client = state.alloc.create(Client) catch return .out_of_memory;
    client.* = Client.init(state.alloc, config.*) catch |err| {
        state.alloc.destroy(client);
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidInput => .invalid_input,
        };
    };
    out.* = client;
    return .ok;
}

export fn ghostty_tmux_client_free(client: ?*Client) Result {
    const value = client orelse return .ok;
    if (value.callback_active) return .callback_active;

    const alloc = value.alloc;
    value.deinit();
    alloc.destroy(value);
    return .ok;
}

export fn ghostty_tmux_client_feed(
    client: ?*Client,
    ptr: ?[*]const u8,
    len: usize,
) Result {
    const value = client orelse return .invalid_input;
    const bytes = (Bytes{ .ptr = ptr, .len = len }).slice() catch
        return .invalid_input;
    value.control.feed(bytes, value) catch |err| return mapClientError(err);
    return .ok;
}

export fn ghostty_tmux_client_outbound(
    client: ?*const Client,
    out_ptr: ?*Bytes,
) Result {
    const value = client orelse return .invalid_input;
    const out = out_ptr orelse return .invalid_input;
    out.* = .fromSlice(value.control.outboundBytes());
    return .ok;
}

export fn ghostty_tmux_client_consume(
    client: ?*Client,
    len: usize,
) Result {
    const value = client orelse return .invalid_input;
    if (value.callback_active) return .callback_active;
    value.control.consumeOutbound(len) catch return .invalid_consumption;
    return .ok;
}

export fn ghostty_tmux_client_enqueue_command(
    client: ?*Client,
    command: Bytes,
    token_out: ?*u64,
) Result {
    const value = client orelse return .invalid_input;
    const out = token_out orelse return .invalid_input;
    const bytes = command.slice() catch return .invalid_input;
    const token = value.control.enqueueCommand(bytes) catch |err|
        return mapClientError(err);
    out.* = @intFromEnum(token);
    return .ok;
}

export fn ghostty_tmux_client_enqueue_command_group(
    client: ?*Client,
    members_ptr: ?[*]const Bytes,
    count: usize,
    tokens_ptr: ?[*]u64,
) Result {
    const value = client orelse return .invalid_input;
    if (count == 0) return .invalid_command;
    const members = members_ptr orelse return .invalid_input;
    const tokens = tokens_ptr orelse return .invalid_input;

    value.group_members.clearRetainingCapacity();
    defer value.group_members.clearRetainingCapacity();
    value.group_members.ensureTotalCapacity(value.alloc, count) catch
        return .out_of_memory;
    for (members[0..count]) |member| {
        value.group_members.appendAssumeCapacity(
            member.slice() catch return .invalid_input,
        );
    }

    const command_tokens: [*]CommandToken = @ptrCast(tokens);
    value.control.enqueueCommandGroup(
        value.group_members.items,
        command_tokens[0..count],
    ) catch |err| return mapClientError(err);
    return .ok;
}

export fn ghostty_tmux_client_send_pane_input(
    client: ?*Client,
    pane_id: u64,
    ptr: ?[*]const u8,
    len: usize,
) Result {
    const value = client orelse return .invalid_input;
    const id = std.math.cast(usize, pane_id) orelse return .invalid_input;
    const bytes = (Bytes{ .ptr = ptr, .len = len }).slice() catch
        return .invalid_input;
    value.control.sendPaneInput(id, bytes) catch |err|
        return mapClientError(err);
    return .ok;
}

export fn ghostty_tmux_client_refresh_pane(
    client: ?*Client,
    pane_id: u64,
) Result {
    const value = client orelse return .invalid_input;
    const id = std.math.cast(usize, pane_id) orelse return .invalid_input;
    value.control.refreshPane(id) catch |err| return mapClientError(err);
    return .ok;
}

export fn ghostty_tmux_client_retain_pane_terminal(
    client: ?*Client,
    pane_id: u64,
    out_ptr: ?*?*SharedTerminal,
) Result {
    const value = client orelse return .invalid_input;
    const out = out_ptr orelse return .invalid_input;
    out.* = null;
    const id = std.math.cast(usize, pane_id) orelse return .invalid_input;
    out.* = value.control.retainPaneTerminal(id) orelse return .pane_unknown;
    return .ok;
}

export fn ghostty_tmux_topology_visit(
    view_ptr: ?*const TopologyView,
    userdata: ?*anyopaque,
    visitor_ptr: ?TopologyVisitor,
) Result {
    const view = view_ptr orelse return .invalid_input;
    const visitor = visitor_ptr orelse return .invalid_input;

    for (view.windows) |window| {
        var record: TopologyRecord = .{
            .tag = .window,
            .value = .{ .window = .{
                .id = @intCast(window.id),
                .active = window.is_active,
                .zoomed = window.is_zoomed,
                .width = window.width,
                .height = window.height,
                .active_pane_id = @intCast(window.active_pane_id),
                .name = .fromSlice(window.name),
            } },
        };
        visitor(userdata, &record);
        visitLayout(view, window.id, window.layout, userdata, visitor);
    }
    return .ok;
}

fn visitLayout(
    view: *const TopologyView,
    window_id: usize,
    layout: Layout,
    userdata: ?*anyopaque,
    visitor: TopologyVisitor,
) void {
    switch (layout.content) {
        .horizontal, .vertical => |children| {
            for (children) |child| {
                visitLayout(view, window_id, child, userdata, visitor);
            }
        },
        .pane => |pane_id| {
            // Published windows and the pane map are synchronized atomically
            // by Viewer before this callback is emitted.
            const phase = view.client.panePhase(pane_id) orelse unreachable;
            var record: TopologyRecord = .{
                .tag = .pane,
                .value = .{ .pane = .{
                    .id = @intCast(pane_id),
                    .window_id = @intCast(window_id),
                    .x = layout.x,
                    .y = layout.y,
                    .width = layout.width,
                    .height = layout.height,
                    .phase = switch (phase) {
                        .hydrating => .hydrating,
                        .live => .live,
                    },
                } },
            };
            visitor(userdata, &record);
        },
    }
}

fn mapClientError(err: ControlClient.Error) Result {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.NotReady => .not_ready,
        error.ChannelClosed => .closed,
        error.ClientFailed => .failed,
        error.ReentrantFeed => .reentrant_feed,
        error.InvalidCommand => .invalid_command,
        error.InvalidTokenCount => .invalid_input,
        error.TokenExhausted => .token_exhausted,
        error.PaneUnknown => .pane_unknown,
    };
}

const TestContext = struct {
    client: ?*Client = null,
    topology_count: usize = 0,
    exit_count: usize = 0,
    exit_reason: ?ExitReason = null,
    exit_detail: [128]u8 = undefined,
    exit_detail_len: usize = 0,
    pane_changed_count: usize = 0,
    pane_changed_ids: [8]u64 = undefined,
    completions: [16]CommandCompletion = undefined,
    completion_count: usize = 0,
    records: [16]TopologyRecord = undefined,
    record_count: usize = 0,
    session_name: [64]u8 = undefined,
    session_name_len: usize = 0,
    exercise_callback_guard: bool = false,
    enqueue_in_callback: bool = false,
    callback_free_result: Result = .failed,
    callback_consume_result: Result = .failed,
    callback_enqueue_result: Result = .failed,
    callback_token: u64 = 0,
    retain_pane_id: ?u64 = null,
    callback_retain_result: Result = .failed,
    retained_terminal: ?*SharedTerminal = null,
    input_failure_count: usize = 0,
    input_failure_body: [128]u8 = undefined,
    input_failure_len: usize = 0,

    fn action(
        userdata: ?*anyopaque,
        value: *const Action,
    ) callconv(.c) void {
        const self: *TestContext = @ptrCast(@alignCast(userdata.?));
        switch (value.tag) {
            .exit => {
                self.exit_count += 1;
                self.exit_reason = value.value.exit.reason;
                const detail = value.value.exit.detail.slice() catch
                    @panic("invalid exit detail");
                if (detail.len > self.exit_detail.len) {
                    @panic("exit detail too long");
                }
                @memcpy(self.exit_detail[0..detail.len], detail);
                self.exit_detail_len = detail.len;
            },
            .topology => {
                self.topology_count += 1;
                self.record_count = 0;

                const topology = value.value.topology;
                const name = topology.session_name.slice() catch @panic("invalid session name");
                if (name.len > self.session_name.len) @panic("session name too long");
                @memcpy(self.session_name[0..name.len], name);
                self.session_name_len = name.len;

                if (ghostty_tmux_topology_visit(
                    topology.view,
                    self,
                    TestContext.visit,
                ) != .ok) @panic("topology visit failed");

                if (self.exercise_callback_guard) {
                    self.callback_consume_result = ghostty_tmux_client_consume(
                        self.client,
                        0,
                    );
                    self.callback_free_result = ghostty_tmux_client_free(self.client);
                }
                if (self.enqueue_in_callback) {
                    const command = "display-message -p callback";
                    self.callback_enqueue_result = ghostty_tmux_client_enqueue_command(
                        self.client,
                        .fromSlice(command),
                        &self.callback_token,
                    );
                }
                if (self.retain_pane_id) |pane_id| {
                    self.callback_retain_result = ghostty_tmux_client_retain_pane_terminal(
                        self.client,
                        pane_id,
                        &self.retained_terminal,
                    );
                }
            },
            .pane_changed => {
                if (self.pane_changed_count >= self.pane_changed_ids.len) {
                    @panic("too many pane changes");
                }
                self.pane_changed_ids[self.pane_changed_count] = value.value.pane_id;
                self.pane_changed_count += 1;
            },
            .command_complete => {
                if (self.completion_count >= self.completions.len) {
                    @panic("too many completions");
                }
                self.completions[self.completion_count] = value.value.command;
                self.completion_count += 1;
            },
            .input_failed => {
                const body = value.value.input_failure.slice() catch
                    @panic("invalid input failure body");
                if (body.len > self.input_failure_body.len) {
                    @panic("input failure body too long");
                }
                @memcpy(self.input_failure_body[0..body.len], body);
                self.input_failure_len = body.len;
                self.input_failure_count += 1;
            },
        }
    }

    fn visit(
        userdata: ?*anyopaque,
        record: *const TopologyRecord,
    ) callconv(.c) void {
        const self: *TestContext = @ptrCast(@alignCast(userdata.?));
        if (self.record_count >= self.records.len) @panic("too many records");
        self.records[self.record_count] = record.*;
        self.record_count += 1;
    }
};

fn testConfig(context: *TestContext) Config {
    return .{
        .userdata = context,
        .action_cb = TestContext.action,
    };
}

fn feedTest(client: *Client, bytes: []const u8) !void {
    try std.testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_feed(client, bytes.ptr, bytes.len),
    );
}

fn consumeAllTest(client: *Client) !void {
    var outbound: Bytes = undefined;
    try std.testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_outbound(client, &outbound),
    );
    try std.testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_consume(client, outbound.len),
    );
}

fn openPaneTestClient(client: *Client) !void {
    try feedTest(
        client,
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
    );
    try consumeAllTest(client);
    try feedTest(
        client,
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n" ++
            "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0\n" ++
            "%end 3 3 1\n",
    );
    try consumeAllTest(client);
    try feedTest(
        client,
        "%begin 4 4 1\n%end 4 4 1\n" ++
            "%begin 5 5 1\n%end 5 5 1\n" ++
            "%begin 6 6 1\n%end 6 6 1\n" ++
            "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\n%end 8 8 1\n",
    );
}

fn expectStructLayout(comptime Zig: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(Zig), @sizeOf(C));
    try std.testing.expectEqual(@alignOf(Zig), @alignOf(C));
    inline for (std.meta.fields(Zig)) |field| {
        try std.testing.expectEqual(
            @offsetOf(Zig, field.name),
            @offsetOf(C, field.name),
        );
    }
}

fn expectUnionLayout(comptime Zig: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(Zig), @sizeOf(C));
    try std.testing.expectEqual(@alignOf(Zig), @alignOf(C));
}

test "tmux C client public ABI matches ghostty header" {
    const testing = std.testing;
    const c = @import("ghostty.h");

    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_tmux_result_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_tmux_action_tag_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_tmux_exit_reason_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_tmux_command_status_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_tmux_pane_phase_e));
    try testing.expectEqual(@sizeOf(c_int), @sizeOf(c.ghostty_tmux_topology_record_tag_e));

    try testing.expectEqual(@as(c_int, @intFromEnum(Result.ok)), @as(c_int, c.GHOSTTY_TMUX_RESULT_OK));
    try testing.expectEqual(@as(c_int, @intFromEnum(Result.callback_active)), @as(c_int, c.GHOSTTY_TMUX_RESULT_CALLBACK_ACTIVE));
    try testing.expectEqual(@as(c_int, @intFromEnum(ActionTag.exit)), @as(c_int, c.GHOSTTY_TMUX_ACTION_EXIT));
    try testing.expectEqual(@as(c_int, @intFromEnum(ActionTag.command_complete)), @as(c_int, c.GHOSTTY_TMUX_ACTION_COMMAND_COMPLETE));
    try testing.expectEqual(@as(c_int, @intFromEnum(ActionTag.input_failed)), @as(c_int, c.GHOSTTY_TMUX_ACTION_INPUT_FAILED));
    try testing.expectEqual(@as(c_int, @intFromEnum(ExitReason.server)), @as(c_int, c.GHOSTTY_TMUX_EXIT_SERVER));
    try testing.expectEqual(@as(c_int, @intFromEnum(ExitReason.unsupported_version)), @as(c_int, c.GHOSTTY_TMUX_EXIT_UNSUPPORTED_VERSION));
    try testing.expectEqual(@as(c_int, @intFromEnum(ExitReason.client_failure)), @as(c_int, c.GHOSTTY_TMUX_EXIT_CLIENT_FAILURE));
    try testing.expectEqual(@as(c_int, @intFromEnum(CommandStatus.success)), @as(c_int, c.GHOSTTY_TMUX_COMMAND_SUCCESS));
    try testing.expectEqual(@as(c_int, @intFromEnum(CommandStatus.skipped)), @as(c_int, c.GHOSTTY_TMUX_COMMAND_SKIPPED));
    try testing.expectEqual(@as(c_int, @intFromEnum(PanePhase.hydrating)), @as(c_int, c.GHOSTTY_TMUX_PANE_HYDRATING));
    try testing.expectEqual(@as(c_int, @intFromEnum(PanePhase.live)), @as(c_int, c.GHOSTTY_TMUX_PANE_LIVE));
    try testing.expectEqual(@as(c_int, @intFromEnum(TopologyRecordTag.window)), @as(c_int, c.GHOSTTY_TMUX_TOPOLOGY_WINDOW));
    try testing.expectEqual(@as(c_int, @intFromEnum(TopologyRecordTag.pane)), @as(c_int, c.GHOSTTY_TMUX_TOPOLOGY_PANE));

    try expectStructLayout(Bytes, c.ghostty_tmux_bytes_s);
    try expectStructLayout(WindowRecord, c.ghostty_tmux_window_record_s);
    try expectStructLayout(PaneRecord, c.ghostty_tmux_pane_record_s);
    try expectUnionLayout(TopologyRecordValue, c.ghostty_tmux_topology_record_u);
    try expectStructLayout(TopologyRecord, c.ghostty_tmux_topology_record_s);
    try expectStructLayout(CommandCompletion, c.ghostty_tmux_command_completion_s);
    try expectStructLayout(TopologyAction, c.ghostty_tmux_topology_action_s);
    try expectStructLayout(ExitAction, c.ghostty_tmux_exit_action_s);
    try expectUnionLayout(ActionValue, c.ghostty_tmux_action_u);
    try expectStructLayout(Action, c.ghostty_tmux_action_s);
    try expectStructLayout(Config, c.ghostty_tmux_client_config_s);
}

test "tmux C client config and invalid boundaries" {
    const testing = std.testing;
    const defaults = ghostty_tmux_client_config_new();
    try testing.expect(defaults.action_cb == null);
    try testing.expect(!defaults.history_line_limit_is_set);
    try testing.expectEqual(10_000, defaults.max_scrollback);
    try testing.expectEqual(0, defaults.initial_columns);
    try testing.expectEqual(0, defaults.initial_rows);

    var out: ?*Client = undefined;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_new(null, &out),
    );
    try testing.expect(out == null);

    var missing_callback: Config = .{};
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_new(&missing_callback, &out),
    );
    try testing.expect(out == null);

    var mixed_size = missing_callback;
    mixed_size.action_cb = TestContext.action;
    mixed_size.initial_columns = 80;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_new(&mixed_size, &out),
    );
    try testing.expect(out == null);
    mixed_size.initial_columns = 0;
    mixed_size.initial_rows = 24;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_new(&mixed_size, &out),
    );
    try testing.expect(out == null);

    var context: TestContext = .{};
    var config = testConfig(&context);
    state.alloc = testing.allocator;
    try testing.expectEqual(Result.ok, ghostty_tmux_client_new(&config, &out));
    const client = out.?;
    defer testing.expectEqual(Result.ok, ghostty_tmux_client_free(client)) catch
        @panic("tmux client cleanup failed");
    context.client = client;

    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_feed(client, null, 1),
    );
    try testing.expectEqual(Result.ok, ghostty_tmux_client_feed(client, null, 0));
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_outbound(client, null),
    );
    try testing.expectEqual(
        Result.invalid_consumption,
        ghostty_tmux_client_consume(client, 1),
    );

    var token: u64 = 999;
    try testing.expectEqual(
        Result.not_ready,
        ghostty_tmux_client_enqueue_command(client, .{}, &token),
    );
    try testing.expectEqual(999, token);
    try testing.expectEqual(
        Result.invalid_command,
        ghostty_tmux_client_enqueue_command_group(client, null, 0, null),
    );

    var terminal: ?*SharedTerminal = @ptrFromInt(@alignOf(SharedTerminal));
    try testing.expectEqual(
        Result.pane_unknown,
        ghostty_tmux_client_retain_pane_terminal(client, 99, &terminal),
    );
    try testing.expect(terminal == null);

    try feedTest(
        client,
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
    );
    try consumeAllTest(client);
    try feedTest(
        client,
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n%end 3 3 1\n",
    );
    try testing.expectEqual(
        Result.invalid_command,
        ghostty_tmux_client_enqueue_command(client, .{}, &token),
    );
    try testing.expectEqual(999, token);

    try testing.expectEqual(Result.ok, ghostty_tmux_client_free(null));
}

test "tmux C client transport batching and callback contract" {
    const testing = std.testing;
    var context: TestContext = .{
        .exercise_callback_guard = true,
        .enqueue_in_callback = true,
    };
    var client = try Client.init(testing.allocator, testConfig(&context));
    defer client.deinit();
    context.client = &client;

    const startup = "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n";
    try feedTest(&client, startup[0..17]);
    try feedTest(&client, startup[17..]);

    var outbound: Bytes = undefined;
    try testing.expectEqual(Result.ok, ghostty_tmux_client_outbound(&client, &outbound));
    const initial = try outbound.slice();
    try testing.expect(std.mem.startsWith(u8, initial, "display-message"));
    const partial = "display-message".len;
    const expected_remainder = try testing.allocator.dupe(u8, initial[partial..]);
    defer testing.allocator.free(expected_remainder);
    try testing.expectEqual(Result.ok, ghostty_tmux_client_consume(&client, partial));
    try testing.expectEqual(Result.ok, ghostty_tmux_client_outbound(&client, &outbound));
    try testing.expectEqualSlices(u8, expected_remainder, try outbound.slice());
    try consumeAllTest(&client);

    try feedTest(
        &client,
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n%end 3 3 1\n",
    );
    try testing.expectEqual(1, context.topology_count);
    try testing.expectEqualStrings("main", context.session_name[0..context.session_name_len]);
    try testing.expectEqual(Result.callback_active, context.callback_consume_result);
    try testing.expectEqual(Result.callback_active, context.callback_free_result);
    try testing.expectEqual(Result.ok, context.callback_enqueue_result);

    var one: u64 = undefined;
    var two: u64 = undefined;
    try testing.expectEqual(Result.ok, ghostty_tmux_client_enqueue_command(
        &client,
        .fromSlice("display-message -p one"),
        &one,
    ));
    try testing.expectEqual(Result.ok, ghostty_tmux_client_enqueue_command(
        &client,
        .fromSlice("display-message -p two"),
        &two,
    ));
    try testing.expectEqual(Result.ok, ghostty_tmux_client_outbound(&client, &outbound));
    try testing.expectEqualStrings(
        "display-message -p callback\n" ++
            "display-message -p one\n" ++
            "display-message -p two\n",
        try outbound.slice(),
    );
    try consumeAllTest(&client);

    try feedTest(
        &client,
        "%begin 4 4 1\ncallback\n%end 4 4 1\n" ++
            "%begin 5 5 1\none\n%end 5 5 1\n" ++
            "%begin 6 6 1\ntwo\n%end 6 6 1\n",
    );
    try testing.expectEqual(3, context.completion_count);
    try testing.expectEqual(context.callback_token, context.completions[0].token);
    try testing.expectEqual(one, context.completions[1].token);
    try testing.expectEqual(two, context.completions[2].token);
    for (context.completions[0..3]) |completion| {
        try testing.expectEqual(CommandStatus.success, completion.status);
    }

    const members = [_]Bytes{
        .fromSlice("first"),
        .fromSlice("second"),
        .fromSlice("third"),
    };
    var group_tokens: [3]u64 = undefined;
    var later: u64 = undefined;
    try testing.expectEqual(Result.ok, ghostty_tmux_client_enqueue_command_group(
        &client,
        &members,
        members.len,
        &group_tokens,
    ));
    try testing.expectEqual(Result.ok, ghostty_tmux_client_enqueue_command(
        &client,
        .fromSlice("later"),
        &later,
    ));
    try testing.expectEqual(Result.ok, ghostty_tmux_client_outbound(&client, &outbound));
    try testing.expectEqualStrings("first ; second ; third\nlater\n", try outbound.slice());
    try consumeAllTest(&client);

    context.completion_count = 0;
    try feedTest(
        &client,
        "%begin 7 7 1\n%end 7 7 1\n" ++
            "%begin 8 8 1\nfailed\n%error 8 8 1\n" ++
            "%begin 9 9 1\n%end 9 9 1\n" ++
            "%begin 10 10 1\nlater\n%end 10 10 1\n",
    );
    try testing.expectEqual(4, context.completion_count);
    try testing.expectEqual(CommandStatus.success, context.completions[0].status);
    try testing.expectEqual(group_tokens[0], context.completions[0].token);
    try testing.expectEqual(CommandStatus.error_block, context.completions[1].status);
    try testing.expectEqual(group_tokens[1], context.completions[1].token);
    try testing.expectEqual(CommandStatus.skipped, context.completions[2].status);
    try testing.expectEqual(group_tokens[2], context.completions[2].token);
    try testing.expectEqual(group_tokens[1], context.completions[2].cause_token);
    try testing.expectEqual(CommandStatus.success, context.completions[3].status);
    try testing.expectEqual(later, context.completions[3].token);
}

test "tmux C client initial size and structured exits" {
    const testing = std.testing;

    {
        var context: TestContext = .{};
        var config = testConfig(&context);
        config.initial_columns = 117;
        config.initial_rows = 41;
        var client = try Client.init(testing.allocator, config);
        defer client.deinit();
        context.client = &client;

        try feedTest(
            &client,
            "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 main\n",
        );
        var outbound: Bytes = undefined;
        try testing.expectEqual(
            Result.ok,
            ghostty_tmux_client_outbound(&client, &outbound),
        );
        try testing.expectEqualStrings(
            "display-message -p '#{version}'\n" ++
                "refresh-client -C 117x41\n" ++
                "list-windows -F '#{session_id} #{window_id} #{window_active} #{pane_id} #{window_width} #{window_height} #{window_layout} #{window_visible_layout} #{window_name}'\n",
            try outbound.slice(),
        );
        try feedTest(
            &client,
            "%begin 2 2 1\n3.0a\n%end 2 2 1\n" ++
                "%begin 3 3 1\n%end 3 3 1\n" ++
                "%begin 4 4 1\n%end 4 4 1\n",
        );
        try testing.expectEqual(1, context.exit_count);
        try testing.expectEqual(ExitReason.unsupported_version, context.exit_reason.?);
        try testing.expectEqualStrings(
            "3.0a",
            context.exit_detail[0..context.exit_detail_len],
        );
    }

    {
        var context: TestContext = .{};
        var client = try Client.init(testing.allocator, testConfig(&context));
        defer client.deinit();
        context.client = &client;

        try feedTest(&client, "%exit detached\n");
        try testing.expectEqual(1, context.exit_count);
        try testing.expectEqual(ExitReason.server, context.exit_reason.?);
        try testing.expectEqualStrings(
            "detached",
            context.exit_detail[0..context.exit_detail_len],
        );
    }

    {
        var context: TestContext = .{};
        var client = try Client.init(testing.allocator, testConfig(&context));
        defer client.deinit();
        context.client = &client;

        try feedTest(&client, "x");
        try testing.expectEqual(1, context.exit_count);
        try testing.expectEqual(ExitReason.client_failure, context.exit_reason.?);
        try testing.expectEqual(0, context.exit_detail_len);
    }
}

test "tmux C client pane input validation and action mapping" {
    const testing = std.testing;
    var context: TestContext = .{};
    var client = try Client.init(testing.allocator, testConfig(&context));
    defer client.deinit();
    context.client = &client;

    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_send_pane_input(null, 0, null, 0),
    );
    try testing.expectEqual(
        Result.not_ready,
        ghostty_tmux_client_send_pane_input(&client, 0, null, 0),
    );
    try openPaneTestClient(&client);

    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_send_pane_input(&client, 0, null, 1),
    );
    try testing.expectEqual(
        Result.pane_unknown,
        ghostty_tmux_client_send_pane_input(&client, 99, null, 0),
    );
    try testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_send_pane_input(&client, 0, null, 0),
    );

    var outbound: Bytes = undefined;
    try testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_outbound(&client, &outbound),
    );
    try testing.expectEqualStrings("", try outbound.slice());

    const binary = [_]u8{ 0x00, 0x1b, 0x80, 0xff };
    try testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_send_pane_input(
            &client,
            0,
            &binary,
            binary.len,
        ),
    );
    try testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_outbound(&client, &outbound),
    );
    try testing.expectEqualStrings(
        "send-keys -H -t %0 00 1b 80 ff\n",
        try outbound.slice(),
    );
    try consumeAllTest(&client);
    try feedTest(
        &client,
        "%begin 9 9 1\npane input rejected\n%error 9 9 1\n",
    );
    try testing.expectEqual(0, context.completion_count);
    try testing.expectEqual(1, context.input_failure_count);
    try testing.expectEqualStrings(
        "pane input rejected",
        context.input_failure_body[0..context.input_failure_len],
    );
}

test "tmux C client pane refresh boundary" {
    const testing = std.testing;
    var context: TestContext = .{};
    var client = try Client.init(testing.allocator, testConfig(&context));
    defer client.deinit();
    context.client = &client;

    try testing.expectEqual(
        Result.invalid_input,
        ghostty_tmux_client_refresh_pane(null, 0),
    );
    try testing.expectEqual(
        Result.not_ready,
        ghostty_tmux_client_refresh_pane(&client, 0),
    );
    try openPaneTestClient(&client);
    try testing.expectEqual(
        Result.pane_unknown,
        ghostty_tmux_client_refresh_pane(&client, 99),
    );
    try testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_refresh_pane(&client, 0),
    );
    try testing.expectEqual(
        Result.not_ready,
        ghostty_tmux_client_refresh_pane(&client, 0),
    );
    try testing.expectEqual(
        ControlClient.PanePhase.hydrating,
        client.control.panePhase(0).?,
    );

    var outbound: Bytes = undefined;
    try testing.expectEqual(
        Result.ok,
        ghostty_tmux_client_outbound(&client, &outbound),
    );
    const bytes = try outbound.slice();
    try testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "display-message -p -t %0 -F '",
    ));
    try testing.expect(std.mem.indexOf(u8, bytes, "#{pane_width}") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "#{pane_height}") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, " ; capture-pane -p -e -N -q -S -") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, " ; capture-pane -p -e -N -a -q -t %0") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, " ; capture-pane -p -e -N -q -t %0") != null);
    try testing.expect(std.mem.endsWith(u8, bytes, " ; capture-pane -p -P -C -t %0\n"));

    context.pane_changed_count = 0;
    try consumeAllTest(&client);
    try feedTest(
        &client,
        "%begin 9 9 1\n" ++
            "%0;100;40;0;0;1;block;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;39;8,16\n" ++
            "%end 9 9 1\n" ++
            "%begin 10 10 1\n%end 10 10 1\n" ++
            "%begin 11 11 1\n%end 11 11 1\n" ++
            "%begin 12 12 1\nrefreshed\n%end 12 12 1\n" ++
            "%begin 13 13 1\n%end 13 13 1\n",
    );
    try testing.expectEqual(1, context.pane_changed_count);
    try testing.expectEqual(0, context.pane_changed_ids[0]);
    try testing.expectEqual(
        ControlClient.PanePhase.live,
        client.control.panePhase(0).?,
    );
}

test "tmux C client topology and retained terminal lifetime" {
    const testing = std.testing;
    var context: TestContext = .{ .retain_pane_id = 0 };
    var client = try Client.init(testing.allocator, testConfig(&context));
    var client_live = true;
    defer if (client_live) client.deinit();
    context.client = &client;

    try feedTest(
        &client,
        "%begin 1 1 0\n%end 1 1 0\n%session-changed $42 work\n",
    );
    try consumeAllTest(&client);
    try feedTest(
        &client,
        "%begin 2 2 1\n3.1\n%end 2 2 1\n" ++
            "%begin 3 3 1\n" ++
            "$42 @0 1 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] editor window\n" ++
            "%end 3 3 1\n",
    );

    try testing.expectEqual(1, context.topology_count);
    try testing.expectEqualStrings("work", context.session_name[0..context.session_name_len]);
    try testing.expectEqual(3, context.record_count);
    try testing.expectEqual(TopologyRecordTag.window, context.records[0].tag);
    const window = context.records[0].value.window;
    try testing.expectEqual(0, window.id);
    try testing.expect(window.active);
    try testing.expect(!window.zoomed);
    try testing.expectEqual(83, window.width);
    try testing.expectEqual(44, window.height);
    try testing.expectEqual(0, window.active_pane_id);
    try testing.expectEqualStrings("editor window", try window.name.slice());

    try testing.expectEqual(TopologyRecordTag.pane, context.records[1].tag);
    const first = context.records[1].value.pane;
    try testing.expectEqual(0, first.id);
    try testing.expectEqual(0, first.window_id);
    try testing.expectEqual(0, first.x);
    try testing.expectEqual(0, first.y);
    try testing.expectEqual(83, first.width);
    try testing.expectEqual(20, first.height);
    try testing.expectEqual(PanePhase.hydrating, first.phase);

    try testing.expectEqual(TopologyRecordTag.pane, context.records[2].tag);
    const second = context.records[2].value.pane;
    try testing.expectEqual(1, second.id);
    try testing.expectEqual(0, second.x);
    try testing.expectEqual(21, second.y);
    try testing.expectEqual(83, second.width);
    try testing.expectEqual(23, second.height);
    try testing.expectEqual(PanePhase.hydrating, second.phase);
    try testing.expectEqual(Result.ok, context.callback_retain_result);

    const retained = context.retained_terminal.?;
    client.deinit();
    client_live = false;
    context.client = null;
    defer retained.release();

    retained.mutex.lock();
    defer retained.mutex.unlock();
    try testing.expectEqual(83, retained.terminal.cols);
    try testing.expectEqual(20, retained.terminal.rows);
}
